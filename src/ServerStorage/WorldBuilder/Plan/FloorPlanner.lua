--!strict
-- FloorPlanner: plans an entire floor from its FloorDef, in dependency order:
-- terrain field -> corridors (streets, paths, canals) -> reserved landmark /
-- plaza / waystone clearances -> landmarks -> plazas -> canals -> districts ->
-- terrace walls and quay -> waystones -> hidden areas -> nature -> cliffs ->
-- gameplay and ambient markers -> skybox, plus the floor's dungeon template.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Geom = require(Shared.Util.Geom)
local Rng = require(Shared.Util.Rng)
local Config = require(Shared.Config)

local Plan = require(script.Parent.Plan)
local Context = require(script.Parent.Context)
local TerrainPlanner = require(script.Parent.TerrainPlanner)
local DistrictPlanner = require(script.Parent.DistrictPlanner)
local CanalPlanner = require(script.Parent.CanalPlanner)
local LandmarkPlanner = require(script.Parent.LandmarkPlanner)
local PlazaPlanner = require(script.Parent.PlazaPlanner)
local HiddenPlanner = require(script.Parent.HiddenPlanner)
local NaturePlanner = require(script.Parent.NaturePlanner)
local DungeonPlanner = require(script.Parent.DungeonPlanner)

type PlanNode = Types.PlanNode
type FloorDef = Types.FloorDef
type LandmarkDef = Types.LandmarkDef
type Field = TerrainPlanner.Field
type Context = Context.Context
type TerrainCarve = HiddenPlanner.TerrainCarve

export type FloorPlan = {
	root: PlanNode,
	dungeon: PlanNode,
	field: Field,
	ctx: Context,
	carves: { TerrainCarve },
	stats: Types.PlanStats,
	dungeonStats: Types.PlanStats,
	log: { string },
}

local FloorPlanner = {}

local SNAP_KINDS = { RuinedTower = true, Ruins = true, Camp = true, Strand = true }
local ORIGIN = Plan.frame(0, 0, 0, 0, 1)

-- Retaining walls along terrace edges and the harbour quay.
local function terraceWalls(floor: FloorDef, field: Field, ctx: Context): PlanNode
	local node = Plan.node("TerraceWalls", 0, 0, 0, 0, "Default")
	for _, d in floor.districts do
		local poly = d.polygon
		local n = #poly
		for i = 1, n do
			local a, b = poly[i], poly[(i % n) + 1]
			local len = Geom.dist2(a[1], a[2], b[1], b[2])
			local tx, tz = (b[1] - a[1]) / len, (b[2] - a[2]) / len
			-- outward normal: whichever side is outside the polygon
			local nx, nz = tz, -tx
			local mx, mz = (a[1] + b[1]) / 2, (a[2] + b[2]) / 2
			if Geom.pointInPolygon(mx + nx * 3, mz + nz * 3, poly) then
				nx, nz = -nx, -nz
			end
			local count = math.max(1, math.floor(len / 16 + 0.5))
			local seg = len / count
			for k = 0, count - 1 do
				local u = (k + 0.5) * seg
				local px, pz = a[1] + tx * u, a[2] + tz * u
				local outside = field:height(px + nx * 6, pz + nz * 6)
				local drop = d.baseY - outside
				local corridor = Context.corridorClearance(ctx, px, pz, { street = true, canal = true })
				if drop > 5 and corridor > 1 then
					local ry = Geom.yawFacing(nx, nz)
					local wx, wz = px + nx * 0.6, pz + nz * 0.6
					-- one retaining wall panel stretched from below grade to the terrace edge
					local wallH = math.min(drop + 3, 72)
					Plan.piece(node, "wall_plain_w16", wx, d.baseY - wallH, wz, ry, {
						sx = seg / 16,
						sy = wallH / 12,
						material = "Slate",
						color = "StoneWet",
					})
					Plan.piece(node, "cornice_l16", wx, d.baseY - 1, wz, ry, { sx = seg / 16, material = "Limestone", color = "StoneLight" })
					-- balustrade on top where nothing else stands
					local rail = { x = px - nx * 0.2, z = pz - nz * 0.2, hw = seg / 2, hd = 0.6, ry = Geom.yawAlong(tx, tz) }
					if not Context.obbBlocked(ctx, rail, 0) then
						Plan.piece(node, "railing_l8", px - nx * 0.2, d.baseY, pz - nz * 0.2, Geom.yawAlong(tx, tz), { sx = seg / 8 })
					end
				end
			end
		end
	end
	-- harbour quay facing the sea
	local q = floor.quay
	for i = 1, #q - 1 do
		local a, b = q[i], q[i + 1]
		local len = Geom.dist2(a[1], a[2], b[1], b[2])
		local tx, tz = (b[1] - a[1]) / len, (b[2] - a[2]) / len
		local nx, nz = -tz, tx
		if nz < 0 then
			nx, nz = -nx, -nz -- the sea lies to the south (+Z)
		end
		local count = math.max(1, math.floor(len / 16 + 0.5))
		local seg = len / count
		for k = 0, count - 1 do
			local u = (k + 0.5) * seg
			local px, pz = a[1] + tx * u, a[2] + tz * u
			-- the quay wall's water side is its -Z face: face the sea
			Plan.piece(node, "canal_wall_l16", px + nx * 0.4, 6, pz + nz * 0.4, Geom.yawFacing(nx, nz), { sx = seg / 16 })
			if k % 3 == 1 then
				Plan.piece(node, "bollard", px - nx * 1.6, 6, pz - nz * 1.6, 0, {})
			end
		end
	end
	return node
