--!strict
--[[
	ItemText
	Everything the UI says about an item: its name, rarity line, stat and
	affix lines, and the full tooltip with an "equipped vs this" comparison
	(green = better, red = worse). Shared by the inventory, character
	sheet, stations, loot labels and toasts so an item reads the same
	everywhere.

	Numbers come from Shared/Data/GearStats (the same code the server uses),
	text from Strings.Items and Strings.Inventory.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Types = require(Shared.Types)
local Items = require(Shared.Data.Items)
local Affixes = require(Shared.Data.Affixes)
local GearStats = require(Shared.Data.GearStats)
local Rules = require(Shared.Data.InventoryRules)

local UITheme = require(script.Parent.UITheme)
local Components = require(script.Parent.Components)

type ItemInstance = Types.ItemInstance
type PlayerData = Types.PlayerData

local S = Strings.Inventory

local ItemText = {}

local BETTER = UITheme.Colors.Heal
local WORSE = UITheme.Colors.Danger

function ItemText.Name(defId: string): string
	local entry = Strings.Items[defId]
	return if entry then entry.Name else defId
end

function ItemText.Description(defId: string): string
	local entry = Strings.Items[defId]
	return if entry then entry.Description else ""
end

function ItemText.Flavor(defId: string): string
	local entry = Strings.Items[defId]
	return if entry then entry.Flavor else ""
end

function ItemText.RarityName(rarity: string): string
	return Strings.Gallery.RarityNames[rarity] or rarity
end

-- "Tideforged Longsword +3"
function ItemText.FullName(item: ItemInstance): string
	local name = ItemText.Name(item.DefId)
	return if item.Upgrade > 0 then `{name} +{item.Upgrade}` else name
end

-- What an ItemSlot shows for an item.
function ItemText.Slot(item: ItemInstance): Components.SlotItem
	return {
		Name = ItemText.Name(item.DefId),
		Rarity = item.Rarity,
		DefId = item.DefId,
		Count = item.Count,
		Upgrade = item.Upgrade,
		Locked = item.Locked,
		New = item.New,
		Broken = item.Durability <= 0 and Items.Get(item.DefId) ~= nil and Items.IsGear(Items.Get(item.DefId) :: Items.ItemDef),
	}
end

-- One affix value as shown: "6" for 6%, "0.5" for seconds, "2" for points.
function ItemText.AffixValue(id: string, value: number): string
	local def = Affixes.Get(id)
	local kind = if def then def.Kind else "Percent"
	if kind == "Percent" or id == "SentryDamage" or id == "AegisRecharge" or id == "RelayCooldown" then
		return tostring(math.floor(value * 100 + 0.5))
	elseif kind == "Seconds" then
		return string.format("%.1f", value)
	end
	return tostring(math.floor(value + 0.5))
end

function ItemText.AffixLine(id: string, value: number): string
	local template = S.Affixes[id]
	if not template then
		return `{id} {value}`
	end
	if id == "ParryWindow" and value >= 1.5 then
		template = S.ParryFrames
	end
	return Strings.Format(template, { value = ItemText.AffixValue(id, value) })
end

function ItemText.UniqueName(id: string): string
	local entry = S.Uniques[id]
	return if entry then entry.Name else id
end

function ItemText.UniqueDescription(id: string): string
	local entry = S.Uniques[id]
	return if entry then entry.Description else ""
end

function ItemText.Subtitle(def: Items.ItemDef, rarity: string): string
	local rarityName = ItemText.RarityName(rarity)
	if def.Type == "Weapon" and def.Class then
		return Strings.Format(S.WeaponSubtitle, { rarity = rarityName, class = S.ClassNames[def.Class] or def.Class })
	end
	local typeName = S.TypeNames[def.Type] or def.Type
	if def.Slot then
		typeName = `{S.SlotNames[def.Slot] or def.Slot} {typeName}`
	end
	return Strings.Format(S.Subtitle, { rarity = rarityName, type = typeName })
end

-- The item in `data` equipped where `item` would go (for comparisons).
function ItemText.CompareTarget(data: PlayerData?, item: ItemInstance): ItemInstance?
	if not data then
		return nil
	end
	local def = Items.Get(item.DefId)
	if not def or not Items.IsGear(def) then
		return nil
	end
	for _, slot in Items.SlotsFor(def) do
		local equipped = GearStats.EquippedItem(data, slot)
		if equipped and equipped.Uid ~= item.Uid then
			return equipped
		end
	end
	return nil
end

local function colorFor(diff: number?): Color3?
	if not diff or math.abs(diff) < 0.001 then
		return nil
	end
	return if diff > 0 then BETTER else WORSE
end

local function signed(value: number, decimals: number): string
	local text = string.format(`%.{decimals}f`, math.abs(value))
	return if value >= 0 then `+{text}` else `-{text}`
end

-- Tooltip lines for one item, compared with `against` when given.
function ItemText.Lines(item: ItemInstance, against: ItemInstance?, data: PlayerData?): { Components.TooltipLine }
	local def = Items.Get(item.DefId)
	if not def then
		return {}
	end
	local lines: { Components.TooltipLine } = {}
	local numbers = GearStats.ItemNumbers(item)
	local other = if against then GearStats.ItemNumbers(against) else nil

	if numbers then
		if numbers.Damage then
			local diff = if other and other.Damage then numbers.Damage - other.Damage else nil
			local text = Strings.Format(S.Damage, { value = string.format("%.1f", numbers.Damage) })
			table.insert(lines, { Text = if diff then `{text}  ({signed(diff, 1)})` else text, Color = colorFor(diff), Bold = true })
		end
		if numbers.Posture then
			local diff = if other and other.Posture then numbers.Posture - other.Posture else nil
			local text = Strings.Format(S.Posture, { value = string.format("%.1f", numbers.Posture) })
			table.insert(lines, { Text = if diff then `{text}  ({signed(diff, 1)})` else text, Color = colorFor(diff) })
		end
		if numbers.Armor > 0 or (other and other.Armor > 0) then
			local diff = if other then (numbers.Armor - other.Armor) * 100 else nil
			local text = Strings.Format(S.Armor, { value = string.format("%.1f", numbers.Armor * 100) })
			table.insert(lines, { Text = if diff then `{text}  ({signed(diff, 1)})` else text, Color = colorFor(diff), Bold = true })
		end
		-- Stat points (base + rolled), compared stat by stat.
		for _, stat in GearStats.StatNames do
			local value = numbers.Stats[stat] or 0
			local was = if other then other.Stats[stat] or 0 else nil
			if value ~= 0 then
				local diff = if was then value - was else nil
				local text = Strings.Format(S.StatLine, { value = value, stat = S.StatNames[stat] or stat })
				table.insert(lines, { Text = if diff and diff ~= 0 then `{text}  ({signed(diff, 0)})` else text, Color = colorFor(diff) })
			elseif was and was ~= 0 then
				table.insert(lines, { Text = Strings.Format(S.StatLine, { value = 0, stat = S.StatNames[stat] or stat }) .. `  ({signed(-was, 0)})`, Color = WORSE })
			end
		end
		-- Bonus lines: fixed ones then rolled affixes (in rolled order).
		local shown: { [string]: boolean } = {}
		local function bonusLine(id: string, value: number)
			if shown[id] then
				return
			end
			shown[id] = true
			local was = if other then other.Bonuses[id] or 0 else nil
			local diff = if was then value - was else nil
			table.insert(lines, { Text = ItemText.AffixLine(id, value), Color = colorFor(diff) or UITheme.Colors.Current })
		end
		if def.Bonuses then
			for id in def.Bonuses do
				bonusLine(id, numbers.Bonuses[id] or 0)
			end
		end
		for _, affix in item.Affixes do
			local affixDef = Affixes.Get(affix.Id)
			if not (affixDef and affixDef.Kind == "Points") then
				bonusLine(affix.Id, numbers.Bonuses[affix.Id] or affix.Value)
			end
		end
		if numbers.Unique then
			table.insert(lines, { Text = Strings.Format(S.Unique, { name = ItemText.UniqueName(numbers.Unique) }), Color = UITheme.Rarity.Legendary, Bold = true })
			table.insert(lines, { Text = ItemText.UniqueDescription(numbers.Unique), Color = UITheme.Colors.TextMuted })
		end
		table.insert(lines, {
			Text = if item.Durability <= 0
				then S.Broken
				else Strings.Format(S.Durability, { value = item.Durability, max = Config.Items.Durability.Max }),
			Color = if item.Durability <= 0 then WORSE elseif item.Durability < 40 then UITheme.Colors.Stamina else UITheme.Colors.TextDim,
		})
	elseif def.Core then
		for id, value in def.Core.Bonuses do
			table.insert(lines, { Text = ItemText.AffixLine(id, value), Color = UITheme.Colors.Current })
		end
	end

	local description = ItemText.Description(item.DefId)
	if description ~= "" and not numbers then
		table.insert(lines, { Text = description })
	end
	if def.RequiredLevel > 1 then
		local low = data ~= nil and data.Level < def.RequiredLevel
		table.insert(lines, { Text = Strings.Format(S.RequiredLevel, { level = def.RequiredLevel }), Color = if low then WORSE else UITheme.Colors.TextMuted })
	end
	if item.Count > 1 then
		table.insert(lines, { Text = Strings.Format(S.StackOf, { count = item.Count }), Color = UITheme.Colors.TextMuted })
	end
	local price = Rules.SellPrice(item)
	table.insert(lines, {
		Text = if price > 0 then Strings.Format(S.SellValue, { gold = price }) else S.CantSell,
		Color = UITheme.Colors.TextDim,
	})
	return lines
end

-- Full tooltip content for an item (compares with what's equipped in `data`).
function ItemText.Tooltip(item: ItemInstance, data: PlayerData?): Components.TooltipContent?
	local def = Items.Get(item.DefId)
	if not def then
		return nil
	end
	local against = ItemText.CompareTarget(data, item)
	local lines = ItemText.Lines(item, against, data)
	if against then
		table.insert(lines, 1, { Text = Strings.Format(S.Compare, { name = ItemText.FullName(against) }), Color = UITheme.Colors.TextDim })
	end
	if data and Rules.EquippedSlot(data, item.Uid) then
		table.insert(lines, 1, { Text = S.Equipped, Color = UITheme.Colors.Current, Bold = true })
	end
	local flavor = ItemText.Flavor(item.DefId)
	return {
		Title = ItemText.FullName(item),
		TitleColor = UITheme.RarityColor(item.Rarity),
		Subtitle = ItemText.Subtitle(def, item.Rarity),
		Lines = lines,
		Footer = if flavor ~= "" then flavor else nil,
	}
end

-- A display copy of an item definition (shop stock, recipe outputs).
function ItemText.Preview(defId: string, count: number?): ItemInstance
	local def = Items.Get(defId)
	return {
		Uid = `preview:{defId}`,
		DefId = defId,
		Count = count or 1,
		Rarity = if def then def.Rarity else "Common",
		Upgrade = 0,
		Durability = Config.Items.Durability.Max,
		Affixes = {},
		Locked = false,
		New = false,
		AcquiredAt = 0,
		Unique = if def then def.Unique else nil,
	}
end

return ItemText
