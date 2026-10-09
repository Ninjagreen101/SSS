--!strict
--[[
	Input defaults (Spec Section 7 control table, Section 12 mobile layout).
	Keyboard bindings are Enum.KeyCode names or mouse button names
	(MouseButton1/2/3). Gamepad bindings are KeyCode names; "A+B" is a chord
	where A must be held when B is pressed.
	Players override these in Settings; overrides are saved in their profile.
]]

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

export type ActionInfo = {
	Contexts: { string }, -- "Gameplay" and/or "Menu"
	Rebindable: boolean,
	Category: string, -- groups the keybind list in Settings
	Keyboard: { string },
	Gamepad: { string },
}

export type TouchButtonInfo = {
	Id: string,
	TapAction: string,
	HoldAction: string?, -- when set, holding past HoldThreshold fires this instead
	Corner: string, -- "BottomRight" | "TopRight"
	Offset: Vector2, -- centre of the button, in px from the corner
	Size: number, -- px, before player Scale
	Glow: boolean,
}

local BOTH = { "Gameplay", "Menu" }
local GAMEPLAY = { "Gameplay" }
local MENU = { "Menu" }

local actions: { [string]: ActionInfo } = {
	-- Movement (Jump keys are Roblox's own Space / A; this action is the touch button)
	Jump = { Contexts = GAMEPLAY, Rebindable = false, Category = "Movement", Keyboard = {}, Gamepad = {} },

	-- Combat
	LightAttack = { Contexts = GAMEPLAY, Rebindable = true, Category = "Combat", Keyboard = { "MouseButton1" }, Gamepad = { "ButtonR1" } },
	HeavyAttack = { Contexts = GAMEPLAY, Rebindable = true, Category = "Combat", Keyboard = { "MouseButton2" }, Gamepad = { "ButtonR2" } },
	Dodge = { Contexts = GAMEPLAY, Rebindable = true, Category = "Combat", Keyboard = { "Q" }, Gamepad = { "ButtonB" } },
	Block = { Contexts = GAMEPLAY, Rebindable = true, Category = "Combat", Keyboard = { "F" }, Gamepad = { "ButtonL1" } },
	LockOn = { Contexts = GAMEPLAY, Rebindable = true, Category = "Combat", Keyboard = { "MouseButton3", "V" }, Gamepad = { "ButtonR3" } },
	Sprint = { Contexts = GAMEPLAY, Rebindable = true, Category = "Movement", Keyboard = { "LeftShift" }, Gamepad = { "ButtonL3" } },
	WeaponArt = { Contexts = GAMEPLAY, Rebindable = true, Category = "Combat", Keyboard = { "R" }, Gamepad = { "ButtonL2+ButtonR2" } },
	-- Position ability (Phase 8): LT + RB mirrors the Weapon Art's LT + RT.
	Ability = { Contexts = GAMEPLAY, Rebindable = true, Category = "Combat", Keyboard = { "B" }, Gamepad = { "ButtonL2+ButtonR1" } },

	-- Magic
	Cast1 = { Contexts = GAMEPLAY, Rebindable = true, Category = "Magic", Keyboard = { "One" }, Gamepad = { "DPadUp" } },
	Cast2 = { Contexts = GAMEPLAY, Rebindable = true, Category = "Magic", Keyboard = { "Two" }, Gamepad = { "DPadRight" } },
	Cast3 = { Contexts = GAMEPLAY, Rebindable = true, Category = "Magic", Keyboard = { "Three" }, Gamepad = { "DPadDown" } },
	Cast4 = { Contexts = GAMEPLAY, Rebindable = true, Category = "Magic", Keyboard = { "Four" }, Gamepad = { "DPadLeft" } },

	-- Utility
	Interact = { Contexts = GAMEPLAY, Rebindable = true, Category = "Utility", Keyboard = { "E" }, Gamepad = { "ButtonX" } },
	Consumable1 = { Contexts = GAMEPLAY, Rebindable = true, Category = "Utility", Keyboard = { "Z" }, Gamepad = { "ButtonY" } },
	Consumable2 = { Contexts = GAMEPLAY, Rebindable = true, Category = "Utility", Keyboard = { "X" }, Gamepad = {} },
	Ping = { Contexts = GAMEPLAY, Rebindable = true, Category = "Utility", Keyboard = { "G" }, Gamepad = {} },
	Emote = { Contexts = GAMEPLAY, Rebindable = true, Category = "Utility", Keyboard = { "T" }, Gamepad = {} },
	FreeCursor = { Contexts = GAMEPLAY, Rebindable = true, Category = "Utility", Keyboard = { "LeftAlt" }, Gamepad = {} },

	-- Menus (work in both contexts so the same key toggles a menu closed)
	-- TAB toggles the Character window (Roblox's own player list, which also
	-- uses Tab, is turned off by UIController).
	OpenCharacter = { Contexts = BOTH, Rebindable = true, Category = "Menus", Keyboard = { "Tab" }, Gamepad = {} },
	OpenInventory = { Contexts = BOTH, Rebindable = true, Category = "Menus", Keyboard = { "I" }, Gamepad = {} },
	OpenSpellbook = { Contexts = BOTH, Rebindable = true, Category = "Menus", Keyboard = { "K" }, Gamepad = {} },
	OpenSkillTree = { Contexts = BOTH, Rebindable = true, Category = "Menus", Keyboard = { "N" }, Gamepad = {} },
	OpenQuestLog = { Contexts = BOTH, Rebindable = true, Category = "Menus", Keyboard = { "J" }, Gamepad = {} },
	OpenMap = { Contexts = BOTH, Rebindable = true, Category = "Menus", Keyboard = { "M" }, Gamepad = {} },
	OpenParty = { Contexts = BOTH, Rebindable = true, Category = "Menus", Keyboard = { "P" }, Gamepad = {} },
	OpenSettings = { Contexts = BOTH, Rebindable = true, Category = "Menus", Keyboard = { "O" }, Gamepad = {} },
	OpenMenuHub = { Contexts = BOTH, Rebindable = false, Category = "Menus", Keyboard = {}, Gamepad = { "ButtonSelect" } },
	CloseMenu = { Contexts = MENU, Rebindable = false, Category = "Menus", Keyboard = { "Backspace" }, Gamepad = { "ButtonB" } },
	TabLeft = { Contexts = MENU, Rebindable = false, Category = "Menus", Keyboard = { "Q" }, Gamepad = { "ButtonL1" } },
	TabRight = { Contexts = MENU, Rebindable = false, Category = "Menus", Keyboard = { "E" }, Gamepad = { "ButtonR1" } },
	-- Gamepad: LT / RT step through the Character window's top tabs
	-- (Character, Inventory, Spellbook, Skill Tree); LB / RB stay for a page's own tabs.
	NavPrev = { Contexts = MENU, Rebindable = false, Category = "Menus", Keyboard = {}, Gamepad = { "ButtonL2" } },
	NavNext = { Contexts = MENU, Rebindable = false, Category = "Menus", Keyboard = {}, Gamepad = { "ButtonR2" } },

	-- Studio-only developer tools (ignored in live servers)
	DevGallery = { Contexts = BOTH, Rebindable = false, Category = "Developer", Keyboard = { "F8" }, Gamepad = {} },
}

local touchButtons: { TouchButtonInfo } = {
	-- Big attack button in the corner; spells on an arc around it (radius 125, 36 degrees apart).
	{ Id = "Attack", TapAction = "LightAttack", HoldAction = "HeavyAttack", Corner = "BottomRight", Offset = Vector2.new(-110, -110), Size = 104, Glow = false },
	{ Id = "Cast1", TapAction = "Cast1", Corner = "BottomRight", Offset = Vector2.new(-121, -235), Size = 60, Glow = false },
	{ Id = "Cast2", TapAction = "Cast2", Corner = "BottomRight", Offset = Vector2.new(-192, -204), Size = 60, Glow = false },
	{ Id = "Cast3", TapAction = "Cast3", Corner = "BottomRight", Offset = Vector2.new(-232, -138), Size = 60, Glow = false },
	{ Id = "Cast4", TapAction = "Cast4", Corner = "BottomRight", Offset = Vector2.new(-225, -61), Size = 60, Glow = false },
	{ Id = "WeaponArt", TapAction = "WeaponArt", Corner = "BottomRight", Offset = Vector2.new(-47, -218), Size = 64, Glow = true },
	-- Shown only while a Position ability is on the key.
	{ Id = "Ability", TapAction = "Ability", Corner = "BottomRight", Offset = Vector2.new(-58, -300), Size = 56, Glow = true },
	{ Id = "LockOn", TapAction = "LockOn", Corner = "BottomRight", Offset = Vector2.new(-36, -36), Size = 48, Glow = false },
	-- Movement / defence column left of the arc.
	{ Id = "Jump", TapAction = "Jump", Corner = "BottomRight", Offset = Vector2.new(-305, -55), Size = 66, Glow = false },
	{ Id = "Dodge", TapAction = "Dodge", Corner = "BottomRight", Offset = Vector2.new(-305, -140), Size = 70, Glow = false },
	{ Id = "Block", TapAction = "Block", Corner = "BottomRight", Offset = Vector2.new(-305, -225), Size = 64, Glow = false },
	{ Id = "Interact", TapAction = "Interact", Corner = "BottomRight", Offset = Vector2.new(-392, -120), Size = 56, Glow = false },
	{ Id = "Consumable1", TapAction = "Consumable1", Corner = "BottomRight", Offset = Vector2.new(-392, -200), Size = 48, Glow = false },
	{ Id = "Menu", TapAction = "OpenMenuHub", Corner = "TopRight", Offset = Vector2.new(-36, 210), Size = 48, Glow = false },
}

return TableUtil.DeepFreeze({
	HoldThreshold = 0.25, -- touch attack: held longer than this = heavy attack
	ChordCaptureWindow = 0.3, -- when rebinding, a second button within this window makes a chord
	CaptureTimeout = 8,
	TouchToastOffset = 330, -- toast feed sits above the touch cluster
	AutoSprintThreshold = 0.9, -- mobile: joystick pushed this far = sprint (when Auto Sprint is on)
	SprintToggleStopDelay = 0.5, -- gamepad toggle-sprint ends after standing still this long
	SprintSendInterval = 0.2, -- min seconds between RequestSprint updates (rate limit is 4/s)
	MoveDeadzone = 0.1, -- move-vector length below this counts as standing still
	MinTouchTarget = 44,
	TouchScaleMin = 0.6,
	TouchScaleMax = 1.6,
	MaxBindingsPerDevice = 2,
	Actions = actions,
	TouchButtons = touchButtons,
	-- Keys that may never be bound (reserved by Roblox or chat).
	ReservedKeys = { "Escape", "Slash", "Unknown", "Menu", "Print" },
})
