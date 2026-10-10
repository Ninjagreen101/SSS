--!strict
--[[
	TutorialController
	What a new Climber sees of the docks tutorial (docs/PHASE11_QUESTS.md section 5). The server
	(TutorialService) runs the steps and sends Net "TutorialStep"(step, payload); step 0 means it
	is over. This controller only presents them, and never blocks movement or combat input:
	nothing here is modal and only the Skip and Continue buttons take clicks.

	- Prompt: one short line (Strings.Tutorial.Prompts) with key / button chips for the current
	  device (InputController.GetPrompt). On touch the matching on-screen button gets a pulsing
	  ring instead. A parry counter during step 5.
	- Old Pell's call-outs under the prompt: on step changes, and timed to the tutor's blows
	  (MobBlow) during the dodge and parry steps: "Now!" lands Parry.Window before the impact.
	- Waypoint: a beam from the player to the step's mob (or point) and a marker over it.
	- Spell step: SpellController.SetPreviewSpell lets an empty first slot cast the preview Tide
	  Bolt (the server allows it for that step only).
	- Night: EnvironmentController.SetClockOverride(Config.Quests.Tutorial.NightClock) while it
	  runs, back to the shared day after.
	- Resonance: the big centre card (title, two short sentences, a Continue button of at least
	  44 px; Interact also continues). Shown once, when the server says the card is open.
	- Skip: a button that appears at the server's SkipAt time.
	- Welcome banner at the start, a completion flourish at the end.
	Reduced Motion: no pops, pulses or beam scroll; plain fades only.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local Maid = require(Shared.Util.Maid)
local TweenUtil = require(Shared.Util.TweenUtil)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Motion = require(UI.Motion)
local Animator = require(UI.Animator)
local Device = require(UI.Device)
local UISound = require(UI.UISound)

local DataController = require(script.Parent.DataController)
local InputController = require(script.Parent.InputController)
local EnvironmentController = require(script.Parent.EnvironmentController)
local SpellController = require(script.Parent.SpellController)

local A = Attributes.Names
local C = UITheme.Colors
local TS = Strings.Tutorial
local TUT = Config.Quests.Tutorial
local PARRY_LEAD = Config.Combat.Parry.Window
local player = Players.LocalPlayer

local TutorialController = {}

local PROMPT_Y = 108 -- px from the top of the HUD layer
local CALLOUT_HOLD = 2.4
local WELCOME_HOLD = 2.6
local FLOURISH_HOLD = 3.5
local FADE = 0.2
local MARKER_SIZE = 22
local MARKER_LIFT = 4.5 -- studs above a point marker
local BEAM_WIDTH = 0.5
local TOUCH_RING_SCALE = 1.35

-- Step name -> the action whose key or button the prompt shows (Move and Sprint are special).
local STEP_ACTIONS: { [string]: string } = {
	Combo = "LightAttack",
	Dodge = "Dodge",
	Parry = "Block",
	Spell = "Cast1",
	Resonance = "LightAttack",
	Finish = "LightAttack",
}
-- Action -> on-screen touch button id (Config.Input.TouchButtons).
local TOUCH_BUTTONS: { [string]: string } = {
	LightAttack = "Attack",
	Dodge = "Dodge",
	Block = "Block",
	Cast1 = "Cast1",
}
-- Old Pell's line when a step begins.
local STEP_CALLOUTS: { [string]: string } = {
	Combo = "Combo",
	Spell = "Spell",
	Finish = "Finish",
}

type Payload = {
	Kind: string,
	Name: string,
	Point: Vector3?,
	Target: Model?,
	Count: number,
	Needed: number,
	CardOpen: boolean,
	SkipAt: number,
}

type View = {
	Prompt: Frame,
	Chips: Frame,
	Text: TextLabel,
	Counter: TextLabel,
	Callout: TextLabel,
	Skip: TextButton,
	Card: CanvasGroup,
	CardScale: UIScale,
	Banner: CanvasGroup,
	BannerScale: UIScale,
	BannerTitle: TextLabel,
	BannerBody: TextLabel,
}

local view: View? = nil
local active = false
local step = 0
local payload: Payload? = nil
local cardShown = false
local welcomed = false
local calloutToken = 0
local stepMaid = Maid.new() -- marker, touch ring, tutor blow watcher
local skipMaid = Maid.new()

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

-- PAYLOAD ------------------------------------------------------------------------------------

local function readPayload(raw: any): Payload
	local data = if type(raw) == "table" then raw else {}
	local target = data.Target
	local point = data.Point
	return {
		Kind = if type(data.Kind) == "string" then data.Kind else "Step",
		Name = if type(data.Name) == "string" then data.Name else "",
		Point = if typeof(point) == "Vector3" then point else nil,
		Target = if typeof(target) == "Instance" and target:IsA("Model") then target else nil,
		Count = if type(data.Count) == "number" then data.Count else 0,
		Needed = if type(data.Needed) == "number" then data.Needed else 0,
		CardOpen = data.CardOpen == true,
		SkipAt = if type(data.SkipAt) == "number" then data.SkipAt else 0,
	}
end

-- BUILD --------------------------------------------------------------------------------------

local function fadeGroup(group: CanvasGroup, scale: UIScale, visible: boolean)
	if visible then
		if isReduced() then
			group.Visible = true
			scale.Scale = 1
			TweenUtil.Play(group, FADE, { GroupTransparency = 0 })
		else
			Motion.Open(group, scale)
		end
	elseif group.Visible then
		task.spawn(Motion.Close, group, scale)
	end
end

local function sendContinue()
	local v = view
	if not v or not v.Card.Visible then
		return
	end
	UISound.Play("UIConfirm")
	Net.FireServer("RequestTutorial", "Continue")
	fadeGroup(v.Card, v.CardScale, false)
end

local function build(): View
	local hud = Layers.Get("HUD")

	-- Prompt pill: chips + one line, centred near the top. Never takes input.
	local prompt: Frame = Create.new("Frame", {
		Name = "TutorialPrompt",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, PROMPT_Y),
		Size = UDim2.fromOffset(0, 44),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.HudPanel,
		BackgroundTransparency = 0.25,
		Active = false,
		Visible = false,
		Parent = hud,
	})
	Create.Corner(prompt, UITheme.CornerPill)
	Create.Stroke(prompt, C.Current, 1.5, 0.35)
	Create.new("UIPadding", { PaddingLeft = UDim.new(0, 18), PaddingRight = UDim.new(0, 18), Parent = prompt })
	Create.List(prompt, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)

	local chips: Frame = Create.new("Frame", {
		Name = "Chips",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 1,
		Parent = prompt,
	})
	Create.List(chips, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)

	local text = Create.Label({
		Name = "Text",
		Text = "",
		Font = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.BodyLarge,
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = prompt,
	})
	text.TextStrokeTransparency = 0.7

	local counter = Create.Label({
		Name = "Counter",
		Text = "",
		Font = UITheme.Fonts.Numbers,
		TextSize = UITheme.TextSize.Body,
		Color = C.Parry,
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 3,
		Parent = prompt,
	})

	local callout = Create.Label({
		Name = "TutorialCallout",
		Text = "",
		Font = UITheme.Fonts.DisplayRegular,
		TextSize = UITheme.TextSize.Body,
		Color = C.Foam,
		XAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, PROMPT_Y + 52),
		Size = UDim2.new(0.6, 0, 0, 26),
		Parent = hud,
	})
	callout.TextStrokeTransparency = 0.4
	callout.TextTransparency = 1

	-- Skip: left edge, clear of the vitals, the tracker and the touch cluster.
	local skip: TextButton = Create.new("TextButton", {
		Name = "TutorialSkip",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 16, 0.42, 0),
		Size = UDim2.fromOffset(0, UITheme.Size.MinTouchTarget),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.HudPanel,
		BackgroundTransparency = 0.35,
		AutoButtonColor = false,
		FontFace = UITheme.Fonts.BodyMedium,
		TextSize = UITheme.TextSize.Small,
		TextColor3 = C.TextMuted,
		Text = TS.Skip,
		Visible = false,
		Parent = hud,
	})
	Create.Corner(skip, UITheme.CornerPill)
	Create.Stroke(skip, C.Edge, 1, 0.5)
	Create.new("UIPadding", { PaddingLeft = UDim.new(0, 18), PaddingRight = UDim.new(0, 18), Parent = skip })
	Motion.AttachButtonFeedback(skip)
	skip.Activated:Connect(function()
		UISound.Play("UIClick")
		skip.Visible = false
		Net.FireServer("RequestTutorial", "Skip")
	end)

	-- The big Resonance card (Overlay layer, centre). Only its button takes input.
	local overlay = Layers.Get("Overlay")
	local card: CanvasGroup = Create.new("CanvasGroup", {
		Name = "TutorialResonance",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromOffset(460, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.Midnight,
		BackgroundTransparency = 0.08,
		GroupTransparency = 1,
		Visible = false,
		Parent = overlay,
	})
	Create.Corner(card)
	Create.Stroke(card, C.Current, 2, 0.1)
	Create.Padding(card, 24)
	Create.List(card, Enum.FillDirection.Vertical, 12, Enum.HorizontalAlignment.Center)
	local cardScale: UIScale = Create.new("UIScale", { Parent = card })
	local title = Create.Label({
		Name = "Title",
		Text = TS.ResonanceTitle,
		Font = UITheme.Fonts.Display,
		TextSize = UITheme.TextSize.Hero,
		Color = C.Current,
		XAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, UITheme.TextSize.Hero + 8),
		LayoutOrder = 1,
		Parent = card,
	})
	title.TextStrokeTransparency = 0.6
	Create.Label({
		Name = "Body",
		Text = TS.ResonanceBody,
		TextSize = UITheme.TextSize.BodyLarge,
		XAlignment = Enum.TextXAlignment.Center,
		Wrapped = true,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = card,
	})
	local continueButton: TextButton = Create.new("TextButton", {
		Name = "Continue",
		Size = UDim2.fromOffset(220, math.max(UITheme.Size.MinTouchTarget, UITheme.Size.ButtonHeightTouch)),
		BackgroundColor3 = C.Current,
		AutoButtonColor = false,
		FontFace = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.BodyLarge,
		TextColor3 = C.TextOnAccent,
		Text = TS.Continue,
		LayoutOrder = 3,
		Parent = card,
	})
	Create.Corner(continueButton, UITheme.CornerPill)
	Motion.AttachButtonFeedback(continueButton)
	continueButton.Activated:Connect(sendContinue)

	-- Welcome / finished banner.
	local banner: CanvasGroup = Create.new("CanvasGroup", {
		Name = "TutorialBanner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.3),
		Size = UDim2.new(0.8, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Visible = false,
		Parent = overlay,
	})
	Create.List(banner, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center)
	local bannerScale: UIScale = Create.new("UIScale", { Parent = banner })
	local bannerTitle = Create.Label({
		Name = "Title",
		Text = "",
		Font = UITheme.Fonts.Display,
		TextSize = UITheme.TextSize.Title,
		Color = C.Foam,
		XAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, UITheme.TextSize.Title + 8),
		LayoutOrder = 1,
		Parent = banner,
	})
	bannerTitle.TextStrokeTransparency = 0.5
	local bannerBody = Create.Label({
		Name = "Body",
		Text = "",
		TextSize = UITheme.TextSize.BodyLarge,
		Color = C.Accent,
		XAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, UITheme.TextSize.BodyLarge + 8),
		LayoutOrder = 2,
		Parent = banner,
	})
	bannerBody.TextStrokeTransparency = 0.6

	return {
		Prompt = prompt,
		Chips = chips,
		Text = text,
		Counter = counter,
		Callout = callout,
		Skip = skip,
		Card = card,
		CardScale = cardScale,
		Banner = banner,
		BannerScale = bannerScale,
		BannerTitle = bannerTitle,
		BannerBody = bannerBody,
	}
