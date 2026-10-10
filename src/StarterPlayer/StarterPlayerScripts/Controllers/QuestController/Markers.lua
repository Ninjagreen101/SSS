--!strict
--[[
	Markers
	Quest markers in the world:
	- Over NPCs: a gold "!" when they have a quest to offer, a "?" when you can hand one in.
	  One billboard per NPC, built the first time it is needed and reused.
	- The focused quest's objective (the tracked quest, else the first in the tracker): a light
	  pillar (Beam) rising from the marker and a diamond billboard with the distance. Hidden
	  beyond Config.Quests.MarkerMaxDistance (the tracker still shows the distance).
	Both bob gently (off under Reduced Motion).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)

local UI = script.Parent.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Icons = require(UI.Icons)
local Animator = require(UI.Animator)
local Motion = require(UI.Motion)

local State = require(script.Parent.State)
local WorldPoints = require(script.Parent.WorldPoints)

local QT = UITheme.Quests
local Q = Strings.QuestUI
local player = Players.LocalPlayer

type NpcMark = {
	Gui: BillboardGui,
	Glyph: TextLabel,
	Glow: ImageLabel,
	Model: Model?,
}

local Markers = {}

local npcMarks: { [string]: NpcMark } = {}
local anchor: Part
local beam: Beam
local objectiveGui: BillboardGui
local distanceLabel: TextLabel
local diamond: Frame
local focusMarker: string? = nil
local focusTurnIn = false

local function playerGui(): PlayerGui
	return player:WaitForChild("PlayerGui") :: PlayerGui
end

local function headOf(model: Model): BasePart?
	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
end

local function npcMark(npcId: string, model: Model): NpcMark?
	local existing = npcMarks[npcId]
	local head = headOf(model)
	if not head then
		return existing
	end
	if existing then
		if existing.Model ~= model then
			existing.Model = model
			existing.Gui.Adornee = head
		end
		return existing
	end
	local gui: BillboardGui = Create.new("BillboardGui", {
		Name = `QuestMark_{npcId}`,
		Adornee = head,
		AlwaysOnTop = false,
		LightInfluence = 0,
		ResetOnSpawn = false,
		MaxDistance = Config.Quests.MarkerMaxDistance,
		Size = UDim2.fromOffset(QT.MarkerSize.X, QT.MarkerSize.Y),
		StudsOffsetWorldSpace = Vector3.new(0, QT.MarkerLift, 0),
		Enabled = false,
	})
	local glow = Icons.Fx("Glow", {
		Name = "Glow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1.4, 1.4),
		Color = QT.Available,
		Transparency = 0.45,
		Parent = gui,
	})
	local glyph: TextLabel = Create.new("TextLabel", {
		Name = "Glyph",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = "!",
		FontFace = UITheme.Fonts.Display,
		TextScaled = true,
		TextColor3 = QT.Available,
		TextStrokeColor3 = Color3.new(0, 0, 0),
		TextStrokeTransparency = 0.2,
		Parent = gui,
	})
	gui.Parent = playerGui()
	local mark: NpcMark = { Gui = gui, Glyph = glyph, Glow = glow, Model = model }
	npcMarks[npcId] = mark
	return mark
end

-- Re-reads every NPC's "!" / "?" from quest state.
function Markers.RefreshNpcs()
	for npcId, model in WorldPoints.NpcModels() do
		local state = State.NpcMark(npcId)
		local mark = if state then npcMark(npcId, model) else npcMarks[npcId]
		if mark then
			mark.Gui.Enabled = state ~= nil
			if state then
				-- "?" hand-in reads as more urgent: brighter, with a stronger glow.
				mark.Glyph.Text = if state == "Ready" then "?" else "!"
				mark.Glyph.TextColor3 = if state == "Ready" then QT.Ready else QT.Available
				mark.Glow.ImageTransparency = if state == "Ready" then 0.3 else 0.5
			end
		end
	end
	for npcId, mark in npcMarks do
		local model = mark.Model
		if not model or not model.Parent then
			mark.Gui.Enabled = false
		elseif WorldPoints.NpcModel(npcId) == nil then
			mark.Gui.Enabled = false
		end
	end
end

local function buildObjective()
	anchor = Create.new("Part", {
		Name = "SpireQuestMarker",
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		Transparency = 1,
		Size = Vector3.new(0.2, 0.2, 0.2),
		CFrame = CFrame.new(0, -1e4, 0),
	})
	local bottom: Attachment = Create.new("Attachment", { Name = "Bottom", Parent = anchor })
	local top: Attachment = Create.new("Attachment", { Name = "Top", Position = Vector3.new(0, QT.BeamHeight, 0), Parent = anchor })
	beam = Create.new("Beam", {
		Name = "Pillar",
		Attachment0 = bottom,
		Attachment1 = top,
		FaceCamera = true,
		LightEmission = 1,
		LightInfluence = 0,
		Segments = 1,
		Width0 = QT.BeamWidth,
		Width1 = QT.BeamWidth * 0.4,
		Color = ColorSequence.new(QT.Ready),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(0.6, 0.75),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Enabled = false,
		Parent = anchor,
	})
	objectiveGui = Create.new("BillboardGui", {
		Name = "QuestObjectiveMarker",
		Adornee = anchor,
		AlwaysOnTop = true,
		LightInfluence = 0,
		ResetOnSpawn = false,
		Size = UDim2.fromOffset(90, 54),
		StudsOffsetWorldSpace = Vector3.new(0, QT.ObjectiveMarkerLift, 0),
		Enabled = false,
	})
	diamond = Create.new("Frame", {
		Name = "Diamond",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 14),
		Size = UDim2.fromOffset(16, 16),
		Rotation = 45,
		BackgroundColor3 = QT.Ready,
		BorderSizePixel = 0,
		Parent = objectiveGui,
	})
	Create.Stroke(diamond, Color3.new(0, 0, 0), 1.5, 0.3)
	distanceLabel = Create.new("TextLabel", {
		Name = "Distance",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 26),
		Size = UDim2.new(1, 0, 0, 18),
		FontFace = UITheme.Fonts.Numbers,
		TextSize = 14,
		TextColor3 = UITheme.Colors.Text,
		TextStrokeTransparency = 0.3,
		Text = "",
		Parent = objectiveGui,
	})
	anchor.Parent = Workspace.CurrentCamera
	objectiveGui.Parent = playerGui()
