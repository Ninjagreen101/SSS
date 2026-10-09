--!strict
--[[
	Achievements
	(Phase 11.) Text lives in Strings.Achievements.List[<id>] = { Name, Description } and, for the
	ones that grant a title, Strings.Achievements.Titles[<id>] (shown under the player's name, e.g.
	"Floor 1 Pioneer", "Parry Master").

	Fields:
	  Event    GameEvents kind counted ("Kill", "Parry", "Clear", "Discover", "Quest", "LevelUp", ...)
	  Key      GameEvents key it needs ("" or nil = any); for LevelUp the amount is compared instead
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

local Achievements: { [string]: AchievementDef } = {}

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
