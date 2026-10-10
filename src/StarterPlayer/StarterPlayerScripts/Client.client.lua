--!strict
--[[
	Client bootstrap: the only LocalScript in the game.
	1. Waits for the remotes (Net.Init).
	2. Requires each controller in a fixed order, calls every Init() (wire
	   up listeners; must not yield), then every Start() (begin running).
	DataController.Start sends ClientReady last-but-not-least, so every
	controller is already listening when the data snapshot arrives.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Log = require(Shared.Util.Log)

local log = Log.new("Client")

type Controller = {
	Init: (() -> ())?,
	Start: (() -> ())?,
}

-- Fixed order: dependencies first. DataController must Start after the
-- others have connected (it fires ClientReady), so it is listed last.
local ORDER = {
	"InputController",
	"UIController",
	"CameraController",
	"EnvironmentController",
	"CanalFishController",
	"CharacterController",
	"HUDController",
	"TutorialController", -- docks onboarding prompts (Phase 11)
	"DeathController",
	"InteractionController",
	"VFXController",
	"SprintVFXController",
	"CombatFeedbackController",
	"LockOnController",
	"CombatController",
	"GuardPoseController",
	"MobController",
	"SpellController",
	"SpellVFXController",
	"ArtController",
	"ArtVFXController",
	"BeaconController",
	-- Guardian fights (Phase 10): telegraphs, music layers, then the fight UI that uses them.
	"TelegraphController",
	"MusicController",
	"GuardianController",
	-- Character window tabs, in tab order (the menu hub lists them this way).
	"CharacterSheetController",
	"InventoryController",
	"SpellbookController",
	"StationController",
	"LootController",
	"ItemHUDController",
	"ProgressionController",
	"SkillTreeController",
	"DevGalleryController",
	-- Quests, achievements, NPC talk, nameplates and the map (Phase 11).
	"QuestController",
	"AchievementController",
	"DialogueController",
	"NameplateController",
	"MapController",
	"DataController",
}

Net.Init()

local folder = script.Parent:WaitForChild("Controllers")
local controllers: { { Name: string, Module: Controller } } = {}

for _, name in ORDER do
	local moduleScript = folder:WaitForChild(name, 10)
	if not moduleScript or not moduleScript:IsA("ModuleScript") then
		log:Error(`Missing controller {name}`)
		continue
	end
	local ok, result = pcall(require, moduleScript)
	if ok then
		table.insert(controllers, { Name = name, Module = result :: Controller })
	else
		log:Error(`{name} failed to load: {tostring(result)}`)
	end
end

local function runPhase(phase: "Init" | "Start")
	for _, entry in controllers do
		local fn = entry.Module[phase]
		if fn then
			local ok, err = xpcall(fn, debug.traceback)
			if not ok then
				log:Error(`{entry.Name}.{phase} failed: {tostring(err)}`)
			end
		end
	end
end

runPhase("Init")
runPhase("Start")
log:Debug(`Started {#controllers} controllers`)
