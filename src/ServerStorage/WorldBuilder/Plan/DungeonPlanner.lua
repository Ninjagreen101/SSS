--!strict
-- DungeonPlanner: The Sunken Cistern, Lowharbor's multi-room dungeon. Built as
-- a template (origin at the arrival point) that DungeonService clones into a
-- private instance per party.
--
--   Entry Stair -> Sluice Gallery -> Flooded Hall -+-> Leech Pools   (valve 1)
--                                                  +-> Lantern Chapel (valve 2)
--                                                  +-> Valve Chamber  (valve 3, sluice gate)
--                                                         -> Reservoir (Cistern Matron, reward, exit)
--
-- Turning all three valves raises the sluice gate into the Reservoir.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Rng = require(Shared.Util.Rng)

local Plan = require(script.Parent.Plan)
local Facade = require(script.Parent.Facade)

type PlanNode = Types.PlanNode
type Rng = Rng.Rng
type Side = Facade.Side

local DungeonPlanner = {}

local ORIGIN = Plan.frame(0, 0, 0, 0, 1)
local S = 1.5
local PANEL = 16 * S
local ROW = 12 * S
local ROWS = 2

type Door = { side: string, index: number }

type RoomOpts = {
	name: string,
	cx: number,
	cy: number,
	cz: number,
	w: number,
	d: number,
	doors: { Door },
	floorMaterial: string?,
}

-- Rectangular stone hall: walls (two rows of 1.5x kit panels), arched door
-- panels where corridors join, floor, ceiling, merged colliders.
local function room(parent: PlanNode, o: RoomOpts, rng: Rng): PlanNode
	local node = Plan.node(o.name, o.cx, o.cy, o.cz, 0, "Default")
	node.attributes.Room = o.name
	local hw, hd = o.w / 2, o.d / 2
	local sides: { Side } = {
		Facade.makeSide("front", -hw, -hd, hw, -hd, 0),
		Facade.makeSide("right", hw, -hd, hw, hd, -math.pi / 2),
		Facade.makeSide("back", hw, hd, -hw, hd, math.pi),
		Facade.makeSide("left", -hw, hd, -hw, -hd, math.pi / 2),
	}
	local top = ROW * ROWS
	for _, side in sides do
		local n = math.floor(side.length / PANEL + 0.5)
		for i = 1, n do
			local isDoor = false
			for _, dr in o.doors do
				if dr.side == side.id and dr.index == i then
					isDoor = true
				end
			end
			for row = 0, ROWS - 1 do
				local kind = if isDoor and row == 0 then "archdoor" elseif row == 1 and rng:chance(0.35) then "archwin" elseif rng:chance(0.15) then "damaged" else "plain"
				if kind == "damaged" and row == 1 then
					kind = "plain"
				end
				local u = (i - 0.5) * PANEL
				local f = Plan.frame(side.ax + side.dx * u, row * ROW, side.az + side.dz * u, side.ry, S)
				Plan.pieceIn(node, f, "wall_" .. kind .. "_w16", 0, 0, 0, 0, { material = "Slate", color = "StoneWet" })
				if kind == "archdoor" then
					table.insert(side.openings, { u0 = u - 3 * S, u1 = u + 3 * S, v0 = 0, v1 = 8 * S })
					Plan.pieceIn(node, f, "frame_archdoor", 0, 0, 0, 0, { material = "Slate", color = "StoneDark" })
				elseif kind == "archwin" then
					-- dark alcoves: openings backed by rock, no glass
					Plan.pieceIn(node, f, "frame_archwin", -4, 3.5, 0, 0, { material = "Slate", color = "StoneDark" })
					Plan.pieceIn(node, f, "frame_archwin", 4, 3.5, 0, 0, { material = "Slate", color = "StoneDark" })
				end
				if row == 0 and not isDoor and rng:chance(0.25) then
					Plan.assembly(node, f, "wall_lantern", 0, 9.6, 0.5, math.pi, { s = 1 / S })
				end
			end
		end
		Facade.emitColliders(node, side, 0, top, 1 * S)
		-- rock backing behind wall openings so nothing looks into the void
		local mx = side.ax + side.dx * side.length / 2
		local mz = side.az + side.dz * side.length / 2
		local nx, nz = -math.sin(side.ry), -math.cos(side.ry)
		Plan.solid(node, mx + nx * 4, top / 2, mz + nz * 4, side.length + 8, top + 4, 4, side.ry, { kind = "Surface", material = "Rock", color = "StoneShadow" })
	end
	for _, c in { { -hw, -hd }, { hw, -hd }, { hw, hd }, { -hw, hd } } do
		Plan.piece(node, "pillar_square_h12", c[1], 0, c[2], 0, { s = S * 1.4, material = "Slate", color = "StoneDark", sy = ROWS / 1.4 })
	end
	Plan.solid(node, 0, -1, 0, o.w, 2, o.d, 0, { kind = "Surface", material = o.floorMaterial or "Cobblestone", color = "StoneWet" })
	Plan.solid(node, 0, top + 1, 0, o.w + 2, 2, o.d + 2, 0, { kind = "Surface", material = "Slate", color = "StoneShadow" })
	-- ceiling beams
	local bx = -hw + 12
	while bx < hw - 4 do
		Plan.piece(node, "beam_l8", bx, top, 0, 0, { s = S, sz = o.d / (8 * S), material = "Slate", color = "StoneDark" })
		bx += 24
	end
	Plan.child(parent, node)
	return node
