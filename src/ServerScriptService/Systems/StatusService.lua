--!strict
--[[
	StatusService
	Status effects from the Current (Config.Current.Status), on any combat
	target: enemies, dummies and players.

	  Soaked    slowed by SoakedSlow                       (Tide)
	  Chilled   stacks; ChilledStacksToFreeze stacks -> Frozen (Rime)
	  Frozen    stunned for FrozenStun
	  Shocked   Tempest hits on a Shocked target jump to nearby enemies (SpellService)
	  Heavy     takes HeavyDefenseDown more damage from everything (Abyss)
	  Rooted    can't move                                   (Bloom)
	  Renewing  heals RenewingHealPerSecond                  (Bloom Ward / Well)

	Each active status is mirrored to the target's model as an attribute
	"Status<Name>" holding the server time it ends (Attributes.Status), so
	clients can draw icons. Chilled stacks go in ChillStacks.

	Reactions: Consume(target, status) removes a status if present and says
	whether it was there; SpellService uses it to detonate a Reaction.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Spells = require(Shared.Data.Spells)

local TargetService = require(script.Parent.TargetService)
local CombatService = require(script.Parent.CombatService)
local VitalsService = require(script.Parent.VitalsService)

local A = Attributes.Names
local S = Config.Current.Status

export type Status = Spells.Status

local StatusService = {}

type Entry = { Until: number, Stacks: number }

local active: { [Model]: { [string]: Entry } } = {}

local DURATIONS: { [string]: number } = {
	Soaked = S.SoakedDuration,
	Chilled = S.ChilledDuration,
	Frozen = S.FrozenStun,
	Shocked = S.ShockedDuration,
	Heavy = S.HeavyDuration,
	Rooted = S.RootedDuration,
	Renewing = S.RenewingDuration,
}

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function mirror(model: Model, status: string, entry: Entry?)
	model:SetAttribute(Attributes.Status(status), if entry then entry.Until else nil)
	if status == "Chilled" then
		model:SetAttribute(A.ChillStacks, if entry then entry.Stacks else nil)
	end
end

local function remove(model: Model, status: string)
	local statuses = active[model]
	if statuses and statuses[status] then
		statuses[status] = nil
		mirror(model, status, nil)
	end
end

-- Applies (or refreshes) a status. Chilled stacks; at the threshold the
-- target freezes instead.
function StatusService.Apply(model: Model, status: string)
	local target = TargetService.Get(model)
	if not target or not TargetService.IsAlive(target) then
		return
	end
	local statuses = active[model]
	if not statuses then
		statuses = {}
		active[model] = statuses
	end
	local t = now()
	local existing = statuses[status]
	local stacks = if existing and existing.Until > t then existing.Stacks + 1 else 1
	if status == "Chilled" and stacks >= S.ChilledStacksToFreeze then
		remove(model, "Chilled")
		StatusService.Apply(model, "Frozen")
		return
	end
	local entry = { Until = t + (DURATIONS[status] or 3), Stacks = stacks }
	statuses[status] = entry
	mirror(model, status, entry)
	if status == "Frozen" then
		CombatService.Stun(model, S.FrozenStun)
	end
end

function StatusService.Has(model: Model, status: string): boolean
	local statuses = active[model]
	local entry = statuses and statuses[status]
	return entry ~= nil and entry.Until > now()
end

-- Removes a status; true if it was active (a Reaction detonated it).
function StatusService.Consume(model: Model, status: string): boolean
	local had = StatusService.Has(model, status)
	remove(model, status)
	return had
end

-- Movement multiplier from statuses (0 when Rooted or Frozen).
function StatusService.SpeedMultiplier(model: Model): number
	if StatusService.Has(model, "Rooted") or StatusService.Has(model, "Frozen") then
		return 0
	end
	if StatusService.Has(model, "Soaked") then
		return 1 - S.SoakedSlow
	end
	return 1
end

-- Damage taken multiplier (Heavy).
function StatusService.DamageTakenMultiplier(model: Model): number
	return if StatusService.Has(model, "Heavy") then 1 + S.HeavyDefenseDown else 1
end

local function tick(dt: number)
	local t = now()
	for model, statuses in active do
		if not model.Parent then
			active[model] = nil
			continue
		end
		for status, entry in statuses do
			if entry.Until <= t then
				statuses[status] = nil
				mirror(model, status, nil)
			elseif status == "Renewing" then
				local player = Players:GetPlayerFromCharacter(model)
				if player then
					VitalsService.Heal(player, S.RenewingHealPerSecond * dt)
				else
					local humanoid = model:FindFirstChildOfClass("Humanoid")
					if humanoid and humanoid.Health > 0 then
						humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + S.RenewingHealPerSecond * dt)
					end
				end
			end
		end
		if next(statuses) == nil then
			active[model] = nil
		end
	end
end

function StatusService.Start()
	TargetService.Removed:Connect(function(target: TargetService.Target)
		local statuses = active[target.Model]
		if statuses then
			for status in statuses do
				mirror(target.Model, status, nil)
			end
			active[target.Model] = nil
		end
	end)
	RunService.Heartbeat:Connect(tick)
end

return StatusService
