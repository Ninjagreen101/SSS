--!strict
-- InteriorPlanner: furnishes one storey of a building by building type.
-- Furniture is placed against walls and in the room centre on a 1-stud
-- occupancy grid that keeps the door corridor and the stair entrance clear,
-- so every generated interior can be walked through.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Rng = require(Shared.Util.Rng)
local Geom = require(Shared.Util.Geom)
local Config = require(Shared.Config)
local KitManifest = require(Shared.Data.KitManifest)
local KitAssemblies = require(Shared.Data.KitAssemblies)

local Plan = require(script.Parent.Plan)

type PlanNode = Types.PlanNode
type Rng = Rng.Rng

local B = Config.World.Buildings

export type Room = {
	x0: number,
	x1: number,
	z0: number, -- front (door side)
	z1: number, -- back
	y: number,
	ceiling: number,
	doorX: number?,
	stair: { x0: number, x1: number, z0: number, z1: number }?,
	stairEntryX: number?,
	stairEntryZ: number?,
	lit: boolean,
}

-- Furniture request: `item` is a kit piece or assembly name.
type Want = {
	item: string,
	at: string, -- "wall" | "back" | "center" | "corner"
	count: number,
	chance: number?,
	chairs: number?, -- for tables: chairs/stools around it
	stool: boolean?,
}

local SETS: { [string]: { ground: { Want }, upper: { Want } } } = {
	house = {
		ground = {
			{ item = "table", at = "center", count = 1, chairs = 4 },
			{ item = "rug", at = "center", count = 1, chance = 0.6 },
			{ item = "bookshelf_full", at = "wall", count = 1, chance = 0.6 },
			{ item = "cookpot", at = "corner", count = 1, chance = 0.5 },
			{ item = "barrel", at = "wall", count = 2 },
			{ item = "crate_s", at = "corner", count = 1 },
			{ item = "bench", at = "wall", count = 1, chance = 0.5 },
			{ item = "potted_plant", at = "corner", count = 1, chance = 0.6 },
		},
		upper = {
			{ item = "bed", at = "back", count = 2 },
			{ item = "chest", at = "wall", count = 1 },
			{ item = "rug", at = "center", count = 1, chance = 0.7 },
			{ item = "table_round", at = "center", count = 1, chairs = 2, chance = 0.5 },
			{ item = "bookshelf_full", at = "wall", count = 1, chance = 0.4 },
			{ item = "potted_plant", at = "corner", count = 1, chance = 0.5 },
		},
	},
	shop = {
		ground = {
			{ item = "counter", at = "back", count = 1 },
			{ item = "bookshelf_full", at = "wall", count = 2 },
			{ item = "crate_l", at = "corner", count = 1 },
			{ item = "crate_s", at = "wall", count = 2 },
			{ item = "barrel", at = "wall", count = 2 },
			{ item = "rug", at = "center", count = 1, chance = 0.5 },
		},
		upper = {
			{ item = "bed", at = "back", count = 1 },
			{ item = "crate_l", at = "corner", count = 2 },
			{ item = "chest", at = "wall", count = 1 },
			{ item = "table", at = "center", count = 1, chairs = 2 },
		},
	},
	tavern = {
		ground = {
			{ item = "counter", at = "wall", count = 1 },
			{ item = "barrel", at = "wall", count = 4 },
			{ item = "table_round", at = "center", count = 3, chairs = 3, stool = true },
			{ item = "cookpot", at = "corner", count = 1 },
			{ item = "bench", at = "wall", count = 2 },
		},
		upper = {
			{ item = "bed", at = "back", count = 3 },
			{ item = "chest", at = "wall", count = 2 },
			{ item = "rug", at = "center", count = 1 },
		},
	},
	smithy = {
		ground = {
			{ item = "forge", at = "back", count = 1 },
			{ item = "anvil", at = "center", count = 1 },
			{ item = "weapon_rack_full", at = "wall", count = 2 },
			{ item = "barrel", at = "corner", count = 2 },
			{ item = "crate_l", at = "wall", count = 1 },
			{ item = "chest", at = "wall", count = 1 },
		},
		upper = {
			{ item = "bed", at = "back", count = 1 },
			{ item = "weapon_rack_full", at = "wall", count = 1 },
			{ item = "chest", at = "wall", count = 1 },
		},
	},
	library = {
		ground = {
			{ item = "bookshelf_full", at = "wall", count = 6 },
			{ item = "table", at = "center", count = 2, chairs = 4 },
			{ item = "rug", at = "center", count = 1 },
		},
		upper = {
			{ item = "bookshelf_full", at = "wall", count = 5 },
			{ item = "table", at = "center", count = 1, chairs = 2 },
			{ item = "chest", at = "corner", count = 1 },
		},
	},
	barracks = {
		ground = {
			{ item = "weapon_rack_full", at = "wall", count = 2 },
			{ item = "table", at = "center", count = 1, chairs = 4 },
			{ item = "chest", at = "wall", count = 2 },
			{ item = "barrel", at = "corner", count = 2 },
		},
		upper = {
			{ item = "bed", at = "wall", count = 5 },
			{ item = "chest", at = "wall", count = 3 },
		},
	},
	warehouse = {
		ground = {
			{ item = "crate_l", at = "wall", count = 5 },
			{ item = "crate_s", at = "corner", count = 3 },
			{ item = "barrel", at = "wall", count = 4 },
			{ item = "cart", at = "center", count = 1, chance = 0.6 },
			{ item = "rope_coil", at = "corner", count = 2 },
			{ item = "fishing_net", at = "center", count = 1, chance = 0.5 },
		},
		upper = {
			{ item = "crate_l", at = "wall", count = 4 },
			{ item = "barrel", at = "wall", count = 2 },
			{ item = "fishing_net", at = "center", count = 1 },
		},
	},
	hall = {
		ground = {
			{ item = "table", at = "center", count = 4, chairs = 4 },
			{ item = "bookshelf_full", at = "wall", count = 2 },
			{ item = "weapon_rack_full", at = "wall", count = 2 },
			{ item = "bench", at = "wall", count = 4 },
		},
		upper = {
			{ item = "bookshelf_full", at = "wall", count = 6 },
			{ item = "table", at = "center", count = 2, chairs = 4 },
			{ item = "chest", at = "corner", count = 2 },
		},
	},
	ruin = {
		ground = {
			{ item = "rubble_pile", at = "center", count = 2 },
			{ item = "crate_s", at = "corner", count = 1, chance = 0.5 },
			{ item = "barrel", at = "wall", count = 1, chance = 0.5 },
		},
		upper = {
			{ item = "rubble_pile", at = "center", count = 1 },
		},
	},
}

