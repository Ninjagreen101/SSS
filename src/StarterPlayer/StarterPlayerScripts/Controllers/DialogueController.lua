--!strict
--[[
	DialogueController
	Talking to the people of the Spire (Phase 11, docs/PHASE11_QUESTS.md).

	An NPC's ProximityPrompt (model tagged SpireNpc, attribute NpcId; built by NpcService) opens a
	box along the bottom of the screen:

	  ┌ Brannoc Hale ─ Dockmaster ┐                       [ ? Salt in the Lungs (ready) ]
	  │                                                    [ ! Nets and Knots            ]
	  │ "Mind the quay, it's slick tonight."               [   Farewell                  ]
	  │                                        Click to continue ▾
	  └────────────────────────────────────────────────────────────────────────────────┘

	- Lines type out (TextLabel.MaxVisibleGraphemes) with a soft voice blip pitched by the NPC's
	  Voice (Data/Npcs). Click / tap anywhere, Space / Enter or gamepad A finishes the line, then
	  moves to the next one.
	- RequestTalk is sent once per open (Talk objectives count on the server).
	- Choices: quests ready to hand in here (Complete lines, then Hand in), quests on offer (Offer
	  lines, then Accept / Not now), quests in progress (their Progress line), Farewell. Number keys
	  pick a choice; gamepad selection lands on the first one.
	- The camera eases in to frame the NPC (left of centre, above the box) and eases back on close.
	- Closes on Farewell, Back (Backspace / B), walking away, opening a menu, or death.
	Every quest action goes to the server; the box re-reads quest state when it changes.
]]

local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local TweenUtil = require(Shared.Util.TweenUtil)
local Npcs = require(Shared.Data.Npcs)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Device = require(UI.Device)
local Motion = require(UI.Motion)
local Animator = require(UI.Animator)
local UISound = require(UI.UISound)
local Icons = require(UI.Icons)
local QuestText = require(UI.QuestText)

local DataController = require(script.Parent.DataController)
local UIController = require(script.Parent.UIController)
local InputController = require(script.Parent.InputController)
local CameraController = require(script.Parent.CameraController)
local QuestController = require(script.Parent.QuestController)

local State = QuestController.State
local WorldPoints = QuestController.WorldPoints

local A = Attributes.Names
local T = Attributes.Tags
local C = UITheme.Colors
local D = UITheme.Dialogue
local QT = UITheme.Quests
local Q = Strings.QuestUI
local player = Players.LocalPlayer

local ANIM_GROUP = "Dialogue"
local MAX_CHOICES = 7
local BLIP_POOL = 4
local BLIP_MIN_GAP = 0.045 -- seconds between blips, whatever the typing speed
local NAME_TAB_HEIGHT = 46

type ChoiceSpec = {
	Text: string,
	Glyph: string?, -- "!" / "?" badge
	Color: Color3?,
	Primary: boolean?,
	Run: () -> (),
}

type ChoiceView = {
	Button: TextButton,
	Stroke: UIStroke,
	Label: TextLabel,
	Badge: TextLabel,
	Key: TextLabel,
	Run: (() -> ())?,
}

type Session = {
	NpcId: string,
	Model: Model,
	Prompt: ProximityPrompt?,
	Lines: { string },
	LineIndex: number,
	After: (() -> ())?,
	Typing: boolean,
	Shown: number, -- graphemes revealed (fractional while typing)
	Length: number,
	LastBlip: number,
	AtRoot: boolean,
	CameraStart: CFrame,
	CameraFov: number,
	CameraTime: number,
	OwnsCamera: boolean,
}

local DialogueController = {}

local root: Frame
local catcher: TextButton
local box: TextButton
local boxScale: UIScale
local nameLabel: TextLabel
local roleLabel: TextLabel
local textLabel: TextLabel
local hint: Frame
local hintLabel: TextLabel
local hintArrow: ImageLabel
local choicesFrame: Frame
local choiceViews: { ChoiceView } = {}
local blips: { Sound } = {}
local blipCursor = 1
type InputContext = typeof(InputController.GetContext())

