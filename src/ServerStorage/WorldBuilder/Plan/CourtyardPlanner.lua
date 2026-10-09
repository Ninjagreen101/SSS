--!strict
-- CourtyardPlanner: fills the open ground left inside town blocks once streets
-- and lots are placed, so no block reads as an empty paved field. Each free
-- spot gets a small vignette that fits its district: kitchen gardens, wells
-- and washing lines on the terraces, crate yards and boats on trestles at the
-- docks, clipped hedges and statues on Guild Hill, stall stores in the market.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Rng = require(Shared.Util.Rng)
local Geom = require(Shared.Util.Geom)

local Plan = require(script.Parent.Plan)
local Context = require(script.Parent.Context)

type PlanNode = Types.PlanNode
type DistrictDef = Types.DistrictDef
type Context = Context.Context
type Rng = Rng.Rng

local CourtyardPlanner = {}

local ORIGIN = Plan.frame(0, 0, 0, 0, 1)
local STEP = 22
local RADIUS = 8

type Vignette = (node: PlanNode, x: number, y: number, z: number, ry: number, rng: Rng) -> ()

local function garden(node: PlanNode, x: number, y: number, z: number, ry: number, rng: Rng)
	local f = Plan.frame(x, y, z, ry, 1)
	local size = rng:pick({ "s", "m" })
	Plan.pieceIn(node, f, "tree_rustwood_" .. size .. "_trunk", 0, -0.4, 0, rng:range(0, 6), {})
	Plan.pieceIn(node, f, "tree_rustwood_" .. size .. "_crown", 0, -0.4, 0, rng:range(0, 6), {})
	Plan.pieceIn(node, f, "bush_a", 4, 0, 2, rng:range(0, 6), { s = 0.7 })
	Plan.pieceIn(node, f, "flowers", -3, 0, 3, 0, {})
	Plan.pieceIn(node, f, "bench", 0, 0, -5, 0, {})
end

local function kitchenGarden(node: PlanNode, x: number, y: number, z: number, ry: number, rng: Rng)
	local f = Plan.frame(x, y, z, ry, 1)
	for i = -1, 1 do
		Plan.pieceIn(node, f, "moss_patch", i * 3.2, 0.02, 0, math.pi / 2, { s = 1.2, color = "LeafGreen" })
	end
	Plan.pieceIn(node, f, "railing_l8", 0, 0, -3.6, 0, { s = 0.6, material = "Wood", color = "WoodLight" })
	Plan.pieceIn(node, f, "barrel", 5, 0, 2, 0, {})
	Plan.pieceIn(node, f, "potted_plant_pot", -5, 0, 2, 0, {})
end

local function washingLine(node: PlanNode, x: number, y: number, z: number, ry: number, rng: Rng)
	local f = Plan.frame(x, y, z, ry, 1)
	Plan.pieceIn(node, f, "corner_timber_h12", -6, 0, 0, 0, { s = 0.6 })
	Plan.pieceIn(node, f, "corner_timber_h12", 6, 0, 0, 0, { s = 0.6 })
	Plan.pieceIn(node, f, "beam_l8", 0, 7.0, 0, math.pi / 2, { sx = 0.12, sy = 0.12, sz = 1.5 })
	local cloths = { "Linen", "ClothRed", "ClothTeal", "Sail", "ClothOchre" }
	for i = -2, 2 do
		Plan.pieceIn(node, f, "banner_wall", i * 2.3, 7.6, 0.8, 0, { s = 0.55, color = rng:pick(cloths) })
	end
	Plan.pieceIn(node, f, "barrel", 7.5, 0, 1.5, 0, { s = 0.7 })
end

local function well(node: PlanNode, x: number, y: number, z: number, ry: number, rng: Rng)
	Plan.assembly(node, ORIGIN, "well", x, y, z, ry, { s = 0.8 })
	local wx, wz = Geom.rotate(4.5, 2, ry)
	Plan.piece(node, "crate_s", x + wx, y, z + wz, ry, {})
end

local function crateYard(node: PlanNode, x: number, y: number, z: number, ry: number, rng: Rng)
	local f = Plan.frame(x, y, z, ry, 1)
	for i = 0, rng:int(2, 4) do
		local cx, cz = rng:range(-4, 4), rng:range(-3, 3)
		Plan.pieceIn(node, f, rng:pick({ "crate_l", "crate_l", "crate_s", "barrel" }), cx, 0, cz, rng:range(-0.3, 0.3), {})
	end
	Plan.pieceIn(node, f, "crate_s", 1, 3, 0, 0.4, {})
	Plan.pieceIn(node, f, "rope_coil", -5, 0, 4, 0, {})
end

