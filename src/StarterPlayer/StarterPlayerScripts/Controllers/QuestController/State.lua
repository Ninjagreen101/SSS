--!strict
--[[
	Quest state, read from the replicated profile (DataController). The server owns every rule;
	this only answers display questions: is a quest available from this NPC, ready to hand in,
	which objective is next, and where its marker points.

	Profile (v6): Quests = { Active = { [id] = { Stage, Progress = { ["1"] = n }, StartedAt } },
	Completed = { [id] = unix }, Tracked, Dailies, Weeklies, Rerolls, DailyResetAt, WeeklyResetAt }.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Quests = require(Shared.Data.Quests)
local Npcs = require(Shared.Data.Npcs)

local DataController = require(script.Parent.Parent.DataController)

export type Status = "Locked" | "Available" | "Active" | "Ready" | "Completed"

export type QuestState = {
	Stage: number,
	Progress: { [string]: number },
	StartedAt: number,
}

local KIND_ORDER: { [string]: number } = { Main = 1, Side = 2, Daily = 3, Weekly = 4, Tutorial = 5 }

local State = {}

local function quests(): { [string]: any }?
	local value = DataController.Get({ "Quests" })
	return if type(value) == "table" then value else nil
end

function State.Active(id: string): QuestState?
	local q = quests()
	local active = q and q.Active
	local entry = if type(active) == "table" then active[id] else nil
	return if type(entry) == "table" then entry :: QuestState else nil
end

function State.IsCompleted(id: string): boolean
	local q = quests()
	local completed = q and q.Completed
	return type(completed) == "table" and completed[id] ~= nil
end

-- (done, needed) for one objective of an active quest.
function State.Progress(id: string, index: number): (number, number)
	local def = Quests.Get(id)
	local objective = def and def.Objectives[index]
	local needed = if objective then objective.Count else 1
	if State.IsCompleted(id) and not State.Active(id) then
		return needed, needed
	end
	local active = State.Active(id)
	local progress = active and active.Progress
	local value = if type(progress) == "table" then progress[tostring(index)] else nil
	return math.min(if type(value) == "number" then value else 0, needed), needed
end

function State.ObjectiveDone(id: string, index: number): boolean
	local done, needed = State.Progress(id, index)
	return done >= needed
end

-- Sequential quests show only the objectives up to the current one.
function State.ObjectiveVisible(id: string, index: number): boolean
	local def = Quests.Get(id)
	if not def or not def.Sequential then
		return true
	end
	for previous = 1, index - 1 do
		if not State.ObjectiveDone(id, previous) then
			return false
		end
	end
	return true
end

function State.IsReady(id: string): boolean
	local def = Quests.Get(id)
	if not def or not State.Active(id) then
		return false
	end
	for index in def.Objectives do
		if not State.ObjectiveDone(id, index) then
			return false
		end
	end
	return true
end

-- First objective that isn't done yet (nil when all are).
function State.CurrentObjective(id: string): number?
	local def = Quests.Get(id)
	if not def then
		return nil
	end
	for index in def.Objectives do
		if not State.ObjectiveDone(id, index) then
			return index
		end
	end
	return nil
end

function State.RequirementsMet(id: string): boolean
	local def = Quests.Get(id)
	if not def then
		return false
	end
	local requires = def.Requires
	if requires then
		for _, required in requires do
			if not State.IsCompleted(required) then
				return false
			end
		end
	end
	return true
end

function State.Status(id: string): Status
	if State.Active(id) then
		return if State.IsReady(id) then "Ready" else "Active"
	end
	if State.IsCompleted(id) then
		return "Completed"
	end
	local def = Quests.Get(id)
	if def and def.Giver and State.RequirementsMet(id) then
		return "Available"
	end
	return "Locked"
end

local function sortIds(ids: { string })
	table.sort(ids, function(a: string, b: string): boolean
		local da, db = Quests.Get(a), Quests.Get(b)
		local ka = if da then KIND_ORDER[da.Kind] or 9 else 9
		local kb = if db then KIND_ORDER[db.Kind] or 9 else 9
		if ka ~= kb then
			return ka < kb
		end
		local oa = if da then da.Order or math.huge else math.huge
		local ob = if db then db.Order or math.huge else math.huge
		if oa ~= ob then
			return oa < ob
		end
		return a < b
	end)
end
State.Sort = sortIds

-- Every active quest id that has a definition, story first.
function State.ActiveIds(): { string }
	local out: { string } = {}
	local q = quests()
	local active = q and q.Active
	if type(active) == "table" then
		for id in active do
			if type(id) == "string" and Quests.Get(id) then
				table.insert(out, id)
			end
		end
	end
	sortIds(out)
	return out
end

-- Completed quest ids of one kind (newest first).
function State.CompletedIds(kind: string): { string }
	local out: { string } = {}
	local q = quests()
	local completed = q and q.Completed
	if type(completed) == "table" then
		for id in completed do
			local def = Quests.Get(id)
			if def and def.Kind == kind and not State.Active(id) then
				table.insert(out, id)
			end
		end
		table.sort(out, function(a: string, b: string): boolean
			local ta, tb = completed[a], completed[b]
			if type(ta) == "number" and type(tb) == "number" and ta ~= tb then
				return ta > tb
			end
			return a < b
		end)
	end
	return out
end

-- Today's rolled dailies ("Dailies") or this week's weeklies ("Weeklies").
function State.Rolled(key: string): { string }
	local q = quests()
	local list = q and q[key]
	local out: { string } = {}
	if type(list) == "table" then
		for _, id in list do
			if type(id) == "string" and Quests.Get(id) then
				table.insert(out, id)
			end
		end
	end
	return out
end

function State.ResetAt(key: string): number
	local q = quests()
	local value = q and q[key]
	return if type(value) == "number" then value else 0
end

-- Daily rerolls left. The profile counts rerolls used today (Quests.Rerolls).
function State.RerollsLeft(): number
	local q = quests()
	local used = q and q.Rerolls
	return math.max(0, Config.Quests.DailyRerolls - (if type(used) == "number" then used else 0))
end

function State.Tracked(): string?
	local q = quests()
	local tracked = q and q.Tracked
	if type(tracked) == "string" and tracked ~= "" and State.Active(tracked) then
		return tracked
	end
	return nil
end

-- Quests for the HUD tracker: the tracked one first, then the rest of the log, story first.
function State.TrackerIds(max: number): { string }
	local out: { string } = {}
	local tracked = State.Tracked()
	if tracked then
		table.insert(out, tracked)
	end
	for _, id in State.ActiveIds() do
		if #out >= max then
			break
		end
		if id ~= tracked then
			table.insert(out, id)
		end
	end
	return out
end

-- NPCS -----------------------------------------------------------------------------------------

-- Quests this NPC can offer right now.
function State.AvailableFrom(npcId: string): { string }
	local out: { string } = {}
	local npc = Npcs.Get(npcId)
	if not npc then
		return out
	end
	for _, id in npc.Gives do
		local def = Quests.Get(id)
		if def and def.Giver == npcId and State.Status(id) == "Available" then
			table.insert(out, id)
		end
	end
	sortIds(out)
	return out
end

-- Active quests ready to hand in to this NPC.
function State.ReadyFor(npcId: string): { string }
	local out: { string } = {}
	for _, id in State.ActiveIds() do
		local def = Quests.Get(id)
		if def and def.TurnIn == npcId and State.IsReady(id) then
			table.insert(out, id)
		end
	end
	return out
end

-- Active quests this NPC gave or takes back, still in progress.
function State.InProgressWith(npcId: string): { string }
	local out: { string } = {}
	for _, id in State.ActiveIds() do
		local def = Quests.Get(id)
		if def and (def.TurnIn == npcId or def.Giver == npcId) and not State.IsReady(id) then
			table.insert(out, id)
		end
	end
	return out
end

-- "?" (ready to hand in), "!" (has a quest to offer) or nil.
function State.NpcMark(npcId: string): ("Ready" | "Available")?
	if #State.ReadyFor(npcId) > 0 then
		return "Ready"
	end
	if #State.AvailableFrom(npcId) > 0 then
		return "Available"
	end
	return nil
end

-- MARKERS --------------------------------------------------------------------------------------

-- Where an objective's marker points (nil = no marker).
function State.ObjectiveMarker(id: string, index: number): string?
	local def = Quests.Get(id)
	local objective = def and def.Objectives[index]
	local marker = objective and objective.Marker
	return if marker and marker ~= "" then marker else nil
end

-- Where a quest points now: its hand-in NPC once ready, otherwise its next objective's marker.
-- Returns (markerId, isTurnIn).
function State.Marker(id: string): (string?, boolean)
	local def = Quests.Get(id)
	if not def then
		return nil, false
	end
	if State.IsReady(id) then
		return def.TurnIn, true
	end
	local index = State.CurrentObjective(id)
	if index then
		return State.ObjectiveMarker(id, index), false
	end
	return nil, false
end

return State
