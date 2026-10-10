--!strict
-- Quests, achievements, map exploration and the tutorial (Phase 11, docs/PHASE11_QUESTS.md).

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

return TableUtil.DeepFreeze({
	MaxActive = 25, -- main + side quests in the log at once (dailies/weeklies don't count)
	TalkRadius = 14, -- studs from an NPC for Talk / Accept / TurnIn
	ReachCheckSeconds = 0.5, -- how often the server checks Reach objectives and regions
	DailyCount = 3, -- one per daily pool (Kill, Gather, Dungeon)
	WeeklyCount = 2,
	DailyRerolls = 1, -- free rerolls per day (VIP adds one in Phase 13)
	DailyResetHourUTC = 0, -- dailies roll at 00:00 UTC
	WeeklyResetWeekdayUTC = 2, -- os.date "!*t" wday: 1 = Sunday, 2 = Monday
	MarkerMaxDistance = 600, -- world markers beyond this are hidden (the tracker still shows distance)

	Map = {
		Cells = 48, -- exploration grid per side (48 x 48 over the floor)
		RevealRadius = 1, -- cells around the player's cell revealed too (a 3x3 block)
		CheckSeconds = 2,
		MinimapRadius = 160, -- studs shown from the centre to the edge of the minimap
		MaxPins = 12,
		PinRemoveRadius = 40, -- studs: Remove takes the nearest pin within this distance of the click
	},

	Npcs = {
		FaceRadius = 20, -- standing NPCs turn to face the nearest player within this many studs
		PromptDistance = 10, -- the Talk prompt's reach (inside TalkRadius, so a Talk always passes)
		WalkSpeed = 7, -- route walkers, studs/s
		ThinkSeconds = 0.25, -- how often NPCs choose where to look and walk
		TalkHoldSeconds = 20, -- an NPC someone talks to stops and faces them this long
		ReturnDistance = 3, -- a standing NPC pushed further than this from its spot walks back
		StuckSeconds = 8, -- a walker that makes no headway this long is placed at its next point
	},

	Tutorial = {
		Floor = "1",
		SkipAfterSeconds = 5, -- the Skip button appears after this long on the first prompt
		TutorMob = "DrownedSailor", -- teaches dodge and parry with slow, telegraphed swings
		CrabMob = "Bilgecrab", -- the first kill
		ParriesNeeded = 2,
		TutorTelegraphScale = 1.6, -- the tutor's wind-ups are this much slower than a real sailor's
		TutorDamageScale = 0.25,
		PreviewSpell = "Tide_Bolt", -- granted for the tutorial only (before any Attunement)
		NightClock = 22.5, -- the client's local clock during the tutorial
		HealthFloor = 0.5, -- the player is topped back up to this fraction of max health (never dies)
		TutorHealthFloor = 0.5, -- the tutor can't drop below this before step 8, and starts step 8 here
		PointRadius = 8, -- studs, for tutorial points without a Radius attribute
	},
})
