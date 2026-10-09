--!strict
-- DungeonService: private dungeon instances per party.
--
-- A player triggers the entrance; everyone standing in the gather ring joins
-- during a short countdown (up to MaxPartySize). The template from
-- ServerStorage/DungeonTemplates is cloned into a free slot far from the
-- floor, the group is moved to its arrival point, and the instance runs its
-- own state: three sluice valves raise the gate to the Reservoir, the boss
-- clear unlocks the reward chest and the far exit. Empty instances are cleaned
-- up. Reserved-server routing (one server per party) plugs in through
-- SetPartyResolver/Teleport in a later phase; this service is the in-place
-- implementation every server can run.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)

local DataService = require(script.Parent.DataService)
local WorldService = require(script.Parent.WorldService)

local DC = Config.World.Dungeon

type Instance_ = {
	id: string,
	dungeonId: string,
	slot: number,
	model: Model,
	members: { Player },
	valves: { [string]: boolean },
	valveCount: number,
	gateOpen: boolean,
	cleared: boolean,
	rewarded: { [Player]: boolean },
	emptySince: number?,
}

local DungeonService = {
	InstanceCreated = Signal.new() :: Signal.Signal<string, Model>,
	InstanceCleared = Signal.new() :: Signal.Signal<string>,
}

local instances: { [string]: Instance_ } = {}
local slots: { [number]: string } = {}
local gathering: { [BasePart]: boolean } = {}
local partyResolver: ((player: Player) -> { Player })? = nil
local counter = 0

local function rootOf(player: Player): BasePart?
	local c = player.Character
	local r = c and c:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function notify(players: { Player }, kind: string, key: string, args: { any }?)
	for _, p in players do
		if p.Parent then
			Net.fire(p, "WorldFeedback", kind, key, args)
		end
	end
end

local function sendState(inst: Instance_)
	local state = {
		instance = inst.id,
		dungeon = inst.dungeonId,
		valves = inst.valveCount,
		valvesTotal = 3,
		gateOpen = inst.gateOpen,
		cleared = inst.cleared,
	}
	for _, p in inst.members do
		if p.Parent then
			Net.fire(p, "DungeonState", state)
		end
	end
end

local function makePrompt(parent: BasePart, action: string, object: string, kind: string, hold: number): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = action
	prompt.ObjectText = object
	prompt.HoldDuration = hold
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt:SetAttribute("PromptKind", kind)
	prompt.Parent = parent
	return prompt
end

local function entranceCFrame(dungeonId: string): CFrame?
	for _, m in CollectionService:GetTagged("DungeonEntrance") do
		if m:IsA("BasePart") and m:GetAttribute("MarkerId") == dungeonId then
			local p = (m :: BasePart).Position
			return CFrame.new(p + Vector3.new(0, 3.5, -12))
		end
	end
	return nil
end

local function leave(player: Player, inst: Instance_)
	local idx = table.find(inst.members, player)
	if idx then
		table.remove(inst.members, idx)
	end
	player:SetAttribute("InDungeon", nil)
	player:SetAttribute("DungeonInstance", nil)
	local cf = entranceCFrame(inst.dungeonId)
	if cf and player.Character then
		pcall(function()
			player:RequestStreamAroundAsync(cf.Position, 5)
		end)
		player.Character:PivotTo(cf)
	end
	Net.fire(player, "WorldFeedback", "Info", "Dungeon.Left", nil)
	Net.fire(player, "DungeonState", { instance = "", dungeon = "", left = true })
	if #inst.members == 0 then
		inst.emptySince = os.clock()
	end
end

local function instanceOf(player: Player): Instance_?
	local id = player:GetAttribute("DungeonInstance")
	return if type(id) == "string" then instances[id] else nil
end

