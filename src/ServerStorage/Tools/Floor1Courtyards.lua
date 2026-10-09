--!strict
--[[
	Floor1Courtyards (edit-time tool; never runs during play)
	Fills the open ground behind and between Lowharbor's houses with small courtyard scenes, so no
	block reads as an empty field. Every scene is built from SpireKit templates (KitLibrary.Place)
	in the floor's own drowned palette, and fits its district:
	  Docks          net yards, boats hauled up on logs, crate yards
	  Market         stall stores, traders' tables, drowned gardens
	  Terraces       drowned gardens, kitchen yards, Climber shrines, crystal grottos
	  Guild Terrace  formal courts, reading nooks, crystal grottos, shrines

	How a spot is chosen
	  * Candidates sit on a polar grid inside each terrace band, 12+ studs from its walls.
	  * The whole footprint must be "Lot" ground (Layout.TownSurface: no street, avenue, canal,
	    plaza or quay) and flat at the band height.
	  * Nothing already in Workspace may come within 3 studs (oriented-box test against every part,
	    visible or not, so paving strips and collision boxes count too).
	  * Scenes stay 30 studs apart, and each scene's open side faces the nearest ring street.
	  * A fixed seed makes the pass repeatable: Undo then Apply rebuilds the same scenes.

	Everything goes into Workspace.Floor1.Courtyards. Nothing that already exists is changed, so Undo
	only deletes that folder.

	Usage (Command Bar, Edit mode):
	    local C = require(game.ServerStorage.Tools.Floor1Courtyards)
	    C.Apply()   -- build (refuses if already built)
	    C.Resnap()  -- re-seat every scene on the voxel surface after a terrain edit
	    C.Undo()    -- remove every scene
]]

local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local KitLibrary = require(script.Parent.KitLibrary)
local Layout = require(script.Parent.Layouts.Floor1)

local Courtyards = {}

export type Options = {
	-- Ground height at (x, z), or nil when there is none. Defaults to a terrain raycast; an offline
	-- build passes Layout.Height.
	Ground: ((x: number, z: number) -> number?)?,
	Seed: number?,
}

type Piece = {
	Name: string,
	X: number,
	Y: number,
	Z: number,
	Yaw: number?,
	Scale: number?,
	Light: boolean?, -- this piece keeps its PointLight (one per scene)
}

type Box = { CFrame: CFrame, Half: Vector3, MinX: number, MaxX: number, MinZ: number, MaxZ: number }

local FOLDER = "Courtyards"
local FOOTPRINT = 18 -- scene footprint (studs, square)
local MARGIN = 3 -- clearance from anything already built
local SPACING = 30 -- minimum distance between scenes
local WALL_MARGIN = 12 -- distance from the terrace walls at the band edges
local STEP = 18 -- candidate grid (radial and along the arc)
local CELL = 32 -- spatial hash cell for the occupancy test
local HEIGHT = 16 -- scenes are checked for clearance this high above the ground
local PI = math.pi

-- Max scenes per terrace band.
local MAX_PER_BAND: { [string]: number } = {
	Docks = 12,
	Market = 16,
	LowerTerraces = 22,
	UpperTerraces = 22,
	GuildTerrace = 16,
}

-- SCENES ----------------------------------------------------------------------------------------
-- Scene space: origin on the ground at the scene centre, +Z = the open side (toward the street),
-- tall pieces at the back (-Z). Kit pieces face +Z in template space, so Yaw = PI turns one around.

