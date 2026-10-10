--!strict
--[[
	Log
	The Quest Log page (J), a tab of the Character window:

	  [ Main Story | Side Quests | Dailies | Weeklies | Achievements ]      (Q / E, LB / RB)
	  ┌ list ───────────────┐  ┌ detail ─────────────────────────────────┐
	  │ Resets in 5:12:03   │  │ Teeth of the Tide              (gold)   │
	  │ IN PROGRESS         │  │ Main Story  ·  Recommended level 2      │
	  │ ▌Teeth of the Tide ◆│  │ summary                                 │
	  │ COMPLETED           │  │ OBJECTIVES  ☐ Slay Bilgecrabs   3/6 ▬▬  │
	  │ ▌A Climber's Mark  ✓│  │ REWARDS     XP  Gold  Shards  [items]   │
	  └─────────────────────┘  │ [Track] [Abandon] [Reroll]              │
	                           └─────────────────────────────────────────┘
	Rows, objective lines, reward chips and item slots are pooled and re-filled on changes.
	Dailies and weeklies show their reset countdown (and rerolls left for dailies).
	The Achievements tab shows AchievementController's panel instead of the list.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Maid = require(Shared.Util.Maid)
local MathUtil = require(Shared.Util.MathUtil)
local Quests = require(Shared.Data.Quests)
local Items = require(Shared.Data.Items)

local UI = script.Parent.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Icons = require(UI.Icons)
local Device = require(UI.Device)
local Motion = require(UI.Motion)
local ItemText = require(UI.ItemText)
local QuestText = require(UI.QuestText)
local Components = require(UI.Components)

local DataController = require(script.Parent.Parent.DataController)
local UIController = require(script.Parent.Parent.UIController)
local AchievementController = require(script.Parent.Parent.AchievementController)

local State = require(script.Parent.State)

local C = UITheme.Colors
local QT = UITheme.Quests
local Q = Strings.QuestUI

local TABS = { "Main", "Side", "Daily", "Weekly", "Achievements" }
local LIST_WIDTH = 0.37
local ROW_HEIGHT = 58
local MAX_OBJECTIVES = 6
local MAX_ITEMS = 4

type Row = {
	Button: TextButton,
	Stroke: UIStroke,
	Accent: Frame,
	Name: TextLabel,
	Meta: TextLabel,
	Icon: ImageLabel,
	QuestId: string?,
}

type ObjectiveRow = {
	Frame: Frame,
	Box: Frame,
	Tick: ImageLabel,
	Text: TextLabel,
	Count: TextLabel,
	Bar: Components.ProgressBar,
}

type Chip = {
	Frame: Frame,
	Icon: ImageLabel,
	Label: TextLabel,
}

type RewardSlot = {
	Holder: Frame,
	Slot: Components.ItemSlot,
	Name: TextLabel,
	Preview: any,
}

local Log = {}

Log.MenuId = "QuestLog"

local focusHandler: ((string) -> ())? = nil
local pendingFocus: string? = nil

-- Which tab a quest lives on.
local function tabFor(id: string): string
	local def = Quests.Get(id)
	if not def then
		return "Main"
	end
	if def.Kind == "Tutorial" then
		return "Main"
	end
	return def.Kind
end

-- Next reset (unix seconds, UTC) for dailies or weeklies, from the Config schedule.
local function nextReset(weekly: boolean): number
	local now = Workspace:GetServerTimeNow()
	local hour = Config.Quests.DailyResetHourUTC * 3600
	local dayStart = math.floor((now - hour) / 86400) * 86400 + hour
	if not weekly then
		return dayStart + 86400
	end
	local wday = (os.date("!*t", math.floor(dayStart)) :: any).wday :: number
	local delta = (Config.Quests.WeeklyResetWeekdayUTC - wday) % 7
	if delta == 0 then
		delta = 7
	end
	return dayStart + delta * 86400
end

local function heading(parent: Instance, text: string, order: number): TextLabel
	local label = Create.Label({
		Name = "Heading",
		Text = string.upper(text),
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Small,
		Color = C.Accent,
		Size = UDim2.new(1, 0, 0, 26),
		YAlignment = Enum.TextYAlignment.Bottom,
		LayoutOrder = order,
		Parent = parent,
	})
	return label
end

function Log.Build(content: Frame, maid: Maid.Maid): any
	local isOpen = false
	local selectedByTab: { [string]: string } = {}

	local tabs: { { Id: string, Text: string } } = {}
	for _, id in TABS do
		table.insert(tabs, { Id = id, Text = Q.Tabs[id] or id })
	end
	local tabBar = Components.TabBar.new({ Tabs = tabs, Selected = "Main", Parent = content })
	maid:Add(tabBar)

	local body: Frame = Create.new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, UITheme.Size.TabHeight + UITheme.Padding.Medium),
		Size = UDim2.new(1, 0, 1, -(UITheme.Size.TabHeight + UITheme.Padding.Medium)),
		Parent = content,
	})

	local questView: Frame = Create.new("Frame", { Name = "Quests", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = body })
	local achievements = AchievementController.BuildPanel(body, maid)
	achievements.Root.Visible = false

	-- LIST ------------------------------------------------------------------------------------
	local listPanel: Frame = Create.new("Frame", {
		Name = "ListPanel",
		BackgroundColor3 = C.PanelSunken,
		BackgroundTransparency = 0.4,
		Size = UDim2.new(LIST_WIDTH, 0, 1, 0),
		Parent = questView,
	})
	Create.Corner(listPanel, UDim.new(0, 10))
	Create.Stroke(listPanel, C.Edge, 1, 0.45)
	Create.Padding(listPanel, UITheme.Padding.Small)

	local info: Frame = Create.new("Frame", { Name = "Info", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44), Visible = false, Parent = listPanel })
	Icons.new("Time", { Position = UDim2.fromOffset(4, 4), Size = UDim2.fromOffset(16, 16), Color = C.Aqua, Parent = info })
	local resetLabel = Create.Label({
		Text = "",
		Font = UITheme.Fonts.BodyMedium,
		TextSize = UITheme.TextSize.Small,
		Color = C.Text,
		Position = UDim2.fromOffset(26, 0),
		Size = UDim2.new(1, -26, 0, 22),
		Parent = info,
	})
	local rerollLabel = Create.Label({
		Text = "",
		TextSize = UITheme.TextSize.Caption,
		Color = C.TextMuted,
		Position = UDim2.fromOffset(26, 20),
		Size = UDim2.new(1, -26, 0, 20),
		Parent = info,
	})

	local list = Components.ScrollList.new({ Name = "List", Spacing = 6, Parent = listPanel })
	maid:Add(list)

	local emptyLabel = Create.Label({
		Name = "Empty",
		Text = Q.Empty,
		Color = C.TextMuted,
		TextSize = UITheme.TextSize.Small,
		Wrapped = true,
		XAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 60),
		Visible = false,
		Parent = listPanel,
	})

	local rows: { Row } = {}
	local headers: { TextLabel } = {}
	local selectQuest: (string) -> ()

	local function getRow(index: number): Row
		local existing = rows[index]
		if existing then
			return existing
		end
		local button: TextButton = Create.new("TextButton", {
			Name = `Row{index}`,
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = C.PanelRaised,
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
			Size = UDim2.new(1, -4, 0, ROW_HEIGHT),
			SelectionImageObject = Create.SelectionImage(),
		})
		Create.Corner(button)
		local stroke = Create.Stroke(button, C.Edge, 1, 0.5)
		local accent: Frame = Create.new("Frame", {
			Name = "Accent",
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(0, 8),
			Size = UDim2.new(0, 3, 1, -16),
			BackgroundColor3 = C.Aqua,
			Parent = button,
		})
		local name = Create.Label({
			Name = "Name",
			Text = "",
			Font = UITheme.Fonts.BodyBold,
			TextSize = UITheme.TextSize.Body,
			Position = UDim2.fromOffset(14, 8),
			Size = UDim2.new(1, -46, 0, 22),
			Parent = button,
		})
		name.TextTruncate = Enum.TextTruncate.AtEnd
		local meta = Create.Label({
			Name = "Meta",
			Text = "",
			TextSize = UITheme.TextSize.Caption,
			Color = C.TextMuted,
			RichText = true,
			Position = UDim2.fromOffset(14, 31),
			Size = UDim2.new(1, -46, 0, 18),
			Parent = button,
		})
		local icon = Icons.new("Mark", {
			Name = "State",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			Size = UDim2.fromOffset(18, 18),
			Color = QT.Ready,
			Parent = button,
		})
		local row: Row = { Button = button, Stroke = stroke, Accent = accent, Name = name, Meta = meta, Icon = icon, QuestId = nil }
		maid:Add(Motion.AttachButtonFeedback(button))
		maid:Add(button.Activated:Connect(function()
			local id = row.QuestId
			if id then
				selectQuest(id)
			end
		end))
		-- Gamepad: moving the selection previews the quest.
		maid:Add(button.SelectionGained:Connect(function()
			local id = row.QuestId
			if id then
				selectQuest(id)
			end
		end))
		rows[index] = row
		list:Add(button)
		return row
	end

	local function getHeader(index: number): TextLabel
		local existing = headers[index]
		if existing then
			return existing
		end
		local label = heading(list.Instance, "", 0)
		label.Size = UDim2.new(1, -4, 0, 24)
		headers[index] = label
		return label
	end

	-- DETAIL ----------------------------------------------------------------------------------
	local detail: ScrollingFrame = Create.new("ScrollingFrame", {
		Name = "Detail",
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		Position = UDim2.new(LIST_WIDTH, UITheme.Padding.Large, 0, 0),
		Size = UDim2.new(1 - LIST_WIDTH, -UITheme.Padding.Large, 1, 0),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.Edge,
		Selectable = false,
		Parent = questView,
	})
	Create.Corner(detail, UDim.new(0, 10))
	Create.Stroke(detail, C.Edge, 1, 0.45)
	Create.Padding(detail, UITheme.Padding.Large)
	Create.List(detail, Enum.FillDirection.Vertical, 8)

	local titleLabel = Create.Label({
		Name = "Title",
		Text = "",
		Font = UITheme.Fonts.Display,
		TextSize = 28,
		Wrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 34),
		LayoutOrder = 1,
		Parent = detail,
	})
	local metaLabel = Create.Label({
		Name = "Meta",
		Text = "",
		TextSize = UITheme.TextSize.Small,
		Color = C.TextMuted,
		RichText = true,
		Size = UDim2.new(1, 0, 0, 20),
		LayoutOrder = 2,
		Parent = detail,
	})
	local statusLabel = Create.Label({
		Name = "Status",
		Text = "",
		Font = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.Body,
		Color = QT.Ready,
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = 3,
		Parent = detail,
	})
	local summaryLabel = Create.Label({
		Name = "Summary",
		Text = "",
		Font = UITheme.Fonts.DisplayRegular,
		TextSize = UITheme.TextSize.Body,
		Color = C.Text,
		Wrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 20),
		LayoutOrder = 4,
		Parent = detail,
	})
	local objectivesHeading = heading(detail, Q.Objectives, 5)
	local objectiveRows: { ObjectiveRow } = {}
	for index = 1, MAX_OBJECTIVES do
		local frame: Frame = Create.new("Frame", {
			Name = `Objective{index}`,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 36),
			LayoutOrder = 5 + index,
			Visible = false,
			Parent = detail,
		})
		local box: Frame = Create.new("Frame", {
			Name = "Box",
			Position = UDim2.fromOffset(0, 3),
			Size = UDim2.fromOffset(18, 18),
			BackgroundColor3 = C.PanelSunken,
			Parent = frame,
		})
		Create.Corner(box, UDim.new(0, 4))
		Create.Stroke(box, C.EdgeBright, 1, 0.3)
		local tick = Icons.new("Check", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(16, 16),
			Color = QT.Done,
			Parent = box,
		})
		local text = Create.Label({
			Name = "Text",
			Text = "",
			TextSize = UITheme.TextSize.Body,
			Position = UDim2.fromOffset(30, 0),
			Size = UDim2.new(1, -110, 0, 24),
			Parent = frame,
		})
		text.TextTruncate = Enum.TextTruncate.AtEnd
		local count = Create.Label({
			Name = "Count",
			Text = "",
			Font = UITheme.Fonts.Numbers,
			TextSize = UITheme.TextSize.Small,
			Color = C.TextMuted,
			XAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.fromOffset(76, 24),
			Parent = frame,
		})
		local bar = Components.ProgressBar.new({
			Name = "Bar",
			Color = C.Aqua,
			Position = UDim2.fromOffset(30, 27),
			Size = UDim2.new(1, -30, 0, 4),
			Parent = frame,
		})
		maid:Add(bar)
		table.insert(objectiveRows, { Frame = frame, Box = box, Tick = tick, Text = text, Count = count, Bar = bar })
	end

	local rewardsHeading = heading(detail, Q.Rewards, 20)
	local chipRow: Frame = Create.new("Frame", { Name = "Chips", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 21, Parent = detail })
	Create.List(chipRow, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local chips: { [string]: Chip } = {}
	for order, kind in { "XP", "Gold", "Shards" } do
		local frame: Frame = Create.new("Frame", {
			Name = kind,
			BackgroundColor3 = C.PanelRaised,
			BackgroundTransparency = 0.3,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 30),
			LayoutOrder = order,
			Parent = chipRow,
		})
		Create.Corner(frame, UITheme.CornerPill)
		Create.Padding(frame, 0, 12, 0)
		Create.List(frame, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		local icon = Icons.new(kind, { Size = UDim2.fromOffset(18, 18), Color = if kind == "Gold" then UITheme.Colors.Stamina else C.Aqua, LayoutOrder = 1, Parent = frame })
		local label = Create.Label({
			Text = "",
			Font = UITheme.Fonts.BodyBold,
			TextSize = UITheme.TextSize.Small,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 1, 0),
			LayoutOrder = 2,
			Parent = frame,
		})
		chips[kind] = { Frame = frame, Icon = icon, Label = label }
	end
	local itemRow: Frame = Create.new("Frame", { Name = "Items", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 86), LayoutOrder = 22, Parent = detail })
	Create.List(itemRow, Enum.FillDirection.Horizontal, 10)
	local rewardSlots: { RewardSlot } = {}
	for index = 1, MAX_ITEMS do
		local holder: Frame = Create.new("Frame", {
			Name = `Item{index}`,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(84, 86),
			LayoutOrder = index,
			Visible = false,
			Parent = itemRow,
		})
		local slot = Components.ItemSlot.new({ Size = 60, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Parent = holder })
		maid:Add(slot)
		local name = Create.Label({
			Text = "",
			TextSize = 11,
			Color = C.TextMuted,
			XAlignment = Enum.TextXAlignment.Center,
			Wrapped = true,
			Position = UDim2.fromOffset(0, 62),
			Size = UDim2.new(1, 0, 0, 24),
			Parent = holder,
		})
		local entry: RewardSlot = { Holder = holder, Slot = slot, Name = name, Preview = nil }
		maid:Add(Components.Tooltip.Attach(slot.Instance, function(): Components.TooltipContent?
			local preview = entry.Preview
			return if preview then ItemText.Tooltip(preview, DataController.GetData()) else nil
		end))
		table.insert(rewardSlots, entry)
	end

	local actions: Frame = Create.new("Frame", { Name = "Actions", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 52), LayoutOrder = 30, Parent = detail })
	Create.List(actions, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local currentId: string? = nil
	local buttonHeight = if Device.IsTouch() then UITheme.Size.ButtonHeightTouch else UITheme.Size.ButtonHeight

	local trackButton = Components.Button.new({
		Text = Q.Track,
		Icon = "Mark",
		Variant = "Primary",
		Size = UDim2.fromOffset(150, buttonHeight),
		LayoutOrder = 1,
		Parent = actions,
		OnActivated = function()
			local id = currentId
			if not id then
				return
			end
			if State.Tracked() == id then
				Net.FireServer("RequestQuestAction", "Track", "", "")
			else
				Net.FireServer("RequestQuestAction", "Track", id, "")
			end
		end,
	})
	maid:Add(trackButton)
	local acceptButton = Components.Button.new({
		Text = Q.Accept,
		Variant = "Primary",
		Size = UDim2.fromOffset(150, buttonHeight),
		LayoutOrder = 2,
		Parent = actions,
		OnActivated = function()
			local id = currentId
			if id then
				Net.FireServer("RequestQuestAction", "Accept", id, "")
			end
		end,
	})
	maid:Add(acceptButton)
	local rerollButton = Components.Button.new({
		Text = Q.Reroll,
		Icon = "Reset",
		Variant = "Secondary",
		Size = UDim2.fromOffset(140, buttonHeight),
		LayoutOrder = 3,
		Parent = actions,
		OnActivated = function()
			local id = currentId
			if id then
				Net.FireServer("RequestQuestAction", "Reroll", id, "")
			end
		end,
	})
	maid:Add(rerollButton)
	local abandonButton = Components.Button.new({
		Text = Q.Abandon,
		Variant = "Danger",
		Size = UDim2.fromOffset(140, buttonHeight),
		LayoutOrder = 4,
		Parent = actions,
		OnActivated = function()
			local id = currentId
			if not id then
				return
			end
			UIController.Confirm({
				Title = Q.Abandon,
				Message = Strings.Format(Q.AbandonConfirm, { name = QuestText.QuestName(id) }),
				ConfirmText = Q.Abandon,
				Danger = true,
			}):andThen(function(confirmed: boolean): any
				if confirmed then
					Net.FireServer("RequestQuestAction", "Abandon", id, "")
				end
				return nil
			end)
		end,
	})
	maid:Add(abandonButton)

	local noSelection = Create.Label({
		Name = "NoSelection",
		Text = Q.Empty,
		Color = C.TextMuted,
		Wrapped = true,
		XAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 80),
		LayoutOrder = 0,
		Visible = false,
		Parent = detail,
	})
	local detailParts: { GuiObject } = { titleLabel, metaLabel, statusLabel, summaryLabel, objectivesHeading, rewardsHeading, chipRow, itemRow, actions }

	local function renderDetail(id: string?)
		currentId = id
		local def = if id then Quests.Get(id) else nil
		noSelection.Visible = def == nil
		for _, part in detailParts do
			part.Visible = def ~= nil
		end
		if not id or not def then
			for _, row in objectiveRows do
				row.Frame.Visible = false
			end
			return
		end
		local status = State.Status(id)
		local color = QuestText.KindColor(def.Kind)
		titleLabel.Text = QuestText.QuestName(id)
		titleLabel.TextColor3 = color
		metaLabel.Text = `<font color="#{color:ToHex()}">{QuestText.KindName(def.Kind)}</font>  ·  {Strings.Format(Q.Level, { level = def.Level })}`
		if status == "Ready" then
			statusLabel.Text = if def.TurnIn then Strings.Format(Q.ReturnTo, { name = QuestText.NpcName(def.TurnIn) }) else Q.Ready
			statusLabel.TextColor3 = QT.Ready
		elseif status == "Completed" then
			statusLabel.Text = Q.Completed
			statusLabel.TextColor3 = QT.Done
		elseif status == "Active" and State.Tracked() == id then
			statusLabel.Text = Q.Tracked
			statusLabel.TextColor3 = C.Aqua
		else
			statusLabel.Text = ""
		end
		statusLabel.Visible = statusLabel.Text ~= ""
		local summary = QuestText.QuestSummary(id)
		summaryLabel.Text = summary
		summaryLabel.Visible = summary ~= ""

		-- Objectives.
		for index, row in objectiveRows do
			local objective = def.Objectives[index]
			if objective and State.ObjectiveVisible(id, index) then
				local done, needed = State.Progress(id, index)
				local complete = done >= needed
				row.Frame.Visible = true
				row.Text.Text = QuestText.Objective(id, index)
				row.Text.TextColor3 = if complete then C.TextMuted else C.Text
				row.Tick.Visible = complete
				row.Count.Text = Strings.Format(Q.Progress, { done = done, total = needed })
				row.Count.TextColor3 = if complete then QT.Done else C.TextMuted
				row.Bar.Instance.Visible = needed > 1
				row.Bar:SetValue(done, needed, true)
				row.Bar:SetColor(if complete then QT.Done else color)
				row.Frame.Size = UDim2.new(1, 0, 0, if needed > 1 then 36 else 26)
			else
				row.Frame.Visible = false
			end
		end

		-- Rewards.
		local rewards = def.Rewards
		chips.XP.Frame.Visible = rewards.XP > 0
		chips.XP.Label.Text = Strings.Format(Q.RewardXP, { xp = MathUtil.FormatNumber(rewards.XP) })
		chips.Gold.Frame.Visible = rewards.Gold > 0
		chips.Gold.Label.Text = Strings.Format(Q.RewardGold, { gold = MathUtil.FormatNumber(rewards.Gold) })
		local shards = rewards.Shards or 0
		chips.Shards.Frame.Visible = shards > 0
		chips.Shards.Label.Text = Strings.Format(Q.RewardShards, { shards = shards })
		local items: { Quests.RewardItem } = rewards.Items or {}
		local shown = 0
		for _, reward in items do
			if shown >= #rewardSlots then
				break
			end
			if Items.Get(reward.Id) then
				shown += 1
				local entry = rewardSlots[shown]
				local preview = ItemText.Preview(reward.Id, reward.Count)
				if reward.Rarity then
					preview.Rarity = reward.Rarity :: any
				end
				entry.Preview = preview
				entry.Slot:SetItem(ItemText.Slot(preview))
				entry.Name.Text = QuestText.ItemName(reward.Id)
				entry.Holder.Visible = true
			end
		end
		for index = shown + 1, #rewardSlots do
			rewardSlots[index].Holder.Visible = false
			rewardSlots[index].Preview = nil
		end
		itemRow.Visible = shown > 0

		-- Actions.
		local active = status == "Active" or status == "Ready"
		trackButton.Instance.Visible = active
		trackButton:SetText(if State.Tracked() == id then Q.Untrack else Q.Track)
		local rolled = def.Kind == "Daily" or def.Kind == "Weekly"
		acceptButton.Instance.Visible = rolled and status ~= "Completed" and not active and def.Giver == nil
		rerollButton.Instance.Visible = def.Kind == "Daily" and status == "Active"
		rerollButton:SetEnabled(State.RerollsLeft() > 0)
		abandonButton.Instance.Visible = active and def.Kind ~= "Main" and def.Kind ~= "Tutorial"
		actions.Visible = trackButton.Instance.Visible or acceptButton.Instance.Visible or rerollButton.Instance.Visible or abandonButton.Instance.Visible
	end

	local function refreshInfo(tab: string)
		local timed = tab == "Daily" or tab == "Weekly"
		info.Visible = timed
		list.Instance.Position = UDim2.fromOffset(0, if timed then 48 else 0)
		list.Instance.Size = UDim2.new(1, 0, 1, if timed then -48 else 0)
		if timed then
			local seconds = nextReset(tab == "Weekly") - Workspace:GetServerTimeNow()
			resetLabel.Text = Strings.Format(Q.ResetsIn, { time = QuestText.Countdown(seconds) })
			rerollLabel.Visible = tab == "Daily"
			rerollLabel.Text = Strings.Format(Q.RerollsLeft, { count = State.RerollsLeft() })
		end
	end

	local function fillRow(row: Row, id: string, order: number)
		local def = Quests.Get(id)
		if not def then
			return
		end
		local status = State.Status(id)
		local selected = selectedByTab[tabBar:GetSelected()] == id
		local color = QuestText.KindColor(def.Kind)
		row.QuestId = id
		row.Button.Visible = true
		row.Button.LayoutOrder = order
		row.Name.Text = QuestText.QuestName(id)
		row.Name.TextColor3 = if status == "Completed" then C.TextMuted else C.Text
		row.Accent.BackgroundColor3 = if status == "Completed" then C.TextDim else color
		local level = Strings.Format(Q.Level, { level = def.Level })
		local progress = ""
		if status == "Ready" then
			progress = `<font color="#{QT.Ready:ToHex()}">{Q.Ready}</font>`
		elseif status == "Completed" then
			progress = `<font color="#{QT.Done:ToHex()}">{Q.Completed}</font>`
		elseif status == "Active" then
			local index = State.CurrentObjective(id)
			if index then
				local done, needed = State.Progress(id, index)
				progress = Strings.Format(Q.Progress, { done = done, total = needed })
			end
		end
		row.Meta.Text = if progress ~= "" then `{level}  ·  {progress}` else level
		-- Right icon: tracked mark, a tick when completed, nothing otherwise.
		local tracked = State.Tracked() == id
		row.Icon.Visible = tracked or status == "Completed" or status == "Ready"
		Icons.Apply(row.Icon, if status == "Completed" then "Check" else "Mark")
		row.Icon.ImageColor3 = if status == "Completed" then QT.Done elseif status == "Ready" then QT.Ready else C.Aqua
		row.Button.BackgroundColor3 = if selected then C.PanelHover else C.PanelRaised
		row.Button.BackgroundTransparency = if selected then 0.05 else 0.35
		row.Stroke.Color = if selected then C.Aqua else C.Edge
		row.Stroke.Transparency = if selected then 0.1 else 0.5
	end

	local function refresh()
		if not isOpen then
			return
		end
		local tab = tabBar:GetSelected()
		local isAchievements = tab == "Achievements"
		questView.Visible = not isAchievements
		achievements.Root.Visible = isAchievements
		if isAchievements then
			achievements.Refresh()
			return
		end
		refreshInfo(tab)

		-- Sections: in progress, then completed (dailies / weeklies: today's roll in order).
		type Section = { Title: string, Ids: { string } }
		local sections: { Section } = {}
		if tab == "Daily" or tab == "Weekly" then
			local rolled = State.Rolled(if tab == "Daily" then "Dailies" else "Weeklies")
			for _, id in State.ActiveIds() do
				local def = Quests.Get(id)
				if def and def.Kind == tab and not table.find(rolled, id) then
					table.insert(rolled, id)
				end
			end
			local title: string = Q.Tabs[tab] or tab
			table.insert(sections, { Title = title, Ids = rolled })
		else
			local active: { string } = {}
			for _, id in State.ActiveIds() do
				if tabFor(id) == tab then
					table.insert(active, id)
				end
			end
			local completed = State.CompletedIds(tab)
			if tab == "Main" then
				for _, id in State.CompletedIds("Tutorial") do
					table.insert(completed, id)
				end
			end
			table.insert(sections, { Title = Q.InProgress, Ids = active })
			table.insert(sections, { Title = Q.Completed, Ids = completed })
		end

		local order = 0
		local rowIndex = 0
		local headerIndex = 0
		local firstId: string? = nil
		local present: { [string]: boolean } = {}
		for _, sectionData in sections do
			if #sectionData.Ids == 0 then
				continue
			end
			headerIndex += 1
			order += 1
			local label = getHeader(headerIndex)
			label.Text = string.upper(sectionData.Title)
			label.LayoutOrder = order
			label.Visible = true
			for _, id in sectionData.Ids do
				rowIndex += 1
				order += 1
				fillRow(getRow(rowIndex), id, order)
				present[id] = true
				firstId = firstId or id
			end
		end
		for index = rowIndex + 1, #rows do
			rows[index].Button.Visible = false
			rows[index].QuestId = nil
		end
		for index = headerIndex + 1, #headers do
			headers[index].Visible = false
		end
		emptyLabel.Visible = rowIndex == 0
		emptyLabel.Position = UDim2.fromOffset(0, if info.Visible then 56 else 8)

		local selected: string? = selectedByTab[tab]
		if not (selected and present[selected]) then
			selected = firstId
			if selected then
				selectedByTab[tab] = selected
				-- The rows were painted before the selection moved: repaint them.
				for _, row in rows do
					local id = row.QuestId
					if id and row.Button.Visible then
						fillRow(row, id, row.Button.LayoutOrder)
					end
				end
			end
		end
		renderDetail(selected)
	end

	function selectQuest(id: string)
		local tab = tabBar:GetSelected()
		if selectedByTab[tab] == id then
			return
		end
		selectedByTab[tab] = id
		refresh()
	end

	local function focus(id: string)
		local tab = tabFor(id)
		tabBar:SetSelected(tab, true)
		selectedByTab[tab] = id
		refresh()
	end
	focusHandler = focus
	maid:Add(function()
		if focusHandler == focus then
			focusHandler = nil
		end
	end)

	maid:Add(tabBar.Changed:Connect(function()
		refresh()
	end))
	maid:Add(DataController.Changed:Connect(function(path: { string })
		local root = path[1]
		if root == "Quests" or root == "Achievements" or root == "PlayStats" or root == "Level" then
			refresh()
		end
	end))

	-- Reset countdowns tick once a second while the page is open.
	maid:Add(task.spawn(function()
		while true do
			task.wait(1)
			if isOpen then
				local tab = tabBar:GetSelected()
				if tab == "Daily" or tab == "Weekly" then
					refreshInfo(tab)
				end
			end
		end
	end))

	return {
		TabBar = tabBar,
		OnOpen = function()
			isOpen = true
			local request = pendingFocus
			pendingFocus = nil
			if request then
				focus(request)
			else
				refresh()
			end
		end,
		OnClose = function()
			isOpen = false
		end,
	}
end

-- Opens the log on a quest (from the tracker or a toast).
function Log.Open(questId: string?)
	if UIController.GetOpen() == Log.MenuId then
		local handler = focusHandler
		if questId and handler then
			handler(questId)
		end
		return
	end
	pendingFocus = questId
	UIController.Open(Log.MenuId)
end

return Log
