--!strict
--[[
	Migrations
	Upgrades saved profiles from older DataVersions to the current one.

	How to change the save schema:
	  1. Bump Config.Data.DataVersion (e.g. 1 -> 2).
	  2. Add Steps[2] = function(data) ... end that converts a version-1
	     profile into a version-2 profile (rename/move/convert fields).
	  3. Update Template and Types to the new shape.
	Purely additive fields need no step body beyond the version bump, because
	Reconcile fills them from the Template after migrations run.

	Migrations run on the raw saved data BEFORE Reconcile, so DataVersion
	reflects what was actually saved.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Recipes = require(Shared.Data.Recipes)

export type Step = (data: { [string]: any }) -> ()

local Migrations = {}

-- Steps[n] upgrades data from version n - 1 to version n.
Migrations.Steps = {} :: { [number]: Step }

-- v2 (first Phase 7 draft): item bookkeeping branch.
Migrations.Steps[2] = function(data: { [string]: any })
	if type(data.ItemState) ~= "table" then
		data.ItemState = { StarterGranted = false, Pity = {}, Buyback = {}, NextBuyback = 1, TrackedRecipe = "" }
	end
end

-- v3 (Phase 7): ItemState gains SeenItems; the v2 draft stored a unique
-- effect as UniqueEffect, now Unique. Known recipes that no longer exist are
-- dropped (Default and key-material recipes are re-learned on load).
Migrations.Steps[3] = function(data: { [string]: any })
	local state = data.ItemState
	if type(state) ~= "table" then
		state = {}
		data.ItemState = state
	end
	if type(state.SeenItems) ~= "table" then
		state.SeenItems = {}
	end
	if type(state.Pity) ~= "table" then
		state.Pity = {}
	end
	if type(state.Buyback) ~= "table" then
		state.Buyback = {}
	end
	for _, branch in { "Inventory", "Bank" } do
		local items = type(data[branch]) == "table" and data[branch].Items
		if type(items) == "table" then
			for _, item in items do
				if type(item) == "table" then
					if item.UniqueEffect ~= nil then
						item.Unique = item.UniqueEffect
						item.UniqueEffect = nil
					end
					if type(item.DefId) == "string" then
						state.SeenItems[item.DefId] = true
					end
				end
			end
		end
	end
	if type(data.RecipesKnown) == "table" then
		for id in data.RecipesKnown do
			if not Recipes.Get(id) then
				data.RecipesKnown[id] = nil
			end
		end
	end
end

export type Result = "Ok" | "Newer" | "Failed"

-- Brings `data` up to the current DataVersion in place.
-- Returns "Newer" if the data was saved by a newer server build (the player
-- must not load it here or this older server would drop unknown fields).
function Migrations.Run(data: { [string]: any }): (Result, string?)
	local current = Config.Data.DataVersion
	local version = data.DataVersion
	if type(version) ~= "number" then
		-- Profiles are always created from the Template, so a missing version
		-- can only mean a brand-new or externally edited profile.
		version = current
	end
	if version > current then
		return "Newer", `saved version {version} > server version {current}`
	end
	for target = version + 1, current do
		local step = Migrations.Steps[target]
		if not step then
			return "Failed", `missing migration step to version {target}`
		end
		local ok, err = pcall(function(): any
			step(data)
			return nil
		end)
		if not ok then
			return "Failed", `migration to {target} errored: {tostring(err)}`
		end
		data.DataVersion = target
	end
	data.DataVersion = current
	return "Ok"
end

-- v4 (Phase 8): the Position ability key (Hotbar.Ability). Older drafts
-- could leave Position / SkillTree with the wrong type; they're reset (with
-- the points refunded on load by ProgressionRules.Repair).
Migrations.Steps[4] = function(data: { [string]: any })
	if type(data.Hotbar) == "table" and type(data.Hotbar.Ability) ~= "string" then
		data.Hotbar.Ability = ""
	end
	if type(data.Position) ~= "string" then
		data.Position = ""
	end
	if type(data.SkillTree) ~= "table" then
		data.SkillTree = {}
	end
end

-- v5 (Phase 10): Floors.IntrosSeen (Guardian intros become skippable after the first view).
-- Additive; a malformed value from an old draft is replaced (Reconcile fills a missing one).
Migrations.Steps[5] = function(data: { [string]: any })
	local floors = data.Floors
	if type(floors) == "table" and floors.IntrosSeen ~= nil and type(floors.IntrosSeen) ~= "table" then
		floors.IntrosSeen = {}
	end
end

-- v6 (Phase 11): Quests gain Dailies / Weeklies / Rerolls and their Progress is keyed by objective
-- index as a string ("1", "2", ...); new Map and AchievementProgress branches; Tutorial becomes
-- { Step, Done, Skipped }. A profile saved before v6 belongs to someone who has already played, so
-- its tutorial is marked done and the docks never pull a veteran back. Malformed branches are
-- dropped here and refilled from the Template by Reconcile.
Migrations.Steps[6] = function(data: { [string]: any })
	local quests = data.Quests
	if type(quests) ~= "table" then
		quests = {}
		data.Quests = quests
	end
	for _, key in { "Active", "Completed", "Dailies", "Weeklies" } do
		if quests[key] ~= nil and type(quests[key]) ~= "table" then
			quests[key] = nil
		end
	end
	if quests.Rerolls ~= nil and type(quests.Rerolls) ~= "number" then
		quests.Rerolls = nil
	end
	if type(quests.Active) == "table" then
		for id, state in quests.Active do
			if type(state) ~= "table" then
				quests.Active[id] = nil
				continue
			end
			local fixed: { [string]: number } = {}
			if type(state.Progress) == "table" then
				for key, value in state.Progress do
					local index = tonumber(key)
					if type(value) == "number" and index and index >= 1 and index % 1 == 0 then
						fixed[tostring(index)] = value
					end
				end
			end
			state.Progress = fixed
			if type(state.Stage) ~= "number" then
				state.Stage = 1
			end
			if type(state.StartedAt) ~= "number" then
				state.StartedAt = 0
			end
		end
	end
	for _, branch in { "Map", "AchievementProgress" } do
		if data[branch] ~= nil and type(data[branch]) ~= "table" then
			data[branch] = nil
		end
	end

	-- New profiles start from the Template at the current version and never run this step, so
	-- every profile here was saved by an earlier build: its owner has played.
	local old = data.Tutorial
	local skipped = type(old) == "table" and old.Skipped == true
	data.Tutorial = { Step = 0, Done = true, Skipped = skipped }
end

-- v7 (Phase 12): the Social branch (Company, emote wheel, party loot preference, blocked list) is
-- new; Reconcile adds it from the Template. A malformed one is dropped so Reconcile refills it.
Migrations.Steps[7] = function(data: { [string]: any })
	if data.Social ~= nil and type(data.Social) ~= "table" then
		data.Social = nil
	end
end

-- v8 (Phase 12 review): PendingReturn, the way home from a reserved run, now lives in the profile
-- (teleport data can be forged by a client). Additive; a malformed one is dropped so Reconcile
-- refills it from the Template.
Migrations.Steps[8] = function(data: { [string]: any })
	local pending = data.PendingReturn
	if pending ~= nil and (type(pending) ~= "table" or type(pending.To) ~= "string" or type(pending.At) ~= "number") then
		data.PendingReturn = nil
	end
end

return Migrations
