--!strict
--[[
	GuardianController
	What a Climber sees of a Floor Guardian fight (Spec Sections 10, 12 and 13;
	docs/PHASE10_GUARDIAN.md). The server drives everything through Net "GuardianEvent"(kind,
	payload) and the Guardian attributes; this controller only presents it.

	- Boss bar (HUD layer, so it follows HUD Scale): shown while the nearest live model tagged
	  Guardian is within BAR_RANGE of you. Serif name and level, health with a damage trail,
	  posture (red while Broken), three phase pips and the tide (Calm / High / Ebb, a countdown to
	  GuardianTideEndsAt and its hint; it pulses during a tide warning). Bottom centre on mouse and
	  gamepad; top centre on touch, where the bottom corners belong to the touch controls.
	- Music (MusicController): one layer per phase while the bar is up; the victory sting.
	- Intro: letterbox, a scripted camera sweep from the claws up to the helm, the name card.
	  When the payload says Skippable, attack / jump / the on-screen button end it early (the
	  server keeps the Guardian dormant regardless). The HUD and touch layers hide meanwhile.
	- Phase: a banner with the phase pips, name and hint, a camera punch and shake.
	- Tide: updates the indicator; a warning also flashes "The tide turns...".
	- Victory: slow motion (the Guardian's animations slow, colour drains, the camera eases in,
	  a deep bell), then the "Guardian Felled" card (time, party), then the personal unlock card.
	- Wipe: "The tide recedes..." and the music stops.
	- Banner: Server scope = a large top banner; Global = a toast.
	- Gather: a small countdown banner while the gate gathers its party.
	Reduced Motion: no camera sweep (a still shot), no slow camera push, no card scaling or pulses.
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local Maid = require(Shared.Util.Maid)
local TweenUtil = require(Shared.Util.TweenUtil)
local MathUtil = require(Shared.Util.MathUtil)
local Guardians = require(Shared.Data.Guardians)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Motion = require(UI.Motion)
local Animator = require(UI.Animator)
local Device = require(UI.Device)
local UISound = require(UI.UISound)
local Components = require(UI.Components)

local DataController = require(script.Parent.DataController)
local CameraController = require(script.Parent.CameraController)
local InputController = require(script.Parent.InputController)
local LockOnController = require(script.Parent.LockOnController)
local MusicController = require(script.Parent.MusicController)

local A = Attributes.Names
local G = UITheme.Guardian
local GS = Strings.Guardians
local GUARDIAN = Config.Mobs.Guardian
local MUSIC = Config.Environment.Music
local player = Players.LocalPlayer

local GuardianController = {}

local BAR_RANGE = 250
local SCAN_INTERVAL = 0.25
local SLOW_MO_SPEED = 0.2 -- the Guardian's animations during the victory moment
local FELLED_HOLD = 4.5
local UNLOCK_HOLD = 4.5
local BANNER_HOLD = 6
local WIPE_HOLD = 5
local DEFAULT_TRANSITION = 3
local SKIP_KEYS: { [Enum.KeyCode]: boolean } = { [Enum.KeyCode.Space] = true, [Enum.KeyCode.ButtonA] = true }
local SKIP_ACTIONS: { [string]: boolean } = { LightAttack = true, HeavyAttack = true, Jump = true }
local GOLD = UITheme.Colors.Parry
local TIDE_COLOURS: { [string]: Color3 } = { Calm = UITheme.Colors.TextMuted, High = G.HighTide, Ebb = G.EbbTide }

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function isReduced(): boolean
	return Motion.IsReduced() or DataController.GetSetting("ReducedMotion") == true
end

local function rootOf(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	return if root and root:IsA("BasePart") then root else nil
end

local function guardianIdOf(model: Model?): string
	local id = if model then model:GetAttribute(A.GuardianId) else nil
	return if type(id) == "string" then id else ""
end

local function guardianName(id: string): string
	return GS.Names[id] or id
end

local function numberAttr(model: Model, name: string, fallback: number): number
	local value = model:GetAttribute(name)
	return if type(value) == "number" then value else fallback
end

local function modelOf(value: any): Model?
	return if typeof(value) == "Instance" and value:IsA("Model") then value else nil
end

local function joinNames(value: any, skipSelf: boolean): string
	local names: { string } = {}
	local skipped = not skipSelf
	if type(value) == "table" then
		for _, name in value do
			if type(name) == "string" then
				if not skipped and (name == player.Name or name == player.DisplayName) then
					skipped = true
				else
					table.insert(names, name)
				end
			end
		end
	end
	return table.concat(names, ", ")
end

-- CARDS ---------------------------------------------------------------------------------------

type Line = {
	Text: string,
	Font: Font,
	Size: number,
	Color: Color3,
	Gradient: ColorSequence?,
}

type Card = { Group: CanvasGroup, Scale: UIScale }

-- A centred stack of text lines in the Overlay layer, optionally over a soft dark band.
local function buildCard(name: string, y: number, lines: { Line }, band: boolean): Card
	local group: CanvasGroup = Create.new("CanvasGroup", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, y),
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Visible = false,
		ZIndex = 30,
	})
	local scale: UIScale = Create.new("UIScale", { Parent = group })
	if band then
		local backdrop: Frame = Create.new("Frame", {
			Name = "Band",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = UITheme.Colors.Overlay,
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
			Parent = group,
		})
		Create.new("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.5, 0),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Rotation = 90,
			Parent = backdrop,
		})
	end
	local stack: Frame = Create.new("Frame", {
		Name = "Lines",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 2,
		Parent = group,
	})
	Create.List(stack, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center)
	Create.new("UIPadding", {
		PaddingTop = UDim.new(0, 22),
		PaddingBottom = UDim.new(0, 22),
		Parent = stack,
	})
	for index, line in lines do
		local label = Create.Label({
			Name = `Line{index}`,
			Text = line.Text,
			Font = line.Font,
			TextSize = line.Size,
			Color = if line.Gradient then Color3.new(1, 1, 1) else line.Color,
			XAlignment = Enum.TextXAlignment.Center,
			Wrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, -80, 0, 0),
			LayoutOrder = index,
			Parent = stack,
		})
		label.TextStrokeTransparency = 0.45
		label.TextStrokeColor3 = UITheme.Colors.Overlay
		label.ZIndex = 3
		if line.Gradient then
			Create.new("UIGradient", { Color = line.Gradient, Rotation = 90, Parent = label })
		end
	end
	group.Parent = Layers.Get("Overlay")
	return { Group = group, Scale = scale }
