--!strict
--[[
	SpellController
	The player's side of the Current: the spell bar, casting, and the
	Attunement Shrine picker. The server decides everything; this only aims,
	predicts and draws.

	Casting (Cast1-4: keys 1-4, D-pad, the I-IV touch buttons)
	  Aim: the lock-on target if locked; on touch the nearest enemy within
	  Casting.MobileAutoTargetConeDegrees of where you face; otherwise the
	  point under the centre of the camera (up to MaxCastRange).
	  Quick cast (default): pressing the key casts at once.
	  Aimed cast (Settings): holding the key shows a reticle in the
	  Attunement's colour (a line, cone, ground circle or blink arrow) and a
	  centre dot; releasing casts there, rolling cancels. Ward casts on press.
	  Charged spells (Lance) always charge while held: RequestChargeCast
	  starts the charge on the server, releasing (or reaching Charge.Max)
	  fires it. The server measures the charge itself.
	  The cast animation plays (Config.Assets.Animations.Casting, or the
	  Form's sword clip until it's uploaded), the character slows and faces
	  the aim, and RequestCast goes to the server. If the server refuses, the
	  local cooldown is undone and a short message shows. SpellCooldowns from
	  the server (Arcblade hits) correct the local cooldowns.

	Spell bar (bottom centre)
	  Four slots from Hotbar.Spells: the Form's name in its Attunement's
	  colour, the key, the Current cost, a cooldown sweep, and greyed out
	  while you lack the Current. A fifth slot is the Weapon Art: the Art's
	  name and cost, its cooldown, an Infusion hold ring (ArtController sets
	  it) and, at full Resonance, CONFLUENCE with a pulsing glow.

	Shrine picker
	  When the server sends AttunementOffer, a modal lists the five
	  Attunements; choosing one sends RequestAttune.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Spells = require(Shared.Data.Spells)
local Formulas = require(Shared.Data.Formulas)
local Arts = require(Shared.Data.Arts)
local Confluences = require(Shared.Data.Confluences)
local Abilities = require(Shared.Data.Abilities)
local Positions = require(Shared.Data.Positions)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Animator = require(UI.Animator)
local Components = require(UI.Components)

local DataController = require(script.Parent.DataController)
local InputController = require(script.Parent.InputController)
local CharacterController = require(script.Parent.CharacterController)
local LockOnController = require(script.Parent.LockOnController)

local A = Attributes.Names
local C = Config.Current
local player = Players.LocalPlayer

local SpellController = {}

local ACTIONS = { "Cast1", "Cast2", "Cast3", "Cast4" }
local SLOT_SIZE = 58
local SLOT_GAP = 8
local ART_SIZE = 66
local ART_GAP = 16

type Slot = {
	Frame: Frame,
	Name: TextLabel,
	Key: TextLabel,
	Cost: TextLabel,
	Sweep: Frame,
	Stroke: UIStroke,
}

type ArtSlot = Slot & {
	Hold: Frame,
	Infusion: Frame,
}

-- A held cast key: aiming (Aimed cast) or charging (Lance).
type Aiming = {
	Index: number,
	Spell: Spells.SpellDef,
	Charging: boolean,
	Started: number,
}

local slots: { Slot } = {}
local artSlot: ArtSlot? = nil
local abilitySlot: Slot? = nil -- the Position ability key (Phase 8), right of the Art slot
local spellBar: Frame? = nil
local BAR_WIDTH = SLOT_SIZE * 4 + SLOT_GAP * 3 + ART_GAP + ART_SIZE -- without the ability slot
local abilityLength = 1 -- seconds of the running ability cooldown (for the sweep)
local stopArtGlow: (() -> ())? = nil
local readyAt: { [string]: number } = {} -- local cooldown prediction, by spell id (os.clock)
local cooldownLength: { [string]: number } = {}
local castUntil = 0
local tracks: { [string]: AnimationTrack } = {}
local picker: Components.Modal? = nil
local aiming: Aiming? = nil
local chargeTrack: AnimationTrack? = nil
local reticleFolder: Folder? = nil
local reticleParts: { BasePart } = {}
local aimDot: Frame? = nil

local function hotbar(): { string }
	local list = DataController.Get({ "Hotbar", "Spells" })
	return if type(list) == "table" then list else { "", "", "", "" }
end

local function stats(): { Density: number, Control: number }
	local s = DataController.Get({ "Stats" })
	if type(s) == "table" then
		return { Density = s.Density or 0, Control = s.Control or 0 }
	end
	return { Density = 0, Control = 0 }
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function overflowing(): boolean
	local overflow = player:GetAttribute(A.Overflow)
	return C.Overflow.FreeSpells and type(overflow) == "number" and overflow > serverNow()
end

local function costOf(spell: Spells.SpellDef): number
	if overflowing() then
		return 0
	end
	return spell.Shape.Cost * Formulas.SpellCost(stats().Control)
end

-- AIM ----------------------------------------------------------------------------

local function rootPart(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function autoTarget(root: BasePart): Vector3?
	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit
	local cone = math.cos(math.rad(C.Casting.MobileAutoTargetConeDegrees))
	local best: Vector3? = nil
	local bestDistance = C.Casting.MaxCastRange
	for _, model in CollectionService:GetTagged(Attributes.Tags.CombatTarget) do
		if model:IsA("Model") and model:GetAttribute(A.Team) == "Enemies" then
			local target = model:FindFirstChild("HumanoidRootPart")
			if target and target:IsA("BasePart") then
				local offset = target.Position - root.Position
				local horizontal = Vector3.new(offset.X, 0, offset.Z)
				local distance = offset.Magnitude
				if distance < bestDistance and horizontal.Magnitude > 0.1 and horizontal.Unit:Dot(look) >= cone then
					best = target.Position
					bestDistance = distance
				end
			end
		end
	end
	return best
end

local function cameraAim(root: BasePart): Vector3
	local camera = Workspace.CurrentCamera
	if not camera then
		return root.Position + root.CFrame.LookVector * 30
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = { player.Character :: Instance }
	local folder = reticleFolder
	if folder then
		table.insert(ignore, folder)
	end
	params.FilterDescendantsInstances = ignore
	local origin = camera.CFrame.Position
	local direction = camera.CFrame.LookVector * C.Casting.MaxCastRange
	local hit = Workspace:Raycast(origin, direction, params)
	return if hit then hit.Position else origin + direction
end

local function aimPoint(root: BasePart, aimed: boolean): Vector3
	local locked = LockOnController.GetTarget()
	local lockedRoot = locked and locked:FindFirstChild("HumanoidRootPart")
	if lockedRoot and lockedRoot:IsA("BasePart") then
		return lockedRoot.Position
	end
	-- While deliberately aiming, every device aims with the camera.
	if not aimed and InputController.GetDevice() == "Touch" then
		local target = autoTarget(root)
		if target then
			return target
		end
		return root.Position + root.CFrame.LookVector * 30
	end
	return cameraAim(root)
end

-- Where a cast (or a thrown quick item) would land right now.
function SpellController.AimPoint(): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	return aimPoint(root, false)
end

-- ANIMATION ----------------------------------------------------------------------

-- The clip for a Form, and the moment in it when the spell leaves the hand:
-- the Form's own casting clip once uploaded, otherwise its sword clip.
local function animationIdFor(shape: Spells.FormDef): (string?, number)
	local casting = (Config.Assets.Animations.Casting :: any)[shape.Animation]
	if type(casting) == "string" and casting ~= "" then
		local contact = (Config.Assets.Animations.CastingContact :: any)[shape.Animation]
		return casting, if type(contact) == "number" then contact else 0.25
	end
	local slot = shape.FallbackAnimation
	local id: any = (Config.Assets.Animations.Classes.Longsword :: any)[slot] or (Config.Assets.Animations.Common :: any)[slot]
	local contact = (Config.Mobs.AnimationContact :: any)[slot] or 0.14
	return if type(id) == "string" and id ~= "" then id else nil, contact
end

local function loadTrack(key: string, id: string): AnimationTrack?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end
	local track = tracks[key]
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
	loaded.Priority = Enum.AnimationPriority.Action
	tracks[key] = loaded
	return loaded
end

local function play(shape: Spells.FormDef, castTime: number)
	local id, contact = animationIdFor(shape)
	if not id then
		return
	end
	local t = loadTrack(`{shape.Animation}:{id}`, id)
	if not t then
		return
	end
	t.Looped = false
	t:Play(0.05, 1, if castTime > 0.02 then contact / castTime else 1)
	if castTime > 0.02 then
		task.delay(castTime, function()
			if t.IsPlaying then
				t:AdjustSpeed(1)
			end
		end)
	end
	if shape.FallbackAnimation == "Block" then
		task.delay(castTime + 0.3, function()
			t:Stop(0.15)
		end)
	end
end

local function playCharge()
	local id = (Config.Assets.Animations.Casting :: any).CastCharge
	if type(id) ~= "string" or id == "" then
		id = (Config.Assets.Animations.Classes.Longsword :: any).HeavyCharge
	end
	if type(id) ~= "string" or id == "" then
		return
	end
	local t = loadTrack(`CastCharge:{id}`, id)
	if t then
		t.Looped = true
		t:Play(0.1)
		chargeTrack = t
	end
end

local function stopCharge()
	local t = chargeTrack
	chargeTrack = nil
	if t then
		t:Stop(0.1)
	end
end

-- RETICLES (Aimed cast / charging) -----------------------------------------------

local function reticles(): Folder
	local folder = reticleFolder
	if folder and folder.Parent then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "SpellAim"
	created.Parent = Workspace
	reticleFolder = created
	return created
end

local function reticlePart(index: number, shape: Enum.PartType, color: Color3): BasePart
	local part = reticleParts[index]
	if not part or not part.Parent then
		local created = Instance.new("Part")
		created.Anchored = true
		created.CanCollide = false
		created.CanQuery = false
		created.CanTouch = false
		created.CastShadow = false
		created.Material = Enum.Material.Neon
		created.Transparency = 0.45
		created.Parent = reticles()
		reticleParts[index] = created
		part = created
	end
	local p = part :: Part
	p.Shape = shape
	p.Color = color
	return p
end

local function clearReticle()
	for _, part in reticleParts do
		part:Destroy()
	end
	table.clear(reticleParts)
	local dot = aimDot
	if dot then
		dot.Visible = false
	end
end

local function groundAt(position: Vector3): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character :: Instance, reticles() }
	local hit = Workspace:Raycast(position + Vector3.new(0, 4, 0), Vector3.new(0, -40, 0), params)
	return if hit then hit.Position else position
end

local function segment(index: number, from: Vector3, to: Vector3, width: number, color: Color3)
	local length = (to - from).Magnitude
	local part = reticlePart(index, Enum.PartType.Block, color)
	if length < 0.05 then
		part.Size = Vector3.new(0.05, 0.05, 0.05)
		part.CFrame = CFrame.new(from)
		return
	end
	part.Size = Vector3.new(width, 0.08, length)
	part.CFrame = CFrame.lookAt(from, to) * CFrame.new(0, 0, -length / 2)
end

local function disc(index: number, center: Vector3, radius: number, color: Color3)
	local part = reticlePart(index, Enum.PartType.Cylinder, color)
	part.Size = Vector3.new(0.1, radius * 2, radius * 2)
	part.CFrame = CFrame.new(center + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
end

local function drawReticle(state: Aiming)
	local root = rootPart()
	if not root then
		return
	end
	local spell = state.Spell
	local shape = spell.Shape
	local color = spell.Element.Color
	local width = C.Casting.AimedLineWidth
	local area = Formulas.SpellArea(stats().Control)
	local target = aimPoint(root, true)
	local feet = groundAt(root.Position)
	local flatAim = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z)
	local direction = if flatAim.Magnitude > 0.1 then flatAim.Unit else Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit
	local reticle = shape.Reticle
	if reticle == "Line" then
		local range = shape.Length or shape.Range or 40
		local toTarget = target - root.Position
		local length = math.min(toTarget.Magnitude, range)
		local endPoint = root.Position + (if toTarget.Magnitude > 0.1 then toTarget.Unit else direction) * length
		local thickness = if state.Charging and shape.Charge
			then width * (1 + 2 * math.clamp((os.clock() - state.Started) / shape.Charge.Max, 0, 1))
			else width
		segment(1, root.Position, endPoint, thickness, color)
	elseif reticle == "Cone" then
		local reach = (shape.Reach or 12) * area
		local half = math.rad((shape.Arc or 90) / 2)
		local base = math.atan2(direction.X, direction.Z)
		local left = Vector3.new(math.sin(base - half), 0, math.cos(base - half))
		local right = Vector3.new(math.sin(base + half), 0, math.cos(base + half))
		local origin = feet + Vector3.new(0, 0.1, 0)
		segment(1, origin, origin + left * reach, width, color)
		segment(2, origin, origin + right * reach, width, color)
		segment(3, origin + left * reach, origin + direction * reach, width, color)
		segment(4, origin + direction * reach, origin + right * reach, width, color)
	elseif reticle == "Circle" then
		local range = shape.Range or 60
		local offset = target - root.Position
		local point = if offset.Magnitude > range then root.Position + offset.Unit * range else target
		disc(1, groundAt(point), (shape.Radius or 8) * area, color)
	elseif reticle == "Arrow" then
		local distance = shape.Distance or 15
		local origin = feet + Vector3.new(0, 0.1, 0)
		segment(1, origin, origin + direction * distance, width, color)
		disc(2, origin + direction * distance, 1.5, color)
	end
	local dot = aimDot
	if dot then
		dot.Visible = true
		dot.BackgroundColor3 = color
	end
end

-- CASTING ------------------------------------------------------------------------

local function canCast(spell: Spells.SpellDef): boolean
	local root = rootPart()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not character or not humanoid or humanoid.Health <= 0 then
		return false
	end
	local clock = os.clock()
	if clock < castUntil or clock < (readyAt[spell.Id] or 0) then
		return false
	end
	local state = character:GetAttribute(A.CombatState)
	if state == "Staggered" or state == "Broken" or state == "Attacking" or state == "Heavy" or state == "Dodging" or state == "Art" then
		return false
	end
	local current = player:GetAttribute(A.Current)
	if type(current) == "number" and current < costOf(spell) then
		Components.Toast.Push({ Title = Strings.Toasts.NoCurrent, Color = UITheme.Colors.Danger, Key = "NoCurrent" })
		return false
	end
	return true
end

local function spellAt(index: number): Spells.SpellDef?
	local id = hotbar()[index]
	return if type(id) == "string" and id ~= "" then Spells.Get(id) else nil
end

-- Sends the cast (after any aiming/charging) and predicts it locally.
local function release(spell: Spells.SpellDef, aimed: boolean)
	local root = rootPart()
	if not root then
		return
	end
	local shape = spell.Shape
	local burnout = player:GetAttribute(A.Burnout)
	local slow = if type(burnout) == "number" and burnout > serverNow() then 1 + C.Burnout.CastSpeedPenalty else 1
	local castTime = shape.CastTime * Formulas.CastTime(stats().Control) * slow
	local aim = aimPoint(root, aimed)
	local clock = os.clock()
	readyAt[spell.Id] = clock + shape.Cooldown
	cooldownLength[spell.Id] = shape.Cooldown
	castUntil = clock + castTime + shape.Recovery

	local flatAim = Vector3.new(aim.X - root.Position.X, 0, aim.Z - root.Position.Z)
	CharacterController.SetActionOverride({
		SpeedMultiplier = C.Casting.CastMoveMultiplier,
		Face = if flatAim.Magnitude > 0.1 then flatAim.Unit else nil,
	})
	task.delay(castTime + shape.Recovery, function()
		if os.clock() >= castUntil - 0.01 then
			CharacterController.SetActionOverride(nil)
		end
	end)
	play(shape, castTime)
	Net.FireServer("RequestCast", spell.Id, aim)
end

local function endAiming()
	aiming = nil
	stopCharge()
	clearReticle()
end

local function finishAiming()
	local state = aiming
	if not state then
		return
	end
	endAiming()
	release(state.Spell, true)
end

local function beginCast(index: number)
	if aiming then
		return
	end
	local spell = spellAt(index)
	if not spell or not canCast(spell) then
		return
	end
	local shape = spell.Shape
	if shape.Charge then
		-- Charged spells always charge while held.
		aiming = { Index = index, Spell = spell, Charging = true, Started = os.clock() }
		Net.FireServer("RequestChargeCast", spell.Id)
		CharacterController.SetActionOverride({ SpeedMultiplier = C.Casting.ChargeMoveMultiplier })
		playCharge()
		return
	end
	if DataController.GetSetting("AimedCast") == true and shape.Reticle ~= "Self" then
		aiming = { Index = index, Spell = spell, Charging = false, Started = os.clock() }
		return
	end
	release(spell, false)
end

local function endCast(index: number)
	local state = aiming
	if state and state.Index == index then
		finishAiming()
	end
end

local function onRejected(action: string, reason: string)
	if action ~= "Cast" then
		return
	end
	-- Undo local predictions so the bar doesn't show a cooldown that isn't real.
	table.clear(readyAt)
	castUntil = 0
	if aiming and aiming.Charging then
		endAiming()
	end
	CharacterController.SetActionOverride(nil)
	if reason == "Current" then
		Components.Toast.Push({ Title = Strings.Toasts.NoCurrent, Color = UITheme.Colors.Danger, Key = "NoCurrent" })
	end
end

-- The server's real cooldowns (server times) replace the local guesses.
local function onCooldowns(list: { [string]: number })
	if type(list) ~= "table" then
		return
	end
	local offset = os.clock() - serverNow()
	for id, ready in list do
		if type(id) == "string" and type(ready) == "number" then
			readyAt[id] = ready + offset
		end
	end
end

local function stepAiming()
	local state = aiming
	if not state then
		return
	end
	local character = player.Character
	local combatState = character and character:GetAttribute(A.CombatState)
	-- A hit (or death) ends the aim; a charge ends with the server's cast.
	if not character or combatState == "Staggered" or combatState == "Broken" then
		endAiming()
		CharacterController.SetActionOverride(nil)
		return
	end
	local charge = state.Spell.Shape.Charge
	if state.Charging and charge and os.clock() - state.Started >= charge.Max then
		finishAiming()
		return
	end
	drawReticle(state)
	local root = rootPart()
	if root then
		local target = aimPoint(root, true)
		local flatAim = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z)
		CharacterController.SetActionOverride({
			SpeedMultiplier = if state.Charging then C.Casting.ChargeMoveMultiplier else C.Casting.CastMoveMultiplier,
			Face = if flatAim.Magnitude > 0.1 then flatAim.Unit else nil,
		})
	end
end

-- SPELL BAR ----------------------------------------------------------------------

local function newSlot(parent: Frame, name: string, position: UDim2, size: number): Slot
	local frame: Frame = Create.new("Frame", {
		Name = name,
		Position = position,
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = UITheme.Colors.HudPanel,
		BackgroundTransparency = 0.25,
		ClipsDescendants = true,
		Parent = parent,
	})
	Create.Corner(frame, UITheme.CornerSmall)
	local stroke = Create.Stroke(frame, UITheme.Colors.Stone, 2, 0.2)
	local sweep: Frame = Create.new("Frame", {
		Name = "Cooldown",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0),
		BackgroundColor3 = UITheme.Colors.Overlay,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = frame,
	})
	local label: TextLabel = Create.new("TextLabel", {
		Name = "Spell",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.new(1, -6, 0, 28),
		FontFace = UITheme.Fonts.BodyBold,
		TextSize = 13,
		-- Scaled (8-13 px) so a long single word like "Maelstrom" shrinks
		-- to fit instead of breaking mid-word.
		TextScaled = true,
		TextWrapped = true,
		TextColor3 = UITheme.Colors.Text,
		Text = Strings.SpellUI.Empty,
		ZIndex = 2,
		Parent = frame,
	})
	Create.new("UITextSizeConstraint", { MinTextSize = 8, MaxTextSize = 13, Parent = label })
	local key: TextLabel = Create.new("TextLabel", {
		Name = "Key",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(4, 2),
		Size = UDim2.fromOffset(28, 14),
		FontFace = UITheme.Fonts.BodyMedium,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = UITheme.Colors.TextMuted,
		Text = "",
		ZIndex = 4,
		Parent = frame,
	})
	local cost: TextLabel = Create.new("TextLabel", {
		Name = "Cost",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -4, 1, -2),
		Size = UDim2.fromOffset(30, 14),
		FontFace = UITheme.Fonts.Numbers,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = UITheme.Colors.Current,
		Text = "",
		ZIndex = 4,
		Parent = frame,
	})
	return { Frame = frame, Name = label, Key = key, Cost = cost, Sweep = sweep, Stroke = stroke }
