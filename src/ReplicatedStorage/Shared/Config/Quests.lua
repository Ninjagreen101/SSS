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
	},
})
