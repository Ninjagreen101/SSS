--!strict
-- LandmarkPlanner: hand-composed landmarks built from the kit (often at 2-5x
-- scale): the Climbers' Guild hall, Tidewatch Cathedral, the harbour
-- lighthouse, the moored trader and piers, the cistern pumphouse, ruins, the
-- hunters' camp, the sealed Guardian Gate and the distant skybox ring
-- (tower wall, Current falls, the underside of Floor 2 and the drowned world).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Rng = require(Shared.Util.Rng)
local Geom = require(Shared.Util.Geom)

local Plan = require(script.Parent.Plan)
local BuildingPlanner = require(script.Parent.BuildingPlanner)
local TerrainPlanner = require(script.Parent.TerrainPlanner)

type PlanNode = Types.PlanNode
type LandmarkDef = Types.LandmarkDef
type Frame = Plan.Frame
type Field = TerrainPlanner.Field
type Rng = Rng.Rng

local LandmarkPlanner = {}

local ORIGIN = Plan.frame(0, 0, 0, 0, 1)

local function landmarkNode(def: LandmarkDef, streaming: string): PlanNode
	local node = Plan.node("Landmark_" .. def.id, def.x, def.y, def.z, def.ry, streaming)
	node.attributes.Landmark = def.kind
	node.attributes.LOD = "StreamingMesh"
	table.insert(node.tags, "Landmark")
	return node
end

-- stacked tower of ring segments; returns the top height
local function tower(node: PlanNode, x: number, y: number, z: number, d: number, rings: number, s: number, windowsFrom: number, roof: boolean, rng: Rng): number
	local h = 12 * s
	for i = 0, rings - 1 do
		local id = if i >= windowsFrom then string.format("tower_ring_win_d%d", d) else string.format("tower_ring_d%d", d)
		Plan.piece(node, id, x, y + i * h, z, (i % 2) * math.pi / 4, { s = s })
	end
	local top = y + rings * h
	if roof then
		Plan.piece(node, string.format("roof_cone_d%d", d), x, top, z, 0, { s = s, color = rng:pick({ "RoofSlateDark", "Verdigris" }) })
	end
	return top
end

-- ===================================================== Climbers' Guild hall