end

local function buildBar()
	local layer = Layers.Get("HUD")
	local bar: Frame = Create.new("Frame", {
		Name = "SpellBar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.fromOffset(BAR_WIDTH, ART_SIZE + 16),
		BackgroundTransparency = 1,
		Parent = layer,
	})
	spellBar = bar
	for index = 1, 4 do
		slots[index] = newSlot(bar, `Slot{index}`, UDim2.fromOffset((index - 1) * (SLOT_SIZE + SLOT_GAP), ART_SIZE - SLOT_SIZE), SLOT_SIZE)
	end
	local base = newSlot(bar, "Art", UDim2.fromOffset(SLOT_SIZE * 4 + SLOT_GAP * 3 + ART_GAP, 0), ART_SIZE)
	local ability = newSlot(bar, "Ability", UDim2.fromOffset(SLOT_SIZE * 4 + SLOT_GAP * 3 + ART_GAP + ART_SIZE + SLOT_GAP, ART_SIZE - SLOT_SIZE), SLOT_SIZE)
	ability.Frame.Visible = false
	abilitySlot = ability
	-- Infusion hold: a bar that fills along the bottom while the button is held.
	local hold: Frame = Create.new("Frame", {
		Name = "Hold",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(0, 0, 0, 5),
		BackgroundColor3 = UITheme.Colors.Current,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = base.Frame,
	})
	-- Infusion remaining: a thin bar along the top.
	local infusion: Frame = Create.new("Frame", {
		Name = "Infusion",
		Size = UDim2.new(0, 0, 0, 4),
		BackgroundColor3 = UITheme.Colors.Current,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = base.Frame,
	})
	artSlot = {
		Frame = base.Frame,
		Name = base.Name,
		Key = base.Key,
		Cost = base.Cost,
		Sweep = base.Sweep,
		Stroke = base.Stroke,
		Hold = hold,
		Infusion = infusion,
	}
	-- The centre dot shown while aiming a cast.
	aimDot = Create.new("Frame", {
		Name = "AimDot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(8, 8),
		BackgroundColor3 = UITheme.Colors.Current,
		Visible = false,
		Parent = layer,
	})
	Create.Corner(aimDot :: Frame, UITheme.CornerPill)
