--!strict
--[[
	Layouts/Floor1 (edit-time data + geometry for Floor 1, Lowharbor)

	The floor is a 3000 x 3000 platform inside the Spire (x, z in -1500..1500; north = -z).

	Lowharbor is a crescent port built like an amphitheatre around a harbour bay of Current-lit
	water. Its terraces are rings around the bay centre BAY (polar radius r, angle a: 0 = east,
	positive = south), stepping up away from the water:
	  Docks            r 300..450   y 6    quays, piers, warehouses, taverns, the moored brig
	  Market           r 450..620   y 30   the market plaza, bell tower, shops and stations
	  Lower Terraces   r 620..780   y 54   houses
	  Upper Terraces   r 780..930   y 78   houses, library
	  Guild Terrace    r 930..1100  y 102  the Climbers' Guild, the Cathedral of the Ascent,
	                                       the Hall of Positions, the Attunement Shrine
	The town spans angles -0.66..0.66 rad. "The Climb", the grand avenue, runs straight up the middle
	(a = 0) with stairways at every terrace wall; two side stairways run at a = +-0.40, and two
	Current canals pour down the terraces at a = -0.20 and a = 0.22 (waterfalls at each wall).

	Around it:
	  * The bay opens west to the edge of the floor between two breakwaters (lighthouse on the
	    north arm, harbour tower on the south).
	  * North: the Old Wharf (a derelict shelf along the shore, Drowned Sailors at night), then cliffs
	    up to the Rustwood highlands (y ~120-170): Rustwood Forest.
	  * South: Tidepool Marsh, lowland at y ~3 with tide pools and channels.
	  * East: the Sunken Cistern's ruined basin (the dungeon entrance) and the First Gate on its
	    plateau (y 148), the Guardian gate seen from everywhere on the floor.
]]

local Layout = {}

Layout.FloorId = "1"
Layout.Bounds = 1500 -- half size of the platform
Layout.Sea = 0 -- harbour and pool water level
Layout.Bay = Vector2.new(-1050, 30)
Layout.TownAngle = 0.66
Layout.TownOuter = 1100
Layout.QuayRadius = 300

export type Band = { Name: string, R0: number, R1: number, Y: number, Street: number, District: string }

Layout.Bands = {
	{ Name = "Docks", R0 = 300, R1 = 450, Y = 6, Street = 326, District = "Docks" },
	{ Name = "Market", R0 = 450, R1 = 620, Y = 30, Street = 540, District = "Market" },
	{ Name = "LowerTerraces", R0 = 620, R1 = 780, Y = 54, Street = 700, District = "Residential" },
	{ Name = "UpperTerraces", R0 = 780, R1 = 930, Y = 78, Street = 855, District = "Residential" },
	{ Name = "GuildTerrace", R0 = 930, R1 = 1100, Y = 102, Street = 1000, District = "Guild" },
} :: { Band }

Layout.StreetWidth = 20
Layout.Climb = { Angle = 0.0, Width = 24 } -- the grand avenue
Layout.Spokes = { -0.40, 0.40 } -- side stairways
Layout.SpokeWidth = 16
Layout.RampRun = 40 -- every avenue climbs each terrace wall by stairs over this run (on the upper terrace)
Layout.Canals = { -0.20, 0.22 } -- radial Current canals
Layout.CanalWidth = 14
Layout.CanalDepth = 6 -- water surface this far below the terrace (matches CanalWall_16)
Layout.CanalEnd = 1080 -- canals rise from a spring wall here on the Guild Terrace
-- The Market plaza (Size = diameter of the open square), on the Climb. Keep = the radius the lot
-- planner leaves clear for the plaza and its ring of workshops.
Layout.Plaza = { Radius = 545, Angle = 0.0, Size = 130, Keep = 104 }

-- One workshop building per station kind around the plaza. Angle is in degrees in plaza space,
-- measured from the bay side (+Z, down the Climb) toward +X (increasing town angle); the front
-- faces the fountain at distance Front. Slots avoid the Climb (0/180) and the ring street (90).
-- The building's station is seated in front of it (LandmarkBuilder.SeatFixtures). Name is the
-- signboard over the door.
export type Workshop = {
	Kind: string,
	Name: string,
	Angle: number,
	Width: number,
	Depth: number,
	Storeys: number,
	Style: "Stone" | "Timber" | "Mixed",
	Building: string, -- BuildingGenerator Kind (interior furniture)
	Plaster: string?,
	Cloth: string, -- awning and banner colour
}
Layout.WorkshopFront = 76
Layout.Workshops = {
	{ Kind = "Forge", Name = "The Ember Anvil", Angle = 66, Width = 20, Depth = 20, Storeys = 2, Style = "Stone",
		Building = "Smithy", Cloth = "#6A2418" },
	{ Kind = "Armorer", Name = "Brinewall Armoury", Angle = 40, Width = 20, Depth = 16, Storeys = 2, Style = "Stone",
		Building = "Smithy", Cloth = "#3A4250" },
	{ Kind = "Loom", Name = "The Tidewoven Loom", Angle = 112, Width = 20, Depth = 16, Storeys = 2, Style = "Timber",
		Building = "Shop", Plaster = "#7E7464", Cloth = "#5A2E4E" },
	{ Kind = "Alchemy", Name = "Murkglass Apothecary", Angle = 132, Width = 16, Depth = 16, Storeys = 3, Style = "Mixed",
		Building = "Shop", Plaster = "#6E7868", Cloth = "#2E5A3A" },
	{ Kind = "Shop", Name = "Lowharbor Provisions", Angle = -66, Width = 20, Depth = 16, Storeys = 2, Style = "Mixed",
		Building = "Shop", Plaster = "#857660", Cloth = "#7A4A1E" },
	{ Kind = "Bank", Name = "The Drowned Vault", Angle = -40, Width = 24, Depth = 20, Storeys = 2, Style = "Stone",
		Building = "Hall", Cloth = "#1E3A4A" },
	{ Kind = "TokenShop", Name = "The Floorwarden's Exchange", Angle = -112, Width = 20, Depth = 16, Storeys = 2,
		Style = "Stone", Building = "Hall", Cloth = "#1F5B5E" },
	{ Kind = "Altar", Name = "The Votive Hollow", Angle = -132, Width = 20, Depth = 16, Storeys = 2, Style = "Stone",
		Building = "Library", Cloth = "#2A2440" },
} :: { Workshop }