local function guildHall(def: LandmarkDef, rng: Rng): PlanNode
	local node = landmarkNode(def, "Atomic")
	local info = BuildingPlanner.plan({
		name = "ClimbersGuild",
		w = 64,
		d = 40,
		storeys = 2,
		style = "Noble",
		wealth = 1,
		kind = "hall",
		seed = 9001,
		plinth = 4,
		scale = 2,
		roof = "hip",
		interiorAll = true,
		doorPanel = "archdoor",
		windowPanel = "archwin",
	}, 0, 0, 0, 0)
	Plan.child(node, info.node)
	-- bell-and-beacon tower rising from the back of the hall
	local top = tower(node, 0, 4, 22, 16, 7, 1.5, 3, true, rng)
	Plan.light(node, 0, top - 8, 22, "CurrentTeal", 60, 2.4, false)
	Plan.emitter(node, "WaystoneMotes", 0, top - 6, 22)
	for i = 0, 6 do
		Plan.piece(node, "runeband_l16", 0, 4 + i * 18 + 1.2, 22 - 12.6, 0, { tag = "RuneGlow" })
	end
	-- buttresses along both long sides
	for _, sx in { -1, 1 } do
		for k = -1, 1 do
			Plan.piece(node, "buttress_h24", sx * 32.6, 4, k * 12, if sx < 0 then math.pi / 2 else -math.pi / 2, { s = 2, material = "Limestone", color = "StoneLight" })
		end
	end
	-- classical portico: raised forecourt, six columns, entablature, pediment
	Plan.solid(node, 0, 2, -28.5, 56, 4, 17, 0, { kind = "Surface", material = "Marble", color = "Marble" })
	for _, cx in { -22, -14, -6, 6, 14, 22 } do
		Plan.piece(node, "column_h24", cx, 4, -33, 0, { s = 1.15, material = "Marble", color = "Marble" })
	end
	Plan.solid(node, 0, 4 + 27.6 + 1.6, -28.5, 58, 3.2, 17, 0, { kind = "Surface", material = "Limestone", color = "StoneLight" })
	Plan.piece(node, "runeband_l16", 0, 4 + 27.6 + 0.8, -37.1, 0, { s = 3.6, tag = "RuneGlow" })
	Plan.piece(node, "gable_r12", 0, 4 + 27.6 + 3.2, -34, 0, { s = 2.4, material = "Limestone", color = "StoneLight" })
	Plan.piece(node, "window_rose", 0, 4 + 27.6 + 3.2 + 9, -35.2, 0, { s = 0.7 })
	Plan.piece(node, "pane_rose", 0, 4 + 27.6 + 3.2 + 9, -35.1, 0, { s = 0.7, tag = "WindowGlow" })
	Plan.piece(node, "sign_board", 0, 4 + 27.6 - 0.6, -37.3, 0, { sx = 6, s = 1.2, text = "Sign.GuildName", material = "Metal", color = "Bronze" })
	for k = -2, 2 do
		Plan.piece(node, "steps_stone_w24", k * 12, 0, -41, 0, { sx = 0.5, s = 1, material = "Granite" })
	end
	for _, sx in { -1, 1 } do
		Plan.piece(node, "banner_tall", sx * 18, 46, -21.4, 0, { s = 2, color = "ClothTeal" })
		Plan.assembly(node, ORIGIN, "statue", sx * 34, 0, -42, 0, { s = 0.9 })
		Plan.assembly(node, ORIGIN, "stair_post", sx * 30.5, 0, -46, 0)
		Plan.piece(node, "pillar_square_h12", sx * 25, 4, -36, 0, { s = 0.45, material = "Basalt", color = "TowerStone" })
		Plan.piece(node, "cookfire", sx * 25, 9.4, -36, 0, { s = 0.9 })
		Plan.light(node, sx * 25, 12, -36, "Ember", 24, 1.6, false)
		Plan.emitter(node, "CampfireFlame", sx * 25, 9.8, -36)
	end
	-- gameplay anchors inside the hall
	Plan.marker(node, "QuestBoard", "guild_quest_board", -20, 4, 10, 0, { Floor = 1 })
	Plan.marker(node, "PartyFinderBoard", "guild_party_board", 20, 4, 10, 0, { Floor = 1 })
	Plan.marker(node, "NpcSpawn", "guildmaster", 0, 4, 12, math.pi, { Role = "GuildMaster" })
	Plan.marker(node, "CraftingStation", "guild_loom", -26, 4, -10, math.pi / 2, { Station = "CurrentLoom" })
	return node
end

-- ======================================================= Tidewatch Cathedral

local function cathedral(def: LandmarkDef, rng: Rng): PlanNode
	local node = landmarkNode(def, "Atomic")
	local w, d, S = 48, 96, 2
	local info = BuildingPlanner.plan({
		name = "TidewatchCathedral",
		w = w,
		d = d,
		storeys = 2,
		style = "Noble",
		wealth = 1,
		kind = "hall",
		seed = 9002,
		plinth = 4,
		scale = S,
		ridgeAxis = "z",
		roof = "gable",
		noInterior = true,
		doorPanel = "archdoor",
		windowPanel = "archwin",
	}, 0, 0, 0, 0)
	Plan.child(node, info.node)
	local top = 4 + 2 * 24
	-- rose window on the front gable
	Plan.piece(node, "window_rose", 0, top + 9, -d / 2 - 1.1, 0, { s = 1.2 })
	Plan.piece(node, "pane_rose", 0, top + 9, -d / 2 - 1.0, 0, { s = 1.2, tag = "WindowGlow" })
	Plan.light(node, 0, top + 9, -d / 2 + 6, "CurrentTeal", 40, 1.6, true)
	-- buttresses along the nave
	for _, sx in { -1, 1 } do
		for k = -2, 2 do
			Plan.piece(node, "buttress_h24", sx * (w / 2 + 0.6), 4, k * 18, if sx < 0 then math.pi / 2 else -math.pi / 2, { s = 2, material = "Limestone", color = "StoneLight" })
		end
	end
	-- bell tower at the front left corner
	local tx, tz = -w / 2 - 8, -d / 2 + 10
	local ttop = tower(node, tx, 4, tz, 12, 6, 2, 4, false, rng)
	Plan.piece(node, "bell", tx, ttop - 20, tz, 0, { s = 1.2 })
	Plan.piece(node, "roof_cone_d12", tx, ttop, tz, 0, { s = 2, color = "Verdigris" })
	Plan.light(node, tx, ttop - 14, tz, "LanternGlow", 34, 1.4, true)
	-- nave interior: two colonnades, pews, an altar with the Climber statue
	for _, sx in { -1, 1 } do
		for k = -3, 3 do
			Plan.piece(node, "column_h24", sx * 12, 4, k * 12, 0, { s = 1.95 })
		end
	end
	for row = 0, 8 do
		for _, sx in { -1, 1 } do
			Plan.piece(node, "bench", sx * 5.5, 4, -30 + row * 6, math.pi, {})
			Plan.piece(node, "bench", sx * 18, 4, -30 + row * 6, math.pi, {})
		end
	end
	Plan.solid(node, 0, 5, 36, 30, 2, 14, 0, { kind = "Surface", material = "Marble", color = "Marble" })
	Plan.assembly(node, ORIGIN, "statue", 0, 6, 40, math.pi, { s = 1.4 })
	Plan.piece(node, "rug", 0, 4.05, 0, math.pi / 2, { s = 2.2, color = "ClothNavy" })
	for k = -3, 3 do
		Plan.assembly(node, ORIGIN, "hanging_lantern", 0, top - 2, k * 12, 0, { noLights = k % 2 ~= 0 })
	end
	Plan.marker(node, "NpcSpawn", "tide_priest", 0, 6, 32, math.pi, { Role = "Priest" })
	Plan.marker(node, "RespecShrine", "cathedral_shrine", 0, 6, 30, math.pi, {})
	return node