end

local function reveal(card: Card, time: number)
	local reduced = isReduced()
	card.Group.Visible = true
	card.Group.GroupTransparency = 1
	card.Scale.Scale = if reduced then 1 else 1.08
	TweenUtil.Play(card.Group, time, { GroupTransparency = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	if not reduced then
		TweenUtil.Play(card.Scale, time * 1.3, { Scale = 1 }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	end
end

-- Yields until the card has faded.
local function conceal(card: Card, time: number)
	if not card.Group.Parent then
		return
	end
	TweenUtil.Await(TweenUtil.Play(card.Group, time, { GroupTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In))
end

-- Shows a card for `hold` seconds, then fades and destroys it. Yields.
local function present(card: Card, hold: number)
	reveal(card, 0.5)
	task.wait(hold)
	conceal(card, 0.5)
	card.Group:Destroy()
end

-- Diamond pips (phase markers) in a horizontal row.
local function buildPips(parent: Instance, size: number, gap: number): { Frame }
	local pips: { Frame } = {}
	local row: Frame = Create.new("Frame", {
		Name = "Pips",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size * 3 + gap * 2 + 4, size + 4),
		Parent = parent,
	})
	for index = 1, 3 do
		local pip: Frame = Create.new("Frame", {
			Name = `Pip{index}`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(2 + size / 2 + (index - 1) * (size + gap), size / 2 + 2),
			Size = UDim2.fromOffset(size * 0.75, size * 0.75),
			Rotation = 45,
			BackgroundColor3 = UITheme.Colors.Brass,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = row,
		})
		Create.Stroke(pip, UITheme.Colors.Brass, 1.5, 0.1)
		pips[index] = pip
	end
	return pips
end

local function setPips(pips: { Frame }, phase: number)
	for index, pip in pips do
		pip.BackgroundTransparency = if index <= phase then 0 else 1
	end
end

-- BOSS BAR ------------------------------------------------------------------------------------

type Bar = {
	Group: CanvasGroup,
	Name: TextLabel,
	Level: TextLabel,
	Health: Components.ProgressBar,
	Posture: Components.ProgressBar,
	Pips: { Frame },
	Tide: TextLabel,
	TideHint: TextLabel,
}

local bar: Bar? = nil
local bound: Model? = nil
local boundMaid = Maid.new()
local barShown = false
local introActive = false
local tideEvent: { State: string, EndsAt: number, Warning: boolean }? = nil
local stopTidePulse: (() -> ())? = nil
local silenced: Model? = nil -- after a wipe, this Guardian's reset doesn't restart the music

local function buildBar(): Bar
	local group: CanvasGroup = Create.new("CanvasGroup", {
		Name = "GuardianBar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -G.BarBottom),
		Size = UDim2.fromOffset(G.BarWidth, 88),
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Visible = false,
	})
	-- A soft dark backdrop so the bar reads over bright water and sky.
	local backdrop: Frame = Create.new("Frame", {
		Name = "Backdrop",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 60, 1, 8),
		BackgroundColor3 = UITheme.Colors.HudSunken,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Parent = group,
	})
	Create.new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.12, 0),
			NumberSequenceKeypoint.new(0.88, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = backdrop,
	})

	local header: Frame = Create.new("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -60, 0, 30),
		Parent = group,
	})
	Create.List(header, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Bottom)
	local name = Create.Label({
		Name = "GuardianName",
		Text = "",
		Font = UITheme.Fonts.Display,
		TextSize = UITheme.TextSize.Heading,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 30),
		LayoutOrder = 1,
		Parent = header,
	})
	name.TextStrokeTransparency = 0.5
	local level = Create.Label({
		Name = "Level",
		Text = "",
		Font = UITheme.Fonts.Numbers,
		TextSize = UITheme.TextSize.Small,
		Color = UITheme.Colors.Brass,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 24),
		LayoutOrder = 2,
		Parent = header,
	})
	level.TextStrokeTransparency = 0.6

	local pipHolder: Frame = Create.new("Frame", {
		Name = "PhasePips",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 10),
		Size = UDim2.fromOffset(G.PipSize * 3 + 16 + 4, G.PipSize + 4),
		BackgroundTransparency = 1,
		Parent = group,
	})
	local pips = buildPips(pipHolder, G.PipSize, 8)

	local health = Components.ProgressBar.new({
		Name = "Health",
		Color = UITheme.Colors.Health,
		TrailColor = UITheme.Colors.HealthTrail,
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 0, G.HealthHeight),
		Parent = group,
	})
	local posture = Components.ProgressBar.new({
		Name = "Posture",
		Color = UITheme.Colors.Parry,
		Position = UDim2.fromOffset(0, 34 + G.HealthHeight + 4),
		Size = UDim2.new(1, 0, 0, G.PostureHeight),
		Parent = group,
	})

	local tideY = 34 + G.HealthHeight + 4 + G.PostureHeight + 6
	local tide = Create.Label({
		Name = "Tide",
		Text = "",
		Font = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.Small,
		Position = UDim2.fromOffset(0, tideY),
		Size = UDim2.new(0.45, 0, 0, 20),
		Parent = group,
	})
	tide.TextStrokeTransparency = 0.6
	local tideHint = Create.Label({
		Name = "TideHint",
		Text = "",
		TextSize = UITheme.TextSize.Caption,
		Color = UITheme.Colors.TextMuted,
		XAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, tideY),
		Size = UDim2.new(0.55, 0, 0, 20),
		Parent = group,
	})
	tideHint.TextStrokeTransparency = 0.7

	group.Parent = Layers.Get("HUD")
	return {
		Group = group,
		Name = name,
		Level = level,
		Health = health,
		Posture = posture,
		Pips = pips,
		Tide = tide,
		TideHint = tideHint,
	}
