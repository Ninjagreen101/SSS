--!strict
--[[
	Points
	Everything the Map (M) and the minimap mark, for one floor:
	- Waystone: every Waystone this client has seen (QuestController.WorldPoints remembers the
	  positions of streamed-out ones), lit when discovered (profile Waystones.Discovered).
	- Quest: each active quest's current marker (its next objective, or its hand-in NPC once ready).
	- Npc: NPCs with a quest to offer ("!").
	- Pin: the player's custom pins (profile Map.Pins[floor]).
	Positions come from the live world, so only the floor this server runs has Waystones, quests
	and NPCs; pins show on every floor.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Quests = require(Shared.Data.Quests)
local Npcs = require(Shared.Data.Npcs)

local DataController = require(script.Parent.Parent.DataController)
local QuestController = require(script.Parent.Parent.QuestController)

local Surface = require(script.Parent.Surface)

export type Kind = "Waystone" | "Quest" | "Npc" | "Pin"

export type Point = {
	Kind: Kind,
	Id: string, -- waystone id, quest id, npc id, or the pin's index
	World: Vector2, -- (x, z)
	Discovered: boolean, -- waystones
	Tracked: boolean, -- quests
	TurnIn: boolean, -- quests: the marker is the hand-in NPC
	Marker: string?, -- quests: the marker id
}

local Points = {}

local function point(kind: Kind, id: string, world: Vector2): Point
	return { Kind = kind, Id = id, World = world, Discovered = false, Tracked = false, TurnIn = false, Marker = nil }
end

function Points.Pins(floor: string): { Point }
	local out: { Point } = {}
	local pins = DataController.Get({ "Map", "Pins", floor })
	if type(pins) == "table" then
		for index, pin in pins do
			if type(pin) == "table" and type(pin.X) == "number" and type(pin.Z) == "number" then
				table.insert(out, point("Pin", tostring(index), Vector2.new(pin.X, pin.Z)))
			end
		end
	end
	return out
end

function Points.Collect(floor: string): { Point }
	local out: { Point } = {}
	if floor == Surface.CurrentFloor() then
		local WorldPoints = QuestController.WorldPoints
		local State = QuestController.State
		for id, position in WorldPoints.Waystones() do
			local entry = point("Waystone", id, Vector2.new(position.X, position.Z))
			entry.Discovered = DataController.Get({ "Waystones", "Discovered", id }) == true
			table.insert(out, entry)
		end
		local questTargets: { [string]: boolean } = {}
		for _, active in QuestController.ActiveMarkers() do
			local def = Quests.Get(active.QuestId)
			local position = WorldPoints.Position(active.Marker)
			if def and def.Floor == floor and position then
				local entry = point("Quest", active.QuestId, Vector2.new(position.X, position.Z))
				entry.Tracked = active.Tracked
				entry.TurnIn = active.TurnIn
				entry.Marker = active.Marker
				table.insert(out, entry)
				questTargets[active.Marker] = true
			end
		end
		for npcId, def in Npcs.All() do
			if def.Floor == floor and not questTargets[npcId] and State.NpcMark(npcId) == "Available" then
				local position = WorldPoints.Position(npcId)
				if position then
					table.insert(out, point("Npc", npcId, Vector2.new(position.X, position.Z)))
				end
			end
		end
	end
	for _, pin in Points.Pins(floor) do
		table.insert(out, pin)
	end
	return out
end

return Points
