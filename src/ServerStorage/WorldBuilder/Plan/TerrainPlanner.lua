--!strict
-- TerrainPlanner: the floor's terrain as a pure height / material / water
-- field. Natural landforms (marsh, forest hills, crags, the north wall) are
-- blended by distance to their region polygons; the town is flattened onto
-- terrace pads; streets, stairs and causeways are cut as corridors; canals and
-- tidepools are carved; materials follow region, slope, shore and street rules.
-- TerrainApplier samples this field into Roblox voxels; the offline harness
-- samples it into a preview heightmap.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Geom = require(Shared.Util.Geom)
local Config = require(Shared.Config)

local Context = require(script.Parent.Context)

type FloorDef = Types.FloorDef
type TerrainSample = Types.TerrainSample
type Point2 = Types.Point2
type Vec3 = Types.Vec3
type Context = Context.Context

local TC = Config.World.Terrain

type Box = { minX: number, minZ: number, maxX: number, maxZ: number }

type Region = { def: Types.TerrainRegionDef, box: Box }
type Pad = { def: Types.DistrictDef, box: Box }
type Line = { points: { Vec3 }, width: number, box: Box, material: string, shoulder: number, kind: string }
type Canal = { def: Types.CanalDef, box: Box, pts: { Vec3 } }

export type Field = {
	floor: FloorDef,
	regions: { Region },
	pads: { Pad },
	streets: { Line },
	paths: { Line },
	canals: { Canal },
	ctx: Context?,
	fills: { { [string]: any } },
	height: (self: Field, x: number, z: number) -> number,
	sample: (self: Field, x: number, z: number) -> TerrainSample,
	attach: (self: Field, ctx: Context) -> (),
	addFills: (self: Field, carves: { { [string]: any } }) -> (),
}

local TerrainPlanner = {}
TerrainPlanner.__index = TerrainPlanner

local function grow(b: Box, m: number): Box
	return { minX = b.minX - m, minZ = b.minZ - m, maxX = b.maxX + m, maxZ = b.maxZ + m }
end

local function inBox(b: Box, x: number, z: number): boolean
	return x >= b.minX and x <= b.maxX and z >= b.minZ and z <= b.maxZ
end

local function lineBox(points: { Vec3 }): Box
	local b = { minX = math.huge, minZ = math.huge, maxX = -math.huge, maxZ = -math.huge }
	for _, p in points do
		b.minX = math.min(b.minX, p[1])
		b.maxX = math.max(b.maxX, p[1])
		b.minZ = math.min(b.minZ, p[3])
		b.maxZ = math.max(b.maxZ, p[3])
	end
	return b
end

-- Closest point on a {x, y, z} polyline: distance and interpolated y.
local function closestY(points: { Vec3 }, x: number, z: number): (number, number)
	local best, by = math.huge, 0
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local d, t = Geom.distToSegment(x, z, a[1], a[3], b[1], b[3])
		if d < best then
			best = d
			by = a[2] + (b[2] - a[2]) * t
		end
	end
	return best, by
end

-- Canal bed height: water surface follows the upstream node's street level
-- until the next node, where a waterfall drops to the next level.
local function canalStreetY(pts: { Vec3 }, x: number, z: number): (number, number)
	local best, by = math.huge, 0
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local d = Geom.distToSegment(x, z, a[1], a[3], b[1], b[3])
		if d < best then
			best = d
			by = a[2]
		end
	end
	return best, by
end

function TerrainPlanner.new(floor: FloorDef): Field
	local self = setmetatable({}, TerrainPlanner) :: any
	self.floor = floor
	self.regions = {}
	for _, r in floor.terrainRegions do
		local b = Geom.polygonBounds(r.polygon)
		table.insert(self.regions, { def = r, box = grow({ minX = b.minX, minZ = b.minZ, maxX = b.maxX, maxZ = b.maxZ }, r.blend) })
	end
	self.pads = {}
	for _, d in floor.districts do
		local b = Geom.polygonBounds(d.polygon)
		table.insert(self.pads, { def = d, box = grow({ minX = b.minX, minZ = b.minZ, maxX = b.maxX, maxZ = b.maxZ }, TC.PadBlend) })
	end
	self.streets = {}
	for _, s in floor.streets do
		table.insert(self.streets, {
			points = s.points,
			width = s.width,
			box = grow(lineBox(s.points), s.width / 2 + 14),
			material = s.material or "Cobblestone",
			shoulder = 12,
			kind = "street",
		})
	end
	self.paths = {}
	for _, p in floor.paths do
		local pts: { Vec3 } = {}
		for _, q in p.points do
			table.insert(pts, { q[1], 0, q[2] })
		end
		table.insert(self.paths, { points = pts, width = p.width, box = grow(lineBox(pts), p.width), material = p.material, shoulder = 0, kind = "path" })
	end
	self.canals = {}
	for _, c in floor.canals do
		local pts: { Vec3 } = {}
		for _, n in c.nodes do
			table.insert(pts, { n[1], n[3], n[2] })
		end
		table.insert(self.canals, { def = c, box = grow(lineBox(pts), c.width), pts = pts })
	end
	self.ctx = nil
	self.fills = {}
	return self :: Field
