--!strict
--[[
	Items
	Every item definition (what an item IS). Item instances in a player's
	inventory (Types.ItemInstance) point here by DefId and add what was
	rolled on that copy: rarity, affixes, upgrade level, durability.
	Display text lives in Strings.Items[DefId] (Name, Description, Flavor).

	Adding an item is one entry here plus its strings. Drops come from
	Config/Loot, recipes from Data/Recipes, shop stock from Data/Shops.

	Common fields (Spec Section 11):
	  Type           Weapon | Armor | Accessory | BeaconCore | Consumable | Material | Quest | Blueprint
	  Rarity         the rarity the item is crafted/bought at, and the lowest it can drop at
	  RequiredLevel  to equip or use
	  SellPrice      gold a shop pays (Shops charge more, see Data/Shops)
	  StackSize      1 for gear
	  Weight         carry weight per unit (Config.Items.Inventory)
	  Tradeable      can be sold, traded and listed
	  Icon           uploaded image id, or "" to show a 3D render of Look/Model
	  Look           how the item is drawn in icons and as a drop (ItemModels)

	Gear fields:
	  Weapons: Class, Damage, Posture, Scaling, Model (see WeaponDef)
	  Armor:   Slot (Head/Chest/Legs/Hands/Cloak), Armor (damage reduction), Stats
	  Accessory: Slot (Ring/Amulet), Stats, Bonuses (fixed affix-style lines)
	  Unique   a fixed unique effect (Data/Affixes) on named Legendaries
	Other:
	  Effect   consumables: what using it does
	  Core     Beacon cores: orb colour and the bonus while slotted
	  (Blueprints teach every recipe that names them, see Data/Recipes)
]]

local Enums = require(script.Parent.Parent.Enums)
local Config = require(script.Parent.Parent.Config)

export type ItemType = "Weapon" | "Armor" | "Accessory" | "BeaconCore" | "Consumable" | "Material" | "Quest" | "Blueprint"

-- Shapes ItemModels can build for icons and drops.
export type LookKind =
	"Helm"
	| "Chest"
	| "Legs"
	| "Gloves"
	| "Cloak"
	| "Ring"
	| "Amulet"
	| "Flask"
	| "Bowl"
	| "Bomb"
	| "Scrap"
	| "Pearl"
	| "Fiber"
	| "Log"
	| "Shell"
	| "Wisp"
	| "Ingot"
	| "Core"
	| "Scroll"
	| "Sigil"
	| "Coin"

export type Look = {
	Kind: LookKind,
	Color: Color3,
	Accent: Color3?,
	Glow: boolean?, -- neon accent (essences, cores)
}

export type WeaponModel = {
	BladeLength: number,
	BladeWidth: number,
	GripLength: number,
	GuardWidth: number,
	BladeColor: Color3,
	Twin: boolean?, -- draw a second blade in the left hand
	GuardColor: Color3?,
	EdgeGlow: Color3?, -- thin neon edge (higher-tier blades)
}

export type ConsumableEffect = {
	Kind: "Heal" | "Current" | "Buff" | "Throw",
	Fraction: number?, -- Heal / Current: fraction of the maximum restored
	Bonuses: { [string]: number }?, -- Buff: GearStats bonus ids while it lasts
	Duration: number?, -- Buff seconds
	BuffId: string?, -- Buff: one buff per id at a time (eating again refreshes it)
	Damage: number?, -- Throw
	Posture: number?,
	Radius: number?,
	Element: Enums.Attunement?, -- Throw: applies that element's status
}

export type CoreDef = {
	Color: Color3,
	Bonuses: { [string]: number },
}

export type ItemDef = {
	Id: string,
	Type: ItemType,
	Rarity: Enums.Rarity,
	RequiredLevel: number,
	SellPrice: number,
	StackSize: number,
	Weight: number,
	Tradeable: boolean,
	Icon: string,
	Look: Look?,

	-- Weapons
	Class: Enums.WeaponClass?,
	Damage: number?,
	Posture: number?,
	Scaling: { Strength: number, Finesse: number }?,
	Model: WeaponModel?,

	-- Armor and accessories
	Slot: string?, -- Head | Chest | Legs | Hands | Cloak | Ring | Amulet
	Armor: number?,
	Stats: { [string]: number }?,
	Bonuses: { [string]: number }?,
	Unique: string?,

	Effect: ConsumableEffect?,
	Core: CoreDef?,
}