end

local function weaponClass(): string?
	local character = player.Character
	local class = character and character:GetAttribute(A.WeaponClass)
	return if type(class) == "string" then class else nil
end

-- What the Weapon Art button does right now: "Confluence" or "Art".
function SpellController.ArtMode(): string
	local stacks = player:GetAttribute(A.Resonance)
	local primary = player:GetAttribute(A.Attunement)
	local class = weaponClass()
	local ready = player:GetAttribute(A.ConfluenceReadyAt)
	if
		type(stacks) == "number"
		and stacks >= C.Resonance.MaxStacks
		and type(primary) == "string"
		and primary ~= ""
		and class
		and Confluences.Get(class, primary)
		and (type(ready) ~= "number" or ready <= serverNow())
	then
		return "Confluence"
	end
	return "Art"
end

local function refreshArt()
	local slot = artSlot
	if not slot then
		return
	end
	local class = weaponClass()
	local art = if class then Arts.ForClass(class) else nil
	local mode = SpellController.ArtMode()
	local primary = player:GetAttribute(A.Attunement)
	local element = if type(primary) == "string" then Spells.Attunement(primary) else nil
	if mode == "Confluence" and class and type(primary) == "string" then
		local strings = Strings.Confluences[`{class}_{primary}`]
		slot.Name.Text = if strings then strings.Name else Strings.SpellUI.Confluence
		slot.Name.TextColor3 = UITheme.Colors.Parry
		slot.Stroke.Color = if element then element.Color else UITheme.Colors.Parry
		slot.Cost.Text = tostring(C.Confluence.CurrentCost)
		if not stopArtGlow then
			stopArtGlow = Animator.Pulse(slot.Stroke, "Transparency", 0, 0.6, 0.7)
		end
	else
		local strings = if class then Strings.Arts[class] else nil
		slot.Name.Text = if strings then strings.Name else Strings.SpellUI.Art
		slot.Name.TextColor3 = UITheme.Colors.Text
		slot.Stroke.Color = UITheme.Colors.Brass
		slot.Cost.Text = if art then tostring(art.Cost) else ""
		local glow = stopArtGlow
		if glow then
			glow()
			stopArtGlow = nil
			slot.Stroke.Transparency = 0.2
		end
	end
	slot.Key.Text = InputController.GetPrompt("WeaponArt")