local session: Session? = nil
local previousContext: InputContext = "Gameplay"

-- HELPERS ----------------------------------------------------------------------------------

local function rootPart(): BasePart?
	local character = player.Character
	local part = character and character:FindFirstChild("HumanoidRootPart")
	return if part and part:IsA("BasePart") then part else nil
end

local function headOf(model: Model): BasePart?
	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
end

-- The NPC model a prompt belongs to (nearest ancestor with an NpcId).
local function npcFromPrompt(prompt: ProximityPrompt): (Model?, string?)
	local node: Instance? = prompt.Parent
	while node and node ~= Workspace do
		if node:IsA("Model") then
			local id = node:GetAttribute(A.NpcId)
			if type(id) == "string" and id ~= "" and (CollectionService:HasTag(node, T.Npc) or Npcs.Get(id) ~= nil) then
				return node, id
			end
		end
		node = node.Parent
	end
	return nil, nil
end

local function personalise(line: string): string
	return Strings.Format(line, { name = player.DisplayName })
end

local function pick(lines: { string }): string?
	if #lines == 0 then
		return nil
	end
	return lines[math.random(1, #lines)]
end

-- VOICE ------------------------------------------------------------------------------------

local function buildBlips()
	local folder = Instance.new("Folder")
	folder.Name = "SpireDialogueVoice"
	folder.Parent = SoundService
	for index = 1, BLIP_POOL do
		local sound = Instance.new("Sound")
		sound.Name = `Blip{index}`
		sound.SoundId = Config.Assets.Sounds.UIClick.Id
		sound.Volume = 0
		sound.Parent = folder
		table.insert(blips, sound)
	end
end

local function blip(voice: number)
	local sound = blips[blipCursor]
	blipCursor = blipCursor % #blips + 1
	if not sound then
		return
	end
	local ui = DataController.GetSetting("UiVolume")
	local master = DataController.GetSetting("MasterVolume")
	local volume = D.BlipVolume * (if type(ui) == "number" then ui else 0.7) * (if type(master) == "number" then master else 0.8)
	sound.Volume = volume
	-- A soft, low click: pitched by the speaker's voice with a little wobble so it never drones.
	sound.PlaybackSpeed = 0.55 * voice * (0.92 + math.random() * 0.16)
	sound.TimePosition = 0
	sound:Play()
end

-- CAMERA -----------------------------------------------------------------------------------

local function easeOut(t: number): number
	local u = 1 - math.clamp(t, 0, 1)
	return 1 - u * u * u
end

-- The shot that frames the NPC: from the player's side, slightly over the shoulder, with the
-- NPC left of centre and above the dialogue box.
local function goalShot(model: Model): CFrame?
	local head = headOf(model)
	local me = rootPart()
	if not head then
		return nil
	end
	local headPosition = head.Position
	local toPlayer = if me then me.Position - headPosition else model:GetPivot().LookVector
	toPlayer = Vector3.new(toPlayer.X, 0, toPlayer.Z)
	if toPlayer.Magnitude < 0.1 then
		toPlayer = model:GetPivot().LookVector
	end
	toPlayer = toPlayer.Unit
	local forward = -toPlayer
	local right = forward:Cross(Vector3.yAxis).Unit
	local eye = headPosition + toPlayer * D.CameraDistance + right * D.CameraSide + Vector3.new(0, 0.6, 0)
	local target = headPosition + right * 1.4 - Vector3.new(0, 0.7, 0)
	return CFrame.lookAt(eye, target)
end

local function takeCamera(current: Session)
	if CameraController.IsCinematic() then
		return -- another scripted shot (a Guardian intro) owns the camera
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	current.CameraStart = camera.CFrame
	current.CameraFov = camera.FieldOfView
	current.CameraTime = 0
	current.OwnsCamera = true
	local last = camera.CFrame
	CameraController.SetCinematic(function(dt: number): (CFrame, number)
		current.CameraTime += dt
		local alpha = if Motion.IsReduced() then 1 else easeOut(current.CameraTime / D.CameraEase)
		local goal = goalShot(current.Model)
		if goal then
			last = current.CameraStart:Lerp(goal, alpha)
		end
		return last, current.CameraFov + (D.CameraFov - current.CameraFov) * alpha
	end)
end

local function releaseCamera(current: Session)
	if current.OwnsCamera then
		current.OwnsCamera = false
		CameraController.SetCinematic(nil, if Motion.IsReduced() then 0 else D.CameraRelease)
	end
end

-- VIEW -------------------------------------------------------------------------------------

local function skipHint(): string
	local device = Device.Current()
	if device == "Touch" then
		return Q.DialogueSkipTouch
	elseif device == "Gamepad" then
		return Q.DialogueSkipGamepad
	end
	return Q.DialogueSkipMouse
end

local function buildChoice(index: number): ChoiceView
	local button: TextButton = Create.new("TextButton", {
		Name = `Choice{index}`,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.12,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, D.ChoiceHeight),
		LayoutOrder = index,
		Visible = false,
		SelectionImageObject = Create.SelectionImage(),
		Parent = choicesFrame,
	})
	Create.Corner(button, UITheme.CornerSmall)
	local stroke = Create.Stroke(button, C.Edge, 1, 0.3)
	Create.PanelGradient(button)
	local key = Create.Label({
		Name = "Key",
		Text = tostring(index),
		Font = UITheme.Fonts.Numbers,
		TextSize = UITheme.TextSize.Caption,
		Color = C.TextDim,
		XAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 8, 0.5, 0),
		Size = UDim2.fromOffset(18, 18),
		Parent = button,
	})
	local badge = Create.Label({
		Name = "Badge",
		Text = "",
		Font = UITheme.Fonts.Display,
		TextSize = 22,
		Color = QT.Available,
		XAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 28, 0.5, 0),
		Size = UDim2.fromOffset(18, 28),
		Parent = button,
	})
	badge.TextStrokeTransparency = 0.4
	local label = Create.Label({
		Name = "Text",
		Text = "",
		Font = UITheme.Fonts.BodyMedium,
		TextSize = UITheme.TextSize.Body,
		Position = UDim2.fromOffset(52, 0),
		Size = UDim2.new(1, -62, 1, 0),
		Parent = button,
	})
	label.TextTruncate = Enum.TextTruncate.AtEnd
	local view: ChoiceView = { Button = button, Stroke = stroke, Label = label, Badge = badge, Key = key, Run = nil }
	Motion.AttachButtonFeedback(button)
	button.MouseEnter:Connect(function()
		stroke.Color = C.Aqua
	end)
	button.MouseLeave:Connect(function()
		stroke.Color = C.Edge
	end)
	button.Activated:Connect(function()
		local run = view.Run
		if run and session then
			UISound.Play("UIClick")
			run()
		end
	end)
	return view