-- The weapon view of an ItemDef (every field a weapon needs is set).
export type WeaponDef = {
	Id: string,
	Type: "Weapon",
	Class: Enums.WeaponClass,
	Rarity: Enums.Rarity,
	RequiredLevel: number,
	Damage: number,
	Posture: number,
	Scaling: { Strength: number, Finesse: number },
	Model: WeaponModel,
	Unique: string?,
}

local function color(hex: string): Color3
	return Color3.fromHex(hex)
end

local defs: { [string]: ItemDef } = {}

local function add(def: ItemDef)
	assert(defs[def.Id] == nil, `duplicate item {def.Id}`)
	defs[def.Id] = def
end

-- WEAPONS -------------------------------------------------------------------
-- Damage is per light hit before combo, stats and crits; Posture breaks guard.

type WeaponSpec = {
	Id: string,
	Class: Enums.WeaponClass,
	Rarity: Enums.Rarity,
	Level: number,
	Damage: number,
	Posture: number,
	Scaling: { Strength: number, Finesse: number },
	Price: number,
	Weight: number,
	Model: WeaponModel,
	Unique: string?,
}

local function weapon(spec: WeaponSpec)
	add({
		Id = spec.Id,
		Type = "Weapon",
		Rarity = spec.Rarity,
		RequiredLevel = spec.Level,
		SellPrice = spec.Price,
		StackSize = 1,
		Weight = spec.Weight,
		Tradeable = true,
		Icon = "",
		Class = spec.Class,
		Damage = spec.Damage,
		Posture = spec.Posture,
		Scaling = spec.Scaling,
		Model = spec.Model,
		Unique = spec.Unique,
	})
end

-- Starters: one per class, Common, level 1.
weapon({
	Id = "ClimbersLongsword", Class = "Longsword", Rarity = "Common", Level = 1, Damage = 14, Posture = 10,
	Scaling = { Strength = 0.5, Finesse = 0.5 }, Price = 12, Weight = 6,
	Model = { BladeLength = 3.6, BladeWidth = 0.3, GripLength = 0.9, GuardWidth = 1.1, BladeColor = color("#C9CED6") },
})
weapon({
	Id = "StonejawGreatblade", Class = "Greatblade", Rarity = "Common", Level = 1, Damage = 24, Posture = 16,
	Scaling = { Strength = 0.9, Finesse = 0.1 }, Price = 14, Weight = 12,
	Model = { BladeLength = 5, BladeWidth = 0.7, GripLength = 1.4, GuardWidth = 1.7, BladeColor = color("#8E8A83") },
})
weapon({
	Id = "BrinecutTwinfangs", Class = "Twinfangs", Rarity = "Common", Level = 1, Damage = 8, Posture = 5,
	Scaling = { Strength = 0.2, Finesse = 0.8 }, Price = 12, Weight = 5,
	Model = { BladeLength = 1.8, BladeWidth = 0.25, GripLength = 0.6, GuardWidth = 0.6, BladeColor = color("#9FD7D2"), Twin = true },
})
weapon({
	Id = "SpirewatchLance", Class = "SpireLance", Rarity = "Common", Level = 1, Damage = 16, Posture = 11,
	Scaling = { Strength = 0.6, Finesse = 0.4 }, Price = 13, Weight = 9,
	Model = { BladeLength = 6.2, BladeWidth = 0.22, GripLength = 2.2, GuardWidth = 0.5, BladeColor = color("#B9A77A") },
})
weapon({
	Id = "GleamNeedle", Class = "Needle", Rarity = "Common", Level = 1, Damage = 11, Posture = 6,
	Scaling = { Strength = 0.1, Finesse = 0.9 }, Price = 12, Weight = 4,
	Model = { BladeLength = 3.4, BladeWidth = 0.12, GripLength = 0.8, GuardWidth = 0.8, BladeColor = color("#E7ECF2") },
})
weapon({
	Id = "RuneedgeArcblade", Class = "Arcblade", Rarity = "Common", Level = 1, Damage = 13, Posture = 9,
	Scaling = { Strength = 0.4, Finesse = 0.6 }, Price = 13, Weight = 6,
	Model = { BladeLength = 3.2, BladeWidth = 0.34, GripLength = 0.9, GuardWidth = 1, BladeColor = color("#7FD8E8") },
})

