--!strict
--[[
	Loot
	Drop tables (Spec Section 11). Every kill rolls separately for each
	player who helped (personal loot: you only ever see your own drops).

	Per kill, each eligible player gets:
	  - their gold (Data/Mobs Rewards range, x Elite multiplier)
	  - MaterialRolls picks from the mob's Materials (weighted, Min..Max each)
	  - a gear roll with GearChance (+ elite bonus): an item from the
	    zone's Gear pool at a rarity from RarityWeights, never below the
	    item's own rarity
	  - each Extra entry rolled on its own Chance (blueprints, named items)

	Pity: kills in a zone without a Rare-or-better gear drop are counted per
	player; at Pity.Kills the next kill always drops Rare-or-better gear.

	Zones come from the mob's spawn point (attribute Zone), falling back to
	DefaultZone.
]]

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

export type WeightedItem = { Id: string, Weight: number, Min: number?, Max: number? }
export type ExtraDrop = { Id: string, Chance: number, EliteOnly: boolean? }
export type MobTable = {
	GearChance: number,
	MaterialRolls: number,
	Materials: { WeightedItem },
	Extra: { ExtraDrop }?,
}

return TableUtil.DeepFreeze({
	DefaultZone = "Lowharbor",

	Pity = {
		Kills = 40,
		MinRarity = "Rare",
	},

	-- Rarity odds for gear rolls (weights, not percentages).
	RarityWeights = {
		Normal = { Common = 62, Uncommon = 26, Rare = 9, Epic = 2.6, Legendary = 0.4 },
		Elite = { Common = 20, Uncommon = 38, Rare = 28, Epic = 11, Legendary = 3 },
	},

	Elite = {
		GearChanceBonus = 0.5, -- added to the mob's GearChance
		MaterialRollBonus = 2,
	},

	-- Gear that can drop in each zone.
	Zones = {
		Lowharbor = {
			Gear = {
				{ Id = "ClimbersLongsword", Weight = 3 },
				{ Id = "StonejawGreatblade", Weight = 3 },
				{ Id = "BrinecutTwinfangs", Weight = 3 },
				{ Id = "SpirewatchLance", Weight = 3 },
				{ Id = "GleamNeedle", Weight = 3 },
				{ Id = "RuneedgeArcblade", Weight = 3 },
				{ Id = "HarborHood", Weight = 4 },
				{ Id = "HarborCoat", Weight = 4 },
				{ Id = "HarborLeggings", Weight = 4 },
				{ Id = "HarborGloves", Weight = 4 },
				{ Id = "HarborCloak", Weight = 4 },
				{ Id = "PearlRing", Weight = 2 },
				{ Id = "BrassAmulet", Weight = 2 },
			},
		},
		TidepoolMarsh = {
			Gear = {
				{ Id = "TideforgedLongsword", Weight = 3 },
				{ Id = "LanternedgeArcblade", Weight = 3 },
				{ Id = "Wispfangs", Weight = 2 },
				{ Id = "HarborCoat", Weight = 3 },
				{ Id = "HarborCloak", Weight = 3 },
				{ Id = "PearlRing", Weight = 3 },
				{ Id = "CoralBand", Weight = 1 },
				{ Id = "BrassAmulet", Weight = 2 },
			},
		},
		RustwoodForest = {
			Gear = {
				{ Id = "LanternedgeArcblade", Weight = 3 },
				{ Id = "Wispfangs", Weight = 3 },
				{ Id = "StonejawGreatblade", Weight = 2 },
				{ Id = "TidewardenGauntlets", Weight = 1 },
				{ Id = "TidewardenGreaves", Weight = 1 },
				{ Id = "CoralBand", Weight = 2 },
			},
		},
		SunkenCistern = {
			Gear = {
				{ Id = "CisternGreatblade", Weight = 3 },
				{ Id = "SaltglassNeedle", Weight = 2 },
				{ Id = "Wispfangs", Weight = 2 },
				{ Id = "TidewardenHelm", Weight = 2 },
				{ Id = "TidewardenMail", Weight = 1 },
				{ Id = "TidewardenMantle", Weight = 2 },
				{ Id = "CoralBand", Weight = 2 },
				{ Id = "LanternPendant", Weight = 1 },
			},
		},
	},

	-- Per mob id (Shared/Data/Mobs). Mobs without an entry use Default.
	Mobs = {
		DrownedSailor = {
			GearChance = 0.14,
			MaterialRolls = 1,
			Materials = {
				{ Id = "IronScrap", Weight = 4, Min = 1, Max = 3 },
				{ Id = "MarshFiber", Weight = 3, Min = 1, Max = 2 },
				{ Id = "Rustwood", Weight = 2, Min = 1, Max = 2 },
				{ Id = "TidePearl", Weight = 0.6, Min = 1, Max = 1 },
			},
			Extra = {
				{ Id = "TideforgedBlueprint", Chance = 0.015 },
				{ Id = "HealingDraught", Chance = 0.08 },
			},
		},
		Brinehulk = {
			GearChance = 0.6,
			MaterialRolls = 3,
			Materials = {
				{ Id = "BrineShell", Weight = 4, Min = 1, Max = 3 },
				{ Id = "IronScrap", Weight = 3, Min = 2, Max = 4 },
				{ Id = "TidePearl", Weight = 1.2, Min = 1, Max = 2 },
				{ Id = "SpireIngot", Weight = 0.25, Min = 1, Max = 1 },
			},
			Extra = {
				{ Id = "TidewardenPattern", Chance = 0.02 },
				{ Id = "TidekeepersPromise", Chance = 0.04, EliteOnly = true },
			},
		},
		-- Floor 1 Guardian (Data/Guardians Rewards.LootTable).
		Brinewarden = {
			GearChance = 1.0,
			MaterialRolls = 3,
			Materials = {
				{ Id = "WardenShellFragment", Weight = 6, Min = 2, Max = 4 },
				{ Id = "BrinewardensPearl", Weight = 1, Min = 1, Max = 1 },
			},
			Extra = {
				{ Id = "Tidecleaver", Chance = 0.12 },
				{ Id = "BrinewardenCarapace", Chance = 0.12 },
				{ Id = "WardensTideCore", Chance = 0.08 },
			},
		},
		LanternAcolyte = {
			GearChance = 0.16,
			MaterialRolls = 1,
			Materials = {
				{ Id = "WispEssence", Weight = 3, Min = 1, Max = 2 },
				{ Id = "TidePearl", Weight = 2, Min = 1, Max = 1 },
				{ Id = "MarshFiber", Weight = 2, Min = 1, Max = 2 },
			},
			Extra = {
				{ Id = "CurrentTonic", Chance = 0.1 },
				{ Id = "BrineCore", Chance = 0.01 },
			},
		},
		Bilgecrab = {
			GearChance = 0.08,
			MaterialRolls = 1,
			Materials = {
				{ Id = "BrineShell", Weight = 4, Min = 1, Max = 2 },
				{ Id = "IronScrap", Weight = 2, Min = 1, Max = 1 },
			},
			Extra = {
				{ Id = "HealingDraught", Chance = 0.05 },
			},
		},
		MarshWisp = {
			GearChance = 0.12,
			MaterialRolls = 1,
			Materials = {
				{ Id = "WispEssence", Weight = 5, Min = 1, Max = 2 },
				{ Id = "MarshFiber", Weight = 2, Min = 1, Max = 2 },
			},
			Extra = {
				{ Id = "CurrentTonic", Chance = 0.12 },
			},
		},
		RustwoodStalker = {
			GearChance = 0.18,
			MaterialRolls = 2,
			Materials = {
				{ Id = "Rustwood", Weight = 5, Min = 1, Max = 3 },
				{ Id = "IronScrap", Weight = 2, Min = 1, Max = 2 },
				{ Id = "TidePearl", Weight = 0.5, Min = 1, Max = 1 },
			},
			Extra = {
				{ Id = "HealingDraught", Chance = 0.08 },
			},
		},
		CisternLeech = {
			GearChance = 0.2,
			MaterialRolls = 2,
			Materials = {
				{ Id = "BrineCore", Weight = 0.6, Min = 1, Max = 1 },
				{ Id = "TidePearl", Weight = 2, Min = 1, Max = 1 },
				{ Id = "IronScrap", Weight = 3, Min = 1, Max = 3 },
			},
			Extra = {
				{ Id = "CurrentTonic", Chance = 0.12 },
			},
		},
	} :: { [string]: MobTable },

	Default = {
		GearChance = 0.12,
		MaterialRolls = 1,
		Materials = {
			{ Id = "IronScrap", Weight = 3, Min = 1, Max = 2 },
			{ Id = "MarshFiber", Weight = 2, Min = 1, Max = 2 },
		},
	} :: MobTable,
})
