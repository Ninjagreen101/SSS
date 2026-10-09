--!strict
-- WorldService: the floor's shared world state. Runs the day/night cycle
-- (a full day every Config.World.DayNight.CycleMinutes real minutes), tracks
-- which zone every player stands in (zone name, kind, safety, level range and
-- Current Pressure as player attributes the HUD reads) and heals players who
-- rest in town Current pools.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Config = require(Shared.Config)
local Geom = require(Shared.Util.Geom)
local Signal = require(Shared.Util.Signal)
local Floors = require(Shared.Data.Floors)
local Net = require(Shared.Net)

type ZoneDef = Types.ZoneDef
type FloorDef = Types.FloorDef

local W = Config.World

local WorldService = {
	ZoneChanged = Signal.new() :: Signal.Signal<Player, string, string?>,
	Floor = (nil :: any) :: FloorDef,
}

local zones: { ZoneDef } = {}
local current: { [Player]: string } = {}
local healing: { [Player]: boolean } = {}

local function resolveFloor(): FloorDef
	local id = Workspace:GetAttribute("FloorId")
	if type(id) == "string" and Floors.ById[id] then
		return Floors.ById[id]
	end
	local floorsFolder = Workspace:FindFirstChild("Floors")
	if floorsFolder then
		for _, child in floorsFolder:GetChildren() do
			if Floors.ById[child.Name] then
				return Floors.ById[child.Name]
			end
		end
	end
	return Floors.ByIndex[1]
end

-- Highest-priority zone containing the position (nil outside every zone).
function WorldService.GetZoneAt(position: Vector3): ZoneDef?
	local best: ZoneDef? = nil
	for _, z in zones do
		if position.Y >= z.minY and position.Y <= z.maxY and Geom.pointInPolygon(position.X, position.Z, z.polygon) then
			if best == nil or z.priority > (best :: ZoneDef).priority then
				best = z
			end
		end
	end
	return best
end

function WorldService.GetPressure(position: Vector3): number
	local z = WorldService.GetZoneAt(position)
	return if z then z.pressure else 3
end

function WorldService.IsNight(): boolean
	local t = Lighting.ClockTime
	return t >= W.DayNight.NightStart or t < W.DayNight.NightEnd
end

local function applyZone(player: Player, zoneId: string, z: ZoneDef?, dungeonId: string?)
	local prev = current[player]
	if prev == zoneId then
		return
	end
	current[player] = zoneId
	if dungeonId then
		player:SetAttribute("Zone", zoneId)
		player:SetAttribute("ZoneName", "Dungeon." .. dungeonId)
		player:SetAttribute("ZoneKind", "Dungeon")
		player:SetAttribute("ZoneSafe", false)
		player:SetAttribute("Pressure", 4)
		player:SetAttribute("ZoneAmbience", "Dungeon")
		player:SetAttribute("ZoneLevelMin", 7)
		player:SetAttribute("ZoneLevelMax", 12)
	elseif z then
		player:SetAttribute("Zone", z.id)
		player:SetAttribute("ZoneName", z.nameKey)
		player:SetAttribute("ZoneKind", z.kind)
		player:SetAttribute("ZoneSafe", z.safe)
		player:SetAttribute("Pressure", z.pressure)
		player:SetAttribute("ZoneAmbience", z.ambience)
		player:SetAttribute("ZoneLevelMin", z.levelRange[1])
		player:SetAttribute("ZoneLevelMax", z.levelRange[2])
	else
		player:SetAttribute("Zone", "wilds")
		player:SetAttribute("ZoneName", "Zone.Wilds")
		player:SetAttribute("ZoneKind", "Wild")
		player:SetAttribute("ZoneSafe", false)
		player:SetAttribute("Pressure", 3)
		player:SetAttribute("ZoneAmbience", "Highland")
	end
	WorldService.ZoneChanged:Fire(player, zoneId, prev)
end

-- true when the root stands in (or just above) a tagged healing Current surface
local function inHealingCurrent(root: BasePart): boolean
	local pos = root.Position
	for _, part in CollectionService:GetTagged("HealingCurrent") do
		if part:IsA("BasePart") then
			local p = part :: BasePart
			local lp = p.CFrame:PointToObjectSpace(pos)
			local half = p.Size / 2
			local isCylinder = p:IsA("Part") and (p :: Part).Shape == Enum.PartType.Cylinder
			if isCylinder then
				-- cylinder axis is local X; the pool is a vertical disc
				local r = math.min(half.Y, half.Z)
				if math.sqrt(lp.Y * lp.Y + lp.Z * lp.Z) <= r and math.abs(lp.X) <= half.X + 6 then
					return true
				end
			elseif math.abs(lp.X) <= half.X and math.abs(lp.Z) <= half.Z and lp.Y <= half.Y + 6 and lp.Y >= -half.Y - 8 then
				return true
			end
		end
	end
	for _, marker in CollectionService:GetTagged("HealingPool") do
		if marker:IsA("BasePart") then
			local radius = (marker:GetAttribute("Radius") :: number?) or 8
			if (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(marker.Position.X, 0, marker.Position.Z)).Magnitude <= radius and math.abs(pos.Y - marker.Position.Y) < 8 then
				return true
			end
		end
	end
	return false
end

local function heal(player: Player, dt: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 then
		return
	end
	if player:GetAttribute("ZoneSafe") ~= true or not inHealingCurrent(root :: BasePart) then
		healing[player] = nil
		return
	end
	if not healing[player] then
		healing[player] = true
		Net.fire(player, "WorldFeedback", "Heal", "Healing.Pool", nil)
	end
	local amount = humanoid.MaxHealth * W.Canals.HealPerSecond / 100 * dt
	humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + amount)
end

function WorldService.Init()
	local floor = resolveFloor()
	WorldService.Floor = floor
	zones = floor.zones
	Workspace:SetAttribute("FloorId", floor.id)
	Workspace:SetAttribute("FloorIndex", floor.index)
	Lighting.ClockTime = W.DayNight.StartClockTime
end

function WorldService.Start()
	-- day / night: hours advance at 24 per CycleMinutes
	local hoursPerSecond = 24 / (W.DayNight.CycleMinutes * 60)
	RunService.Heartbeat:Connect(function(dt: number)
		Lighting.ClockTime = (Lighting.ClockTime + dt * hoursPerSecond) % 24
	end)
	task.spawn(function()
		while true do
			local isNight = WorldService.IsNight()
			if Workspace:GetAttribute("IsNight") ~= isNight then
				Workspace:SetAttribute("IsNight", isNight)
			end
			task.wait(W.DayNight.ReplicateInterval)
		end
	end)

	-- zones and healing pools
	local interval = W.Zones.CheckInterval
	task.spawn(function()
		while true do
			for _, player in Players:GetPlayers() do
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") then
					local dungeonId = player:GetAttribute("InDungeon")
					if type(dungeonId) == "string" and dungeonId ~= "" then
						applyZone(player, "dungeon_" .. dungeonId, nil, dungeonId)
					else
						local z = WorldService.GetZoneAt(root.Position)
						applyZone(player, if z then z.id else "wilds", z, nil)
					end
					heal(player, interval)
				end
			end
			task.wait(interval)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		current[player] = nil
		healing[player] = nil
	end)
end

return WorldService
