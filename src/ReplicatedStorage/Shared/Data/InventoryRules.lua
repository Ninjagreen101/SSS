--!strict
--[[
	InventoryRules
	Every rule for changing items and currencies, as pure functions on a
	PlayerData table. They never yield, never touch Instances and never
	trust their inputs.

	InventoryService runs them on a private draft copy and only commits the
	draft when the whole operation succeeds, so a failed craft or purchase
	can never leave half its changes behind. The client uses the read-only
	helpers (counts, prices, CanEquip...) to grey out buttons, but the
	server always re-checks.

	Mutating functions return (ok, reason). Reasons are keys in
	Strings.Inventory.Errors.
]]

local Shared = script.Parent.Parent
local Config = require(Shared.Config)
local Types = require(Shared.Types)
local Items = require(script.Parent.Items)
local Affixes = require(script.Parent.Affixes)
local Recipes = require(script.Parent.Recipes)
local Shops = require(script.Parent.Shops)
local GearStats = require(script.Parent.GearStats)

type PlayerData = Types.PlayerData
type ItemInstance = Types.ItemInstance

export type Reason = string

local Rules = {}

-- VALIDATION -------------------------------------------------------------------

function Rules.IsCount(value: any, maximum: number): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and value >= 1 and value <= maximum
end

-- READ HELPERS -----------------------------------------------------------------

function Rules.SlotsUsed(items: { [string]: ItemInstance }): number
	local count = 0
	for _ in items do
		count += 1
	end
	return count
end

-- The equipment slot holding `uid`, if any.
function Rules.EquippedSlot(data: PlayerData, uid: string): string?
	for slot, equipped in data.Equipped do
		if equipped == uid then
			return slot
		end
	end
	return nil
end

-- How many of `defId` are in the bag. `spendable` skips locked and equipped copies.
function Rules.Count(data: PlayerData, defId: string, spendable: boolean?): number
	local total = 0
	for uid, item in data.Inventory.Items do
		if item.DefId == defId and (not spendable or (not item.Locked and Rules.EquippedSlot(data, uid) == nil)) then
			total += item.Count
		end
	end
	return total
end

function Rules.HasMaterials(data: PlayerData, materials: { [string]: number }): boolean
	for defId, count in materials do
		if Rules.Count(data, defId, true) < count then
			return false
		end
	end
	return true
end

function Rules.Balance(data: PlayerData, currency: string, floor: string?): number
	if currency == "Gold" then
		return data.Currencies.Gold
	elseif currency == "Shards" then
		return data.Currencies.Shards
	elseif currency == "FloorTokens" then
		return data.Currencies.FloorTokens[floor or data.Floors.Current] or 0
	end
	return 0
end

-- ITEM CREATION ------------------------------------------------------------------

