--!strict
--[[
	Server bootstrap: the only server Script in the game.
	1. Creates every remote (Net.Init).
	2. Requires each system in a fixed order and calls Init() on all of them
	   (wire references, connect remotes; must not yield).
	3. Calls Start() on all of them (begin running; may spawn loops).
	A system that errors is reported, but the rest still start so one bug
	can't take the whole server down.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Log = require(Shared.Util.Log)

local log = Log.new("Server")

type System = {
	Init: (() -> ())?,
	Start: (() -> ())?,
}

-- Fixed start order: dependencies first.
local ORDER = {
	"AnalyticsService",
	"AntiExploitService",
	"DataService",
	"GearService",
	"VitalsService",
	"FloorService",
	"EnvironmentService",
	"TargetService",
	"WeaponService",
	"CharacterService",
	"CombatService",
	"StatusService",
	"PressureService",
	"CurrentService",
	"ProjectileService",
	"ProgressionService",
	"MobService",
	"SpellService",
	"BeaconService",
	"ArtService",
	"InventoryService",
	"EconomyService",
	"PositionService",
	"CraftingService",
	"LootService",
	"GearEffectsService",
	"TrainingService",
	"SecretService",
	"DungeonService",
	"GuardianService",
	"DevService",
}

Net.Init()

local systemsFolder = ServerScriptService:WaitForChild("Systems")
local systems: { { Name: string, Module: System } } = {}

for _, name in ORDER do
	local moduleScript = systemsFolder:FindFirstChild(name)
	if not moduleScript or not moduleScript:IsA("ModuleScript") then
		log:Error(`Missing system module {name}`)
		continue
	end
	local ok, result = pcall(require, moduleScript)
	if ok then
		table.insert(systems, { Name = name, Module = result :: System })
	else
		log:Error(`{name} failed to load: {tostring(result)}`)
	end
end

local function runPhase(phase: "Init" | "Start")
	for _, entry in systems do
		local fn = entry.Module[phase]
		if fn then
			local started = os.clock()
			local ok, err = xpcall(fn, debug.traceback)
			if not ok then
				log:Error(`{entry.Name}.{phase} failed: {tostring(err)}`)
			end
			local elapsed = os.clock() - started
			if phase == "Init" and elapsed > 0.05 then
				log:Warn(`{entry.Name}.Init took {string.format("%.0f", elapsed * 1000)} ms (Init should not yield)`)
			end
		end
	end
end

runPhase("Init")
runPhase("Start")
log:Info(`Started {#systems} systems`)
