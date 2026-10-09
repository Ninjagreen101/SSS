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
	  name, health and posture (balance) bars.
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
local L = Config.Camera.LockOn
local M = UITheme.LockOn
local player = Players.LocalPlayer

local LockOnController = {}

local target: Model? = nil
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

-- MARKER ---------------------------------------------------------------------

local function buildMarker(model: Model)
	markerMaid:Clean()
	local root = rootOf(model)
	if not root then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")

	-- Reticle: a slowly turning diamond at the target's centre.
	local reticleGui: BillboardGui = Create.new("BillboardGui", {
		Name = "LockOnReticle",
		Adornee = root,
		AlwaysOnTop = true,
		LightInfluence = 0,
		ResetOnSpawn = false,
		Size = UDim2.fromOffset(M.ReticleSize, M.ReticleSize),
	})
	markerMaid:Add(reticleGui)
	local diamond: Frame = Create.new("Frame", {
		Name = "Diamond",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.6, 0.6),
		BackgroundTransparency = 1,
		Rotation = 45,
		Parent = reticleGui,
	})
	Create.Stroke(diamond, UITheme.Colors.Current, 2, 0)
	local dot: Frame = Create.new("Frame", {
		Name = "Dot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(4, 4),
		BackgroundColor3 = UITheme.Colors.Current,
		Parent = reticleGui,
	})
	Create.Corner(dot, UITheme.CornerPill)
	markerMaid:Add(Animator.Add(function(time: number)
		diamond.Rotation = 45 + time * 40
	end))

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

	reticleGui.Parent = playerGui
	infoGui.Parent = playerGui
end

-- LOCKING ----------------------------------------------------------------------

local function setTarget(model: Model?)
	target = model
	if model then
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
	local currentRoot = rootOf(current)
	if not currentRoot then
		return
	end
	local currentScreen = camera:WorldToViewportPoint(currentRoot.Position)
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
		setTarget(best)
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
	CameraController.SetTargetLook(targetRoot.Position)
	CharacterController.SetLockTarget(targetRoot.Position)

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
