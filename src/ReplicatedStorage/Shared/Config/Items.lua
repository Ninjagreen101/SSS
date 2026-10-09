--!strict
--[[
	Item, rarity, loot, upgrade and station tuning (Spec Section 11).
	Every number the item systems use lives here so balancing never means
	touching code. Item definitions themselves are in Shared/Data/Items, drop
	tables in Config/Loot.
]]

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

return TableUtil.DeepFreeze({
	-- Low to high. Used for sorting, "at least Rare" checks and pity.
	RarityOrder = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "SpireForged" },

	-- Per rarity:
	--   MinAffixes/MaxAffixes  bonus lines rolled on weapons, armour and accessories
	--   AffixPower             multiplier on every rolled affix value
	--   StatMultiplier         multiplier on the item's base numbers (damage, armour, stats)
	--   UniqueEffect           Legendary and above carry a unique named effect
	--   Beam                   drops show a vertical light beam
	--   SalvageScrap           Iron Scrap returned when salvaged
	Rarities = {
		Common = { MinAffixes = 0, MaxAffixes = 0, AffixPower = 1.0, StatMultiplier = 1.0, UniqueEffect = false, Beam = false, SalvageScrap = 1 },
		Uncommon = { MinAffixes = 1, MaxAffixes = 1, AffixPower = 1.0, StatMultiplier = 1.08, UniqueEffect = false, Beam = false, SalvageScrap = 2 },
		Rare = { MinAffixes = 1, MaxAffixes = 2, AffixPower = 1.15, StatMultiplier = 1.16, UniqueEffect = false, Beam = true, SalvageScrap = 4 },
		Epic = { MinAffixes = 2, MaxAffixes = 3, AffixPower = 1.3, StatMultiplier = 1.25, UniqueEffect = false, Beam = true, SalvageScrap = 7 },
		Legendary = { MinAffixes = 3, MaxAffixes = 4, AffixPower = 1.45, StatMultiplier = 1.35, UniqueEffect = true, Beam = true, SalvageScrap = 12 },
		Mythic = { MinAffixes = 4, MaxAffixes = 4, AffixPower = 1.6, StatMultiplier = 1.45, UniqueEffect = true, Beam = true, SalvageScrap = 18 },
		SpireForged = { MinAffixes = 4, MaxAffixes = 4, AffixPower = 1.8, StatMultiplier = 1.6, UniqueEffect = true, Beam = true, SalvageScrap = 25 },
	},

	-- Smithing: +0 to +10 at the Forge. +7 and higher can fail: the item is
	-- kept at its level, the gold and materials are spent.
	Upgrade = {
		MaxLevel = 10,
		StatBonusPerLevel = 0.06, -- +6% to the item's base numbers per level
		-- Index = target level. Material ids are Shared/Data/Items materials.
		Steps = {
			{ Gold = 25, Materials = { IronScrap = 3 }, FailChance = 0 },
			{ Gold = 45, Materials = { IronScrap = 5 }, FailChance = 0 },
			{ Gold = 70, Materials = { IronScrap = 8 }, FailChance = 0 },
			{ Gold = 110, Materials = { IronScrap = 10, TidePearl = 1 }, FailChance = 0 },
			{ Gold = 160, Materials = { IronScrap = 12, TidePearl = 2 }, FailChance = 0 },
			{ Gold = 230, Materials = { IronScrap = 15, TidePearl = 3 }, FailChance = 0 },
			{ Gold = 320, Materials = { IronScrap = 18, TidePearl = 4, SpireIngot = 1 }, FailChance = 0.25 },
			{ Gold = 450, Materials = { IronScrap = 22, TidePearl = 5, SpireIngot = 2 }, FailChance = 0.35 },
			{ Gold = 620, Materials = { IronScrap = 26, TidePearl = 6, SpireIngot = 3 }, FailChance = 0.45 },
			{ Gold = 850, Materials = { IronScrap = 30, TidePearl = 8, SpireIngot = 4 }, FailChance = 0.55 },
		},
	},

	-- Gear wears down only on death and is repaired at the Forge or Armorer's Bench.
	Durability = {
		Max = 100,
		LossOnDeath = 10,
		BrokenStatMultiplier = 0.5, -- broken gear (0 durability) gives half its numbers
		RepairGoldPerPoint = 0.4, -- times the item's rarity StatMultiplier
	},

	Inventory = {
		BaseCapacity = 60,
		PassCapacityBonus = 40,
		BaseBankCapacity = 40,
		PassBankBonus = 60,
		MaxStack = 999,
		MaxRequestCount = 999, -- largest stack size a client request may name
		-- Carry weight: going over slows you (no sprint, slower walk) but never
		-- blocks a pickup, so nobody loses loot to a full bar.
		BaseWeight = 120,
		WeightPerEndurance = 3,
		OverburdenedWalkMultiplier = 0.75,
	},

	Equipment = {
		AccessorySlots = { "Ring1", "Ring2", "Amulet" },
		ArmorSlots = { "Head", "Chest", "Legs", "Hands", "Cloak" },
	},

	-- Personal loot on the ground (LootService / LootController).
	Loot = {
		AutoPickupRadius = 12, -- gold and materials fly to you inside this radius
		WalkOverRadius = 4, -- gear is picked up by walking over it...
		InteractRadius = 10, -- ...or with Interact from this far
		ServerRadiusSlack = 4, -- extra studs the server allows for latency
		DropLifetime = 180,
		MaxDropsPerPlayer = 60, -- oldest drop is removed past this
		ScatterRadius = 2.5,
	},

	-- Drops on screen (LootController).
	Visual = {
		ArcTime = 0.55,
		ArcHeight = 3.2,
		BounceHeight = 0.5,
		BounceDecay = 5,
		BeamHeight = 10,
		MagnetTime = 0.22,
		LabelDistance = 60,
		SpinSpeed = 1.2, -- radians per second
		LegendaryGlowTime = 2.4, -- screen-edge glow when a Legendary+ drop lands
		FeedDuration = 3.2, -- pickup feed rows linger this long
	},

	-- Consumables (effects are defined per item in Shared/Data/Items).
	Consumables = {
		SharedCooldown = 1.5, -- seconds between any two quick-item uses
		ThrowRange = 40,
		ThrowTime = 0.45, -- seconds a throwable flies before it bursts
	},

	Stations = {
		InteractRadius = 14, -- how close you must stand to use a station (server-checked)
		Tag = "ItemStation",
	},

	Crafting = {
		Seconds = 1.6, -- progress ring at the station before the item appears
	},

	Shop = {
		SellMultiplier = 1, -- of the item's SellPrice (upgrades add value, see InventoryRules)
		BuybackSlots = 12,
		BuyPriceFromSell = 4, -- shops without a fixed price charge this x SellPrice
	},

	-- Salvaging gear at the Forge returns Iron Scrap by rarity (Rarities.SalvageScrap)
	-- plus this many Spire Ingots for Epic and above.
	Salvage = {
		IngotFromRarity = "Epic",
		Ingots = 1,
	},

	-- What a brand-new Climber carries. The first weapon is equipped.
	StarterKit = {
		{ Id = "ClimbersLongsword", Count = 1 },
		{ Id = "HealingDraught", Count = 3 },
		{ Id = "CurrentTonic", Count = 2 },
	},
})
