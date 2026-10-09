--!strict
-- World, building-kit, streaming and day/night tuning. Every world number that
-- matters for gameplay or performance lives here.

local World = {
	Kit = {
		Grid = 4,
		StoreyHeight = 12,
		WallThickness = 1,
		PanelWidths = { 8, 12, 16 },
		PitchRuns = { 6, 8, 10, 12, 14, 16 },
		RoofOverhang = 1.5,
		-- Templates are looked up here after the FBX kit is imported into Studio.
		TemplateFolderPath = { "Assets", "Kit" },
	},

	Buildings = {
		MinWidth = 12,
		MaxWidth = 32,
		MinDepth = 12,
		MaxDepth = 32,
		DefaultPlinth = 2,
		BeamSpacing = 12,
		StairCellWidth = 8,
		StairCellDepth = 12,
		DoorLightRange = 18,
		DoorLightBrightness = 1.4,
		InteriorLightRange = 16,
		InteriorLightBrightness = 1.1,
		UpperFloorFurnishChance = 0.4,
		WindowGlowChance = 0.55,
	},

	Districts = {
		SetbackMin = 1,
		SetbackMax = 3,
		RowHouseChance = 0.5,
		AlleyMin = 6,
		AlleyMax = 12,
		LampSpacing = 44,
		SecondaryWidth = 18,
		CrossSpacing = 120,
		StreetClearance = 1.5,
	},

	Canals = {
		WallSegment = 16,
		WaterTransparency = 0.28,
		WaterThickness = 2,
		HealPerSecond = 6, -- % of max health per second in town Current pools
	},

	Nature = {
		TreeSpacing = { Forest = 21, Marsh = 34, Crags = 46, Shore = 60 },
		CliffSlope = 1.15,
		MaxTrees = 1150,
	},

	Terrain = {
		VoxelResolution = 4,
		WriteChunk = 64, -- voxels per side per WriteVoxels call
		SeaFloor = -34,
		ShoreBlend = 70,
		PadBlend = 14,
		CanalBedOffset = 8,
	},

	Streaming = {
		Enabled = true,
		TargetRadius = 512,
		MinRadius = 160,
		MobileTargetRadius = 384,
	},

	InstanceBudgetPerFloor = 40000,

	DayNight = {
		CycleMinutes = 24,
		StartClockTime = 20.5, -- the tutorial begins on the docks at night
		NightStart = 19.0,
		NightEnd = 5.5,
		ReplicateInterval = 1.0,
	},

	Waystones = {
		DiscoverRadius = 22,
		InteractRadius = 14,
		FastTravelCooldown = 8,
		ArrivalOffset = 9,
		ScanInterval = 0.5,
	},

	Treasure = {
		InteractRadius = 10,
		HoldSeconds = 0.6,
	},

	Dungeon = {
		ClearReward = { Gold = 400, FloorTokens = 3 },
		ValveHoldSeconds = 1.5,
		EnterHoldSeconds = 1,
		GateLiftSeconds = 3,
		InstanceOrigin = { 9000, 0, 0 },
		InstanceSpacing = 900,
		MaxInstances = 12,
		GatherRadius = 18,
		GatherSeconds = 5,
		MaxPartySize = 6,
		EmptyCleanupSeconds = 30,
	},

	Zones = {
		CheckInterval = 0.5,
		BannerSeconds = 3.2,
	},

	Ambient = {
		WalkerCount = 16,
		WalkerSpeed = 6,
		WalkerRenderDistance = 260,
		GullCount = 10,
		FishPerCanal = 10,
		MerchantCallRadius = 36,
		MerchantCallInterval = { 14, 28 },
		RainRate = { Low = 0, Medium = 180, High = 360 },
	},
}

return World
