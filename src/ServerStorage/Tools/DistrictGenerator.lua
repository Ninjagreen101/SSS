--!strict
--[[
	DistrictGenerator (edit-time tool)
	Builds a terraced ring town from its layout (Layouts/<Floor>): the civil works first, then
	the buildings.

	  Infrastructure(layout, parent)  quay walls, terrace retaining walls, avenue stairways with
	                                  side walls, canal walls, bridges, canal waterfalls and spring,
	                                  street lamps, piers
	  PlanLots(layout, seed)          lots along both sides of every ring street, kept clear of
	                                  avenues, canals, the plaza and landmark sites
	  Populate(layout, lots, parent)  one BuildingGenerator building per lot, picked from the
	                                  district's weighted spec (kinds, storeys, wealth, style)

	Positions are polar around the layout's bay centre (r = distance, a = angle; see Layouts/Floor1).
	"Facing in" = the front (+Z of a piece or building) looks toward the bay.

	Usage (Command Bar, Edit mode, after KitLibrary.Prepare()):
	    local DG = require(game.ServerStorage.Tools.DistrictGenerator)
	    local L = require(game.ServerStorage.Tools.Layouts.Floor1)
	    DG.Infrastructure(L, workspace.Floor1.Town)
	    local lots = DG.PlanLots(L, 1)
	    DG.Populate(L, lots, workspace.Floor1.Town, 1, 40)  -- 40 buildings per run (re-run to continue)
]]

local CollectionService = game:GetService("CollectionService")

local Kit = require(script.Parent.KitLibrary)
local BuildingGenerator = require(script.Parent.BuildingGenerator)
local Floor1 = require(script.Parent.Layouts.Floor1)

type Layout = typeof(Floor1)
type Band = Floor1.Band

export type Lot = {
	Id: number,
	CFrame: CFrame, -- building origin (centre of footprint at street level), front facing the street
	Width: number,
	Depth: number,
	District: string,
	Band: string,
	Side: string,
	R: number,
	A: number,
}

local DistrictGenerator = {}

local WATER_COLOR = Color3.fromHex("#2FB9B0")
local CURRENT = Color3.fromHex("#3FE0D0")

-- GEOMETRY ---------------------------------------------------------------------------------

local function radial(a: number): Vector3
	return Vector3.new(math.cos(a), 0, math.sin(a))
end

local function tangent(a: number): Vector3
	return Vector3.new(-math.sin(a), 0, math.cos(a))
end

local function at(L: Layout, r: number, a: number, y: number): Vector3
	local p = L.FromPolar(r, a)
	return Vector3.new(p.X, y, p.Y)
end

-- CFrame whose +Z (the front) points along `front`.
local function facing(pos: Vector3, front: Vector3): CFrame
	return CFrame.lookAt(pos, pos - front)
end

local function polarCF(L: Layout, r: number, a: number, y: number, inward: boolean): CFrame
	local f = if inward then -radial(a) else radial(a)
	return facing(at(L, r, a, y), f)
end

local function folder(parent: Instance, name: string): Folder
	local f = parent:FindFirstChild(name)
	if f and f:IsA("Folder") then
		return f
	end
	local n = Instance.new("Folder")
	n.Name = name
	n.Parent = parent
	return n
end

local function avenues(L: Layout): { { A: number, W: number } }
	local list = { { A = L.Climb.Angle, W = L.Climb.Width } }
	for _, a in L.Spokes do
		table.insert(list, { A = a, W = L.SpokeWidth })
	end
	return list
end

-- Angular intervals blocked at radius r by avenues and/or canals (each padded by `pad` studs).
local function openings(L: Layout, r: number, pad: number, withAvenues: boolean, withCanals: boolean): { { number } }
	local out = {}
	if withAvenues then
		for _, av in avenues(L) do
			local half = (av.W / 2 + pad) / r
			table.insert(out, { av.A - half, av.A + half })
		end
	end
	if withCanals and r <= L.CanalEnd then
		for _, ca in L.Canals do
			local half = (L.CanalWidth / 2 + 1 + pad) / r
			table.insert(out, { ca - half, ca + half })
		end
	end
	table.sort(out, function(x, y)
		return x[1] < y[1]
	end)
	return out
end

-- [a0, a1] minus the blocked intervals.
local function runs(a0: number, a1: number, blocked: { { number } }): { { number } }
	local out = {}
	local cur = a0
	for _, b in blocked do
		if b[2] <= cur then
			continue
		end
		if b[1] > cur then
			table.insert(out, { cur, math.min(b[1], a1) })
		end
		cur = math.max(cur, b[2])
		if cur >= a1 then
			break
		end
	end
	if cur < a1 then
		table.insert(out, { cur, a1 })
	end
	return out
