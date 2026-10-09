--!strict
--[[
	Recipes
	What each crafting station makes (Spec Section 11, Terraria-style).

	  Station   Forge | Armorer | Alchemy | Loom | Altar
	  Output    item id, Count copies, crafted at the item's own rarity
	  Gold      fee paid at the station
	  Materials item id -> count (locked or equipped items are never used)
	  Discover  how the recipe becomes known:
	              "Default"    every Climber knows it
	              "Key"        picking up the Key material for the first time
	              "Blueprint"  using the Blueprint item (Data/Items)

	The recipe book shows every known recipe, greyed out until you have the
	materials; "Track" pins the missing ones to the HUD tracker.
]]

export type Station = "Forge" | "Armorer" | "Alchemy" | "Loom" | "Altar"

export type Recipe = {
	Id: string,
	Station: Station,
	Output: string,
	Count: number,
	Gold: number,
	Materials: { [string]: number },
	Discover: "Default" | "Key" | "Blueprint",
	Key: string?,
	Blueprint: string?,
	Order: number, -- position in the recipe book
}

local list: { Recipe } = {}

local function recipe(r: Recipe)
	table.insert(list, r)
end

-- ALCHEMY TABLE: consumables ---------------------------------------------------
recipe({ Id = "HealingDraught", Station = "Alchemy", Output = "HealingDraught", Count = 2, Gold = 4, Materials = { MarshFiber = 3 }, Discover = "Default", Order = 1 })
recipe({ Id = "CurrentTonic", Station = "Alchemy", Output = "CurrentTonic", Count = 2, Gold = 5, Materials = { WispEssence = 1, MarshFiber = 2 }, Discover = "Key", Key = "WispEssence", Order = 2 })
recipe({ Id = "MarshStew", Station = "Alchemy", Output = "MarshStew", Count = 2, Gold = 4, Materials = { MarshFiber = 3, BrineShell = 1 }, Discover = "Key", Key = "BrineShell", Order = 3 })
recipe({ Id = "PearlBroth", Station = "Alchemy", Output = "PearlBroth", Count = 2, Gold = 6, Materials = { TidePearl = 1, MarshFiber = 2 }, Discover = "Key", Key = "TidePearl", Order = 4 })
recipe({ Id = "BrineBomb", Station = "Alchemy", Output = "BrineBomb", Count = 3, Gold = 6, Materials = { BrineShell = 2, IronScrap = 2, TidePearl = 1 }, Discover = "Key", Key = "TidePearl", Order = 5 })

-- FORGE: weapons and ingots ------------------------------------------------------
recipe({ Id = "SpireIngot", Station = "Forge", Output = "SpireIngot", Count = 1, Gold = 20, Materials = { IronScrap = 10, TidePearl = 2 }, Discover = "Key", Key = "TidePearl", Order = 1 })
recipe({ Id = "TideforgedLongsword", Station = "Forge", Output = "TideforgedLongsword", Count = 1, Gold = 40, Materials = { IronScrap = 12, Rustwood = 4, TidePearl = 2 }, Discover = "Blueprint", Blueprint = "TideforgedBlueprint", Order = 2 })
recipe({ Id = "LanternedgeArcblade", Station = "Forge", Output = "LanternedgeArcblade", Count = 1, Gold = 45, Materials = { IronScrap = 10, Rustwood = 3, WispEssence = 3 }, Discover = "Key", Key = "WispEssence", Order = 3 })
recipe({ Id = "Wispfangs", Station = "Forge", Output = "Wispfangs", Count = 1, Gold = 80, Materials = { IronScrap = 14, WispEssence = 6, Rustwood = 2 }, Discover = "Key", Key = "WispEssence", Order = 4 })
recipe({ Id = "CisternGreatblade", Station = "Forge", Output = "CisternGreatblade", Count = 1, Gold = 110, Materials = { IronScrap = 20, BrineShell = 8, SpireIngot = 1 }, Discover = "Key", Key = "SpireIngot", Order = 5 })

