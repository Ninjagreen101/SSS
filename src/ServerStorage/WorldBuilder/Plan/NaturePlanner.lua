--!strict
-- NaturePlanner: scatters wild-zone dressing by biome on a jittered grid
-- (trees as trunk + crown, rocks, bushes, reeds and lily pads at the water's
-- edge, logs, stumps, glowcaps, Current crystals), places MeshPart cliffs on
-- steep terrain for crisp silhouettes, and adds night-only firefly volumes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Rng = require(Shared.Util.Rng)
local Geom = require(Shared.Util.Geom)
local Config = require(Shared.Config)

local Plan = require(script.Parent.Plan)
local Context = require(script.Parent.Context)
local TerrainPlanner = require(script.Parent.TerrainPlanner)

type PlanNode = Types.PlanNode
type WildDef = Types.WildDef
type Context = Context.Context
type Field = TerrainPlanner.Field
type Rng = Rng.Rng

local N = Config.World.Nature

local NaturePlanner = {}

type BiomeSpec = {
	trees: { [string]: number },
	extras: { [string]: number },
	waterEdge: { [string]: number },
	extraSpacing: number,
}

local BIOMES: { [string]: BiomeSpec } = {
	Marsh = {
		trees = { willow = 6, rustwood = 1 },
		extras = { bush_a = 3, rock_1 = 2, rock_2 = 1, log_fallen = 1, stump = 1, crystal_s = 0.6, grass_clump = 2, mushrooms = 0.5 },
		waterEdge = { reeds = 6, lily_pads = 2, crystal_s = 0.4 },
		extraSpacing = 46,
	},
	Forest = {
		trees = { rustwood = 7, pine = 2 },
		extras = { bush_b = 4, bush_a = 1, rock_1 = 1.5, rock_2 = 1.5, rock_3 = 0.6, log_fallen = 1.2, stump = 1.2, mushrooms = 1.5, roots = 0.8, crystal_s = 0.25, flowers = 1 },
		waterEdge = { reeds = 1 },
		extraSpacing = 34,
	},
	Crags = {
		trees = { pine = 5, rustwood = 0.5 },
		extras = { rock_2 = 2, rock_3 = 2, rock_4 = 1.2, rock_5 = 0.4, bush_a = 0.8, stump = 0.4, grass_clump = 1 },
		waterEdge = {},
		extraSpacing = 40,
	},
	Shore = {
		trees = { pine = 2, willow = 0.5 },
		extras = { rock_1 = 2, rock_2 = 2, rock_3 = 1, log_fallen = 1.6, grass_clump = 2, reeds = 1, bush_a = 0.6 },
		waterEdge = { reeds = 3, rock_2 = 1 },
		extraSpacing = 40,
	},
}

local function slopeAt(field: Field, x: number, z: number): (number, number, number)
	local h = field:height(x, z)
	local gx = (field:height(x + 4, z) - field:height(x - 4, z)) / 8
	local gz = (field:height(x, z + 4) - field:height(x, z - 4)) / 8
	return h, gx, gz
end

local function placeTree(node: PlanNode, species: string, x: number, y: number, z: number, rng: Rng)
	local size = rng:weighted({ s = 2, m = 4, l = 2 })
	local ry = rng:range(0, math.pi * 2)
	local s = rng:range(0.85, 1.2)
	local lean = rng:range(-0.05, 0.05)
	Plan.piece(node, string.format("tree_%s_%s_trunk", species, size), x, y - 0.6, z, ry, { s = s, rz = lean })
	Plan.piece(node, string.format("tree_%s_%s_crown", species, size), x, y - 0.6, z, ry, { s = s, rz = lean })
end

local BIOME_TREE_WEIGHT: { [string]: number } = { Forest = 1.6, Marsh = 0.55, Crags = 0.35, Shore = 0.25 }