end

-- ================================================================ lighthouse

local function lighthouse(def: LandmarkDef, rng: Rng): PlanNode
	local node = landmarkNode(def, "Atomic")
	local s = 1.25
	-- foundation drum down to the seabed so the tower stands on the mole's end
	Plan.solid(node, 0, -20, 0, 42, 26, 26, 0, { kind = "Surface", shape = "Cylinder", material = "Cobblestone", color = "StoneWet", rz = math.pi / 2 })
	Plan.solid(node, 0, 0.5, 0, 1, 27, 27, 0, { kind = "Surface", shape = "Cylinder", material = "Slate", color = "StoneLight", rz = math.pi / 2 })
	local base = 1
	local rings = 6
	local h = 12 * s
	for i = 0, rings - 1 do
		Plan.piece(node, if i == 0 or i == rings - 1 then "tower_ring_win_d12" else "tower_ring_d12", 0, base + i * h, 0, 0, { s = s, material = "Limestone", color = "StoneLight" })
		Plan.piece(node, "stairs_spiral_h12", 0, base + i * h, 0, i * 0.6, { s = s })
	end
	-- entrance steps up to a ground-floor window arch (sill at 5)
	Plan.piece(node, "steps_stone_w8", 0, base - 0.4, -12, 0, { s = 1.3 })
	local top = base + rings * h
	Plan.piece(node, "roof_cone_d12", 0, top, 0, 0, { s = s, color = "ClothRed", material = "Metal" })
	-- lantern room: platform, beacon and the hidden chest
	Plan.solid(node, 2.2, top - h + 0.5, 0, 4.2, 1, 8.5, 0, { kind = "Surface", material = "WoodPlanks", color = "Wood" })
	Plan.piece(node, "lantern_glass", 0, top - 9, 0, 0, { s = 3 })
	Plan.light(node, 0, top - 7, 0, "LanternGlow", 60, 3, true)
	Plan.emitter(node, "BeaconGlow", 0, top - 7, 0)
	Plan.assembly(node, ORIGIN, "treasure_chest", 2.6, top - h + 1, 0, -math.pi / 2)
	return node
end

-- ======================================================== harbour pieces

