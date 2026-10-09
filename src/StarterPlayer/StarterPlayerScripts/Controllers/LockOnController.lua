--!strict
--[[
	LockOnController
	Lock-on targeting (Spec Section 7): Middle mouse / Tab, R3, or the LOCK
	button on touch.

	- Locks the enemy nearest the centre of your view (within MaxDistance
	  and ViewAngleDegrees of where the camera looks).
	- While locked, the camera keeps the target in view, your character
	  faces it (strafing instead of turning to run), and attacks aim at it.
	- Switch targets with a quick mouse flick or a right-stick flick; the
	  next enemy in that direction (on screen) is chosen.
	- The lock breaks when the target dies, leaves, or gets too far away.
	- A marker shows the target: a reticle at its centre and, above it, its
	  name, health and posture (balance) bars (Floor Guardians skip the bars;
	  their boss bar shows them).
	- Lock points: big targets carry Attachments named "LockPoint" (attribute
	  Enabled ~= false). The reticle, the camera and your facing aim at the
	  chosen point. A switch flick first moves to the next enabled point in
	  that direction on screen (points ordered left to right), and only past
	  the last one moves on to the next target. A point that is disabled
	  while chosen hands over to the nearest enabled one.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Attributes = require(Shared.Attributes)
local Maid = require(Shared.Util.Maid)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Animator = require(UI.Animator)
local Components = require(UI.Components)

local InputController = require(script.Parent.InputController)
local CameraController = require(script.Parent.CameraController)
local CharacterController = require(script.Parent.CharacterController)

local A = Attributes.Names
local LOCK_POINT = "LockPoint"
local SCREEN_EPSILON = 2 -- pixels: points closer than this on screen count as the same column
local L = Config.Camera.LockOn
local M = UITheme.LockOn
local player = Players.LocalPlayer

local LockOnController = {}

local target: Model? = nil
local lockPoint: Attachment? = nil
local points: { Attachment } = {} -- every LockPoint on the target, enabled or not
local reticleGui: BillboardGui? = nil
local markerMaid = Maid.new()
local lastSwitch = 0
local stickArmed = true -- the right stick must return to centre between flicks

local function rootOf(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	return if root and root:IsA("BasePart") then root else nil
end

local function isValid(model: Model): boolean
	if not model.Parent or model:GetAttribute(A.Team) ~= "Enemies" then
		return false
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0 and rootOf(model) ~= nil
end

local function myRoot(): BasePart?
	local character = player.Character
	return if character then rootOf(character) else nil
end

-- Candidates in front of the camera, with their angle from view centre.
local function candidates(): { { Model: Model, Angle: number, Distance: number } }
	local list = {}
	local camera = Workspace.CurrentCamera
	local root = myRoot()
	if not camera or not root then
		return list
	end
	local look = camera.CFrame.LookVector
	for _, instance in CollectionService:GetTagged(Attributes.Tags.CombatTarget) do
		if instance:IsA("Model") and isValid(instance) then
			local targetRoot = rootOf(instance) :: BasePart
			local distance = (targetRoot.Position - root.Position).Magnitude
			local toTarget = targetRoot.Position - camera.CFrame.Position
			if distance <= L.MaxDistance and toTarget.Magnitude > 0 then
				local angle = math.deg(math.acos(math.clamp(look:Dot(toTarget.Unit), -1, 1)))
				if angle <= L.ViewAngleDegrees then
					table.insert(list, { Model = instance, Angle = angle, Distance = distance })
				end
			end
		end
	end
	return list
end

-- LOCK POINTS ------------------------------------------------------------------

local function pointEnabled(point: Attachment): boolean
	return point.Parent ~= nil and point:GetAttribute(A.Enabled) ~= false
end

local function enabledPoints(): { Attachment }
	local list = {}
	for _, point in points do
		if pointEnabled(point) then
			table.insert(list, point)
		end
	end
	return list
end

local function collectPoints(model: Model)
	table.clear(points)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Attachment") and descendant.Name == LOCK_POINT then
			table.insert(points, descendant)
		end
	end
end

-- Where the lock aims: the chosen point, or the target's root.
local function aimPosition(model: Model): Vector3?
	local point = lockPoint
	if point and pointEnabled(point) then
		return point.WorldPosition
	end
	local root = rootOf(model)
	return if root then root.Position else nil
end

local function setPoint(point: Attachment?)
	lockPoint = point
	local gui = reticleGui
	local current = target
	if gui and current then
		local adornee: Instance? = point or rootOf(current)
		if adornee then
			gui.Adornee = adornee
		end
	end
end

-- The enabled point nearest the centre of the view (a fresh lock starts there).
local function centredPoint(): Attachment?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local best: Attachment? = nil
	local bestAngle = math.huge
	local look = camera.CFrame.LookVector
	for _, point in enabledPoints() do
		local offset = point.WorldPosition - camera.CFrame.Position
		if offset.Magnitude > 0 then
			local angle = math.acos(math.clamp(look:Dot(offset.Unit), -1, 1))
			if angle < bestAngle then
				best = point
				bestAngle = angle
			end
		end
	end
	return best
end

-- The enabled point furthest toward one side of the screen (-1 left edge, +1 right edge).
local function edgePoint(side: number): Attachment?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local best: Attachment? = nil
	local bestX = -math.huge
	for _, point in enabledPoints() do
		local screen = camera:WorldToViewportPoint(point.WorldPosition)
		if screen.Z > 0 and screen.X * side > bestX then
			best = point
			bestX = screen.X * side
		end
	end
	return best
end

-- Replaces a chosen point that was disabled or removed with the nearest enabled one.
local function revalidatePoint()
	local point = lockPoint
	if point == nil or pointEnabled(point) then
		return
	end
	local from = point.WorldPosition
	local best: Attachment? = nil
	local bestDistance = math.huge
	for _, other in enabledPoints() do
		local distance = (other.WorldPosition - from).Magnitude
		if distance < bestDistance then
			best = other
			bestDistance = distance
		end
	end
	setPoint(best)
end

-- MARKER ---------------------------------------------------------------------

local function buildMarker(model: Model)
	markerMaid:Clean()
	local root = rootOf(model)
	if not root then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")

	-- Reticle: a slowly turning diamond at the target's centre (or its lock point).
	local reticle: BillboardGui = Create.new("BillboardGui", {
		Name = "LockOnReticle",
		Adornee = lockPoint or root,
		AlwaysOnTop = true,
		LightInfluence = 0,
		ResetOnSpawn = false,
		Size = UDim2.fromOffset(M.ReticleSize, M.ReticleSize),
	})
	markerMaid:Add(reticle)
	reticleGui = reticle
	markerMaid:Add(function()
		if reticleGui == reticle then
			reticleGui = nil
		end
	end)
	local diamond: Frame = Create.new("Frame", {
		Name = "Diamond",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.6, 0.6),
		BackgroundTransparency = 1,
		Rotation = 45,
		Parent = reticle,
	})
	Create.Stroke(diamond, UITheme.Colors.Current, 2, 0)
	local dot: Frame = Create.new("Frame", {
		Name = "Dot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(4, 4),
		BackgroundColor3 = UITheme.Colors.Current,
		Parent = reticle,
	})
	Create.Corner(dot, UITheme.CornerPill)
	markerMaid:Add(Animator.Add(function(time: number)
		diamond.Rotation = 45 + time * 40
	end))

	-- Lock points appear and disappear with the body (a Guardian's core in its last phase).
	markerMaid:Add(model.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("Attachment") and descendant.Name == LOCK_POINT and not table.find(points, descendant) then
			table.insert(points, descendant)
		end
	end))
	markerMaid:Add(model.DescendantRemoving:Connect(function(descendant: Instance)
		if descendant:IsA("Attachment") then
			local index = table.find(points, descendant)
			if index then
				table.remove(points, index)
			end
			if descendant == lockPoint then
				lockPoint = nil
				setPoint(centredPoint())
			end
		end
	end))
	reticle.Parent = playerGui
	if CollectionService:HasTag(model, Attributes.Tags.Guardian) then
		return
	end

	-- Info above the head: name, health, posture.
	local infoGui: BillboardGui = Create.new("BillboardGui", {
		Name = "LockOnInfo",
		Adornee = root,
		AlwaysOnTop = true,
		LightInfluence = 0,
		ResetOnSpawn = false,
		StudsOffsetWorldSpace = M.InfoOffset,
		Size = UDim2.fromOffset(M.BarWidth, 22 + M.HealthHeight + M.PostureHeight + 8),
	})
	markerMaid:Add(infoGui)
	local nameKey = model:GetAttribute(A.NameKey)
	local name = model.Name
	if type(nameKey) == "string" then
		local section, key = string.match(nameKey, "^(%w+)%.(%w+)$")
		local group = section and (Strings :: any)[section]
		if group and key and type(group[key]) == "string" then
			name = group[key]
		end
	end
	Create.Label({
		Name = "Name",
		Text = name,
		Font = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.Small,
		XAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 20),
		Parent = infoGui,
	}).TextStrokeTransparency = 0.4
	local health = Components.ProgressBar.new({
		Name = "Health",
		Color = UITheme.Colors.Health,
		TrailColor = UITheme.Colors.HealthTrail,
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.new(1, 0, 0, M.HealthHeight),
		Parent = infoGui,
	})
	markerMaid:Add(function()
		health:Destroy()
	end)
	local posture = Components.ProgressBar.new({
		Name = "Posture",
		Color = UITheme.Colors.Parry,
		Position = UDim2.fromOffset(0, 22 + M.HealthHeight + 4),
		Size = UDim2.new(1, 0, 0, M.PostureHeight),
		Parent = infoGui,
	})
	markerMaid:Add(function()
		posture:Destroy()
	end)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local function refreshHealth(instant: boolean?)
		if humanoid then
			health:SetValue(humanoid.Health, humanoid.MaxHealth, instant)
		end
	end
	local function refreshPosture(instant: boolean?)
		local value = model:GetAttribute(A.Posture)
		local max = model:GetAttribute(A.MaxPosture)
		posture:SetValue(if type(value) == "number" then value else 0, if type(max) == "number" then max else 100, instant)
		local broken = model:GetAttribute(A.CombatState) == "Broken"
		posture:SetColor(if broken then UITheme.Colors.Danger else UITheme.Colors.Parry)
	end
	refreshHealth(true)
	refreshPosture(true)
	if humanoid then
		markerMaid:Add(humanoid.HealthChanged:Connect(function()
			refreshHealth()
		end))
	end
	markerMaid:Add(model:GetAttributeChangedSignal(A.Posture):Connect(function()
		refreshPosture()
	end))
	markerMaid:Add(model:GetAttributeChangedSignal(A.CombatState):Connect(function()
		refreshPosture()
	end))

	infoGui.Parent = playerGui
end

-- LOCKING ----------------------------------------------------------------------

-- `entrySide` (+1 / -1): arriving from a switch in that direction starts on the near edge's point.
local function setTarget(model: Model?, entrySide: number?)
	target = model
	lockPoint = nil
	table.clear(points)
	if model then
		collectPoints(model)
		lockPoint = if entrySide then edgePoint(-entrySide) else centredPoint()
		buildMarker(model)
	else
		markerMaid:Clean()
		CameraController.SetTargetLook(nil)
		CharacterController.SetLockTarget(nil)
	end
end

local function acquire()
	local best: Model? = nil
	local bestScore = math.huge
	for _, candidate in candidates() do
		-- Prefer what you're looking at; distance breaks ties.
		local score = candidate.Angle + candidate.Distance * 0.5
		if score < bestScore then
			best = candidate.Model
			bestScore = score
		end
	end
	setTarget(best)
end

-- Switches to the nearest other target on the given side of the screen (+1 right, -1 left).
local function switch(side: number)
	local current = target
	local camera = Workspace.CurrentCamera
	if not current or not camera or os.clock() - lastSwitch < L.SwitchCooldown then
		return
	end
	local currentAim = aimPosition(current)
	if not currentAim then
		return
	end
	local currentScreen = camera:WorldToViewportPoint(currentAim)

	-- First the target's own lock points, left to right on screen.
	local bestPoint: Attachment? = nil
	local bestPointDelta = math.huge
	for _, point in enabledPoints() do
		if point ~= lockPoint then
			local screen = camera:WorldToViewportPoint(point.WorldPosition)
			local delta = (screen.X - currentScreen.X) * side
			if screen.Z > 0 and delta > SCREEN_EPSILON and delta < bestPointDelta then
				bestPoint = point
				bestPointDelta = delta
			end
		end
	end
	if bestPoint then
		lastSwitch = os.clock()
		setPoint(bestPoint)
		return
	end

	local currentRoot = rootOf(current)
	if not currentRoot then
		return
	end
	currentScreen = camera:WorldToViewportPoint(currentRoot.Position)
	local best: Model? = nil
	local bestDelta = math.huge
	for _, candidate in candidates() do
		if candidate.Model ~= current then
			local candidateRoot = rootOf(candidate.Model) :: BasePart
			local screen = camera:WorldToViewportPoint(candidateRoot.Position)
			local delta = (screen.X - currentScreen.X) * side
			if delta > 0 and delta < bestDelta then
				best = candidate.Model
				bestDelta = delta
			end
		end
	end
	if best then
		lastSwitch = os.clock()
		setTarget(best, side)
	end
end

-- PUBLIC API -------------------------------------------------------------------

function LockOnController.GetTarget(): Model?
	return target
end

function LockOnController.Unlock()
	setTarget(nil)
end

local function step()
	local current = target
	if not current then
		return
	end
	local root = myRoot()
	local targetRoot = rootOf(current)
	if not root or not targetRoot or not isValid(current)
		or (targetRoot.Position - root.Position).Magnitude > L.MaxDistance * L.BreakDistanceMultiplier then
		setTarget(nil)
		return
	end
	revalidatePoint()
	local aim = aimPosition(current) or targetRoot.Position
	CameraController.SetTargetLook(aim)
	CharacterController.SetLockTarget(aim)

	-- Mouse flick to switch.
	if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
		local delta = UserInputService:GetMouseDelta()
		if math.abs(delta.X) >= L.SwitchMousePixels then
			switch(if delta.X > 0 then 1 else -1)
		end
	end
end

function LockOnController.Init()
	InputController.ActionBegan:Connect(function(action: string)
		if action ~= "LockOn" then
			return
		end
		if target then
			setTarget(nil)
		else
			acquire()
		end
	end)
	-- Right stick flicks.
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if input.KeyCode ~= Enum.KeyCode.Thumbstick2 or not target then
			return
		end
		local x = input.Position.X
		if math.abs(x) < L.SwitchFlickThreshold * 0.5 then
			stickArmed = true
		elseif stickArmed and math.abs(x) >= L.SwitchFlickThreshold then
			stickArmed = false
			switch(if x > 0 then 1 else -1)
		end
	end)
end

function LockOnController.Start()
	player.CharacterAdded:Connect(function()
		setTarget(nil)
	end)
	RunService:BindToRenderStep("SpireLockOn", Enum.RenderPriority.Camera.Value, step)
end

return LockOnController
