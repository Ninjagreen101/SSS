--!strict
--[[
	CurrentService
	The Current's rhythm (Spec Sections 6 and 8): Saturation, Overflow,
	Burnout, Resonance and Infusion. Spending Current (VitalsService) and
	casting (SpellService) live elsewhere; this service keeps the state that
	builds as you fight, and plugs it into combat and regeneration.

	Saturation (0..Saturation.Max, the ring around the HUD portrait)
	  Each cast adds cost x PerCastFraction. It drains DrainPerSecond after
	  DrainDelay seconds without casting. Filling it triggers:
	Overflow (Overflow.Duration s)
	  Spells cost nothing and deal +DensityBonus damage; Saturation stays full.
	Burnout (Burnout.Duration s) when Overflow ends
	  Saturation empties and can't build, no Current regeneration, and
	  casting is CastSpeedPenalty slower.

	Resonance (0..MaxStacks, the HUD diamonds)
	  Landing a weapon blow and then a spell (or a spell then a weapon blow)
	  within LinkWindow seconds adds a stack; the same tool twice in a row
	  doesn't. Weapon Arts count as weapon blows. A successful parry adds
	  ParryStacks at once. Each stack adds DamagePerStack to weapon blows and
	  spells. After DecayDelay seconds without a new stack, stacks fall off
	  one every DecayInterval. A Confluence consumes them all (ConsumeStacks).

	Infusion (Infusion.Duration s, started by ArtService)
	  The blade carries the primary Attunement: weapon blows and Arts apply
	  its status, and weapon blows Siphon +SiphonBonus Current.

	It also wires the other systems: CombatService damage modifiers (Heavy
	on every blow taken; Resonance and low Pressure on weapon blows), the
	Siphon modifier (Draw, Pressure, Infusion) and VitalsService Current
	regeneration (Pressure, pools and canals, Burnout).
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
local Affixes = require(Shared.Data.Affixes)

local DataService = require(script.Parent.DataService)
local GearService = require(script.Parent.GearService)
local VitalsService = require(script.Parent.VitalsService)
local CombatService = require(script.Parent.CombatService)
local StatusService = require(script.Parent.StatusService)
local PressureService = require(script.Parent.PressureService)

local A = Attributes.Names
local C = Config.Current

local decayDelay: (player: Player) -> number
local holdsResonance: (player: Player) -> boolean

local CurrentService = {}

type Tool = "Weapon" | "Spell"

type State = {
	Saturation: number,
	LastCastAt: number,
	OverflowUntil: number,
	BurnoutUntil: number,
	Stacks: number,
	LastLinkAt: number,
	NextDecayAt: number,
	LastTool: Tool?,
	LastToolAt: number,
	InfusedUntil: number,
	Infusion: string,
}

local states: { [Player]: State } = {}

-- Blows that land (the target felt them); dodges, parries and Aegis don't count.
local LANDED: { [string]: boolean } = {
	Hit = true,
	Blocked = true,
	GuardBreak = true,
	Riposte = true,
	Finisher = true,
	Broken = true,
	Reaction = true,
}

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function stateOf(player: Player): State
	local state = states[player]
	if not state then
		state = {
			Saturation = 0,
			LastCastAt = 0,
			OverflowUntil = 0,
			BurnoutUntil = 0,
			Stacks = 0,
			LastLinkAt = 0,
			NextDecayAt = 0,
			LastTool = nil,
			LastToolAt = -math.huge,
			InfusedUntil = 0,
			Infusion = "",
		}
		states[player] = state
	end
	return state
end

local function push(player: Player, state: State)
	player:SetAttribute(A.Saturation, math.floor(state.Saturation + 0.5))
	player:SetAttribute(A.Resonance, state.Stacks)
	player:SetAttribute(A.Overflow, state.OverflowUntil)
	player:SetAttribute(A.Burnout, state.BurnoutUntil)
	player:SetAttribute(A.InfusedUntil, state.InfusedUntil)
	player:SetAttribute(A.Infusion, state.Infusion)
end

-- Which tool a blow came from, for Resonance (nil = doesn't count).
local function toolOf(kind: string): Tool?
	if kind == "Spell" then
		return "Spell"
	end
	if kind == "Art" or kind == "Ability" or CombatService.IsWeaponKind(kind) then
		return "Weapon"
	end
	return nil
end

local function isAttuned(player: Player): boolean
	local data = DataService.GetData(player)
	return data ~= nil and data.Attunements.Primary ~= ""
end

local function addStacks(player: Player, state: State, amount: number)
	local before = state.Stacks
	state.Stacks = math.min(C.Resonance.MaxStacks, state.Stacks + amount)
	state.LastLinkAt = now()
	push(player, state)
	if state.Stacks > before then
		Net.Fire("ResonanceTriggered", player, state.Stacks)
		if state.Stacks >= C.Resonance.MaxStacks and isAttuned(player) then
			Net.Fire("Notify", player, "Toasts.ConfluenceReady", {}, "Success")
		end
	end
end

-- SATURATION ---------------------------------------------------------------------

-- A spell was cast for `cost` Current.
function CurrentService.OnCast(player: Player, cost: number)
	local state = stateOf(player)
	local t = now()
	state.LastCastAt = t
	if t < state.OverflowUntil or t < state.BurnoutUntil then
		return
	end
	state.Saturation = math.min(C.Saturation.Max, state.Saturation + cost * C.Saturation.PerCastFraction)
	if state.Saturation >= C.Saturation.Max then
		-- Tidecaller tree: OverflowDuration stretches it.
		state.OverflowUntil = t + C.Overflow.Duration + GearService.Bonus(player, "OverflowDuration")
		Net.Fire("Notify", player, "Toasts.Overflow", {}, "Success")
	end
	push(player, state)
end

function CurrentService.IsOverflowing(player: Player): boolean
	return now() < stateOf(player).OverflowUntil
end

function CurrentService.IsBurnedOut(player: Player): boolean
	return now() < stateOf(player).BurnoutUntil
end

-- Spell damage multiplier: Resonance and Overflow.
function CurrentService.SpellMultiplier(player: Player): number
	local state = stateOf(player)
	local scale = 1 + state.Stacks * C.Resonance.DamagePerStack
	if now() < state.OverflowUntil then
		scale *= 1 + C.Overflow.DensityBonus
	end
	return scale
end

-- Cast time multiplier (Burnout slows casting).
function CurrentService.CastTimeMultiplier(player: Player): number
	return if now() < stateOf(player).BurnoutUntil then 1 + C.Burnout.CastSpeedPenalty else 1
end

-- RESONANCE ----------------------------------------------------------------------

-- Grants Resonance stacks from outside the weave (gear effects).
function CurrentService.AddStacks(player: Player, amount: number)
	addStacks(player, stateOf(player), amount)
end

function CurrentService.GetStacks(player: Player): number
	return stateOf(player).Stacks
end

-- Studio testing only (DevService): sets the stack count directly.
function CurrentService.DevSetStacks(player: Player, stacks: number)
	local state = stateOf(player)
	state.Stacks = math.clamp(stacks, 0, C.Resonance.MaxStacks)
	state.LastLinkAt = now()
	push(player, state)
end

-- A Confluence spends every stack.
function CurrentService.ConsumeStacks(player: Player)
	local state = stateOf(player)
	state.Stacks = 0
	state.LastTool = nil
	push(player, state)
end

-- INFUSION -----------------------------------------------------------------------

-- Infuses the player's blade with `attunement` for `duration` seconds.
function CurrentService.Infuse(player: Player, attunement: string, duration: number)
	local state = stateOf(player)
	state.Infusion = attunement
	state.InfusedUntil = now() + duration
	push(player, state)
end

-- The element the player's blade carries right now, or nil.
function CurrentService.GetInfusion(player: Player): string?
	local state = stateOf(player)
	if state.Infusion ~= "" and now() < state.InfusedUntil then
		return state.Infusion
	end
	return nil
end

-- HITS ---------------------------------------------------------------------------

local function onHitLanded(attacker: Model?, defender: Model, outcome: string, _applied: number, kind: string)
	local player = if attacker then Players:GetPlayerFromCharacter(attacker) else nil
	if not player or not LANDED[outcome] then
		return
	end
	local state = stateOf(player)
	local t = now()
	local tool: Tool? = toolOf(kind)
	if tool then
		-- Alternating tools within the window builds Resonance; repeating one doesn't.
		if state.LastTool and state.LastTool ~= tool and t - state.LastToolAt <= C.Resonance.LinkWindow then
			addStacks(player, state, 1)
		end
		state.LastTool = tool
		state.LastToolAt = t
	end
	-- Infused weapon blows and Arts carry the element's status.
	if tool == "Weapon" then
		local infusion = CurrentService.GetInfusion(player)
		local element = infusion and Spells.Attunement(infusion)
		if element then
			StatusService.Apply(defender, element.Status)
		end
	end
end

local function onParried(parrier: Model, _attacker: Model?)
	local player = Players:GetPlayerFromCharacter(parrier)
	if player then
		addStacks(player, stateOf(player), C.Resonance.ParryStacks)
	end
end

-- TICK ---------------------------------------------------------------------------

-- Seconds without a new stack before Resonance starts to fall (gear can lengthen it).
function decayDelay(player: Player): number
	return C.Resonance.DecayDelay + GearService.Bonus(player, "ResonanceDecay")
end

-- Spireheart (unique effect): no decay while health stays high.
function holdsResonance(player: Player): boolean
	if not GearService.HasUnique(player, "Spireheart") then
		return false
	end
	local params = Affixes.GetUnique("Spireheart")
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not params or not humanoid or humanoid.MaxHealth <= 0 then
		return false
	end
	return humanoid.Health / humanoid.MaxHealth >= params.Params.HealthThreshold
end

local function tick(dt: number)
	local t = now()
	for player, state in states do
		local changed = false
		if state.OverflowUntil > 0 and t >= state.OverflowUntil then
			state.OverflowUntil = 0
			state.Saturation = 0
			state.BurnoutUntil = t + C.Burnout.Duration
			Net.Fire("Notify", player, "Toasts.Burnout", {}, "Warning")
			changed = true
		elseif state.BurnoutUntil > 0 and t >= state.BurnoutUntil then
			state.BurnoutUntil = 0
			changed = true
		end
		if state.Saturation > 0 and state.OverflowUntil == 0 and t - state.LastCastAt >= C.Saturation.DrainDelay then
			state.Saturation = math.max(0, state.Saturation - C.Saturation.DrainPerSecond * dt)
			changed = true
		end
		if state.Stacks > 0 and t - state.LastLinkAt >= decayDelay(player) and t >= state.NextDecayAt and not holdsResonance(player) then
			state.Stacks -= 1
			state.NextDecayAt = t + C.Resonance.DecayInterval
			changed = true
		end
		if state.Infusion ~= "" and t >= state.InfusedUntil then
			state.Infusion = ""
			state.InfusedUntil = 0
			changed = true
		end
		if changed then
			push(player, state)
		end
	end
end

function CurrentService.Start()
	-- Heavy on every blow taken; Resonance and low Pressure on weapon blows and Arts.
	CombatService.SetDamageModifiers(StatusService.DamageTakenMultiplier, function(attacker: Model, kind: string): number
		local player = Players:GetPlayerFromCharacter(attacker)
		if not player or toolOf(kind) ~= "Weapon" then
			return 1
		end
		return (1 + stateOf(player).Stacks * C.Resonance.DamagePerStack) * PressureService.MeleePower(player)
	end)
	-- Siphon: Draw (with gear), gear Siphon, Pressure and Infusion.
	CombatService.SetSiphonModifier(function(player: Player): number
		local scale = Formulas.SiphonPower(GearService.GetStats(player).Draw)
			* (1 + GearService.Bonus(player, "Siphon"))
			* PressureService.SiphonPower(player)
		if CurrentService.GetInfusion(player) then
			scale *= 1 + Config.Current.Infusion.SiphonBonus
		end
		return scale
	end)
	-- Regeneration: Pressure and pools/canals; nothing at all during Burnout.
	VitalsService.SetCurrentRegenModifier(function(player: Player): (number, number)
		if C.Burnout.StopsRegen and CurrentService.IsBurnedOut(player) then
			return 0, 0
		end
		return PressureService.RegenMultiplier(player), PressureService.SourceRegen(player)
	end)
	CombatService.HitLanded:Connect(onHitLanded)
	CombatService.Parried:Connect(onParried)

	local function track(player: Player)
		push(player, stateOf(player))
		player.CharacterAdded:Connect(function()
			local state = stateOf(player)
			state.Stacks = 0
			state.LastTool = nil
			state.Infusion = ""
			state.InfusedUntil = 0
			push(player, state)
		end)
	end
	Players.PlayerAdded:Connect(track)
	for _, player in Players:GetPlayers() do
		track(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		states[player] = nil
	end)
	RunService.Heartbeat:Connect(tick)
end

return CurrentService
