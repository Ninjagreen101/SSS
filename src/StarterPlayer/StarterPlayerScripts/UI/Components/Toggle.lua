--!strict
-- Toggle: pill switch that slides its knob and glows teal when on.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Motion = require(UI.Motion)
local UISound = require(UI.UISound)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)
local TweenUtil = require(Shared.Util.TweenUtil)

export type ToggleProps = {
	Value: boolean,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	LayoutOrder: number?,
	Parent: Instance?,
}

export type Toggle = {
	Instance: TextButton,
	Changed: Signal.Signal<boolean>,
	Maid: Maid.Maid,
	GetValue: (self: Toggle) -> boolean,
	SetValue: (self: Toggle, value: boolean, silent: boolean?) -> (),
	Destroy: (self: Toggle) -> (),
}

local WIDTH = 52
local HEIGHT = 28
local KNOB = 22

local Toggle = {}

function Toggle.new(props: ToggleProps): Toggle
	local maid = Maid.new()
	local changed = Signal.new() :: Signal.Signal<boolean>
	maid:Add(changed)
	local value = props.Value

	local button: TextButton = Create.new("TextButton", {
		Name = "Toggle",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = UITheme.Colors.PanelSunken,
		Size = UDim2.fromOffset(WIDTH, HEIGHT),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		SelectionImageObject = Create.SelectionImage(),
	})
	Create.Corner(button, UITheme.CornerPill)
	local stroke = Create.Stroke(button)
	maid:Add(button)
	maid:Add(Motion.AttachButtonFeedback(button))

	local knob: Frame = Create.new("Frame", {
		Name = "Knob",
		BackgroundColor3 = UITheme.Colors.TextMuted,
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(KNOB, KNOB),
		Parent = button,
	})
	Create.Corner(knob, UITheme.CornerPill)

	local function render(animate: boolean)
		local x = if value then WIDTH - KNOB - 3 else 3
		local props2 = {
			Position = UDim2.new(0, x, 0.5, 0),
			BackgroundColor3 = if value then UITheme.Colors.Text else UITheme.Colors.TextMuted,
		}
		local bg = if value then UITheme.Colors.Current else UITheme.Colors.PanelSunken
		stroke.Color = if value then UITheme.Colors.Current else UITheme.Stroke.Color
		if animate then
			TweenUtil.Play(knob, UITheme.Motion.OpenTime, props2, Enum.EasingStyle.Back)
			TweenUtil.Play(button, UITheme.Motion.OpenTime, { BackgroundColor3 = bg })
		else
			knob.Position = props2.Position
			knob.BackgroundColor3 = props2.BackgroundColor3
			button.BackgroundColor3 = bg
		end
	end

	local self = {
		Instance = button,
		Changed = changed,
		Maid = maid,
	}
	function self.GetValue(_self: Toggle): boolean
		return value
	end
	function self.SetValue(_self: Toggle, newValue: boolean, silent: boolean?)
		if newValue == value then
			return
		end
		value = newValue
		render(true)
		if not silent then
			changed:Fire(value)
		end
	end
	function self.Destroy(_self: Toggle)
		maid:Clean()
	end

	maid:Add(button.Activated:Connect(function()
		UISound.Play("UIClick")
		self.SetValue(self :: any, not value)
	end))

	render(false)
	button.Parent = props.Parent
	return self :: Toggle
end

return Toggle
