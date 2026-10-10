--!strict
--[[
	MapController
	The Map (M) and the minimap (Phase 11, docs/PHASE11_QUESTS.md; Spec Section 12).

	- FullMap: a full-screen menu page (UIController, "Immersive" layout) with the floor map, fog
	  of war, Waystones, quest markers, pins, a floor selector, and zoom / pan for mouse, touch and
	  gamepad.
	- Minimap: the round, rotating map at the top right under the Current Pressure pill.
	- Surface draws the floor (uploaded render or the region grid) and the fog; Points gathers the
	  markers; Icon draws them.
	Both views follow the replicated profile (Map, Waystones, Quests, Floors) and quest state.

	Waystone travel goes through RequestWaystoneTravel (FloorService re-checks everything);
	SetTravelHandler(fn) can replace the default handler.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)

local DataController = require(script.Parent.DataController)
local UIController = require(script.Parent.UIController)
local QuestController = require(script.Parent.QuestController)

local Surface = require(script.Surface)
local FullMap = require(script.FullMap)
local Minimap = require(script.Minimap)
local Extra = require(script.Extra)

local MapController = {}

MapController.MenuId = FullMap.MenuId

-- Plugs in Waystone fast travel: called with (fromWaystoneId, toWaystoneId) when the player
-- confirms Travel on the map while standing at a discovered Waystone. nil removes it.
function MapController.SetTravelHandler(handler: FullMap.TravelHandler?)
	FullMap.SetTravelHandler(handler)
end

function MapController.Open()
	if UIController.GetOpen() ~= FullMap.MenuId then
		UIController.Open(FullMap.MenuId)
	end
end

-- Live markers from other controllers (party members, pings) on the Map and the minimap.
-- `provider` returns the current markers and is called every map update; nil removes it.
export type ExtraMarker = Extra.Marker
function MapController.SetExtraMarkers(key: string, provider: Extra.Provider?)
	Extra.Set(key, provider)
end

-- The floor this server runs and world <-> map helpers, for other controllers.
MapController.CurrentFloor = Surface.CurrentFloor
MapController.Info = Surface.Info

local minimapQueued = false
local function queueMinimap()
	if minimapQueued then
		return
	end
	minimapQueued = true
	task.defer(function()
		minimapQueued = false
		Minimap.Refresh()
	end)
end

function MapController.Init()
	UIController.RegisterMenu({
		Id = FullMap.MenuId,
		Title = Strings.QuestUI.MapTitle,
		Action = "OpenMap",
		FullScreen = true,
		ShowInHub = true,
		Icon = "Recenter",
		Layout = "Immersive",
		Build = FullMap.Build,
	})
	Minimap.Init(MapController.Open)
end

function MapController.Start()
	for _, key in { "Map", "Waystones", "Floors" } do
		DataController.Observe({ key }, queueMinimap)
	end
	QuestController.Changed:Connect(queueMinimap)
	QuestController.WorldPoints.Changed:Connect(queueMinimap)
	queueMinimap()
	-- Fast travel: the server checks you stand at a discovered Waystone, the cooldown and combat.
	MapController.SetTravelHandler(function(_from: string, to: string)
		Net.FireServer("RequestWaystoneTravel", to)
		if UIController.GetOpen() == FullMap.MenuId then
			UIController.Close()
		end
	end)
end

return MapController
