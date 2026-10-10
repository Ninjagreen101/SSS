--!strict
--[[
	AchievementService
	Achievements (docs/PHASE11_QUESTS.md; Shared.Data.Achievements, decisions in Rules):

	- Counts GameEvents actions toward every locked achievement and keeps the counts in
	  Data.AchievementProgress (written only when a count moves). On join every locked achievement
	  is seeded from PlayStats and the level (Rules.Seed), so progress from before Phase 11 counts.
	- Unlocking: Data.Achievements[id] = unix time, the count is dropped, the Spire Shards are
	  granted (EconomyService.GrantShards) and AchievementUnlocked(id) tells the client.
	- Titles: RequestSetTitle(id) shows the title of an unlocked achievement that grants one ("" =
	  none). Data.Title keeps the achievement id; the player attribute Title carries the Strings
	  path ("Achievements.Titles.<id>") for every client's nameplates. Set again on every join.
	Nothing here trusts the client beyond "which unlocked title to wear".
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local Types = require(Shared.Types)
local Log = require(Shared.Util.Log)
local Achievements = require(Shared.Data.Achievements)

local GameEvents = require(script.Parent.GameEvents)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local AnalyticsService = require(script.Parent.AnalyticsService)
local Rules = require(script.Rules)

type PlayerData = Types.PlayerData

local A = Attributes.Names
local log = Log.new("AchievementService")

local AchievementService = {}

local function factsOf(data: PlayerData): Rules.Facts
	return { Stats = data.PlayStats :: any, Level = data.Level }
end

local function unlock(player: Player, id: string)
	local data = DataService.GetData(player)
	local def = Achievements.Get(id)
	if not data or not def or data.Achievements[id] ~= nil then
		return
	end
	-- Recorded before anything is granted, so the Shards can never be paid twice.
	DataService.Set(player, { "Achievements", id }, os.time())
	if data.AchievementProgress[id] ~= nil then
		DataService.Set(player, { "AchievementProgress", id }, nil)
	end
	EconomyService.GrantShards(player, def.Shards, "Achievement")
	AnalyticsService.Custom(player, "AchievementUnlocked")
	Net.Fire("AchievementUnlocked", player, id)
end

local function apply(player: Player, outcome: Rules.Outcome)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	for _, id in outcome.Progressed do
		DataService.Set(player, { "AchievementProgress", id }, data.AchievementProgress[id])
	end
	for _, id in outcome.Unlocked do
		unlock(player, id)
	end
end

local function onEvent(player: Player, kind: GameEvents.Kind, key: string, amount: number)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	apply(player, Rules.Feed(data.AchievementProgress, data.Achievements, kind, key, amount, factsOf(data)))
end

local function setTitleAttribute(player: Player, id: string)
	player:SetAttribute(A.Title, Rules.TitlePath(id))
end

local function onLoaded(player: Player)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	-- Drop counts for achievements that no longer exist or are already unlocked.
	for id in data.AchievementProgress do
		if not Achievements.Get(id) or data.Achievements[id] ~= nil then
			DataService.Set(player, { "AchievementProgress", id }, nil)
		end
	end
	apply(player, Rules.SeedAll(data.AchievementProgress, data.Achievements, factsOf(data)))
	-- A title whose achievement vanished (content change) is taken off.
	local title = data.Title
	if not Rules.CanWearTitle(title, data.Achievements) then
		title = ""
		DataService.Set(player, { "Title" }, title)
	end
	setTitleAttribute(player, title)
end

local function onSetTitle(player: Player, id: string)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	if not Rules.CanWearTitle(id, data.Achievements) then
		return
	end
	if data.Title ~= id then
		DataService.Set(player, { "Title" }, id)
	end
	setTitleAttribute(player, id)
end

-- PUBLIC API ---------------------------------------------------------------------------------

-- True once `player` has unlocked achievement `id`.
function AchievementService.IsUnlocked(player: Player, id: string): boolean
	local data = DataService.GetData(player)
	return data ~= nil and data.Achievements[id] ~= nil
end

function AchievementService.Init()
	Net.On("RequestSetTitle", onSetTitle)
end

function AchievementService.Start()
	GameEvents.Fired:Connect(onEvent)
	DataService.ProfileLoaded:Connect(function(player: Player)
		onLoaded(player)
	end)
	for _, player in Players:GetPlayers() do
		if DataService.IsLoaded(player) then
			task.spawn(onLoaded, player)
		end
	end
	log:Debug(`{#Achievements.Ordered()} achievements`)
end

return AchievementService