-- Floor 1 upgrades: crafted, found in the wilds and the Sunken Cistern.
weapon({
	Id = "TideforgedLongsword", Class = "Longsword", Rarity = "Uncommon", Level = 3, Damage = 17, Posture = 12,
	Scaling = { Strength = 0.5, Finesse = 0.5 }, Price = 30, Weight = 6,
	Model = {
		BladeLength = 3.8, BladeWidth = 0.32, GripLength = 0.95, GuardWidth = 1.25, BladeColor = color("#B8D6DE"),
		GuardColor = color("#4E7C86"),
	},
})
weapon({
	Id = "LanternedgeArcblade", Class = "Arcblade", Rarity = "Uncommon", Level = 4, Damage = 16, Posture = 11,
	Scaling = { Strength = 0.4, Finesse = 0.6 }, Price = 34, Weight = 6,
	Model = {
		BladeLength = 3.3, BladeWidth = 0.36, GripLength = 0.9, GuardWidth = 1.05, BladeColor = color("#E8D7A6"),
		GuardColor = color("#8A6A32"), EdgeGlow = color("#FFD98A"),
	},
})
weapon({
	Id = "Wispfangs", Class = "Twinfangs", Rarity = "Rare", Level = 5, Damage = 10, Posture = 6,
	Scaling = { Strength = 0.2, Finesse = 0.8 }, Price = 55, Weight = 5,
	Model = {
		BladeLength = 1.9, BladeWidth = 0.26, GripLength = 0.6, GuardWidth = 0.65, BladeColor = color("#CFF5D8"), Twin = true,
		GuardColor = color("#3E6B4C"), EdgeGlow = color("#9BFFB5"),
	},
})
weapon({
	Id = "CisternGreatblade", Class = "Greatblade", Rarity = "Rare", Level = 6, Damage = 30, Posture = 20,
	Scaling = { Strength = 0.9, Finesse = 0.1 }, Price = 70, Weight = 13,
	Model = {
		BladeLength = 5.3, BladeWidth = 0.75, GripLength = 1.45, GuardWidth = 1.9, BladeColor = color("#6F8C8A"),
		GuardColor = color("#2F4A52"), EdgeGlow = color("#3FE0D0"),
	},
})
weapon({
	Id = "SaltglassNeedle", Class = "Needle", Rarity = "Epic", Level = 7, Damage = 15, Posture = 8,
	Scaling = { Strength = 0.1, Finesse = 0.9 }, Price = 110, Weight = 4,
	Model = {
		BladeLength = 3.6, BladeWidth = 0.13, GripLength = 0.8, GuardWidth = 0.9, BladeColor = color("#EAF6FF"),
		GuardColor = color("#6A5A8C"), EdgeGlow = color("#C9A6FF"),
	},
})
-- Named Legendary: only from elites in the Sunken Cistern (Config/Loot).
weapon({
	Id = "TidekeepersPromise", Class = "SpireLance", Rarity = "Legendary", Level = 8, Damage = 22, Posture = 15,
	Scaling = { Strength = 0.6, Finesse = 0.4 }, Price = 220, Weight = 9, Unique = "Undertow",
	Model = {
		BladeLength = 6.6, BladeWidth = 0.26, GripLength = 2.3, GuardWidth = 0.7, BladeColor = color("#9EE8F0"),
		GuardColor = color("#C79A3E"), EdgeGlow = color("#3FE0D0"),
	},
})

-- ARMOR ---------------------------------------------------------------------
-- Armor = damage reduction fraction (summed with Vitality, capped by
-- Config.Combat.Damage.DefenseCap). Stats are base stat points.

type ArmorSpec = {
	Id: string,
	Slot: "Head" | "Chest" | "Legs" | "Hands" | "Cloak",
	Rarity: Enums.Rarity,
	Level: number,
	Armor: number,
	Stats: { [string]: number },
	Price: number,
	Weight: number,
	Look: Look,
}

local function armor(spec: ArmorSpec)
	add({
		Id = spec.Id,
		Type = "Armor",
		Rarity = spec.Rarity,
		RequiredLevel = spec.Level,
		SellPrice = spec.Price,
		StackSize = 1,
		Weight = spec.Weight,
		Tradeable = true,
		Icon = "",
		Look = spec.Look,
		Slot = spec.Slot,
		Armor = spec.Armor,
		Stats = spec.Stats,
	})
end

