--!strict
-- UI components built from UITheme. Every element gets UICorner, a brass
-- UIStroke, padding and a subtle gradient, scales with UIScale, and animates
-- (open: scale from 96% + fade; buttons: hover 1.04 / press 0.96).

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

local Components = {}

local function corner(parent: GuiObject, radius: UDim?)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius or Theme.Corner
	c.Parent = parent
end

local function stroke(parent: GuiObject, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Color = Theme.Colors.Border
	s.Thickness = Theme.Stroke
	s.Transparency = transparency or Theme.Colors.BorderTransparency
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
end

local function padding(parent: GuiObject, px: number)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, px)
	p.PaddingBottom = UDim.new(0, px)
	p.PaddingLeft = UDim.new(0, px)
	p.PaddingRight = UDim.new(0, px)
	p.Parent = parent
end

local function gradient(parent: GuiObject)
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 0.12),
	})
	g.Parent = parent
end

export type PanelOpts = {
	name: string,
	size: UDim2,
	position: UDim2,
	anchor: Vector2?,
	parent: Instance?,
}

function Components.panel(o: PanelOpts): Frame
	local f = Instance.new("Frame")
	f.Name = o.name
	f.Size = o.size
	f.Position = o.position
	f.AnchorPoint = o.anchor or Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = Theme.Colors.Background
	f.BackgroundTransparency = Theme.Colors.BackgroundTransparency
	f.BorderSizePixel = 0
	corner(f)
	stroke(f)
	padding(f, Theme.Padding)
	gradient(f)
	local scale = Instance.new("UIScale")
	scale.Name = "OpenScale"
	scale.Parent = f
	f.Parent = o.parent
	return f
end

export type LabelOpts = {
	name: string,
	text: string,
	font: Font?,
	size: number?,
	color: Color3?,
	frame: UDim2,
	position: UDim2?,
	anchor: Vector2?,
	alignX: Enum.TextXAlignment?,
	parent: Instance?,
}

function Components.label(o: LabelOpts): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = o.name
	l.Text = o.text
	l.FontFace = o.font or Theme.Fonts.Body
	l.TextSize = o.size or Theme.TextSize.Body
	l.TextColor3 = o.color or Theme.Colors.Text
	l.BackgroundTransparency = 1
	l.Size = o.frame
	l.Position = o.position or UDim2.new()
	l.AnchorPoint = o.anchor or Vector2.new()
	l.TextXAlignment = o.alignX or Enum.TextXAlignment.Left
	l.TextWrapped = true
	l.RichText = false
	l.Parent = o.parent
	return l
end

export type ButtonOpts = {
	name: string,
	text: string,
	variant: string?, -- "primary" | "secondary" | "danger"
	frame: UDim2,
	position: UDim2?,
	anchor: Vector2?,
	parent: Instance?,
	onActivated: () -> (),
}

function Components.button(o: ButtonOpts): TextButton
	local b = Instance.new("TextButton")
	b.Name = o.name
	b.Text = o.text
	b.FontFace = Theme.Fonts.BodyBold
	b.TextSize = Theme.TextSize.Body
	b.AutoButtonColor = false
	b.Size = o.frame
	b.Position = o.position or UDim2.new()
	b.AnchorPoint = o.anchor or Vector2.new()
	local variant = o.variant or "primary"
	if variant == "primary" then
		b.BackgroundColor3 = Theme.Colors.CurrentDeep
		b.TextColor3 = Theme.Colors.Text
	elseif variant == "danger" then
		b.BackgroundColor3 = Theme.Colors.Danger
		b.TextColor3 = Theme.Colors.Text
	else
		b.BackgroundColor3 = Theme.Colors.Surface
		b.TextColor3 = Theme.Colors.Text
	end
	b.BorderSizePixel = 0
	corner(b, Theme.CornerSmall)
	stroke(b, 0.4)
	local scale = Instance.new("UIScale")
	scale.Parent = b
	local base = b.BackgroundColor3
	b.MouseEnter:Connect(function()
		TweenService:Create(scale, Theme.Tween.Hover, { Scale = Theme.HoverScale }):Play()
		TweenService:Create(b, Theme.Tween.Hover, { BackgroundColor3 = base:Lerp(Theme.Colors.Current, 0.18) }):Play()
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(scale, Theme.Tween.Hover, { Scale = 1 }):Play()
		TweenService:Create(b, Theme.Tween.Hover, { BackgroundColor3 = base }):Play()
	end)
	b.MouseButton1Down:Connect(function()
		TweenService:Create(scale, Theme.Tween.Hover, { Scale = Theme.PressScale }):Play()
	end)
	b.MouseButton1Up:Connect(function()
		TweenService:Create(scale, Theme.Tween.Hover, { Scale = 1 }):Play()
	end)
	b.Activated:Connect(o.onActivated)
	b.Parent = o.parent
	return b
end

-- Animate a panel open (scale from 96% + fade) and return a close function.
function Components.open(panel: Frame)
	local scale = panel:FindFirstChild("OpenScale") :: UIScale?
	panel.Visible = true
	if scale then
		scale.Scale = Theme.OpenScale
		TweenService:Create(scale, Theme.Tween.Open, { Scale = 1 }):Play()
	end
	local target = Theme.Colors.BackgroundTransparency
	panel.BackgroundTransparency = 1
	TweenService:Create(panel, Theme.Tween.Open, { BackgroundTransparency = target }):Play()
end

function Components.close(panel: Frame, onDone: (() -> ())?)
	local scale = panel:FindFirstChild("OpenScale") :: UIScale?
	if scale then
		TweenService:Create(scale, Theme.Tween.Close, { Scale = Theme.OpenScale }):Play()
	end
	local t = TweenService:Create(panel, Theme.Tween.Close, { BackgroundTransparency = 1 })
	t.Completed:Once(function()
		panel.Visible = false
		if onDone then
			onDone()
		end
	end)
	t:Play()
end

function Components.screen(name: string, parent: Instance, order: number): ScreenGui
	local g = Instance.new("ScreenGui")
	g.Name = name
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	g.DisplayOrder = order
	local scale = Instance.new("UIScale")
	scale.Name = "HudScale"
	scale.Parent = g
	g.Parent = parent
	return g
end

return Components
