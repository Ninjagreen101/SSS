--!strict
--[[
	Profile template: the full PlayerData a brand-new Climber starts with.
	ProfileStore reconciles existing profiles against this, so adding a new
	field here gives every old profile the default automatically. Renaming or
	restructuring a field needs a migration (see Migrations).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Types = require(Shared.Types)
local TableUtil = require(Shared.Util.TableUtil)
local SettingsSchema = require(Shared.Data.SettingsSchema)

local template: Types.PlayerData = {
	DataVersion = Config.Data.DataVersion,

	Level = 1,
	XP = 0,
	StatPoints = 0,
	SkillPoints = 0,
	Stats = {
		Vitality = 0,
		Endurance = 0,
		Strength = 0,
		Finesse = 0,
		Draw = 0,
		Density = 0,
		Control = 0,
	},
	Position = "",
	SkillTree = {},
	Attunements = {
		Primary = "",
		Secondary = "",
		UnlockedForms = {},
	},
	RespecCount = 0,

	Inventory = {
		Items = {},
		NextUid = 1,
		Capacity = Config.Items.Inventory.BaseCapacity,
	},
	Bank = {
		Items = {},
		Capacity = Config.Items.Inventory.BaseBankCapacity,
	},
	Equipped = {
		Weapon = "",
		Head = "",
		Chest = "",
		Legs = "",
		Hands = "",
		Cloak = "",
		Ring1 = "",
		Ring2 = "",
		Amulet = "",
	},
	ItemState = {
		StarterGranted = false,
		Pity = {},
		Buyback = {},
		NextBuyback = 1,
		TrackedRecipe = "",
		SeenItems = {},
	},
	Hotbar = {
		Spells = { "", "", "", "" },
		WeaponArt = "",
		Consumables = { "", "" },
		Ability = "",
	},
	-- Beacon behaviour per slot ("" = empty); how many slots are usable
	-- depends on Control (Config.Current.Beacons).
	Beacons = {
		Slots = { "", "", "", "" },
		Skin = "",
	},

	Currencies = {
		Gold = Config.Economy.StartingGold,
		Shards = 0,
		FloorTokens = {},
	},
	LostCurrent = {
		Gold = 0,
		FloorId = "",
		Position = {},
	},

	Quests = {
		Active = {},
		Completed = {},
		Tracked = "",
		DailyResetAt = 0,
		WeeklyResetAt = 0,
		Dailies = {}, -- today's rolled daily quest ids (one per pool)
		Weeklies = {}, -- this week's rolled weekly quest ids
		Rerolls = 0, -- daily rerolls used today (back to 0 at the daily reset)
	},
	Floors = {
		Unlocked = { ["1"] = true },
		GuardiansCleared = {},
		IntrosSeen = {}, -- Guardian id -> true once its intro has played (skippable after)
		Current = "1",
	},
	Waystones = {
		Discovered = {},
		Last = "",
	},
	Discoveries = {},
	RecipesKnown = {},
	Achievements = {},
	AchievementProgress = {}, -- achievement id -> events counted so far (until unlocked)
	Title = "", -- achievement id whose title is shown ("" = none)
	Social = {
		CompanyId = "", -- Climber Company id ("" = none); the Company record lives in its own DataStore
		Emotes = {}, -- emote wheel slot ("1".."8") -> emote id
		LootMode = "Personal", -- preferred party loot setting when this player leads
		Blocked = {}, -- UserId (as string) -> true: no trade / party invites from them
	},
	Map = {
		Explored = {}, -- floor id -> fog-of-war bitset as hex (MapService)
		Pins = {}, -- floor id -> { { X, Z, Icon } }
	},

	Cosmetics = {
		Owned = {},
		Equipped = {},
		Outfits = {},
	},
	Purchases = {
		Receipts = {},
		Passes = {},
	},

	Character = {
		Created = false,
		Name = "",
		BodyType = 1,
		SkinTone = 1,
		Face = 1,
		Hair = 1,
		HairColor = 1,
		CloakColor = 1,
	},
	Settings = TableUtil.DeepCopy(SettingsSchema.Defaults),
	Tutorial = {
		Step = 0,
		Done = false, -- profiles from before v6 migrate to true (veterans never see the docks again)
		Skipped = false,
	},
	PlayStats = {
		FirstJoin = 0,
		LastJoin = 0,
		Sessions = 0,
		PlaySeconds = 0,
		Kills = 0,
		Deaths = 0,
		GuardianKills = 0,
		Parries = 0,
	},
}

return TableUtil.DeepFreeze(template)