local SCENES: { [string]: { Piece } } = {
	DrownedGarden = {
		{ Name = "Bush_Fern", X = -4.5, Y = 0, Z = -3.5, Yaw = 0.4 },
		{ Name = "Bush_Round", X = 4, Y = 0, Z = -4, Scale = 0.8 },
		{ Name = "Rock_M", X = 0, Y = 0, Z = -5.5, Yaw = 1.1, Scale = 0.6 },
		{ Name = "Flowers", X = -2, Y = 0, Z = 1.5 },
		{ Name = "Flowers", X = 3, Y = 0, Z = 0.5, Yaw = 1.9 },
		{ Name = "Glow_Mushrooms", X = 5.5, Y = 0, Z = 3, Scale = 0.6, Light = true },
		{ Name = "Rock_S", X = -5.5, Y = 0, Z = 2.5, Yaw = 2.4 },
		{ Name = "Bench", X = 0, Y = 0, Z = 5.5, Yaw = PI },
	},
	KitchenYard = {
		{ Name = "Table", X = 0, Y = 0, Z = 0 },
		{ Name = "Stool", X = -2, Y = 0, Z = 2.4 },
		{ Name = "Stool", X = 2, Y = 0, Z = 2.4, Yaw = 0.5 },
		{ Name = "Stool", X = 0.4, Y = 0, Z = -2.6, Yaw = 2 },
		{ Name = "Cooking_Pot", X = -6, Y = 0, Z = -3.5, Light = true },
		{ Name = "Barrel", X = 5.5, Y = 0, Z = -4.5 },
		{ Name = "Barrel", X = 7.2, Y = 0, Z = -2.8, Yaw = 1 },
		{ Name = "Sacks", X = 5.5, Y = 0, Z = 1.5, Yaw = -0.6 },
		{ Name = "Crate", X = -6.5, Y = 0, Z = 2.5, Yaw = 0.3 },
	},
	ClimberShrine = {
		{ Name = "Statue_Climber", X = 0, Y = 0, Z = -4.5, Scale = 0.45, Light = true },
		{ Name = "Candles", X = -2.2, Y = 0, Z = -1 },
		{ Name = "Candles", X = 2.2, Y = 0, Z = -1, Yaw = 1.3 },
		{ Name = "Potted_Plant", X = -5, Y = 0, Z = -4.5 },
		{ Name = "Potted_Plant", X = 5, Y = 0, Z = -4.5 },
		{ Name = "Anemone_Glow", X = 0, Y = 0, Z = 0.5, Scale = 0.5 },
		{ Name = "Bench", X = 0, Y = 0, Z = 5.5, Yaw = PI },
	},
	CrystalGrotto = {
		{ Name = "Current_Crystal_M", X = 0, Y = 0, Z = -3.5, Scale = 0.6, Light = true },
		{ Name = "Rock_M", X = -4.5, Y = 0, Z = -1.5, Yaw = 0.7, Scale = 0.8 },
		{ Name = "Rock_S", X = 4.5, Y = 0, Z = -0.5, Yaw = 2.1 },
		{ Name = "Anemone_Glow", X = 2.5, Y = 0, Z = 2.5, Scale = 0.7 },
		{ Name = "Coral_Fan", X = -3, Y = 0, Z = 2.5, Yaw = 0.4, Scale = 0.8 },
		{ Name = "Barnacles", X = 0.5, Y = 0, Z = 4 },
		{ Name = "Bench", X = 0, Y = 0, Z = 6.5, Yaw = PI },
	},
	NetYard = {
		{ Name = "Nets_Frame", X = 0, Y = 0, Z = -4 },
		{ Name = "Fish_Rack", X = -5.5, Y = 0, Z = 1, Yaw = PI / 2 },
		{ Name = "Lobster_Traps", X = 2.5, Y = 0, Z = 1.5, Yaw = 0.3 },
		{ Name = "Rope_Coil", X = 5.5, Y = 0, Z = -1.5 },
		{ Name = "Barrel", X = -2, Y = 0, Z = 4 },
		{ Name = "Buoy", X = 6, Y = 1.2, Z = 4, Yaw = 0.8, Light = true },
	},
	BoatYard = {
		{ Name = "Log_Fallen", X = 0, Y = 0, Z = -2.5, Scale = 0.45 },
		{ Name = "Log_Fallen", X = 0, Y = 0, Z = 2.5, Yaw = PI, Scale = 0.45 },
		{ Name = "Rowboat", X = 0, Y = 1.9, Z = 0, Yaw = 0.05 },
		{ Name = "Driftwood", X = -6, Y = 0, Z = 5, Yaw = 0.6, Scale = 0.7 },
		{ Name = "Barnacles", X = 4.5, Y = 0, Z = 5 },
		{ Name = "Rope_Coil", X = 6.5, Y = 0, Z = -4.5 },
		{ Name = "LampPost", X = -7, Y = 0, Z = -5.5, Light = true },
	},
	CrateYard = {
		{ Name = "Crate_Stack", X = -0.5, Y = 0, Z = -4 },
		{ Name = "Crate", X = -5, Y = 0, Z = 0 },
		{ Name = "Crate", X = -5, Y = 2.5, Z = 0, Yaw = 0.4 },
		{ Name = "Barrel", X = 3, Y = 0, Z = 1 },
		{ Name = "Barrel", X = 4.8, Y = 0, Z = -0.6 },
		{ Name = "Sacks", X = 0, Y = 0, Z = 3, Yaw = 0.2 },
		{ Name = "Rope_Coil", X = 5.5, Y = 0, Z = 4 },
	},
	StallStore = {
		{ Name = "Market_Stall", X = 0, Y = 0, Z = -3.5 },
		{ Name = "Crate_Stack", X = -6.5, Y = 0, Z = 0.5, Yaw = 0.3 },
		{ Name = "Sacks", X = 5, Y = 0, Z = 2 },
		{ Name = "Barrel", X = 6, Y = 0, Z = -3 },
		{ Name = "Crate", X = -3, Y = 0, Z = 4, Yaw = 0.5 },
	},
	TradersRest = {
		{ Name = "Table", X = 0, Y = 0, Z = 0 },
		{ Name = "Chair", X = -2.6, Y = 0, Z = 0, Yaw = PI / 2 },
		{ Name = "Chair", X = 2.6, Y = 0, Z = 0, Yaw = -PI / 2 },
		{ Name = "Barrel", X = -5.5, Y = 0, Z = -4 },
		{ Name = "Crate", X = -3.5, Y = 0, Z = -5, Yaw = 0.7 },
		{ Name = "LampPost", X = 5.5, Y = 0, Z = -5, Light = true },
	},
	FormalCourt = {
		{ Name = "Floor_Stone", X = 0, Y = 0, Z = 0 },
		{ Name = "Bush_Round", X = -5.5, Y = 0.1, Z = -5.5, Scale = 0.7 },
		{ Name = "Bush_Round", X = 5.5, Y = 0.1, Z = -5.5, Scale = 0.7 },
		{ Name = "Bush_Round", X = -5.5, Y = 0.1, Z = 5.5, Scale = 0.7 },
		{ Name = "Bush_Round", X = 5.5, Y = 0.1, Z = 5.5, Scale = 0.7 },
		{ Name = "Statue_Climber", X = 0, Y = 0.1, Z = -1, Scale = 0.5, Light = true },
		{ Name = "Bench", X = 0, Y = 0.1, Z = -6.6 },
	},
	ReadingNook = {
		{ Name = "Rug", X = 0, Y = 0, Z = 0, Yaw = PI / 2 },
		{ Name = "Table", X = 0, Y = 0.2, Z = 0 },
		{ Name = "Candles", X = 0.6, Y = 3.7, Z = 0, Light = true },
		{ Name = "Chair", X = -2.6, Y = 0.2, Z = 0, Yaw = PI / 2 },
		{ Name = "Chair", X = 2.6, Y = 0.2, Z = 0, Yaw = -PI / 2 },
		{ Name = "Potted_Plant", X = -5.5, Y = 0, Z = -4.5 },
		{ Name = "Potted_Plant", X = 5.5, Y = 0, Z = -4.5 },
		{ Name = "Barrel", X = 6, Y = 0, Z = 3, Yaw = 0.4 },
	},
}

