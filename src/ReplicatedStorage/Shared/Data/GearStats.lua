--!strict
--[[
	GearStats
	Turns what a player has equipped into numbers. Pure and shared: the
	server uses it for combat, the client uses the same code for tooltips
	and the Character sheet, so what you read is what you get.

	An item's numbers = its definition's base numbers
	  x rarity StatMultiplier (Config.Items.Rarities)
	  x (1 + upgrade level x StatBonusPerLevel)
	  x BrokenStatMultiplier when durability is 0
	Rolled affixes keep their rolled value (rarity already scaled them),
	halved when broken. Stat points round to whole numbers.

	Summary.Bonuses is one table of every bonus id (affix ids from
	Data/Affixes, Beacon core and food bonus ids) summed across equipped
	gear, the slotted Beacon core, the Position skill tree (Phase 8) and
	active buffs (food, abilities). Stat points from the tree are added to
	the stats like gear points (Summary.TreeStats on its own for the sheet).
]]

local Shared = script.Parent.Parent
local Config = require(Shared.Config)
local Types = require(Shared.Types)
local Items = require(script.Parent.Items)
local Affixes = require(script.Parent.Affixes)
local ProgressionRules = require(script.Parent.ProgressionRules)

type ItemInstance = Types.ItemInstance
type PlayerData = Types.PlayerData

export type ItemNumbers = {
	Damage: number?,
	Posture: number?,
	Armor: number,
	Stats: { [string]: number },
	Bonuses: { [string]: number },
	Unique: string?,
}

export type Summary = {
	Stats: Types.StatBlock, -- base stat points + gear points
	GearStats: { [string]: number }, -- just the gear part, for the Character sheet
	TreeStats: { [string]: number }, -- just the skill tree part
	Bonuses: { [string]: number },
	Armor: number, -- damage reduction from armour pieces (before the cap)
	Uniques: { [string]: boolean },
	Weight: number,
	MaxWeight: number,
}

local STAT_NAMES = { "Vitality", "Endurance", "Strength", "Finesse", "Draw", "Density", "Control" }

local GearStats = {}

GearStats.StatNames = table.freeze(STAT_NAMES)

-- The multiplier on an item's base numbers from rarity, upgrades and wear.
function GearStats.Multiplier(item: ItemInstance): number
	local rarity = Config.Items.Rarities[item.Rarity]
	local multiplier = (if rarity then rarity.StatMultiplier else 1) * (1 + item.Upgrade * Config.Items.Upgrade.StatBonusPerLevel)
	if item.Durability <= 0 then
		multiplier *= Config.Items.Durability.BrokenStatMultiplier
	end
	return multiplier
end

local function add(into: { [string]: number }, id: string, value: number)
	into[id] = (into[id] or 0) + value
end

-- Everything one item adds when equipped.
function GearStats.ItemNumbers(item: ItemInstance): ItemNumbers?
	local def = Items.Get(item.DefId)
	if not def or not Items.IsGear(def) then
		return nil
	end
	local multiplier = GearStats.Multiplier(item)
	local wear = if item.Durability <= 0 then Config.Items.Durability.BrokenStatMultiplier else 1
	local numbers: ItemNumbers = {
		Damage = if def.Damage then def.Damage * multiplier else nil,
		Posture = if def.Posture then def.Posture * multiplier else nil,
		Armor = (def.Armor or 0) * multiplier,
		Stats = {},
		Bonuses = {},
		Unique = item.Unique or def.Unique,
	}
	if def.Stats then
		for stat, value in def.Stats do
			numbers.Stats[stat] = math.floor(value * multiplier + 0.5)
		end
	end
	if def.Bonuses then
		for id, value in def.Bonuses do
			local affix = Affixes.Get(id)
			local scaled = value * multiplier
			add(numbers.Bonuses, id, if affix then Affixes.Round(affix.Kind, scaled) else scaled)
		end
	end
	for _, rolled in item.Affixes do
		local affix = Affixes.Get(rolled.Id)
		if affix and affix.Kind == "Points" and affix.Stat then
			numbers.Stats[affix.Stat] = (numbers.Stats[affix.Stat] or 0) + math.floor(rolled.Value * wear + 0.5)
		else
			add(numbers.Bonuses, rolled.Id, rolled.Value * wear)
		end
	end
	return numbers
