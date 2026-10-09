--!strict
--[[
	CraftingService
	Terraria-style crafting at stations (Spec Section 11).

	Craft request -> checks (station in reach, recipe known, materials and
	fee on hand) -> a short timed job with a progress ring on the client ->
	the transaction runs (fee and materials out, item in) -> the client
	reveals the item in its rarity colour.

	Nothing is taken until the job finishes, and the transaction re-checks
	everything, so selling materials mid-craft or walking away (the job is
	cancelled if you leave the station's reach or die) can't cheat a recipe.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Recipes = require(Shared.Data.Recipes)
local Rules = require(Shared.Data.InventoryRules)

local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local EconomyService = require(script.Parent.EconomyService)

type PlayerData = Types.PlayerData

type Job = {
	StationId: string,
	Recipe: Recipes.Recipe,
	EndsAt: number,
	Character: Model?,
}

local A = Attributes.Names

local CraftingService = {}

local jobs: { [Player]: Job } = {}
local random = Random.new()

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function begin(player: Player, station: Instance, recipeId: string)
	local recipe = Recipes.Get(recipeId)
	if not recipe then
		InventoryService.Result(player, false, "Invalid", { Action = "Craft" })
		return
	end
	if EconomyService.KindOf(station) ~= recipe.Station then
		InventoryService.Result(player, false, "WrongStation", { Action = "Craft" })
		return
	end
	if jobs[player] then
		InventoryService.Result(player, false, "Busy", { Action = "Craft" })
		return
	end
	local data = DataService.GetData(player)
	if not data then
		return
	end
	local ok, reason = Rules.CanCraft(data, recipeId)
	if not ok then
		InventoryService.Result(player, false, reason, { Action = "Craft", Recipe = recipeId })
		return
	end
	local stationId = station:GetAttribute(A.StationId)
	local job: Job = {
		StationId = if type(stationId) == "string" then stationId else "",
		Recipe = recipe,
		EndsAt = now() + Config.Items.Crafting.Seconds,
		Character = player.Character,
	}
	jobs[player] = job
	Net.Fire("CraftState", player, "Start", recipeId, job.EndsAt)
end

local function cancel(player: Player, job: Job)
	jobs[player] = nil
	Net.Fire("CraftState", player, "End", job.Recipe.Id, 0)
	InventoryService.Result(player, false, "Cancelled", { Action = "Craft", Recipe = job.Recipe.Id })
end

local function finish(player: Player, job: Job)
	jobs[player] = nil
	Net.Fire("CraftState", player, "End", job.Recipe.Id, 0)
	local made: Types.ItemInstance? = nil
	local ok, reason = InventoryService.Transact(player, function(draft: PlayerData): (boolean, string?)
		local before: { [string]: boolean } = {}
		for uid in draft.Inventory.Items do
			before[uid] = true
		end
		local crafted, why = Rules.Craft(draft, job.Recipe.Id, random)
		if crafted then
			-- The new copy (or the stack it joined) for the reveal.
			for uid, item in draft.Inventory.Items do
				if item.DefId == job.Recipe.Output and (not before[uid] or made == nil) then
					made = item
				end
			end
		end
		return crafted, why
	end)
	local item = made :: Types.ItemInstance?
	InventoryService.Result(player, ok, reason, {
		Action = "Craft",
		Recipe = job.Recipe.Id,
		DefId = job.Recipe.Output,
		Count = job.Recipe.Count,
		Rarity = if item then item.Rarity else nil,
		Uid = if item then item.Uid else nil,
	})
end

function CraftingService.Init()
	EconomyService.SetCraftingHandler(begin)
end

function CraftingService.Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		jobs[player] = nil
	end)
	RunService.Heartbeat:Connect(function()
		if next(jobs) == nil then
			return
		end
		local t = now()
		for player, job in jobs do
			if player.Character ~= job.Character or not EconomyService.StationFor(player, job.StationId) then
				cancel(player, job)
			elseif t >= job.EndsAt then
				finish(player, job)
			end
		end
	end)
end

return CraftingService