end

-- Bottom centre above the spell bar; top centre on touch (the bottom corners hold the controls).
local function layoutBar()
	local b = bar
	if not b then
		return
	end
	if Device.IsTouch() then
		b.Group.AnchorPoint = Vector2.new(0.5, 0)
		b.Group.Position = UDim2.new(0.5, 0, 0, 8)
		b.Group.Size = UDim2.fromOffset(math.floor(G.BarWidth * 0.8), 88)
	else
		b.Group.AnchorPoint = Vector2.new(0.5, 1)
		b.Group.Position = UDim2.new(0.5, 0, 1, -G.BarBottom)
		b.Group.Size = UDim2.fromOffset(G.BarWidth, 88)
	end
end

local function refreshBarVisibility()
	local b = bar
	if not b then
		return
	end
	local show = bound ~= nil and not introActive
	if show == barShown then
		return
	end
	barShown = show
	if show then
		b.Group.Visible = true
	end
	local tween = TweenUtil.Play(b.Group, 0.4, { GroupTransparency = if show then 0 else 1 })
	if not show then
		tween.Completed:Once(function()
			if not barShown then
				b.Group.Visible = false
			end
		end)
	end
end

local function refreshHealth(model: Model, instant: boolean?)
	local b = bar
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if b and humanoid then
		b.Health:SetValue(humanoid.Health, humanoid.MaxHealth, instant)
	end
end

local function refreshPosture(model: Model, instant: boolean?)
	local b = bar
	if not b then
		return
	end
	b.Posture:SetValue(numberAttr(model, A.Posture, 0), numberAttr(model, A.MaxPosture, 100), instant)
	b.Posture:SetColor(if model:GetAttribute(A.CombatState) == "Broken" then UITheme.Colors.Danger else UITheme.Colors.Parry)
end

local function setTidePulse(on: boolean)
	local b = bar
	if on and not stopTidePulse and b and not isReduced() then
		stopTidePulse = Animator.Pulse(b.Tide, "TextTransparency", 0, 0.65, 0.5)
	elseif not on and stopTidePulse then
		stopTidePulse()
		stopTidePulse = nil
		if b then
			b.Tide.TextTransparency = 0
		end
	end
end

-- The tide row: attributes are the authority; the Tide event adds the warning flag.
local function refreshTide()
	local b = bar
	local model = bound
	if not b or not model then
		return
	end
	local event = tideEvent
	local stateAttr = model:GetAttribute(A.GuardianTide)
	local state = if type(stateAttr) == "string" then stateAttr elseif event then event.State else "Calm"
	local endsAttr = model:GetAttribute(A.GuardianTideEndsAt)
	local endsAt = if type(endsAttr) == "number" then endsAttr elseif event then event.EndsAt else 0
	local label = GS.Tide[state] or state
	local remaining = endsAt - now()
	if state ~= "Calm" and remaining > 0 then
		label = `{label}  {MathUtil.FormatDuration(math.ceil(remaining))}`
	end
	local warning = event ~= nil and event.Warning and event.State == state and remaining > 0
	b.Tide.Text = label
	b.Tide.TextColor3 = if warning and isReduced() then UITheme.Colors.Text else (TIDE_COLOURS[state] or UITheme.Colors.TextMuted)
	b.TideHint.Text = GS.TideHint[state] or ""
	setTidePulse(warning)
end

local function phaseTrack(id: string, phase: number): string
	local set = MUSIC.Guardian[id]
	if not set then
		return ""
	end
	return if phase >= 3 then set.Phase3 elseif phase == 2 then set.Phase2 else set.Phase1
end

local function playPhaseMusic(id: string, phase: number)
	MusicController.Play(`Guardian:{id}:{phase}`, phaseTrack(id, phase))
end