-- Which scenes each district gets, weighted.
local BY_DISTRICT: { [string]: { [string]: number } } = {
	Docks = { NetYard = 3, BoatYard = 2, CrateYard = 3, KitchenYard = 1 },
	Market = { StallStore = 3, TradersRest = 2, CrateYard = 2, DrownedGarden = 2 },
	Residential = { DrownedGarden = 3, KitchenYard = 3, ClimberShrine = 1, CrystalGrotto = 1, TradersRest = 1 },
	Guild = { FormalCourt = 3, ReadingNook = 2, CrystalGrotto = 2, ClimberShrine = 1, DrownedGarden = 1 },
}

-- OCCUPANCY -------------------------------------------------------------------------------------

local function boxOf(cf: CFrame, size: Vector3): Box
	local half = size / 2
	local hx = math.abs(cf.XVector.X) * half.X + math.abs(cf.YVector.X) * half.Y + math.abs(cf.ZVector.X) * half.Z
	local hz = math.abs(cf.XVector.Z) * half.X + math.abs(cf.YVector.Z) * half.Y + math.abs(cf.ZVector.Z) * half.Z
	local p = cf.Position
	return { CFrame = cf, Half = half, MinX = p.X - hx, MaxX = p.X + hx, MinZ = p.Z - hz, MaxZ = p.Z + hz }
