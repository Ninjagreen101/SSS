--!strict
-- Parties, raids, party finder, pings, trading, Climber Companies, emotes and inspect
-- (Phase 12, docs/PHASE12_MULTIPLAYER.md).

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

return TableUtil.DeepFreeze({
	Party = {
		MaxMembers = 6,
		RaidMaxMembers = 8, -- a raid group (Guardian fights) is a party converted by its leader
		InviteSeconds = 30, -- an invite expires after this
		InviteRadius = 120, -- "nearby" list in the invite panel
		ShareRadius = 150, -- kill XP is shared with members this close (spec)
		XPBonusPerMember = 0.1, -- +10% kill XP per other member in range (spec)
		LootModes = { "Personal", "SharedGold" }, -- Personal: everyone rolls their own; SharedGold: gold split evenly
		PingSeconds = 8, -- a ping marker lasts this long
		PingCooldown = 1.0,
		MaxPings = 3, -- per player at once
		PingRange = 600, -- studs: a ping must land this close to the pinger
		FrameUpdateHz = 4, -- party frame health/Current refresh
	},

	Finder = {
		MaxListings = 40, -- per server
		ListingSeconds = 900, -- a listing expires after 15 minutes unless refreshed
		WatchSeconds = 60, -- a Refresh keeps sending you board updates this long (the open tab re-sends it)
		NoteMax = 80, -- characters in a listing note (matches the RequestFinder validator)
		Activities = { "Questing", "Dungeon:SunkenCistern", "Guardian:Brinewarden", "Farming" },
	},

	Instances = {
		-- Dungeons and Guardian arenas run in reserved servers when the place is published
		-- (game.PlaceId ~= 0) and UseReservedServers is true; otherwise in this server (decision #133).
		UseReservedServers = true,
		TeleportRetries = 3,
		ReturnTimeout = 20, -- seconds an instance server waits after the run before sending everyone home
		ArrivalTimeout = 45, -- seconds an instance server waits for its party before giving up
	},

	Trade = {
		MaxDistance = 20, -- studs between the two players to start and to confirm
		RequestSeconds = 20,
		MaxItems = 8, -- item slots per side
		CountdownSeconds = 3, -- after both lock (spec)
		Cooldown = 5, -- seconds between trade requests from one player
		TownOnly = true, -- trades only start inside the town region (spec: "in town")
	},

	Company = {
		UnlockLevel = 20, -- spec
		CreateCost = 5000, -- gold
		NameMin = 3,
		NameMax = 20,
		MaxMembers = 30,
		Ranks = { "Leader", "Officer", "Member", "Recruit" }, -- highest first
		StorageSlots = 40,
		Emblems = 24, -- preset emblem icons (Shared UI icon set), chosen by index
		WeeklyQuests = 2, -- Company quests rolled each Monday
		CacheSeconds = 30, -- in-server cache of a Company record before re-reading
		DataStore = "SpireCompanies_v1",
		Topic = "SpireCompany", -- MessagingService topic for cross-server Company updates
	},

	Emotes = {
		Slots = 8, -- spec
		Cooldown = 1.5,
	},

	Inspect = {
		MaxDistance = 60,
		Cooldown = 1,
	},
})
