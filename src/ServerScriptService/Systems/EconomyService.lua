--!strict
--[[
	EconomyService
	Shops, smithing and the bank: everything you do at a station except
	crafting (CraftingService). Spec Section 11.

	Stations are world objects tagged ItemStation with attributes:
	  StationId    unique id ("Harbor_Forge"), what clients send
	  StationKind  Forge | Armorer | Alchemy | Loom | Altar | Shop | TokenShop | Bank
	  ShopId       Shop / TokenShop: which Data/Shops entry they sell
	Every request names a station; the server checks the player is alive
	and standing within Config.Items.Stations.InteractRadius of it, that the
	station can do that action, then runs the InventoryRules transaction.

	Gold sinks here: upgrades (+7 and higher can fail), repairs, shop
	purchases. Sales go through buy-back so a misclick is never permanent.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Items = require(Shared.Data.Items)
local Shops = require(Shared.Data.Shops)
local Rules = require(Shared.Data.InventoryRules)

local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local AnalyticsService = require(script.Parent.AnalyticsService)

type PlayerData = Types.PlayerData

local A = Attributes.Names

-- Which actions each kind of station allows.
local ACTIONS: { [string]: { [string]: boolean } } = {
	Forge = { Craft = true, Upgrade = true, Repair = true, RepairAll = true, Salvage = true },
	Armorer = { Craft = true, Repair = true, RepairAll = true },
	Alchemy = { Craft = true },
	Loom = { Craft = true },
	Altar = { Craft = true },
	Shop = { Buy = true, Sell = true, Buyback = true },
	TokenShop = { Buy = true, Sell = true, Buyback = true },
	Bank = { Deposit = true, Withdraw = true },
}

local EconomyService = {}

local random = Random.new()
local stations: { [string]: Instance } = {}

local function positionOf(station: Instance): Vector3?
	if station:IsA("Model") then
		return station:GetPivot().Position
	elseif station:IsA("BasePart") then
		return station.Position
	end
	return nil
end

-- The station `stationId` if `player` is alive and close enough to use it.
function EconomyService.StationFor(player: Player, stationId: string): Instance?
	local station = stations[stationId]
	if not station or not station.Parent or not InventoryService.IsAlive(player) then
		return nil
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local point = positionOf(station)
	if not root or not root:IsA("BasePart") or not point then
		return nil
	end
	if (root.Position - point).Magnitude > Config.Items.Stations.InteractRadius then
		return nil
	end
	return station
end

function EconomyService.KindOf(station: Instance): string
	local kind = station:GetAttribute(A.StationKind)
	return if type(kind) == "string" then kind else ""
end

-- REQUESTS -------------------------------------------------------------------------

local CraftingHandler: ((player: Player, station: Instance, recipeId: string) -> ())? = nil

-- CraftingService registers itself here (it needs this module for station checks).
function EconomyService.SetCraftingHandler(handler: (player: Player, station: Instance, recipeId: string) -> ())
	CraftingHandler = handler
end

local function onStation(player: Player, stationId: string, action: string, id: string, count: number)
	local station = EconomyService.StationFor(player, stationId)
	if not station then
		InventoryService.Result(player, false, "Distance", { Action = action })
		return
	end
	local kind = EconomyService.KindOf(station)
	local allowed = ACTIONS[kind]
	if not allowed or not allowed[action] then
		InventoryService.Result(player, false, "WrongStation", { Action = action })
		return
	end
	if action == "Craft" then
		if CraftingHandler then
			CraftingHandler(player, station, id)
		end
		return
	end

	local shopIdAttribute = station:GetAttribute(A.ShopId)
	local shopId = if type(shopIdAttribute) == "string" then shopIdAttribute else ""
	local payload: { [string]: any } = { Action = action }
	local spent = 0
	local currency = "Gold"

	local ok, reason = InventoryService.Transact(player, function(draft: PlayerData): (boolean, string?)
		if action == "Buy" then
			local shop = Shops.Get(shopId)
			local price = shop and Shops.Price(shop, id)
			if not shop or not price then
				return false, "Invalid"
			end
			payload.DefId = id
			payload.Count = count
			spent = price * count
			currency = shop.Currency
			return Rules.Buy(draft, shopId, id, count, random)
		elseif action == "Sell" then
			local item = draft.Inventory.Items[id]
			if not item then
				return false, "Missing"
			end
			payload.DefId = item.DefId
			payload.Gold = Rules.SellPrice(item) * count
			return Rules.Sell(draft, id, count)
		elseif action == "Buyback" then
			for _, entry in draft.ItemState.Buyback do
				if entry.Id == id then
					payload.DefId = entry.Item.DefId
					spent = entry.Price
				end
			end
			return Rules.Buyback(draft, id)
		elseif action == "Upgrade" then
			local item = draft.Inventory.Items[id]
			if not item then
				return false, "Missing"
			end
			local step = Rules.UpgradeStep(item.Upgrade + 1)
			spent = if step then step.Gold else 0
			payload.DefId = item.DefId
			payload.Rarity = item.Rarity
			local upgraded, why = Rules.Upgrade(draft, id, random)
			payload.Level = item.Upgrade
			return upgraded, why
		elseif action == "Repair" then
			local item = draft.Inventory.Items[id]
			if not item then
				return false, "Missing"
			end
			spent = Rules.RepairCost(item)
			payload.DefId = item.DefId
			return Rules.Repair(draft, id)
		elseif action == "RepairAll" then
			local repaired = 0
			for uid, item in draft.Inventory.Items do
				local def = Items.Get(item.DefId)
				if def and Items.IsGear(def) and item.Durability < Config.Items.Durability.Max then
					spent += Rules.RepairCost(item)
					local fixed, why = Rules.Repair(draft, uid)
					if not fixed then
						return false, why
					end
					repaired += 1
				end
			end
			if repaired == 0 then
				return false, "NotDamaged"
			end
			payload.Count = repaired
			return true, nil
		elseif action == "Salvage" then
			local item = draft.Inventory.Items[id]
			if not item then
				return false, "Missing"
			end
			payload.DefId = item.DefId
			payload.Yield = Rules.SalvageYield(item)
			return Rules.Salvage(draft, id, random)
		elseif action == "Deposit" then
			return Rules.Deposit(draft, id)
		elseif action == "Withdraw" then
			return Rules.Withdraw(draft, id)
		end
		return false, "Invalid"
	end)

	if ok then
		local data = DataService.GetData(player)
		if spent > 0 then
			local balance = if data then Rules.Balance(data, currency) else 0
			AnalyticsService.Economy(player, "Sink", currency, spent, balance, if action == "Buy" or action == "Buyback" then "Shop" else "Gameplay", action)
		elseif action == "Sell" and type(payload.Gold) == "number" then
			AnalyticsService.Economy(player, "Source", "Gold", payload.Gold, if data then data.Currencies.Gold else 0, "Shop", "Sell")
		end
	end
	InventoryService.Result(player, ok, reason, payload)
end

-- STATIONS -----------------------------------------------------------------------------

local function track(station: Instance)
	local id = station:GetAttribute(A.StationId)
	if type(id) == "string" and id ~= "" then
		stations[id] = station
	end
end

function EconomyService.Init()
	Net.On("RequestStation", onStation)
end

function EconomyService.Start()
	local tag = Attributes.Tags.ItemStation
	CollectionService:GetInstanceAddedSignal(tag):Connect(track)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(function(station: Instance)
		local id = station:GetAttribute(A.StationId)
		if type(id) == "string" and stations[id] == station then
			stations[id] = nil
		end
	end)
	for _, station in CollectionService:GetTagged(tag) do
		track(station)
	end
end

return EconomyService
