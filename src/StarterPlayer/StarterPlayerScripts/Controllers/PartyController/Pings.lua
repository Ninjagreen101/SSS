--!strict
--[[
	Pings
	Party ping markers (Spec Section 14: G or tap).
	- Placing: tap G to ping "Here" where the camera's centre looks; hold G (past
	  Config.Input.HoldThreshold) for a 4-way radial (Here / Danger / Loot / Go): move the mouse
	  toward one and release. On touch, tapping the PING button arms a ping that lands where you
	  tap the world next; holding it opens the radial, whose options are tapped (then the world).
	  Only RequestPing is sent; the server checks party, cooldown, live count and range.
	- Showing: each Ping is a pooled world marker (a vertical beam and a billboard with the kind
	  and distance) for its lifetime, plus a dot on the minimap and the Map (Markers()). At most
	  Social.Party.MaxPings per sender; a newer one replaces their oldest.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)

local UI = script.Parent.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Animator = require(UI.Animator)
local Components = require(UI.Components)
local UISound = require(UI.UISound)
local Motion = require(UI.Motion)

local InputController = require(script.Parent.Parent.InputController)

local State = require(script.Parent.State)

local C = UITheme.Colors
local S = Strings.Party
local SP = Config.Social.Party
local localPlayer = Players.LocalPlayer

local KINDS = { "Here", "Danger", "Loot", "Go" } -- radial order: up, right, down, left
local DIRECTIONS = { Vector2.new(0, -1), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(-1, 0) }
local COLORS: { [string]: Color3 } = {
	Here = C.Current,
	Danger = C.Danger,
	Loot = C.Parry,
	Go = C.Aqua,
}
local BEAM_HEIGHT = 24
local RADIAL_RADIUS = 78
local OPTION_SIZE = 64
local AIM_DEADZONE = 18 -- px of mouse travel before a direction is picked
local ARM_SECONDS = 5 -- touch: how long a ping waits for the world tap

type Marker = {
	Bottom: Attachment,
	Top: Attachment,
	Beam: Beam,
	Gui: BillboardGui,
	Kind: TextLabel,
	Distance: TextLabel,
	From: number,
	Position: Vector3,
	Color: Color3,
	Expires: number,
	Active: boolean,
}

export type MapMarker = { World: Vector3, Color: Color3, Size: number?, Rim: boolean? }

local Pings = {}

local markers: { Marker } = {}
local holdThread: thread? = nil
local radial: Frame
local options: { TextButton } = {}
local radialOpen = false
local radialDevice = ""
local aim = Vector2.zero
local highlighted = 1
local armedKind: string? = nil
local armedUntil = 0
local pressDevice = ""
local guiFolder: Folder

-- WORLD MARKERS ---------------------------------------------------------------------------------

local function newMarker(): Marker
	local terrain = Workspace.Terrain
	local bottom = Instance.new("Attachment")
	bottom.Name = "PingBottom"
	bottom.Parent = terrain
	local top = Instance.new("Attachment")
	top.Name = "PingTop"
	top.Parent = terrain
	local beam = Instance.new("Beam")
	beam.Attachment0 = bottom
	beam.Attachment1 = top
	beam.Width0 = 0.6
	beam.Width1 = 0.1
	beam.FaceCamera = true
	beam.LightEmission = 1
	beam.Transparency = NumberSequence.new(0.1, 0.8)
	beam.Enabled = false
	beam.Parent = terrain
	local gui: BillboardGui = Create.new("BillboardGui", {
		Name = "Ping",
		AlwaysOnTop = true,
		LightInfluence = 0,
		Size = UDim2.fromOffset(110, 42),
		StudsOffsetWorldSpace = Vector3.new(0, 2, 0),
		Enabled = false,
		Adornee = top,
		Parent = guiFolder,
	})
	local kind: TextLabel = Create.new("TextLabel", {
		Name = "Kind",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 22),
		FontFace = UITheme.Fonts.Title,
		TextSize = 18,
		TextStrokeTransparency = 0.2,
		Text = "",
		Parent = gui,
	})
	local distance: TextLabel = Create.new("TextLabel", {
		Name = "Distance",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.new(1, 0, 0, 18),
		FontFace = UITheme.Fonts.BodyBold,
		TextSize = 14,
		TextColor3 = C.Text,
		TextStrokeTransparency = 0.3,
		Text = "",
		Parent = gui,
	})
	return {
		Bottom = bottom,
		Top = top,
		Beam = beam,
		Gui = gui,
		Kind = kind,
		Distance = distance,
		From = 0,
		Position = Vector3.zero,
		Color = C.Current,
		Expires = 0,
		Active = false,
	}