-- Wild areas and landmarks (world x, z).
Layout.Points = {
	Lighthouse = Vector2.new(-1250, -80),
	HarbourTower = Vector2.new(-1250, 140),
	Brig = Vector2.new(-845, 120),
	OldWharf = Vector2.new(-808, -288),
	Cistern = Vector2.new(520, 240),
	FirstGate = Vector2.new(1250, 0),
	MarshHeart = Vector2.new(-250, 1000),
	ForestHeart = Vector2.new(150, -900),
	BrinehulkDeep = Vector2.new(200, 1200),
}
-- Two rock arms close most of the harbour mouth (the gap between their tips is 220 wide).
Layout.Breakwaters = {
	{ Vector2.new(-1250, -300), Vector2.new(-1250, -80) },
	{ Vector2.new(-1250, 360), Vector2.new(-1250, 140) },
}
-- Leviathan skeletons half-sunk in the wilds: set dressing that sells the drowned-world story and
-- gives players landmarks to navigate by. Yaw in radians, Sink = studs pushed into the ground.
Layout.Relics = {
	{ Piece = "Leviathan_Ribs", At = Vector2.new(-120, 940), Yaw = 0.6, Scale = 2.4, Sink = 6 }, -- marsh heart
	{ Piece = "Leviathan_Ribs", At = Vector2.new(-560, 980), Yaw = 2.2, Scale = 1.6, Sink = 4 },
	{ Piece = "Leviathan_Ribs", At = Vector2.new(-735, -330), Yaw = -0.9, Scale = 1.8, Sink = 3 }, -- beside the Old Wharf
	{ Piece = "Leviathan_Ribs", At = Vector2.new(330, -760), Yaw = 1.4, Scale = 1.3, Sink = 5 }, -- deep in the Rustwood
}
Layout.CisternBasin = { Radius = 70, Rim = 120, Y = 86 }
Layout.GatePlateau = { Radius = 190, Rim = 270, Y = 148 }

-- Town landmarks, as polar spots (r, a) with a keep-clear radius for the lot planner.
-- Facing: "In" = the front looks toward the bay, "Out" = away from it.
export type Landmark = { R: number, A: number, Clear: number, Facing: "In" | "Out" }
Layout.Landmarks = {
	ClimbersGuild = { R = 1058, A = 0.0, Clear = 58, Facing = "In" }, -- at the head of the Climb
	Cathedral = { R = 1052, A = -0.52, Clear = 64, Facing = "In" },
	HallOfPositions = { R = 962, A = 0.09, Clear = 34, Facing = "Out" },
	-- the Rotunda of Attunement: a domed drum on the Guild Terrace, front to the bay
	AttunementShrine = { R = 1046, A = -0.30, Clear = 62, Facing = "In" }, -- room for a forecourt
	-- on the bay side of the plaza, between the Climb and the Drowned Vault
	Belltower = { R = 476, A = -0.053, Clear = 12, Facing = "In" },
	Barracks = { R = 1050, A = 0.45, Clear = 44, Facing = "In" }, -- the Watch, by the east gate
	LibraryOfFloors = { R = 870, A = 0.30, Clear = 30, Facing = "In" },
	TrainingYard = { R = 1052, A = 0.3, Clear = 38, Facing = "In" },
	EastGate = { R = 1070, A = 0.15, Clear = 24, Facing = "In" }, -- the arch where the East Road leaves town
} :: { [string]: Landmark }

-- What each district builds. Kinds are weighted; Width/Depth are lot ranges (multiples of 4).
export type DistrictSpec = {
	Kinds: { [string]: number },
	Storeys: { number },
	Wealth: { number },
	Styles: { [string]: number },
	Width: { number },
	Depth: { number },
	Gap: { number }, -- space between neighbours (alleys, gardens)
	Sides: { string }, -- which side of the ring street gets lots: "Inner" (bay side), "Outer"
}
Layout.Districts = {
	Docks = {
		Kinds = { Warehouse = 4, Tavern = 2, Shop = 2, House = 2, Smithy = 1 },
		Storeys = { 1, 3 },
		Wealth = { 0.05, 0.4 },
		Styles = { Timber = 5, Mixed = 4, Stone = 1 },
		Width = { 16, 32 },
		Depth = { 20, 44 },
		Gap = { 4, 8 },
		Sides = { "Outer" },
	},
	Market = {
		Kinds = { Shop = 6, Tavern = 1, Smithy = 1, House = 2 },
		Storeys = { 2, 3 },
		Wealth = { 0.3, 0.7 },
		Styles = { Mixed = 5, Stone = 3, Timber = 2 },
		Width = { 16, 28 },
		Depth = { 16, 28 },
		Gap = { 6, 14 },
		Sides = { "Inner", "Outer" },
	},
	Residential = {
		Kinds = { House = 8, Shop = 1, Tavern = 1 },
		Storeys = { 2, 3 },
		Wealth = { 0.3, 0.75 },
		Styles = { Mixed = 4, Timber = 3, Stone = 3 },
		Width = { 16, 24 },
		Depth = { 16, 24 },
		Gap = { 16, 32 },
		Sides = { "Inner", "Outer" },
	},
	Guild = {
		Kinds = { Hall = 2, Library = 2, House = 3, Barracks = 1 },
		Storeys = { 2, 4 },
		Wealth = { 0.7, 1.0 },
		Styles = { Stone = 7, Mixed = 3 },
		Width = { 20, 32 },
		Depth = { 20, 28 },
		Gap = { 16, 26 },
		Sides = { "Inner", "Outer" },
	},
} :: { [string]: DistrictSpec }

