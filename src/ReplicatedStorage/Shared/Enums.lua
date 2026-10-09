--!strict
--[[
	Enums
	String-literal enums shared by client and server. Each enum is exported as a
	Luau type (for annotations) and as a frozen ordered list (for iteration,
	validation and UI ordering). Strings, not numbers, so saved data stays
	readable and survives reordering.
]]

export type Rarity = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic" | "SpireForged"
export type DamageType = "Physical" | "Tide" | "Rime" | "Tempest" | "Abyss" | "Bloom" | "True"
export type Attunement = "Tide" | "Rime" | "Tempest" | "Abyss" | "Bloom"
export type Form = "Bolt" | "Lance" | "Wave" | "Ward" | "Well" | "Step"
export type WeaponClass = "Longsword" | "Greatblade" | "Twinfangs" | "SpireLance" | "Needle" | "Arcblade"
export type Position = "Vanguard" | "Lancer" | "Tidecaller" | "Beaconkeeper" | "Pathfinder"
export type Stat = "Vitality" | "Endurance" | "Strength" | "Finesse" | "Draw" | "Density" | "Control"
export type EquipSlot = "Weapon" | "Head" | "Chest" | "Legs" | "Hands" | "Cloak" | "Ring1" | "Ring2" | "Amulet"
export type ItemType = "Weapon" | "Armor" | "Accessory" | "BeaconCore" | "Consumable" | "Material" | "Quest" | "Cosmetic"
export type CurrencyType = "Gold" | "Shards" | "FloorTokens"
export type MobState =
	"Idle"
	| "Patrol"
	| "Alert"
	| "Chase"
	| "Attack"
	| "Recover"
	| "Return"
	| "Dead"
	| "Staggered"
	| "Broken"
export type CharacterState =
	"Idle"
	| "Moving"
	| "Sprinting"
	| "Attacking"
	| "Casting"
	| "Dodging"
	| "Blocking"
	| "Staggered"
	| "Broken"
	| "Winded"
	| "Dead"
export type InputDevice = "KeyboardMouse" | "Touch" | "Gamepad"
export type InputContext = "Gameplay" | "Menu"
export type BindingDevice = "Keyboard" | "Gamepad"
export type Action =
	"Jump"
	| "LightAttack"
	| "HeavyAttack"
	| "Dodge"
	| "Block"
	| "LockOn"
	| "Sprint"
	| "Cast1"
	| "Cast2"
	| "Cast3"
	| "Cast4"
	| "WeaponArt"
	| "Interact"
	| "Consumable1"
	| "Consumable2"
	| "Ping"
	| "Emote"
	| "FreeCursor"
	| "OpenCharacter"
	| "OpenInventory"
	| "OpenSpellbook"
	| "OpenSkillTree"
	| "OpenQuestLog"
	| "OpenMap"
	| "OpenParty"
	| "OpenSettings"
	| "OpenMenuHub"
	| "CloseMenu"
	| "TabLeft"
	| "TabRight"
	| "NavPrev"
	| "NavNext"
	| "DevGallery"
export type GraphicsQuality = "Auto" | "Low" | "Medium" | "High"
export type EffectsQuality = "Low" | "Medium" | "High"
export type ColorblindMode = "Off" | "Protanopia" | "Deuteranopia" | "Tritanopia"
export type ShoulderSide = "Right" | "Left"
export type TouchButtonId =
	"Attack"
	| "Jump"
	| "Dodge"
	| "Block"
	| "Cast1"
	| "Cast2"
	| "Cast3"
	| "Cast4"
	| "WeaponArt"
	| "Ability"
	| "LockOn"
	| "Interact"
	| "Consumable1"
	| "Menu"

