--!strict
--[[
	KeybindField
	Shows a binding ("Q", "LT + RT"); click it and press a key or button to
	rebind. The actual capture is supplied by the caller (InputController),
	which keeps this component independent of the input system.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Motion = require(UI.Motion)
local Animator = require(UI.Animator)
local UISound = require(UI.UISound)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)
local Promise = require(Shared.Util.Promise)
local Strings = require(Shared.Strings)

export type KeybindFieldProps = {
	Binding: string,
	-- Starts listening; resolves with the new binding, or nil if cancelled.
	Capture: () -> Promise.Promise<string?>,
	Size: UDim2?,
	Position: UDim2?,
	LayoutOrder: number?,
	Parent: Instance?,
}

export type KeybindField = {
	Instance: TextButton,
	Changed: Signal.Signal<string>,
	Maid: Maid.Maid,
	SetBinding: (self: KeybindField, binding: string) -> (),
	Destroy: (self: KeybindField) -> (),
}

local KeybindField = {}

function KeybindField.new(props: KeybindFieldProps): KeybindField
	local maid = Maid.new()
	local changed = Signal.new() :: Signal.Signal<string>
	maid:Add(changed)
	local binding = props.Binding
	local capturing = false

	local button: TextButton = Create.new("TextButton", {
		Name = "KeybindField",
		Text = Strings.KeyName(binding),
		FontFace = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.Body,
		TextColor3 = UITheme.Colors.Text,
		BackgroundColor3 = UITheme.Colors.PanelSunken,
		BackgroundTransparency = UITheme.SunkenTransparency,
		AutoButtonColor = false,
		Size = props.Size or UDim2.fromOffset(120, UITheme.Size.InputHeight),
		Position = props.Position or UDim2.new(),
		LayoutOrder = props.LayoutOrder or 0,
		SelectionImageObject = Create.SelectionImage(),
	})
	Create.Corner(button)
	local stroke = Create.Stroke(button)
	maid:Add(button)
	maid:Add(Motion.AttachButtonFeedback(button))

	local function stopCapturing()
		capturing = false
		maid:Set("pulse", nil)
		stroke.Color = UITheme.Stroke.Color
		stroke.Transparency = UITheme.Stroke.Transparency
		button.TextColor3 = UITheme.Colors.Text
		button.Text = Strings.KeyName(binding)
	end

	maid:Add(button.Activated:Connect(function()
		if capturing then
			return
		end
		capturing = true
		UISound.Play("UIClick")
		button.Text = Strings.UI.PressAKey
		button.TextColor3 = UITheme.Colors.Current
		stroke.Color = UITheme.Colors.Current
		maid:Set("pulse", Animator.Pulse(stroke, "Transparency", 0, 0.7, 0.8))
		props.Capture():andThen(function(result: string?)
			if not capturing then
				return nil
			end
			if result then
				binding = result
				UISound.Play("UIConfirm")
				changed:Fire(result)
			end
			stopCapturing()
			return nil
		end)
	end))

	local self = {
		Instance = button,
		Changed = changed,
		Maid = maid,
	}
	function self.SetBinding(_self: KeybindField, newBinding: string)
		binding = newBinding
		if not capturing then
			button.Text = Strings.KeyName(binding)
		end
	end
	function self.Destroy(_self: KeybindField)
		maid:Clean()
	end

	button.Parent = props.Parent
	return self :: KeybindField
end

return KeybindField