-- GAMEPLAY PLACEMENTS ---------------------------------------------------------------------
-- Positions are world (x, z); heights come from the terrain (Height) unless Y is given.

export type WaystoneSpot = { Id: string, At: Vector2, Default: boolean? }
Layout.Waystones = {
	{ Id = "F1_ClimbersRest", At = Vector2.new(-729, 8), Default = true }, -- the quay at the foot of the Climb
	{ Id = "F1_TidewatchSteps", At = Vector2.new(-548, 0) }, -- the Market plaza
	{ Id = "F1_ReedwardenPost", At = Vector2.new(-250, 1000) }, -- the heart of Tidepool Marsh
	{ Id = "F1_RustwoodCamp", At = Vector2.new(150, -900) }, -- a clearing in Rustwood
	{ Id = "F1_CisternMouth", At = Vector2.new(440, 150) }, -- above the Cistern basin
	{ Id = "F1_GateApproach", At = Vector2.new(1060, 44) }, -- where the colonnade to the First Gate begins
} :: { WaystoneSpot }

-- Enemy spawn points (MobService reads these attributes). Levels rise away from town:
-- crabs on the shores (1-3), sailors on the Old Wharf (3-5), wisps in the marsh (4-6),
-- acolytes at the ruins (5-7), stalkers in Rustwood (6-8), the Brinehulk in its lagoon (8),
-- leeches inside the Cistern (7-9).
export type SpawnSpot = {
	Mob: string,
	At: Vector2,
	Count: number,
	Patrol: number,
	Respawn: number,
	Zone: string,
	Elite: boolean?,
	NightOnly: boolean?,
}
Layout.Spawns = {
	{ Mob = "Bilgecrab", At = Vector2.new(-830, -275), Count = 3, Patrol = 28, Respawn = 20, Zone = "Lowharbor" },
	{ Mob = "Bilgecrab", At = Vector2.new(-700, 480), Count = 3, Patrol = 30, Respawn = 20, Zone = "TidepoolMarsh" },
	{ Mob = "Bilgecrab", At = Vector2.new(-520, 700), Count = 2, Patrol = 30, Respawn = 25, Zone = "TidepoolMarsh" },
	{ Mob = "DrownedSailor", At = Vector2.new(-790, -300), Count = 2, Patrol = 20, Respawn = 40, Zone = "Lowharbor" },
	{ Mob = "DrownedSailor", At = Vector2.new(-850, -255), Count = 3, Patrol = 26, Respawn = 40, Zone = "Lowharbor", NightOnly = true },
	{ Mob = "DrownedSailor", At = Vector2.new(-150, 820), Count = 3, Patrol = 24, Respawn = 45, Zone = "TidepoolMarsh" },
	{ Mob = "MarshWisp", At = Vector2.new(-300, 950), Count = 2, Patrol = 30, Respawn = 40, Zone = "TidepoolMarsh" },
	{ Mob = "MarshWisp", At = Vector2.new(0, 1100), Count = 3, Patrol = 34, Respawn = 40, Zone = "TidepoolMarsh" },
	{ Mob = "MarshWisp", At = Vector2.new(300, 900), Count = 2, Patrol = 30, Respawn = 40, Zone = "TidepoolMarsh" },
	{ Mob = "MarshWisp", At = Vector2.new(-450, 1250), Count = 2, Patrol = 30, Respawn = 45, Zone = "TidepoolMarsh", NightOnly = true },
	{ Mob = "LanternAcolyte", At = Vector2.new(-600, 1150), Count = 2, Patrol = 14, Respawn = 60, Zone = "TidepoolMarsh" },
	{ Mob = "DrownedSailor", At = Vector2.new(-610, 1170), Count = 2, Patrol = 18, Respawn = 45, Zone = "TidepoolMarsh" },
	{ Mob = "LanternAcolyte", At = Vector2.new(700, 200), Count = 1, Patrol = 10, Respawn = 60, Zone = "Lowharbor" },
	{ Mob = "DrownedSailor", At = Vector2.new(715, 215), Count = 2, Patrol = 20, Respawn = 45, Zone = "Lowharbor" },
	{ Mob = "LanternAcolyte", At = Vector2.new(520, 250), Count = 2, Patrol = 16, Respawn = 60, Zone = "Lowharbor" },
	{ Mob = "RustwoodStalker", At = Vector2.new(-100, -700), Count = 2, Patrol = 34, Respawn = 45, Zone = "RustwoodForest" },
	{ Mob = "RustwoodStalker", At = Vector2.new(170, -960), Count = 3, Patrol = 36, Respawn = 45, Zone = "RustwoodForest" },
	{ Mob = "RustwoodStalker", At = Vector2.new(400, -1100), Count = 3, Patrol = 36, Respawn = 45, Zone = "RustwoodForest" },
	{ Mob = "RustwoodStalker", At = Vector2.new(700, -800), Count = 2, Patrol = 34, Respawn = 45, Zone = "RustwoodForest" },
	{ Mob = "RustwoodStalker", At = Vector2.new(-300, -1150), Count = 2, Patrol = 34, Respawn = 50, Zone = "RustwoodForest" },
	{ Mob = "Brinehulk", At = Vector2.new(200, 1200), Count = 1, Patrol = 40, Respawn = 300, Zone = "TidepoolMarsh" },
} :: { SpawnSpot }

