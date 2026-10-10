--!strict
--[[
	WorldPoints
	Where quest markers point. A marker id is an NPC id (tag SpireNpc, attribute NpcId), a quest
	point id (tag SpireQuestPoint, attribute PointId) or a Waystone id (tag Waystone, attribute
	WaystoneId). NPC markers in Workspace.Floor<N>.Npcs (attribute NpcId) count too.

	With streaming on, far parts of the world are not on the client. Every position seen is
	remembered, so a marker keeps pointing at a place after it streams out; live instances win
	while they exist (NPCs walk their routes).
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Attributes)
local Signal = require(Shared.Util.Signal)

local A = Attributes.Names
local T = Attributes.Tags

export type Kind = "Npc" | "Point" | "Waystone"

local WorldPoints = {}

-- Fired when a point is first seen or a live instance (re)appears: (kind, id).
WorldPoints.Changed = Signal.new() :: Signal.Signal<Kind, string>

local live: { [string]: Instance } = {} -- id -> live instance (model or part)
local cached: { [string]: Vector3 } = {}
local kinds: { [string]: Kind } = {}
local npcModels: { [string]: Model } = {}
local started = false

local function positionOf(instance: Instance): Vector3?
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	elseif instance:IsA("BasePart") then
		return instance.Position
	end
	return nil
end

local function remember(kind: Kind, id: string, instance: Instance, isLive: boolean)
	if id == "" then
		return
	end
	local position = positionOf(instance)
	if not position then
		return
	end
	local isNew = not cached[id]
	-- A live NPC model outranks its static marker part.
	if isLive or not live[id] then
		live[id] = instance
	end
	cached[id] = position
	kinds[id] = kind
	if kind == "Npc" and instance:IsA("Model") and CollectionService:HasTag(instance, T.Npc) then
		npcModels[id] = instance
	end
	if isNew or isLive then
		WorldPoints.Changed:Fire(kind, id)
	end
end

local function forget(id: string, instance: Instance)
	local position = positionOf(instance)
	if position then
		cached[id] = position
	end
	if live[id] == instance then
		live[id] = nil
	end
	if npcModels[id] == instance then
		npcModels[id] = nil
	end
end

local function watchTag(tag: string, attribute: string, kind: Kind)
	local function added(instance: Instance)
		local id = instance:GetAttribute(attribute)
		if type(id) == "string" then
			remember(kind, id, instance, true)
		end
	end
	for _, instance in CollectionService:GetTagged(tag) do
		added(instance)
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(added)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance: Instance)
		local id = instance:GetAttribute(attribute)
		if type(id) == "string" then
			forget(id, instance)
		end
	end)
end

-- Static NPC marker parts (Workspace.Floor<N>.Npcs): remembered, never preferred over a live model.
local function watchNpcMarkers(folder: Instance)
	local function consider(instance: Instance)
		if instance:IsA("BasePart") then
			local id = instance:GetAttribute(A.NpcId)
			if type(id) == "string" and not npcModels[id] then
				remember("Npc", id, instance, false)
			end
		end
	end
	for _, descendant in folder:GetDescendants() do
		consider(descendant)
	end
	folder.DescendantAdded:Connect(consider)
end

local function watchFloor(child: Instance)
	if not string.match(child.Name, "^Floor%d+$") then
		return
	end
	local npcs = child:FindFirstChild("Npcs")
	if npcs then
		watchNpcMarkers(npcs)
	end
	child.ChildAdded:Connect(function(grandchild: Instance)
		if grandchild.Name == "Npcs" then
			watchNpcMarkers(grandchild)
		end
	end)
end

function WorldPoints.Start()
	if started then
		return
	end
	started = true
	watchTag(T.Npc, A.NpcId, "Npc")
	watchTag(T.QuestPoint, A.PointId, "Point")
	watchTag(T.Waystone, A.WaystoneId, "Waystone")
	for _, child in Workspace:GetChildren() do
		watchFloor(child)
	end
	Workspace.ChildAdded:Connect(watchFloor)
end

-- Current (or last known) position of a marker id.
function WorldPoints.Position(id: string): Vector3?
	local instance = live[id]
	if instance and instance.Parent then
		local position = positionOf(instance)
		if position then
			cached[id] = position
			return position
		end
	end
	return cached[id]
end

function WorldPoints.Kind(id: string): Kind?
	return kinds[id]
end

-- The live NPC model for an id (nil while streamed out).
function WorldPoints.NpcModel(id: string): Model?
	local model = npcModels[id]
	if model and model.Parent then
		return model
	end
	return nil
end

function WorldPoints.NpcModels(): { [string]: Model }
	return npcModels
end

-- Every known Waystone id with its last known position.
function WorldPoints.Waystones(): { [string]: Vector3 }
	local out: { [string]: Vector3 } = {}
	for id, kind in kinds do
		if kind == "Waystone" then
			local position = WorldPoints.Position(id)
			if position then
				out[id] = position
			end
		end
	end
	return out
end

return WorldPoints