end

function TerrainPlanner.attach(self: Field, ctx: Context)
	self.ctx = ctx
end

-- natural landform height and dominant region material
local function natural(self: Field, x: number, z: number): (number, string, string)
	local floor = self.floor
	local wsum, hsum = 0, 0
	local bestW, bestMat, bestId = 0, "Sand", "sea"
	for _, r in self.regions do
		if inBox(r.box, x, z) then
			local def = r.def
			local sd = Geom.polygonDistance(x, z, def.polygon)
			local w = 1 - Geom.smoothstep(-def.blend * 0.5, def.blend * 0.5, sd)
			if w > 0 then
				local n: number
				if def.id == "crags" or def.id == "northwall" then
					n = Geom.ridged(x * def.frequency, z * def.frequency, floor.seed + #def.id, 4) * 2 - 0.6
				else
					n = Geom.fbm(x * def.frequency, z * def.frequency, floor.seed + #def.id * 17, 4)
				end
				local h = def.base + def.amplitude * n
				wsum += w
				hsum += w * h
				if w > bestW then
					bestW, bestMat, bestId = w, def.material, def.id
				end
			end
		end
	end
	local seaW = math.max(0, 1 - wsum)
	local seaFloor = TC.SeaFloor + Geom.fbm(x / 160, z / 160, floor.seed + 5, 3) * 6
	local h = (hsum + seaW * seaFloor) / (wsum + seaW)
	if seaW > 0.5 then
		bestMat, bestId = "Sand", "sea"
	end
	-- the floor's rim rises into the tower's foot everywhere but the open south
	local rim = math.max(math.abs(x) - 1380, -z - 1380, 0)
	if z > 1250 then
		rim = math.max(math.abs(x) - 1380, 0)
	end
	if rim > 0 then
		h += Geom.smoothstep(0, 120, rim) * (260 + Geom.ridged(x / 90, z / 90, floor.seed, 3) * 120)
		if rim > 30 then
			bestMat, bestId = "Basalt", "rim"
		end
	end
	return h, bestMat, bestId
end

local function padHeight(self: Field, x: number, z: number, h: number): (number, boolean, Types.DistrictDef?)
	for _, p in self.pads do
		if inBox(p.box, x, z) then
			local sd = Geom.polygonDistance(x, z, p.def.polygon)
			if sd <= 0 then
				return p.def.baseY, true, p.def
			end
		end
	end
	-- outside every pad: blend from the nearest pad edge toward the natural height
	local best, bestY = math.huge, 0
	for _, p in self.pads do
		if inBox(p.box, x, z) then
			local sd = Geom.polygonDistance(x, z, p.def.polygon)
			if sd < best then
				best, bestY = sd, p.def.baseY
			end
		end
	end
	if best < TC.PadBlend then
		local t = Geom.smoothstep(0, TC.PadBlend, best)
		-- terraces drop steeply toward lower ground and ramp gently up to higher ground
		if h < bestY then
			t = Geom.smoothstep(0, TC.PadBlend * 0.6, best)
		end
		return Geom.lerp(bestY, h, t), false, nil
	end
	return h, false, nil
end

-- Solid terrain additions (islets, cave floors) that the heightfield must know
-- about; Air carves are applied by TerrainApplier only.
function TerrainPlanner.addFills(self: Field, carves: { { [string]: any } })
	for _, c in carves do
		if c.op == "Fill" then
			table.insert(self.fills, c)
		end
	end
end

local function fillTop(c: { [string]: any }, x: number, z: number): number?
	local lx, lz = Geom.rotate(x - c.x, z - c.z, -c.ry)
	if c.shape == "Ball" then
		local u = (lx / (c.sx / 2)) ^ 2 + (lz / (c.sz / 2)) ^ 2
		if u < 1 then
			return c.y + c.sy / 2 * math.sqrt(1 - u)
		end
	elseif math.abs(lx) <= c.sx / 2 and math.abs(lz) <= c.sz / 2 then
		return c.y + c.sy / 2
	end
	return nil
end

function TerrainPlanner.height(self: Field, x: number, z: number): number
	return self:sample(x, z).height
end

function TerrainPlanner.sample(self: Field, x: number, z: number): TerrainSample
	local floor = self.floor
	local h, mat, regionId = natural(self, x, z)
	local base = h
	local onPad, district
	h, onPad, district = padHeight(self, x, z, h)
	local water: number? = if base < floor.seaLevel and not onPad then floor.seaLevel else nil

	-- marsh tidepools
	for _, pool in floor.pools do
		local d = Geom.dist2(x, z, pool.x, pool.z)
		if d < pool.radius + 10 then
			local t = Geom.smoothstep(pool.radius * 0.55, pool.radius + 10, d)
			local hb = Geom.lerp(pool.bedY, h, t)
			if hb < h then
				h = hb
			end
			if d < pool.radius + 4 and h < pool.waterY then
				water = pool.waterY
			end
			if d < pool.radius + 6 then
				mat = "Mud"
			end
		end
	end

	-- plazas (flat discs)
	local plazaMat: string? = nil
	for _, pz in floor.plazas do
		local d = Geom.dist2(x, z, pz.x, pz.z)
		if d < pz.radius + 8 then
			local t = Geom.smoothstep(pz.radius, pz.radius + 8, d)
			h = Geom.lerp(pz.y, h, t)
			if d < pz.radius then
				plazaMat = pz.material
			end
		end
	end

	-- streets, stairs and causeways
	local streetMat: string? = nil
	for _, s in self.streets do
		if inBox(s.box, x, z) then
			local d, sy = closestY(s.points, x, z)
			local half = s.width / 2
			if d < half + s.shoulder then
				local t = Geom.smoothstep(half, half + s.shoulder, d)
				local target = sy - 0.4
				local hn = Geom.lerp(target, h, t)
				-- shoulders may only lower the ground beside raised roads by blending, never dig into pads
				if d < half or not onPad then
					h = hn
				end
				if d < half then
					streetMat = s.material
					if water ~= nil and h >= (water :: number) then
						water = nil
					end
				end
			end
		end
	end

	-- canals: carved channel below the street level
	local canalWater: number? = nil
	for _, c in self.canals do
		if inBox(c.box, x, z) then
			local d, sy = canalStreetY(c.pts, x, z)
			if d < c.def.width / 2 + 1.6 then
				h = sy - c.def.depth
				canalWater = sy - c.def.waterDrop
				mat = "Slate"
				streetMat = nil
				plazaMat = nil
			end
		end
	end

	-- solid additions (islets, platforms)
	for _, c in self.fills do
		local top = fillTop(c, x, z)
		if top and top > h then
			h = top
			mat = c.material
			if water ~= nil and h >= (water :: number) then
				water = nil
			end
		end
	end

	-- materials
	if canalWater then
		water = nil -- canals use the custom Current water surface, not terrain water
	elseif streetMat then
		mat = streetMat :: string
	elseif plazaMat then
		mat = plazaMat :: string
	elseif onPad then
		local lane = false
		if self.ctx then
			local d = Context.corridorClearance(self.ctx :: Context, x, z, { street = true })
			lane = d < 0
		end
		if lane then
			mat = "Cobblestone"
		else
			-- town ground between streets: flagstones with the odd garden or yard
			local n = Geom.fbm(x / 36, z / 36, floor.seed + 9, 2)
			mat = if n > 0.42 then "Grass" elseif n > 0.3 then "Ground" else "Pavement"
			if district and district.style == "Docks" then
				mat = if z > 1088 then "WoodPlanks" elseif n > 0.35 then "Mud" else "Cobblestone"
			elseif district and district.style == "Noble" then
				mat = if n > 0.25 then "Grass" else "Slate"
			end
		end
	else
		-- natural ground: shore, slope and region rules
		local hx = natural(self, x + 4, z)
		local hz = natural(self, x, z + 4)
		local slope = math.max(math.abs(hx - base), math.abs(hz - base)) / 4
		local n = Geom.fbm(x / 55, z / 55, floor.seed + 21, 3)
		if regionId == "sea" or (h < floor.seaLevel + 2.5 and regionId ~= "marsh") then
			mat = if n > 0.3 then "Mud" else "Sand"
		elseif slope > 0.95 then
			mat = if regionId == "northwall" or regionId == "rim" then "Basalt" elseif regionId == "crags" then "Slate" else "Rock"
		elseif regionId == "marsh" then
			mat = if h < 3.4 then "Mud" elseif n > 0.15 then "LeafyGrass" elseif n > -0.25 then "Grass" else "Ground"
		elseif regionId == "forest" or regionId == "bluffs" or regionId == "gaterise" or regionId == "townbase" then
			mat = if n > 0.3 then "LeafyGrass" elseif n > -0.3 then "Grass" else "Ground"
		elseif regionId == "crags" then
			mat = if n > 0.2 then "Rock" elseif n > -0.2 then "Ground" else "Slate"
		end
		-- dirt paths
		for _, p in self.paths do
			if inBox(p.box, x, z) then
				local d = closestY(p.points, x, z)
				if d < p.width / 2 then
					mat = p.material
				end
			end
		end
	end

	return { height = h, material = mat, water = water }
end

-- Water surface of a canal at a point (nil outside canals); used by planners.
function TerrainPlanner.canalWater(self: Field, x: number, z: number): number?
	for _, c in self.canals do
		if inBox(c.box, x, z) then
			local d, sy = canalStreetY(c.pts, x, z)
			if d < c.def.width / 2 then
				return sy - c.def.waterDrop
			end
		end
	end
	return nil
end

return TerrainPlanner
