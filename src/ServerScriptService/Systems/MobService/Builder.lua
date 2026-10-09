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
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
	for _, spec in body.Extras do
		extra(model, spec, scale)
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
