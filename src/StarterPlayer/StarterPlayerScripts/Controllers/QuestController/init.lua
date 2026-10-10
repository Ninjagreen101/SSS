--!strict
--[[
	QuestController
	Quests on the client (Phase 11, docs/PHASE11_QUESTS.md). The server owns quest state; it
	replicates through DataController (profile Quests) and QuestEvent carries the moments.

	- Quest Log (J): a tab of the Character window (Log).
	- HUD tracker on the right, under the minimap (Tracker).
	- World markers: "!" / "?" over NPCs and a light pillar at the focused objective (Markers).
	- Toasts and sounds on QuestEvent: Accepted, Progress (throttled per quest), Ready, Completed
	  (a banner with the rewards).
	State helpers (State) and marker positions (WorldPoints) are shared with DialogueController
	and MapController.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Quests = require(Shared.Data.Quests)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local UISound = require(UI.UISound)
local Banner = require(UI.Banner)
local QuestText = require(UI.QuestText)
local Components = require(UI.Components)

local DataController = require(script.Parent.DataController)
local UIController = require(script.Parent.UIController)

local State = require(script.State)
local WorldPoints = require(script.WorldPoints)
local Log = require(script.Log)
local Tracker = require(script.Tracker)
local Markers = require(script.Markers)

local QT = UITheme.Quests
local Q = Strings.QuestUI

local QuestController = {}

QuestController.State = State
QuestController.WorldPoints = WorldPoints
QuestController.MenuId = Log.MenuId

-- Fired (at most once a frame) after quest state changes.
QuestController.Changed = Signal.new() :: Signal.Signal<>

local refreshQueued = false
local lastProgressToast: { [string]: number } = {}

-- Opens the Quest Log, on a quest if given.
function QuestController.OpenLog(questId: string?)
	Log.Open(questId)
end

-- Every active quest's current marker: { QuestId, Marker, Tracked, TurnIn }.
export type ActiveMarker = { QuestId: string, Marker: string, Tracked: boolean, TurnIn: boolean }

function QuestController.ActiveMarkers(): { ActiveMarker }
	local out: { ActiveMarker } = {}
	local tracked = State.Tracked()
	for _, id in State.ActiveIds() do
		local marker, turnIn = State.Marker(id)
		if marker then
			table.insert(out, { QuestId = id, Marker = marker, Tracked = id == tracked, TurnIn = turnIn })
		end
	end
	return out
end

local function refreshAll()
	refreshQueued = false
	Tracker.Refresh()
	Markers.RefreshNpcs()
	Markers.RefreshObjective()
	QuestController.Changed:Fire()
end

local function queueRefresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	task.defer(refreshAll)
end

-- TOASTS -----------------------------------------------------------------------------------

local function progressToast(questId: string, payload: any)
	local now = os.clock()
	if now - (lastProgressToast[questId] or 0) < QT.ProgressToastInterval then
		return
	end
	lastProgressToast[questId] = now
	-- The state change may land a moment after the event: read it on the next frame.
	task.defer(function()
		local def = Quests.Get(questId)
		if not def then
			return
		end
		local index = if type(payload) == "table" and type(payload.Index) == "number" then payload.Index else State.CurrentObjective(questId)
		if not index or not def.Objectives[index] then
			return
		end
		local done, needed = State.Progress(questId, index)
		Components.Toast.Push({
			Title = `{QuestText.Objective(questId, index)}  <font color="#9DB2CA">{Strings.Format(Q.Progress, { done = done, total = needed })}</font>`,
			Body = QuestText.QuestName(questId),
			Color = QuestText.KindColor(def.Kind),
			Duration = 2.5,
			Silent = true,
		})
		UISound.Play("ItemPickup")
		Tracker.Flash(questId)
	end)
end

local function onQuestEvent(kind: any, questId: any, payload: any)
	if type(kind) ~= "string" or type(questId) ~= "string" then
		queueRefresh()
		return
	end
	local def = Quests.Get(questId)
	local name = QuestText.QuestName(questId)
	local color = if def then QuestText.KindColor(def.Kind) else UITheme.Colors.Aqua
	if kind == "Accepted" then
		UISound.Play("UIConfirm")
		local summary = QuestText.QuestSummary(questId)
		Components.Toast.Push({
			Title = Strings.Format(Q.Accepted, { name = name }),
			Body = if summary ~= "" then summary else nil,
			Color = color,
			Duration = 5,
		})
	elseif kind == "Progress" then
		progressToast(questId, payload)
	elseif kind == "Ready" then
		UISound.Play("RareLoot")
		local turnIn = def and def.TurnIn
		Components.Toast.Push({
			Title = if turnIn then Strings.Format(Q.ReturnTo, { name = QuestText.NpcName(turnIn) }) else Q.Ready,
			Body = name,
			Color = QT.Ready,
			Duration = 5,
		})
		task.defer(Tracker.Flash, questId)
	elseif kind == "Completed" then
		UISound.Play("LevelUp")
		task.delay(0.15, function()
			UISound.Play("LevelUpHigh")
		end)
		Banner.Show({
			Eyebrow = Q.Completed,
			Title = name,
			Subtitle = QuestText.Rewards(questId),
			Color = color,
		})
	end
	queueRefresh()
end

-- LIFECYCLE --------------------------------------------------------------------------------

function QuestController.Init()
	UIController.RegisterMenu({
		Id = Log.MenuId,
		Title = Q.LogTitle,
		Action = "OpenQuestLog",
		FullScreen = true,
		ShowInHub = true,
		Icon = "Quests",
		Nav = "Journal",
		Build = Log.Build,
	})
	Tracker.Init(Log.Open)
	Markers.Init()
	Net.OnClient("QuestEvent", onQuestEvent)
end

function QuestController.Start()
	WorldPoints.Start()
	DataController.Observe({ "Quests" }, queueRefresh)
	-- Requirements and levels change what NPCs offer.
	DataController.Observe({ "Level" }, queueRefresh)
	queueRefresh()
end

return QuestController
