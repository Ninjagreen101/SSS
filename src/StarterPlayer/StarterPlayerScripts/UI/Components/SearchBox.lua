--!strict
-- SearchBox: sunken text field with a drawn magnifier, clear button and
-- debounced Changed signal (so filtering big lists doesn't run per keystroke).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)
local Strings = require(Shared.Strings)

export type SearchBoxProps = {
	Placeholder: string?,
	Size: UDim2?,
	Position: UDim2?,
	LayoutOrder: number?,
	Debounce: number?,
	Parent: Instance?,
}

export type SearchBox = {
	Instance: Frame,
	TextBox: TextBox,
	Changed: Signal.Signal<string>,
	Maid: Maid.Maid,
	GetText: (self: SearchBox) -> string,
	SetText: (self: SearchBox, text: string) -> (),
	Destroy: (self: SearchBox) -> (),
}

local SearchBox = {}

local function drawMagnifier(parent: Instance)
	local holder: Frame = Create.new("Frame", {
		Name = "Magnifier",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 10, 0.5, 0),
		Size = UDim2.fromOffset(16, 16),
		Parent = parent,
	})
	local ring: Frame = Create.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(11, 11),
		Parent = holder,
	})
	Create.Corner(ring, UITheme.CornerPill)
	Create.Stroke(ring, UITheme.Colors.TextMuted, 2, 0)
	Create.new("Frame", {
		BackgroundColor3 = UITheme.Colors.TextMuted,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(13, 13),
		Size = UDim2.fromOffset(6, 2),
		Rotation = 45,
		Parent = holder,
	})
end

function SearchBox.new(props: SearchBoxProps): SearchBox
	local maid = Maid.new()
	local changed = Signal.new() :: Signal.Signal<string>
	maid:Add(changed)
	local debounce = props.Debounce or 0.15

	local frame: Frame = Create.new("Frame", {
		Name = "SearchBox",
		BackgroundColor3 = UITheme.Colors.PanelSunken,
		BackgroundTransparency = UITheme.SunkenTransparency,
		Size = props.Size or UDim2.new(1, 0, 0, UITheme.Size.InputHeight),
		Position = props.Position or UDim2.new(),
		LayoutOrder = props.LayoutOrder or 0,
	})
	Create.Corner(frame, UITheme.CornerPill)
	local stroke = Create.Stroke(frame)
	maid:Add(frame)
	drawMagnifier(frame)

	local box: TextBox = Create.new("TextBox", {
		Name = "Input",
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		Text = "",
		PlaceholderText = props.Placeholder or Strings.UI.Search,
		PlaceholderColor3 = UITheme.Colors.TextDim,
		TextColor3 = UITheme.Colors.Text,
		FontFace = UITheme.Fonts.Body,
		TextSize = UITheme.TextSize.Body,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(34, 0),
		Size = UDim2.new(1, -70, 1, 0),
		SelectionImageObject = Create.SelectionImage(),
		Parent = frame,
	})

	local clear: TextButton = Create.new("TextButton", {
		Name = "Clear",
		Text = "×",
		FontFace = UITheme.Fonts.BodyBold,
		TextSize = 20,
		TextColor3 = UITheme.Colors.TextMuted,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(26, 26),
		Visible = false,
		Parent = frame,
	})

	maid:Add(box.Focused:Connect(function()
		stroke.Color = UITheme.Colors.Current
		stroke.Transparency = 0.2
	end))
	maid:Add(box.FocusLost:Connect(function()
		stroke.Color = UITheme.Stroke.Color
		stroke.Transparency = UITheme.Stroke.Transparency
	end))
	maid:Add(box:GetPropertyChangedSignal("Text"):Connect(function()
		clear.Visible = box.Text ~= ""
		local text = box.Text
		maid:Set("debounce", task.delay(debounce, function()
			changed:Fire(text)
		end))
	end))
	maid:Add(clear.Activated:Connect(function()
		box.Text = ""
	end))

	local self = {
		Instance = frame,
		TextBox = box,
		Changed = changed,
		Maid = maid,
	}
	function self.GetText(_self: SearchBox): string
		return box.Text
	end
	function self.SetText(_self: SearchBox, text: string)
		box.Text = text
	end
	function self.Destroy(_self: SearchBox)
		maid:Clean()
	end

	frame.Parent = props.Parent
	return self :: SearchBox
end

return SearchBox