end

local function release(marker: Marker)
	marker.Active = false
	marker.Beam.Enabled = false
	marker.Gui.Enabled = false
end

local function take(from: number): Marker
	-- Their oldest live ping goes once they are at the cap.
	local mine: { Marker } = {}
	for _, marker in markers do
		if marker.Active and marker.From == from then
			table.insert(mine, marker)
		end
	end
	if #mine >= SP.MaxPings then
		table.sort(mine, function(a: Marker, b: Marker): boolean
			return a.Expires < b.Expires
		end)
		return mine[1]
	end
	for _, marker in markers do
		if not marker.Active then
			return marker
		end
	end
	local marker = newMarker()
	table.insert(markers, marker)
	return marker
end

function Pings.Show(fromUserId: number, position: Vector3, kind: string, expiresAt: number)
	if typeof(position) ~= "Vector3" or type(expiresAt) ~= "number" then
		return
	end
	local color = COLORS[kind] or C.Current
	local marker = take(fromUserId)
	marker.From = fromUserId
	marker.Position = position
	marker.Color = color
	marker.Expires = expiresAt
	marker.Active = true
	marker.Bottom.WorldPosition = position
	marker.Top.WorldPosition = position + Vector3.new(0, BEAM_HEIGHT, 0)
	marker.Beam.Color = ColorSequence.new(color)
	marker.Beam.Enabled = true
	marker.Kind.Text = S.PingKinds[kind] or S.PingKinds.Here
	marker.Kind.TextColor3 = color
	marker.Gui.Enabled = true
	if fromUserId ~= localPlayer.UserId then
		UISound.Play("UIToast")
	end
end

-- Live pings for the minimap and the Map.
function Pings.Markers(): { MapMarker }
	local list: { MapMarker } = {}
	for _, marker in markers do
		if marker.Active then
			table.insert(list, { World = marker.Position, Color = marker.Color, Size = 10, Rim = true })
		end
	end
	return list
end

function Pings.Clear()
	for _, marker in markers do
		release(marker)
	end
end

local function updateMarkers(time: number)
	local now = Workspace:GetServerTimeNow()
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	for _, marker in markers do
		if marker.Active then
			if now >= marker.Expires then
				release(marker)
			else
				if root and root:IsA("BasePart") then
					local distance = math.floor((root.Position - marker.Position).Magnitude + 0.5)
					marker.Distance.Text = Strings.Format(S.PingDistance, { distance = distance })
				end
				if not Motion.IsReduced() then
					marker.Beam.Width0 = 0.6 + math.sin(time * 6) * 0.15
				end
			end
		end
	end
end

-- PLACING ---------------------------------------------------------------------------------------

local function raycast(origin: Vector3, direction: Vector3): Vector3?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = {}
	if localPlayer.Character then
		table.insert(ignore, localPlayer.Character)
	end
	params.FilterDescendantsInstances = ignore
	local result = Workspace:Raycast(origin, direction.Unit * SP.PingRange, params)
	return if result then result.Position else nil
end

local function send(kind: string, position: Vector3?)
	if not position then
		UISound.Play("UIError")
		return
	end
	Net.FireServer("RequestPing", position, kind)
end

local function centreTarget(): Vector3?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local size = camera.ViewportSize
	local ray = camera:ViewportPointToRay(size.X / 2, size.Y / 2)
	return raycast(ray.Origin, ray.Direction)
end

local function arm(kind: string)
	armedKind = kind
	armedUntil = os.clock() + ARM_SECONDS
end

local function setHighlight(index: number)
	highlighted = index
	for i, option in options do
		local stroke = option:FindFirstChildOfClass("UIStroke")
		option.BackgroundTransparency = if i == index then 0.05 else 0.35
		if stroke then
			stroke.Transparency = if i == index then 0 else 0.5
		end
	end
end

local function closeRadial()
	radialOpen = false
	radial.Visible = false
end