end

-- The Position ability slot: shown once an ability is on the key.
local function refreshAbility()
	local slot = abilitySlot
	if not slot then
		return
	end
	local id = DataController.Get({ "Hotbar", "Ability" })
	local def = if type(id) == "string" and id ~= "" then Abilities.Get(id) else nil
	slot.Frame.Visible = def ~= nil
	-- The bar stays centred: it only widens while the ability slot shows.
	local bar = spellBar
	if bar then
		bar.Size = UDim2.fromOffset(BAR_WIDTH + (if def then SLOT_GAP + SLOT_SIZE else 0), ART_SIZE + 16)
	end
	if not def then
		return
	end
	local strings = Strings.Abilities[def.Id]
	local position = Positions.Get(def.Position)
	slot.Name.Text = if strings then strings.Name else def.Id
	slot.Name.TextColor3 = UITheme.Colors.Text
	slot.Stroke.Color = if position then position.Color else UITheme.Colors.Brass
	slot.Cost.Text = if def.Cost > 0 then tostring(def.Cost) else ""
	slot.Key.Text = InputController.GetPrompt("Ability")
end

-- Infusion hold progress (0..1) or nil to hide; called by ArtController.
function SpellController.SetArtHold(alpha: number?)
	local slot = artSlot
	if slot then
		slot.Hold.Size = UDim2.new(math.clamp(alpha or 0, 0, 1), 0, 0, 5)
	end
