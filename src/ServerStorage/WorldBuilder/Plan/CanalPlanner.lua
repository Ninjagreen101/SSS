--!strict
-- CanalPlanner: Current canals. Stone channel walls line both banks, the water
-- is a translucent glowing teal surface (custom water with a scrolling flow
-- texture and rising motes applied at runtime), terrace drops become Current
-- waterfalls with mist, and every street that crosses a canal gets an arched
-- bridge. Town canals are tagged as healing pools.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Geom = require(Shared.Util.Geom)
local Rng = require(Shared.Util.Rng)
local Config = require(Shared.Config)

local Plan = require(script.Parent.Plan)
local Context = require(script.Parent.Context)

type PlanNode = Types.PlanNode
type CanalDef = Types.CanalDef
type Vec3 = Types.Vec3
type Context = Context.Context

local CC = Config.World.Canals

local CanalPlanner = {}

-- Register canal corridors before districts so lots keep clear of them.
function CanalPlanner.register(ctx: Context)
	for _, c in ctx.floor.canals do
		local pts: { Vec3 } = {}
		for _, n in c.nodes do
			table.insert(pts, { n[1], n[3], n[2] })
		end
		Context.addCorridor(ctx, { id = c.id, points = pts, width = c.width + 5, kind = "canal", main = true })
	end
end

local function segmentIntersect(ax: number, az: number, bx: number, bz: number, cx: number, cz: number, dx: number, dz: number): (number?, number?)
	local rX, rZ = bx - ax, bz - az
	local sX, sZ = dx - cx, dz - cz
	local denom = rX * sZ - rZ * sX
	if math.abs(denom) < 1e-9 then
		return nil, nil
	end
	local t = ((cx - ax) * sZ - (cz - az) * sX) / denom
	local u = ((cx - ax) * rZ - (cz - az) * rX) / denom
	if t >= 0 and t <= 1 and u >= 0 and u <= 1 then
		return t, u
	end
	return nil, nil
end

