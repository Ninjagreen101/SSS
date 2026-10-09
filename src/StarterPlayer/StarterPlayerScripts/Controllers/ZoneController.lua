--!strict
-- ZoneController: the zone title card. Entering a new area fades in its name
-- in the display serif with a subtitle (Safe Haven / Wild Zone, level range,
-- Current Pressure) and a teal rule, then fades out.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Theme = require(Shared.UI.Theme)
local Components = require(Shared.UI.Components)
local Strings = require(Shared.Strings)
local Config = require(Shared.Config)

local ZoneController = {}

local gui: ScreenGui
local title: TextLabel
local subtitle: TextLabel
local rule: Frame
local token = 0
local lastZone: string? = nil

local function show(nameKey: string, kind: string, minL: number?, maxL: number?, pressure: number?)
	token += 1
	local my = token
	title.Text = Strings.get(nameKey)
	local parts = { Strings.get("Zone.Kind." .. kind) }
	if minL and maxL and kind ~= "Town" then
		table.insert(parts, Strings.get("Zone.Levels", minL, maxL))
	end
	if pressure then
		table.insert(parts, Strings.get("Zone.Pressure", pressure))
	end
	subtitle.Text = table.concat(parts, "  ·  ")
	subtitle.TextColor3 = if kind == "Town" then Theme.Colors.Current elseif kind == "Arena" then Theme.Colors.Danger else Theme.Colors.Gold
	local open = Theme.Tween.Fade
	TweenService:Create(title, open, { TextTransparency = 0, TextStrokeTransparency = 0.5 }):Play()
	TweenService:Create(subtitle, open, { TextTransparency = 0 }):Play()
	rule.Size = UDim2.new(0, 0, 0, 2)
	TweenService:Create(rule, Theme.Tween.Slow, { Size = UDim2.new(0.28, 0, 0, 2), BackgroundTransparency = 0.2 }):Play()
	task.delay(Config.World.Zones.BannerSeconds, function()
		if my ~= token then
			return
		end
		TweenService:Create(title, open, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		TweenService:Create(subtitle, open, { TextTransparency = 1 }):Play()
		TweenService:Create(rule, open, { BackgroundTransparency = 1 }):Play()
	end)
end

function ZoneController.Init()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui = Components.screen("ZoneBanner", playerGui, 15)
	title = Components.label({
		name = "Title",
		text = "",
		font = Theme.Fonts.Display,
		size = Theme.TextSize.Banner,
		frame = UDim2.new(0.9, 0, 0, 56),
		position = UDim2.fromScale(0.5, 0.16),
		anchor = Vector2.new(0.5, 0.5),
		alignX = Enum.TextXAlignment.Center,
		parent = gui,
	})
	title.TextTransparency = 1
	title.TextStrokeColor3 = Theme.Colors.Shadow
	title.TextStrokeTransparency = 1
	rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.AnchorPoint = Vector2.new(0.5, 0.5)
	rule.Position = UDim2.new(0.5, 0, 0.16, 34)
	rule.BackgroundColor3 = Theme.Colors.Current
	rule.BackgroundTransparency = 1
	rule.BorderSizePixel = 0
	rule.Parent = gui
	local grad = Instance.new("UIGradient")
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	grad.Parent = rule
	subtitle = Components.label({
		name = "Subtitle",
		text = "",
		font = Theme.Fonts.BodyBold,
		size = Theme.TextSize.Body,
		frame = UDim2.new(0.9, 0, 0, 24),
		position = UDim2.new(0.5, 0, 0.16, 52),
		anchor = Vector2.new(0.5, 0.5),
		alignX = Enum.TextXAlignment.Center,
		parent = gui,
	})
	subtitle.TextTransparency = 1
end

function ZoneController.Start()
	local player = Players.LocalPlayer
	local function update()
		local zone = player:GetAttribute("Zone")
		local nameKey = player:GetAttribute("ZoneName")
		if type(zone) ~= "string" or type(nameKey) ~= "string" or zone == lastZone then
			return
		end
		lastZone = zone
		show(
			nameKey,
			(player:GetAttribute("ZoneKind") :: string?) or "Wild",
			player:GetAttribute("ZoneLevelMin") :: number?,
			player:GetAttribute("ZoneLevelMax") :: number?,
			player:GetAttribute("Pressure") :: number?
		)
	end
	player:GetAttributeChangedSignal("ZoneName"):Connect(update)
	update()
end

return ZoneController
