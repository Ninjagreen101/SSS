--!strict
-- FloorService: Waystones (discovery by proximity or interaction, saved per
-- floor), fast travel between attuned Waystones while standing at one,
-- respawning at the last attuned Waystone, and one-time per-player treasure
-- chests in hidden areas. All decisions are made here; clients only ask.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Items = require(Shared.Data.Items)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)

local DataService = require(script.Parent.DataService)
local WorldService = require(script.Parent.WorldService)

local WC = Config.World.Waystones
local TC = Config.World.Treasure

local FloorService = {
	WaystoneAttuned = Signal.new() :: Signal.Signal<Player, string>,
	ChestOpened = Signal.new() :: Signal.Signal<Player, string>,
}

local waystones: { [string]: BasePart } = {}
local chests: { [string]: BasePart } = {}
local lastTravel: { [Player]: number } = {}

local function floorId(): string
	return WorldService.Floor.id
end

local function discovered(player: Player): { string }
	local data = DataService.Get(player)
	if not data then
		return {}
	end
	return data.Waystones[floorId()] or {}
end

local function isDiscovered(player: Player, id: string): boolean
	return table.find(discovered(player), id) ~= nil
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local humanoid = (character :: Model):FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			return root
		end
	end
	return nil
end

local function flatDistance(a: Vector3, b: Vector3): number
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

local function nearestWaystone(position: Vector3, radius: number): string?
	local best, bestD = nil, radius
	for id, marker in waystones do
		local d = flatDistance(position, marker.Position)
		if d <= bestD and math.abs(position.Y - marker.Position.Y) < 20 then
			best, bestD = id, d
		end
	end
	return best
end

local function attune(player: Player, id: string)
	local first = false
	DataService.Update(player, function(data)
		local list = data.Waystones[floorId()]
		if not list then
			list = {}
			data.Waystones[floorId()] = list
		end
		if not table.find(list, id) then
			table.insert(list, id)
			first = true
		end
		data.LastWaystone[floorId()] = id
	end)
	player:SetAttribute("LastWaystone", id)
	if first then
		local marker = waystones[id]
		local nameKey = if marker then (marker:GetAttribute("NameKey") :: string?) or id else id
		Net.fire(player, "WaystoneDiscovered", id)
		Net.fire(player, "WorldFeedback", "Waystone", "Waystone.Attuned", { Strings.get(nameKey) })
		FloorService.WaystoneAttuned:Fire(player, id)
	end
end

local function arrivalCFrame(marker: BasePart, player: Player): CFrame
	local offset = WC.ArrivalOffset
	local angle = (player.UserId % 8) / 8 * math.pi * 2
	local pos = marker.Position + Vector3.new(math.cos(angle) * offset, 3.5, math.sin(angle) * offset)
	return CFrame.lookAt(pos, Vector3.new(marker.Position.X, pos.Y, marker.Position.Z))
end

local function moveCharacter(player: Player, cf: CFrame)
	local character = player.Character
	if not character then
		return
	end
	pcall(function()
		player:RequestStreamAroundAsync(cf.Position, 5)
	end)
	character:PivotTo(cf)
end

-- --------------------------------------------------------------- travel

local function travel(player: Player, targetId: string)
	local root = rootOf(player)
	if not root then
		return
	end
	local here = nearestWaystone(root.Position, WC.InteractRadius + 4)
	if not here or not isDiscovered(player, here) then
		Net.fire(player, "WorldFeedback", "Error", "Waystone.Error.TooFar", nil)
		return
	end
	local target = waystones[targetId]
	if not target or not isDiscovered(player, targetId) then
		Net.fire(player, "WorldFeedback", "Error", "Waystone.Error.Unknown", nil)
		return
	end
	if player:GetAttribute("InCombat") == true then
		Net.fire(player, "WorldFeedback", "Error", "Waystone.Error.Combat", nil)
		return
	end
	local now = os.clock()
	if lastTravel[player] and now - lastTravel[player] < WC.FastTravelCooldown then
		Net.fire(player, "WorldFeedback", "Error", "Waystone.Error.Cooldown", nil)
		return
	end
	lastTravel[player] = now
	if targetId == here then
		return
	end
	moveCharacter(player, arrivalCFrame(target, player))
	attune(player, targetId)
	local nameKey = (target:GetAttribute("NameKey") :: string?) or targetId
	Net.fire(player, "WorldFeedback", "Travel", "Waystone.Arrived", { Strings.get(nameKey) })
end

-- ---------------------------------------------------------------- chests

local function parseItems(s: string): { { id: string, count: number } }
	local out = {}
	for entry in string.gmatch(s, "[^,]+") do
		local id, count = string.match(entry, "^([%w_]+):(%d+)$")
		if id and count and Items[id] then
			table.insert(out, { id = id, count = tonumber(count) :: number })
		end
	end
	return out
end

