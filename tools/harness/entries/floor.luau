-- Harness entry: plan a whole floor and export plan, dungeon and a terrain heightmap.
-- usage: run_luau.py entries/floor.luau <floorModule> <mode> [step]
local args = { ... }
local floorName = args[1] or "Lowharbor"
local mode = args[2] or "plan"
local step = tonumber(args[3] or "8")
local FloorPlanner = HARNESS.require("ServerStorage/WorldBuilder/Plan/FloorPlanner")
local floor = HARNESS.require("ReplicatedStorage/Shared/Data/Floors/" .. floorName)
local t0 = os.clock()
local fp = FloorPlanner.plan(floor)
local t1 = os.clock()
if mode == "plan" then
	print(HARNESS.json({ plan = fp.root, stats = fp.stats, log = fp.log, seconds = t1 - t0 }))
elseif mode == "dungeon" then
	print(HARNESS.json({ plan = fp.dungeon, stats = fp.dungeonStats }))
elseif mode == "terrain" then
	local half = floor.size / 2
	local n = math.floor(floor.size / step) + 1
	local names = { "Grass", "LeafyGrass", "Mud", "Ground", "Rock", "Slate", "Basalt", "Sand", "Cobblestone", "Pavement", "WoodPlanks", "Limestone" }
	local colors = { Grass = "5E7340", LeafyGrass = "4C6438", Mud = "4A4136", Ground = "5C5040", Rock = "5E5C58", Slate = "4E5258", Basalt = "33353A", Sand = "8C8272", Cobblestone = "6A665E", Pavement = "707070", WoodPlanks = "5A4630", Limestone = "8D887E" }
	local idx = {}
	for i, v in names do idx[v] = i - 1 end
	local heights, mats, water = table.create(n * n, 0), table.create(n * n, 0), {}
	local any = false
	for j = 0, n - 1 do
		for i = 0, n - 1 do
			local x, z = -half + i * step, -half + j * step
			local s = fp.field:sample(x, z)
			local k = j * n + i + 1
			heights[k] = s.height
			mats[k] = idx[s.material] or 0
			water[k] = s.water or "null"
		end
	end
	-- encode nil water as JSON null
	local w = {}
	for k = 1, n * n do w[k] = water[k] end
	print(HARNESS.json({ nx = n, nz = n, step = step, x0 = -half, z0 = -half, heights = heights, materials = mats, materialNames = names, materialColors = colors, water = w, seconds = os.clock() - t1 }))
end
