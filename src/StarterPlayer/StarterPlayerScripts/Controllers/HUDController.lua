--!strict
--[[
	HUDController
	The top-left vitals cluster (Spec Section 12):

	  [portrait]  Health  ███████████░░  (red, with a pale "recent damage" trail)
	  [ ring  ]   Current ████████░░     (flowing teal)
	  [ (lvl) ]   Stamina ██████         (thin gold; flashes red while Winded, teal while Surging)
	              ◆ ◆ ◇ ◇ ◇              (Resonance notches)

	- The ring around the portrait is Saturation: teal while filling, gold in
	  Overflow, grey in Burnout.
	- Resonance notches light in the primary Attunement's colour, pop when a
	  stack lands and pulse when full (Confluence ready).
	- Top right: the Current Pressure where you stand (wave icon + 5 pips).
	- Health comes from the Humanoid; everything else from the Player
	  attributes VitalsService replicates.
	- Out of combat with everything full, the cluster fades to 40% so the
	  world stays the focus; any damage, spending or sprinting brings it back.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Attributes = require(Shared.Attributes)
local TweenUtil = require(Shared.Util.TweenUtil)
local Net = require(Shared.Net)
local Spells = require(Shared.Data.Spells)
local Formulas = require(Shared.Data.Formulas)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Animator = require(UI.Animator)
local Components = require(UI.Components)

local DataController = require(script.Parent.DataController)

local A = Attributes.Names
local H = UITheme.HUD
local player = Players.LocalPlayer

local HUDController = {}

local root: CanvasGroup
local healthBar: Components.ProgressBar
local currentBar: Components.ProgressBar
local staminaBar: Components.ProgressBar
local saturationRing: Components.RadialProgress
local levelLabel: TextLabel
local xpBar: Components.ProgressBar
local xpLabel: TextLabel
local notches: { Frame } = {}
local notchScales: { UIScale } = {}
local stopResonancePulse: (() -> ())? = nil
local pressureFrame: Frame
local pressureLabel: TextLabel
local pressurePips: { Frame } = {}
local humanoid: Humanoid? = nil
local humanoidConnections: { RBXScriptConnection } = {}
local stopWindedFlash: (() -> ())? = nil
local faded = false

local function attr(name: string, fallback: number): number
	local value = player:GetAttribute(name)
	return if type(value) == "number" then value else fallback
end

-- BUILD ----------------------------------------------------------------------

local function build()
	local layer = Layers.Get("HUD")
	root = Create.new("CanvasGroup", {
		Name = "Vitals",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(H.Margin.X, H.Margin.Y),
		Size = UDim2.fromOffset(H.BarsX + H.HealthSize.X + 8, H.PortraitSize + 8),
		Parent = layer,
	})
	-- CanvasGroups clip their contents, and UIStrokes draw outside a frame's
	-- edge, so inset everything by the ring thickness to keep rings whole.
	Create.Padding(root, H.RingThickness)
	root.Size += UDim2.fromOffset(H.RingThickness * 2, H.RingThickness * 2)

	-- Portrait: avatar headshot in a dark circle, Saturation ring around it.
	local portrait: Frame = Create.new("Frame", {
		Name = "Portrait",
		BackgroundColor3 = UITheme.Colors.HudPanel,
		BackgroundTransparency = UITheme.PanelTransparency,
		Size = UDim2.fromOffset(H.PortraitSize, H.PortraitSize),
		Parent = root,
	})
	Create.Corner(portrait, UITheme.CornerPill)
	local headshot: ImageLabel = Create.new("ImageLabel", {
		Name = "Headshot",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -H.RingThickness * 3, 1, -H.RingThickness * 3),
		Image = "",
		Parent = portrait,
	})
	Create.Corner(headshot, UITheme.CornerPill)
	task.spawn(function()
		local ok, image = pcall(function()
			return Players:GetUserThumbnailAsync(
				math.max(1, player.UserId),
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size150x150
			)
		end)
		if ok then
			headshot.Image = image
		end
	end)
	saturationRing = Components.RadialProgress.new({
		Name = "Saturation",
		Color = UITheme.Colors.Current,
		Thickness = H.RingThickness,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = portrait,
	})

	-- Level badge on the portrait's lower-right edge.
	local badge: Frame = Create.new("Frame", {
		Name = "LevelBadge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -8, 1, -8),
		Size = UDim2.fromOffset(H.BadgeSize, H.BadgeSize),
		BackgroundColor3 = UITheme.Colors.HudSunken,
		ZIndex = 4,
		Parent = portrait,
	})
	Create.Corner(badge, UITheme.CornerPill)
	Create.Stroke(badge, UITheme.Colors.Brass, 1.5, 0.1)
	levelLabel = Create.Label({
		Name = "Level",
		Text = "1",
		Font = UITheme.Fonts.Numbers,
		TextSize = UITheme.TextSize.Small,
		XAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = badge,
	})
	levelLabel.ZIndex = 5

	-- Bars, stacked to the right of the portrait.
	local y = 8
	healthBar = Components.ProgressBar.new({
		Name = "Health",
		Color = UITheme.Colors.Health,
		TrailColor = UITheme.Colors.HealthTrail,
		ShowText = true,
		Position = UDim2.fromOffset(H.BarsX, y),
		Size = UDim2.fromOffset(H.HealthSize.X, H.HealthSize.Y),
		Parent = root,
	})
	y += H.HealthSize.Y + H.BarGap
	currentBar = Components.ProgressBar.new({
		Name = "Current",
		Color = UITheme.Colors.Current,
		Flow = true,
		Position = UDim2.fromOffset(H.BarsX, y),
		Size = UDim2.fromOffset(H.CurrentSize.X, H.CurrentSize.Y),
		Parent = root,
	})
	y += H.CurrentSize.Y + H.BarGap
	staminaBar = Components.ProgressBar.new({
		Name = "Stamina",
		Color = UITheme.Colors.Stamina,
		Position = UDim2.fromOffset(H.BarsX, y),
		Size = UDim2.fromOffset(H.StaminaSize.X, H.StaminaSize.Y),
		Parent = root,
	})
	y += H.StaminaSize.Y + H.BarGap + 2

	-- Resonance notches (diamonds).
	for index = 1, Config.Current.Resonance.MaxStacks do
		local notch: Frame = Create.new("Frame", {
			Name = `Notch{index}`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(H.BarsX + H.NotchSize / 2 + 2 + (index - 1) * H.NotchGap, y + H.NotchSize / 2),
			Size = UDim2.fromOffset(H.NotchSize, H.NotchSize),
			Rotation = 45,
			BackgroundColor3 = UITheme.Colors.Track,
			BackgroundTransparency = 0.2,
			Parent = root,
		})
		Create.Stroke(notch, UITheme.Colors.Brass, 1, 0.5)
		table.insert(notchScales, Create.new("UIScale", { Parent = notch }))
		table.insert(notches, notch)
	end

	-- XP toward the next level: a slim gold bar under the Resonance notches.
	local xpY = y + H.NotchSize + 6
	xpBar = Components.ProgressBar.new({
		Name = "XP",
		Color = UITheme.Colors.Brass,
		Position = UDim2.fromOffset(H.BarsX, xpY),
		Size = UDim2.fromOffset(H.XPSize.X, H.XPSize.Y),
		Parent = root,
	})
	xpLabel = Create.Label({
		Name = "XPText",
		Text = "",
		Font = UITheme.Fonts.Numbers,
		TextSize = UITheme.TextSize.Caption,
		Color = UITheme.Colors.TextMuted,
		Position = UDim2.fromOffset(H.BarsX + H.XPSize.X + 6, xpY - 5),
		Size = UDim2.fromOffset(90, 14),
		Parent = root,
	})

	-- Current Pressure, top right (where the minimap will sit beside it).
	pressureFrame = Create.new("Frame", {
		Name = "Pressure",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -H.Margin.X, 0, H.Margin.Y),
		Size = UDim2.fromOffset(H.PressureSize.X, H.PressureSize.Y),
		BackgroundColor3 = UITheme.Colors.HudPanel,
		BackgroundTransparency = 0.35,
		Parent = layer,
	})
	Create.Corner(pressureFrame, UITheme.CornerPill)
	Create.Stroke(pressureFrame, UITheme.Colors.Brass, 1, 0.5)
	Create.new("TextLabel", {
		Name = "Wave",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(8, 0),
		Size = UDim2.new(0, 22, 1, 0),
		FontFace = UITheme.Fonts.BodyBold,
		TextSize = 20,
		TextColor3 = UITheme.Colors.Current,
		Text = "≈",
		Parent = pressureFrame,
	})
	pressureLabel = Create.new("TextLabel", {
		Name = "Level",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(32, 2),
		Size = UDim2.new(1, -40, 0, 16),
		FontFace = UITheme.Fonts.BodyMedium,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = UITheme.Colors.TextMuted,
		Text = "",
		Parent = pressureFrame,
	})
	for index = 1, Config.Current.Pressure.Max do
		local pip: Frame = Create.new("Frame", {
			Name = `Pip{index}`,
			Position = UDim2.fromOffset(32 + (index - 1) * 12, 21),
			Size = UDim2.fromOffset(9, 5),
			BackgroundColor3 = UITheme.Colors.Track,
			Parent = pressureFrame,
		})
		Create.Corner(pip, UITheme.CornerPill)
		table.insert(pressurePips, pip)
	end