-- Current Pressure (1 low .. 5 high; 3 is neutral everywhere else). Box zones: centre x/z, size x/z.
export type PressureSpot = { Name: string, At: Vector2, Size: Vector2, Pressure: number }
Layout.PressureZones = {
	{ Name = "BayCurrents", At = Vector2.new(-1200, 30), Size = Vector2.new(600, 700), Pressure = 4 },
	{ Name = "MarshStill", At = Vector2.new(-100, 1050), Size = Vector2.new(1700, 800), Pressure = 2 },
	{ Name = "RustwoodDeep", At = Vector2.new(250, -1050), Size = Vector2.new(1400, 800), Pressure = 2 },
	{ Name = "CisternWell", At = Vector2.new(520, 240), Size = Vector2.new(240, 240), Pressure = 5 },
	{ Name = "GateHush", At = Vector2.new(1250, 0), Size = Vector2.new(420, 420), Pressure = 4 },
} :: { PressureSpot }

-- Hidden areas. Terrain: edits applied in order after the terrain is written:
--   { Op = "Ball", X, Y, Z, R, Material }            sphere
--   { Op = "Cylinder", X, Y, Z, R, H, Material }     upright cylinder centred at Y
--   { Op = "Block", X, Y, Z, SX, SY, SZ, Material }  box centred at X, Y, Z
-- ("Air" carves). Trigger: discovery volume (x, y, z, size). Cache: chest (x, y, z, yawDegrees).
export type TerrainOp = {
	Op: "Ball" | "Cylinder" | "Block",
	X: number,
	Y: number,
	Z: number,
	R: number?,
	H: number?,
	SX: number?,
	SY: number?,
	SZ: number?,
	Material: string,
}
export type SecretSpot = {
	Id: string,
	Terrain: { TerrainOp },
	Trigger: { number },
	Cache: { number },
	Items: string,
	Gold: number,
	Crystal: boolean?,
}
local function ball(x: number, y: number, z: number, r: number, m: string?): TerrainOp
	return { Op = "Ball", X = x, Y = y, Z = z, R = r, Material = m or "Air" }
end
local function block(x: number, y: number, z: number, sx: number, sy: number, sz: number, m: string): TerrainOp
	return { Op = "Block", X = x, Y = y, Z = z, SX = sx, SY = sy, SZ = sz, Material = m }
end
local function cylinder(x: number, y: number, z: number, r: number, h: number, m: string): TerrainOp
	return { Op = "Cylinder", X = x, Y = y, Z = z, R = r, H = h, Material = m }
end
Layout.Secrets = {
	{
		-- a sea cave in the cliffs at the bay's north shore, reached along the rocks from the Old Wharf
		Id = "F1_SmugglersCove",
		Terrain = {
			ball(-1094, 8, -262, 8), ball(-1102, 9, -276, 9), ball(-1110, 10, -291, 10), ball(-1118, 11, -306, 11),
			ball(-1126, 14, -323, 16), ball(-1136, 16, -340, 18),
			block(-1124, 3, -318, 34, 4, 50, "Sand"),
		},
		Trigger = { -1132, 12, -334, 30 },
		Cache = { -1140, 5, -346, 200 },
		Items = "IronScrap x12, BrinecutTwinfangs:Rare",
		Gold = 120,
	},
	{
		-- a root-hollow under the forest floor, entered down a slope beside a fallen arch of stone
		Id = "F1_ForestHollow",
		Terrain = {
			ball(620, 132, -1180, 9), ball(628, 126, -1196, 9), ball(636, 120, -1212, 10), ball(646, 116, -1232, 16),
			block(640, 106, -1222, 30, 4, 40, "Ground"),
		},
		Trigger = { 646, 116, -1232, 26 },
		Cache = { 652, 108, -1240, 20 },
		Items = "IronScrap x10, SpirewatchLance:Rare",
		Gold = 140,
		Crystal = true,
	},
	{
		-- an island shrine in a hidden pool at the marsh's south-west edge
		Id = "F1_ReedShrine",
		Terrain = {
			cylinder(-820, 2, 1250, 46, 16, "Air"),
			cylinder(-820, -5, 1250, 46, 6, "Mud"), -- the pool bed (top at -2)
			cylinder(-820, -1, 1250, 44, 2, "Water"),
			cylinder(-820, 0, 1250, 13, 8, "Ground"), -- the island (top at 4)
		},
		Trigger = { -820, 6, 1250, 24 },
		Cache = { -820, 4, 1253, 180 },
		Items = "IronScrap x8, GleamNeedle:Rare",
		Gold = 100,
	},
	{
		-- a grotto in the cliff at the north end of the Upper Terraces, behind the last houses
		Id = "F1_CliffShrine",
		Terrain = { ball(-404, 86, -520, 11), ball(-414, 88, -532, 12), block(-410, 78.5, -527, 22, 1, 24, "Slate") },
		Trigger = { -410, 86, -527, 20 },
		Cache = { -416, 79, -534, 135 },
		Items = "IronScrap x8, StonejawGreatblade:Rare",
		Gold = 100,
	},
} :: { SecretSpot }