end

local function refreshBar()
	local list = hotbar()
	for index, slot in slots do
		local id = list[index]
		local spell = if type(id) == "string" and id ~= "" then Spells.Get(id) else nil
		if spell then
			local form = Strings.Forms[spell.Form]
			slot.Name.Text = if form then form.Name else spell.Form
			-- Lifted toward white so dark elements (Abyss) stay readable on the panel.
			slot.Name.TextColor3 = spell.Element.Color:Lerp(UITheme.Colors.Text, 0.35)
			slot.Stroke.Color = spell.Element.Color
			slot.Cost.Text = tostring(math.floor(costOf(spell) + 0.5))
		else
			slot.Name.Text = Strings.SpellUI.Empty
			slot.Name.TextColor3 = UITheme.Colors.TextDim
			slot.Stroke.Color = UITheme.Colors.Stone
			slot.Cost.Text = ""
		end
		slot.Key.Text = InputController.GetPrompt(ACTIONS[index] :: any)
	end
	refreshArt()
	refreshAbility()
end

local function updateBar()
	local list = hotbar()
	local clock = os.clock()
	local current = player:GetAttribute(A.Current)
	for index, slot in slots do
		local id = list[index]
		local spell = if type(id) == "string" and id ~= "" then Spells.Get(id) else nil
		if spell then
			local remaining = (readyAt[spell.Id] or 0) - clock
			local length = cooldownLength[spell.Id] or spell.Shape.Cooldown
			slot.Sweep.Size = UDim2.fromScale(1, if remaining > 0 then math.clamp(remaining / length, 0, 1) else 0)
			local cost = costOf(spell)
			local affordable = type(current) ~= "number" or current >= cost
			slot.Frame.BackgroundTransparency = if affordable then 0.25 else 0.6
			slot.Name.TextTransparency = if affordable then 0 else 0.5
			slot.Cost.Text = tostring(math.floor(cost + 0.5))
		else
			slot.Sweep.Size = UDim2.fromScale(1, 0)
		end
	end
	-- Weapon Art slot: cooldown sweep and Infusion time left.
	local art = artSlot
	if art then
		local now = serverNow()
		local mode = SpellController.ArtMode()
		local readyName = if mode == "Confluence" then A.ConfluenceReadyAt else A.ArtReadyAt
		local ready = player:GetAttribute(readyName)
		local class = weaponClass()
		local def = if class then Arts.ForClass(class) else nil
		local length = if mode == "Confluence" then C.Confluence.Cooldown elseif def then def.Cooldown else 1
		local remaining = if type(ready) == "number" then ready - now else 0
		art.Sweep.Size = UDim2.fromScale(1, if remaining > 0 then math.clamp(remaining / length, 0, 1) else 0)
		local infusedUntil = player:GetAttribute(A.InfusedUntil)
		local infusion = player:GetAttribute(A.Infusion)
		local left = if type(infusedUntil) == "number" then infusedUntil - now else 0
		local element = if type(infusion) == "string" then Spells.Attunement(infusion) else nil
		art.Infusion.Size = UDim2.new(math.clamp(left / C.Infusion.Duration, 0, 1), 0, 0, 4)
		if element then
			art.Infusion.BackgroundColor3 = element.Color
			art.Hold.BackgroundColor3 = element.Color
		end
	end
	-- Ability slot: cooldown sweep, dimmed when the Current is short.
	local ability = abilitySlot
	if ability and ability.Frame.Visible then
		local ready = player:GetAttribute(A.AbilityReadyAt)
		local remaining = if type(ready) == "number" then ready - serverNow() else 0
		ability.Sweep.Size = UDim2.fromScale(1, if remaining > 0 then math.clamp(remaining / abilityLength, 0, 1) else 0)
		local id = DataController.Get({ "Hotbar", "Ability" })
		local def = if type(id) == "string" then Abilities.Get(id) else nil
		local affordable = not def or type(current) ~= "number" or current >= def.Cost
		ability.Frame.BackgroundTransparency = if affordable then 0.25 else 0.6
		ability.Name.TextTransparency = if affordable then 0 else 0.5
	end