end

local function waystones(floor: FloorDef, field: Field): PlanNode
	local node = Plan.node("Waystones", 0, 0, 0, 0, "Persistent")
	for _, w in floor.waystones do
		local y = w.y
		if not w.district then
			y = field:height(w.x, w.z)
		end
		local wn = Plan.node("Waystone_" .. w.id, w.x, y, w.z, w.ry, "Persistent")
		table.insert(wn.tags, "Waystone")
		wn.attributes.WaystoneId = w.id
		Plan.solid(wn, 0, -2, 0, 4.4, 15, 15, 0, { kind = "Surface", shape = "Cylinder", material = "Slate", color = "StoneDark", rz = math.pi / 2 })
		Plan.assembly(wn, ORIGIN, "waystone", 0, 0.2, 0, 0)
		Plan.marker(wn, "Waystone", w.id, 0, 0.2, 0, 0, {
			NameKey = w.nameKey,
			Floor = floor.index,
			Starting = w.starting == true,
		})
		Plan.child(node, wn)
	end
	return node
end

local function markers(floor: FloorDef, field: Field, ctx: Context): PlanNode
	local node = Plan.node("Markers", 0, 0, 0, 0, "Persistent")
	for _, sp in floor.spawns do
		local y = field:height(sp.x, sp.z)
		Plan.marker(node, "MobSpawnRegion", sp.id, sp.x, y, sp.z, 0, {
			Mob = sp.mob,
			Radius = sp.radius,
			Count = sp.count,
			LevelMin = sp.levelMin,
			LevelMax = sp.levelMax,
			Night = sp.night == true,
			Elite = sp.elite == true,
		})
	end
	-- townsfolk walking routes along the main streets
	local rng = Rng.new("routes")
	for _, st in floor.streets do
		if st.sides ~= "none" then
			local pts = Geom.samplePolyline(st.points, 28, 3)
			local ids = {}
			for i, s in pts do
				local side = if i % 2 == 0 then 1 else -1
				local off = st.width / 2 - 3
				local x, z = s.x + s.tz * off * side, s.z - s.tx * off * side
				local id = string.format("%s_%02d", st.id, i)
				table.insert(ids, id)
				Plan.marker(node, "WalkerNode", id, x, s.y, z, 0, {
					Route = st.id,
					Index = i,
				})
			end
			node.attributes["Route_" .. st.id] = #ids
		end
	end
	-- gulls over the harbour, fish schools in the bay
	for i = 1, 4 do
		Plan.marker(node, "GullCircle", "gulls_" .. i, rng:range(-300, 400), rng:range(40, 70), rng:range(1050, 1350), 0, { Radius = rng:range(40, 90) })
	end
	for i = 1, 3 do
		Plan.marker(node, "FishSchool", "bay_fish_" .. i, rng:range(-400, 450), -3, rng:range(1180, 1400), 0, { Radius = 50 })
	end
	-- floor spawn and death-recovery fallback
	local start = floor.waystones[1]
	for _, w in floor.waystones do
		if w.starting then
			start = w
		end
	end
	Plan.marker(node, "FloorSpawn", floor.id, start.x, start.y + 1, start.z - 10, 0, { Floor = floor.index })
	return node
end

