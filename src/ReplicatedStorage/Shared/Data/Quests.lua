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
	  Target  the GameEvents key it needs ("" or nil = any key; "Prefix:*" = any key with that prefix), e.g. "Bilgecrab", "Waystone:F1_RustwoodCamp",
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

local Quests: { [string]: QuestDef } = {
	-- MAIN STORY: Floor 1, from the docks to the Brinewarden ------------------------------------
	F1_M01 = {
		Kind = "Main", Floor = "1", Order = 1, Level = 1, Giver = "Brannoc", TurnIn = "Brannoc",
		Objectives = { { Type = "Talk", Target = "Brannoc", Count = 1, Marker = "Brannoc" } },
		Rewards = { XP = 50, Gold = 10, Items = { { Id = "HealingDraught", Count = 3 } } },
	},
	F1_M02 = {
		Kind = "Main", Floor = "1", Order = 2, Level = 1, Giver = "Brannoc", TurnIn = "Ysolde", Requires = { "F1_M01" },
		Objectives = {
			{ Type = "Reach", Target = "GuildSteps", Count = 1, Marker = "GuildSteps" },
			{ Type = "Talk", Target = "Ysolde", Count = 1, Marker = "Ysolde" },
		},
		Rewards = { XP = 150, Gold = 25, Items = { { Id = "HealingDraught", Count = 2 } } },
	},
	F1_M03 = {
		Kind = "Main", Floor = "1", Order = 3, Level = 2, Giver = "Ysolde", TurnIn = "Ysolde", Requires = { "F1_M02" },
		Objectives = { { Type = "Discover", Target = "Waystone:*", Count = 2, Marker = "F1_TidewatchSteps" } },
		Rewards = { XP = 150, Gold = 30, Items = { { Id = "CurrentTonic", Count = 2 } } },
	},
	F1_M04 = {
		Kind = "Main", Floor = "1", Order = 4, Level = 2, Giver = "Ysolde", TurnIn = "Ysolde", Requires = { "F1_M03" },
		Objectives = { { Type = "Kill", Target = "Bilgecrab", Count = 6, Marker = "OldWharf" } },
		Rewards = { XP = 160, Gold = 40, Items = { { Id = "HealingDraught", Count = 3 }, { Id = "BrineShell", Count = 4 } } },
	},
	F1_M05 = {
		Kind = "Main", Floor = "1", Order = 5, Level = 3, Giver = "Ysolde", TurnIn = "Ysolde", Requires = { "F1_M04" },
		Objectives = { { Type = "Attune", Count = 1, Marker = "RotundaDoor" } },
		Rewards = { XP = 300, Gold = 60, Items = { { Id = "TideforgedLongsword", Count = 1, Rarity = "Uncommon" } } },
	},
	F1_M06 = {
		Kind = "Main", Floor = "1", Order = 6, Level = 4, Giver = "Ysolde", TurnIn = "Osk", Requires = { "F1_M05" },
		Sequential = true,
		Objectives = {
			{ Type = "Discover", Target = "Waystone:F1_ReedwardenPost", Count = 1, Marker = "F1_ReedwardenPost" },
			{ Type = "Kill", Target = "MarshWisp", Count = 4, Marker = "F1_ReedwardenPost" },
		},
		Rewards = { XP = 470, Gold = 80, Items = { { Id = "CurrentTonic", Count = 3 }, { Id = "WispEssence", Count = 2 } } },
	},
	F1_M07 = {
		Kind = "Main", Floor = "1", Order = 7, Level = 5, Giver = "Maren", TurnIn = "Maren", Requires = { "F1_M06" },
		Objectives = {
			{ Type = "Reach", Target = "OldWharf", Count = 1, Marker = "OldWharf" },
			{ Type = "Kill", Target = "DrownedSailor", Count = 5, Marker = "OldWharf" },
		},
		Rewards = { XP = 680, Gold = 110, Items = { { Id = "PearlBroth", Count = 2 }, { Id = "TidePearl", Count = 2 } } },
	},
	F1_M08 = {
		Kind = "Main", Floor = "1", Order = 8, Level = 6, Giver = "Ysolde", TurnIn = "Hesk", Requires = { "F1_M07" },
		Objectives = {
			{ Type = "Discover", Target = "Waystone:F1_RustwoodCamp", Count = 1, Marker = "F1_RustwoodCamp" },
			{ Type = "Kill", Target = "RustwoodStalker", Count = 5, Marker = "F1_RustwoodCamp" },
		},
		Rewards = { XP = 920, Gold = 140, Items = { { Id = "HealingDraught", Count = 4 }, { Id = "IronScrap", Count = 6 } } },
	},
	F1_M09 = {
		Kind = "Main", Floor = "1", Order = 9, Level = 8, Giver = "Ysolde", TurnIn = "Ysolde", Requires = { "F1_M08" },
		Objectives = { { Type = "Kill", Target = "Brinehulk", Count = 1, Marker = "BrinehulkLagoon" } },
		Rewards = { XP = 1480, Gold = 220, Items = { { Id = "TidePearl", Count = 3 }, { Id = "BrineBomb", Count = 3 } } },
	},
	F1_M10 = {
		Kind = "Main", Floor = "1", Order = 10, Level = 9, Giver = "Ilse", TurnIn = "Ilse", Requires = { "F1_M09" },
		Sequential = true,
		Objectives = {
			{ Type = "Talk", Target = "Ilse", Count = 1, Marker = "Ilse" },
			{ Type = "Clear", Target = "Dungeon:SunkenCistern", Count = 1, Marker = "CisternMouth" },
		},
		Rewards = { XP = 1800, Gold = 300, Items = { { Id = "TidewardenMail", Count = 1, Rarity = "Rare" } } },
	},
	F1_M11 = {
		Kind = "Main", Floor = "1", Order = 11, Level = 11, Giver = "Ysolde", TurnIn = "Ysolde", Requires = { "F1_M10" },
		Sequential = true,
		Objectives = {
			{ Type = "Talk", Target = "Ysolde", Count = 1, Marker = "Ysolde" },
			{ Type = "Discover", Target = "Waystone:F1_GateApproach", Count = 1, Marker = "F1_GateApproach" },
		},
		Rewards = { XP = 2500, Gold = 400, Items = { { Id = "PearlBroth", Count = 3 }, { Id = "HealingDraught", Count = 5 } } },
	},
	F1_M12 = {
		Kind = "Main", Floor = "1", Order = 12, Level = 12, Giver = "Ysolde", TurnIn = "Ysolde", Requires = { "F1_M11" },
		Objectives = { { Type = "Clear", Target = "Guardian:Brinewarden", Count = 1, Marker = "GateApproach" } },
		Rewards = { XP = 2900, Gold = 800, Shards = 25, Items = { { Id = "BrinewardensPearl", Count = 1 }, { Id = "HealingDraught", Count = 5 } } },
	},

	-- SIDE QUESTS ---------------------------------------------------------------------------------
	F1_S01 = {
		Kind = "Side", Floor = "1", Level = 1, Giver = "Brannoc", TurnIn = "Brannoc",
		Objectives = { { Type = "Collect", Target = "MarshFiber", Count = 8 } },
		Rewards = { XP = 60, Gold = 20, Items = { { Id = "HarborGloves", Count = 1 }, { Id = "HealingDraught", Count = 2 } } },
	},
	F1_S02 = {
		Kind = "Side", Floor = "1", Level = 2, Giver = "Pell", TurnIn = "Pell",
		Objectives = {
			{ Type = "Collect", Target = "BrineShell", Count = 5 },
			{ Type = "Collect", Target = "IronScrap", Count = 6 },
		},
		Rewards = { XP = 110, Gold = 35, Items = { { Id = "PearlRing", Count = 1, Rarity = "Uncommon" } } },
	},
	F1_S03 = {
		Kind = "Side", Floor = "1", Level = 5, Giver = "Ilse", TurnIn = "Ilse",
		Objectives = {
			{ Type = "Discover", Target = "Secret:F1_SmugglersCove", Count = 1 },
			{ Type = "Discover", Target = "Secret:F1_ReedShrine", Count = 1, Marker = "F1_ReedwardenPost" },
		},
		Rewards = { XP = 380, Gold = 90, Items = { { Id = "CoralBand", Count = 1, Rarity = "Rare" } } },
	},
	F1_S04 = {
		Kind = "Side", Floor = "1", Level = 6, Giver = "Tobin", TurnIn = "Tobin",
		Objectives = { { Type = "Collect", Target = "TidePearl", Count = 3, Marker = "Tobin" } },
		Rewards = { XP = 480, Gold = 150, Items = { { Id = "BrassAmulet", Count = 1, Rarity = "Uncommon" } } },
	},
	F1_S05 = {
		Kind = "Side", Floor = "1", Level = 4, Giver = "Caddith", TurnIn = "Caddith", Sequential = true,
		Objectives = {
			{ Type = "Collect", Target = "WispEssence", Count = 4, Marker = "F1_ReedwardenPost" },
			{ Type = "Reach", Target = "OldWharf", Count = 1, Marker = "OldWharf" },
		},
		Rewards = { XP = 260, Gold = 60, Items = { { Id = "CurrentTonic", Count = 3 }, { Id = "PearlBroth", Count = 1 } } },
	},
	F1_S06 = {
		Kind = "Side", Floor = "1", Level = 3, Giver = "Maren", TurnIn = "Maren",
		Objectives = { { Type = "Do", Event = "Parry", Count = 10, Marker = "Maren" } },
		Rewards = { XP = 200, Gold = 45, Items = { { Id = "HealingDraught", Count = 3 }, { Id = "BrassAmulet", Count = 1, Rarity = "Uncommon" } } },
	},
	F1_S07 = {
		Kind = "Side", Floor = "1", Level = 5, Giver = "Maren", TurnIn = "Maren", Requires = { "F1_S06" },
		Objectives = { { Type = "Craft", Target = "LanternedgeArcblade", Count = 1 } },
		Rewards = { XP = 420, Gold = 120, Items = { { Id = "TidePearl", Count = 3 } } },
	},
	F1_S08 = {
		Kind = "Side", Floor = "1", Level = 5, Giver = "Osk", TurnIn = "Osk", Requires = { "F1_M06" },
		Objectives = { { Type = "Kill", Target = "LanternAcolyte", Count = 5, Marker = "F1_ReedwardenPost" } },
		Rewards = { XP = 400, Gold = 100, Items = { { Id = "CurrentTonic", Count = 4 }, { Id = "TidePearl", Count = 2 } } },
	},
	F1_S09 = {
		Kind = "Side", Floor = "1", Level = 6, Giver = "Hesk", TurnIn = "Hesk", Requires = { "F1_M08" },
		Objectives = {
			{ Type = "Kill", Target = "RustwoodStalker", Count = 4, Marker = "F1_RustwoodCamp" },
			{ Type = "Collect", Target = "Rustwood", Count = 8, Marker = "F1_RustwoodCamp" },
		},
		Rewards = { XP = 520, Gold = 130, Items = { { Id = "TidewardenGreaves", Count = 1, Rarity = "Rare" } } },
	},
	F1_S10 = {
		Kind = "Side", Floor = "1", Level = 4, Giver = "Fen", TurnIn = "Fen",
		Objectives = {
			{ Type = "Reach", Target = "CanalNorthFalls", Count = 1, Marker = "CanalNorthFalls" },
			{ Type = "Reach", Target = "CanalSouthFalls", Count = 1, Marker = "CanalSouthFalls" },
			{ Type = "Reach", Target = "CanalMouth", Count = 1, Marker = "CanalMouth" },
		},
		Rewards = { XP = 300, Gold = 70, Items = { { Id = "PearlBroth", Count = 2 }, { Id = "TidePearl", Count = 2 } } },
	},

	-- DAILIES: one rolled per pool each day ----------------------------------------------------------
	F1_DK01 = {
		Kind = "Daily", Floor = "1", Pool = "Kill", Level = 2,
		Objectives = { { Type = "Kill", Target = "Bilgecrab", Count = 10, Marker = "OldWharf" } },
		Rewards = { XP = 120, Gold = 60, Shards = 10 },
	},
	F1_DK02 = {
		Kind = "Daily", Floor = "1", Pool = "Kill", Level = 4,
		Objectives = { { Type = "Kill", Target = "DrownedSailor", Count = 8, Marker = "OldWharf" } },
		Rewards = { XP = 250, Gold = 90, Shards = 12 },
	},
	F1_DK03 = {
		Kind = "Daily", Floor = "1", Pool = "Kill", Level = 5,
		Objectives = { { Type = "Kill", Target = "MarshWisp", Count = 8, Marker = "F1_ReedwardenPost" } },
		Rewards = { XP = 300, Gold = 100, Shards = 12 },
	},
	F1_DK04 = {
		Kind = "Daily", Floor = "1", Pool = "Kill", Level = 6,
		Objectives = { { Type = "Kill", Target = "RustwoodStalker", Count = 6, Marker = "F1_RustwoodCamp" } },
		Rewards = { XP = 380, Gold = 120, Shards = 15 },
	},
	F1_DG01 = {
		Kind = "Daily", Floor = "1", Pool = "Gather", Level = 2,
		Objectives = { { Type = "Collect", Target = "IronScrap", Count = 12 } },
		Rewards = { XP = 100, Gold = 55, Shards = 10 },
	},
	F1_DG02 = {
		Kind = "Daily", Floor = "1", Pool = "Gather", Level = 3,
		Objectives = { { Type = "Collect", Target = "MarshFiber", Count = 15 } },
		Rewards = { XP = 120, Gold = 60, Shards = 10 },
	},
	F1_DG03 = {
		Kind = "Daily", Floor = "1", Pool = "Gather", Level = 5,
		Objectives = { { Type = "Collect", Target = "WispEssence", Count = 6, Marker = "F1_ReedwardenPost" } },
		Rewards = { XP = 250, Gold = 90, Shards = 12 },
	},
	F1_DG04 = {
		Kind = "Daily", Floor = "1", Pool = "Gather", Level = 6,
		Objectives = { { Type = "Collect", Target = "Rustwood", Count = 10, Marker = "F1_RustwoodCamp" } },
		Rewards = { XP = 280, Gold = 90, Shards = 12 },
	},
	F1_DD01 = {
		Kind = "Daily", Floor = "1", Pool = "Dungeon", Level = 9,
		Objectives = { { Type = "Clear", Target = "Dungeon:SunkenCistern", Count = 1, Marker = "CisternMouth" } },
		Rewards = { XP = 700, Gold = 160, Shards = 15 },
	},
	F1_DD02 = {
		Kind = "Daily", Floor = "1", Pool = "Dungeon", Level = 9,
		Objectives = { { Type = "Kill", Target = "CisternLeech", Count = 8, Marker = "CisternMouth" } },
		Rewards = { XP = 600, Gold = 140, Shards = 12 },
	},
	F1_DD03 = {
		Kind = "Daily", Floor = "1", Pool = "Dungeon", Level = 9,
		Objectives = { { Type = "Clear", Target = "Dungeon:SunkenCistern", Count = 2, Marker = "CisternMouth" } },
		Rewards = { XP = 1200, Gold = 280, Shards = 15 },
	},

	-- WEEKLIES: two rolled each week ----------------------------------------------------------------
	F1_W01 = {
		Kind = "Weekly", Floor = "1", Pool = "Weekly", Level = 5,
		Objectives = { { Type = "Kill", Count = 60 } },
		Rewards = { XP = 800, Gold = 500, Shards = 40 },
	},
	F1_W02 = {
		Kind = "Weekly", Floor = "1", Pool = "Weekly", Level = 9,
		Objectives = { { Type = "Clear", Target = "Dungeon:SunkenCistern", Count = 5, Marker = "CisternMouth" } },
		Rewards = { XP = 2500, Gold = 900, Shards = 55 },
	},
	F1_W03 = {
		Kind = "Weekly", Floor = "1", Pool = "Weekly", Level = 12,
		Objectives = { { Type = "Clear", Target = "Guardian:Brinewarden", Count = 1, Marker = "GateApproach" } },
		Rewards = { XP = 3000, Gold = 1000, Shards = 60 },
	},
	F1_W04 = {
		Kind = "Weekly", Floor = "1", Pool = "Weekly", Level = 5,
		Objectives = {
			{ Type = "Do", Event = "Parry", Count = 40 },
			{ Type = "Do", Event = "Confluence", Count = 3 },
		},
		Rewards = { XP = 900, Gold = 600, Shards = 45 },
	},
}

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

-- Does a Target / Key pattern match a GameEvents key? "" or nil = any key; a trailing "*" matches
-- by prefix ("Waystone:*" = any waystone, not secrets); otherwise the key must be equal.
function QuestsModule.KeyMatches(pattern: string?, key: string): boolean
	if pattern == nil or pattern == "" then
		return true
	end
	if string.sub(pattern, -1) == "*" then
		local prefix = string.sub(pattern, 1, -2)
		return string.sub(key, 1, #prefix) == prefix
	end
	return pattern == key
end

-- Does objective `objective` count GameEvents (kind, key)?
function QuestsModule.Matches(objective: Objective, kind: string, key: string): boolean
	local wanted = if objective.Type == "Do" then objective.Event else objective.Type
	if wanted ~= kind then
		return false
	end
	return QuestsModule.KeyMatches(objective.Target, key)
end

return table.freeze(QuestsModule)
