--!strict
-- Shared Luau types for The Spire.
-- World types describe the data-only output of the edit-time planners
-- (ServerStorage/WorldBuilder/Plan) and the floor definitions in Shared/Data/Floors.

export type Vec3 = { number }

-- ===================================================================== kit

export type KitCollider = {
	shape: string, -- "Box" | "Wedge" (wedge rises toward local +Z, like a Roblox WedgePart)
	c: Vec3,
	s: Vec3,
	ry: number, -- degrees
}

export type KitOpening = {
	kind: string, -- "door" | "window" | "arch" | "archdoor" | "shop" | "breach"
	x0: number,
	x1: number,
	y0: number,
	y1: number,
}

export type KitPiece = {
	id: string,
	category: string,
	material: string,
	color: string,
	collision: string, -- "Box" | "Hull" | "None" | "Colliders" | "Facade"
	stretch: string,
	size: Vec3,
	center: Vec3,
	footprint: Vec3,
	colliders: { KitCollider },
	openings: { KitOpening },
	anchors: { [string]: Vec3 },
	tris: number,
}

-- An assembly is a reusable group of kit pieces plus lights/emitters (e.g. a
-- lantern = post + glowing glass + light). Offsets are in assembly space.
export type AssemblyPart = {
	kit: string,
	x: number,
	y: number,
	z: number,
	ry: number?,
	s: number?,
	material: string?,
	color: string?,
}

export type AssemblyLight = {
	x: number,
	y: number,
	z: number,
	color: string,
	range: number,
	brightness: number,
	night: boolean,
	attach: number?, -- index of the assembly part that hosts the light (no extra anchor)
}

export type AssemblyEmitter = {
	preset: string,
	x: number,
	y: number,
	z: number,
}

export type Assembly = {
	parts: { AssemblyPart },
	lights: { AssemblyLight }?,
	emitters: { AssemblyEmitter }?,
	footprint: { number }, -- {w, d} for placement clearance
}

-- ============================================================ plan output

export type PiecePlacement = {
	kit: string,
	x: number,
	y: number,
	z: number,
	ry: number, -- radians
	rx: number?,
	rz: number?,
	s: number?, -- uniform scale
	sx: number?, -- per-axis stretch (only for pieces whose manifest allows it)
	sy: number?,
	sz: number?,
	material: string?,
	color: string?,
	tag: string?,
	noCollide: boolean?,
	text: string?, -- Strings key painted on both faces (sign boards)
}

export type SolidPlacement = {
	kind: string, -- "Collider" | "Surface" | "Glass" | "Current" | "Falls" | "Trigger" | "Barrier"
	shape: string, -- "Block" | "Wedge" | "Cylinder"
	x: number,
	y: number,
	z: number,
	sx: number,
	sy: number,
	sz: number,
	ry: number,
	rx: number?,
	rz: number?,
	material: string?,
	color: string?,
	transparency: number?,
	tag: string?,
	name: string?,
	text: string?, -- Strings key rendered on the front face (signs, notice boards)
}

export type LightPlacement = {
	x: number,
	y: number,
	z: number,
	color: string,
	range: number,
	brightness: number,
	night: boolean,
	piece: number?, -- index into the node's pieces: the light is parented to that part
}

export type EmitterPlacement = {
	preset: string,
	x: number,
	y: number,
	z: number,
	sx: number?,
	sy: number?,
	sz: number?,
	ry: number?,
}

export type MarkerValue = string | number | boolean

export type MarkerPlacement = {
	kind: string,
	id: string,
	x: number,
	y: number,
	z: number,
	ry: number,
	attributes: { [string]: any }?, -- string | number | boolean values
}

export type PlanNode = {
	name: string,
	x: number,
	y: number,
	z: number,
	ry: number,
	streaming: string, -- "Atomic" | "Persistent" | "Default" | "Nonatomic"
	pieces: { PiecePlacement },
	solids: { SolidPlacement },
	lights: { LightPlacement },
	emitters: { EmitterPlacement },
	markers: { MarkerPlacement },
	children: { PlanNode },
	tags: { string },
	attributes: { [string]: MarkerValue },
}