local function refreshPhase(model: Model)
	local b = bar
	local phase = math.clamp(math.floor(numberAttr(model, A.GuardianPhase, 1)), 1, 3)
	if b then
		setPips(b.Pips, phase)
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 and model ~= silenced then
		playPhaseMusic(guardianIdOf(model), phase)
	end
end

local function unbind()
	if not bound then
		return
	end
	boundMaid:Clean()
	bound = nil
	silenced = nil
	tideEvent = nil
	setTidePulse(false)
	MusicController.Stop()
	refreshBarVisibility()
end

local function bind(model: Model)
	if bound == model then
		return
	end
	boundMaid:Clean()
	bound = model
	local b = bar
	local id = guardianIdOf(model)
	local def = Guardians.Get(id)
	if b then
		b.Name.Text = guardianName(id)
		b.Level.Text = Strings.Format(GS.BossLevel, { level = if def then def.Level else "" })
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		boundMaid:Add(humanoid.HealthChanged:Connect(function()
			refreshHealth(model)
		end))
		boundMaid:Add(humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
			refreshHealth(model)
		end))
	end
	for _, name in { A.Posture, A.MaxPosture, A.CombatState } do
		boundMaid:Add(model:GetAttributeChangedSignal(name):Connect(function()
			refreshPosture(model)
		end))
	end
	boundMaid:Add(model:GetAttributeChangedSignal(A.GuardianPhase):Connect(function()
		refreshPhase(model)
	end))
	for _, name in { A.GuardianTide, A.GuardianTideEndsAt } do
		boundMaid:Add(model:GetAttributeChangedSignal(name):Connect(refreshTide))
	end
	refreshHealth(model, true)
	refreshPosture(model, true)
	refreshPhase(model)
	refreshTide()
	refreshBarVisibility()
end

-- The nearest live Guardian within BAR_RANGE of the local character (or the camera).
local function findGuardian(): Model?
	local character = player.Character
	local root = if character then rootOf(character) else nil
	local camera = Workspace.CurrentCamera
	local origin = if root then root.Position elseif camera then camera.CFrame.Position else nil
	if not origin then
		return nil
	end
	local best: Model? = nil
	local bestDistance = BAR_RANGE
	for _, instance in CollectionService:GetTagged(Attributes.Tags.Guardian) do
		if instance:IsA("Model") and instance:IsDescendantOf(Workspace) then
			local humanoid = instance:FindFirstChildOfClass("Humanoid")
			local guardianRoot = rootOf(instance)
			if humanoid and humanoid.Health > 0 and guardianRoot then
				local distance = (guardianRoot.Position - origin).Magnitude
				if distance <= bestDistance then
					best = instance
					bestDistance = distance
				end
			end
		end
	end
	return best
end

-- SMALL BANNERS -------------------------------------------------------------------------------

type Callout = { Group: CanvasGroup, Label: TextLabel, Token: number }

local function buildCallout(name: string, y: number, size: number, font: Font): Callout
	local group: CanvasGroup = Create.new("CanvasGroup", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, y),
		Size = UDim2.new(1, 0, 0, size + 26),
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Visible = false,
		ZIndex = 25,
		Parent = Layers.Get("Overlay"),
	})
	local backdrop: Frame = Create.new("Frame", {
		Name = "Band",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.7, 0, 1, 0),
		BackgroundColor3 = UITheme.Colors.Overlay,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Parent = group,
	})
	Create.new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.2, 0),
			NumberSequenceKeypoint.new(0.8, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = backdrop,
	})
	local label = Create.Label({
		Name = "Text",
		Text = "",
		Font = font,
		TextSize = size,
		XAlignment = Enum.TextXAlignment.Center,
		Wrapped = true,
		Size = UDim2.new(1, -60, 1, 0),
		Position = UDim2.fromOffset(30, 0),
		Parent = group,
	})
	label.TextStrokeTransparency = 0.5
	label.ZIndex = 2
	return { Group = group, Label = label, Token = 0 }
end

local function showCallout(callout: Callout, text: string, color: Color3, seconds: number?)
	callout.Token += 1
	local token = callout.Token
	callout.Label.Text = text
	callout.Label.TextColor3 = color
	if not callout.Group.Visible then
		callout.Group.Visible = true
		TweenUtil.Play(callout.Group, 0.25, { GroupTransparency = 0 })
	end
	if seconds then
		task.delay(seconds, function()
			if callout.Token ~= token then
				return
			end
			local tween = TweenUtil.Play(callout.Group, 0.35, { GroupTransparency = 1 })
			tween.Completed:Once(function()
				if callout.Token == token then
					callout.Group.Visible = false
				end
			end)
		end)
	end
end

local function hideCallout(callout: Callout)
	if callout.Group.Visible then
		showCallout(callout, callout.Label.Text, callout.Label.TextColor3, 0)
	end
end

local gatherCallout: Callout? = nil
local tideCallout: Callout? = nil
local gather: { EndsAt: number, Count: number, Max: number }? = nil

local function refreshGather()
	local state = gather
	local callout = gatherCallout
	if not state or not callout then
		return
	end
	local remaining = state.EndsAt - now()
	if remaining <= 0 then
		gather = nil
		hideCallout(callout)
		return
	end
	local text = Strings.Format(GS.Gathering, { seconds = math.ceil(remaining), count = state.Count, max = state.Max })
	if callout.Label.Text ~= text or not callout.Group.Visible then
		showCallout(callout, text, UITheme.Colors.Accent)
	end
