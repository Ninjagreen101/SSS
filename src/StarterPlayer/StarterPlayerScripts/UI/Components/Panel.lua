--!strict
-- Panel: the dark-glass container every menu and card is built from.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Maid = require(ReplicatedStorage:WaitForChild("Shared").Util.Maid)

export type PanelProps = {
	Name: string?,
	Title: string?,
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	AutomaticSize: Enum.AutomaticSize?,
	LayoutOrder: number?,
	Padding: number?,
	Glow: boolean?,
	Transparency: number?,
	Parent: Instance?,
}

export type Panel = {
	Instance: Frame,
	Content: Frame,
	TitleLabel: TextLabel?,
	Maid: Maid.Maid,
	Destroy: (self: Panel) -> (),
}

local Panel = {}

local TITLE_HEIGHT = 34

function Panel.new(props: PanelProps): Panel
	local maid = Maid.new()
	local frame: Frame = Create.new("Frame", {
		Name = props.Name or "Panel",
		Size = props.Size or UDim2.fromOffset(320, 200),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		AutomaticSize = props.AutomaticSize or Enum.AutomaticSize.None,
		LayoutOrder = props.LayoutOrder or 0,
	})
	Create.ApplyPanelStyle(frame, { Glow = props.Glow, Transparency = props.Transparency })
	Create.Padding(frame, props.Padding or UITheme.Padding.Large)
	maid:Add(frame)

	local titleLabel: TextLabel? = nil
	local contentTop = 0
	if props.Title then
		titleLabel = Create.Label({
			Name = "Title",
			Text = props.Title,
			Font = UITheme.Fonts.Title,
			TextSize = UITheme.TextSize.Heading,
			Size = UDim2.new(1, 0, 0, TITLE_HEIGHT - 6),
			Parent = frame,
		})
		Create.new("Frame", {
			Name = "Divider",
			BackgroundColor3 = UITheme.Colors.Edge,
			BackgroundTransparency = 0.3,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(0, TITLE_HEIGHT - 4),
			Size = UDim2.new(1, 0, 0, 1),
			Parent = frame,
		})
		contentTop = TITLE_HEIGHT + UITheme.Padding.Small
	end

	local content: Frame = Create.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, contentTop),
		Size = UDim2.new(1, 0, 1, -contentTop),
		AutomaticSize = if props.AutomaticSize == Enum.AutomaticSize.Y then Enum.AutomaticSize.Y else Enum.AutomaticSize.None,
		Parent = frame,
	})

	frame.Parent = props.Parent

	local self = {
		Instance = frame,
		Content = content,
		TitleLabel = titleLabel,
		Maid = maid,
	}
	function self.Destroy(_self: Panel)
		maid:Clean()
	end
	return self :: Panel
end

return Panel