local function openChest(player: Player, chestId: string)
	local marker = chests[chestId]
	local root = rootOf(player)
	if not marker or not root then
		return
	end
	if (root.Position - marker.Position).Magnitude > TC.InteractRadius + 4 then
		return
	end
	local data = DataService.Get(player)
	if not data then
		return
	end
	if data.Chests[chestId] then
		Net.fire(player, "WorldFeedback", "Info", "Chest.Already", nil)
		return
	end
	local gold = (marker:GetAttribute("Gold") :: number?) or 0
	local items = parseItems((marker:GetAttribute("Items") :: string?) or "")
	DataService.Update(player, function(d)
		d.Chests[chestId] = true
	end)
	DataService.AddGold(player, gold)
	for _, it in items do
		DataService.AddItem(player, it.id, it.count)
	end
	DataService.SaveNow(player)
	Net.fire(player, "ChestOpened", chestId, gold, items)
	FloorService.ChestOpened:Fire(player, chestId)
end

-- --------------------------------------------------------------- prompts

local function makePrompt(parent: BasePart, action: string, object: string, kind: string, hold: number, distance: number): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = action
	prompt.ObjectText = object
	prompt.HoldDuration = hold
	prompt.MaxActivationDistance = distance
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt:SetAttribute("PromptKind", kind)
	prompt.Parent = parent
	return prompt
end

local function registerWaystone(marker: Instance)
	if not marker:IsA("BasePart") then
		return
	end
	local id = marker:GetAttribute("MarkerId")
	if type(id) ~= "string" or waystones[id] then
		return
	end
	waystones[id] = marker
	local nameKey = (marker:GetAttribute("NameKey") :: string?) or id
	local prompt = makePrompt(marker, Strings.get("Prompt.Travel"), Strings.get(nameKey), "Waystone", 0, WC.InteractRadius)
	prompt:SetAttribute("WaystoneId", id)
	prompt.Triggered:Connect(function(player: Player)
		local root = rootOf(player)
		if not root or (root.Position - marker.Position).Magnitude > WC.InteractRadius + 4 then
			return
		end
		attune(player, id)
		Net.fire(player, "WaystoneMenu", id, discovered(player))
	end)
end

local function registerChest(marker: Instance)
	if not marker:IsA("BasePart") then
		return
	end
	local id = marker:GetAttribute("MarkerId")
	if type(id) ~= "string" or chests[id] then
		return
	end
	chests[id] = marker
	local prompt = makePrompt(marker, Strings.get("Prompt.OpenChest"), Strings.get("Prompt.Chest"), "Chest", TC.HoldSeconds, TC.InteractRadius)
	prompt:SetAttribute("ChestId", id)
	prompt.Triggered:Connect(function(player: Player)
		openChest(player, id)
	end)
end

local function spawnCFrame(player: Player): CFrame?
	local data = DataService.Get(player)
	local last = if data then data.LastWaystone[floorId()] else nil
	if last and waystones[last] then
		return arrivalCFrame(waystones[last], player)
	end
	for _, m in CollectionService:GetTagged("FloorSpawn") do
		if m:IsA("BasePart") and m:GetAttribute("MarkerId") == floorId() then
			return (m :: BasePart).CFrame + Vector3.new(0, 3, 0)
		end
	end
	for _, marker in waystones do
		if marker:GetAttribute("Starting") == true then
			return arrivalCFrame(marker, player)
		end
	end
	return nil
end

local function onCharacterAdded(player: Player, character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not root then
		return
	end
	if player:GetAttribute("InDungeon") then
		return -- DungeonService places characters inside instances
	end
	DataService.WaitFor(player, 20)
	local cf = spawnCFrame(player)
	if cf and character.Parent then
		moveCharacter(player, cf)
	end
end

function FloorService.Init()
	Net.onEvent("RequestWaystoneTravel", travel)
	Net.onEvent("RequestOpenChest", openChest)
	Net.onInvoke("RequestWorldState", function(player: Player): any
		local data = DataService.WaitFor(player, 15)
		local opened = {}
		if data then
			for id in data.Chests do
				table.insert(opened, id)
			end
		end
		return {
			floor = floorId(),
			waystones = discovered(player),
			chests = opened,
			lastWaystone = if data then data.LastWaystone[floorId()] else nil,
		}
	end)
end

function FloorService.Start()
	for _, m in CollectionService:GetTagged("Waystone") do
		registerWaystone(m)
	end
	CollectionService:GetInstanceAddedSignal("Waystone"):Connect(registerWaystone)
	for _, m in CollectionService:GetTagged("TreasureChest") do
		registerChest(m)
	end
	CollectionService:GetInstanceAddedSignal("TreasureChest"):Connect(registerChest)

	local function hook(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			onCharacterAdded(player, character)
		end)
		if player.Character then
			task.spawn(onCharacterAdded, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(hook)
	for _, p in Players:GetPlayers() do
		hook(p)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		lastTravel[player] = nil
	end)
	DataService.ProfileLoaded:Connect(function(player: Player, data)
		local last = data.LastWaystone[floorId()]
		if last then
			player:SetAttribute("LastWaystone", last)
		end
	end)

	-- discovery by walking past a waystone
	task.spawn(function()
		while true do
			task.wait(WC.ScanInterval)
			for _, player in Players:GetPlayers() do
				local root = rootOf(player)
				if root then
					local id = nearestWaystone(root.Position, WC.DiscoverRadius)
					if id and not isDiscovered(player, id) and DataService.Get(player) then
						attune(player, id)
					end
				end
			end
		end
	end)
end

function FloorService.GetWaystone(id: string): BasePart?
	return waystones[id]
end

return FloorService
