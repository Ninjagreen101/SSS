--!strict
--[[
	UITheme
	The single style guide for every piece of UI (Spec Sections 4 and 12).
	Components and menus read colours, fonts, sizes, radii, strokes, padding
	and motion timings from here; nothing hard-codes a colour or font.
]]

local function hex(value: string): Color3
	return Color3.fromHex(value)
end

local Colors = {
	-- Palette (exact values from the art direction)
	Current = hex("#3FE0D0"),
	CurrentDeep = hex("#1A4E8C"),
	Stone = hex("#6E6A63"),
	StoneShadow = hex("#2B2A28"),
	Wood = hex("#4A3426"),
	Brass = hex("#A88A4F"), -- HUD accents (vitals badge, notches); menus use Edge / Accent
	Danger = hex("#E2483D"),
	Parry = hex("#FFD25A"),
	Text = hex("#E8F1FA"),

	-- Deep-ocean menu palette: midnight navy and ocean blue surfaces, slate
	-- panels, restrained cyan / turquoise / pale-blue highlights.
	Abyss = hex("#030914"), -- full-screen backdrops (Skill Tree)
	Midnight = hex("#061226"), -- window frames
	Panel = hex("#0A1A31"), -- panels
	PanelRaised = hex("#122846"), -- buttons, cards
	PanelHover = hex("#1A3760"),
	PanelSunken = hex("#050F1E"), -- slots, wells, inputs
	Edge = hex("#2A5482"), -- borders
	EdgeBright = hex("#5C9FD6"), -- fine inner borders, selected outlines
	Accent = hex("#8FD8F5"), -- section headings
	Aqua = hex("#5ED3F3"), -- highlights, selected tabs
	Foam = hex("#D6F1FF"), -- brightest highlight (core, selected node)
	TextMuted = hex("#9DB2CA"),
	TextDim = hex("#62809F"),
	TextOnAccent = hex("#04201F"),
	Track = hex("#030A14"),

	-- The in-game HUD keeps its original stone-and-brass surfaces.
	HudPanel = hex("#10141C"),
	HudRaised = hex("#1A2130"),
	HudSunken = hex("#0A0D13"),

	Health = hex("#B3262E"),
	HealthTrail = hex("#F0B2A8"),
	Stamina = hex("#E9C25B"),
	Heal = hex("#6EE07A"),
	Reaction = hex("#C38BFF"),
	Blocked = hex("#9A9A9A"),
	Overlay = hex("#000000"),
}

-- Skill tree branches: complementary water shades (always paired with a
-- label and an icon, so colour is never the only difference).
local Branch: { Color3 } = {
	hex("#4FA8FF"), -- deep-sea blue
	hex("#3FE0D0"), -- turquoise
	hex("#9ADFFF"), -- pale glacier blue
}

local Rarity: { [string]: Color3 } = {
	Common = hex("#BFBFBF"),
	Uncommon = hex("#5FD35F"),
	Rare = hex("#4FA3FF"),
	Epic = hex("#B36BFF"),
	Legendary = hex("#FFA53A"),
	Mythic = hex("#FF4F6D"),
	SpireForged = hex("#3FE0D0"),
}

-- Second colour used by animated rarity gradients.
local RarityAccent: { [string]: Color3 } = {
	Mythic = hex("#FFC36B"),
	SpireForged = hex("#E9FFFD"),
}

local Attunement: { [string]: Color3 } = {
	Tide = hex("#3FE0D0"),
	Rime = hex("#CFEFFF"),
	Tempest = hex("#A274FF"),
	Abyss = hex("#5B4BD6"),
	Bloom = hex("#C3E27A"),
}

local SARPANCH = Font.fromEnum(Enum.Font.Sarpanch).Family

local Fonts = {
	-- Screen titles, tab labels, section headers: a crisp, wide display face.
	Title = Font.new(SARPANCH, Enum.FontWeight.Bold),
	TitleMedium = Font.new(SARPANCH, Enum.FontWeight.SemiBold),
	Display = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Bold),
	DisplayRegular = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Regular),
	Body = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Regular),
	BodyMedium = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium),
	BodyBold = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold),
	Numbers = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold),
}

local TextSize = {
	Caption = 13,
	Small = 15,
	Body = 17,
	BodyLarge = 19,
	Heading = 22,
	Title = 30,
	Hero = 46,
}

