--!strict
--[[
	Icon
	One pooled map marker (Map and minimap): a glow, a body (a diamond for Waystones and quests, a
	disc for pins), a glyph ("!" for NPCs with a quest, "?" for hand-ins) and, on the big map, a
	caption under it. Apply() restyles a pooled icon for a point, so pools never rebuild.
]]

local UI = script.Parent.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Icons = require(UI.Icons)
local Shapes = require(UI.Shapes)

local Points = require(script.Parent.Points)

local M = UITheme.Map
local C = UITheme.Colors

export type View = {
	Frame: Frame,
	Body: Frame,
	Corner: UICorner,
	Stroke: UIStroke,
	Glow: ImageLabel,
	Glyph: TextLabel,
	Caption: TextLabel?,
	Point: Points.Point?,
	Size: number,
}

local Icon = {}

function Icon.new(parent: Instance, size: number, caption: boolean, zIndex: number): View
	local frame: Frame = Create.new("Frame", {
		Name = "Icon",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		Visible = false,
		ZIndex = zIndex,
		Parent = parent,
	})
	local glow = Icons.Fx("Glow", {
		Name = "Glow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(2.2, 2.2),
		Color = M.Waystone,
		Transparency = 0.4,
		ZIndex = zIndex,
		Parent = frame,
	})
	local body: Frame = Create.new("Frame", {
		Name = "Body",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.62, 0.62),
		Rotation = 45,
		BackgroundColor3 = M.Waystone,
		BorderSizePixel = 0,
		ZIndex = zIndex + 1,
		Parent = frame,
	})
	local corner = Create.Corner(body, UDim.new(0, 2))
	local stroke = Create.Stroke(body, Color3.new(0, 0, 0), 1.5, 0.25)
	local glyph: TextLabel = Create.new("TextLabel", {
		Name = "Glyph",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		FontFace = UITheme.Fonts.Display,
		TextScaled = true,
		TextColor3 = M.Quest,
		TextStrokeTransparency = 0.2,
		Text = "",
		ZIndex = zIndex + 2,
		Parent = frame,
	})
	local label: TextLabel? = nil
	if caption then
		local made = Create.Label({
			Name = "Caption",
			Text = "",
			Font = UITheme.Fonts.BodyBold,
			TextSize = 13,
			Color = C.Text,
			XAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 1, 2),
			Size = UDim2.fromOffset(160, 16),
			Parent = frame,
		})
		made.ZIndex = zIndex + 2
		made.TextStrokeTransparency = 0.3
		label = made
	end
	return {
		Frame = frame,
		Body = body,
		Corner = corner,
		Stroke = stroke,
		Glow = glow,
		Glyph = glyph,
		Caption = label,
		Point = nil,
		Size = size,
	}
end

-- Styles a pooled icon for `point`. `caption` is the text under it on the big map ("" = none).
function Icon.Apply(view: View, point: Points.Point, caption: string?)
	view.Point = point
	view.Frame.Visible = true
	local size = view.Size
	local kind = point.Kind
	local body, glyph, glow = view.Body, view.Glyph, view.Glow
	if kind == "Waystone" then
		body.Visible = true
		body.Rotation = 45
		view.Corner.CornerRadius = UDim.new(0, 2)
		body.BackgroundColor3 = if point.Discovered then M.Waystone else M.WaystoneUndiscovered
		body.Size = UDim2.fromScale(0.62, 0.62)
		glow.Visible = point.Discovered
		glow.ImageColor3 = M.Waystone
		glow.ImageTransparency = 0.35
		glyph.Text = ""
	elseif kind == "Quest" then
		body.Visible = true
		body.Rotation = 45
		view.Corner.CornerRadius = UDim.new(0, 2)
		body.BackgroundColor3 = M.Quest
		body.Size = UDim2.fromScale(if point.Tracked then 0.72 else 0.56, if point.Tracked then 0.72 else 0.56)
		glow.Visible = point.Tracked or point.TurnIn
		glow.ImageColor3 = M.Quest
		glow.ImageTransparency = if point.Tracked then 0.3 else 0.55
		glyph.Text = if point.TurnIn then "?" else ""
		glyph.TextColor3 = Color3.fromRGB(30, 20, 4)
		glyph.TextStrokeTransparency = 1
	elseif kind == "Npc" then
		body.Visible = false
		glow.Visible = true
		glow.ImageColor3 = M.Quest
		glow.ImageTransparency = 0.6
		glyph.Text = "!"
		glyph.TextColor3 = M.Quest
		glyph.TextStrokeTransparency = 0.2
	else
		body.Visible = true
		body.Rotation = 0
		view.Corner.CornerRadius = UDim.new(0.5, 0)
		body.BackgroundColor3 = M.Pin
		body.Size = UDim2.fromScale(0.5, 0.5)
		glow.Visible = false
		glyph.Text = ""
	end
	view.Frame.Size = UDim2.fromOffset(size, size)
	local label = view.Caption
	if label then
		label.Text = caption or ""
		label.Visible = caption ~= nil and caption ~= ""
		label.TextColor3 = if kind == "Waystone" and not point.Discovered then C.TextMuted else C.Text
	end
end

-- The player's arrow (points up at Rotation 0): a pale arrowhead on a soft glow.
function Icon.Arrow(parent: Instance, size: number, zIndex: number): Frame
	local frame: Frame = Create.new("Frame", {
		Name = "PlayerArrow",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		ZIndex = zIndex,
		Parent = parent,
	})
	Icons.Fx("Glow", {
		Name = "Glow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(2, 2),
		Color = C.Aqua,
		Transparency = 0.45,
		ZIndex = zIndex,
		Parent = frame,
	})
	local tip = Vector2.new(size / 2, 0)
	local notch = Vector2.new(size / 2, size * 0.68)
	local props: Shapes.ShapeProps = { Color = M.Player, ZIndex = zIndex + 1, Parent = frame }
	Shapes.Triangle(tip, Vector2.new(size * 0.92, size), notch, props)
	Shapes.Triangle(tip, notch, Vector2.new(size * 0.08, size), props)
	return frame
end

function Icon.Hide(view: View)
	view.Frame.Visible = false
	view.Point = nil
end

return Icon