local HARBOR = color("#6B5A44")
local HARBOR_TRIM = color("#A88A4F")
armor({ Id = "HarborHood", Slot = "Head", Rarity = "Common", Level = 1, Armor = 0.02, Stats = { Vitality = 1 }, Price = 10, Weight = 2, Look = { Kind = "Helm", Color = HARBOR, Accent = HARBOR_TRIM } })
armor({ Id = "HarborCoat", Slot = "Chest", Rarity = "Common", Level = 1, Armor = 0.04, Stats = { Vitality = 2 }, Price = 14, Weight = 6, Look = { Kind = "Chest", Color = HARBOR, Accent = HARBOR_TRIM } })
armor({ Id = "HarborLeggings", Slot = "Legs", Rarity = "Common", Level = 1, Armor = 0.03, Stats = { Endurance = 1 }, Price = 11, Weight = 4, Look = { Kind = "Legs", Color = HARBOR, Accent = HARBOR_TRIM } })
armor({ Id = "HarborGloves", Slot = "Hands", Rarity = "Common", Level = 1, Armor = 0.015, Stats = { Strength = 1 }, Price = 8, Weight = 1, Look = { Kind = "Gloves", Color = HARBOR, Accent = HARBOR_TRIM } })
armor({ Id = "HarborCloak", Slot = "Cloak", Rarity = "Common", Level = 1, Armor = 0.015, Stats = { Draw = 1 }, Price = 9, Weight = 2, Look = { Kind = "Cloak", Color = color("#3E4A5C"), Accent = HARBOR_TRIM } })

local TIDE = color("#3D6E78")
local TIDE_TRIM = color("#3FE0D0")
armor({ Id = "TidewardenHelm", Slot = "Head", Rarity = "Rare", Level = 6, Armor = 0.03, Stats = { Vitality = 2, Endurance = 1 }, Price = 48, Weight = 3, Look = { Kind = "Helm", Color = TIDE, Accent = TIDE_TRIM } })
armor({ Id = "TidewardenMail", Slot = "Chest", Rarity = "Rare", Level = 6, Armor = 0.06, Stats = { Vitality = 3 }, Price = 64, Weight = 8, Look = { Kind = "Chest", Color = TIDE, Accent = TIDE_TRIM } })
armor({ Id = "TidewardenGreaves", Slot = "Legs", Rarity = "Rare", Level = 6, Armor = 0.045, Stats = { Endurance = 2 }, Price = 52, Weight = 5, Look = { Kind = "Legs", Color = TIDE, Accent = TIDE_TRIM } })
armor({ Id = "TidewardenGauntlets", Slot = "Hands", Rarity = "Rare", Level = 6, Armor = 0.025, Stats = { Strength = 1, Finesse = 1 }, Price = 40, Weight = 2, Look = { Kind = "Gloves", Color = TIDE, Accent = TIDE_TRIM } })
armor({ Id = "TidewardenMantle", Slot = "Cloak", Rarity = "Rare", Level = 6, Armor = 0.025, Stats = { Draw = 2, Control = 1 }, Price = 44, Weight = 3, Look = { Kind = "Cloak", Color = color("#1F3F4C"), Accent = TIDE_TRIM } })

-- ACCESSORIES -----------------------------------------------------------------
-- Two ring slots and one amulet. Bonuses are fixed lines on every copy
-- (rolled affixes come on top).

type AccessorySpec = {
	Id: string,
	Slot: "Ring" | "Amulet",
	Rarity: Enums.Rarity,
	Level: number,
	Stats: { [string]: number },
	Bonuses: { [string]: number },
	Price: number,
	Look: Look,
}

local function accessory(spec: AccessorySpec)
	add({
		Id = spec.Id,
		Type = "Accessory",
		Rarity = spec.Rarity,
		RequiredLevel = spec.Level,
		SellPrice = spec.Price,
		StackSize = 1,
		Weight = 0.2,
		Tradeable = true,
		Icon = "",
		Look = spec.Look,
		Slot = spec.Slot,
		Stats = spec.Stats,
		Bonuses = spec.Bonuses,
	})
end

accessory({ Id = "PearlRing", Slot = "Ring", Rarity = "Uncommon", Level = 2, Stats = {}, Bonuses = { MaxCurrent = 10 }, Price = 24, Look = { Kind = "Ring", Color = color("#C9B37E"), Accent = color("#F3EEE2") } })
accessory({ Id = "CoralBand", Slot = "Ring", Rarity = "Rare", Level = 5, Stats = { Finesse = 1 }, Bonuses = { CritChance = 0.03 }, Price = 46, Look = { Kind = "Ring", Color = color("#B8B8C0"), Accent = color("#FF7B6B") } })
accessory({ Id = "BrassAmulet", Slot = "Amulet", Rarity = "Uncommon", Level = 2, Stats = {}, Bonuses = { MaxHealth = 12 }, Price = 26, Look = { Kind = "Amulet", Color = HARBOR_TRIM, Accent = color("#6E6A63") } })
accessory({ Id = "LanternPendant", Slot = "Amulet", Rarity = "Epic", Level = 7, Stats = { Draw = 2 }, Bonuses = { CurrentRegen = 0.1 }, Price = 95, Look = { Kind = "Amulet", Color = color("#8A6A32"), Accent = color("#FFD98A"), Glow = true } })

