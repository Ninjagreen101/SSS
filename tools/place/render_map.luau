--!nocheck
-- Renders the Floor 1 map image (assets/map/floor1_map.png, 1024 x 1024) from Layouts/Floor1.
--
--   lune run tools/place/render_map.luau [out.png]
--
-- The image covers Config.World.Maps["1"]: Center (0, 0), Size 3000, north (-Z) at the top, so image
-- x = world X and image y = world Z. This script samples the layout (height, region, town surface,
-- water) on a 1024 x 1024 grid into build/map_samples.bin and dumps the vector data (bands, canals,
-- roads, landmarks) into build/map_layout.json; tools/place/render_map.py then paints the PNG
-- (hillshade, biome colours, town terraces, glyphs, vignette). It needs Python 3 with Pillow and numpy.
--
-- Upload the PNG as a Decal image in Studio (Asset Manager > Bulk Import) and paste the asset id into
-- Config.World.Maps["1"].Image. Leave it empty to fall back to the client's region-run map.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local SIZE = 1024 -- pixels per side
local WORLD = 3000 -- studs per side, centred on (0, 0)
local HEIGHT_BIAS = 40 -- stored height = (h + bias) * HEIGHT_SCALE
local HEIGHT_SCALE = 200

local out = process.args[1] or "assets/map/floor1_map.png"

local env = setmetatable({
	Vector2 = roblox.Vector2,
	Vector3 = roblox.Vector3,
	Enum = roblox.Enum,
}, { __index = _G })
local Layout = luau.load(fs.readFile("src/ServerStorage/Tools/Layouts/Floor1.lua"), {
	debugName = "Floor1Layout",
	environment = env,
})()

local REGIONS = { "Town", "Harbour", "OldWharf", "TidepoolMarsh", "RustwoodForest", "Downs", "Cistern", "FirstGate" }
local regionId = {}
for i, name in REGIONS do
	regionId[name] = i
end
local SURFACES = { Canal = 1, Plaza = 2, Avenue = 3, Street = 4, Quay = 5, Lot = 6 }

local samples = buffer.create(SIZE * SIZE * 5)
local step = WORLD / SIZE
for j = 0, SIZE - 1 do
	local z = -WORLD / 2 + (j + 0.5) * step
	for i = 0, SIZE - 1 do
		local x = -WORLD / 2 + (i + 0.5) * step
		local h = Layout.Height(x, z)
		local region = Layout.Region(x, z)
		local surface = Layout.TownSurface(x, z)
		local water = Layout.Water(x, z, h)
		local at = (j * SIZE + i) * 5
		buffer.writeu16(samples, at, math.clamp(math.floor((h + HEIGHT_BIAS) * HEIGHT_SCALE), 0, 65535))
		buffer.writeu8(samples, at + 2, regionId[region])
		buffer.writeu8(samples, at + 3, if surface then SURFACES[surface] else 0)
		buffer.writeu8(samples, at + 4, if water then 1 else 0)
	end
	if j % 128 == 0 then
		print(string.format("sampled row %d / %d", j, SIZE))
	end
end
if not fs.isDir("build") then
	fs.writeDir("build")
end
fs.writeFile("build/map_samples.bin", buffer.tostring(samples))

local function v2(p)
	return { x = p.X, z = p.Y }
end
local landmarks = {}
for name, lm in Layout.Landmarks do
	landmarks[name] = v2(Layout.FromPolar(lm.R, lm.A))
end
local roads = {}
for _, road in Layout.Roads do
	local pts = {}
	for _, p in road.Points do
		table.insert(pts, v2(p))
	end
	table.insert(roads, { name = road.Name, width = road.Width, points = pts })
end
local breakwaters = {}
for _, arm in Layout.Breakwaters do
	table.insert(breakwaters, { v2(arm[1]), v2(arm[2]) })
end
local bands = {}
for _, band in Layout.Bands do
	table.insert(bands, { r0 = band.R0, r1 = band.R1, y = band.Y, street = band.Street })
end
local points = {}
for name, p in Layout.Points do
	points[name] = v2(p)
end
local layout = {
	size = SIZE,
	world = WORLD,
	heightBias = HEIGHT_BIAS,
	heightScale = HEIGHT_SCALE,
	regions = REGIONS,
	bay = v2(Layout.Bay),
	townAngle = Layout.TownAngle,
	townOuter = Layout.TownOuter,
	quayRadius = Layout.QuayRadius,
	bands = bands,
	climb = { angle = Layout.Climb.Angle, width = Layout.Climb.Width },
	spokes = Layout.Spokes,
	spokeWidth = Layout.SpokeWidth,
	canals = Layout.Canals,
	canalWidth = Layout.CanalWidth,
	canalEnd = Layout.CanalEnd,
	plaza = { center = v2(Layout.FromPolar(Layout.Plaza.Radius, Layout.Plaza.Angle)), size = Layout.Plaza.Size },
	landmarks = landmarks,
	points = points,
	roads = roads,
	breakwaters = breakwaters,
	gate = { radius = Layout.GatePlateau.Radius },
	cistern = { radius = Layout.CisternBasin.Radius },
}
fs.writeFile("build/map_layout.json", serde.encode("json", layout))

local result = process.exec("python3", { "tools/place/render_map.py", "build/map_samples.bin", "build/map_layout.json", out })
print(result.stdout)
assert(result.ok, "render_map.py failed: " .. result.stderr)
print("wrote " .. out)