-- ARMORER'S BENCH: armour ----------------------------------------------------------
recipe({ Id = "HarborHood", Station = "Armorer", Output = "HarborHood", Count = 1, Gold = 8, Materials = { MarshFiber = 4, BrineShell = 1 }, Discover = "Default", Order = 1 })
recipe({ Id = "HarborCoat", Station = "Armorer", Output = "HarborCoat", Count = 1, Gold = 12, Materials = { MarshFiber = 6, BrineShell = 2 }, Discover = "Default", Order = 2 })
recipe({ Id = "HarborLeggings", Station = "Armorer", Output = "HarborLeggings", Count = 1, Gold = 10, Materials = { MarshFiber = 5, BrineShell = 1 }, Discover = "Default", Order = 3 })
recipe({ Id = "HarborGloves", Station = "Armorer", Output = "HarborGloves", Count = 1, Gold = 6, Materials = { MarshFiber = 3, IronScrap = 1 }, Discover = "Default", Order = 4 })
recipe({ Id = "HarborCloak", Station = "Armorer", Output = "HarborCloak", Count = 1, Gold = 8, Materials = { MarshFiber = 5 }, Discover = "Default", Order = 5 })
recipe({ Id = "TidewardenHelm", Station = "Armorer", Output = "TidewardenHelm", Count = 1, Gold = 50, Materials = { IronScrap = 8, BrineShell = 4, TidePearl = 2 }, Discover = "Blueprint", Blueprint = "TidewardenPattern", Order = 6 })
recipe({ Id = "TidewardenMail", Station = "Armorer", Output = "TidewardenMail", Count = 1, Gold = 70, Materials = { IronScrap = 12, BrineShell = 6, TidePearl = 3 }, Discover = "Blueprint", Blueprint = "TidewardenPattern", Order = 7 })
recipe({ Id = "TidewardenGreaves", Station = "Armorer", Output = "TidewardenGreaves", Count = 1, Gold = 55, Materials = { IronScrap = 10, BrineShell = 5, TidePearl = 2 }, Discover = "Blueprint", Blueprint = "TidewardenPattern", Order = 8 })
recipe({ Id = "TidewardenGauntlets", Station = "Armorer", Output = "TidewardenGauntlets", Count = 1, Gold = 42, Materials = { IronScrap = 6, BrineShell = 3, TidePearl = 2 }, Discover = "Blueprint", Blueprint = "TidewardenPattern", Order = 9 })
recipe({ Id = "TidewardenMantle", Station = "Armorer", Output = "TidewardenMantle", Count = 1, Gold = 46, Materials = { MarshFiber = 8, WispEssence = 2, TidePearl = 2 }, Discover = "Blueprint", Blueprint = "TidewardenPattern", Order = 10 })

-- CURRENT LOOM: Beacon cores and Current-woven accessories ---------------------------
recipe({ Id = "PearlRing", Station = "Loom", Output = "PearlRing", Count = 1, Gold = 20, Materials = { TidePearl = 3, IronScrap = 4 }, Discover = "Key", Key = "TidePearl", Order = 1 })
recipe({ Id = "BrassAmulet", Station = "Loom", Output = "BrassAmulet", Count = 1, Gold = 20, Materials = { IronScrap = 6, BrineShell = 2 }, Discover = "Default", Order = 2 })
recipe({ Id = "BrineCore", Station = "Loom", Output = "BrineCore", Count = 1, Gold = 35, Materials = { WispEssence = 4, TidePearl = 2, BrineShell = 4 }, Discover = "Key", Key = "WispEssence", Order = 3 })
recipe({ Id = "PearlCore", Station = "Loom", Output = "PearlCore", Count = 1, Gold = 35, Materials = { TidePearl = 6, WispEssence = 2 }, Discover = "Key", Key = "WispEssence", Order = 4 })
recipe({ Id = "EchoCore", Station = "Loom", Output = "EchoCore", Count = 1, Gold = 45, Materials = { WispEssence = 6, SpireIngot = 1 }, Discover = "Key", Key = "SpireIngot", Order = 5 })

-- ALTAR: summoning items --------------------------------------------------------------
recipe({ Id = "BrineSigil", Station = "Altar", Output = "BrineSigil", Count = 1, Gold = 60, Materials = { BrineShell = 10, TidePearl = 4, WispEssence = 4 }, Discover = "Key", Key = "SpireIngot", Order = 1 })

local byId: { [string]: Recipe } = {}
for _, r in list do
	assert(byId[r.Id] == nil, `duplicate recipe {r.Id}`)
	byId[r.Id] = table.freeze(r)
end

local Recipes = {}

Recipes.List = table.freeze(list)

function Recipes.Get(id: string): Recipe?
	return byId[id]
end

-- Known recipes for a station, in book order.
function Recipes.ForStation(station: string): { Recipe }
	local out = {}
	for _, r in list do
		if r.Station == station then
			table.insert(out, r)
		end
	end
	table.sort(out, function(a: Recipe, b: Recipe): boolean
		return a.Order < b.Order
	end)
	return out
end

-- Recipes a first pickup of `itemId` discovers.
function Recipes.DiscoveredBy(itemId: string): { string }
	local out = {}
	for _, r in list do
		if r.Discover == "Key" and r.Key == itemId then
			table.insert(out, r.Id)
		end
	end
	return out
end

-- Recipes a blueprint teaches.
function Recipes.TaughtBy(blueprintId: string): { string }
	local out = {}
	for _, r in list do
		if r.Discover == "Blueprint" and r.Blueprint == blueprintId then
			table.insert(out, r.Id)
		end
	end
	return out
end

return table.freeze(Recipes)