end

-- INTRO ---------------------------------------------------------------------------------------

local introMaid = Maid.new()
local introToken = 0

local function setHudHidden(hidden: boolean)
	Layers.Get("HUD").Enabled = not hidden
	Layers.Get("Touch").Enabled = not hidden
end

local function partNamed(model: Model, names: { string }): BasePart?
	for _, name in names do
		local found = model:FindFirstChild(name, true)
		if found and found:IsA("BasePart") then
			return found
		end
	end
	return nil
end

-- The intro shot: a low view of the claws rising (with a slight arc) to the helm.
local function introShot(model: Model, duration: number): ((dt: number) -> (CFrame, number))?
	local root = rootOf(model)
	if not root then
		return nil
	end
	local boxCFrame, extents = model:GetBoundingBox()
	local height = math.max(extents.Y, 6)
	local bottom = boxCFrame.Position.Y - extents.Y / 2
	local forward = MathUtil.FlatUnit(root.CFrame.LookVector)
	if forward.Magnitude < 0.5 then
		forward = Vector3.new(0, 0, -1)
	end
	local right = forward:Cross(Vector3.yAxis)
	local claw = partNamed(model, { "Claw", "RightHand" })
	local helm = partNamed(model, { "Helm", "Head" })
	local clawPoint = if claw then claw.Position else root.Position + forward * height * 0.2
	local helmPoint = if helm then helm.Position else Vector3.new(root.Position.X, bottom + height * 0.9, root.Position.Z)
	local startPos = clawPoint + forward * height * 0.55 + right * height * 0.18
	startPos = Vector3.new(startPos.X, math.max(bottom + 1.5, clawPoint.Y - height * 0.06), startPos.Z)
	local endPos = helmPoint + forward * height * 1.15 - Vector3.new(0, height * 0.18, 0)
	endPos = Vector3.new(endPos.X, math.max(bottom + 2, endPos.Y), endPos.Z)
	if isReduced() then
		local still = CFrame.lookAt(endPos, helmPoint)
		return function(_dt: number): (CFrame, number)
			return still, 55
		end
	end
	local sweep = math.max(0.5, duration * 0.85)
	local elapsed = 0
	return function(dt: number): (CFrame, number)
		elapsed += dt
		local alpha = math.clamp(elapsed / sweep, 0, 1)
		local eased = (1 - math.cos(alpha * math.pi)) / 2
		local arc = right * math.sin(eased * math.pi) * height * 0.25
		local position = startPos:Lerp(endPos, eased) + arc
		local look = clawPoint:Lerp(helmPoint, eased)
		return CFrame.lookAt(position, look), 62 - 8 * eased
	end
end

local function endIntro(skipped: boolean)
	if not introActive then
		return
	end
	introActive = false
	introToken += 1
	local token = introToken
	CameraController.SetCinematic(nil, if skipped then 0.35 else 0.8)
	setHudHidden(false)
	refreshBarVisibility()
	-- Fade the letterbox and card out, then clear.
	local screen = introMaid:Get("screen")
	if typeof(screen) == "Instance" and screen:IsA("CanvasGroup") then
		TweenUtil.Play(screen, 0.45, { GroupTransparency = 1 })
	end
	introMaid:Set("input", nil)
	introMaid:Set("timer", nil)
	task.delay(0.5, function()
		if introToken == token then
			introMaid:Clean()
		end
	end)
end

