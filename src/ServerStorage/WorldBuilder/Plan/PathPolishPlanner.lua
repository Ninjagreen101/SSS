--!strict
-- PathPolishPlanner: the hand-polish pass over the streets players walk most.
--
--  * Quest-path stairs become real stone flights (the terrain under them is
--    only a ramp), framed by lantern posts and planters at the head and foot.
--  * Glowing Current rune inlays run up the centre of the quest path, so a new
--    Climber can always follow the light from the pier to the Climbers' Guild.
--  * Signposts with painted destination names stand at the points each
--    StreetDef lists.
--  * Wear: puddles and moss gather along kerbs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Rng = require(Shared.Util.Rng)
local Geom = require(Shared.Util.Geom)

local Plan = require(script.Parent.Plan)
local Context = require(script.Parent.Context)

type PlanNode = Types.PlanNode
type StreetDef = Types.StreetDef
type Vec3 = Types.Vec3
type Context = Context.Context

local PathPolishPlanner = {}

local ORIGIN = Plan.frame(0, 0, 0, 0, 1)
local STAIR_SLOPE = 0.3
local RUNE_SPACING = 18

local function isStair(a: Vec3, b: Vec3): boolean
	local run = Geom.dist2(a[1], a[3], b[1], b[3])
	return run > 0 and math.abs(b[2] - a[2]) / run > STAIR_SLOPE
end

-- Stone flight from a to b (either direction), filling the street width.
local function stairs(node: PlanNode, st: StreetDef, a: Vec3, b: Vec3)
	local low, high = a, b
	if b[2] < a[2] then
		low, high = b, a
	end
	local dx, dz = high[1] - low[1], high[3] - low[3]
	local run = math.sqrt(dx * dx + dz * dz)
	local rise = high[2] - low[2]
	local ux, uz = dx / run, dz / run
	local ry = math.atan2(ux, uz) -- the piece rises toward its local +Z
	local n = math.max(1, math.floor(rise / 4 + 0.5))
	local segRun, segRise = run / n, rise / n
	for k = 0, n - 1 do
		local cx = low[1] + ux * (segRun * (k + 0.5))
		local cz = low[3] + uz * (segRun * (k + 0.5))
		Plan.piece(node, "steps_stone_w24", cx, low[2] + segRise * k, cz, ry, {
			sx = st.width / 24,
			sy = segRise / 4,
			sz = segRun / 8,
			material = "Cobblestone",
			color = "Stone",
		})
	end
	-- lantern posts and planters frame the head and the foot of the flight
	local nx, nz = uz, -ux
	type End = { p: Vec3, out: number }
	local ends: { End } = { { p = low, out = -1 }, { p = high, out = 1 } }
	for _, e in ends do
		local p = e.p
		local out = e.out
		local px, pz = p[1] + ux * out * 2, p[3] + uz * out * 2
		for _, sgn in { 1, -1 } do
			local off = st.width / 2 + 1.4
			Plan.assembly(node, ORIGIN, "stair_post", px + nx * off * sgn, p[2], pz + nz * off * sgn, ry)
			if out > 0 then
				Plan.assembly(node, ORIGIN, "potted_plant", px + nx * (off - 2.6) * sgn + ux * 1.5, p[2], pz + nz * (off - 2.6) * sgn + uz * 1.5, 0, { s = 1.3 })
			end
		end
	end
end

local function signpost(node: PlanNode, st: StreetDef, index: number, key: string, back: string?)
	local pts = st.points
	local p = pts[index]
	local q = pts[math.min(index + 1, #pts)]
	if index == #pts then
		q = p
		p = pts[index - 1]
	end
	local dx, dz = q[1] - p[1], q[3] - p[3]
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 1e-3 then
		return
	end
	dx, dz = dx / len, dz / len
	-- stand at the right-hand kerb
	local rx, rz = -dz, dx
	local off = st.width / 2 - 1.6
	local sx, sz = p[1] + rx * off, p[3] + rz * off
	local y = p[2]
	Plan.piece(node, "corner_timber_h12", sx, y, sz, 0, { s = 0.75 })
	-- board pointing along the street toward its destination
	local function board(text: string, height: number, dirX: number, dirZ: number)
		local ry = Geom.yawAlong(dirX, dirZ)
		Plan.piece(node, "sign_board", sx + dirX * 2.9, y + height, sz + dirZ * 2.9, ry, {
			sx = 1.55,
			text = text,
			material = "WoodPlanks",
			color = "WoodLight",
		})
	end
	board(key, 8.4, dx, dz)
	if back then
		board(back, 6.6, -dx, -dz)
	end
end

function PathPolishPlanner.plan(floor: Types.FloorDef, ctx: Context): PlanNode
	local node = Plan.node("PathPolish", 0, 0, 0, 0, "Default")
	local rng = Rng.new("path_polish_" .. floor.id)
	for _, st in floor.streets do
		local pts = st.points
		if st.questPath then
			for i = 1, #pts - 1 do
				if isStair(pts[i], pts[i + 1]) then
					stairs(node, st, pts[i], pts[i + 1])
				end
			end
			-- guide runes along the centre (not on stairs or under plaza features)
			for _, smp in Geom.samplePolyline(pts, RUNE_SPACING, 3) do
				local onStair = false
				for i = 1, #pts - 1 do
					local d = Geom.distToSegment(smp.x, smp.z, pts[i][1], pts[i][3], pts[i + 1][1], pts[i + 1][3])
					if d < 6 and isStair(pts[i], pts[i + 1]) then
						onStair = true
					end
				end
				if not onStair then
					local ry = Geom.yawAlong(smp.tx, smp.tz)
					Plan.piece(node, "runeband_l8", smp.x, smp.y - 0.5, smp.z, ry, { rx = math.pi / 2, tag = "RuneGlow", noCollide = true })
				end
			end
		end
		if st.signs then
			for _, sg in st.signs do
				signpost(node, st, sg.at, sg.key, sg.back)
			end
		end
		-- kerbside wear on every main street
		if st.main then
			for _, smp in Geom.samplePolyline(pts, 26, 3) do
				if rng:chance(0.28) then
					local sgn = if rng:chance(0.5) then 1 else -1
					local off = st.width / 2 - rng:range(1.5, 3.5)
					local x, z = smp.x + smp.tz * off * sgn, smp.z - smp.tx * off * sgn
					local corridor = Context.corridorClearance(ctx, x, z, { canal = true })
					local item = if corridor < 10 or rng:chance(0.55) then "puddle" else "moss_patch"
					Plan.piece(node, item, x, smp.y + 0.03, z, rng:range(0, math.pi * 2), {
						s = rng:range(0.5, 0.9),
						tag = if item == "puddle" then "Puddle" else nil,
						noCollide = true,
					})
				end
			end
		end
	end
	return node
end

return PathPolishPlanner
