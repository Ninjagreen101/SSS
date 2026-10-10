--!strict
--[[
	MapService
	What each player has explored and the pins they placed (docs/PHASE11_QUESTS.md, Map (M)).

	- Exploration: every Config.Quests.Map.CheckSeconds the cell under each player (a Cells x Cells
	  grid over Config.World.Maps[floor]) and the cells within RevealRadius of it are revealed.
	  The grid lives in memory while the player is here and is written to Data.Map.Explored[floor]
	  (a hex bitset, see Fog) only when a cell is new. Floors without a map square aren't tracked.
	- Pins: RequestMapPin("Add", x, z, icon) adds a pin on this floor inside its map square (up to
	  MaxPins; icon is a short id the client draws, "" = its default); RequestMapPin("Remove", x, z)
	  removes the pin nearest (x, z) within PinRemoveRadius. Pins live in Data.Map.Pins[floor].
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Types = require(Shared.Types)

local DataService = require(script.Parent.DataService)
local FloorService = require(script.Parent.FloorService)
local Fog = require(script.Fog)

local MAP = Config.Quests.Map

type Explored = { Floor: string, Grid: Fog.Grid }

local MapService = {}

local explored: { [Player]: Explored } = {}

local function mapSquare(floor: string): { Image: string, Center: Vector2, Size: number }?
	return Config.World.Maps[floor]
end

local function rootPosition(player: Player): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

local function load(player: Player)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	local floor = FloorService.GetFloorId()
	local saved = data.Map.Explored[floor]
	explored[player] = { Floor = floor, Grid = Fog.Decode(if type(saved) == "string" then saved else "", MAP.Cells) }
end

local function scan()
	for player, entry in explored do
		local square = mapSquare(entry.Floor)
		local position = rootPosition(player)
		if not square or not position or not DataService.IsLoaded(player) then
			continue
		end
		local row, col = Fog.Cell(position.X, position.Z, square.Center.X, square.Center.Y, square.Size, MAP.Cells)
		if row and col and Fog.Reveal(entry.Grid, MAP.Cells, row, col, MAP.RevealRadius) then
			DataService.Set(player, { "Map", "Explored", entry.Floor }, Fog.Encode(entry.Grid))
		end
	end
end

local function round(value: number): number
	return math.floor(value * 10 + 0.5) / 10
end

local function onPin(player: Player, action: string, x: number, z: number, icon: string)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	local floor = FloorService.GetFloorId()
	local pins: { Types.MapPin } = data.Map.Pins[floor] or {}
	if action == "Add" then
		local square = mapSquare(floor)
		if not square or not string.match(icon, "^[%w_]*$") then
			return
		end
		local half = square.Size / 2
		if math.abs(x - square.Center.X) > half or math.abs(z - square.Center.Y) > half then
			return
		end
		if #pins >= MAP.MaxPins then
			Net.Fire("Notify", player, "QuestUI.MapPinsFull", { count = MAP.MaxPins }, "Warning")
			return
		end
		local list = table.clone(pins)
		table.insert(list, { X = round(x), Z = round(z), Icon = icon })
		DataService.Set(player, { "Map", "Pins", floor }, list)
	elseif action == "Remove" then
		local nearest: number? = nil
		local best = MAP.PinRemoveRadius
		for index, pin in pins do
			local distance = math.sqrt((pin.X - x) ^ 2 + (pin.Z - z) ^ 2)
			if distance <= best then
				best = distance
				nearest = index
			end
		end
		if nearest then
			local list = table.clone(pins)
			table.remove(list, nearest)
			DataService.Set(player, { "Map", "Pins", floor }, list)
		end
	end
end

function MapService.Init()
	Net.On("RequestMapPin", onPin)
end

function MapService.Start()
	DataService.ProfileLoaded:Connect(function(player: Player)
		load(player)
	end)
	for _, player in Players:GetPlayers() do
		if DataService.IsLoaded(player) then
			load(player)
		end
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		explored[player] = nil
	end)
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator >= MAP.CheckSeconds then
			accumulator = 0
			scan()
		end
	end)
end

return MapService
