--!strict
--[[
	TelegraphController
	Red ground telegraphs for enemy area attacks (Spec Section 10; docs/PHASE10_GUARDIAN.md).
	The server sends Net "Telegraph"(shape, cframe, sizeA, sizeB, duration, flags):

	  Circle  radius A                     Ring  outer radius A, inner radius B
	  Line    length A along LookVector, width B   Cone  radius A, arc B degrees

	Each telegraph is a translucent outline at full size plus a fill that grows to full over
	`duration`; when it lands the fill flashes and everything fades. A Ring with B = 0 is a
	travelling wave (the Tidal Wave): a thin front expands from the centre to A over `duration`,
	with a faint line where it stops.

	Flags (bit set): 1 = unparryable, drawn in a deeper ember red that pulses gently (no pulse with
	Reduced Motion); 2 = `cframe` is relative to the attacker's root. The payload names no attacker,
	so bit 2 follows the nearest Floor Guardian (tag Guardian) to the camera, within
	GUARDIAN_RANGE; Guardian arenas are instanced per party, so that is always the attacker. A
	relative telegraph with no Guardian in range is dropped.

	Rendering: pooled, anchored, invisible anchor parts carrying HandleAdornments (cylinders for
	circles, rings and cones; boxes for lines). Each telegraph is snapped to the floor once with a
	downward raycast that ignores characters, mobs and non-colliding parts (tide water). Nothing is
	created per frame; slots go back to the pool when they finish.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Attributes = require(Shared.Attributes)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Motion = require(UI.Motion)

local T = UITheme.Telegraph

local TelegraphController = {}

export type Shape = "Circle" | "Ring" | "Line" | "Cone"

local FLAG_UNPARRYABLE = 1
local FLAG_RELATIVE = 2
local GUARDIAN_RANGE = 250
local CULL_DISTANCE = 400 -- telegraphs further than this from the camera are not drawn
local MAX_SLOTS = 40
local HEIGHT = 0.05 -- adornment thickness
local SNAP_ABOVE = 8 -- the floor raycast starts this far above the telegraph
local SNAP_DEPTH = 60
-- CylinderHandleAdornment sectors open from the adornment's +X axis; this turns the arc so its
-- bisector points along the telegraph's LookVector.
local CONE_BASE_TURN = 90

type CylSlot = {
	Part: Part,
	Base: CylinderHandleAdornment,
	Rim: CylinderHandleAdornment,
	Fill: CylinderHandleAdornment,
}

type BoxSlot = {
	Part: Part,
	Base: BoxHandleAdornment,
	RailLeft: BoxHandleAdornment,
	RailRight: BoxHandleAdornment,
	Fill: BoxHandleAdornment,
}

type Active = {
	Shape: Shape,
	Placement: CFrame, -- world placement, or relative to Follow
	Follow: BasePart?,
	GroundY: number,
	A: number,
	B: number,
	Duration: number,
	Started: number,
	Unparryable: boolean,
	Wave: boolean,
	Cyl: CylSlot?,
	Box: BoxSlot?,
}

local folder: Folder? = nil
local cylPool: { CylSlot } = {}
local boxPool: { BoxSlot } = {}
local slotCount = 0
local active: { Active } = {}
local connection: RBXScriptConnection? = nil

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
rayParams.RespectCanCollide = true

local FLAT = CFrame.Angles(-math.pi / 2, 0, 0) -- cylinder axis (Z) pointing up, +Y forward

-- POOL ------------------------------------------------------------------------------------

local function getFolder(): Folder
	local existing = folder
	if existing and existing.Parent then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "SpireTelegraphs"
	created.Parent = Workspace
	folder = created
	return created
end

local function anchorPart(): Part
	local part = Instance.new("Part")
	part.Name = "Telegraph"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.one * 0.2
	part.Parent = getFolder()
	return part
end

local function cylinder(part: Part, name: string): CylinderHandleAdornment
	local adornment = Instance.new("CylinderHandleAdornment")
	adornment.Name = name
	adornment.Adornee = part
	adornment.Height = HEIGHT
	adornment.Radius = 1
	adornment.Shading = Enum.AdornShading.Default
	adornment.AlwaysOnTop = false
	adornment.Visible = false
	adornment.Parent = part
	return adornment
end

local function box(part: Part, name: string): BoxHandleAdornment
	local adornment = Instance.new("BoxHandleAdornment")
	adornment.Name = name
	adornment.Adornee = part
	adornment.Size = Vector3.one
	adornment.Shading = Enum.AdornShading.Default
	adornment.AlwaysOnTop = false
	adornment.Visible = false
	adornment.Parent = part
	return adornment
end

local function takeCyl(): CylSlot?
	local slot = table.remove(cylPool)
	if slot then
		return slot
	end
	if slotCount >= MAX_SLOTS then
		return nil
	end
	slotCount += 1
	local part = anchorPart()
	return {
		Part = part,
		Base = cylinder(part, "Base"),
		Rim = cylinder(part, "Rim"),
		Fill = cylinder(part, "Fill"),
	}
end

local function takeBox(): BoxSlot?
	local slot = table.remove(boxPool)
	if slot then
		return slot
	end
	if slotCount >= MAX_SLOTS then
		return nil
	end
	slotCount += 1
	local part = anchorPart()
	return {
		Part = part,
		Base = box(part, "Base"),
		RailLeft = box(part, "RailLeft"),
		RailRight = box(part, "RailRight"),
		Fill = box(part, "Fill"),
	}
end

local function release(entry: Active)
	local cyl = entry.Cyl
	if cyl then
		cyl.Base.Visible = false
		cyl.Rim.Visible = false
		cyl.Fill.Visible = false
		table.insert(cylPool, cyl)
		entry.Cyl = nil
	end
	local rect = entry.Box
	if rect then
		rect.Base.Visible = false
		rect.RailLeft.Visible = false
		rect.RailRight.Visible = false
		rect.Fill.Visible = false
		table.insert(boxPool, rect)
		entry.Box = nil
	end
end

-- PLACEMENT -------------------------------------------------------------------------------

local function rootOf(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	return if root and root:IsA("BasePart") then root else nil
end

local function nearestGuardianRoot(): BasePart?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local eye = camera.CFrame.Position
	local best: BasePart? = nil
	local bestDistance = GUARDIAN_RANGE
	for _, instance in CollectionService:GetTagged(Attributes.Tags.Guardian) do
		if instance:IsA("Model") and instance:IsDescendantOf(Workspace) then
			local root = rootOf(instance)
			if root then
				local distance = (root.Position - eye).Magnitude
				if distance <= bestDistance then
					best = root
					bestDistance = distance
				end
			end
		end
	end
	return best
end

-- The world CFrame of a telegraph: on its floor height, level, facing its flattened LookVector.
local function placement(entry: Active): CFrame
	local follow = entry.Follow
	local world = if follow then follow.CFrame * entry.Placement else entry.Placement
	local look = world.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local position = Vector3.new(world.Position.X, entry.GroundY + T.Lift, world.Position.Z)
	return CFrame.lookAt(position, position + flat)
end

local function groundY(position: Vector3): number
	local exclude: { Instance } = { getFolder() }
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(exclude, other.Character)
		end
	end
	for _, tag in { Attributes.Tags.Mob, Attributes.Tags.Guardian } do
		for _, model in CollectionService:GetTagged(tag) do
			table.insert(exclude, model)
		end
	end
	rayParams.FilterDescendantsInstances = exclude
	local hit = Workspace:Raycast(position + Vector3.new(0, SNAP_ABOVE, 0), Vector3.new(0, -SNAP_DEPTH, 0), rayParams)
	return if hit then hit.Position.Y else position.Y
end

-- DRAWING ---------------------------------------------------------------------------------

local function colours(entry: Active): (Color3, Color3)
	if entry.Unparryable then
		return T.Unparryable, T.Ember
	end
	return T.Color, T.Color
end

local function lift(offset: number): CFrame
	return CFrame.new(0, offset, 0)
end

-- First frame: sizes, colours and visibility that stay fixed for the telegraph's life.
local function setup(entry: Active)
	local main, rim = colours(entry)
	local a = math.max(entry.A, 0.1)
	local b = math.max(entry.B, 0)
	local cyl = entry.Cyl
	if cyl then
		local turn = CFrame.identity
		local angle = 360
		if entry.Shape == "Cone" then
			angle = math.clamp(b, 1, 360)
			turn = CFrame.Angles(0, 0, math.rad(CONE_BASE_TURN - angle / 2))
		end
		local inner = if entry.Shape == "Ring" and not entry.Wave then math.min(b, a - 0.05) else 0
		cyl.Base.CFrame = FLAT * turn
		cyl.Rim.CFrame = lift(0.02) * FLAT * turn
		cyl.Fill.CFrame = lift(0.04) * FLAT * turn
		for _, adornment in { cyl.Base, cyl.Rim, cyl.Fill } do
			adornment.InnerRadius = 0 -- reset before radii shrink (a reused slot may hold a bigger ring)
			adornment.Angle = angle
			adornment.Visible = true
		end
		cyl.Base.Color3 = main
		cyl.Base.Radius = a
		cyl.Base.InnerRadius = inner
		cyl.Base.Transparency = if entry.Wave then 1 else T.OutlineTransparency
		cyl.Rim.Color3 = rim
		cyl.Rim.Radius = a
		cyl.Rim.InnerRadius = math.max(0, a - T.RimWidth * (if entry.Wave then 2 else 1))
		cyl.Rim.Transparency = T.RimTransparency
		cyl.Fill.Color3 = if entry.Wave then rim else main
		cyl.Fill.Transparency = if entry.Wave then 0.15 else T.FillTransparency
		cyl.Fill.Radius = 0.05
		cyl.Fill.InnerRadius = 0
	end
	local rect = entry.Box
	if rect then
		local width = math.max(b, 0.5)
		rect.Base.Size = Vector3.new(width, HEIGHT, a)
		rect.Base.CFrame = CFrame.new(0, 0, -a / 2)
		rect.Base.Color3 = main
		rect.Base.Transparency = T.OutlineTransparency
		local rail = Vector3.new(T.RimWidth, HEIGHT, a)
		rect.RailLeft.Size = rail
		rect.RailRight.Size = rail
		rect.RailLeft.CFrame = CFrame.new(-(width - T.RimWidth) / 2, 0.02, -a / 2)
		rect.RailRight.CFrame = CFrame.new((width - T.RimWidth) / 2, 0.02, -a / 2)
		rect.Fill.Color3 = main
		rect.Fill.Transparency = T.FillTransparency
		for _, railPart in { rect.RailLeft, rect.RailRight } do
			railPart.Color3 = rim
			railPart.Transparency = T.RimTransparency
		end
		for _, adornment in { rect.Base, rect.RailLeft, rect.RailRight, rect.Fill } do
			adornment.Visible = true
		end
		rect.Fill.Size = Vector3.new(width, HEIGHT, 0.05)
		rect.Fill.CFrame = CFrame.new(0, 0.04, -0.025)
	end
end

-- Per frame. Returns false once the telegraph has finished.
local function step(entry: Active, clock: number, reduced: boolean): boolean
	local follow = entry.Follow
	local partCFrame: CFrame? = nil
	if follow then
		if not follow:IsDescendantOf(Workspace) then
			return false
		end
		partCFrame = placement(entry)
	end
	local elapsed = clock - entry.Started
	local progress = if entry.Duration > 0 then math.clamp(elapsed / entry.Duration, 0, 1) else 1
	local flashing = elapsed >= entry.Duration
	local fadeAlpha = if flashing then math.clamp((elapsed - entry.Duration) / T.FlashTime, 0, 1) else 0
	if flashing and fadeAlpha >= 1 then
		return false
	end
	-- Unparryable outlines breathe; reduced motion keeps them steady.
	local pulse = 0
	if entry.Unparryable and not reduced and not flashing then
		pulse = (math.sin(clock * math.pi * 2 / T.PulsePeriod) + 1) * 0.5
	end
	local main = colours(entry)
	local a = math.max(entry.A, 0.1)
	local b = math.max(entry.B, 0)

	local cyl = entry.Cyl
	if cyl then
		if partCFrame then
			cyl.Part.CFrame = partCFrame
		end
		if entry.Wave then
			local radius = math.max(0.05, a * progress)
			cyl.Fill.Radius = radius
			cyl.Fill.InnerRadius = math.max(0, radius - T.WaveWidth)
			cyl.Fill.Transparency = 0.15 + 0.85 * fadeAlpha
			cyl.Rim.Transparency = T.RimTransparency + (1 - T.RimTransparency) * fadeAlpha - 0.15 * pulse
		else
			local inner = if entry.Shape == "Ring" then math.min(b, a - 0.05) else 0
			cyl.Fill.InnerRadius = inner
			cyl.Fill.Radius = math.max(inner + 0.05, inner + (a - inner) * progress)
			cyl.Base.Transparency = T.OutlineTransparency + (1 - T.OutlineTransparency) * fadeAlpha - 0.12 * pulse
			cyl.Rim.Transparency = T.RimTransparency + (1 - T.RimTransparency) * fadeAlpha
			if flashing then
				cyl.Fill.Color3 = if reduced then main else T.Flash:Lerp(main, fadeAlpha)
				cyl.Fill.Transparency = (if reduced then T.FillTransparency else 0.1) + (1 - (if reduced then T.FillTransparency else 0.1)) * fadeAlpha
			else
				cyl.Fill.Transparency = T.FillTransparency - 0.1 * pulse
			end
		end
	end

	local rect = entry.Box
	if rect then
		if partCFrame then
			rect.Part.CFrame = partCFrame
		end
		local width = math.max(b, 0.5)
		local length = math.max(0.05, a * progress)
		rect.Fill.Size = Vector3.new(width, HEIGHT, length)
		rect.Fill.CFrame = CFrame.new(0, 0.04, -length / 2)
		rect.Base.Transparency = T.OutlineTransparency + (1 - T.OutlineTransparency) * fadeAlpha - 0.12 * pulse
		local rail = T.RimTransparency + (1 - T.RimTransparency) * fadeAlpha
		rect.RailLeft.Transparency = rail
		rect.RailRight.Transparency = rail
		if flashing then
			rect.Fill.Color3 = if reduced then main else T.Flash:Lerp(main, fadeAlpha)
			rect.Fill.Transparency = (if reduced then T.FillTransparency else 0.1) + (1 - (if reduced then T.FillTransparency else 0.1)) * fadeAlpha
		else
			rect.Fill.Transparency = T.FillTransparency - 0.1 * pulse
		end
	end
	return true
end

local function stepAll()
	local clock = os.clock()
	local reduced = Motion.IsReduced()
	for index = #active, 1, -1 do
		local entry = active[index]
		if not step(entry, clock, reduced) then
			release(entry)
			table.remove(active, index)
		end
	end
	if #active == 0 then
		local current = connection
		if current then
			current:Disconnect()
			connection = nil
		end
	end
end

-- PUBLIC API ------------------------------------------------------------------------------

-- Draws a telegraph. `follow` (optional) makes `cframe` relative to that part.
function TelegraphController.Show(shape: Shape, cframe: CFrame, sizeA: number, sizeB: number, duration: number, flags: number, follow: BasePart?)
	local camera = Workspace.CurrentCamera
	local world = if follow then follow.CFrame * cframe else cframe
	if camera and (world.Position - camera.CFrame.Position).Magnitude > CULL_DISTANCE then
		return
	end
	local entry: Active = {
		Shape = shape,
		Placement = cframe,
		Follow = follow,
		GroundY = groundY(world.Position),
		A = sizeA,
		B = sizeB,
		Duration = math.max(0, duration),
		Started = os.clock(),
		Unparryable = bit32.band(flags, FLAG_UNPARRYABLE) ~= 0,
		Wave = shape == "Ring" and sizeB <= 0,
		Cyl = nil,
		Box = nil,
	}
	if shape == "Line" then
		entry.Box = takeBox()
		if not entry.Box then
			return
		end
	else
		entry.Cyl = takeCyl()
		if not entry.Cyl then
			return
		end
	end
	local placed = placement(entry)
	local cyl = entry.Cyl
	if cyl then
		cyl.Part.CFrame = placed
	end
	local rect = entry.Box
	if rect then
		rect.Part.CFrame = placed
	end
	setup(entry)
	step(entry, entry.Started, Motion.IsReduced())
	table.insert(active, entry)
	if not connection then
		connection = RunService.RenderStepped:Connect(stepAll)
	end
end

-- Removes every telegraph at once (a wipe or leaving an arena).
function TelegraphController.Clear()
	for _, entry in active do
		release(entry)
	end
	table.clear(active)
end

local SHAPES: { [string]: Shape } = { Circle = "Circle", Ring = "Ring", Line = "Line", Cone = "Cone" }

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function onTelegraph(shape: any, cframe: any, sizeA: any, sizeB: any, duration: any, flags: any)
	local kind: Shape? = if type(shape) == "string" then SHAPES[shape] else nil
	if not kind or typeof(cframe) ~= "CFrame" or not finite(sizeA) or not finite(sizeB) or not finite(duration) then
		return
	end
	local bits = if finite(flags) then math.floor(flags) else 0
	local follow: BasePart? = nil
	if bit32.band(bits, FLAG_RELATIVE) ~= 0 then
		follow = nearestGuardianRoot()
		if not follow then
			return
		end
	end
	TelegraphController.Show(kind, cframe, math.clamp(sizeA, 0, 500), math.clamp(sizeB, 0, 500), math.clamp(duration, 0, 30), bits, follow)
end

function TelegraphController.Init()
	Net.OnClient("Telegraph", onTelegraph)
end

return TelegraphController