local function polygonArea(poly: { Types.Point2 }): number
	local a = 0
	for i = 1, #poly do
		local p, q = poly[i], poly[(i % #poly) + 1]
		a += p[1] * q[2] - q[1] * p[2]
	end
	return math.abs(a) / 2
end

-- Split the floor's tree budget across wild zones by area, biome and density.
function NaturePlanner.allocate(wilds: { WildDef }, total: number): { [string]: number }
	local weights: { [string]: number } = {}
	local sum = 0
	for _, w in wilds do
		local wt = polygonArea(w.polygon) * (BIOME_TREE_WEIGHT[w.biome] or 0.3) * w.density
		weights[w.id] = wt
		sum += wt
	end
	local out: { [string]: number } = {}
	for id, wt in weights do
		out[id] = math.floor(total * wt / math.max(sum, 1))
	end
	return out
end

function NaturePlanner.plan(wild: WildDef, field: Field, ctx: Context, budget: { trees: number }): PlanNode
	local node = Plan.node("Wild_" .. wild.id, 0, 0, 0, 0, "Default")
	node.attributes.Biome = wild.biome
	local rng = Rng.new(wild.seed * 104729)
	local spec = BIOMES[wild.biome]
	local b = Geom.polygonBounds(wild.polygon)
	local spacing = (N.TreeSpacing :: any)[wild.biome] / math.max(0.3, wild.density)
	local exSpacing = spec.extraSpacing / math.max(0.3, wild.density)
	local sea = ctx.floor.seaLevel

	-- trees on a jittered grid, visited in shuffled order so a budget cut
	-- thins the whole zone evenly instead of leaving its far side bare
	local cells: { { number } } = {}
	local cellX = b.minX + spacing / 2
	while cellX < b.maxX do
		local cellZ = b.minZ + spacing / 2
		while cellZ < b.maxZ do
			table.insert(cells, { cellX, cellZ })
			cellZ += spacing
		end
		cellX += spacing
	end
	rng:shuffle(cells)
	for _, cell in cells do
		do
			local px, pz = cell[1] + rng:range(-0.45, 0.45) * spacing, cell[2] + rng:range(-0.45, 0.45) * spacing
			if budget.trees > 0 and Geom.pointInPolygon(px, pz, wild.polygon) then
				local smp = field:sample(px, pz)
				local _, gx, gz = slopeAt(field, px, pz)
				local slope = math.sqrt(gx * gx + gz * gz)
				local wet = smp.water ~= nil and (smp.water :: number) > smp.height
				local clumpNoise = Geom.fbm(px / 180, pz / 180, wild.seed, 2)
				if not wet and smp.height > sea + 0.8 and slope < 0.9 and clumpNoise > -0.35 and Context.pointFree(ctx, px, pz, 5, 4) then
					local species = rng:weighted(spec.trees)
					if wild.biome == "Forest" and smp.height > 90 and rng:chance(0.6) then
						species = "pine"
					end
					placeTree(node, species, px, smp.height, pz, rng)
					Context.addObb(ctx, { x = px, z = pz, hw = 2, hd = 2, ry = 0 })
					budget.trees -= 1
				end
			end
		end
	end

	-- undergrowth, rocks and water-edge plants
	local x = b.minX + exSpacing / 2
	while x < b.maxX do
		local z = b.minZ + exSpacing / 2
		while z < b.maxZ do
			local px, pz = x + rng:range(-0.5, 0.5) * exSpacing, z + rng:range(-0.5, 0.5) * exSpacing
			if Geom.pointInPolygon(px, pz, wild.polygon) and Context.pointFree(ctx, px, pz, 2.5, 3) then
				local smp = field:sample(px, pz)
				local water = smp.water
				local nearWater = water ~= nil and math.abs((water :: number) - smp.height) < 1.4
				local item: string? = nil
				if nearWater and next(spec.waterEdge) ~= nil then
					item = rng:weighted(spec.waterEdge)
				elseif water == nil or (water :: number) < smp.height then
					item = rng:weighted(spec.extras)
				end
				if item then
					local y = smp.height
					if item == "lily_pads" and water then
						y = (water :: number) + 0.02
					end
					local s = if string.sub(item, 1, 5) == "rock_" then rng:range(0.7, 1.4) else rng:range(0.8, 1.2)
					Plan.piece(node, item, px, y - 0.3, pz, rng:range(0, math.pi * 2), {
						s = s,
						rx = if string.sub(item, 1, 5) == "rock_" then rng:range(-0.2, 0.2) else nil,
						tag = if item == "mushrooms" then "Glowcap" elseif string.sub(item, 1, 8) == "crystal_" then "CurrentCrystal" else nil,
					})
					if string.sub(item, 1, 8) == "crystal_" then
						Plan.light(node, px, y + 2.5, pz, "CurrentTeal", 14, 0.9, false)
					end
				end
			end
			z += exSpacing
		end
		x += exSpacing
	end

	-- fireflies over marsh and forest at night
	if wild.biome == "Marsh" or wild.biome == "Forest" then
		local count = 0
		for _ = 1, 40 do
			if count >= 14 then
				break
			end
			local px, pz = rng:range(b.minX, b.maxX), rng:range(b.minZ, b.maxZ)
			if Geom.pointInPolygon(px, pz, wild.polygon) then
				local h = field:height(px, pz)
				Plan.emitter(node, "Fireflies", px, h + 5, pz, 90, 8, 90, 0)
				count += 1
			end
		end
	end
	return node
end

-- MeshPart cliffs wherever natural terrain is steep, facing downhill.
function NaturePlanner.cliffs(field: Field, ctx: Context, maxCount: number): PlanNode
	local node = Plan.node("Cliffs", 0, 0, 0, 0, "Default")
	local rng = Rng.new("cliffs")
	local step = 34
	local placed = 0
	local half = ctx.floor.size / 2
	local x = -half + step
	while x < half - step and placed < maxCount do
		local z = -half + step
		while z < half - step and placed < maxCount do
			local px, pz = x + rng:range(-8, 8), z + rng:range(-8, 8)
			local h, gx, gz = slopeAt(field, px, pz)
			local g = math.sqrt(gx * gx + gz * gz)
			if g > N.CliffSlope then
				local onTown = false
				for _, d in ctx.floor.districts do
					if Geom.polygonDistance(px, pz, d.polygon) < 16 then
						onTown = true
						break
					end
				end
				local clearance = Context.corridorClearance(ctx, px, pz, nil)
				if not onTown and clearance > 10 then
					local dx, dz = -gx / g, -gz / g -- downhill
					local lowH = field:height(px + dx * 18, pz + dz * 18)
					local highH = field:height(px - dx * 18, pz - dz * 18)
					local relief = math.max(8, highH - lowH)
					local id = rng:pick({ "cliff_a", "cliff_b", "cliff_c" })
					local baseH = if id == "cliff_a" then 60 elseif id == "cliff_b" then 40 else 90
					local s = math.clamp(relief / baseH, 0.35, 2.2)
					Plan.piece(node, id, px + dx * 4, lowH - 4, pz + dz * 4, Geom.yawFacing(dx, dz) + rng:range(-0.25, 0.25), {
						s = s,
						material = if h > 200 then "Basalt" else nil,
					})
					placed += 1
				end
			end
			z += step
		end
		x += step
	end
	node.attributes.Count = placed
	return node
end

return NaturePlanner
