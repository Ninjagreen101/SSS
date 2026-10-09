local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local process = require("@lune/process")
local serde = require("@lune/serde")
local game = roblox.deserializePlace(fs.readFile(process.args[1]))
local ws = game:GetService("Workspace")
local out = {}
local function add(d, kind)
	local cf, s = d.CFrame, d.Size
	local p = cf.Position
	if p.X < -900 or p.X > 120 or p.Z < -720 or p.Z > 780 then return end
	if s.X > 400 or s.Z > 400 then return end
	local function c(x, z)
		local w = cf:PointToWorldSpace(roblox.Vector3.new(x, 0, z))
		return { math.floor(w.X * 10) / 10, math.floor(w.Z * 10) / 10 }
	end
	table.insert(out, { k = kind, y = math.floor(p.Y), pts = { c(-s.X/2, -s.Z/2), c(s.X/2, -s.Z/2), c(s.X/2, s.Z/2), c(-s.X/2, s.Z/2) } })
end
local cy = ws.Floor1:FindFirstChild("Courtyards")
for _, d in ws:GetDescendants() do
	if d:IsA("BasePart") and not d:IsA("Terrain") then
		if d.Transparency >= 1 and not d.CanCollide then continue end
		local kind = "world"
		if cy and d:IsDescendantOf(cy) then kind = "court"
		elseif d:IsDescendantOf(ws.Floor1.Town.Buildings) then kind = "bld"
		elseif d:IsDescendantOf(ws.Floor1.Polish) then kind = "polish" end
		add(d, kind)
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
fs.writeFile(process.args[2], serde.encode("json", { parts = out, scenes = scenes }))
print(#out, #scenes)