end

local function build()
	local layer = Layers.Get("Menu")
	root = Create.new("Frame", {
		Name = "Dialogue",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = layer,
	})
	-- Clicks and taps anywhere skip ahead (and don't reach the world).
	catcher = Create.new("TextButton", {
		Name = "Catcher",
		Text = "",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Selectable = false,
		AutoButtonColor = false,
		Parent = root,
	})
	-- A soft shade along the bottom so the box reads over bright scenes.
	local shade: Frame = Create.new("Frame", {
		Name = "Shade",
		BorderSizePixel = 0,
		BackgroundColor3 = C.Abyss,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, D.Height + D.Bottom + 140),
		Parent = root,
	})
	shade.Active = false
	Create.new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(1, 0.35), Parent = shade })

	box = Create.new("TextButton", {
		Name = "Box",
		Text = "",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -D.Bottom),
		Size = UDim2.new(1, -24, 0, D.Height),
		BackgroundColor3 = C.Midnight,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		SelectionImageObject = Create.SelectionImage(),
		Parent = root,
	})
	Create.new("UISizeConstraint", { MaxSize = Vector2.new(D.Width, math.huge), Parent = box })
	boxScale = Create.new("UIScale", { Parent = box })
	Create.Corner(box, UDim.new(0, 12))
	Create.Stroke(box, C.Edge, 1.5, 0.15)
	Create.PanelGradient(box)
	-- Fine gold rule along the top edge.
	local rule: Frame = Create.new("Frame", {
		Name = "Rule",
		BorderSizePixel = 0,
		BackgroundColor3 = UITheme.Banner.Gold,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.new(1, -40, 0, 1),
		Parent = box,
	})
	Create.new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.2, 0.3),
			NumberSequenceKeypoint.new(0.8, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = rule,
	})

	-- Name tab on the top-left edge.
	local tab: Frame = Create.new("Frame", {
		Name = "NameTab",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromOffset(22, 14),
		Size = UDim2.fromOffset(0, NAME_TAB_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		Parent = box,
	})
	Create.Corner(tab, UITheme.CornerSmall)
	Create.Stroke(tab, UITheme.Banner.Gold, 1, 0.45)
	Create.new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 16), Parent = tab })
	Create.List(tab, Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	nameLabel = Create.Label({
		Name = "Name",
		Text = "",
		Font = UITheme.Fonts.Display,
		TextSize = UITheme.TextSize.BodyLarge,
		Color = UITheme.Banner.Gold,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 22),
		LayoutOrder = 1,
		Parent = tab,
	})
	roleLabel = Create.Label({
		Name = "Role",
		Text = "",
		TextSize = UITheme.TextSize.Caption,
		Color = C.TextMuted,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 16),
		LayoutOrder = 2,
		Parent = tab,
	})

	textLabel = Create.Label({
		Name = "Text",
		Text = "",
		Font = UITheme.Fonts.DisplayRegular,
		TextSize = UITheme.TextSize.BodyLarge,
		Color = C.Text,
		Wrapped = true,
		YAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(28, 30),
		Size = UDim2.new(1, -56, 1, -70),
		Parent = box,
	})
	textLabel.LineHeight = 1.15

	hint = Create.new("Frame", {
		Name = "Hint",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -18, 1, -10),
		Size = UDim2.fromOffset(240, 22),
		Visible = false,
		Parent = box,
	})
	Create.List(hint, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	hintLabel = Create.Label({
		Text = "",
		TextSize = UITheme.TextSize.Caption,
		Color = C.TextMuted,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 18),
		LayoutOrder = 1,
		Parent = hint,
	})
	hintArrow = Icons.new("ChevronRight", { Size = UDim2.fromOffset(14, 14), Color = UITheme.Banner.Gold, LayoutOrder = 2, Parent = hint })
	hintArrow.Rotation = 90

	choicesFrame = Create.new("Frame", {
		Name = "Choices",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 0, -12),
		Size = UDim2.fromOffset(D.ChoiceWidth, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = box,
	})
	Create.List(choicesFrame, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Bottom)
	for index = 1, MAX_CHOICES do
		table.insert(choiceViews, buildChoice(index))
	end
