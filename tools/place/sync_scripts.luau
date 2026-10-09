--!nocheck
-- Offline script sync: writes every script in src/ into a copy of the place and keeps everything
-- else (world, kit, terrain, lighting) as it is. Existing scripts get their Source replaced, missing
-- ones are created (with Folders for missing directories). Optionally runs an edit-time tool
-- afterwards, the way Studio's command bar would.
--
--   lune run tools/place/sync_scripts.luau <in.rbxl> <out.rbxl> [--courtyards]
--
-- --courtyards runs Tools.Floor1Courtyards.Apply with the analytic ground (Layout.Height), since
-- Lune has no voxel engine. Run Floor1Courtyards.Resnap() in Studio afterwards to seat the scenes
-- on the voxel surface.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

local input, output = process.args[1], process.args[2]
assert(input and output and input ~= output, "usage: sync_scripts.luau <in.rbxl> <out.rbxl> [--courtyards]")
local runCourtyards = table.find(process.args, "--courtyards") ~= nil

local game = roblox.deserializePlace(fs.readFile(input))
local Instance = roblox.Instance

-- Where each top-level src directory lands.
local ROOTS = {
	{ dir = "src/ReplicatedStorage", parent = game:GetService("ReplicatedStorage") },
	{ dir = "src/ServerScriptService", parent = game:GetService("ServerScriptService") },
	{ dir = "src/ServerStorage", parent = game:GetService("ServerStorage") },
	{
		dir = "src/StarterPlayer/StarterPlayerScripts",
		parent = game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts"),
	},
}

local created, updated = 0, 0

local function classFor(file: string): (string, string)
	for _, rule in { { ".server.lua", "Script" }, { ".client.lua", "LocalScript" }, { ".lua", "ModuleScript" } } do
		if string.sub(file, -#rule[1]) == rule[1] then
			return string.sub(file, 1, -#rule[1] - 1), rule[2]
		end
	end
	return file, ""
end

local function ensure(parent, name: string, class: string)
	local existing = parent:FindFirstChild(name)
	if existing then
		assert(existing.ClassName == class, existing:GetFullName() .. " is a " .. existing.ClassName .. ", src has a " .. class)
		return existing
	end
	local inst = Instance.new(class)
	inst.Name = name
	inst.Parent = parent
	created += 1
	print("  created " .. inst:GetFullName())
	return inst
end

local function setSource(inst, source: string)
	if inst.Source ~= source then
		local fresh = inst.Source == ""
		inst.Source = source
		if not fresh then
			updated += 1
			print("  updated " .. inst:GetFullName())
		end
	end
end

local function sync(dir: string, parent)
	local entries = fs.readDir(dir)
	table.sort(entries)
	for _, entry in entries do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			-- a directory is a script with children when it holds an init file, else a Folder
			local initClass, initFile = nil, nil
			for _, f in fs.readDir(path) do
				local base, class = classFor(f)
				if base == "init" and class ~= "" then
					initClass, initFile = class, f
				end
			end
			local inst = ensure(parent, entry, initClass or "Folder")
			if initFile then
				setSource(inst, fs.readFile(path .. "/" .. initFile))
			end
			sync(path, inst)
		else
			local name, class = classFor(entry)
			if class ~= "" and name ~= "init" then
				setSource(ensure(parent, name, class), fs.readFile(path))
			end
		end
	end
end

for _, root in ROOTS do
	sync(root.dir, root.parent)
end
print(string.format("scripts: %d updated, %d created", updated, created))

if runCourtyards then
	-- A minimal module runtime for edit-time tools (Studio services Lune leaves to the host).
	roblox.implementMethod("Instance", "WaitForChild", function(self, name)
		local child = self:FindFirstChild(name)
		assert(child, "WaitForChild: " .. self:GetFullName() .. "." .. tostring(name) .. " missing")
		return child
	end)
	local CollectionFacade = {}
	function CollectionFacade:AddTag(inst, tag)
		inst:AddTag(tag)
	end
	function CollectionFacade:HasTag(inst, tag)
		return inst:HasTag(tag)
	end
	function CollectionFacade:GetTags(inst)
		return inst:GetTags()
	end
	local HttpFacade = {}
	function HttpFacade:JSONDecode(text)
		return serde.decode("json", text)
	end
	function HttpFacade:JSONEncode(value)
		return serde.encode("json", value)
	end
	local gameFacade = {}
	function gameFacade:GetService(name)
		if name == "CollectionService" then
			return CollectionFacade
		elseif name == "HttpService" then
			return HttpFacade
		end
		return game:GetService(name)
	end
	local cache = {}
	local function requireModule(ms)
		if cache[ms] ~= nil then
			return cache[ms]
		end
		local env = setmetatable({
			script = ms,
			game = gameFacade,
			workspace = game:GetService("Workspace"),
			require = requireModule,
			Instance = roblox.Instance,
			Vector3 = roblox.Vector3,
			Vector2 = roblox.Vector2,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			Enum = roblox.Enum,
			task = task,
		}, { __index = _G })
		local result = luau.load(ms.Source, { debugName = ms:GetFullName(), environment = env })()
		cache[ms] = result
		return result
	end

	local tools = game:GetService("ServerStorage"):FindFirstChild("Tools")
	local Layout = requireModule(tools.Layouts.Floor1)
	local Courtyards = requireModule(tools.Floor1Courtyards)
	local floor = game:GetService("Workspace"):FindFirstChild("Floor1")
	if floor and floor:FindFirstChild("Courtyards") then
		Courtyards.Undo()
	end
	local counts = Courtyards.Apply({ Ground = Layout.Height })
	local root = floor:FindFirstChild("Courtyards")
	-- Lune keeps WorldPivot in memory only; the file format stores it as WorldPivotData
	local parts, lights = 0, 0
	for _, d in root:GetDescendants() do
		if d:IsA("Model") then
			d.WorldPivotData = d.WorldPivot
		elseif d:IsA("BasePart") then
			parts += 1
		elseif d:IsA("Light") then
			lights += 1
		end
	end
	local kinds = {}
	for k, v in counts do
		table.insert(kinds, k .. "=" .. v)
	end
	table.sort(kinds)
	print("courtyards: " .. table.concat(kinds, " "))
	print(string.format("courtyards: %d instances, %d parts, %d lights", #root:GetDescendants(), parts, lights))
end

fs.writeFile(output, roblox.serializePlace(game))
print("wrote " .. output)
