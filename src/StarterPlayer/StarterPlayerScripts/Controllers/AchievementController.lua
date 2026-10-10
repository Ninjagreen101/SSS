--!strict
--[[
	AchievementController
	- Unlocks (AchievementUnlocked remote): a big gold banner with the name, what it was for and
	  its Shards, plus a toast when it also grants a title.
	- The Achievements tab of the Quest Log (BuildPanel): every achievement in order, unlocked ones
	  lit gold, progress bars where the profile knows the count (PlayStats fields, level), hidden
	  ones masked until unlocked.
	- The title picker in the Character sheet (CreateTitlePicker): choose which unlocked title shows
	  under your name (RequestSetTitle; the server writes the player attribute Title).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Strings = require(Shared.Strings)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)
local Achievements = require(Shared.Data.Achievements)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Icons = require(UI.Icons)
local UISound = require(UI.UISound)
local Motion = require(UI.Motion)
local Device = require(UI.Device)
local Banner = require(UI.Banner)
local QuestText = require(UI.QuestText)
local Components = require(UI.Components)

local DataController = require(script.Parent.DataController)

local A = Attributes.Names
local C = UITheme.Colors
local Q = Strings.QuestUI
local GOLD = UITheme.Banner.Gold
local player = Players.LocalPlayer

export type Panel = {
	Root: Frame,
	Refresh: () -> (),
}

local AchievementController = {}

-- Fired when an achievement unlocks this session: (achievementId).
AchievementController.Unlocked = Signal.new() :: Signal.Signal<string>

-- STATE ------------------------------------------------------------------------------------

function AchievementController.IsUnlocked(id: string): boolean
	local value = DataController.Get({ "Achievements", id })
	return value ~= nil and value ~= false
end

-- (current, needed) where the profile knows the count; nil otherwise.
function AchievementController.Progress(id: string): (number?, number)
	local def = Achievements.Get(id)
	if not def then
		return nil, 1
	end
	if def.Event == "LevelUp" then
		local level = DataController.Get({ "Level" })
		return if type(level) == "number" then math.min(level, def.Count) else nil, def.Count
	end
	local stat = def.Stat
	if stat then
		local value = DataController.Get({ "PlayStats", stat })
		return if type(value) == "number" then math.min(value, def.Count) else nil, def.Count
	end
	return nil, def.Count
end

-- Unlocked achievement ids that grant a title, in display order.
function AchievementController.UnlockedTitles(): { string }
	local out: { string } = {}
	for _, id in Achievements.Ordered() do
		local def = Achievements.Get(id)
		if def and def.Title and AchievementController.IsUnlocked(id) then
			table.insert(out, id)
		end
	end
	return out
end

-- The achievement id whose title the local player shows ("" = none).
function AchievementController.CurrentTitle(): string
	return QuestText.TitleId(player:GetAttribute(A.Title))
end

-- UNLOCK FEEDBACK --------------------------------------------------------------------------

local function onUnlocked(id: any)
	if type(id) ~= "string" then
		return
	end
	local def = Achievements.Get(id)
	local description = QuestText.AchievementDescription(id)
	local shards = if def and def.Shards > 0 then Strings.Format(Q.AchievementReward, { shards = def.Shards }) else ""
	local subtitle = if description ~= "" and shards ~= "" then `{description}  ·  {shards}` else description .. shards
	UISound.Play("LegendaryLoot")
	task.delay(0.18, function()
		UISound.Play("LevelUpHigh")
	end)
	Banner.Show({
		Eyebrow = Q.AchievementUnlocked,
		Title = QuestText.AchievementName(id),
		Subtitle = subtitle,
		Color = GOLD,
	})
	if def and def.Title then
		Components.Toast.Push({
			Title = Strings.Format(Q.TitleUnlocked, { title = QuestText.Title(id) }),
			Body = Q.TitlePick,
			Color = GOLD,
			Icon = "Level",
			Duration = 6,
		})
	end
	AchievementController.Unlocked:Fire(id)
end

-- ACHIEVEMENTS TAB -------------------------------------------------------------------------

type Card = {
	Frame: Frame,
	Stroke: UIStroke,
	Badge: Frame,
	BadgeIcon: ImageLabel,
	Name: TextLabel,
	Description: TextLabel,
	Reward: TextLabel,
	Bar: Components.ProgressBar,
	Count: TextLabel,
}

function AchievementController.BuildPanel(parent: Instance, maid: Maid.Maid): Panel
	local root: Frame = Create.new("Frame", {
		Name = "Achievements",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = parent,
	})

	-- Summary: "7 / 22 unlocked" and a gold bar.
	local header: Frame = Create.new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), Parent = root })
	local summary = Create.Label({
		Text = "",
		Font = UITheme.Fonts.TitleMedium,
		TextSize = UITheme.TextSize.BodyLarge,
		Color = GOLD,
		Size = UDim2.new(0.4, 0, 0, 24),
		Parent = header,
	})
	local totalBar = Components.ProgressBar.new({
		Name = "Total",
		Color = GOLD,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 9),
		Size = UDim2.new(0.55, 0, 0, 6),
		Parent = header,
	})
	maid:Add(totalBar)

	local list = Components.ScrollList.new({
		Name = "List",
		Position = UDim2.fromOffset(0, 46),
		Size = UDim2.new(1, 0, 1, -46),
		Grid = {
			CellSize = UDim2.new(0.5, -6, 0, 104),
			CellPadding = UDim2.fromOffset(10, 10),
		},
		Parent = root,
	})
	maid:Add(list)
	local function applyColumns()
		local grid = list.Instance:FindFirstChildOfClass("UIGridLayout")
		if grid then
			local narrow = Device.IsTouch() and root.AbsoluteSize.X < 640
			grid.CellSize = if narrow then UDim2.new(1, -6, 0, 104) else UDim2.new(0.5, -6, 0, 104)
		end
	end
	maid:Add(root:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyColumns))
	applyColumns()

	local cards: { [string]: Card } = {}

	local function card(id: string, order: number): Card
		local existing = cards[id]
		if existing then
			return existing
		end
		local frame: Frame = Create.new("Frame", {
			Name = id,
			BackgroundColor3 = C.PanelRaised,
			BackgroundTransparency = 0.25,
			LayoutOrder = order,
			Selectable = true,
			SelectionImageObject = Create.SelectionImage(),
		})
		Create.Corner(frame)
		local stroke = Create.Stroke(frame, C.Edge, 1.2, 0.3)
		Create.PanelGradient(frame)
		local badge: Frame = Create.new("Frame", {
			Name = "Badge",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 12, 0.5, 0),
			Size = UDim2.fromOffset(52, 52),
			BackgroundColor3 = C.PanelSunken,
			Parent = frame,
		})
		Create.Corner(badge, UITheme.CornerPill)
		local badgeIcon = Icons.new("Lock", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(26, 26),
			Color = C.TextDim,
			Parent = badge,
		})
		local x = 76
		local name = Create.Label({
			Name = "Name",
			Text = "",
			Font = UITheme.Fonts.BodyBold,
			TextSize = UITheme.TextSize.Body,
			Position = UDim2.fromOffset(x, 10),
			Size = UDim2.new(1, -x - 10, 0, 20),
			Parent = frame,
		})
		name.TextTruncate = Enum.TextTruncate.AtEnd
		local description = Create.Label({
			Name = "Description",
			Text = "",
			TextSize = UITheme.TextSize.Caption,
			Color = C.TextMuted,
			Wrapped = true,
			YAlignment = Enum.TextYAlignment.Top,
			Position = UDim2.fromOffset(x, 32),
			Size = UDim2.new(1, -x - 10, 0, 34),
			Parent = frame,
		})
		local reward = Create.Label({
			Name = "Reward",
			Text = "",
			Font = UITheme.Fonts.BodyMedium,
			TextSize = UITheme.TextSize.Caption,
			Color = GOLD,
			RichText = true,
			Position = UDim2.fromOffset(x, 72),
			Size = UDim2.new(0.6, -x, 0, 18),
			Parent = frame,
		})
		local bar = Components.ProgressBar.new({
			Name = "Progress",
			Color = C.Aqua,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -12, 0, 86),
			Size = UDim2.new(0.4, -12, 0, 5),
			Parent = frame,
		})
		maid:Add(bar)
		local count = Create.Label({
			Name = "Count",
			Text = "",
			Font = UITheme.Fonts.Numbers,
			TextSize = UITheme.TextSize.Caption,
			Color = C.TextMuted,
			XAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -12, 0, 66),
			Size = UDim2.new(0.4, -12, 0, 16),
			Parent = frame,
		})
		local built: Card = {
			Frame = frame,
			Stroke = stroke,
			Badge = badge,
			BadgeIcon = badgeIcon,
			Name = name,
			Description = description,
			Reward = reward,
			Bar = bar,
			Count = count,
		}
		cards[id] = built
		list:Add(frame)
		return built
	end

	local function refresh()
		local ordered = Achievements.Ordered()
		local done, total = 0, 0
		for order, id in ordered do
			local def = Achievements.Get(id)
			if not def then
				continue
			end
			local unlocked = AchievementController.IsUnlocked(id)
			total += 1
			if unlocked then
				done += 1
			end
			local view = card(id, order)
			local hidden = def.Hidden == true and not unlocked
			view.Frame.Visible = true
			view.Name.Text = if hidden then Q.Hidden else QuestText.AchievementName(id)
			view.Name.TextColor3 = if unlocked then GOLD elseif hidden then C.TextDim else C.Text
			view.Description.Text = if hidden then "" else QuestText.AchievementDescription(id)
			view.Stroke.Color = if unlocked then GOLD else C.Edge
			view.Stroke.Transparency = if unlocked then 0.25 else 0.3
			view.Frame.BackgroundTransparency = if unlocked then 0.15 else 0.35
			Icons.Apply(view.BadgeIcon, if unlocked then "Check" else "Lock")
			view.BadgeIcon.ImageColor3 = if unlocked then GOLD else C.TextDim
			view.Badge.BackgroundColor3 = if unlocked then C.PanelHover else C.PanelSunken
			local parts: { string } = {}
			if def.Shards > 0 then
				table.insert(parts, Strings.Format(Q.AchievementReward, { shards = def.Shards }))
			end
			if def.Title and not hidden then
				table.insert(parts, Strings.Format(Q.TitleReward, { title = QuestText.Title(id) }))
			end
			view.Reward.Text = table.concat(parts, "  ·  ")
			local current, needed = AchievementController.Progress(id)
			local showBar = not unlocked and not hidden and current ~= nil and needed > 1
			view.Bar.Instance.Visible = showBar
			if showBar and current then
				view.Bar:SetValue(current, needed, true)
				view.Count.Text = Strings.Format(Q.Progress, { done = current, total = needed })
			else
				view.Count.Text = if unlocked then Q.Unlocked else ""
			end
			view.Count.TextColor3 = if unlocked then GOLD else C.TextMuted
		end
		summary.Text = Strings.Format(Q.AchievementsSummary, { done = done, total = total })
		totalBar:SetValue(done, math.max(total, 1), true)
	end

	return {
		Root = root,
		Refresh = refresh,
	}
