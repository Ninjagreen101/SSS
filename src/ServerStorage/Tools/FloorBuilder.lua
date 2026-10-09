--!strict
--[[
	FloorBuilder (edit-time tool)
	Writes a floor's terrain from its layout module (Layouts/<Floor>) and builds the floor's
	backdrop: the rock underside of the platform, the distant tower wall, the drowned world far
	below, the Current falls where the harbour spills off the edge, and invisible edge barriers.

	The layout supplies four pure functions of world (x, z):
	    Height(x, z) -> surface y          Material(x, z, h, slopeDegrees) -> Enum.Material
	    Water(x, z, h) -> water y or nil   Bounds (half size of the platform)
	Terrain is written in 128 x 128 stud columns (32 x 32 voxels), from y = BOTTOM up to the highest
	surface in the column, so the job can be split across several Command Bar runs:

	    local FB = require(game.ServerStorage.Tools.FloorBuilder)
	    local L = require(game.ServerStorage.Tools.Layouts.Floor1)
	    FB.ClearTerrain()
	    local nextChunk = 1
	    repeat nextChunk = FB.WriteTerrain(L, nextChunk, 20) until nextChunk == 0  -- 20 s per run
	    FB.BuildBackdrop(L, workspace)
]]

local Workspace = game:GetService("Workspace")

export type Layout = {
	Bounds: number,
	Height: (x: number, z: number) -> number,
	Material: (x: number, z: number, h: number, slope: number) -> Enum.Material,
	Water: (x: number, z: number, h: number) -> number?,
	InTown: (x: number, z: number) -> boolean,
	Region: (x: number, z: number) -> string,
}

local FloorBuilder = {}

