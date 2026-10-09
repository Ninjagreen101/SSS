--!strict
--[[
	CharacterController
	Local movement feel: sprint input per device and predicted walk speed.

	Sprint input:
	  Keyboard: hold Sprint (Left Shift).
	  Gamepad:  click Sprint (L3) to toggle; it switches off after standing
	            still for SprintToggleStopDelay.
	  Touch:    with the Auto Sprint setting on, pushing the move stick past
	            AutoSprintThreshold sprints.

	The client owns its character's physics, so it sets WalkSpeed itself for
	instant response (walk / sprint / winded). The server is still the
	authority: it receives only the sprint *intent* (RequestSprint), drains
	stamina, decides Winded, and AntiExploitService rejects any speed faster
	than a legal sprint.

	Combat hooks:
	  SetActionOverride({ SpeedMultiplier?, Speed?, Direction?, Face? })
	      CombatController drives movement during actions: slowed swings,
	      the dodge roll (forced direction and speed), facing the aim.
	  SetLockTarget(position?)
	      LockOnController: while locked, the character faces the target
	      and strafes instead of turning to run.
	  The character's CombatState attribute (Staggered / Broken) slows or
	  roots the character on its own.

	Sprint animation: while sprinting on the ground, a looping sprint clip
	plays over Roblox's default run, sped up or slowed to match real speed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)

local DataController = require(script.Parent.DataController)
local InputController = require(script.Parent.InputController)
local CameraController = require(script.Parent.CameraController)

local A = Attributes.Names
local player = Players.LocalPlayer

local CharacterController = {}

export type ActionOverride = {
	SpeedMultiplier: number?, -- fraction of walk speed
	Speed: number?, -- absolute studs/s (dodge roll)
	Direction: Vector3?, -- forced move direction (dodge roll)
	Face: Vector3?, -- horizontal direction the character must face
}

local actionOverride: ActionOverride? = nil
local lockTarget: Vector3? = nil
local align: AlignOrientation? = nil

local humanoid: Humanoid? = nil
local controls: any = nil
local sprintHeld = false
local sprintToggled = false
local stillSince: number? = nil
local sentIntent = false
local lastSent = 0
local sprintTrack: AnimationTrack? = nil

local function moveMagnitude(): number
	if controls then
		local ok, vector = pcall(function()
			return controls:GetMoveVector()
		end)
		if ok and typeof(vector) == "Vector3" then
			return math.min(1, vector.Magnitude)
		end
	end
	local hum = humanoid
	return if hum then hum.MoveDirection.Magnitude else 0
end

local function autoSprint(magnitude: number): boolean
	return InputController.GetDevice() == "Touch"
		and DataController.GetSetting("AutoSprint") ~= false
		and magnitude >= Config.Input.AutoSprintThreshold
end

local function sendIntent(intent: boolean)
	local now = os.clock()
	if intent == sentIntent or now - lastSent < Config.Input.SprintSendInterval then
		return
	end
	sentIntent = intent
	lastSent = now
	Net.FireServer("RequestSprint", intent)
end

-- SPRINT ANIMATION -------------------------------------------------------------

local function loadSprintTrack(hum: Humanoid)
	local id = Config.Assets.Animations.Movement.Sprint
	if type(id) ~= "string" or id == "" then
		return
	end
	local animator = hum:WaitForChild("Animator", 10)
	if not animator or not animator:IsA("Animator") then
		return
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = if string.find(id, "rbxassetid://", 1, true) then id else `rbxassetid://{id}`
	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	-- The character may have respawned while the animation loaded.
	if ok and humanoid == hum then
		track.Priority = Enum.AnimationPriority.Movement
		track.Looped = true
		sprintTrack = track
	end
end

local function stopSprintAnimation()
	local track = sprintTrack
	if track and track.IsPlaying then
		track:Stop(Config.Combat.Movement.SprintAnimation.FadeTime)
	end
end

local function updateSprintAnimation(hum: Humanoid, running: boolean)
	local track = sprintTrack
	if not track then
		return
	end
	local tuning = Config.Combat.Movement.SprintAnimation
	local root = hum.RootPart
	local velocity = if root then root.AssemblyLinearVelocity else Vector3.zero
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local grounded = hum.FloorMaterial ~= Enum.Material.Air
	if running and grounded and speed >= Config.Combat.Movement.WalkSpeed * tuning.MinSpeedFraction then
		local rate = math.clamp(speed / tuning.NaturalSpeed, tuning.MinRate, tuning.MaxRate)
		if track.IsPlaying then
			track:AdjustSpeed(rate)
		else
			track:Play(tuning.FadeTime, 1, rate)
		end
	else
		stopSprintAnimation()
	end
end

local function step()
	local hum = humanoid
	if not hum or hum.Health <= 0 then
		CameraController.PredictedSprint = false
		stopSprintAnimation()
		return
	end
	local magnitude = moveMagnitude()
	local moving = magnitude > Config.Input.MoveDeadzone

	-- Gamepad toggle ends after standing still for a moment.
	if sprintToggled then
		if moving then
			stillSince = nil
		else
			local since = stillSince or os.clock()
			stillSince = since
			if os.clock() - since >= Config.Input.SprintToggleStopDelay then
				sprintToggled = false
				stillSince = nil
			end
		end
	end

	local override = actionOverride
	local combatState = hum.Parent and (hum.Parent :: Instance):GetAttribute(A.CombatState)
	local acting = override ~= nil or combatState == "Staggered" or combatState == "Broken"
	local intent = (sprintHeld or sprintToggled or autoSprint(magnitude)) and not acting
	sendIntent(intent)

	local winded = player:GetAttribute(A.Winded) == true
	local locked = player:GetAttribute(A.SprintLocked) == true
	local stamina = player:GetAttribute(A.Stamina)
	local hasStamina = type(stamina) ~= "number" or stamina > 0
	-- Overburdened (bag over carry weight): no sprint, slower walk.
	local burdened = player:GetAttribute(A.Overburdened) == true
	local sprinting = intent and moving and hasStamina and not winded and not locked and not burdened

	local movement = Config.Combat.Movement
	local speed = if winded
		then movement.WalkSpeed * Config.Combat.Stamina.WindedWalkSpeedMultiplier
		elseif sprinting then movement.SprintSpeed
		elseif burdened then movement.WalkSpeed * Config.Items.Inventory.OverburdenedWalkMultiplier
		else movement.WalkSpeed
	-- SpeedBonus (server-written: Position tree, Windstep): faster feet.
	local bonus = player:GetAttribute(A.SpeedBonus)
	if type(bonus) == "number" and bonus > 0 then
		speed *= 1 + bonus
	end
	local actionMove = Config.Combat.ActionMove
	if combatState == "Broken" then
		speed = movement.WalkSpeed * actionMove.Broken
	elseif combatState == "Staggered" then
		speed = movement.WalkSpeed * actionMove.Staggered
	elseif override then
		if override.Speed then
			speed = override.Speed
		elseif override.SpeedMultiplier then
			speed = math.min(speed, movement.WalkSpeed * override.SpeedMultiplier)
		end
	elseif combatState == "Blocking" then
		speed = movement.WalkSpeed * Config.Combat.Block.WalkSpeedMultiplier
	end
	if hum.WalkSpeed ~= speed then
		hum.WalkSpeed = speed
	end
	-- Forced movement (dodge roll) replaces stick/keys this frame. This runs
	-- after Roblox's ControlModule, so our Move call wins.
	if override and override.Direction then
		hum:Move(override.Direction, false)
	end

	-- Facing: an action's facing beats lock-on; otherwise turn toward movement.
	local face: Vector3? = if override then override.Face else nil
	local root = hum.RootPart
	local target = lockTarget
	if not face and target and root then
		local toTarget = target - root.Position
		face = Vector3.new(toTarget.X, 0, toTarget.Z)
	end
	local orientation = align
	if face and face.Magnitude > 0.05 and root and orientation then
		hum.AutoRotate = false
		orientation.Enabled = true
		orientation.CFrame = CFrame.lookAt(Vector3.zero, Vector3.new(face.X, 0, face.Z))
	else
		hum.AutoRotate = true
		if orientation then
			orientation.Enabled = false
		end
	end
	CameraController.PredictedSprint = sprinting and not acting
	updateSprintAnimation(hum, sprinting and not acting)
end

local function bindCharacter(character: Model)
	humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	sprintTrack = nil
	local hum = humanoid
	if hum then
		task.spawn(loadSprintTrack, hum)
	end
	sprintToggled = false
	stillSince = nil
	actionOverride = nil
	align = nil
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if root and root:IsA("BasePart") then
		-- Turns the character to face a direction without fighting physics.
		local attachment = Instance.new("Attachment")
		attachment.Name = "FacingAttachment"
		attachment.Parent = root
		local orientation = Instance.new("AlignOrientation")
		orientation.Name = "Facing"
		orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
		orientation.Attachment0 = attachment
		orientation.Responsiveness = Config.Combat.FacingResponsiveness
		orientation.MaxTorque = math.huge
		orientation.Enabled = false
		orientation.Parent = root
		align = orientation
	end
end

-- PUBLIC API -----------------------------------------------------------------

function CharacterController.SetActionOverride(override: ActionOverride?)
	actionOverride = override
end

function CharacterController.SetLockTarget(position: Vector3?)
	lockTarget = position
end

function CharacterController.Init()
	InputController.ActionBegan:Connect(function(action: string, device: string)
		if action ~= "Sprint" then
			return
		end
		if device == "Gamepad" then
			sprintToggled = not sprintToggled
			stillSince = nil
		else
			sprintHeld = true
		end
	end)
	InputController.ActionEnded:Connect(function(action: string)
		if action == "Sprint" then
			sprintHeld = false
		end
	end)
	-- Leaving gameplay (menu opened) cancels a toggled sprint.
	InputController.ContextChanged:Connect(function(context: string)
		if context ~= "Gameplay" then
			sprintToggled = false
		end
	end)
end

function CharacterController.Start()
	task.spawn(function()
		local playerScripts = player:WaitForChild("PlayerScripts")
		local module = playerScripts:WaitForChild("PlayerModule", 10)
		if module and module:IsA("ModuleScript") then
			local ok, playerModule = pcall(require, module)
			if ok and type(playerModule) == "table" then
				controls = (playerModule :: any):GetControls()
			end
		end
	end)
	player.CharacterAdded:Connect(bindCharacter)
	if player.Character then
		task.spawn(bindCharacter, player.Character)
	end
	-- Runs after input, before physics.
	RunService:BindToRenderStep("SpireCharacter", Enum.RenderPriority.Input.Value + 1, step)
end

return CharacterController