end

-- Separating-axis test between two oriented boxes.
local function overlaps(a: Box, b: Box): boolean
	local ax = { a.CFrame.XVector, a.CFrame.YVector, a.CFrame.ZVector }
	local bx = { b.CFrame.XVector, b.CFrame.YVector, b.CFrame.ZVector }
	local ah = { a.Half.X, a.Half.Y, a.Half.Z }
	local bh = { b.Half.X, b.Half.Y, b.Half.Z }
	local d = b.CFrame.Position - a.CFrame.Position
	local function separated(axis: Vector3): boolean
		local len = axis.Magnitude
		if len < 1e-6 then
			return false
		end
		local n = axis / len
		local ra = 0
		local rb = 0
		for i = 1, 3 do
			ra += ah[i] * math.abs(ax[i]:Dot(n))
			rb += bh[i] * math.abs(bx[i]:Dot(n))
		end
		return math.abs(d:Dot(n)) > ra + rb
	end
	for i = 1, 3 do
		if separated(ax[i]) or separated(bx[i]) then
			return false
		end
	end
	for i = 1, 3 do
		for j = 1, 3 do
			if separated(ax[i]:Cross(bx[j])) then
				return false
			end
		end
	end
	return true
end

type Index = { [number]: { [number]: { Box } } }

local function insert(index: Index, box: Box)
	for cx = math.floor(box.MinX / CELL), math.floor(box.MaxX / CELL) do
		local column = index[cx]
		if not column then
			column = {}
			index[cx] = column
		end
		for cz = math.floor(box.MinZ / CELL), math.floor(box.MaxZ / CELL) do
			local list = column[cz]
			if not list then
				list = {}
				column[cz] = list
			end
			table.insert(list, box)
		end
	end
end

local function blocked(index: Index, query: Box): boolean
	for cx = math.floor(query.MinX / CELL), math.floor(query.MaxX / CELL) do
		local column = index[cx]
		if column then
			for cz = math.floor(query.MinZ / CELL), math.floor(query.MaxZ / CELL) do
				local list = column[cz]
				if list then
					for _, box in list do
						if box.MaxX >= query.MinX and box.MinX <= query.MaxX and box.MaxZ >= query.MinZ
							and box.MinZ <= query.MaxZ and overlaps(box, query)
						then
							return true
						end
					end
				end
			end
		end
	end
	return false
end

-- Every part in the world that a scene must not touch. Pure trigger volumes (invisible and
-- non-colliding) and huge backdrop slabs are left out.
local function buildIndex(skip: Instance?): Index
	local index: Index = {}
	for _, d in Workspace:GetDescendants() do
		if not d:IsA("BasePart") or d:IsA("Terrain") then
			continue
		end
		if skip and d:IsDescendantOf(skip) then
			continue
		end
		if d.Transparency >= 1 and not d.CanCollide then
			continue
		end
		if d.Size.X > 400 or d.Size.Z > 400 then
			continue
		end
		insert(index, boxOf(d.CFrame, d.Size))
	end
	return index
