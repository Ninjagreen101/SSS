--!strict
--[[
	Device
	Which input device the player is using right now (KeyboardMouse, Touch or
	Gamepad), from UserInputService.PreferredInput with a last-input fallback.
	UI swaps button prompts, layouts and selection behaviour on Changed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local Signal = require(Shared.Util.Signal)

export type InputDevice = Enums.InputDevice

local Device = {}

Device.Changed = Signal.new() :: Signal.Signal<InputDevice>

local current: InputDevice = "KeyboardMouse"
local started = false

local function fromPreferred(): InputDevice?
	local ok, preferred = pcall(function(): EnumItem
		return UserInputService.PreferredInput
	end)
	if not ok then
		return nil
	end
	if preferred == Enum.PreferredInput.Touch then
		return "Touch"
	elseif preferred == Enum.PreferredInput.Gamepad or preferred == Enum.PreferredInput.MicroGamepad then
		return "Gamepad"
	end
	return "KeyboardMouse"
end

local function fromInputType(inputType: Enum.UserInputType): InputDevice?
	if inputType == Enum.UserInputType.Touch then
		return "Touch"
	elseif string.sub(inputType.Name, 1, 7) == "Gamepad" then
		return "Gamepad"
	elseif
		inputType == Enum.UserInputType.Keyboard
		or inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseButton2
		or inputType == Enum.UserInputType.MouseMovement
		or inputType == Enum.UserInputType.MouseWheel
	then
		return "KeyboardMouse"
	end
	return nil
end

local function set(device: InputDevice?)
	if device and device ~= current then
		current = device
		Device.Changed:Fire(device)
	end
end

function Device.Current(): InputDevice
	Device.Start()
	return current
end

function Device.IsGamepad(): boolean
	return Device.Current() == "Gamepad"
end

function Device.IsTouch(): boolean
	return Device.Current() == "Touch"
end

-- Idempotent; called lazily by the first reader.
function Device.Start()
	if started then
		return
	end
	started = true
	current = fromPreferred() or fromInputType(UserInputService:GetLastInputType()) or "KeyboardMouse"
	local ok = pcall(function()
		UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(function()
			set(fromPreferred())
		end)
	end)
	if not ok then
		UserInputService.LastInputTypeChanged:Connect(function(inputType: Enum.UserInputType)
			set(fromInputType(inputType))
		end)
	end
end

return Device
