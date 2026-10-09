--!nocheck
-- Offline Studio-equivalent build: loads the Rojo-built place in Lune, runs
-- WorldBuilder.Build with the real PlanApplier/KitLibrary against Lune's
-- reflection-checked Instance API, and writes the result to a place file.
-- Terrain is skipped (Lune has no voxel engine); everything else is the same
-- code path Studio runs.
--
--   rojo build default.project.json -o build/TheSpire.rbxl
--   lune run tools/lune/build_world.luau build/TheSpire.rbxl build/Lowharbor_world.rbxl Lowharbor

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local input = process.args[1] or "build/TheSpire.rbxl"
local output = process.args[2] or "build/Lowharbor_world.rbxl"
local floorId = process.args[3] or "Lowharbor"

local game = roblox.deserializePlace(fs.readFile(input))

-- Methods Studio provides that Lune's Instance API leaves to the host.
roblox.implementMethod("Instance", "WaitForChild", function(self, name)
	local child = self:FindFirstChild(name)
	assert(child, "WaitForChild: " .. self:GetFullName() .. "." .. tostring(name) .. " missing")
	return child
end)
-- Lune's built-in Instance:AddTag shadows CollectionService:AddTag, so the
-- build environment sees a small CollectionService facade instead.
local CollectionFacade = {}
function CollectionFacade:AddTag(inst, tag)
	inst:AddTag(tag)
end
function CollectionFacade:HasTag(inst, tag)
	return inst:HasTag(tag)
end
function CollectionFacade:GetTagged(tag)
	local out = {}
	for _, d in game:GetDescendants() do
		if d:HasTag(tag) then
			table.insert(out, d)
		end
	end
	return out
end
local gameFacade = {}
function gameFacade:GetService(name)
	if name == "CollectionService" then
		return CollectionFacade
	end
	return game:GetService(name)
end
roblox.implementMethod("Model", "GetPivot", function(self)
	return self.WorldPivot
end)

local cache = {}
local loading = {}
local function requireModule(ms)
	if cache[ms] ~= nil then
		return cache[ms]
	end
	assert(ms.ClassName == "ModuleScript", "require of non-ModuleScript " .. ms:GetFullName())
	assert(not loading[ms], "cyclic require " .. ms:GetFullName())
	loading[ms] = true
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
		ColorSequence = roblox.ColorSequence,
		NumberSequence = roblox.NumberSequence,
		NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
		NumberRange = roblox.NumberRange,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Region3 = roblox.Region3,
		Font = roblox.Font,
		Enum = roblox.Enum,
		task = task,
	}, { __index = _G })
	local fn = luau.load(ms.Source, { debugName = ms:GetFullName(), environment = env })
	local result = fn()
	loading[ms] = nil
	cache[ms] = result
	return result
end

local WorldBuilder = requireModule(game:GetService("ServerStorage"):FindFirstChild("WorldBuilder"))
local t0 = os.clock()
local report = WorldBuilder.Build(floorId, { terrain = false })
print(string.format("build finished in %.1fs", os.clock() - t0))

local floors = game:GetService("Workspace"):FindFirstChild("Floors")
local holder = floors and floors:FindFirstChild(floorId)
assert(holder, "no floor built")
local counts = {}
for _, d in holder:GetDescendants() do
	counts[d.ClassName] = (counts[d.ClassName] or 0) + 1
end
local keys = {}
for k in counts do
	table.insert(keys, k)
end
table.sort(keys, function(a, b)
	return counts[a] > counts[b]
end)
for _, k in keys do
	print(string.format("  %-22s %d", k, counts[k]))
end
fs.writeFile(output, roblox.serializePlace(game))
print("wrote " .. output)

-- Optional: dump every BasePart inside a box as JSON for visual verification
-- (tools/blender/preview_parts.py). Args 4..9: minX minY minZ maxX maxY maxZ.
local serde = require("@lune/serde")
if process.args[4] then
	local lo = roblox.Vector3.new(tonumber(process.args[4]), tonumber(process.args[5]), tonumber(process.args[6]))
	local hi = roblox.Vector3.new(tonumber(process.args[7]), tonumber(process.args[8]), tonumber(process.args[9]))
	local out = {}
	for _, d in game:GetService("Workspace"):GetDescendants() do
		if d:IsA("BasePart") then
			local p = d.CFrame.Position
			if p.X >= lo.X and p.X <= hi.X and p.Y >= lo.Y and p.Y <= hi.Y and p.Z >= lo.Z and p.Z <= hi.Z then
				local cf = d.CFrame
				local c = { cf:GetComponents() }
				table.insert(out, {
					name = d.Name,
					class = d.ClassName,
					shape = if d.ClassName == "Part" then d.Shape.Name else "",
					cf = c,
					size = { d.Size.X, d.Size.Y, d.Size.Z },
					color = d.Color:ToHex(),
					material = d.Material.Name,
					transparency = d.Transparency,
					collide = d.CanCollide,
				})
			end
		end
	end
	fs.writeFile(output .. ".parts.json", serde.encode("json", out))
	print(string.format("dumped %d parts", #out))
end