function CanalPlanner.plan(canal: CanalDef, ctx: Context): PlanNode
	local node = Plan.node("Canal_" .. canal.id, 0, 0, 0, 0, "Default")
	node.attributes.Canal = canal.id
	table.insert(node.tags, "CurrentCanal")
	local rng = Rng.new(canal.id)
	local half = canal.width / 2
	local nodes = canal.nodes

	for i = 1, #nodes - 1 do
		local a, b = nodes[i], nodes[i + 1]
		local ax, az, ay = a[1], a[2], a[3]
		local bx, bz = b[1], b[2]
		local len = Geom.dist2(ax, az, bx, bz)
		local tx, tz = (bx - ax) / len, (bz - az) / len
		local nx, nz = tz, -tx -- left normal
		local ryAlong = Geom.yawAlong(tx, tz)
		local waterY = ay - canal.waterDrop

		-- channel walls: 16-stud panels on both banks, facing the water
		local count = math.max(1, math.floor(len / CC.WallSegment + 0.5))
		local seg = len / count
		for k = 0, count - 1 do
			local u = (k + 0.5) * seg
			local cx, cz = ax + tx * u, az + tz * u
			for _, sgn in { 1, -1 } do
				local wx, wz = cx + nx * sgn * (half + 0.4), cz + nz * sgn * (half + 0.4)
				-- wall piece faces -Z toward the water: front direction = -normal*sgn
				local ry = Geom.yawFacing(-nx * sgn, -nz * sgn)
				Plan.piece(node, "canal_wall_l16", wx, ay, wz, ry, { sx = seg / 16 })
			end
			-- floating lily pads and puddles on the coping now and then
			if rng:chance(0.18) then
				local sgn = if rng:chance(0.5) then 1 else -1
				local px, pz = cx + nx * sgn * (half + 3.5), cz + nz * sgn * (half + 3.5)
				if Context.pointFree(ctx, px, pz, 2, nil) then
					Plan.piece(node, "puddle", px, ay + 0.02, pz, rng:range(0, math.pi), { s = rng:range(0.5, 0.9), tag = "Puddle" })
				end
			end
		end
		-- corner blocks hide joints where the canal bends
		if i > 1 then
			for _, sgn in { 1, -1 } do
				Plan.solid(node, ax + nx * sgn * (half + 0.9), ay - 3.6, az + nz * sgn * (half + 0.9), 2.4, 8.4, 2.4, ryAlong, {
					kind = "Surface",
					material = "Slate",
					color = "StoneWet",
				})
			end
		end

		-- water surface (custom Current water) and its glow
		local cx, cz = (ax + bx) / 2, (az + bz) / 2
		Plan.solid(node, cx, waterY - CC.WaterThickness / 2, cz, len + (if i < #nodes - 1 then 0.6 else 0), CC.WaterThickness, canal.width + 0.6, ryAlong, {
			kind = "Current",
			material = "Glass",
			color = "CurrentTeal",
			transparency = CC.WaterTransparency,
			tag = if canal.healing then "HealingCurrent" else "CurrentWater",
			name = "CurrentWater",
		})
		Plan.emitter(node, "CurrentMotes", cx, waterY + 0.5, cz, len, 1, canal.width, ryAlong)
		local lights = math.max(1, math.floor(len / 48))
		for k = 1, lights do
			local u = (k - 0.5) / lights * len
			Plan.light(node, ax + tx * u, waterY + 1.5, az + tz * u, "CurrentTeal", 22, 0.9, false)
		end
		Plan.marker(node, "CanalFlow", canal.id .. "_" .. i, cx, waterY, cz, ryAlong, {
			Length = len,
			Width = canal.width,
			Healing = canal.healing == true,
		})

		-- waterfall at the downstream node when the street level drops
		if i < #nodes then
			local nextY = if i + 1 <= #nodes then b[3] else ay
			local isOutlet = i + 1 == #nodes
			local dropTo = if isOutlet then ctx.floor.seaLevel else nextY - canal.waterDrop
			if nextY < ay - 0.5 or isOutlet then
				local lipY = waterY
				local fallH = lipY - dropTo
				local ry = Geom.yawFacing(tx, tz)
				Plan.piece(node, "waterfall_lip", bx, lipY, bz, ry, { sx = canal.width / 16 })
				Plan.solid(node, bx + tx * 1.4, (lipY + dropTo) / 2, bz + tz * 1.4, canal.width - 1, fallH, 1.2, ryAlong, {
					kind = "Falls",
					material = "Glass",
					color = "CurrentFalls",
					transparency = 0.35,
					tag = "CurrentFalls",
				})
				Plan.emitter(node, "FallsMist", bx + tx * 3, dropTo + 1, bz + tz * 3, canal.width, 2, 4, ryAlong)
				Plan.light(node, bx + tx * 2, dropTo + 4, bz + tz * 2, "CurrentTeal", 28, 1.4, false)
			end
		end
	end

	-- bridges where streets cross the canal
	local bridged = 0
	for _, st in ctx.floor.streets do
		local sp = st.points
		for si = 1, #sp - 1 do
			for ci = 1, #nodes - 1 do
				local a, b = nodes[ci], nodes[ci + 1]
				local t, u = segmentIntersect(sp[si][1], sp[si][3], sp[si + 1][1], sp[si + 1][3], a[1], a[2], b[1], b[2])
				if t and u then
					local x = sp[si][1] + (sp[si + 1][1] - sp[si][1]) * (t :: number)
					local z = sp[si][3] + (sp[si + 1][3] - sp[si][3]) * (t :: number)
					local y = a[3]
					local dx, dz = sp[si + 1][1] - sp[si][1], sp[si + 1][3] - sp[si][3]
					local ry = Geom.yawFacing(dx, dz)
					local s = math.max(1, st.width / 10)
					Plan.piece(node, "bridge_arch_l16", x, y, z, ry, { s = s })
					bridged += 1
				end
			end
		end
	end
	for _, lane in ctx.corridors do
		if lane.kind == "street" and not lane.main then
			local sp = lane.points
			for si = 1, #sp - 1 do
				for ci = 1, #nodes - 1 do
					local a, b = nodes[ci], nodes[ci + 1]
					local t = segmentIntersect(sp[si][1], sp[si][3], sp[si + 1][1], sp[si + 1][3], a[1], a[2], b[1], b[2])
					if t then
						local x = sp[si][1] + (sp[si + 1][1] - sp[si][1]) * (t :: number)
						local z = sp[si][3] + (sp[si + 1][3] - sp[si][3]) * (t :: number)
						-- skip crossings right at a waterfall
						local nearFall = false
						for k = 2, #nodes do
							if Geom.dist2(x, z, nodes[k][1], nodes[k][2]) < 14 then
								nearFall = true
							end
						end
						if not nearFall then
							local dx, dz = sp[si + 1][1] - sp[si][1], sp[si + 1][3] - sp[si][3]
							Plan.piece(node, "bridge_arch_l16", x, sp[si][2], z, Geom.yawFacing(dx, dz), { s = lane.width / 10 })
							bridged += 1
						end
					end
				end
			end
		end
	end
	node.attributes.Bridges = bridged

	-- source spring: a glowing pool where the canal begins
	local first = nodes[1]
	Plan.solid(node, first[1], first[3] - canal.waterDrop - 0.5, first[2], 1, canal.width + 6, canal.width + 6, 0, {
		kind = "Current",
		shape = "Cylinder",
		material = "Glass",
		color = "CurrentTeal",
		transparency = CC.WaterTransparency,
		tag = if canal.healing then "HealingCurrent" else "CurrentWater",
		rz = math.pi / 2,
	})
	Plan.emitter(node, "SpringBubbles", first[1], first[3] - canal.waterDrop, first[2], canal.width, 1, canal.width, 0)
	return node
end

return CanalPlanner
