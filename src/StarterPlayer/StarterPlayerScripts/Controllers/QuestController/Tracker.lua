--!strict
--[[
	Tracker
	The HUD quest tracker on the right, under the minimap (Spec Section 12):

	  QUESTS                                   Hide
	  ▌ Teeth of the Tide                        ◆
	  ▌  ◇ Slay Bilgecrabs near the Old Wharf 3/6   142 studs
	  ▌ Lights in the Reeds
	  ▌  ◆ Return to Reedwarden Osk                  80 studs

	The tracked quest comes first, then up to two more from the log (story first). Objective
	lines show their counters and the distance to their marker; finished lines dim with a tick.
	Clicking a quest opens it in the Quest Log. The header collapses the panel to one pill.
	Blocks and lines are built once (pooled) and only re-filled on changes; distances update a
	few times a second.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Strings = require(Shared.Strings)
local Quests = require(Shared.Data.Quests)
local TweenUtil = require(Shared.Util.TweenUtil)

local UI = script.Parent.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Device = require(UI.Device)
local Icons = require(UI.Icons)
local UISound = require(UI.UISound)
local Motion = require(UI.Motion)
local QuestText = require(UI.QuestText)

local State = require(script.Parent.State)
local WorldPoints = require(script.Parent.WorldPoints)

local C = UITheme.Colors
local QT = UITheme.Quests
local Q = Strings.QuestUI
local player = Players.LocalPlayer

type Line = {
	Frame: Frame,
	Bullet: Frame,
	Text: TextLabel,
	Distance: TextLabel,
	Marker: string?,
}

type Block = {
	Button: TextButton,
	Accent: Frame,
	Name: TextLabel,
	TrackedIcon: ImageLabel,
	Lines: { Line },
	QuestId: string?,
}

local Tracker = {}

local root: Frame
local header: TextButton
local headerLabel: TextLabel
local toggleLabel: TextLabel
local body: Frame
local blocks: { Block } = {}
local collapsed = false
local onOpenQuest: ((string) -> ())? = nil

local function playerPosition(): Vector3?
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	return if rootPart and rootPart:IsA("BasePart") then rootPart.Position else nil
end

local function distanceText(marker: string?): string
	if not marker then
		return ""
	end
	local target = WorldPoints.Position(marker)
	local from = playerPosition()
	if not target or not from then
		return ""
	end
	return Strings.Format(Q.Distance, { distance = math.floor((target - from).Magnitude + 0.5) })
end

-- Top of the tracker: under the Pressure icon and the minimap.
local function topOffset(): number
	local H = UITheme.HUD
	local M = UITheme.Map
	local minimap = if Device.IsTouch() then M.MinimapSizeTouch else M.MinimapSize
	return H.Margin.Y + H.PressureSize.Y + M.MinimapGap + minimap + QT.TrackerGap
end

local function buildLine(parent: Instance, order: number): Line
	local frame: Frame = Create.new("Frame", {
		Name = `Line{order}`,
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 18),
		LayoutOrder = order + 1,
		Visible = false,
		Parent = parent,
	})
	local bullet: Frame = Create.new("Frame", {
		Name = "Bullet",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(16, 9),
		Size = UDim2.fromOffset(6, 6),
		Rotation = 45,
		BackgroundColor3 = C.Text,
		BorderSizePixel = 0,
		Parent = frame,
	})
	local text = Create.Label({
		Name = "Text",
		Text = "",
		TextSize = UITheme.TextSize.Small - 1,
		Color = C.Text,
		RichText = true,
		Wrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		YAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(26, 0),
		Size = UDim2.new(1, -26 - 64, 0, 18),
		Parent = frame,
	})
	text.TextStrokeTransparency = 0.6
	local distance = Create.Label({
		Name = "Distance",
		Text = "",
		Font = UITheme.Fonts.Numbers,
		TextSize = UITheme.TextSize.Caption - 1,
		Color = C.TextMuted,
		XAlignment = Enum.TextXAlignment.Right,
		YAlignment = Enum.TextYAlignment.Top,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 1),
		Size = UDim2.fromOffset(62, 16),
		Parent = frame,
	})
	distance.TextStrokeTransparency = 0.6
	return { Frame = frame, Bullet = bullet, Text = text, Distance = distance, Marker = nil }
