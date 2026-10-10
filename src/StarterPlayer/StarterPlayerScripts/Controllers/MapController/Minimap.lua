--!strict
--[[
	Minimap
	The circular minimap at the top right, under the Current Pressure pill (UITheme.Map: MinimapGap
	below it, right-aligned with it, so the two never overlap; the quest tracker sits under both).

	- The floor surface (Surface) rotates with the camera so "up" is where you look; it sits
	  inside a round CanvasGroup that clips it. Config.Quests.Map.MinimapRadius studs reach from
	  the centre to the edge.
	- Markers are drawn on top without rotating: Waystones, "!" NPCs, pins and other players inside
	  the circle; quest markers stick to the rim when they are farther away (the tracked one is
	  larger). The player's arrow sits in the centre and turns with the character.
	- An "N" on the rim shows north. Clicking / tapping the minimap opens the Map.
	Updates run at most 30 times a second.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local UI = script.Parent.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Device = require(UI.Device)
local Animator = require(UI.Animator)

local Surface = require(script.Parent.Surface)
local Points = require(script.Parent.Points)
local Icon = require(script.Parent.Icon)
local Extra = require(script.Parent.Extra)

local M = UITheme.Map
local H = UITheme.HUD
local C = UITheme.Colors
local player = Players.LocalPlayer

local UPDATE_INTERVAL = 1 / 30
local RIM_MARGIN = 9 -- px inside the edge for markers stuck to the rim

local Minimap = {}

local holder: Frame
local clip: CanvasGroup
local rotor: Frame
local surface: Surface.Surface
local overlay: Frame
local arrow: Frame
local north: TextLabel
local icons: { Icon.View } = {}
local playerDots: { Frame } = {}
local extraDots: { Frame } = {}
local points: { Points.Point } = {}
local floorInfo: Surface.MapInfo? = nil
local size = M.MinimapSize
local lastUpdate = 0

local function minimapSize(): number
	return if Device.IsTouch() then M.MinimapSizeTouch else M.MinimapSize
end

local function layout()
	size = minimapSize()
	holder.Position = UDim2.new(1, -H.Margin.X, 0, H.Margin.Y + H.PressureSize.Y + M.MinimapGap)
	holder.Size = UDim2.fromOffset(size, size)
	local pixelsPerStud = (size / 2) / Config.Quests.Map.MinimapRadius
	local info = floorInfo
	if info then
		local side = info.Size * pixelsPerStud
		surface.Root.Size = UDim2.fromOffset(side, side)
	end
end

local function getIcon(index: number): Icon.View
	local view = icons[index]
	if not view then
		view = Icon.new(overlay, M.MinimapIconSize, false, 5)
		icons[index] = view
	end
	return view
end

local function getDot(index: number): Frame
	local existing = playerDots[index]
	if existing then
		return existing
	end
	local dot: Frame = Create.new("Frame", {
		Name = "Player",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(7, 7),
		BackgroundColor3 = C.Foam,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = overlay,
	})
	Create.Corner(dot, UDim.new(0.5, 0))
	Create.Stroke(dot, Color3.new(0, 0, 0), 1, 0.3)
	playerDots[index] = dot
	return dot
end

local function getExtraDot(index: number): Frame
	local existing = extraDots[index]
	if existing then
		return existing
	end
	local dot: Frame = Create.new("Frame", {
		Name = "Extra",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = overlay,
	})
	Create.Corner(dot, UDim.new(0.5, 0))
	Create.Stroke(dot, Color3.new(0, 0, 0), 1, 0.2)
	extraDots[index] = dot
	return dot
end

local function heading(look: Vector3): number
	return math.deg(math.atan2(look.Z, look.X))
end

local function update()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local camera = Workspace.CurrentCamera
	local info = floorInfo
	if not (root and root:IsA("BasePart") and camera and info) then
		return
	end
	local position = root.Position
	local radius = size / 2
	local pixelsPerStud = radius / Config.Quests.Map.MinimapRadius
	local side = info.Size * pixelsPerStud

	-- Rotate so the camera's forward points up.
	local look = camera.CFrame.LookVector
	local rotation = if Vector2.new(look.X, look.Z).Magnitude > 0.01 then -90 - heading(look) else rotor.Rotation
	rotor.Rotation = rotation
	local unit = Surface.ToUnit(info, position.X, position.Z)
	surface.Root.Position = UDim2.fromOffset(-unit.X * side, -unit.Y * side)
	arrow.Rotation = heading(root.CFrame.LookVector) + 90 + rotation

	local theta = math.rad(rotation)
	local cosT, sinT = math.cos(theta), math.sin(theta)
	local function place(world: Vector2): (Vector2, number)
		local dx = (world.X - position.X) * pixelsPerStud
		local dy = (world.Y - position.Z) * pixelsPerStud
		local offset = Vector2.new(dx * cosT - dy * sinT, dx * sinT + dy * cosT)
		return offset, offset.Magnitude
	end

	local used = 0
	local limit = radius - RIM_MARGIN
	for _, entry in points do
		local offset, distance = place(entry.World)
		local sticky = entry.Kind == "Quest" and (entry.Tracked or entry.TurnIn)
		if distance <= limit or sticky then
			if distance > limit then
				offset = offset.Unit * limit
			end
			used += 1
			local view = getIcon(used)
			if view.Point ~= entry then
				Icon.Apply(view, entry, nil)
				if entry.Kind == "Quest" and entry.Tracked then
					view.Frame.Size = UDim2.fromOffset(M.MinimapIconSize + 4, M.MinimapIconSize + 4)
				end
			end
			view.Frame.Position = UDim2.new(0.5, offset.X, 0.5, offset.Y)
		end
	end
	for index = used + 1, #icons do
		if icons[index].Frame.Visible then
			Icon.Hide(icons[index])
		end
	end

	-- Other players inside the circle.
	local dots = 0
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local otherCharacter = other.Character
			local otherRoot = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart")
			if otherRoot and otherRoot:IsA("BasePart") then
				local offset, distance = place(Vector2.new(otherRoot.Position.X, otherRoot.Position.Z))
				if distance <= limit then
					dots += 1
					local dot = getDot(dots)
					dot.Visible = true
					dot.Position = UDim2.new(0.5, offset.X, 0.5, offset.Y)
				end
			end
		end
	end
	for index = dots + 1, #playerDots do
		playerDots[index].Visible = false
	end

	-- Extra markers (MapController.SetExtraMarkers: party members, pings).
	local extras = 0
	for _, marker in Extra.Collect() do
		local offset, distance = place(Vector2.new(marker.World.X, marker.World.Z))
		if distance <= limit or marker.Rim then
			if distance > limit then
				offset = offset.Unit * limit
			end
			extras += 1
			local dot = getExtraDot(extras)
			local dotSide = marker.Size or 9
			dot.Visible = true
			dot.Size = UDim2.fromOffset(dotSide, dotSide)
			dot.BackgroundColor3 = marker.Color
			dot.Position = UDim2.new(0.5, offset.X, 0.5, offset.Y)
		end
	end
	for index = extras + 1, #extraDots do
		extraDots[index].Visible = false
	end

	-- North on the rim.
	local northOffset = Vector2.new(sinT, -cosT) * (radius + 1)
	north.Position = UDim2.new(0.5, northOffset.X, 0.5, northOffset.Y)
end

-- Re-reads the markers (quest state, pins, Waystones changed).
function Minimap.Refresh()
	local floor = Surface.CurrentFloor()
	if surface.Floor ~= floor then
		surface:SetFloor(floor)
		floorInfo = Surface.Info(floor)
		layout()
	end
	surface:RefreshFog()
	points = Points.Collect(floor)
	for _, view in icons do
		view.Point = nil -- restyle on the next update
	end
	lastUpdate = 0
end

function Minimap.Init(openMap: () -> ())
	holder = Create.new("Frame", {
		Name = "Minimap",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Parent = Layers.Get("HUD"),
	})
	-- Rim: a dark disc with a brass edge, a little larger than the map.
	local rim: Frame = Create.new("Frame", {
		Name = "Rim",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 6, 1, 6),
		BackgroundColor3 = C.HudPanel,
		BackgroundTransparency = 0.2,
		Parent = holder,
	})
	Create.Corner(rim, UDim.new(0.5, 0))
	Create.Stroke(rim, UITheme.Colors.Brass, 1.5, 0.35)

	clip = Create.new("CanvasGroup", {
		Name = "Clip",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = M.Background,
		BorderSizePixel = 0,
		Parent = holder,
	})
	Create.Corner(clip, UDim.new(0.5, 0))
	rotor = Create.new("Frame", {
		Name = "Rotor",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 0),
		Parent = clip,
	})
	surface = Surface.new(rotor, false)
	surface.Root.Size = UDim2.fromOffset(0, 0)
	overlay = Create.new("Frame", {
		Name = "Markers",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
		Parent = clip,
	})
	arrow = Icon.Arrow(overlay, 16, 8)
	arrow.Position = UDim2.fromScale(0.5, 0.5)

	north = Create.new("TextLabel", {
		Name = "North",
		BackgroundColor3 = C.HudPanel,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(18, 18),
		FontFace = UITheme.Fonts.Title,
		TextSize = 12,
		TextColor3 = UITheme.Colors.Brass,
		Text = "N",
		ZIndex = 6,
		Parent = holder,
	})
	Create.Corner(north, UDim.new(0.5, 0))
	Create.Stroke(north, UITheme.Colors.Brass, 1, 0.4)

	local button: TextButton = Create.new("TextButton", {
		Name = "Open",
		Text = "",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 7,
		Selectable = false,
		Parent = holder,
	})
	button.Activated:Connect(openMap)

	layout()
	Device.Changed:Connect(layout)
	Animator.Add(function(time: number)
		if time - lastUpdate >= UPDATE_INTERVAL then
			lastUpdate = time
			update()
		end
	end)
end

return Minimap