local VOXEL = 4
local CHUNK = 32 -- voxels per chunk side
FloorBuilder.Bottom = -48 -- underside of the terrain slab (the backdrop's rock skirt continues below)

-- What lies under a surface material (exposed on cliffs, terrace walls and canal sides).
local UNDER: { [Enum.Material]: Enum.Material } = {
	[Enum.Material.Sand] = Enum.Material.Sandstone,
	[Enum.Material.Mud] = Enum.Material.Mud,
	[Enum.Material.Cobblestone] = Enum.Material.Slate,
	[Enum.Material.Pavement] = Enum.Material.Slate,
	[Enum.Material.Slate] = Enum.Material.Slate,
	[Enum.Material.Rock] = Enum.Material.Rock,
}

local function chunkCount(layout: Layout): number
	local cells = math.ceil(layout.Bounds * 2 / VOXEL)
	local per = math.ceil(cells / CHUNK)
	return per * per
end
FloorBuilder.ChunkCount = chunkCount

function FloorBuilder.ClearTerrain()
	Workspace.Terrain:Clear()
end

-- Writes one 128 x 128 column of terrain. Returns the number of voxels written.
function FloorBuilder.WriteChunk(layout: Layout, index: number): number
	local B = layout.Bounds
	local cells = math.ceil(B * 2 / VOXEL)
	local per = math.ceil(cells / CHUNK)
	local ci = (index - 1) % per
	local ck = (index - 1) // per
	local i0 = ci * CHUNK
	local k0 = ck * CHUNK
	local nx = math.min(CHUNK, cells - i0)
	local nz = math.min(CHUNK, cells - k0)
	if nx <= 0 or nz <= 0 then
		return 0
	end

	-- heights (with a one-cell border for slopes), materials and water per column
	local hs: { { number } } = {}
	for a = 0, nx + 1 do
		local col: { number } = {}
		local x = -B + (i0 + a - 1) * VOXEL + VOXEL / 2
		for b = 0, nz + 1 do
			local z = -B + (k0 + b - 1) * VOXEL + VOXEL / 2
			col[b + 1] = layout.Height(x, z)
		end
		hs[a + 1] = col
	end
	local surf: { { Enum.Material } } = {}
	local under: { { Enum.Material } } = {}
	local water: { { number } } = {}
	local top = -math.huge
	for a = 1, nx do
		surf[a], under[a], water[a] = {}, {}, {}
		local x = -B + (i0 + a - 1) * VOXEL + VOXEL / 2
		for b = 1, nz do
			local z = -B + (k0 + b - 1) * VOXEL + VOXEL / 2
			local h = hs[a + 1][b + 1]
			local dx = (hs[a + 2][b + 1] - hs[a][b + 1]) / (2 * VOXEL)
			local dz = (hs[a + 1][b + 2] - hs[a + 1][b]) / (2 * VOXEL)
			local slope = math.deg(math.atan(math.sqrt(dx * dx + dz * dz)))
			local m = layout.Material(x, z, h, slope)
			surf[a][b] = m
			under[a][b] = UNDER[m] or (if layout.InTown(x, z) then Enum.Material.Slate else Enum.Material.Rock)
			local w = layout.Water(x, z, h)
			water[a][b] = w or -math.huge
			top = math.max(top, h, w or -math.huge)
		end
	end

	local yLo = FloorBuilder.Bottom
	local yHi = math.ceil((top + 2) / VOXEL) * VOXEL
	local ny = (yHi - yLo) // VOXEL
	-- Written as explicit channels: the legacy WriteVoxels leaves an old solid occupancy behind
	-- when a voxel becomes water (the canals stayed half-filled with stone). Water fills the free
	-- part of any voxel below the water line, including the partly solid one at the bed.
	local mats: { { { Enum.Material } } } = table.create(nx)
	local occ: { { { number } } } = table.create(nx)
	local liquid: { { { number } } } = table.create(nx)
	local written = 0
	for a = 1, nx do
		local mA: { { Enum.Material } } = table.create(ny)
		local oA: { { number } } = table.create(ny)
		local lA: { { number } } = table.create(ny)
		for j = 1, ny do
			mA[j] = table.create(nz, Enum.Material.Air)
			oA[j] = table.create(nz, 0)
			lA[j] = table.create(nz, 0)
		end
		for b = 1, nz do
			local h = hs[a + 1][b + 1]
			local w = water[a][b]
			for j = 1, ny do
				local yb = yLo + (j - 1) * VOXEL
				local fill = math.clamp((h - yb) / VOXEL, 0, 1)
				if fill > 0 then
					oA[j][b] = fill
					if h - yb < VOXEL * 2 then
						mA[j][b] = surf[a][b]
					elseif yb < yLo + 12 then
						mA[j][b] = Enum.Material.Basalt
					else
						mA[j][b] = under[a][b]
					end
					written += 1
				end
				if yb < w and fill < 1 then
					lA[j][b] = math.clamp((w - yb) / VOXEL, 0, 1)
					written += 1
				end
			end
		end
		mats[a] = mA
		occ[a] = oA
		liquid[a] = lA
	end
	local x0 = -B + i0 * VOXEL
	local z0 = -B + k0 * VOXEL
	local region = Region3.new(Vector3.new(x0, yLo, z0), Vector3.new(x0 + nx * VOXEL, yHi, z0 + nz * VOXEL))
	Workspace.Terrain:WriteVoxelChannels(region, VOXEL, {
		SolidMaterial = mats,
		SolidOccupancy = occ,
		LiquidOccupancy = liquid,
	})
	return written
end

-- Writes chunks from `first` until `budget` seconds pass. Returns the next chunk to write (0 = done).
function FloorBuilder.WriteTerrain(layout: Layout, first: number, budget: number?): number
	local total = chunkCount(layout)
	local started = os.clock()
	local index = first
	while index <= total do
		FloorBuilder.WriteChunk(layout, index)
		index += 1
		if os.clock() - started > (budget or 20) then
			break
		end
	end
	return if index > total then 0 else index
end

-- REGION GRID -------------------------------------------------------------------------

-- One letter per region; the client reads the grid to pick ambience (EnvironmentController).
FloorBuilder.RegionLetters = {
	Town = "T",
	Harbour = "H",
	OldWharf = "W",
	TidepoolMarsh = "M",
	RustwoodForest = "F",
	Downs = "D",
	Cistern = "C",
	FirstGate = "G",
}

--[[
	Bakes ReplicatedStorage.FloorData.Regions: a StringValue holding a grid of region letters,
	row by row from the north-west corner (z rows, x columns), `cell` studs per letter.
	Attributes: Cell, Origin (x, z of the first cell's corner), Columns, Legend ("T=Town,...").
]]
function FloorBuilder.BakeRegions(layout: Layout, cell: number): StringValue
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local folder = ReplicatedStorage:FindFirstChild("FloorData")
	if not folder then
		local f = Instance.new("Folder")
		f.Name = "FloorData"
		f.Parent = ReplicatedStorage
		folder = f
	end
	assert(folder, "FloorData")
	local value = folder:FindFirstChild("Regions")
	if not (value and value:IsA("StringValue")) then
		local v = Instance.new("StringValue")
		v.Name = "Regions"
		v.Parent = folder
		value = v
	end
	assert(value and value:IsA("StringValue"), "Regions")
	local B = layout.Bounds
	local n = math.ceil(2 * B / cell)
	local rows = table.create(n)
	for k = 0, n - 1 do
		local row = table.create(n)
		local z = -B + (k + 0.5) * cell
		for i = 0, n - 1 do
			local x = -B + (i + 0.5) * cell
			row[i + 1] = FloorBuilder.RegionLetters[layout.Region(x, z)] or "D"
		end
		rows[k + 1] = table.concat(row)
	end
	value.Value = table.concat(rows)
	value:SetAttribute("Cell", cell)
	value:SetAttribute("Origin", Vector2.new(-B, -B))
	value:SetAttribute("Columns", n)
	local legend = {}
	for name, letter in FloorBuilder.RegionLetters do
		table.insert(legend, `{letter}={name}`)
	end
	table.sort(legend)
	value:SetAttribute("Legend", table.concat(legend, ","))
	return value
end

-- BACKDROP -----------------------------------------------------------------------------

local ROCK = Color3.fromHex("#2E3236")
local WALL = Color3.fromHex("#2A3038")
local CURRENT = Color3.fromHex("#3FE0D0")

local function block(parent: Instance, name: string, size: Vector3, cf: CFrame, material: Enum.Material, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Material = material
	p.Color = color
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

--[[
	Builds Workspace.<floor>.Backdrop:
	  Underside   three stepped rock layers under the platform (quarters, parts are capped at 2048)
	  TowerWall   a ring of the Spire's inner wall at radius 2400 with glowing Current veins
	  Drowned     the drowned world far below (a dark sea plane, hazed by Atmosphere)
	  CurrentFalls  where the harbour pours off the west edge
	  EdgeBarrier invisible walls along the platform edge
	The backdrop model is Persistent so far-away scenery never streams out.
]]
function FloorBuilder.BuildBackdrop(layout: Layout, parent: Instance, opts: { Falls: { Z0: number, Z1: number }? }?): Model
	local old = parent:FindFirstChild("Backdrop")
	if old then
		old:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = "Backdrop"
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	local B = layout.Bounds
	local bottom = FloorBuilder.Bottom

	-- underside: stepped layers, each split into quarters
	local under = Instance.new("Folder")
	under.Name = "Underside"
	under.Parent = model
	local layers = { { inset = 0, h = 70 }, { inset = 70, h = 90 }, { inset = 170, h = 130 } }
	local y = bottom
	for li, layer in layers do
		local half = B - layer.inset
		for _, q in { Vector2.new(-1, -1), Vector2.new(1, -1), Vector2.new(-1, 1), Vector2.new(1, 1) } do
			local cf = CFrame.new(q.X * half / 2, y - layer.h / 2, q.Y * half / 2)
			block(under, `Layer{li}`, Vector3.new(half, layer.h, half), cf, Enum.Material.Basalt, ROCK)
		end
		y -= layer.h
	end

	-- tower wall
	local wall = Instance.new("Folder")
	wall.Name = "TowerWall"
	wall.Parent = model
	local R, SEG = 2400, 48
	local chord = 2 * math.pi * R / SEG + 8
	for i = 0, SEG - 1 do
		local ang = (i + 0.5) / SEG * 2 * math.pi
		local base = CFrame.new(math.cos(ang) * R, 0, math.sin(ang) * R) * CFrame.Angles(0, -ang + math.pi / 2, 0)
		for k, cy in { -400, 800 } do
			block(wall, `Wall{i}_{k}`, Vector3.new(chord, 1200, 80), base + Vector3.new(0, cy, 0), Enum.Material.Slate, WALL)
		end
		if i % 3 == 0 then
			for k, cy in { -400, 800 } do
				-- thin and faint: through the dense teal atmosphere they read as distant seams of
				-- light in the tower wall rather than bright stripes
				local vein = block(wall, `Vein{i}_{k}`, Vector3.new(2.5, 1200, 4), base * CFrame.new(chord * 0.2, cy, -41),
					Enum.Material.Neon, CURRENT)
				vein.Transparency = 0.55
			end
		end
	end
	-- the ledge of the floor above, a dark ring high overhead
	for i = 0, SEG - 1 do
		local ang = (i + 0.5) / SEG * 2 * math.pi
		local cf = CFrame.new(math.cos(ang) * (R - 120), 1350, math.sin(ang) * (R - 120)) * CFrame.Angles(0, -ang + math.pi / 2, 0)
		block(wall, `Ledge{i}`, Vector3.new(chord, 100, 240), cf, Enum.Material.Basalt, ROCK)
	end

	-- the drowned world far below
	local drowned = Instance.new("Folder")
	drowned.Name = "Drowned"
	drowned.Parent = model
	for gx = -1, 1 do
		for gz = -1, 1 do
			local p = block(drowned, "Sea", Vector3.new(1700, 4, 1700), CFrame.new(gx * 1700, -900, gz * 1700),
				Enum.Material.Glass, Color3.fromHex("#0C3A42"))
			p.Reflectance = 0.15
		end
	end

	-- the Current falls off the west edge (the harbour's overflow)
	local falls = opts and opts.Falls
	if falls then
		local folder = Instance.new("Folder")
		folder.Name = "CurrentFalls"
		folder.Parent = model
		local width = falls.Z1 - falls.Z0
		local zc = (falls.Z0 + falls.Z1) / 2
		local sheet = block(folder, "Sheet", Vector3.new(3, 600, width), CFrame.new(-B - 3, -300, zc), Enum.Material.Glass, CURRENT)
		sheet.Transparency = 0.45
		local glow = block(folder, "Glow", Vector3.new(1, 600, width * 0.8), CFrame.new(-B - 5, -300, zc), Enum.Material.Neon, CURRENT)
		glow.Transparency = 0.75
		local lip = block(folder, "Lip", Vector3.new(14, 6, width), CFrame.new(-B - 4, -1, zc), Enum.Material.Glass, CURRENT)
		lip.Transparency = 0.4
		local spray = Instance.new("ParticleEmitter")
		spray.Name = "Mist"
		spray.Texture = "rbxasset://textures/particles/smoke_main.dds"
		spray.Color = ColorSequence.new(Color3.fromHex("#BFF7F0"))
		spray.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 1) })
		spray.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 10), NumberSequenceKeypoint.new(1, 40) })
		spray.Lifetime = NumberRange.new(3, 5)
		spray.Rate = 12
		spray.Speed = NumberRange.new(4, 10)
		spray.EmissionDirection = Enum.NormalId.Left
		spray.LightEmission = 0.3
		spray.Parent = lip
	end

	-- edge barriers (invisible, collide only)
	local edge = Instance.new("Folder")
	edge.Name = "EdgeBarrier"
	edge.Parent = model
	for i, d in { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) } do
		local along = if d.X ~= 0 then Vector3.new(4, 600, 2 * B + 8) else Vector3.new(2 * B + 8, 600, 4)
		local p = block(edge, `Barrier{i}`, along, CFrame.new(d * (B + 2) + Vector3.new(0, 250, 0)), Enum.Material.SmoothPlastic, ROCK)
		p.Transparency = 1
		p.CanCollide = true
	end

	model.Parent = parent
	return model
end

return FloorBuilder