end

local function buildBlock(order: number): Block
	local button: TextButton = Create.new("TextButton", {
		Name = `Quest{order}`,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.HudPanel,
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		LayoutOrder = order,
		Selectable = false,
		Visible = false,
		Parent = body,
	})
	Create.Corner(button, UITheme.CornerSmall)
	Create.new("UIGradient", {
		Rotation = 0,
		Transparency = NumberSequence.new(0.4, 1),
		Parent = button,
	})
	-- Kind-coloured rule down the left edge; the text sits in a padded list beside it.
	local accent: Frame = Create.new("Frame", {
		Name = "Accent",
		BorderSizePixel = 0,
		BackgroundColor3 = C.Aqua,
		Size = UDim2.new(0, 3, 1, 0),
		Parent = button,
	})
	local content: Frame = Create.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		Parent = button,
	})
	Create.new("UIPadding", {
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 8),
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 7),
		Parent = content,
	})
	Create.List(content, Enum.FillDirection.Vertical, 3)
	local nameRow: Frame = Create.new("Frame", {
		Name = "NameRow",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 20),
		LayoutOrder = 0,
		Parent = content,
	})
	local name = Create.Label({
		Name = "Name",
		Text = "",
		Font = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.Body - 1,
		Color = C.Aqua,
		Size = UDim2.new(1, -22, 1, 0),
		Parent = nameRow,
	})
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.TextStrokeTransparency = 0.5
	local trackedIcon = Icons.new("Mark", {
		Name = "Tracked",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(16, 16),
		Color = QT.Ready,
		Parent = nameRow,
	})
	local lines: { Line } = {}
	for index = 1, QT.TrackerMaxLines do
		table.insert(lines, buildLine(content, index))
	end
	local block: Block = { Button = button, Accent = accent, Name = name, TrackedIcon = trackedIcon, Lines = lines, QuestId = nil }
	button.Activated:Connect(function()
		local id = block.QuestId
		local open = onOpenQuest
		if id and open then
			UISound.Play("UIClick")
			open(id)
		end
	end)
	return block
end

local function build()
	local width = QT.TrackerWidth
	root = Create.new("Frame", {
		Name = "QuestTracker",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -UITheme.HUD.Margin.X, 0, topOffset()),
		Size = UDim2.fromOffset(width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = Layers.Get("HUD"),
	})
	Create.List(root, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Right)

	header = Create.new("TextButton", {
		Name = "Header",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.HudPanel,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(width, 30),
		LayoutOrder = 0,
		Selectable = false,
		Parent = root,
	})
	Create.Corner(header, UITheme.CornerPill)
	Create.Stroke(header, UITheme.Colors.Brass, 1, 0.6)
	headerLabel = Create.Label({
		Name = "Title",
		Text = string.upper(Q.Expand),
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Small,
		Color = C.Text,
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -90, 1, 0),
		Parent = header,
	})
	toggleLabel = Create.Label({
		Name = "Toggle",
		Text = Q.Collapse,
		Font = UITheme.Fonts.BodyMedium,
		TextSize = UITheme.TextSize.Caption,
		Color = C.TextMuted,
		XAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 0),
		Size = UDim2.new(0, 70, 1, 0),
		Parent = header,
	})
	Motion.AttachButtonFeedback(header)

	body = Create.new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.fromOffset(width, 0),
		LayoutOrder = 1,
		Parent = root,
	})
	Create.List(body, Enum.FillDirection.Vertical, 6)
	for index = 1, QT.TrackerMaxQuests do
		table.insert(blocks, buildBlock(index))
	end

	header.Activated:Connect(function()
		UISound.Play("UIClick")
		Tracker.SetCollapsed(not collapsed)
	end)
end

