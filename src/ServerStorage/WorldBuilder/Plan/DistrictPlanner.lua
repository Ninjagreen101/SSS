--!strict
-- DistrictGenerator (planning half): lays out an organic street network inside
-- a district polygon (curved lanes and cross lanes, never a perfect grid),
-- then walks every street frontage placing building lots that face the street,
-- varying height and style by district, and dresses the streets with lamps,
-- benches, carts and clutter. Landmarks, plazas and canals placed earlier are
-- respected through the shared Context.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Rng = require(Shared.Util.Rng)
local Geom = require(Shared.Util.Geom)
local Config = require(Shared.Config)

local Plan = require(script.Parent.Plan)
local Context = require(script.Parent.Context)
local BuildingPlanner = require(script.Parent.BuildingPlanner)

type PlanNode = Types.PlanNode
type DistrictDef = Types.DistrictDef
type Vec3 = Types.Vec3
type OBB = Types.OBB
type Rng = Rng.Rng
type Context = Context.Context
type Corridor = Context.Corridor

local D = Config.World.Districts

local DistrictPlanner = {}

local FRONTAGES = { 12, 16, 20, 24, 28, 32 }
local DEPTHS = { 12, 16, 20, 24, 28 }

-- --------------------------------------------------------------- lanes

local function shrinkInside(poly: { Types.Point2 }, x: number, z: number, margin: number): boolean
	return Geom.pointInPolygon(x, z, poly) and -Geom.polygonDistance(x, z, poly) >= margin
end

-- Split a sampled line into runs that stay inside the polygon.
local function clipRuns(points: { Vec3 }, poly: { Types.Point2 }, margin: number, minLen: number): { { Vec3 } }
	local runs: { { Vec3 } } = {}
	local cur: { Vec3 } = {}
	for _, p in points do
		if shrinkInside(poly, p[1], p[3], margin) then
			table.insert(cur, p)
		else
			if #cur >= 2 then
				table.insert(runs, cur)
			end
			cur = {}
		end
	end
	if #cur >= 2 then
		table.insert(runs, cur)
	end
	local out: { { Vec3 } } = {}
	for _, r in runs do
		if Geom.polylineLength(r, 3) >= minLen then
			table.insert(out, r)
		end
	end
	return out
end

local function generateLanes(district: DistrictDef, ctx: Context, rng: Rng): { Corridor }
	local poly = district.polygon
	local b = Geom.polygonBounds(poly)
	local spanX, spanZ = b.maxX - b.minX, b.maxZ - b.minZ
	local alongX = spanX >= spanZ
	local spacing = district.secondarySpacing or 70
	local lanes: { Corridor } = {}
	local width = D.SecondaryWidth
	local y = district.baseY

	local function tryLane(points: { Vec3 }, id: string)
		for i, run in clipRuns(points, poly, width / 2 + 4, 70) do
			-- reject lanes that mostly duplicate an existing street or ride a canal
			local near, total = 0, 0
			for _, s in Geom.samplePolyline(run, 12, 3) do
				total += 1
				local d = Context.corridorClearance(ctx, s.x, s.z, nil)
				if d < width + 8 then
					near += 1
				end
			end
			if total > 0 and near / total < 0.35 then
				local c: Corridor = { id = id .. "_" .. i, points = run, width = width, kind = "street", main = false }
				table.insert(lanes, c)
				Context.addCorridor(ctx, c)
			end
		end
	end

	local amp = rng:range(6, 14)
	local wave = rng:range(140, 220)
	local phase = rng:range(0, math.pi * 2)
	-- long lanes
	local offset = (if alongX then spanZ else spanX) % spacing / 2 + spacing / 2
	local t = (if alongX then b.minZ else b.minX) + offset
	local n = 0
	while t < (if alongX then b.maxZ else b.maxX) do
		n += 1
		local pts: { Vec3 } = {}
		local s = if alongX then b.minX else b.minZ
		local e = if alongX then b.maxX else b.maxZ
		local jitter = rng:range(-spacing * 0.15, spacing * 0.15)
		local u = s
		while u <= e do
			local warp = math.sin(u / wave + phase + n) * amp + Geom.fbm(u / 90, n * 3.1, district.seed, 2) * 6
			if alongX then
				table.insert(pts, { u, y, t + jitter + warp })
			else
				table.insert(pts, { t + jitter + warp, y, u })
			end
			u += 12
		end
		tryLane(pts, district.id .. "_lane" .. n)
		t += spacing * rng:range(0.9, 1.15)
	end
	-- cross lanes
	local cross = D.CrossSpacing * rng:range(0.9, 1.2)
	t = (if alongX then b.minX else b.minZ) + cross * rng:range(0.4, 0.7)
	n = 0
	while t < (if alongX then b.maxX else b.maxZ) do
		n += 1
		local pts: { Vec3 } = {}
		local s = if alongX then b.minZ else b.minX
		local e = if alongX then b.maxZ else b.maxX
		local u = s
		local lean = rng:range(-0.18, 0.18)
		while u <= e do
			local warp = math.sin(u / (wave * 0.7) + phase * 1.7 + n) * amp * 0.8 + (u - s) * lean
			if alongX then
				table.insert(pts, { t + warp, y, u })
			else
				table.insert(pts, { u, y, t + warp })
			end
			u += 12
		end
		tryLane(pts, district.id .. "_cross" .. n)
		t += cross * rng:range(0.85, 1.25)
	end
	return lanes