end

-- Lays a 16-long piece along an arc run, scaled so the chords join exactly.
local function layArc(L: Layout, piece: string, r: number, a0: number, a1: number, y: number, inward: boolean, parent: Instance,
	collision: boolean?): number
	local len = (a1 - a0) * r
	if len < 4 then
		return 0
	end
	local n = math.max(1, math.ceil(len / 16))
	local step = (a1 - a0) / n
	local chord = 2 * r * math.sin(step / 2)
	for k = 0, n - 1 do
		local a = a0 + (k + 0.5) * step
		Kit.Place(piece, polarCF(L, r, a, y, inward), parent, {
			Scale = Vector3.new(chord / 16 + 0.03, 1, 1),
			Collision = collision == true,
			Flatten = true,
			Shadows = true,
		})
	end
	return n
end

-- Lays a 16-long piece along a straight line from p0 to p1 (front facing `front`).
local function layLine(piece: string, p0: Vector3, p1: Vector3, front: Vector3, parent: Instance, collision: boolean?): number
	local len = (p1 - p0).Magnitude
	if len < 2 then
		return 0
	end
	local n = math.max(1, math.ceil(len / 16))
	local seg = len / n
	for k = 0, n - 1 do
		local pos = p0:Lerp(p1, (k + 0.5) / n)
		Kit.Place(piece, facing(pos, front), parent, {
			Scale = Vector3.new(seg / 16 + 0.03, 1, 1),
			Collision = collision == true,
			Flatten = true,
		})
	end
	return n
end

-- INFRASTRUCTURE ---------------------------------------------------------------------------

local function waterfall(L: Layout, parent: Instance, r: number, a: number, top: number, bottom: number, width: number)
	local height = top - bottom
	if height <= 0.5 then
		return
	end
	local pos = at(L, r, a, (top + bottom) / 2)
	local cf = facing(pos, -radial(a))
	local sheet = Instance.new("Part")
	sheet.Name = "Waterfall"
	sheet.Anchored = true
	sheet.CanCollide = false
	sheet.CanTouch = false
	sheet.CanQuery = false
	sheet.CastShadow = false
	sheet.Material = Enum.Material.Glass
	sheet.Color = WATER_COLOR
	sheet.Transparency = 0.35
	sheet.Size = Vector3.new(width, height, 0.8)
	sheet.CFrame = cf
	sheet.Parent = parent
	CollectionService:AddTag(sheet, "SpireWaterfall") -- EnvironmentController adds the sound
	local glow = sheet:Clone()
	glow.Name = "WaterfallGlow"
	glow.Material = Enum.Material.Neon
	glow.Color = CURRENT
	glow.Transparency = 0.82
	glow.Size = Vector3.new(width * 0.7, height, 0.2)
	glow.CFrame = cf * CFrame.new(0, 0, 0.6)
	glow.Parent = parent
	local foam = Instance.new("Attachment")
	foam.Name = "Foam"
	foam.Position = Vector3.new(0, -height / 2 + 0.5, 1.5)
	foam.Parent = sheet
	local mist = Instance.new("ParticleEmitter")
	mist.Name = "Mist"
	mist.Texture = "rbxasset://textures/particles/smoke_main.dds"
	mist.Color = ColorSequence.new(Color3.fromHex("#D8FFF9"))
	mist.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) })
	mist.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 7) })
	mist.Lifetime = NumberRange.new(1.2, 2)
	mist.Rate = 10
	mist.Speed = NumberRange.new(2, 4)
	mist.SpreadAngle = Vector2.new(50, 20)
	mist.EmissionDirection = Enum.NormalId.Top
	mist.LightEmission = 0.2
	mist.Parent = foam
end