end

-- A weapon definition with this copy's damage and posture (rarity, upgrades, wear).
function GearStats.Weapon(def: Items.WeaponDef, item: ItemInstance?): Items.WeaponDef
	if not item then
		return def
	end
	local multiplier = GearStats.Multiplier(item)
	local copy = table.clone(def)
	copy.Damage = def.Damage * multiplier
	copy.Posture = def.Posture * multiplier
	copy.Rarity = item.Rarity
	copy.Unique = item.Unique or def.Unique
	return copy
end

-- Total carry weight of the bag (the bank doesn't count).
function GearStats.Weight(data: PlayerData): number
	local total = 0
	for _, item in data.Inventory.Items do
		local def = Items.Get(item.DefId)
		if def then
			total += def.Weight * item.Count
		end
	end
	return total
end

function GearStats.MaxWeight(endurance: number): number
	local inventory = Config.Items.Inventory
	return inventory.BaseWeight + inventory.WeightPerEndurance * endurance
end

-- The equipped copy of an item uid, if it's in the bag.
function GearStats.EquippedItem(data: PlayerData, slot: string): ItemInstance?
	local uid = data.Equipped[slot]
	if not uid or uid == "" then
		return nil
	end
	return data.Inventory.Items[uid]
end

-- Everything equipped, the slotted Beacon core, the skill tree and `buffs`
-- (food and ability bonus tables).
function GearStats.Summarize(data: PlayerData, buffs: { { [string]: number } }?): Summary
	local gearStats: { [string]: number } = {}
	local bonuses: { [string]: number } = {}
	local uniques: { [string]: boolean } = {}
	local armorTotal = 0
	local seen: { [string]: boolean } = {}
	for slot, uid in data.Equipped do
		local item = if uid ~= "" then data.Inventory.Items[uid] else nil
		if item and not seen[uid] then
			seen[uid] = true
			local def = Items.Get(item.DefId)
			local numbers = GearStats.ItemNumbers(item)
			-- An item only counts in a slot it fits (guards hand-edited data).
			if def and numbers and table.find(Items.SlotsFor(def), slot) then
				armorTotal += numbers.Armor
				for stat, value in numbers.Stats do
					add(gearStats, stat, value)
				end
				for id, value in numbers.Bonuses do
					add(bonuses, id, value)
				end
				if numbers.Unique then
					uniques[numbers.Unique] = true
				end
			end
		end
	end
	-- Beacon core: the item id is stored in Beacons.Skin while slotted.
	local core = Items.Get(data.Beacons.Skin)
	if core and core.Core then
		for id, value in core.Core.Bonuses do
			add(bonuses, id, value)
		end
	end
	local treeBonuses, treeStats = ProgressionRules.TreeBonuses(data)
	for id, value in treeBonuses do
		add(bonuses, id, value)
	end
	if buffs then
		for _, buff in buffs do
			for id, value in buff do
				add(bonuses, id, value)
			end
		end
	end
	local stats = table.clone(data.Stats)
	for _, name in STAT_NAMES do
		(stats :: any)[name] = (data.Stats :: any)[name] + (gearStats[name] or 0) + (treeStats[name] or 0)
	end
	-- Bonuses with a hard ceiling (Config.Progression.BonusCaps).
	for id, cap in Config.Progression.BonusCaps :: { [string]: number } do
		if bonuses[id] then
			bonuses[id] = math.min(bonuses[id], cap)
		end
	end
	return {
		Stats = stats,
		GearStats = gearStats,
		TreeStats = treeStats,
		Bonuses = bonuses,
		Armor = armorTotal,
		Uniques = uniques,
		Weight = GearStats.Weight(data),
		MaxWeight = GearStats.MaxWeight(stats.Endurance),
	}
end

return table.freeze(GearStats)
