--!strict
-- WorldBuilder: edit-time entry point. Never required at runtime.
--
-- Studio command bar (or the WorldBuilder plugin buttons):
--   local WB = require(game.ServerStorage.WorldBuilder)
--   WB.ImportKit()                  -- after importing assets/kit/fbx into ReplicatedStorage/Assets/Kit
--   WB.Build("Lowharbor")           -- terrain + world + dungeon template
--   WB.Build("Lowharbor", { terrain = false })   -- rebuild only the static world
--   WB.Clear("Lowharbor")
--
-- Results: Workspace/Floors/<FloorId> (static Models, saved with the place),
-- ServerStorage/DungeonTemplates/<DungeonId>, ServerStorage/BuildReports/<FloorId>.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Floors = require(Shared.Data.Floors)

local FloorPlanner = require(script.Plan.FloorPlanner)
local PlanApplier = require(script.PlanApplier)
local TerrainApplier = require(script.TerrainApplier)
local KitLibrary = require(script.KitLibrary)

export type BuildOptions = {
	terrain: boolean?,
	world: boolean?,
	dungeon: boolean?,
}

local WorldBuilder = {}

local function folder(parent: Instance, name: string): Folder
	local f = parent:FindFirstChild(name)
	if f and f:IsA("Folder") then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = name
	nf.Parent = parent
	return nf
end

local function configurePlace()
	local s = Config.World.Streaming
	Workspace.StreamingEnabled = s.Enabled
	Workspace.StreamingTargetRadius = s.TargetRadius
	Workspace.StreamingMinRadius = s.MinRadius
	Lighting.Technology = Enum.Technology.Future
end

function WorldBuilder.ImportKit(): number
	local fixed, warnings = KitLibrary.fixupImported()
	for _, w in warnings do
		warn("[WorldBuilder] " .. w)
	end
	print(string.format("[WorldBuilder] kit fixup: %d meshes configured", fixed))
	return fixed
end

function WorldBuilder.Clear(floorId: string)
	local floors = Workspace:FindFirstChild("Floors")
	if floors then
		local f = floors:FindFirstChild(floorId)
		if f then
			f:Destroy()
		end
	end
end

function WorldBuilder.Build(floorId: string, options: BuildOptions?): string
	local opts: BuildOptions = options or {}
	local floor = Floors.ById[floorId]
	assert(floor, "unknown floor " .. floorId)
	configurePlace()
	KitLibrary.refresh()

	local t0 = os.clock()
	local fp = FloorPlanner.plan(floor)
	local lines = { string.format("Floor %s planned in %.1fs", floorId, os.clock() - t0) }
	for _, l in fp.log do
		table.insert(lines, l)
	end

	if opts.terrain ~= false then
		local tt = os.clock()
		TerrainApplier.apply(fp.field, floor, fp.carves, {
			onProgress = function(done: number, total: number)
				if done % 16 == 0 or done == total then
					print(string.format("[WorldBuilder] terrain %d/%d", done, total))
				end
			end,
		})
		table.insert(lines, string.format("terrain written in %.1fs", os.clock() - tt))
	end

	if opts.world ~= false then
		WorldBuilder.Clear(floorId)
		local floorsFolder = folder(Workspace, "Floors")
		local holder = Instance.new("Folder")
		holder.Name = floorId
		holder:SetAttribute("FloorIndex", floor.index)
		holder.Parent = floorsFolder
		local tw = os.clock()
		local _, stats = PlanApplier.apply(fp.root, holder, {
			onProgress = function(done: number)
				if done % 6000 == 0 then
					print(string.format("[WorldBuilder] world instances %d", done))
				end
			end,
		})
		local count = #holder:GetDescendants()
		table.insert(lines, string.format(
			"world: %d models, %d parts, %d lights, %d emitters, %d markers (%d blockout pieces) in %.1fs",
			stats.models, stats.parts, stats.lights, stats.emitters, stats.markers, stats.blockouts, os.clock() - tw
		))
		table.insert(lines, string.format("instances in Workspace/Floors/%s: %d (budget %d)", floorId, count, Config.World.InstanceBudgetPerFloor))
		if count > Config.World.InstanceBudgetPerFloor * 1.05 then
			warn(string.format("[WorldBuilder] %s is over the instance budget (%d)", floorId, count))
		end
	end

	if opts.dungeon ~= false then
		local templates = folder(ServerStorage, "DungeonTemplates")
		local existing = templates:FindFirstChild(floor.dungeon.id)
		if existing then
			existing:Destroy()
		end
		local holder = Instance.new("Folder")
		holder.Name = "_building"
		holder.Parent = templates
		local model = PlanApplier.apply(fp.dungeon, holder, {})
		model.Name = floor.dungeon.id
		model.Parent = templates
		holder:Destroy()
		table.insert(lines, string.format("dungeon template %s: %d instances", floor.dungeon.id, #model:GetDescendants()))
	end

	local report = table.concat(lines, "\n")
	local reports = folder(ServerStorage, "BuildReports")
	local sv = reports:FindFirstChild(floorId) :: StringValue?
	if not sv then
		local nsv = Instance.new("StringValue")
		nsv.Name = floorId
		nsv.Parent = reports
		sv = nsv
	end
	(sv :: StringValue).Value = report
	print("[WorldBuilder]\n" .. report)
	return report
end

return WorldBuilder
