--!strict
--[[
	Floor1GuardianArena (edit-time tool; never runs during play)
	Builds the Floor 1 Guardian's arena, "The Drowned Threshold", and the challenge markers at the
	First Gate (docs/PHASE10_GUARDIAN.md, sections 2 and 3).

	1. The arena TEMPLATE: ServerStorage.GuardianArenas.Brinewarden (a Model). GuardianService clones
	   it per party and pivots it into a slot beyond the Spire wall; it is self-contained (its own
	   floor, walls and backdrop, since no terrain exists there).
	   Template space: Origin at (0, 0, 0) on the walking surface, +Z toward the sealed gate.
	     r 0..50    the fight floor: flagstones only, no collision clutter
	     r 50..70   the rim: tide pools, braziers, Current crystals, a ring of broken colonnade
	     r 73       the ring wall (damaged stone, arches, rune bands, tide-line runes)
	     r 76.5     an invisible wall ring, so nobody leaves the court
	     +Z, r 66+  a replica of the sealed First Gate; its opening is closed by the Seal curtain
	     outside    a drowned apron, cliffs, kelp and a leviathan's ribs as the backdrop
	   Markers (the contract):
	     Origin        PrimaryPart, invisible, at floor centre; its +Z points at the gate
	     BossSpawn     the Warden's start; its LookVector faces the gate side
	     PlayerSpawns  8 parts on an arc near the gate side; each LookVector faces the centre
	     AddPools      4 parts at the tide pools (Bilgecrab spawns)
	     TideWater     the flood plane; attributes CalmY, HighY, EbbY are Y offsets from Origin
	     TideLines     dim Neon strips on the ring wall, lit by the tide
	     PressureZone  covers the arena, tag PressureZone, attribute Pressure
	     Seal          the Current curtain across the gate opening (CanCollide while sealed)
	     Bounds        attribute Radius: the walkable radius
	2. The GATE markers: Workspace.Floor1.GuardianGate with
	     ChallengePrompt  in front of the First Gate's sealed door (tag SpireGuardianGate,
	                      attributes GuardianId and GatherRadius)
	     Return           on the approach floor west of the prompt, facing west (where the party
	                      comes back after the fight)
	     SealGlow         a faint Current sheen on the sealed door so players notice it

	Undo removes exactly what Apply added. Every piece is placed with computed CFrames (no PivotTo,
	no raycasts), so the tool also runs offline under Lune (tools/place/sync_scripts.luau).

	Usage (Command Bar, Edit mode):
	    local A = require(game.ServerStorage.Tools.Floor1GuardianArena)
	    A.Apply()  -- build (refuses if already built)
	    A.Undo()   -- remove the template and the gate markers
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local KitLibrary = require(script.Parent.KitLibrary)
local Config = require(ReplicatedStorage.Shared.Config)
local Attributes = require(ReplicatedStorage.Shared.Attributes)

local Arena = {}

-- NAMES -----------------------------------------------------------------------------------------

local GUARDIAN_ID = "Brinewarden"
local ARENAS_FOLDER = "GuardianArenas"
local GATE_FOLDER = "GuardianGate"
local CREATED_BY = "Floor1GuardianArena"
local NIGHT_LIGHT_TAG = KitLibrary.Tags.NightLight

-- LAYOUT (template space, studs) -------------------------------------------------------------------

local COURT_RADIUS = 82 -- the collision floor disc (reaches under the wall and the edge paving)
local COURT_DEPTH = 4
local TILE = 16 -- Floor_Stone tile pitch
local TILE_REACH = 62 -- whole tiles lie entirely within this radius
local RIM_TILE_REACH = 76 -- half-size tiles fill out to here (centres), under the ring wall
local FIGHT_RADIUS = 50 -- the clear fight floor (an inlay ring marks its edge)
local BOUNDS_RADIUS = 70

local WALL_RADIUS = 73
local WALL_SEGMENTS = 28
local WALL_SCALE_Y = 1.3
local WALL_OVERLAP = 1.04 -- segment width stretch so neighbours close their seams
local GATE_GAP_DEG = 25 -- wall segments within this angle of +Z give way to the gate
local ARCH_ANGLES = { 70.7, -70.7, 173.6, -173.6 } -- wall segments (centre angles) that are arches
local RUNE_BAND_Y = 8
local WALL_FACE = 1.0 -- the wall's inner face, in front of the piece origin

local OUTER_RADIUS = 76.5 -- invisible containment ring
local OUTER_SEGMENTS = 24
local OUTER_HEIGHT = 80

local APRON_SIZE = 240 -- the drowned ground outside the walls
local APRON_TOP = -3

local GATE_SCALE = 0.62
local GATE_Z = 76.5 -- the replica's centre (its front face is at about z 66)
local GATE_FRONT_Z = 67.6 -- the front of its pillars
local GATE_OPENING = 26 -- width of the doorway between the pillars
local GATE_OPENING_H = 44
local GATE_JOIN_X = 31 -- columns that close the seam between the gate and the ring wall
local GATE_JOIN_Z = 65.5

local COLUMN_RADIUS = 63
local BRAZIER_RADIUS = 58
local CRYSTAL_RADIUS = 68
local POOL_RADIUS = 56 -- distance of each tide pool from the centre
local POOL_SIZE = 5 -- radius of a pool
local STATUE_RADIUS = 63
local STATUE_ANGLE = 36
local STATUE_SCALE = 0.6
local DRESS_INNER = 66 -- rim dressing band
local DRESS_OUTER = 70

local SPAWN_RADIUS = 45
local SPAWN_ARC = 42 -- degrees either side of +Z
local BOSS_SPAWN_Z = -16

-- Tide offsets from Origin (the flood plane's centre).
local CALM_Y = -1.5 -- hidden below the flagstones
local HIGH_Y = 0.6 -- ankle-deep
local EBB_Y = -0.6
local TIDE_LINE_Y = 2.2 -- tide-line runes sit just above the high-water mark
local WATER_SIZE = 236
local WATER_THICKNESS = 0.4

local PRESSURE = 3 -- calm phase; GuardianService raises it with the tide
local PRESSURE_SIZE = Vector3.new(160, 120, 160)
local PRESSURE_Y = 40

-- Lights (budget: 12, all shadowless).
local BRAZIER_RANGE = 26
local BRAZIER_BRIGHTNESS = 1.1
local CRYSTAL_RANGE = 22
local CRYSTAL_BRIGHTNESS = 0.9
local SEAL_RANGE = 30
local SEAL_BRIGHTNESS = 1.4

local SEED = 4471

-- GATE MARKERS (world space, the First Gate on its plateau at y = 148) ---------------------------

local PLATEAU_Y = 148
local PROMPT_POSITION = Vector3.new(1236, 152, 0)
local PROMPT_SIZE = Vector3.new(4, 8, 4)
local RETURN_POSITION = Vector3.new(1211, PLATEAU_Y + 0.5, 0)
local SEAL_GLOW_X = 1250.2 -- just west of the sealed door panel (x 1250.5..1253.5)
local SEAL_GLOW_SIZE = Vector3.new(0.3, 56, 38)
local SEAL_GLOW_RANGE = 28
local SEAL_GLOW_BRIGHTNESS = 1.2

-- PALETTE -----------------------------------------------------------------------------------------

local CURRENT = Color3.fromHex("#3FE0D0")
local COURT_STONE = Color3.fromHex("#2E3536")
local APRON_MUD = Color3.fromHex("#1C2321")
local FLAG_TINT = Color3.fromHex("#56605C")
local FLAG_DARK = Color3.fromHex("#2B3233")
local WATER = Color3.fromHex("#14474D")
local TIDE_DIM = Color3.fromHex("#1F4F4B")
local POOL_WATER = Color3.fromHex("#1F6E78")
local BRASS = Color3.fromHex("#7D6A43")
local BANNER = Color3.fromHex("#1F5A66")

-- HELPERS -----------------------------------------------------------------------------------------

type PartSpec = {
	Material: Enum.Material?,
	Color: Color3?,
	Transparency: number?,
	Collide: boolean?, -- default false
	Query: boolean?, -- default = Collide
	Shadow: boolean?, -- default = Collide
	Shape: Enum.PartType?,
}

local function newPart(parent: Instance, name: string, size: Vector3, cf: CFrame, spec: PartSpec?): Part
	local s: PartSpec = spec or {}
	local collide = s.Collide == true
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.CanCollide = collide
	p.CanQuery = if s.Query ~= nil then s.Query else collide
	p.CanTouch = false
	p.CastShadow = if s.Shadow ~= nil then s.Shadow else collide
	p.Material = s.Material or Enum.Material.Slate
	p.Color = s.Color or COURT_STONE
	p.Transparency = s.Transparency or 0
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if s.Shape then
		p.Shape = s.Shape
	end
	p.Parent = parent
	return p
end

local function marker(parent: Instance, name: string, cf: CFrame, size: Vector3?): Part
	return newPart(parent, name, size or Vector3.new(4, 1, 4), cf, { Transparency = 1, Collide = false, Query = false })
end

local function newFolder(parent: Instance, name: string): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

-- Point on the floor at radius r, angle deg (0 = +Z, the gate; +90 = +X).
local function polar(r: number, deg: number, y: number?): Vector3
	local a = math.rad(deg)
	return Vector3.new(r * math.sin(a), y or 0, r * math.cos(a))
end

-- A CFrame at `pos` whose LookVector is the horizontal direction `dir`. Built from a yaw rather
-- than CFrame.lookAt, whose Lune implementation mirrors Z, so Studio and the offline build agree.
local function facing(pos: Vector3, dir: Vector3): CFrame
	return CFrame.new(pos) * CFrame.Angles(0, math.atan2(-dir.X, -dir.Z), 0)
end

-- A kit piece's front (+Z in template space, opposite its LookVector) faces the arena centre.
local function facingIn(pos: Vector3): CFrame
	return facing(pos, Vector3.new(pos.X, 0, pos.Z))
end

-- A kit piece's front faces away from the centre.
local function facingOut(pos: Vector3): CFrame
	return facing(pos, -Vector3.new(pos.X, 0, pos.Z))
end

-- Keeps (and tunes) or removes the PointLights a placement brought, and clears the night-light tag
-- so the arena's lights stay on by day (the arena is not lit by the floor's clock).
local function tuneLights(parts: { BasePart }, keep: boolean, range: number?, brightness: number?): number
	local kept = 0
	for _, part in parts do
		for _, child in part:GetChildren() do
			if child:IsA("PointLight") then
				if keep and kept == 0 then
					child.Range = range or child.Range
					child.Brightness = brightness or child.Brightness
					child.Shadows = false
					kept += 1
				else
					child:Destroy()
				end
			end
		end
		if part:HasTag(NIGHT_LIGHT_TAG) then
			part:RemoveTag(NIGHT_LIGHT_TAG)
		end
	end
	return kept
end

local function place(parent: Instance, piece: string, cf: CFrame, opts: KitLibrary.PlaceOptions?): { BasePart }
	local o: KitLibrary.PlaceOptions = opts or {}
	if o.Flatten == nil then
		o.Flatten = true
	end
	local parts = KitLibrary.Place(piece, cf, parent, o)
	return parts
end

-- Decor that never lights and never collides (small clutter must not snag feet in a fight).
local function decor(parent: Instance, piece: string, cf: CFrame, scale: number?)
	local s = scale or 1
	local parts = place(parent, piece, cf, { Scale = Vector3.new(s, s, s), Collision = false, Shadows = false })
	tuneLights(parts, false)
end

-- A small seeded generator (Park-Miller), so Studio and the offline build agree.
type Rng = { State: number }

local function rngNext(rng: Rng, lo: number, hi: number): number
	rng.State = (rng.State * 48271) % 2147483647
	return lo + (hi - lo) * (rng.State / 2147483647)
end

-- TEMPLATE PARTS ------------------------------------------------------------------------------------

local function buildFloor(geo: Folder)
	local up = CFrame.Angles(0, 0, math.pi / 2) -- a Cylinder's axis is X; stand it up
	newPart(geo, "Court", Vector3.new(COURT_DEPTH, COURT_RADIUS * 2, COURT_RADIUS * 2),
		CFrame.new(0, -COURT_DEPTH / 2, 0) * up, { Collide = true, Shadow = false, Shape = Enum.PartType.Cylinder })
	newPart(geo, "Apron", Vector3.new(APRON_SIZE, 2, APRON_SIZE), CFrame.new(0, APRON_TOP - 1, 0), {
		Collide = true,
		Shadow = false,
		Material = Enum.Material.Mud,
		Color = APRON_MUD,
	})
	-- the floor under the gate's doorway, out to the sealed door
	newPart(geo, "Threshold", Vector3.new(GATE_OPENING, 1, 14), CFrame.new(0, -0.5, GATE_FRONT_Z + 6), { Collide = true, Shadow = false })

	-- whole flagstones in the middle, half-size ones out to the wall so the paving meets it evenly
	local tiles = newFolder(geo, "Flagstones")
	local tint = { Stone = FLAG_TINT, StoneDark = FLAG_DARK }
	local half = TILE / 2
	local n = math.ceil(RIM_TILE_REACH / TILE)
	for i = -n, n do
		for j = -n, n do
			local x, z = i * TILE, j * TILE
			local far = math.sqrt((math.abs(x) + half) ^ 2 + (math.abs(z) + half) ^ 2)
			local turn = ((i * 7 + j * 3) % 4) * (math.pi / 2) -- vary the pattern
			if far <= TILE_REACH then
				place(tiles, "Floor_Stone", CFrame.new(x, 0, z) * CFrame.Angles(0, turn, 0), {
					Collision = false,
					Shadows = false,
					Tint = tint,
				})
			else
				for _, q in { Vector2.new(-1, -1), Vector2.new(1, -1), Vector2.new(-1, 1), Vector2.new(1, 1) } do
					local hx, hz = x + q.X * half / 2, z + q.Y * half / 2
					if math.sqrt(hx * hx + hz * hz) <= RIM_TILE_REACH then
						place(tiles, "Floor_Stone", CFrame.new(hx, 0, hz) * CFrame.Angles(0, turn, 0), {
							Scale = Vector3.new(0.5, 1, 0.5),
							Collision = false,
							Shadows = false,
							Tint = tint,
						})
					end
				end
			end
		end
	end

	-- brass inlay rings: the edge of the fight floor and a small centre medallion
	local inlay = newFolder(geo, "Inlay")
	for _, ring in { { R = FIGHT_RADIUS, N = 32 }, { R = 10, N = 12 } } do
		local chord = 2 * ring.R * math.sin(math.pi / ring.N) + 0.2
		for k = 0, ring.N - 1 do
			local pos = polar(ring.R, (k + 0.5) * 360 / ring.N, 0.16)
			newPart(inlay, "Inlay", Vector3.new(chord, 0.06, 0.5), facingIn(pos), {
				Material = Enum.Material.Metal,
				Color = BRASS,
			})
		end
	end
end

local function isArch(deg: number): boolean
	for _, a in ARCH_ANGLES do
		if math.abs(a - deg) < 0.5 then
			return true
		end
	end
	return false
end

local function buildWalls(geo: Folder, tideLines: Folder, dressing: Folder, rng: Rng): number
	local walls = newFolder(geo, "RingWall")
	local step = 360 / WALL_SEGMENTS
	local chord = 2 * WALL_RADIUS * math.sin(math.rad(step / 2))
	local sx = chord / 16 * WALL_OVERLAP
	local count = 0
	for k = 0, WALL_SEGMENTS - 1 do
		local deg = -180 + (k + 0.5) * step
		if math.abs(deg) < GATE_GAP_DEG then
			continue
		end
		local cf = facingIn(polar(WALL_RADIUS, deg))
		local arch = isArch(deg)
		local piece = if arch then "Wall_Stone_Arch_16" elseif k % 3 == 0 then "Wall_Stone_Plain_16" else "Wall_Stone_Damaged_16"
		place(walls, piece, cf, { Scale = Vector3.new(sx, WALL_SCALE_Y, 1), Lit = false })
		count += 1
		if not arch then
			newPart(tideLines, "TideLine", Vector3.new(chord * 0.9, 0.3, 0.2), cf * CFrame.new(0, TIDE_LINE_Y, WALL_FACE + 0.12), {
				Material = Enum.Material.Neon,
				Color = TIDE_DIM,
				Transparency = 0.5,
			})
		end
		if piece == "Wall_Stone_Plain_16" then
			decor(walls, "RuneBand_16", cf * CFrame.new(0, RUNE_BAND_Y, WALL_FACE), 1)
		end
		-- rim dressing at the wall's foot
		local picks = { "Barnacles", "Coral_Fan", "Anemone_Glow", "Rubble", "Coral_Branch", "Rock_S", "Kelp_Tall" }
		for _ = 1, 2 do
			local name = picks[math.floor(rngNext(rng, 1, #picks + 0.999))]
			local r = rngNext(rng, DRESS_INNER, DRESS_OUTER)
			local a = deg + rngNext(rng, -step * 0.45, step * 0.45)
			local pos = polar(if name == "Kelp_Tall" then DRESS_OUTER + 0.5 else r, a)
			local turn = rngNext(rng, -0.6, 0.6)
			decor(dressing, name, facingIn(pos) * CFrame.Angles(0, turn, 0), rngNext(rng, 0.8, 1.15))
		end
		if piece ~= "Wall_Stone_Arch_16" and k % 2 == 1 then
			-- barnacles crusting the wall face just above the tide line
			decor(dressing, "Barnacles", cf * CFrame.new(rngNext(rng, -5, 5), TIDE_LINE_Y + 1.5, WALL_FACE + 0.2), 0.9)
		end
	end
	return count
end

local function buildOuterRing(geo: Folder)
	local ring = newFolder(geo, "Containment")
	local chord = 2 * OUTER_RADIUS * math.sin(math.pi / OUTER_SEGMENTS) + 1.5
	for k = 0, OUTER_SEGMENTS - 1 do
		local pos = polar(OUTER_RADIUS, (k + 0.5) * 360 / OUTER_SEGMENTS, OUTER_HEIGHT / 2 - 2)
		newPart(ring, "Barrier", Vector3.new(chord, OUTER_HEIGHT, 2), facingIn(pos), {
			Collide = true,
			Query = false,
			Shadow = false,
			Transparency = 1,
		})
	end
end

local function buildGate(geo: Folder, model: Model): number
	local gate = Instance.new("Model")
	gate.Name = "SealedGate"
	gate.WorldPivot = CFrame.new(0, 0, GATE_Z)
	gate.Parent = geo
	local s = GATE_SCALE
	-- front (+Z in template space) faces the arena centre
	local at = facing(Vector3.new(0, 0, GATE_Z), Vector3.zAxis)
	local parts = place(gate, "First_Gate", at, { Scale = Vector3.new(s, s, s) })
	tuneLights(parts, false)
	for _, x in { -1, 1 } do
		place(gate, "Column_Grand", facingIn(Vector3.new(x * GATE_JOIN_X, 0, GATE_JOIN_Z)))
		place(gate, "Banner_Wall", at * CFrame.new(x * 19.8, 34, 8.9), { Tint = { Cloth = BANNER }, Shadows = false })
	end

	local seal = newPart(model, "Seal", Vector3.new(GATE_OPENING, GATE_OPENING_H, 1),
		CFrame.new(0, GATE_OPENING_H / 2, GATE_FRONT_Z - 0.2), {
			Material = Enum.Material.Neon,
			Color = CURRENT,
			Transparency = 0.55,
			Collide = true,
			Query = false, -- the camera passes through the curtain
			Shadow = false,
		})
	local light = Instance.new("PointLight")
	light.Color = CURRENT
	light.Range = SEAL_RANGE
	light.Brightness = SEAL_BRIGHTNESS
	light.Shadows = false
	light.Parent = seal
	return 1
end

type Column = { Deg: number, Kind: "Standing" | "Broken" | "Toppled" }

local COLUMNS: { Column } = {
	{ Deg = 52, Kind = "Standing" },
	{ Deg = 80, Kind = "Broken" },
	{ Deg = 108, Kind = "Standing" },
	{ Deg = 136, Kind = "Toppled" },
	{ Deg = 164, Kind = "Standing" },
	{ Deg = -52, Kind = "Standing" },
	{ Deg = -80, Kind = "Standing" },
	{ Deg = -108, Kind = "Broken" },
	{ Deg = -136, Kind = "Standing" },
	{ Deg = -164, Kind = "Toppled" },
}

local function buildColonnade(geo: Folder, dressing: Folder)
	local colonnade = newFolder(geo, "Colonnade")
	for _, c in COLUMNS do
		local pos = polar(COLUMN_RADIUS, c.Deg)
		if c.Kind == "Standing" then
			place(colonnade, "Column_Grand", facingIn(pos))
		elseif c.Kind == "Broken" then
			place(colonnade, "Pillar_Stone", facingIn(pos), { Scale = Vector3.new(1.4, 0.9, 1.4) })
			decor(dressing, "Rubble", facingIn(polar(COLUMN_RADIUS + 3, c.Deg + 3)) * CFrame.Angles(0, 0.7, 0), 1.2)
			decor(dressing, "Rubble", facingIn(polar(COLUMN_RADIUS + 2, c.Deg - 4)) * CFrame.Angles(0, -1.9, 0), 0.9)
		else
			-- a fallen drum lying along the ring (tangent), its stump left standing
			local a = math.rad(c.Deg)
			local tangent = Vector3.new(math.cos(a), 0, -math.sin(a))
			local up = Vector3.yAxis
			local base = pos - tangent * 10 + Vector3.new(0, 2.7, 0) + pos.Unit * 1.5
			local lying = CFrame.fromMatrix(base, up, tangent, up:Cross(tangent))
			place(colonnade, "Column_Grand", lying, { Scale = Vector3.new(1, 0.85, 1) })
			place(colonnade, "Pillar_Stone", facingIn(pos - tangent * 12), { Scale = Vector3.new(1.8, 0.3, 1.8) })
			decor(dressing, "Rubble", facingIn(pos + tangent * 12) * CFrame.Angles(0, 2.2, 0), 1.1)
		end
	end
	for _, side in { -1, 1 } do
		local pos = polar(STATUE_RADIUS, side * STATUE_ANGLE)
		local parts = place(colonnade, "Statue_Climber", facingIn(pos), {
			Scale = Vector3.new(STATUE_SCALE, STATUE_SCALE, STATUE_SCALE),
		})
		tuneLights(parts, false)
	end
end

local function buildLights(geo: Folder): number
	local lights = newFolder(geo, "Lights")
	local count = 0
	local braziers = {
		polar(BRAZIER_RADIUS, 66),
		polar(BRAZIER_RADIUS, -66),
		polar(BRAZIER_RADIUS, 122),
		polar(BRAZIER_RADIUS, -122),
		Vector3.new(-17, 0, GATE_FRONT_Z - 5), -- flanking the Seal
		Vector3.new(17, 0, GATE_FRONT_Z - 5),
	}
	for _, pos in braziers do
		local parts = place(lights, "Cistern_Brazier", facingIn(pos), { Shadows = false })
		count += tuneLights(parts, true, BRAZIER_RANGE, BRAZIER_BRIGHTNESS)
	end
	for _, deg in { 94, -94, 172, -172 } do
		local pos = polar(CRYSTAL_RADIUS, deg)
		local parts = place(lights, "Current_Crystal_M", facingIn(pos) * CFrame.Angles(0, math.rad(deg * 0.37), 0), {
			Scale = Vector3.new(0.8, 0.8, 0.8),
			Shadows = false,
		})
		count += tuneLights(parts, true, CRYSTAL_RANGE, CRYSTAL_BRIGHTNESS)
	end
	-- small unlit crystals between the lights
	for _, deg in { 40, -40, 120, -120, 150, -150 } do
		decor(lights, "Current_Crystal_S", facingIn(polar(DRESS_OUTER - 1, deg + 4)), 1.1)
	end
	return count
end

local function buildPools(model: Model, dressing: Folder): { Vector3 }
	local pools = newFolder(model, "AddPools")
	local spots: { Vector3 } = {}
	local up = CFrame.Angles(0, 0, math.pi / 2)
	for i, deg in { 94, -94, 150, -150 } do
		local centre = polar(POOL_RADIUS, deg)
		table.insert(spots, centre)
		local pool = marker(pools, `Pool{i}`, CFrame.new(centre + Vector3.new(0, 0.5, 0)))
		pool:SetAttribute("Index", i)
		newPart(dressing, "PoolWater", Vector3.new(0.12, POOL_SIZE * 2, POOL_SIZE * 2), CFrame.new(centre + Vector3.new(0, 0.16, 0)) * up, {
			Material = Enum.Material.Glass,
			Color = POOL_WATER,
			Transparency = 0.25,
			Shape = Enum.PartType.Cylinder,
		})
		local ring = { "Rock_S", "Barnacles", "Anemone_Glow", "Rock_S", "Coral_Fan" }
		for k, name in ring do
			local a = math.rad(deg + 40 + k * 70)
			local pos = centre + Vector3.new(math.sin(a), 0, math.cos(a)) * (POOL_SIZE + 0.6)
			decor(dressing, name, facingOut(pos - centre) + centre, 0.7)
		end
	end
	return spots
end

local function buildBackdrop(geo: Folder)
	local back = newFolder(geo, "Backdrop")
	local apron = Vector3.new(0, APRON_TOP, 0)
	for _, spot in {
		{ Piece = "Cliff_A", R = 112, Deg = 150 },
		{ Piece = "Cliff_A", R = 112, Deg = -150 },
		{ Piece = "Cliff_B", R = 106, Deg = 72 },
		{ Piece = "Cliff_B", R = 106, Deg = -72 },
		{ Piece = "Cliff_C", R = 114, Deg = 112 },
		{ Piece = "Cliff_C", R = 114, Deg = -112 },
		{ Piece = "Rock_XL", R = 98, Deg = 38 },
		{ Piece = "Rock_XL", R = 98, Deg = -38 },
	} do
		local parts = place(back, spot.Piece, facingIn(polar(spot.R, spot.Deg) + apron), { Shadows = false, Collision = false })
		tuneLights(parts, false)
	end
	-- the ribs of something enormous, seen through the back arches
	local ribs = place(back, "Leviathan_Ribs", facingIn(polar(100, 180) + apron) * CFrame.new(-8, 0, 0), {
		Collision = false,
		Shadows = false,
	})
	tuneLights(ribs, false)
	for k = 0, 11 do
		local deg = 15 + k * 30
		decor(back, "Kelp_Tall", facingIn(polar(84 + (k % 3) * 3, deg) + apron), 1 + (k % 2) * 0.3)
	end
end

local function buildTemplate(root: Instance): (Model, { [string]: number })
	local model = Instance.new("Model")
	model.Name = GUARDIAN_ID
	model:SetAttribute("GuardianId", GUARDIAN_ID)
	model:SetAttribute("Purpose", "The Drowned Threshold, Brinewarden arena template (Tools.Floor1GuardianArena)")

	local origin = marker(model, "Origin", CFrame.identity, Vector3.new(1, 1, 1))
	local geo = newFolder(model, "Geometry")
	local dressing = newFolder(model, "Dressing")
	local tideLines = newFolder(model, "TideLines")
	local rng: Rng = { State = SEED }

	buildFloor(geo)
	local walls = buildWalls(geo, tideLines, dressing, rng)
	buildOuterRing(geo)
	local lights = buildGate(geo, model)
	buildColonnade(geo, dressing)
	lights += buildLights(geo)
	buildPools(model, dressing)
	buildBackdrop(geo)

	-- contract markers
	marker(model, "BossSpawn", facing(Vector3.new(0, 0.5, BOSS_SPAWN_Z), Vector3.zAxis))
	local spawns = newFolder(model, "PlayerSpawns")
	for i = 1, 8 do
		local deg = -SPAWN_ARC + (i - 1) * (2 * SPAWN_ARC / 7)
		local pos = polar(SPAWN_RADIUS, deg, 0.5)
		local p = marker(spawns, `Spawn{i}`, facing(pos, -Vector3.new(pos.X, 0, pos.Z)))
		p:SetAttribute("Index", i)
	end
	local water = newPart(model, "TideWater", Vector3.new(WATER_SIZE, WATER_THICKNESS, WATER_SIZE), CFrame.new(0, CALM_Y, 0), {
		Material = Enum.Material.Glass,
		Color = WATER,
		Transparency = 0.35,
	})
	water:SetAttribute("CalmY", CALM_Y)
	water:SetAttribute("HighY", HIGH_Y)
	water:SetAttribute("EbbY", EBB_Y)
	local zone = newPart(model, "PressureZone", PRESSURE_SIZE, CFrame.new(0, PRESSURE_Y, 0), { Transparency = 1 })
	zone:SetAttribute(Attributes.Names.Pressure, PRESSURE)
	CollectionService:AddTag(zone, Attributes.Tags.PressureZone)
	local bounds = marker(model, "Bounds", CFrame.identity, Vector3.new(BOUNDS_RADIUS * 2, 0.2, BOUNDS_RADIUS * 2))
	bounds:SetAttribute("Radius", BOUNDS_RADIUS)

	model.PrimaryPart = origin
	model.WorldPivot = CFrame.identity
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model.Parent = root
	return model, { Walls = walls, Lights = lights }
end

-- GATE MARKERS ----------------------------------------------------------------------------------------

local function buildGateMarkers(floor: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = GATE_FOLDER
	folder:SetAttribute("Purpose", "Brinewarden challenge prompt and return point (Tools.Floor1GuardianArena)")
	local prompt = marker(folder, "ChallengePrompt", facing(PROMPT_POSITION, -Vector3.xAxis), PROMPT_SIZE)
	prompt:SetAttribute(Attributes.Names.GuardianId, GUARDIAN_ID)
	prompt:SetAttribute("GatherRadius", Config.Mobs.Guardian.GatherRadius)
	CollectionService:AddTag(prompt, Attributes.Tags.GuardianGate)
	marker(folder, "Return", facing(RETURN_POSITION, -Vector3.xAxis))
	local glow = newPart(folder, "SealGlow", SEAL_GLOW_SIZE, CFrame.new(SEAL_GLOW_X, PLATEAU_Y + SEAL_GLOW_SIZE.Y / 2, 0), {
		Material = Enum.Material.Neon,
		Color = CURRENT,
		Transparency = 0.8,
	})
	local light = Instance.new("PointLight")
	light.Color = CURRENT
	light.Range = SEAL_GLOW_RANGE
	light.Brightness = SEAL_GLOW_BRIGHTNESS
	light.Shadows = false
	light.Parent = glow
	folder.Parent = floor
	return folder
end

-- API ---------------------------------------------------------------------------------------------------

function Arena.Apply(): { [string]: number }
	local ok, running = pcall(function(): boolean
		return RunService:IsRunning()
	end)
	assert(not (ok and running), "Apply in Edit mode")
	local floor = Workspace:FindFirstChild("Floor1")
	assert(floor and floor:FindFirstChild("Town"), "Existing Lowharbor required")
	assert(not floor:FindFirstChild(GATE_FOLDER), "Guardian gate already built; Undo before reapplying")
	local existing = ServerStorage:FindFirstChild(ARENAS_FOLDER)
	assert(not (existing and existing:FindFirstChild(GUARDIAN_ID)), "Brinewarden arena already built; Undo before reapplying")
	local kit = ServerStorage:FindFirstChild("SpireKit")
	assert(kit and kit:FindFirstChild("Templates"), "SpireKit templates missing (KitLibrary.Prepare)")

	local root: Instance
	if existing then
		root = existing
	else
		local f = Instance.new("Folder")
		f.Name = ARENAS_FOLDER
		f:SetAttribute("CreatedBy", CREATED_BY)
		f.Parent = ServerStorage
		root = f
	end
	local model, counts = buildTemplate(root)
	buildGateMarkers(floor)
	counts.Instances = #model:GetDescendants()
	return counts
end

function Arena.Undo()
	local floor = Workspace:FindFirstChild("Floor1")
	local gate = floor and floor:FindFirstChild(GATE_FOLDER)
	if gate then
		gate:Destroy()
	end
	local root = ServerStorage:FindFirstChild(ARENAS_FOLDER)
	local model = root and root:FindFirstChild(GUARDIAN_ID)
	if model then
		model:Destroy()
	end
	if root and root:GetAttribute("CreatedBy") == CREATED_BY and #root:GetChildren() == 0 then
		root:Destroy()
	end
end

return Arena
