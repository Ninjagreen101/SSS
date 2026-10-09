--!strict
-- WorldFeedbackController: toasts and centre cards for world events —
-- Waystone attunement and travel, treasure finds (gold and items in rarity
-- colour), healing pools, dungeon countdowns and progress, and errors.
-- Toasts stack in a feed at the bottom right; centre cards fade in and out.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Theme = require(Shared.UI.Theme)
local Components = require(Shared.UI.Components)
local Strings = require(Shared.Strings)
local Items = require(Shared.Data.Items)
local Net = require(Shared.Net)

local WorldFeedbackController = {}

-- chests this player has already emptied: their prompts are hidden locally
local openedChests: { [string]: boolean } = {}

local function refreshChest(marker: Instance)
	local id = marker:GetAttribute("MarkerId")
	if type(id) ~= "string" then
		return
	end
	local prompt = marker:FindFirstChildOfClass("ProximityPrompt") or marker:WaitForChild("ProximityPrompt", 5)
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt.Enabled = not openedChests[id]
	end
end

local function refreshAllChests()
	for _, m in CollectionService:GetTagged("TreasureChest") do
		task.spawn(refreshChest, m)
	end
end

local gui: ScreenGui
local feed: Frame
local centre: TextLabel
local centreToken = 0
local MAX_TOASTS = 5

local KIND_COLORS: { [string]: Color3 } = {
	Waystone = Theme.Colors.Current,
	Travel = Theme.Colors.Current,
	Error = Theme.Colors.Danger,
	Heal = Theme.Colors.Success,
	Info = Theme.Colors.TextDim,
	Event = Theme.Colors.Gold,
	Loot = Theme.Colors.Gold,
}

function WorldFeedbackController.toast(text: string, accent: Color3, duration: number?)
	local card = Instance.new("Frame")
	card.Name = "Toast"
	card.Size = UDim2.new(1, 0, 0, 44)
	card.BackgroundColor3 = Theme.Colors.Background
	card.BackgroundTransparency = 1
	card.LayoutOrder = -os.clock() * 1000
	local c = Instance.new("UICorner")
	c.CornerRadius = Theme.CornerSmall
	c.Parent = card
	local s = Instance.new("UIStroke")
	s.Color = Theme.Colors.Border
	s.Transparency = 1
	s.Thickness = Theme.Stroke
	s.Parent = card
	local bar = Instance.new("Frame")
	bar.Name = "Accent"
	bar.Size = UDim2.new(0, 4, 1, -12)
	bar.Position = UDim2.fromOffset(8, 6)
	bar.BackgroundColor3 = accent
	bar.BorderSizePixel = 0
	bar.BackgroundTransparency = 1
	bar.Parent = card
	local label = Components.label({
		name = "Text",
		text = text,
		frame = UDim2.new(1, -28, 1, 0),
		position = UDim2.fromOffset(20, 0),
		font = Theme.Fonts.BodyBold,
		size = Theme.TextSize.Body,
		parent = card,
	})
	label.TextTransparency = 1
	card.Parent = feed
	local fadeIn = Theme.Tween.Open
	TweenService:Create(card, fadeIn, { BackgroundTransparency = Theme.Colors.BackgroundTransparency }):Play()
	TweenService:Create(s, fadeIn, { Transparency = Theme.Colors.BorderTransparency }):Play()
	TweenService:Create(bar, fadeIn, { BackgroundTransparency = 0 }):Play()
	TweenService:Create(label, fadeIn, { TextTransparency = 0 }):Play()
	-- keep the feed short
	local toasts = {}
	for _, ch in feed:GetChildren() do
		if ch:IsA("Frame") then
			table.insert(toasts, ch)
		end
	end
	if #toasts > MAX_TOASTS then
		table.sort(toasts, function(a: Frame, b: Frame): boolean
			return a.LayoutOrder > b.LayoutOrder
		end)
		toasts[1]:Destroy()
	end
	task.delay(duration or 4, function()
		if not card.Parent then
			return
		end
		local out = Theme.Tween.Fade
		TweenService:Create(card, out, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(s, out, { Transparency = 1 }):Play()
		TweenService:Create(bar, out, { BackgroundTransparency = 1 }):Play()
		local t = TweenService:Create(label, out, { TextTransparency = 1 })
		t.Completed:Once(function()
			card:Destroy()
		end)
		t:Play()
	end)
end

function WorldFeedbackController.centre(text: string, color: Color3, duration: number)
	centreToken += 1
	local token = centreToken
	centre.Text = text
	centre.TextColor3 = color
	TweenService:Create(centre, Theme.Tween.Open, { TextTransparency = 0, TextStrokeTransparency = 0.6 }):Play()
	task.delay(duration, function()
		if token == centreToken then
			TweenService:Create(centre, Theme.Tween.Fade, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		end
	end)
end

local function format(key: string, args: { any }?): string
	if args and #args > 0 then
		return Strings.get(key, table.unpack(args))
	end
	return Strings.get(key)
end

function WorldFeedbackController.Init()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui = Components.screen("WorldFeedback", playerGui, 20)
	local f = Instance.new("Frame")
	f.Name = "Feed"
	f.AnchorPoint = Vector2.new(1, 1)
	f.Position = UDim2.new(1, -24, 1, -150)
	f.Size = UDim2.fromOffset(340, 300)
	f.BackgroundTransparency = 1
	f.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.Padding = UDim.new(0, 6)
	layout.Parent = f
	feed = f
	centre = Components.label({
		name = "Centre",
		text = "",
		font = Theme.Fonts.Display,
		size = Theme.TextSize.Title,
		frame = UDim2.new(0.8, 0, 0, 40),
		position = UDim2.fromScale(0.5, 0.3),
		anchor = Vector2.new(0.5, 0.5),
		alignX = Enum.TextXAlignment.Center,
		parent = gui,
	})
	centre.TextTransparency = 1
	centre.TextStrokeColor3 = Theme.Colors.Shadow
	centre.TextStrokeTransparency = 1
end

function WorldFeedbackController.Start()
	Net.connect("WorldFeedback", function(kind: string, key: string, args: { any }?)
		local text = format(key, args)
		local color = KIND_COLORS[kind] or Theme.Colors.Text
		if kind == "Countdown" or kind == "Event" then
			WorldFeedbackController.centre(text, color, if kind == "Countdown" then 1.1 else 2.6)
		else
			WorldFeedbackController.toast(text, color)
		end
	end)
	CollectionService:GetInstanceAddedSignal("TreasureChest"):Connect(function(m: Instance)
		task.spawn(refreshChest, m)
	end)
	task.spawn(function()
		local ok, state = pcall(Net.invoke, "RequestWorldState")
		if ok and type(state) == "table" and type(state.chests) == "table" then
			for _, id in state.chests do
				openedChests[id] = true
			end
			refreshAllChests()
		end
	end)
	Net.connect("ChestOpened", function(chestId: string, gold: number, items: { { id: string, count: number } })
		openedChests[chestId] = true
		refreshAllChests()
		WorldFeedbackController.centre(Strings.get("Chest.Found"), Theme.Colors.Gold, 2.4)
		if gold > 0 then
			WorldFeedbackController.toast(Strings.get("Chest.Gold", gold), Theme.Colors.Gold)
		end
		for _, it in items do
			local def = Items[it.id]
			local name = if def then def.name else it.id
			local color = if def then (Theme.Rarity :: any)[def.rarity] or Theme.Colors.Text else Theme.Colors.Text
			WorldFeedbackController.toast(string.format("%s  x%d", name, it.count), color, 5)
		end
	end)
end

return WorldFeedbackController
