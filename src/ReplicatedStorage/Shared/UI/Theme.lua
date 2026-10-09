--!strict
-- UITheme: every colour, font, size, radius, stroke and tween timing used by
-- The Spire's interface. Dark-glass fantasy: near-black navy panels with an
-- aged-brass border, off-white text, teal Current accents.

local Theme = {
	Colors = {
		Background = Color3.fromHex("#10141C"),
		BackgroundTransparency = 0.15,
		Surface = Color3.fromHex("#18202C"),
		SurfaceHover = Color3.fromHex("#202A38"),
		Border = Color3.fromHex("#A88A4F"),
		BorderTransparency = 0.6,
		Text = Color3.fromHex("#EDEAE2"),
		TextDim = Color3.fromHex("#A9A69E"),
		Current = Color3.fromHex("#3FE0D0"),
		CurrentDeep = Color3.fromHex("#1A4E8C"),
		Gold = Color3.fromHex("#FFD25A"),
		Danger = Color3.fromHex("#E2483D"),
		Success = Color3.fromHex("#5FD35F"),
		Shadow = Color3.fromHex("#000000"),
	},
	Rarity = {
		Common = Color3.fromHex("#BFBFBF"),
		Uncommon = Color3.fromHex("#5FD35F"),
		Rare = Color3.fromHex("#4FA3FF"),
		Epic = Color3.fromHex("#B36BFF"),
		Legendary = Color3.fromHex("#FFA53A"),
		Mythic = Color3.fromHex("#FF4F6D"),
		SpireForged = Color3.fromHex("#3FE0D0"),
	},
	Fonts = {
		Display = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal),
		DisplayItalic = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Regular, Enum.FontStyle.Italic),
		Body = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium, Enum.FontStyle.Normal),
		BodyBold = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal),
	},
	TextSize = {
		Banner = 46,
		Title = 26,
		Heading = 20,
		Body = 16,
		Small = 13,
		Key = 15,
	},
	Corner = UDim.new(0, 8),
	CornerSmall = UDim.new(0, 6),
	Stroke = 1.5,
	Padding = 12,
	PaddingSmall = 6,
	Touch = 44, -- minimum touch target (px)
	Tween = {
		Open = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		Close = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		Hover = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		Fade = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		Slow = TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
	},
	OpenScale = 0.96,
	HoverScale = 1.04,
	PressScale = 0.96,
	BlurSize = 10,
}

return Theme
