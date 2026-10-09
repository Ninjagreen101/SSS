-- Top-down footprints for plot_footprints.py.
--   lune run tools/place/footprints.luau <place.rbxl> <out.json>              Lowharbor (Workspace)
--   lune run tools/place/footprints.luau <place.rbxl> <out.json> <Path.To.Model>
-- Add --all anywhere after the output path to plot the whole floor instead of the Lowharbor window.
-- When Workspace.Floor1.Npcs / QuestPoints exist their markers are written too (plot_footprints.py
-- draws them).
-- With a path (e.g. ServerStorage.GuardianArenas.Brinewarden) every part under that instance is
-- plotted in its own space, classified as floor / collide / visual / neon / water / barrier / marker.
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local process = require("@lune/process")
local serde = require("@lune/serde")
local game = roblox.deserializePlace(fs.readFile(process.args[1]))
local ws = game:GetService("Workspace")
local out = {}
local plotAll = table.find(process.args, "--all") ~= nil
local function add(d, kind, filter)
	local cf, s = d.CFrame, d.Size
	local p = cf.Position
	if filter and not plotAll and (p.X < -900 or p.X > 120 or p.Z < -720 or p.Z > 780) then return end
	if s.X > 400 or s.Z > 400 then return end
	local function c(x, z, y)
		local w = cf:PointToWorldSpace(roblox.Vector3.new(x, y or 0, z))
		return { math.floor(w.X * 10) / 10, math.floor(w.Z * 10) / 10 }
	end
	if d:IsA("Part") and d.Shape == roblox.Enum.PartType.Cylinder and math.abs(cf.XVector.Y) > 0.99 then
		-- a standing disc (axis along X turned upright): draw its circle
		local pts = {}
		for i = 0, 23 do
			local a = i / 24 * 2 * math.pi
			table.insert(pts, { math.floor((p.X + math.cos(a) * s.Y / 2) * 10) / 10, math.floor((p.Z + math.sin(a) * s.Y / 2) * 10) / 10 })
		end
		table.insert(out, { k = kind, y = math.floor(p.Y), pts = pts })
		return
	end
	if not filter then
		-- model mode: all eight corners (plot_footprints.py draws their hull), so tilted parts show
		local pts = {}
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					table.insert(pts, c(sx * s.X / 2, sz * s.Z / 2, sy * s.Y / 2))
				end
			end
		end
		table.insert(out, { k = kind, y = math.floor(p.Y), pts = pts })
		return
	end
	table.insert(out, { k = kind, y = math.floor(p.Y), pts = { c(-s.X/2, -s.Z/2), c(s.X/2, -s.Z/2), c(s.X/2, s.Z/2), c(-s.X/2, s.Z/2) } })
end
local path = process.args[3]
if path == "--all" then
	path = nil
end
if path then
	local node = game
	for name in string.gmatch(path, "[^%.]+") do
		node = if node == game then game:GetService(name) else node:FindFirstChild(name)
		assert(node, path .. " not found")
	end
	for _, d in node:GetDescendants() do
		if d:IsA("BasePart") then
			local big = d.ClassName == "Part" and math.max(d.Size.X, d.Size.Y, d.Size.Z) > 60 and d.CFrame.Position.Y < 1
			local kind
			if d.Name == "TideWater" or d.Name == "PressureZone" or d.Name == "Bounds" then continue
			elseif big then kind = "floor"
			elseif d.Transparency >= 1 and d.CanCollide then kind = "barrier"
			elseif d.Transparency >= 1 then kind = "marker"
			elseif d.Material == roblox.Enum.Material.Neon then kind = "neon"
			elseif d.Material == roblox.Enum.Material.Glass then kind = "water"
			elseif d.CanCollide then kind = "collide"
			elseif d.Name == "Collision" then kind = "collide"
			else kind = "visual" end
			-- kit collision boxes are invisible colliders: draw them as obstacles
			if d.Name == "Collision" and d.CanCollide then kind = "collide" end
			add(d, kind, false)
		end
	end
	fs.writeFile(process.args[2], serde.encode("json", { parts = out, scenes = {} }))
	print(#out)
	return
end
local cy = ws.Floor1:FindFirstChild("Courtyards")
for _, d in ws:GetDescendants() do
	if d:IsA("BasePart") and not d:IsA("Terrain") then
		if d.Transparency >= 1 and not d.CanCollide then continue end
		local kind = "world"
		if cy and d:IsDescendantOf(cy) then kind = "court"
		elseif d:IsDescendantOf(ws.Floor1.Town.Buildings) then kind = "bld"
		elseif d:IsDescendantOf(ws.Floor1.Polish) then kind = "polish" end
		add(d, kind, true)
	end
end
local scenes = {}
if cy then
	for _, m in cy:GetDescendants() do
		if m:IsA("Model") and m:GetAttribute("Scene") then
			local p = m.WorldPivotData
			table.insert(scenes, { n = m:GetAttribute("Scene"), x = p.Position.X, z = p.Position.Z, lx = p.LookVector.X, lz = p.LookVector.Z })
		end
	end
end
local marks = {}
local floor1 = ws.Floor1
local function mark(kind, d, label, radius)
	local cf = d.CFrame
	table.insert(marks, { k = kind, id = label, x = cf.Position.X, z = cf.Position.Z, lx = cf.LookVector.X, lz = cf.LookVector.Z, r = radius })
end
if floor1:FindFirstChild("Npcs") then
	for _, m in floor1.Npcs:GetChildren() do
		if m:IsA("BasePart") then
			mark("npc", m, m:GetAttribute("NpcId"), 3)
		else
			for _, rp in m:GetChildren() do
				mark("route", rp, rp.Name, 2)
			end
		end
	end
end
if floor1:FindFirstChild("QuestPoints") then
	for _, q in floor1.QuestPoints:GetChildren() do
		mark("point", q, q:GetAttribute("PointId"), q:GetAttribute("Radius"))
	end
end
fs.writeFile(process.args[2], serde.encode("json", { parts = out, scenes = scenes, marks = marks }))
print(#out, #scenes, #marks)