local Enums = {
	Rarity = table.freeze({ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "SpireForged" } :: { Rarity }),
	DamageType = table.freeze({ "Physical", "Tide", "Rime", "Tempest", "Abyss", "Bloom", "True" } :: { DamageType }),
	Attunement = table.freeze({ "Tide", "Rime", "Tempest", "Abyss", "Bloom" } :: { Attunement }),
	Form = table.freeze({ "Bolt", "Lance", "Wave", "Ward", "Well", "Step" } :: { Form }),
	WeaponClass = table.freeze(
		{ "Longsword", "Greatblade", "Twinfangs", "SpireLance", "Needle", "Arcblade" } :: { WeaponClass }
	),
	Position = table.freeze({ "Vanguard", "Lancer", "Tidecaller", "Beaconkeeper", "Pathfinder" } :: { Position }),
	Stat = table.freeze({ "Vitality", "Endurance", "Strength", "Finesse", "Draw", "Density", "Control" } :: { Stat }),
	EquipSlot = table.freeze(
		{ "Weapon", "Head", "Chest", "Legs", "Hands", "Cloak", "Ring1", "Ring2", "Amulet" } :: { EquipSlot }
	),
	ItemType = table.freeze(
		{ "Weapon", "Armor", "Accessory", "BeaconCore", "Consumable", "Material", "Quest", "Cosmetic" } :: { ItemType }
	),
	CurrencyType = table.freeze({ "Gold", "Shards", "FloorTokens" } :: { CurrencyType }),
	MobState = table.freeze({
		"Idle",
		"Patrol",
		"Alert",
		"Chase",
		"Attack",
		"Recover",
		"Return",
		"Dead",
		"Staggered",
		"Broken",
	} :: { MobState }),
	CharacterState = table.freeze({
		"Idle",
		"Moving",
		"Sprinting",
		"Attacking",
		"Casting",
		"Dodging",
		"Blocking",
		"Staggered",
		"Broken",
		"Winded",
		"Dead",
	} :: { CharacterState }),
	InputDevice = table.freeze({ "KeyboardMouse", "Touch", "Gamepad" } :: { InputDevice }),
	InputContext = table.freeze({ "Gameplay", "Menu" } :: { InputContext }),
	BindingDevice = table.freeze({ "Keyboard", "Gamepad" } :: { BindingDevice }),
	Action = table.freeze({
		"Jump",
		"LightAttack",
		"HeavyAttack",
		"Dodge",
		"Block",
		"LockOn",
		"Sprint",
		"Cast1",
		"Cast2",
		"Cast3",
		"Cast4",
		"WeaponArt",
		"Interact",
		"Consumable1",
		"Consumable2",
		"Ping",
		"Emote",
		"FreeCursor",
		"OpenCharacter",
		"OpenInventory",
		"OpenSpellbook",
		"OpenSkillTree",
		"OpenQuestLog",
		"OpenMap",
		"OpenParty",
		"OpenSettings",
		"OpenMenuHub",
		"CloseMenu",
		"TabLeft",
		"TabRight",
		"NavPrev",
		"NavNext",
		"DevGallery",
	} :: { Action }),
	GraphicsQuality = table.freeze({ "Auto", "Low", "Medium", "High" } :: { GraphicsQuality }),
	EffectsQuality = table.freeze({ "Low", "Medium", "High" } :: { EffectsQuality }),
	ColorblindMode = table.freeze({ "Off", "Protanopia", "Deuteranopia", "Tritanopia" } :: { ColorblindMode }),
	ShoulderSide = table.freeze({ "Right", "Left" } :: { ShoulderSide }),
	TouchButtonId = table.freeze({
		"Attack",
		"Jump",
		"Dodge",
		"Block",
		"Cast1",
		"Cast2",
		"Cast3",
		"Cast4",
		"WeaponArt",
		"Ability",
		"LockOn",
		"Interact",
		"Consumable1",
		"Menu",
	} :: { TouchButtonId }),
}

-- True if `value` is one of the members of an enum list.
function Enums.Has(list: { any }, value: any): boolean
	return type(value) == "string" and table.find(list, value) ~= nil
end

-- Position of a member in its list (rarity tiers compare by index).
function Enums.IndexOf(list: { any }, value: string): number
	return table.find(list, value) or 0
end

return table.freeze(Enums)
