--!strict
-- Currencies, sinks, social and trading rules (Spec Sections 11 and 14).

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

return TableUtil.DeepFreeze({
	StartingGold = 25,
	MaxGold = 999_999_999,
	MaxShards = 9_999_999,

	Death = {
		GoldDropFraction = 0.10, -- dropped as a Lost Current orb
	},

	MarketBoard = {
		UnlockLevel = 20,
		ListingFeeFraction = 0.05,
		MaxListings = 10,
	},

	Trade = {
		CountdownSeconds = 3,
		MaxItemsPerSide = 12,
		RequestTimeout = 20,
		MaxDistance = 30,
	},

	Party = {
		MaxSize = 6,
		RaidMaxSize = 8,
		InviteTimeout = 30,
	},

	Companies = {
		UnlockLevel = 20,
		MaxMembers = 50,
		CreationCost = 5000,
	},

	FastTravel = {
		SameFloorCost = 0,
		BetweenFloorsCostPerFloor = 50,
	},

	Server = {
		MaxPlayers = 30,
	},
})
