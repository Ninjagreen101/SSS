--!strict
--[[
	SprintVFXController
	Sprint wind, the Surge boom and the local screen speed lines. Visual only:
	every effect reads server-written state (Sprinting / Surging attributes,
	the SurgeBoom remote) plus the character's real speed.

	Wind rig: built once per character the first time it sprints near the
	camera, then only toggled and tuned (no per-frame Instance creation).
	  - Thin Trails at the shoulders and hips (hips from Medium Effects
	    Quality), white at the head fading to Current teal.
	  - A ParticleEmitter on the root blowing thin air lines out behind the
	    torso, stretched along their motion.
	  The wind ramps from walk to sprint speed. While Surging the streaks
	  last longer, show stronger and tint teal, and the air lines double.

	Surge boom (SurgeBoom remote, everyone near the runner): from a small
	pool, a ground shockwave ring, a vertical wind ring around the runner,
	a dust kick-up tinted by the ground and a burst of air lines. The runner
	themselves also gets an FOV punch and a light shake (CameraController
	honours Reduced Motion and Camera Shake). No sound: no fitting id is in
	Config.Assets or Config.Environment yet.

	Screen speed lines (local player only, at full sprint speed): a pool of
	thin frames sweeping out from the centre of the screen; more of them,
	teal, while Surging.

	Effects Quality (and Graphics Quality when not Auto) scale what is drawn.
	Reduced Motion removes the speed lines and halves the air lines.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Layers = require(UI.Layers)

local DataController = require(script.Parent.DataController)
local CameraController = require(script.Parent.CameraController)

local A = Attributes.Names
local S = Config.Combat.Surge
local W = S.Wind
local MOVE = Config.Combat.Movement
local player = Players.LocalPlayer

local SprintVFXController = {}

local WHITE = Color3.new(1, 1, 1)
local TEAL = UITheme.Colors.Current
local DUST = Color3.fromRGB(150, 140, 125)
local WISP_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local DUST_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

-- Streak anchor points in root space (R15 root is 2 studs tall), shoulders first.
local STREAK_POINTS = {
	Vector3.new(-0.95, 1.15, 0.25),
	Vector3.new(0.95, 1.15, 0.25),
	Vector3.new(-0.55, -0.75, 0.3),
	Vector3.new(0.55, -0.75, 0.3),
}

type Rig = {
	Character: Model,
	Trails: { Trail },
	Wisps: ParticleEmitter,
	Active: boolean,
	Key: string, -- last applied look (surging / intensity step / quality), to skip redundant writes
}

type Boom = {
	Ring: Part,
	Cone: Part,
	Holder: Part,
	Dust: ParticleEmitter,
	Gust: ParticleEmitter,
	Started: number?,
	Radius: number,
	ConeRadius: number,
	Base: CFrame,
	ConeBase: CFrame,
}

type Line = {
	Frame: Frame,
	Phase: number,
	Angle: number,
	Last: number,
}

local rigs: { [Model]: Rig } = {}
local booms: { Boom } = {}
local nextBoom = 1
local lines: { Line } = {}
local lineHolder: Frame? = nil
local folder: Folder? = nil
local flashUntil = 0
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = false

-- SETTINGS -----------------------------------------------------------------------

local function level(value: any): number
	return if value == "Low" then 0.5 elseif value == "Medium" then 0.75 else 1
end

-- 0.5 / 0.75 / 1 from Effects Quality, capped by Graphics Quality unless Auto.
local function quality(): number
	local q = level(DataController.GetSetting("EffectsQuality"))
	local graphics = DataController.GetSetting("GraphicsQuality")
	if graphics == "Low" or graphics == "Medium" then
		q = math.min(q, level(graphics))
	end
	return q
end

local function reducedMotion(): boolean
	return DataController.GetSetting("ReducedMotion") == true
end

local function fxFolder(): Folder
	local existing = folder
	if existing and existing.Parent then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "SprintFX"
	created.Parent = Workspace
	folder = created
	return created
end

-- WIND RIG -------------------------------------------------------------------------

local function sequence(head: number, tail: number): NumberSequence
	return NumberSequence.new({ NumberSequenceKeypoint.new(0, head), NumberSequenceKeypoint.new(1, tail) })
end

local function windColors(surging: boolean): ColorSequence
	local head = if surging then WHITE:Lerp(TEAL, 0.35) else WHITE
	local tail = if surging then TEAL else WHITE:Lerp(TEAL, 0.5)
	return ColorSequence.new(head, tail)
end

local function buildRig(character: Model, root: BasePart): Rig
	local scale = root.Size.Y / 2
	local trails: { Trail } = {}
	for index, point in STREAK_POINTS do
		local a0 = Instance.new("Attachment")
		a0.Name = `SpireWind{index}A`
		a0.Position = point * scale
		a0.Parent = root
		local a1 = Instance.new("Attachment")
		a1.Name = `SpireWind{index}B`
		a1.Position = point * scale + Vector3.new(0, W.StreakWidth, 0)
		a1.Parent = root
		local trail = Instance.new("Trail")
		trail.Name = `SpireWind{index}`
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.FaceCamera = true
		trail.LightEmission = 0.6
		trail.MinLength = 0.05
		trail.Lifetime = W.TrailLifetime
		trail.Color = windColors(false)
		trail.Transparency = sequence(W.TrailTransparency, 1)
		trail.WidthScale = sequence(1, 0.2)
		trail.Enabled = false
		trail.Parent = root
		table.insert(trails, trail)
	end

	local wisps = Instance.new("ParticleEmitter")
	wisps.Name = "SpireWindWisps"
	wisps.Texture = WISP_TEXTURE
	wisps.EmissionDirection = Enum.NormalId.Back
	wisps.Orientation = Enum.ParticleOrientation.VelocityParallel
	wisps.Size = sequence(0.14, 0.04)
	wisps.Squash = sequence(2.5, 2.5)
	wisps.Transparency = sequence(0.5, 1)
	wisps.LightEmission = 0.7
	wisps.Color = windColors(false)
	wisps.Lifetime = NumberRange.new(W.WispLifetime * 0.7, W.WispLifetime)
	wisps.Speed = NumberRange.new(W.WispSpeed * 0.6, W.WispSpeed)
	wisps.SpreadAngle = Vector2.new(20, 20)
	wisps.Drag = 2
	wisps.LockedToPart = false
	wisps.Rate = 0
	wisps.Enabled = false
	wisps.Parent = root

	local rig: Rig = { Character = character, Trails = trails, Wisps = wisps, Active = false, Key = "" }
	rigs[character] = rig
	return rig
end

local function disableRig(rig: Rig)
	if not rig.Active then
		return
	end
	rig.Active = false
	rig.Key = ""
	for _, trail in rig.Trails do
		trail.Enabled = false
	end
	rig.Wisps.Enabled = false
end

-- intensity 0..1 (walk to full sprint speed).
local function applyRig(rig: Rig, intensity: number, surging: boolean, q: number, reduced: boolean)
	local step = math.clamp(math.floor(intensity * 10 + 0.5), 1, 10)
	local key = `{surging}{step}{q}{reduced}`
	local wasActive = rig.Active
	rig.Active = true
	if key == rig.Key then
		return
	end
	rig.Key = key
	local strength = step / 10
	local head = if surging then W.SurgeTrailTransparency else W.TrailTransparency
	local transparency = sequence(1 - (1 - head) * strength, 1)
	local colors = windColors(surging)
	local streaks = if q >= 0.75 then #rig.Trails else 2
	for index, trail in rig.Trails do
		local on = index <= streaks
		if on and not (wasActive and trail.Enabled) then
			trail:Clear() -- no streak back to where this runner last stopped
		end
		trail.Enabled = on
		if on then
			trail.Lifetime = if surging then W.SurgeTrailLifetime else W.TrailLifetime
			trail.Transparency = transparency
			trail.Color = colors
		end
	end
	local rate = (if surging then W.SurgeWispRate else W.WispRate) * strength * q * (if reduced then 0.5 else 1)
	local wisps = rig.Wisps
	wisps.Rate = rate
	wisps.Color = colors
	wisps.Enabled = rate > 0
end

local function horizontalSpeed(root: BasePart): number
	local velocity = root.AssemblyLinearVelocity
	return Vector3.new(velocity.X, 0, velocity.Z).Magnitude
end

-- 0 at walk speed, 1 at full sprint speed (and beyond, while Surging).
local function sprintIntensity(root: BasePart): number
	return math.clamp((horizontalSpeed(root) - MOVE.WalkSpeed) / (MOVE.SprintSpeed - MOVE.WalkSpeed), 0, 1)
end

local function updateWind(cameraPosition: Vector3, q: number, reduced: boolean)
	for model, rig in rigs do
		if not model.Parent then
			rigs[model] = nil
		end
	end
	for _, other in Players:GetPlayers() do
		local character = other.Character
		if not character then
			continue
		end
		local rig = rigs[character]
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local root = character:FindFirstChild("HumanoidRootPart")
		local sprinting = other:GetAttribute(A.Sprinting) == true
		if other == player then
			sprinting = sprinting or CameraController.PredictedSprint
		end
		local show = sprinting
			and humanoid ~= nil
			and humanoid.Health > 0
			and root ~= nil
			and root:IsA("BasePart")
			and (root.Position - cameraPosition).Magnitude <= W.Range
		if show and root and root:IsA("BasePart") then
			local intensity = sprintIntensity(root)
			if intensity > 0.05 then
				applyRig(rig or buildRig(character, root), intensity, other:GetAttribute(A.Surging) == true, q, reduced)
				continue
			end
		end
		if rig then
			disableRig(rig)
		end
	end
end

-- SPEED LINES ----------------------------------------------------------------------

local function buildLines()
	local holder = Instance.new("Frame")
	holder.Name = "SpeedLines"
	holder.Size = UDim2.fromScale(1, 1)
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = Layers.Get("Overlay")
	lineHolder = holder
	local total = math.ceil(W.SpeedLines * W.SpeedLineSurgeMultiplier)
	for _ = 1, total do
		local frame = Instance.new("Frame")
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.BackgroundColor3 = WHITE
		frame.BorderSizePixel = 0
		frame.Visible = false
		frame.Parent = holder
		local gradient = Instance.new("UIGradient")
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.4, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		gradient.Parent = frame
		table.insert(lines, { Frame = frame, Phase = math.random(), Angle = math.random() * math.pi * 2, Last = 0 })
	end
end

local function updateLines(clock: number, q: number, reduced: boolean)
	local holder = lineHolder
	if not holder then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local sprinting = CameraController.PredictedSprint or player:GetAttribute(A.Sprinting) == true
	local alpha = 0
	if sprinting and root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
		-- Only at (nearly) full speed.
		alpha = math.clamp((sprintIntensity(root) - 0.85) / 0.15, 0, 1)
	end
	local surging = player:GetAttribute(A.Surging) == true and alpha > 0
	if clock < flashUntil then
		alpha = 1
		surging = true
	end
	local camera = Workspace.CurrentCamera
	if reduced or alpha <= 0 or not camera or CameraController.IsCinematic() then
		if holder.Visible then
			holder.Visible = false
		end
		return
	end
	if not holder.Visible then
		holder.Visible = true
	end
	local viewport = camera.ViewportSize
	local count = math.floor(W.SpeedLines * (if surging then W.SpeedLineSurgeMultiplier else 1) * q * alpha + 0.5)
	local color = if surging then TEAL else WHITE
	local layerScale = Layers.GetScale("Overlay")
	for index, line in lines do
		local frame = line.Frame
		local on = index <= count
		if frame.Visible ~= on then
			frame.Visible = on
		end
		if on then
			local p = ((clock + line.Phase * W.SpeedLineCycle) / W.SpeedLineCycle) % 1
			if p < line.Last then
				line.Angle = math.random() * math.pi * 2 -- a new sweep: new direction
			end
			line.Last = p
			local dx, dy = math.cos(line.Angle), math.sin(line.Angle)
			local radius = 0.34 + 0.3 * p
			frame.Position = UDim2.fromScale(0.5 + dx * radius, 0.5 + dy * radius)
			frame.Rotation = math.deg(math.atan2(dy * viewport.Y, dx * viewport.X))
			local length = (viewport.Magnitude * (0.04 + 0.08 * p)) / layerScale
			frame.Size = UDim2.fromOffset(length, if surging then 3 else 2)
			frame.BackgroundColor3 = color
			frame.BackgroundTransparency = 1 - math.sin(p * math.pi) * (if surging then 0.7 else 0.5) * alpha
		end
	end
end

-- SURGE BOOM ---------------------------------------------------------------------------

local function plainPart(name: string, shape: Enum.PartType): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.ForceField
	part.Color = TEAL:Lerp(WHITE, 0.4)
	part.Transparency = 1
	part.Size = Vector3.one
	part.Parent = fxFolder()
	return part
end

local function buildBoom(): Boom
	local holder = plainPart("SurgeBoomHolder", Enum.PartType.Block)
	holder.Size = Vector3.new(W.BoomRadius * 0.4, 0.2, W.BoomRadius * 0.4)

	local dust = Instance.new("ParticleEmitter")
	dust.Name = "Dust"
	dust.Texture = DUST_TEXTURE
	dust.EmissionDirection = Enum.NormalId.Top
	dust.SpreadAngle = Vector2.new(75, 75)
	dust.Speed = NumberRange.new(6, 13)
	dust.Drag = 3
	dust.Lifetime = NumberRange.new(0.6, 1.1)
	dust.Size = sequence(1.2, 3.2)
	dust.Transparency = sequence(0.45, 1)
	dust.Acceleration = Vector3.new(0, -3, 0)
	dust.Rotation = NumberRange.new(0, 360)
	dust.RotSpeed = NumberRange.new(-60, 60)
	dust.Rate = 0
	dust.Parent = holder

	local gust = Instance.new("ParticleEmitter")
	gust.Name = "Gust"
	gust.Texture = WISP_TEXTURE
	gust.EmissionDirection = Enum.NormalId.Top
	gust.SpreadAngle = Vector2.new(88, 88)
	gust.Orientation = Enum.ParticleOrientation.VelocityParallel
	gust.Speed = NumberRange.new(24, 40)
	gust.Drag = 4
	gust.Lifetime = NumberRange.new(0.25, 0.45)
	gust.Size = sequence(0.25, 0.06)
	gust.Squash = sequence(2.8, 2.8)
	gust.Transparency = sequence(0.2, 1)
	gust.LightEmission = 0.8
	gust.Color = windColors(true)
	gust.Rate = 0
	gust.Parent = holder

	return {
		Ring = plainPart("SurgeBoomRing", Enum.PartType.Cylinder),
		Cone = plainPart("SurgeBoomCone", Enum.PartType.Cylinder),
		Holder = holder,
		Dust = dust,
		Gust = gust,
		Started = nil,
		Radius = W.BoomRadius,
		ConeRadius = W.BoomConeRadius,
		Base = CFrame.identity,
		ConeBase = CFrame.identity,
	}
end

local function groundColor(origin: Vector3, character: Model): (Vector3, Color3)
	raycastParams.FilterDescendantsInstances = { character, fxFolder() }
	local result = Workspace:Raycast(origin, Vector3.new(0, -12, 0), raycastParams)
	if not result then
		return origin - Vector3.new(0, 3, 0), DUST
	end
	local hit = result.Instance
	local color = DUST
	if hit:IsA("Terrain") then
		local ok, terrainColor = pcall(function(): Color3
			return hit:GetMaterialColor(result.Material)
		end)
		if ok then
			color = terrainColor
		end
	elseif hit:IsA("BasePart") then
		color = hit.Color
	end
	return result.Position, color:Lerp(DUST, 0.45)
end

local function playBoom(character: Model)
	local root = character:FindFirstChild("HumanoidRootPart")
	local camera = Workspace.CurrentCamera
	if #booms == 0 or not root or not root:IsA("BasePart") or not camera then
		return
	end
	if (root.Position - camera.CFrame.Position).Magnitude > W.Range then
		return
	end
	local q = quality()
	local boom = booms[nextBoom]
	nextBoom = nextBoom % #booms + 1

	local velocity = root.AssemblyLinearVelocity
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	local forward = if flat.Magnitude > 1 then flat.Unit else Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit
	local feet, dustColor = groundColor(root.Position, character)

	-- Ground ring: a flat cylinder (axis up).
	boom.Base = CFrame.new(feet + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
	-- Wind ring: axis along the run, just behind the runner at chest height.
	local coneCenter = root.Position - forward * 1.5 + Vector3.new(0, 0.5, 0)
	boom.ConeBase = CFrame.lookAt(coneCenter, coneCenter + forward) * CFrame.Angles(0, math.rad(90), 0)
	boom.Radius = W.BoomRadius * (0.75 + 0.25 * q)
	boom.ConeRadius = W.BoomConeRadius
	boom.Started = os.clock()

	boom.Holder.CFrame = CFrame.new(feet + Vector3.new(0, 0.2, 0))
	boom.Dust.Color = ColorSequence.new(dustColor)
	boom.Dust:Emit(math.max(4, math.floor(W.BoomDust * q + 0.5)))
	boom.Gust:Emit(math.max(4, math.floor(W.BoomWisps * q * (if reducedMotion() then 0.5 else 1) + 0.5)))

	if character == player.Character then
		CameraController.Punch(S.BoomFovPunch)
		CameraController.Shake(S.BoomShake)
		flashUntil = os.clock() + W.BoomDuration * 0.6
	end
end

local function updateBooms(clock: number)
	for _, boom in booms do
		local started = boom.Started
		if not started then
			continue
		end
		local t = (clock - started) / W.BoomDuration
		if t >= 1 then
			boom.Started = nil
			boom.Ring.Transparency = 1
			boom.Cone.Transparency = 1
			continue
		end
		local eased = 1 - (1 - t) ^ 3
		local ringSize = 2 + (boom.Radius * 2 - 2) * eased
		boom.Ring.Size = Vector3.new(0.3, ringSize, ringSize)
		boom.Ring.CFrame = boom.Base
		boom.Ring.Transparency = 0.15 + 0.85 * t
		local coneSize = 1 + (boom.ConeRadius * 2 - 1) * eased
		boom.Cone.Size = Vector3.new(0.4 + 2.6 * eased, coneSize, coneSize)
		boom.Cone.CFrame = boom.ConeBase * CFrame.new(-1.3 * eased, 0, 0) -- drifts back along the run
		boom.Cone.Transparency = 0.1 + 0.9 * t
	end
end

-- LIFECYCLE ----------------------------------------------------------------------------

local function step()
	local clock = os.clock()
	local camera = Workspace.CurrentCamera
	local cameraPosition = if camera then camera.CFrame.Position else Vector3.zero
	local q = quality()
	local reduced = reducedMotion()
	updateWind(cameraPosition, q, reduced)
	updateLines(clock, q, reduced)
	updateBooms(clock)
end

function SprintVFXController.Init()
	Net.OnClient("SurgeBoom", function(character: any)
		if typeof(character) == "Instance" and character:IsA("Model") then
			playBoom(character)
		end
	end)
end

function SprintVFXController.Start()
	for _ = 1, W.BoomPool do
		table.insert(booms, buildBoom())
	end
	buildLines()
	RunService.RenderStepped:Connect(step)
end

return SprintVFXController
