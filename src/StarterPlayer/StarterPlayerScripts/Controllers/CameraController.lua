--!strict
--[[
	CameraController
	Over-the-shoulder third-person camera (Spec Section 7).

	- Scriptable camera driven by yaw/pitch that we own, so it behaves the
	  same on mouse, gamepad and touch.
	  Mouse:   the cursor is locked to the centre during gameplay; hold
	           Free Cursor (Left Alt) or open a menu to get it back.
	  Gamepad: right stick, scaled by CameraSensitivity.
	  Touch:   drag anywhere that isn't a button or the move stick; pinch
	           to zoom. Mouse wheel zooms on PC.
	- Collision: a spherecast from the character's head to the desired camera
	  spot pulls the camera in front of walls instead of through them.
	- Shoulder side (Right/Left setting) springs across smoothly.
	- FOV widens while sprinting; landings from a real fall dip the camera.
	- Shake(intensity): trauma-based shake, scaled by the Camera Shake
	  setting and disabled by Reduced Motion.
	- The character fades out when the camera is pushed very close to it.
	- While the mouse is locked, a small reticle marks the screen centre
	  (where the hidden cursor is), like a shift-lock cursor.
	Lock-on (Phase 3) will steer yaw/pitch through SetTargetLook().
	- SetCinematic(source, blend): scripted shots (Guardian intros and
	  victories) take the camera; releasing blends back to the gameplay view.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Spring = require(Shared.Util.Spring)
local MathUtil = require(Shared.Util.MathUtil)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)

local DataController = require(script.Parent.DataController)
local InputController = require(script.Parent.InputController)
local UIController = require(script.Parent.UIController)

local A = Attributes.Names
local C = Config.Camera
local player = Players.LocalPlayer

local CameraController = {}

-- Set by CharacterController so the FOV reacts before the server confirms.
CameraController.PredictedSprint = false

local yaw = 0
local pitch = math.rad(-12)
local zoom = C.Distance
local zoomTarget = C.Distance
local currentDistance = C.Distance
local focus: Vector3? = nil
local fov = C.FieldOfView
local punch = 0 -- extra FOV from CameraController.Punch, decays back to 0
local trauma = 0
local shakeSeed = math.random() * 1000
local sideSpring = Spring.newNumber(1, C.ShoulderSwapSpeed)
local dipSpring = Spring.newNumber(0, C.LandingDipSpring.Speed, C.LandingDipSpring.Damper) -- landing dip, studs (X axis)
local lastFade = 0
local gamepadLook = Vector2.zero
local cameraTouches: { [InputObject]: Vector2 } = {}
local pinchDistance: number? = nil
local lastFallSpeed = 0
local freeCursorHeld = false
local character: Model? = nil
local humanoid: Humanoid? = nil
local root: BasePart? = nil
local lookOverride: Vector3? = nil
local reticle: Frame? = nil
local cinematic: ((dt: number) -> (CFrame, number))? = nil
local cinematicLast: CFrame? = nil
local cinematicFov = C.FieldOfView
local blendTotal = 0
local blendLeft = 0

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local function setting(key: string, fallback: any): any
	local value = DataController.GetSetting(key)
	if value == nil then
		return fallback
	end
	return value
end

local function reducedMotion(): boolean
	return setting("ReducedMotion", false) == true
end

local function sensitivity(): number
	local value = setting("CameraSensitivity", 1)
	return if type(value) == "number" then value else 1
end

local function gameplayActive(): boolean
	return InputController.GetContext() == "Gameplay" and not UIController.IsMenuOpen()
end

local function isAlive(): boolean
	return humanoid ~= nil and humanoid.Health > 0
end

-- Cursor: locked during gameplay on mouse, free in menus, while dead, or
-- while Free Cursor is held.
local function updateMouse()
	local lock = gameplayActive() and isAlive() and not freeCursorHeld and InputController.GetDevice() == "KeyboardMouse"
	local behavior = if lock then Enum.MouseBehavior.LockCenter else Enum.MouseBehavior.Default
	if UserInputService.MouseBehavior ~= behavior then
		UserInputService.MouseBehavior = behavior
	end
	UserInputService.MouseIconEnabled = not lock
	local mark = reticle
	if mark and mark.Visible ~= lock then
		mark.Visible = lock
	end
end

-- Centre reticle: a teal dot inside a thin ring, outlined in dark so it
-- reads on any background. Lives in the Overlay layer, which ignores the
-- top bar inset, so it sits exactly where the locked mouse is.
local function buildReticle()
	local R = UITheme.Reticle
	local holder: Frame = Create.new("Frame", {
		Name = "Reticle",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(R.RingSize, R.RingSize),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = Layers.Get("Overlay"),
	})
	local ring: Frame = Create.new("Frame", {
		Name = "Ring",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = holder,
	})
	Create.Corner(ring, UITheme.CornerPill)
	Create.Stroke(ring, UITheme.Colors.Text, R.RingThickness, R.RingTransparency)
	local dot: Frame = Create.new("Frame", {
		Name = "Dot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(R.DotSize, R.DotSize),
		BackgroundColor3 = UITheme.Colors.Current,
		BorderSizePixel = 0,
		Parent = holder,
	})
	Create.Corner(dot, UITheme.CornerPill)
	Create.Stroke(dot, UITheme.Colors.Overlay, 1, R.ShadowTransparency)
	reticle = holder
end

local function rotate(deltaYawDeg: number, deltaPitchDeg: number)
	-- While locked on, the target owns the yaw (sideways flicks switch targets instead).
	if lookOverride == nil then
		yaw -= math.rad(deltaYawDeg)
	end
	pitch = math.clamp(pitch - math.rad(deltaPitchDeg), math.rad(C.PitchMin), math.rad(C.PitchMax))
end

local function setZoom(distance: number)
	zoomTarget = math.clamp(distance, C.MinDistance, C.MaxDistance)
end

local function setFade(alpha: number)
	local model = character
	if not model then
		return
	end
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") or part:IsA("Decal") then
			(part :: any).LocalTransparencyModifier = alpha
		end
	end
end

local function bindCharacter(newCharacter: Model)
	character = newCharacter
	humanoid = newCharacter:WaitForChild("Humanoid", 10) :: Humanoid?
	root = newCharacter:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	raycastParams.FilterDescendantsInstances = { newCharacter }
	focus = nil
	trauma = 0
	lastFade = 0
	dipSpring:Reset(Vector3.zero)
	local rootPart = root
	if rootPart then
		-- Start behind the character, looking where it faces.
		local look = rootPart.CFrame.LookVector
		yaw = math.atan2(-look.X, -look.Z)
	end
	local hum = humanoid
	if hum then
		hum.StateChanged:Connect(function(_old: Enum.HumanoidStateType, new: Enum.HumanoidStateType)
			if new == Enum.HumanoidStateType.Freefall then
				lastFallSpeed = 0
			elseif new == Enum.HumanoidStateType.Landed then
				if lastFallSpeed >= C.LandingMinFallSpeed and not reducedMotion() then
					local strength = math.min(lastFallSpeed / C.LandingMinFallSpeed, 2.5)
					-- A downward kick that springs back: the camera "lands" too.
					dipSpring:Impulse(Vector3.new(-C.LandingDip * strength, 0, 0))
				end
			end
		end)
	end
end

-- PUBLIC API -----------------------------------------------------------------

-- Adds camera shake (0..1). Stacks up to 1; decays over time.
function CameraController.Shake(intensity: number)
	if reducedMotion() then
		return
	end
	local scale = setting("CameraShake", 1)
	trauma = math.min(1, trauma + intensity * (if type(scale) == "number" then scale else 1))
end

-- A quick FOV kick (degrees) that springs back: Confluences and big impacts.
function CameraController.Punch(degrees: number)
	if reducedMotion() then
		return
	end
	punch = math.max(punch, degrees)
end

-- Horizontal look direction (used by movement-relative systems and lock-on).
function CameraController.GetYaw(): number
	return yaw
end

-- Lock-on: steer the camera toward a world point (nil releases it).
function CameraController.SetTargetLook(point: Vector3?)
	lookOverride = point
end

-- Scripted camera: while set, `source(dt)` returns the camera CFrame and field of view each
-- frame and look input is ignored. nil hands the camera back, blending from the last scripted
-- frame to the gameplay view over `blend` seconds.
function CameraController.SetCinematic(source: ((dt: number) -> (CFrame, number))?, blend: number?)
	local previous = cinematic
	cinematic = source
	blendLeft = 0
	if source == nil and previous ~= nil and cinematicLast ~= nil then
		blendTotal = math.max(0, blend or 0)
		blendLeft = blendTotal
	end
end

function CameraController.IsCinematic(): boolean
	return cinematic ~= nil
end

-- STEP -----------------------------------------------------------------------

local function step(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	updateMouse()

	local source = cinematic
	if source then
		local shot, shotFov = source(dt)
		cinematicLast = shot
		cinematicFov = shotFov
		camera.CFrame = shot
		camera.Focus = shot
		camera.FieldOfView = shotFov
		return
	end

	-- Look input.
	if gameplayActive() then
		if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
			local delta = UserInputService:GetMouseDelta()
			local k = C.MouseDegreesPerPixel * sensitivity()
			rotate(delta.X * k, delta.Y * k)
		end
		if gamepadLook.Magnitude > C.GamepadDeadzone then
			local k = C.GamepadDegreesPerSecond * sensitivity() * dt
			-- Square the stick for fine aim near the centre.
			local x = gamepadLook.X * math.abs(gamepadLook.X)
			local y = gamepadLook.Y * math.abs(gamepadLook.Y)
			rotate(x * k, -y * k)
		end
	end

	local rootPart = root
	if not rootPart or not rootPart.Parent then
		return
	end

	-- Track fall speed for landing dips.
	local vy = rootPart.AssemblyLinearVelocity.Y
	if vy < 0 then
		lastFallSpeed = math.max(lastFallSpeed, -vy)
	end

	-- Lock-on steering (smoothly turn toward the target).
	local override = lookOverride
	if override then
		local toTarget = override - rootPart.Position
		local flat = MathUtil.FlatUnit(toTarget)
		if flat.Magnitude > 0 then
			local targetYaw = math.atan2(-flat.X, -flat.Z)
			local diff = (targetYaw - yaw + math.pi) % (2 * math.pi) - math.pi
			yaw += diff * math.min(1, dt * C.LockOnTurnSpeed)
		end
	end

	-- Smoothed focus point at shoulder height.
	local desiredFocus = rootPart.Position + Vector3.new(0, C.ShoulderOffset.Y, 0)
	local current = focus
	if current == nil or (current - desiredFocus).Magnitude > C.FocusSnapDistance then
		current = desiredFocus
	end
	local newFocus = MathUtil.ExpDecayVector3(current :: Vector3, desiredFocus, C.FollowSpeed, dt)
	focus = newFocus

	-- Zoom smoothing and shoulder side.
	zoom = MathUtil.ExpDecay(zoom, zoomTarget, C.ZoomSmoothing, dt)
	sideSpring.Target = Vector3.new(if setting("ShoulderSide", "Right") == "Left" then -1 else 1, 0, 0)
	local side = sideSpring:Update(dt).X

	local dip = dipSpring:Update(dt).X
	local rotation = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
	local offset = rotation:VectorToWorldSpace(Vector3.new(C.ShoulderOffset.X * side, 0, zoom))

	-- Pull in against walls (spherecast from the focus to the camera spot).
	local wanted = offset.Magnitude
	local distance = wanted
	local hit = Workspace:Spherecast(newFocus, C.CollisionRadius, offset, raycastParams)
	if hit then
		distance = math.max(0.5, hit.Distance)
	end
	-- Snap in instantly when blocked, ease back out when clear.
	if distance < currentDistance then
		currentDistance = distance
	else
		currentDistance = MathUtil.ExpDecay(currentDistance, distance, C.CollisionEaseOut, dt)
	end
	local position = newFocus + offset.Unit * currentDistance + Vector3.new(0, dip, 0)

	-- Trauma shake: small rotation noise, squared for a natural falloff.
	local shake = CFrame.identity
	if trauma > 0 then
		local amount = trauma * trauma * math.rad(C.ShakeMaxDegrees)
		local t = os.clock() * C.ShakeFrequency
		shake = CFrame.Angles(
			math.noise(shakeSeed, t) * amount,
			math.noise(shakeSeed + 10, t) * amount,
			math.noise(shakeSeed + 20, t) * amount * 0.5
		)
		trauma = math.max(0, trauma - C.ShakeDecay * dt)
	end

	camera.CFrame = CFrame.new(position) * rotation * shake
	camera.Focus = CFrame.new(newFocus)

	-- FOV: wider while sprinting.
	local sprinting = player:GetAttribute(A.Sprinting) == true or CameraController.PredictedSprint
	local targetFov = if sprinting and not reducedMotion() then C.SprintFieldOfView else C.FieldOfView
	fov = MathUtil.ExpDecay(fov, targetFov, C.FovSpeed, dt)
	punch = MathUtil.ExpDecay(punch, 0, C.PunchRecovery, dt)
	camera.FieldOfView = fov + punch

	-- Hand-back from a scripted shot: ease from its last frame into the gameplay view.
	local last = cinematicLast
	if blendLeft > 0 and last then
		blendLeft = math.max(0, blendLeft - dt)
		local alpha = if blendTotal > 0 then 1 - blendLeft / blendTotal else 1
		local eased = alpha * alpha * (3 - 2 * alpha)
		camera.CFrame = last:Lerp(camera.CFrame, eased)
		camera.FieldOfView = cinematicFov + (camera.FieldOfView - cinematicFov) * eased
	end

	-- Fade the character when the camera is jammed against it.
	local closeness = (position - newFocus).Magnitude
	local fade = if closeness < C.FadeDistance then math.clamp(1 - (closeness - 1) / (C.FadeDistance - 1), 0, C.MaxFade) else 0
	if math.abs(fade - lastFade) > 0.02 or (fade == 0 and lastFade ~= 0) then
		lastFade = fade
		setFade(fade)
	end
end

-- INPUT ----------------------------------------------------------------------

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if input.UserInputType == Enum.UserInputType.Touch and not gameProcessed then
		cameraTouches[input] = Vector2.new(input.Position.X, input.Position.Y)
	end
end

local function onInputChanged(input: InputObject, gameProcessed: boolean)
	local inputType = input.UserInputType
	if inputType == Enum.UserInputType.MouseWheel then
		if not gameProcessed and gameplayActive() then
			setZoom(zoomTarget - input.Position.Z * C.ZoomStep)
		end
	elseif inputType == Enum.UserInputType.Gamepad1 and input.KeyCode == Enum.KeyCode.Thumbstick2 then
		gamepadLook = Vector2.new(input.Position.X, input.Position.Y)
	elseif inputType == Enum.UserInputType.Touch then
		local last = cameraTouches[input]
		if not last then
			return
		end
		local position = Vector2.new(input.Position.X, input.Position.Y)
		cameraTouches[input] = position
		local count = 0
		local points: { Vector2 } = {}
		for _, point in cameraTouches do
			count += 1
			table.insert(points, point)
		end
		if count == 1 then
			if gameplayActive() then
				local delta = position - last
				local k = C.TouchDegreesPerPixel * sensitivity()
				rotate(delta.X * k, delta.Y * k)
			end
			pinchDistance = nil
		elseif count == 2 then
			local distance = (points[1] - points[2]).Magnitude
			local previous = pinchDistance
			if previous then
				setZoom(zoomTarget - (distance - previous) * C.PinchZoomSpeed)
			end
			pinchDistance = distance
		end
	end
end

local function onInputEnded(input: InputObject)
	if cameraTouches[input] then
		cameraTouches[input] = nil
		pinchDistance = nil
	end
	if input.KeyCode == Enum.KeyCode.Thumbstick2 then
		gamepadLook = Vector2.zero
	end
end

function CameraController.Init()
	InputController.ActionBegan:Connect(function(action: string)
		if action == "FreeCursor" then
			freeCursorHeld = true
		end
	end)
	InputController.ActionEnded:Connect(function(action: string)
		if action == "FreeCursor" then
			freeCursorHeld = false
		end
	end)
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputChanged:Connect(onInputChanged)
	UserInputService.InputEnded:Connect(onInputEnded)
end

function CameraController.Start()
	buildReticle()
	player.CharacterAdded:Connect(bindCharacter)
	if player.Character then
		task.spawn(bindCharacter, player.Character)
	end
	RunService:BindToRenderStep("SpireCamera", Enum.RenderPriority.Camera.Value + 1, step)
end

return CameraController
