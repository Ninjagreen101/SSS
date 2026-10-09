--!strict
-- HiddenPlanner: optional treasure areas off the main path. Each hides one
-- per-player treasure chest: the Smugglers' Grotto carved into the market
-- cliff, the Drowned Bell Chapel on a rock in the bay, the Hermit's Hollow
-- deep in Rustwood and the Lantern Room atop the lighthouse.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Rng = require(Shared.Util.Rng)

local Plan = require(script.Parent.Plan)
local BuildingPlanner = require(script.Parent.BuildingPlanner)
local TerrainPlanner = require(script.Parent.TerrainPlanner)

type PlanNode = Types.PlanNode
type HiddenAreaDef = Types.HiddenAreaDef
type Field = TerrainPlanner.Field

export type TerrainCarve = {
	op: string, -- "Air" | "Fill"
	shape: string, -- "Block" | "Ball"
	material: string,
	x: number,
	y: number,
	z: number,
	sx: number,
	sy: number,
	sz: number,
	ry: number,
}

local HiddenPlanner = {}

local ORIGIN = Plan.frame(0, 0, 0, 0, 1)

local function encodeRewards(def: HiddenAreaDef): string
	local parts = {}
	for _, it in def.rewards.items do
		table.insert(parts, it.id .. ":" .. it.count)
	end
	return table.concat(parts, ",")
end

local function chest(node: PlanNode, def: HiddenAreaDef, x: number, y: number, z: number, ry: number)
	Plan.assembly(node, ORIGIN, "treasure_chest", x, y, z, ry)
	Plan.marker(node, "TreasureChest", def.chestId, x, y, z, ry, {
		Area = def.id,
		Gold = def.rewards.gold,
		Items = encodeRewards(def),
	})
end

-- Returns the node plus terrain edits the area needs (caves, islets).
function HiddenPlanner.plan(def: HiddenAreaDef, field: Field): (PlanNode?, { TerrainCarve })
	local carves: { TerrainCarve } = {}
	local rng = Rng.new("hidden_" .. def.id)
	if def.kind == "LanternRoom" then
		-- the chest is part of the lighthouse landmark; only register the marker
		local node = Plan.node("Hidden_" .. def.id, def.x, def.y, def.z, def.ry, "Atomic")
		local top = 1 + 6 * 15
		Plan.marker(node, "TreasureChest", def.chestId, 2.6, top - 15 + 1, 0, -math.pi / 2, {
			Area = def.id,
			Gold = def.rewards.gold,
			Items = encodeRewards(def),
		})
		return node, carves
	end

	local node = Plan.node("Hidden_" .. def.id, def.x, def.y, def.z, def.ry, "Atomic")
	node.attributes.Hidden = def.id
	table.insert(node.tags, "HiddenArea")

	if def.kind == "Grotto" then
		-- a tunnel into the market cliff from the marsh side, opening into a cave
		table.insert(carves, { op = "Air", shape = "Block", material = "Air", x = def.x - 14, y = def.y + 5, z = def.z, sx = 30, sy = 10, sz = 10, ry = def.ry })
		table.insert(carves, { op = "Air", shape = "Ball", material = "Air", x = def.x + 10, y = def.y + 8, z = def.z, sx = 34, sy = 34, sz = 34, ry = 0 })
		table.insert(carves, { op = "Fill", shape = "Block", material = "Slate", x = def.x + 10, y = def.y - 6, z = def.z, sx = 40, sy = 12, sz = 40, ry = 0 })
		Plan.solid(node, -10, 0.5, 0, 10, 1, 36, 0, { kind = "Surface", material = "WoodPlanks", color = "WoodWet" })
		for _ = 1, 6 do
			Plan.piece(node, rng:pick({ "crate_s", "barrel", "crate_l", "rope_coil" }), rng:range(-6, 6), 0, rng:range(-12, 12), rng:range(0, 6), {})
		end
		Plan.piece(node, "boat_row", 4, -0.4, 10, 0.5, {})
		Plan.piece(node, "crystal_m", 8, -1, -8, 1, {})
		Plan.light(node, 8, 3, -8, "CurrentTeal", 24, 1.4, false)
		Plan.assembly(node, ORIGIN, "hanging_lantern", -4, 12, 0, 0, {})
		chest(node, def, -2, 0, -10, 0)
	elseif def.kind == "Chapel" then
		-- a rock islet with a half-drowned chapel and its fallen bell
		table.insert(carves, { op = "Fill", shape = "Ball", material = "Rock", x = def.x, y = def.y - 26, z = def.z, sx = 70, sy = 54, sz = 62, ry = 0 })
		table.insert(carves, { op = "Fill", shape = "Block", material = "Slate", x = def.x, y = def.y - 1, z = def.z, sx = 34, sy = 2, sz = 30, ry = def.ry })
		local info = BuildingPlanner.plan({
			name = "DrownedChapel",
			w = 16,
			d = 24,
			storeys = 1,
			style = "Ruin",
			wealth = 0,
			kind = "ruin",
			seed = 9005,
			plinth = 2,
			ridgeAxis = "z",
			roof = "none",
			damaged = 0.45,
			doorPanel = "archdoor",
			windowPanel = "archwin",
		}, 0, 0, 0, 0)
		Plan.child(node, info.node)
		Plan.piece(node, "bell", 3, 2, 6, 0.4, { rz = 1.2 })
		Plan.piece(node, "window_rose", 0, 16, 12.6, math.pi, { s = 0.6 })
		chest(node, def, -3, 2, 7, math.pi)
		Plan.light(node, 0, 6, 4, "CurrentTeal", 18, 1, true)
	elseif def.kind == "Hermitage" then
		local gy = field:height(def.x, def.z)
		node.y = gy
		local info = BuildingPlanner.plan({
			name = "HermitHut",
			w = 16,
			d = 12,
			storeys = 1,
			style = "Docks",
			wealth = 0.1,
			kind = "house",
			seed = 9006,
			plinth = 4,
			roof = "gable",
		}, 0, -1.5, 0, 0)
		Plan.child(node, info.node)
		Plan.piece(node, "roots", 0, -0.5, 0, 0.6, { s = 2.2 })
		Plan.piece(node, "tree_rustwood_l_trunk", 14, -1, 10, 0.4, { s = 1.3 })
		Plan.piece(node, "tree_rustwood_l_crown", 14, -1, 10, 0.4, { s = 1.3 })
		Plan.piece(node, "mushrooms", -10, -0.5, 4, 0, { s = 1.5 })
		chest(node, def, 4, 2.5, 3, math.pi)
	end
	return node, carves
end

return HiddenPlanner