end

-- SHRINE PICKER ------------------------------------------------------------------

local function closePicker()
	local modal = picker
	picker = nil
	if modal then
		modal:Close()
	end
	InputController.SetContext("Gameplay")
end

local function openPicker(slot: string, primary: string)
	closePicker()
	local primaryName = Strings.Attunements[primary]
	local modal = Components.Modal.new({
		Title = Strings.SpellUI.ShrineTitle,
		Size = UDim2.fromOffset(560, 440),
		Dismissable = true,
	})
	picker = modal
	modal.Closed:Connect(function()
		if picker == modal then
			picker = nil
			InputController.SetContext("Gameplay")
		end
		-- A closed modal only hides; this one is built fresh each visit.
		task.defer(function()
			modal:Destroy()
		end)
	end)
	local content = modal.Content
	Create.new("UIListLayout", {
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = content,
	})
	Create.Label({
		Text = if slot == "Secondary"
			then Strings.Format(Strings.SpellUI.ShrineSecondary, { name = if primaryName then primaryName.Name else primary })
			else Strings.SpellUI.ShrinePrimary,
		LayoutOrder = 0,
		Size = UDim2.new(1, 0, 0, 22),
		Parent = content,
	} :: any)
	local order = { "Tide", "Rime", "Tempest", "Abyss", "Bloom" }
	for index, attunement in order do
		if attunement ~= primary then
			local info = Strings.Attunements[attunement]
			local element = Spells.Attunement(attunement)
			local row: Frame = Create.new("Frame", {
				Name = attunement,
				LayoutOrder = index,
				Size = UDim2.new(1, 0, 0, 58),
				BackgroundColor3 = UITheme.Colors.PanelRaised,
				Parent = content,
			})
			Create.Corner(row, UITheme.CornerSmall)
			if element then
				Create.Stroke(row, element.Color, 2, 0.1)
			end
			Create.new("TextLabel", {
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(12, 6),
				Size = UDim2.new(1, -150, 0, 20),
				FontFace = UITheme.Fonts.Display,
				TextSize = 18,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = if element then element.Color else UITheme.Colors.Text,
				Text = if info then info.Name else attunement,
				Parent = row,
			})
			Create.new("TextLabel", {
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(12, 28),
				Size = UDim2.new(1, -150, 0, 26),
				FontFace = UITheme.Fonts.Body,
				TextSize = 13,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextColor3 = UITheme.Colors.TextMuted,
				Text = if info then info.Description else "",
				Parent = row,
			})
			Components.Button.new({
				Text = Strings.SpellUI.Choose,
				Variant = "Primary",
				Size = UDim2.fromOffset(120, 36),
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -10, 0.5, 0),
				Parent = row,
				OnActivated = function()
					Net.FireServer("RequestAttune", attunement)
					closePicker()
				end,
			})
		end
	end
	InputController.SetContext("Menu")
	modal:Open()
