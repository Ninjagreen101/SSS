--!strict
-- ScrollList: themed ScrollingFrame with a list or grid layout and
-- automatic canvas sizing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Maid = require(ReplicatedStorage:WaitForChild("Shared").Util.Maid)

export type GridOptions = {
	CellSize: UDim2,
	CellPadding: UDim2?,
}

export type ScrollListProps = {
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	LayoutOrder: number?,
	Spacing: number?,
	Grid: GridOptions?,
	Name: string?,
	Parent: Instance?,
}

export type ScrollList = {
	Instance: ScrollingFrame,
	Maid: Maid.Maid,
	Add: (self: ScrollList, child: GuiObject) -> (),
	Clear: (self: ScrollList) -> (),
	Destroy: (self: ScrollList) -> (),
}

local ScrollList = {}

function ScrollList.new(props: ScrollListProps): ScrollList
	local maid = Maid.new()
	local frame: ScrollingFrame = Create.new("ScrollingFrame", {
		Name = props.Name or "ScrollList",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = props.Size or UDim2.fromScale(1, 1),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = UITheme.Colors.Edge,
		ScrollBarImageTransparency = 0.3,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		Selectable = false,
	})
	maid:Add(frame)
	Create.new("UIPadding", {
		PaddingTop = UDim.new(0, 2),
		PaddingBottom = UDim.new(0, 2),
		PaddingLeft = UDim.new(0, 2),
		PaddingRight = UDim.new(0, 4),
		Parent = frame,
	})
	local grid = props.Grid
	if grid then
		Create.new("UIGridLayout", {
			CellSize = grid.CellSize,
			CellPadding = grid.CellPadding or UDim2.fromOffset(UITheme.Padding.Small, UITheme.Padding.Small),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = frame,
		})
	else
		Create.List(frame, Enum.FillDirection.Vertical, props.Spacing or UITheme.Padding.Small)
	end

	local self = {
		Instance = frame,
		Maid = maid,
	}
	function self.Add(_self: ScrollList, child: GuiObject)
		child.Parent = frame
	end
	function self.Clear(_self: ScrollList)
		for _, child in frame:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end
	function self.Destroy(_self: ScrollList)
		maid:Clean()
	end

	frame.Parent = props.Parent
	return self :: ScrollList
end

return ScrollList
