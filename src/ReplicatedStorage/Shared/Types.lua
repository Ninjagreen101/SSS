--!strict
--[[
	Types
	Shared Luau types for saved data and cross-system payloads.
	PlayerData is the exact shape stored in ProfileStore (see
	ServerScriptService/Systems/DataService/Template). Saved tables only use
	string keys or dense arrays, never sparse number keys, so they serialize safely.
]]

local Enums = require(script.Parent.Enums)

export type Rarity = Enums.Rarity
export type Attunement = Enums.Attunement
export type Stat = Enums.Stat
export type EquipSlot = Enums.EquipSlot
export type Action = Enums.Action
export type BindingDevice = Enums.BindingDevice
export type TouchButtonId = Enums.TouchButtonId

-- One rolled affix on an item instance, e.g. { Id = "TideDamage", Value = 6 }.
export type Affix = {
	Id: string,
	Value: number,
}

-- A concrete item a player owns. `DefId` points at Shared/Data/Items.
export type ItemInstance = {
	Uid: string,
	DefId: string,
	Count: number,
	Rarity: Rarity,
	Upgrade: number,
	Durability: number,
	Affixes: { Affix },
	Locked: boolean,
	New: boolean,
	AcquiredAt: number,
	Unique: string?, -- unique named effect rolled on Legendary+ gear (Data/Affixes)
}

-- A sold item a shop keeps for buy-back (newest last).
export type BuybackEntry = {
	Id: string,
	Item: ItemInstance,
	Price: number,
}

-- Item bookkeeping that isn't an item: starter kit, pity, buy-back, tracking.
export type ItemState = {
	StarterGranted: boolean,
	Pity: { [string]: number }, -- zone -> kills since the last Rare+ gear drop
	Buyback: { BuybackEntry },
	NextBuyback: number,
	TrackedRecipe: string, -- "" = nothing pinned to the HUD
	SeenItems: { [string]: boolean }, -- item ids ever picked up (key-material discovery, "new" badges)
}

export type StatBlock = {
	Vitality: number,
	Endurance: number,
	Strength: number,
	Finesse: number,
	Draw: number,
	Density: number,
	Control: number,
}

-- Up to two bindings per device per action, stored as names:
-- KeyCode names ("Q"), mouse buttons ("MouseButton1"), or gamepad chords ("ButtonL2+ButtonR2").
export type ActionBinding = {
	Keyboard: { string },
	Gamepad: { string },
}

export type TouchButtonLayout = {
	X: number, -- 0..1 of screen width (anchor point = button centre)
	Y: number, -- 0..1 of screen height
	Scale: number,
}

export type Settings = {
	CameraShake: number,
	DamageNumbers: boolean,
	HudScale: number,
	MasterVolume: number,
	MusicVolume: number,
	SfxVolume: number,
	UiVolume: number,
	AmbientVolume: number,
	GraphicsQuality: Enums.GraphicsQuality,
	EffectsQuality: Enums.EffectsQuality,
	ColorblindMode: Enums.ColorblindMode,
	ReducedMotion: boolean,
	AimedCast: boolean,
	ShoulderSide: Enums.ShoulderSide,
	AutoSprint: boolean,
	CameraSensitivity: number,
	Keybinds: { [string]: ActionBinding }, -- only actions the player changed
	TouchLayout: { [string]: TouchButtonLayout }, -- only buttons the player moved
}

export type QuestState = {
	Stage: number,
	Progress: { [string]: number },
	StartedAt: number,
}

export type PlayerData = {
	DataVersion: number,

	-- Progression
	Level: number,
	XP: number,
	StatPoints: number,
	SkillPoints: number,
	Stats: StatBlock,
	Position: string, -- "" until chosen at level 15
	SkillTree: { [string]: boolean }, -- unlocked node ids
	Attunements: {
		Primary: string, -- "" until the Attunement Trial
		Secondary: string,
		UnlockedForms: { string },
	},
	RespecCount: number,

	-- Items
	Inventory: {
		Items: { [string]: ItemInstance }, -- keyed by Uid
		NextUid: number,
		Capacity: number,
	},
	Bank: {
		Items: { [string]: ItemInstance },
		Capacity: number,
	},
	Equipped: { [string]: string }, -- EquipSlot -> item Uid ("" = empty)
	ItemState: ItemState,
	Hotbar: {
		Spells: { string }, -- 4 spell ids ("" = empty)
		WeaponArt: string,
		Consumables: { string }, -- 2 item def ids
		Ability: string, -- Position ability on the ability key ("" = none)
	},
	Beacons: {
		Slots: { string }, -- behaviour id per slot
		Skin: string,
	},

	-- Economy
	Currencies: {
		Gold: number,
		Shards: number,
		FloorTokens: { [string]: number }, -- floor id -> tokens
	},
	LostCurrent: {
		Gold: number,
		FloorId: string,
		Position: { number }, -- {x, y, z}; empty when none
	},

	-- World
	Quests: {
		Active: { [string]: QuestState },
		Completed: { [string]: number }, -- quest id -> completion unix time
		Tracked: string,
		DailyResetAt: number,
		WeeklyResetAt: number,
	},
	Floors: {
		Unlocked: { [string]: boolean }, -- "1", "2" ...
		GuardiansCleared: { [string]: number },
		Current: string,
	},
	Waystones: {
		Discovered: { [string]: boolean },
		Last: string,
	},
	Discoveries: { [string]: boolean },
	RecipesKnown: { [string]: boolean },
	Achievements: { [string]: number },
	Title: string,

	-- Cosmetics & monetization
	Cosmetics: {
		Owned: { [string]: boolean },
		Equipped: { [string]: string },
		Outfits: { { [string]: string } },
	},
	Purchases: {
		Receipts: { [string]: number }, -- PurchaseId -> unix time (idempotent grants)
		Passes: { [string]: boolean },
	},

	-- Player
	Character: {
		Created: boolean,
		Name: string,
		BodyType: number,
		SkinTone: number,
		Face: number,
		Hair: number,
		HairColor: number,
		CloakColor: number,
	},
	Settings: Settings,
	Tutorial: { [string]: boolean },
	PlayStats: {
		FirstJoin: number,
		LastJoin: number,
		Sessions: number,
		PlaySeconds: number,
		Kills: number,
		Deaths: number,
		GuardianKills: number,
		Parries: number,
	},
}

-- Payload the server sends for one changed value in the client replica.
export type DataChange = {
	Path: { string },
	Value: any,
}

-- Types are compile-time only; the module returns an empty frozen table.
return table.freeze({})