local function layoutForDevice()
	local touch = Device.IsTouch()
	-- Touch targets: the header grows to 44 px; the panel narrows on phones.
	header.Size = UDim2.fromOffset(if collapsed then 150 else QT.TrackerWidth, if touch then UITheme.Size.MinTouchTarget else 30)
	root.Position = UDim2.new(1, -UITheme.HUD.Margin.X, 0, topOffset())
end

local function fillLine(line: Line, text: string, done: boolean, marker: string?, color: Color3?)
	line.Frame.Visible = true
	line.Text.Text = text
	line.Text.TextColor3 = if done then C.TextDim else color or C.Text
	line.Bullet.BackgroundColor3 = if done then QT.Done elseif color then color else C.Text
	line.Bullet.BackgroundTransparency = if done then 0.2 else 0
	line.Marker = if done then nil else marker
	line.Distance.Text = if done then "" else distanceText(line.Marker)
end

local function fillBlock(block: Block, id: string, tracked: boolean)
	local def = Quests.Get(id)
	if not def then
		block.Button.Visible = false
		block.QuestId = nil
		return
	end
	block.QuestId = id
	block.Button.Visible = true
	local color = QuestText.KindColor(def.Kind)
	block.Name.Text = QuestText.QuestName(id)
	block.Name.TextColor3 = color
	block.Accent.BackgroundColor3 = color
	block.TrackedIcon.Visible = tracked
	local used = 0
	if State.IsReady(id) then
		local turnIn = def.TurnIn
		if turnIn then
			used += 1
			fillLine(block.Lines[used], Strings.Format(Q.ReturnTo, { name = QuestText.NpcName(turnIn) }), false, turnIn, QT.Ready)
		else
			used += 1
			fillLine(block.Lines[used], Q.Ready, false, nil, QT.Ready)
		end
	else
		for index, objective in def.Objectives do
			if used >= #block.Lines then
				break
			end
			if State.ObjectiveVisible(id, index) then
				local done, needed = State.Progress(id, index)
				local label = QuestText.Objective(id, index)
				if needed > 1 then
					label = `{label}  <font color="#9DB2CA">{Strings.Format(Q.Progress, { done = done, total = needed })}</font>`
				end
				used += 1
				fillLine(block.Lines[used], label, done >= needed, objective.Marker, nil)
			end
		end
	end
	for index = used + 1, #block.Lines do
		block.Lines[index].Frame.Visible = false
		block.Lines[index].Marker = nil
	end
end

function Tracker.Refresh()
	local ids = State.TrackerIds(QT.TrackerMaxQuests)
	local tracked = State.Tracked()
	for index, block in blocks do
		local id = ids[index]
		if id then
			fillBlock(block, id, id == tracked)
		else
			block.Button.Visible = false
			block.QuestId = nil
		end
	end
	root.Visible = #ids > 0
	headerLabel.Text = if collapsed then `{string.upper(Q.Expand)}  {#ids}` else string.upper(Q.Expand)
end

-- Distances only (cheap; runs a few times a second).
local function refreshDistances()
	for _, block in blocks do
		if block.Button.Visible then
			for _, line in block.Lines do
				if line.Frame.Visible and line.Marker then
					line.Distance.Text = distanceText(line.Marker)
				end
			end
		end
	end
end

function Tracker.SetCollapsed(value: boolean)
	collapsed = value
	body.Visible = not value
	toggleLabel.Text = if value then "" else Q.Collapse
	layoutForDevice()
	Tracker.Refresh()
end

-- A quick brighten on a quest's block (progress landed).
function Tracker.Flash(questId: string)
	for _, block in blocks do
		if block.QuestId == questId and block.Button.Visible then
			block.Button.BackgroundTransparency = 0.15
			TweenUtil.Play(block.Button, 0.6, { BackgroundTransparency = 0.55 })
		end
	end
end

function Tracker.Init(openQuest: (string) -> ())
	onOpenQuest = openQuest
	build()
	layoutForDevice()
	Device.Changed:Connect(layoutForDevice)
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator >= QT.DistanceRefresh then
			accumulator = 0
			if not collapsed and root.Visible then
				refreshDistances()
			end
		end
	end)
end

return Tracker
