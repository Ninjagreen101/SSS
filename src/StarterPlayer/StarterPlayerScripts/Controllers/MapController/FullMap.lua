--!strict
--[[
	FullMap
	The Map (M): a full-screen page of the floor.

	  MAP   ◀ Floor 1: Lowharbor ▶                                   [−] [+] [◎]  [×]
	  ┌───────────────────────────────────────────────────────────────────────────────┐
	  │   fog of war over unexplored ground, region names once explored               │
	  │   ◆ Waystones (glowing once discovered)   ◆ quest markers   ! NPC quests      │
	  │   ● your pins                              ▲ you                ┌ card ─────┐ │
	  │                                                                 │ Tidewatch │ │
	  │ ┌ legend ┐                                                      │ [Travel]  │ │
	  └───────────────────────────────────────────────────────────────────────────────┘
	                     Drag to pan · Wheel to zoom · Right-click to place a pin

	- Mouse: drag to pan, wheel zooms at the cursor, click a marker for its card, click a pin to
	  remove it, right-click to place a pin. Touch: drag, pinch, tap, hold to pin. Gamepad: left
	  stick pans under a centre reticle, right stick zooms, A selects (A again runs the card's
	  action), X places / removes a pin, Y recentres, LB / RB change floor.
	- Pins go through RequestMapPin (current floor only; the server keeps at most MaxPins).
	- Waystone travel: while standing at a discovered Waystone, another discovered Waystone's card
	  offers Travel, which hands off to the travel handler (MapController.SetTravelHandler).
	The view is one square canvas inside a clipping viewport; markers are placed by Scale on it,
	so panning and zooming only move and resize the canvas.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Maid = require(Shared.Util.Maid)
local Quests = require(Shared.Data.Quests)

local UI = script.Parent.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Device = require(UI.Device)
local Icons = require(UI.Icons)
local Motion = require(UI.Motion)
local Animator = require(UI.Animator)
local UISound = require(UI.UISound)
local QuestText = require(UI.QuestText)
local Components = require(UI.Components)

local DataController = require(script.Parent.Parent.DataController)
local UIController = require(script.Parent.Parent.UIController)
local InputController = require(script.Parent.Parent.InputController)
local QuestController = require(script.Parent.Parent.QuestController)

local Surface = require(script.Parent.Surface)
local Points = require(script.Parent.Points)
local Icon = require(script.Parent.Icon)
local Extra = require(script.Parent.Extra)

local M = UITheme.Map
local C = UITheme.Colors
local Q = Strings.QuestUI
local player = Players.LocalPlayer

local MENU_ID = "Map"
local HEADER_HEIGHT = 78
local SIDE_MARGIN = 28
local CARD_WIDTH = 300
local FIT = 0.92 -- the floor fills this much of the shorter side at zoom 1
local DRAG_THRESHOLD = 6
local STICK_DEADZONE = 0.2

export type TravelHandler = (fromWaystone: string, toWaystone: string) -> ()

local FullMap = {}
FullMap.MenuId = MENU_ID

local travelHandler: TravelHandler? = nil

function FullMap.SetTravelHandler(handler: TravelHandler?)
	travelHandler = handler
end

-- Floors the selector offers: unlocked ones plus the one you stand on, in order.
local function floorList(): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local current = Surface.CurrentFloor()
	table.insert(out, current)
	seen[current] = true
	local unlocked = DataController.Get({ "Floors", "Unlocked" })
	if type(unlocked) == "table" then
		for floor, value in unlocked do
			if type(floor) == "string" and value == true and not seen[floor] then
				seen[floor] = true
				table.insert(out, floor)
			end
		end
	end
	table.sort(out, function(a: string, b: string): boolean
		return (tonumber(a) or 0) < (tonumber(b) or 0)
	end)
	return out
end

local function playerRoot(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- The discovered Waystone the player stands at (current floor), if any.
local function standingAt(points: { Points.Point }): string?
	local root = playerRoot()
	if not root then
		return nil
	end
	local here = Vector2.new(root.Position.X, root.Position.Z)
	local best: string? = nil
	local bestDistance = Config.World.Waystones.DiscoverRadius
	for _, entry in points do
		if entry.Kind == "Waystone" and entry.Discovered then
			local distance = (entry.World - here).Magnitude
			if distance <= bestDistance then
				best, bestDistance = entry.Id, distance
			end
		end
	end
	return best
end

local function controlsText(): string
	local device = Device.Current()
	if device == "Touch" then
		return Q.MapControlsTouch
	elseif device == "Gamepad" then
		return Q.MapControlsGamepad
	end
	return Q.MapControlsMouse
end

function FullMap.Build(content: Frame, maid: Maid.Maid): any
	local isOpen = false
	local floor = Surface.CurrentFloor()
	local info: Surface.MapInfo? = Surface.Info(floor)
	local zoom = 1
	local center = Vector2.new(0.5, 0.5)
	local points: { Points.Point } = {}
	local selected: Points.Point? = nil
	local panStick = Vector2.zero
	local zoomStick = 0

	-- BACKDROP AND VIEWPORT -------------------------------------------------------------------
	Create.new("Frame", {
		Name = "Backdrop",
		BackgroundColor3 = C.Abyss,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = content,
	})
	local viewport: Frame = Create.new("Frame", {
		Name = "Viewport",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Active = true,
		Size = UDim2.fromScale(1, 1),
		Parent = content,
	})
	local canvas: Frame = Create.new("Frame", {
		Name = "Canvas",
		BackgroundTransparency = 1,
		Parent = viewport,
	})
	local surface = Surface.new(canvas, true)
	local iconLayer: Frame = Create.new("Frame", { Name = "Markers", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 10, Parent = canvas })
	local selectionRing = Icons.Fx("Ring", {
		Name = "Selection",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(M.IconSize * 2, M.IconSize * 2),
		Color = C.Foam,
		Transparency = 0.1,
		ZIndex = 11,
		Parent = iconLayer,
	})
	selectionRing.Visible = false
	local arrow = Icon.Arrow(iconLayer, M.IconSize, 20)
	local extraDots: { Frame } = {}
	local reticle: Frame = Create.new("Frame", {
		Name = "Reticle",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(M.PickRadius * 2, M.PickRadius * 2),
		BackgroundTransparency = 1,
		ZIndex = 30,
		Visible = false,
		Parent = viewport,
	})
	Create.Corner(reticle, UDim.new(0.5, 0))
	Create.Stroke(reticle, C.Foam, 1.5, 0.2)
	Create.new("Frame", {
		Name = "Dot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(4, 4),
		BackgroundColor3 = C.Foam,
		BorderSizePixel = 0,
		ZIndex = 30,
		Parent = reticle,
	})
	local noData = Create.Label({
		Name = "NoData",
		Text = Q.MapNoData,
		Font = UITheme.Fonts.Display,
		TextSize = UITheme.TextSize.Heading,
		Color = C.TextMuted,
		XAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(600, 40),
		Parent = content,
	})
	noData.Visible = false

	-- HEADER -----------------------------------------------------------------------------------
	local header: Frame = Create.new("Frame", { Name = "Header", BackgroundTransparency = 1, Active = true, Size = UDim2.new(1, 0, 0, HEADER_HEIGHT), ZIndex = 40, Parent = content })
	local headerShade: Frame = Create.new("Frame", { Name = "Shade", BorderSizePixel = 0, BackgroundColor3 = C.Abyss, Size = UDim2.new(1, 0, 1, 24), Parent = header })
	Create.new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(0.1, 1), Parent = headerShade })
	local titleRow: Frame = Create.new("Frame", {
		Name = "TitleRow",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(SIDE_MARGIN, 16),
		Size = UDim2.new(0.7, 0, 0, 46),
		Parent = header,
	})
	Create.List(titleRow, Enum.FillDirection.Horizontal, 14, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	Create.Label({
		Name = "Title",
		Text = string.upper(Q.MapTitle),
		Font = UITheme.Fonts.Title,
		TextSize = 36,
		Color = C.Foam,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 40),
		LayoutOrder = 1,
		Parent = titleRow,
	})
	local prevFloor = Components.IconButton.new({ Name = "PrevFloor", Icon = "ChevronLeft", Size = 44, Tooltip = Q.MapPrevFloor, LayoutOrder = 2, Parent = titleRow })
	maid:Add(prevFloor)
	local floorLabel = Create.Label({
		Name = "Floor",
		Text = "",
		Font = UITheme.Fonts.Display,
		TextSize = UITheme.TextSize.Heading,
		Color = UITheme.Banner.Gold,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 30),
		LayoutOrder = 3,
		Parent = titleRow,
	})
	local nextFloor = Components.IconButton.new({ Name = "NextFloor", Icon = "ChevronRight", Size = 44, Tooltip = Q.MapNextFloor, LayoutOrder = 4, Parent = titleRow })
	maid:Add(nextFloor)

	local tools: Frame = Create.new("Frame", {
		Name = "Tools",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -SIDE_MARGIN, 0, 16),
		Size = UDim2.fromOffset(0, 46),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = header,
	})
	Create.List(tools, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	local zoomOut = Components.IconButton.new({ Name = "ZoomOut", Icon = "Minus", Size = 44, Tooltip = Q.MapZoomOut, LayoutOrder = 1, Parent = tools })
	maid:Add(zoomOut)
	local zoomIn = Components.IconButton.new({ Name = "ZoomIn", Icon = "Plus", Size = 44, Tooltip = Q.MapZoomIn, LayoutOrder = 2, Parent = tools })
	maid:Add(zoomIn)
	local recenter = Components.IconButton.new({ Name = "Recenter", Icon = "Recenter", Size = 44, Tooltip = Q.MapRecenter, LayoutOrder = 3, Parent = tools })
	maid:Add(recenter)
	local closeHolder: Frame = Create.new("Frame", { Name = "CloseHolder", BackgroundTransparency = 1, Size = UDim2.fromOffset(46, 46), LayoutOrder = 4, Parent = tools })
	UIController.CreateCloseButton(closeHolder, maid)
	-- Gamepad drives the map with sticks and face buttons; header buttons stay mouse / touch only.
	for _, button in { prevFloor, nextFloor, zoomOut, zoomIn, recenter } do
		button.Instance.Selectable = false
	end
	for _, descendant in closeHolder:GetDescendants() do
		if descendant:IsA("GuiButton") then
			descendant.Selectable = false
		end
	end

	-- LEGEND -----------------------------------------------------------------------------------
	local legend: Frame = Create.new("Frame", {
		Name = "Legend",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, SIDE_MARGIN, 1, -SIDE_MARGIN - 26),
		Size = UDim2.fromOffset(196, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.18,
		Active = true,
		ZIndex = 40,
		Parent = content,
	})
	Create.Corner(legend, UDim.new(0, 10))
	Create.Stroke(legend, C.Edge, 1, 0.35)
	Create.Padding(legend, 12)
	Create.List(legend, Enum.FillDirection.Vertical, 6)
	Create.Label({
		Text = string.upper(Q.MapLegend),
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Caption,
		Color = C.Accent,
		Size = UDim2.new(1, 0, 0, 18),
		LayoutOrder = 0,
		Parent = legend,
	})
	local function legendRow(order: number, text: string): Frame
		local row: Frame = Create.new("Frame", { Name = `Row{order}`, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = order, Parent = legend })
		Create.Label({ Text = text, TextSize = UITheme.TextSize.Small, Color = C.Text, Position = UDim2.fromOffset(32, 0), Size = UDim2.new(1, -32, 1, 0), Parent = row })
		return row
	end
	local function legendIcon(order: number, text: string, sample: Points.Point)
		local row = legendRow(order, text)
		local view = Icon.new(row, 18, false, 41)
		view.Frame.Position = UDim2.fromOffset(11, 11)
		Icon.Apply(view, sample, nil)
	end
	local function sample(kind: Points.Kind, discovered: boolean): Points.Point
		return { Kind = kind, Id = "", World = Vector2.zero, Discovered = discovered, Tracked = false, TurnIn = false, Marker = nil }
	end
	local youRow = legendRow(1, Q.MapYou)
	local youArrow = Icon.Arrow(youRow, 14, 41)
	youArrow.Position = UDim2.fromOffset(11, 11)
	legendIcon(2, Q.MapWaystone, sample("Waystone", true))
	legendIcon(3, Q.MapNotDiscovered, sample("Waystone", false))
	legendIcon(4, Q.MapQuest, sample("Quest", false))
	legendIcon(5, Q.MapAvailable, sample("Npc", false))
	legendIcon(6, Q.MapPin, sample("Pin", false))
	local fogRow = legendRow(7, Q.MapUnexplored)
	local fogSwatch: Frame = Create.new("Frame", {
		Position = UDim2.fromOffset(3, 4),
		Size = UDim2.fromOffset(16, 14),
		BackgroundColor3 = M.Fog,
		Parent = fogRow,
	})
	Create.Corner(fogSwatch, UDim.new(0, 3))
	Create.Stroke(fogSwatch, C.Edge, 1, 0.3)

	local controls = Create.Label({
		Name = "Controls",
		Text = controlsText(),
		TextSize = UITheme.TextSize.Small,
		Color = C.TextMuted,
		XAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.new(1, -2 * SIDE_MARGIN, 0, 20),
		Parent = content,
	})
	controls.ZIndex = 40
	controls.TextStrokeTransparency = 0.5

	-- CARD -------------------------------------------------------------------------------------
	local card: Frame = Create.new("Frame", {
		Name = "Card",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -SIDE_MARGIN, 0, HEADER_HEIGHT + 12),
		Size = UDim2.fromOffset(CARD_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.08,
		Active = true,
		Visible = false,
		ZIndex = 40,
		Parent = content,
	})
	Create.Corner(card, UDim.new(0, 10))
	local cardStroke = Create.Stroke(card, C.Edge, 1.2, 0.2)
	Create.PanelGradient(card)
	Create.Padding(card, 16)
	Create.List(card, Enum.FillDirection.Vertical, 6)
	local cardTitle = Create.Label({
		Name = "Title",
		Text = "",
		Font = UITheme.Fonts.Display,
		TextSize = UITheme.TextSize.Heading,
		Color = C.Foam,
		Wrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 26),
		LayoutOrder = 1,
		Parent = card,
	})
	local cardSubtitle = Create.Label({
		Name = "Subtitle",
		Text = "",
		Font = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.Small,
		Color = C.Accent,
		Size = UDim2.new(1, 0, 0, 18),
		LayoutOrder = 2,
		Parent = card,
	})
	local cardBody = Create.Label({
		Name = "Body",
		Text = "",
		TextSize = UITheme.TextSize.Small,
		Color = C.TextMuted,
		Wrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 18),
		LayoutOrder = 3,
		Parent = card,
	})
	local cardAction: (() -> ())? = nil
	local actionButton = Components.Button.new({
		Name = "Action",
		Text = "",
		Variant = "Primary",
		Size = UDim2.new(1, 0, 0, if Device.IsTouch() then UITheme.Size.ButtonHeightTouch else UITheme.Size.ButtonHeight),
		LayoutOrder = 4,
		Parent = card,
		OnActivated = function()
			local action = cardAction
			if action then
				action()
			end
		end,
	})
	maid:Add(actionButton)
	actionButton.Instance.Selectable = false

	-- VIEW -------------------------------------------------------------------------------------
	local function viewSide(): number
		local size = viewport.AbsoluteSize
		return math.min(size.X, size.Y) * FIT * zoom
	end

	local function canvasOrigin(): Vector2
		local size = viewport.AbsoluteSize
		local side = viewSide()
		return Vector2.new(size.X / 2 - center.X * side, size.Y / 2 - center.Y * side)
	end

	local function applyView()
		local size = viewport.AbsoluteSize
		if size.X < 1 or size.Y < 1 then
			return
		end
		center = Vector2.new(math.clamp(center.X, 0, 1), math.clamp(center.Y, 0, 1))
		local side = viewSide()
		local origin = canvasOrigin()
		canvas.Size = UDim2.fromScale(side / size.X, side / size.Y)
		canvas.Position = UDim2.fromScale(origin.X / size.X, origin.Y / size.Y)
	end

	local function screenToUnit(screen: Vector2): Vector2
		return (screen - viewport.AbsolutePosition - canvasOrigin()) / math.max(viewSide(), 1)
	end

	local function unitToScreen(unit: Vector2): Vector2
		return viewport.AbsolutePosition + canvasOrigin() + unit * viewSide()
	end

	local function zoomAt(screen: Vector2, target: number)
		local before = screenToUnit(screen)
		zoom = math.clamp(target, M.MinZoom, M.MaxZoom)
		local fromCentre = screen - viewport.AbsolutePosition - viewport.AbsoluteSize / 2
		center = before - fromCentre / math.max(viewSide(), 1)
		applyView()
	end

	local function viewportCentre(): Vector2
		return viewport.AbsolutePosition + viewport.AbsoluteSize / 2
	end

	local function playerUnit(): Vector2?
		local root = playerRoot()
		local mapInfo = info
		if not root or not mapInfo or floor ~= Surface.CurrentFloor() then
			return nil
		end
		return Surface.ToUnit(mapInfo, root.Position.X, root.Position.Z)
	end

	local function centreOnPlayer()
		local unit = playerUnit()
		center = unit or Vector2.new(0.5, 0.5)
		applyView()
	end

	-- MARKERS ----------------------------------------------------------------------------------
	local views: { Icon.View } = {}

	local function unitOf(entry: Points.Point): Vector2?
		local mapInfo = info
		if not mapInfo then
			return nil
		end
		return Surface.ToUnit(mapInfo, entry.World.X, entry.World.Y)
	end

	local function caption(entry: Points.Point): string?
		if entry.Kind == "Waystone" then
			return QuestText.WaystoneName(entry.Id)
		elseif entry.Kind == "Quest" then
			return if entry.Tracked then QuestText.QuestName(entry.Id) else nil
		elseif entry.Kind == "Npc" then
			return QuestText.NpcName(entry.Id)
		end
		return nil
	end

	local renderCard: () -> ()

	local function placeSelection()
		local entry = selected
		local unit = entry and unitOf(entry)
		selectionRing.Visible = unit ~= nil
		if unit then
			selectionRing.Position = UDim2.fromScale(unit.X, unit.Y)
		end
	end

	local function refreshMarkers()
		points = if info then Points.Collect(floor) else {}
		local used = 0
		local stillSelected = false
		for _, entry in points do
			local unit = unitOf(entry)
			if unit then
				used += 1
				local view = views[used]
				if not view then
					view = Icon.new(iconLayer, M.IconSize, true, 12)
					views[used] = view
				end
				Icon.Apply(view, entry, caption(entry))
				view.Frame.Position = UDim2.fromScale(unit.X, unit.Y)
				view.Frame.ZIndex = if entry.Kind == "Quest" then 14 else 12
				local current = selected
				if current and current.Kind == entry.Kind and current.Id == entry.Id then
					selected = entry
					stillSelected = true
				end
			end
		end
		for index = used + 1, #views do
			Icon.Hide(views[index])
		end
		if selected and not stillSelected then
			selected = nil
		end
		placeSelection()
		renderCard()
	end

	local function setFloor(target: string)
		floor = target
		info = Surface.Info(target)
		surface:SetFloor(target)
		floorLabel.Text = QuestText.FloorName(target)
		local list = floorList()
		local index = table.find(list, target) or 1
		prevFloor.Instance.Visible = index > 1
		nextFloor.Instance.Visible = index < #list
		noData.Visible = not surface.HasMap
		selected = nil
		arrow.Visible = floor == Surface.CurrentFloor()
		refreshMarkers()
		centreOnPlayer()
	end

	local function stepFloor(delta: number)
		local list = floorList()
		local index = table.find(list, floor) or 1
		local target = list[math.clamp(index + delta, 1, #list)]
		if target and target ~= floor then
			UISound.Play("UIClick")
			setFloor(target)
		end
	end

	-- CARD -------------------------------------------------------------------------------------
	function renderCard()
		local entry = selected
		cardAction = nil
		if not entry then
			card.Visible = false
			return
		end
		card.Visible = true
		cardStroke.Color = C.Edge
		local subtitle, body, actionText = "", "", ""
		local action: (() -> ())? = nil
		if entry.Kind == "Waystone" then
			cardTitle.Text = QuestText.WaystoneName(entry.Id)
			subtitle = if entry.Discovered then Q.MapDiscovered else Q.MapNotDiscovered
			cardSubtitle.TextColor3 = if entry.Discovered then M.Waystone else C.TextMuted
			cardStroke.Color = if entry.Discovered then M.Waystone else C.Edge
			local standing = standingAt(points)
			local handler = travelHandler
			if standing == entry.Id then
				body = Q.MapHere
			elseif handler and entry.Discovered then
				if standing then
					actionText = Q.MapTravel
					local from = standing
					action = function()
						UIController.Confirm({
							Title = Q.MapTravel,
							Message = Strings.Format(Q.MapTravelTo, { name = QuestText.WaystoneName(entry.Id) }),
							ConfirmText = Q.MapTravel,
						}):andThen(function(confirmed: boolean): any
							if confirmed and travelHandler == handler then
								handler(from, entry.Id)
								UIController.Close()
							end
							return nil
						end)
					end
				else
					body = Q.MapTravelHint
				end
			end
		elseif entry.Kind == "Quest" then
			local def = Quests.Get(entry.Id)
			cardTitle.Text = QuestText.QuestName(entry.Id)
			cardSubtitle.TextColor3 = if def then QuestText.KindColor(def.Kind) else M.Quest
			cardStroke.Color = M.Quest
			if entry.TurnIn and def and def.TurnIn then
				subtitle = Strings.Format(Q.ReturnTo, { name = QuestText.NpcName(def.TurnIn) })
			else
				subtitle = if entry.Tracked then Q.Tracked else Q.MapQuest
				local index = QuestController.State.CurrentObjective(entry.Id)
				body = if index then QuestText.Objective(entry.Id, index) else ""
			end
			actionText = Q.MapOpenQuest
			local questId = entry.Id
			action = function()
				QuestController.OpenLog(questId)
			end
		elseif entry.Kind == "Npc" then
			cardTitle.Text = QuestText.NpcName(entry.Id)
			subtitle = QuestText.NpcRole(entry.Id)
			cardSubtitle.TextColor3 = C.Accent
			body = Q.MapAvailable
			cardStroke.Color = M.Quest
		else
			cardTitle.Text = Q.MapPin
			cardSubtitle.TextColor3 = M.Pin
			if floor == Surface.CurrentFloor() then
				actionText = Q.MapPinRemove
				local pin = entry
				action = function()
					Net.FireServer("RequestMapPin", "Remove", pin.World.X, pin.World.Y, "")
					UISound.Play("UIClose")
					selected = nil
					renderCard()
					placeSelection()
				end
			end
		end
		cardSubtitle.Text = subtitle
		cardSubtitle.Visible = subtitle ~= ""
		cardBody.Text = body
		cardBody.Visible = body ~= ""
		cardAction = action
		actionButton.Instance.Visible = action ~= nil
		if action then
			actionButton:SetText(actionText)
		end
	end

	local function selectPoint(entry: Points.Point?)
		selected = entry
		if entry then
			UISound.Play("UIClick")
		end
		placeSelection()
		renderCard()
	end

	-- The marker nearest a screen point, within the pick radius.
	local function pickAt(screen: Vector2): Points.Point?
		local radius = M.PickRadius * Layers.GetScale("Menu")
		local best: Points.Point? = nil
		local bestDistance = radius
		for _, entry in points do
			local unit = unitOf(entry)
			if unit then
				local distance = (unitToScreen(unit) - screen).Magnitude
				if distance <= bestDistance then
					best, bestDistance = entry, distance
				end
			end
		end
		return best
	end

	-- PINS -------------------------------------------------------------------------------------
	local function removePin(entry: Points.Point)
		if floor ~= Surface.CurrentFloor() then
			return
		end
		Net.FireServer("RequestMapPin", "Remove", entry.World.X, entry.World.Y, "")
		UISound.Play("UIClose")
		if selected == entry then
			selectPoint(nil)
		end
	end

	local function addPinAt(screen: Vector2)
		local mapInfo = info
		if not mapInfo or floor ~= Surface.CurrentFloor() then
			UISound.Play("UIError")
			return
		end
		local unit = screenToUnit(screen)
		if unit.X < 0 or unit.Y < 0 or unit.X > 1 or unit.Y > 1 then
			return
		end
		local existing = pickAt(screen)
		if existing and existing.Kind == "Pin" then
			removePin(existing)
			return
		end
		if #Points.Pins(floor) >= Config.Quests.Map.MaxPins then
			UISound.Play("UIError")
			Components.Toast.Push({ Title = Strings.Format(Q.MapPinsFull, { count = Config.Quests.Map.MaxPins }), Color = M.Pin, Duration = 3 })
			return
		end
		local x, z = Surface.ToWorld(mapInfo, unit)
		Net.FireServer("RequestMapPin", "Add", x, z, "Pin")
		UISound.Play("UIConfirm")
	end

	local function clickAt(screen: Vector2)
		local entry = pickAt(screen)
		if entry and entry.Kind == "Pin" then
			removePin(entry)
			return
		end
		selectPoint(entry)
	end

	-- INPUT ------------------------------------------------------------------------------------
	local dragInput: InputObject? = nil
	local dragStart = Vector2.zero
	local centreStart = Vector2.zero
	local moved = false
	local pinching = false
	local pinchStartZoom = 1
	local longPressed = false

	local function position(input: InputObject): Vector2
		return Vector2.new(input.Position.X, input.Position.Y)
	end

	maid:Add(viewport.InputBegan:Connect(function(input: InputObject)
		local kind = input.UserInputType
		if (kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch) and not dragInput then
			dragInput = input
			dragStart = position(input)
			centreStart = center
			moved = false
			longPressed = false
		elseif kind == Enum.UserInputType.MouseButton2 then
			addPinAt(position(input))
		end
	end))
	maid:Add(UserInputService.InputChanged:Connect(function(input: InputObject)
		if not isOpen then
			return
		end
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			local value = Vector2.new(input.Position.X, -input.Position.Y)
			panStick = if value.Magnitude > STICK_DEADZONE then value else Vector2.zero
			return
		elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
			zoomStick = if math.abs(input.Position.Y) > STICK_DEADZONE then input.Position.Y else 0
			return
		end
		local active = dragInput
		if not active or pinching then
			return
		end
		local matches = (active.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement)
			or input == active
		if matches then
			local delta = position(input) - dragStart
			if moved or delta.Magnitude > DRAG_THRESHOLD then
				moved = true
				center = centreStart - delta / math.max(viewSide(), 1)
				applyView()
			end
		end
	end))
	maid:Add(UserInputService.InputEnded:Connect(function(input: InputObject)
		local active = dragInput
		if not active then
			return
		end
		local ended = input == active
			or (active.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseButton1)
		if ended then
			dragInput = nil
			if isOpen and not moved and not pinching and not longPressed then
				clickAt(dragStart)
			end
		end
	end))
	maid:Add(viewport.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			zoomAt(position(input), zoom * (if input.Position.Z > 0 then M.ZoomStep else 1 / M.ZoomStep))
		end
	end))
	maid:Add(viewport.TouchPinch:Connect(function(touches: { Vector2 }, scale: number, _velocity: number, state: Enum.UserInputState)
		if state == Enum.UserInputState.Begin then
			pinching = true
			moved = true
			pinchStartZoom = zoom
		elseif state == Enum.UserInputState.Change then
			local focus = if #touches >= 2 then (touches[1] + touches[2]) / 2 else viewportCentre()
			zoomAt(focus, pinchStartZoom * scale)
		else
			pinching = false
		end
	end))
	maid:Add(viewport.TouchLongPress:Connect(function(touches: { Vector2 }, state: Enum.UserInputState)
		if state == Enum.UserInputState.Begin and not moved and not pinching and touches[1] then
			longPressed = true
			addPinAt(touches[1])
		end
	end))

	-- Gamepad: A selects under the reticle (again: the card's action), X pins, Y recentres.
	maid:Add(UserInputService.InputBegan:Connect(function(input: InputObject)
		if not isOpen or Components.Modal.IsAnyOpen() then
			return
		end
		local key = input.KeyCode
		if key == Enum.KeyCode.ButtonA then
			local entry = pickAt(viewportCentre())
			local action = cardAction
			if entry and selected == entry and action then
				action()
			else
				selectPoint(entry)
			end
		elseif key == Enum.KeyCode.ButtonX then
			addPinAt(viewportCentre())
		elseif key == Enum.KeyCode.ButtonY then
			UISound.Play("UIClick")
			centreOnPlayer()
		end
	end))
	maid:Add(InputController.ActionBegan:Connect(function(action: string)
		if not isOpen or Components.Modal.IsAnyOpen() then
			return
		end
		if action == "TabLeft" then
			stepFloor(-1)
		elseif action == "TabRight" then
			stepFloor(1)
		end
	end))

	prevFloor.Activated:Connect(function()
		stepFloor(-1)
	end)
	nextFloor.Activated:Connect(function()
		stepFloor(1)
	end)
	zoomIn.Activated:Connect(function()
		zoomAt(viewportCentre(), zoom * M.ZoomStep * M.ZoomStep)
	end)
	zoomOut.Activated:Connect(function()
		zoomAt(viewportCentre(), zoom / (M.ZoomStep * M.ZoomStep))
	end)
	recenter.Activated:Connect(centreOnPlayer)
	maid:Add(viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyView))

	local function applyDevice()
		controls.Text = controlsText()
		reticle.Visible = Device.IsGamepad()
	end
	maid:Add(Device.Changed:Connect(applyDevice))
	applyDevice()

	-- LIVE -------------------------------------------------------------------------------------
	maid:Add(Animator.Add(function(time: number, dt: number)
		-- Sticks.
		if panStick.Magnitude > 0 then
			center += Vector2.new(panStick.X, -panStick.Y) * M.GamepadPanSpeed * dt / math.max(viewSide(), 1)
			applyView()
		end
		if zoomStick ~= 0 then
			zoomAt(viewportCentre(), zoom * M.GamepadZoomSpeed ^ (zoomStick * dt))
		end
		-- You.
		local unit = playerUnit()
		local root = playerRoot()
		arrow.Visible = unit ~= nil
		if unit and root then
			arrow.Position = UDim2.fromScale(unit.X, unit.Y)
			local look = root.CFrame.LookVector
			arrow.Rotation = math.deg(math.atan2(look.Z, look.X)) + 90
		end
		-- Extra markers (MapController.SetExtraMarkers: party members, pings), this floor only.
		local extras = 0
		local mapInfo = info
		if mapInfo and floor == Surface.CurrentFloor() then
			for _, marker in Extra.Collect() do
				extras += 1
				local dot: Frame? = extraDots[extras]
				if not dot then
					local made: Frame = Create.new("Frame", { Name = "Extra", AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, ZIndex = 18, Parent = iconLayer })
					Create.Corner(made, UDim.new(0.5, 0))
					Create.Stroke(made, Color3.new(0, 0, 0), 1.5, 0.2)
					extraDots[extras] = made
					dot = made
				end
				assert(dot, "extra map dot")
				local markerUnit = Surface.ToUnit(mapInfo, marker.World.X, marker.World.Z)
				local side = math.floor((marker.Size or 9) * 1.5)
				dot.Visible = true
				dot.Size = UDim2.fromOffset(side, side)
				dot.BackgroundColor3 = marker.Color
				dot.Position = UDim2.fromScale(markerUnit.X, markerUnit.Y)
			end
		end
		for index = extras + 1, #extraDots do
			extraDots[index].Visible = false
		end
		-- Discovered Waystones breathe.
		if not Motion.IsReduced() then
			local pulse = 0.3 + (math.sin(time * 2.2) + 1) * 0.12
			for _, view in views do
				local entry = view.Point
				if entry and entry.Kind == "Waystone" and entry.Discovered then
					view.Glow.ImageTransparency = pulse
				end
			end
			selectionRing.Rotation = time * 30
		end
	end, MENU_ID))

	local function onData(path: { string })
		local rootKey = path[1]
		if not isOpen then
			return
		end
		if rootKey == "Map" then
			surface:RefreshFog()
			refreshMarkers()
		elseif rootKey == "Waystones" or rootKey == "Quests" then
			refreshMarkers()
		elseif rootKey == "Floors" then
			setFloor(floor)
		end
	end
	maid:Add(DataController.Changed:Connect(onData))
	maid:Add(QuestController.Changed:Connect(function()
		if isOpen then
			refreshMarkers()
		end
	end))

	setFloor(floor)

	return {
		OnOpen = function()
			isOpen = true
			Animator.SetPaused(MENU_ID, false)
			local current = Surface.CurrentFloor()
			if floor ~= current then
				setFloor(current)
			else
				floorLabel.Text = QuestText.FloorName(floor)
				surface:RefreshFog()
				refreshMarkers()
				centreOnPlayer()
			end
			-- The sticks and face buttons drive the map: no gamepad selection inside the page.
			task.defer(function()
				local selection = GuiService.SelectedObject
				if Device.IsGamepad() and selection and selection:IsDescendantOf(content) then
					GuiService.SelectedObject = nil
				end
			end)
		end,
		OnClose = function()
			isOpen = false
			dragInput = nil
			panStick = Vector2.zero
			zoomStick = 0
			Animator.SetPaused(MENU_ID, true)
		end,
	}
end

return FullMap
