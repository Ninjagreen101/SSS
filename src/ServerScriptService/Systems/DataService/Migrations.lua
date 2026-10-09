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

return Migrations