end

-- Straight corridor between two door centres (axis aligned); a level change
-- becomes a smooth cobbled ramp.
local function corridor(parent: PlanNode, name: string, ax: number, ay: number, az: number, bx: number, by: number, bz: number)
	local node = Plan.node(name, 0, 0, 0, 0, "Default")
	local dx, dz = bx - ax, bz - az
	local len = math.sqrt(dx * dx + dz * dz)
	local ux, uz = dx / len, dz / len
	local ry = math.atan2(-uz, ux) -- local +X along the corridor
	local width = 10
	local h = 14
	local cx, cz = (ax + bx) / 2, (az + bz) / 2
	local lowY = math.min(ay, by)
	local hiY = math.max(ay, by)
	local wallH = (hiY - lowY) + h
	local count = math.max(1, math.ceil(len / 16))
	local seg = len / count
	for k = 0, count - 1 do
		local u = (k + 0.5) * seg
		local px, pz = ax + ux * u, az + uz * u
		for _, sgn in { 1, -1 } do
			local nx, nz = -uz * sgn, ux * sgn
			Plan.piece(node, "wall_plain_w16", px + nx * (width / 2 + 0.5), lowY, pz + nz * (width / 2 + 0.5), math.atan2(-nx, -nz), {
				sx = seg / 16,
				sy = wallH / 12,
				material = "Slate",
				color = "StoneWet",
			})
		end
		if k % 2 == 0 then
			Plan.assembly(node, ORIGIN, "hanging_lantern", px, hiY + h - 0.5, pz, 0, { noLights = k % 4 ~= 0 })
		end
	end
	Plan.solid(node, cx, (ay + by) / 2 - 1, cz, len + 0.5, 2, width + 2, ry, {
		kind = "Surface",
		material = "Cobblestone",
		color = "StoneWet",
		rz = math.atan2(by - ay, len),
	})
	Plan.solid(node, cx, hiY + h + 1, cz, len + 2, 2, width + 4, ry, { kind = "Surface", material = "Slate", color = "StoneShadow" })
	Plan.child(parent, node)
end

local function currentPool(node: PlanNode, x: number, y: number, z: number, sx: number, sz: number, tag: string)
	Plan.solid(node, x, y - 0.75, z, sx, 1.5, sz, 0, {
		kind = "Current",
		material = "Glass",
		color = "CurrentTeal",
		transparency = 0.25,
		tag = tag,
	})
	Plan.solid(node, x, y - 4, z, sx + 1, 2, sz + 1, 0, { kind = "Surface", material = "Slate", color = "StoneShadow" })
	Plan.light(node, x, y + 2, z, "CurrentTeal", math.max(sx, sz) * 0.9, 1.1, false)
	Plan.emitter(node, "CurrentMotes", x, y + 0.4, z, sx, 1, sz, 0)
end

local function spawn(node: PlanNode, id: string, mob: string, x: number, y: number, z: number, count: number, levelMin: number, levelMax: number, radius: number)
	Plan.marker(node, "DungeonSpawn", id, x, y, z, 0, {
		Mob = mob,
		Count = count,
		LevelMin = levelMin,
		LevelMax = levelMax,
		Radius = radius,
	})
end

