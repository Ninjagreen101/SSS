--!strict
--[[
	ArtController
	The Weapon Art button on the client (R / LT+RT / the glowing ART button):

	  Tap  -> RequestWeaponArt with the aim. The server decides between the
	          weapon's Art and, at full Resonance, its Confluence
	          (SpellController.ArtMode shows which on the bar). The move is
	          predicted at once: animation, facing, and the caster's own motion
	          for Dash / Leap steps (the server checks the path and hits).
	  Hold -> after Infusion.HoldTime, RequestInfuse (the bar's Art slot fills
	          while held; the blade glows in the element's colour after).

	The caster's client plays the animation (Config.Assets.Animations.Arts /
	.Confluences, or the move's sword clip until uploaded), which replicates
	to everyone. A rejection (cooldown, Current, busy) cancels the prediction.
	Confluences also punch the camera (CameraController.Punch).

	The Position ability key (B / LT+RB / the SKILL button, Phase 8) works
	the same way: RequestAbility with the aim, predicted locally from
	Shared/Data/Abilities, cooldown from the AbilityReadyAt attribute.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Arts = require(Shared.Data.Arts)
local Confluences = require(Shared.Data.Confluences)
local Moves = require(Shared.Data.Moves)
local Abilities = require(Shared.Data.Abilities)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Components = require(UI.Components)

local InputController = require(script.Parent.InputController)
local CharacterController = require(script.Parent.CharacterController)
local LockOnController = require(script.Parent.LockOnController)
local CameraController = require(script.Parent.CameraController)
local SpellController = require(script.Parent.SpellController)
local DataController = require(script.Parent.DataController)

local A = Attributes.Names
local C = Config.Current
local player = Players.LocalPlayer

local ArtController = {}

local HOLD_SHOW_AFTER = 0.12 -- seconds before the hold fill appears (taps don't flicker it)

local holdStarted: number? = nil
local infusedThisHold = false
local tracks: { [string]: AnimationTrack } = {}
local playing: AnimationTrack? = nil
local infuseTrack: AnimationTrack? = nil
local moveToken = 0
local predictedAt = 0
local predictedKind = ""

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function rootPart(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function flatten(v: Vector3): Vector3?
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 0.05 then f.Unit else nil
end

-- Same aim rules as sword swings: lock-on, then camera (mouse), then movement.
local function aim(): Vector3
	local root = rootPart()
	local target = LockOnController.GetTarget()
	local targetRoot = target and target:FindFirstChild("HumanoidRootPart")
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
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local moving = flatten(humanoid.MoveDirection)
		if moving then
			return moving
		end
	end
	if root then
		return flatten(root.CFrame.LookVector) or Vector3.new(0, 0, -1)
	end
	return Vector3.new(0, 0, -1)
end

-- ANIMATION ----------------------------------------------------------------------

local function slotClip(path: string): string?
	local group, slot = string.match(path, "^(%w+)%.(%w+)$")
	local animations = Config.Assets.Animations :: any
	if group and slot and animations[group] then
		local id = animations[group][slot]
		if type(id) == "string" and id ~= "" then
			return id
		end
	end
	return nil
end

-- The clip for an animation slot path ("Arts.Longsword"), and whether it is
-- the slot's own clip (true) or the fallback (false). A fallback is a sword
-- clip name ("Light3") or another slot path ("Casting.Cast2H").
local function idFor(path: string, fallback: string): (string?, boolean)
	local own = slotClip(path)
	if own then
		return own, true
	end
	local animations = Config.Assets.Animations :: any
	local id = slotClip(fallback) or animations.Classes.Longsword[fallback] or animations.Common[fallback]
	return if type(id) == "string" and id ~= "" then id else nil, false
end

local function load(id: string): AnimationTrack?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end
	local track = tracks[id]
	if track and track.Parent then
		return track
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = if string.find(id, "rbxasset", 1, true) then id else `rbxassetid://{id}`
	local ok, loaded = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		return nil
	end
	loaded.Priority = Enum.AnimationPriority.Action2
	tracks[id] = loaded
	return loaded
end

local function stopMoveAnimation()
	local track = playing
	playing = nil
	if track then
		track:Stop(0.12)
	end
end

local function playMove(move: Moves.Move)
	stopMoveAnimation()
	local id, own = idFor(move.Animation, move.FallbackAnimation)
	local track = if id then load(id) else nil
	if track then
		track.Looped = false
		-- Own clips are built to the move's exact timing; AnimationSpeed only
		-- retimes the borrowed sword clip.
		track:Play(0.05, 1, if own then 1 else move.AnimationSpeed or 1)
		playing = track
		local token = moveToken
		task.delay(move.Duration, function()
			if moveToken == token and playing == track then
				stopMoveAnimation()
			end
		end)
	end
end

-- PREDICTION ---------------------------------------------------------------------

local function endMove()
	moveToken += 1
	stopMoveAnimation()
	CharacterController.SetActionOverride(nil)
end

-- Plays a move locally: animation, facing, and the caster's own motion.
local function predict(kind: string, move: Moves.Move, direction: Vector3)
	moveToken += 1
	local token = moveToken
	predictedAt = os.clock()
	predictedKind = kind
	playMove(move)
	CharacterController.SetActionOverride({ SpeedMultiplier = 0.15, Face = direction })
	for _, step in move.Steps do
		if step.Do == "Dash" or step.Do == "Leap" then
			task.delay(step.At, function()
				if moveToken ~= token then
					return
				end
				local duration = math.max(step.Duration or 0.4, 0.05)
				CharacterController.SetActionOverride({
					Speed = (step.Distance or 10) / duration,
					Direction = direction,
					Face = direction,
				})
				local root = rootPart()
				if step.Do == "Leap" and root then
					local height = step.Height or 6
					local up = math.sqrt(2 * Workspace.Gravity * height)
					root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, up, root.AssemblyLinearVelocity.Z)
				end
				task.delay(duration, function()
					if moveToken == token then
						CharacterController.SetActionOverride({ SpeedMultiplier = 0.15, Face = direction })
					end
				end)
			end)
		end
	end
	task.delay(move.Duration, function()
		if moveToken == token then
			CharacterController.SetActionOverride(nil)
		end
	end)
	if kind == "Confluence" then
		CameraController.Punch(Config.Camera.PunchDegrees)
		CameraController.Shake(Config.Camera.ShakeConfluence)
	end
end

local function canAct(): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then
		return false
	end
	local state = character:GetAttribute(A.CombatState)
	return state ~= "Staggered" and state ~= "Broken" and state ~= "Art" and state ~= "Dodging"
end

local function currentAtLeast(amount: number): boolean
	local current = player:GetAttribute(A.Current)
	return type(current) ~= "number" or current >= amount
end

local function noCurrent()
	Components.Toast.Push({ Title = Strings.Toasts.NoCurrent, Color = UITheme.Colors.Danger, Key = "NoCurrent" })
end

local function tap()
	if not canAct() then
		return
	end
	local character = player.Character
	local class = character and character:GetAttribute(A.WeaponClass)
	if type(class) ~= "string" then
		return
	end
	local direction = aim()
	if SpellController.ArtMode() == "Confluence" then
		local primary = player:GetAttribute(A.Attunement)
		local confluence = if type(primary) == "string" then Confluences.Get(class, primary) else nil
		if not confluence then
			return
		end
		if not currentAtLeast(C.Confluence.CurrentCost) then
			noCurrent()
			return
		end
		Net.FireServer("RequestWeaponArt", direction)
		predict("Confluence", confluence.Move, direction)
		return
	end
	local art = Arts.ForClass(class)
	if not art then
		return
	end
	local ready = player:GetAttribute(A.ArtReadyAt)
	if type(ready) == "number" and ready > serverNow() + 0.05 then
		return
	end
	if not currentAtLeast(art.Cost) then
		noCurrent()
		return
	end
	Net.FireServer("RequestWeaponArt", direction)
	predict("Art", art.Move, direction)
end

-- INFUSION HOLD ------------------------------------------------------------------

local function stopInfuseAnimation()
	local track = infuseTrack
	infuseTrack = nil
	if track then
		track:Stop(0.15)
	end
end

local function startInfuseAnimation()
	if infuseTrack then
		return
	end
	local id = idFor("Casting.Infuse", "HeavyCharge")
	local track = if id then load(id) else nil
	if track then
		track.Looped = true
		track:Play(0.15)
		infuseTrack = track
	end
end

local function infuse()
	infusedThisHold = true
	SpellController.SetArtHold(nil)
	stopInfuseAnimation()
	local primary = player:GetAttribute(A.Attunement)
	if type(primary) ~= "string" or primary == "" then
		Components.Toast.Push({ Title = Strings.Toasts.NeedAttunement, Color = UITheme.Colors.Danger, Key = "NeedAttunement" })
		return
	end
	if not currentAtLeast(C.Infusion.Cost) then
		noCurrent()
		return
	end
	Net.FireServer("RequestInfuse")
end

local function step()
	local started = holdStarted
	if not started or infusedThisHold then
		return
	end
	local held = os.clock() - started
	if held >= C.Infusion.HoldTime then
		infuse()
	elseif held >= HOLD_SHOW_AFTER and canAct() then
		SpellController.SetArtHold(held / C.Infusion.HoldTime)
		startInfuseAnimation()
	end
end

-- POSITION ABILITY ---------------------------------------------------------------

local function equippedAbility(): Abilities.AbilityDef?
	local id = DataController.Get({ "Hotbar", "Ability" })
	return if type(id) == "string" and id ~= "" then Abilities.Get(id) else nil
end

local function castAbility()
	local def = equippedAbility()
	if not def then
		Components.Toast.Push({ Title = Strings.Progression.Reasons.NoAbility, Color = UITheme.Colors.Danger, Key = "NoAbility" })
		return
	end
	if not canAct() then
		return
	end
	local ready = player:GetAttribute(A.AbilityReadyAt)
	if type(ready) == "number" and ready > serverNow() + 0.05 then
		local strings = Strings.Abilities[def.Id]
		Components.Toast.Push({
			Title = Strings.Format(Strings.Toasts.AbilityCooldown, { name = if strings then strings.Name else def.Id }),
			Color = UITheme.Colors.TextMuted,
			Key = "AbilityCooldown",
		})
		return
	end
	if not currentAtLeast(def.Cost) then
		noCurrent()
		return
	end
	local direction = aim()
	Net.FireServer("RequestAbility", direction)
	predict("Ability", def.Move, direction)
end

-- SERVER EVENTS ------------------------------------------------------------------

local function onMoveStart(caster: Model, kind: string, key: string, direction: Vector3, _element: string)
	if caster ~= player.Character or typeof(direction) ~= "Vector3" then
		return
	end
	-- The prediction already covers it, unless the server chose the other move.
	if os.clock() - predictedAt < 0.6 and predictedKind == kind then
		return
	end
	local move: Moves.Move? = nil
	if kind == "Confluence" then
		local confluence = Confluences.All()[key]
		move = if confluence then confluence.Move else nil
	elseif kind == "Ability" then
		local ability = Abilities.Get(key)
		move = if ability then ability.Move else nil
	else
		local art = Arts.ForClass(key)
		move = if art then art.Move else nil
	end
	if move then
		predict(kind, move, direction)
	end
end

function ArtController.Init()
	InputController.ActionBegan:Connect(function(action: string)
		if action == "WeaponArt" then
			holdStarted = os.clock()
			infusedThisHold = false
		elseif action == "Ability" then
			castAbility()
		end
	end)
	InputController.ActionEnded:Connect(function(action: string)
		if action ~= "WeaponArt" then
			return
		end
		local held = if holdStarted then os.clock() - holdStarted else 0
		holdStarted = nil
		SpellController.SetArtHold(nil)
		stopInfuseAnimation()
		if not infusedThisHold and held < C.Infusion.HoldTime then
			tap()
		end
		infusedThisHold = false
	end)
	Net.OnClient("ActionRejected", function(action: string, reason: string)
		if action == "WeaponArt" then
			endMove()
		elseif action == "Ability" then
			if predictedKind == "Ability" then
				endMove()
			end
			local text = Strings.Progression.Reasons[reason]
			if text and reason ~= "Busy" then
				Components.Toast.Push({ Title = text, Color = UITheme.Colors.Danger, Key = "AbilityRejected" })
			end
		end
	end)
	Net.OnClient("MoveStart", onMoveStart)
end

function ArtController.Start()
	local function bindCharacter(character: Model)
		table.clear(tracks)
		endMove()
		holdStarted = nil
		-- A stagger ends the move early on the server; stop predicting it too.
		character:GetAttributeChangedSignal(A.CombatState):Connect(function()
			local state = character:GetAttribute(A.CombatState)
			if (state == "Staggered" or state == "Broken") and playing then
				endMove()
			end
		end)
	end
	player.CharacterAdded:Connect(bindCharacter)
	if player.Character then
		task.spawn(bindCharacter, player.Character)
	end
	RunService.RenderStepped:Connect(step)
end

return ArtController