end

local function getView(): View
	local existing = view
	if existing then
		return existing
	end
	local created = build()
	view = created
	return created
end

-- PROMPT -------------------------------------------------------------------------------------

local function addChip(parent: Frame, label: string)
	local chip: TextLabel = Create.new("TextLabel", {
		Name = "Chip",
		Size = UDim2.fromOffset(0, 28),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.HudRaised,
		BackgroundTransparency = 0.1,
		FontFace = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.Small,
		TextColor3 = C.Text,
		Text = label,
		Parent = parent,
	})
	Create.Corner(chip, UITheme.CornerSmall)
	Create.Stroke(chip, C.EdgeBright, 1, 0.3)
	Create.new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = chip })
end

-- A pulsing ring around one of the on-screen touch buttons.
local function ringTouchButton(buttonId: string, maid: Maid.Maid)
	local controls = Layers.Get("Touch"):FindFirstChild("TouchControls")
	local button = controls and controls:FindFirstChild(buttonId)
	if not button or not button:IsA("GuiObject") then
		return
	end
	local ring: Frame = Create.new("Frame", {
		Name = "TutorialRing",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(TOUCH_RING_SCALE, TOUCH_RING_SCALE),
		BackgroundTransparency = 1,
		Active = false,
		Parent = button,
	})
	Create.Corner(ring, UITheme.CornerPill)
	local stroke = Create.Stroke(ring, C.Current, 3, 0.1)
	maid:Add(ring)
	if not isReduced() then
		maid:Add(Animator.Pulse(stroke, "Transparency", 0.05, 0.7, 1.1))
	end