local function weightedPick<T>(pool: { T }, weightOf: (T) -> number, random: Random): T?
	local total = 0
	for _, entry in pool do
		total += weightOf(entry)
	end
	if total <= 0 then
		return nil
	end
	local roll = random:NextNumber() * total
	for _, entry in pool do
		roll -= weightOf(entry)
		if roll <= 0 then
			return entry
		end
	end
	return pool[#pool]
end

-- A fresh copy of an item. Gear rolls affixes (and a unique effect at
-- Legendary+) for its rarity; `rarity` never goes below the item's own.
function Rules.NewItem(defId: string, rarity: string?, random: Random): ItemInstance
	local def = assert(Items.Get(defId), `unknown item {defId}`)
	local chosen: Types.Rarity = def.Rarity
	if rarity and Config.Items.Rarities[rarity] then
		chosen = Items.MaxRarity(def.Rarity, rarity :: any)
	end
	local item: ItemInstance = {
		Uid = "",
		DefId = defId,
		Count = 1,
		Rarity = chosen,
		Upgrade = 0,
		Durability = Config.Items.Durability.Max,
		Affixes = {},
		Locked = false,
		New = true,
		AcquiredAt = os.time(),
	}
	local group: Affixes.AffixGroup? = Items.AffixGroup(def)
	if group then
		local tuning = Config.Items.Rarities[chosen]
		local pool = Affixes.Pool(group)
		-- Fixed lines on the item don't roll again as affixes.
		local fixed = def.Bonuses or {}
		for index = #pool, 1, -1 do
			if fixed[pool[index].Id] ~= nil then
				table.remove(pool, index)
			end
		end
		for _ = 1, random:NextInteger(tuning.MinAffixes, tuning.MaxAffixes) do
			local affix = weightedPick(pool, function(entry: Affixes.AffixDef): number
				return entry.Weight
			end, random)
			if not affix then
				break
			end
			table.remove(pool, table.find(pool, affix) :: number)
			local value = affix.Min + (affix.Max - affix.Min) * random:NextNumber()
			table.insert(item.Affixes, { Id = affix.Id, Value = Affixes.Round(affix.Kind, value * tuning.AffixPower) })
		end
		if tuning.UniqueEffect and not def.Unique then
			local unique = weightedPick(Affixes.UniquePool(group), function(): number
				return 1
			end, random)
			if unique then
				item.Unique = unique.Id
			end
		end
	end
	return item
end

local function nextUid(data: PlayerData): string
	local inventory = data.Inventory
	local uid = tostring(inventory.NextUid)
	while inventory.Items[uid] or data.Bank.Items[uid] do
		inventory.NextUid += 1
		uid = tostring(inventory.NextUid)
	end
	inventory.NextUid += 1
	return uid
end

-- Learns recipes the first pickup of `defId` discovers. Returns the new ones.
function Rules.NoteSeen(data: PlayerData, defId: string): { string }
	local learned = {}
	if data.ItemState.SeenItems[defId] then
		return learned
	end
	data.ItemState.SeenItems[defId] = true
	for _, recipeId in Recipes.DiscoveredBy(defId) do
		if not data.RecipesKnown[recipeId] then
			data.RecipesKnown[recipeId] = true
			table.insert(learned, recipeId)
		end
	end
	return learned
end

-- Every "Default" recipe, plus key-material recipes for items already seen.
function Rules.LearnBaseRecipes(data: PlayerData)
	for _, recipe in Recipes.List do
		if recipe.Discover == "Default" then
			data.RecipesKnown[recipe.Id] = true
		elseif recipe.Discover == "Key" and recipe.Key and data.ItemState.SeenItems[recipe.Key] then
			data.RecipesKnown[recipe.Id] = true
		end
	end
end

-- ADD / REMOVE ---------------------------------------------------------------------

-- Puts `count` copies of `item` into the bag: tops up existing stacks of
-- the same item and rarity first, then opens new slots. Fails (and changes
-- nothing the caller keeps) if the bag runs out of slots.
function Rules.Add(data: PlayerData, item: ItemInstance, count: number): (boolean, Reason?)
	local def = Items.Get(item.DefId)
	if not def or not Rules.IsCount(count, Config.Items.Inventory.MaxStack * 10) then
		return false, "Invalid"
	end
	local remaining = count
	if def.StackSize > 1 then
		for _, existing in data.Inventory.Items do
			if existing.DefId == item.DefId and existing.Rarity == item.Rarity and existing.Count < def.StackSize then
				local moved = math.min(remaining, def.StackSize - existing.Count)
				existing.Count += moved
				existing.New = true
				remaining -= moved
				if remaining == 0 then
					break
				end
			end
		end
	end
	while remaining > 0 do
		if Rules.SlotsUsed(data.Inventory.Items) >= data.Inventory.Capacity then
			return false, "Full"
		end
		local entry = table.clone(item)
		entry.Affixes = table.clone(item.Affixes)
		entry.Uid = nextUid(data)
		entry.Count = math.min(remaining, def.StackSize)
		data.Inventory.Items[entry.Uid] = entry
		remaining -= entry.Count
	end
	Rules.NoteSeen(data, item.DefId)
	return true, nil
end

-- Creates and adds a fresh item (crafting, shops, quest rewards).
function Rules.Grant(data: PlayerData, defId: string, count: number, random: Random, rarity: string?): (boolean, Reason?)
	if not Items.Get(defId) then
		return false, "Invalid"
	end
	local def = Items.Get(defId) :: Items.ItemDef
	if def.StackSize > 1 then
		return Rules.Add(data, Rules.NewItem(defId, rarity, random), count)
	end
	-- Gear: every copy rolls its own affixes.
	for _ = 1, count do
		local ok, reason = Rules.Add(data, Rules.NewItem(defId, rarity, random), 1)
		if not ok then
			return false, reason
		end
	end
	return true, nil
end

function Rules.Remove(data: PlayerData, uid: string, count: number): (boolean, Reason?)
	local item = data.Inventory.Items[uid]
	if not item or not Rules.IsCount(count, item.Count) then
		return false, "Missing"
	end
	if item.Locked then
		return false, "Locked"
	end
	if Rules.EquippedSlot(data, uid) then
		return false, "Equipped"
	end
	item.Count -= count
	if item.Count <= 0 then
		data.Inventory.Items[uid] = nil
	end
	return true, nil
end

-- Spends materials from unlocked, unequipped stacks (smallest stacks first,
-- so partial stacks get used up before full ones).
function Rules.Consume(data: PlayerData, materials: { [string]: number }): (boolean, Reason?)
	if not Rules.HasMaterials(data, materials) then
		return false, "Materials"
	end
	for defId, count in materials do
		local stacks = {}
		for uid, item in data.Inventory.Items do
			if item.DefId == defId and not item.Locked and Rules.EquippedSlot(data, uid) == nil then
				table.insert(stacks, item)
			end
		end
		table.sort(stacks, function(a: ItemInstance, b: ItemInstance): boolean
			return if a.Count == b.Count then a.Uid < b.Uid else a.Count < b.Count
		end)
		local remaining = count
		for _, item in stacks do
			local take = math.min(remaining, item.Count)
			item.Count -= take
			if item.Count <= 0 then
				data.Inventory.Items[item.Uid] = nil
			end
			remaining -= take
			if remaining == 0 then
				break
			end
		end
	end
	return true, nil
end

-- CURRENCIES -------------------------------------------------------------------------

local function capFor(currency: string): number
	if currency == "Gold" then
		return Config.Economy.MaxGold
	elseif currency == "Shards" then
		return Config.Economy.MaxShards
	end
	return Config.Economy.MaxGold
end

function Rules.Pay(data: PlayerData, currency: string, amount: number, floor: string?): (boolean, Reason?)
	if type(amount) ~= "number" or amount ~= amount or amount < 0 or amount % 1 ~= 0 then
		return false, "Invalid"
	end
	if Rules.Balance(data, currency, floor) < amount then
		return false, "Funds"
	end
	if currency == "Gold" then
		data.Currencies.Gold -= amount
	elseif currency == "Shards" then
		data.Currencies.Shards -= amount
	elseif currency == "FloorTokens" then
		local key = floor or data.Floors.Current
		data.Currencies.FloorTokens[key] = (data.Currencies.FloorTokens[key] or 0) - amount
	else
		return false, "Invalid"
	end
	return true, nil
end

-- Adds currency, clamped to its cap. Returns how much actually landed.
function Rules.Earn(data: PlayerData, currency: string, amount: number, floor: string?): number
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return 0
	end
	amount = math.floor(amount)
	local before = Rules.Balance(data, currency, floor)
	local after = math.min(capFor(currency), before + amount)
	if currency == "Gold" then
		data.Currencies.Gold = after
	elseif currency == "Shards" then
		data.Currencies.Shards = after
	elseif currency == "FloorTokens" then
		data.Currencies.FloorTokens[floor or data.Floors.Current] = after
	else
		return 0
	end
	return after - before
end

-- EQUIPMENT -----------------------------------------------------------------------------

function Rules.CanEquip(data: PlayerData, item: ItemInstance, slot: string): (boolean, Reason?)
	local def = Items.Get(item.DefId)
	if not def or not Items.IsGear(def) then
		return false, "Invalid"
	end
	if not table.find(Items.SlotsFor(def), slot) then
		return false, "WrongSlot"
	end
	if data.Level < def.RequiredLevel then
		return false, "Level"
	end
	return true, nil
end

function Rules.Equip(data: PlayerData, uid: string, slot: string): (boolean, Reason?)
	local item = data.Inventory.Items[uid]
	if not item then
		return false, "Missing"
	end
	local ok, reason = Rules.CanEquip(data, item, slot)
	if not ok then
		return false, reason
	end
	-- Moving a ring between ring slots: clear its old slot.
	local previous = Rules.EquippedSlot(data, uid)
	if previous then
		data.Equipped[previous] = ""
	end
	data.Equipped[slot] = uid
	item.New = false
	return true, nil
end

-- Best slot to equip into when the player didn't pick one: the first
-- empty fitting slot, else the first fitting slot.
function Rules.DefaultSlot(data: PlayerData, item: ItemInstance): string?
	local def = Items.Get(item.DefId)
	if not def then
		return nil
	end
	local slots = Items.SlotsFor(def)
	for _, slot in slots do
		if data.Equipped[slot] == "" then
			return slot
		end
	end
	return slots[1]
end

function Rules.Unequip(data: PlayerData, slot: string): (boolean, Reason?)
	if data.Equipped[slot] == nil then
		return false, "Invalid"
	end
	data.Equipped[slot] = ""
	return true, nil
end

-- STACKS ------------------------------------------------------------------------------------

function Rules.Split(data: PlayerData, uid: string, count: number): (boolean, Reason?)
	local item = data.Inventory.Items[uid]
	if not item or not Rules.IsCount(count, item.Count - 1) then
		return false, "Invalid"
	end
	if item.Locked then
		return false, "Locked"
	end
	if Rules.SlotsUsed(data.Inventory.Items) >= data.Inventory.Capacity then
		return false, "Full"
	end
	local copy = table.clone(item)
	copy.Affixes = table.clone(item.Affixes)
	copy.Uid = nextUid(data)
	copy.Count = count
	item.Count -= count
	data.Inventory.Items[copy.Uid] = copy
	return true, nil
end

-- SMITHING -------------------------------------------------------------------------------------

export type UpgradeStep = { Gold: number, Materials: { [string]: number }, FailChance: number }

function Rules.UpgradeStep(target: number): UpgradeStep?
	return Config.Items.Upgrade.Steps[target]
end

-- Returns ok, reason; ok with reason "UpgradeFailed" means the attempt was
-- paid for and rolled a failure (item kept at its level).
function Rules.Upgrade(data: PlayerData, uid: string, random: Random): (boolean, Reason?)
	local item = data.Inventory.Items[uid]
	local def = item and Items.Get(item.DefId)
	if not item or not def or not Items.IsGear(def) then
		return false, "Invalid"
	end
	if item.Upgrade >= Config.Items.Upgrade.MaxLevel then
		return false, "Maximum"
	end
	local step = Rules.UpgradeStep(item.Upgrade + 1) :: UpgradeStep
	local paid, reason = Rules.Pay(data, "Gold", step.Gold)
	if not paid then
		return false, reason
	end
	local consumed, why = Rules.Consume(data, step.Materials)
	if not consumed then
		return false, why
	end
	if random:NextNumber() < step.FailChance then
		return true, "UpgradeFailed"
	end
	item.Upgrade += 1
	return true, nil
end

function Rules.RepairCost(item: ItemInstance): number
	local rarity = Config.Items.Rarities[item.Rarity]
	local missing = Config.Items.Durability.Max - item.Durability
	return math.ceil(missing * Config.Items.Durability.RepairGoldPerPoint * (if rarity then rarity.StatMultiplier else 1))
end

function Rules.Repair(data: PlayerData, uid: string): (boolean, Reason?)
	local item = data.Inventory.Items[uid]
	local def = item and Items.Get(item.DefId)
	if not item or not def or not Items.IsGear(def) then
		return false, "Invalid"
	end
	if item.Durability >= Config.Items.Durability.Max then
		return false, "NotDamaged"
	end
	local paid, reason = Rules.Pay(data, "Gold", Rules.RepairCost(item))
	if not paid then
		return false, reason
	end
	item.Durability = Config.Items.Durability.Max
	return true, nil
end

-- What salvaging one piece of gear returns.
function Rules.SalvageYield(item: ItemInstance): { [string]: number }
	local rarity = Config.Items.Rarities[item.Rarity]
	local out: { [string]: number } = { IronScrap = if rarity then rarity.SalvageScrap else 1 }
	local salvage = Config.Items.Salvage
	if Items.RarityRank(item.Rarity) >= Items.RarityRank(salvage.IngotFromRarity) then
		out.SpireIngot = salvage.Ingots
	end
	return out
end

function Rules.Salvage(data: PlayerData, uid: string, random: Random): (boolean, Reason?)
	local item = data.Inventory.Items[uid]
	local def = item and Items.Get(item.DefId)
	if not item or not def or not Items.IsGear(def) then
		return false, "Invalid"
	end
	local yield = Rules.SalvageYield(item)
	local removed, reason = Rules.Remove(data, uid, 1)
	if not removed then
		return false, reason
	end
	for material, count in yield do
		local ok, why = Rules.Grant(data, material, count, random)
		if not ok then
			return false, why
		end
	end
	return true, nil
end

-- SHOPS ---------------------------------------------------------------------------------------------

-- Gold a shop pays for one of this item (0 = it won't buy it).
function Rules.SellPrice(item: ItemInstance): number
	local def = Items.Get(item.DefId)
	if not def or not def.Tradeable then
		return 0
	end
	local rarity = Config.Items.Rarities[item.Rarity]
	local value = def.SellPrice * (if rarity then rarity.StatMultiplier else 1) * (1 + item.Upgrade * 0.25)
	return math.floor(value * Config.Items.Shop.SellMultiplier)
end

function Rules.Buy(data: PlayerData, shopId: string, itemId: string, count: number, random: Random): (boolean, Reason?)
	local shop = Shops.Get(shopId)
	local def = Items.Get(itemId)
	local price = shop and Shops.Price(shop, itemId)
	if not shop or not def or not price then
		return false, "Invalid"
	end
	local maximum = if def.StackSize > 1 then def.StackSize else 1
	if not Rules.IsCount(count, maximum) then
		return false, "Invalid"
	end
	local paid, reason = Rules.Pay(data, shop.Currency, price * count, shop.Floor)
	if not paid then
		return false, reason
	end
	return Rules.Grant(data, itemId, count, random)
end

function Rules.Sell(data: PlayerData, uid: string, count: number): (boolean, Reason?)
	local item = data.Inventory.Items[uid]
	if not item then
		return false, "Missing"
	end
	local unit = Rules.SellPrice(item)
	if unit <= 0 then
		return false, "CantSell"
	end
	local sold = table.clone(item)
	sold.Affixes = table.clone(item.Affixes)
	sold.Count = count
	sold.New = false
	local removed, reason = Rules.Remove(data, uid, count)
	if not removed then
		return false, reason
	end
	local price = unit * count
	Rules.Earn(data, "Gold", price)
	local state = data.ItemState
	table.insert(state.Buyback, { Id = tostring(state.NextBuyback), Item = sold, Price = price })
	state.NextBuyback += 1
	while #state.Buyback > Config.Items.Shop.BuybackSlots do
		table.remove(state.Buyback, 1)
	end
	return true, nil
end

function Rules.Buyback(data: PlayerData, entryId: string): (boolean, Reason?)
	for index, entry in data.ItemState.Buyback do
		if entry.Id == entryId then
			local paid, reason = Rules.Pay(data, "Gold", entry.Price)
			if not paid then
				return false, reason
			end
			local added, why = Rules.Add(data, entry.Item, entry.Item.Count)
			if not added then
				return false, why
			end
			table.remove(data.ItemState.Buyback, index)
			return true, nil
		end
	end
	return false, "Missing"
end

-- CRAFTING ----------------------------------------------------------------------------------------------

function Rules.CanCraft(data: PlayerData, recipeId: string): (boolean, Reason?)
	local recipe = Recipes.Get(recipeId)
	if not recipe then
		return false, "Invalid"
	end
	if not data.RecipesKnown[recipeId] then
		return false, "Unknown"
	end
	if data.Currencies.Gold < recipe.Gold then
		return false, "Funds"
	end
	if not Rules.HasMaterials(data, recipe.Materials) then
		return false, "Materials"
	end
	return true, nil
end

function Rules.Craft(data: PlayerData, recipeId: string, random: Random): (boolean, Reason?)
	local ok, reason = Rules.CanCraft(data, recipeId)
	if not ok then
		return false, reason
	end
	local recipe = Recipes.Get(recipeId) :: Recipes.Recipe
	Rules.Pay(data, "Gold", recipe.Gold)
	Rules.Consume(data, recipe.Materials)
	return Rules.Grant(data, recipe.Output, recipe.Count, random)
end

-- Uses a blueprint: learns its recipes and consumes it.
function Rules.LearnBlueprint(data: PlayerData, uid: string): (boolean, Reason?)
	local item = data.Inventory.Items[uid]
	local def = item and Items.Get(item.DefId)
	if not item or not def or def.Type ~= "Blueprint" then
		return false, "Invalid"
	end
	local learned = 0
	for _, recipeId in Recipes.TaughtBy(def.Id) do
		if not data.RecipesKnown[recipeId] then
			data.RecipesKnown[recipeId] = true
			learned += 1
		end
	end
	if learned == 0 then
		return false, "AlreadyKnown"
	end
	return Rules.Remove(data, uid, 1)
end

-- BANK -----------------------------------------------------------------------------------------------------

function Rules.Deposit(data: PlayerData, uid: string): (boolean, Reason?)
	local item = data.Inventory.Items[uid]
	if not item then
		return false, "Missing"
	end
	if Rules.EquippedSlot(data, uid) then
		return false, "Equipped"
	end
	if Rules.SlotsUsed(data.Bank.Items) >= data.Bank.Capacity then
		return false, "BankFull"
	end
	data.Inventory.Items[uid] = nil
	data.Bank.Items[uid] = item
	return true, nil
end

function Rules.Withdraw(data: PlayerData, uid: string): (boolean, Reason?)
	local item = data.Bank.Items[uid]
	if not item then
		return false, "Missing"
	end
	if Rules.SlotsUsed(data.Inventory.Items) >= data.Inventory.Capacity then
		return false, "Full"
	end
	data.Bank.Items[uid] = nil
	data.Inventory.Items[uid] = item
	return true, nil
end

-- DEATH ---------------------------------------------------------------------------------------------------

-- Equipped gear loses durability on death only (Spec Section 11).
function Rules.WearOnDeath(data: PlayerData)
	for _, uid in data.Equipped do
		local item = if uid ~= "" then data.Inventory.Items[uid] else nil
		if item then
			item.Durability = math.max(0, item.Durability - Config.Items.Durability.LossOnDeath)
		end
	end
end

-- Whether the bag is over its carry weight (with gear stats applied).
function Rules.IsOverburdened(data: PlayerData): boolean
	local summary = GearStats.Summarize(data)
	return summary.Weight > summary.MaxWeight
end

return table.freeze(Rules)