-- CONSUMABLES -----------------------------------------------------------------

type ConsumableSpec = {
	Id: string,
	Rarity: Enums.Rarity,
	Level: number,
	Price: number,
	Effect: ConsumableEffect,
	Look: Look,
}

local function consumable(spec: ConsumableSpec)
	add({
		Id = spec.Id,
		Type = "Consumable",
		Rarity = spec.Rarity,
		RequiredLevel = spec.Level,
		SellPrice = spec.Price,
		StackSize = 99,
		Weight = 0.3,
		Tradeable = true,
		Icon = "",
		Look = spec.Look,
		Effect = spec.Effect,
	})
end

consumable({ Id = "HealingDraught", Rarity = "Common", Level = 1, Price = 4, Effect = { Kind = "Heal", Fraction = 0.35 }, Look = { Kind = "Flask", Color = color("#B3262E"), Accent = color("#F0B2A8") } })
consumable({ Id = "CurrentTonic", Rarity = "Common", Level = 1, Price = 5, Effect = { Kind = "Current", Fraction = 0.4 }, Look = { Kind = "Flask", Color = color("#1A4E8C"), Accent = color("#3FE0D0"), Glow = true } })
-- Buff foods: one of each at a time; eating again refreshes the timer.
consumable({
	Id = "MarshStew", Rarity = "Common", Level = 1, Price = 6,
	Effect = { Kind = "Buff", BuffId = "MarshStew", Duration = 180, Bonuses = { StaminaRegen = 0.25, MaxStamina = 10 } },
	Look = { Kind = "Bowl", Color = color("#6B4A2C"), Accent = color("#8FB357") },
})
consumable({
	Id = "PearlBroth", Rarity = "Uncommon", Level = 3, Price = 9,
	Effect = { Kind = "Buff", BuffId = "PearlBroth", Duration = 180, Bonuses = { CurrentRegen = 0.2, MaxCurrent = 10 } },
	Look = { Kind = "Bowl", Color = color("#6B4A2C"), Accent = color("#E9E4D4") },
})
-- Throwable: bursts where you aim, Soaking what it hits.
consumable({
	Id = "BrineBomb", Rarity = "Uncommon", Level = 2, Price = 7,
	Effect = { Kind = "Throw", Damage = 34, Posture = 14, Radius = 8, Element = "Tide" },
	Look = { Kind = "Bomb", Color = color("#2B3A46"), Accent = color("#3FE0D0"), Glow = true },
})

-- MATERIALS -------------------------------------------------------------------

local function material(id: string, rarity: Enums.Rarity, price: number, look: Look)
	add({
		Id = id,
		Type = "Material",
		Rarity = rarity,
		RequiredLevel = 1,
		SellPrice = price,
		StackSize = 999,
		Weight = 0.05,
		Tradeable = true,
		Icon = "",
		Look = look,
	})
end

material("IronScrap", "Common", 2, { Kind = "Scrap", Color = color("#7A7670"), Accent = color("#A3542C") })
material("MarshFiber", "Common", 2, { Kind = "Fiber", Color = color("#6F8A3E"), Accent = color("#C9B37E") })
material("Rustwood", "Common", 3, { Kind = "Log", Color = color("#7A3E22"), Accent = color("#C46A3A") })
material("BrineShell", "Common", 4, { Kind = "Shell", Color = color("#C9C2B3"), Accent = color("#3D6E78") })
material("TidePearl", "Uncommon", 8, { Kind = "Pearl", Color = color("#E9F4F6"), Accent = color("#3FE0D0"), Glow = true })
material("WispEssence", "Uncommon", 8, { Kind = "Wisp", Color = color("#9BFFB5"), Accent = color("#3FE0D0"), Glow = true })
material("SpireIngot", "Rare", 30, { Kind = "Ingot", Color = color("#8FA6B8"), Accent = color("#3FE0D0"), Glow = true })