end

local function renderPrompt()
	local v = getView()
	local data = payload
	stepMaid:Set("Ring", nil)
	for _, child in v.Chips:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	if not active or not data or data.CardOpen then
		v.Prompt.Visible = false
		return
	end
	local name = data.Name
	local device = Device.Current()
	local line = TS.Prompts[name] or ""
	if name == "Move" then
		addChip(v.Chips, if device == "Touch" then TS.Glyphs.MoveTouch elseif device == "Gamepad" then TS.Glyphs.MoveStick else TS.Glyphs.MoveKeys)
	elseif name == "Sprint" then
		line = if device == "Touch" then TS.Prompts.SprintTouch else Strings.Format(TS.Prompts.Sprint, { key = InputController.GetPrompt("Sprint") })
	else
		local action = STEP_ACTIONS[name]
		if action then
			if device == "Touch" then
				local buttonId = TOUCH_BUTTONS[action]
				if buttonId then
					local ringMaid = Maid.new()
					stepMaid:Set("Ring", ringMaid)
					ringTouchButton(buttonId, ringMaid)
				end
			else
				addChip(v.Chips, InputController.GetPrompt(action))
			end
		end
	end
	v.Chips.Visible = #v.Chips:GetChildren() > 1 -- the list layout is always there
	v.Text.Text = line
	v.Counter.Text = if data.Needed > 0 then Strings.Format(TS.Count, { done = data.Count, total = data.Needed }) else ""
	v.Counter.Visible = data.Needed > 0
	v.Prompt.Visible = line ~= ""