end

-- UPDATES --------------------------------------------------------------------

local function refreshHealth(instant: boolean?)
	local hum = humanoid
	if hum then
		healthBar:SetValue(math.ceil(hum.Health), hum.MaxHealth, instant)
	end
end

local function refreshCurrent(instant: boolean?)
	currentBar:SetValue(attr(A.Current, 0), attr(A.MaxCurrent, 100), instant)
end

local function refreshStamina(instant: boolean?)
	staminaBar:SetValue(attr(A.Stamina, 0), attr(A.MaxStamina, 100), instant)
end

local function refreshSaturation()
	local t = Workspace:GetServerTimeNow()
	local color = if attr(A.Overflow, 0) > t then UITheme.Colors.Parry
		elseif attr(A.Burnout, 0) > t then UITheme.Colors.TextDim
		else UITheme.Colors.Current
	saturationRing:SetColor(color)
	saturationRing:SetValue(attr(A.Saturation, 0) / 100, 0.25)
end

local function attunementColor(): Color3
	local name = player:GetAttribute(A.Attunement)
	local element = if type(name) == "string" then Spells.Attunement(name) else nil
	return if element then element.Color else UITheme.Colors.Current
end

local function refreshResonance()
	local value = attr(A.Resonance, 0)
	local color = attunementColor()
	for index, notch in notches do
		local lit = index <= value
		notch.BackgroundColor3 = if lit then color else UITheme.Colors.Track
		notch.BackgroundTransparency = if lit then 0 else 0.2
	end
	-- Full gauge: the notches breathe so Confluence readiness is unmissable.
	local full = value >= Config.Current.Resonance.MaxStacks
	if full and not stopResonancePulse then
		stopResonancePulse = Animator.Add(function(time: number)
			local glow = (math.sin(time * math.pi * 2 / H.ResonancePulsePeriod) + 1) / 2
			for _, scale in notchScales do
				scale.Scale = 1 + glow * 0.25
			end
		end)
	elseif not full and stopResonancePulse then
		stopResonancePulse()
		stopResonancePulse = nil
		for _, scale in notchScales do
			scale.Scale = 1
		end
	end
