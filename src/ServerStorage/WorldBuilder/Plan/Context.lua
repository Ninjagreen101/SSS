--!strict
-- Shared planning context for one floor: everything placed so far (lots,
-- landmarks, plazas), every street and canal corridor, and the terrain height
-- function. Spatial hashing keeps clearance queries fast on 3000-stud floors.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Geom = require(Shared.Util.Geom)

type OBB = Types.OBB
type Vec3 = Types.Vec3
type FloorDef = Types.FloorDef

local CELL = 64

export type Corridor = {
	id: string,
	points: { Vec3 }, -- {x, y, z}
	width: number,
	kind: string, -- "street" | "canal" | "path"
	main: boolean,
}

type Sample = { x: number, z: number, r: number, corridor: Corridor }

export type Context = {
	floor: FloorDef,
	obbs: { OBB },
	obbGrid: { [string]: { number } },
	samples: { [string]: { Sample } },
	corridors: { Corridor },
	circles: { { number } }, -- {x, z, r}
	height: (x: number, z: number) -> number,
}

local Context = {}

local function key(i: number, j: number): string
	return i .. ":" .. j
end

function Context.new(floor: FloorDef, height: (x: number, z: number) -> number): Context
	return {
		floor = floor,
		obbs = {},
		obbGrid = {},
		samples = {},
		corridors = {},
		circles = {},
		height = height,
	}
end

local function obbCells(o: OBB): (number, number, number, number)
	local r = math.sqrt(o.hw * o.hw + o.hd * o.hd)
	return math.floor((o.x - r) / CELL), math.floor((o.x + r) / CELL), math.floor((o.z - r) / CELL), math.floor((o.z + r) / CELL)
end

function Context.addObb(ctx: Context, o: OBB)
	table.insert(ctx.obbs, o)
	local idx = #ctx.obbs
	local i0, i1, j0, j1 = obbCells(o)
	for i = i0, i1 do
		for j = j0, j1 do
			local k = key(i, j)
			local list = ctx.obbGrid[k]
			if not list then
				list = {}
				ctx.obbGrid[k] = list
			end
			table.insert(list, idx)
		end
	end
end

function Context.addCircle(ctx: Context, x: number, z: number, r: number)
	table.insert(ctx.circles, { x, z, r })
	Context.addObb(ctx, { x = x, z = z, hw = r * 0.92, hd = r * 0.92, ry = math.pi / 4 })
	Context.addObb(ctx, { x = x, z = z, hw = r * 0.92, hd = r * 0.92, ry = 0 })
end

function Context.addCorridor(ctx: Context, c: Corridor)
	table.insert(ctx.corridors, c)
	for _, s in Geom.samplePolyline(c.points, 4, 3) do
		local k = key(math.floor(s.x / CELL), math.floor(s.z / CELL))
		local list = ctx.samples[k]
		if not list then
			list = {}
			ctx.samples[k] = list
		end
		table.insert(list, { x = s.x, z = s.z, r = c.width / 2, corridor = c })
	end
end

-- Distance from a point to the nearest corridor edge (negative = inside).
function Context.corridorClearance(ctx: Context, x: number, z: number, kinds: { [string]: boolean }?): (number, Corridor?)
	local best = math.huge
	local which: Corridor? = nil
	local ci, cj = math.floor(x / CELL), math.floor(z / CELL)
	for i = ci - 1, ci + 1 do
		for j = cj - 1, cj + 1 do
			local list = ctx.samples[key(i, j)]
			if list then
				for _, s in list do
					if kinds == nil or (kinds :: { [string]: boolean })[s.corridor.kind] then
						local d = Geom.dist2(x, z, s.x, s.z) - s.r
						if d < best then
							best = d
							which = s.corridor
						end
					end
				end
			end
		end
	end
	return best, which
end

function Context.obbBlocked(ctx: Context, o: OBB, margin: number): boolean
	local i0, i1, j0, j1 = obbCells(o)
	local seen: { [number]: boolean } = {}
	for i = i0, i1 do
		for j = j0, j1 do
			local list = ctx.obbGrid[key(i, j)]
			if list then
				for _, idx in list do
					if not seen[idx] then
						seen[idx] = true
						if Geom.obbOverlap(o, ctx.obbs[idx], margin) then
							return true
						end
					end
				end
			end
		end
	end
	return false
end

-- Full clearance test for a lot or prop footprint.
function Context.blocked(ctx: Context, o: OBB, margin: number, corridorClear: number): boolean
	if Context.obbBlocked(ctx, o, margin) then
		return true
	end
	for _, p in Geom.obbPerimeter(o, 4) do
		local d = Context.corridorClearance(ctx, p[1], p[2], nil)
		if d < corridorClear then
			return true
		end
	end
	return false
end

function Context.pointFree(ctx: Context, x: number, z: number, radius: number, corridorClear: number?): boolean
	local o: OBB = { x = x, z = z, hw = radius, hd = radius, ry = 0 }
	if Context.obbBlocked(ctx, o, 0) then
		return false
	end
	if corridorClear then
		local d = Context.corridorClearance(ctx, x, z, nil)
		if d < corridorClear + radius then
			return false
		end
	end
	return true
end

return Context
