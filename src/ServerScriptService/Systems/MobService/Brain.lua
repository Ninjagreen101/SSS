--!strict
--[[
	Brain
	One mob's decisions, run on each think (MobService schedules thinks:
	10 Hz near players, 1 Hz further out, asleep when nobody is around).

	States (Enums.MobState, mirrored to the MobState attribute):
	  Idle / Patrol  stands, or wanders near home now and then; looks for players
	  Alert          spotted someone: turns to face them for NoticeTime
	  Chase          moves on its target (highest threat); circles when it has
	                 to wait for an attack slot; ranged mobs keep their distance
	  Attack         running a move: telegraph glow, blows, then...
	  Recover        stands open for the move's Recovery time
	  Staggered / Broken   hit stun or posture break (CombatService decides)
	  Return         pulled past the leash, or lost its target: walks home and heals
	  Dead

	Fairness rules (Config.Mobs.AI):
	  - at most MaxAttackersPerPlayer mobs attack one player at a time
	    (attack slots); the rest circle and wait
	  - no move is used more than MaxSameAttackRepeats times in a row
	  - every move has a telegraph of at least MinTelegraph seconds, and the
	    mob stops turning toward you TrackCutoff before the blow lands, so a
	    late dodge works
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Enums = require(Shared.Enums)
local Mobs = require(Shared.Data.Mobs)

local CombatService = require(script.Parent.Parent.CombatService)
local Types = require(script.Parent.Types)
local Navigator = require(script.Parent.Navigator)
local ProjectileService = require(script.Parent.Parent.ProjectileService)
local StatusService = require(script.Parent.Parent.StatusService)

local A = Attributes.Names
local AI = Config.Mobs.AI
local THREAT = Config.Mobs.Threat
local SEE = Config.Mobs.Perception
local MOVE = Config.Mobs.Movement
local PACING = Config.Mobs.Pacing

local Brain = {}

local BOLT_COLOR = Color3.fromHex("#4FE0D2")

-- Attack slots: which mobs are attacking each player right now.
local slots: { [Player]: { [Types.Mob]: boolean } } = {}

local random = Random.new()

local sightParams = RaycastParams.new()
sightParams.FilterType = Enum.RaycastFilterType.Exclude
sightParams.IgnoreWater = true

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Characters and mobs never block sight.
-- Every live mob (Buff moves look for allies). Set by MobService.
local mobProvider: (() -> { Types.Mob })? = nil
function Brain.SetMobProvider(provider: () -> { Types.Mob })
	mobProvider = provider
end

local ENGAGED = { Alert = true, Chase = true, Attack = true, Recover = true }

-- Allies a Buff move would empower: engaged, close enough, not already empowered.
local function buffTargets(mob: Types.Mob, move: Mobs.MoveDef): { Types.Mob }
	local out = {}
	local provider = mobProvider
	if not provider then
		return out
	end
	local radius = move.Radius or 30
	local t = now()
	for _, other in provider() do
		if other ~= mob and not other.Dead and ENGAGED[other.State] and other.EmpowerUntil <= t
			and (other.Root.Position - mob.Root.Position).Magnitude <= radius then
			table.insert(out, other)
		end
	end
	return out
end

function Brain.SetIgnored(list: { Instance })
	sightParams.FilterDescendantsInstances = list
end

-- STATE ------------------------------------------------------------------------

local function setState(mob: Types.Mob, state: Enums.MobState)
	if mob.State ~= state then
		mob.State = state
		mob.Model:SetAttribute(A.MobState, state)
	end
end

-- Turn to face a point (or nil: face where it walks).
local function face(mob: Types.Mob, point: Vector3?)
	local align = mob.Align
	if point then
		local look = flat(point - mob.Root.Position)
		if look.Magnitude > 0.1 then
			mob.Humanoid.AutoRotate = false
			align.CFrame = CFrame.lookAt(Vector3.zero, look)
			align.Enabled = true
		end
	else
		mob.Humanoid.AutoRotate = true
		align.Enabled = false
	end
end

-- TARGETS ----------------------------------------------------------------------

local function rootOf(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- A mob with AllowedTargets (a Guardian's adds) only fights those players.
local function allowed(mob: Types.Mob, player: Player): boolean
	local set = mob.AllowedTargets
	return set == nil or set[player] == true
end

local function canSee(mob: Types.Mob, target: BasePart): boolean
	local eye = mob.Root.Position + Vector3.new(0, SEE.SightHeight * mob.Def.Body.Scale - mob.Root.Size.Y / 2, 0)
	local offset = target.Position - eye
	return Workspace:Raycast(eye, offset, sightParams) == nil
end

-- The nearest visible player within aggro range.
local function perceive(mob: Types.Mob): Player?
	local best: Player? = nil
	local bestDistance = mob.Def.AggroRadius
	local position = mob.Root.Position
	for _, player in Players:GetPlayers() do
		local root = if allowed(mob, player) then rootOf(player) else nil
		if root then
			local distance = (root.Position - position).Magnitude
			if distance <= bestDistance and canSee(mob, root) then
				best = player
				bestDistance = distance
			end
		end
	end
	return best
end

-- Highest-threat player who is alive and inside the leash (a live Taunt wins).
local function pickTarget(mob: Types.Mob): (Player?, BasePart?)
	local taunter = mob.TauntedBy
	if taunter then
		local root = if taunter.Parent and now() < mob.TauntUntil then rootOf(taunter) else nil
		if root and flat(root.Position - mob.Home).Magnitude <= AI.LeashRadius then
			return taunter, root
		end
		mob.TauntedBy = nil
	end
	local best: Player? = nil
	local bestRoot: BasePart? = nil
	local bestThreat = -math.huge
	for player, threat in mob.Threat do
		local root = if player.Parent and allowed(mob, player) then rootOf(player) else nil
		if not root or flat(root.Position - mob.Home).Magnitude > AI.LeashRadius then
			mob.Threat[player] = nil
		elseif threat > bestThreat then
			best = player
			bestRoot = root
			bestThreat = threat
		end
	end
	return best, bestRoot
end

function Brain.AddThreat(mob: Types.Mob, player: Player, amount: number)
	mob.Threat[player] = (mob.Threat[player] or 0) + amount
end

-- ATTACK SLOTS -----------------------------------------------------------------

local function slotCount(player: Player): number
	local held = slots[player]
	local count = 0
	if held then
		for _ in held do
			count += 1
		end
	end
	return count
end

local function canTakeSlot(mob: Types.Mob, player: Player): boolean
	local held = slots[player]
	return (held ~= nil and held[mob] == true) or slotCount(player) < AI.MaxAttackersPerPlayer
end

local function takeSlot(mob: Types.Mob, player: Player)
	local held = slots[player]
	if not held then
		held = {}
		slots[player] = held
	end
	held[mob] = true
	mob.Token = player
end

function Brain.ReleaseSlot(mob: Types.Mob)
	local player = mob.Token
	mob.Token = nil
	if player then
		local held = slots[player]
		if held then
			held[mob] = nil
			if next(held) == nil then
				slots[player] = nil
			end
		end
	end
end

function Brain.ForgetPlayer(player: Player)
	slots[player] = nil
end

-- MOVES ------------------------------------------------------------------------

-- `canShoot`: a clear line to the target (projectile moves need one).
local function chooseMove(mob: Types.Mob, distance: number, canShoot: boolean): (string?, Mobs.MoveDef?)
	local t = now()
	local options: { { Id: string, Move: Mobs.MoveDef } } = {}
	local total = 0
	for id, move in mob.Def.Moves do
		local repeatsBlocked = mob.LastMove == id and mob.MoveRepeats >= AI.MaxSameAttackRepeats
		local blocked = (move.Kind == "Projectile" and not canShoot) or (move.Kind == "Buff" and #buffTargets(mob, move) == 0)
		if distance >= move.MinRange and distance <= move.MaxRange and (mob.Cooldowns[id] or 0) <= t and not repeatsBlocked and not blocked then
			table.insert(options, { Id = id, Move = move })
			total += move.Weight
		end
	end
	if total <= 0 then
		return nil, nil
	end
	local roll = random:NextNumber(0, total)
	for _, option in options do
		roll -= option.Move.Weight
		if roll <= 0 then
			return option.Id, option.Move
		end
	end
	local last = options[#options]
	return last.Id, last.Move
end

local function interrupted(mob: Types.Mob): boolean
	if mob.Dead or not mob.Model.Parent then
		return true
	end
	local action = CombatService.GetAction(mob.Model)
	return action == "Staggered" or action == "Broken"
end

-- Tells clients a blow is coming: which animation, how long until contact,
-- when it started, and whether to show the telegraph glow.
local function announceBlow(mob: Types.Mob, slot: string, windup: number, telegraph: boolean)
	mob.Model:SetAttribute(A.MobBlow, string.format("%s;%.3f;%.3f;%d", slot, windup, now(), if telegraph then 1 else 0))
end

local function hitSpec(mob: Types.Mob, move: Mobs.MoveDef): CombatService.HitSpec
	local empowered = if now() < mob.EmpowerUntil then mob.EmpowerBonus else 0
	return {
		Damage = move.Damage * mob.DamageMultiplier * (1 + empowered),
		Posture = move.Posture,
		Kind = "Npc",
		Parryable = move.Parryable,
		Blockable = move.Blockable,
		HitStun = move.HitStun,
		CritChance = 0,
		CritMultiplier = 1,
	}
end

-- Where projectiles leave from: the glowing hand if it has one, else the chest.
local function castOrigin(mob: Types.Mob): Vector3
	local hand = mob.Model:FindFirstChild("RightHand")
	if hand and hand:IsA("BasePart") then
		return hand.Position
	end
	return mob.Root.Position + Vector3.new(0, 1, 0)
end

local function release(mob: Types.Mob, move: Mobs.MoveDef, target: Player?)
	local aim = flat(mob.Root.CFrame.LookVector)
	aim = if aim.Magnitude > 0.01 then aim.Unit else Vector3.new(0, 0, -1)
	if move.Kind == "Buff" then
		local untilAt = now() + (move.Duration or 8)
		for _, ally in buffTargets(mob, move) do
			ally.EmpowerUntil = untilAt
			ally.EmpowerBonus = move.Bonus or 0.25
			ally.Model:SetAttribute("EmpoweredUntil", untilAt) -- clients show the amber glow
		end
	elseif move.Kind == "Melee" then
		local spec: CombatService.SwingSpec = {
			Reach = (move.Reach or 6) * mob.Def.Body.Scale,
			Arc = move.Arc or 90,
			Aim = aim,
			Hit = hitSpec(mob, move),
		}
		CombatService.NpcSwingVisual(mob.Model, spec, 0)
		CombatService.NpcSwing(mob.Model, spec)
	else
		local origin = castOrigin(mob)
		local root = if target then rootOf(target) else nil
		-- Aim at the target's chest if it's roughly in front, otherwise straight ahead.
		local direction = aim
		if root then
			local toTarget = root.Position - origin
			if toTarget.Magnitude > 0.1 and flat(toTarget).Unit:Dot(aim) > 0.5 then
				direction = toTarget.Unit
			end
		end
		local hit = hitSpec(mob, move)
		ProjectileService.Fire({
			Owner = mob.Model,
			Team = "Enemies",
			Origin = origin,
			Direction = direction,
			Speed = move.Speed or 50,
			Radius = move.Radius or 1,
			Range = move.Range or 60,
			Color = BOLT_COLOR,
			OnHit = function(target: Model, _position: Vector3): boolean
				local outcome = CombatService.NpcHit(mob.Model, target, hit, origin)
				return outcome == "Dodge" or outcome == "PerfectDodge"
			end,
		})
	end
end

local function endMove(mob: Types.Mob)
	local gap = if mob.Def.KeepAway then PACING.RangedMoveGap else PACING.MoveGap
	mob.NextMoveAt = now() + random:NextNumber(gap[1], gap[2])
	CombatService.NpcEndAttack(mob.Model)
	mob.Humanoid:Move(Vector3.zero)
	mob.Humanoid.WalkSpeed = mob.Def.WalkSpeed
	Brain.ReleaseSlot(mob)
	mob.Acting = false
	mob.ActionThread = nil
	if not mob.Dead then
		face(mob, nil)
		if mob.State == "Attack" or mob.State == "Recover" then
			setState(mob, "Chase")
		end
	end
end

local function runMove(mob: Types.Mob, moveId: string, move: Mobs.MoveDef, target: Player)
	local blows = move.Blows
	local interval = move.BlowInterval or 0
	local telegraph = math.max(move.Telegraph * mob.TelegraphScale, AI.MinTelegraph)
	local busyFor = telegraph + interval * (#blows - 1) + 0.25
	if not CombatService.NpcBeginAttack(mob.Model, busyFor, move.HyperArmor == true) then
		endMove(mob)
		return
	end
	setState(mob, "Attack")
	Navigator.Stop(mob)

	for index, slot in blows do
		local windup = if index == 1 then telegraph else interval
		local contactAt = now() + windup
		announceBlow(mob, slot, windup, index == 1)
		local lunged = false
		while true do
			if interrupted(mob) then
				endMove(mob)
				return
			end
			local remaining = contactAt - now()
			if remaining <= 0 then
				break
			end
			local root = rootOf(target)
			if root and remaining > MOVE.TrackCutoff then
				face(mob, root.Position)
			end
			local lunge = move.Lunge
			if lunge and not lunged and remaining <= MOVE.LungeTime then
				lunged = true
				-- Step in, but stop short of the target instead of shoving into them.
				local look = flat(mob.Root.CFrame.LookVector)
				local gap = if root then flat(root.Position - mob.Root.Position).Magnitude - MOVE.LungeStopDistance * mob.Def.Body.Scale else lunge
				local distance = math.clamp(gap, 0, lunge * mob.Def.Body.Scale)
				if look.Magnitude > 0.01 and distance > 0.1 then
					mob.Humanoid.WalkSpeed = distance / MOVE.LungeTime * StatusService.SpeedMultiplier(mob.Model)
					mob.Humanoid:Move(look.Unit)
				end
			end
			task.wait(math.min(remaining, 1 / 30))
		end
		mob.Humanoid:Move(Vector3.zero)
		mob.Humanoid.WalkSpeed = mob.Def.WalkSpeed
		if interrupted(mob) then
			endMove(mob)
			return
		end
		release(mob, move, target)
	end

	CombatService.NpcEndAttack(mob.Model)
	setState(mob, "Recover")
	local recoverUntil = now() + move.Recovery
	while now() < recoverUntil do
		if mob.Dead then
			break
		end
		task.wait(1 / 15)
	end
	endMove(mob)
end

local function startMove(mob: Types.Mob, moveId: string, move: Mobs.MoveDef, target: Player)
	mob.Acting = true
	takeSlot(mob, target)
	mob.Cooldowns[moveId] = now() + move.Cooldown
	if mob.LastMove == moveId then
		mob.MoveRepeats += 1
	else
		mob.LastMove = moveId
		mob.MoveRepeats = 1
	end
	mob.ActionThread = task.spawn(runMove, mob, moveId, move, target)
end

-- Stops whatever move is running (death, despawn).
function Brain.CancelMove(mob: Types.Mob)
	local thread = mob.ActionThread
	mob.ActionThread = nil
	if thread and coroutine.status(thread) ~= "dead" and coroutine.running() ~= thread then
		task.cancel(thread)
	end
	if mob.Acting then
		endMove(mob)
	end
end

-- BEHAVIOURS -------------------------------------------------------------------

function Brain.StartReturn(mob: Types.Mob)
	Brain.CancelMove(mob)
	table.clear(mob.Threat)
	mob.Target = nil
	mob.TauntedBy = nil
	face(mob, nil)
	setState(mob, "Return")
	Navigator.MoveTo(mob, mob.Home, mob.Def.RunSpeed)
end

-- Spotting or being hit: start the fight (and wake the pack).
function Brain.Engage(mob: Types.Mob, player: Player, others: { Types.Mob }?)
	if mob.Dead or mob.State == "Return" or mob.Scripted or not allowed(mob, player) then
		return
	end
	local wasCalm = mob.State == "Idle" or mob.State == "Patrol"
	if not mob.Threat[player] then
		Brain.AddThreat(mob, player, SEE.ProximityThreat)
	end
	mob.LastTargetAt = now()
	if wasCalm then
		mob.Target = player
		mob.NoticeUntil = now() + SEE.NoticeTime
		Navigator.Stop(mob)
		setState(mob, "Alert")
		if others then
			for _, other in others do
				if other ~= mob and (other.Root.Position - mob.Root.Position).Magnitude <= SEE.PackRadius then
					Brain.Engage(other, player, nil)
				end
			end
		end
	end
end

local function patrol(mob: Types.Mob, t: number)
	if mob.State == "Patrol" then
		local goal = mob.Nav.Goal
		if not goal or flat(goal - mob.Root.Position).Magnitude <= MOVE.ArriveDistance then
			Navigator.Stop(mob)
			setState(mob, "Idle")
		else
			Navigator.MoveTo(mob, goal, mob.Def.WalkSpeed)
		end
		return
	end
	if t >= mob.NextPatrolAt then
		local interval = MOVE.PatrolInterval
		mob.NextPatrolAt = t + random:NextNumber(interval[1], interval[2])
		if mob.PatrolRadius > 0 then
			local angle = random:NextNumber(0, math.pi * 2)
			local distance = random:NextNumber(mob.PatrolRadius * 0.3, mob.PatrolRadius)
			local goal = mob.Home + Vector3.new(math.cos(angle), 0, math.sin(angle)) * distance
			setState(mob, "Patrol")
			Navigator.MoveTo(mob, goal, mob.Def.WalkSpeed)
		end
	end
end

-- Melee mobs waiting for a slot circle the target at CircleRadius.
local function circle(mob: Types.Mob, targetRoot: BasePart)
	local offset = flat(mob.Root.Position - targetRoot.Position)
	if offset.Magnitude < 0.1 then
		offset = Vector3.new(1, 0, 0)
	end
	local radial = offset.Unit
	local tangent = Vector3.new(-radial.Z, 0, radial.X) * (if mob.Serial % 2 == 0 then 1 else -1)
	local goal = targetRoot.Position + (radial * MOVE.CircleRadius + tangent * 4).Unit * MOVE.CircleRadius
	Navigator.MoveTo(mob, goal, mob.Def.WalkSpeed * MOVE.CircleSpeedMultiplier)
	face(mob, targetRoot.Position)
end

local function engage(mob: Types.Mob, target: Player, targetRoot: BasePart)
	local def = mob.Def
	local distance = flat(targetRoot.Position - mob.Root.Position).Magnitude

	local canShoot = true
	if def.KeepAway then
		canShoot = canSee(mob, targetRoot)
	end
	if canTakeSlot(mob, target) and now() >= mob.NextMoveAt then
		local moveId, move = chooseMove(mob, distance, canShoot)
		if moveId and move then
			startMove(mob, moveId, move, target)
			return
		end
	end

	-- Ranged mobs keep their distance.
	local keepAway = def.KeepAway
	if keepAway and distance < keepAway then
		local away = flat(mob.Root.Position - targetRoot.Position)
		away = if away.Magnitude > 0.1 then away.Unit else -flat(mob.Root.CFrame.LookVector).Unit
		Navigator.MoveTo(mob, mob.Root.Position + away * 8, def.WalkSpeed)
		face(mob, targetRoot.Position)
		return
	end

	-- How close it wants to be: in range of its shortest-reaching move.
	local want = math.huge
	for _, move in def.Moves do
		if move.MaxRange < want and (keepAway == nil or move.MinRange >= keepAway * 0.5) then
			want = move.MaxRange
		end
	end
	want = if want == math.huge then 6 else want * 0.75

	if not canTakeSlot(mob, target) and not keepAway then
		circle(mob, targetRoot)
	elseif distance > want or not canShoot then
		-- Too far, or (ranged) something is in the way: move in.
		face(mob, nil)
		Navigator.MoveTo(mob, targetRoot.Position, def.RunSpeed)
	else
		Navigator.Stop(mob)
		face(mob, targetRoot.Position)
	end
end

-- One think. `dt` is the time since the last one.
function Brain.Think(mob: Types.Mob, dt: number, others: { Types.Mob })
	if mob.Dead then
		return
	end
	local t = now()

	-- Threat fades slowly so an old grudge doesn't last forever.
	local keep = math.max(0, 1 - THREAT.DecayPerSecond * dt)
	for player, threat in mob.Threat do
		mob.Threat[player] = threat * keep
	end

	local action = CombatService.GetAction(mob.Model)
	if action == "Staggered" or action == "Broken" then
		if not mob.Acting then
			Navigator.Stop(mob)
		end
		setState(mob, action)
		return
	elseif mob.State == "Staggered" or mob.State == "Broken" then
		setState(mob, if mob.Target then "Chase" else "Idle")
	end
	if mob.Acting then
		return -- the running move owns the mob
	end

	if mob.State == "Return" then
		if flat(mob.Home - mob.Root.Position).Magnitude <= MOVE.ReturnArriveDistance then
			Navigator.Stop(mob)
			local humanoid = mob.Humanoid
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + humanoid.MaxHealth * AI.ReturnHealFraction)
			CombatService.ResetPosture(mob.Model)
			setState(mob, "Idle")
		else
			Navigator.MoveTo(mob, mob.Home, mob.Def.RunSpeed)
		end
		return
	end

	if flat(mob.Root.Position - mob.Home).Magnitude > AI.LeashRadius then
		Brain.StartReturn(mob)
		return
	end

	local target, targetRoot = pickTarget(mob)
	if target and targetRoot then
		mob.Target = target
		mob.LastTargetAt = t
	end

	if mob.State == "Idle" or mob.State == "Patrol" then
		local spotted = perceive(mob)
		if spotted then
			Brain.Engage(mob, spotted, others)
		else
			patrol(mob, t)
		end
		return
	end

	if not target or not targetRoot then
		mob.Target = nil
		Navigator.Stop(mob)
		face(mob, nil)
		if t - mob.LastTargetAt >= SEE.LoseTargetTime then
			Brain.StartReturn(mob)
		else
			-- Look around for someone else in the meantime.
			local spotted = perceive(mob)
			if spotted then
				Brain.AddThreat(mob, spotted, SEE.ProximityThreat)
			end
		end
		return
	end

	if mob.State == "Alert" then
		face(mob, targetRoot.Position)
		if t >= mob.NoticeUntil then
			setState(mob, "Chase")
		end
		return
	end

	setState(mob, "Chase")
	engage(mob, target, targetRoot)
end

return Brain