local function boatYard(node: PlanNode, x: number, y: number, z: number, ry: number, rng: Rng)
	local f = Plan.frame(x, y, z, ry, 1)
	Plan.pieceIn(node, f, "log_fallen", 0, 0, -3, 0, { s = 0.5 })
	Plan.pieceIn(node, f, "log_fallen", 0, 0, 3, 0, { s = 0.5 })
	Plan.pieceIn(node, f, "boat_row", 0, 1.2, 0, 0.05, { rz = 0.12 })
	Plan.pieceIn(node, f, "fishing_net", 5, 0, -5, rng:range(0, 6), { s = 0.8 })
	Plan.pieceIn(node, f, "fish_rack", -6, 0, 0, math.pi / 2, {})
end

local function formalGarden(node: PlanNode, x: number, y: number, z: number, ry: number, rng: Rng)
	local f = Plan.frame(x, y, z, ry, 1)
	for _, c in { { -4, -4 }, { 4, -4 }, { -4, 4 }, { 4, 4 } } do
		Plan.pieceIn(node, f, "bush_a", c[1], -0.3, c[2], rng:range(0, 6), { s = 0.6 })
	end
	if rng:chance(0.5) then
		Plan.assembly(node, f, "statue", 0, 0, 0, rng:range(0, 6), { s = 0.6 })
	else
		Plan.assembly(node, f, "potted_plant", 0, 0, 0, 0, { s = 1.6 })
	end
	Plan.pieceIn(node, f, "bench", 0, 0, -6.5, 0, {})
end

local function stallStore(node: PlanNode, x: number, y: number, z: number, ry: number, rng: Rng)
	local f = Plan.frame(x, y, z, ry, 1)
	Plan.pieceIn(node, f, "cart", 0, 0, 0, rng:range(-0.4, 0.4), {})
	Plan.pieceIn(node, f, "crate_l", 5, 0, 3, 0.2, {})
	Plan.pieceIn(node, f, "barrel", -5, 0, 3, 0, {})
	Plan.pieceIn(node, f, "tent", 0, 0, -6, 0, { s = 0.7, color = rng:pick({ "ClothRed", "ClothOchre", "ClothTeal" }) })
end

local BY_STYLE: { [string]: { [string]: number } } = {
	Docks = { crateYard = 4, boatYard = 3, washingLine = 2, well = 1 },
	Market = { stallStore = 3, crateYard = 2, garden = 2, well = 1, washingLine = 1 },
	Residential = { garden = 3, kitchenGarden = 3, washingLine = 3, well = 1 },
	Noble = { formalGarden = 4, garden = 2, well = 1 },
}

local VIGNETTES: { [string]: Vignette } = {
	garden = garden,
	kitchenGarden = kitchenGarden,
	washingLine = washingLine,
	well = well,
	crateYard = crateYard,
	boatYard = boatYard,
	formalGarden = formalGarden,
	stallStore = stallStore,
}

function CourtyardPlanner.plan(district: DistrictDef, ctx: Context, maxCount: number): PlanNode
	local node = Plan.node("Courtyards_" .. district.id, 0, 0, 0, 0, "Default")
	local rng = Rng.new("courtyards_" .. district.id)
	local weights = BY_STYLE[district.style] or BY_STYLE.Residential
	local b = Geom.polygonBounds(district.polygon)
	local spots: { { number } } = {}
	local x = b.minX + STEP / 2
	while x < b.maxX do
		local z = b.minZ + STEP / 2
		while z < b.maxZ do
			table.insert(spots, { x + rng:range(-5, 5), z + rng:range(-5, 5) })
			z += STEP
		end
		x += STEP
	end
	rng:shuffle(spots)
	local count = 0
	for _, sp in spots do
		if count >= maxCount then
			break
		end
		local px, pz = sp[1], sp[2]
		if Geom.pointInPolygon(px, pz, district.polygon) and -Geom.polygonDistance(px, pz, district.polygon) > RADIUS + 2 and Context.pointFree(ctx, px, pz, RADIUS, 2) then
			local kind = rng:weighted(weights)
			-- face the nearest street so vignettes read as backyards of the lots around them
			local _, corridor = Context.corridorClearance(ctx, px, pz, { street = true })
			local ry = rng:range(0, math.pi * 2)
			if corridor then
				local hit = Geom.closestOnPolyline(px, pz, corridor.points, 3)
				local a = corridor.points[hit.segment]
				local c = corridor.points[hit.segment + 1]
				ry = Geom.yawAlong(c[1] - a[1], c[3] - a[3])
			end
			VIGNETTES[kind](node, px, district.baseY, pz, ry, rng)
			Context.addObb(ctx, { x = px, z = pz, hw = RADIUS, hd = RADIUS, ry = 0 })
			count += 1
		end
	end
	node.attributes.Count = count
	return node
end

return CourtyardPlanner
