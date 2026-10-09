--!strict
--[[
	GearService
	The server's answer to "what does this player's gear give them?".

	Wraps Shared/Data/GearStats with a per-player cache that is marked dirty
	whenever the profile's equipment, bag, stats, level or Beacon core
	change, and rebuilt on the next read. Every system that cares asks here:

	  GetStats(player)        base stat points + gear points (use instead of data.Stats)
	  Bonus(player, id)       a summed bonus, e.g. Bonus(p, "WeaponDamage") = 0.07
	  Armor(player)           damage reduction from armour pieces
	  HasUnique(player, id)   a unique named effect is equipped (GearEffectsService)

	Food buffs (Marsh Stew...) are session-only bonus tables with an end
	time; they show on the HUD through the Buffs attribute.

	Also keeps player attributes in sync for clients: Overburdened (bag
	over carry weight), BeaconCore (slotted core item id, recolours orbs) and
	SpeedBonus (the MoveSpeed bonus; the client walks faster and movement
	checks allow it). Ability buffs (Phase 8) use the same buff table as food.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Attributes)
local Types = require(Shared.Types)
local GearStats = require(Shared.Data.GearStats)
local Signal = require(Shared.Util.Signal)

local DataService = require(script.Parent.DataService)

local A = Attributes.Names

type Buff = { EndsAt: number, Bonuses: { [string]: number } }
type State = {
	Dirty: boolean,
	Summary: GearStats.Summary?,
	Buffs: { [string]: Buff },
	NotifyQueued: boolean,
}

local GearService = {}

-- Fired (deferred, at most once per frame) after a player's gear numbers change.
GearService.Changed = Signal.new() :: Signal.Signal<Player>

local states: { [Player]: State } = {}

local ZERO_STATS: Types.StatBlock = table.freeze({
	Vitality = 0,
	Endurance = 0,
	Strength = 0,
	Finesse = 0,
	Draw = 0,
	Density = 0,
	Control = 0,
})

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function stateOf(player: Player): State
	local state = states[player]
	if not state then
		state = { Dirty = true, Summary = nil, Buffs = {}, NotifyQueued = false }
		states[player] = state
	end
	return state
end

local function buffAttribute(state: State): string
	local parts = {}
	for id, buff in state.Buffs do
		table.insert(parts, `{id}:{math.floor(buff.EndsAt)}`)
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

-- Rebuilds the cache if needed and returns it (nil before the profile loads).
local function summary(player: Player): GearStats.Summary?
	local state = stateOf(player)
	if state.Dirty or not state.Summary then
		local data = DataService.GetData(player)
		if not data then
			return nil
		end
		local buffs = {}
		for _, buff in state.Buffs do
			table.insert(buffs, buff.Bonuses)
		end
		local result = GearStats.Summarize(data, buffs)
		state.Summary = result
		state.Dirty = false
		player:SetAttribute(A.Overburdened, result.Weight > result.MaxWeight)
		player:SetAttribute(A.BeaconCore, data.Beacons.Skin)
		player:SetAttribute(A.Buffs, buffAttribute(state))
		player:SetAttribute(A.SpeedBonus, result.Bonuses.MoveSpeed or 0)
	end
	return state.Summary
end

-- Marks the cache stale and tells listeners once, after this frame's changes.
local function invalidate(player: Player)
	local state = stateOf(player)
	state.Dirty = true
	if state.NotifyQueued then
		return
	end
	state.NotifyQueued = true
	task.defer(function()
		state.NotifyQueued = false
		if player.Parent == Players then
			summary(player) -- refresh attributes even if nobody reads this frame
			GearService.Changed:Fire(player)
		end
	end)
end

-- PUBLIC API -------------------------------------------------------------------

function GearService.GetSummary(player: Player): GearStats.Summary?
	return summary(player)
end

function GearService.GetStats(player: Player): Types.StatBlock
	local result = summary(player)
	return if result then result.Stats else ZERO_STATS
end

function GearService.Bonus(player: Player, id: string): number
	local result = summary(player)
	return if result then result.Bonuses[id] or 0 else 0
end

function GearService.Armor(player: Player): number
	local result = summary(player)
	return if result then result.Armor + (result.Bonuses.Armor or 0) else 0
end

function GearService.HasUnique(player: Player, id: string): boolean
	local result = summary(player)
	return result ~= nil and result.Uniques[id] == true
end

function GearService.IsOverburdened(player: Player): boolean
	local result = summary(player)
	return result ~= nil and result.Weight > result.MaxWeight
end

-- Starts or refreshes a timed buff (food, abilities; one per id).
function GearService.AddBuff(player: Player, id: string, bonuses: { [string]: number }, duration: number)
	stateOf(player).Buffs[id] = { EndsAt = now() + duration, Bonuses = bonuses }
	invalidate(player)
end

function GearService.Invalidate(player: Player)
	invalidate(player)
end

-- LIFECYCLE --------------------------------------------------------------------

local WATCHED: { [string]: boolean } = {
	Inventory = true,
	Equipped = true,
	Stats = true,
	Level = true,
	Beacons = true,
	Position = true,
	SkillTree = true,
}

function GearService.Start()
	DataService.ProfileLoaded:Connect(function(player: Player)
		invalidate(player)
	end)
	DataService.Changed:Connect(function(player: Player, path: { string })
		if WATCHED[path[1]] then
			invalidate(player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		states[player] = nil
	end)

	-- Expire food buffs (checked twice a second; cheap).
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < 0.5 then
			return
		end
		accumulator = 0
		local t = now()
		for player, state in states do
			local expired = false
			for id, buff in state.Buffs do
				if t >= buff.EndsAt then
					state.Buffs[id] = nil
					expired = true
				end
			end
			if expired then
				invalidate(player)
			end
		end
	end)
end

return GearService