end

-- A stack just landed: pop the newest notch.
local function onResonanceTriggered(stacks: number)
	local scale = if type(stacks) == "number" then notchScales[stacks] else nil
	if scale and not stopResonancePulse then
		scale.Scale = 1.7
		TweenUtil.Play(scale, 0.25, { Scale = 1 })
	end
end

local function refreshPressure()
	local P = Config.Current.Pressure
	local level = math.floor(attr(A.Pressure, P.Neutral))
	pressureLabel.Text = Strings.Format(Strings.Pressure.Label, { level = level })
	local color = if level > P.Neutral then UITheme.Colors.Current
		elseif level < P.Neutral then UITheme.Colors.Stamina
		else UITheme.Colors.TextMuted
	for index, pip in pressurePips do
		pip.BackgroundColor3 = if index <= level then color else UITheme.Colors.Track
	end
end

local function refreshLevel()
	levelLabel.Text = Strings.Format(Strings.HUD.Level, { level = attr(A.Level, 1) })
end

-- XP comes from the saved profile (level and XP both replicate with it).
local function refreshXP()
	local level = DataController.Get({ "Level" })
	local xp = DataController.Get({ "XP" })
	if type(level) ~= "number" or type(xp) ~= "number" then
		return
	end
	if level >= Config.Progression.LevelCap then
		xpBar:SetValue(1, 1)
		xpLabel.Text = Strings.HUD.XPMax
		return
	end
	local needed = Formulas.XPToNext(level)
	xpBar:SetValue(xp, needed)
	xpLabel.Text = `{math.floor(xp / needed * 100)}%`
