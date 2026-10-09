--!strict
--[[
	SettingsSchema
	Default values and validators for every player setting. The server uses
	the validators to accept RequestSaveSetting(key, value); the client uses
	the defaults for "Reset" buttons and to build the Settings menu.
]]

local Shared = script.Parent.Parent
local Config = require(Shared.Config)
local Enums = require(Shared.Enums)
local Schema = require(Shared.Util.Schema)
local Types = require(Shared.Types)

local S = Schema

local Defaults: Types.Settings = {
	CameraShake = 1,
	DamageNumbers = true,
	HudScale = 1,
	MasterVolume = 0.8,
	MusicVolume = 0.6,
	SfxVolume = 0.9,
	UiVolume = 0.7,
	AmbientVolume = 0.7,
	GraphicsQuality = "Auto",
	EffectsQuality = "High",
	ColorblindMode = "Off",
	ReducedMotion = false,
	AimedCast = false,
	ShoulderSide = "Right",
	AutoSprint = true,
	CameraSensitivity = 1,
	Keybinds = {},
	TouchLayout = {},
}

local MOUSE_BUTTONS = { MouseButton1 = true, MouseButton2 = true, MouseButton3 = true }

local reserved: { [string]: boolean } = {}
for _, key in Config.Input.ReservedKeys do
	reserved[key] = true
end

local function isGamepadKey(name: string): boolean
	return string.sub(name, 1, 6) == "Button" or string.sub(name, 1, 4) == "DPad" or string.sub(name, 1, 10) == "Thumbstick"
end

local function isKeyCodeName(name: string): boolean
	return Enum.KeyCode:FromName(name) ~= nil
end

-- A single keyboard/mouse binding: one KeyCode name or a mouse button, no chords.
local function keyboardBinding(value: any): (boolean, string?)
	if type(value) ~= "string" or #value == 0 or #value > 32 then
		return false, "expected binding string"
	end
	if reserved[value] then
		return false, "reserved key"
	end
	if MOUSE_BUTTONS[value] then
		return true
	end
	if not isKeyCodeName(value) or isGamepadKey(value) then
		return false, "not a keyboard key"
	end
	return true
end

-- A gamepad binding: a button name, or "Modifier+Button" chord.
local function gamepadBinding(value: any): (boolean, string?)
	if type(value) ~= "string" or #value == 0 or #value > 48 then
		return false, "expected binding string"
	end
	local parts = string.split(value, "+")
	if #parts > 2 then
		return false, "chord too long"
	end
	for _, part in parts do
		if not isKeyCodeName(part) or not isGamepadKey(part) then
			return false, "not a gamepad button"
		end
	end
	if #parts == 2 and parts[1] == parts[2] then
		return false, "chord repeats a button"
	end
	return true
end

local rebindable: { string } = {}
for name, info in Config.Input.Actions do
	if info.Rebindable then
		table.insert(rebindable, name)
	end
end
table.sort(rebindable)

local MAX = Config.Input.MaxBindingsPerDevice

local Validators: { [string]: Schema.Validator } = {
	CameraShake = S.Number(0, 1),
	DamageNumbers = S.Boolean(),
	HudScale = S.Number(0.75, 1.25),
	MasterVolume = S.Number(0, 1),
	MusicVolume = S.Number(0, 1),
	SfxVolume = S.Number(0, 1),
	UiVolume = S.Number(0, 1),
	AmbientVolume = S.Number(0, 1),
	GraphicsQuality = S.OneOf(Enums.GraphicsQuality),
	EffectsQuality = S.OneOf(Enums.EffectsQuality),
	ColorblindMode = S.OneOf(Enums.ColorblindMode),
	ReducedMotion = S.Boolean(),
	AimedCast = S.Boolean(),
	ShoulderSide = S.OneOf(Enums.ShoulderSide),
	AutoSprint = S.Boolean(),
	CameraSensitivity = S.Number(0.2, 3),
	Keybinds = S.MapOf(
		S.OneOf(rebindable),
		S.Shape({
			Keyboard = S.ArrayOf(keyboardBinding, MAX),
			Gamepad = S.ArrayOf(gamepadBinding, MAX),
		}),
		#rebindable
	),
	TouchLayout = S.MapOf(
		S.OneOf(Enums.TouchButtonId),
		S.Shape({
			X = S.Number(0, 1),
			Y = S.Number(0, 1),
			Scale = S.Number(Config.Input.TouchScaleMin, Config.Input.TouchScaleMax),
		}),
		#Enums.TouchButtonId
	),
}

local SettingsSchema = {
	Defaults = Defaults,
	Validators = Validators,
	RebindableActions = rebindable,
	ValidateKeyboardBinding = keyboardBinding,
	ValidateGamepadBinding = gamepadBinding,
	IsGamepadKey = isGamepadKey,
}

return table.freeze(SettingsSchema)
