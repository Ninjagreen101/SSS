--!strict
--[[
	DungeonService
	Instanced dungeons: every group that goes in gets its own copy (Spec: Sunken Cistern,
	instanced per party; cross-server reserved instances arrive in Phase 12).

	Entering: dungeon doors are parts tagged SpireDungeonDoor with attribute DungeonId. Stepping
	within DoorRadius starts a gathering: anyone else who steps in within GatherSeconds joins the
	same run (up to MaxPlayers; players below MinLevel are turned away). Then the server clones the
	template (ServerStorage.Dungeons.<Template>) into a free slot far beyond the Spire wall and
	moves the group to its Arrival point.

	Inside: the template's Spawns move into Workspace.MobSpawns (MobService fills them, they never
	refill). Pulling every DungeonLever raises the SluiceGate. Once no enemy from the run is left
	alive the DungeonChest unlocks: each member opens it once (Reward, plus DailyBonus on their
	first clear of the day). ExitPortals send you to the dungeon's ExitWaystone.

	Closing: a run with nobody inside for CloseAfterEmpty seconds is destroyed with its spawns.
	Everything here is decided on the server; clients only touch prompts the server created and
	positions the server reads itself.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Log = require(Shared.Util.Log)

local DataService = require(script.Parent.DataService)
local FloorService = require(script.Parent.FloorService)
local MobService = require(script.Parent.MobService)
local ProgressionService = require(script.Parent.ProgressionService)
local AnalyticsService = require(script.Parent.AnalyticsService)
local Rewards = require(script.Parent.Rewards)
local AntiExploitService = require(script.Parent.AntiExploitService)
local GameEvents = require(script.Parent.GameEvents)

local D = Config.Dungeons
local log = Log.new("DungeonService")

type Run = {
	Id: number,
	DungeonId: string,
	Def: Config.DungeonDef,
	Slot: number,
	Model: Model,
	Origin: CFrame,
	Members: { [Player]: boolean },
	Spawns: { BasePart },
	LeversPulled: { [Model]: boolean },
	LeverCount: number,
	GateOpen: boolean,
	ChestOpenedBy: { [Player]: boolean },
	Cleared: boolean,
	EmptySince: number?,
}

type Gathering = { DungeonId: string, Door: BasePart, Players: { Player }, Deadline: number }

local DungeonService = {}

local runs: { [number]: Run } = {}
local slotsUsed: { [number]: boolean } = {}
local gatherings: { [BasePart]: Gathering } = {}
local playerRun: { [Player]: Run } = {}
local serial = 0
local folder: Folder

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function teleport(player: Player, cf: CFrame)
	local character = player.Character
	if not character then
		return
	end
	pcall(function()
		player:RequestStreamAroundAsync(cf.Position, 5)
	end)
	-- a server teleport is not a speed hack: clear the movement check's last sample around the jump
	AntiExploitService.ResetMovement(player)
	character:PivotTo(cf + Vector3.new(0, 3, 0))
	task.defer(AntiExploitService.ResetMovement, player)
end

local function freeSlot(): number?
	for i = 1, D.MaxInstances do
		if not slotsUsed[i] then
			return i
		end
	end
	return nil
end

local function insideRun(run: Run, position: Vector3): boolean
	local localPos = run.Origin:PointToObjectSpace(position)
	return math.abs(localPos.X) < 120 and localPos.Y > -40 and localPos.Y < 80 and localPos.Z > -40 and localPos.Z < 280
end

local function closeRun(run: Run)
	runs[run.Id] = nil
	slotsUsed[run.Slot] = nil
	for _, spawn in run.Spawns do
		spawn:Destroy() -- MobService removes their mobs
	end
	for player in run.Members do
		if playerRun[player] == run then
			playerRun[player] = nil
		end
	end
	run.Model:Destroy()
	log:Info(`closed {run.DungeonId} run {run.Id}`)
end

local function exitRun(player: Player, run: Run)
	local cf = FloorService.GetWaystoneCFrame(run.Def.ExitWaystone) or FloorService.GetSpawnCFrame(player)
	teleport(player, cf)
	run.Members[player] = nil
	if playerRun[player] == run then
		playerRun[player] = nil
	end
end

local function livingEnemies(run: Run): number
	local n = 0
	local spawns: { [BasePart]: boolean } = {}
	for _, s in run.Spawns do
		spawns[s] = true
	end
	for _, mob in MobService.GetAll() do
		if not mob.Dead and mob.Spawn and spawns[mob.Spawn.Part] then
			n += 1
		end
	end
	return n
end

local function openGate(run: Run)
	if run.GateOpen then
		return
	end
	run.GateOpen = true
	local gate = run.Model:FindFirstChild("SluiceGate")
	if gate and gate:IsA("BasePart") then
		local rise = gate:GetAttribute("OpenOffset")
		local goal = gate.CFrame + Vector3.new(0, if type(rise) == "number" then rise else 15, 0)
		TweenService:Create(gate, TweenInfo.new(3, Enum.EasingStyle.Sine), { CFrame = goal }):Play()
		task.delay(3, function()
			gate.CanCollide = false
		end)
	end
	for player in run.Members do
		Net.Fire("Notify", player, "Toasts.SluiceOpened", {}, "Info")
	end
end

local function pullLever(player: Player, run: Run, lever: Model)
	if run.LeversPulled[lever] or not run.Members[player] then
		return
	end
	run.LeversPulled[lever] = true
	local handle = lever:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		TweenService:Create(handle, TweenInfo.new(0.4), { CFrame = handle.CFrame * CFrame.Angles(math.rad(70), 0, 0) }):Play()
	end
	local rune = lever:FindFirstChild("Rune")
	if rune and rune:IsA("BasePart") then
		rune.Color = Color3.fromHex("#3FE0D0")
	end
	local pulled = 0
	for _ in run.LeversPulled do
		pulled += 1
	end
	if pulled >= run.LeverCount then
		openGate(run)
	else
		for member in run.Members do
			Net.Fire("Notify", member, "Toasts.LeverPulled", { left = run.LeverCount - pulled }, "Info")
		end
	end
end

local function openChest(player: Player, run: Run)
	if not run.Members[player] or run.ChestOpenedBy[player] then
		return
	end
	if not run.Cleared then
		Net.Fire("Notify", player, "Toasts.ChestSealed", {}, "Warning")
		return
	end
	run.ChestOpenedBy[player] = true
	Rewards.Grant(player, run.Def.Reward.Items, run.Def.Reward.Gold)
	local data = DataService.GetData(player)
	local today = `Dungeon:{run.DungeonId}:{os.date("!%Y-%m-%d")}`
	if data and not data.Discoveries[today] then
		DataService.Set(player, { "Discoveries", today }, true)
		Rewards.Grant(player, run.Def.DailyBonus.Items, nil)
	end
	ProgressionService.AwardDiscovery(player, "Cache")
	Net.Fire("Notify", player, "Toasts.DungeonCleared", { name = run.DungeonId }, "Success")
	AnalyticsService.Custom(player, "DungeonCleared")
end

local function prompt(host: BasePart, action: string, object: string, onTrigger: (Player) -> ())
	local p = Instance.new("ProximityPrompt")
	p.ActionText = action
	p.ObjectText = object
	p.HoldDuration = 0.5
	p.MaxActivationDistance = 9
	p.RequiresLineOfSight = false
	p.KeyboardKeyCode = Enum.KeyCode.E
	p.GamepadKeyCode = Enum.KeyCode.ButtonX
	p.Parent = host
	p.Triggered:Connect(function(player: Player)
		local root = rootOf(player)
		if root and (root.Position - host.Position).Magnitude <= 12 then
			onTrigger(player)
		end
	end)
end

local function startRun(dungeonId: string, group: { Player })
	local def = D.Dungeons[dungeonId]
	local templates = ServerStorage:FindFirstChild("Dungeons")
	local template = templates and templates:FindFirstChild(def.Template)
	if not template or not template:IsA("Model") then
		log:Warn(`no template ServerStorage.Dungeons.{def.Template} (run DungeonBuilder)`)
		return
	end
	local slot = freeSlot()
	if not slot then
		for _, player in group do
			Net.Fire("Notify", player, "Toasts.DungeonFull", {}, "Warning")
		end
		return
	end
	serial += 1
	slotsUsed[slot] = true
	local origin = CFrame.new(D.Origin + Vector3.new(slot * D.SlotSpacing, 0, 0))
	local model = template:Clone()
	model.Name = `{dungeonId}_{serial}`
	model:PivotTo(origin)
	model.Parent = folder
	local run: Run = {
		Id = serial,
		DungeonId = dungeonId,
		Def = def,
		Slot = slot,
		Model = model,
		Origin = origin,
		Members = {},
		Spawns = {},
		LeversPulled = {},
		LeverCount = 0,
		GateOpen = false,
		ChestOpenedBy = {},
		Cleared = false,
		EmptySince = nil,
	}
	runs[serial] = run
	-- spawns go live
	local spawnFolder = model:FindFirstChild("Spawns")
	local mobSpawns = Workspace:FindFirstChild(Config.Mobs.Spawning.Folder)
	if spawnFolder and mobSpawns then
		for _, s in spawnFolder:GetChildren() do
			if s:IsA("BasePart") then
				s.Name = `{model.Name}_{s.Name}`
				s:SetAttribute("Run", serial)
				s.Parent = mobSpawns
				table.insert(run.Spawns, s)
			end
		end
	end
	-- levers, chest, exits
	for _, d in model:GetDescendants() do
		if d:IsA("Model") and CollectionService:HasTag(d, "DungeonLever") and d.PrimaryPart then
			run.LeverCount += 1
			prompt(d.PrimaryPart, "Pull", "Sluice Lever", function(player)
				pullLever(player, run, d)
			end)
		end
	end
	if run.LeverCount == 0 then
		openGate(run)
	end
	local chest = model:FindFirstChild("DungeonChest")
	local chestHost = chest and chest:FindFirstChildWhichIsA("BasePart", true)
	if chestHost then
		prompt(chestHost, "Open", "Cistern Hoard", function(player)
			openChest(player, run)
		end)
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Name == "ExitPortal" then
			d:SetAttribute("Run", serial)
			CollectionService:AddTag(d, "SpireDungeonExit")
		end
	end
	-- the group goes in
	local arrival = model:FindFirstChild("Arrival")
	local arrivalCF = if arrival and arrival:IsA("BasePart") then arrival.CFrame else origin
	for i, player in group do
		run.Members[player] = true
		playerRun[player] = run
		teleport(player, arrivalCF * CFrame.new((i - 1) * 3 - 4, 0, 0))
		AnalyticsService.Custom(player, "DungeonEntered")
	end
	log:Info(`started {dungeonId} run {serial} in slot {slot} for {#group}`)
end

local function tryJoin(door: BasePart, player: Player)
	local dungeonId = door:GetAttribute("DungeonId")
	local def = if type(dungeonId) == "string" then D.Dungeons[dungeonId] else nil
	if not def or playerRun[player] then
		return
	end
	local data = DataService.GetData(player)
	if not data or data.Level < def.MinLevel then
		Net.Fire("Notify", player, "Toasts.DungeonLevel", { level = def.MinLevel }, "Warning")
		return
	end
	local gathering = gatherings[door]
	if not gathering then
		gathering = { DungeonId = dungeonId :: string, Door = door, Players = {}, Deadline = os.clock() + def.GatherSeconds }
		gatherings[door] = gathering
	end
	if table.find(gathering.Players, player) or #gathering.Players >= def.MaxPlayers then
		return
	end
	table.insert(gathering.Players, player)
	for _, member in gathering.Players do
		Net.Fire("Notify", member, "Toasts.DungeonGathering", { count = #gathering.Players, max = def.MaxPlayers }, "Info")
	end
end

local warned: { [Player]: number } = {}

local function scan()
	local t = os.clock()
	-- doors
	for _, door in CollectionService:GetTagged("SpireDungeonDoor") do
		if not door:IsA("BasePart") then
			continue
		end
		for _, player in Players:GetPlayers() do
			local root = rootOf(player)
			if root and (root.Position - door.Position).Magnitude <= D.DoorRadius then
				if (warned[player] or 0) < t then
					warned[player] = t + 3
					tryJoin(door, player)
				end
			end
		end
	end
	-- gatherings that are ready
	for door, gathering in gatherings do
		local def = D.Dungeons[gathering.DungeonId]
		if t >= gathering.Deadline or #gathering.Players >= def.MaxPlayers then
			gatherings[door] = nil
			local group = {}
			for _, player in gathering.Players do
				local root = rootOf(player)
				-- still near the door when the run starts
				if player.Parent == Players and root and (root.Position - door.Position).Magnitude <= D.DoorRadius * 3 then
					table.insert(group, player)
				end
			end
			if #group > 0 then
				startRun(gathering.DungeonId, group)
			end
		end
	end
	-- exits
	for _, exit in CollectionService:GetTagged("SpireDungeonExit") do
		if not exit:IsA("BasePart") then
			continue
		end
		local run = runs[exit:GetAttribute("Run") :: number? or -1]
		if not run then
			continue
		end
		for player in run.Members do
			local root = rootOf(player)
			if root and (root.Position - exit.Position).Magnitude <= 5 then
				exitRun(player, run)
			end
		end
	end
	-- runs: clear state, membership, closing
	for _, run in runs do
		if not run.Cleared and run.GateOpen and livingEnemies(run) == 0 then
			run.Cleared = true
			for player in run.Members do
				Net.Fire("Notify", player, "Toasts.ChestUnsealed", {}, "Success")
				GameEvents.Fire(player, "Clear", `Dungeon:{run.DungeonId}`)
			end
		end
		local anyone = false
		for player in run.Members do
			local root = rootOf(player)
			if player.Parent ~= Players then
				run.Members[player] = nil
			elseif root and insideRun(run, root.Position) then
				anyone = true
			end
		end
		if anyone then
			run.EmptySince = nil
		else
			run.EmptySince = run.EmptySince or t
			if t - (run.EmptySince :: number) >= D.CloseAfterEmpty then
				closeRun(run)
			end
		end
	end
end

-- The run a player is in, if any (for other systems: e.g. respawn rules later).
function DungeonService.GetRun(player: Player): number?
	local run = playerRun[player]
	return run and run.Id
end

function DungeonService.Init()
	local f = Workspace:FindFirstChild("Dungeons")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Dungeons"
		f.Parent = Workspace
	end
	folder = f :: Folder
end

function DungeonService.Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		local run = playerRun[player]
		if run then
			run.Members[player] = nil
		end
		playerRun[player] = nil
		warned[player] = nil
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc >= D.ScanInterval then
			acc = 0
			scan()
		end
	end)
end

return DungeonService