-- BEACON CORES ----------------------------------------------------------------
-- Slotted from the inventory; they recolour your Beacons and strengthen one
-- behaviour. Bonus ids are read by BeaconService.

local function core(id: string, rarity: Enums.Rarity, price: number, core: CoreDef)
	add({
		Id = id,
		Type = "BeaconCore",
		Rarity = rarity,
		RequiredLevel = 8, -- Beacons need an Attunement (Config.Current.Attunement.PrimaryLevel)
		SellPrice = price,
		StackSize = 1,
		Weight = 0.3,
		Tradeable = true,
		Icon = "",
		Look = { Kind = "Core", Color = core.Color, Accent = Color3.new(1, 1, 1), Glow = true },
		Core = core,
	})
end

core("BrineCore", "Rare", 40, { Color = color("#3FE09A"), Bonuses = { SentryDamage = 0.2 } })
core("PearlCore", "Rare", 40, { Color = color("#F3EEE2"), Bonuses = { AegisRecharge = 0.25 } })
core("EchoCore", "Rare", 40, { Color = color("#B36BFF"), Bonuses = { RelayCooldown = 0.25 } })

-- BLUEPRINTS AND QUEST ITEMS ----------------------------------------------------

local function blueprint(id: string, price: number)
	add({
		Id = id,
		Type = "Blueprint",
		Rarity = "Uncommon",
		RequiredLevel = 1,
		SellPrice = price,
		StackSize = 1,
		Weight = 0.1,
		Tradeable = true,
		Icon = "",
		Look = { Kind = "Scroll", Color = color("#E4D6B0"), Accent = color("#4E7C86") },
	})
end

blueprint("TideforgedBlueprint", 15)
blueprint("TidewardenPattern", 25)

-- Summoning item: crafted at the Altar, offered at the drowned altar in the
-- Sunken Cistern to call its optional boss.
add({
	Id = "BrineSigil",
	Type = "Quest",
	Rarity = "Epic",
	RequiredLevel = 6,
	SellPrice = 0,
	StackSize = 5,
	Weight = 0.5,
	Tradeable = false,
	Icon = "",
	Look = { Kind = "Sigil", Color = color("#2F4A52"), Accent = color("#3FE0D0"), Glow = true },
})

-- Gold on the ground uses this look (it's a currency, not an item).
local GOLD_LOOK: Look = { Kind = "Coin", Color = color("#E9C25B"), Accent = color("#A88A4F") }

-- Freeze and index ---------------------------------------------------------------

local weapons: { [string]: WeaponDef } = {}
for id, def in defs do
	if def.Type == "Weapon" then
		weapons[id] = def :: any
	end
	table.freeze(def)
end

local Items = {}

Items.Definitions = table.freeze(defs)
Items.Weapons = table.freeze(weapons)
-- Wielded when the Weapon slot is empty, so every Climber always has a blade.
Items.DefaultWeapon = "ClimbersLongsword"
Items.GoldLook = GOLD_LOOK

function Items.Get(defId: string): ItemDef?
	return defs[defId]
end

function Items.GetWeapon(defId: string): WeaponDef?
	return weapons[defId]
end

function Items.IsGear(def: ItemDef): boolean
	return def.Type == "Weapon" or def.Type == "Armor" or def.Type == "Accessory"
end

-- The equipment slots an item can go in ("Ring" fits either ring slot).
function Items.SlotsFor(def: ItemDef): { string }
	if def.Type == "Weapon" then
		return { "Weapon" }
	elseif def.Slot == "Ring" then
		return { "Ring1", "Ring2" }
	elseif def.Slot then
		return { def.Slot }
	end
	return {}
end

-- 1 for Common up to 7 for Spire-Forged (0 for an unknown name).
function Items.RarityRank(rarity: string): number
	return table.find(Config.Items.RarityOrder, rarity) or 0
end

-- The higher of two rarities.
function Items.MaxRarity(a: Enums.Rarity, b: Enums.Rarity): Enums.Rarity
	return if Items.RarityRank(a) >= Items.RarityRank(b) then a else b
end

-- Affix group an item rolls from (Data/Affixes), or nil for non-gear.
function Items.AffixGroup(def: ItemDef): ("Weapon" | "Armor" | "Accessory")?
	if def.Type == "Weapon" then
		return "Weapon"
	elseif def.Type == "Armor" then
		return "Armor"
	elseif def.Type == "Accessory" then
		return "Accessory"
	end
	return nil
end

return table.freeze(Items)