end

-- TITLE PICKER -----------------------------------------------------------------------------

export type TitlePickerProps = {
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Size: UDim2?,
	ZIndex: number?,
	Parent: Instance,
}

-- A gold "Title" button that opens a list of unlocked titles.
function AchievementController.CreateTitlePicker(props: TitlePickerProps, maid: Maid.Maid): TextButton
	local button: TextButton = Create.new("TextButton", {
		Name = "TitlePicker",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.PanelRaised,
		BackgroundTransparency = 0.25,
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		Position = props.Position or UDim2.new(),
		Size = props.Size or UDim2.fromOffset(220, UITheme.Size.MinTouchTarget),
		ZIndex = props.ZIndex or 3,
		SelectionImageObject = Create.SelectionImage(),
		Parent = props.Parent,
	})
	maid:Add(button)
	Create.Corner(button)
	Create.Stroke(button, GOLD, 1, 0.45)
	local caption = Create.Label({
		Name = "Caption",
		Text = string.upper(Q.TitlePick),
		Font = UITheme.Fonts.BodyBold,
		TextSize = 11,
		Color = C.TextDim,
		XAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 4),
		Size = UDim2.new(1, 0, 0, 13),
		Parent = button,
	})
	caption.ZIndex = button.ZIndex + 1
	local value = Create.Label({
		Name = "Value",
		Text = "",
		Font = UITheme.Fonts.Display,
		TextSize = UITheme.TextSize.Small,
		Color = GOLD,
		XAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(6, 17),
		Size = UDim2.new(1, -12, 0, 22),
		Parent = button,
	})
	value.ZIndex = button.ZIndex + 1
	value.TextTruncate = Enum.TextTruncate.AtEnd
	maid:Add(Motion.AttachButtonFeedback(button))

	local function refresh()
		local current = AchievementController.CurrentTitle()
		value.Text = if current ~= "" then QuestText.Title(current) else Q.TitleNone
		value.TextColor3 = if current ~= "" then GOLD else C.TextMuted
	end
	refresh()
	maid:Add(player:GetAttributeChangedSignal(A.Title):Connect(refresh))

	local function choose(id: string)
		UISound.Play("UIConfirm")
		Net.FireServer("RequestSetTitle", id)
	end

	maid:Add(button.Activated:Connect(function()
		UISound.Play("UIClick")
		local current = AchievementController.CurrentTitle()
		local options: { Components.ContextOption } = {
			{
				Text = Q.TitleNone,
				Enabled = current ~= "",
				OnSelect = function()
					choose("")
				end,
			},
		}
		for _, id in AchievementController.UnlockedTitles() do
			table.insert(options, {
				Text = QuestText.Title(id),
				Enabled = id ~= current,
				OnSelect = function()
					choose(id)
				end,
			})
		end
		Components.ContextMenu.Show({
			Title = Q.TitlePick,
			TitleColor = GOLD,
			Options = options,
			Anchor = button,
		})
	end))
	return button
end

-- LIFECYCLE --------------------------------------------------------------------------------

function AchievementController.Init()
	Net.OnClient("AchievementUnlocked", onUnlocked)
end

return AchievementController
