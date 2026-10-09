--!strict
--[[
	Arena (GuardianService)
	One party's copy of a Guardian arena, cloned from ServerStorage.GuardianArenas.<name> into a
	slot beyond the Spire wall, and the arena state that follows the fight: tide water height,
	tide-line runes, the Pressure zone and the seal over the gate.

	Template contract (docs/PHASE10_GUARDIAN.md section 3): a Model with PrimaryPart Origin (floor
	centre, +Z toward the gate) holding BossSpawn, PlayerSpawns (parts, optional Index attribute),
	AddPools (parts), TideWater (attributes CalmY / HighY / EbbY, offsets from Origin), TideLines
	(Neon parts), PressureZone, Seal and Bounds (attribute Radius).
]]

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local PressureService = require(script.Parent.Parent.PressureService)
local Types = require(script.Parent.Types)

local G = Config.Mobs.Guardian
local RAY_LIFT = 1 -- ground rays start this far above the point (a ray born on a surface can miss it)

local Arena = {}

local function part(parent: Instance, name: string): BasePart?
	local found = parent:FindFirstChild(name)
	return if found and found:IsA("BasePart") then found else nil
end

-- Parts directly in a child folder or model (or the child itself if it is a part).
local function partsIn(parent: Instance, name: string): { BasePart }
	local holder = parent:FindFirstChild(name)
	local list: { BasePart } = {}
	if not holder then
		return list
	end
	if holder:IsA("BasePart") then
		table.insert(list, holder)
	end
	for _, child in holder:GetDescendants() do
		if child:IsA("BasePart") then
			table.insert(list, child)
		end
	end
	return list
end

-- The template for a Guardian's arena (nil if the edit-time tool hasn't built it).
function Arena.Template(name: string): Model?
	local folder = ServerStorage:FindFirstChild("GuardianArenas")
	local template = folder and folder:FindFirstChild(name)
	return if template and template:IsA("Model") then template else nil
end

-- Where slot `slot` (1..MaxArenas) is laid out.
function Arena.SlotOrigin(slot: number): CFrame
	return CFrame.new(G.ArenaOrigin + Vector3.new(0, 0, G.ArenaSpacing * (slot - 1)))
end

function Arena.Create(template: Model, slot: number, parent: Instance, name: string): Types.Arena
	local origin = Arena.SlotOrigin(slot)
	local model = template:Clone()
	model.Name = name
	model:PivotTo(origin)
	model.Parent = parent

	local originPart = model.PrimaryPart or part(model, "Origin")
	local originCFrame = if originPart then originPart.CFrame else origin

	local bounds = part(model, "Bounds")
	local radiusAttr = bounds and bounds:GetAttribute("Radius")
	local radius = if type(radiusAttr) == "number" and radiusAttr > 0 then radiusAttr else model:GetExtentsSize().X / 2

	local boss = part(model, "BossSpawn")
	local spawnParts = partsIn(model, "PlayerSpawns")
	table.sort(spawnParts, function(a: BasePart, b: BasePart): boolean
		local ia = a:GetAttribute("Index")
		local ib = b:GetAttribute("Index")
		local na = if type(ia) == "number" then ia else math.huge
		local nb = if type(ib) == "number" then ib else math.huge
		if na ~= nb then
			return na < nb
		end
		return a.Name < b.Name
	end)
	local spawns: { CFrame } = {}
	for _, p in spawnParts do
		table.insert(spawns, p.CFrame)
	end
	local pools: { Vector3 } = {}
	for _, p in partsIn(model, "AddPools") do
		table.insert(pools, p.Position)
	end

	-- Visual-only parts never block raycasts (spawning, telegraph snapping) or touches.
	local water = part(model, "TideWater")
	local waterY: { [string]: number } = {}
	if water then
		water.CanCollide = false
		water.CanQuery = false
		water.CanTouch = false
		for _, level in { "Calm", "High", "Ebb" } do
			local y = water:GetAttribute(`{level}Y`)
			waterY[level] = if type(y) == "number" then y else 0
		end
	end
	local lines = partsIn(model, "TideLines")
	local dim: { [BasePart]: number } = {}
	for _, line in lines do
		line.CanQuery = false
		line.CanTouch = false
		dim[line] = line.Transparency
	end
	for _, p in { part(model, "BossSpawn"), part(model, "Bounds"), originPart } do
		if p then
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.Transparency = 1
		end
	end
	for _, p in spawnParts do
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Transparency = 1
	end

	return {
		Model = model,
		Slot = slot,
		Origin = originCFrame,
		Radius = radius,
		BossSpawn = if boss then boss.CFrame else originCFrame,
		PlayerSpawns = spawns,
		AddPools = pools,
		Water = water,
		WaterY = waterY,
		TideLines = lines,
		LineDim = dim,
		PressureZone = part(model, "PressureZone"),
		Seal = part(model, "Seal"),
	}
