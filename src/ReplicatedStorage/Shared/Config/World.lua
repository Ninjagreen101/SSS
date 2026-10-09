--!strict
-- World, streaming and environment tuning (Spec Sections 4 and 5).

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

return TableUtil.DeepFreeze({
	Scale = {
		CharacterHeight = 5.5,
		DoorHeight = 8,
		DoorWidth = 5,
		StoreyHeight = 13,
		GrandStoreyHeight = 32,
		KitGrid = 4,
	},

	DayNight = {
		CycleMinutes = 24, -- one full day every 24 real minutes
		NightStart = 18.5,
		NightEnd = 5.5,
	},

	Streaming = {
		TargetRadius = 512,
		MobileTargetRadius = 384,
		MinRadius = 128,
	},

	Waystones = {
		DiscoverRadius = 24,
		InteractDistance = 10,
		RestHoldDuration = 0.5,
		ScanInterval = 0.5,
		SpawnHeight = 4, -- studs above the Waystone's spawn point
		CrystalBob = 0.35, -- studs up/down (client-side animation)
		CrystalBobSpeed = 1.6, -- radians per second
		CrystalSpinDegreesPerSecond = 25,
		CrystalAnimateRange = 150, -- only animate crystals this close to the camera
	},

	LostCurrent = {
		OrbSize = 1.6,
		OrbHeight = 2, -- studs above the death position
		LightRange = 12,
		LightBrightness = 2,
		BobHeight = 0.4,
		BobSpeed = 2.2,
	},

	-- Practice dummies beside the first Waystone (Phase 3; real enemies arrive in Phase 4).
	Training = {
		MaxHealth = 400,
		MaxPosture = 100,
		RegenDelay = 4, -- seconds without being hit before a dummy heals fully
		ResetDelay = 0.8, -- a dummy knocked to 0 health stands back up after this
		Sparring = {
			Interval = 2.4, -- seconds between swings
			Telegraph = 0.55, -- red warning glow before each swing (>= Mobs.AI.MinTelegraph)
			AggroRange = 12,
			Reach = 8,
			Arc = 120,
			Damage = 14,
			Posture = 14,
		},
	},

	PlayerCollision = false, -- players pass through each other (busy towns, parties)

	Floors = {
		Count = 5,
		PlayableSize = 3000,
		InstanceBudget = 40000,
	},

	-- Floor maps (Map M and the minimap, Phase 11). Image: an uploaded top-down render of the floor
	-- (tools/place/render_map.luau writes assets/map/floor<N>_map.png); empty = the client draws the
	-- map from ReplicatedStorage.FloorData.Regions. Center/Size: the world square the image covers.
	Maps = {
		["1"] = { Image = "", Center = Vector2.new(0, 0), Size = 3000 },
	} :: { [string]: { Image: string, Center: Vector2, Size: number } },
})
