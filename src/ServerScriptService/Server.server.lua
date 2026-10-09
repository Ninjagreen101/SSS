--!strict
-- Server bootstrap: the only server Script. Requires every system in a fixed
-- order, runs all Init() (wire references), then all Start() (begin running).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local Systems = script.Parent:WaitForChild("Systems")

type System = { Init: () -> any?, Start: () -> any? }

local ORDER = {
	"DataService",
	"WorldService",
	"FloorService",
	"DungeonService",
}

Net.initServer()

local loaded: { { name: string, system: System } } = {}
for _, name in ORDER do
	local module = Systems:FindFirstChild(name)
	assert(module and module:IsA("ModuleScript"), "missing system " .. name)
	table.insert(loaded, { name = name, system = require(module) :: any })
end

for _, entry in loaded do
	local ok, err = pcall(entry.system.Init)
	if not ok then
		error(string.format("[Server] %s.Init failed: %s", entry.name, tostring(err)))
	end
end

for _, entry in loaded do
	task.spawn(function()
		local ok, err = pcall(entry.system.Start)
		if not ok then
			warn(string.format("[Server] %s.Start failed: %s", entry.name, tostring(err)))
		end
	end)
end