-- Scatter (trees, rocks, plants) per region: pieces with weights, density per 10k sq studs,
-- minimum spacing, scale range, and the slope above which nothing grows.
export type ScatterRule = {
	Region: string,
	Pieces: { [string]: number },
	Density: number,
	Spacing: number,
	Scale: { number },
	MaxSlope: number,
	MinHeight: number?, -- skip below this (shore, pools)
}
Layout.Scatter = {
	-- Trees are 50-110 studs tall now, so spacing is wide and density low: a few giants with
	-- understory between them reads more ominous (and costs fewer parts) than a dense grove.
	{ Region = "RustwoodForest", Pieces = { Tree_Rustwood_L = 4, Tree_Rustwood_M = 5, Tree_Rustwood_S = 2, Tree_Spirepine_L = 2 },
		Density = 3.0, Spacing = 30, Scale = { 0.9, 1.25 }, MaxSlope = 32 },
	{ Region = "RustwoodForest", Pieces = { Bush_Fern = 5, Bush_Round = 2, Log_Fallen = 1, Rock_M = 1, Roots = 2, Glow_Mushrooms = 2 },
		Density = 1.6, Spacing = 12, Scale = { 0.9, 1.4 }, MaxSlope = 34 },
	{ Region = "TidepoolMarsh", Pieces = { Tree_Marshroot_M = 3, Tree_Marshroot_S = 3, Tree_Marshroot_L = 2 },
		Density = 1.2, Spacing = 40, Scale = { 0.9, 1.2 }, MaxSlope = 25, MinHeight = 1.2 },
	{ Region = "TidepoolMarsh", Pieces = { Reeds = 8, Driftwood = 1, Rock_S = 1, Barnacles = 1, Anemone_Glow = 1 },
		Density = 2.6, Spacing = 9, Scale = { 1.0, 1.6 }, MaxSlope = 25, MinHeight = -1 },
	{ Region = "TidepoolMarsh", Pieces = { Lilypads = 3, Kelp_Tall = 1 }, Density = 2.5, Spacing = 10, Scale = { 0.8, 1.5 },
		MaxSlope = 10 },
	{ Region = "Downs", Pieces = { Tree_Spirepine_M = 2, Tree_Spirepine_S = 2, Tree_Rustwood_M = 1 },
		Density = 0.5, Spacing = 40, Scale = { 0.9, 1.2 }, MaxSlope = 30 },
	{ Region = "Downs", Pieces = { Rock_M = 2, Rock_L = 1, Bush_Round = 3, Flowers = 3, Rock_S = 2 },
		Density = 1.6, Spacing = 14, Scale = { 0.8, 1.3 }, MaxSlope = 40 },
	{ Region = "OldWharf", Pieces = { Driftwood = 3, Rock_M = 2, Barnacles = 2, Coral_Branch = 1, Coral_Fan = 1, Anemone_Glow = 1,
		Kelp_Tall = 2 }, Density = 4, Spacing = 10, Scale = { 0.8, 1.3 }, MaxSlope = 40 },
	{ Region = "Harbour", Pieces = { Kelp_Tall = 4, Coral_Branch = 2, Coral_Fan = 2, Anemone_Glow = 1, Rock_M = 1 },
		Density = 1.4, Spacing = 14, Scale = { 0.9, 1.6 }, MaxSlope = 40 },
	{ Region = "Cistern", Pieces = { Rubble = 3, Current_Crystal_S = 2, Current_Crystal_M = 1, Rock_M = 1, Barnacles = 1 },
		Density = 4, Spacing = 12, Scale = { 0.8, 1.2 }, MaxSlope = 45 },
	{ Region = "FirstGate", Pieces = { Rock_S = 2, Flowers = 2, Current_Crystal_S = 1 }, Density = 1, Spacing = 16,
		Scale = { 0.8, 1.2 }, MaxSlope = 35 },
} :: { ScatterRule }

-- Roads outside the town (polyline points x, z) and their widths.
Layout.Roads = {
	{ Name = "EastRoad", Width = 18, Points = { Vector2.new(46, 192), Vector2.new(240, 150), Vector2.new(420, 120),
		Vector2.new(640, 90), Vector2.new(860, 40), Vector2.new(1060, 10) } },
	{ Name = "CisternSpur", Width = 12, Points = { Vector2.new(420, 120), Vector2.new(470, 175), Vector2.new(520, 240) } },
	{ Name = "NorthRoad", Width = 14, Points = { Vector2.new(-378, -494), Vector2.new(-300, -600), Vector2.new(-150, -650),
		Vector2.new(-40, -760), Vector2.new(120, -880) } },
	{ Name = "CoastRoad", Width = 14, Points = { Vector2.new(-760, 262), Vector2.new(-720, 420), Vector2.new(-640, 600),
		Vector2.new(-480, 760), Vector2.new(-300, 900) } },
	{ Name = "WharfPath", Width = 12, Points = { Vector2.new(-822, -186), Vector2.new(-870, -290), Vector2.new(-930, -370) } },
}

-- MATH ---------------------------------------------------------------------------------

local function smooth(e0: number, e1: number, x: number): number
	local t = math.clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end
Layout.Smooth = smooth

local function fbm(x: number, z: number, scale: number, octaves: number, seed: number): number
	local total, amp, norm = 0, 1, 0
	local s = scale
	for o = 1, octaves do
		total += math.noise(x / s + seed * 13.7, z / s - seed * 7.1, seed * 3.3 + o * 1.7) * amp
		norm += amp
		amp *= 0.5
		s *= 0.5
	end
	return total / norm
end
Layout.Fbm = fbm

function Layout.Polar(x: number, z: number): (number, number)
	local dx, dz = x - Layout.Bay.X, z - Layout.Bay.Y
	return math.sqrt(dx * dx + dz * dz), math.atan2(dz, dx)