end

local function hideChoices()
	for _, view in choiceViews do
		view.Button.Visible = false
		view.Run = nil
	end
end

local function showChoices(list: { ChoiceSpec })
	local current = session
	if not current then
		return
	end
	local keyboard = Device.Current() == "KeyboardMouse"
	for index, view in choiceViews do
		local spec = list[index]
		if spec then
			view.Button.Visible = true
			view.Label.Text = spec.Text
			view.Label.TextColor3 = spec.Color or C.Text
			view.Badge.Text = spec.Glyph or ""
			view.Badge.TextColor3 = spec.Color or QT.Available
			view.Key.Visible = keyboard
			view.Button.BackgroundColor3 = if spec.Primary then C.PanelHover else C.Panel
			view.Stroke.Color = if spec.Primary then C.Aqua else C.Edge
			view.Run = spec.Run
			if not Motion.IsReduced() then
				view.Button.Position = UDim2.fromOffset(16, 0)
				TweenUtil.Play(view.Button, 0.16 + index * 0.03, { Position = UDim2.fromOffset(0, 0) })
			end
		else
			view.Button.Visible = false
			view.Run = nil
		end
	end
	hint.Visible = false
	if Device.IsGamepad() and list[1] then
		GuiService.SelectedObject = choiceViews[1].Button
	end