end

-- CALLOUTS -----------------------------------------------------------------------------------

local function callout(key: string, emphasis: boolean)
	local line = TS.Callouts[key]
	if not line then
		return
	end
	local v = getView()
	calloutToken += 1
	local token = calloutToken
	v.Callout.Text = `{TS.Tutor}: {line}`
	v.Callout.TextColor3 = if emphasis then C.Parry else C.Foam
	v.Callout.TextSize = if emphasis then UITheme.TextSize.Heading else UITheme.TextSize.Body
	v.Callout.TextTransparency = 0
	v.Callout.TextStrokeTransparency = 0.4
	task.delay(CALLOUT_HOLD, function()
		if calloutToken == token then
			TweenUtil.Play(v.Callout, FADE, { TextTransparency = 1, TextStrokeTransparency = 1 })
		end
	end)
end

-- During the dodge and parry steps, Pell reads the tutor's blows (MobBlow "slot;windup;start;flag").
local function watchTutor(model: Model?, name: string)
	stepMaid:Set("Blows", nil)
	if not model or (name ~= "Dodge" and name ~= "Parry") then
		return
	end
	local blows = Maid.new()
	stepMaid:Set("Blows", blows)
	blows:Add(model:GetAttributeChangedSignal(A.MobBlow):Connect(function()
		local raw = model:GetAttribute(A.MobBlow)
		if type(raw) ~= "string" then
			return
		end
		local parts = string.split(raw, ";")
		local windup = tonumber(parts[2])
		local started = tonumber(parts[3])
		if not windup or not started then
			return
		end
		if name == "Dodge" then
			callout("DodgeWatch", false)
			return
		end
		callout("ParryWatch", false)
		local delay = started + windup - PARRY_LEAD - now()
		blows:Add(task.delay(math.max(0, delay), function()
			if active and step == 5 then
				callout("ParryNow", true)
			end
		end))
	end))