end

-- -------------------------------------------------------------- lots

type Frontage = { points: { Vec3 }, width: number, sides: string, main: boolean }

local function samplesAt(points: { Vec3 }, along: number): (number, number, number, number)
	local acc = 0
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local seg = Geom.dist2(a[1], a[3], b[1], b[3])
		if acc + seg >= along or i == #points - 1 then
			local t = if seg > 0 then math.clamp((along - acc) / seg, 0, 1) else 0
			local tx, tz = (b[1] - a[1]) / math.max(seg, 1e-6), (b[3] - a[3]) / math.max(seg, 1e-6)
			return a[1] + (b[1] - a[1]) * t, a[3] + (b[3] - a[3]) * t, tx, tz
		end
		acc += seg
	end
	local last = points[#points]
	return last[1], last[3], 1, 0
end

local function placeLots(district: DistrictDef, ctx: Context, node: PlanNode, f: Frontage, rng: Rng, counter: { n: number })
	local poly = district.polygon
	local total = Geom.polylineLength(f.points, 3)
	local sideList: { number } = {}
	if f.sides == "both" or f.sides == "left" then
		table.insert(sideList, 1)
	end
	if f.sides == "both" or f.sides == "right" then
		table.insert(sideList, -1)
	end
	for _, sideSign in sideList do
		local s = rng:range(2, 10)
		while s < total - 8 do
			local fw = rng:pick(FRONTAGES)
			if rng:chance(0.35) then
				fw = math.min(fw, 20)
			end
			local depth = rng:pick(DEPTHS)
			if district.style == "Docks" and rng:chance(0.4) then
				fw, depth = rng:pick({ 24, 28, 32 }), rng:pick({ 20, 24 })
			end
			depth = math.min(depth, 28)
			local cx, cz, tx, tz = samplesAt(f.points, s + fw / 2)
			-- left normal = (tz, -tx); right = (-tz, tx)
			local nx, nz = tz * sideSign, -tx * sideSign
			local setback = f.width / 2 + rng:range(D.SetbackMin, D.SetbackMax)
			local dist = setback + depth / 2 + 1.3
			local bx, bz = cx + nx * dist, cz + nz * dist
			local ry = math.atan2(nx, nz)
			local obb: OBB = { x = bx, z = bz, hw = fw / 2 + 1.3, hd = depth / 2 + 1.3, ry = ry }
			local inside = true
			for _, c in Geom.obbCorners(obb) do
				if not shrinkInside(poly, c[1], c[2], 1) then
					inside = false
					break
				end
			end
			if inside and not Context.blocked(ctx, obb, 0.2, D.StreetClearance) then
				counter.n += 1
				local kind = rng:weighted(district.kinds)
				local storeys = rng:int(district.storeys[1], district.storeys[2])
				if kind == "warehouse" then
					storeys = math.min(storeys, 2)
				end
				if fw < 12 or depth < 12 then
					storeys = 1
				end
				local wealth = math.clamp(district.wealth + rng:range(-0.2, 0.2), 0, 1)
				local info = BuildingPlanner.plan({
					name = string.format("%s_%03d", district.id, counter.n),
					w = fw,
					d = depth,
					storeys = storeys,
					style = district.style,
					wealth = wealth,
					kind = kind,
					seed = district.seed * 1000 + counter.n,
					plinth = 2,
					ridgeAxis = if fw < depth and rng:chance(0.7) then "z" else "x",
					damaged = if district.style == "Docks" and rng:chance(0.08) then 0.18 else nil,
				}, bx, district.baseY, bz, ry)
				Plan.child(node, info.node)
				Context.addObb(ctx, obb)
				local gap = if rng:chance(D.RowHouseChance * district.density) then 0 else rng:range(D.AlleyMin, D.AlleyMax)
				s += fw + 2.6 + gap
			else
				s += 4
			end
		end
	end
end

-- ------------------------------------------------------- street dressing

local function dressStreet(district: DistrictDef, ctx: Context, node: PlanNode, f: Frontage, rng: Rng)
	local total = Geom.polylineLength(f.points, 3)
	local y = district.baseY
	local s = rng:range(6, 20)
	local side = 1
	while s < total - 4 do
		local cx, cz, tx, tz = samplesAt(f.points, s)
		local nx, nz = tz * side, -tx * side
		local edge = f.width / 2 - 1.2
		local lx, lz = cx + nx * edge, cz + nz * edge
		if Context.pointFree(ctx, lx, lz, 1.5, nil) and shrinkInside(district.polygon, lx, lz, 1) then
			local ry = math.atan2(nx, nz)
			Plan.assembly(node, Plan.frame(0, 0, 0, 0, 1), "street_lantern", lx, y, lz, ry)
			Context.addObb(ctx, { x = lx, z = lz, hw = 1, hd = 1, ry = 0 })
		end
		-- small clutter between lamps
		if rng:chance(0.55) then
			local s2 = s + rng:range(8, 18)
			local px, pz, ptx, ptz = samplesAt(f.points, s2)
			local sgn = if rng:chance(0.5) then 1 else -1
			local qx, qz = ptz * sgn, -ptx * sgn
			local ox, oz = px + qx * (f.width / 2 - 1.8), pz + qz * (f.width / 2 - 1.8)
			if Context.pointFree(ctx, ox, oz, 2.2, nil) and shrinkInside(district.polygon, ox, oz, 1) then
				local item = rng:weighted({
					bench = 2,
					barrel = if district.style == "Docks" then 3 else 1,
					crate_s = if district.style == "Docks" then 3 else 1,
					potted_plant = if district.style == "Residential" or district.style == "Noble" then 3 else 0.5,
					cart = 0.6,
					rubble_pile = if district.style == "Docks" then 0.4 else 0.1,
				})
				local ry = math.atan2(qx, qz) + (if item == "bench" then 0 else rng:range(-0.5, 0.5))
				if item == "potted_plant" then
					Plan.assembly(node, Plan.frame(0, 0, 0, 0, 1), item, ox, y, oz, ry)
				elseif item == "cart" then
					Plan.piece(node, "cart", ox, y, oz, math.atan2(ptx, ptz), {})
				else
					Plan.piece(node, item, ox, y, oz, ry, {})
				end
				Context.addObb(ctx, { x = ox, z = oz, hw = 1.6, hd = 1.6, ry = 0 })
			end
		end
		s += D.LampSpacing * rng:range(0.85, 1.15)
		side = -side
	end
end

-- overlook railings where a lane runs into a terrace edge
local function capLaneEnds(district: DistrictDef, ctx: Context, node: PlanNode, lane: Corridor)
	local pts = lane.points
	for _, endIdx in { 1, #pts } do
		local p = pts[endIdx]
		local q = if endIdx == 1 then pts[2] else pts[#pts - 1]
		local dx, dz = p[1] - q[1], p[3] - q[3]
		local len = math.sqrt(dx * dx + dz * dz)
		if len > 0 then
			dx, dz = dx / len, dz / len
			local ax, az = p[1] + dx * 3, p[3] + dz * 3
			local below = ctx.height(ax + dx * 14, az + dz * 14)
			if below < district.baseY - 6 then
				local ry = Geom.yawAlong(-dz, dx)
				local n = math.ceil(lane.width / 8)
				for k = 0, n - 1 do
					local off = (k - (n - 1) / 2) * 8
					Plan.piece(node, "railing_l8", ax + (-dz) * off, district.baseY, az + dx * off, ry, {})
				end
			end
		end
	end
end

function DistrictPlanner.plan(district: DistrictDef, ctx: Context): PlanNode
	local rng = Rng.new(district.seed * 7919)
	local node = Plan.node("District_" .. district.id, 0, 0, 0, 0, "Default")
	node.attributes.District = district.id
	local counter = { n = 0 }

	-- main streets that pass through this district
	local frontages: { Frontage } = {}
	for _, st in ctx.floor.streets do
		if st.sides ~= "none" then
			local sampled: { Vec3 } = {}
			for _, s in Geom.samplePolyline(st.points, 8, 3) do
				table.insert(sampled, { s.x, s.y, s.z })
			end
			for _, run in clipRuns(sampled, district.polygon, 2, 40) do
				table.insert(frontages, { points = run, width = st.width, sides = st.sides or "both", main = true })
			end
		end
	end
	-- generated lanes
	local lanes = generateLanes(district, ctx, rng:fork("lanes"))
	local laneNode = Plan.node("Lanes", 0, 0, 0, 0, "Default")
	Plan.child(node, laneNode)
	for _, lane in lanes do
		table.insert(frontages, { points = lane.points, width = lane.width, sides = "both", main = false })
		capLaneEnds(district, ctx, laneNode, lane)
	end
	-- dress streets first so lamps sit at the kerb, then fill frontage with lots
	local dress = Plan.node("StreetDressing", 0, 0, 0, 0, "Default")
	Plan.child(node, dress)
	for _, f in frontages do
		dressStreet(district, ctx, dress, f, rng:fork("dress"))
	end
	for i, f in frontages do
		placeLots(district, ctx, node, f, rng:fork("lots" .. i), counter)
	end
	node.attributes.Buildings = counter.n
	return node
end

-- Generated lanes are needed by the terrain painter, so expose a query.
function DistrictPlanner.lanesOf(ctx: Context, districtId: string): { Corridor }
	local out: { Corridor } = {}
	for _, c in ctx.corridors do
		if c.kind == "street" and not c.main and string.sub(c.id, 1, #districtId) == districtId then
			table.insert(out, c)
		end
	end
	return out
end

return DistrictPlanner
