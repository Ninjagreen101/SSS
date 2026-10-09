--!strict
--[[
	Shops
	What each vendor sells. A shop station in the world names its shop with
	the ShopId attribute (Config.Items.Stations). Prices are in the shop's
	Currency; FloorTokens shops spend that floor's tokens.

	Every shop also buys: it pays SellPrice x Config.Items.Shop.SellMultiplier
	(more for upgraded gear) and keeps the last few sales for buy-back.
]]

export type Currency = "Gold" | "Shards" | "FloorTokens"

export type Entry = {
	Id: string,
	Price: number,
}

export type Shop = {
	Id: string,
	Currency: Currency,
	Floor: string?, -- FloorTokens shops: which floor's tokens
	Stock: { Entry },
}

local shops: { [string]: Shop } = {
	-- Harbor provisions in Lowharbor's market: basics for new Climbers.
	Harbor = {
		Id = "Harbor",
		Currency = "Gold",
		Stock = {
			{ Id = "HealingDraught", Price = 18 },
			{ Id = "CurrentTonic", Price = 20 },
			{ Id = "MarshStew", Price = 22 },
			{ Id = "BrineBomb", Price = 26 },
			{ Id = "IronScrap", Price = 8 },
			{ Id = "MarshFiber", Price = 7 },
			{ Id = "Rustwood", Price = 10 },
			{ Id = "TideforgedBlueprint", Price = 90 },
			{ Id = "HarborHood", Price = 40 },
			{ Id = "HarborCoat", Price = 55 },
			{ Id = "HarborLeggings", Price = 45 },
			{ Id = "HarborGloves", Price = 32 },
			{ Id = "HarborCloak", Price = 36 },
			{ Id = "StonejawGreatblade", Price = 45 },
			{ Id = "BrinecutTwinfangs", Price = 40 },
			{ Id = "SpirewatchLance", Price = 42 },
			{ Id = "GleamNeedle", Price = 40 },
			{ Id = "RuneedgeArcblade", Price = 42 },
		},
	},
	-- Floor 1 token vendor: Sunken Cistern rewards.
	Floor1Tokens = {
		Id = "Floor1Tokens",
		Currency = "FloorTokens",
		Floor = "1",
		Stock = {
			{ Id = "SpireIngot", Price = 3 },
			{ Id = "TidewardenPattern", Price = 10 },
			{ Id = "CisternGreatblade", Price = 18 },
			{ Id = "CoralBand", Price = 14 },
			{ Id = "LanternPendant", Price = 24 },
		},
	},
}

for _, shop in shops do
	for _, entry in shop.Stock do
		table.freeze(entry)
	end
	table.freeze(shop.Stock)
	table.freeze(shop)
end

local Shops = {}

function Shops.Get(id: string): Shop?
	return shops[id]
end

function Shops.Price(shop: Shop, itemId: string): number?
	for _, entry in shop.Stock do
		if entry.Id == itemId then
			return entry.Price
		end
	end
	return nil
end

return table.freeze(Shops)