-- The Current running in a canal stretch: a faint Neon seam on the bed (seen through the water)
-- and a slow drift of glowing motes rising off the surface. Two parts per stretch, no collision.
local function canalGlow(L: Layout, parent: Instance, r0: number, r1: number, a: number, surface: number)
	local mid = (r0 + r1) / 2
	local length = r1 - r0 - 2
	if length < 8 then
		return
	end
	local p = at(L, mid, a, surface - 4.4)
	local cf = CFrame.fromMatrix(p, tangent(a), Vector3.yAxis)
	local seam = Instance.new("Part")
	seam.Name = "CurrentSeam"
	seam.Anchored = true
	seam.CanCollide = false
	seam.CanQuery = false
	seam.CanTouch = false
	seam.CastShadow = false
	seam.Material = Enum.Material.Neon
	seam.Color = CURRENT
	seam.Transparency = 0.55
	seam.Size = Vector3.new(L.CanalWidth * 0.35, 0.2, length)
	seam.CFrame = cf
	seam.Parent = parent
	local motes = Instance.new("Part")
	motes.Name = "CurrentMotes"
	motes.Anchored = true
	motes.CanCollide = false
	motes.CanQuery = false
	motes.CanTouch = false
	motes.Transparency = 1
	motes.Size = Vector3.new(L.CanalWidth - 4, 0.2, length)
	motes.CFrame = cf + Vector3.new(0, 4.6, 0)
	motes.Parent = parent
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Motes"
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = ColorSequence.new(CURRENT)
	emitter.LightEmission = 1
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new(0.35, 0.1)
	emitter.Lifetime = NumberRange.new(3, 5)
	-- rate scales with length so long and short stretches look equally busy (~1 mote per 10 studs/s)
	emitter.Rate = math.clamp(length / 10, 2, 8)
	emitter.Speed = NumberRange.new(1, 2.5)
	emitter.SpreadAngle = Vector2.new(20, 20)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Parent = motes
end

local function lamp(L: Layout, parent: Instance, r: number, a: number, y: number, armInward: boolean)
	local arm = if armInward then -radial(a) else radial(a)
	local pos = at(L, r, a, y)
	local cf = CFrame.fromMatrix(pos, arm, Vector3.yAxis)
	Kit.Place("LampPost", cf, parent, { Flatten = false, Name = "LampPost" })
end

export type InfraStats = { [string]: number }

