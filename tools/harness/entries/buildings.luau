-- Harness entry: a row of sample buildings in every style/kind for review.
local Plan = HARNESS.require("ServerStorage/WorldBuilder/Plan/Plan")
local BP = HARNESS.require("ServerStorage/WorldBuilder/Plan/BuildingPlanner")

local root = Plan.node("Samples", 0, 0, 0, 0)
local specs = {
	{ style = "Residential", kind = "house", w = 24, d = 20, storeys = 3 },
	{ style = "Market", kind = "shop", w = 28, d = 20, storeys = 2 },
	{ style = "Docks", kind = "warehouse", w = 32, d = 24, storeys = 2 },
	{ style = "Noble", kind = "library", w = 28, d = 24, storeys = 3 },
	{ style = "Market", kind = "tavern", w = 24, d = 24, storeys = 3 },
	{ style = "Residential", kind = "house", w = 16, d = 12, storeys = 2 },
	{ style = "Docks", kind = "smithy", w = 20, d = 16, storeys = 2 },
	{ style = "Ruin", kind = "ruin", w = 24, d = 16, storeys = 2, damaged = 0.45, roof = "none" },
}
local x = 0
for i, s in specs do
	local info = BP.plan({
		name = "B" .. i, w = s.w, d = s.d, storeys = s.storeys, style = s.style, wealth = 0.5,
		kind = s.kind, seed = 100 + i, plinth = 2, roof = s.roof, damaged = s.damaged,
	}, x + s.w / 2, 0, 0, 0)
	Plan.child(root, info.node)
	x += s.w + 10
end
print(HARNESS.json({ plan = root, stats = Plan.stats(root) }))