export type PlanStats = {
	pieces: number,
	solids: number,
	lights: number,
	emitters: number,
	markers: number,
	models: number,
	instances: number,
	tris: number,
}

-- 2D oriented box used for lot / exclusion tests (half extents)
export type OBB = { x: number, z: number, hw: number, hd: number, ry: number }

-- ========================================================== floor schema

export type Point2 = { number } -- {x, z}

export type StreetDef = {
	id: string,
	points: { Vec3 }, -- {x, y, z}; y is the street surface height
	width: number,
	material: string?,
	main: boolean?,
	lamps: boolean?,
	sides: string?, -- "both" (default) | "left" | "right" | "none": which sides get building frontage
	questPath: boolean?, -- the main quest route: real stairs, guide runes, stair posts
	signs: { { at: number, key: string, back: string? } }?, -- signposts at polyline points
}

export type DistrictDef = {
	id: string,
	nameKey: string,
	polygon: { Point2 },
	baseY: number,
	style: string,
	wealth: number,
	density: number,
	storeys: { number }, -- {min, max}
	kinds: { [string]: number },
	secondarySpacing: number?,
	seed: number,
}

export type PlazaDef = {
	id: string,
	x: number,
	z: number,
	y: number,
	radius: number,
	material: string,
	features: { string },
}

export type CanalNode = { number } -- {x, z, streetY}

export type CanalDef = {
	id: string,
	nodes: { CanalNode },
	width: number,
	depth: number,
	waterDrop: number, -- water surface below street level
	healing: boolean?,
}

export type WaystoneDef = {
	id: string,
	nameKey: string,
	x: number,
	y: number,
	z: number,
	ry: number,
	district: string?,
	starting: boolean?,
}

export type ZoneDef = {
	id: string,
	nameKey: string,
	kind: string, -- "Town" | "Wild" | "Dungeon" | "Hidden" | "Arena"
	polygon: { Point2 },
	minY: number,
	maxY: number,
	pressure: number, -- 1..5
	safe: boolean,
	levelRange: { number },
	ambience: string,
	priority: number,
}

export type LandmarkDef = {
	id: string,
	kind: string,
	x: number,
	y: number,
	z: number,
	ry: number,
	clearRadius: number,
}

export type HiddenAreaDef = {
	id: string,
	nameKey: string,
	kind: string,
	x: number,
	y: number,
	z: number,
	ry: number,
	chestId: string,
	rewards: { gold: number, items: { { id: string, count: number } } },
}

export type SpawnRegionDef = {
	id: string,
	mob: string,
	x: number,
	z: number,
	radius: number,
	count: number,
	levelMin: number,
	levelMax: number,
	night: boolean?,
	elite: boolean?,
}

export type WildDef = {
	id: string,
	polygon: { Point2 },
	biome: string, -- "Marsh" | "Forest" | "Crags" | "Shore"
	density: number,
	seed: number,
}

export type PathDef = {
	id: string,
	points: { Point2 },
	width: number,
	material: string,
	boardwalk: boolean?,
}

export type TerrainRegionDef = {
	id: string,
	polygon: { Point2 },
	base: number,
	amplitude: number,
	frequency: number,
	material: string,
	blend: number,
}

export type PoolDef = { x: number, z: number, radius: number, waterY: number, bedY: number }

export type FloorDef = {
	id: string,
	index: number,
	nameKey: string,
	seed: number,
	size: number,
	seaLevel: number,
	spawnWaystone: string,
	lightingPreset: string,
	terrainRegions: { TerrainRegionDef },
	pools: { PoolDef },
	districts: { DistrictDef },
	streets: { StreetDef },
	plazas: { PlazaDef },
	canals: { CanalDef },
	waystones: { WaystoneDef },
	zones: { ZoneDef },
	landmarks: { LandmarkDef },
	hidden: { HiddenAreaDef },
	spawns: { SpawnRegionDef },
	wilds: { WildDef },
	paths: { PathDef },
	quay: { Point2 },
	dungeon: { id: string, nameKey: string, entrance: Vec3, entranceRy: number },
	guardianGate: { x: number, y: number, z: number, ry: number },
}

-- ============================================================ runtime

export type TerrainSample = {
	height: number,
	material: string,
	water: number?, -- water surface height, nil when dry
}

return {}