local function choose(index: number)
	local kind = KINDS[index] or "Here"
	closeRadial()
	if radialDevice == "Touch" then
		arm(kind)
	else
		send(kind, centreTarget())
	end
end

local function openRadial(device: string)
	radialOpen = true
	radialDevice = device
	aim = Vector2.zero
	setHighlight(1)
	radial.Visible = true
	UISound.Play("UIOpen")
	if device == "Touch" then
		task.delay(ARM_SECONDS, function()
			if radialOpen and radialDevice == "Touch" then
				closeRadial()
			end
		end)
	end
end

local function buildRadial()
	radial = Create.new("Frame", {
		Name = "PingRadial",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(RADIAL_RADIUS * 2 + OPTION_SIZE, RADIAL_RADIUS * 2 + OPTION_SIZE),
		Visible = false,
		Parent = Layers.Get("Overlay"),
	})
	for index, kind in KINDS do
		local offset = DIRECTIONS[index] * RADIAL_RADIUS
		local option: TextButton = Create.new("TextButton", {
			Name = kind,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, offset.X, 0.5, offset.Y),
			Size = UDim2.fromOffset(OPTION_SIZE, OPTION_SIZE),
			BackgroundColor3 = C.HudPanel,
			BackgroundTransparency = 0.35,
			FontFace = UITheme.Fonts.BodyBold,
			TextSize = 15,
			TextColor3 = COLORS[kind],
			Text = S.PingKinds[kind],
			AutoButtonColor = false,
			Parent = radial,
		})
		Create.Corner(option, UDim.new(0.5, 0))
		Create.Stroke(option, COLORS[kind], 2, 0.5)
		option.MouseEnter:Connect(function()
			setHighlight(index)
		end)
		option.Activated:Connect(function()
			choose(index)
		end)
		options[index] = option
	end
end

local function onBegan(action: string, device: string)
	if action ~= "Ping" then
		return
	end
	if not State.Party then
		Components.Toast.Push({ Title = S.NoPartyPing, Color = C.TextMuted, Key = "PartyPing" })
		return
	end
	if holdThread then
		task.cancel(holdThread)
	end
	pressDevice = device
	holdThread = task.delay(Config.Input.HoldThreshold, function()
		holdThread = nil
		openRadial(device)
	end)
end

local function onEnded(action: string)
	if action ~= "Ping" then
		return
	end
	local pending = holdThread
	if pending then
		-- A tap.
		task.cancel(pending)
		holdThread = nil
		if pressDevice == "Touch" then
			arm("Here")
		else
			send("Here", centreTarget())
		end
	elseif radialOpen and radialDevice ~= "Touch" then
		choose(highlighted)
	end
end

function Pings.Init()
	guiFolder = Instance.new("Folder")
	guiFolder.Name = "SpirePings"
	guiFolder.Parent = localPlayer:WaitForChild("PlayerGui")
	buildRadial()
	InputController.ActionBegan:Connect(function(action: string, device: string)
		onBegan(action, device)
	end)
	InputController.ActionEnded:Connect(function(action: string)
		onEnded(action)
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if not radialOpen or radialDevice == "Touch" or input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
			aim += Vector2.new(input.Delta.X, input.Delta.Y)
		else
			local centre = radial.AbsolutePosition + radial.AbsoluteSize / 2
			aim = Vector2.new(input.Position.X, input.Position.Y) - centre
		end
		if aim.Magnitude >= AIM_DEADZONE then
			local best, bestDot = 1, -math.huge
			for index, direction in DIRECTIONS do
				local dot = aim.Unit:Dot(direction)
				if dot > bestDot then
					best, bestDot = index, dot
				end
			end
			if best ~= highlighted then
				setHighlight(best)
			end
		end
	end)
	UserInputService.TouchTapInWorld:Connect(function(position: Vector2, processedByUI: boolean)
		local kind = armedKind
		if processedByUI or not kind then
			return
		end
		armedKind = nil
		if os.clock() > armedUntil then
			return
		end
		local camera = Workspace.CurrentCamera
		if camera then
			local ray = camera:ScreenPointToRay(position.X, position.Y)
			send(kind, raycast(ray.Origin, ray.Direction))
		end
	end)
	Animator.Add(function(time: number)
		updateMarkers(time)
	end)
end

return Pings
