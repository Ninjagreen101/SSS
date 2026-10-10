--!strict
--[[
	FloorService
	Floor identity and Waystones (bonfire-style checkpoints).

	Waystones are Models in the world tagged "Waystone" with a WaystoneId
	attribute (display names live in Strings.Waystones). One may carry
	DefaultWaystone = true: new Climbers start there. A child BasePart named
	"SpawnPoint" marks where players rise; otherwise the model pivot is used.

	- Discover: walking within DiscoverRadius records the Waystone.
	- Rest: holding Interact at a Waystone (server ProximityPrompt) sets it
	  as your respawn point and fully restores health, stamina and Current.
	- Respawn position: last rested Waystone -> default Waystone -> any
	  SpawnLocation -> world origin.

	- Fast travel (Phase 11, from the map): standing within TravelRadius of a
	  discovered Waystone, RequestWaystoneTravel(targetId) moves you to another
	  discovered one on this floor. Refused in combat (TravelCombatLock),
	  during the tutorial, and within TravelCooldown of the last trip.

	- Reserved instances (Phase 12, InstanceService): in an instance server the
	  run's owner sets a run spawn (SetRunSpawn) and may hold respawns
	  (SetSpawnHold); members always rise in the run, never on the floor, and
	  can't fast travel. In a public server, a player coming home from a run
	  rises once at its ReturnTo: a dungeon's exit Waystone or a Guardian
	  gate's Return point (anything else is ignored).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local Log = require(Shared.Util.Log)

local DataService = require(script.Parent.DataService)
local VitalsService = require(script.Parent.VitalsService)
local AnalyticsService = require(script.Parent.AnalyticsService)
local ProgressionService = require(script.Parent.ProgressionService)
local GameEvents = require(script.Parent.GameEvents)
local InstanceService = require(script.Parent.InstanceService)

local A = Attributes.Names
local log = Log.new("FloorService")

type Waystone = {
	Id: string,
	Model: Model,
	IsDefault: boolean,
	Prompt: ProximityPrompt?,
}

local FloorService = {}

local waystones: { [string]: Waystone } = {}
local floorId = "1"
local lastTravel: { [Player]: number } = {}
local runSpawn: ((Player) -> CFrame?)? = nil
local spawnHold: ((Player) -> boolean)? = nil

local function displayName(id: string): string
	return Strings.Waystones[id] or id
end

local function spawnCFrame(waystone: Waystone): CFrame
	local marker = waystone.Model:FindFirstChild("SpawnPoint")
	local base = if marker and marker:IsA("BasePart") then marker.CFrame else waystone.Model:GetPivot()
	return base + Vector3.new(0, Config.World.Waystones.SpawnHeight, 0)
end

local function waystonePosition(waystone: Waystone): Vector3
	return waystone.Model:GetPivot().Position
end

local function rest(player: Player, waystone: Waystone)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local data = DataService.GetData(player)
	if not data then
		return
	end
	if not data.Waystones.Discovered[waystone.Id] then
		DataService.Set(player, { "Waystones", "Discovered", waystone.Id }, true)
		ProgressionService.AwardDiscovery(player, "Waystone")
		GameEvents.Fire(player, "Discover", `Waystone:{waystone.Id}`)
	end
	DataService.Set(player, { "Waystones", "Last" }, waystone.Id)
	VitalsService.RestoreAll(player)
	Net.Fire("Notify", player, "Toasts.WaystoneRested", { name = displayName(waystone.Id) }, "Success")
end

local function createPrompt(waystone: Waystone)
	-- The prompt sits on the crystal (or the model's primary part).
	local host: BasePart? = nil
	for _, descendant in waystone.Model:GetDescendants() do
		if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, Attributes.Tags.WaystoneCrystal) then
			host = descendant
			break
		end
	end
	host = host or waystone.Model.PrimaryPart
	if not host then
		log:Warn(`Waystone {waystone.Id} has no crystal or PrimaryPart for its prompt`)
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "RestPrompt"
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.ActionText = Strings.Prompts.Rest
	prompt.ObjectText = displayName(waystone.Id)
	prompt.HoldDuration = Config.World.Waystones.RestHoldDuration
	prompt.MaxActivationDistance = Config.World.Waystones.InteractDistance
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Parent = host
	prompt.Triggered:Connect(function(player: Player)
		rest(player, waystone)
	end)
	waystone.Prompt = prompt
end

local function register(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local id = model:GetAttribute(A.WaystoneId)
	if type(id) ~= "string" or id == "" then
		log:Warn(`Waystone {model:GetFullName()} is missing a WaystoneId attribute`)
		return
	end
	if waystones[id] then
		log:Warn(`Duplicate WaystoneId '{id}'`)
		return
	end
	local waystone: Waystone = {
		Id = id,
		Model = model,
		IsDefault = model:GetAttribute(A.DefaultWaystone) == true,
		Prompt = nil,
	}
	waystones[id] = waystone
	-- Waystones must always be streamed in (they are checkpoints).
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	createPrompt(waystone)
end

local function scanDiscoveries()
	local radius = Config.World.Waystones.DiscoverRadius
	for _, player in Players:GetPlayers() do
		local data = DataService.GetData(player)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if data and root then
			for id, waystone in waystones do
				if not data.Waystones.Discovered[id] and (waystonePosition(waystone) - root.Position).Magnitude <= radius then
					DataService.Set(player, { "Waystones", "Discovered", id }, true)
					Net.Fire("Notify", player, "Toasts.WaystoneDiscovered", { name = displayName(id) }, "Info")
					AnalyticsService.Custom(player, "WaystoneDiscovered")
					ProgressionService.AwardDiscovery(player, "Waystone")
					GameEvents.Fire(player, "Discover", `Waystone:{id}`)
				end
			end
		end
	end
end

local function isDungeonExit(id: string): boolean
	for _, def in Config.Dungeons.Dungeons do
		if def.ExitWaystone == id then
			return true
		end
	end
	return false
end

-- A ReturnTo point from teleport data, checked against this floor: only a dungeon's exit
-- Waystone or a Guardian gate's Return marker (teleport data passes through the client).
local function returnPoint(kind: string, id: string): CFrame?
	if kind == "Waystone" then
		local waystone = waystones[id]
		return if waystone and isDungeonExit(id) then spawnCFrame(waystone) else nil
	end
	if kind == "Gate" then
		for _, gate in CollectionService:GetTagged(Attributes.Tags.GuardianGate) do
			if gate:IsA("BasePart") and gate:GetAttribute(A.GuardianId) == id then
				local holder = gate.Parent
				local marker = holder and holder:FindFirstChild("Return")
				if marker and marker:IsA("BasePart") then
					return marker.CFrame + Vector3.new(0, Config.World.Waystones.SpawnHeight, 0)
				end
			end
		end
	end
	return nil
end

-- PUBLIC API -----------------------------------------------------------------

function FloorService.GetFloorId(): string
	return floorId
end

-- Instance servers: where members of the run rise (nil: not a member / no run).
function FloorService.SetRunSpawn(resolver: ((Player) -> CFrame?)?)
	runSpawn = resolver
end

-- Instance servers: true from `hold` keeps a player from rising for now (a Guardian fight).
function FloorService.SetSpawnHold(hold: ((Player) -> boolean)?)
	spawnHold = hold
end

-- Whether this player may not get a character right now (CharacterService asks).
function FloorService.SpawnHeld(player: Player): boolean
	if InstanceService.HoldsSpawn(player) then
		return true
	end
	local hold = spawnHold
	return hold ~= nil and hold(player)
end

-- Where a player should (re)spawn on this floor.
function FloorService.GetSpawnCFrame(player: Player): CFrame
	local resolver = runSpawn
	local inRun = if resolver then resolver(player) else nil
	if inRun then
		return inRun
	end
	local kind, id = InstanceService.TakeReturnTo(player)
	local returning = if kind and id then returnPoint(kind, id) else nil
	if returning then
		return returning
	end
	local data = DataService.GetData(player)
	local last = data and data.Waystones.Last
	if last and waystones[last] then
		return spawnCFrame(waystones[last])
	end
	for _, waystone in waystones do
		if waystone.IsDefault then
			return spawnCFrame(waystone)
		end
	end
	local spawnLocation = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	if spawnLocation then
		return spawnLocation.CFrame + Vector3.new(0, Config.World.Waystones.SpawnHeight, 0)
	end
	return CFrame.new(0, 10, 0)
end

-- Where a given Waystone puts players (dungeon exits, fast travel). nil if it isn't on this floor.
function FloorService.GetWaystoneCFrame(id: string): CFrame?
	local waystone = waystones[id]
	return if waystone then spawnCFrame(waystone) else nil
end

function FloorService.GetWaystoneIds(): { string }
	local ids = {}
	for id in waystones do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

-- Fast travel from the map. Everything is re-checked here; the client only names the target.
local function travel(player: Player, targetId: string)
	local W = Config.World.Waystones
	local function refuse(reason: string)
		Net.Fire("Notify", player, `QuestUI.TravelErrors.{reason}`, {}, "Warning")
	end
	local data = DataService.GetData(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not data or not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		refuse("Busy")
		return
	end
	if InstanceService.IsInstanceServer() then
		refuse("Busy")
		return
	end
	local target = waystones[targetId]
	if not target or not data.Waystones.Discovered[targetId] then
		refuse("Unknown")
		return
	end
	-- Must be standing at a Waystone you know (not the target itself).
	local here: Waystone? = nil
	for id, waystone in waystones do
		if id ~= targetId and data.Waystones.Discovered[id] and (waystonePosition(waystone) - root.Position).Magnitude <= W.TravelRadius then
			here = waystone
			break
		end
	end
	if not here then
		refuse("NotAtWaystone")
		return
	end
	local now = Workspace:GetServerTimeNow()
	local lastCombat = player:GetAttribute(A.LastCombat)
	if type(lastCombat) == "number" and now - lastCombat < W.TravelCombatLock then
		refuse("Combat")
		return
	end
	if now - (lastTravel[player] or -math.huge) < W.TravelCooldown then
		refuse("Cooldown")
		return
	end
	-- The tutorial keeps a new Climber on the docks until it ends (required lazily: no load cycle).
	local tutorial = require(script.Parent.TutorialService) :: any
	if tutorial.IsActive(player) then
		refuse("Busy")
		return
	end
	lastTravel[player] = now
	local characterService = require(script.Parent.CharacterService) :: any
	characterService.Teleport(player, spawnCFrame(target))
	Net.Fire("Notify", player, "QuestUI.TravelArrived", { name = displayName(targetId) }, "Success")
	AnalyticsService.Custom(player, "WaystoneTravel")
end

function FloorService.Init()
	local configured = Workspace:GetAttribute("FloorId")
	if type(configured) == "string" and configured ~= "" then
		floorId = configured
	end
end

function FloorService.Start()
	for _, model in CollectionService:GetTagged(Attributes.Tags.Waystone) do
		register(model)
	end
	CollectionService:GetInstanceAddedSignal(Attributes.Tags.Waystone):Connect(register)
	Net.On("RequestWaystoneTravel", function(player: Player, targetId: string)
		travel(player, targetId)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		lastTravel[player] = nil
	end)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator >= Config.World.Waystones.ScanInterval then
			accumulator = 0
			scanDiscoveries()
		end
	end)
end

return FloorService