end

-- LINES ------------------------------------------------------------------------------------

local function setLine(current: Session, line: string)
	textLabel.Text = personalise(line)
	current.Length = utf8.len(textLabel.ContentText) or #textLabel.ContentText
	current.Shown = 0
	current.Typing = true
	current.LastBlip = 0
	textLabel.MaxVisibleGraphemes = if Motion.IsReduced() then -1 else 0
	if Motion.IsReduced() then
		current.Typing = false
	end
	hint.Visible = false
	if Device.IsGamepad() then
		GuiService.SelectedObject = box
	end
end

local function lineFinished(current: Session)
	current.Typing = false
	textLabel.MaxVisibleGraphemes = -1
	if current.LineIndex < #current.Lines then
		hintLabel.Text = skipHint()
		hint.Visible = true
	else
		local after = current.After
		current.After = nil
		if after then
			after()
		end
	end
end

-- Says `lines` one after another, then runs `after` (usually: show choices).
local function say(lines: { string }, after: (() -> ())?)
	local current = session
	if not current then
		return
	end
	current.AtRoot = false
	hideChoices()
	current.Lines = if #lines > 0 then lines else { "..." }
	current.LineIndex = 1
	current.After = after
	setLine(current, current.Lines[1])
	if not current.Typing then
		lineFinished(current)
	end
end

local function advance()
	local current = session
	if not current then
		return
	end
	if current.Typing then
		lineFinished(current)
	elseif current.LineIndex < #current.Lines then
		current.LineIndex += 1
		setLine(current, current.Lines[current.LineIndex])
		if not current.Typing then
			lineFinished(current)
		end
	end
end

local function step(_time: number, dt: number)
	local current = session
	if not current then
		return
	end
	if current.Typing then
		local before = math.floor(current.Shown)
		current.Shown += dt * D.CharsPerSecond
		local shown = math.floor(current.Shown)
		if shown >= current.Length then
			lineFinished(current)
		elseif shown ~= before then
			textLabel.MaxVisibleGraphemes = shown
			local now = os.clock()
			if shown % D.BlipEvery == 0 and now - current.LastBlip >= BLIP_MIN_GAP then
				-- No blip on spaces and punctuation: the voice pauses between words.
				local char = string.sub(textLabel.ContentText, shown, shown)
				if not string.match(char, "[%s%p]") then
					current.LastBlip = now
					local npc = Npcs.Get(current.NpcId)
					blip(if npc then npc.Voice else 1)
				end
			end
		end
	elseif hint.Visible and not Motion.IsReduced() then
		hint.Position = UDim2.new(1, -18, 1, -10 + math.sin(os.clock() * 5) * 2)
	end
end

-- FLOW -------------------------------------------------------------------------------------

local close: () -> ()
local showRoot: (fresh: boolean) -> ()

local function questLines(questId: string, stage: string, fallback: string): { string }
	local lines = QuestText.Dialogue(questId, stage)
	if #lines == 0 and fallback ~= "" then
		table.insert(lines, fallback)
	end
	return lines
end

local function backChoice(): ChoiceSpec
	return {
		Text = Q.Continue,
		Run = function()
			showRoot(false)
		end,
	}
end

local function offer(questId: string)
	local current = session
	if not current then
		return
	end
	local npcId = current.NpcId
	say(questLines(questId, "Offer", QuestText.QuestSummary(questId)), function()
		showChoices({
			{
				Text = Q.Accept,
				Primary = true,
				Color = QT.Available,
				Run = function()
					UISound.Play("UIConfirm")
					Net.FireServer("RequestQuestAction", "Accept", questId, npcId)
					showRoot(false)
				end,
			},
			{
				Text = Q.Decline,
				Run = function()
					showRoot(false)
				end,
			},
		})
	end)
