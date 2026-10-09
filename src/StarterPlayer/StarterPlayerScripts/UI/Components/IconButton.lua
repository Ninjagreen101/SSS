--!strict
-- IconButton: round glass button showing an icon image, or a short glyph
-- when no icon is set. Optional tooltip text.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Motion = require(UI.Motion)
local UISound = require(UI.UISound)
local Tooltip = require(script.Parent.Tooltip)
local Icons = require(UI.Icons)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)

export type IconButtonProps = {
	Icon: string?, -- name of an icon on the UI icon sheet (preferred)
	Image: string?,
	Glyph: string?,
	Size: number?,
	Color: Color3?,
	Tooltip: string?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	LayoutOrder: number?,
	Name: string?,
	Parent: Instance?,
	OnActivated: (() -> ())?,
}

export type IconButton = {
	Instance: TextButton,
	Activated: Signal.Signal<>,
	Maid: Maid.Maid,
	SetGlyph: (self: IconButton, glyph: string) -> (),
	SetImage: (self: IconButton, image: string) -> (),
	Destroy: (self: IconButton) -> (),
}

local IconButton = {}

function IconButton.new(props: IconButtonProps): IconButton
	local maid = Maid.new()
	local size = props.Size or UITheme.Size.IconButton
	local color = props.Color or UITheme.Colors.Text

	local button: TextButton = Create.new("TextButton", {
		Name = props.Name or "IconButton",
		Text = props.Glyph or "",
		FontFace = UITheme.Fonts.BodyBold,
		TextSize = math.floor(size * 0.45),
		TextColor3 = color,
		BackgroundColor3 = UITheme.Colors.PanelRaised,
		BackgroundTransparency = 0.1,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(size, size),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		SelectionImageObject = Create.SelectionImage(),
	})
	Create.Corner(button, UITheme.CornerPill)
	local stroke = Create.Stroke(button, UITheme.Colors.Edge, 1.2, 0.1)
	maid:Add(button)
	maid:Add(Motion.AttachButtonFeedback(button))

	local image: ImageLabel = Create.new("ImageLabel", {
		Name = "Icon",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.62, 0.62),
		Image = props.Image or "",
		ImageColor3 = color,
		Visible = props.Image ~= nil and props.Image ~= "",
		Parent = button,
	})
	if props.Icon then
		Icons.Apply(image, props.Icon)
		image.Size = UDim2.fromScale(0.5, 0.5)
		image.Visible = true
	end
	-- Hover: the edge and the icon brighten toward foam.
	maid:Add(button.MouseEnter:Connect(function()
		stroke.Color = UITheme.Colors.EdgeBright
		image.ImageColor3 = UITheme.Colors.Foam
		button.TextColor3 = UITheme.Colors.Foam
	end))
	maid:Add(button.MouseLeave:Connect(function()
		stroke.Color = UITheme.Colors.Edge
		image.ImageColor3 = color
		button.TextColor3 = color
	end))
	if image.Visible then
		button.Text = ""
	end

	local activated = Signal.new() :: Signal.Signal<>
	maid:Add(activated)
	maid:Add(button.Activated:Connect(function()
		UISound.Play("UIClick")
		activated:Fire()
		if props.OnActivated then
			props.OnActivated()
		end
	end))

	local tooltipText = props.Tooltip
	if tooltipText then
		maid:Add(Tooltip.Attach(button, function(): Tooltip.TooltipContent?
			return { Title = tooltipText }
		end))
	end

	button.Parent = props.Parent

	local self = {
		Instance = button,
		Activated = activated,
		Maid = maid,
	}
	function self.SetGlyph(_self: IconButton, glyph: string)
		image.Visible = false
		button.Text = glyph
	end
	function self.SetImage(_self: IconButton, newImage: string)
		image.Image = newImage
		image.Visible = newImage ~= ""
		if image.Visible then
			button.Text = ""
		end
	end
	function self.Destroy(_self: IconButton)
		maid:Clean()
	end
	return self :: IconButton
end

return IconButton