function DistrictGenerator.Infrastructure(L: Layout, parent: Instance): InfraStats
	local root = folder(parent, "Infrastructure")
	local stats: InfraStats = {}
	local function count(key: string, n: number)
		stats[key] = (stats[key] or 0) + n
	end
	local A = L.TownAngle
	local bands = L.Bands
	local docks = bands[1]

	-- quay wall along the waterfront (open where the canals meet the bay)
	local quay = folder(root, "Quay")
	for _, run in runs(-A, A, openings(L, L.QuayRadius, 0, false, true)) do
		count("Quay", layArc(L, "Quay_16", L.QuayRadius + 1.1, run[1], run[2], docks.Y, true, quay))
	end

	-- terrace retaining walls: two 12-tall courses per 24-stud drop, open at avenues and canals
	local walls = folder(root, "TerraceWalls")
	for i = 2, #bands do
		local band = bands[i]
		local r = band.R0 - 2.1
		for _, run in runs(-A, A, openings(L, band.R0, 0.5, true, true)) do
			for course = 0, 1 do
				count("TerraceWall", layArc(L, "Terrace_Wall_16", r, run[1], run[2], band.Y - 12 * course, true, walls))
			end
		end
	end

	-- avenue stairways: two 12-rise flights per terrace, side walls along the cut
	local stairs = folder(root, "Stairways")
	for i = 2, #bands do
		local band = bands[i]
		for _, av in avenues(L) do
			local flights = av.W // 8
			local t = tangent(av.A)
			for k = 1, flights do
				local off = (k - (flights + 1) / 2) * 8
				for j = 0, 1 do
					local pos = at(L, band.R0 + 20 * j, av.A, band.Y - 24 + 12 * j) + t * off
					Kit.Place("Stairway_12", facing(pos, -radial(av.A)), stairs, { Flatten = true })
					count("Stairs", 1)
				end
			end
			for _, side in { -1, 1 } do
				local d = av.W / 2 + 1.4
				local inward = t * -side -- side walls face the avenue
				local p0 = at(L, band.R0, av.A, band.Y) + t * (side * d)
				local p1 = at(L, band.R0 + L.RampRun, av.A, band.Y) + t * (side * d)
				count("TerraceWall", layLine("Terrace_Wall_16", p0, p1, inward, stairs))
				local q0 = p0 - Vector3.new(0, 12, 0)
				local q1 = p0:Lerp(p1, 0.5) - Vector3.new(0, 12, 0)
				count("TerraceWall", layLine("Terrace_Wall_16", q0, q1, inward, stairs))
			end
		end
	end

	-- canals: side walls the whole way, waterfalls at every terrace wall, a spring at the top
	local canals = folder(root, "Canals")
	for _, ca in L.Canals do
		local t = tangent(ca)
		for i, band in bands do
			local r0 = if i == 1 then L.QuayRadius else band.R0
			local r1 = math.min(band.R1, L.CanalEnd)
			for _, side in { -1, 1 } do
				local off = t * (side * (L.CanalWidth / 2 + 1.1))
				local p0 = at(L, r0, ca, band.Y) + off
				local p1 = at(L, r1, ca, band.Y) + off
				count("CanalWall", layLine("CanalWall_16", p0, p1, t * -side, canals))
			end
			canalGlow(L, canals, r0, r1, ca, band.Y - L.CanalDepth)
			if i > 1 then
				local below = bands[i - 1]
				Kit.Place("Waterfall_Spout", polarCF(L, band.R0 + 1.6, ca, band.Y - L.CanalDepth + 0.6, true), canals, {
					Scale = Vector3.new(L.CanalWidth / 8, 1, 1),
					Flatten = true,
					Collision = false,
				})
				waterfall(L, canals, band.R0 - 0.2, ca, band.Y - L.CanalDepth + 0.4, below.Y - L.CanalDepth, L.CanalWidth)
				count("Waterfall", 1)
			end
		end
		-- the spring wall where the canal begins
		local top = bands[#bands]
		Kit.Place("Waterfall_Spout", polarCF(L, L.CanalEnd - 0.5, ca, top.Y, true), canals, {
			Scale = Vector3.new(L.CanalWidth / 8, 1, 1),
			Flatten = true,
			Collision = false,
		})
		waterfall(L, canals, L.CanalEnd - 2.5, ca, top.Y - 0.4, top.Y - L.CanalDepth, L.CanalWidth * 0.6)
		count("Waterfall", 1)
	end

	-- bridges where ring streets (and the quay promenade) cross the canals
	local bridges = folder(root, "Bridges")
	for _, ca in L.Canals do
		local crossings = { { R = L.QuayRadius + 8, Y = docks.Y } }
		for _, band in bands do
			if band.Street <= L.CanalEnd then
				table.insert(crossings, { R = band.Street, Y = band.Y })
			end
		end
		for _, c in crossings do
			Kit.Place("Bridge_Canal", polarCF(L, c.R, ca, c.Y, true), bridges, {
				Scale = Vector3.new(1, 1, L.StreetWidth / 8 - 0.1),
				Name = "Bridge",
			})
			count("Bridge", 1)
		end
	end

	-- street lamps: zigzag along every ring street and the quay promenade, every ~40 studs
	local lamps = folder(root, "Lamps")
	local lines = { { R = L.QuayRadius + 12, Y = docks.Y, Sides = { 1 } } }
	for _, band in bands do
		table.insert(lines, { R = band.Street, Y = band.Y, Sides = { -1, 1 } })
	end
	local plaza = L.FromPolar(L.Plaza.Radius, L.Plaza.Angle)
	for _, line in lines do
		local blocked = openings(L, line.R, 6, true, true)
		local k = 0
		for _, run in runs(-A + 8 / line.R, A - 8 / line.R, blocked) do
			local len = (run[2] - run[1]) * line.R
			local n = math.floor(len / 40)
			for j = 0, n do
				local a = run[1] + (if n == 0 then 0.5 else j / n) * (run[2] - run[1])
				k += 1
				local side = line.Sides[(k % #line.Sides) + 1]
				local r = line.R + side * (L.StreetWidth / 2 - 1)
				local p = L.FromPolar(r, a)
				if (p - plaza).Magnitude < L.Plaza.Size / 2 + 4 then
					continue
				end
				-- never stand a lamp right in front of a landmark's door
				local blocking = false
				for _, lm in L.Landmarks do
					if math.abs(a - lm.A) * line.R < 10 and (p - L.FromPolar(lm.R, lm.A)).Magnitude < lm.Clear then
						blocking = true
						break
					end
				end
				if blocking then
					continue
				end
				lamp(L, lamps, r, a, line.Y, side > 0)
				count("Lamp", 1)
			end
		end
	end

	stats.Instances = #root:GetDescendants()
	return stats
end

-- LOTS -------------------------------------------------------------------------------------

local function pickWeighted(rng: Random, weights: { [string]: number }): string
	local keys = {}
	local total = 0
	for k, w in weights do
		table.insert(keys, k)
		total += w
	end
	table.sort(keys) -- deterministic order
	local roll = rng:NextNumber() * total
	for _, k in keys do
		roll -= weights[k]
		if roll <= 0 then
			return k
		end
	end
	return keys[#keys]
end

local function multipleOf4(rng: Random, range: { number }): number
	return rng:NextInteger(math.ceil(range[1] / 4), math.floor(range[2] / 4)) * 4
end

-- Is a footprint centred at (r, a) with radius `rad` clear of plaza, landmarks and openings?
local function lotClear(L: Layout, r: number, a: number, frontR: number, halfW: number, rad: number): boolean
	local p = L.FromPolar(r, a)
	local plaza = L.FromPolar(L.Plaza.Radius, L.Plaza.Angle)
	-- the plaza plus its ring of workshop buildings (LandmarkBuilder.Market)
	if (p - plaza).Magnitude < L.Plaza.Keep + rad + 4 then
		return false
	end
	for _, lm in L.Landmarks do
		if (p - L.FromPolar(lm.R, lm.A)).Magnitude < lm.Clear + rad then
			return false
		end
	end
	for _, b in openings(L, frontR, 4, true, true) do
		local lo, hi = a - halfW / frontR, a + halfW / frontR
		if hi > b[1] and lo < b[2] then
			return false
		end
	end
	return true
end

function DistrictGenerator.PlanLots(L: Layout, seed: number): { Lot }
	local rng = Random.new(seed)
	local lots: { Lot } = {}
	local A = L.TownAngle
	for i, band in L.Bands do
		local spec = L.Districts[band.District]
		if not spec then
			continue
		end
		for _, side in spec.Sides do
			local inner = side == "Inner"
			local frontR = if inner then band.Street - (L.StreetWidth / 2 + 3) else band.Street + (L.StreetWidth / 2 + 3)
			local room = if inner then frontR - (band.R0 + 4) else (band.R1 - 4) - frontR
			if i == 1 and inner then
				continue -- the docks' bay side is the quay promenade
			end
			if room < 8 then
				continue
			end
			local a = -A + 6 / frontR
			local guard = 0
			while guard < 400 do
				guard += 1
				local W = multipleOf4(rng, spec.Width)
				local D = math.min(multipleOf4(rng, spec.Depth), math.floor(room / 4) * 4)
				if D < 8 then
					break
				end
				local da = W / frontR
				local centre = a + da / 2
				if centre + da / 2 > A - 6 / frontR then
					break
				end
				local rc = if inner then frontR - D / 2 else frontR + D / 2
				local rad = math.sqrt(W * W + D * D) / 2
				if not lotClear(L, rc, centre, frontR, W / 2, rad) then
					a += 4 / frontR
					continue
				end
				local cf = polarCF(L, rc, centre, band.Y, not inner)
				table.insert(lots, {
					Id = #lots + 1,
					CFrame = cf,
					Width = W,
					Depth = D,
					District = band.District,
					Band = band.Name,
					Side = side,
					R = rc,
					A = centre,
				})
				a += da + rng:NextInteger(spec.Gap[1], spec.Gap[2]) / frontR
			end
		end
	end
	return lots
end

-- BUILDINGS --------------------------------------------------------------------------------

-- Builds lots[first .. first + count - 1]. Returns the next index (0 when done) and instances added.
function DistrictGenerator.Populate(L: Layout, lots: { Lot }, parent: Instance, first: number, count: number): (number, number)
	local root = folder(parent, "Buildings")
	local added = 0
	local last = math.min(#lots, first + count - 1)
	for i = first, last do
		local lot = lots[i]
		local spec = L.Districts[lot.District]
		local rng = Random.new(lot.Id * 7919 + 17)
		local kind = pickWeighted(rng, spec.Kinds)
		local storeys = rng:NextInteger(spec.Storeys[1], spec.Storeys[2])
		if kind == "Warehouse" then
			storeys = math.min(storeys, 2)
		end
		local result = BuildingGenerator.Build({
			Width = lot.Width,
			Depth = lot.Depth,
			Storeys = storeys,
			Style = pickWeighted(rng, spec.Styles) :: any,
			Kind = kind :: any,
			Wealth = spec.Wealth[1] + rng:NextNumber() * (spec.Wealth[2] - spec.Wealth[1]),
			Roof = if rng:NextNumber() < 0.25 then "Hip" else "Gable",
			Seed = lot.Id * 31 + 5,
			Name = `{lot.Band}_{kind}_{lot.Id}`,
		}, lot.CFrame, folder(root, lot.Band))
		result.Model:SetAttribute("LotId", lot.Id)
		added += BuildingGenerator.Count(result.Model) + 1
	end
	return if last >= #lots then 0 else last + 1, added
end

return DistrictGenerator
