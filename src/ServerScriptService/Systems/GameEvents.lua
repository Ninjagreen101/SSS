--!strict
--[[
	GameEvents (helper, not a system)
	One server-side bus for "a player did something that matters to progress". The systems that
	know an action happened fire it here (one line each); QuestService, AchievementService and
	TutorialService listen. Nothing in this module trusts the client: only server code fires it,
	after the server has already decided the action really happened.

	Kinds and their key / amount (Phase 11, docs/PHASE11_QUESTS.md):
	  Kill          mob id (Shared.Data.Mobs, resolved)       1 per kill credited to the player
	  Collect       item def id                               count picked up / received
	  Craft         produced item def id                      count crafted
	  Discover      "Waystone:<id>" | "Secret:<id>"           1
	  Attune        Attunement name ("Tide", ...)            1
	  Clear         "Dungeon:<id>" | "Guardian:<id>"         1
	  Reach         quest point id (Workspace QuestPoints)    1 (first entry per visit)
	  Talk          npc id (Shared.Data.Npcs)                 1
	  Parry         "" (any parry)                            1
	  PerfectDodge  ""                                        1
	  Dodge         ""                                        1
	  Combo         "" (a full light combo landed)            combo length
	  Cast          spell id                                  1
	  Resonance     "" (a Resonance stack gained)             stacks now
	  Confluence    confluence id                             1
	  LevelUp       ""                                        new level
	  Region        region name (Layouts' Region names)       1 (on entering it)
	  Gold          "" (gold earned, any source)              amount
	  Quest         quest id (a quest was completed)          1
	  Death         ""                                        1
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)

export type Kind =
	"Kill"
	| "Collect"
	| "Craft"
	| "Discover"
	| "Attune"
	| "Clear"
	| "Reach"
	| "Talk"
	| "Parry"
	| "PerfectDodge"
	| "Dodge"
	| "Combo"
	| "Cast"
	| "Resonance"
	| "Confluence"
	| "LevelUp"
	| "Region"
	| "Gold"
	| "Quest"
	| "Death"

local GameEvents = {}

-- (player, kind, key, amount)
GameEvents.Fired = Signal.new() :: Signal.Signal<Player, Kind, string, number>

-- Reports one action. `key` is "" when the kind has none; `amount` defaults to 1.
function GameEvents.Fire(player: Player, kind: Kind, key: string?, amount: number?)
	if not player.Parent then
		return
	end
	GameEvents.Fired:Fire(player, kind, key or "", amount or 1)
end

return GameEvents
