--!strict
--[[
	Achievements
	(Phase 11.) Text lives in Strings.Achievements.List[<id>] = { Name, Description } and, for the
	ones that grant a title, Strings.Achievements.Titles[<id>] (shown under the player's name, e.g.
	"Floor 1 Pioneer", "Parry Master").

	Fields:
	  Event    GameEvents kind counted ("Kill", "Parry", "Clear", "Discover", "Quest", "LevelUp", ...)
	  Key      GameEvents key it needs ("" or nil = any, "Prefix:*" = prefix; matched with
	           Data/Quests.KeyMatches); for LevelUp the amount is compared instead
	  Count    events needed (LevelUp: the level to reach)
	  Stat     optional PlayStats field to read the starting count from (e.g. "Parries"), so
	           progress made before Phase 11 still counts
	  Title    true = unlocking grants the title Strings.Achievements.Titles[<id>]
	  Shards   Spire Shards granted on unlock
	  Hidden   not listed until unlocked (secrets)
	  Order    display order
]]

export type AchievementDef = {
	Event: string,
	Key: string?,
	Count: number,
	Stat: string?,
	Title: boolean?,
	Shards: number,
	Hidden: boolean?,
	Order: number,
}

local Achievements: { [string]: AchievementDef } = {
	FirstBlood = { Event = "Kill", Key = "", Count = 1, Stat = "Kills", Shards = 5, Order = 1 },
	CrabCracker = { Event = "Kill", Key = "Bilgecrab", Count = 25, Shards = 10, Order = 2 },
	SailorsRest = { Event = "Kill", Key = "DrownedSailor", Count = 25, Shards = 10, Order = 3 },
	WispSnuffer = { Event = "Kill", Key = "MarshWisp", Count = 25, Shards = 10, Order = 4 },
	ParryMaster = { Event = "Parry", Key = "", Count = 100, Stat = "Parries", Title = true, Shards = 20, Order = 5 },
	Untouchable = { Event = "PerfectDodge", Key = "", Count = 25, Title = true, Shards = 20, Order = 6 },
	Confluent = { Event = "Confluence", Key = "", Count = 1, Title = true, Shards = 15, Order = 7 },
	WaystoneWanderer = { Event = "Discover", Key = "Waystone:*", Count = 6, Shards = 15, Order = 8 },
	CisternDelver = { Event = "Clear", Key = "Dungeon:SunkenCistern", Count = 1, Shards = 15, Order = 9 },
	CisternRegular = { Event = "Clear", Key = "Dungeon:SunkenCistern", Count = 10, Title = true, Shards = 25, Order = 10 },
	Floor1Pioneer = { Event = "Clear", Key = "Guardian:Brinewarden", Count = 1, Title = true, Shards = 50, Order = 11 },
	WardenBreaker = { Event = "Clear", Key = "Guardian:Brinewarden", Count = 5, Title = true, Shards = 40, Order = 12 },
	Level5 = { Event = "LevelUp", Key = "", Count = 5, Shards = 10, Order = 13 },
	Level10 = { Event = "LevelUp", Key = "", Count = 10, Shards = 20, Order = 14 },
	Level12 = { Event = "LevelUp", Key = "", Count = 12, Shards = 30, Order = 15 },
	TheFirstGateOpens = { Event = "Quest", Key = "F1_M12", Count = 1, Shards = 30, Order = 16 },
	Questing = { Event = "Quest", Key = "", Count = 20, Shards = 20, Order = 17 },
	Crafter = { Event = "Craft", Key = "", Count = 10, Shards = 15, Order = 18 },
	Tidepurse = { Event = "Gold", Key = "", Count = 5000, Shards = 10, Order = 19 },
	TideTaken = { Event = "Death", Key = "", Count = 10, Stat = "Deaths", Shards = 5, Order = 20 },
	SmugglersFriend = { Event = "Discover", Key = "Secret:F1_SmugglersCove", Count = 1, Shards = 15, Hidden = true, Order = 21 },
	HollowKeeper = { Event = "Discover", Key = "Secret:F1_ForestHollow", Count = 1, Shards = 15, Hidden = true, Order = 22 },
}

local AchievementsModule = {}

function AchievementsModule.Get(id: string): AchievementDef?
	return Achievements[id]
end

function AchievementsModule.All(): { [string]: AchievementDef }
	return Achievements
end

-- Ids sorted by Order.
function AchievementsModule.Ordered(): { string }
	local out = {}
	for id in Achievements do
		table.insert(out, id)
	end
	table.sort(out, function(a: string, b: string): boolean
		return Achievements[a].Order < Achievements[b].Order
	end)
	return out
end

return table.freeze(AchievementsModule)