end

local function handIn(questId: string)
	local current = session
	if not current then
		return
	end
	local npcId = current.NpcId
	say(questLines(questId, "Complete", QuestText.QuestName(questId)), function()
		showChoices({
			{
				Text = Q.TurnIn,
				Primary = true,
				Color = QT.Ready,
				Run = function()
					Net.FireServer("RequestQuestAction", "TurnIn", questId, npcId)
					showRoot(false)
				end,
			},
			{
				Text = Q.Decline,
				Run = function()
					showRoot(false)
				end,
			},
		})
	end)
end

local function progress(questId: string)
	local index = State.CurrentObjective(questId)
	local fallback = if index then QuestText.Objective(questId, index) else QuestText.QuestSummary(questId)
	local lines = QuestText.Dialogue(questId, "Progress")
	local line = pick(lines) or fallback
	say({ line }, function()
		showChoices({ backChoice() })
	end)
end

local function rootChoices(npcId: string): { ChoiceSpec }
	local list: { ChoiceSpec } = {}
	for _, id in State.ReadyFor(npcId) do
		table.insert(list, {
			Text = Strings.Format(Q.ChoiceReady, { name = QuestText.QuestName(id) }),
			Glyph = "?",
			Color = QT.Ready,
			Primary = true,
			Run = function()
				handIn(id)
			end,
		})
	end
	for _, id in State.AvailableFrom(npcId) do
		table.insert(list, {
			Text = QuestText.QuestName(id),
			Glyph = "!",
			Color = QT.Available,
			Run = function()
				offer(id)
			end,
		})
	end
	for _, id in State.InProgressWith(npcId) do
		if #list >= MAX_CHOICES - 1 then
			break
		end
		table.insert(list, {
			Text = Strings.Format(Q.ChoiceProgress, { name = QuestText.QuestName(id) }),
			Color = C.TextMuted,
			Run = function()
				progress(id)
			end,
		})
	end
	while #list > MAX_CHOICES - 1 do
		table.remove(list)
	end
	table.insert(list, {
		Text = Q.Goodbye,
		Run = function()
			close()
		end,
	})
	return list
end

function showRoot(fresh: boolean)
	local current = session
	if not current then
		return
	end
	local npcId = current.NpcId
	if fresh then
		local greeting = pick(QuestText.NpcGreetings(npcId)) or "..."
		say({ greeting }, function()
			current.AtRoot = true
			showChoices(rootChoices(npcId))
		end)
	else
		-- Back from a branch: the greeting stays, the choices re-read quest state.
		local greeting = pick(QuestText.NpcGreetings(npcId)) or "..."
		hideChoices()
		current.Lines = { greeting }
		current.LineIndex = 1
		current.After = nil
		textLabel.Text = personalise(greeting)
		textLabel.MaxVisibleGraphemes = -1
		current.Typing = false
		hint.Visible = false
		current.AtRoot = true
		showChoices(rootChoices(npcId))
	end
end

function close()
	local current = session
	if not current then
		return
	end
	session = nil
	releaseCamera(current)
	local prompt = current.Prompt
	if prompt and prompt.Parent then
		prompt.Enabled = true
	end
	hideChoices()
	Animator.SetPaused(ANIM_GROUP, true)
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(root) then
		GuiService.SelectedObject = nil
	end
	if not UIController.IsMenuOpen() then
		InputController.SetContext(previousContext)
	end
	if Motion.IsReduced() then
		root.Visible = false
	else
		TweenUtil.Play(boxScale, 0.12, { Scale = 0.96 })
		task.delay(0.12, function()
			if not session then
				root.Visible = false
			end
		end)
	end
	UISound.Play("UIClose")
end
DialogueController.Close = close

