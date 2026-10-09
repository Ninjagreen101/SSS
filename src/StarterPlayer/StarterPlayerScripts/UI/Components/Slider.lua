--!strict
--[[
	Slider
	Drag with mouse or touch; when selected with a gamepad (or focused with
	the keyboard arrows), D-pad / arrow keys step the value. Changed fires
	live while dragging; Committed fires once on release (use it for saving).
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)
local MathUtil = require(Shared.Util.MathUtil)

export type SliderProps = {
	Min: number,
	Max: number,
	Value: number,
	Step: number?,
	Format: ((number) -> string)?,
	Size: UDim2?,
	Position: UDim2?,
	LayoutOrder: number?,
	Parent: Instance?,
}

export type Slider = {
	Instance: Frame,
	Changed: Signal.Signal<number>,
	Committed: Signal.Signal<number>,
	Maid: Maid.Maid,
	GetValue: (self: Slider) -> number,
	SetValue: (self: Slider, value: number, silent: boolean?) -> (),
	Destroy: (self: Slider) -> (),
}

local KNOB = 18
local VALUE_WIDTH = 52

local Slider = {}

-- 0..1 sliders read as percentages; anything else as a rounded number.
local function percentFormat(value: number): string
	return string.format("%d%%", math.floor(value * 100 + 0.5))
end

local function numberFormat(value: number): string
	if math.abs(value - math.floor(value)) < 1e-6 then
		return tostring(math.floor(value))
	end
	return string.format("%.2f", value)
end

function Slider.new(props: SliderProps): Slider
	assert(props.Max > props.Min, "Slider Max must exceed Min")
	local maid = Maid.new()
	local changed = Signal.new() :: Signal.Signal<number>
	local committed = Signal.new() :: Signal.Signal<number>
	maid:Add(changed)
	maid:Add(committed)
	local step = props.Step
	local format: (number) -> string = props.Format or (if props.Min >= 0 and props.Max <= 1 then percentFormat else numberFormat)
	local value = props.Value
	local dragging = false

	local frame: Frame = Create.new("Frame", {
		Name = "Slider",
		BackgroundTransparency = 1,
		Size = props.Size or UDim2.fromOffset(240, 28),
		Position = props.Position or UDim2.new(),
		LayoutOrder = props.LayoutOrder or 0,
	})
	maid:Add(frame)

	-- Hit area doubles as the selectable object for gamepad.
	local hit: TextButton = Create.new("TextButton", {
		Name = "Hit",
		Text = "",
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Size = UDim2.new(1, -VALUE_WIDTH - 8, 1, 0),
		SelectionImageObject = Create.SelectionImage(),
		Parent = frame,
	})
	-- Keep gamepad selection on the slider while D-pad left/right adjusts it.
	hit.NextSelectionLeft = hit
	hit.NextSelectionRight = hit

	local track: Frame = Create.new("Frame", {
		Name = "Track",
		BackgroundColor3 = UITheme.Colors.Track,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, KNOB / 2, 0.5, 0),
		Size = UDim2.new(1, -KNOB, 0, 6),
		Parent = hit,
	})
	Create.Corner(track, UITheme.CornerPill)
	Create.Stroke(track, UITheme.Colors.Edge, 1, 0.75)

	local fill: Frame = Create.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = UITheme.Colors.Current,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		Parent = track,
	})
	Create.Corner(fill, UITheme.CornerPill)

	local knob: Frame = Create.new("Frame", {
		Name = "Knob",
		BackgroundColor3 = UITheme.Colors.Text,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(KNOB, KNOB),
		ZIndex = 2,
		Parent = track,
	})
	Create.Corner(knob, UITheme.CornerPill)
	local knobStroke = Create.Stroke(knob, UITheme.Colors.Current, 2, 0.2)

	local valueLabel: TextLabel = Create.Label({
		Name = "Value",
		Text = "",
		Font = UITheme.Fonts.Numbers,
		TextSize = UITheme.TextSize.Small,
		Color = UITheme.Colors.TextMuted,
		XAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, VALUE_WIDTH, 1, 0),
		Parent = frame,
	})

	local function normalize(raw: number): number
		local v = math.clamp(raw, props.Min, props.Max)
		if step then
			v = props.Min + MathUtil.Round(v - props.Min, step)
			v = math.clamp(v, props.Min, props.Max)
		end
		return v
	end

	local function render()
		local alpha = (value - props.Min) / (props.Max - props.Min)
		fill.Size = UDim2.fromScale(alpha, 1)
		knob.Position = UDim2.fromScale(alpha, 0.5)
		valueLabel.Text = format(value)
	end

	local function setFromScreenX(x: number)
		local left = track.AbsolutePosition.X
		local width = math.max(1, track.AbsoluteSize.X)
		local alpha = math.clamp((x - left) / width, 0, 1)
		local newValue = normalize(props.Min + alpha * (props.Max - props.Min))
		if newValue ~= value then
			value = newValue
			render()
			changed:Fire(value)
		end
	end

	local function stepBy(direction: number)
		local amount = step or (props.Max - props.Min) * 0.05
		local newValue = normalize(value + amount * direction)
		if newValue ~= value then
			value = newValue
			render()
			changed:Fire(value)
			committed:Fire(value)
		end
	end

	maid:Add(hit.InputBegan:Connect(function(input: InputObject)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			dragging = true
			knobStroke.Transparency = 0
			setFromScreenX(input.Position.X)
		end
	end))
	maid:Add(UserInputService.InputChanged:Connect(function(input: InputObject)
		if not dragging then
			return
		end
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
			setFromScreenX(input.Position.X)
		end
	end))
	maid:Add(UserInputService.InputEnded:Connect(function(input: InputObject)
		local t = input.UserInputType
		if dragging and (t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch) then
			dragging = false
			knobStroke.Transparency = 0.2
			committed:Fire(value)
		end
	end))
	maid:Add(UserInputService.InputBegan:Connect(function(input: InputObject)
		if GuiService.SelectedObject ~= hit then
			return
		end
		local key = input.KeyCode
		if key == Enum.KeyCode.DPadLeft or key == Enum.KeyCode.Left then
			stepBy(-1)
		elseif key == Enum.KeyCode.DPadRight or key == Enum.KeyCode.Right then
			stepBy(1)
		end
	end))

	local self = {
		Instance = frame,
		Changed = changed,
		Committed = committed,
		Maid = maid,
	}
	function self.GetValue(_self: Slider): number
		return value
	end
	function self.SetValue(_self: Slider, newValue: number, silent: boolean?)
		value = normalize(newValue)
		render()
		if not silent then
			changed:Fire(value)
		end
	end
	function self.Destroy(_self: Slider)
		maid:Clean()
	end

	value = normalize(value)
	render()
	frame.Parent = props.Parent
	return self :: Slider
end

return Slider
