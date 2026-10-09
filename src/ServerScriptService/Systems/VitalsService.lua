--!strict
--[[
	VitalsService
	Server authority for every player's health, stamina and Current (the Vessel).

	- Health lives on the Humanoid (written only by the server).
	- Stamina and Current are tracked here and replicated as Player
	  attributes (see Shared.Attributes) at Config.Combat.Vitals.TickRate.
	- Sprint is client intent (RequestSprint); the server decides whether it
	  is allowed and drains stamina only while the character actually moves.
	- Hitting 0 stamina makes the player Winded for 1 s (slow walk, no dodge),
	  and sprint stays locked until stamina refills to SprintResumeStamina
	  (so holding Shift can't stutter between sprint and Winded).
	- Out of combat (Vitals.CombatTimeout since LastCombat) sprinting costs
	  Surge.OutOfCombatCostMultiplier of the normal stamina.
	- Surge (SurgeState): Surge.ChargeSeconds of unbroken out-of-combat
	  sprinting sets the Surging attribute (faster sprint, applied by the
	  client and allowed by AntiExploitService only while it is set) and fires
	  SurgeBoom to everyone nearby. It ends and the charge resets when the
	  sprint stops, on death, Winded, any stamina-spending action (swing,
	  heavy, dodge, blocked blow), any CombatState other than Idle (blocking,
	  staggered), and any combat mark: damage taken, MarkCombat (blows landed
	  or received, casts, Arts) or a health drop.
	- Max values come from level + stats through Shared.Data.Formulas and are
	  recomputed whenever the profile's Level, Stats or equipped gear change (GearService).

	Other systems use the API: Damage, Heal, SpendStamina, SpendCurrent,
	AddCurrent, RestoreAll, MarkCombat. Passive Current regeneration can be
	scaled (Pressure, Burnout) and topped up (pools, canals) through
	SetCurrentRegenModifier.
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

local SurgeState = require(script.Parent.SurgeState)

local DataService = require(script.Parent.DataService)
local GearService = require(script.Parent.GearService)

local A = Attributes.Names

type State = {
	Player: Player,
	Humanoid: Humanoid?,
	Root: BasePart?,
	Stamina: number,
	MaxStamina: number,
	StaminaRegen: number,
	Current: number,
	MaxCurrent: number,
	CurrentRegen: number,
	SprintIntent: boolean,
	Sprinting: boolean,
	SprintLocked: boolean,
	WindedUntil: number,
	LastSpend: number,
	LastCombat: number,
	Surge: SurgeState.State,
	Shield: number, -- Ward: absorbs damage before health
	ShieldUntil: number,
	Sent: { [string]: any },
	Connections: { RBXScriptConnection },
}

local VitalsService = {}

-- Fired when a player's health drops: (player, amount)
VitalsService.Damaged = Signal.new() :: Signal.Signal<Player, number>

local states: { [Player]: State } = {}

local SURGE_TUNING: SurgeState.Tuning = {
	ChargeSeconds = Config.Combat.Surge.ChargeSeconds,
	StopGrace = Config.Combat.Surge.StopGrace,
	CombatTimeout = Config.Combat.Vitals.CombatTimeout,
}

-- (player) -> (regen multiplier, extra Current per second); set by CurrentService.
type RegenModifier = (Player) -> (number, number)
local regenModifier: RegenModifier? = nil

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function round1(value: number): number
	return math.floor(value * 10 + 0.5) / 10
end

-- Writes an attribute only when its value changed (keeps replication lean).
local function push(state: State, name: string, value: any)
	if state.Sent[name] ~= value then
		state.Sent[name] = value
		state.Player:SetAttribute(name, value)
	end
end

local function pushAll(state: State)
	push(state, A.Stamina, round1(state.Stamina))
	push(state, A.MaxStamina, state.MaxStamina)
	push(state, A.Current, round1(state.Current))
	push(state, A.MaxCurrent, state.MaxCurrent)
	push(state, A.Sprinting, state.Sprinting)
	push(state, A.Winded, now() < state.WindedUntil)
	push(state, A.SprintLocked, state.SprintLocked)
	push(state, A.LastCombat, state.LastCombat)
	push(state, A.Surging, state.Surge.Surging)
	push(state, A.Shield, math.ceil(state.Shield))
end

-- Ends a Surge and resets its charge now (the attribute flips at once, not
-- on the next tick).
local function breakSurge(state: State)
	SurgeState.Cancel(state.Surge)
	push(state, A.Surging, false)
end

-- Anything that counts as combat: stamps LastCombat and breaks the Surge.
local function enterCombat(state: State)
	state.LastCombat = now()
	push(state, A.LastCombat, state.LastCombat)
	breakSurge(state)
end

-- The sonic boom: everyone near the runner draws it (SprintVFXController).
local function fireSurgeBoom(state: State)
	local root = state.Root
	local humanoid = state.Humanoid
	local character = humanoid and humanoid.Parent
	if not root or not character then
		return
	end
	local audience: { Player } = {}
	for _, other in Players:GetPlayers() do
		local otherCharacter = other.Character
		local otherRoot = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart")
		if otherRoot and otherRoot:IsA("BasePart") and (otherRoot.Position - root.Position).Magnitude <= Config.Combat.FeedbackRadius then
			table.insert(audience, other)
		end
	end
	Net.FireList("SurgeBoom", audience, character)
end

local function getState(player: Player): State?
	return states[player]
end

local function isAlive(state: State): boolean
	local humanoid = state.Humanoid
	return humanoid ~= nil and humanoid.Parent ~= nil and humanoid.Health > 0
end

-- Recomputes max values from the profile (level, stats) and equipped gear.
local function recompute(state: State)
	local player = state.Player
	local data = DataService.GetData(player)
	if not data then
		return
	end
	local stats = GearService.GetStats(player)
	local bonus = GearService.Bonus
	local maxHealth = Formulas.MaxHealth(data.Level, stats.Vitality, bonus(player, "MaxHealth"))
	state.MaxStamina = Formulas.MaxStamina(stats.Endurance, bonus(player, "MaxStamina"))
	state.StaminaRegen = Formulas.StaminaRegen(stats.Endurance) * (1 + bonus(player, "StaminaRegen"))
	state.MaxCurrent = Formulas.MaxCurrent(data.Level, stats.Draw, bonus(player, "MaxCurrent"))
	state.CurrentRegen = Formulas.CurrentRegen(stats.Draw) * (1 + bonus(player, "CurrentRegen"))
	state.Stamina = math.min(state.Stamina, state.MaxStamina)
	state.Current = math.min(state.Current, state.MaxCurrent)
	state.Player:SetAttribute(A.Level, data.Level)

	local humanoid = state.Humanoid
	if humanoid and humanoid.Parent then
		-- Keep the same health fraction when the maximum changes.
		local fraction = if humanoid.MaxHealth > 0 then humanoid.Health / humanoid.MaxHealth else 1
		humanoid.MaxHealth = maxHealth
		if humanoid.Health > 0 then
			humanoid.Health = math.clamp(maxHealth * fraction, 1, maxHealth)
		end
	end
	pushAll(state)
end

local function becomeWinded(state: State)
	state.WindedUntil = now() + Config.Combat.Stamina.WindedDuration
	state.Sprinting = false
	state.SprintLocked = true
	breakSurge(state)
end

-- Any action state (swinging, dodging, blocking, staggered) breaks a Surge.
local function isActing(state: State): boolean
	local humanoid = state.Humanoid
	local character = humanoid and humanoid.Parent
	local combatState = character and character:GetAttribute(A.CombatState)
	return combatState ~= nil and combatState ~= "Idle"
end

local function tick(state: State, dt: number)
	if not isAlive(state) then
		if state.Surge.Surging then
			breakSurge(state)
		end
		return
	end
	local t = now()
	if state.Shield > 0 and t >= state.ShieldUntil then
		state.Shield = 0
	end
	local root = state.Root
	local moving = false
	if root then
		local velocity = root.AssemblyLinearVelocity
		moving = Vector3.new(velocity.X, 0, velocity.Z).Magnitude > Config.Combat.Vitals.SprintMinSpeed
	end

	local winded = t < state.WindedUntil
	if state.SprintLocked and state.Stamina >= Config.Combat.Stamina.SprintResumeStamina then
		state.SprintLocked = false
	end
	-- Overburdened (bag over carry weight) can't sprint.
	local burdened = state.Player:GetAttribute(A.Overburdened) == true
	state.Sprinting = state.SprintIntent and not winded and not burdened and not state.SprintLocked and state.Stamina > 0

	if state.Sprinting and moving then
		local cost = Config.Combat.Stamina.SprintCostPerSecond
		if not SurgeState.InCombat(SURGE_TUNING, t, state.LastCombat) then
			cost *= Config.Combat.Surge.OutOfCombatCostMultiplier
		end
		state.Stamina = math.max(0, state.Stamina - cost * dt)
		state.LastSpend = t
		if state.Stamina <= 0 then
			becomeWinded(state)
		end
	elseif not winded and t - state.LastSpend >= Config.Combat.Stamina.RegenDelay then
		state.Stamina = math.min(state.MaxStamina, state.Stamina + state.StaminaRegen * dt)
	end

	-- Surge: after the drain, so running dry this tick ends it.
	local event = if isActing(state)
		then SurgeState.Cancel(state.Surge)
		else SurgeState.Step(state.Surge, SURGE_TUNING, dt, state.Sprinting, moving, t, state.LastCombat)
	if event == "Started" then
		push(state, A.Surging, true)
		fireSurgeBoom(state)
	end

	local multiplier, extra = 1, 0
	local modifier = regenModifier
	if modifier then
		multiplier, extra = modifier(state.Player)
	end
	state.Current = math.min(state.MaxCurrent, state.Current + (state.CurrentRegen * multiplier + extra) * dt)
	pushAll(state)
end

-- PUBLIC API -----------------------------------------------------------------

-- Attaches vitals to a freshly spawned character and fully restores them.
function VitalsService.Bind(player: Player, character: Model)
	local state = getState(player)
	if not state then
		return
	end
	for _, connection in state.Connections do
		connection:Disconnect()
	end
	table.clear(state.Connections)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	state.Humanoid = humanoid
	state.Root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	state.SprintIntent = false
	state.Sprinting = false
	state.SprintLocked = false
	state.WindedUntil = 0
	state.Surge = SurgeState.new()
	state.Shield = 0
	state.ShieldUntil = 0
	recompute(state)
	if humanoid then
		humanoid.Health = humanoid.MaxHealth
		local lastHealth = humanoid.Health
		table.insert(
			state.Connections,
			humanoid.HealthChanged:Connect(function(health: number)
				if health < lastHealth then
					enterCombat(state)
				end
				lastHealth = health
			end)
		)
	end
	state.Stamina = state.MaxStamina
	state.Current = state.MaxCurrent
	pushAll(state)
end

-- Deals damage (already mitigated by the caller). Returns damage applied.
function VitalsService.Damage(player: Player, amount: number): number
	local state = getState(player)
	if not state or not isAlive(state) or amount <= 0 then
		return 0
	end
	-- A Ward shield soaks damage first.
	if state.Shield > 0 and now() < state.ShieldUntil then
		local absorbed = math.min(state.Shield, amount)
		state.Shield -= absorbed
		amount -= absorbed
		push(state, A.Shield, math.ceil(state.Shield))
		if amount <= 0 then
			enterCombat(state)
			return 0
		end
	end
	local humanoid = state.Humanoid :: Humanoid
	local applied = math.min(amount, humanoid.Health)
	humanoid.Health -= applied
	enterCombat(state)
	VitalsService.Damaged:Fire(player, applied)
	return applied
end

-- Ward: a shield of `amount` that absorbs damage for `duration` seconds
-- (replaces any shield already up).
function VitalsService.SetShield(player: Player, amount: number, duration: number)
	local state = getState(player)
	if not state or not isAlive(state) then
		return
	end
	state.Shield = math.max(0, amount)
	state.ShieldUntil = now() + duration
	push(state, A.Shield, math.ceil(state.Shield))
end

function VitalsService.HasShield(player: Player): boolean
	local state = getState(player)
	return state ~= nil and state.Shield > 0 and now() < state.ShieldUntil
end

function VitalsService.Heal(player: Player, amount: number): number
	local state = getState(player)
	if not state or not isAlive(state) or amount <= 0 then
		return 0
	end
	local humanoid = state.Humanoid :: Humanoid
	local before = humanoid.Health
	humanoid.Health = math.min(humanoid.MaxHealth, before + amount)
	return humanoid.Health - before
end

-- Spends stamina for an action. Actions are allowed while any stamina is
-- left (souls-like: the last action can overdraw into Winded). Every caller
-- is a combat action (swing, heavy, dodge, blocked blow), so it breaks a Surge.
function VitalsService.SpendStamina(player: Player, amount: number): boolean
	local state = getState(player)
	if not state or not isAlive(state) then
		return false
	end
	if state.Stamina <= 0 or now() < state.WindedUntil then
		return false
	end
	state.Stamina = math.max(0, state.Stamina - amount)
	state.LastSpend = now()
	breakSurge(state)
	if state.Stamina <= 0 then
		becomeWinded(state)
	end
	pushAll(state)
	return true
end

function VitalsService.SpendCurrent(player: Player, amount: number): boolean
	local state = getState(player)
	if not state or not isAlive(state) or state.Current < amount then
		return false
	end
	state.Current -= amount
	pushAll(state)
	return true
end

function VitalsService.AddCurrent(player: Player, amount: number)
	local state = getState(player)
	if state and isAlive(state) then
		state.Current = math.clamp(state.Current + amount, 0, state.MaxCurrent)
		pushAll(state)
	end
end

function VitalsService.RestoreAll(player: Player)
	local state = getState(player)
	if not state or not isAlive(state) then
		return
	end
	local humanoid = state.Humanoid :: Humanoid
	humanoid.Health = humanoid.MaxHealth
	state.Stamina = state.MaxStamina
	state.Current = state.MaxCurrent
	state.WindedUntil = 0
	state.SprintLocked = false
	pushAll(state)
end

-- Gives stamina back (perfect dodges). Never exceeds the maximum.
function VitalsService.RestoreStamina(player: Player, amount: number)
	local state = getState(player)
	if state and isAlive(state) and amount > 0 then
		state.Stamina = math.min(state.MaxStamina, state.Stamina + amount)
		pushAll(state)
	end
end

-- Holds stamina regen off this tick (blocking keeps stamina from refilling).
function VitalsService.PauseRegen(player: Player)
	local state = getState(player)
	if state then
		state.LastSpend = now()
	end
end

function VitalsService.SetCurrentRegenModifier(modifier: RegenModifier?)
	regenModifier = modifier
end

function VitalsService.GetMaxHealth(player: Player): number
	local state = getState(player)
	local humanoid = state and state.Humanoid
	return if humanoid then humanoid.MaxHealth else 0
end

function VitalsService.GetMaxCurrent(player: Player): number
	local state = getState(player)
	return if state then state.MaxCurrent else 0
end

function VitalsService.MarkCombat(player: Player)
	local state = getState(player)
	if state then
		enterCombat(state)
	end
end

function VitalsService.IsWinded(player: Player): boolean
	local state = getState(player)
	return state ~= nil and now() < state.WindedUntil
end

function VitalsService.IsSprinting(player: Player): boolean
	local state = getState(player)
	return state ~= nil and state.Sprinting
end

function VitalsService.IsSurging(player: Player): boolean
	local state = getState(player)
	return state ~= nil and state.Surge.Surging
end

function VitalsService.GetStamina(player: Player): number
	local state = getState(player)
	return if state then state.Stamina else 0
end

function VitalsService.GetCurrent(player: Player): number
	local state = getState(player)
	return if state then state.Current else 0
end

-- LIFECYCLE ------------------------------------------------------------------

local function createState(player: Player)
	local stamina = Config.Combat.Stamina.Max
	local current = Config.Current.Vessel.Base
	states[player] = {
		Player = player,
		Humanoid = nil,
		Root = nil,
		Stamina = stamina,
		MaxStamina = stamina,
		StaminaRegen = Config.Combat.Stamina.RegenPerSecond,
		Current = current,
		MaxCurrent = current,
		CurrentRegen = Config.Current.Regen.BasePerSecond,
		SprintIntent = false,
		Sprinting = false,
		SprintLocked = false,
		WindedUntil = 0,
		LastSpend = 0,
		LastCombat = 0,
		Surge = SurgeState.new(),
		Shield = 0,
		ShieldUntil = 0,
		Sent = {},
		Connections = {},
	}
	player:SetAttribute(A.Saturation, 0)
	player:SetAttribute(A.Resonance, 0)
end

function VitalsService.Init()
	Net.On("RequestSprint", function(player: Player, wantsSprint: boolean)
		local state = getState(player)
		if state then
			state.SprintIntent = wantsSprint
			if not wantsSprint then
				state.Sprinting = false
				push(state, A.Sprinting, false)
				breakSurge(state)
			end
		end
	end)
end

function VitalsService.Start()
	Players.PlayerAdded:Connect(createState)
	for _, player in Players:GetPlayers() do
		if not states[player] then
			createState(player)
		end
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		local state = states[player]
		if state then
			for _, connection in state.Connections do
				connection:Disconnect()
			end
		end
		states[player] = nil
	end)

	DataService.ProfileLoaded:Connect(function(player: Player)
		local state = getState(player)
		if state then
			recompute(state)
		end
	end)
	-- Level, stats and gear all flow through GearService (one deferred signal
	-- per frame, however many items changed).
	GearService.Changed:Connect(function(player: Player)
		local state = getState(player)
		if state then
			recompute(state)
		end
	end)

	-- Fixed-rate tick: cheap at 30 players (a handful of numbers each).
	local interval = 1 / Config.Combat.Vitals.TickRate
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < interval then
			return
		end
		local step = accumulator
		accumulator = 0
		for _, state in states do
			tick(state, step)
		end
	end)
end

return VitalsService
