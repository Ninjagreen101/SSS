--!strict
-- TerrainApplier (edit time): writes a TerrainPlanner field into Roblox
-- Terrain with WriteVoxels in chunks (smooth sub-voxel occupancy for the
-- surface, terrain water below each column's water level), then applies cave
-- carves. Also sets the floor's terrain material colours and water look.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Config = require(Shared.Config)

local TerrainPlanner = require(script.Parent.Plan.TerrainPlanner)
local HiddenPlanner = require(script.Parent.Plan.HiddenPlanner)

type FloorDef = Types.FloorDef
type Field = TerrainPlanner.Field
type TerrainCarve = HiddenPlanner.TerrainCarve

local TC = Config.World.Terrain
local Palette = Config.Palette

local TerrainApplier = {}

local MATERIAL_COLORS: { [string]: string } = {
	Grass = "GrassTuft",
	LeafyGrass = "LeafGreen",
	Mud = "Mud",
	Ground = "Bark",
	Rock = "Rock",
	Slate = "StoneWet",
	Basalt = "TowerStone",
	Sand = "Sand",
	Cobblestone = "Stone",
	Pavement = "StoneLight",
	WoodPlanks = "WoodWet",
}

local function terrainMaterial(name: string): Enum.Material
	local ok, m = pcall(function(): Enum.Material
		return (Enum.Material :: any)[name]
	end)
	if ok and m then
		return m
	end
	return Enum.Material.Ground
end

function TerrainApplier.configure(terrain: Terrain)
	for name, key in MATERIAL_COLORS do
		local color = Palette[key]
		if color then
			terrain:SetMaterialColor(terrainMaterial(name), color)
		end
	end
	terrain.WaterColor = Palette.Water
	terrain.WaterTransparency = 0.55
	terrain.WaterReflectance = 0.85
	terrain.WaterWaveSize = 0.18
	terrain.WaterWaveSpeed = 9
	(terrain :: any).Decoration = true -- animated grass on Grass terrain
end

export type TerrainOptions = {
	clear: boolean?,
	onProgress: ((done: number, total: number) -> ())?,
}

function TerrainApplier.apply(field: Field, floor: FloorDef, carves: { TerrainCarve }, opts: TerrainOptions?)
	local o: TerrainOptions = opts or {}
	local terrain = Workspace.Terrain
	TerrainApplier.configure(terrain)
	if o.clear ~= false then
		terrain:Clear()
	end
	local res = TC.VoxelResolution
	local chunk = TC.WriteChunk
	local half = floor.size / 2
	local cells = math.floor(floor.size / res)
	local chunksPerSide = math.ceil(cells / chunk)
	local total = chunksPerSide * chunksPerSide
	local done = 0

	for ci = 0, chunksPerSide - 1 do
		for cj = 0, chunksPerSide - 1 do
			local i0 = ci * chunk
			local j0 = cj * chunk
			local nx = math.min(chunk, cells - i0)
			local nz = math.min(chunk, cells - j0)
			-- sample columns at voxel centres
			local heights = table.create(nx * nz, 0)
			local mats: { string } = table.create(nx * nz, "Ground")
			local waters: { number } = table.create(nx * nz, -math.huge)
			local lo, hi = math.huge, -math.huge
			for i = 1, nx do
				for j = 1, nz do
					local x = -half + (i0 + i - 0.5) * res
					local z = -half + (j0 + j - 0.5) * res
					local s = field:sample(x, z)
					local k = (i - 1) * nz + j
					heights[k] = s.height
					mats[k] = s.material
					local w = s.water
					if w then
						waters[k] = w
					end
					lo = math.min(lo, s.height)
					hi = math.max(hi, s.height, w or -math.huge)
				end
			end
			local y0 = math.floor((lo - 8) / res) * res
			local y1 = math.ceil((hi + 1) / res) * res
			local ny = math.max(1, (y1 - y0) / res)
			local materials = table.create(nx)
			local occupancy = table.create(nx)
			for i = 1, nx do
				local mx = table.create(ny)
				local ox = table.create(ny)
				for yv = 1, ny do
					local my = table.create(nz)
					local oy = table.create(nz)
					local vy = y0 + (yv - 1) * res
					for j = 1, nz do
						local k = (i - 1) * nz + j
						local h = heights[k]
						local occ = math.clamp((h - vy) / res, 0, 1)
						if occ > 0.02 then
							my[j] = terrainMaterial(mats[k])
							oy[j] = occ
						else
							local w = waters[k]
							if w > vy then
								my[j] = Enum.Material.Water
								oy[j] = math.clamp((w - vy) / res, 0, 1)
							else
								my[j] = Enum.Material.Air
								oy[j] = 0
							end
						end
					end
					mx[yv] = my
					ox[yv] = oy
				end
				materials[i] = mx
				occupancy[i] = ox
			end
			local minV = Vector3.new(-half + i0 * res, y0, -half + j0 * res)
			local maxV = minV + Vector3.new(nx * res, ny * res, nz * res)
			terrain:WriteVoxels(Region3.new(minV, maxV), res, materials, occupancy)
			done += 1
			if o.onProgress then
				(o.onProgress :: (number, number) -> ())(done, total)
			end
			task.wait()
		end
	end

	-- caves and grottoes
	for _, c in carves do
		if c.op == "Air" then
			local cf = CFrame.new(c.x, c.y, c.z) * CFrame.Angles(0, c.ry, 0)
			if c.shape == "Ball" then
				terrain:FillBall(Vector3.new(c.x, c.y, c.z), c.sx / 2, Enum.Material.Air)
			else
				terrain:FillBlock(cf, Vector3.new(c.sx, c.sy, c.sz), Enum.Material.Air)
			end
		end
	end
end

return TerrainApplier
