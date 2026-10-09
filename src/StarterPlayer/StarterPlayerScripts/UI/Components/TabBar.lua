--!strict
-- TabBar: row of tabs with a teal underline on the selected one. Next/Prev
-- are driven by Q/E on keyboard and LB/RB on gamepad through UIController.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local UISound = require(UI.UISound)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)
local TweenUtil = require(Shared.Util.TweenUtil)

export type Tab = {
	Id: string,
	Text: string,
}

export type TabBarProps = {
	Tabs: { Tab },
	Selected: string?,
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	LayoutOrder: number?,
	Stretch: boolean?, -- tabs share the full width (mobile bottom tabs)
	Parent: Instance?,
}

export type TabBar = {
	Instance: Frame,
	Changed: Signal.Signal<string>,
	Maid: Maid.Maid,
	GetSelected: (self: TabBar) -> string,
	SetSelected: (self: TabBar, id: string, silent: boolean?) -> (),
	Next: (self: TabBar) -> (),
	Prev: (self: TabBar) -> (),
	Destroy: (self: TabBar) -> (),
}

local TabBar = {}

function TabBar.new(props: TabBarProps): TabBar
	assert(#props.Tabs > 0, "TabBar needs at least one tab")
	local maid = Maid.new()
	local changed = Signal.new() :: Signal.Signal<string>
	maid:Add(changed)

	local frame: Frame = Create.new("Frame", {
		Name = "TabBar",
		BackgroundTransparency = 1,
		Size = props.Size or UDim2.new(1, 0, 0, UITheme.Size.TabHeight),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
	})
	maid:Add(frame)

	-- Tabs live in their own row so the baseline below isn't laid out with them.
	local row: Frame = Create.new("Frame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	})
	local list = Create.List(row, Enum.FillDirection.Horizontal, UITheme.Padding.Small)
	list.VerticalAlignment = Enum.VerticalAlignment.Center

	-- Bottom hairline across the whole bar.
	Create.new("Frame", {
		Name = "Baseline",
		BackgroundColor3 = UITheme.Colors.Edge,
		BackgroundTransparency = 0.75,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 1),
		Parent = frame,
	})

	local buttons: { [string]: TextButton } = {}
	local underlines: { [string]: Frame } = {}
	local order: { string } = {}
	local selected = props.Selected or props.Tabs[1].Id
	local count = #props.Tabs

	local function refresh(animate: boolean)
		for id, button in buttons do
			local isSelected = id == selected
			button.FontFace = if isSelected then UITheme.Fonts.BodyBold else UITheme.Fonts.BodyMedium
			local color = if isSelected then UITheme.Colors.Current else UITheme.Colors.TextMuted
			local underline = underlines[id]
			local width = if isSelected then 1 else 0
			if animate then
				TweenUtil.Play(button, UITheme.Motion.HoverTime, { TextColor3 = color })
				TweenUtil.Play(underline, UITheme.Motion.OpenTime, { Size = UDim2.new(width, 0, 0, 2) })
			else
				button.TextColor3 = color
				underline.Size = UDim2.new(width, 0, 0, 2)
			end
		end
	end

	local self = {
		Instance = frame,
		Changed = changed,
		Maid = maid,
	}

	function self.GetSelected(_self: TabBar): string
		return selected
	end

	function self.SetSelected(_self: TabBar, id: string, silent: boolean?)
		if not buttons[id] or id == selected then
			return
		end
		selected = id
		refresh(true)
		if not silent then
			UISound.Play("UIClick")
			changed:Fire(id)
		end
	end

	local function step(delta: number)
		local index = table.find(order, selected) or 1
		local nextIndex = (index - 1 + delta) % #order + 1
		self.SetSelected(self :: any, order[nextIndex])
	end

	function self.Next(_self: TabBar)
		step(1)
	end

	function self.Prev(_self: TabBar)
		step(-1)
	end

	function self.Destroy(_self: TabBar)
		maid:Clean()
	end

	for index, tab in props.Tabs do
		table.insert(order, tab.Id)
		local button: TextButton = Create.new("TextButton", {
			Name = tab.Id,
			Text = tab.Text,
			FontFace = UITheme.Fonts.BodyMedium,
			TextSize = UITheme.TextSize.Body,
			TextColor3 = UITheme.Colors.TextMuted,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			LayoutOrder = index,
			Size = if props.Stretch
				then UDim2.new(1 / count, -UITheme.Padding.Small, 1, 0)
				else UDim2.new(0, 0, 1, 0),
			AutomaticSize = if props.Stretch then Enum.AutomaticSize.None else Enum.AutomaticSize.X,
			SelectionImageObject = Create.SelectionImage(),
			Parent = row,
		})
		Create.Padding(button, 0, UITheme.Padding.Medium, 0)
		local underline: Frame = Create.new("Frame", {
			Name = "Underline",
			BackgroundColor3 = UITheme.Colors.Current,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, 0),
			Size = UDim2.new(0, 0, 0, 2),
			Parent = button,
		})
		buttons[tab.Id] = button
		underlines[tab.Id] = underline
		local id = tab.Id
		maid:Add(button.Activated:Connect(function()
			self.SetSelected(self :: any, id)
		end))
	end

	refresh(false)
	frame.Parent = props.Parent
	return self :: TabBar
end

return TabBar