end

local function refreshWinded()
	local winded = player:GetAttribute(A.Winded) == true
	if winded and not stopWindedFlash then
		local danger = UITheme.Colors.Danger
		local base = UITheme.Colors.Stamina
		stopWindedFlash = Animator.Add(function(time: number)
			local t = (math.sin(time * math.pi * 2 / UITheme.HUD.WindedFlashPeriod) + 1) / 2
			staminaBar:SetColor(base:Lerp(danger, t))
		end)
	elseif not winded then
		if stopWindedFlash then
			stopWindedFlash()
			stopWindedFlash = nil
		end
		-- A sprint Surge tints the bar toward Current teal.
		local surging = player:GetAttribute(A.Surging) == true
		staminaBar:SetColor(if surging then UITheme.Colors.Stamina:Lerp(UITheme.Colors.Current, 0.7) else UITheme.Colors.Stamina)
	end
end

-- Full brightness while anything is happening; fade when idle and full.
local function updateFade()
	local hum = humanoid
	local lastCombat = attr(A.LastCombat, 0)
	local inCombat = Workspace:GetServerTimeNow() - lastCombat < Config.Combat.Vitals.CombatTimeout
	local healthFull = hum == nil or hum.Health >= hum.MaxHealth
	local dead = hum ~= nil and hum.Health <= 0
	local staminaFull = attr(A.Stamina, 0) >= attr(A.MaxStamina, 0)
	local currentFull = attr(A.Current, 0) >= attr(A.MaxCurrent, 0)
	local active = inCombat or dead or not healthFull or not staminaFull or not currentFull
		or player:GetAttribute(A.Sprinting) == true
	local shouldFade = not active
	if shouldFade ~= faded then
		faded = shouldFade
		TweenUtil.Play(root, H.FadeTime, { GroupTransparency = if shouldFade then H.IdleTransparency else 0 })
	end
end

local function bindCharacter(character: Model)
	for _, connection in humanoidConnections do
		connection:Disconnect()
	end
	table.clear(humanoidConnections)
	local hum = character:WaitForChild("Humanoid", 10) :: Humanoid?
	humanoid = hum
	if not hum then
		return
	end
	table.insert(humanoidConnections, hum.HealthChanged:Connect(function()
		refreshHealth()
	end))
	table.insert(humanoidConnections, hum:GetPropertyChangedSignal("MaxHealth"):Connect(function()
		refreshHealth()
	end))
	refreshHealth(true)
end

function HUDController.Init()
	build()
end

function HUDController.Start()
	local watchers: { [string]: () -> () } = {
		[A.Current] = refreshCurrent,
		[A.MaxCurrent] = refreshCurrent,
		[A.Stamina] = refreshStamina,
		[A.MaxStamina] = refreshStamina,
		[A.Saturation] = refreshSaturation,
		[A.Overflow] = refreshSaturation,
		[A.Burnout] = refreshSaturation,
		[A.Resonance] = refreshResonance,
		[A.Attunement] = refreshResonance,
		[A.Pressure] = refreshPressure,
		[A.Level] = refreshLevel,
		[A.Winded] = refreshWinded,
		[A.Surging] = refreshWinded,
	}
	for name, callback in watchers do
		player:GetAttributeChangedSignal(name):Connect(callback)
	end
	refreshCurrent(true)
	refreshStamina(true)
	refreshSaturation()
	refreshResonance()
	refreshPressure()
	refreshLevel()
	Net.OnClient("ResonanceTriggered", onResonanceTriggered)
	refreshWinded()
	DataController.Observe({ "XP" }, refreshXP)
	DataController.Observe({ "Level" }, refreshXP)

	player.CharacterAdded:Connect(bindCharacter)
	if player.Character then
		task.spawn(bindCharacter, player.Character)
	end

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator >= H.FadeCheckInterval then
			accumulator = 0
			updateFade()
		end
	end)
end

return HUDController
