--!strict
-- Dungeons: instanced areas a group enters together (DungeonService).

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

export type DungeonDef = {
	Template: string, -- ServerStorage.Dungeons.<Template>
	MinLevel: number,
	MaxPlayers: number,
	GatherSeconds: number, -- after the first player steps in, others have this long to join
	ExitWaystone: string, -- where the exit portals return you
	Reward: { Items: string, Gold: number }, -- the altar chest, once per player per run
	DailyBonus: { Items: string }, -- first clear of the day adds this
}

return TableUtil.DeepFreeze({
	-- Instances are laid out far beyond the Spire's wall (never visible from the floor).
	Origin = Vector3.new(0, -300, 5200),
	SlotSpacing = 700,
	MaxInstances = 12,
	CloseAfterEmpty = 30, -- seconds an instance stays open with nobody inside
	DoorRadius = 9, -- how close to a dungeon door counts as stepping in
	ScanInterval = 0.4,

	Dungeons = {
		SunkenCistern = {
			Template = "SunkenCistern",
			MinLevel = 5,
			MaxPlayers = 4,
			GatherSeconds = 8,
			ExitWaystone = "F1_CisternMouth",
			Reward = { Items = "IronScrap x6, BrineShell x3, TidePearl x1", Gold = 90 },
			DailyBonus = { Items = "SpireIngot x1" },
		},
	} :: { [string]: DungeonDef },
})