end

function Layout.FromPolar(r: number, a: number): Vector2
	return Vector2.new(Layout.Bay.X + math.cos(a) * r, Layout.Bay.Y + math.sin(a) * r)
end

-- Arc-length distance (studs) between angle a and a reference angle at radius r.
local function arcGap(r: number, a: number, ref: number): number
	return math.abs(a - ref) * r
end
Layout.ArcGap = arcGap

function Layout.BandAt(r: number): Band?
	for _, band in Layout.Bands do
		if r >= band.R0 and r < band.R1 then
			return band
		end
	end
	return nil
end

local function segDist(p: Vector2, a: Vector2, b: Vector2): (number, number)
	local ab = b - a
	local t = math.clamp((p - a):Dot(ab) / ab:Dot(ab), 0, 1)
	return (p - (a + ab * t)).Magnitude, t
end
Layout.SegDist = segDist

-- Distance from p to a polyline, and the index/param of the closest segment.
function Layout.PolylineDist(p: Vector2, points: { Vector2 }): (number, number, number)
	local best, bestI, bestT = math.huge, 1, 0
	for i = 1, #points - 1 do
		local d, t = segDist(p, points[i], points[i + 1])
		if d < best then
			best, bestI, bestT = d, i, t
		end
	end
	return best, bestI, bestT
end

-- REGIONS ------------------------------------------------------------------------------

function Layout.InTown(x: number, z: number): boolean
	local r, a = Layout.Polar(x, z)
	return math.abs(a) <= Layout.TownAngle and r >= Layout.QuayRadius and r < Layout.TownOuter
end

-- Domain warp: bends every region boundary so nothing outside the town follows a straight line.
local function warp(x: number, z: number): (number, number)
	return x + 140 * fbm(x, z, 420, 2, 21), z + 140 * fbm(x, z, 420, 2, 22)
end
Layout.Warp = warp

-- Signed distance to the harbour shore (negative = water): the bay disc plus the channel west.
local function shoreDist(x: number, z: number, r: number, a: number): number
	local bayR = Layout.QuayRadius
	if math.abs(a) > Layout.TownAngle then
		bayR += 28 * fbm(x, z, 120, 2, 23) -- natural coast outside the quays
	end
	local dBay = r - bayR
	local halfW = 290 + 80 * smooth(-1050, -1450, x) + 26 * fbm(x, z, 140, 2, 24)
	local dChan = math.max(math.abs(z - Layout.Bay.Y) - halfW, x - Layout.Bay.X)
	return math.min(dBay, dChan)
end

-- Old Wharf: a low sandy shelf along the shore north of the docks.
local function wharfMask(r: number, a: number): number
	local ang = smooth(-1.3, -1.12, a) * (1 - smooth(-0.72, -0.66, a))
	return ang * (1 - smooth(430, 490, r))
end

-- Tidepool Marsh (lowland): the whole south of the floor, and the coast south of the town.
local function lowMask(x: number, z: number, r: number, a: number): number
	local wx, wz = warp(x, z)
	local edgeZ = 520 + 240 * smooth(400, 1100, wx)
	local south = smooth(-90, 90, wz - edgeZ)
	local coast = smooth(0.64, 0.8, a) * (1 - smooth(1000, 1250, r + (wz - z)))
	return math.max(south, coast)
end

-- Rustwood Forest: the northern highlands (its edge swings south toward the east).
local function forestMask(x: number, z: number): number
	local wx, wz = warp(x, z)
	local edgeZ = -430 + 250 * smooth(-200, 700, wx)
	return smooth(-60, 60, edgeZ - wz)
end
Layout.ForestMask = forestMask

-- Highland base height (Rustwood and the eastern downs).
local function highland(x: number, z: number): number
	local h = 122 + 16 * fbm(x, z, 520, 3, 1) + 6 * fbm(x, z, 140, 2, 2)
	-- ridges in the far north
	h += 22 * smooth(-700, -1300, z) * (0.6 + 0.4 * fbm(x, z, 260, 2, 3))
	-- the gate plateau
	local g = (Vector2.new(x, z) - Layout.Points.FirstGate).Magnitude
	local plateau = Layout.GatePlateau
	h = h + (plateau.Y - h) * (1 - smooth(plateau.Radius, plateau.Rim, g))
	-- the Cistern basin (sunken ruin)
	local c = (Vector2.new(x, z) - Layout.Points.Cistern).Magnitude
	local basin = Layout.CisternBasin
	h = h + (basin.Y - h) * (1 - smooth(basin.Radius, basin.Rim, c))
	return h
end

-- Lowland (marsh) height and its tide pools.
local function marsh(x: number, z: number): number
	local n = fbm(x, z, 180, 3, 4)
	local h = 3.2 + 2.5 * n
	-- tide pools: more of them toward the sea, plus the deep lagoon where the Brinehulk lurks
	local pools = fbm(x, z, 90, 2, 5)
	local bias = -0.16 + 0.14 * fbm(x, z, 600, 1, 27) + 0.08 * smooth(-200, 600, x)
	if pools < bias then
		h = math.min(h, -2.5 + (pools - bias) * 6)
	end
	local lagoon = (Vector2.new(x, z) - Layout.Points.BrinehulkDeep).Magnitude + 40 * fbm(x, z, 80, 2, 28)
	if lagoon < 150 then
		h = h + (-7 - h) * (1 - smooth(90, 150, lagoon))
	end
	return h
end

