--!strict
--[[
	Floor1Npcs (edit-time tool; never runs during play)
	Places the Phase 11 world markers for Floor 1 (docs/PHASE11_QUESTS.md, sections 2 and 3):

	  Workspace.Floor1.Npcs          one marker Part per NPC id (attribute NpcId, tag-free; NpcService
	                                 builds the bodies). The marker's LookVector is the direction the NPC
	                                 faces, which is toward where players approach. Everyone stands except
	                                 Fen, who walks the points of Npcs.Route_Fen (Part names "1".."N", also
	                                 attribute Order; the Fen marker sits on the route's bridge end).
	  Workspace.Floor1.QuestPoints   one Part per quest point (tag SpireQuestPoint, attributes PointId and
	                                 Radius): the tutorial path on the Docks quay, the town doors, the
	                                 fountain, the wild landmarks and the canal falls.

	All markers and points are anchored, invisible, non-colliding and CanQuery = false.

	How a spot is chosen
	  * Landmark fronts (Guild, Library, Rotunda, Cathedral, Barracks): start 10 studs outside the
	    landmark's keep-clear radius on the line toward the bay, walk inward until something blocks, and
	    stop in front of it. That is the doorstep, wherever the building actually ends.
	  * Every NPC then needs a clear 6 x 6 spot: no part (visible, or colliding) between 1.2 and 7.2 studs
	    above the ground may come within 1.5 studs (oriented-box test against every part, like
	    Floor1Courtyards), the ground must be flat and dry, and no canal. The search nudges outward up
	    to 12 studs, preferring the approach side.
	  * The tutorial arena is a clear 30 x 30 patch of the quay; no NPC may stand in it.
	  * y comes from Layout.Height + 0.1 (the analytic ground, as in Floor1Courtyards).

	Undo removes exactly Floor1.Npcs and Floor1.QuestPoints.

	Usage (Command Bar, Edit mode):
	    local N = require(game.ServerStorage.Tools.Floor1Npcs)
	    N.Apply()  -- build (refuses if already built)
	    N.Undo()   -- remove both folders
]]

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Layout = require(script.Parent.Layouts.Floor1)

local Npcs = {}

export type Options = {
	-- Ground height at (x, z), or nil when there is none. Defaults to Layout.Height.
	Ground: ((x: number, z: number) -> number?)?,
}

type Box = { CFrame: CFrame, Half: Vector3, MinX: number, MaxX: number, MinZ: number, MaxZ: number }
type Index = { [number]: { [number]: { Box } } }
type Ctx = { Index: Index, Ground: (x: number, z: number) -> number? }

-- NAMES -----------------------------------------------------------------------------------------

local NPC_FOLDER = "Npcs"
local POINT_FOLDER = "QuestPoints"
local ROUTE_PREFIX = "Route_"
local POINT_TAG = "SpireQuestPoint"
local CREATED_BY = "Floor1Npcs"

-- NUMBERS ---------------------------------------------------------------------------------------

local PI = math.pi
local CELL = 32 -- spatial hash cell
local MARKER_LIFT = 0.1 -- markers sit this far above the ground
local NPC_HALF = 3 -- the clear spot is 6 x 6
local NPC_MARGIN = 1.5 -- extra clearance around an NPC
local MAX_NUDGE = 12 -- how far a spot may move from its base
local NUDGE_STEP = 1.5
local NUDGE_ANGLES = 16
local CLEAR_LOW = 1.2 -- parts below this height above the ground are floor, not obstacles
local CLEAR_HEIGHT = 6
local FLAT_TOL = 0.9 -- ground height spread allowed across a spot
local DOOR_APPROACH = 10 -- the front search starts this far beyond a landmark's keep-clear radius
local DOOR_PAD = 2 -- the doorstep point stands this far out from the first blocked spot
local MAX_PART_SIZE = 400 -- backdrop slabs are skipped

-- The tutorial arena: a clear square of this size near the arrival waystone, found by scanning a
-- window around it for the clear patch nearest the preferred spot (waystone + offset).
local ARENA_SIZE = 30
local ARENA_PREFER = Vector2.new(30, 24)
local ARENA_WINDOW = 90 -- scan this far either side of the preferred spot
local ARENA_STEP = 2

-- The tutorial path along the quay: polar spots (r, a), north to south, ending at the arena.
local QUAY_PATH_R = 320
local QUAY_START_A = -0.43
local QUAY_MOVE_A = -0.36
local QUAY_SPRINT_A = -0.27
local PATH_NUDGE = 8

-- Fen's route: along the Market ring street across the north canal's bridge. Offsets are arc
-- lengths along the street from the canal's centre line (negative = north); the point at 0 is on the
-- bridge deck itself, at the terrace height.
local FEN_CANAL = 1 -- index into Layout.Canals
local FEN_STREET_R = 540
local FEN_OFFSETS = { -45, -26, 0, 26, 45 }
local FEN_NUDGE = 6
local BRIDGE_HALF = 13 -- canal half-width plus its walls: points this close are on the deck

local WILD_APPROACH_PUSH = 9 -- wild NPCs stand this far from their waystone, toward the road

local FALLS_R = 612 -- just in front of the Market band's upper wall
local MOUTH_R = 318

-- Point radii (studs).
local RADIUS: { [string]: number } = {
	TutorialStart = 6,
	TutorialMove = 6,
	TutorialSprint = 10,
	TutorialArena = ARENA_SIZE / 2,
	TutorialExit = 10,
	GuildSteps = 14,
	RotundaDoor = 12,
	LibraryDoor = 10,
	CathedralDoor = 12,
	MarketFountain = 18,
	OldWharf = 25,
	BrinehulkLagoon = 25,
	CisternMouth = 18,
	GateApproach = 20,
	CanalNorthFalls = 18,
	CanalSouthFalls = 18,
	CanalMouth = 16,
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

-- Every part in the world a standing NPC must not touch. Pure trigger volumes (invisible and
-- non-colliding) and huge backdrop slabs are left out; so are earlier runs of this tool.
local function buildIndex(skip: { Instance }): Index
	local index: Index = {}
	for _, d in Workspace:GetDescendants() do
		if not d:IsA("BasePart") or d:IsA("Terrain") then
			continue
		end
		local skipped = false
		for _, s in skip do
			if d:IsDescendantOf(s) then
				skipped = true
				break
			end
		end
		if skipped then
			continue
		end
		if d.Transparency >= 1 and not d.CanCollide then
			continue
		end
		if d.Size.X > MAX_PART_SIZE or d.Size.Z > MAX_PART_SIZE then
			continue
		end
		insert(index, boxOf(d.CFrame, d.Size))
	end
	return index
end

-- PLACEMENT -------------------------------------------------------------------------------------

-- Is a square of half-size `half` (plus `margin` of clearance) at (x, z) flat, dry, off the canals
-- and free of obstacles between CLEAR_LOW and CLEAR_LOW + CLEAR_HEIGHT above the ground?
local function spotOk(ctx: Ctx, x: number, z: number, half: number, margin: number): boolean
	local gy = ctx.Ground(x, z)
	if not gy then
		return false
	end
	for i = 0, 4 do
		local px, pz = x, z
		if i > 0 then
			px += if i % 2 == 1 then half else -half
			pz += if i <= 2 then half else -half
		end
		local h = ctx.Ground(px, pz)
		if not h or math.abs(h - gy) > FLAT_TOL or Layout.Water(px, pz, h) ~= nil then
			return false
		end
		if Layout.TownSurface(px, pz) == "Canal" then
			return false
		end
	end
	local reach = (half + margin) * 2
	local center = Vector3.new(x, gy + CLEAR_LOW + CLEAR_HEIGHT / 2, z)
	return not blocked(ctx.Index, boxOf(CFrame.new(center), Vector3.new(reach, CLEAR_HEIGHT, reach)))
end

-- The nearest clear 6 x 6 spot to `base` within `maxNudge` studs; ties go to the one closest to
-- `bias` (the side players approach from).
local function findSpot(ctx: Ctx, base: Vector2, bias: Vector2, maxNudge: number): Vector2?
	local ring = 0
	while ring <= maxNudge + 1e-6 do
		local candidates: { Vector2 } = {}
		if ring == 0 then
			table.insert(candidates, base)
		else
			for i = 0, NUDGE_ANGLES - 1 do
				local a = i / NUDGE_ANGLES * 2 * PI
				table.insert(candidates, base + Vector2.new(math.cos(a), math.sin(a)) * ring)
			end
		end
		table.sort(candidates, function(p: Vector2, q: Vector2): boolean
			return (p - bias).Magnitude < (q - bias).Magnitude
		end)
		for _, p in candidates do
			if spotOk(ctx, p.X, p.Y, NPC_HALF, NPC_MARGIN) then
				return p
			end
		end
		ring += NUDGE_STEP
	end
	return nil
end

-- Walking inward from outside a landmark along `dir`, the last clear spot before the first obstacle.
local function doorStep(ctx: Ctx, center: Vector2, dir: Vector2, reach: number, lateral: number): Vector2
	local perp = Vector2.new(-dir.Y, dir.X)
	local t = reach
	local last: Vector2? = nil
	while t >= 0 do
		local p = center + dir * t + perp * lateral
		if spotOk(ctx, p.X, p.Y, NPC_HALF, NPC_MARGIN) then
			last = p
		elseif last then
			break
		end
		t -= 1
	end
	assert(last, "no doorstep found near " .. tostring(center))
	return last + dir * DOOR_PAD
end

local function toBay(p: Vector2): Vector2
	return (Layout.Bay - p).Unit
end

-- The yaw that makes a part's LookVector point along (dx, dz).
local function yawFacing(dir: Vector2): number
	return math.atan2(-dir.X, -dir.Y)
end

local function polarSpot(r: number, a: number): Vector2
	return Layout.FromPolar(r, a)
end

-- PARTS -----------------------------------------------------------------------------------------

local function newMarker(parent: Instance, name: string, ground: number, at: Vector2, face: Vector2?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(2, 1, 2)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	local yaw = if face then yawFacing(face) else 0
	part.CFrame = CFrame.new(at.X, ground + MARKER_LIFT, at.Y) * CFrame.Angles(0, yaw, 0)
	part:SetAttribute("CreatedBy", CREATED_BY)
	part.Parent = parent
	return part
end

local function folder(name: string, purpose: string, parent: Instance?): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f:SetAttribute("Purpose", purpose)
	f.Parent = parent
	return f
end

-- BUILD -----------------------------------------------------------------------------------------

function Npcs.Apply(options: Options?): { [string]: number }
	local opts: Options = options or {}
	local floor = Workspace:FindFirstChild("Floor1")
	assert(floor and floor:FindFirstChild("Town"), "Existing Lowharbor required")
	assert(not floor:FindFirstChild(NPC_FOLDER) and not floor:FindFirstChild(POINT_FOLDER), "Npcs already built; Undo before reapplying")
	local ground: (x: number, z: number) -> number? = opts.Ground or Layout.Height

	local ctx: Ctx = { Index = buildIndex({}), Ground = ground }
	local function groundY(p: Vector2): number
		local h = ground(p.X, p.Y)
		assert(h, "no ground at " .. tostring(p))
		return h
	end
	local function reserve(p: Vector2, half: number)
		local gy = groundY(p)
		insert(ctx.Index, boxOf(CFrame.new(p.X, gy + CLEAR_LOW + CLEAR_HEIGHT / 2, p.Y), Vector3.new(half * 2, CLEAR_HEIGHT, half * 2)))
	end
	local function spot(label: string, base: Vector2, bias: Vector2, maxNudge: number): Vector2
		local p = findSpot(ctx, base, bias, maxNudge)
		assert(p, "no clear spot for " .. label .. " near " .. tostring(base))
		reserve(p, NPC_HALF + NPC_MARGIN)
		return p
	end

	local npcRoot = folder(NPC_FOLDER, "NPC markers (Tools.Floor1Npcs); LookVector = facing", nil)
	local pointRoot = folder(POINT_FOLDER, "Quest points (Tools.Floor1Npcs)", nil)

	local npcCount = 0
	local pointCount = 0

	local function npc(id: string, at: Vector2, face: Vector2)
		local m = newMarker(npcRoot, id, groundY(at), at, face)
		m:SetAttribute("NpcId", id)
		npcCount += 1
	end
	local function point(id: string, at: Vector2, y: number?)
		local radius = RADIUS[id]
		assert(radius, "no radius for " .. id)
		local gy = y or math.max(groundY(at), Layout.Sea)
		local p = newMarker(pointRoot, id, gy, at, nil)
		p:SetAttribute("PointId", id)
		p:SetAttribute("Radius", radius)
		CollectionService:AddTag(p, POINT_TAG)
		pointCount += 1
	end

	-- THE ARRIVAL QUAY ------------------------------------------------------------------------
	local rest = Layout.Waystones[1].At -- F1_ClimbersRest
	assert(Layout.Waystones[1].Id == "F1_ClimbersRest", "waystone order changed")

	-- the arena: the clear 30 x 30 quay patch nearest the preferred spot
	local arenaWant = rest + ARENA_PREFER
	local arena: Vector2? = nil
	local arenaDist = math.huge
	local ox = -ARENA_WINDOW
	while ox <= ARENA_WINDOW do
		local oz = -ARENA_WINDOW
		while oz <= ARENA_WINDOW do
			local p = arenaWant + Vector2.new(ox, oz)
			local d = (p - arenaWant).Magnitude
			if d < arenaDist and spotOk(ctx, p.X, p.Y, ARENA_SIZE / 2, 0) then
				arena = p
				arenaDist = d
			end
			oz += ARENA_STEP
		end
		ox += ARENA_STEP
	end
	assert(arena, "no clear arena patch on the quay")
	reserve(arena, ARENA_SIZE / 2)
	point("TutorialArena", arena, nil)

	local brannocBase = rest + Vector2.new(-2, -13)
	local brannoc = spot("Brannoc", brannocBase, arena, MAX_NUDGE)
	npc("Brannoc", brannoc, (arena - brannoc).Unit)
	local exitAt = brannoc + (arena - brannoc).Unit * 5
	point("TutorialExit", exitAt, nil)

	local pellBase = (brannoc + arena) / 2 + Vector2.new(4, 0)
	local pell = spot("Pell", pellBase, arena, MAX_NUDGE)
	npc("Pell", pell, (arena - pell).Unit)

	-- the path, north to south
	local function pathPoint(id: string, a: number)
		local base = polarSpot(QUAY_PATH_R, a)
		local p = findSpot(ctx, base, arena, PATH_NUDGE)
		assert(p, "no clear spot for " .. id)
		point(id, p, nil)
	end
	pathPoint("TutorialStart", QUAY_START_A)
	pathPoint("TutorialMove", QUAY_MOVE_A)
	pathPoint("TutorialSprint", QUAY_SPRINT_A)

	-- THE TOWN ------------------------------------------------------------------------------
	local function landmarkFront(name: string, lateral: number): (Vector2, Vector2)
		local lm = Layout.Landmarks[name]
		local center = polarSpot(lm.R, lm.A)
		local dir = toBay(center)
		return doorStep(ctx, center, dir, lm.Clear + DOOR_APPROACH, lateral), dir
	end

	local guild, guildDir = landmarkFront("ClimbersGuild", 0)
	point("GuildSteps", guild, nil)
	local ysolde = spot("Ysolde", guild + Vector2.new(-guildDir.Y, guildDir.X) * 10, guild + guildDir * 6, MAX_NUDGE)
	npc("Ysolde", ysolde, guildDir)

	local rotunda = landmarkFront("AttunementShrine", 0)
	point("RotundaDoor", rotunda, nil)

	local library, libraryDir = landmarkFront("LibraryOfFloors", 0)
	point("LibraryDoor", library, nil)
	local ilse = spot("Ilse", library + Vector2.new(-libraryDir.Y, libraryDir.X) * 5, library + libraryDir * 6, MAX_NUDGE)
	npc("Ilse", ilse, libraryDir)

	local cathedral, cathedralDir = landmarkFront("Cathedral", 0)
	point("CathedralDoor", cathedral, nil)
	local caddith = spot("Caddith", cathedral + Vector2.new(-cathedralDir.Y, cathedralDir.X) * 5, cathedral + cathedralDir * 6, MAX_NUDGE)
	npc("Caddith", caddith, cathedralDir)

	local barracks, barracksDir = landmarkFront("Barracks", 0)
	local maren = spot("Maren", barracks, barracks + barracksDir * 6, MAX_NUDGE)
	npc("Maren", maren, barracksDir)

	local plaza = polarSpot(Layout.Plaza.Radius, Layout.Plaza.Angle)
	point("MarketFountain", plaza, nil)
	local tobinBase = plaza + Vector2.new(-17, 14)
	local tobin = spot("Tobin", tobinBase, plaza + Vector2.new(-40, 0), MAX_NUDGE)
	npc("Tobin", tobin, toBay(tobin))

	-- Fen and his route along the north canal's south bank
	local canalA = Layout.Canals[FEN_CANAL]
	local marketBand = Layout.BandAt(FEN_STREET_R)
	assert(marketBand, "Market band missing")
	local routeRoot = folder(ROUTE_PREFIX .. "Fen", "Fen's walk (Tools.Floor1Npcs); ordered points", npcRoot)
	local routePoints: { Vector2 } = {}
	local routeY: { number } = {}
	local bridgeIndex = 1
	for i, offset in FEN_OFFSETS do
		local base = polarSpot(FEN_STREET_R, canalA + offset / FEN_STREET_R)
		if math.abs(offset) < BRIDGE_HALF then
			table.insert(routePoints, base)
			table.insert(routeY, marketBand.Y)
			bridgeIndex = i
		else
			local p = findSpot(ctx, base, plaza, FEN_NUDGE)
			assert(p, "no clear spot on Fen's route at offset " .. offset)
			reserve(p, NPC_HALF)
			table.insert(routePoints, p)
			table.insert(routeY, groundY(p))
		end
	end
	for i, p in routePoints do
		local face = if i < #routePoints then (routePoints[i + 1] - p).Unit else (p - routePoints[i - 1]).Unit
		local m = newMarker(routeRoot, tostring(i), routeY[i], p, face)
		m:SetAttribute("Order", i)
	end
	local fenFace = (routePoints[bridgeIndex + 1] - routePoints[bridgeIndex]).Unit
	local fen = newMarker(npcRoot, "Fen", routeY[bridgeIndex], routePoints[bridgeIndex], fenFace)
	fen:SetAttribute("NpcId", "Fen")
	npcCount += 1

	-- THE WILD ----------------------------------------------------------------------------
	local function waystoneAt(id: string): Vector2
		for _, w in Layout.Waystones do
			if w.Id == id then
				return w.At
			end
		end
		error("no waystone " .. id)
	end
	local function wildNpc(id: string, waystone: Vector2, toward: Vector2)
		local dir = (toward - waystone).Unit
		local p = spot(id, waystone + dir * WILD_APPROACH_PUSH, toward, MAX_NUDGE)
		npc(id, p, dir)
	end
	local coastEnd = Layout.Roads[4].Points[#Layout.Roads[4].Points]
	local northEnd = Layout.Roads[3].Points[#Layout.Roads[3].Points]
	assert(Layout.Roads[4].Name == "CoastRoad" and Layout.Roads[3].Name == "NorthRoad", "road order changed")
	wildNpc("Osk", waystoneAt("F1_ReedwardenPost"), coastEnd)
	wildNpc("Hesk", waystoneAt("F1_RustwoodCamp"), northEnd)

	point("OldWharf", Layout.Points.OldWharf, nil)
	point("BrinehulkLagoon", Layout.Points.BrinehulkDeep, nil)
	point("CisternMouth", waystoneAt("F1_CisternMouth"), nil)
	point("GateApproach", waystoneAt("F1_GateApproach"), nil)

	-- THE CANALS: points on the canals' centre lines; y is the terrace the banks stand on
	local fallsBand = Layout.BandAt(FALLS_R)
	local mouthBand = Layout.BandAt(MOUTH_R)
	assert(fallsBand and mouthBand, "canal bands missing")
	point("CanalNorthFalls", polarSpot(FALLS_R, Layout.Canals[1]), fallsBand.Y)
	point("CanalSouthFalls", polarSpot(FALLS_R, Layout.Canals[2]), fallsBand.Y)
	point("CanalMouth", polarSpot(MOUTH_R, Layout.Canals[2]), mouthBand.Y)

	npcRoot:SetAttribute("Count", npcCount)
	pointRoot:SetAttribute("Count", pointCount)
	npcRoot.Parent = floor
	pointRoot.Parent = floor
	return { Npcs = npcCount, RoutePoints = #routePoints, QuestPoints = pointCount }
end

function Npcs.Undo()
	local floor = Workspace:FindFirstChild("Floor1")
	if not floor then
		return
	end
	for _, name in { NPC_FOLDER, POINT_FOLDER } do
		local root = floor:FindFirstChild(name)
		if root then
			root:Destroy()
		end
	end
end

return Npcs