local InteriorPlanner = {}

-- footprint {width, depth} of an item in its own frame (front = -Z)
local function footprintOf(item: string): (number, number, number, number)
	local a = KitAssemblies[item]
	if a then
		local first = KitManifest[a.parts[1].kit]
		local cx = if first then first.center[1] else 0
		local cz = if first then first.center[3] else 0
		return a.footprint[1], a.footprint[2], cx, cz
	end
	local m = KitManifest[item]
	assert(m, "unknown furniture " .. item)
	return m.size[1], m.size[3], m.center[1], m.center[3]
end

type Grid = {
	x0: number,
	z0: number,
	nx: number,
	nz: number,
	cells: { boolean },
}

local function newGrid(room: Room): Grid
	local nx = math.max(1, math.floor(room.x1 - room.x0))
	local nz = math.max(1, math.floor(room.z1 - room.z0))
	return { x0 = room.x0, z0 = room.z0, nx = nx, nz = nz, cells = table.create(nx * nz, false) }
end

local function rectCells(g: Grid, x0: number, x1: number, z0: number, z1: number, fn: (i: number) -> boolean): boolean
	local ia = math.floor(x0 - g.x0)
	local ib = math.ceil(x1 - g.x0) - 1
	local ja = math.floor(z0 - g.z0)
	local jb = math.ceil(z1 - g.z0) - 1
	if ia < 0 or ja < 0 or ib >= g.nx or jb >= g.nz then
		return false
	end
	for j = ja, jb do
		for i = ia, ib do
			if not fn(j * g.nx + i + 1) then
				return false
			end
		end
	end
	return true
end

