--!strict
--[[
	EmoteController (Phase 12)
	- The wheel: hold the Emote action (T; LT + Y on a gamepad; the EMOTE touch button) to open a
	  ring of the 8 slotted emotes. Aim with the mouse (the cursor is freed while it is open) or the
	  right stick; release to play the highlighted one. On touch a quick tap leaves the wheel open so
	  an emote can be tapped. Clicking or tapping an emote always plays it.
	- Playing: the emote's animation runs on your own Animator (Roblox replicates it to everyone).
	  It stops when you move, jump, attack, dodge, block, cast, take damage or die, and a cooldown
	  (Config.Social.Emotes.Cooldown) spaces them out.
	- The Emotes page (menu, key OpenEmotes, also in the menu hub): choose a slot, then an emote to
	  put in it (RequestSetEmoteSlot; the server validates and saves Social.Emotes). An empty saved
	  wheel shows the first eight emotes (Emotes.Resolve).
	The UI is built once and reused.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local Maid = require(Shared.Util.Maid)
local TweenUtil = require(Shared.Util.TweenUtil)
local Emotes = require(Shared.Data.Emotes)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Motion = require(UI.Motion)
local Device = require(UI.Device)
local UISound = require(UI.UISound)
local Components = require(UI.Components)

local DataController = require(script.Parent.DataController)
local InputController = require(script.Parent.InputController)
local UIController = require(script.Parent.UIController)

local A = Attributes.Names
local C = UITheme.Colors
local S = Strings.Emotes
local player = Players.LocalPlayer

local MENU_ID = "Emotes"
local NODE_SIZE = 88
local RADIUS = 140
local ROW_HEIGHT = 46
local COLUMN_TOP = 74
local DEAD_ZONE = 0.12 -- mouse: fraction of the ring's width around the centre that selects nothing
local STICK_THRESHOLD = 0.5

-- Actions that end a playing emote (and close the wheel).
local CANCELLING: { [string]: boolean } = {
	LightAttack = true,
	HeavyAttack = true,
	Dodge = true,
	Block = true,
	WeaponArt = true,
	Ability = true,
	Cast1 = true,
	Cast2 = true,
	Cast3 = true,
	Cast4 = true,
	Jump = true,
	Sprint = true,
}

type Node = {
	Button: TextButton,
	Stroke: UIStroke,
}

type Wheel = {
	Holder: Frame,
	Backdrop: TextButton,
	Ring: Frame,
	Scale: UIScale,
	Nodes: { Node },
	CentreName: TextLabel,
	Hint: TextLabel,
	Edit: Components.Button,
}

type Row = {
	Button: TextButton,
	Stroke: UIStroke,
	Main: TextLabel,
	Side: TextLabel,
}

local EmoteController = {}

local slots: { string } = Emotes.Resolve(nil)
local wheel: Wheel? = nil
local wheelOpen = false
local sticky = false
local selected: number? = nil
local ownsFreeCursor = false
local wheelMaid = Maid.new()

local playing: { Id: string, Track: AnimationTrack }? = nil
local playMaid = Maid.new()
local lastPlayed = -math.huge
local cache: { [string]: AnimationTrack } = {}
local cacheCharacter: Model? = nil

-- Page state.
local pageSlotRows: { Row } = {}
local pageEmoteRows: { [string]: Row } = {}
local pageHeader: TextLabel? = nil
local pageSlot = 1
local pageOpen = false

local function emoteName(id: string): string
	local def = Emotes.Get(id)
	return if def then (S.Names[def.Key] or def.Key) else S.Empty
end

local function toast(text: string)
	Components.Toast.Push({ Title = text, Color = C.TextMuted, Key = "EmoteNotice", Silent = true })
end

-- PLAYING ---------------------------------------------------------------------------------------

local function humanoidOf(): (Humanoid?, Model?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	return character:FindFirstChildOfClass("Humanoid"), character
end

local function isIdle(character: Model): boolean
	local state = character:GetAttribute(A.CombatState)
	return state == nil or state == "Idle"
end

local function isMoving(humanoid: Humanoid): boolean
	return humanoid.MoveDirection.Magnitude > Config.Input.MoveDeadzone
end

function EmoteController.Stop()
	local current = playing
	playing = nil
	playMaid:Clean()
	if current and current.Track.IsPlaying then
		current.Track:Stop(0.2)
	end
end

function EmoteController.GetPlaying(): string?
	return if playing then playing.Id else nil
end

local function trackFor(def: Emotes.EmoteDef, humanoid: Humanoid, character: Model): AnimationTrack?
	if cacheCharacter ~= character then
		cacheCharacter = character
		table.clear(cache)
	end
	local existing = cache[def.Id]
	if existing then
		return existing
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = def.Animation
	local ok, track = pcall(function(): AnimationTrack
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()
	if not ok then
		return nil
	end
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = def.Looped
	cache[def.Id] = track
	return track
end

-- Plays emote `id` on your character. Returns false (with a short notice) when it can't start.
function EmoteController.Play(id: string): boolean
	local def = Emotes.Get(id)
	local humanoid, character = humanoidOf()
	if not def or not humanoid or not character then
		return false
	end
	if humanoid.Health <= 0 then
		toast(S.Dead)
		return false
	end
	if os.clock() - lastPlayed < Config.Social.Emotes.Cooldown then
		toast(S.Cooldown)
		return false
	end
	if not isIdle(character) then
		toast(S.Busy)
		return false
	end
	if isMoving(humanoid) or humanoid:GetState() == Enum.HumanoidStateType.Freefall then
		toast(S.Moving)
		return false
	end
	local track = trackFor(def, humanoid, character)
	if not track then
		return false
	end
	EmoteController.Stop()
	lastPlayed = os.clock()
	track:Play(0.2)
	local current = { Id = id, Track = track }
	playing = current

	local lastHealth = humanoid.Health
	playMaid:Add(RunService.Heartbeat:Connect(function()
		if not isIdle(character) or isMoving(humanoid) or humanoid:GetState() == Enum.HumanoidStateType.Jumping then
			EmoteController.Stop()
		end
	end))
	playMaid:Add(humanoid.HealthChanged:Connect(function(health: number)
		if health < lastHealth or health <= 0 then
			EmoteController.Stop()
		end
		lastHealth = health
	end))
	playMaid:Add(track.Stopped:Connect(function()
		if playing == current then
			playing = nil
			playMaid:Clean()
		end
	end))
	return true
end

-- THE WHEEL ---------------------------------------------------------------------------------------

local function nodeCount(): number
	return Config.Social.Emotes.Slots
end

local function refreshWheel()
	local w = wheel
	if not w then
		return
	end
	for index, node in w.Nodes do
		local id = slots[index] or ""
		local isSelected = selected == index
		node.Button.Text = if id == "" then S.WheelEmpty else emoteName(id)
		node.Button.TextColor3 = if id == "" then C.TextDim else C.Text
		node.Button.BackgroundColor3 = if isSelected then C.PanelHover else C.PanelRaised
		node.Stroke.Color = if isSelected then C.Aqua else C.Edge
		node.Stroke.Thickness = if isSelected then 3 else 1.5
		node.Stroke.Transparency = if isSelected then 0 else 0.35
	end
	local id = if selected then slots[selected] or "" else ""
	w.CentreName.Text = if id ~= "" then emoteName(id) else S.WheelCentre
end

local function setSelected(index: number?)
	if selected == index then
		return
	end
	selected = index
	refreshWheel()
end

-- Slot index (clockwise from the top) for a direction; x to the right, y up.
local function sectorOf(x: number, y: number): number
	local count = nodeCount()
	local angle = math.atan2(x, y)
	if angle < 0 then
		angle += 2 * math.pi
	end
	return (math.floor(angle / (2 * math.pi / count) + 0.5) % count) + 1
end

local function stickVector(): Vector2?
	for _, pad in UserInputService:GetConnectedGamepads() do
		for _, state in UserInputService:GetGamepadState(pad) do
			if state.KeyCode == Enum.KeyCode.Thumbstick2 then
				return Vector2.new(state.Position.X, state.Position.Y)
			end
		end
	end
	return nil
end

local function aim()
	local w = wheel
	if not w or sticky then
		return
	end
	local device = Device.Current()
	if device == "KeyboardMouse" then
		local ring = w.Ring
		local centre = ring.AbsolutePosition + ring.AbsoluteSize / 2
		local offset = UserInputService:GetMouseLocation() - centre
		if offset.Magnitude > ring.AbsoluteSize.X * DEAD_ZONE then
			setSelected(sectorOf(offset.X, -offset.Y))
		else
			setSelected(nil)
		end
	elseif device == "Gamepad" then
		local stick = stickVector()
		if stick and stick.Magnitude >= STICK_THRESHOLD then
			setSelected(sectorOf(stick.X, stick.Y))
		end
	end
end

local function closeWheel()
	if not wheelOpen then
		return
	end
	wheelOpen = false
	sticky = false
	wheelMaid:Clean()
	if ownsFreeCursor then
		ownsFreeCursor = false
		InputController.EndAction("FreeCursor")
	end
	local w = wheel
	if w then
		w.Holder.Visible = false
	end
	selected = nil
end

local function hintText(): string
	local device = Device.Current()
	if device == "Touch" then
		return S.WheelHintTouch
	end
	local key = InputController.GetPrompt("Emote")
	return Strings.Format(if device == "Gamepad" then S.WheelHintPad else S.WheelHint, { key = key })
end

local function canOpen(): boolean
	local humanoid = humanoidOf()
	return humanoid ~= nil
		and humanoid.Health > 0
		and InputController.GetContext() == "Gameplay"
		and not UIController.IsMenuOpen()
end

local function playSlot(index: number)
	local id = slots[index] or ""
	closeWheel()
	if id ~= "" then
		EmoteController.Play(id)
	end
end

local function openWheel()
	local w = wheel
	if not w or wheelOpen or not canOpen() then
		return
	end
	wheelOpen = true
	sticky = false
	selected = nil
	w.Hint.Text = hintText()
	refreshWheel()
	w.Backdrop.BackgroundTransparency = 1
	w.Holder.Visible = true
	if not Motion.IsReduced() then
		w.Scale.Scale = 0.9
		TweenUtil.Play(w.Scale, 0.12, { Scale = 1 })
	else
		w.Scale.Scale = 1
	end
	UISound.Play("UIOpen")
	if Device.Current() == "KeyboardMouse" then
		ownsFreeCursor = InputController.BeginAction("FreeCursor", "KeyboardMouse")
	end
	wheelMaid:Add(RunService.RenderStepped:Connect(aim))
end

local function buildWheel(): Wheel
	local holder: Frame = Create.new("Frame", {
		Name = "EmoteWheel",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = Layers.Get("Overlay"),
	})
	local backdrop: TextButton = Create.new("TextButton", {
		Name = "Backdrop",
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		BackgroundColor3 = C.Overlay,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = holder,
	})
	local diameter = RADIUS * 2 + NODE_SIZE
	local ring: Frame = Create.new("Frame", {
		Name = "Ring",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(diameter, diameter),
		Parent = holder,
	})
	local scale: UIScale = Create.new("UIScale", { Parent = ring })

	local hub: Frame = Create.new("Frame", {
		Name = "Hub",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(150, 150),
		BackgroundColor3 = C.Midnight,
		BackgroundTransparency = 0.2,
		Parent = ring,
	})
	Create.Corner(hub, UITheme.CornerPill)
	Create.Stroke(hub, C.Edge, 2, 0.3)
	local centreName = Create.Label({
		Name = "CentreName",
		Text = S.WheelCentre,
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Heading,
		Color = C.Foam,
		XAlignment = Enum.TextXAlignment.Center,
		Wrapped = true,
		Size = UDim2.new(1, -24, 1, -24),
		Position = UDim2.fromOffset(12, 12),
		Parent = hub,
	})

	local nodes: { Node } = {}
	local count = nodeCount()
	for index = 1, count do
		local angle = -math.pi / 2 + (index - 1) * (2 * math.pi / count)
		local button: TextButton = Create.new("TextButton", {
			Name = `Slot{index}`,
			AutoButtonColor = false,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, math.cos(angle) * RADIUS, 0.5, math.sin(angle) * RADIUS),
			Size = UDim2.fromOffset(NODE_SIZE, NODE_SIZE),
			BackgroundColor3 = C.PanelRaised,
			BackgroundTransparency = 0.08,
			FontFace = UITheme.Fonts.BodyBold,
			TextSize = UITheme.TextSize.Small,
			TextColor3 = C.Text,
			TextWrapped = true,
			Text = "",
			Parent = ring,
		})
		Create.Corner(button, UITheme.CornerPill)
		Create.Padding(button, 8)
		local stroke = Create.Stroke(button, C.Edge, 1.5, 0.35)
		button.Activated:Connect(function()
			playSlot(index)
		end)
		nodes[index] = { Button = button, Stroke = stroke }
	end

	local hint = Create.Label({
		Name = "Hint",
		Text = "",
		TextSize = UITheme.TextSize.Small,
		Color = C.TextMuted,
		XAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, diameter / 2 + 4),
		Size = UDim2.fromOffset(460, 22),
		Parent = holder,
	})
	local edit = Components.Button.new({
		Text = S.WheelEdit,
		Variant = "Secondary",
		Size = UDim2.fromOffset(180, UITheme.Size.MinTouchTarget + 4),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, diameter / 2 + 30),
		Parent = holder,
		OnActivated = function()
			closeWheel()
			UIController.Open(MENU_ID)
		end,
	})

	backdrop.Activated:Connect(function()
		if sticky then
			closeWheel()
		end
	end)

	return {
		Holder = holder,
		Backdrop = backdrop,
		Ring = ring,
		Scale = scale,
		Nodes = nodes,
		CentreName = centreName,
		Hint = hint,
		Edit = edit,
	}
end

local function onEmoteReleased(held: number)
	if not wheelOpen then
		return
	end
	local w = wheel
	if Device.Current() == "Touch" and (selected == nil or held < Config.Input.HoldThreshold) then
		-- A tap on the touch button: keep the wheel up so an emote can be tapped.
		sticky = true
		if w then
			w.Backdrop.BackgroundTransparency = 0.6
		end
		return
	end
	local pick = selected
	if pick then
		playSlot(pick)
	else
		closeWheel()
	end
end

-- THE EMOTES PAGE ---------------------------------------------------------------------------------

local function makeRow(parent: Instance, name: string, order: number, onActivated: () -> ()): Row
	local button: TextButton = Create.new("TextButton", {
		Name = name,
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = C.PanelRaised,
		BackgroundTransparency = 0.1,
		Size = UDim2.new(1, -6, 0, ROW_HEIGHT),
		LayoutOrder = order,
		Parent = parent,
	})
	Create.Corner(button, UITheme.CornerSmall)
	local stroke = Create.Stroke(button, C.Edge, 1.5, 0.35)
	local main = Create.Label({
		Name = "Main",
		Text = "",
		Font = UITheme.Fonts.BodyBold,
		RichText = true,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(0.62, -12, 1, 0),
		Parent = button,
	})
	local side = Create.Label({
		Name = "Side",
		Text = "",
		TextSize = UITheme.TextSize.Caption,
		Color = C.TextMuted,
		XAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(0.62, 0, 0, 0),
		Size = UDim2.new(0.38, -12, 1, 0),
		Parent = button,
	})
	button.Activated:Connect(function()
		UISound.Play("UIClick")
		onActivated()
	end)
	return { Button = button, Stroke = stroke, Main = main, Side = side }
end

local function styleRow(row: Row, highlighted: boolean)
	row.Button.BackgroundColor3 = if highlighted then C.PanelHover else C.PanelRaised
	row.Stroke.Color = if highlighted then C.Aqua else C.Edge
	row.Stroke.Thickness = if highlighted then 2 else 1.5
	row.Stroke.Transparency = if highlighted then 0 else 0.35
end

local function refreshPage()
	if #pageSlotRows == 0 then
		return
	end
	local aqua = C.Aqua:ToHex()
	local assigned: { [string]: number } = {}
	for index, id in slots do
		if id ~= "" then
			assigned[id] = index
		end
	end
	for index, row in pageSlotRows do
		local id = slots[index] or ""
		local def = Emotes.Get(id)
		row.Main.Text = `<font color="#{aqua}">{index}</font>   {if def then emoteName(id) else S.Empty}`
		row.Main.TextColor3 = if def then C.Text else C.TextDim
		row.Side.Text = if def then (S.Categories[def.Category] or def.Category) else ""
		styleRow(row, index == pageSlot)
	end
	for id, row in pageEmoteRows do
		local def = Emotes.Get(id)
		local slot = assigned[id]
		row.Main.Text = emoteName(id)
		row.Side.Text = if slot then Strings.Format(S.Assigned, { n = slot }) else (if def then (S.Categories[def.Category] or def.Category) else "")
		row.Side.TextColor3 = if slot then C.Current else C.TextMuted
		styleRow(row, slot == pageSlot)
	end
	local header = pageHeader
	if header then
		header.Text = Strings.Format(S.PickFor, { n = pageSlot })
	end
end

local function buildPage(content: Frame, maid: Maid.Maid): UIController.MenuContent
	table.clear(pageSlotRows)
	table.clear(pageEmoteRows)

	local intro = Create.Label({
		Name = "Intro",
		Text = S.PageIntro,
		Color = C.TextMuted,
		Wrapped = true,
		Size = UDim2.new(1, 0, 0, 40),
		Parent = content,
	})
	maid:Add(intro)
	Create.Label({
		Name = "SlotsHeader",
		Text = string.upper(S.Wheel),
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Body,
		Color = C.Accent,
		Position = UDim2.fromOffset(0, 44),
		Size = UDim2.new(0.4, 0, 0, 26),
		Parent = content,
	})
	pageHeader = Create.Label({
		Name = "LibraryHeader",
		Text = "",
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Body,
		Color = C.Accent,
		Position = UDim2.new(0.43, 0, 0, 44),
		Size = UDim2.new(0.57, 0, 0, 26),
		Parent = content,
	})

	local slotList = Components.ScrollList.new({
		Name = "Slots",
		Spacing = 6,
		Position = UDim2.fromOffset(0, COLUMN_TOP),
		Size = UDim2.new(0.4, 0, 1, -(COLUMN_TOP + UITheme.Size.MinTouchTarget + 14)),
		Parent = content,
	})
	maid:Add(slotList)
	for index = 1, nodeCount() do
		pageSlotRows[index] = makeRow(slotList.Instance, `Slot{index}`, index, function()
			pageSlot = index
			refreshPage()
		end)
	end

	local clear = Components.Button.new({
		Text = S.ClearSlot,
		Variant = "Secondary",
		Position = UDim2.new(0, 0, 1, 0),
		AnchorPoint = Vector2.new(0, 1),
		Size = UDim2.new(0.4, -6, 0, UITheme.Size.MinTouchTarget + 2),
		Parent = content,
		OnActivated = function()
			Net.FireServer("RequestSetEmoteSlot", pageSlot, "")
		end,
	})
	maid:Add(clear)

	local library = Components.ScrollList.new({
		Name = "Library",
		Spacing = 6,
		Position = UDim2.new(0.43, 0, 0, COLUMN_TOP),
		Size = UDim2.new(0.57, 0, 1, -COLUMN_TOP),
		Parent = content,
	})
	maid:Add(library)
	for order, def in Emotes.Ordered() do
		local id = def.Id
		pageEmoteRows[id] = makeRow(library.Instance, id, order, function()
			Net.FireServer("RequestSetEmoteSlot", pageSlot, id)
		end)
	end

	pageSlot = 1
	refreshPage()
	return {
		OnOpen = function()
			pageOpen = true
			pageSlot = 1
			refreshPage()
		end,
		OnClose = function()
			pageOpen = false
		end,
	}
end

-- LIFECYCLE ---------------------------------------------------------------------------------------

function EmoteController.GetSlots(): { string }
	return table.clone(slots)
end

function EmoteController.Init()
	UIController.RegisterMenu({
		Id = MENU_ID,
		Title = S.PageTitle,
		Action = "OpenEmotes",
		FullScreen = false,
		ShowInHub = true,
		Icon = "Reaction",
		Size = Vector2.new(800, 620),
		Build = buildPage,
	})
end

function EmoteController.Start()
	wheel = buildWheel()

	DataController.Observe({ "Social", "Emotes" }, function(value: any)
		slots = Emotes.Resolve(if type(value) == "table" then value else nil)
		refreshWheel()
		if pageOpen then
			refreshPage()
		end
	end)

	InputController.ActionBegan:Connect(function(action: string)
		if action == "Emote" then
			if wheelOpen then
				closeWheel()
			else
				openWheel()
			end
		elseif CANCELLING[action] then
			EmoteController.Stop()
			closeWheel()
		end
	end)
	InputController.ActionEnded:Connect(function(action: string, held: number)
		if action == "Emote" then
			onEmoteReleased(held)
		end
	end)
	InputController.ContextChanged:Connect(function(context: string)
		if context ~= "Gameplay" then
			closeWheel()
		end
	end)
	UIController.MenuOpened:Connect(function()
		closeWheel()
	end)
	player.CharacterAdded:Connect(function()
		EmoteController.Stop()
		closeWheel()
		table.clear(cache)
		cacheCharacter = nil
	end)
end

return EmoteController