end

-- Points the objective marker at the focused quest (tracked, else the first in the tracker).
function Markers.RefreshObjective()
	local focus = State.Tracked() or State.TrackerIds(1)[1]
	local marker: string?, turnIn = nil, false
	if focus then
		marker, turnIn = State.Marker(focus)
	end
	focusMarker = marker
	focusTurnIn = turnIn
	local color = if turnIn then QT.Ready else QT.KindColors.Main
	beam.Color = ColorSequence.new(color)
	diamond.BackgroundColor3 = color
end

local function step(time: number)
	local marker = focusMarker
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	local target = if marker then WorldPoints.Position(marker) else nil
	if not marker or not target or not (rootPart and rootPart:IsA("BasePart")) then
		if beam.Enabled then
			beam.Enabled = false
			objectiveGui.Enabled = false
		end
	else
		local distance = (target - rootPart.Position).Magnitude
		local visible = distance <= Config.Quests.MarkerMaxDistance
		-- NPCs carry their own "!" / "?": lift the diamond above it.
		local isNpc = WorldPoints.Kind(marker) == "Npc"
		local base = if isNpc then target - Vector3.new(0, 3, 0) else target
		anchor.CFrame = CFrame.new(base)
		objectiveGui.StudsOffsetWorldSpace = Vector3.new(0, QT.ObjectiveMarkerLift + (if isNpc then QT.MarkerLift + 3.5 else 0), 0)
		-- No pillar on top of an NPC you're about to talk to.
		beam.Enabled = visible and not (isNpc and distance < Config.Quests.TalkRadius * 2)
		objectiveGui.Enabled = visible and distance > Config.Quests.TalkRadius * 0.5
		distanceLabel.Text = Strings.Format(Q.Distance, { distance = math.floor(distance + 0.5) })
	end

	if Motion.IsReduced() then
		return
	end
	local bob = math.sin(time * 2.4) * 0.25
	for _, mark in npcMarks do
		if mark.Gui.Enabled then
			mark.Gui.StudsOffsetWorldSpace = Vector3.new(0, QT.MarkerLift + bob, 0)
		end
	end
	diamond.Rotation = 45 + (if focusTurnIn then math.sin(time * 3) * 8 else 0)
end

function Markers.Init()
	buildObjective()
	WorldPoints.Changed:Connect(function(kind: WorldPoints.Kind)
		if kind == "Npc" then
			Markers.RefreshNpcs()
		end
	end)
	Animator.Add(step)
end

return Markers