end

-- LIFECYCLE ----------------------------------------------------------------------

function SpellController.Init()
	InputController.ActionBegan:Connect(function(action: string)
		local index = table.find(ACTIONS, action)
		if index then
			beginCast(index)
		elseif action == "Dodge" and aiming and not aiming.Charging then
			-- Rolling cancels an aimed cast (a charge can't be rolled out of).
			endAiming()
		end
	end)
	InputController.ActionEnded:Connect(function(action: string)
		local index = table.find(ACTIONS, action)
		if index then
			endCast(index)
		end
	end)
end

function SpellController.Start()
	-- The Spire has no Tools, and Roblox's Backpack claims keys 1-9, which
	-- are the cast keys.
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	buildBar()
	refreshBar()
	DataController.Observe({ "Hotbar", "Spells" }, function()
		refreshBar()
	end)
	DataController.Observe({ "Stats" }, function()
		refreshBar()
	end)
	DataController.Observe({ "Hotbar", "Ability" }, function()
		refreshAbility()
	end)
	player:GetAttributeChangedSignal(A.AbilityReadyAt):Connect(function()
		local ready = player:GetAttribute(A.AbilityReadyAt)
		if type(ready) == "number" then
			abilityLength = math.max(0.5, ready - serverNow())
		end
	end)
	InputController.BindingsChanged:Connect(refreshBar)
	InputController.DeviceChanged:Connect(refreshBar)
	for _, name in { A.Resonance, A.Attunement, A.ConfluenceReadyAt, A.Overflow } do
		player:GetAttributeChangedSignal(name):Connect(refreshArt)
	end
	Net.OnClient("ActionRejected", onRejected)
	Net.OnClient("SpellCooldowns", onCooldowns)
	Net.OnClient("AttunementOffer", function(slot: string, primary: string)
		if type(slot) == "string" then
			openPicker(slot, if type(primary) == "string" then primary else "")
		end
	end)
	local function bindCharacter(character: Model)
		table.clear(tracks)
		castUntil = 0
		endAiming()
		character:GetAttributeChangedSignal(A.WeaponClass):Connect(refreshArt)
		refreshArt()
	end
	player.CharacterAdded:Connect(bindCharacter)
	if player.Character then
		task.spawn(bindCharacter, player.Character)
	end
	RunService.RenderStepped:Connect(function()
		stepAiming()
		updateBar()
	end)
end

return SpellController
