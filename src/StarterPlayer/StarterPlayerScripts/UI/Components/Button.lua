--!strict
-- Button: primary (teal), secondary (raised glass) and danger (ember) variants
-- with hover/press scaling, click sound and gamepad selection highlight.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Motion = require(UI.Motion)
local UISound = require(UI.UISound)
local Icons = require(UI.Icons)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)

export type Variant = "Primary" | "Secondary" | "Danger"

export type ButtonProps = {
	Text: string,
	Icon: string?, -- icon name (UI/Icons) shown before the text
	Variant: Variant?,
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	LayoutOrder: number?,
	Enabled: boolean?,
	TextSize: number?,
	Name: string?,
	Parent: Instance?,
	OnActivated: (() -> ())?,
}

export type Button = {
	Instance: TextButton,
	Activated: Signal.Signal<>,
	Maid: Maid.Maid,
	SetText: (self: Button, text: string) -> (),
	SetEnabled: (self: Button, enabled: boolean) -> (),
	IsEnabled: (self: Button) -> boolean,
	Destroy: (self: Button) -> (),
}

type Style = { Background: Color3, Text: Color3, Gradient: ColorSequence, Stroke: Color3, StrokeTransparency: number }

-- Primary: a bright aqua-to-turquoise "water" fill. Secondary: slate glass
-- with a fine blue edge. Danger: deep coral.
local STYLES: { [Variant]: Style } = {
	Primary = {
		Background = Color3.new(1, 1, 1),
		Text = UITheme.Colors.TextOnAccent,
		Gradient = ColorSequence.new(UITheme.Colors.Aqua:Lerp(Color3.new(1, 1, 1), 0.15), UITheme.Colors.Current),
		Stroke = UITheme.Colors.Foam,
		StrokeTransparency = 0.55,
	},
	Secondary = {
		Background = UITheme.Colors.PanelRaised,
		Text = UITheme.Colors.Text,
		Gradient = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(176, 190, 214)),
		Stroke = UITheme.Colors.Edge,
		StrokeTransparency = 0.15,
	},
	Danger = {
		Background = UITheme.Colors.Danger,
		Text = UITheme.Colors.Text,
		Gradient = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(190, 150, 160)),
		Stroke = UITheme.Colors.Danger:Lerp(Color3.new(1, 1, 1), 0.3),
		StrokeTransparency = 0.5,
	},
}

local Button = {}

function Button.new(props: ButtonProps): Button
	local maid = Maid.new()
	local variant: Variant = props.Variant or "Secondary"
	local style = STYLES[variant]
	local enabled = if props.Enabled == nil then true else props.Enabled

	local button: TextButton = Create.new("TextButton", {
		Name = props.Name or "Button",
		Text = props.Text,
		FontFace = UITheme.Fonts.BodyBold,
		TextSize = props.TextSize or UITheme.TextSize.Body,
		TextColor3 = style.Text,
		BackgroundColor3 = style.Background,
		BackgroundTransparency = 0,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Size = props.Size or UDim2.fromOffset(160, UITheme.Size.ButtonHeight),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		SelectionImageObject = Create.SelectionImage(),
	})
	Create.Corner(button)
	Create.Stroke(button, style.Stroke, 1.2, style.StrokeTransparency)
	Create.new("UIGradient", { Rotation = 90, Color = style.Gradient, Parent = button })
	Create.Padding(button, 0, UITheme.Padding.Medium, 0)
	-- With an icon, the button shows an [icon  text] row centred together
	-- (its own Text stays empty and SetText updates the row's label).
	local iconLabel: ImageLabel? = nil
	local rowLabel: TextLabel? = nil
	if props.Icon then
		local textSize = props.TextSize or UITheme.TextSize.Body
		local iconSize = math.floor(textSize * 1.2)
		button.Text = ""
		local row: Frame = Create.new("Frame", {
			Name = "Row",
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.X,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(0, 0, 1, 0),
			Parent = button,
		})
		Create.List(row, Enum.FillDirection.Horizontal, 7, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
		iconLabel = Icons.new(props.Icon, {
			Size = UDim2.fromOffset(iconSize, iconSize),
			Color = style.Text,
			LayoutOrder = 1,
			Parent = row,
		})
		rowLabel = Create.new("TextLabel", {
			Name = "Label",
			BackgroundTransparency = 1,
			Text = props.Text,
			FontFace = UITheme.Fonts.BodyBold,
			TextSize = textSize,
			TextColor3 = style.Text,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 1, 0),
			LayoutOrder = 2,
			Visible = props.Text ~= "", -- icon-only buttons stay centred
			Parent = row,
		})
	end
	maid:Add(button)
	maid:Add(Motion.AttachButtonFeedback(button))

	local activated = Signal.new() :: Signal.Signal<>
	maid:Add(activated)

	local function applyEnabled()
		button.Active = enabled
		button.Selectable = enabled
		button.BackgroundTransparency = if enabled then 0 else 0.55
		button.TextTransparency = if enabled then 0 else 0.45
		if iconLabel then
			iconLabel.ImageTransparency = if enabled then 0 else 0.45
		end
		if rowLabel then
			rowLabel.TextTransparency = if enabled then 0 else 0.45
		end
	end
	applyEnabled()

	maid:Add(button.Activated:Connect(function()
		if not enabled then
			return
		end
		UISound.Play("UIClick")
		activated:Fire()
		if props.OnActivated then
			props.OnActivated()
		end
	end))

	button.Parent = props.Parent

	local self = {
		Instance = button,
		Activated = activated,
		Maid = maid,
	}
	function self.SetText(_self: Button, text: string)
		if rowLabel then
			rowLabel.Text = text
			rowLabel.Visible = text ~= ""
		else
			button.Text = text
		end
	end
	function self.SetEnabled(_self: Button, value: boolean)
		enabled = value
		applyEnabled()
	end
	function self.IsEnabled(_self: Button): boolean
		return enabled
	end
	function self.Destroy(_self: Button)
		maid:Clean()
	end
	return self :: Button
end

return Button
