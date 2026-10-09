--!strict
-- SettingsController: client graphics settings the world systems read.
-- Picks a sensible EffectsQuality per device (lower on phones) and exposes a
-- Changed signal; the full Settings menu writes through Set().

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)

export type Quality = "Low" | "Medium" | "High"

local SettingsController = {
	Changed = Signal.new() :: Signal.Signal<string, any>,
}

local values: { [string]: any } = {
	EffectsQuality = "High",
	ReducedMotion = false,
	AmbientLife = true,
}

local function isPhone(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and not UserInputService.GamepadEnabled
end

function SettingsController.Get(key: string): any
	return values[key]
end

function SettingsController.Quality(): Quality
	return values.EffectsQuality :: Quality
end

-- 0..1 multiplier for particle rates and ambient counts
function SettingsController.QualityScale(): number
	local q = values.EffectsQuality
	return if q == "Low" then 0.35 elseif q == "Medium" then 0.65 else 1
end

function SettingsController.Set(key: string, value: any)
	if values[key] == value then
		return
	end
	values[key] = value
	SettingsController.Changed:Fire(key, value)
end

function SettingsController.Init()
	if isPhone() then
		values.EffectsQuality = "Medium"
	end
end

function SettingsController.Start() end

return SettingsController
