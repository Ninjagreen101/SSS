--!strict
-- Facade: wall-run bookkeeping shared by building and dungeon planners, and the
-- band decomposition that turns a wall full of openings into a handful of
-- merged collider boxes (instead of one collider per panel piece).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)

local Plan = require(script.Parent.Plan)

type PlanNode = Types.PlanNode

export type Opening = { u0: number, u1: number, v0: number, v1: number }

export type Side = {
	id: string,
	ax: number,
	az: number,
	dx: number, -- unit direction A -> B (panel +X)
	dz: number,
	ry: number,
	length: number,
	widths: { number },
	openings: { Opening },
}

local Facade = {}

function Facade.makeSide(id: string, ax: number, az: number, bx: number, bz: number, ry: number): Side
	local len = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
	return {
		id = id,
		ax = ax,
		az = az,
		dx = (bx - ax) / len,
		dz = (bz - az) / len,
		ry = ry,
		length = len,
		widths = {},
		openings = {},
	}
end


local function subtractIntervals(L: number, cuts: { { number } }): { { number } }
	table.sort(cuts, function(a: { number }, b: { number }): boolean
		return a[1] < b[1]
	end)
	local out: { { number } } = {}
	local cursor = 0
	for _, c in cuts do
		if c[1] > cursor + 0.05 then
			table.insert(out, { cursor, c[1] })
		end
		cursor = math.max(cursor, c[2])
	end
	if cursor < L - 0.05 then
		table.insert(out, { cursor, L })
	end
	return out
end

function Facade.emitColliders(node: PlanNode, side: Side, v0: number, v1: number, thickness: number)
	local ys: { number } = { v0, v1 }
	for _, o in side.openings do
		table.insert(ys, math.clamp(o.v0, v0, v1))
		table.insert(ys, math.clamp(o.v1, v0, v1))
	end
	table.sort(ys)
	local uniq: { number } = {}
	for _, y in ys do
		if #uniq == 0 or y - uniq[#uniq] > 0.05 then
			table.insert(uniq, y)
		end
	end
	type Open = { u0: number, u1: number, vStart: number }
	local active: { [string]: Open } = {}
	local function emit(o: Open, vEnd: number)
		local h = vEnd - o.vStart
		if h < 0.05 then
			return
		end
		local u = (o.u0 + o.u1) / 2
		local x = side.ax + side.dx * u
		local z = side.az + side.dz * u
		Plan.solid(node, x, (o.vStart + vEnd) / 2, z, o.u1 - o.u0, h, thickness, side.ry, { kind = "Collider" })
	end
	for i = 1, #uniq - 1 do
		local ya, yb = uniq[i], uniq[i + 1]
		local cuts: { { number } } = {}
		for _, o in side.openings do
			if o.v0 <= ya + 0.01 and o.v1 >= yb - 0.01 then
				table.insert(cuts, { o.u0, o.u1 })
			end
		end
		local intervals = subtractIntervals(side.length, cuts)
		local nextActive: { [string]: Open } = {}
		for _, iv in intervals do
			local key = string.format("%.2f:%.2f", iv[1], iv[2])
			local cur = active[key]
			if cur then
				nextActive[key] = cur
				active[key] = nil
			else
				nextActive[key] = { u0 = iv[1], u1 = iv[2], vStart = ya }
			end
		end
		local leftover: { string } = {}
		for key in active do
			table.insert(leftover, key)
		end
		table.sort(leftover)
		for _, key in leftover do
			emit(active[key], ya)
		end
		active = nextActive
	end
	local rest: { string } = {}
	for key in active do
		table.insert(rest, key)
	end
	table.sort(rest)
	for _, key in rest do
		emit(active[key], v1)
	end
end

return Facade
