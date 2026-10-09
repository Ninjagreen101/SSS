--!strict
-- Player-facing world text: floor, district, zone, waystone and hidden-area
-- names, interaction prompts, world feedback and ambient town chatter.

local World: { [string]: string } = {
	["Floor.Lowharbor"] = "Lowharbor",
	["Floor.Subtitle.Lowharbor"] = "Floor 1 — The Drowned Gate",

	["District.Docks"] = "The Docks",
	["District.Market"] = "Lantern Market",
	["District.LowerTerraces"] = "Lower Terraces",
	["District.UpperTerraces"] = "Upper Terraces",
	["District.GuildHill"] = "Guild Hill",

	["Zone.Docks"] = "Lowharbor Docks",
	["Zone.Market"] = "Lantern Market",
	["Zone.Terraces"] = "The Terraces",
	["Zone.GuildHill"] = "Guild Hill",
	["Zone.Bay"] = "Lowharbor Bay",
	["Zone.TidepoolMarsh"] = "Tidepool Marsh",
	["Zone.RustwoodForest"] = "Rustwood Forest",
	["Zone.GatewatchRise"] = "Gatewatch Rise",
	["Zone.GatewatchCrags"] = "Gatewatch Crags",
	["Zone.FirstGate"] = "The First Gate",
	["Zone.SmugglersGrotto"] = "Smugglers' Grotto",
	["Zone.DrownedChapel"] = "Drowned Bell Chapel",
	["Zone.HermitsHollow"] = "Hermit's Hollow",
	["Zone.LanternRoom"] = "The Lantern Room",
	["Zone.Wilds"] = "The Wilds",

	["Zone.Kind.Town"] = "Safe Haven",
	["Zone.Kind.Wild"] = "Wild Zone",
	["Zone.Kind.Hidden"] = "Hidden Place",
	["Zone.Kind.Arena"] = "Guardian Ground",
	["Zone.Kind.Dungeon"] = "Dungeon",
	["Zone.Levels"] = "Lv. %d–%d",
	["Zone.Pressure"] = "Pressure %d",

	["Waystone.HarborSteps"] = "Harbor Steps",
	["Waystone.LanternPlaza"] = "Lantern Plaza",
	["Waystone.ClimbersRest"] = "Climbers' Rest",
	["Waystone.Reedwatch"] = "Reedwatch",
	["Waystone.RustwoodHollow"] = "Rustwood Hollow",
	["Waystone.Gatewatch"] = "Gatewatch",

	["Hidden.SmugglersGrotto"] = "Smugglers' Grotto",
	["Hidden.DrownedChapel"] = "Drowned Bell Chapel",
	["Hidden.HermitsHollow"] = "Hermit's Hollow",
	["Hidden.LanternRoom"] = "The Lantern Room",

	["Dungeon.SunkenCistern"] = "The Sunken Cistern",

	["Prompt.Attune"] = "Attune",
	["Prompt.Waystone"] = "Waystone",
	["Prompt.Travel"] = "Fast Travel",
	["Prompt.OpenChest"] = "Open",
	["Prompt.Chest"] = "Treasure Chest",
	["Prompt.Descend"] = "Descend",
	["Prompt.CisternEntrance"] = "Sunken Cistern",
	["Prompt.TurnValve"] = "Turn",
	["Prompt.Valve"] = "Sluice Valve",
	["Prompt.Leave"] = "Leave",
	["Prompt.Exit"] = "Way Out",

	["Waystone.Panel.Title"] = "Waystones",
	["Waystone.Panel.Subtitle"] = "Step into the Current and rise elsewhere.",
	["Waystone.Panel.Here"] = "You are here",
	["Waystone.Panel.Travel"] = "Travel",
	["Waystone.Panel.Locked"] = "Undiscovered",
	["Waystone.Panel.Close"] = "Close",
	["Waystone.Attuned"] = "Waystone attuned: %s",
	["Waystone.Arrived"] = "Arrived at %s",
	["Waystone.Error.TooFar"] = "Stand at a waystone to travel.",
	["Waystone.Error.Unknown"] = "You have not attuned to that waystone.",
	["Waystone.Error.Cooldown"] = "The Current is still settling. Try again shortly.",
	["Waystone.Error.Combat"] = "You cannot travel while the Current is turbulent.",

	["Chest.Found"] = "Treasure found!",
	["Chest.Gold"] = "+%d Gold",
	["Chest.Already"] = "This chest is empty for you.",

	["Dungeon.Gathering"] = "Gathering at the Cistern… %d",
	["Dungeon.Entering"] = "Descending into %s",
	["Dungeon.Full"] = "Every cistern is flooded with Climbers. Try again in a moment.",
	["Dungeon.ValveTurned"] = "Valve %d of %d turned",
	["Dungeon.GateRises"] = "The sluice gate grinds open!",
	["Dungeon.Left"] = "You return to Lowharbor.",
	["Dungeon.NotCleared"] = "The way out is sealed until the Matron falls.",

	["Healing.Pool"] = "The Current mends you",

	["Sign.Guild"] = "Climbers' Guild",
	["Sign.Harbor"] = "Harbor & Piers",
	["Sign.Market"] = "Lantern Market",
	["Sign.Terraces"] = "The Terraces",
	["Sign.Marsh"] = "Tidepool Marsh",
	["Sign.Forest"] = "Rustwood",
	["Sign.Gate"] = "The First Gate",
	["Sign.Cathedral"] = "Tidewatch Cathedral",
	["Sign.Lighthouse"] = "Lighthouse",
	["Sign.Cistern"] = "Old Pumphouse",
	["Sign.Notices"] = "Climbers Wanted",
	["Sign.GuildName"] = "THE CLIMBERS' GUILD",
	["Sign.Tavern"] = "The Brass Anchor",
	["Sign.Waystone"] = "Waystone",
}

-- Original call-outs used by market stall keepers and dockhands.
local MerchantLines: { [string]: { string } } = {
	Market = {
		"Fresh tidefish, still glowing from the canal!",
		"Lantern oil! Keeps the night-damp out of your bones!",
		"Climbers, mind your step past the Rise — buy a draught first!",
		"Rope, rations and a little luck. Two out of three guaranteed!",
		"Brine pearls from the marsh — hold one to your ear and hear the tide.",
		"Whetstones! A dull blade never reached the second floor.",
		"Warm cider for cold Climbers!",
		"Maps of the Gatewatch road, hand-drawn, mostly accurate!",
	},
	Docks = {
		"Mind the nets, they bite back after dark.",
		"Ship's in from the far rim — first crates go cheap!",
		"Anyone seen my boat? It was here at low tide.",
	},
}

return {
	Text = World,
	MerchantLines = MerchantLines,
}
