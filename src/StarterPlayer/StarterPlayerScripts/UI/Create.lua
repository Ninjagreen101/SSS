--!strict
--[[
	Create
	Instance construction helpers so every UI element is built the same way.
	Create("Frame", { Size = ... }, { children }) sets properties then parents
	children; style helpers add the theme's corner, stroke, padding, gradient
	and inner glow to any GuiObject.
]]

local UITheme = require(script.Parent.UITheme)

local Create = {}

-- Generic constructor. `props.Parent` is applied last so the instance is
-- fully configured before it replicates into the visible tree.
function Create.new(className: string, props: { [string]: any }?, children: { Instance }?): any
	local instance = Instance.new(className) :: any
	local parent: Instance? = nil
	if props then
		for key, value in props do
			if key == "Parent" then
				parent = value
			else
				instance[key] = value
			end
		end
	end
	if children then
		for _, child in children do
			child.Parent = instance
		end
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

function Create.Corner(parent: Instance, radius: UDim?): UICorner
	return Create.new("UICorner", { CornerRadius = radius or UITheme.Corner, Parent = parent })
end

function Create.Stroke(parent: Instance, color: Color3?, thickness: number?, transparency: number?): UIStroke
	return Create.new("UIStroke", {
		Color = color or UITheme.Stroke.Color,
		Thickness = thickness or UITheme.Stroke.Thickness,
		Transparency = if transparency ~= nil then transparency else UITheme.Stroke.Transparency,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

function Create.Padding(parent: Instance, all: number?, horizontal: number?, vertical: number?): UIPadding
	local base = all or UITheme.Padding.Medium
	local h = UDim.new(0, horizontal or base)
	local v = UDim.new(0, vertical or base)
	-- Padding also insets children, so grow the inner glow back out to the
	-- panel's edge (it must hug the border, not the content area).
	local glow = parent:FindFirstChild("InnerGlow")
	if glow and glow:IsA("GuiObject") then
		glow.Size = UDim2.new(1, h.Offset * 2 - 4, 1, v.Offset * 2 - 4)
	end
	return Create.new("UIPadding", {
		PaddingLeft = h,
		PaddingRight = h,
		PaddingTop = v,
		PaddingBottom = v,
		Parent = parent,
	})
end

-- Subtle top-to-bottom sheen used on every panel (lighter at the top, like
-- light falling through water).
function Create.PanelGradient(parent: Instance): UIGradient
	return Create.new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(178, 192, 214)),
		Parent = parent,
	})
end

-- A 1-px inset frame with a faint teal stroke: the "soft inner glow".
function Create.InnerGlow(parent: GuiObject, radius: UDim?): Frame
	local glow = Create.new("Frame", {
		Name = "InnerGlow",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -4, 1, -4),
		ZIndex = parent.ZIndex,
		Parent = parent,
	})
	Create.Corner(glow, radius or UITheme.CornerSmall)
	Create.Stroke(glow, UITheme.InnerGlow.Color, UITheme.InnerGlow.Thickness, UITheme.InnerGlow.Transparency)
	return glow
end

-- Applies the full dark-glass panel style to a frame.
export type PanelStyle = {
	Glow: boolean?,
	Transparency: number?,
	Color: Color3?,
	StrokeColor: Color3?,
	StrokeTransparency: number?,
}

function Create.ApplyPanelStyle(frame: GuiObject, options: PanelStyle?)
	local opts: PanelStyle = options or {}
	frame.BackgroundColor3 = opts.Color or UITheme.Colors.Panel
	frame.BackgroundTransparency = if opts.Transparency ~= nil then opts.Transparency else UITheme.PanelTransparency
	frame.BorderSizePixel = 0
	Create.Corner(frame)
	Create.Stroke(frame, opts.StrokeColor, nil, opts.StrokeTransparency)
	Create.PanelGradient(frame)
	if opts.Glow ~= false then
		Create.InnerGlow(frame)
	end
end

export type LabelProps = {
	Text: string,
	Font: Font?,
	TextSize: number?,
	Color: Color3?,
	XAlignment: Enum.TextXAlignment?,
	YAlignment: Enum.TextYAlignment?,
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	AutomaticSize: Enum.AutomaticSize?,
	Wrapped: boolean?,
	RichText: boolean?,
	LayoutOrder: number?,
	Name: string?,
	Parent: Instance?,
}

-- Themed TextLabel (body font, off-white) with sensible defaults.
function Create.Label(props: LabelProps): TextLabel
	return Create.new("TextLabel", {
		Name = props.Name or "Label",
		BackgroundTransparency = 1,
		Text = props.Text,
		FontFace = props.Font or UITheme.Fonts.Body,
		TextSize = props.TextSize or UITheme.TextSize.Body,
		TextColor3 = props.Color or UITheme.Colors.Text,
		TextXAlignment = props.XAlignment or Enum.TextXAlignment.Left,
		TextYAlignment = props.YAlignment or Enum.TextYAlignment.Center,
		TextWrapped = props.Wrapped or false,
		RichText = props.RichText or false,
		Size = props.Size or UDim2.new(1, 0, 0, (props.TextSize or UITheme.TextSize.Body) + 6),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		AutomaticSize = props.AutomaticSize or Enum.AutomaticSize.None,
		LayoutOrder = props.LayoutOrder or 0,
		Parent = props.Parent,
	})
end

function Create.List(
	parent: Instance,
	direction: Enum.FillDirection?,
	padding: number?,
	hAlign: Enum.HorizontalAlignment?,
	vAlign: Enum.VerticalAlignment?
): UIListLayout
	return Create.new("UIListLayout", {
		FillDirection = direction or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, padding or UITheme.Padding.Small),
		HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left,
		VerticalAlignment = vAlign or Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = parent,
	})
end

-- Shared gamepad selection highlight (teal outline) for every selectable.
local selectionTemplate: Frame? = nil
function Create.SelectionImage(): Frame
	if selectionTemplate then
		return selectionTemplate
	end
	local frame = Create.new("Frame", {
		Name = "SpireSelection",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 6, 1, 6),
		Position = UDim2.fromOffset(-3, -3),
	})
	Create.Corner(frame, UDim.new(0, 10))
	Create.Stroke(frame, UITheme.Selection.Color, UITheme.Selection.Thickness, 0)
	selectionTemplate = frame
	return frame
end

return Create
