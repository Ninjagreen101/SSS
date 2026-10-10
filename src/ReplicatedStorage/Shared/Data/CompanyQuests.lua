--!strict
--[[
	CompanyQuests
	The weekly Climber Company quest pool (Phase 12, docs/PHASE12_MULTIPLAYER.md). Each Monday
	00:00 UTC every Company rolls Config.Social.Company.WeeklyQuests of these, deterministically from
	its id and the week (CompanyService.Rules.RollQuests). Every member's GameEvents feed them; when
	one completes, every member who belonged to the Company at that moment is paid its Rewards
	once (online members at once, offline members on their next join).

	Player-facing text: Strings.Company.Quests[<id>] = { Name, Summary }.

	Fields:
	  Id         unique id
	  Objective  the Shared/Data/Quests objective schema (Type, Target, Event, Count; Marker unused)
	  Rewards    Gold and Shards paid to each member
]]

local Quests = require(script.Parent.Quests)

export type CompanyQuestDef = {
	Id: string,
	Objective: Quests.Objective,
	Rewards: { Gold: number, Shards: number },
}

local LIST: { CompanyQuestDef } = {
	{
		Id = "CQ_Slayers",
		Objective = { Type = "Kill", Count = 500 },
		Rewards = { Gold = 1500, Shards = 40 },
	},
	{
		Id = "CQ_Cistern",
		Objective = { Type = "Clear", Target = "Dungeon:SunkenCistern", Count = 10 },
		Rewards = { Gold = 2000, Shards = 50 },
	},
	{
		Id = "CQ_Artisans",
		Objective = { Type = "Craft", Count = 30 },
		Rewards = { Gold = 1200, Shards = 35 },
	},
	{
		Id = "CQ_Wardens",
		Objective = { Type = "Clear", Target = "Guardian:Brinewarden", Count = 3 },
		Rewards = { Gold = 2500, Shards = 60 },
	},
	{
		Id = "CQ_Parries",
		Objective = { Type = "Do", Event = "Parry", Count = 300 },
		Rewards = { Gold = 1200, Shards = 35 },
	},
	{
		Id = "CQ_Errands",
		Objective = { Type = "Do", Event = "Quest", Count = 25 },
		Rewards = { Gold = 1500, Shards = 40 },
	},
}

local byId: { [string]: CompanyQuestDef } = {}
local ids: { string } = {}
for _, def in LIST do
	byId[def.Id] = def
	table.insert(ids, def.Id)
end
table.sort(ids)

local CompanyQuests = {}

function CompanyQuests.Get(id: string): CompanyQuestDef?
	return byId[id]
end

-- Every quest id, sorted (the roll's pool order).
function CompanyQuests.Ids(): { string }
	return table.clone(ids)
end

-- Does GameEvents (kind, key) count toward quest `id`?
function CompanyQuests.Matches(id: string, kind: string, key: string): boolean
	local def = byId[id]
	return def ~= nil and Quests.Matches(def.Objective, kind, key)
end

return table.freeze(CompanyQuests)
