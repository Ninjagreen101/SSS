--!strict
-- Client bootstrap: the only LocalScript. Requires every controller in a
-- fixed order, runs all Init() then all Start().

local Controllers = script.Parent:WaitForChild("Controllers")

type Controller = { Init: () -> any?, Start: () -> any? }

local ORDER = {
	"SettingsController",
	"LightingController",
	"CanalController",
	"AmbientController",
	"PromptController",
	"WorldFeedbackController",
	"ZoneController",
	"WaystoneController",
}

local loaded: { { name: string, controller: Controller } } = {}
for _, name in ORDER do
	local module = Controllers:WaitForChild(name)
	assert(module:IsA("ModuleScript"), "missing controller " .. name)
	table.insert(loaded, { name = name, controller = require(module) :: any })
end

for _, entry in loaded do
	local ok, err = pcall(entry.controller.Init)
	if not ok then
		warn(string.format("[Client] %s.Init failed: %s", entry.name, tostring(err)))
	end
end

for _, entry in loaded do
	task.spawn(function()
		local ok, err = pcall(entry.controller.Start)
		if not ok then
			warn(string.format("[Client] %s.Start failed: %s", entry.name, tostring(err)))
		end
	end)
end
