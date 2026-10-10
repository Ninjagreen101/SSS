--!strict
--[[
	QuestText
	Everything the quest, dialogue, achievement and map UI says, read from Strings by path:
	  Strings.Quests[<id>]              Name, Summary, Objectives, Offer, Progress, Complete
	  Strings.Npcs[<id>]                Name, Role, Greetings, Idle
	  Strings.Achievements.List[<id>]   Name, Description
	  Strings.Achievements.Titles[<id>] the title shown under a player's name
	Content is written separately from the code, so every lookup falls back to the id when a key
	is missing instead of erroring.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Strings = require(Shared.Strings)
local Quests = require(Shared.Data.Quests)
local Items = require(Shared.Data.Items)
local MathUtil = require(Shared.Util.MathUtil)

local UITheme = require(script.Parent.UITheme)

local Q = Strings.QuestUI

local QuestText = {}

-- Resolves "Achievements.Titles.ParryMaster" in the Strings tree (nil if missing).
function QuestText.Lookup(path: string): any
	local node: any = Strings
	for _, key in string.split(path, ".") do
		if type(node) ~= "table" then
			return nil
		end
		node = node[key]
	end
	return node
end

local function section(name: string, id: string): { [string]: any }?
	local root = (Strings :: any)[name]
	local entry = if type(root) == "table" then root[id] else nil
	return if type(entry) == "table" then entry else nil
end

local function text(value: any, fallback: string): string
	return if type(value) == "string" and value ~= "" then value else fallback
end

local function lines(value: any): { string }
	local out: { string } = {}
	if type(value) == "table" then
		for _, line in value do
			if type(line) == "string" and line ~= "" then
				table.insert(out, line)
			end
		end
	elseif type(value) == "string" and value ~= "" then
		table.insert(out, value)
	end
	return out
end

-- QUESTS -------------------------------------------------------------------------------------

function QuestText.QuestName(id: string): string
	local entry = section("Quests", id)
	return text(entry and entry.Name, id)
end

function QuestText.QuestSummary(id: string): string
	local entry = section("Quests", id)
	return text(entry and entry.Summary, "")
end

-- The objective's line ("Slay Bilgecrabs near the Old Wharf"); falls back to "Kill Bilgecrab".
function QuestText.Objective(id: string, index: number): string
	local entry = section("Quests", id)
	local list = entry and entry.Objectives
	local line = if type(list) == "table" then list[index] else nil
	if type(line) == "string" and line ~= "" then
		return line
	end
	local def = Quests.Get(id)
	local objective = def and def.Objectives[index]
	if not objective then
		return id
	end
	local verb = if objective.Type == "Do" then objective.Event or objective.Type else objective.Type
	local target = objective.Target
	return if target and target ~= "" then `{verb} {target}` else verb
end

-- Dialogue lines for a quest stage: "Offer" | "Progress" | "Complete".
function QuestText.Dialogue(id: string, stage: string): { string }
	local entry = section("Quests", id)
	return lines(entry and entry[stage])
end

function QuestText.KindColor(kind: string): Color3
	return UITheme.Quests.KindColors[kind] or UITheme.Colors.Aqua
end

function QuestText.KindName(kind: string): string
	return Q.Tabs[kind] or kind
end

function QuestText.ItemName(defId: string): string
	local entry = (Strings.Items :: any)[defId]
	return if type(entry) == "table" and type(entry.Name) == "string" then entry.Name else defId
end

-- "150 XP  ·  25 Gold  ·  2 x Healing Draught"
function QuestText.Rewards(id: string): string
	local def = Quests.Get(id)
	if not def then
		return ""
	end
	local rewards = def.Rewards
	local parts: { string } = {}
	if rewards.XP > 0 then
		table.insert(parts, Strings.Format(Q.RewardXP, { xp = MathUtil.FormatNumber(rewards.XP) }))
	end
	if rewards.Gold > 0 then
		table.insert(parts, Strings.Format(Q.RewardGold, { gold = MathUtil.FormatNumber(rewards.Gold) }))
	end
	local shards = rewards.Shards
	if shards and shards > 0 then
		table.insert(parts, Strings.Format(Q.RewardShards, { shards = shards }))
	end
	local items = rewards.Items
	if items then
		for _, item in items do
			if Items.Get(item.Id) then
				table.insert(parts, Strings.Format(Q.RewardItem, { name = QuestText.ItemName(item.Id), count = item.Count }))
			end
		end
	end
	return table.concat(parts, "  ·  ")
end

-- "5:12:03", or "2d 4h" beyond a day.
function QuestText.Countdown(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	if s >= 86400 then
		return Strings.Format(Q.ResetDays, { days = s // 86400, hours = (s % 86400) // 3600 })
	end
	return MathUtil.FormatDuration(s)
end

-- NPCS ---------------------------------------------------------------------------------------

function QuestText.NpcName(id: string): string
	local entry = section("Npcs", id)
	return text(entry and entry.Name, id)
end

function QuestText.NpcRole(id: string): string
	local entry = section("Npcs", id)
	return text(entry and entry.Role, "")
end

function QuestText.NpcGreetings(id: string): { string }
	local entry = section("Npcs", id)
	return lines(entry and entry.Greetings)
end

-- ACHIEVEMENTS -------------------------------------------------------------------------------

local function achievementEntry(id: string): { [string]: any }?
	local root = (Strings :: any).Achievements
	local list = if type(root) == "table" then root.List else nil
	local entry = if type(list) == "table" then list[id] else nil
	return if type(entry) == "table" then entry else nil
end

function QuestText.AchievementName(id: string): string
	local entry = achievementEntry(id)
	return text(entry and entry.Name, id)
end

function QuestText.AchievementDescription(id: string): string
	local entry = achievementEntry(id)
	return text(entry and entry.Description, "")
end

-- Strings path of an achievement's title (the value of the player attribute Title).
function QuestText.TitlePath(id: string): string
	return `Achievements.Titles.{id}`
end

function QuestText.Title(id: string): string
	local value = QuestText.Lookup(QuestText.TitlePath(id))
	return text(value, id)
end

-- The title text for a player attribute value ("" or unknown = nil).
function QuestText.TitleFromPath(path: any): string?
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local value = QuestText.Lookup(path)
	return if type(value) == "string" and value ~= "" then value else nil
end

-- The achievement id inside a title path ("Achievements.Titles.ParryMaster" -> "ParryMaster").
function QuestText.TitleId(path: any): string
	if type(path) ~= "string" then
		return ""
	end
	local parts = string.split(path, ".")
	return parts[#parts] or ""
end

-- WORLD --------------------------------------------------------------------------------------

function QuestText.WaystoneName(id: string): string
	return Strings.Waystones[id] or id
end

function QuestText.FloorName(floor: string): string
	return Strings.Format(Q.MapFloor, { floor = floor, name = Strings.Guardians.Floors[floor] or floor })
end

-- A marker id's display name: an NPC, a Waystone, or (for quest points) nothing.
function QuestText.MarkerName(id: string): string?
	if section("Npcs", id) then
		return QuestText.NpcName(id)
	end
	local waystone = Strings.Waystones[id]
	if waystone then
		return waystone
	end
	return nil
end

return QuestText