-- Opens the dialogue with an NPC (its prompt was used, or another system asks).
function DialogueController.Open(npcId: string, model: Model?, prompt: ProximityPrompt?)
	local target = model or WorldPoints.NpcModel(npcId)
	if not target or not Npcs.Get(npcId) then
		return
	end
	if session then
		close()
	end
	if UIController.IsMenuOpen() then
		UIController.Close()
	end
	local current: Session = {
		NpcId = npcId,
		Model = target,
		Prompt = prompt,
		Lines = {},
		LineIndex = 1,
		After = nil,
		Typing = false,
		Shown = 0,
		Length = 0,
		LastBlip = 0,
		AtRoot = false,
		CameraStart = CFrame.identity,
		CameraFov = 70,
		CameraTime = 0,
		OwnsCamera = false,
	}
	session = current
	Net.FireServer("RequestTalk", npcId)

	nameLabel.Text = QuestText.NpcName(npcId)
	local role = QuestText.NpcRole(npcId)
	roleLabel.Text = role
	roleLabel.Visible = role ~= ""
	if prompt then
		prompt.Enabled = false
	end
	previousContext = InputController.GetContext()
	InputController.SetContext("Menu")
	root.Visible = true
	Animator.SetPaused(ANIM_GROUP, false)
	if Motion.IsReduced() then
		boxScale.Scale = 1
	else
		boxScale.Scale = 0.94
		TweenUtil.Play(boxScale, 0.18, { Scale = 1 })
	end
	UISound.Play("UIOpen")
	takeCamera(current)
	showRoot(true)
end

function DialogueController.IsOpen(): boolean
	return session ~= nil
end

-- Closes when the player walks off, dies, or the NPC streams out.
local function watchDistance()
	while true do
		task.wait(0.25)
		local current = session
		if current then
			local me = rootPart()
			local head = headOf(current.Model)
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not current.Model.Parent or not head or not me or (humanoid and humanoid.Health <= 0) then
				close()
			elseif (me.Position - head.Position).Magnitude > Config.Quests.TalkRadius * D.WalkAwayFactor then
				close()
			end
		end
	end
end

-- LIFECYCLE --------------------------------------------------------------------------------

function DialogueController.Init()
	build()
	buildBlips()
	Animator.SetPaused(ANIM_GROUP, true)
	Animator.Add(step, ANIM_GROUP)

	catcher.Activated:Connect(advance)
	box.Activated:Connect(advance)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		local current = session
		if not current then
			return
		end
		local key = input.KeyCode
		if key == Enum.KeyCode.ButtonA then
			-- A on a choice is handled by the button itself.
			local selected = GuiService.SelectedObject
			if not selected or selected == box then
				advance()
			end
			return
		end
		if processed then
			return
		end
		if key == Enum.KeyCode.Space or key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter then
			advance()
			return
		end
		local number = key.Value - Enum.KeyCode.One.Value + 1
		if number >= 1 and number <= MAX_CHOICES and not current.Typing then
			local view = choiceViews[number]
			local run = if view and view.Button.Visible then view.Run else nil
			if run then
				UISound.Play("UIClick")
				run()
			end
		end
	end)

	InputController.ActionBegan:Connect(function(action: string)
		if action == "CloseMenu" and session then
			close()
		end
	end)
	UIController.MenuOpened:Connect(function()
		if session then
			close()
		end
	end)
end

function DialogueController.Start()
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
		if who ~= player then
			return
		end
		local model, npcId = npcFromPrompt(prompt)
		if model and npcId then
			DialogueController.Open(npcId, model, prompt)
		end
	end)
	-- Quest state changed (accepted, handed in, a Talk objective counted): refresh the choices.
	QuestController.Changed:Connect(function()
		local current = session
		if current and current.AtRoot and not current.Typing then
			showChoices(rootChoices(current.NpcId))
		end
	end)
	Device.Changed:Connect(function()
		if session and hint.Visible then
			hintLabel.Text = skipHint()
		end
	end)
	player.CharacterRemoving:Connect(function()
		close()
	end)
	task.spawn(watchDistance)
end

return DialogueController
