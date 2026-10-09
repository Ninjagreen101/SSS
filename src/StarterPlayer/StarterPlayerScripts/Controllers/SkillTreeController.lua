--!strict
--[[
	SkillTreeController
	The Skill Tree (N, or its tab in the Character window) and the Hall of
	Positions (Spec Sections 9 and 12).

	Full screen, over deep water: a luminous Current core in the middle
	(ripple rings, two counter-turning swirls, a blue-white heart) feeds
	your Position's three branches. Each branch is a stream of light in its
	own water shade (blue, turquoise, glacier), labelled with its name and
	its ability's icon near the core; streams curve where a branch forks and
	joins. Learned streams glow and flow outward from the core.

	Nodes are circles sized by kind (minor < notable < ability < keystone),
	each with an icon for what it does:
	  locked        dim, no glow (abilities and keystones show a lock)
	  can't afford  reachable, branch-tinted rim
	  available     bright rim and a soft breathing glow
	  learned       filled with the branch colour
	Hover a node for everything about it; click to select it (the details
	panel on the right shows effects, requirements, cost and a Learn button
	that says why when it can't be bought); click a selected node again to
	learn it. A Current spark runs into every node you learn.

	Header: the title, your skill points, stat points, level and gold, and
	your Position. Left: Build (stat points with - / +, shared with the
	Character page, and a radar of your attributes). Bottom: zoom controls.

	Before you hold a Position the five Positions show as cards. Choosing one
	only works at the Hall of Positions in Lowharbor (a station with
	StationKind "Positions"; its prompt opens this menu in Hall mode) from
	level Config.Progression.Positions.UnlockLevel.

	Controls: drag (mouse / one finger) to pan, wheel or pinch to zoom, the
	- / + / recenter buttons. Gamepad: move between nodes with the stick /
	D-pad (the view follows), right stick pans, A selects and, on a selected
	node, learns it.

	Every request goes to the server (PositionService); this only draws.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Strings = require(Shared.Strings)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Maid = require(Shared.Util.Maid)
local Positions = require(Shared.Data.Positions)
local Abilities = require(Shared.Data.Abilities)
local GearStats = require(Shared.Data.GearStats)
local Rules = require(Shared.Data.ProgressionRules)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Device = require(UI.Device)
local Animator = require(UI.Animator)
local Icons = require(UI.Icons)
local Shapes = require(UI.Shapes)
local StatDraft = require(UI.StatDraft)
local StatAllocator = require(UI.StatAllocator)
local StatRadar = require(UI.StatRadar)
local UISound = require(UI.UISound)
local Components = require(UI.Components)
local ProgressionText = require(UI.ProgressionText)

local DataController = require(script.Parent.DataController)
local UIController = require(script.Parent.UIController)
local InputController = require(script.Parent.InputController)
local StationController = require(script.Parent.StationController)
local ProgressionController = require(script.Parent.ProgressionController)

type PlayerData = Types.PlayerData
type NodeDef = Positions.NodeDef

local A = Attributes.Names
local S = Strings.Positions
local P = Config.Progression
local C = UITheme.Colors

local MENU_ID = "SkillTree"
local UNIT = 48 -- pixels per tree unit at zoom 1
local WORLD_SIZE = 1400 -- the world frame (px at zoom 1); the tree fits well inside it
local ZOOM_MIN = 0.45
local ZOOM_MAX = 1.8
local ZOOM_STEP = 1.18
local DRAG_THRESHOLD = 6
local STICK_PAN_SPEED = 700 -- px per second at full right-stick tilt
local HEADER_HEIGHT = 112
local SIDE_MARGIN = 20
local LEFT_WIDTH = 300
local RIGHT_WIDTH = 330
local BOTTOM_ROOM = 70
local FLOW_PERIOD = 120 -- px between bright pulses on a learned stream
local FLOW_SPEED = 0.55 -- pulses per second

local NODE_SIZE: { [string]: number } = { Minor = 30, Notable = 40, Active = 46, Keystone = 54 }
local LOCKED_RIM = Color3.fromHex("#294366")
local STREAM_DIM = Color3.fromHex("#18304F")

local SkillTreeController = {}

local player = Players.LocalPlayer
local hallStation: Instance? = nil -- set while the menu was opened at the Hall

type NodeView = {
	Def: NodeDef,
	Color: Color3,
	Button: TextButton,
	Disc: Frame,
	Stroke: UIStroke,
	Icon: ImageLabel,
	Halo: ImageLabel,
	Rim: ImageLabel?,
	Lock: ImageLabel?,
	Selected: ImageLabel,
	Scale: UIScale,
	StopPulse: (() -> ())?,
}

type Segment = { Frame: Frame, Glow: Frame, Gradient: UIGradient, Distance: number }

type StreamView = {
	From: string?, -- nil = from the core
	To: string,
	Color: Color3,
	Segments: { Segment },
}

local function data(): PlayerData?
	return DataController.GetData()
end

local function stationId(): string?
	local station = hallStation
	local id = station and station:GetAttribute(A.StationId)
	return if type(id) == "string" then id else nil
end

local function atHall(): boolean
	local station = hallStation
	if not station or not station.Parent then
		return false
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local pivot = if station:IsA("Model") then station:GetPivot().Position elseif station:IsA("BasePart") then station.Position else nil
	return root ~= nil and root:IsA("BasePart") and pivot ~= nil and (root.Position - pivot).Magnitude <= Config.Items.Stations.InteractRadius
end

local function pixel(node: NodeDef): Vector2
	return Vector2.new(node.X * UNIT, node.Y * UNIT)
end

-- Icon for a node: its ability, else what its bonuses do.
local function nodeIcon(node: NodeDef): string
	if node.Ability then
		return Icons.ForAbility(node.Ability)
	end
	return Icons.ForBonuses(node.Bonuses)
end

-- Each branch's water shade, by its order in the Position.
local function branchColors(def: Positions.PositionDef): { [string]: Color3 }
	local colors: { [string]: Color3 } = {}
	for index, branchDef in def.Branches do
		colors[branchDef.Id] = UITheme.Branch[(index - 1) % #UITheme.Branch + 1]
	end
	return colors
end

local function branchAbility(branchDef: Positions.BranchDef): string?
	for _, node in branchDef.Nodes do
		if node.Ability then
			return node.Ability
		end
	end
	return nil
end

-- The box (px at zoom 1) holding every node of a Position.
local function treeBounds(positionId: string): (Vector2, Vector2)
	local low = Vector2.new(-80, -80)
	local high = Vector2.new(80, 80)
	for _, node in Positions.NodesOf(positionId) do
		local half = (NODE_SIZE[node.Kind] or 30) / 2 + 8
		local point = pixel(node)
		low = Vector2.new(math.min(low.X, point.X - half), math.min(low.Y, point.Y - half))
		high = Vector2.new(math.max(high.X, point.X + half), math.max(high.Y, point.Y + half))
	end
	return low, high
end

-- A small resource chip for the header: [icon] value label.
local function resourceChip(parent: Instance, icon: string, color: Color3, order: number): TextLabel
	local chip: Frame = Create.new("Frame", {
		Name = icon,
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.25,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 34),
		LayoutOrder = order,
		Parent = parent,
	})
	Create.Corner(chip, UDim.new(0, 8))
	Create.Stroke(chip, C.Edge, 1.2, 0.2)
	Create.new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 14), Parent = chip })
	Create.List(chip, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	Icons.new(icon, { Size = UDim2.fromOffset(20, 20), Color = color, LayoutOrder = 1, Parent = chip })
	return Create.new("TextLabel", {
		Name = "Value",
		BackgroundTransparency = 1,
		Text = "",
		RichText = true,
		FontFace = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.Body,
		TextColor3 = C.Text,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 0, 1, 0),
		LayoutOrder = 2,
		Parent = chip,
	})
end

-- A glass side panel with a caps heading.
local function sidePanel(parent: Instance, name: string, title: string, icon: string): (Frame, Frame)
	local panel: Frame = Create.new("Frame", {
		Name = name,
		BackgroundColor3 = C.Midnight,
		BackgroundTransparency = 0.18,
		Parent = parent,
	})
	Create.Corner(panel, UDim.new(0, 12))
	Create.Stroke(panel, C.Edge, 1.5, 0.1)
	Create.new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(160, 172, 196)),
		Parent = panel,
	})
	Icons.Fx("Corner", { Size = UDim2.fromOffset(46, 46), Color = C.Aqua, Transparency = 0.45, Parent = panel })
	Icons.new(icon, { Position = UDim2.fromOffset(16, 15), Size = UDim2.fromOffset(20, 20), Color = C.Aqua, Parent = panel })
	Create.Label({
		Text = string.upper(title),
		Font = UITheme.Fonts.Title,
		TextSize = 18,
		Color = C.Accent,
		Position = UDim2.fromOffset(44, 10),
		Size = UDim2.new(1, -60, 0, 30),
		Parent = panel,
	})
	local body: Frame = Create.new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 48),
		Size = UDim2.new(1, -28, 1, -60),
		Parent = panel,
	})
	return panel, body
end

-- BUILD ------------------------------------------------------------------------------

