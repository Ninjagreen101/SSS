--!strict
--[[
	Banner
	A big centred card near the top of the screen for moments that deserve more than a toast:
	achievements (gold) and quest completions. One card is built once and reused; banners queue
	and play one after another. Reduced Motion keeps the fade and drops the scale pop.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TweenUtil = require(Shared.Util.TweenUtil)

local UITheme = require(script.Parent.UITheme)
local Create = require(script.Parent.Create)
local Layers = require(script.Parent.Layers)
local Icons = require(script.Parent.Icons)
local Motion = require(script.Parent.Motion)

export type BannerData = {
	Eyebrow: string, -- small caps line above the title ("ACHIEVEMENT UNLOCKED")
	Title: string,
	Subtitle: string?,
	Color: Color3?,
	Duration: number?,
}

type View = {
	Group: CanvasGroup,
	Scale: UIScale,
	Eyebrow: TextLabel,
	Title: TextLabel,
	Subtitle: TextLabel,
	Glow: ImageLabel,
	Rules: { Frame },
	Waves: { ImageLabel },
}

local B = UITheme.Banner

local Banner = {}

local view: View? = nil
local queue: { BannerData } = {}
local playing = false

local function build(): View
	local existing = view
	if existing and existing.Group.Parent then
		return existing
	end
	local group: CanvasGroup = Create.new("CanvasGroup", {
		Name = "Banner",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, B.Top),
		Size = UDim2.fromOffset(B.Width, 120),
		GroupTransparency = 1,
		Visible = false,
		Parent = Layers.Get("Overlay"),
	})
	local scale: UIScale = Create.new("UIScale", { Parent = group })
	local glow = Icons.Fx("Glow", {
		Name = "Glow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 0, 1.6, 0),
		Color = B.Gold,
		Transparency = 0.55,
		Parent = group,
	})
	local card: Frame = Create.new("Frame", {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -60, 0, 96),
		BackgroundColor3 = UITheme.Colors.Midnight,
		BackgroundTransparency = 0.12,
		BorderSizePixel = 0,
		Parent = group,
	})
	Create.Corner(card, UDim.new(0, 10))
	Create.PanelGradient(card)
	local rules: { Frame } = {}
	for index, y in { 0, 1 } do
		local rule: Frame = Create.new("Frame", {
			Name = `Rule{index}`,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, y),
			Position = UDim2.fromScale(0.5, y),
			Size = UDim2.new(0.9, 0, 0, 2),
			BackgroundColor3 = B.Gold,
			Parent = card,
		})
		Create.new("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.5, 0),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = rule,
		})
		table.insert(rules, rule)
	end
	local waves: { ImageLabel } = {}
	for index, side in { -1, 1 } do
		table.insert(waves, Icons.Fx("Wave", {
			Name = `Wave{index}`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, side * 150, 0, 22),
			Size = UDim2.fromOffset(110, 12),
			Rotation = if side < 0 then 0 else 180,
			Color = B.Gold,
			Transparency = 0.35,
			Parent = card,
		}))
	end
	local eyebrow = Create.Label({
		Name = "Eyebrow",
		Text = "",
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Small,
		Color = B.Gold,
		XAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 12),
		Size = UDim2.new(1, 0, 0, 20),
		Parent = card,
	})
	local title = Create.Label({
		Name = "Title",
		Text = "",
		Font = UITheme.Fonts.Display,
		TextSize = UITheme.TextSize.Title,
		Color = UITheme.Colors.Foam,
		XAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 32),
		Size = UDim2.new(1, 0, 0, 36),
		Parent = card,
	})
	title.TextScaled = false
	title.TextTruncate = Enum.TextTruncate.AtEnd
	local subtitle = Create.Label({
		Name = "Subtitle",
		Text = "",
		TextSize = UITheme.TextSize.Small,
		Color = UITheme.Colors.TextMuted,
		XAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 68),
		Size = UDim2.new(1, -24, 0, 20),
		Parent = card,
	})
	subtitle.TextTruncate = Enum.TextTruncate.AtEnd
	local built: View = {
		Group = group,
		Scale = scale,
		Eyebrow = eyebrow,
		Title = title,
		Subtitle = subtitle,
		Glow = glow,
		Rules = rules,
		Waves = waves,
	}
	view = built
	return built
end

local function playNext()
	local data = table.remove(queue, 1)
	if not data then
		playing = false
		return
	end
	playing = true
	local v = build()
	local color = data.Color or B.Gold
	v.Eyebrow.Text = string.upper(data.Eyebrow)
	v.Eyebrow.TextColor3 = color
	v.Title.Text = data.Title
	v.Subtitle.Text = data.Subtitle or ""
	v.Glow.ImageColor3 = color
	for _, rule in v.Rules do
		rule.BackgroundColor3 = color
	end
	for _, wave in v.Waves do
		wave.ImageColor3 = color
	end
	Motion.Open(v.Group, v.Scale)
	task.delay(data.Duration or B.Duration, function()
		local fade = TweenUtil.Play(v.Group, UITheme.Motion.CloseTime * 2, { GroupTransparency = 1 })
		TweenUtil.Await(fade)
		v.Group.Visible = false
		playNext()
	end)
end

function Banner.Show(data: BannerData)
	table.insert(queue, data)
	if not playing then
		playNext()
	end
end

return Banner