local function isFree(g: Grid, x0: number, x1: number, z0: number, z1: number): boolean
	return rectCells(g, x0, x1, z0, z1, function(i: number): boolean
		return not g.cells[i]
	end)
end

local function block(g: Grid, x0: number, x1: number, z0: number, z1: number)
	local ia = math.max(0, math.floor(x0 - g.x0))
	local ib = math.min(g.nx - 1, math.ceil(x1 - g.x0) - 1)
	local ja = math.max(0, math.floor(z0 - g.z0))
	local jb = math.min(g.nz - 1, math.ceil(z1 - g.z0) - 1)
	for j = ja, jb do
		for i = ia, ib do
			g.cells[j * g.nx + i + 1] = true
		end
	end
end

local function blockPath(g: Grid, ax: number, az: number, bx: number, bz: number, width: number)
	local len = Geom.dist2(ax, az, bx, bz)
	local steps = math.max(1, math.ceil(len))
	for k = 0, steps do
		local t = k / steps
		local x, z = ax + (bx - ax) * t, az + (bz - az) * t
		block(g, x - width / 2, x + width / 2, z - width / 2, z + width / 2)
	end
end

local function place(node: PlanNode, item: string, x: number, y: number, z: number, ry: number, rng: Rng)
	if KitAssemblies[item] then
		Plan.assembly(node, Plan.frame(0, 0, 0, 0, 1), item, x, y, z, ry, {
			color = if item == "bed" then rng:pick({ "Linen", "ClothRed", "ClothTeal", "ClothNavy" }) else nil,
		})
	else
		Plan.piece(node, item, x, y, z, ry, {
			color = if item == "rug" then rng:pick({ "ClothRed", "ClothTeal", "ClothNavy", "ClothOchre" }) else nil,
		})
	end
end

type Candidate = { cx: number, cz: number, ry: number, ex: number, ez: number }

-- Candidate bbox centres for an item of size (fw, fd) at a given location kind.
local function candidates(room: Room, at: string, fw: number, fd: number, rng: Rng): { Candidate }
	local out: { Candidate } = {}
	local function along(axisLen: number, fn: (t: number) -> ())
		local n = math.max(1, math.floor(axisLen / 2))
		local order = {}
		for i = 0, n do
			table.insert(order, i / n)
		end
		rng:shuffle(order)
		for _, t in order do
			fn(t)
		end
	end
	local W, D = room.x1 - room.x0, room.z1 - room.z0
	if at == "back" or at == "wall" then
		along(W - fw, function(t: number)
			table.insert(out, { cx = room.x0 + fw / 2 + t * (W - fw), cz = room.z1 - fd / 2, ry = 0, ex = fw, ez = fd })
		end)
	end
	if at == "wall" then
		along(D - fw, function(t: number)
			local cz = room.z0 + fw / 2 + t * (D - fw)
			table.insert(out, { cx = room.x0 + fd / 2, cz = cz, ry = -math.pi / 2, ex = fd, ez = fw })
			table.insert(out, { cx = room.x1 - fd / 2, cz = cz, ry = math.pi / 2, ex = fd, ez = fw })
		end)
		rng:shuffle(out)
	end
	if at == "corner" then
		for _, c in { { 0, 1 }, { 1, 1 }, { 0, 0 }, { 1, 0 } } do
			local cx = if c[1] == 0 then room.x0 + fw / 2 + 0.2 else room.x1 - fw / 2 - 0.2
			local cz = if c[2] == 1 then room.z1 - fd / 2 - 0.2 else room.z0 + fd / 2 + 0.2
			table.insert(out, { cx = cx, cz = cz, ry = if c[2] == 1 then 0 else math.pi, ex = fw, ez = fd })
		end
		rng:shuffle(out)
	end
	if at == "center" then
		local mx, mz = (room.x0 + room.x1) / 2, (room.z0 + room.z1) / 2
		local spots = {}
		for i = -3, 3 do
			for j = -3, 3 do
				table.insert(spots, { mx + i * (W / 8), mz + j * (D / 8) })
			end
		end
		table.sort(spots, function(a: { number }, b: { number }): boolean
			return (a[1] - mx) ^ 2 + (a[2] - mz) ^ 2 < (b[1] - mx) ^ 2 + (b[2] - mz) ^ 2
		end)
		for _, sp in spots do
			local rot = rng:chance(0.3)
			table.insert(out, {
				cx = sp[1],
				cz = sp[2],
				ry = if rot then math.pi / 2 else 0,
				ex = if rot then fd else fw,
				ez = if rot then fw else fd,
			})
		end
	end
	return out