end

-- Inside the walkable circle (with `margin` extra studs), within a generous height band.
function Arena.Inside(arena: Types.Arena, position: Vector3, margin: number): boolean
	local localPoint = arena.Origin:PointToObjectSpace(position)
	local flatDistance = Vector3.new(localPoint.X, 0, localPoint.Z).Magnitude
	return flatDistance <= arena.Radius + margin and math.abs(localPoint.Y) <= arena.Radius
end

-- Pulls a point back inside the walkable circle, `margin` studs from the wall.
function Arena.Clamp(arena: Types.Arena, position: Vector3, margin: number): Vector3
	local center = arena.Origin.Position
	local offset = Vector3.new(position.X - center.X, 0, position.Z - center.Z)
	local limit = math.max(0, arena.Radius - margin)
	if offset.Magnitude <= limit then
		return position
	end
	local clamped = center + offset.Unit * limit
	return Vector3.new(clamped.X, position.Y, clamped.Z)
end

-- The arena floor under a point (only the arena's own colliding parts count). The ray starts at
-- the point (a character's or the Warden's root) so arches overhead never catch it.
function Arena.Ground(arena: Types.Arena, position: Vector3): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { arena.Model }
	params.RespectCanCollide = true
	local top = Vector3.new(position.X, math.max(position.Y, arena.Origin.Position.Y) + RAY_LIFT, position.Z)
	local hit = Workspace:Raycast(top, Vector3.new(0, -arena.Radius, 0), params)
	return if hit then hit.Position else Vector3.new(position.X, arena.Origin.Position.Y, position.Z)
end

function Arena.SetWater(arena: Types.Arena, level: string, seconds: number)
	local water = arena.Water
	if not water then
		return
	end
	local y = arena.WaterY[level] or 0
	local position = water.Position
	local goal = CFrame.new(position.X, arena.Origin.Position.Y + y, position.Z) * water.CFrame.Rotation
	if seconds <= 0 then
		water.CFrame = goal
		return
	end
	TweenService:Create(water, TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { CFrame = goal }):Play()
end

-- Tide-line runes light up at high tide and fall back to their built (dim) look otherwise.
function Arena.SetTideLines(arena: Types.Arena, lit: boolean, seconds: number)
	for _, line in arena.TideLines do
		local goal = if lit then 0 else arena.LineDim[line] or line.Transparency
		if seconds <= 0 then
			line.Transparency = goal
		else
			TweenService:Create(line, TweenInfo.new(seconds, Enum.EasingStyle.Sine), { Transparency = goal }):Play()
		end
	end
end

function Arena.SetPressure(arena: Types.Arena, level: number)
	local zone = arena.PressureZone
	if zone then
		PressureService.SetZonePressure(zone, level)
	end
end

function Arena.SetSealed(arena: Types.Arena, sealed: boolean)
	local seal = arena.Seal
	if seal then
		seal.CanCollide = sealed
	end
end

function Arena.Destroy(arena: Types.Arena)
	arena.Model:Destroy()
end

return Arena
