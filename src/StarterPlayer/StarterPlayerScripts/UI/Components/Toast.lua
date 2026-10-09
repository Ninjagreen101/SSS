--!strict
--[[
	Toast
	Notification feed (level ups, item pickups, quest updates, achievements).
	Toasts slide in from the right, stack bottom-up, merge when they share a
	Key (item pickups add to the count), and fade out after their duration.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local UISound = require(UI.UISound)
local ItemIcon = require(UI.ItemIcon)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Maid = require(Shared.Util.Maid)
local TweenUtil = require(Shared.Util.TweenUtil)

export type ToastData = {
	Title: string,
	Body: string?,
	Color: Color3?,
	Icon: string?,
	Item: string?, -- item DefId: shows a 3D render of the item on the left
	ItemRarity: string?,
	Duration: number?,
	Key: string?, -- toasts with the same key merge
	Count: number?,
	Silent: boolean?,
}

type Entry = {
	Key: string?,
	Count: number,
	Title: string,
	Group: CanvasGroup,
	TitleLabel: TextLabel,
	Maid: Maid.Maid,
	ExpiresAt: number,
	Closing: boolean,
}

local MAX_VISIBLE = 5

local ICON_SIZE = 36

local Toast = {}

local feed: Frame? = nil
local entries: { Entry } = {}
local orderCounter = 0
local bottomOffset = 24

local function getFeed(): Frame
	if feed and feed.Parent then
		return feed
	end
	local frame: Frame = Create.new("Frame", {
		Name = "ToastFeed",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -bottomOffset),
		Size = UDim2.fromOffset(UITheme.Size.ToastWidth, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = Layers.Get("Overlay"),
	})
	local list = Create.List(frame, Enum.FillDirection.Vertical, UITheme.Padding.Small)
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	feed = frame
	return frame
end

local function titleText(entry: Entry): string
	if entry.Count > 1 then
		return `{entry.Title}  <font color="#A9A59C">x{entry.Count}</font>`
	end
	return entry.Title
end

local function close(entry: Entry)
	if entry.Closing then
		return
	end
	entry.Closing = true
	local index = table.find(entries, entry)
	if index then
		table.remove(entries, index)
	end
	task.spawn(function()
		local tween = TweenUtil.Play(entry.Group, UITheme.Motion.ToastTime, { GroupTransparency = 1 })
		TweenUtil.Await(tween)
		entry.Maid:Clean()
	end)
end

local function schedule(entry: Entry, duration: number)
	entry.ExpiresAt = os.clock() + duration
	entry.Maid:Set("expire", task.delay(duration, function()
		if os.clock() >= entry.ExpiresAt - 0.01 then
			close(entry)
		end
	end))
end

function Toast.Push(data: ToastData)
	local duration = data.Duration or UITheme.Motion.ToastDuration
	local addCount = data.Count or 1

	-- Merge with a visible toast that has the same key.
	if data.Key then
		for _, entry in entries do
			if entry.Key == data.Key and not entry.Closing then
				entry.Count += addCount
				entry.TitleLabel.Text = titleText(entry)
				schedule(entry, duration)
				return
			end
		end
	end

	local parent = getFeed()
	local maid = Maid.new()
	orderCounter += 1
	local accent = data.Color or UITheme.Colors.Current

	local group: CanvasGroup = Create.new("CanvasGroup", {
		Name = "Toast",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		GroupTransparency = 1,
		LayoutOrder = orderCounter,
	})
	maid:Add(group)

	local card: Frame = Create.new("Frame", {
		Name = "Card",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.fromOffset(40, 0),
		Parent = group,
	})
	Create.ApplyPanelStyle(card, { Glow = false, Transparency = 0.08 })

	-- Accent bar pinned to the left edge of the card.
	local bar: Frame = Create.new("Frame", {
		Name = "Accent",
		BackgroundColor3 = accent,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(0, 3, 1, 0),
		Parent = card,
	})
	Create.Corner(bar, UDim.new(0, 2))

	local inner: Frame = Create.new("Frame", {
		Name = "Inner",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = card,
	})
	if data.Item then
		local icon = ItemIcon.new({
			Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE),
			Position = UDim2.new(0, 10, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			Parent = card,
		})
		icon:Set(data.Item, data.ItemRarity)
	end
	Create.new("UIPadding", {
		PaddingLeft = UDim.new(0, if data.Item then 16 + ICON_SIZE + 6 else 16),
		PaddingRight = UDim.new(0, 12),
		PaddingTop = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 10),
		Parent = inner,
	})
	Create.List(inner, Enum.FillDirection.Vertical, 2)

	local entry: Entry = {
		Key = data.Key,
		Count = addCount,
		Title = data.Title,
		Group = group,
		TitleLabel = nil :: any,
		Maid = maid,
		ExpiresAt = 0,
		Closing = false,
	}

	entry.TitleLabel = Create.Label({
		Name = "Title",
		Text = titleText(entry),
		Font = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.Body,
		Color = accent,
		RichText = true,
		Wrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		LayoutOrder = 1,
		Parent = inner,
	})
	if data.Body then
		Create.Label({
			Name = "Body",
			Text = data.Body,
			TextSize = UITheme.TextSize.Small,
			Color = UITheme.Colors.TextMuted,
			Wrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = 2,
			Parent = inner,
		})
	end

	group.Parent = parent
	table.insert(entries, entry)
	TweenUtil.Play(group, UITheme.Motion.ToastTime, { GroupTransparency = 0 })
	TweenUtil.Play(card, UITheme.Motion.ToastTime, { Position = UDim2.fromOffset(0, 0) }, Enum.EasingStyle.Back)
	if not data.Silent then
		UISound.Play("UIToast")
	end
	schedule(entry, duration)

	while #entries > MAX_VISIBLE do
		close(entries[1])
	end
end

-- Lifts the feed above on-screen touch controls when needed.
function Toast.SetBottomOffset(offset: number)
	bottomOffset = offset
	if feed then
		feed.Position = UDim2.new(1, -16, 1, -offset)
	end
end

function Toast.Clear()
	for index = #entries, 1, -1 do
		close(entries[index])
	end
end

return Toast
