--!nocheck
-- Exports a place's scripts into a Rojo tree. Lists non-script instances found inside the exported
-- trees (Rojo would delete those on sync unless they are kept).
--   lune run export.luau <place.rbxl> <outDir>
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local process = require("@lune/process")
local game = roblox.deserializePlace(fs.readFile(process.args[1]))
local out = process.args[2]

local ROOTS = {
	{ "ReplicatedStorage", "Shared" },
	{ "ServerScriptService" },
	{ "ServerStorage", "Tools" },
	{ "ServerStorage", "DESIGN_DECISIONS.md" },
	{ "StarterPlayer", "StarterPlayerScripts", true },
}
local function isScript(i) return i:IsA("LuaSourceContainer") end
local function hasScriptBelow(i)
	for _, d in i:GetDescendants() do if isScript(d) then return true end end
	return false
end
local stray, files = {}, 0
local function suffix(i)
	if i.ClassName == "Script" then return ".server.lua" elseif i.ClassName == "LocalScript" then return ".client.lua" end
	return ".lua"
end
local function write(path, inst)
	if isScript(inst) then
		local kids = inst:GetChildren()
		if #kids > 0 then
			fs.writeDir(path .. "/" .. inst.Name)
			fs.writeFile(path .. "/" .. inst.Name .. "/init" .. suffix(inst), inst.Source)
			for _, c in kids do write(path .. "/" .. inst.Name, c) end
		else
			fs.writeFile(path .. "/" .. inst.Name .. suffix(inst), inst.Source)
		end
		files += 1
	elseif inst.ClassName == "Folder" and hasScriptBelow(inst) then
		fs.writeDir(path .. "/" .. inst.Name)
		for _, c in inst:GetChildren() do write(path .. "/" .. inst.Name, c) end
	else
		table.insert(stray, inst:GetFullName() .. " [" .. inst.ClassName .. "]")
	end
end
for _, r in ROOTS do
	local inst = game:GetService(r[1])
	local dir = out .. "/" .. r[1]
	fs.writeDir(dir)
	if r[3] then
		local holder = inst:FindFirstChild(r[2])
		dir ..= "/" .. r[2]
		fs.writeDir(dir)
		for _, c in holder:GetChildren() do write(dir, c) end
	elseif r[2] then
		write(dir, inst:FindFirstChild(r[2]))
	else
		for _, c in inst:GetChildren() do write(dir, c) end
	end
end
print("files", files)
for _, s in stray do print("stray", s) end
