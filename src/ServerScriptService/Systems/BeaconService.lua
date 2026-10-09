--!strict
--[[
	BeaconService
	Beacons (Spec Section 6): small orbs of shaped Current that circle an
	attuned Climber. Slots: Config.Current.Beacons.StartSlots, plus one at
	each Control threshold (Formulas.BeaconSlots), up to MaxSlots. Each slot
	holds a behaviour (profile Beacons.Slots, set from the Spellbook with
	RequestSetBeacon):

	  Sentry   while you're fighting (you hit or were hit by something in the
	           last CombatTimeout seconds; Sentry shots don't count), fires a
	           small Bolt every Interval at that enemy, or the nearest one.
	  Aegis    absorbs one blow completely (CombatService absorber), then
	           breaks and re-forms after Recharge seconds.
	  Lantern  lights the area and reveals hidden things (client side,
	           CollectionService tag LanternReveal).
	  Relay    remembers the last spell you cast (not Step) and casts it again
	           for free at whoever you parry; Cooldown between recasts.

	The active list is mirrored to the player's Beacons attribute
	("Sentry,Aegis,~Aegis": "~" marks a broken Aegis) so every client can
	draw the orbs; RelaySpell and AegisReadyAt drive the Spellbook and HUD.
	A first Attunement fills an empty first slot with a Sentry.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local Spells = require(Shared.Data.Spells)
local Formulas = require(Shared.Data.Formulas)

local DataService = require(script.Parent.DataService)
local GearService = require(script.Parent.GearService)
local TargetService = require(script.Parent.TargetService)
local CombatService = require(script.Parent.CombatService)
local ProjectileService = require(script.Parent.ProjectileService)
local SpellService = require(script.Parent.SpellService)

local A = Attributes.Names
local B = Config.Current.Beacons

local BeaconService = {}

local BEHAVIOURS = { "Sentry", "Aegis", "Lantern", "Relay" }

type Beacon = {
	Behaviour: string,
	ReadyAt: number, -- Aegis: re-forms at this server time (0 = whole)
	NextShot: number, -- Sentry
}

type State = {
	Beacons: { Beacon },
	LastTarget: Model?,
	EngagedAt: number, -- last time the player hit, or was hit by, an enemy (not counting Sentry shots)
	Relay: string,
	RelayReadyAt: number,
	Sent: string,
}

local states: { [Player]: State } = {}

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function rootOf(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function stateOf(player: Player): State
	local state = states[player]
	if not state then
		state = { Beacons = {}, LastTarget = nil, EngagedAt = 0, Relay = "", RelayReadyAt = 0, Sent = "" }
		states[player] = state
	end
	return state
end

local function push(player: Player, state: State)
	local tokens = {}
	local aegisReady = 0
	local t = now()
	for _, beacon in state.Beacons do
		local broken = beacon.Behaviour == "Aegis" and beacon.ReadyAt > t
		table.insert(tokens, (if broken then "~" else "") .. beacon.Behaviour)
		if broken and (aegisReady == 0 or beacon.ReadyAt < aegisReady) then
			aegisReady = beacon.ReadyAt
		end
	end
	local text = table.concat(tokens, ",")
	if text ~= state.Sent then
		state.Sent = text
		player:SetAttribute(A.Beacons, text)
	end
	player:SetAttribute(A.AegisReadyAt, aegisReady)
	player:SetAttribute(A.RelaySpell, state.Relay)
end

-- How many slots the player can use right now (0 until attuned).
function BeaconService.SlotCount(player: Player): number
	local data = DataService.GetData(player)
	if not data then
		return 0
	end
	if B.UnlockWithAttunement and data.Attunements.Primary == "" then
		return 0
	end
	-- Beaconkeeper tree: BeaconSlots adds slots on top of Control's, up to MaxSlots.
	local extra = math.floor(GearService.Bonus(player, "BeaconSlots"))
	return math.min(B.MaxSlots, Formulas.BeaconSlots(GearService.GetStats(player).Control) + extra)
end

-- Rebuilds the active Beacons from the profile, keeping Aegis breaks.
local function refresh(player: Player)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	local state = stateOf(player)
	local previous = state.Beacons
	local count = BeaconService.SlotCount(player)
	local beacons: { Beacon } = {}
	for slot = 1, count do
		local behaviour = data.Beacons.Slots[slot]
		if type(behaviour) == "string" and table.find(BEHAVIOURS, behaviour) then
			local old = previous[#beacons + 1]
			table.insert(beacons, {
				Behaviour = behaviour,
				ReadyAt = if old and old.Behaviour == behaviour then old.ReadyAt else 0,
				NextShot = 0,
			})
		end
	end
	state.Beacons = beacons
	local hasRelay = false
	for _, beacon in beacons do
		hasRelay = hasRelay or beacon.Behaviour == "Relay"
	end
	if not hasRelay then
		state.Relay = ""
	end
	push(player, state)
end

local function has(state: State, behaviour: string): boolean
	for _, beacon in state.Beacons do
		if beacon.Behaviour == behaviour then
			return true
		end
	end
	return false
end

-- AEGIS --------------------------------------------------------------------------

local function absorb(defender: Model): boolean
	local player = Players:GetPlayerFromCharacter(defender)
	local state = player and states[player]
	if not player or not state then
		return false
	end
	local t = now()
	for _, beacon in state.Beacons do
		if beacon.Behaviour == "Aegis" and beacon.ReadyAt <= t then
			-- Pearl Core (and any "AegisRecharge" bonus) re-forms it sooner.
			beacon.ReadyAt = t + B.Aegis.Recharge * math.max(0.25, 1 - GearService.Bonus(player, "AegisRecharge"))
			push(player, state)
			return true
		end
	end
	return false
end

-- SENTRY -------------------------------------------------------------------------

local function sentryTarget(state: State, root: BasePart): Model?
	local last = state.LastTarget
	local lastTarget = last and TargetService.Get(last)
	if
		last
		and lastTarget
		and lastTarget.Team ~= "Players"
		and TargetService.IsAlive(lastTarget)
		and TargetService.DistanceTo(lastTarget, root.Position) <= B.Sentry.Range
	then
		return last
	end
	local best: Model? = nil
	local bestDistance = B.Sentry.Range
	for model, target in TargetService.GetAll() do
		if target.Team ~= "Players" and TargetService.IsAlive(target) then
			local distance = TargetService.DistanceTo(target, root.Position)
			if distance < bestDistance then
				best = model
				bestDistance = distance
			end
		end
	end
	return best
end

local function fireSentry(player: Player, character: Model, root: BasePart, target: Model, index: number, total: number)
	local targetRoot = rootOf(target)
	local info = TargetService.Get(target)
	if not targetRoot or not info then
		return
	end
	local data = DataService.GetData(player)
	local density = GearService.GetStats(player).Density
	local primary = if data then data.Attunements.Primary else ""
	local element = Spells.Attunement(primary)
	-- Shots leave from where the orb is in its orbit (roughly).
	local angle = (index / math.max(total, 1)) * math.pi * 2 + now() * B.OrbitSpeed
	local origin = root.Position
		+ Vector3.new(math.cos(angle) * B.OrbitRadiusCombat, B.Height, math.sin(angle) * B.OrbitRadiusCombat)
	local hit = {
		Damage = B.Sentry.Damage * Formulas.SpellPower(density) * (1 + GearService.Bonus(player, "SentryDamage")),
		Posture = B.Sentry.Posture,
		Kind = "Beacon" :: CombatService.HitKind,
		Parryable = false,
		Blockable = true,
		HitStun = 0,
		CritChance = 0,
		CritMultiplier = 1,
		Element = if primary ~= "" then primary else nil,
	}
	ProjectileService.Fire({
		Owner = character,
		Team = "Players",
		Origin = origin,
		-- At the nearest point of the body (its root, unless it is a big one).
		Direction = TargetService.AxisPoint(info, origin, targetRoot.Position) - origin,
		Speed = B.Sentry.Speed,
		Radius = B.Sentry.Radius,
		Range = B.Sentry.Range + 6,
		Color = if element then element.Color else Color3.fromHex("#3FE0D0"),
		OnHit = function(model: Model, _position: Vector3): boolean
			local outcome = CombatService.NpcHit(character, model, hit, origin)
			return outcome == "Dodge" or outcome == "PerfectDodge"
		end,
	})
end

local function tick()
	local t = now()
	for player, state in states do
		local character = player.Character
		local root = character and rootOf(character)
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if character and root and humanoid and humanoid.Health > 0 and #state.Beacons > 0 then
			local fighting = t - state.EngagedAt <= Config.Combat.Vitals.CombatTimeout
			local changed = false
			for index, beacon in state.Beacons do
				if beacon.Behaviour == "Sentry" and fighting and t >= beacon.NextShot then
					local target = sentryTarget(state, root)
					if target then
						beacon.NextShot = t + B.Sentry.Interval
						fireSentry(player, character, root, target, index, #state.Beacons)
					end
				elseif beacon.Behaviour == "Aegis" and beacon.ReadyAt > 0 and t >= beacon.ReadyAt then
					beacon.ReadyAt = 0
					changed = true
				end
			end
			if changed then
				push(player, state)
			end
		end
	end
end

-- RELAY --------------------------------------------------------------------------

local function onSpellCast(player: Player, spellId: string)
	local state = states[player]
	local spell = Spells.Get(spellId)
	if state and spell and spell.Form ~= "Step" and has(state, "Relay") then
		state.Relay = spellId
		push(player, state)
	end
end

local function onParried(parrier: Model, attacker: Model?)
	local player = Players:GetPlayerFromCharacter(parrier)
	local state = player and states[player]
	if not player or not state or state.Relay == "" or not attacker then
		return
	end
	local t = now()
	if t < state.RelayReadyAt then
		return
	end
	local attackerRoot = rootOf(attacker)
	if not attackerRoot then
		return
	end
	local spellId = state.Relay
	state.Relay = ""
	state.RelayReadyAt = t + B.Relay.Cooldown * math.max(0.25, 1 - GearService.Bonus(player, "RelayCooldown"))
	push(player, state)
	SpellService.Recast(player, spellId, attackerRoot.Position)
end

-- HITS / REQUESTS ----------------------------------------------------------------

local function onHitLanded(attacker: Model?, defender: Model, _outcome: string, _applied: number, kind: string)
	-- The player struck something (Sentry shots don't count, or they'd never stop).
	local player = if attacker then Players:GetPlayerFromCharacter(attacker) else nil
	local state = player and states[player]
	if state and kind ~= "Beacon" and TargetService.Get(defender) then
		state.LastTarget = defender
		state.EngagedAt = now()
	end
	-- The player was struck: the Sentry answers whoever did it.
	local victim = Players:GetPlayerFromCharacter(defender)
	local victimState = victim and states[victim]
	if victimState and attacker and TargetService.Get(attacker) then
		victimState.EngagedAt = now()
		victimState.LastTarget = attacker
	end
end

local function onSetBeacon(player: Player, slot: number, behaviour: string)
	local data = DataService.GetData(player)
	if not data or slot > BeaconService.SlotCount(player) then
		return
	end
	local slots = table.clone(data.Beacons.Slots)
	for index = #slots + 1, B.MaxSlots do
		slots[index] = ""
	end
	slots[slot] = behaviour
	DataService.Set(player, { "Beacons", "Slots" }, slots)
end

-- A first Attunement gives an empty first slot a Sentry, so Beacons show up.
local function seedFirstBeacon(player: Player)
	local data = DataService.GetData(player)
	if not data or data.Attunements.Primary == "" then
		return
	end
	for _, behaviour in data.Beacons.Slots do
		if behaviour ~= "" then
			return
		end
	end
	local slots = table.clone(data.Beacons.Slots)
	for index = #slots + 1, B.MaxSlots do
		slots[index] = ""
	end
	slots[1] = "Sentry"
	DataService.Set(player, { "Beacons", "Slots" }, slots)
end

function BeaconService.Init()
	Net.On("RequestSetBeacon", onSetBeacon)
end

function BeaconService.Start()
	CombatService.SetAbsorber(absorb)
	CombatService.HitLanded:Connect(onHitLanded)
	CombatService.Parried:Connect(onParried)
	SpellService.SpellCast:Connect(onSpellCast)

	DataService.ProfileLoaded:Connect(function(player: Player)
		seedFirstBeacon(player)
		refresh(player)
	end)
	DataService.Changed:Connect(function(player: Player, path: { string })
		local root = path[1]
		if root == "Attunements" then
			seedFirstBeacon(player)
			refresh(player)
		elseif root == "Beacons" or root == "Stats" then
			refresh(player)
		end
	end)
	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			local state = states[player]
			if state then
				for _, beacon in state.Beacons do
					beacon.ReadyAt = 0
				end
				state.Relay = ""
				push(player, state)
			end
		end)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		states[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		if DataService.IsLoaded(player) then
			refresh(player)
		end
	end

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator >= 0.1 then
			accumulator = 0
			tick()
		end
	end)
end

return BeaconService
