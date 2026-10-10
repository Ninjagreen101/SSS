--!strict
--[[
	AchievementService Rules
	The pure achievement decisions (Shared.Data.Achievements), with no Roblox services, so the Lune
	simulation (tools/place/sim_quests.luau) runs exactly what the server runs.

	Counting: an achievement counts the GameEvents of its Event whose key matches its Key
	(Data/Quests.KeyMatches: "" = any key, "Prefix:*" = any key with that prefix). Most kinds add
	the event's amount; LevelUp and Resonance keep the highest value seen and Combo counts full
	combos (as quests do). An achievement with a Stat also reads that PlayStats field (bumped by the
	same system that fires the event), so progress made before Phase 11 still counts: the count is
	never below the stat. Seed gives the count from the profile alone (on join).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Quests = require(Shared.Data.Quests)
local Achievements = require(Shared.Data.Achievements)

type AchievementDef = Achievements.AchievementDef

-- What a count can be seeded from: PlayStats fields and the player's level.
export type Facts = {
	Stats: { [string]: number },
	Level: number,
}

-- The outcome of one action: achievements that unlocked and those whose count moved (not unlocked).
export type Outcome = {
	Unlocked: { string },
	Progressed: { string },
}

local Rules = {}

-- Does this achievement count GameEvents (kind, key)?
function Rules.Matches(def: AchievementDef, kind: string, key: string): boolean
	if def.Event ~= kind then
		return false
	end
	-- LevelUp has no key: its amount (the new level) is what counts.
	return kind == "LevelUp" or Quests.KeyMatches(def.Key, key)
end

local function statOf(def: AchievementDef, facts: Facts): number
	local stat = def.Stat
	local value = if stat then facts.Stats[stat] else nil
	return if type(value) == "number" and value == value then math.max(0, math.floor(value)) else 0
end

-- The count from the profile alone: the Stat, or the level for LevelUp achievements.
function Rules.Seed(def: AchievementDef, current: number, facts: Facts): number
	local count = math.max(current, statOf(def, facts))
	if def.Event == "LevelUp" then
		count = math.max(count, facts.Level)
	end
	return count
end

-- The count after one matching event of `amount`.
function Rules.Next(def: AchievementDef, current: number, amount: number, facts: Facts): number
	local kind = def.Event
	local count: number
	if kind == "LevelUp" or kind == "Resonance" then
		count = math.max(current, amount)
	elseif kind == "Combo" then
		count = current + 1
	else
		count = current + math.max(0, amount)
	end
	return math.max(count, statOf(def, facts))
end

-- Ids in display order, so unlocks always come out in the same order.
local function ordered(): { string }
	return Achievements.Ordered()
end

-- Feeds one GameEvents action. `progress` (id -> count) is updated in place for achievements that
-- moved but didn't unlock; unlocked ones are left for the caller to record (and drop from
-- progress). `unlocked` (id -> unix time) is read only.
function Rules.Feed(
	progress: { [string]: number },
	unlocked: { [string]: number },
	kind: string,
	key: string,
	amount: number,
	facts: Facts
): Outcome
	local outcome: Outcome = { Unlocked = {}, Progressed = {} }
	for _, id in ordered() do
		local def = Achievements.Get(id)
		if not def or unlocked[id] ~= nil or not Rules.Matches(def, kind, key) then
			continue
		end
		local before = progress[id] or 0
		local after = Rules.Next(def, before, amount, facts)
		if after >= def.Count then
			table.insert(outcome.Unlocked, id)
		elseif after ~= before then
			progress[id] = after
			table.insert(outcome.Progressed, id)
		end
	end
	return outcome
end

-- Seeds every locked achievement from the profile (on join). Same contract as Feed.
function Rules.SeedAll(progress: { [string]: number }, unlocked: { [string]: number }, facts: Facts): Outcome
	local outcome: Outcome = { Unlocked = {}, Progressed = {} }
	for _, id in ordered() do
		local def = Achievements.Get(id)
		if not def or unlocked[id] ~= nil then
			continue
		end
		local before = progress[id] or 0
		local after = Rules.Seed(def, before, facts)
		if after >= def.Count then
			table.insert(outcome.Unlocked, id)
		elseif after ~= before then
			progress[id] = after
			table.insert(outcome.Progressed, id)
		end
	end
	return outcome
end

-- May `id` be shown as a title? "" (no title) always may.
function Rules.CanWearTitle(id: string, unlocked: { [string]: number }): boolean
	if id == "" then
		return true
	end
	local def = Achievements.Get(id)
	return def ~= nil and def.Title == true and unlocked[id] ~= nil
end

-- The player attribute Title for an achievement id: a Strings path, or "".
function Rules.TitlePath(id: string): string
	return if id == "" then "" else `Achievements.Titles.{id}`
end

return Rules
