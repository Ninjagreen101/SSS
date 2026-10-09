--!strict
--[[
	Quests
	Every quest's mechanics (Phase 11; design in docs/PHASE11_QUESTS.md). Player-facing text lives
	in Strings.Quests[<id>] = { Name, Summary, Objectives = { one line per objective },
	Offer = { lines }, Progress = { lines }, Complete = { lines } } (dialogue lines in order).

	Quest fields:
	  Kind        "Main" | "Side" | "Daily" | "Weekly" | "Tutorial"
	  Floor       floor id ("1")
	  Order       main story position (1..n); nil for others
	  Level       recommended level (shown in the log; never a hard gate)
	  Giver       npc id that offers it; nil = given automatically (tutorial hand-off, dailies)
	  TurnIn      npc id to hand it in to; nil = completes on the spot when objectives are done
	  Requires    quest ids that must be completed first (main story: the previous one)
	  Sequential  objectives unlock one at a time, in order (stage = current objective index)
	  Pool        dailies/weeklies only: "Kill" | "Gather" | "Dungeon" (dailies), "Weekly"
	  Objectives  see below
	  Rewards     XP, Gold, Shards, Items ({ Id, Count, Rarity? })

	Objective fields:
	  Type    "Kill" | "Collect" | "Craft" | "Discover" | "Attune" | "Clear" | "Reach" | "Talk" | "Do"
	          (the GameEvents kind it counts; "Do" counts Parry / PerfectDodge / Dodge / Combo / Cast /
	          Resonance / Confluence named in Event)
	  Target  the GameEvents key it needs ("" or nil = any key), e.g. "Bilgecrab", "Waystone:F1_RustwoodCamp",
	          "Dungeon:SunkenCistern", "Guardian:Brinewarden", npc id, point id, item id
	  Event   "Do" only: the GameEvents kind ("Parry", "Combo", ...)
	  Count   how many
	  Marker  where the tracker / world marker points: a quest point id, an npc id, or a waystone id;
	          nil = no marker (e.g. "craft anywhere")
]]

export type QuestKind = "Main" | "Side" | "Daily" | "Weekly" | "Tutorial"
export type ObjectiveType = "Kill" | "Collect" | "Craft" | "Discover" | "Attune" | "Clear" | "Reach" | "Talk" | "Do"
export type Pool = "Kill" | "Gather" | "Dungeon" | "Weekly"

export type Objective = {
	Type: ObjectiveType,
	Target: string?,
	Event: string?,
	Count: number,
	Marker: string?,
}

export type RewardItem = { Id: string, Count: number, Rarity: string? }

export type QuestDef = {
	Kind: QuestKind,
	Floor: string,
	Order: number?,
	Level: number,
	Giver: string?,
	TurnIn: string?,
	Requires: { string }?,
	Sequential: boolean?,
	Pool: Pool?,
	Objectives: { Objective },
	Rewards: { XP: number, Gold: number, Shards: number?, Items: { RewardItem }? },
}

local Quests: { [string]: QuestDef } = {}

local QuestsModule = {}

function QuestsModule.Get(id: string): QuestDef?
	return Quests[id]
end

function QuestsModule.All(): { [string]: QuestDef }
	return Quests
end

-- Quest ids of one kind (sorted by Order, then id), optionally for one floor.
function QuestsModule.OfKind(kind: QuestKind, floor: string?): { string }
	local out = {}
	for id, def in Quests do
		if def.Kind == kind and (floor == nil or def.Floor == floor) then
			table.insert(out, id)
		end
	end
	table.sort(out, function(a: string, b: string): boolean
		local oa, ob = Quests[a].Order or math.huge, Quests[b].Order or math.huge
		if oa ~= ob then
			return oa < ob
		end
		return a < b
	end)
	return out
end

-- Daily / weekly ids in a pool (sorted), for deterministic rolls.
function QuestsModule.InPool(pool: Pool): { string }
	local out = {}
	for id, def in Quests do
		if def.Pool == pool then
			table.insert(out, id)
		end
	end
	table.sort(out)
	return out
end

-- Does objective `objective` count GameEvents (kind, key)?
function QuestsModule.Matches(objective: Objective, kind: string, key: string): boolean
	local wanted = if objective.Type == "Do" then objective.Event else objective.Type
	if wanted ~= kind then
		return false
	end
	local target = objective.Target
	return target == nil or target == "" or target == key
end

return table.freeze(QuestsModule)