local UITheme = {
	Colors = Colors,
	Rarity = Rarity,
	RarityAccent = RarityAccent,
	Attunement = Attunement,
	Branch = Branch,
	Fonts = Fonts,
	TextSize = TextSize,

	PanelTransparency = 0.12, -- 88% opaque
	SunkenTransparency = 0.25,
	OverlayTransparency = 0.45, -- world darkening behind full-screen menus
	BlurSize = 12,

	Corner = UDim.new(0, 8),
	CornerSmall = UDim.new(0, 6),
	CornerPill = UDim.new(0.5, 0),

	Stroke = {
		Thickness = 1.5,
		Color = Colors.Edge,
		Transparency = 0.35,
	},
	InnerGlow = {
		Thickness = 1,
		Color = Colors.Aqua,
		Transparency = 0.86,
	},
	Selection = {
		Thickness = 2,
		Color = Colors.Current,
	},

	Padding = {
		Tiny = 4,
		Small = 8,
		Medium = 12,
		Large = 18,
		Huge = 28,
	},

	Size = {
		ButtonHeight = 42,
		ButtonHeightTouch = 52,
		IconButton = 40,
		Slot = 64,
		TabHeight = 40,
		InputHeight = 38,
		ToastWidth = 300,
		TooltipMaxWidth = 280,
		MinTouchTarget = 44,
	},

	Motion = {
		OpenTime = 0.18,
		CloseTime = 0.12,
		OpenScale = 0.96,
		HoverScale = 1.04,
		PressScale = 0.96,
		HoverTime = 0.08,
		Style = Enum.EasingStyle.Quad,
		ToastTime = 0.22,
		ToastDuration = 3.5,
		TrailDelay = 0.5, -- health "recent damage" trail waits this long, then drains
		TrailDrainTime = 0.35,
		FlowSpeed = 0.35, -- flowing Current bar texture scroll speed
		ShimmerSpeed = 0.5,
	},

	-- ScreenGui DisplayOrder per layer.
	Layers = {
		HUD = 1,
		Touch = 5,
		Menu = 10,
		Overlay = 20,
		Modal = 30,
		Tooltip = 40,
	},

	-- Top-left vitals cluster (Phase 2).
	HUD = {
		Margin = Vector2.new(16, 10),
		PortraitSize = 96,
		RingThickness = 5,
		BadgeSize = 32,
		BarsX = 112,
		HealthSize = Vector2.new(310, 22),
		CurrentSize = Vector2.new(275, 14),
		StaminaSize = Vector2.new(240, 8),
		XPSize = Vector2.new(170, 4),
		BarGap = 7,
		NotchSize = 11,
		NotchGap = 19,
		IdleTransparency = 0.25, -- out of combat the cluster dims slightly (75% visible)
		FadeTime = 0.5,
		FadeCheckInterval = 0.25,
		WindedFlashPeriod = 0.35,
		ResonancePulsePeriod = 0.9, -- full Resonance gauge breathing
		PressureSize = Vector2.new(104, 32),
	},

	-- Centre reticle shown while the mouse is locked to the screen centre.
	Reticle = {
		DotSize = 4,
		RingSize = 18,
		RingThickness = 1.5,
		RingTransparency = 0.35,
		ShadowTransparency = 0.5, -- dark outline so it reads on bright skies
	},

	-- Floating combat text and swing effects (Phase 3).
	CombatText = {
		TextSize = 26,
		BigTextSize = 34, -- crits, finishers, ripostes
		LabelTextSize = 22, -- PARRY, DODGE, BROKEN...
		Rise = 3, -- studs the number floats up
		Duration = 0.8,
		MaxActive = 30, -- pooled; the oldest is reused when exceeded
		Spread = 1.2, -- random sideways offset so stacked numbers stay readable
	},
	Slash = {
		Segments = 7,
		Thickness = 0.18,
		RadiusFraction = 0.6, -- arc radius as a fraction of reach
		Height = 1, -- studs above the attacker's root
		RevealTime = 0.06,
		FadeTime = 0.16,
	},

	-- Lock-on marker on the locked target (Phase 3).
	LockOn = {
		ReticleSize = 26,
		BarWidth = 150,
		HealthHeight = 8,
		PostureHeight = 5,
		InfoOffset = Vector3.new(0, 3.4, 0),
	},

	-- Ground telegraphs (TelegraphController): an outline at full size and a fill that grows
	-- until the attack lands, then a short flash. Unparryable attacks burn a deeper ember red.
	Telegraph = {
		Color = Colors.Danger,
		Unparryable = hex("#B3170C"),
		Ember = hex("#FF7A2E"),
		Flash = hex("#FFD9CC"),
		OutlineTransparency = 0.8,
		RimTransparency = 0.25,
		FillTransparency = 0.5,
		RimWidth = 0.35, -- studs
		WaveWidth = 2.6, -- studs: the travelling front of a ring wave
		FlashTime = 0.28,
		PulsePeriod = 0.4,
		Lift = 0.06, -- studs above the floor
	},

	-- Guardian fights (GuardianController): boss bar, cinematic cards, the unparryable glint.
	Guardian = {
		BarWidth = 560,
		BarBottom = 118, -- clears the spell bar
		HealthHeight = 14,
		PostureHeight = 5,
		PipSize = 10,
		Letterbox = 0.11, -- of the screen height, top and bottom
		NameSize = 72,
		CardTitleSize = 56,
		Glint = hex("#FF6A2A"),
		GlintSize = 5, -- studs
		GlintTime = 0.45,
		HighTide = Colors.Current,
		EbbTide = hex("#E0B872"),
	},

	-- Death screen (Phase 2).
	Death = {
		Saturation = -1,
		Contrast = 0.1,
		Tint = Color3.fromRGB(200, 205, 220),
		FadeTime = 1.2,
		AnimationSpeed = 0.3, -- local animations play in slow motion while you fall
		RevealDelay = 0.8, -- seconds before the death text fades in
	},

	-- World-space interaction prompt (Phase 2).
	Prompt = {
		Size = Vector2.new(220, 64),
		KeySize = 40,
		StudsOffset = Vector3.new(0, 1.5, 0),
		MaxDistance = 40,
	},

	-- Quests (Phase 11): the HUD tracker, the Quest Log, world markers and quest toasts.
	Quests = {
		KindColors = {
			Main = hex("#FFD25A"), -- gold: the story
			Side = hex("#5ED3F3"),
			Daily = hex("#3FE0D0"),
			Weekly = hex("#C38BFF"),
			Tutorial = hex("#D6F1FF"),
		} :: { [string]: Color3 },
		Ready = hex("#FFD25A"),
		Available = hex("#FFD25A"),
		Done = hex("#6EE07A"),
		TrackerWidth = 290,
		TrackerMaxQuests = 3,
		TrackerMaxLines = 5,
		TrackerGap = 12, -- px below the minimap
		DistanceRefresh = 0.25, -- seconds between distance updates
		ProgressToastInterval = 1.5, -- seconds between progress toasts for one quest
		MarkerSize = Vector2.new(64, 64),
		MarkerLift = 3.2, -- studs above an NPC's head for "!" / "?"
		BeamHeight = 60, -- studs: the light pillar at the tracked objective
		BeamWidth = 1.6,
		ObjectiveMarkerLift = 4,
	},

	-- Dialogue box (DialogueController).
	Dialogue = {
		Width = 900,
		Height = 210,
		Bottom = 28, -- px above the screen bottom
		ChoiceWidth = 330,
		ChoiceHeight = 48, -- touch-friendly (>= 44)
		CharsPerSecond = 48,
		BlipEvery = 2, -- characters between voice blips
		BlipVolume = 0.22,
		CameraEase = 0.6, -- seconds to frame the NPC
		CameraRelease = 0.5,
		CameraDistance = 8, -- studs from the NPC's head
		CameraSide = 2.6, -- studs to the side, so the NPC sits left of centre
		CameraFov = 50,
		WalkAwayFactor = 1.6, -- dialogue closes beyond TalkRadius x this
	},

	-- Player nameplates (NameplateController).
	Nameplate = {
		Size = Vector2.new(240, 58),
		StudsOffset = Vector3.new(0, 2.4, 0),
		FadeStart = 70, -- studs from the camera where the plate starts to fade
		MaxDistance = 110,
		Refresh = 0.1,
		Title = hex("#E7C46A"), -- gold serif title under the name
	},

	-- Map (M) and the minimap (MapController).
	Map = {
		Regions = {
			Town = hex("#5C5A55"),
			Harbour = hex("#1F4E73"),
			OldWharf = hex("#4A3E33"),
			TidepoolMarsh = hex("#3E5B45"),
			RustwoodForest = hex("#5B3F2B"),
			Downs = hex("#6B7451"),
			Cistern = hex("#2E3B4A"),
			FirstGate = hex("#5E5470"),
		} :: { [string]: Color3 },
		Background = hex("#0B1D33"), -- sea / outside the floor
		Fog = hex("#030914"),
		FogTransparency = 0.08,
		Waystone = hex("#3FE0D0"),
		WaystoneUndiscovered = hex("#62809F"),
		Quest = hex("#FFD25A"),
		Pin = hex("#FF7A5C"),
		Player = hex("#E8F1FA"),
		IconSize = 26,
		MinZoom = 1,
		MaxZoom = 6,
		ZoomStep = 1.18, -- per wheel notch
		GamepadPanSpeed = 700, -- px per second at full stick
		GamepadZoomSpeed = 1.6, -- zoom factor per second at full stick
		PickRadius = 22, -- px: a click this close to an icon picks it
		MinimapSize = 172,
		MinimapSizeTouch = 128,
		MinimapGap = 8, -- px below the Pressure icon
		MinimapIconSize = 16,
	},

	-- Big centred banners (achievements, quest completions).
	Banner = {
		Width = 520,
		Top = 110,
		Duration = 3.6,
		Gold = hex("#E7C46A"),
	},

	-- Reference resolution: UI is authored at this height and scaled.
	ReferenceHeight = 900,
	ScaleMin = 0.62,
	ScaleMax = 1.35,
}

function UITheme.RarityColor(rarity: string): Color3
	return Rarity[rarity] or Rarity.Common
end

function UITheme.AttunementColor(attunement: string): Color3
	return Attunement[attunement] or Colors.Current
end

-- UI scale for a viewport: authored at ReferenceHeight, clamped, times the
-- player's HUD scale setting.
function UITheme.ComputeScale(viewport: Vector2, userScale: number): number
	local base = viewport.Y / UITheme.ReferenceHeight
	return math.clamp(base, UITheme.ScaleMin, UITheme.ScaleMax) * userScale
end

return UITheme