end

-- WAYPOINT -----------------------------------------------------------------------------------

local function buildMarker(data: Payload)
	stepMaid:Set("Marker", nil)
	local character = player.Character
	local playerRoot = character and rootOf(character)
	local target = data.Target
	local targetRoot = if target then rootOf(target) else nil
	local point = data.Point
	if not playerRoot or (not targetRoot and not point) then
		return
	end
	local marker = Maid.new()
	stepMaid:Set("Marker", marker)

	local from: Attachment = marker:Add(Create.new("Attachment", { Name = "TutorialFrom", Parent = playerRoot }))
	local to: Attachment
	if targetRoot then
		to = marker:Add(Create.new("Attachment", { Name = "TutorialTo", Parent = targetRoot }))
	else
		to = marker:Add(Create.new("Attachment", {
			Name = "TutorialTo",
			Position = (point :: Vector3) + Vector3.new(0, MARKER_LIFT, 0),
			Parent = Workspace.Terrain,
		}))
	end
	local reduced = isReduced()
	marker:Add(Create.new("Beam", {
		Name = "TutorialBeam",
		Attachment0 = from,
		Attachment1 = to,
		Color = ColorSequence.new(C.Current),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.85), NumberSequenceKeypoint.new(0.5, 0.45), NumberSequenceKeypoint.new(1, 0.2) }),
		Width0 = BEAM_WIDTH,
		Width1 = BEAM_WIDTH,
		FaceCamera = true,
		LightEmission = 1,
		Segments = 12,
		CurveSize0 = 0,
		CurveSize1 = 0,
		TextureSpeed = if reduced then 0 else 1,
		Parent = Workspace.Terrain,
	}))

	local billboard: BillboardGui = marker:Add(Create.new("BillboardGui", {
		Name = "TutorialMarker",
		Adornee = to,
		AlwaysOnTop = true,
		LightInfluence = 0,
		Size = UDim2.fromOffset(MARKER_SIZE * 2, MARKER_SIZE * 2),
		StudsOffsetWorldSpace = if targetRoot then Vector3.new(0, MARKER_LIFT, 0) else Vector3.zero,
		Parent = player:WaitForChild("PlayerGui"),
	}))
	local diamond: Frame = Create.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(MARKER_SIZE, MARKER_SIZE),
		Rotation = 45,
		BackgroundColor3 = C.Current,
		BackgroundTransparency = 0.1,
		Parent = billboard,
	})
	Create.Stroke(diamond, C.Foam, 2, 0.2)
	if not reduced then
		marker:Add(Animator.Pulse(diamond, "BackgroundTransparency", 0.05, 0.5, 1.2))
	end
