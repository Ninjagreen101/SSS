--!strict
--[[
	Builder
	Makes a mob's body: an R15 rig from a HumanoidDescription (Roblox's
	default body in the mob's colours), scaled, with a few extra parts welded
	on (hoods, barnacles, robes) and the blade it holds. Creatures (crabs,
	wisps, leeches) hide the rig's limbs and are built entirely from Extras
	riding those limbs, which gives them procedural motion from the standard
	animations. These are placeholder
	bodies until real enemy models exist; everything gameplay needs (the
	Humanoid, HumanoidRootPart, R15 joints for animation) is already final.

	Mesh bodies: a Body with MeshBody = "<Name>" uses the Blender-made pieces
	(tools/blender/guardian, imported as SpireKit_Guardians and turned into
	ServerStorage.SpireKit.Templates by KitLibrary.Prepare) when every piece of
	that body is there. Each piece is rigid, its origin is the centre of the R15
	part it rides, so it is cloned, scaled to the rig, set on its limb and welded.
	Pieces are named by their Role (Shell, Core, Seam, Claw, Helm...), the names
	the fight code looks for. Without the templates the Extras body is built.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Mobs = require(Shared.Data.Mobs)

local WeaponService = require(script.Parent.Parent.WeaponService)

local ELITE = Config.Mobs.Elite

local Builder = {}

local function weld(part: BasePart, to: BasePart)
	local joint = Instance.new("WeldConstraint")
	joint.Part0 = to
	joint.Part1 = part
	joint.Parent = part
end

local function extra(model: Model, spec: Mobs.BodyPart, scale: number)
	local attach = model:FindFirstChild(spec.Attach)
	if not attach or not attach:IsA("BasePart") then
		return
	end
	local part = Instance.new("Part")
	part.Name = spec.Role or "Detail"
	part.Shape = spec.Shape or Enum.PartType.Block
	part.Size = spec.Size * scale
	part.Color = spec.Color
	part.Material = if spec.Glow then Enum.Material.Neon else spec.Material
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = not spec.Glow
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	local offset = spec.Offset
	part.CFrame = attach.CFrame * (offset - offset.Position + offset.Position * scale)
	weld(part, attach)
	if spec.Glow then
		local light = Instance.new("PointLight")
		light.Color = spec.Color
		light.Range = 8
		light.Brightness = 1.2
		light.Shadows = false
		light.Parent = part
	end
	part.Parent = model
end

-- MESH BODIES ---------------------------------------------------------------------------------

-- Template attributes written by KitLibrary.Prepare for body pieces.
local PIECE = {
	Body = "Body",
	Limb = "Limb",
	Role = "Role",
	RigScale = "RigScale",
	BodyPieces = "BodyPieces",
	Shadow = "Shadow",
	LightRange = "LightRange",
	LightBrightness = "LightBrightness",
	Channel = "Channel",
}

-- Kit pieces face template +Z; an R15 part faces -Z.
local FACE_LIMB = CFrame.Angles(0, math.pi, 0)

-- Every template piece of mesh body `name`, or nil unless the whole body was prepared.
local function meshPieces(name: string): { Model }?
	local kit = ServerStorage:FindFirstChild("SpireKit")
	local templates = kit and kit:FindFirstChild("Templates")
	if not templates then
		return nil
	end
	local found: { Model } = {}
	local expected = 0
	for _, child in templates:GetChildren() do
		if child:IsA("Model") and child:GetAttribute(PIECE.Body) == name then
			table.insert(found, child)
			local count = child:GetAttribute(PIECE.BodyPieces)
			if type(count) == "number" then
				expected = math.max(expected, count)
			end
		end
	end
	if #found == 0 or #found < expected then
		return nil
	end
	return found
end

local function volume(part: BasePart): number
	return part.Size.X * part.Size.Y * part.Size.Z
end

-- Clones every piece onto its limb. Returns false (and builds nothing) if a limb is missing.
local function meshBody(model: Model, pieces: { Model }, scale: number): boolean
	local limbs: { [Model]: BasePart } = {}
	for _, template in pieces do
		local limbName = template:GetAttribute(PIECE.Limb)
		local limb = if type(limbName) == "string" then model:FindFirstChild(limbName) else nil
		if not (limb and limb:IsA("BasePart")) then
			return false
		end
		limbs[template] = limb
	end
	for _, template in pieces do
		local limb = limbs[template]
		local rigScale = template:GetAttribute(PIECE.RigScale)
		local k = scale / (if type(rigScale) == "number" and rigScale > 0 then rigScale else 1)
		local role = template:GetAttribute(PIECE.Role)
		local name = if type(role) == "string" then role else template.Name
		local shadow = template:GetAttribute(PIECE.Shadow) == true
		local frame = limb.CFrame * FACE_LIMB
		local parts: { BasePart } = {}
		for _, child in template:GetChildren() do
			if child:IsA("BasePart") and child.Name ~= "Collision" then
				table.insert(parts, child)
			end
		end
		-- biggest first, so FindFirstChild(name) lands on the main shape of the piece
		table.sort(parts, function(a: BasePart, b: BasePart): boolean
			return volume(a) > volume(b)
		end)
		local glow: BasePart? = nil
		for _, source in parts do
			local part = source:Clone()
			for _, tag in CollectionService:GetTags(part) do
				CollectionService:RemoveTag(part, tag)
			end
			for _, item in part:GetChildren() do
				item:Destroy()
			end
			local rel = source.CFrame
			part.Name = name
			part:SetAttribute("Piece", template.Name)
			part.Size = source.Size * k
			part.CFrame = frame * CFrame.new(rel.Position * k) * rel.Rotation
			part.Anchored = false
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true
			part.CastShadow = shadow and source.CastShadow
			weld(part, limb)
			part.Parent = model
			if not glow and part:GetAttribute(PIECE.Channel) == "Glow" then
				glow = part
			end
		end
		local range = template:GetAttribute(PIECE.LightRange)
		if glow and type(range) == "number" then
			local brightness = template:GetAttribute(PIECE.LightBrightness)
			local light = Instance.new("PointLight")
			light.Color = glow.Color
			light.Range = range * math.min(k, 2)
			light.Brightness = if type(brightness) == "number" then brightness else 1
			light.Shadows = false
			light.Parent = glow
		end
	end
	return true
end

-- A gold band and glow marks an elite.
local function eliteMarks(model: Model, scale: number)
	local torso = model:FindFirstChild("UpperTorso")
	if not torso or not torso:IsA("BasePart") then
		return
	end
	local band = Instance.new("Part")
	band.Name = "EliteBand"
	band.Size = Vector3.new(torso.Size.X * 1.04, 0.25 * scale, torso.Size.Z * 1.08)
	band.Color = ELITE.GlowColor
	band.Material = Enum.Material.Neon
	band.CanCollide = false
	band.CanQuery = false
	band.CanTouch = false
	band.Massless = true
	band.CastShadow = false
	band.CFrame = torso.CFrame * CFrame.new(0, -torso.Size.Y * 0.2, 0)
	weld(band, torso)
	band.Parent = model
	local light = Instance.new("PointLight")
	light.Color = ELITE.GlowColor
	light.Range = 10
	light.Brightness = 1
	light.Shadows = false
	light.Parent = torso
end

function Builder.Build(mobId: string, def: Mobs.MobDef, elite: boolean): Model
	local body = def.Body
	local description = Instance.new("HumanoidDescription")
	description.HeadColor = body.Skin
	description.TorsoColor = body.Torso
	description.LeftArmColor = body.Arms
	description.RightArmColor = body.Arms
	description.LeftLegColor = body.Legs
	description.RightLegColor = body.Legs
	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	description:Destroy()
	model.Name = mobId

	-- Mobs are driven from the server and animated by each client; no scripts inside.
	for _, item in model:GetDescendants() do
		if item:IsA("LuaSourceContainer") then
			item:Destroy()
		end
	end

	local scale = body.Scale * (if elite then ELITE.ScaleMultiplier else 1)
	if math.abs(scale - 1) > 1e-3 then
		model:ScaleTo(scale)
	end
	if body.Creature then
		-- The rig stays (pathing, hit boxes, animation) but its limbs vanish: the Extras welded
		-- to them are the creature, so walk and attack animations swing legs, claws and motes.
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
				d.Transparency = 1
			elseif d:IsA("Decal") then
				d:Destroy()
			end
		end
	end
	local pieces = if body.MeshBody then meshPieces(body.MeshBody) else nil
	if not (pieces and meshBody(model, pieces, scale)) then
		for _, spec in body.Extras do
			extra(model, spec, scale)
		end
	end
	if elite then
		eliteMarks(model, scale)
	end
	if def.Weapon then
		WeaponService.BuildModel(model, def.Weapon)
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	if body.Hover then
		-- floats above the ground (wisps); automatic scaling would recompute HipHeight from the legs
		humanoid.AutomaticScalingEnabled = false
		humanoid.HipHeight += body.Hover * scale
	end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.BreakJointsOnDeath = false
	for _, state in { Enum.HumanoidStateType.Climbing, Enum.HumanoidStateType.Swimming, Enum.HumanoidStateType.Seated, Enum.HumanoidStateType.FallingDown, Enum.HumanoidStateType.Ragdoll } do
		humanoid:SetStateEnabled(state, false)
	end
	if not humanoid:FindFirstChildOfClass("Animator") then
		Instance.new("Animator").Parent = humanoid
	end
	-- Arrive on clients in one piece (streaming).
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	return model
end

return Builder