local function raiseGate(inst: Instance_)
	if inst.gateOpen then
		return
	end
	inst.gateOpen = true
	for _, d in inst.model:GetDescendants() do
		if d:IsA("BasePart") then
			if CollectionService:HasTag(d, "SluiceGate") then
				local goal = d.CFrame + Vector3.new(0, 16, 0)
				TweenService:Create(d, TweenInfo.new(DC.GateLiftSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { CFrame = goal }):Play()
			elseif CollectionService:HasTag(d, "SluiceBarrier") then
				d.CanCollide = false
			end
		end
	end
	notify(inst.members, "Event", "Dungeon.GateRises", nil)
	sendState(inst)
end

local function wireInstance(inst: Instance_)
	for _, d in inst.model:GetDescendants() do
		if not d:IsA("BasePart") then
			continue
		end
		local kind = d:GetAttribute("MarkerKind")
		local markerId = d:GetAttribute("MarkerId")
		if kind == "CisternValve" and type(markerId) == "string" then
			local prompt = makePrompt(d, Strings.get("Prompt.TurnValve"), Strings.get("Prompt.Valve"), "Valve", DC.ValveHoldSeconds)
			prompt.Triggered:Connect(function(player: Player)
				if instanceOf(player) ~= inst or inst.valves[markerId] then
					return
				end
				inst.valves[markerId] = true
				inst.valveCount += 1
				prompt.Enabled = false
				-- spin the nearest valve wheel
				for _, w in inst.model:GetDescendants() do
					if w:IsA("BasePart") and w.Name == "valve_wheel" and (w.Position - d.Position).Magnitude < 8 then
						TweenService:Create(w, TweenInfo.new(1.4, Enum.EasingStyle.Quad), { CFrame = w.CFrame * CFrame.Angles(0, 0, math.pi * 2 - 0.01) }):Play()
					end
				end
				notify(inst.members, "Event", "Dungeon.ValveTurned", { inst.valveCount, 3 })
				sendState(inst)
				if inst.valveCount >= 3 then
					raiseGate(inst)
				end
			end)
		elseif kind == "DungeonExit" then
			local requiresClear = d:GetAttribute("RequiresClear") == true
			local prompt = makePrompt(d, Strings.get("Prompt.Leave"), Strings.get("Prompt.Exit"), "Exit", 0.5)
			prompt.Triggered:Connect(function(player: Player)
				if instanceOf(player) ~= inst then
					return
				end
				if requiresClear and not inst.cleared then
					Net.fire(player, "WorldFeedback", "Error", "Dungeon.NotCleared", nil)
					return
				end
				leave(player, inst)
			end)
		elseif kind == "DungeonChest" then
			local prompt = makePrompt(d, Strings.get("Prompt.OpenChest"), Strings.get("Prompt.Chest"), "Chest", 0.6)
			prompt.Triggered:Connect(function(player: Player)
				if instanceOf(player) ~= inst then
					return
				end
				if not inst.cleared then
					Net.fire(player, "WorldFeedback", "Error", "Dungeon.NotCleared", nil)
					return
				end
				if inst.rewarded[player] then
					Net.fire(player, "WorldFeedback", "Info", "Chest.Already", nil)
					return
				end
				inst.rewarded[player] = true
				DataService.AddGold(player, DC.ClearReward.Gold)
				DataService.AddFloorTokens(player, WorldService.Floor.id, DC.ClearReward.FloorTokens)
				DataService.Update(player, function(data)
					data.DungeonClears[inst.dungeonId] = (data.DungeonClears[inst.dungeonId] or 0) + 1
				end)
				Net.fire(player, "ChestOpened", inst.dungeonId .. "_clear", DC.ClearReward.Gold, {})
			end)
		end
	end
end

local function arrival(inst: Instance_): CFrame
	for _, d in inst.model:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("MarkerKind") == "DungeonArrival" then
			return (d :: BasePart).CFrame + Vector3.new(0, 3.5, 0)
		end
	end
	return inst.model:GetPivot() + Vector3.new(0, 4, 0)
end

local function createInstance(dungeonId: string, members: { Player }): Instance_?
	local templates = ServerStorage:FindFirstChild("DungeonTemplates")
	local template = templates and templates:FindFirstChild(dungeonId)
	if not template or not template:IsA("Model") then
		warn("[DungeonService] missing template " .. dungeonId .. " (run WorldBuilder.Build)")
		return nil
	end
	local slot: number? = nil
	for i = 1, DC.MaxInstances do
		if not slots[i] then
			slot = i
			break
		end
	end
	if not slot then
		notify(members, "Error", "Dungeon.Full", nil)
		return nil
	end
	counter += 1
	local id = string.format("%s_%d", dungeonId, counter)
	local model = template:Clone()
	model.Name = id
	local o = DC.InstanceOrigin
	model:PivotTo(CFrame.new(o[1] + (slot :: number) * DC.InstanceSpacing, o[2], o[3]))
	local holder = Workspace:FindFirstChild("DungeonInstances")
	if not holder then
		local f = Instance.new("Folder")
		f.Name = "DungeonInstances"
		f.Parent = Workspace
		holder = f
	end
	model.Parent = holder
	local inst: Instance_ = {
		id = id,
		dungeonId = dungeonId,
		slot = slot :: number,
		model = model,
		members = {},
		valves = {},
		valveCount = 0,
		gateOpen = false,
		cleared = false,
		rewarded = {},
		emptySince = nil,
	}
	instances[id] = inst
	slots[slot :: number] = id
	wireInstance(inst)
	DungeonService.InstanceCreated:Fire(id, model)
	return inst
end

local function enter(inst: Instance_, members: { Player })
	local cf = arrival(inst)
	for i, p in members do
		if p.Parent and p.Character then
			table.insert(inst.members, p)
			p:SetAttribute("InDungeon", inst.dungeonId)
			p:SetAttribute("DungeonInstance", inst.id)
			local spot = cf * CFrame.new((i - 1) % 3 * 4 - 4, 0, math.floor((i - 1) / 3) * 4)
			pcall(function()
				p:RequestStreamAroundAsync(spot.Position, 5)
			end)
			p.Character:PivotTo(spot)
		end
	end
	inst.emptySince = nil
	notify(inst.members, "Event", "Dungeon.Entering", { Strings.get("Dungeon." .. inst.dungeonId) })
	sendState(inst)
end

local function gather(entrance: BasePart, starter: Player)
	if gathering[entrance] then
		return
	end
	local dungeonId = (entrance:GetAttribute("Dungeon") :: string?) or (entrance:GetAttribute("MarkerId") :: string)
	gathering[entrance] = true
	local function nearby(): { Player }
		local list: { Player } = {}
		if partyResolver then
			for _, p in (partyResolver :: (Player) -> { Player })(starter) do
				table.insert(list, p)
			end
		end
		for _, p in Players:GetPlayers() do
			local r = rootOf(p)
			if r and not table.find(list, p) and not p:GetAttribute("InDungeon") and (r.Position - entrance.Position).Magnitude <= DC.GatherRadius then
				table.insert(list, p)
			end
		end
		while #list > DC.MaxPartySize do
			table.remove(list)
		end
		return list
	end
	for t = DC.GatherSeconds, 1, -1 do
		notify(nearby(), "Countdown", "Dungeon.Gathering", { t })
		task.wait(1)
	end
	local members = nearby()
	if #members > 0 then
		local inst = createInstance(dungeonId, members)
		if inst then
			enter(inst, members)
		end
	end
	gathering[entrance] = nil
end

-- Hooks for later systems ----------------------------------------------------

-- Party systems decide who enters together with the player who triggered entry.
function DungeonService.SetPartyResolver(fn: (player: Player) -> { Player })
	partyResolver = fn
end

-- Called by boss logic when an instance's final boss falls.
function DungeonService.ReportBossDefeated(instanceId: string)
	local inst = instances[instanceId]
	if not inst or inst.cleared then
		return
	end
	inst.cleared = true
	DungeonService.InstanceCleared:Fire(instanceId)
	sendState(inst)
end

function DungeonService.GetInstanceModel(instanceId: string): Model?
	local inst = instances[instanceId]
	return if inst then inst.model else nil
end

function DungeonService.Init()
	Net.onEvent("RequestDungeonLeave", function(player: Player)
		local inst = instanceOf(player)
		if inst then
			-- leaving early is always allowed through the menu; it returns to the entrance
			leave(player, inst)
		end
	end)
end

function DungeonService.Start()
	local function registerEntrance(m: Instance)
		if not m:IsA("BasePart") or m:FindFirstChildOfClass("ProximityPrompt") then
			return
		end
		local dungeonId = (m:GetAttribute("Dungeon") :: string?) or "SunkenCistern"
		local prompt = makePrompt(m, Strings.get("Prompt.Descend"), Strings.get("Dungeon." .. dungeonId), "Dungeon", DC.EnterHoldSeconds)
		prompt.Triggered:Connect(function(player: Player)
			if player:GetAttribute("InDungeon") then
				return
			end
			task.spawn(gather, m, player)
		end)
	end
	for _, m in CollectionService:GetTagged("DungeonEntrance") do
		registerEntrance(m)
	end
	CollectionService:GetInstanceAddedSignal("DungeonEntrance"):Connect(registerEntrance)

	Players.PlayerRemoving:Connect(function(player: Player)
		local inst = instanceOf(player)
		if inst then
			local idx = table.find(inst.members, player)
			if idx then
				table.remove(inst.members, idx)
			end
			if #inst.members == 0 then
				inst.emptySince = os.clock()
			end
		end
	end)
	-- characters that respawn inside a dungeon return to its arrival point
	local function hook(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			local inst = instanceOf(player)
			if inst then
				character:WaitForChild("HumanoidRootPart", 10)
				task.wait()
				character:PivotTo(arrival(inst))
			end
		end)
	end
	Players.PlayerAdded:Connect(hook)
	for _, p in Players:GetPlayers() do
		hook(p)
	end
	-- cleanup
	task.spawn(function()
		while true do
			task.wait(5)
			for id, inst in instances do
				if #inst.members == 0 and inst.emptySince and os.clock() - inst.emptySince > DC.EmptyCleanupSeconds then
					inst.model:Destroy()
					slots[inst.slot] = nil
					instances[id] = nil
				end
			end
		end
	end)
end

return DungeonService