local function onAvenue(r: number, a: number): (boolean, number)
	if arcGap(r, a, Layout.Climb.Angle) < Layout.Climb.Width / 2 + 1 then
		return true, Layout.Climb.Width
	end
	for _, sa in Layout.Spokes do
		if arcGap(r, a, sa) < Layout.SpokeWidth / 2 + 1 then
			return true, Layout.SpokeWidth
		end
	end
	return false, 0
end
Layout.OnAvenue = onAvenue

local function onCanal(r: number, a: number): boolean
	if r > Layout.CanalEnd then
		return false
	end
	for _, ca in Layout.Canals do
		if arcGap(r, a, ca) < Layout.CanalWidth / 2 + 1 then
			return true
		end
	end
	return false
end
Layout.OnCanal = onCanal

-- Height of a town point: flat terraces, with stair ramps on the avenues and canal channels.
local function townHeight(r: number, a: number): number
	local band = Layout.BandAt(r)
	if not band then
		return Layout.Bands[#Layout.Bands].Y
	end
	local h = band.Y
	local below = r - band.R0
	if band.R0 > Layout.QuayRadius and onAvenue(r, a) and below < Layout.RampRun then
		-- the terrain ramp sits 1.5 under the stair pieces' walking surface
		h = band.Y - 24 + 24 * math.clamp(below / Layout.RampRun, 0, 1) - 1.5
	elseif onCanal(r, a) then
		if band.R0 > Layout.QuayRadius and below < 4 then
			h = band.Y - Layout.CanalDepth + 0.6 -- the lip the canal pours over
		else
			-- 5 below the surface, not 3: terrain water only fills voxels with no solid in them, and
			-- every band's water line (band.Y - CanalDepth) sits on a 4-stud voxel boundary, so the
			-- bed must stay below the next boundary down or the channel holds no water at all
			h = band.Y - Layout.CanalDepth - 5
		end
	end
	return h
end

-- Road profiles (height along each road) are computed lazily from the un-roaded terrain.
local roadProfiles: { [string]: { number } } = {}

local function rawHeight(x: number, z: number): number
	local r, a = Layout.Polar(x, z)
	local townAngle = math.abs(a) <= Layout.TownAngle
	local h: number
	if townAngle and r >= Layout.QuayRadius and r < Layout.TownOuter then
		h = townHeight(r, a)
	else
		local hl = highland(x, z)
		local lo = marsh(x, z)
		h = hl + (lo - hl) * lowMask(x, z, r, a)
		local w = wharfMask(r, a)
		if w > 0 then
			h = h + (5 + 1.5 * fbm(x, z, 40, 2, 25) - h) * w
		end
		-- east of the Guild Terrace the land rises gently into the downs
		if math.abs(a) <= Layout.TownAngle + 0.04 and r >= Layout.TownOuter then
			h = 104 + (h - 104) * smooth(Layout.TownOuter, Layout.TownOuter + 180, r)
		end
	end
	-- the harbour: a rocky coast falls to the water, the quays drop straight in
	local d = shoreDist(x, z, r, a)
	local depth = -5 - 15 * smooth(0, 90, -d) + 2 * fbm(x, z, 60, 2, 26)
	if townAngle and r < Layout.TownOuter then
		if r < Layout.QuayRadius then
			h = depth
		end
	elseif d < 140 then
		local coast = 1 - smooth(0, 140, d) -- 1 at the waterline
		h = h + (math.min(h, 6) - h) * coast * coast
		if d < 0 then
			h = h + (depth - h) * smooth(0, 10, -d)
		end
	end
	-- breakwaters (rock arms carrying the quay pieces)
	for _, arm in Layout.Breakwaters do
		local bd = segDist(Vector2.new(x, z), arm[1], arm[2])
		if bd < 18 then
			local k = 1 - smooth(10, 18, bd)
			h = h + (5 - h) * k
		end
	end
	-- reef lip at the floor's west edge keeps the harbour water in
	if x < -1466 then
		h = math.max(h, 2.5 + 2 * fbm(x, z, 30, 2, 9))
	end
	return h
end


local function profileFor(road: { Name: string, Width: number, Points: { Vector2 } }): { number }
	local cached = roadProfiles[road.Name]
	if cached then
		return cached
	end
	-- sample every 8 studs along the road, then smooth so slopes stay walkable
	local samples: { number } = {}
	for i = 1, #road.Points - 1 do
		local a, b = road.Points[i], road.Points[i + 1]
		local n = math.max(1, math.floor((b - a).Magnitude / 8))
		for k = 0, n - 1 do
			local p = a:Lerp(b, k / n)
			table.insert(samples, rawHeight(p.X, p.Y))
		end
	end
	local last = road.Points[#road.Points]
	table.insert(samples, rawHeight(last.X, last.Y))
	for _ = 1, 6 do
		local out = table.clone(samples)
		for i = 2, #samples - 1 do
			out[i] = (samples[i - 1] + samples[i] * 2 + samples[i + 1]) / 4
		end
		samples = out
	end
	roadProfiles[road.Name] = samples
	return samples
end

-- Height of the road surface at arc-length position s along a road.
local function roadHeightAt(road: { Name: string, Width: number, Points: { Vector2 } }, segIndex: number, t: number): number
	local samples = profileFor(road)
	local s = 0
	for i = 1, segIndex - 1 do
		s += (road.Points[i + 1] - road.Points[i]).Magnitude
	end
	s += (road.Points[segIndex + 1] - road.Points[segIndex]).Magnitude * t
	local f = s / 8
	local i0 = math.clamp(math.floor(f) + 1, 1, #samples)
	local i1 = math.clamp(i0 + 1, 1, #samples)
	local frac = f - math.floor(f)
	return samples[i0] + (samples[i1] - samples[i0]) * frac
end

-- Final surface height at (x, z).
function Layout.Height(x: number, z: number): number
	local h = rawHeight(x, z)
	if Layout.InTown(x, z) then
		return h
	end
	local p = Vector2.new(x, z)
	for _, road in Layout.Roads do
		local d, i, t = Layout.PolylineDist(p, road.Points)
		local w = road.Width / 2
		if d < w + 14 then
			local ry = roadHeightAt(road, i, t)
			local k = 1 - smooth(w, w + 14, d)
			h = h + (ry - h) * k
		end
	end
	return h
end

-- Is (x, z) on a town street, avenue, stair spoke or plaza? Returns the surface kind or nil.
function Layout.TownSurface(x: number, z: number): string?
	local r, a = Layout.Polar(x, z)
	if not Layout.InTown(x, z) then
		return nil
	end
	if onCanal(r, a) then
		return "Canal"
	end
	local plaza = Layout.FromPolar(Layout.Plaza.Radius, Layout.Plaza.Angle)
	if (Vector2.new(x, z) - plaza).Magnitude < Layout.Plaza.Size / 2 then
		return "Plaza"
	end
	if onAvenue(r, a) then
		return "Avenue"
	end
	local band = Layout.BandAt(r)
	if band and math.abs(r - band.Street) < Layout.StreetWidth / 2 then
		return "Street"
	end
	if r < Layout.QuayRadius + 14 then
		return "Quay"
	end
	return "Lot"
end

-- Terrain material at (x, z) for a surface of height h and slope (degrees).
function Layout.Material(x: number, z: number, h: number, slope: number): Enum.Material
	if Layout.InTown(x, z) then
		local s = Layout.TownSurface(x, z)
		if s == "Street" or s == "Avenue" then
			return Enum.Material.Cobblestone
		elseif s == "Plaza" or s == "Quay" then
			return Enum.Material.Pavement
		elseif s == "Canal" then
			return Enum.Material.Slate
		end
		-- lots: paved yards with garden patches (buildings cover most of them)
		return if fbm(x, z, 70, 2, 6) > 0.3 then Enum.Material.Grass else Enum.Material.Pavement
	end
	if slope > 48 then
		return Enum.Material.Rock
	elseif slope > 36 then
		return if fbm(x, z, 30, 1, 7) > 0 then Enum.Material.Slate else Enum.Material.Rock
	end
	local p = Vector2.new(x, z)
	for _, road in Layout.Roads do
		local d = Layout.PolylineDist(p, road.Points)
		if d < road.Width / 2 then
			return Enum.Material.Cobblestone
		elseif d < road.Width / 2 + 3 then
			return Enum.Material.Ground
		end
	end
	if (p - Layout.Points.FirstGate).Magnitude < Layout.GatePlateau.Radius - 10 then
		return Enum.Material.Pavement
	end
	if (p - Layout.Points.Cistern).Magnitude < Layout.CisternBasin.Radius then
		return Enum.Material.Cobblestone
	end
	if h < 0.5 then
		return if h < -6 then Enum.Material.Mud else Enum.Material.Sand
	end
	local r, a = Layout.Polar(x, z)
	if lowMask(x, z, r, a) > 0.5 then
		local n = fbm(x, z, 60, 2, 8)
		if h < 2.2 then
			return Enum.Material.Mud
		end
		return if n > 0.15 then Enum.Material.Grass elseif n > -0.2 then Enum.Material.Mud else Enum.Material.Ground
	end
	if wharfMask(r, a) > 0.5 then
		return Enum.Material.Sand
	end
	if h < 8 and shoreDist(x, z, r, a) < 30 then
		return Enum.Material.Sand
	end
	-- Rustwood floor (autumn leaf litter) in the north, meadows elsewhere
	local f = forestMask(x, z)
	if f > 0.5 + 0.3 * fbm(x, z, 40, 2, 12) then
		return if fbm(x, z, 50, 2, 10) > -0.25 then Enum.Material.LeafyGrass else Enum.Material.Ground
	end
	return if fbm(x, z, 70, 2, 11) > -0.3 then Enum.Material.Grass else Enum.Material.Ground
end

-- Named region at (x, z) (ambient sound, music, mob spawns, map labels).
export type Region = "Town" | "Harbour" | "OldWharf" | "TidepoolMarsh" | "RustwoodForest" | "Downs" | "Cistern" | "FirstGate"
function Layout.Region(x: number, z: number): Region
	local r, a = Layout.Polar(x, z)
	if Layout.InTown(x, z) then
		return "Town"
	end
	if shoreDist(x, z, r, a) < 0 then
		return "Harbour"
	end
	if wharfMask(r, a) > 0.4 then
		return "OldWharf"
	end
	local p = Vector2.new(x, z)
	if (p - Layout.Points.Cistern).Magnitude < Layout.CisternBasin.Rim then
		return "Cistern"
	end
	if (p - Layout.Points.FirstGate).Magnitude < Layout.GatePlateau.Rim then
		return "FirstGate"
	end
	if lowMask(x, z, r, a) > 0.5 then
		return "TidepoolMarsh"
	end
	if forestMask(x, z) > 0.5 then
		return "RustwoodForest"
	end
	return "Downs"
end

-- Water surface height at (x, z), or nil.
function Layout.Water(x: number, z: number, h: number): number?
	if Layout.InTown(x, z) then
		local r, a = Layout.Polar(x, z)
		local band = Layout.BandAt(r)
		if band and onCanal(r, a) then
			local w = band.Y - Layout.CanalDepth
			return if h < w - 0.3 then w else nil
		end
	end
	if h < Layout.Sea - 0.3 then
		return Layout.Sea
	end
	return nil
end

return Layout