function FloorPlanner.plan(floor: FloorDef): FloorPlan
	local log: { string } = {}
	local field = TerrainPlanner.new(floor)
	local ctx = Context.new(floor, function(x: number, z: number): number
		return field:height(x, z)
	end)
	local root = Plan.node("Floor_" .. floor.id, 0, 0, 0, 0, "Default")
	root.attributes.Floor = floor.index

	-- 1. corridors
	for _, st in floor.streets do
		Context.addCorridor(ctx, { id = st.id, points = st.points, width = st.width, kind = "street", main = true })
	end
	for _, p in floor.paths do
		local pts: { Types.Vec3 } = {}
		for _, q in p.points do
			table.insert(pts, { q[1], 0, q[2] })
		end
		Context.addCorridor(ctx, { id = p.id, points = pts, width = p.width + 2, kind = "path", main = true })
	end
	CanalPlanner.register(ctx)

	-- 2. reserve space for landmarks, plazas, waystones and hidden areas
	for _, l in floor.landmarks do
		if l.clearRadius > 0 then
			Context.addCircle(ctx, l.x, l.z, l.clearRadius)
		end
	end
	for _, pz in floor.plazas do
		Context.addCircle(ctx, pz.x, pz.z, pz.radius)
	end
	for _, w in floor.waystones do
		Context.addCircle(ctx, w.x, w.z, 9)
	end
	for _, h in floor.hidden do
		Context.addCircle(ctx, h.x, h.z, 18)
	end

	-- 3. landmarks
	local landmarks = Plan.child(root, Plan.node("Landmarks", 0, 0, 0, 0, "Default"))
	for _, l in floor.landmarks do
		local def: LandmarkDef = l
		if SNAP_KINDS[l.kind] then
			def = table.clone(l)
			def.y = field:height(l.x, l.z)
		end
		Plan.child(landmarks, LandmarkPlanner.plan(def, field))
	end

	-- 4. plazas and canals
	local plazas = Plan.child(root, Plan.node("Plazas", 0, 0, 0, 0, "Default"))
	for _, pz in floor.plazas do
		Plan.child(plazas, PlazaPlanner.plan(pz, ctx))
	end
	local canals = Plan.child(root, Plan.node("Canals", 0, 0, 0, 0, "Default"))
	for _, c in floor.canals do
		Plan.child(canals, CanalPlanner.plan(c, ctx))
	end

	-- 5. districts (lanes + lots)
	local districts = Plan.child(root, Plan.node("Districts", 0, 0, 0, 0, "Default"))
	for _, d in floor.districts do
		local dn = DistrictPlanner.plan(d, ctx)
		Plan.child(districts, dn)
		table.insert(log, string.format("district %s: %s buildings", d.id, tostring(dn.attributes.Buildings)))
	end
	field:attach(ctx)

	-- 6. terraces, quay, waystones
	Plan.child(root, terraceWalls(floor, field, ctx))
	Plan.child(root, waystones(floor, field))

	-- 7. hidden areas
	local carves: { TerrainCarve } = {}
	local hidden = Plan.child(root, Plan.node("HiddenAreas", 0, 0, 0, 0, "Default"))
	for _, h in floor.hidden do
		local hn, hc = HiddenPlanner.plan(h, field)
		if hn then
			Plan.child(hidden, hn)
		end
		for _, c in hc do
			table.insert(carves, c)
		end
	end
	field:addFills(carves :: any)

	-- 8. nature and cliffs
	local nature = Plan.child(root, Plan.node("Nature", 0, 0, 0, 0, "Default"))
	local shares = NaturePlanner.allocate(floor.wilds, Config.World.Nature.MaxTrees)
	local placedTrees = 0
	for _, w in floor.wilds do
		local budget = { trees = shares[w.id] or 0 }
		Plan.child(nature, NaturePlanner.plan(w, field, ctx, budget))
		placedTrees += (shares[w.id] or 0) - budget.trees
	end
	Plan.child(nature, NaturePlanner.cliffs(field, ctx, 260))
	table.insert(log, string.format("trees placed: %d", placedTrees))

	-- 9. markers
	Plan.child(root, markers(floor, field, ctx))

	local stats = Plan.stats(root)
	local dungeon = DungeonPlanner.plan(floor.dungeon.id)
	local dungeonStats = Plan.stats(dungeon)
	table.insert(log, string.format("floor instances ~%d (budget %d), tris %d", stats.instances, Config.World.InstanceBudgetPerFloor, stats.tris))
	table.insert(log, string.format("dungeon instances ~%d", dungeonStats.instances))
	return {
		root = root,
		dungeon = dungeon,
		field = field,
		ctx = ctx,
		carves = carves,
		stats = stats,
		dungeonStats = dungeonStats,
		log = log,
	}
end

return FloorPlanner
