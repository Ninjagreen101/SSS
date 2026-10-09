--!strict
--[[
	CombatService
	Server authority for sword combat (Spec Section 7). Clients only send
	intent ("I swing, aiming this way"); everything else happens here.

	Fighters
	  Every registered target (TargetService) gets a fighter record: what it
	  is doing (Idle / Attacking / Heavy / Dodging / Staggered / Broken), its
	  guard (Blocking, parry window), dodge invincibility, riposte window and
	  posture. CombatState / Posture / MaxPosture are mirrored to the model's
	  attributes so every client can show them.
	  Weapon Arts and Confluences run as an "Art" action (BeginMove); a hit
	  that staggers the caster cancels the rest of the move unless it has
	  hyper armour.

	Player actions (remotes)
	  RequestAttack       light combo hit. The server decides the combo step
	                      (it resets after Combo.ResetTime) and the timing.
	  RequestHeavyAttack  heavy blow; charge time is clamped to what the
	                      player could really have held.
	  RequestDodge        roll with invincibility frames.
	  RequestBlock        raise/lower guard. Raising it opens a short parry
	                      window (Longsword and touch players get a little more).

	Hits
	  A blow is checked when its windup ends: every enemy-team target within
	  reach and inside the swing arc is hit. Targets are rewound to where the
	  attacking player saw them (TargetService.PositionAt + RewindFor).
	  ResolveHit applies, in order:
	    dodge i-frames -> parry -> Aegis (Beacon) -> block -> clean hit
	    (crit, finisher on a Broken target, posture, stagger, Current siphon).
	  Only weapon blows siphon Current; other systems scale it (Infusion,
	  Pressure, Draw) through SetSiphonModifier.
	  Dummies and enemies use the same path through NpcSwing, so a parry or
	  dodge works identically against everything.
	  Big bodies (Floor Guardians): swings add the defender's HitRadius to
	  their reach and both fighters' HitHeight to the vertical tolerance
	  (TargetService.SetHitSize). An Unflinching fighter (SetUnflinching) is
	  not staggered by clean hits, parries or stuns; only a posture break
	  interrupts it. SetBrokenDuration overrides how long that break lasts.

	Feedback goes out as DamageDealt (numbers, flashes, hit stop) and
	SwingVisual (other players' slash effects) to players nearby.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Formulas = require(Shared.Data.Formulas)
local Items = require(Shared.Data.Items)

local DataService = require(script.Parent.DataService)
local GearService = require(script.Parent.GearService)
local VitalsService = require(script.Parent.VitalsService)
local TargetService = require(script.Parent.TargetService)
local WeaponService = require(script.Parent.WeaponService)
local AntiExploitService = require(script.Parent.AntiExploitService)

local C = Config.Combat
local A = Attributes.Names
local FRAME = C.Frame

export type Action = "Idle" | "Attacking" | "Heavy" | "Dodging" | "Casting" | "Art" | "Staggered" | "Broken"
export type HitKind =
	"Light"
	| "Heavy"
	| "Charged"
	| "Riposte"
	| "Thrust"
	| "Npc"
	| "Spell"
	| "Art"
	| "Confluence"
	| "Ability"
	| "Beacon"
export type Outcome =
	"Hit"
	| "Blocked"
	| "GuardBreak"
	| "Parry"
	| "Dodge"
	| "PerfectDodge"
	| "Riposte"
	| "Finisher"
	| "Broken"
	| "Reaction"
	| "Absorbed"

export type HitSpec = {
	Damage: number,
	Posture: number,
	Kind: HitKind,
	Parryable: boolean,
	Blockable: boolean,
	HitStun: number,
	CritChance: number,
	CritMultiplier: number,
	Reaction: string?, -- a spell Reaction's name (already multiplied in Damage), e.g. "Shatter"
	Element: string?, -- Attunement of a magical blow (damage numbers use its colour)
}

export type SwingSpec = {
	Reach: number,
	Arc: number, -- degrees
	Aim: Vector3, -- horizontal unit vector
	Hit: HitSpec,
}

type Fighter = {
	Target: TargetService.Target,
	Action: Action,
	ActionEnd: number,
	Combo: number,
	LastLightEnd: number,
	Pending: thread?,
	Blocking: boolean,
	ParryUntil: number,
	ParryOpenedAt: number,
	DodgeStart: number,
	IFrameStart: number,
	IFrameEnd: number,
	RiposteUntil: number,
	Posture: number,
	MaxPosture: number,
	PostureHitAt: number,
	HyperArmor: boolean,
	Unflinching: boolean, -- clean hits, parries and stuns never stagger it (bosses)
	BrokenDuration: number?, -- seconds a posture break lasts (default Posture.BrokenDuration)
	HitCount: number,
	Sent: { [string]: any },
}

local CombatService = {}

-- (attacker model?, defender model, outcome, damage applied)
-- (attacker model?, defender model, outcome, damage applied, kind of blow)
CombatService.HitLanded = Signal.new() :: Signal.Signal<Model?, Model, Outcome, number, HitKind>
-- (parrying model, parried model?)
CombatService.Parried = Signal.new() :: Signal.Signal<Model, Model?>

local fighters: { [Model]: Fighter } = {}

-- Damage modifiers other systems plug in (statuses, Resonance):
--   taken(defender)        multiplies every blow a target takes (e.g. Heavy)
--   dealt(attacker, kind)  multiplies blows an attacker lands (e.g. Resonance)
type TakenModifier = (Model) -> number
type DealtModifier = (Model, HitKind) -> number
local takenModifier: TakenModifier? = nil
local dealtModifier: DealtModifier? = nil
-- Weak points (the Brinehulk's back): (defender, where the blow came from) -> damage x, posture x
type WeakPointResolver = (Model, Vector3) -> (number, number)
local weakPointResolver: WeakPointResolver? = nil
-- siphon(player) multiplies the Current a weapon blow draws (Infusion, Pressure, Draw).
type SiphonModifier = (Player) -> number
local siphonModifier: SiphonModifier? = nil
-- absorber(defender) returns true if something (the Aegis Beacon) eats this blow whole.
type Absorber = (Model) -> boolean
local absorber: Absorber? = nil

-- Weapon blows: they siphon Current, count as sword hits for Resonance and Infusion.
local WEAPON_KINDS: { [string]: boolean } = { Light = true, Heavy = true, Charged = true, Riposte = true, Thrust = true }

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- STATE ----------------------------------------------------------------------

local function setAttr(f: Fighter, name: string, value: any)
	if f.Sent[name] ~= value then
		f.Sent[name] = value
		f.Target.Model:SetAttribute(name, value)
	end
end

local function push(f: Fighter)
	local state: string = f.Action
	if state == "Idle" and f.Blocking then
		state = "Blocking"
	end
	setAttr(f, A.CombatState, state)
	setAttr(f, A.Posture, math.floor(f.Posture + 0.5))
	setAttr(f, A.MaxPosture, f.MaxPosture)
end

local function cancelPending(f: Fighter)
	local pending = f.Pending
	f.Pending = nil
	if pending and coroutine.status(pending) ~= "dead" then
		task.cancel(pending)
	end
end

local function startAction(f: Fighter, action: Action, duration: number)
	f.Action = action
	f.ActionEnd = now() + duration
	f.Blocking = false
	f.HyperArmor = false
	push(f)
end

-- Interrupts whatever the fighter was doing (stagger, guard break).
local function interrupt(f: Fighter, action: Action, duration: number)
	cancelPending(f)
	startAction(f, action, duration)
end

local function breakPosture(f: Fighter)
	f.Posture = f.MaxPosture
	interrupt(f, "Broken", f.BrokenDuration or C.Posture.BrokenDuration)
end

-- Adds posture damage; returns true if this broke the fighter.
local function addPosture(f: Fighter, amount: number): boolean
	if f.Action == "Broken" or amount <= 0 then
		return false
	end
	f.Posture = math.min(f.MaxPosture, f.Posture + amount)
	f.PostureHitAt = now()
	if f.Posture >= f.MaxPosture then
		breakPosture(f)
		return true
	end
	push(f)
	return false
end

local function isBusy(f: Fighter, t: number): boolean
	if f.Action == "Staggered" or f.Action == "Broken" then
		return true
	end
	return f.Action ~= "Idle" and t < f.ActionEnd - C.HitValidation.TimingTolerance
end

local function isAlive(f: Fighter): boolean
	return TargetService.IsAlive(f.Target)
end

-- FEEDBACK -------------------------------------------------------------------

local function playersNear(position: Vector3, except: Player?): { Player }
	local list = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if player ~= except and root and (root.Position - position).Magnitude <= C.FeedbackRadius then
			table.insert(list, player)
		end
	end
	return list
end

local function feedback(defender: Fighter, attacker: Fighter?, outcome: Outcome, amount: number, crit: boolean, hit: HitSpec?)
	local position = defender.Target.Root.Position
	local attackerModel = if attacker then attacker.Target.Model else nil
	local reaction = if hit then hit.Reaction else nil
	local element = if hit then hit.Element else nil
	Net.FireList(
		"DamageDealt",
		playersNear(position),
		defender.Target.Model,
		math.floor(amount + 0.5),
		outcome,
		crit,
		position,
		attackerModel,
		reaction,
		element
	)
end

local function reject(player: Player, action: string, reason: string)
	Net.Fire("ActionRejected", player, action, reason)
end

-- WEAPON NUMBERS -------------------------------------------------------------

type Loadout = {
	Def: Items.WeaponDef, -- this copy's numbers (rarity, upgrades, wear)
	Class: any,
	Strength: number, -- with gear
	Finesse: number,
	Speed: number,
	Crit: number, -- crit chance: Finesse + gear
	DamageBonus: number, -- gear "+x% weapon damage"
	PostureBonus: number,
}

local function loadout(player: Player): Loadout
	local _, def = WeaponService.GetWeapon(player)
	local class = C.WeaponClasses[def.Class]
	local stats = GearService.GetStats(player)
	return {
		Def = def,
		Class = class,
		Strength = stats.Strength,
		Finesse = stats.Finesse,
		Speed = Formulas.AttackSpeed(class.AttackSpeed, stats.Finesse),
		Crit = Formulas.CritChance(stats.Finesse) + GearService.Bonus(player, "CritChance"),
		DamageBonus = GearService.Bonus(player, "WeaponDamage"),
		PostureBonus = GearService.Bonus(player, "PostureDamage"),
	}
end

local function baseDamage(l: Loadout): number
	return l.Def.Damage * Formulas.WeaponScaling(l.Strength, l.Finesse, l.Def.Scaling) * (1 + l.DamageBonus)
end

local function basePosture(l: Loadout): number
	return l.Def.Posture * Formulas.PostureScaling(l.Strength) * (l.Class.PostureDamageMultiplier or 1) * (1 + l.PostureBonus)
end

-- HIT RESOLUTION -------------------------------------------------------------

-- True if `source` is inside the defender's guard (in front of them).
local function inFront(defender: Fighter, source: Vector3): boolean
	local root = defender.Target.Root
	local toSource = flat(source - root.Position)
	if toSource.Magnitude < 0.1 then
		return true
	end
	local facing = flat(root.CFrame.LookVector)
	if facing.Magnitude < 0.1 then
		return true
	end
	local cos = facing.Unit:Dot(toSource.Unit)
	return cos >= math.cos(math.rad(C.Block.FrontAngle / 2))
end

local function blockReduction(defender: Fighter): number
	local player = defender.Target.Player
	if player then
		local _, def = WeaponService.GetWeapon(player)
		return C.WeaponClasses[def.Class].BlockReduction
	end
	return C.Block.DamageReduction
end

-- A player fighter's bonus from gear, the skill tree and buffs (0 for NPCs).
local function bonusOf(f: Fighter?, id: string): number
	local player = f and f.Target.Player
	return if player then GearService.Bonus(player, id) else 0
end

-- Health left as a fraction of max (for execution bonuses).
local function healthFraction(f: Fighter): number
	local humanoid = f.Target.Humanoid
	return if humanoid.MaxHealth > 0 then humanoid.Health / humanoid.MaxHealth else 1
end

local function mitigate(defender: Fighter, damage: number): number
	local player = defender.Target.Player
	if player then
		-- Vitality (with gear) plus armour pieces, capped (Formulas.DamageReduction).
		local reduction = Formulas.DamageReduction(GearService.GetStats(player).Vitality, GearService.Armor(player))
		damage *= 1 - reduction
	end
	local variance = C.Damage.DamageNumberVariance
	damage *= 1 + (math.random() * 2 - 1) * variance
	return math.max(1, math.floor(damage + 0.5))
end

-- Modifier from statuses and Resonance for one blow.
local function modifiers(attacker: Fighter?, defender: Fighter, kind: HitKind): number
	local scale = 1
	local taken = takenModifier
	if taken then
		scale *= taken(defender.Target.Model)
	end
	local dealt = dealtModifier
	if dealt and attacker then
		scale *= dealt(attacker.Target.Model, kind)
	end
	return scale
end

-- Weapon blows refill the attacker's Current (spells, Arts and Beacons don't).
local function siphon(attacker: Fighter, kind: HitKind)
	local player = attacker.Target.Player
	if not player or not WEAPON_KINDS[kind] then
		return
	end
	attacker.HitCount += 1
	local _, def = WeaponService.GetWeapon(player)
	local every = C.WeaponClasses[def.Class].DoubleSiphonEveryHits
	local amount = Config.Current.Regen.SiphonPerHit
	if every and attacker.HitCount % every == 0 then
		amount *= 2
	end
	local modifier = siphonModifier
	if modifier then
		amount *= modifier(player)
	end
	VitalsService.AddCurrent(player, amount)
end

local function markCombat(f: Fighter?)
	local player = f and f.Target.Player
	if player then
		VitalsService.MarkCombat(player)
	end
end

-- Resolves one blow against one defender. `source` is where the blow comes
-- from (for guard direction). Returns what happened.
local function resolveHit(attacker: Fighter?, defender: Fighter, hit: HitSpec, source: Vector3): Outcome?
	if not isAlive(defender) then
		return nil
	end
	local t = now()
	markCombat(attacker)
	markCombat(defender)

	-- 1. Dodge invincibility.
	if t >= defender.IFrameStart and t <= defender.IFrameEnd then
		local perfect = t - defender.DodgeStart <= C.Dodge.PerfectWindow
		local player = defender.Target.Player
		if perfect and player then
			VitalsService.RestoreStamina(player, C.Dodge.PerfectStaminaRefund)
		end
		local outcome: Outcome = if perfect then "PerfectDodge" else "Dodge"
		feedback(defender, attacker, outcome, 0, false)
		return outcome
	end

	local front = inFront(defender, source)
	local attackerModel = if attacker then attacker.Target.Model else nil

	-- 2. Parry: guard raised within the parry window, facing the blow.
	if defender.Blocking and front and hit.Parryable and t <= defender.ParryUntil then
		defender.RiposteUntil = t + C.Parry.RiposteWindow
		local player = defender.Target.Player
		if player then
			VitalsService.AddCurrent(player, VitalsService.GetMaxCurrent(player) * C.Parry.CurrentRefillFraction)
			DataService.Increment(player, { "PlayStats", "Parries" }, 1)
		end
		if attacker and isAlive(attacker) then
			if not addPosture(attacker, C.Posture.ParriedPostureDamage) and not attacker.Unflinching then
				interrupt(attacker, "Staggered", C.HitStun.Parried)
			end
		end
		feedback(defender, attacker, "Parry", 0, false)
		CombatService.Parried:Fire(defender.Target.Model, attackerModel)
		CombatService.HitLanded:Fire(attackerModel, defender.Target.Model, "Parry", 0, hit.Kind)
		return "Parry"
	end

	-- 3. Something eats the blow whole (the Aegis Beacon).
	local absorb = absorber
	if absorb and absorb(defender.Target.Model) then
		feedback(defender, attacker, "Absorbed", 0, false, hit)
		CombatService.HitLanded:Fire(attackerModel, defender.Target.Model, "Absorbed", 0, hit.Kind)
		return "Absorbed"
	end

	-- 4. Block: damage reduced, costs stamina and posture.
	if defender.Blocking and front and hit.Blockable then
		local incoming = hit.Damage * modifiers(attacker, defender, hit.Kind)
		local blocked = incoming * blockReduction(defender)
		local through = incoming - blocked
		local guardBroken = false
		local player = defender.Target.Player
		if player then
			-- Vanguard tree: BlockCost / GuardPosture make holding the line cheaper.
			VitalsService.SpendStamina(player, blocked * C.Stamina.BlockCostPerDamage * (1 - bonusOf(defender, "BlockCost")))
			guardBroken = VitalsService.GetStamina(player) <= 0
		end
		if guardBroken then
			breakPosture(defender)
		else
			guardBroken = addPosture(defender, incoming * C.Posture.BlockPostureFraction * (1 - bonusOf(defender, "GuardPosture")))
		end
		local applied = TargetService.ApplyDamage(defender.Target, if through > 0 then mitigate(defender, through) else 0)
		local outcome: Outcome = if guardBroken then "GuardBreak" else "Blocked"
		feedback(defender, attacker, outcome, applied, false, hit)
		CombatService.HitLanded:Fire(attackerModel, defender.Target.Model, outcome, applied, hit.Kind)
		return outcome
	end

	-- 5. Clean hit.
	local damage = hit.Damage * modifiers(attacker, defender, hit.Kind)
	local crit = math.random() < hit.CritChance
	local postureScale = 1
	local resolver = weakPointResolver
	if resolver and attacker then
		-- (damage x, posture x). The posture scale applies on its own as well: a Guardian's
		-- ebb-tide shell takes more posture everywhere, not only at the weak point.
		local dmgScale, postScale = resolver(defender.Target.Model, source)
		if dmgScale > 1 then
			damage *= dmgScale
			crit = true -- weak-point blows show as big numbers
		end
		postureScale = postScale
	end
	if crit then
		-- Lancer tree: CritDamage raises the multiplier.
		damage *= hit.CritMultiplier + (if hit.CritMultiplier > 1 then bonusOf(attacker, "CritDamage") else 0)
	end
	-- Lancer tree: ExecuteDamage on foes close to death.
	if healthFraction(defender) <= Config.Progression.ExecuteThreshold then
		damage *= 1 + bonusOf(attacker, "ExecuteDamage")
	end
	local outcome: Outcome = if hit.Kind == "Riposte" then "Riposte" elseif hit.Reaction then "Reaction" else "Hit"
	local wasBroken = defender.Action == "Broken"
	if wasBroken then
		-- A blow on a Broken target is a finisher: big damage, balance restored.
		damage *= C.Damage.RiposteMultiplier
		outcome = "Finisher"
		defender.Posture = 0
		interrupt(defender, "Staggered", C.HitStun.Heavy)
	end
	if outcome == "Riposte" or outcome == "Finisher" then
		-- Vanguard / Lancer trees: guard counters hit harder.
		damage *= 1 + bonusOf(attacker, "RiposteDamage")
	end
	local applied = TargetService.ApplyDamage(defender.Target, mitigate(defender, damage))

	-- Posture builds on enemies with every hit (players only lose it by blocking).
	if not wasBroken and defender.Target.Kind ~= "Player" and addPosture(defender, hit.Posture * postureScale) then
		outcome = "Broken"
	end
	if outcome ~= "Broken" and not wasBroken and not defender.HyperArmor and not defender.Unflinching and isAlive(defender) then
		interrupt(defender, "Staggered", hit.HitStun)
	end
	if attacker then
		siphon(attacker, hit.Kind)
	end
	feedback(defender, attacker, outcome, applied, crit, hit)
	CombatService.HitLanded:Fire(attackerModel, defender.Target.Model, outcome, applied, hit.Kind)
	return outcome
end

-- Checks a swing against every enemy-team target. Returns how many it hit.
local function swing(attacker: Fighter, spec: SwingSpec): number
	if not isAlive(attacker) then
		return 0
	end
	local origin = attacker.Target.Root.Position
	local rewindTo = now() - TargetService.RewindFor(attacker.Target)
	local halfArc = math.rad(spec.Arc / 2)
	local attackerHeight = attacker.Target.HitHeight
	local hits = 0
	for model, defender in fighters do
		local target = defender.Target
		if defender ~= attacker and target.Team ~= attacker.Target.Team and isAlive(defender) then
			local position = TargetService.PositionAt(target, rewindTo)
			local offset = position - origin
			-- Big bodies stand tall: both fighters' HitHeight widens the vertical band.
			if math.abs(offset.Y) <= C.HitValidation.VerticalReach + attackerHeight + target.HitHeight then
				local horizontal = flat(offset)
				local distance = horizontal.Magnitude
				-- A blow lands on a body, not a point: the defender's size adds to the reach.
				local radius = C.HitValidation.TargetRadius + target.HitRadius
				if distance <= spec.Reach + radius then
					-- Very close targets are hit regardless of angle (you're inside their body).
					local angleOk = distance < radius
						or math.acos(math.clamp(spec.Aim:Dot(horizontal.Unit), -1, 1)) <= halfArc
					if angleOk and model.Parent then
						hits += 1
						resolveHit(attacker, defender, spec.Hit, origin)
					end
				end
			end
		end
	end
	return hits
end

local function schedule(attacker: Fighter, windup: number, spec: SwingSpec)
	cancelPending(attacker)
	attacker.Pending = task.delay(windup, function()
		attacker.Pending = nil
		swing(attacker, spec)
	end)
end

local function swingVisual(attacker: Fighter, kind: HitKind, spec: SwingSpec, windup: number)
	local player = attacker.Target.Player
	Net.FireList("SwingVisual", playersNear(attacker.Target.Root.Position, player), attacker.Target.Model, kind, spec.Aim, spec.Reach, spec.Arc, windup)
end

local function aimFor(f: Fighter, aim: Vector3): Vector3
	local horizontal = flat(aim)
	if horizontal.Magnitude < 0.1 then
		horizontal = flat(f.Target.Root.CFrame.LookVector)
	end
	return if horizontal.Magnitude > 0 then horizontal.Unit else Vector3.new(0, 0, -1)
end

-- PLAYER ACTIONS -------------------------------------------------------------

local function fighterFor(player: Player): Fighter?
	local character = player.Character
	local f = if character then fighters[character] else nil
	if f and isAlive(f) then
		return f
	end
	return nil
end

local function onAttack(player: Player, _comboIndex: number, aim: Vector3)
	local f = fighterFor(player)
	if not f then
		return
	end
	local t = now()
	local l = loadout(player)
	local thrust = l.Class.DodgeCancelThrust == true and f.Action == "Dodging"
	if not thrust and isBusy(f, t) then
		reject(player, "LightAttack", "Busy")
		return
	end
	if not VitalsService.SpendStamina(player, C.Stamina.LightAttackCost) then
		reject(player, "LightAttack", "Stamina")
		return
	end

	-- The server owns the combo counter; the client's index is only a hint.
	local combo = if t - f.LastLightEnd <= C.Combo.ResetTime then f.Combo % l.Class.ComboLength + 1 else 1
	local riposte = f.RiposteUntil >= t
	f.RiposteUntil = 0
	local kind: HitKind = if riposte then "Riposte" elseif thrust then "Thrust" else "Light"

	local windup = l.Class.Light.Windup / l.Speed
	local recovery = l.Class.Light.Recovery / l.Speed
	local damage = baseDamage(l) * Formulas.ComboMultiplier(combo)
	local critChance = l.Crit
	local critMultiplier = C.Damage.CritMultiplier
	if riposte then
		damage = baseDamage(l) * C.Damage.RiposteMultiplier
		if l.Class.CritOnParriedMultiplier then
			critChance = 1
			critMultiplier = l.Class.CritOnParriedMultiplier
		end
	end

	if thrust then
		f.IFrameEnd = math.min(f.IFrameEnd, t)
	end
	startAction(f, "Attacking", windup + recovery)
	f.Combo = combo
	f.LastLightEnd = t + windup + recovery

	local spec: SwingSpec = {
		Reach = l.Class.Reach + (if thrust then l.Class.ThrustReachBonus or 0 else 0) + C.HitValidation.ReachTolerance,
		Arc = l.Class.Arc,
		Aim = aimFor(f, aim),
		Hit = {
			Damage = damage,
			Posture = basePosture(l),
			Kind = kind,
			Parryable = true,
			Blockable = true,
			HitStun = C.HitStun.Light,
			CritChance = critChance,
			CritMultiplier = critMultiplier,
		},
	}
	schedule(f, windup, spec)
	swingVisual(f, kind, spec, windup)
end

local function onHeavy(player: Player, chargeSeconds: number, aim: Vector3)
	local f = fighterFor(player)
	if not f then
		return
	end
	local t = now()
	if isBusy(f, t) then
		reject(player, "HeavyAttack", "Busy")
		return
	end
	-- A charge can't be longer than the time the player has been free to hold it.
	local charge = math.clamp(chargeSeconds, 0, C.Heavy.MaxCharge)
	charge = math.min(charge, math.max(0, t - f.ActionEnd) + C.HitValidation.TimingTolerance)
	if not VitalsService.SpendStamina(player, C.Stamina.HeavyAttackCost) then
		reject(player, "HeavyAttack", "Stamina")
		return
	end
	local l = loadout(player)
	local charged = charge >= C.Heavy.ChargeTime
	local riposte = f.RiposteUntil >= t
	f.RiposteUntil = 0
	local multiplier = if riposte
		then C.Damage.RiposteMultiplier
		elseif charged then C.Damage.ChargedHeavyMultiplier
		else C.Damage.HeavyMultiplier
	local windup = l.Class.Heavy.Windup / l.Speed
	local recovery = l.Class.Heavy.Recovery / l.Speed
	local kind: HitKind = if riposte then "Riposte" elseif charged then "Charged" else "Heavy"

	startAction(f, "Heavy", windup + recovery)
	f.HyperArmor = l.Class.HeavyHyperArmor == true
	f.Combo = 0

	local spec: SwingSpec = {
		Reach = l.Class.Reach + C.HitValidation.ReachTolerance,
		Arc = l.Class.Arc,
		Aim = aimFor(f, aim),
		Hit = {
			Damage = baseDamage(l) * multiplier,
			Posture = basePosture(l) * C.Damage.HeavyMultiplier,
			Kind = kind,
			Parryable = true,
			Blockable = true,
			HitStun = C.HitStun.Heavy,
			CritChance = l.Crit,
			CritMultiplier = C.Damage.CritMultiplier,
		},
	}
	schedule(f, windup, spec)
	swingVisual(f, kind, spec, windup)
end

local function onDodge(player: Player, _direction: Vector3)
	local f = fighterFor(player)
	if not f then
		return
	end
	local t = now()
	-- A swing whose blow already landed can be cancelled into a roll.
	local cancelRecovery = (
		f.Action == "Attacking"
		or f.Action == "Heavy"
		or f.Action == "Casting"
		or (f.Action == "Art" and Config.Current.Arts.CancelIntoDodge)
	) and f.Pending == nil
	if f.Action == "Staggered" or f.Action == "Broken" or f.Action == "Dodging" or (isBusy(f, t) and not cancelRecovery) then
		reject(player, "Dodge", "Busy")
		return
	end
	-- Heavy (Abyss) pins you down: no rolling until it wears off.
	local heavyUntil = f.Target.Model:GetAttribute(Attributes.Status("Heavy"))
	if type(heavyUntil) == "number" and heavyUntil > t then
		reject(player, "Dodge", "Heavy")
		return
	end
	if not VitalsService.SpendStamina(player, C.Stamina.DodgeCost * (1 - GearService.Bonus(player, "DodgeCost"))) then
		reject(player, "Dodge", "Stamina")
		return
	end
	startAction(f, "Dodging", C.Dodge.Duration)
	f.DodgeStart = t
	f.IFrameStart = t + C.Dodge.IFrameStart
	f.IFrameEnd = f.IFrameStart + C.Dodge.IFrameDuration
	-- The roll moves faster than walking; tell the movement checks it's legal.
	AntiExploitService.AllowBurst(player, C.Dodge.Distance / C.Dodge.Duration, C.Dodge.Duration + 0.3)
end

local function onBlock(player: Player, raise: boolean, fromTouch: boolean)
	local f = fighterFor(player)
	if not f then
		return
	end
	local t = now()
	if not raise then
		f.Blocking = false
		push(f)
		return
	end
	if isBusy(f, t) or f.Blocking then
		return
	end
	f.Blocking = true
	-- Each raise opens a parry window, but not more often than Parry.Cooldown (no mashing).
	if t - f.ParryOpenedAt >= C.Parry.Cooldown then
		f.ParryOpenedAt = t
		local _, def = WeaponService.GetWeapon(player)
		local bonusFrames = (C.WeaponClasses[def.Class].ParryBonusFrames or 0)
			+ (if fromTouch then C.Parry.TouchBonusFrames else 0)
			+ GearService.Bonus(player, "ParryWindow")
		f.ParryUntil = t + C.Parry.Window + bonusFrames * FRAME
	end
	push(f)
end

-- PUBLIC API (dummies, enemies) ------------------------------------------------

-- An NPC blow, checked immediately (the caller handles its telegraph).
-- Refused while the NPC is staggered, broken, or busy with something other
-- than its own attack (NpcBeginAttack).
function CombatService.NpcSwing(model: Model, spec: SwingSpec): number
	local f = fighters[model]
	if not f or (f.Action ~= "Attacking" and isBusy(f, now())) or f.Action == "Staggered" or f.Action == "Broken" then
		return 0
	end
	return swing(f, spec)
end

-- One NPC blow against one target (projectiles). `source` is where the blow
-- comes from, for guard direction. Returns the outcome, or nil if nothing happened.
function CombatService.NpcHit(attackerModel: Model?, defenderModel: Model, hit: HitSpec, source: Vector3): Outcome?
	local defender = fighters[defenderModel]
	if not defender then
		return nil
	end
	local attacker = if attackerModel then fighters[attackerModel] else nil
	return resolveHit(attacker, defender, hit, source)
end

-- An NPC starts an attack: it shows as Attacking for `duration`. With
-- `hyperArmor`, hits don't stagger it until the attack ends. Returns false
-- if it can't act right now (staggered, broken).
function CombatService.NpcBeginAttack(model: Model, duration: number, hyperArmor: boolean): boolean
	local f = fighters[model]
	if not f or not isAlive(f) or isBusy(f, now()) then
		return false
	end
	startAction(f, "Attacking", duration)
	f.HyperArmor = hyperArmor
	return true
end

-- Ends an NPC attack early (finished, or cancelled by the caller).
function CombatService.NpcEndAttack(model: Model)
	local f = fighters[model]
	if f and f.Action == "Attacking" then
		f.Action = "Idle"
		f.ActionEnd = now()
		f.HyperArmor = false
		push(f)
	end
end

-- Shows an NPC's swing to nearby players (slash arc after `windup` seconds).
function CombatService.NpcSwingVisual(model: Model, spec: SwingSpec, windup: number)
	local f = fighters[model]
	if f then
		swingVisual(f, "Npc", spec, windup)
	end
end

-- A spell (or other non-weapon) blow from `attackerModel` on one target.
function CombatService.SpellHit(attackerModel: Model?, defenderModel: Model, hit: HitSpec, source: Vector3): Outcome?
	return CombatService.NpcHit(attackerModel, defenderModel, hit, source)
end

-- Starts a spell cast: the caster shows as Casting for castTime + recovery,
-- and `release` runs after castTime unless a hit (stagger, break) interrupts
-- the cast first. Returns false if the caster can't act right now.
function CombatService.BeginCast(model: Model, castTime: number, recovery: number, release: () -> ()): boolean
	local f = fighters[model]
	if not f or not isAlive(f) or isBusy(f, now()) then
		return false
	end
	cancelPending(f)
	startAction(f, "Casting", castTime + recovery)
	if castTime <= 0 then
		release()
	else
		f.Pending = task.delay(castTime, function()
			f.Pending = nil
			if isAlive(f) then
				release()
			end
		end)
	end
	return true
end

-- Starts a player's Weapon Art or Confluence: the fighter shows as "Art"
-- for `duration`, and `runner` (the move's timeline) runs in the fighter's
-- pending slot, so a stagger cancels the rest of it (unless hyperArmor).
-- Returns false if the fighter can't act right now.
function CombatService.BeginMove(model: Model, duration: number, hyperArmor: boolean, runner: () -> ()): boolean
	local f = fighters[model]
	if not f or not isAlive(f) or isBusy(f, now()) then
		return false
	end
	cancelPending(f)
	startAction(f, "Art", duration)
	f.HyperArmor = hyperArmor
	f.Combo = 0
	-- Deferred, so the caller can announce the move (MoveStart) before its
	-- first step runs, even a step at time 0.
	local thread: thread? = nil
	thread = task.defer(function()
		runner()
		if f.Pending == thread then
			f.Pending = nil
		end
	end)
	f.Pending = thread
	return true
end

-- True while `model` is still running the move it started (not interrupted).
function CombatService.IsInMove(model: Model): boolean
	local f = fighters[model]
	return f ~= nil and f.Action == "Art" and isAlive(f)
end

-- The weapon numbers a player's Arts scale from: scaled base damage, base
-- posture damage and crit chance.
function CombatService.GetWeaponPower(player: Player): (number, number, number)
	local l = loadout(player)
	return baseDamage(l), basePosture(l), l.Crit
end

-- Identifies the action a fighter is in right now (changes whenever a new
-- action starts), so a system can tell whether "its" action was interrupted.
function CombatService.ActionToken(model: Model): number
	local f = fighters[model]
	return if f then f.ActionEnd else 0
end

-- Ends a Casting action early (a charged spell being released): the caster
-- is free again at once. Does nothing for any other action.
function CombatService.EndCast(model: Model)
	local f = fighters[model]
	if f and f.Action == "Casting" then
		cancelPending(f)
		f.Action = "Idle"
		f.ActionEnd = now()
		push(f)
	end
end

-- Brief invincibility (Step).
function CombatService.GrantIFrames(model: Model, duration: number)
	local f = fighters[model]
	if f then
		local t = now()
		f.DodgeStart = t - 1 -- never a "perfect" dodge
		f.IFrameStart = t
		f.IFrameEnd = t + duration
	end
end

-- Stuns a target for `duration` (Frozen): it can't act, its current action is cancelled.
-- Unflinching fighters (bosses) ignore stuns.
function CombatService.Stun(model: Model, duration: number)
	local f = fighters[model]
	if f and isAlive(f) and not f.Unflinching then
		interrupt(f, "Staggered", duration)
	end
end

-- Bosses: clean hits, parries and stuns no longer stagger the fighter; a posture
-- break still interrupts it.
function CombatService.SetUnflinching(model: Model, unflinching: boolean)
	local f = fighters[model]
	if f then
		f.Unflinching = unflinching
	end
end

-- How long this fighter stays Broken after a posture break (nil: Posture.BrokenDuration).
function CombatService.SetBrokenDuration(model: Model, seconds: number?)
	local f = fighters[model]
	if f then
		f.BrokenDuration = if seconds then math.max(0, seconds) else nil
	end
end

function CombatService.SetDamageModifiers(taken: TakenModifier?, dealt: DealtModifier?)
	takenModifier = taken
	dealtModifier = dealt
end

function CombatService.SetWeakPointResolver(resolver: WeakPointResolver?)
	weakPointResolver = resolver
end

function CombatService.SetSiphonModifier(modifier: SiphonModifier?)
	siphonModifier = modifier
end

function CombatService.SetAbsorber(fn: Absorber?)
	absorber = fn
end

-- True for blows that come from the weapon itself (they siphon and Infuse).
function CombatService.IsWeaponKind(kind: string): boolean
	return WEAPON_KINDS[kind] == true
end

-- What a target is doing right now ("Idle" if it isn't a fighter).
function CombatService.GetAction(model: Model): Action
	local f = fighters[model]
	return if f then f.Action else "Idle"
end

function CombatService.IsBusy(model: Model): boolean
	local f = fighters[model]
	return f ~= nil and isBusy(f, now())
end

function CombatService.SetMaxPosture(model: Model, maxPosture: number)
	local f = fighters[model]
	if f then
		f.MaxPosture = maxPosture
		f.Posture = math.min(f.Posture, maxPosture)
		push(f)
	end
end

function CombatService.ResetPosture(model: Model)
	local f = fighters[model]
	if f then
		f.Posture = 0
		push(f)
	end
end

-- LIFECYCLE ------------------------------------------------------------------

local function addFighter(target: TargetService.Target)
	local f: Fighter = {
		Target = target,
		Action = "Idle",
		ActionEnd = 0,
		Combo = 0,
		LastLightEnd = 0,
		Pending = nil,
		Blocking = false,
		ParryUntil = 0,
		ParryOpenedAt = 0,
		DodgeStart = 0,
		IFrameStart = 0,
		IFrameEnd = 0,
		RiposteUntil = 0,
		Posture = 0,
		MaxPosture = C.Posture.Max,
		PostureHitAt = 0,
		HyperArmor = false,
		Unflinching = false,
		BrokenDuration = nil,
		HitCount = 0,
		Sent = {},
	}
	fighters[target.Model] = f
	push(f)
end

local function removeFighter(target: TargetService.Target)
	local f = fighters[target.Model]
	if f then
		cancelPending(f)
		fighters[target.Model] = nil
	end
end

local function tick(dt: number)
	local t = now()
	for _, f in fighters do
		if f.Action ~= "Idle" and t >= f.ActionEnd then
			if f.Action == "Broken" then
				f.Posture = 0
			end
			f.Action = "Idle"
			f.HyperArmor = false
		end
		if f.Action ~= "Broken" and f.Posture > 0 and t - f.PostureHitAt >= C.Posture.RecoveryDelay then
			f.Posture = math.max(0, f.Posture - C.Posture.RecoveryPerSecond * dt)
		end
		local player = f.Target.Player
		if f.Blocking and player then
			VitalsService.PauseRegen(player)
		end
		push(f)
	end
end

function CombatService.Init()
	Net.On("RequestAttack", onAttack)
	Net.On("RequestHeavyAttack", onHeavy)
	Net.On("RequestDodge", onDodge)
	Net.On("RequestBlock", onBlock)
end

function CombatService.Start()
	for _, target in TargetService.GetAll() do
		addFighter(target)
	end
	TargetService.Registered:Connect(addFighter)
	TargetService.Removed:Connect(removeFighter)
	RunService.Heartbeat:Connect(tick)
end

return CombatService