local function startIntro(model: Model?, duration: number, skippable: boolean)
	introMaid:Clean()
	if introActive then
		setHudHidden(false)
	end
	introActive = true
	introToken += 1
	silenced = nil
	LockOnController.Unlock()
	setHudHidden(true)
	refreshBarVisibility()
	local reduced = isReduced()
	local id = guardianIdOf(model)

	local screen: CanvasGroup = Create.new("CanvasGroup", {
		Name = "GuardianIntro",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 20,
	})
	introMaid:Set("screen", screen)
	local top: Frame = Create.new("Frame", {
		Name = "LetterboxTop",
		Size = UDim2.fromScale(1, 0),
		BackgroundColor3 = UITheme.Colors.Overlay,
		BorderSizePixel = 0,
		Parent = screen,
	})
	local bottom: Frame = Create.new("Frame", {
		Name = "LetterboxBottom",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0),
		BackgroundColor3 = UITheme.Colors.Overlay,
		BorderSizePixel = 0,
		Parent = screen,
	})
	local barTime = if reduced then 0.2 else 0.6
	TweenUtil.Play(top, barTime, { Size = UDim2.fromScale(1, G.Letterbox) }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	TweenUtil.Play(bottom, barTime, { Size = UDim2.fromScale(1, G.Letterbox) }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

	-- The name card, low on the screen above the bottom bar.
	local card: CanvasGroup = Create.new("CanvasGroup", {
		Name = "NameCard",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1 - G.Letterbox, -24),
		Size = UDim2.new(1, 0, 0, G.NameSize + 64),
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Parent = screen,
	})
	local cardScale: UIScale = Create.new("UIScale", { Scale = if reduced then 1 else 1.1, Parent = card })
	local nameLabel = Create.Label({
		Name = "GuardianName",
		Text = guardianName(id),
		Font = UITheme.Fonts.Display,
		TextSize = G.NameSize,
		Color = Color3.new(1, 1, 1),
		XAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, -40, 0, G.NameSize + 8),
		Position = UDim2.fromOffset(20, 0),
		Parent = card,
	})
	nameLabel.TextScaled = true
	nameLabel.TextStrokeTransparency = 0.4
	Create.new("UITextSizeConstraint", { MaxTextSize = G.NameSize, Parent = nameLabel })
	Create.new("UIGradient", {
		Color = ColorSequence.new(UITheme.Colors.Foam, UITheme.Colors.Accent),
		Rotation = 90,
		Parent = nameLabel,
	})
	local divider: Frame = Create.new("Frame", {
		Name = "Divider",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, G.NameSize + 12),
		Size = UDim2.fromOffset(if reduced then 360 else 0, 2),
		BackgroundColor3 = UITheme.Colors.Brass,
		BorderSizePixel = 0,
		Parent = card,
	})
	local subtitle = Create.Label({
		Name = "Subtitle",
		Text = GS.Subtitles[id] or "",
		Font = UITheme.Fonts.DisplayRegular,
		TextSize = UITheme.TextSize.Heading,
		Color = UITheme.Colors.TextMuted,
		XAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, -40, 0, 30),
		Position = UDim2.fromOffset(20, G.NameSize + 22),
		Parent = card,
	})
	subtitle.TextStrokeTransparency = 0.6
	subtitle.TextTransparency = 1

	if skippable then
		local device = InputController.GetDevice()
		local key = if device == "Touch" then Strings.Prompts.Tap else InputController.GetPrompt("LightAttack")
		local skip: TextButton = Create.new("TextButton", {
			Name = "Skip",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -24, 1 - G.Letterbox / 2, 0),
			Size = UDim2.fromOffset(0, UITheme.Size.MinTouchTarget),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = UITheme.Colors.HudPanel,
			BackgroundTransparency = 0.4,
			AutoButtonColor = false,
			FontFace = UITheme.Fonts.BodyMedium,
			TextSize = UITheme.TextSize.Small,
			TextColor3 = UITheme.Colors.TextMuted,
			Text = if device == "Touch" then GS.SkipIntroTouch else Strings.Format(GS.SkipIntro, { key = key }),
			ZIndex = 3,
			Parent = screen,
		})
		Create.Corner(skip, UITheme.CornerPill)
		Create.Stroke(skip, UITheme.Colors.Edge, 1, 0.5)
		Create.new("UIPadding", { PaddingLeft = UDim.new(0, 18), PaddingRight = UDim.new(0, 18), Parent = skip })
		introMaid:Add(Motion.AttachButtonFeedback(skip))
		local inputMaid = Maid.new()
		inputMaid:Add(skip.Activated:Connect(function()
			endIntro(true)
		end))
		inputMaid:Add(InputController.ActionBegan:Connect(function(action: string)
			if SKIP_ACTIONS[action] then
				endIntro(true)
			end
		end))
		inputMaid:Add(UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if not processed and SKIP_KEYS[input.KeyCode] then
				endIntro(true)
			end
		end))
		introMaid:Set("input", inputMaid)
	end
	screen.Parent = Layers.Get("Overlay")

	-- Camera sweep.
	local shot = if model then introShot(model, duration) else nil
	if shot then
		CameraController.SetCinematic(shot)
	end

	-- Card in after the letterbox settles.
	introMaid:Add(task.delay(if reduced then 0.1 else 0.45, function()
		TweenUtil.Play(card, 0.7, { GroupTransparency = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		if not reduced then
			TweenUtil.Play(cardScale, 1.4, { Scale = 1 }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
			TweenUtil.Play(divider, 0.9, { Size = UDim2.fromOffset(360, 2) }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
		end
		task.wait(0.35)
		TweenUtil.Play(subtitle, 0.6, { TextTransparency = 0 })
	end))
	introMaid:Set("timer", task.delay(duration, function()
		endIntro(false)
	end))
	introMaid:Add(function()
		-- A cleaned intro (new intro or teardown) never leaves the camera or HUD captured.
		if not introActive then
			return
		end
		CameraController.SetCinematic(nil, 0.3)
	end)
end

-- PHASE ---------------------------------------------------------------------------------------

local phaseMaid = Maid.new()

local function showPhase(model: Model?, phase: number, duration: number)
	local id = if model then guardianIdOf(model) else guardianIdOf(bound)
	local names = GS.Phases[id]
	local hints = GS.PhaseHints[id]
	local reduced = isReduced()
	phaseMaid:Clean()

	local card = buildCard("GuardianPhase", 0.24, {
		{ Text = if names then names[phase] or "" else "", Font = UITheme.Fonts.Display, Size = 40, Color = UITheme.Colors.Text, Gradient = ColorSequence.new(UITheme.Colors.Foam, GOLD) },
		{ Text = if hints then hints[phase] or "" else "", Font = UITheme.Fonts.Body, Size = UITheme.TextSize.BodyLarge, Color = UITheme.Colors.TextMuted },
	}, true)
	phaseMaid:Add(card.Group)
	-- Pips sit above the name.
	local holder: Frame = Create.new("Frame", {
		Name = "PipRow",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, G.PipSize * 1.6 + 4),
		LayoutOrder = 0,
		Parent = card.Group:FindFirstChild("Lines"),
	})
	local pips = buildPips(holder, math.floor(G.PipSize * 1.6), 12)
	local row = holder:FindFirstChild("Pips")
	if row and row:IsA("Frame") then
		row.AnchorPoint = Vector2.new(0.5, 0)
		row.Position = UDim2.fromScale(0.5, 0)
	end
	setPips(pips, phase)

	CameraController.Shake(0.45)
	CameraController.Punch(Config.Camera.PunchDegrees * 0.5)
	if id ~= "" and (model or bound) ~= silenced then
		playPhaseMusic(id, phase)
	end
	local b = bar
	if b then
		setPips(b.Pips, phase)
	end
	phaseMaid:Add(task.spawn(function()
		reveal(card, if reduced then 0.25 else 0.5)
		task.wait(math.max(1.5, duration))
		conceal(card, 0.5)
		card.Group:Destroy()
	end))
end

-- VICTORY -------------------------------------------------------------------------------------

local victoryMaid = Maid.new()

local function slowMotion(model: Model, seconds: number)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for _, track in animator:GetPlayingAnimationTracks() do
			track:AdjustSpeed(track.Speed * SLOW_MO_SPEED)
		end
	end
	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = "SpireGuardianVictory"
	effect.Parent = Lighting
	victoryMaid:Add(effect)
	TweenUtil.Play(effect, seconds * 0.7, { Saturation = -0.8, Contrast = 0.12 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	victoryMaid:Add(task.delay(seconds, function()
		local tween = TweenUtil.Play(effect, 1.4, { Saturation = 0, Contrast = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
		tween.Completed:Once(function()
			effect:Destroy()
		end)
	end))
end

-- A slow push toward the fallen Guardian with the field of view easing in.
local function victoryShot(model: Model, seconds: number): ((dt: number) -> (CFrame, number))?
	local camera = Workspace.CurrentCamera
	local root = rootOf(model)
	if not camera or not root then
		return nil
	end
	local start = camera.CFrame
	local startFov = camera.FieldOfView
	local boxCFrame = model:GetBoundingBox()
	local focus = boxCFrame.Position
	local goalPos = start.Position:Lerp(focus, 0.3)
	local elapsed = 0
	return function(dt: number): (CFrame, number)
		elapsed += dt
		local alpha = math.clamp(elapsed / seconds, 0, 1)
		local eased = 1 - (1 - alpha) ^ 3
		local look = (start.Position + start.LookVector * 10):Lerp(focus, eased)
		return CFrame.lookAt(start.Position:Lerp(goalPos, eased), look), startFov + (startFov * 0.8 - startFov) * eased
	end
end

local function onVictory(payload: { [string]: any })
	local model = modelOf(payload.Model) or bound
	local id = guardianIdOf(model)
	local def = Guardians.Get(id)
	local seconds = GUARDIAN.VictorySlowMo
	local reduced = isReduced()
	victoryMaid:Clean()

	MusicController.Sting(Config.Environment.Sounds.Bell, 0.55)
	MusicController.Stop(seconds)
	if model then
		slowMotion(model, seconds)
		local shot = if reduced then nil else victoryShot(model, seconds)
		if shot then
			CameraController.SetCinematic(shot)
			victoryMaid:Add(function()
				if CameraController.IsCinematic() then
					CameraController.SetCinematic(nil, 0.3)
				end
			end)
		end
	end

	local fightSeconds = if type(payload.Seconds) == "number" then payload.Seconds else 0
	local party = joinNames(payload.Names, true)
	local unlocked = if type(payload.Unlocked) == "string" then payload.Unlocked else nil
	local firstClear = payload.FirstClear == true

	victoryMaid:Add(task.spawn(function()
		task.wait(seconds)
		if CameraController.IsCinematic() then
			CameraController.SetCinematic(nil, 0.9)
		end
		local tracks = MUSIC.Guardian[id]
		if tracks then
			MusicController.Sting(tracks.Victory)
		end
		local felled = buildCard("GuardianFelled", 0.4, {
			{ Text = GS.Victory, Font = UITheme.Fonts.Display, Size = G.CardTitleSize, Color = GOLD, Gradient = ColorSequence.new(UITheme.Colors.Foam, GOLD) },
			{ Text = guardianName(id), Font = UITheme.Fonts.DisplayRegular, Size = UITheme.TextSize.Title, Color = UITheme.Colors.Text },
			{ Text = Strings.Format(GS.VictoryTime, { time = MathUtil.FormatDuration(fightSeconds) }), Font = UITheme.Fonts.Numbers, Size = UITheme.TextSize.Heading, Color = UITheme.Colors.Accent },
			{ Text = if party ~= "" then Strings.Format(GS.VictoryParty, { names = party }) else GS.VictorySolo, Font = UITheme.Fonts.Body, Size = UITheme.TextSize.BodyLarge, Color = UITheme.Colors.TextMuted },
		}, true)
		victoryMaid:Add(felled.Group)
		UISound.Play("LevelUp")
		present(felled, FELLED_HOLD)

		if unlocked then
			local lines: { Line } = {
				{
					Text = Strings.Format(GS.Unlocked, { floor = unlocked, name = GS.Floors[unlocked] or unlocked }),
					Font = UITheme.Fonts.Display,
					Size = 40,
					Color = UITheme.Colors.Current,
					Gradient = ColorSequence.new(UITheme.Colors.Foam, UITheme.Colors.Current),
				},
			}
			if firstClear then
				table.insert(lines, {
					Text = Strings.Format(GS.FirstClear, {
						shards = if def then def.Rewards.Shards else 0,
						points = Config.Progression.GuardianBonusSkillPoints,
					}),
					Font = UITheme.Fonts.BodyMedium,
					Size = UITheme.TextSize.BodyLarge,
					Color = GOLD,
				})
			end
			local unlock = buildCard("GuardianUnlock", 0.4, lines, true)
			victoryMaid:Add(unlock.Group)
			UISound.Play("LevelUpHigh")
			present(unlock, UNLOCK_HOLD)
		end
	end))
end

-- EVENTS --------------------------------------------------------------------------------------

local cardMaid = Maid.new()

local function onWipe()
	silenced = bound
	MusicController.Stop()
	phaseMaid:Clean()
	tideEvent = nil
	local card = buildCard("GuardianWipe", 0.3, {
		{ Text = GS.Wipe, Font = UITheme.Fonts.Display, Size = UITheme.TextSize.Hero, Color = UITheme.Colors.Text },
		{ Text = GS.WipeHint, Font = UITheme.Fonts.DisplayRegular, Size = UITheme.TextSize.BodyLarge, Color = UITheme.Colors.TextMuted },
	}, true)
	cardMaid:Set("wipe", card.Group)
	task.spawn(present, card, WIPE_HOLD)
end

local function onBanner(payload: { [string]: any })
	local names = joinNames(payload.Names, false)
	local floor = if type(payload.Floor) == "string" or type(payload.Floor) == "number" then tostring(payload.Floor) else ""
	if payload.Scope == "Global" then
		Components.Toast.Push({
			Title = Strings.Format(GS.BannerGlobal, { floor = floor, names = names }),
			Color = GOLD,
			Duration = BANNER_HOLD,
		})
		return
	end
	local card = buildCard("GuardianBanner", 0.13, {
		{ Text = Strings.Format(GS.BannerServer, { floor = floor, names = names }), Font = UITheme.Fonts.Display, Size = 34, Color = GOLD, Gradient = ColorSequence.new(UITheme.Colors.Foam, GOLD) },
	}, true)
	cardMaid:Set("banner", card.Group)
	UISound.Play("LevelUpHigh")
	task.spawn(present, card, BANNER_HOLD)
end

local function onTide(payload: { [string]: any })
	local state = if type(payload.State) == "string" then payload.State else "Calm"
	local endsAt = if type(payload.EndsAt) == "number" then payload.EndsAt else 0
	local warning = payload.Warning == true
	tideEvent = { State = state, EndsAt = endsAt, Warning = warning }
	refreshTide()
	local callout = tideCallout
	if warning and callout then
		local def = Guardians.Get(guardianIdOf(modelOf(payload.Model) or bound))
		showCallout(callout, GS.TideTurning, G.HighTide, if def then def.Tide.WarnSeconds else 1.5)
	end
end

local function onGuardianEvent(kind: any, payload: any)
	if type(kind) ~= "string" then
		return
	end
	local data: { [string]: any } = if type(payload) == "table" then payload else {}
	if kind == "Gather" then
		local endsAt = data.EndsAt
		if type(endsAt) == "number" then
			gather = {
				EndsAt = endsAt,
				Count = if type(data.Count) == "number" then data.Count else 1,
				Max = if type(data.Max) == "number" then data.Max else GUARDIAN.MaxPlayers,
			}
			refreshGather()
		end
	elseif kind == "Intro" then
		gather = nil
		if gatherCallout then
			hideCallout(gatherCallout)
		end
		local duration = if type(data.Duration) == "number" then math.clamp(data.Duration, 0.5, 15) else GUARDIAN.IntroDuration
		startIntro(modelOf(data.Model), duration, data.Skippable == true)
	elseif kind == "Phase" then
		local phase = if type(data.Phase) == "number" then math.clamp(math.floor(data.Phase), 1, 3) else 1
		local model = modelOf(data.Model)
		local def = Guardians.Get(guardianIdOf(model or bound))
		local duration = if type(data.Duration) == "number" then data.Duration elseif def then def.Transition else DEFAULT_TRANSITION
		showPhase(model, phase, duration)
	elseif kind == "Tide" then
		onTide(data)
	elseif kind == "Victory" then
		onVictory(data)
	elseif kind == "Wipe" then
		onWipe()
	elseif kind == "Banner" then
		onBanner(data)
	end
end

-- LIFECYCLE -----------------------------------------------------------------------------------

function GuardianController.Init()
	Net.OnClient("GuardianEvent", onGuardianEvent)
end

function GuardianController.Start()
	bar = buildBar()
	layoutBar()
	Device.Changed:Connect(function()
		layoutBar()
	end)
	gatherCallout = buildCallout("GuardianGather", 0.17, UITheme.TextSize.Body, UITheme.Fonts.BodyMedium)
	tideCallout = buildCallout("GuardianTide", 0.33, UITheme.TextSize.Title, UITheme.Fonts.Display)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < SCAN_INTERVAL then
			return
		end
		accumulator = 0
		local found = findGuardian()
		if found ~= bound then
			if found then
				bind(found)
			else
				unbind()
			end
		end
		refreshTide()
		refreshGather()
	end)
	player.CharacterAdded:Connect(function()
		-- Respawning (after a wipe) never inherits a captured camera or hidden HUD.
		if introActive then
			endIntro(true)
		end
	end)
end

return GuardianController