function DungeonPlanner.plan(dungeonId: string): PlanNode
	local root = Plan.node("Dungeon_" .. dungeonId, 0, 0, 0, 0, "Atomic")
	root.attributes.Dungeon = dungeonId
	table.insert(root.tags, "DungeonTemplate")
	local rng = Rng.new(dungeonId)

	-- entry landing and stair down
	Plan.solid(root, 0, -1, -4, 24, 2, 16, 0, { kind = "Surface", material = "Cobblestone", color = "StoneWet" })
	Plan.marker(root, "DungeonArrival", "arrival", 0, 0.5, -4, 0, {})
	Plan.solid(root, 0, 2.5, 4.5, 0.6, 6, 6, 0, { kind = "Current", shape = "Cylinder", material = "Glass", color = "CurrentTeal", transparency = 0.2, tag = "DungeonExitPortal", rz = math.pi / 2 })
	Plan.marker(root, "DungeonExit", "entry_exit", 0, 0.5, 4.5, 0, { Radius = 4 })
	corridor(root, "EntryStair", 0, 0, -12, 0, -16, -32)

	-- A: Sluice Gallery
	local a = room(root, { name = "SluiceGallery", cx = 0, cy = -16, cz = -80, w = 72, d = 96, doors = { { side = "back", index = 2 }, { side = "front", index = 2 } } }, rng)
	currentPool(a, 0, -1.5, 0, 12, 90, "CurrentWater")
	for _, sx in { -1, 1 } do
		for k = -1, 1 do
			Plan.piece(a, "pillar_round_h12", sx * 14, 0, k * 28, 0, { s = 1.5, material = "Slate", color = "StoneWet" })
			Plan.piece(a, "hanging_chain", sx * 22, 34, k * 28 + 10, 0, {})
		end
	end
	for _ = 1, 6 do
		Plan.piece(a, "puddle", rng:range(-30, 30), 0.03, rng:range(-44, 44), rng:range(0, 6), { s = rng:range(0.6, 1.2), tag = "Puddle" })
	end
	spawn(a, "gallery_leeches", "CisternLeech", 0, 0.5, -10, 3, 7, 8, 26)

	corridor(root, "GalleryToHall", 0, -16, -128, 0, -16, -144)

	-- B: Flooded Hall
	local b = room(root, { name = "FloodedHall", cx = 0, cy = -16, cz = -204, w = 120, d = 120, doors = { { side = "back", index = 3 }, { side = "front", index = 3 }, { side = "left", index = 3 }, { side = "right", index = 3 } } }, rng)
	for _, q in { { -32, -32 }, { 32, -32 }, { -32, 32 }, { 32, 32 } } do
		currentPool(b, q[1], -1, q[2], 38, 38, "CurrentWater")
	end
	for _, x in { -48, -16, 16, 48 } do
		for _, z in { -48, -16, 16, 48 } do
			Plan.piece(b, "column_h24", x, 0, z, 0, { s = 1.45, material = "Slate", color = "StoneWet" })
		end
	end
	for _ = 1, 6 do
		Plan.piece(b, "rubble_pile", rng:range(-50, 50), 0, rng:range(-50, 50), rng:range(0, 6), {})
	end
	spawn(b, "hall_leeches", "CisternLeech", 0, 0.5, 0, 4, 8, 9, 34)
	spawn(b, "hall_acolyte", "LanternAcolyte", 0, 0.5, 30, 1, 8, 9, 10)

	corridor(root, "HallToPools", -60, -16, -204, -76, -16, -204)
	corridor(root, "HallToChapel", 60, -16, -204, 76, -16, -204)
	corridor(root, "HallToValves", 0, -16, -264, 0, -16, -280)

	-- C: Leech Pools (valve 1)
	local c = room(root, { name = "LeechPools", cx = -112, cy = -16, cz = -204, w = 72, d = 72, doors = { { side = "right", index = 2 } } }, rng)
	currentPool(c, -8, -2, -14, 40, 26, "CurrentWater")
	currentPool(c, -8, -2, 18, 40, 22, "CurrentWater")
	Plan.piece(c, "pier_deck_8", -8, 0, 2, 0, { material = "WoodPlanks", color = "WoodWet", sx = 5 })
	for _ = 1, 4 do
		Plan.piece(c, "crystal_m", rng:range(-30, 10), -1.5, rng:range(-30, 30), rng:range(0, 6), { tag = "CurrentCrystal" })
	end
	Plan.assembly(c, ORIGIN, "valve", -34, 0, 0, math.pi / 2)
	Plan.marker(c, "CisternValve", "valve_1", -33, 4, 0, math.pi / 2, { Index = 1 })
	spawn(c, "pool_leeches", "CisternLeech", -8, 0.5, 0, 6, 8, 10, 26)

	-- D: Lantern Chapel (valve 2)
	local d = room(root, { name = "LanternChapel", cx = 112, cy = -16, cz = -204, w = 72, d = 72, doors = { { side = "left", index = 2 } } }, rng)
	Plan.solid(d, 20, 1, 0, 24, 2, 40, 0, { kind = "Surface", material = "Marble", color = "Marble" })
	Plan.assembly(d, ORIGIN, "statue", 28, 2, 0, -math.pi / 2, { s = 1.2 })
	for row = 0, 4 do
		for _, sz in { -1, 1 } do
			Plan.piece(d, "bench", -22 + row * 7, 0, sz * 9, -math.pi / 2, {})
		end
	end
	for k = -2, 2 do
		Plan.assembly(d, ORIGIN, "hanging_lantern", k * 12, 34, 0, 0, { noLights = k % 2 ~= 0 })
	end
	Plan.assembly(d, ORIGIN, "valve", 34, 0, -24, -math.pi / 2)
	Plan.marker(d, "CisternValve", "valve_2", 33, 4, -24, -math.pi / 2, { Index = 2 })
	spawn(d, "chapel_acolytes", "LanternAcolyte", 10, 0.5, 0, 3, 9, 11, 20)
	spawn(d, "chapel_leeches", "CisternLeech", -14, 0.5, 0, 2, 9, 10, 14)

	-- E: Valve Chamber (valve 3, sluice gate)
	local e = room(root, { name = "ValveChamber", cx = 0, cy = -16, cz = -304, w = 72, d = 48, doors = { { side = "back", index = 2 }, { side = "front", index = 2 } } }, rng)
	for _, sx in { -1, 1 } do
		Plan.solid(e, sx * 30, 8, 0, 44, 5, 5, math.pi / 2, { kind = "Surface", shape = "Cylinder", material = "Metal", color = "IronRust" })
		Plan.solid(e, sx * 30, 20, 0, 44, 4, 4, math.pi / 2, { kind = "Surface", shape = "Cylinder", material = "Metal", color = "Bronze" })
	end
	Plan.assembly(e, ORIGIN, "valve", -34, 0, 10, math.pi / 2)
	Plan.marker(e, "CisternValve", "valve_3", -33, 4, 10, math.pi / 2, { Index = 3 })
	Plan.piece(e, "sluice_gate", 0, 0, -24.5, 0, { tag = "SluiceGate", sx = 0.8 })
	Plan.solid(e, 0, 6, -24.5, 9, 12, 2, 0, { kind = "Barrier", material = "SmoothPlastic", color = "StoneDark", transparency = 1, tag = "SluiceBarrier", name = "SluiceBarrier" })
	Plan.marker(e, "SluiceGate", "sluice_gate", 0, 0, -24.5, 0, { Valves = 3, Lift = 16 })
	spawn(e, "valve_acolytes", "LanternAcolyte", 0, 0.5, 0, 2, 10, 11, 14)

	corridor(root, "ValvesToReservoir", 0, -16, -328, 0, -28, -352)

	-- F: Reservoir (boss, reward, exit)
	local f = room(root, { name = "Reservoir", cx = 0, cy = -28, cz = -412, w = 120, d = 120, doors = { { side = "back", index = 3 } } }, rng)
	currentPool(f, 0, -1.2, 0, 116, 116, "CurrentWater")
	Plan.solid(f, 0, 0.5, 0, 3, 64, 64, 0, { kind = "Surface", shape = "Cylinder", material = "Slate", color = "StoneWet", rz = math.pi / 2 })
	Plan.solid(f, 0, 0.5, 44, 10, 1, 26, 0, { kind = "Surface", material = "Cobblestone", color = "StoneWet" })
	for i = 0, 7 do
		local ang = i / 8 * math.pi * 2
		Plan.piece(f, "column_h24", math.cos(ang) * 46, -2, math.sin(ang) * 46, 0, { s = 1.6, material = "Slate", color = "StoneWet" })
	end
	Plan.solid(f, 0, 18, -56, 30, 36, 1.2, 0, { kind = "Falls", material = "Glass", color = "CurrentFalls", transparency = 0.35, tag = "CurrentFalls" })
	Plan.emitter(f, "FallsMist", 0, 1, -50, 30, 2, 4, 0)
	Plan.light(f, 0, 12, -48, "CurrentTeal", 50, 2, false)
	Plan.marker(f, "DungeonBoss", "cistern_matron", 0, 2, 0, 0, { Mob = "CisternMatron", Level = 12, ArenaRadius = 30 })
	Plan.assembly(f, ORIGIN, "treasure_chest", -8, 2, -22, 0)
	Plan.marker(f, "DungeonChest", "cistern_reward", -8, 2, -22, 0, { LootTable = "SunkenCisternClear" })
	Plan.solid(f, 8, 4.6, -22, 0.6, 7, 7, 0, { kind = "Current", shape = "Cylinder", material = "Glass", color = "CurrentTeal", transparency = 0.15, tag = "DungeonExitPortal", rz = math.pi / 2 })
	Plan.marker(f, "DungeonExit", "reservoir_exit", 8, 2, -22, 0, { Radius = 4, RequiresClear = true })

	return root
end

return DungeonPlanner