local function piers(def: LandmarkDef, width: number, length: number, rng: Rng, fishing: boolean): PlanNode
	local node = landmarkNode(def, "Atomic")
	local cols = width / 8
	local rows = math.floor(length / 8)
	for r = 0, rows - 1 do
		local z = 4 + r * 8
		for c = 0, cols - 1 do
			local x = -width / 2 + 4 + c * 8
			if not (fishing and r > 2 and rng:chance(0.04)) then
				Plan.piece(node, "pier_deck_8", x, 0, z, 0, { material = "WoodPlanks" })
			end
		end
		for _, sx in { -1, 1 } do
			Plan.piece(node, "pier_piling", sx * (width / 2 - 0.6), 0, z - 3.4, 0, {})
		end
		if r % 4 == 2 then
			local sx = if (r // 4) % 2 == 0 then -1 else 1
			Plan.assembly(node, ORIGIN, "street_lantern", sx * (width / 2 - 1.2), 0, z, if sx < 0 then -math.pi / 2 else math.pi / 2)
		end
		if r % 3 == 1 then
			Plan.piece(node, "bollard", (if r % 2 == 0 then -1 else 1) * (width / 2 - 1.4), 0, z + 2, 0, {})
		end
	end
	-- dockside clutter and moored rowboats
	for _ = 1, math.floor(rows / 2) do
		local z = rng:range(8, length - 8)
		local sx = if rng:chance(0.5) then -1 else 1
		local item = rng:pick(if fishing then { "fishing_net", "rope_coil", "fish_rack", "barrel", "crate_s" } else { "crate_l", "barrel", "rope_coil", "crate_s" })
		Plan.piece(node, item, sx * rng:range(1, width / 2 - 2.5), 0, z, rng:range(0, math.pi * 2), {})
	end
	for _ = 1, if fishing then 4 else 2 do
		local z = rng:range(16, length - 8)
		local sx = if rng:chance(0.5) then -1 else 1
		Plan.piece(node, "boat_row", sx * (width / 2 + 3), -6.6, z, rng:range(-0.15, 0.15), {})
	end
	Plan.marker(node, "FishSchool", def.id .. "_fish", 0, -4, length * 0.6, 0, { Radius = 40 })
	return node
end

local function ship(def: LandmarkDef, rng: Rng): PlanNode
	local node = landmarkNode(def, "Atomic")
	Plan.assembly(node, ORIGIN, "ship", 0, 0, 0, 0)
	-- gangplank from the pier (x = 8) to the deck
	Plan.solid(node, -16.5, 11.1, 0, 20, 0.6, 4, 0, { kind = "Surface", material = "WoodPlanks", color = "WoodLight", rz = -0.094 })
	Plan.marker(node, "TutorialShip", "moored_trader", 0, 10.2, 0, 0, {})
	Plan.marker(node, "BirdPerch", "ship_mast_a", 0, 61, -14, 0, {})
	Plan.marker(node, "BirdPerch", "ship_mast_b", 0, 61, 4, 0, {})
	return node
end

-- ======================================================= cistern pumphouse

local function pumphouse(def: LandmarkDef, rng: Rng): PlanNode
	local node = landmarkNode(def, "Persistent")
	local info = BuildingPlanner.plan({
		name = "CisternPumphouse",
		w = 20,
		d = 20,
		storeys = 1,
		style = "Market",
		wealth = 0.3,
		kind = "warehouse",
		seed = 9003,
		plinth = 2,
		roof = "hip",
		noInterior = true,
		doorPanel = "archdoor",
	}, 0, 0, 0, 0)
	Plan.child(node, info.node)
	-- the way down: a ring of railings around a glowing Current shaft
	Plan.solid(node, 0, 2.2, 2, 0.6, 9, 9, 0, { kind = "Current", shape = "Cylinder", material = "Glass", color = "CurrentTeal", transparency = 0.2, tag = "DungeonPortal", rz = math.pi / 2 })
	Plan.emitter(node, "SpringBubbles", 0, 2.6, 2, 8, 1, 8, 0)
	Plan.light(node, 0, 4, 2, "CurrentTeal", 24, 1.8, false)
	for k = 0, 3 do
		local a = k * math.pi / 2
		Plan.piece(node, "railing_l4", math.sin(a) * 5.4, 2, 2 + math.cos(a) * 5.4, a + math.pi / 2, { material = "Metal", color = "Iron" })
	end
	Plan.assembly(node, ORIGIN, "valve", -8, 2, 6, math.pi / 2)
	Plan.piece(node, "hanging_chain", 6, 13, 6, 0, {})
	Plan.marker(node, "DungeonEntrance", "SunkenCistern", 0, 2, 2, 0, { Dungeon = "SunkenCistern", Radius = 18 })
	return node
end

-- ================================================================== ruins

local function ruinedTower(def: LandmarkDef, rng: Rng): PlanNode
	local node = landmarkNode(def, "Atomic")
	local s = 1.4
	tower(node, 0, -2, 0, 16, 2, s, 1, false, rng)
	Plan.piece(node, "tower_ring_win_d16", 0, -2 + 2 * 12 * s, 0, 0.3, { s = s, rx = 0.12, rz = -0.05, noCollide = true })
	for _ = 1, 6 do
		local a = rng:range(0, math.pi * 2)
		local r = rng:range(14, 22)
		Plan.piece(node, rng:pick({ "rubble_pile", "rock_2", "rock_3" }), math.cos(a) * r, -0.5, math.sin(a) * r, rng:range(0, 6), { s = rng:range(0.8, 1.6) })
	end
	for _ = 1, 3 do
		local a = rng:range(0, math.pi * 2)
		Plan.piece(node, "wall_damaged_w12", math.cos(a) * 26, -1, math.sin(a) * 26, a, { material = "Slate", color = "StoneShadow" })
	end
	Plan.light(node, 0, 6, 0, "CurrentTeal", 18, 0.8, true)
	return node
end

local function ruinField(def: LandmarkDef, rng: Rng, field: Field): PlanNode
	local node = landmarkNode(def, "Atomic")
	for i = 1, 3 do
		local a = rng:range(0, math.pi * 2)
		local r = rng:range(6, 26)
		local bx, bz = math.cos(a) * r, math.sin(a) * r
		local wx, wz = Geom.rotate(bx, bz, def.ry)
		local gy = field:height(def.x + wx, def.z + wz) - def.y
		local info = BuildingPlanner.plan({
			name = def.id .. "_ruin" .. i,
			w = rng:pick({ 16, 20, 24 }),
			d = rng:pick({ 12, 16 }),
			storeys = rng:int(1, 2),
			style = "Ruin",
			wealth = 0,
			kind = "ruin",
			seed = 7000 + i + #def.id,
			plinth = 2,
			roof = "none",
			damaged = 0.55,
			noInterior = false,
		}, bx, gy - 1.5, bz, rng:range(-0.4, 0.4))
		Plan.child(node, info.node)
	end
	Plan.piece(node, "arch_l16", rng:range(-10, 10), -2, rng:range(20, 30), rng:range(-0.3, 0.3), { rz = 0.06 })
	for _ = 1, 4 do
		Plan.piece(node, "column_h24", rng:range(-30, 30), -1, rng:range(-30, 30), rng:range(0, 6), {
			rx = if rng:chance(0.5) then rng:range(1.2, 1.5) else 0,
			noCollide = false,
		})
	end
	Plan.piece(node, "statue_climber", rng:range(-20, 20), 0, rng:range(-20, 20), 0, { rx = 1.45, s = 1.3 })
	for _ = 1, 8 do
		Plan.piece(node, rng:pick({ "rubble_pile", "moss_patch", "rock_2" }), rng:range(-36, 36), -0.2, rng:range(-36, 36), rng:range(0, 6), {})
	end
	return node
end

local function strand(def: LandmarkDef, rng: Rng, field: Field): PlanNode
	local node = landmarkNode(def, "Atomic")
	-- broken pier running into the shallows
	for r = 0, 12 do
		if rng:chance(0.78) then
			Plan.piece(node, "pier_deck_8", 0, 3.2 - r * 0.05, 10 + r * 8, rng:range(-0.05, 0.05), { rz = rng:range(-0.06, 0.06) })
		end
		for _, sx in { -1, 1 } do
			if rng:chance(0.8) then
				Plan.piece(node, "pier_piling", sx * 3.4, 3.2, 10 + r * 8, 0, {})
			end
		end
	end
	-- the beached wreck
	Plan.piece(node, "ship_hull", 46, -5, 70, 0.9, { rz = 0.32, rx = -0.05 })
	Plan.piece(node, "ship_mast", 52, 3, 64, 0.9, { rz = 1.1 })
	-- drowned warehouse
	local info = BuildingPlanner.plan({
		name = "StrandWarehouse",
		w = 28,
		d = 20,
		storeys = 2,
		style = "Ruin",
		wealth = 0,
		kind = "warehouse",
		seed = 9004,
		plinth = 2,
		roof = "none",
		damaged = 0.5,
	}, -40, field:height(def.x - 40, def.z - 30) - def.y - 0.5, -30, 0.2)
	Plan.child(node, info.node)
	for _ = 1, 10 do
		local x, z = rng:range(-60, 60), rng:range(-40, 60)
		local gy = field:height(def.x + x, def.z + z) - def.y
		Plan.piece(node, rng:pick({ "barrel", "crate_s", "fishing_net", "rope_coil", "boat_row", "log_fallen" }), x, gy - 0.3, z, rng:range(0, 6), { rz = rng:range(-0.3, 0.3) })
	end
	return node
end

local function camp(def: LandmarkDef, rng: Rng, field: Field): PlanNode
	local node = landmarkNode(def, "Atomic")
	Plan.assembly(node, ORIGIN, "camp", 0, 0, 0, 0)
	for i = 1, 2 do
		local a = i * 2.2
		local x, z = math.cos(a) * 14, math.sin(a) * 14
		Plan.piece(node, "tent", x, field:height(def.x + x, def.z + z) - def.y, z, a + math.pi, { color = rng:pick({ "Sail", "ClothOchre" }) })
	end
	Plan.piece(node, "fish_rack", -10, 0, -14, 0.4, {})
	Plan.assembly(node, ORIGIN, "weapon_rack_full", 9, 0, -16, -0.6)
	Plan.marker(node, "NpcSpawn", "hunter_vessa", 4, 0, -12, 0, { Role = "Hunter" })
	return node
end

-- ============================================================ Guardian Gate

local function guardianGate(def: LandmarkDef, rng: Rng): PlanNode
	local node = landmarkNode(def, "Persistent")
	node.attributes.Floor = 1
	-- dais and front steps
	Plan.solid(node, 0, -2, 4, 120, 8, 52, 0, { kind = "Surface", material = "Slate", color = "StoneDark" })
	for k = -1, 1 do
		Plan.piece(node, "steps_stone_w24", k * 24, -2.2, -26, 0, { s = 0.55, material = "Granite" })
	end
	local floorY = 2
	-- pylons, arch and colonnade
	for _, sx in { -1, 1 } do
		Plan.piece(node, "pillar_square_h12", sx * 31, floorY, 0, 0, { s = 5, material = "Basalt", color = "TowerStone" })
		Plan.piece(node, "column_h24", sx * 52, floorY, 6, 0, { s = 3, material = "Basalt", color = "TowerStone" })
		Plan.piece(node, "column_h24", sx * 70, floorY, 10, 0, { s = 2.5, material = "Basalt", color = "TowerStone" })
		Plan.assembly(node, ORIGIN, "statue", sx * 44, floorY, -18, 0, { s = 3.2 })
		-- braziers
		Plan.piece(node, "pillar_square_h12", sx * 24, floorY, -30, 0, { s = 0.5, material = "Basalt", color = "TowerStone" })
		Plan.piece(node, "cookfire", sx * 24, floorY + 6, -30, 0, { s = 1.4 })
		Plan.light(node, sx * 24, floorY + 9, -30, "Ember", 30, 2, false)
		Plan.emitter(node, "CampfireFlame", sx * 24, floorY + 6.5, -30)
		Plan.piece(node, "banner_tall", sx * 31, floorY + 58, -7.4, 0, { s = 3, color = "ClothNavy" })
	end
	Plan.piece(node, "arch_l16", 0, floorY, 3, 0, { s = 3, material = "Basalt", color = "TowerStone" })
	-- the sealed doors
	Plan.piece(node, "gate_leaf", -20, floorY, 3, 0, {})
	Plan.piece(node, "gate_leaf", 0, floorY, 3, 0, {})
	Plan.piece(node, "gate_rune", 0, floorY + 34, 0.6, 0, { tag = "GateSeal" })
	Plan.solid(node, 0, floorY + 30, -0.8, 40, 60, 1.5, 0, {
		kind = "Barrier",
		material = "ForceField",
		color = "CurrentTeal",
		transparency = 0.15,
		tag = "GuardianSeal",
		name = "GuardianSeal",
	})
	Plan.light(node, 0, floorY + 34, -6, "CurrentTeal", 60, 2.6, false)
	Plan.emitter(node, "GateMotes", 0, floorY + 30, -2, 40, 60, 2, 0)
	Plan.marker(node, "GuardianGate", "floor1_gate", 0, floorY, -10, 0, { Floor = 1, Guardian = "Brinewarden", Sealed = true })
	Plan.marker(node, "GuardianArenaEntry", "brinewarden_arena", 0, floorY, -14, 0, { Guardian = "Brinewarden" })
	return node
end

-- ================================================================== skybox

local function skybox(def: LandmarkDef, rng: Rng): PlanNode
	local node = Plan.node("Skybox", 0, 0, 0, 0, "Persistent")
	table.insert(node.tags, "Skybox")
	node.attributes.Skybox = true
	local R = 2300
	local count = 36
	for i = 0, count - 1 do
		local a = (i + 0.5) / count * math.pi * 2
		local x, z = math.cos(a) * R, math.sin(a) * R
		local ry = Geom.yawFacing(-math.cos(a), -math.sin(a))
		for row = 0, 1 do
			Plan.piece(node, "tower_wall_segment", x, -700 + row * 900, z, ry, { sx = 1.02, noCollide = true, tag = "Skybox" })
		end
	end
	for i = 1, 12 do
		local a = rng:range(0, math.pi * 2)
		local r = R - 60
		Plan.piece(node, "current_falls", math.cos(a) * r, -620, math.sin(a) * r, Geom.yawFacing(-math.cos(a), -math.sin(a)), {
			s = rng:range(1.2, 1.6),
			noCollide = true,
			tag = "Skybox",
		})
	end
	-- the sea spilling over the open southern rim
	for i = -2, 2 do
		Plan.piece(node, "current_falls", i * 180 + rng:range(-40, 40), -590, 1505, 0, { s = 1.1, noCollide = true, tag = "Skybox", color = "Water", material = "Glass" })
	end
	Plan.piece(node, "floor_underside", 0, 1650, 0, 0, { s = 1.1, noCollide = true, tag = "Skybox" })
	-- the drowned world far below
	for i = -1, 1 do
		for j = -1, 1 do
			Plan.solid(node, i * 2048, -1600, j * 2048, 2048, 4, 2048, 0, {
				kind = "Surface",
				material = "Glass",
				color = "CurrentDeep",
				transparency = 0.05,
				tag = "Skybox",
				name = "DrownedSea",
			})
		end
	end
	for k = 1, 5 do
		local a = rng:range(0, math.pi * 2)
		local r = rng:range(700, 1800)
		Plan.piece(node, "tower_ring_win_d16", math.cos(a) * r, -1700, math.sin(a) * r, rng:range(0, 6), {
			s = rng:range(8, 12),
			rz = rng:range(-0.2, 0.2),
			noCollide = true,
			tag = "Skybox",
		})
	end
	return node
end

-- ===================================================================== API

function LandmarkPlanner.plan(def: LandmarkDef, field: Field): PlanNode
	local rng = Rng.new("landmark_" .. def.id)
	if def.kind == "GuildHall" then
		return guildHall(def, rng)
	elseif def.kind == "Cathedral" then
		return cathedral(def, rng)
	elseif def.kind == "Lighthouse" then
		return lighthouse(def, rng)
	elseif def.kind == "Ship" then
		return ship(def, rng)
	elseif def.kind == "Pier" then
		return piers(def, 16, 170, rng, false)
	elseif def.kind == "FishPier" then
		return piers(def, 8, 120, rng, true)
	elseif def.kind == "Pumphouse" then
		return pumphouse(def, rng)
	elseif def.kind == "RuinedTower" then
		return ruinedTower(def, rng)
	elseif def.kind == "Ruins" then
		return ruinField(def, rng, field)
	elseif def.kind == "Strand" then
		return strand(def, rng, field)
	elseif def.kind == "Camp" then
		return camp(def, rng, field)
	elseif def.kind == "GuardianGate" then
		return guardianGate(def, rng)
	elseif def.kind == "Skybox" then
		return skybox(def, rng)
	end
	error("unknown landmark kind " .. def.kind)
end

return LandmarkPlanner
