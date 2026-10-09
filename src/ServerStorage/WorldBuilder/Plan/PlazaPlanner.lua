--!strict
-- PlazaPlanner: dresses town plazas (market stalls in rings, wells, statues,
-- lantern rings, benches, banners, the Current spring of Climbers' Rest and the
-- braziers of the gate plaza). Plaza paving itself is painted into terrain.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Rng = require(Shared.Util.Rng)
local Geom = require(Shared.Util.Geom)

local Plan = require(script.Parent.Plan)
local Context = require(script.Parent.Context)

type PlanNode = Types.PlanNode
type PlazaDef = Types.PlazaDef
type Context = Context.Context

local PlazaPlanner = {}

local ORIGIN = Plan.frame(0, 0, 0, 0, 1)

local function has(features: { string }, f: string): boolean
	return table.find(features, f) ~= nil
end

-- true when a plaza-local point is clear of streets crossing the plaza centre
local function clearOfWay(ctx: Context, def: PlazaDef, lx: number, lz: number, radius: number): boolean
	local d = Context.corridorClearance(ctx, def.x + lx, def.z + lz, { street = true })
	return d > radius
end

function PlazaPlanner.plan(def: PlazaDef, ctx: Context): PlanNode
	local node = Plan.node("Plaza_" .. def.id, def.x, def.y, def.z, 0, "Atomic")
	node.attributes.Plaza = def.id
	local rng = Rng.new("plaza_" .. def.id)
	local R = def.radius
	local f = def.features

	if has(f, "lanterns") then
		local n = math.max(6, math.floor(2 * math.pi * R / 30))
		for i = 0, n - 1 do
			local a = (i + 0.5) / n * math.pi * 2
			local x, z = math.cos(a) * (R - 3), math.sin(a) * (R - 3)
			if clearOfWay(ctx, def, x, z, 1) then
				Plan.assembly(node, ORIGIN, "street_lantern", x, 0, z, Geom.yawFacing(-math.cos(a), -math.sin(a)))
			end
		end
	end
	if has(f, "stalls") then
		local rings = { { R * 0.48, 9 }, { R * 0.72, 13 } }
		local colors = { "ClothRed", "ClothTeal", "ClothOchre", "ClothNavy" }
		for _, ring in rings do
			for i = 0, ring[2] - 1 do
				local a = (i + rng:range(0.2, 0.8)) / ring[2] * math.pi * 2
				local x, z = math.cos(a) * ring[1], math.sin(a) * ring[1]
				if clearOfWay(ctx, def, x, z, 5) then
					Plan.assembly(node, ORIGIN, "market_stall", x, 0, z, Geom.yawFacing(-math.cos(a), -math.sin(a)), { color = rng:pick(colors) })
					Plan.marker(node, "MerchantCall", string.format("%s_stall_%d", def.id, i), x, 4, z, 0, { Lines = "Market" })
				end
			end
		end
	end
	if has(f, "well") then
		local x, z = R * 0.3, -R * 0.25
		if not clearOfWay(ctx, def, x, z, 5) then
			x = -x
		end
		Plan.assembly(node, ORIGIN, "well", x, 0, z, rng:range(0, 6))
	end
	if has(f, "statue") then
		local x, z = -R * 0.3, R * 0.22
		if not clearOfWay(ctx, def, x, z, 5) then
			x = -x
		end
		Plan.assembly(node, ORIGIN, "statue", x, 0, z, Geom.yawFacing(-x, -z))
		Plan.light(node, x, 3, z - 5, "LanternGlow", 14, 0.8, true)
	end
	if has(f, "benches") then
		for i = 0, 5 do
			local a = i / 6 * math.pi * 2 + 0.3
			local r = R * 0.86
			local x, z = math.cos(a) * r, math.sin(a) * r
			if clearOfWay(ctx, def, x, z, 3) then
				Plan.piece(node, "bench", x, 0, z, Geom.yawFacing(-math.cos(a), -math.sin(a)) + math.pi, {})
			end
		end
	end
	if has(f, "banners") then
		for i = 0, 3 do
			local a = i / 4 * math.pi * 2 + math.pi / 4
			local x, z = math.cos(a) * R * 0.6, math.sin(a) * R * 0.6
			if clearOfWay(ctx, def, x, z, 3) then
				Plan.piece(node, "pillar_square_h12", x, 0, z, 0, { s = 1.2 })
				Plan.piece(node, "banner_tall", x, 13.4, z - 1.7, 0, { color = if i % 2 == 0 then "ClothTeal" else "ClothNavy" })
				Plan.piece(node, "banner_tall", x, 13.4, z + 1.7, math.pi, { color = if i % 2 == 0 then "ClothTeal" else "ClothNavy" })
			end
		end
	end
	if has(f, "crates") then
		for _ = 1, 6 do
			local a = rng:range(0, math.pi * 2)
			local r = rng:range(R * 0.5, R * 0.85)
			local x, z = math.cos(a) * r, math.sin(a) * r
			if clearOfWay(ctx, def, x, z, 3) then
				Plan.piece(node, rng:pick({ "crate_l", "crate_s", "barrel" }), x, 0, z, rng:range(0, 6), {})
			end
		end
	end
	if has(f, "trees") then
		for i = 0, 4 do
			local a = i / 5 * math.pi * 2
			local x, z = math.cos(a) * R * 0.55, math.sin(a) * R * 0.55
			if clearOfWay(ctx, def, x, z, 4) then
				local size = rng:pick({ "s", "m" })
				local ry = rng:range(0, 6)
				Plan.piece(node, "tree_rustwood_" .. size .. "_trunk", x, 0, z, ry, {})
				Plan.piece(node, "tree_rustwood_" .. size .. "_crown", x, 0, z, ry, {})
			end
		end
	end
	if has(f, "spring") then
		-- the Current spring that feeds Tidewater Run: a glowing healing pool
		local sx, sz = -36, 4
		Plan.solid(node, sx, -1.4, sz, 1.2, 22, 22, 0, {
			kind = "Current",
			shape = "Cylinder",
			material = "Glass",
			color = "CurrentTeal",
			transparency = 0.25,
			tag = "HealingCurrent",
			rz = math.pi / 2,
		})
		Plan.solid(node, sx, -3, sz, 3, 23.5, 23.5, 0, { kind = "Surface", shape = "Cylinder", material = "Slate", color = "StoneWet", rz = math.pi / 2 })
		for i = 0, 7 do
			local a = i / 8 * math.pi * 2
			Plan.piece(node, "pillar_round_h12", sx + math.cos(a) * 13.5, 0, sz + math.sin(a) * 13.5, 0, { s = 0.6, material = "Marble", color = "Marble" })
		end
		Plan.piece(node, "crystal_l", sx, -1, sz, 0.3, {})
		Plan.emitter(node, "SpringBubbles", sx, -0.6, sz, 18, 1, 18, 0)
		Plan.light(node, sx, 3, sz, "CurrentTeal", 34, 2, false)
		Plan.marker(node, "HealingPool", def.id .. "_spring", sx, 0, sz, 0, { Radius = 11 })
	end
	if has(f, "braziers") then
		for i = 0, 5 do
			local a = i / 6 * math.pi * 2
			local x, z = math.cos(a) * (R - 8), math.sin(a) * (R - 8)
			if clearOfWay(ctx, def, x, z, 2) then
				Plan.piece(node, "pillar_square_h12", x, 0, z, 0, { s = 0.4, material = "Basalt", color = "TowerStone" })
				Plan.piece(node, "cookfire", x, 4.8, z, 0, {})
				Plan.light(node, x, 7, z, "Ember", 22, 1.6, false)
				Plan.emitter(node, "CampfireFlame", x, 5.2, z)
			end
		end
	end
	return node
end

return PlazaPlanner