end

-- PLACEMENT -------------------------------------------------------------------------------------

local function terrainGround(x: number, z: number): number?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { Workspace.Terrain }
	params.IgnoreWater = true
	local hit = Workspace:Raycast(Vector3.new(x, 600, z), Vector3.new(0, -900, 0), params)
	return if hit then hit.Position.Y else nil
end

-- A small seeded generator (Park-Miller). Random's sequence is engine-defined, and this pass must
-- give the same scenes in Studio and in an offline build.
type Rng = { NextNumber: (self: Rng, lo: number?, hi: number?) -> number, State: number }

local function newRng(seed: number): Rng
	local rng = { State = math.max(1, math.floor(seed) % 2147483647) } :: any
	function rng.NextNumber(self: Rng, lo: number?, hi: number?): number
		self.State = (self.State * 48271) % 2147483647
		local u = self.State / 2147483647
		local a = lo or 0
		local b = hi or 1
		return a + (b - a) * u
	end
	return rng :: Rng
end

local function pick(weights: { [string]: number }, rng: Rng): string
	local names = {}
	local total = 0
	for name, w in weights do
		table.insert(names, name)
		total += w
	end
	table.sort(names) -- pairs order is not stable; sorting keeps the seed meaningful
	local roll = rng:NextNumber(0, total)
	for _, name in names do
		roll -= weights[name]
		if roll <= 0 then
			return name
		end
	end
	return names[#names]
end

-- The whole footprint is lot ground at the band's height.
local function onLot(x: number, z: number, y: number): boolean
	local r = FOOTPRINT / 2 + 1
	for i = 0, 8 do
		local px, pz = x, z
		if i > 0 then
			local a = (i - 1) / 8 * 2 * PI
			px += math.cos(a) * r
			pz += math.sin(a) * r
		end
		if Layout.TownSurface(px, pz) ~= "Lot" then
			return false
		end
		if math.abs(Layout.Height(px, pz) - y) > 0.25 then
			return false
		end
	end
	return true
end

local function buildScene(parent: Instance, name: string, kind: string, at: CFrame): Model
	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("Scene", kind)
	model.WorldPivot = at
	local lit = false
	for _, piece in SCENES[kind] do
		local s = piece.Scale or 1
		local cf = at * CFrame.new(piece.X, piece.Y, piece.Z) * CFrame.Angles(0, piece.Yaw or 0, 0)
		local parts = KitLibrary.Place(piece.Name, cf, model, {
			Scale = Vector3.new(s, s, s),
			Flatten = true,
			Shadows = s >= 0.8 and piece.Name ~= "Flowers" and piece.Name ~= "Candles",
		})
		-- one light per scene keeps nights cheap; the rest of the candles and glows stay emissive
		for _, part in parts do
			for _, child in part:GetChildren() do
				if child:IsA("Light") then
					if piece.Light and not lit then
						lit = true
					else
						child:Destroy()
					end
				end
			end
		end
	end
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model.Parent = parent
	return model
end

function Courtyards.Apply(options: Options?): { [string]: number }
	local opts: Options = options or {}
	if not opts.Ground then
		assert(not RunService:IsRunning(), "Apply in Edit mode")
	end
	local floor = Workspace:FindFirstChild("Floor1")
	assert(floor and floor:FindFirstChild("Town"), "Existing Lowharbor required")
	assert(not floor:FindFirstChild(FOLDER), "Courtyards already built; Undo before reapplying")
	assert(
		ServerStorage:FindFirstChild("SpireKit") and ServerStorage.SpireKit:FindFirstChild("Templates"),
		"SpireKit templates missing (KitLibrary.Prepare)"
	)
	local ground: (x: number, z: number) -> number? = opts.Ground or terrainGround
	local rng = newRng(opts.Seed or 1147)

	local root = Instance.new("Folder")
	root.Name = FOLDER
	root:SetAttribute("Purpose", "Courtyard scenes in Lowharbor's block interiors (Tools.Floor1Courtyards)")
	local index = buildIndex(nil)
	local placed: { Vector2 } = {}
	local counts: { [string]: number } = {}
	local total = 0

	for _, band in Layout.Bands do
		local holder = Instance.new("Folder")
		holder.Name = band.Name
		holder.Parent = root
		local weights = BY_DISTRICT[band.District] or BY_DISTRICT.Residential
		-- candidate spots on a jittered polar grid, visited in shuffled order
		local spots: { Vector3 } = {}
		local r = band.R0 + WALL_MARGIN + FOOTPRINT / 2
		while r <= band.R1 - WALL_MARGIN - FOOTPRINT / 2 do
			local da = STEP / r
			local a = -Layout.TownAngle + da
			while a < Layout.TownAngle - da do
				local jr = r + rng:NextNumber(-4, 4)
				local ja = a + rng:NextNumber(-0.25, 0.25) * da
				table.insert(spots, Vector3.new(jr, ja, rng:NextNumber()))
				a += da
			end
			r += STEP
		end
		table.sort(spots, function(p, q)
			return p.Z < q.Z
		end)
		local count = 0
		local limit = MAX_PER_BAND[band.Name] or 12
		for _, spot in spots do
			if count >= limit then
				break
			end
			local sr, sa = spot.X, spot.Y
			local p = Layout.FromPolar(sr, sa)
			local tooClose = false
			for _, q in placed do
				if (q - p).Magnitude < SPACING then
					tooClose = true
					break
				end
			end
			if tooClose or not onLot(p.X, p.Y, band.Y) then
				continue
			end
			local gy = ground(p.X, p.Y)
			if not gy or math.abs(gy - band.Y) > 1.5 then
				continue
			end
			-- face the open side toward the ring street
			local out = if sr < band.Street then 1 else -1
			local dirX, dirZ = math.cos(sa) * out, math.sin(sa) * out
			local yaw = math.atan2(dirX, dirZ)
			local at = CFrame.new(p.X, gy, p.Y) * CFrame.Angles(0, yaw, 0)
			local query = boxOf(at * CFrame.new(0, HEIGHT / 2 - 0.4, 0), Vector3.new(FOOTPRINT + 2 * MARGIN, HEIGHT, FOOTPRINT + 2 * MARGIN))
			if blocked(index, query) then
				continue
			end
			local kind = pick(weights, rng)
			count += 1
			total += 1
			buildScene(holder, `{band.Name}_{count}_{kind}`, kind, at)
			insert(index, boxOf(at * CFrame.new(0, HEIGHT / 2, 0), Vector3.new(FOOTPRINT, HEIGHT, FOOTPRINT)))
			table.insert(placed, p)
			counts[kind] = (counts[kind] or 0) + 1
		end
		holder:SetAttribute("Count", count)
	end
	root:SetAttribute("Count", total)
	root.Parent = floor
	counts.Total = total
	return counts
end

-- Re-seats every scene on the voxel surface (Studio only; uses a terrain raycast).
function Courtyards.Resnap(): number
	local floor = Workspace:FindFirstChild("Floor1")
	local root = floor and floor:FindFirstChild(FOLDER)
	assert(root, "Courtyards not built")
	local moved = 0
	for _, d in root:GetDescendants() do
		if d:IsA("Model") and d:GetAttribute("Scene") then
			local pivot = d:GetPivot()
			local gy = terrainGround(pivot.Position.X, pivot.Position.Z)
			if gy then
				local dy = gy - pivot.Position.Y
				if math.abs(dy) > 0.05 and math.abs(dy) < 8 then
					d:PivotTo(pivot + Vector3.new(0, dy, 0))
					moved += 1
				end
			end
		end
	end
	return moved
end

function Courtyards.Undo()
	local floor = Workspace:FindFirstChild("Floor1")
	local root = floor and floor:FindFirstChild(FOLDER)
	if root then
		root:Destroy()
	end
end

return Courtyards