end

-- SKIP ---------------------------------------------------------------------------------------

local function scheduleSkip(data: Payload)
	skipMaid:Clean()
	local v = getView()
	if not active or data.SkipAt <= 0 then
		v.Skip.Visible = false
		return
	end
	local wait = data.SkipAt - now()
	if wait <= 0 then
		v.Skip.Visible = true
		return
	end
	v.Skip.Visible = false
	skipMaid:Add(task.delay(wait, function()
		if active then
			v.Skip.Visible = true
		end
	end))
end

-- BANNERS ------------------------------------------------------------------------------------

local function banner(title: string, body: string, hold: number)
	local v = getView()
	v.BannerTitle.Text = title
	v.BannerBody.Text = body
	fadeGroup(v.Banner, v.BannerScale, true)
	task.delay(hold, function()
		if v.BannerTitle.Text == title then
			fadeGroup(v.Banner, v.BannerScale, false)
		end
	end)
end

-- FLOW ---------------------------------------------------------------------------------------

local function stop(finished: boolean)
	active = false
	step = 0
	payload = nil
	calloutToken += 1
	stepMaid:Clean()
	skipMaid:Clean()
	EnvironmentController.SetClockOverride(nil)
	SpellController.SetPreviewSpell(nil)
	local v = view
	if v then
		v.Prompt.Visible = false
		v.Skip.Visible = false
		v.Callout.TextTransparency = 1
		v.Callout.TextStrokeTransparency = 1
		fadeGroup(v.Card, v.CardScale, false)
	end
	if finished then
		UISound.Play("LevelUp")
		banner(TS.FinishedTitle, TS.Finished, FLOURISH_HOLD)
	end
end

local function onStep(rawStep: any, rawPayload: any)
	local data = readPayload(rawPayload)
	local newStep = if type(rawStep) == "number" then rawStep else 0
	if newStep <= 0 then
		if active then
			stop(data.Kind == "Finished")
		end
		return
	end
	local changed = newStep ~= step
	active = true
	step = newStep
	payload = data
	EnvironmentController.SetClockOverride(TUT.NightClock)
	SpellController.SetPreviewSpell(if data.Name == "Spell" then TUT.PreviewSpell else nil)

	if not welcomed then
		welcomed = true
		banner(TS.Welcome, "", WELCOME_HOLD)
	end
	if changed then
		stepMaid:Clean()
		local key = STEP_CALLOUTS[data.Name]
		if key then
			callout(key, false)
		end
		if newStep > 1 then
			UISound.Play("UIConfirm")
		end
	elseif data.Name == "Parry" and data.Count > 0 then
		callout("ParryGood", false)
	end

	renderPrompt()
	buildMarker(data)
	watchTutor(data.Target, data.Name)
	scheduleSkip(data)

	local v = getView()
	if data.CardOpen and not cardShown then
		cardShown = true
		UISound.Play("UIOpen")
		fadeGroup(v.Card, v.CardScale, true)
	elseif not data.CardOpen and v.Card.Visible then
		fadeGroup(v.Card, v.CardScale, false)
	end
end

-- LIFECYCLE ----------------------------------------------------------------------------------

function TutorialController.Init()
	Net.OnClient("TutorialStep", onStep)
end

function TutorialController.Start()
	InputController.DeviceChanged:Connect(function()
		if active then
			renderPrompt()
		end
	end)
	InputController.BindingsChanged:Connect(function()
		if active then
			renderPrompt()
		end
	end)
	InputController.ActionBegan:Connect(function(action: string)
		if action == "Interact" and active then
			sendContinue()
		end
	end)
	-- The beam hangs off the character: rebuild it after a respawn.
	player.CharacterAdded:Connect(function(character: Model)
		local data = payload
		if active and data then
			task.spawn(function()
				character:WaitForChild("HumanoidRootPart", 10)
				if active and payload == data then
					buildMarker(data)
				end
			end)
		end
	end)
end

return TutorialController
