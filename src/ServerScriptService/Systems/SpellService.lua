--!strict
--[[
	SpellService
	Casting the Current's spells (Spec Sections 6 and 8), the Attunement
	Shrine, learning Forms and the spell hotbar. Everything is decided here;
	clients only say "cast spell X at point P".

	Casting (RequestCast spellId, aimPoint)
	  Checks: alive, the spell is known (one of your Attunements and an
	  unlocked Form), off cooldown, not busy, enough Current (none during
	  Overflow). The aim point is clamped to Casting.MaxCastRange. The cast
	  then runs through CombatService.BeginCast, so getting staggered during
	  the cast time cancels it. Rejections go back as ActionRejected("Cast",
	  reason).

	Charging (Lance)
	  RequestChargeCast starts the charge: the caster shows as Casting (a hit
	  cancels it) and the server notes when it began. RequestCast releases
	  it; the server measures the charge itself and scales damage from
	  Charge.MinMultiplier to Charge.MaxMultiplier. A charge held past
	  Charge.Max (plus latency) fires on its own straight ahead.

	Numbers per cast
	  cost      Form cost x Formulas.SpellCost(Control) (0 during Overflow)
	  cast time Form cast time x Formulas.CastTime(Control) x Burnout
	  damage    Form damage x Formulas.SpellPower(Density)
	            x PressureService.SpellPower (high Pressure)
	            x charge multiplier (Lance)
	            x CurrentService.SpellMultiplier (Resonance, Overflow)
	            x ReactionDamageMultiplier when a Reaction detonates
	  area      Form radius / reach x Formulas.SpellArea(Control)

	Arcblade: each light hit takes SpellCooldownReductionPerHit seconds off
	every spell cooldown (sent to the client as SpellCooldowns).
	Relay (BeaconService): SpellCast fires on every cast, and Recast casts a
	stored spell again for free.

	Every enemy a spell hits gets its Attunement's status. A Tempest hit on
	an already Shocked enemy jumps to ShockChainTargets more enemies. A Ward
	marks anyone who strikes it with your Attunement's status.

	Attunement Shrine
	  Models tagged "AttunementShrine". At Attunement.PrimaryLevel the Shrine
	  offers a first Attunement, at SecondaryLevel a second. The choice is a
	  RequestAttune, only accepted after the Shrine made the offer and while
	  you're still beside it.

	Forms and hotbar
	  Attuned Climbers learn each Form at its UnlockLevel (checked on level
	  up and on join). New spells drop into empty hotbar slots;
	  RequestEquipSpell moves them around.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local Strings = require(Shared.Strings)
local Spells = require(Shared.Data.Spells)
local Formulas = require(Shared.Data.Formulas)
local Affixes = require(Shared.Data.Affixes)
local Log = require(Shared.Util.Log)
local Signal = require(Shared.Util.Signal)

local DataService = require(script.Parent.DataService)
local GearService = require(script.Parent.GearService)
local VitalsService = require(script.Parent.VitalsService)
local TargetService = require(script.Parent.TargetService)
local CombatService = require(script.Parent.CombatService)
local StatusService = require(script.Parent.StatusService)
local CurrentService = require(script.Parent.CurrentService)
local ProjectileService = require(script.Parent.ProjectileService)
local CharacterService = require(script.Parent.CharacterService)
local AnalyticsService = require(script.Parent.AnalyticsService)
local PressureService = require(script.Parent.PressureService)
local WeaponService = require(script.Parent.WeaponService)

local A = Attributes.Names
local C = Config.Current

local gearSpellMultiplier: (player: Player, spell: Spells.SpellDef) -> number
local log = Log.new("SpellService")

local SpellService = {}

-- (player, spellId) after every successful cast (the Relay Beacon listens).
SpellService.SpellCast = Signal.new() :: Signal.Signal<Player, string>

type Well = {
	Player: Player,
	Caster: Model,
	Spell: Spells.SpellDef,
	Position: Vector3,
	Radius: number,
	Damage: number,
	Posture: number,
	Until: number,
	NextTick: number,
}

type Ward = { Spell: Spells.SpellDef, Until: number }

local cooldowns: { [Player]: { [string]: number } } = {}
local wells: { Well } = {}
local wards: { [Player]: Ward } = {}
local offers: { [Player]: { Slot: string, Shrine: BasePart } } = {}
type Charge = { SpellId: string, Started: number, Token: number }
local charges: { [Player]: Charge } = {}

local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Exclude
wallParams.IgnoreWater = true

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function rootOf(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Walls only: characters and mobs never block spells' line checks.
local function refreshWallFilter()
	local ignore: { Instance } = {}
	for model in TargetService.GetAll() do
		table.insert(ignore, model)
	end
	wallParams.FilterDescendantsInstances = ignore
end

local function playersNear(position: Vector3): { Player }
	local list = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and rootOf(character)
		if root and (root.Position - position).Magnitude <= Config.Combat.FeedbackRadius then
			table.insert(list, player)
		end
	end
	return list
end

local function visual(caster: Model, spell: Spells.SpellDef, kind: string, data: { [string]: any })
	local root = rootOf(caster)
	if root then
		Net.FireList("SpellVisual", playersNear(root.Position), caster, spell.Id, kind, data)
	end
end

-- Living combat targets of the other team within `radius` of `position`
-- (measured to their body, so big bodies count from their surface).
local function enemiesNear(position: Vector3, radius: number, team: TargetService.Team): { Model }
	local list = {}
	for model, target in TargetService.GetAll() do
		if target.Team ~= team and TargetService.IsAlive(target) and TargetService.DistanceTo(target, position) <= radius then
			table.insert(list, model)
		end
	end
	return list
end

-- KNOWLEDGE ----------------------------------------------------------------------

-- The spell if this player knows it (one of their Attunements, an unlocked Form).
local function knownSpell(player: Player, spellId: string): Spells.SpellDef?
	local spell = Spells.Get(spellId)
	local data = DataService.GetData(player)
	if not spell or not data then
		return nil
	end
	local attunements = data.Attunements
	if spell.Attunement ~= attunements.Primary and spell.Attunement ~= attunements.Secondary then
		return nil
	end
	if not table.find(attunements.UnlockedForms, spell.Form) then
		return nil
	end
	return spell
end

-- Every spell this player knows, primary Attunement first, Forms in unlock order.
local function knownSpells(player: Player): { string }
	local data = DataService.GetData(player)
	local list = {}
	if not data then
		return list
	end
	for _, attunement in { data.Attunements.Primary, data.Attunements.Secondary } do
		if attunement ~= "" then
			for _, form in Spells.FormsByLevel() do
				if table.find(data.Attunements.UnlockedForms, form) then
					table.insert(list, Spells.Id(attunement, form))
				end
			end
		end
	end
	return list
end

-- Clears slots holding spells the player no longer knows, then puts newly
-- known spells into empty slots.
local function fillHotbar(player: Player)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	local slots = table.clone(data.Hotbar.Spells)
	local changed = false
	for index, id in slots do
		if id ~= "" and not knownSpell(player, id) then
			slots[index] = ""
			changed = true
		end
	end
	for _, id in knownSpells(player) do
		if not table.find(slots, id) then
			local empty = table.find(slots, "")
			if not empty then
				break
			end
			slots[empty] = id
			changed = true
		end
	end
	if changed then
		DataService.Set(player, { "Hotbar", "Spells" }, slots)
	end
end

-- Learns every Form the player's level allows (once attuned).
local function learnForms(player: Player)
	local data = DataService.GetData(player)
	if not data or data.Attunements.Primary == "" then
		return
	end
	local forms = table.clone(data.Attunements.UnlockedForms)
	local learned = {}
	for _, form in Spells.FormsByLevel() do
		local shape = Spells.Form(form)
		if shape and data.Level >= shape.UnlockLevel and not table.find(forms, form) then
			table.insert(forms, form)
			table.insert(learned, form)
		end
	end
	if #learned > 0 then
		DataService.Set(player, { "Attunements", "UnlockedForms" }, forms)
		for _, form in learned do
			local name = Strings.Forms[form]
			Net.Fire("Notify", player, "Toasts.FormLearned", { form = if name then name.Name else form }, "Success")
		end
	end
	fillHotbar(player)
end

-- STRIKES ------------------------------------------------------------------------

-- One spell blow on one enemy: Reaction check, damage, status, Shock chain.
local function strike(player: Player, caster: Model, spell: Spells.SpellDef, target: Model, damage: number, posture: number, source: Vector3, chained: boolean): string?
	local element = spell.Element
	local detonates = element.Detonates
	local reaction = detonates ~= nil and StatusService.Consume(target, detonates)
	local shocked = spell.Attunement == "Tempest" and StatusService.Has(target, "Shocked")
	local scale = CurrentService.SpellMultiplier(player)
		* (if reaction then C.Status.ReactionDamageMultiplier * (1 + GearService.Bonus(player, "ReactionDamage")) else 1)
	local outcome: string? = CombatService.SpellHit(caster, target, {
		Damage = damage * scale,
		Posture = posture,
		Kind = "Spell",
		Parryable = false,
		Blockable = true,
		HitStun = Config.Combat.HitStun.Light,
		CritChance = 0,
		CritMultiplier = 1,
		Reaction = if reaction then element.Reaction or "Reaction" else nil,
		Element = spell.Attunement,
	}, source)
	if outcome == nil or outcome == "Dodge" or outcome == "PerfectDodge" or outcome == "Parry" then
		return outcome
	end
	StatusService.Apply(target, element.Status)
	if shocked and not chained then
		local root = rootOf(target)
		if root then
			local others = enemiesNear(root.Position, C.Status.ShockChainRadius, "Players")
			table.sort(others, function(a: Model, b: Model): boolean
				local ra, rb = rootOf(a), rootOf(b)
				local ta, tb = TargetService.Get(a), TargetService.Get(b)
				return (if ra and ta then TargetService.DistanceTo(ta, root.Position, ra.Position) else math.huge)
					< (if rb and tb then TargetService.DistanceTo(tb, root.Position, rb.Position) else math.huge)
			end)
			local jumps = 0
			for _, other in others do
				if other ~= target and jumps < C.Status.ShockChainTargets then
					jumps += 1
					local otherRoot = rootOf(other)
					if otherRoot then
						visual(caster, spell, "Chain", { From = root.Position, To = otherRoot.Position })
					end
					strike(player, caster, spell, other, damage * C.Status.ShockChainFraction, posture * C.Status.ShockChainFraction, root.Position, true)
				end
			end
		end
	end
	return outcome
end

-- FORMS --------------------------------------------------------------------------

type Cast = {
	Player: Player,
	Caster: Model,
	Root: BasePart,
	Spell: Spells.SpellDef,
	Aim: Vector3, -- aimed world point (already clamped to range)
	Damage: number,
	Posture: number,
	Area: number,
	Density: number,
}

local function castOrigin(cast: Cast): Vector3
	local hand = cast.Caster:FindFirstChild("RightHand")
	if hand and hand:IsA("BasePart") then
		return hand.Position
	end
	return cast.Root.Position + Vector3.new(0, 1.5, 0)
end

local function aimFlat(cast: Cast): Vector3
	local direction = flat(cast.Aim - cast.Root.Position)
	if direction.Magnitude < 0.1 then
		direction = flat(cast.Root.CFrame.LookVector)
	end
	return if direction.Magnitude > 0.01 then direction.Unit else Vector3.new(0, 0, -1)
end

local FORMS: { [string]: (Cast) -> () } = {}

FORMS.Bolt = function(cast: Cast)
	local shape = cast.Spell.Shape
	local origin = castOrigin(cast)
	local direction = cast.Aim - origin
	ProjectileService.Fire({
		Owner = cast.Caster,
		Team = "Players",
		Origin = origin,
		Direction = if direction.Magnitude > 0.1 then direction else aimFlat(cast),
		Speed = shape.Speed or 80,
		Radius = shape.Radius or 1,
		Range = shape.Range or 90,
		Color = cast.Spell.Element.Color,
		OnHit = function(target: Model, _position: Vector3): boolean
			local outcome = strike(cast.Player, cast.Caster, cast.Spell, target, cast.Damage, cast.Posture, origin, false)
			return outcome == "Dodge" or outcome == "PerfectDodge"
		end,
	})
end

FORMS.Wave = function(cast: Cast)
	local shape = cast.Spell.Shape
	local reach = (shape.Reach or 12) * cast.Area
	local halfArc = math.rad((shape.Arc or 90) / 2)
	local aim = aimFlat(cast)
	local origin = cast.Root.Position
	for _, model in enemiesNear(origin, reach + Config.Combat.HitValidation.TargetRadius, "Players") do
		local root = rootOf(model)
		local target = TargetService.Get(model)
		if root and target then
			-- Aim at the nearest point of the body; its width widens the arc it fills.
			local point = TargetService.AxisPoint(target, origin, root.Position)
			local offset = flat(point - origin)
			local distance = offset.Magnitude
			local inside = distance < Config.Combat.HitValidation.TargetRadius + target.HitRadius
				or math.acos(math.clamp(aim:Dot(offset.Unit), -1, 1)) <= halfArc + math.asin(math.min(1, target.HitRadius / distance))
			if inside and not Workspace:Raycast(origin, point - origin, wallParams) then
				strike(cast.Player, cast.Caster, cast.Spell, model, cast.Damage, cast.Posture, origin, false)
			end
		end
	end
	visual(cast.Caster, cast.Spell, "Wave", { Aim = aim, Reach = reach, Arc = shape.Arc or 90 })
end

FORMS.Lance = function(cast: Cast)
	local shape = cast.Spell.Shape
	local origin = castOrigin(cast)
	local direction = cast.Aim - origin
	direction = if direction.Magnitude > 0.1 then direction.Unit else aimFlat(cast)
	local length = shape.Length or 40
	local wall = Workspace:Raycast(origin, direction * length, wallParams)
	if wall then
		length = wall.Distance
	end
	local width = (shape.Width or 2) * cast.Area + Config.Combat.HitValidation.TargetRadius
	for _, model in enemiesNear(origin, length + width, "Players") do
		local root = rootOf(model)
		local target = TargetService.Get(model)
		if root and target then
			-- Distance from the target's body to the beam (a line segment).
			local point = TargetService.AxisPointToSegment(target, origin, origin + direction * length, root.Position)
			local along = math.clamp((point - origin):Dot(direction), 0, length)
			local closest = origin + direction * along
			if (point - closest).Magnitude - target.HitRadius <= width then
				strike(cast.Player, cast.Caster, cast.Spell, model, cast.Damage, cast.Posture, origin, false)
			end
		end
	end
	visual(cast.Caster, cast.Spell, "Lance", { From = origin, To = origin + direction * length })
end

FORMS.Ward = function(cast: Cast)
	local shape = cast.Spell.Shape
	local duration = shape.Duration or 5
	VitalsService.SetShield(cast.Player, (shape.Shield or 40) * Formulas.ShieldPower(cast.Density), duration)
	wards[cast.Player] = { Spell = cast.Spell, Until = now() + duration }
	if cast.Spell.Element.Heals then
		StatusService.Apply(cast.Caster, "Renewing")
	end
	visual(cast.Caster, cast.Spell, "Ward", { Duration = duration })
end

FORMS.Well = function(cast: Cast)
	local shape = cast.Spell.Shape
	local range = shape.Range or 60
	local offset = cast.Aim - cast.Root.Position
	local point = if offset.Magnitude > range then cast.Root.Position + offset.Unit * range else cast.Aim
	local ground = Workspace:Raycast(point + Vector3.new(0, 8, 0), Vector3.new(0, -60, 0), wallParams)
	local position = if ground then ground.Position else point
	local duration = shape.Duration or 5
	local radius = (shape.Radius or 8) * cast.Area
	table.insert(wells, {
		Player = cast.Player,
		Caster = cast.Caster,
		Spell = cast.Spell,
		Position = position,
		Radius = radius,
		Damage = cast.Damage,
		Posture = cast.Posture,
		Until = now() + duration,
		NextTick = now(),
	})
	visual(cast.Caster, cast.Spell, "Well", { Position = position, Radius = radius, Duration = duration })
end

FORMS.Step = function(cast: Cast)
	local shape = cast.Spell.Shape
	local direction = aimFlat(cast)
	local from = cast.Root.Position
	local distance = shape.Distance or 15
	local wall = Workspace:Raycast(from, direction * distance, wallParams)
	if wall then
		distance = math.max(0, wall.Distance - C.Casting.StepWallMargin)
	end
	local to = from + direction * distance
	local ground = Workspace:Raycast(to + Vector3.new(0, 4, 0), Vector3.new(0, -20, 0), wallParams)
	if ground then
		local humanoid = cast.Caster:FindFirstChildOfClass("Humanoid")
		local height = (if humanoid then humanoid.HipHeight else 2) + cast.Root.Size.Y / 2
		to = ground.Position + Vector3.new(0, height, 0)
	end
	CombatService.GrantIFrames(cast.Caster, shape.IFrames or 0.3)
	CharacterService.Teleport(cast.Player, CFrame.lookAt(to, to + direction))
	local radius = (shape.Radius or 6) * cast.Area
	for _, model in enemiesNear(to, radius, "Players") do
		strike(cast.Player, cast.Caster, cast.Spell, model, cast.Damage, cast.Posture, to, false)
	end
	visual(cast.Caster, cast.Spell, "Step", { From = from, To = to, Radius = radius })
end

-- CASTING ------------------------------------------------------------------------

local function reject(player: Player, reason: string)
	Net.Fire("ActionRejected", player, "Cast", reason)
end

local function cooldownsOf(player: Player): { [string]: number }
	local list = cooldowns[player]
	if not list then
		list = {}
		cooldowns[player] = list
	end
	return list
end

-- Sends the player's real cooldowns (server time each spell is ready).
local function syncCooldowns(player: Player)
	Net.Fire("SpellCooldowns", player, table.clone(cooldownsOf(player)))
end

-- Gear on spell damage: "+x% <Attunement> damage" lines, and Deepglass
-- (more damage while the Vessel is nearly full; checked before the cost is paid).
function gearSpellMultiplier(player: Player, spell: Spells.SpellDef): number
	-- Element lines and the Tidecaller tree's SpellDamage add together.
	local multiplier = 1 + GearService.Bonus(player, `{spell.Attunement}Damage`) + GearService.Bonus(player, "SpellDamage")
	if GearService.HasUnique(player, "Deepglass") then
		local unique = Affixes.GetUnique("Deepglass")
		local maxCurrent = VitalsService.GetMaxCurrent(player)
		if unique and maxCurrent > 0 and VitalsService.GetCurrent(player) / maxCurrent >= unique.Params.Threshold then
			multiplier *= 1 + unique.Params.DamageBonus
		end
	end
	return multiplier
end

-- Builds the numbers for one cast of `spell` (charge = Lance multiplier).
local function buildCast(player: Player, character: Model, root: BasePart, spell: Spells.SpellDef, aim: Vector3, charge: number): Cast?
	local data = DataService.GetData(player)
	if not data then
		return nil
	end
	-- Never further than MaxCastRange.
	local offset = aim - root.Position
	if offset.Magnitude > C.Casting.MaxCastRange then
		aim = root.Position + offset.Unit * C.Casting.MaxCastRange
	end
	local stats = GearService.GetStats(player)
	local shape = spell.Shape
	local power = Formulas.SpellPower(stats.Density) * PressureService.SpellPower(player) * charge * gearSpellMultiplier(player, spell)
	return {
		Player = player,
		Caster = character,
		Root = root,
		Spell = spell,
		Aim = aim,
		Damage = shape.Damage * power,
		Posture = shape.Posture * Formulas.SpellPosture(stats.Density) * charge,
		Area = Formulas.SpellArea(stats.Control) * (1 + GearService.Bonus(player, "SpellArea")),
		Density = stats.Density,
	}
end

local function runForm(cast: Cast)
	local ok, err = pcall(function(): string?
		FORMS[cast.Spell.Form](cast)
		return nil
	end)
	if not ok then
		log:Error(`{cast.Spell.Id} failed: {err}`)
	end
end

-- How strong a charged spell is after `held` seconds of charging.
local function chargeMultiplier(spell: Spells.SpellDef, held: number): number
	local charge = spell.Shape.Charge
	if not charge then
		return 1
	end
	local alpha = math.clamp(held / charge.Max, 0, 1)
	return charge.MinMultiplier + (charge.MaxMultiplier - charge.MinMultiplier) * alpha
end

local function castCost(player: Player, spell: Spells.SpellDef): number
	if Config.Current.Overflow.FreeSpells and CurrentService.IsOverflowing(player) then
		return 0
	end
	local data = DataService.GetData(player)
	return spell.Shape.Cost * Formulas.SpellCost(if data then GearService.GetStats(player).Control else 0)
end

-- Releases a cast: spends Current, runs the cast time through CombatService
-- (a hit cancels it) and starts the cooldown. Returns false if refused.
local function release(player: Player, spell: Spells.SpellDef, aim: Vector3, charge: number): boolean
	local character = player.Character
	local root = character and rootOf(character)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local data = DataService.GetData(player)
	if not character or not root or not humanoid or humanoid.Health <= 0 or not data then
		return false
	end
	local cast = buildCast(player, character, root, spell, aim, charge)
	if not cast then
		return false
	end
	local shape = spell.Shape
	local cost = castCost(player, spell)
	if not VitalsService.SpendCurrent(player, cost) then
		reject(player, "Current")
		return false
	end
	local castTime = shape.CastTime
		* Formulas.CastTime(GearService.GetStats(player).Control)
		* CurrentService.CastTimeMultiplier(player)
		/ (1 + GearService.Bonus(player, "CastSpeed"))
	local started = CombatService.BeginCast(character, castTime, shape.Recovery, function()
		if character.Parent and humanoid.Health > 0 then
			runForm(cast)
		end
	end)
	if not started then
		VitalsService.AddCurrent(player, cost)
		reject(player, "Busy")
		return false
	end
	cooldownsOf(player)[spell.Id] = now() + shape.Cooldown
	CurrentService.OnCast(player, cost)
	VitalsService.MarkCombat(player)
	SpellService.SpellCast:Fire(player, spell.Id)
	return true
end

local function offCooldown(player: Player, spellId: string): boolean
	return (cooldownsOf(player)[spellId] or 0) <= now() + Config.Combat.HitValidation.TimingTolerance
end

local function onCast(player: Player, spellId: string, aim: Vector3)
	local character = player.Character
	if not character then
		return
	end
	local spell = knownSpell(player, spellId)
	if not spell then
		reject(player, "Unknown")
		return
	end
	if not offCooldown(player, spellId) then
		reject(player, "Cooldown")
		return
	end

	-- Releasing a charge: the server measures how long it was held.
	local charge = 1
	if spell.Shape.Charge then
		local pending = charges[player]
		charges[player] = nil
		if pending and pending.SpellId == spellId and CombatService.ActionToken(character) == pending.Token then
			charge = chargeMultiplier(spell, now() - pending.Started + C.Casting.ChargeTolerance)
			CombatService.EndCast(character)
		else
			-- Released without a valid charge (tapped, or the charge was interrupted).
			charge = chargeMultiplier(spell, 0)
		end
	end

	if CombatService.IsBusy(character) then
		reject(player, "Busy")
		return
	end
	release(player, spell, aim, charge)
end

-- Starts charging a spell that charges (Lance). Refused if it couldn't be cast.
local function onChargeCast(player: Player, spellId: string)
	local character = player.Character
	local root = character and rootOf(character)
	local spell = knownSpell(player, spellId)
	if not character or not root or not spell or not spell.Shape.Charge then
		return
	end
	local chargeDef = spell.Shape.Charge
	if not offCooldown(player, spellId) then
		reject(player, "Cooldown")
		return
	end
	if VitalsService.GetCurrent(player) < castCost(player, spell) then
		reject(player, "Current")
		return
	end
	-- Charging is a Casting action, so a hit cancels it. If the player holds
	-- past the maximum (and latency), it fires straight ahead on its own.
	local hold = chargeDef.Max + C.Casting.ChargeTolerance * 4
	local started = CombatService.BeginCast(character, hold, 0, function()
		local pending = charges[player]
		if not pending or pending.SpellId ~= spellId then
			return
		end
		charges[player] = nil
		CombatService.EndCast(character)
		local look = root.CFrame.LookVector
		release(player, spell, root.Position + look * (spell.Shape.Length or 40), chargeMultiplier(spell, chargeDef.Max))
	end)
	if not started then
		reject(player, "Busy")
		return
	end
	charges[player] = { SpellId = spellId, Started = now(), Token = CombatService.ActionToken(character) }
end

-- Casts a known spell again for free, with no cast time or cooldown (Relay).
function SpellService.Recast(player: Player, spellId: string, aim: Vector3): boolean
	local character = player.Character
	local root = character and rootOf(character)
	local spell = knownSpell(player, spellId)
	if not character or not root or not spell then
		return false
	end
	local cast = buildCast(player, character, root, spell, aim, chargeMultiplier(spell, if spell.Shape.Charge then spell.Shape.Charge.Max else 0))
	if not cast then
		return false
	end
	runForm(cast)
	return true
end

-- Arcblade: light hits shave time off every spell cooldown.
local function onWeaponHit(attacker: Model?, _defender: Model, outcome: string, _applied: number, kind: string)
	local player = if attacker then Players:GetPlayerFromCharacter(attacker) else nil
	if not player or kind ~= "Light" or outcome == "Dodge" or outcome == "PerfectDodge" or outcome == "Parry" or outcome == "Absorbed" then
		return
	end
	local _, weapon = WeaponService.GetWeapon(player)
	local reduction = (Config.Combat.WeaponClasses :: any)[weapon.Class].SpellCooldownReductionPerHit
	if type(reduction) ~= "number" then
		return
	end
	local list = cooldownsOf(player)
	local t = now()
	local changed = false
	for id, readyAt in list do
		if readyAt > t then
			list[id] = readyAt - reduction
			changed = true
		end
	end
	if changed then
		syncCooldowns(player)
	end
end

-- SHRINE -------------------------------------------------------------------------

local function offer(player: Player, shrine: BasePart)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	local attunements = data.Attunements
	local slot: string? = nil
	local needLevel = 0
	if attunements.Primary == "" then
		slot = "Primary"
		needLevel = C.Attunement.PrimaryLevel
	elseif attunements.Secondary == "" then
		slot = "Secondary"
		needLevel = C.Attunement.SecondaryLevel
	end
	if not slot then
		Net.Fire("Notify", player, "Toasts.ShrineDone", {}, "Info")
		return
	end
	if data.Level < needLevel then
		Net.Fire("Notify", player, "Toasts.ShrineNeedsLevel", { level = needLevel }, "Info")
		return
	end
	offers[player] = { Slot = slot, Shrine = shrine }
	Net.Fire("AttunementOffer", player, slot, attunements.Primary)
end

local function onAttune(player: Player, attunement: string)
	local pending = offers[player]
	local data = DataService.GetData(player)
	local character = player.Character
	local root = character and rootOf(character)
	if not pending or not data or not root then
		return
	end
	if (root.Position - pending.Shrine.Position).Magnitude > C.Casting.ShrineDistance then
		return
	end
	if not Spells.Attunement(attunement) or attunement == data.Attunements.Primary then
		return
	end
	offers[player] = nil
	DataService.Set(player, { "Attunements", pending.Slot }, attunement)
	if pending.Slot == "Primary" then
		player:SetAttribute(A.Attunement, attunement)
	end
	local name = Strings.Attunements[attunement]
	Net.Fire("Notify", player, "Toasts.Attuned", { name = if name then name.Name else attunement }, "Success")
	AnalyticsService.Custom(player, `Attuned{pending.Slot}`)
	learnForms(player)
	fillHotbar(player)
end

local function addShrine(instance: Instance)
	local host: BasePart? = nil
	if instance:IsA("BasePart") then
		host = instance
	elseif instance:IsA("Model") then
		local altar = instance:FindFirstChild("Altar")
		host = if altar and altar:IsA("BasePart") then altar else instance.PrimaryPart
	end
	if not host then
		log:Warn(`Attunement Shrine {instance:GetFullName()} needs an "Altar" part or a PrimaryPart`)
		return
	end
	local shrine = host
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "AttunePrompt"
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.ActionText = Strings.Prompts.Attune
	prompt.ObjectText = Strings.Prompts.Shrine
	prompt.HoldDuration = Config.World.Waystones.RestHoldDuration
	prompt.MaxActivationDistance = Config.World.Waystones.InteractDistance
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Parent = shrine
	prompt.Triggered:Connect(function(player: Player)
		offer(player, shrine)
	end)
end

-- HOTBAR -------------------------------------------------------------------------

local function onEquip(player: Player, slot: number, spellId: string)
	local data = DataService.GetData(player)
	if not data or not knownSpell(player, spellId) then
		return
	end
	local slots = table.clone(data.Hotbar.Spells)
	local existing = table.find(slots, spellId)
	if existing then
		-- Moving a spell swaps it with whatever was in the target slot.
		slots[existing] = slots[slot]
	end
	slots[slot] = spellId
	DataService.Set(player, { "Hotbar", "Spells" }, slots)
end

-- LIFECYCLE ----------------------------------------------------------------------

local function tickWells()
	local t = now()
	for index = #wells, 1, -1 do
		local well = wells[index]
		if t >= well.Until or not well.Player.Parent then
			table.remove(wells, index)
		elseif t >= well.NextTick then
			well.NextTick = t + (well.Spell.Shape.TickInterval or 1)
			for _, model in enemiesNear(well.Position, well.Radius, "Players") do
				strike(well.Player, well.Caster, well.Spell, model, well.Damage, well.Posture, well.Position, false)
			end
			if well.Spell.Element.Heals then
				for _, other in Players:GetPlayers() do
					local character = other.Character
					local root = character and rootOf(character)
					if character and root and (root.Position - well.Position).Magnitude <= well.Radius then
						StatusService.Apply(character, "Renewing")
					end
				end
			end
		end
	end
end

-- A Ward marks whoever strikes it with the caster's Attunement status.
local function onHitLanded(attacker: Model?, defender: Model, _outcome: string, _applied: number, _kind: string)
	local player = Players:GetPlayerFromCharacter(defender)
	local ward = player and wards[player]
	if not attacker or not player or not ward then
		return
	end
	if now() > ward.Until or not VitalsService.HasShield(player) then
		wards[player] = nil
		return
	end
	StatusService.Apply(attacker, ward.Spell.Element.Status)
end

function SpellService.Init()
	Net.On("RequestCast", onCast)
	Net.On("RequestChargeCast", onChargeCast)
	Net.On("RequestAttune", onAttune)
	Net.On("RequestEquipSpell", onEquip)
end

function SpellService.Start()
	refreshWallFilter()
	TargetService.Registered:Connect(refreshWallFilter)
	TargetService.Removed:Connect(function()
		task.defer(refreshWallFilter)
	end)
	CombatService.HitLanded:Connect(onHitLanded)
	CombatService.HitLanded:Connect(onWeaponHit)

	DataService.ProfileLoaded:Connect(function(player: Player)
		local data = DataService.GetData(player)
		if data then
			player:SetAttribute(A.Attunement, data.Attunements.Primary)
		end
		learnForms(player)
	end)
	DataService.Changed:Connect(function(player: Player, path: { string })
		if path[1] == "Level" then
			learnForms(player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		cooldowns[player] = nil
		wards[player] = nil
		offers[player] = nil
		charges[player] = nil
	end)

	for _, shrine in CollectionService:GetTagged(Attributes.Tags.AttunementShrine) do
		addShrine(shrine)
	end
	CollectionService:GetInstanceAddedSignal(Attributes.Tags.AttunementShrine):Connect(addShrine)
	RunService.Heartbeat:Connect(tickWells)
end

return SpellService