end

function InteriorPlanner.furnish(node: PlanNode, room: Room, kind: string, storey: number, rng: Rng)
	local set = SETS[kind] or SETS.house
	local wants: { Want } = if storey == 0 then set.ground else set.upper
	local g = newGrid(room)

	-- keep the stair cell, its entrance and the door corridor clear
	if room.stair then
		local s = room.stair
		block(g, s.x0 - 0.5, s.x1 + 0.5, s.z0 - 0.5, s.z1 + 0.5)
	end
	local mx, mz = (room.x0 + room.x1) / 2, (room.z0 + room.z1) / 2
	if room.doorX then
		blockPath(g, room.doorX, room.z0, room.doorX, room.z0 + 5, 6)
		blockPath(g, room.doorX, room.z0 + 4, mx, mz, 3.5)
	end
	if room.stairEntryX and room.stairEntryZ then
		blockPath(g, mx, mz, room.stairEntryX, (room.stairEntryZ :: number) - 1.5, 3.5)
	end

	for _, want in wants do
		if want.chance and not rng:chance(want.chance) then
			continue
		end
		local fw, fd, cx0, cz0 = footprintOf(want.item)
		local placedCount = 0
		for _, c in candidates(room, want.at, fw, fd, rng) do
			if placedCount >= want.count then
				break
			end
			local pad = if want.item == "rug" then 0 else 0.4
			local extraZ = if want.chairs then 2.6 else 0
			local extraX = if want.chairs then 1.2 else 0
			local ex = c.ex + (if c.ry == 0 or c.ry == math.pi then extraX else extraZ) * 2
			local ez = c.ez + (if c.ry == 0 or c.ry == math.pi then extraZ else extraX) * 2
			local rugOk = want.item == "rug"
			if rugOk or isFree(g, c.cx - ex / 2 - pad, c.cx + ex / 2 + pad, c.cz - ez / 2 - pad, c.cz + ez / 2 + pad) then
				-- origin so that the rotated bbox centre lands on (cx, cz)
				local ox, oz = Geom.rotate(cx0, cz0, c.ry)
				local x, z = c.cx - ox, c.cz - oz
				place(node, want.item, x, room.y, z, c.ry, rng)
				if not rugOk then
					block(g, c.cx - ex / 2, c.cx + ex / 2, c.cz - ez / 2, c.cz + ez / 2)
				end
				if want.chairs then
					local seat = if want.stool then "stool" else "chair"
					local n = want.chairs :: number
					local halfLong = if want.item == "table_round" then 2.6 else 1.6
					local spots = if want.item == "table_round"
						then { { 0, -2.9, 0 }, { 2.6, 1.4, -2.1 }, { -2.6, 1.4, 2.1 }, { 0, 2.9, math.pi } }
						else { { -halfLong, -2.7, 0 }, { halfLong, -2.7, 0 }, { -halfLong, 2.7, math.pi }, { halfLong, 2.7, math.pi } }
					for k = 1, math.min(n, #spots) do
						local sp = spots[k]
						local sx, sz = Geom.rotate(sp[1], sp[2], c.ry)
						Plan.piece(node, seat, c.cx + sx, room.y, c.cz + sz, c.ry + sp[3] + rng:range(-0.25, 0.25), {})
					end
				end
				placedCount += 1
			end
		end
	end

	-- a hanging lantern lights ground floors; upper rooms rely on window glow
	if room.lit then
		local lx = mx + rng:range(-1.5, 1.5)
		local lz = mz + rng:range(-1.5, 1.5)
		Plan.assembly(node, Plan.frame(0, 0, 0, 0, 1), "hanging_lantern", lx, room.ceiling - 0.3, lz, 0, {})
		-- the hanging lantern's own light uses Config ranges for interiors
		local last = node.lights[#node.lights]
		if last then
			last.range = B.InteriorLightRange
			last.brightness = B.InteriorLightBrightness
		end
	end
end

return InteriorPlanner