local function build(content: Frame, maid: Maid.Maid): any
	local isOpen = false
	local zoom = 1
	local pan = Vector2.zero -- world centre offset from the canvas centre (unscaled px)
	local builtFor = ""
	local selectedId: string? = nil
	local nodeViews: { [string]: NodeView } = {}
	local streamViews: { StreamView } = {}
	local litSegments: { Segment } = {}
	local treeMaid = Maid.new()
	maid:Add(treeMaid)
	local stick = Vector2.zero
	local leftOpen = true
	local viewTouched = false -- true once you pan, zoom or a node is centred
	local refresh: () -> ()

	-- BACKDROP ---------------------------------------------------------------------
	local canvas: Frame = Create.new("Frame", {
		Name = "Canvas",
		BackgroundColor3 = C.Abyss,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
		Active = true,
		Parent = content,
	})
	Create.new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromHex("#0A2240")),
			ColorSequenceKeypoint.new(0.5, Color3.fromHex("#06152B")),
			ColorSequenceKeypoint.new(1, Color3.fromHex("#02070F")),
		}),
		Parent = canvas,
	})
	-- Slow nebulae of deep water light.
	local nebulae = {
		{ Position = UDim2.fromScale(0.22, 0.3), Size = 760, Color = Color3.fromHex("#1D4F8F"), Transparency = 0.55 },
		{ Position = UDim2.fromScale(0.8, 0.65), Size = 820, Color = Color3.fromHex("#0F6C7A"), Transparency = 0.62 },
		{ Position = UDim2.fromScale(0.62, 0.18), Size = 560, Color = Color3.fromHex("#2B3F8C"), Transparency = 0.68 },
		{ Position = UDim2.fromScale(0.35, 0.85), Size = 640, Color = Color3.fromHex("#124A6B"), Transparency = 0.66 },
	}
	for index, cloud in nebulae do
		local image = Icons.Fx("Nebula", {
			Name = `Nebula{index}`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = cloud.Position,
			Size = UDim2.fromOffset(cloud.Size, cloud.Size),
			Color = cloud.Color,
			Transparency = cloud.Transparency,
			Rotation = index * 47,
			Parent = canvas,
		})
		local drift = 2 + index
		maid:Add(Animator.Add(function(time: number)
			image.Rotation = index * 47 + time * drift
		end, MENU_ID))
	end
	-- Drifting motes rising through the water.
	local random = Random.new(11)
	local motes: { { Image: ImageLabel, X: number, Speed: number, Sway: number, Phase: number } } = {}
	for index = 1, 30 do
		local size = random:NextNumber(3, 9)
		local image = Icons.Fx(if index % 4 == 0 then "Bubble" else "Dot", {
			Name = "Mote",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(size, size),
			Color = if index % 3 == 0 then C.Aqua else C.Foam,
			Transparency = random:NextNumber(0.45, 0.8),
			Parent = canvas,
		})
		table.insert(motes, { Image = image, X = random:NextNumber(), Speed = random:NextNumber(0.008, 0.022), Sway = random:NextNumber(0.004, 0.012), Phase = random:NextNumber(0, 10) })
	end
	maid:Add(Animator.Add(function(time: number)
		for _, mote in motes do
			local y = 1.05 - ((time * mote.Speed + mote.Phase) % 1.1)
			mote.Image.Position = UDim2.fromScale(mote.X + math.sin(time * 0.6 + mote.Phase) * mote.Sway, y)
		end
	end, MENU_ID))

	-- WORLD (pans and zooms) -----------------------------------------------------------
	local world: Frame = Create.new("Frame", {
		Name = "World",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(WORLD_SIZE, WORLD_SIZE),
		Parent = canvas,
	})
	local worldScale: UIScale = Create.new("UIScale", { Parent = world })
	local function layer(name: string, z: number): Frame
		return Create.new("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = z, Parent = world })
	end
	local raysLayer = layer("Rays", 1)
	local coreLayer = layer("Core", 2)
	local streamsLayer = layer("Streams", 3)
	local nodesLayer = layer("Nodes", 4)
	local labelsLayer = layer("Labels", 5)

	-- Faint light rays crossing the deep, slowly turning around the core.
	local rayGroup: Frame = Create.new("Frame", { Name = "RayGroup", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Parent = raysLayer })
	for index = 1, 7 do
		Icons.Fx("Ray", {
			Name = `Ray{index}`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(WORLD_SIZE * 1.6, if index % 2 == 0 then 26 else 14),
			Rotation = index * 26 + 8,
			Color = C.Aqua,
			Transparency = if index % 2 == 0 then 0.9 else 0.84,
			Parent = rayGroup,
		})
	end
	maid:Add(Animator.Add(function(time: number)
		rayGroup.Rotation = math.sin(time * 0.05) * 8
	end, MENU_ID))

	-- The Current core.
	local function coreImage(kind: string, size: number, color: Color3, transparency: number, name: string): ImageLabel
		return Icons.Fx(kind, {
			Name = name,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(size, size),
			Color = color,
			Transparency = transparency,
			Parent = coreLayer,
		})
	end
	coreImage("Glow", 600, C.CurrentDeep:Lerp(C.Aqua, 0.4), 0.72, "OuterGlow")
	local ripples: { ImageLabel } = {}
	for index = 1, 3 do
		table.insert(ripples, coreImage("Ring", 120, C.Aqua, 1, `Ripple{index}`))
	end
	coreImage("Glow", 280, C.Aqua, 0.45, "MidGlow")
	local swirlOuter = coreImage("Swirl", 250, C.Aqua, 0.2, "SwirlOuter")
	local swirlInner = coreImage("Swirl", 170, C.Foam, 0.35, "SwirlInner")
	coreImage("Ring", 156, C.Foam, 0.45, "Rim")
	coreImage("Glow", 110, Color3.new(1, 1, 1), 0.05, "Heart")
	local glint = coreImage("Sparkle", 120, C.Foam, 0.1, "Glint")
	maid:Add(Animator.Add(function(time: number)
		swirlOuter.Rotation = time * 14
		swirlInner.Rotation = 180 - time * 22
		glint.Rotation = time * 6
		for index, ripple in ripples do
			local phase = ((time / 4) + (index - 1) / 3) % 1
			local size = 130 + phase * 330
			ripple.Size = UDim2.fromOffset(size, size)
			ripple.ImageTransparency = 0.45 + phase * 0.55
		end
	end, MENU_ID))

	-- Flow along learned streams: a bright band travels outward from the core.
	maid:Add(Animator.Add(function(time: number)
		for _, segment in litSegments do
			local phase = (time * FLOW_SPEED - segment.Distance / FLOW_PERIOD) % 1
			segment.Gradient.Offset = Vector2.new(phase * 2 - 1, 0)
		end
	end, MENU_ID))

	-- HEADER ---------------------------------------------------------------------------
	local header: Frame = Create.new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, HEADER_HEIGHT), ZIndex = 10, Parent = content })
	-- Darken the top edge so the title reads over the nebulae.
	local shade: Frame = Create.new("Frame", { Name = "Shade", BorderSizePixel = 0, BackgroundColor3 = C.Abyss, Size = UDim2.new(1, 0, 1, 30), Parent = header })
	Create.new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(0.15, 1), Parent = shade })
	local navHolder: Frame = Create.new("Frame", { Name = "Nav", BackgroundTransparency = 1, Position = UDim2.fromOffset(SIDE_MARGIN, 16), Size = UDim2.fromOffset(0, 46), AutomaticSize = Enum.AutomaticSize.X, Parent = header })
	UIController.CreateNavStrip("Journal", navHolder, maid)
	local closeHolder: Frame = Create.new("Frame", { Name = "CloseHolder", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -SIDE_MARGIN, 0, 14), Size = UDim2.fromOffset(46, 46), Parent = header })
	UIController.CreateCloseButton(closeHolder, maid)

	local title = Create.Label({
		Text = string.upper(S.Title),
		Font = UITheme.Fonts.Title,
		TextSize = 42,
		Color = Color3.new(1, 1, 1),
		XAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 4),
		Size = UDim2.fromOffset(520, 46),
		Parent = header,
	})
	title.TextStrokeColor3 = C.Abyss
	title.TextStrokeTransparency = 0.4
	Create.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(C.Foam, C.Aqua), Parent = title })
	-- Under the title: a wave crest, or "HALL OF POSITIONS" when opened there.
	local titleWave = Icons.Fx("Wave", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 49), Size = UDim2.fromOffset(200, 16), Color = C.Aqua, Transparency = 0.4, Parent = header })
	local subtitle = Create.Label({
		Text = "",
		Font = UITheme.Fonts.TitleMedium,
		TextSize = UITheme.TextSize.Small,
		Color = C.Accent,
		XAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 48),
		Size = UDim2.fromOffset(520, 18),
		Parent = header,
	})
	-- Resources under the title.
	local chips: Frame = Create.new("Frame", { Name = "Resources", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 70), Size = UDim2.fromOffset(700, 34), Parent = header })
	Create.List(chips, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local skillChip = resourceChip(chips, "SkillPoint", C.Aqua, 1)
	local statChip = resourceChip(chips, "StatPoint", C.Accent, 2)
	local levelChip = resourceChip(chips, "Level", C.Foam, 3)
	local goldChip = resourceChip(chips, "Gold", C.Stamina, 4)
	-- Your Position, top right.
	local positionChip: Frame = Create.new("Frame", {
		Name = "PositionChip",
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.2,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -(SIDE_MARGIN + 58), 0, 16),
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 46),
		Parent = header,
	})
	Create.Corner(positionChip, UDim.new(0, 10))
	local positionStroke = Create.Stroke(positionChip, C.Edge, 1.5, 0.1)
	Create.new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 14), Parent = positionChip })
	Create.List(positionChip, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	-- Roblox's own top-bar buttons (menu, chat, voice) sit over the top-left
	-- corner, and some experiences show more on the right: keep the nav strip,
	-- the Position chip and the close button clear of them.
	local function applyTopbar()
		local inset = GuiService.TopbarInset
		local scale = Layers.GetScale("Menu")
		local left, right = SIDE_MARGIN, SIDE_MARGIN
		if inset.Height > 0 then
			left = math.max(left, inset.Min.X / scale + 8)
			local width = canvas.AbsoluteSize.X
			if inset.Max.X > 0 and inset.Max.X < width - 1 then
				right = math.max(right, (width - inset.Max.X) / scale + 8)
			end
		end
		navHolder.Position = UDim2.fromOffset(left, 16)
		closeHolder.Position = UDim2.new(1, -right, 0, 14)
		positionChip.Position = UDim2.new(1, -(right + 58), 0, 16)
	end
	maid:Add(GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(applyTopbar))
	maid:Add(canvas:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyTopbar))
	local positionIcon = Icons.new("SkillTree", { Size = UDim2.fromOffset(28, 28), LayoutOrder = 1, Parent = positionChip })
	local positionText: Frame = Create.new("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 40), LayoutOrder = 2, Parent = positionChip })
	local positionName = Create.new("TextLabel", {
		BackgroundTransparency = 1,
		Text = "",
		FontFace = UITheme.Fonts.Title,
		TextSize = 18,
		TextColor3 = C.Text,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = positionText,
	})
	local positionRole = Create.new("TextLabel", {
		BackgroundTransparency = 1,
		Text = "",
		FontFace = UITheme.Fonts.Body,
		TextSize = UITheme.TextSize.Caption,
		TextColor3 = C.TextMuted,
		AutomaticSize = Enum.AutomaticSize.X,
		Position = UDim2.fromOffset(0, 21),
		Size = UDim2.fromOffset(0, 16),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = positionText,
	})

	-- LEFT: BUILD ---------------------------------------------------------------------
	local leftPanel, leftBody = sidePanel(content, "Build", S.Build, "StatPoint")
	leftPanel.Position = UDim2.fromOffset(SIDE_MARGIN, HEADER_HEIGHT + 8)
	leftPanel.Size = UDim2.new(0, LEFT_WIDTH, 1, -(HEADER_HEIGHT + 8 + SIDE_MARGIN))
	leftPanel.ZIndex = 8
	local leftScroll: ScrollingFrame = Create.new("ScrollingFrame", {
		Name = "Scroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.Edge,
		Parent = leftBody,
	})
	Create.List(leftScroll, Enum.FillDirection.Vertical, UITheme.Padding.Medium, Enum.HorizontalAlignment.Center)
	local allocator = StatAllocator.new({
		Data = data,
		Confirm = function(points: { [string]: number })
			Net.FireServer("RequestAllocateStats", points)
		end,
		Width = UDim.new(1, -6),
		LayoutOrder = 1,
		Parent = leftScroll,
	})
	maid:Add(allocator)
	local radar = StatRadar.new({ Size = 236, LayoutOrder = 2, Parent = leftScroll })
	maid:Add(radar)
	Create.Label({
		Text = S.RadarHint,
		TextSize = UITheme.TextSize.Caption,
		Color = C.TextDim,
		Wrapped = true,
		XAlignment = Enum.TextXAlignment.Center,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -10, 0, 16),
		LayoutOrder = 3,
		Parent = leftScroll,
	})
	-- On narrow screens the Build panel folds away behind a button.
	local buildToggle = Components.IconButton.new({
		Name = "BuildToggle",
		Icon = "StatPoint",
		Size = 46,
		Tooltip = S.Build,
		Position = UDim2.fromOffset(SIDE_MARGIN, HEADER_HEIGHT + 8),
		Parent = content,
	})
	maid:Add(buildToggle)

	-- RIGHT: DETAILS ------------------------------------------------------------------
	local rightPanel, rightBody = sidePanel(content, "Details", S.DetailsTitle, "Info")
	rightPanel.AnchorPoint = Vector2.new(1, 0)
	rightPanel.Position = UDim2.new(1, -SIDE_MARGIN, 0, HEADER_HEIGHT + 8)
	rightPanel.Size = UDim2.new(0, RIGHT_WIDTH, 1, -(HEADER_HEIGHT + 8 + SIDE_MARGIN))
	rightPanel.ZIndex = 8
	local details = Components.ScrollList.new({ Name = "DetailsList", Spacing = 6, Parent = rightBody })
	maid:Add(details)

	-- BOTTOM: hint and zoom controls -------------------------------------------------------
	local controls: Frame = Create.new("Frame", { Name = "Controls", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -16), Size = UDim2.fromOffset(170, 44), ZIndex = 9, Parent = content })
	Create.List(controls, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local zoomOut = Components.IconButton.new({ Name = "ZoomOut", Icon = "Minus", Size = 40, Tooltip = S.ZoomOut, LayoutOrder = 1, Parent = controls })
	local recenter = Components.IconButton.new({ Name = "Recenter", Icon = "Recenter", Size = 44, Tooltip = S.Recenter, LayoutOrder = 2, Parent = controls })
	local zoomIn = Components.IconButton.new({ Name = "ZoomIn", Icon = "Plus", Size = 40, Tooltip = S.ZoomIn, LayoutOrder = 3, Parent = controls })
	maid:Add(zoomOut)
	maid:Add(recenter)
	maid:Add(zoomIn)
	local hint = Create.Label({
		Text = S.Hint,
		TextSize = UITheme.TextSize.Caption,
		Color = C.TextDim,
		XAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -62),
		Size = UDim2.fromOffset(520, 16),
		Parent = content,
	})
	hint.ZIndex = 9

	-- CHOOSER (no Position yet) ---------------------------------------------------------
	local chooser: ScrollingFrame = Create.new("ScrollingFrame", {
		Name = "Chooser",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = C.Edge,
		Visible = false,
		ZIndex = 7,
		Parent = content,
	})
	Create.List(chooser, Enum.FillDirection.Vertical, UITheme.Padding.Medium, Enum.HorizontalAlignment.Center)
	Create.Padding(chooser, UITheme.Padding.Medium)

	-- LAYOUT ------------------------------------------------------------------------------

	local function layerScale(): number
		return Layers.GetScale("Menu")
	end

	local function screenSize(): Vector2
		return canvas.AbsoluteSize / layerScale()
	end

	-- Narrow screens fold the Build panel away (its button brings it back).
	local function compactLeft(): boolean
		return screenSize().X < LEFT_WIDTH + RIGHT_WIDTH + 760
	end

	-- The part of the screen the tree has to itself (between the panels,
	-- under the header, above the controls), relative to the canvas centre.
	local function freeRegion(): (Vector2, Vector2)
		local size = screenSize()
		local leftEdge = if leftPanel.Visible then SIDE_MARGIN + LEFT_WIDTH + 12 else SIDE_MARGIN + 56
		local rightEdge = size.X - (SIDE_MARGIN + RIGHT_WIDTH + 12)
		local top = HEADER_HEIGHT
		local bottom = size.Y - BOTTOM_ROOM
		local centre = Vector2.new((leftEdge + rightEdge) / 2, (top + bottom) / 2) - size / 2
		return centre, Vector2.new(math.max(rightEdge - leftEdge, 200), math.max(bottom - top, 200))
	end

	local function applyLayout()
		local compact = compactLeft()
		buildToggle.Instance.Visible = compact
		leftPanel.Visible = not compact or leftOpen
		leftPanel.Position = UDim2.fromOffset(SIDE_MARGIN + (if compact then 56 else 0), HEADER_HEIGHT + 8)
		local centre, room = freeRegion()
		chooser.Position = UDim2.new(0.5, centre.X - room.X / 2, 0.5, centre.Y - room.Y / 2)
		chooser.Size = UDim2.fromOffset(room.X, room.Y + BOTTOM_ROOM - 10)
		controls.Position = UDim2.new(0.5, centre.X, 1, -16)
		hint.Position = UDim2.new(0.5, centre.X, 1, -62)
	end
	buildToggle.Activated:Connect(function()
		leftOpen = not leftOpen
		applyLayout()
	end)

	-- VIEW ---------------------------------------------------------------------------------

	local function clampPan()
		-- Keep the core within reach: never more than the tree's size off-screen.
		local limit = 640 * zoom + 160
		pan = Vector2.new(math.clamp(pan.X, -limit, limit), math.clamp(pan.Y, -limit, limit))
	end

	local function applyView()
		clampPan()
		world.Position = UDim2.new(0.5, pan.X, 0.5, pan.Y)
		worldScale.Scale = zoom
	end

	-- Zoom and pan that frame the whole tree inside the free region.
	local function fitView(positionId: string): (number, Vector2)
		local low, high = treeBounds(positionId)
		local span = high - low
		local centre, room = freeRegion()
		room -= Vector2.new(40, 40)
		local fit = math.clamp(math.min(room.X / math.max(span.X, 1), room.Y / math.max(span.Y, 1)), ZOOM_MIN, ZOOM_MAX)
		return fit, centre - (low + high) / 2 * fit
	end

	-- Zoom keeping the point under `focus` (px from the canvas centre) still.
	local function zoomAt(focus: Vector2, newZoom: number)
		viewTouched = true
		newZoom = math.clamp(newZoom, ZOOM_MIN, ZOOM_MAX)
		pan = focus - (focus - pan) * (newZoom / zoom)
		zoom = newZoom
		applyView()
	end

	local function centerOn(point: Vector2, animate: boolean)
		viewTouched = true
		local centre = freeRegion()
		local goal = centre - point * zoom
		if animate then
			local from = pan
			local started = os.clock()
			local stop: (() -> ())? = nil
			stop = Animator.Add(function()
				local alpha = math.clamp((os.clock() - started) / 0.25, 0, 1)
				local eased = 1 - (1 - alpha) * (1 - alpha)
				pan = from:Lerp(goal, eased)
				applyView()
				if alpha >= 1 and stop then
					stop()
				end
			end)
			treeMaid:Set("centre", stop)
		else
			pan = goal
			applyView()
		end
	end

	local function resetView()
		zoom, pan = fitView(builtFor)
		applyView()
		viewTouched = false
	end
	-- The window may still be settling (sliding in, or switching from the
	-- framed Character window to full screen) when the tree is first fitted,
	-- so refit whenever the canvas resizes until you move the view yourself.
	maid:Add(canvas:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		applyLayout()
		if isOpen and not viewTouched and builtFor ~= "" then
			resetView()
		end
	end))
	recenter.Activated:Connect(resetView)
	zoomIn.Activated:Connect(function()
		zoomAt((freeRegion()), zoom * ZOOM_STEP)
	end)
	zoomOut.Activated:Connect(function()
		zoomAt((freeRegion()), zoom / ZOOM_STEP)
	end)

	-- Canvas-centre-relative position of a screen point (input positions and
	-- AbsolutePosition share the same space).
	local function fromCentre(position: Vector2): Vector2
		local centre = canvas.AbsolutePosition + canvas.AbsoluteSize / 2
		return (position - centre) / layerScale()
	end

	-- Pan by dragging, zoom with the wheel or a pinch.
	local dragInput: InputObject? = nil
	local dragStart = Vector2.zero
	local panStart = Vector2.zero
	local pinching = false
	local pinchStartZoom = 1
	maid:Add(canvas.InputBegan:Connect(function(input: InputObject)
		local kind = input.UserInputType
		if (kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch) and not dragInput and not chooser.Visible then
			dragInput = input
			dragStart = Vector2.new(input.Position.X, input.Position.Y)
			panStart = pan
		end
	end))
	maid:Add(UserInputService.InputChanged:Connect(function(input: InputObject)
		if not isOpen then
			return
		end
		if input.KeyCode == Enum.KeyCode.Thumbstick2 then
			local value = Vector2.new(input.Position.X, -input.Position.Y)
			stick = if value.Magnitude > 0.2 then value else Vector2.zero
			return
		end
		local active = dragInput
		if not active or pinching then
			return
		end
		local matches = (active.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement)
			or input == active
		if matches then
			local delta = (Vector2.new(input.Position.X, input.Position.Y) - dragStart) / layerScale()
			if delta.Magnitude > DRAG_THRESHOLD then
				pan = panStart + delta
				viewTouched = true
				applyView()
			end
		end
	end))
	maid:Add(UserInputService.InputEnded:Connect(function(input: InputObject)
		local active = dragInput
		if active and (input == active or (active.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseButton1)) then
			dragInput = nil
		end
	end))
	maid:Add(canvas.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseWheel and not chooser.Visible then
			local focus = fromCentre(Vector2.new(input.Position.X, input.Position.Y))
			zoomAt(focus, zoom * (if input.Position.Z > 0 then 1.12 else 1 / 1.12))
		end
	end))
	maid:Add(canvas.TouchPinch:Connect(function(touches: { Vector2 }, scale: number, _velocity: number, state: Enum.UserInputState)
		if chooser.Visible then
			return
		end
		if state == Enum.UserInputState.Begin then
			pinching = true
			dragInput = nil
			pinchStartZoom = zoom
		elseif state == Enum.UserInputState.Change then
			local focus = if #touches >= 2 then fromCentre((touches[1] + touches[2]) / 2) else Vector2.zero
			zoomAt(focus, pinchStartZoom * scale)
		else
			pinching = false
		end
	end))
	maid:Add(RunService.RenderStepped:Connect(function(dt: number)
		if isOpen and stick.Magnitude > 0 and not chooser.Visible then
			pan -= stick * STICK_PAN_SPEED * dt
			viewTouched = true
			applyView()
		end
	end))

	-- TREE ---------------------------------------------------------------------------------

	local function stateOf(current: PlayerData, id: string): Rules.NodeState
		return Rules.NodeState(current, id)
	end

	local renderPanel: () -> ()

	local function select(id: string?)
		selectedId = id
		for nodeId, view in nodeViews do
			local isSelected = nodeId == id
			view.Selected.Visible = isSelected
			view.Scale.Scale = if isSelected then 1.12 else 1
		end
		renderPanel()
	end

	-- Why a node can't be learned right now (nil if it can).
	local function blocker(current: PlayerData, node: NodeDef): string?
		local state = stateOf(current, node.Id)
		if state == "Taken" then
			return S.Learned
		elseif state == "Locked" then
			return S.NeedLink
		elseif state == "Unaffordable" then
			return Strings.Format(S.NeedMorePoints, { more = Rules.NodeCost(node) - current.SkillPoints })
		end
		return nil
	end

	local function learn(id: string)
		local current = data()
		local node = Positions.Node(id)
		if not current or not node or stateOf(current, id) == "Taken" then
			return
		end
		local reason = blocker(current, node)
		if reason then
			-- Say why, and give the node a little shake.
			UISound.Play("UIError")
			Components.Toast.Push({ Title = reason, Color = C.Danger, Key = "SkillTreeBlocked" })
			local view = nodeViews[id]
			if view then
				local button = view.Button
				local base = button.Position
				for step = 1, 4 do
					task.delay(step * 0.04, function()
						button.Position = base + UDim2.fromOffset(if step % 2 == 1 then 4 else -4, 0)
					end)
				end
				task.delay(0.2, function()
					button.Position = base
				end)
			end
			return
		end
		Net.FireServer("RequestUnlockNode", id)
	end

	local function requirementNames(node: NodeDef): { string }
		local names = {}
		for _, link in node.Links do
			local linked = Positions.Node(link)
			if linked then
				table.insert(names, ProgressionText.NodeName(linked))
			end
		end
		return names
	end

	local function tooltipFor(node: NodeDef, color: Color3): Components.TooltipContent
		local current = data()
		local lines: { Components.TooltipLine } = {}
		for _, text in ProgressionText.NodeLines(node) do
			table.insert(lines, { Text = text, Color = C.Aqua })
		end
		local names = requirementNames(node)
		table.insert(lines, {
			Text = if #names == 0 then S.RequiresCore elseif #names == 1 then Strings.Format(S.Requires, { names = names[1] }) else Strings.Format(S.RequiresOne, { names = table.concat(names, ", ") }),
			Color = C.TextMuted,
		})
		local cost = Rules.NodeCost(node)
		table.insert(lines, { Text = Strings.Format(if cost == 1 then S.CostOne else S.CostMany, { cost = cost }), Color = C.Text, Bold = true })
		local footer: string
		if not current then
			footer = ""
		else
			local reason = blocker(current, node)
			footer = if reason then reason elseif selectedId == node.Id then S.ClickToLearn else S.ClickToSelect
		end
		return {
			Title = ProgressionText.NodeName(node),
			TitleColor = color:Lerp(Color3.new(1, 1, 1), 0.35),
			Icon = nodeIcon(node),
			Subtitle = `{S.Kinds[node.Kind]}  ·  {ProgressionText.BranchName(node.Branch)}`,
			Lines = lines,
			Footer = footer,
		}
	end

	-- One stream: a quadratic curve from `a` to `b`, bowed by `bend` px
	-- (0 = straight), drawn as short segments with a soft glow under them.
	-- `startDistance` is how far along the branch `a` is (for the flow).
	local function stream(a: Vector2, b: Vector2, bend: number, startDistance: number, color: Color3): { Segment }
		local delta = b - a
		local length = delta.Magnitude
		local normal = if length > 0 then Vector2.new(-delta.Y, delta.X) / length else Vector2.zero
		local control = (a + b) / 2 + normal * bend
		local count = if math.abs(bend) < 0.5 then 1 else 5
		local segments: { Segment } = {}
		local previous = a
		local travelled = startDistance
		local half = Vector2.new(WORLD_SIZE / 2, WORLD_SIZE / 2)
		for index = 1, count do
			local t = index / count
			local point = a * (1 - t) * (1 - t) + control * 2 * (1 - t) * t + b * t * t
			local glow = Shapes.Line(previous + half, point + half, 10, { Name = "Glow", Color = color, Transparency = 1, Parent = streamsLayer })
			local line = Shapes.Line(previous + half, point + half, 2, { Name = "Stream", Color = STREAM_DIM, Parent = streamsLayer })
			Create.Corner(glow, UITheme.CornerPill)
			Create.Corner(line, UITheme.CornerPill)
			-- Bright band that slides along the segment while the stream is lit.
			local gradient: UIGradient = Create.new("UIGradient", {
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0),
					NumberSequenceKeypoint.new(1, 0),
				}),
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(205, 215, 230)),
					ColorSequenceKeypoint.new(0.45, Color3.fromRGB(205, 215, 230)),
					ColorSequenceKeypoint.new(0.5, Color3.new(1, 1, 1)),
					ColorSequenceKeypoint.new(0.55, Color3.fromRGB(205, 215, 230)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(205, 215, 230)),
				}),
				Parent = line,
			})
			table.insert(segments, { Frame = line, Glow = glow, Gradient = gradient, Distance = travelled })
			travelled += (point - previous).Magnitude
			previous = point
		end
		return segments
	end

	local function buildTree(positionId: string)
		treeMaid:Clean()
		table.clear(nodeViews)
		table.clear(streamViews)
		table.clear(litSegments)
		for _, layerFrame in { streamsLayer, nodesLayer, labelsLayer } do
			layerFrame:ClearAllChildren()
		end
		builtFor = positionId
		selectedId = nil
		local def = Positions.Get(positionId)
		if not def then
			return
		end
		local colors = branchColors(def)
		local half = Vector2.new(WORLD_SIZE / 2, WORLD_SIZE / 2)

		-- Streams first, so nodes draw on top. Forked links bow outward from
		-- the branch's spine; links along the spine stay straight.
		for _, branchDef in def.Branches do
			local color = colors[branchDef.Id]
			local radians = math.rad(branchDef.Angle)
			local along = Vector2.new(math.cos(radians), math.sin(radians))
			local side = Vector2.new(-along.Y, along.X)
			for _, node in branchDef.Nodes do
				local toPoint = pixel(node)
				if #node.Links == 0 then
					-- From the rim of the core.
					local start = along * 74
					table.insert(streamViews, { From = nil, To = node.Id, Color = color, Segments = stream(start, toPoint, 0, 0, color) })
				end
				for _, link in node.Links do
					local from = Positions.Node(link)
					if from then
						local fromPoint = pixel(from)
						local offset = fromPoint:Dot(side) + toPoint:Dot(side)
						local delta = toPoint - fromPoint
						local normal = Vector2.new(-delta.Y, delta.X).Unit
						local bend = if math.abs(offset) < 1 then 0 else math.sign(normal:Dot(side) * offset) * delta.Magnitude * 0.16
						table.insert(streamViews, { From = link, To = node.Id, Color = color, Segments = stream(fromPoint, toPoint, bend, fromPoint.Magnitude, color) })
					end
				end
			end

			-- Branch name and its ability's icon, beside the stream near the core.
			-- The label starts beside the stream (anchored on its near edge) so it
			-- never runs back over the stream or the branch's first node.
			local away = side * (if side.X < -0.01 or (math.abs(side.X) <= 0.01 and side.Y < 0) then -1 else 1)
			local labelPoint = along * 118 + away * 22
			local labelHolder: Frame = Create.new("Frame", {
				Name = `Branch_{branchDef.Id}`,
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(if away.X > 0.3 then 0 elseif away.X < -0.3 then 1 else 0.5, if away.Y > 0.3 then 0 elseif away.Y < -0.3 then 1 else 0.5),
				Position = UDim2.fromOffset(labelPoint.X + half.X, labelPoint.Y + half.Y),
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.fromOffset(0, 24),
				Parent = labelsLayer,
			})
			Create.List(labelHolder, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
			local ability = branchAbility(branchDef)
			Icons.new(if ability then Icons.ForAbility(ability) else "SkillTree", { Size = UDim2.fromOffset(18, 18), Color = color, LayoutOrder = 1, Parent = labelHolder })
			local nameLabel = Create.new("TextLabel", {
				BackgroundTransparency = 1,
				Text = string.upper(ProgressionText.BranchName(branchDef.Id)),
				FontFace = UITheme.Fonts.Title,
				TextSize = 17,
				TextColor3 = color:Lerp(Color3.new(1, 1, 1), 0.3),
				TextStrokeColor3 = C.Abyss,
				TextStrokeTransparency = 0.3,
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.new(0, 0, 1, 0),
				LayoutOrder = 2,
				Parent = labelHolder,
			})
			nameLabel.Name = "Name"
		end

		-- Nodes.
		for _, node in Positions.NodesOf(positionId) do
			local color = colors[node.Branch] or C.Aqua
			local size = NODE_SIZE[node.Kind] or 30
			local point = pixel(node) + half
			local button: TextButton = Create.new("TextButton", {
				Name = node.Id,
				Text = "",
				AutoButtonColor = false,
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(point.X, point.Y),
				Size = UDim2.fromOffset(size, size),
				Selectable = true,
				SelectionImageObject = Create.SelectionImage(),
				Parent = nodesLayer,
			})
			local scale: UIScale = Create.new("UIScale", { Parent = button })
			local halo = Icons.Fx("Glow", {
				Name = "Halo",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(2.5, 2.5),
				Color = color,
				Transparency = 1,
				Parent = button,
			})
			local rim: ImageLabel? = nil
			if node.Kind ~= "Minor" then
				-- Notables, abilities and keystones wear an outer ring.
				rim = Icons.Fx("Ring", {
					Name = "Rim",
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromScale(if node.Kind == "Keystone" then 1.5 else 1.36, if node.Kind == "Keystone" then 1.5 else 1.36),
					Color = color,
					Transparency = 0.6,
					ZIndex = 2,
					Parent = button,
				})
			end
			local disc: Frame = Create.new("Frame", {
				Name = "Disc",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = C.PanelSunken,
				ZIndex = 3,
				Parent = button,
			})
			Create.Corner(disc, UITheme.CornerPill)
			Create.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(150, 165, 190)), Parent = disc })
			local stroke = Create.Stroke(disc, LOCKED_RIM, if node.Kind == "Minor" then 2 else 2.5, 0)
			local icon = Icons.new(nodeIcon(node), {
				Name = "Icon",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(0.58, 0.58),
				Color = C.TextDim,
				ZIndex = 4,
				Parent = button,
			})
			local lock: ImageLabel? = nil
			if node.Kind == "Active" or node.Kind == "Keystone" then
				lock = Icons.new("Lock", {
					Name = "Lock",
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.new(1, -2, 1, -2),
					Size = UDim2.fromOffset(14, 14),
					Color = C.TextMuted,
					ZIndex = 5,
					Parent = button,
				})
			end
			local selectedRing = Icons.Fx("Ring", {
				Name = "SelectedRing",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1.75, 1.75),
				Color = C.Foam,
				Transparency = 0,
				ZIndex = 5,
				Parent = button,
			})
			selectedRing.Visible = false
			local view: NodeView = {
				Def = node,
				Color = color,
				Button = button,
				Disc = disc,
				Stroke = stroke,
				Icon = icon,
				Halo = halo,
				Rim = rim,
				Lock = lock,
				Selected = selectedRing,
				Scale = scale,
				StopPulse = nil,
			}
			nodeViews[node.Id] = view
			treeMaid:Add(Components.Tooltip.Attach(button, function()
				return tooltipFor(node, color)
			end))
			treeMaid:Add(button.MouseEnter:Connect(function()
				if selectedId ~= node.Id then
					TweenService:Create(scale, TweenInfo.new(0.1), { Scale = 1.08 }):Play()
				end
			end))
			treeMaid:Add(button.MouseLeave:Connect(function()
				TweenService:Create(scale, TweenInfo.new(0.1), { Scale = if selectedId == node.Id then 1.12 else 1 }):Play()
			end))
			treeMaid:Add(button.Activated:Connect(function()
				if selectedId == node.Id then
					learn(node.Id)
				else
					UISound.Play("UIClick")
					select(node.Id)
				end
			end))
			treeMaid:Add(button.SelectionGained:Connect(function()
				if selectedId ~= node.Id then
					select(node.Id)
				end
				centerOn(pixel(node), true)
			end))
		end
		-- The selected ring turns slowly.
		treeMaid:Add(Animator.Add(function(time: number)
			local id = selectedId
			local view = id and nodeViews[id]
			if view then
				view.Selected.Rotation = time * 40
			end
		end, MENU_ID))
	end

	-- Colours every node and stream by state.
	local function refreshStates(current: PlayerData)
		table.clear(litSegments)
		for id, view in nodeViews do
			local state = stateOf(current, id)
			local color = view.Color
			if view.StopPulse then
				view.StopPulse()
				view.StopPulse = nil
			end
			local rim = view.Rim
			local lock = view.Lock
			if state == "Taken" then
				view.Disc.BackgroundColor3 = color:Lerp(C.Abyss, 0.3)
				view.Stroke.Color = color:Lerp(Color3.new(1, 1, 1), 0.45)
				view.Stroke.Transparency = 0
				view.Icon.ImageColor3 = Color3.new(1, 1, 1)
				view.Icon.ImageTransparency = 0
				view.Halo.ImageTransparency = 0.55
				if rim then
					rim.ImageTransparency = 0.15
				end
			elseif state == "Available" then
				view.Disc.BackgroundColor3 = C.Panel
				view.Stroke.Color = color
				view.Stroke.Transparency = 0
				view.Icon.ImageColor3 = C.Foam
				view.Icon.ImageTransparency = 0
				view.Halo.ImageTransparency = 0.7
				view.StopPulse = Animator.Pulse(view.Halo, "ImageTransparency", 0.45, 0.85, 1.6, MENU_ID)
				if rim then
					rim.ImageTransparency = 0.35
				end
			elseif state == "Unaffordable" then
				view.Disc.BackgroundColor3 = C.PanelSunken
				view.Stroke.Color = color:Lerp(LOCKED_RIM, 0.5)
				view.Stroke.Transparency = 0
				view.Icon.ImageColor3 = C.TextMuted
				view.Icon.ImageTransparency = 0
				view.Halo.ImageTransparency = 1
				if rim then
					rim.ImageTransparency = 0.6
				end
			else
				view.Disc.BackgroundColor3 = C.PanelSunken
				view.Stroke.Color = LOCKED_RIM
				view.Stroke.Transparency = 0.1
				view.Icon.ImageColor3 = C.TextDim
				view.Icon.ImageTransparency = 0.3
				view.Halo.ImageTransparency = 1
				if rim then
					rim.ImageTransparency = 0.8
				end
			end
			if lock then
				lock.Visible = state == "Locked"
			end
		end
		for _, streamView in streamViews do
			local fromTaken = streamView.From == nil or current.SkillTree[streamView.From] == true
			local lit = fromTaken and current.SkillTree[streamView.To] == true
			local open = fromTaken and not lit
			for _, segment in streamView.Segments do
				local line = segment.Frame
				local thickness = if lit then 4 elseif open then 2.5 else 2
				line.Size = UDim2.fromOffset(line.Size.X.Offset, thickness)
				line.BackgroundColor3 = if lit then streamView.Color elseif open then streamView.Color:Lerp(STREAM_DIM, 0.45) else STREAM_DIM
				line.BackgroundTransparency = if open then 0.2 else 0
				segment.Glow.BackgroundTransparency = if lit then 0.8 elseif open then 0.93 else 1
				segment.Gradient.Enabled = lit
				if lit then
					table.insert(litSegments, segment)
				end
			end
		end
	end

	-- A Current spark runs into a freshly learned node, then a ripple.
	local function pulseInto(id: string)
		local view = nodeViews[id]
		local current = data()
		if not view or not current then
			return
		end
		local node = view.Def
		local half = Vector2.new(WORLD_SIZE / 2, WORLD_SIZE / 2)
		local fromPoint = Vector2.zero
		for _, link in node.Links do
			local linked = Positions.Node(link)
			if linked and current.SkillTree[link] then
				fromPoint = pixel(linked)
				break
			end
		end
		fromPoint += half
		local toPoint = pixel(node) + half
		local spark = Icons.Fx("Sparkle", {
			Name = "Spark",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(fromPoint.X, fromPoint.Y),
			Size = UDim2.fromOffset(34, 34),
			Color = C.Foam,
			ZIndex = 6,
			Parent = labelsLayer,
		})
		local tween = TweenService:Create(spark, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.fromOffset(toPoint.X, toPoint.Y),
		})
		tween:Play()
		tween.Completed:Once(function()
			spark:Destroy()
			view.Scale.Scale = 1.6
			TweenService:Create(view.Scale, TweenInfo.new(0.4, Enum.EasingStyle.Back), { Scale = if selectedId == id then 1.12 else 1 }):Play()
			for index = 1, 2 do
				local ring = Icons.Fx("Ring", {
					Name = "LearnRipple",
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromOffset(toPoint.X, toPoint.Y),
					Size = UDim2.fromOffset(30, 30),
					Color = view.Color:Lerp(Color3.new(1, 1, 1), 0.4),
					ZIndex = 6,
					Parent = labelsLayer,
				})
				local grow = TweenService:Create(ring, TweenInfo.new(0.55 + index * 0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Size = UDim2.fromOffset(130 + index * 50, 130 + index * 50),
					ImageTransparency = 1,
				})
				grow:Play()
				grow.Completed:Once(function()
					ring:Destroy()
				end)
			end
		end)
	end

	-- DETAILS PANEL --------------------------------------------------------------------

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	local function text(value: string, props: { [string]: any }?): TextLabel
		local options: { [string]: any } = props or {}
		local label = Create.Label({
			Text = value,
			Font = options.Font,
			TextSize = options.TextSize or UITheme.TextSize.Small,
			Color = options.Color or C.TextMuted,
			Wrapped = true,
			RichText = options.RichText,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, -8, 0, 0),
			LayoutOrder = nextOrder(),
		})
		details:Add(label)
		return label
	end

	local function heading(value: string, icon: string)
		local row: Frame = Create.new("Frame", { Name = "Heading", BackgroundTransparency = 1, Size = UDim2.new(1, -8, 0, 28), LayoutOrder = nextOrder() })
		Icons.new(icon, { Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(0, 6), Color = C.Aqua, Parent = row })
		Create.Label({ Text = string.upper(value), Font = UITheme.Fonts.Title, TextSize = 15, Color = C.Accent, Position = UDim2.fromOffset(24, 0), Size = UDim2.new(1, -24, 1, 0), Parent = row })
		Create.new("Frame", { BorderSizePixel = 0, BackgroundColor3 = C.Edge, BackgroundTransparency = 0.4, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 1), Parent = row })
		details:Add(row)
	end

	local function gap(height: number)
		details:Add(Create.new("Frame", { Name = "Gap", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, height), LayoutOrder = nextOrder() }))
	end

	-- An "icon  text" line (bonus effects, requirements, cost).
	local function iconLine(icon: string, value: string, color: Color3, iconColor: Color3?)
		local row: Frame = Create.new("Frame", { Name = "Line", BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, -8, 0, 22), LayoutOrder = nextOrder() })
		Icons.new(icon, { Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(0, 3), Color = iconColor or color, Parent = row })
		Create.Label({
			Text = value,
			RichText = true,
			TextSize = UITheme.TextSize.Small,
			Color = color,
			Wrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Position = UDim2.fromOffset(24, 0),
			Size = UDim2.new(1, -24, 0, 22),
			Parent = row,
		})
		details:Add(row)
	end

	local function button(props: { [string]: any }): Components.Button
		local holder: Frame = Create.new("Frame", { Name = `{props.Name}Row`, BackgroundTransparency = 1, Size = UDim2.new(1, -8, 0, 40), LayoutOrder = nextOrder() })
		props.Parent = holder
		props.Size = props.Size or UDim2.new(1, 0, 0, 36)
		local made = Components.Button.new(props :: any)
		details:Add(holder)
		return made
	end

	local function confirmRespec(changePosition: boolean)
		local current = data()
		if not current then
			return
		end
		local cost = Rules.RespecCost(current)
		local body = if cost == 0 then S.RespecBodyFree else Strings.Format(S.RespecBody, { gold = cost })
		if changePosition then
			body ..= `\n\n{S.RespecChange}`
		end
		UIController.Confirm({
			Title = S.RespecTitle,
			Message = body,
			ConfirmText = if cost == 0 then S.RespecFree else Strings.Format(S.RespecCost, { gold = cost }),
			Danger = true,
		}):andThen(function(yes: boolean): any
			if yes then
				Net.FireServer("RequestRespec", changePosition)
			end
			return nil
		end)
	end

	-- The selected node: a header card, effects, requirements, cost and Learn.
	local function nodeCard(current: PlayerData, node: NodeDef, color: Color3)
		local state = stateOf(current, node.Id)
		local cardFrame: Frame = Create.new("Frame", {
			Name = "NodeCard",
			BackgroundColor3 = C.PanelSunken,
			BackgroundTransparency = 0.3,
			Size = UDim2.new(1, -8, 0, 76),
			LayoutOrder = nextOrder(),
		})
		Create.Corner(cardFrame, UDim.new(0, 10))
		Create.Stroke(cardFrame, color, 1.2, 0.45)
		local badge: Frame = Create.new("Frame", {
			Name = "Badge",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 12, 0.5, 0),
			Size = UDim2.fromOffset(52, 52),
			BackgroundColor3 = if state == "Taken" then color:Lerp(C.Abyss, 0.3) else C.Panel,
			Parent = cardFrame,
		})
		Create.Corner(badge, UITheme.CornerPill)
		Create.Stroke(badge, color, 2, 0)
		Icons.new(nodeIcon(node), { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(30, 30), Color = Color3.new(1, 1, 1), Parent = badge })
		Create.Label({
			Text = ProgressionText.NodeName(node),
			Font = UITheme.Fonts.Title,
			TextSize = 18,
			Color = color:Lerp(Color3.new(1, 1, 1), 0.35),
			Wrapped = true,
			Position = UDim2.fromOffset(76, 10),
			Size = UDim2.new(1, -84, 0, 34),
			YAlignment = Enum.TextYAlignment.Top,
			Parent = cardFrame,
		})
		Create.Label({
			Text = `{S.Kinds[node.Kind]}  ·  {ProgressionText.BranchName(node.Branch)}`,
			TextSize = UITheme.TextSize.Caption,
			Color = C.TextMuted,
			Position = UDim2.fromOffset(76, 48),
			Size = UDim2.new(1, -84, 0, 18),
			Parent = cardFrame,
		})
		details:Add(cardFrame)

		-- State.
		local stateText, stateColor, stateIcon
		if state == "Taken" then
			stateText, stateColor, stateIcon = S.Learned, C.Heal, "Check"
		elseif state == "Available" then
			stateText, stateColor, stateIcon = S.StateAvailable, C.Aqua, "SkillPoint"
		elseif state == "Unaffordable" then
			stateText, stateColor, stateIcon = Strings.Format(S.NeedMorePoints, { more = Rules.NodeCost(node) - current.SkillPoints }), C.Parry, "SkillPoint"
		else
			stateText, stateColor, stateIcon = S.NeedLink, C.TextDim, "Lock"
		end
		iconLine(stateIcon, `<b>{stateText}</b>`, stateColor)
		gap(2)

		heading(S.Effects, "Info")
		if node.Ability then
			local def = Abilities.Get(node.Ability)
			iconLine(nodeIcon(node), ProgressionText.AbilityDescription(node.Ability), C.Text, color)
			if def then
				iconLine("Time", Strings.Format(S.AbilityStats, { cost = def.Cost, cooldown = def.Cooldown }), C.TextMuted)
			end
		else
			local ids = {}
			for id in node.Bonuses do
				table.insert(ids, id)
			end
			table.sort(ids)
			for _, id in ids do
				local lines = ProgressionText.BonusLines({ [id] = node.Bonuses[id] })
				iconLine(Icons.ForBonus(id), lines[1] or id, C.Aqua)
			end
		end
		gap(2)

		heading(S.RequirementsTitle, "SkillTree")
		local names = requirementNames(node)
		if #names == 0 then
			iconLine("Current", S.RequiresCore, C.TextMuted)
		else
			for index, link in node.Links do
				local taken = current.SkillTree[link] == true
				iconLine(if taken then "Check" else "Lock", names[index] or link, if taken then C.Text else C.TextDim, if taken then C.Heal else C.TextDim)
			end
			if #names > 1 then
				text(S.AnyOneOf, { TextSize = UITheme.TextSize.Caption, Color = C.TextDim })
			end
		end
		local cost = Rules.NodeCost(node)
		iconLine("SkillPoint", Strings.Format(if cost == 1 then S.CostOne else S.CostMany, { cost = cost }), C.Text, C.Aqua)
		gap(4)

		if state ~= "Taken" then
			local reason = blocker(current, node)
			local learnButton = button({
				Name = "Learn",
				Text = if reason then reason else S.Learn,
				Icon = if reason then (if state == "Locked" then "Lock" else "SkillPoint") else "Check",
				Variant = if reason then "Secondary" else "Primary",
				Enabled = reason == nil,
				TextSize = UITheme.TextSize.Small,
				OnActivated = function()
					learn(node.Id)
				end,
			})
			learnButton.Instance.Selectable = reason == nil
		end
	end

	local function abilityRows(current: PlayerData, def: Positions.PositionDef, colors: { [string]: Color3 })
		heading(S.Abilities, "AbilityPower")
		for _, branchDef in def.Branches do
			for _, node in branchDef.Nodes do
				local abilityId = node.Ability
				if abilityId then
					local learned = current.SkillTree[node.Id] == true
					local equipped = current.Hotbar.Ability == abilityId
					local color = colors[branchDef.Id]
					local row: Frame = Create.new("Frame", { Name = `Ability_{abilityId}`, BackgroundColor3 = C.PanelSunken, BackgroundTransparency = if equipped then 0.1 else 0.45, Size = UDim2.new(1, -8, 0, 48), LayoutOrder = nextOrder() })
					Create.Corner(row, UDim.new(0, 8))
					Create.Stroke(row, if equipped then C.Aqua else C.Edge, 1.2, if equipped then 0 else 0.4)
					Icons.new(Icons.ForAbility(abilityId), { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Size = UDim2.fromOffset(26, 26), Color = if learned then color else C.TextDim, Parent = row })
					Create.Label({ Text = ProgressionText.AbilityName(abilityId), Font = UITheme.Fonts.BodyBold, TextSize = UITheme.TextSize.Small, Color = if learned then C.Text else C.TextDim, Position = UDim2.fromOffset(46, 5), Size = UDim2.new(1, -150, 0, 20), Parent = row })
					Create.Label({
						Text = if equipped then `{S.Equipped}  ({InputController.GetPrompt("Ability")})` elseif learned then S.LearnedShort else `{Strings.Format(S.Cost, { cost = Rules.NodeCost(node) })}  ·  {ProgressionText.BranchName(branchDef.Id)}`,
						TextSize = UITheme.TextSize.Caption,
						Color = if equipped then C.Aqua else C.TextDim,
						Position = UDim2.fromOffset(46, 24),
						Size = UDim2.new(1, -150, 0, 18),
						Parent = row,
					})
					if learned and not equipped then
						local equip = Components.Button.new({
							Name = `Equip_{abilityId}`,
							Text = S.EquipShort,
							TextSize = UITheme.TextSize.Caption,
							AnchorPoint = Vector2.new(1, 0.5),
							Position = UDim2.new(1, -8, 0.5, 0),
							Size = UDim2.fromOffset(92, 30),
							Parent = row,
							OnActivated = function()
								Net.FireServer("RequestEquipAbility", abilityId)
							end,
						})
						equip.Instance.ZIndex = row.ZIndex + 1
					end
					details:Add(row)
				end
			end
		end
	end

	function renderPanel()
		details:Clear()
		order = 0
		local current = data()
		if not current then
			return
		end
		local def = Positions.Get(current.Position)
		if not def then
			-- The chooser explains everything; the panel just sums it up.
			text(S.NoPositionYet, { Font = UITheme.Fonts.Title, TextSize = UITheme.TextSize.Body, Color = C.Text })
			local levelled = current.Level >= P.Positions.UnlockLevel
			text(if levelled and atHall() then S.ChooseHint elseif levelled then S.VisitHallHint else Strings.Format(S.NoPositionHint, { level = P.Positions.UnlockLevel }))
			if Rules.InvestedStatPoints(current) > 0 then
				gap(10)
				local cost = Rules.RespecCost(current)
				button({
					Name = "Respec",
					Text = if cost == 0 then S.RespecFree else Strings.Format(S.RespecCost, { gold = cost }),
					Icon = "Reset",
					Variant = "Danger",
					TextSize = UITheme.TextSize.Small,
					OnActivated = function()
						confirmRespec(false)
					end,
				})
			end
			return
		end
		local colors = branchColors(def)

		local node = if selectedId then Positions.Node(selectedId) else nil
		if node and node.Position == def.Id then
			nodeCard(current, node, colors[node.Branch] or C.Aqua)
		else
			iconLine("Info", S.Details, C.TextDim)
		end
		gap(8)
		abilityRows(current, def, colors)
		gap(8)

		heading(S.RebuildTitle, "Reset")
		local cost = Rules.RespecCost(current)
		button({
			Name = "Respec",
			Text = if cost == 0 then S.RespecFree else Strings.Format(S.RespecCost, { gold = cost }),
			Icon = "Reset",
			Variant = "Danger",
			TextSize = UITheme.TextSize.Small,
			Enabled = Rules.HasAnythingToRespec(current, false),
			OnActivated = function()
				confirmRespec(false)
			end,
		})
		button({
			Name = "ChangePosition",
			Text = S.RespecChange,
			TextSize = UITheme.TextSize.Caption,
			OnActivated = function()
				confirmRespec(true)
			end,
		})
	end

	-- CHOOSER --------------------------------------------------------------------------

	local function renderChooser(current: PlayerData)
		for _, child in chooser:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		Create.Label({
			Text = string.upper(S.ChooseTitle),
			Font = UITheme.Fonts.Title,
			TextSize = 28,
			Color = C.Foam,
			XAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.new(1, 0, 0, 36),
			LayoutOrder = 1,
			Parent = chooser,
		})
		Create.Label({
			Text = S.ChooseIntro,
			Wrapped = true,
			Color = C.TextMuted,
			TextSize = UITheme.TextSize.Small,
			XAlignment = Enum.TextXAlignment.Center,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(0.9, 0, 0, 0),
			LayoutOrder = 2,
			Parent = chooser,
		})
		local levelOk = current.Level >= P.Positions.UnlockLevel
		local here = atHall()
		local status = if not levelOk then Strings.Format(S.ChooseLocked, { level = P.Positions.UnlockLevel }) elseif not here then S.ChooseAway else ""
		if status ~= "" then
			Create.Label({
				Text = status,
				Font = UITheme.Fonts.BodyBold,
				Color = if levelOk then C.Aqua else C.Danger,
				TextSize = UITheme.TextSize.Small,
				XAlignment = Enum.TextXAlignment.Center,
				Wrapped = true,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(0.9, 0, 0, 0),
				LayoutOrder = 3,
				Parent = chooser,
			})
		end
		-- The grid wraps to the free width (several cards on a desktop, 1-2 on phones).
		local row: Frame = Create.new("Frame", {
			Name = "Cards",
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, -10, 0, 0),
			LayoutOrder = 4,
			Parent = chooser,
		})
		local grid = Create.new("UIGridLayout", {
			CellSize = UDim2.fromOffset(204, 318),
			CellPadding = UDim2.fromOffset(UITheme.Padding.Medium, UITheme.Padding.Medium),
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Parent = row,
		})
		grid.Name = "Grid"
		local canChoose = levelOk and here
		for index, id in Positions.Order do
			local def = Positions.Get(id) :: Positions.PositionDef
			local card: Frame = Create.new("Frame", {
				Name = id,
				LayoutOrder = index,
				BackgroundColor3 = C.Midnight,
				BackgroundTransparency = 0.12,
				Parent = row,
			})
			Create.Corner(card, UDim.new(0, 12))
			Create.Stroke(card, def.Color, 1.5, 0.25)
			Icons.Fx("Glow", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 52), Size = UDim2.fromOffset(170, 120), Color = def.Color, Transparency = 0.72, Parent = card })
			Icons.new(Icons.ForPosition(id), { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 18), Size = UDim2.fromOffset(56, 56), Color = def.Color:Lerp(Color3.new(1, 1, 1), 0.25), Parent = card })
			local body: Frame = Create.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 84), Size = UDim2.new(1, -24, 1, -96), Parent = card })
			Create.List(body, Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Center)
			Create.Label({ Text = string.upper(ProgressionText.PositionName(id)), Font = UITheme.Fonts.Title, TextSize = 20, Color = def.Color:Lerp(Color3.new(1, 1, 1), 0.2), XAlignment = Enum.TextXAlignment.Center, LayoutOrder = 1, Parent = body })
			Create.Label({ Text = S.Roles[id] or "", Font = UITheme.Fonts.BodyBold, TextSize = UITheme.TextSize.Caption, Color = C.TextMuted, XAlignment = Enum.TextXAlignment.Center, LayoutOrder = 2, Parent = body })
			Create.Label({
				Text = S.Blurbs[id] or "",
				TextSize = UITheme.TextSize.Caption,
				Color = C.Text,
				Wrapped = true,
				XAlignment = Enum.TextXAlignment.Center,
				YAlignment = Enum.TextYAlignment.Top,
				Size = UDim2.new(1, 0, 0, 92),
				LayoutOrder = 3,
				Parent = body,
			})
			-- The three abilities, as icons with names on hover.
			local abilities: Frame = Create.new("Frame", { Name = "Abilities", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = 4, Parent = body })
			Create.List(abilities, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
			for _, branchDef in def.Branches do
				local ability = branchAbility(branchDef)
				if ability then
					local chip: Frame = Create.new("Frame", { Name = ability, BackgroundColor3 = C.PanelSunken, Size = UDim2.fromOffset(34, 34), Active = true, Parent = abilities })
					Create.Corner(chip, UITheme.CornerPill)
					Create.Stroke(chip, def.Color, 1, 0.4)
					Icons.new(Icons.ForAbility(ability), { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(20, 20), Color = C.Foam, Parent = chip })
					maid:Add(Components.Tooltip.Attach(chip, function(): Components.TooltipContent?
						return { Title = ProgressionText.AbilityName(ability), Icon = Icons.ForAbility(ability), TitleColor = def.Color, Lines = { { Text = ProgressionText.AbilityDescription(ability) } } }
					end))
				end
			end
			local choose = Components.Button.new({
				Name = `Choose_{id}`,
				Text = Strings.Format(S.ChooseHere, { name = ProgressionText.PositionName(id) }),
				Variant = "Primary",
				Enabled = canChoose,
				TextSize = UITheme.TextSize.Small,
				Size = UDim2.new(1, 0, 0, 34),
				LayoutOrder = 5,
				Parent = body,
				OnActivated = function()
					local station = stationId()
					if not station then
						return
					end
					UIController.Confirm({
						Title = Strings.Format(S.ChooseConfirmTitle, { name = ProgressionText.PositionName(id) }),
						Message = S.ChooseConfirmBody,
						ConfirmText = Strings.Format(S.ChooseHere, { name = ProgressionText.PositionName(id) }),
					}):andThen(function(yes: boolean): any
						if yes then
							Net.FireServer("RequestChoosePosition", id, station)
						end
						return nil
					end)
				end,
			})
			choose.Instance.Selectable = canChoose
		end
	end

	-- HEADER -------------------------------------------------------------------------------

	local function renderHeader(current: PlayerData)
		local staged = StatDraft.Total()
		skillChip.Text = `{current.SkillPoints} <font color="#9DB2CA">{S.SkillPointsLabel}</font>`
		skillChip.TextColor3 = if current.SkillPoints > 0 then C.Aqua else C.Text
		statChip.Text = `{current.StatPoints - staged} <font color="#9DB2CA">{S.StatPointsLabel}</font>`
		levelChip.Text = `<font color="#9DB2CA">{S.LevelLabel}</font> {current.Level}`
		goldChip.Text = `{current.Currencies.Gold} <font color="#9DB2CA">{Strings.Inventory.Gold}</font>`
		subtitle.Text = if hallStation then string.upper(S.HallTitle) else ""
		titleWave.Visible = hallStation == nil
		local def = Positions.Get(current.Position)
		positionChip.Visible = def ~= nil
		if def then
			positionStroke.Color = def.Color
			Icons.Apply(positionIcon, Icons.ForPosition(def.Id))
			positionIcon.ImageColor3 = def.Color:Lerp(Color3.new(1, 1, 1), 0.2)
			positionName.Text = string.upper(ProgressionText.PositionName(def.Id))
			positionName.TextColor3 = def.Color:Lerp(Color3.new(1, 1, 1), 0.3)
			positionRole.Text = S.Roles[def.Id] or ""
		end
	end

	local function renderBuild(current: PlayerData)
		allocator:Refresh()
		local summary = GearStats.Summarize(current)
		local totals: { [string]: number } = {}
		local staged: { [string]: number } = {}
		for _, stat in GearStats.StatNames do
			totals[stat] = summary.Stats[stat] or 0
			staged[stat] = StatDraft.Get(stat)
		end
		radar:Set(GearStats.StatNames, totals, staged)
	end

	-- REFRESH ------------------------------------------------------------------------------

	function refresh()
		if not isOpen then
			return
		end
		local current = data()
		if not current then
			return
		end
		local hasPosition = Positions.Get(current.Position) ~= nil
		applyLayout()
		chooser.Visible = not hasPosition
		world.Visible = hasPosition
		hint.Visible = hasPosition
		controls.Visible = hasPosition
		if hasPosition then
			if builtFor ~= current.Position then
				buildTree(current.Position)
				resetView()
			end
			refreshStates(current)
		else
			builtFor = ""
			renderChooser(current)
		end
		renderHeader(current)
		renderBuild(current)
		renderPanel()
	end

	maid:Add(StatDraft.Changed:Connect(function()
		local current = data()
		if isOpen and current then
			renderHeader(current)
			renderBuild(current)
		end
	end))
	maid:Add(DataController.Changed:Connect(function(path: { string })
		local key = path[1]
		if
			key == "Position"
			or key == "SkillTree"
			or key == "SkillPoints"
			or key == "StatPoints"
			or key == "Hotbar"
			or key == "Level"
			or key == "Currencies"
			or key == "RespecCount"
			or key == "Stats"
			or key == "Equipped"
		then
			refresh()
		end
	end))
	maid:Add(ProgressionController.Result:Connect(function(ok: boolean, action: string, _reason: string, payload: { [string]: any })
		if ok and action == "Unlock" and type(payload.Node) == "string" and isOpen then
			-- Let the data change land first so the stream is lit when the spark arrives.
			task.defer(pulseInto, payload.Node)
		end
		if ok and (action == "Stats" or action == "Respec") then
			StatDraft.Clear()
		end
	end))

	return {
		OnOpen = function()
			isOpen = true
			Animator.SetPaused(MENU_ID, false)
			leftOpen = not compactLeft()
			builtFor = ""
			viewTouched = false
			applyTopbar()
			refresh()
			if Device.IsGamepad() then
				task.defer(function()
					local current = data()
					local target: GuiObject? = nil
					if current and Positions.Get(current.Position) then
						-- Start on a node you can learn, else the first entry node.
						for _, node in Positions.NodesOf(current.Position) do
							if stateOf(current, node.Id) == "Available" and nodeViews[node.Id] then
								target = nodeViews[node.Id].Button
								break
							end
						end
						local first = Positions.NodesOf(current.Position)[1]
						target = target or (if first and nodeViews[first.Id] then nodeViews[first.Id].Button else nil)
					end
					if target then
						GuiService.SelectedObject = target
					end
				end)
			end
		end,
		OnClose = function()
			isOpen = false
			-- Water, swirls and pulsing nodes stop while the menu is hidden.
			Animator.SetPaused(MENU_ID, true)
			hallStation = nil
			stick = Vector2.zero
			dragInput = nil
			task.defer(function()
				if not UIController.IsMenuOpen() then
					StatDraft.Clear()
				end
			end)
		end,
	}
end

-- Opens the menu as the Hall of Positions (choosing is allowed here).
function SkillTreeController.OpenHall(station: Instance)
	UIController.Close()
	task.defer(function()
		hallStation = station
		UIController.Open(MENU_ID)
	end)
end

function SkillTreeController.Init()
	UIController.RegisterMenu({
		Id = MENU_ID,
		Title = S.Title,
		Action = "OpenSkillTree",
		FullScreen = true,
		ShowInHub = true,
		Icon = "SkillTree",
		Nav = "Journal",
		Layout = "Immersive",
		Build = build,
	})
	StationController.SetKindHandler(P.Positions.StationKind, SkillTreeController.OpenHall)
end

return SkillTreeController
