--!strict
--[[
	CombatController
	Turns combat input into actions, with client-side prediction so combat
	feels instant. The server (CombatService) re-checks everything and sends
	ActionRejected if it disagrees, which cancels the local action.

	Inputs (rebindable): Light Attack, Heavy Attack (hold to charge),
	Dodge, Block (raise to parry).
	- Input buffering: a press during the last BufferFraction of an action
	  is remembered and fires the moment the action ends, so combos chain
	  smoothly without frame-perfect timing.
	- Aim: the lock-on target if any; otherwise the camera direction on
	  mouse, or the movement direction on gamepad/touch.
	- Movement while acting goes through CharacterController overrides:
	  swings slow you and face the aim, the roll moves you on its own.
	- Animations are optional (Config.Assets.Animations). Empty slots are
	  skipped; slash arcs (CombatFeedbackController) show every swing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local Formulas = require(Shared.Data.Formulas)
local Items = require(Shared.Data.Items)

local DataController = require(script.Parent.DataController)
local InputController = require(script.Parent.InputController)
local CharacterController = require(script.Parent.CharacterController)
local LockOnController = require(script.Parent.LockOnController)
local CombatFeedbackController = require(script.Parent.CombatFeedbackController)

local C = Config.Combat
local A = Attributes.Names
local player = Players.LocalPlayer

local CombatController = {}

type LocalAction = "Idle" | "Attacking" | "Heavy" | "Dodging"

local action: LocalAction = "Idle"
local actionStart = 0
local actionEnd = 0
local blowLanded = true -- the current swing's windup has passed
local combo = 0
local lastLightEnd = 0
local buffered: string? = nil
local bufferedAt = 0
local charging = false
local chargeStart = 0
local blockHeld = false
local blockSent = false
local humanoid: Humanoid? = nil
local tracks: { [string]: AnimationTrack } = {}
local looping: { [string]: AnimationTrack } = {}

local BUFFER_LIFETIME = C.Combo.ResetTime -- a buffered press older than this is dropped

-- HELPERS ----------------------------------------------------------------------

local function clock(): number
	return os.clock()
end

local function character(): Model?
	return player.Character
end

local function rootPart(): BasePart?
	local model = character()
	local root = model and model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function combatState(): string?
	local model = character()
	local value = model and model:GetAttribute(A.CombatState)
	return if type(value) == "string" then value else nil
end

local function weapon(): (Items.WeaponDef, any)
	local model = character()
	local id = model and model:GetAttribute(A.WeaponId)
	local def = (type(id) == "string" and Items.GetWeapon(id)) or Items.GetWeapon(Items.DefaultWeapon)
	local weaponDef = def :: Items.WeaponDef
	return weaponDef, C.WeaponClasses[weaponDef.Class]
end

local function attackSpeed(class: any): number
	local finesse = DataController.Get({ "Stats", "Finesse" })
	return Formulas.AttackSpeed(class.AttackSpeed, if type(finesse) == "number" then finesse else 0)
end

local function hasStamina(): boolean
	local stamina = player:GetAttribute(A.Stamina)
	return player:GetAttribute(A.Winded) ~= true and (type(stamina) ~= "number" or stamina > 0)
end

local function flatten(v: Vector3): Vector3?
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 0.05 then f.Unit else nil
end

-- Where the next blow should go.
local function aim(): Vector3
	local root = rootPart()
	local target = LockOnController.GetTarget()
	local targetRoot = target and (target:FindFirstChild("HumanoidRootPart") or target.PrimaryPart)
	if root and targetRoot and targetRoot:IsA("BasePart") then
		local toTarget = flatten(targetRoot.Position - root.Position)
		if toTarget then
			return toTarget
		end
	end
	local camera = Workspace.CurrentCamera
	if InputController.GetDevice() == "KeyboardMouse" and camera then
		local look = flatten(camera.CFrame.LookVector)
		if look then
			return look
		end
	end
	local hum = humanoid
	if hum then
		local moving = flatten(hum.MoveDirection)
		if moving then
			return moving
		end
	end
	if root then
		return flatten(root.CFrame.LookVector) or Vector3.new(0, 0, -1)
	end
	return Vector3.new(0, 0, -1)
end

-- ANIMATIONS -------------------------------------------------------------------

-- Classes without their own animations borrow the Longsword set (retimed
-- in play() so the blow still lands on that class's windup).
local FALLBACK_CLASS = "Longsword"

local function lookup(set: any, slot: string): string?
	local id = set and set[slot]
	return if type(id) == "string" and id ~= "" then id else nil
end

-- Returns the animation id for a slot and whether it was borrowed from the fallback class.
local function animationId(slot: string): (string?, boolean)
	local model = character()
	local className = model and model:GetAttribute(A.WeaponClass)
	local classes = Config.Assets.Animations.Classes :: any
	local id = if type(className) == "string" then lookup(classes[className], slot) else nil
	local borrowed = false
	if not id and className ~= FALLBACK_CLASS then
		id = lookup(classes[FALLBACK_CLASS], slot)
		borrowed = id ~= nil
	end
	id = id or lookup(Config.Assets.Animations.Common, slot)
	if not id then
		return nil, false
	end
	return (if string.find(id, "rbxassetid://", 1, true) then id else `rbxassetid://{id}`), borrowed
end

-- Loads (or reuses) the track for a slot. Returns the track and whether it
-- was borrowed from the fallback class.
local function loadTrack(slot: string): (AnimationTrack?, boolean)
	local hum = humanoid
	local id, borrowed = animationId(slot)
	if not hum or not id then
		return nil, false
	end
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		return nil, false
	end
	local key = `{slot}:{id}`
	local track = tracks[key]
	if not track then
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local ok, loaded = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if not ok then
			return nil, false
		end
		track = loaded
		tracks[key] = loaded
	end
	return track, borrowed
end

-- Animations download the first time they're loaded, and a track played
-- before its download finishes shows nothing. Loading every slot as soon as
-- the character (or weapon class) is ready means the first swing is visible.
local PRELOAD_SLOTS = { "Light1", "Light2", "Light3", "Light4", "Light5", "Heavy", "HeavyCharge", "Dodge", "Block", "Parry", "Hurt", "Broken" }
local function preloadAnimations()
	local hum = humanoid
	if not hum or not hum:WaitForChild("Animator", 10) then
		return
	end
	for _, slot in PRELOAD_SLOTS do
		loadTrack(slot)
	end
end

-- `phase` ("Light" / "Heavy") lets a borrowed swing be sped up or slowed so
-- its moment of contact matches this weapon class's windup.
local function play(slot: string, speed: number?, loop: boolean?, phase: string?): AnimationTrack?
	local track, borrowed = loadTrack(slot)
	if not track then
		return nil
	end
	if borrowed and phase then
		local _, class = weapon()
		local own = class[phase]
		local source = (C.WeaponClasses :: any)[FALLBACK_CLASS][phase]
		speed = (speed or 1) * source.Windup / own.Windup
	end
	local t = track :: AnimationTrack
	t.Priority = Enum.AnimationPriority.Action
	t.Looped = loop == true
	t:Play(0.05, 1, speed or 1)
	if loop then
		looping[slot] = t
	end
	return t
end

local function stopLoop(slot: string)
	local track = looping[slot]
	looping[slot] = nil
	if track then
		track:Stop(0.1)
	end
end

local function stopActionAnimations()
	for _, track in tracks do
		if track.IsPlaying and not track.Looped then
			track:Stop(0.08)
		end
	end
end

-- ACTION STATE -----------------------------------------------------------------

local function setAction(newAction: LocalAction, duration: number, override: CharacterController.ActionOverride?)
	action = newAction
	actionStart = clock()
	actionEnd = actionStart + duration
	CharacterController.SetActionOverride(override)
end

local function blockOverride(): CharacterController.ActionOverride?
	return if blockHeld then { SpeedMultiplier = C.Block.WalkSpeedMultiplier } else nil
end

local function endAction()
	action = "Idle"
	blowLanded = true
	CharacterController.SetActionOverride(blockOverride())
end

local function cancelAll()
	charging = false
	buffered = nil
	stopLoop("HeavyCharge")
	stopActionAnimations()
	endAction()
end

local function canAct(): boolean
	local hum = humanoid
	if not hum or hum.Health <= 0 or charging then
		return false
	end
	local state = combatState()
	-- The server runs Weapon Arts, Confluences and spell casts as their own
	-- actions; the client doesn't start a swing over them.
	if state == "Staggered" or state == "Broken" or state == "Art" or state == "Casting" then
		return false
	end
	return action == "Idle" or clock() >= actionEnd
end

-- True if a press now may be buffered for when the current action ends.
local function canBuffer(): boolean
	if action == "Idle" or charging then
		return false
	end
	local total = actionEnd - actionStart
	return actionEnd - clock() <= total * C.Combo.BufferFraction
end

-- ACTIONS ----------------------------------------------------------------------

local function light()
	local _, class = weapon()
	local now = clock()
	local thrust = class.DodgeCancelThrust == true and action == "Dodging"
	if not thrust and not canAct() then
		if canBuffer() then
			buffered = "Light"
			bufferedAt = now
		end
		return
	end
	if not hasStamina() then
		return
	end
	combo = if now - lastLightEnd <= C.Combo.ResetTime then combo % class.ComboLength + 1 else 1
	local speed = attackSpeed(class)
	local windup = class.Light.Windup / speed
	local total = windup + class.Light.Recovery / speed
	local direction = aim()
	Net.FireServer("RequestAttack", combo, direction)
	blockSent = false
	setAction("Attacking", total, { SpeedMultiplier = C.ActionMove.Attacking, Face = direction })
	lastLightEnd = now + total
	blowLanded = false
	play(`Light{combo}`, speed, false, "Light")
	local model = character()
	local reach = class.Reach + (if thrust then class.ThrustReachBonus or 0 else 0)
	task.delay(windup, function()
		blowLanded = true
		if model and model.Parent and action ~= "Idle" then
			CombatFeedbackController.DrawSlash(model, direction, reach, class.Arc, if thrust then "Thrust" else "Light")
		end
	end)
end

local function startCharge()
	if not canAct() then
		if canBuffer() then
			buffered = "Heavy"
			bufferedAt = clock()
		end
		return
	end
	if not hasStamina() then
		return
	end
	charging = true
	chargeStart = clock()
	blockSent = false
	CharacterController.SetActionOverride({ SpeedMultiplier = C.Heavy.ChargeMoveMultiplier, Face = aim() })
	play("HeavyCharge", 1, true)
end

local function releaseHeavy()
	if not charging then
		return
	end
	charging = false
	stopLoop("HeavyCharge")
	local _, class = weapon()
	local held = clock() - chargeStart
	local speed = attackSpeed(class)
	local windup = class.Heavy.Windup / speed
	local total = windup + class.Heavy.Recovery / speed
	local direction = aim()
	Net.FireServer("RequestHeavyAttack", math.min(held, C.Heavy.MaxCharge), direction)
	setAction("Heavy", total, { SpeedMultiplier = C.ActionMove.Attacking, Face = direction })
	combo = 0
	blowLanded = false
	play("Heavy", speed, false, "Heavy")
	local kind = if held >= C.Heavy.ChargeTime then "Charged" else "Heavy"
	local model = character()
	task.delay(windup, function()
		blowLanded = true
		if model and model.Parent and action ~= "Idle" then
			CombatFeedbackController.DrawSlash(model, direction, class.Reach, class.Arc, kind)
		end
	end)
end

local function dodge()
	local hum = humanoid
	local root = rootPart()
	if not hum or not root then
		return
	end
	local state = combatState()
	-- A swing whose blow already landed can be cancelled into a roll.
	local cancelRecovery = (action == "Attacking" or action == "Heavy") and blowLanded
	if state == "Staggered" or state == "Broken" or charging or action == "Dodging"
		or (not canAct() and not cancelRecovery) then
		if canBuffer() then
			buffered = "Dodge"
			bufferedAt = clock()
		end
		return
	end
	if not hasStamina() then
		return
	end
	-- Roll where you're moving; with no input, hop backwards.
	local direction = flatten(hum.MoveDirection) or -(flatten(root.CFrame.LookVector) or Vector3.new(0, 0, -1))
	Net.FireServer("RequestDodge", direction)
	blockSent = false
	stopActionAnimations()
	setAction("Dodging", C.Dodge.Duration, {
		Speed = C.Dodge.Distance / C.Dodge.Duration,
		Direction = direction,
		Face = direction,
	})
	play("Dodge")
end

local function raiseBlock()
	if blockSent or not canAct() then
		return
	end
	blockSent = true
	Net.FireServer("RequestBlock", true, InputController.GetDevice() == "Touch")
	CharacterController.SetActionOverride(blockOverride())
	play("Block", 1, true)
end

local function lowerBlock()
	if blockSent then
		Net.FireServer("RequestBlock", false, false)
	end
	blockSent = false
	stopLoop("Block")
	if action == "Idle" then
		CharacterController.SetActionOverride(nil)
	end
end

-- LOOP -------------------------------------------------------------------------

local function step()
	local hum = humanoid
	if not hum or hum.Health <= 0 then
		return
	end
	local now = clock()
	if action ~= "Idle" and now >= actionEnd then
		endAction()
	end
	-- Charged heavies release on their own at the cap.
	if charging then
		if now - chargeStart >= C.Heavy.MaxCharge then
			releaseHeavy()
		else
			CharacterController.SetActionOverride({ SpeedMultiplier = C.Heavy.ChargeMoveMultiplier, Face = aim() })
		end
	end
	-- Fire a buffered press as soon as we're free.
	local pending = buffered
	if pending and canAct() then
		buffered = nil
		if now - bufferedAt <= BUFFER_LIFETIME then
			if pending == "Light" then
				light()
			elseif pending == "Heavy" then
				startCharge()
				if not InputController.IsDown("HeavyAttack") then
					releaseHeavy()
				end
			elseif pending == "Dodge" then
				dodge()
			end
		end
	end
	-- Holding block through an action raises the guard once it ends.
	if blockHeld and not blockSent and action == "Idle" and canAct() then
		raiseBlock()
	end
end

local function bindCharacter(model: Model)
	humanoid = model:WaitForChild("Humanoid", 10) :: Humanoid?
	table.clear(tracks)
	table.clear(looping)
	action = "Idle"
	charging = false
	buffered = nil
	blockSent = false
	combo = 0
	CharacterController.SetActionOverride(nil)
	task.spawn(preloadAnimations)
	model:GetAttributeChangedSignal(A.WeaponClass):Connect(preloadAnimations)
	model:GetAttributeChangedSignal(A.CombatState):Connect(function()
		local state = model:GetAttribute(A.CombatState)
		if state == "Staggered" or state == "Broken" then
			cancelAll()
			blockSent = false
			stopLoop("Block")
			play(if state == "Broken" then "Broken" else "Hurt")
		end
	end)
end

function CombatController.Init()
	InputController.ActionBegan:Connect(function(name: string)
		if name == "LightAttack" then
			light()
		elseif name == "HeavyAttack" then
			startCharge()
		elseif name == "Dodge" then
			dodge()
		elseif name == "Block" then
			blockHeld = true
			raiseBlock()
		end
	end)
	InputController.ActionEnded:Connect(function(name: string)
		if name == "HeavyAttack" then
			releaseHeavy()
		elseif name == "Block" then
			blockHeld = false
			lowerBlock()
		end
	end)
	Net.OnClient("ActionRejected", function(_name: string, _reason: string)
		cancelAll()
	end)
	-- Losing window focus mid-charge must not leave the charge running.
	UserInputService.WindowFocusReleased:Connect(function()
		if charging then
			releaseHeavy()
		end
	end)
end

function CombatController.Start()
	player.CharacterAdded:Connect(bindCharacter)
	if player.Character then
		task.spawn(bindCharacter, player.Character)
	end
	RunService:BindToRenderStep("SpireCombat", Enum.RenderPriority.Input.Value + 2, step)
end

return CombatController
