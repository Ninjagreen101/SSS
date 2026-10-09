--!strict
--[[
	VFXController
	Client-only ambient visuals (nothing here affects gameplay):

	- Waystone crystals bob and slowly spin. Each client animates its own
	  copy, so the server never streams per-frame CFrame updates. Only
	  crystals near the camera animate (cheap on mobile).
	- Lost Current orb: when this player has gold waiting where they died
	  on this floor, a glowing teal orb marks the spot. It exists only on the
	  owner's client; the server decides pickup by distance.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)

local DataController = require(script.Parent.DataController)

local W = Config.World.Waystones
local L = Config.World.LostCurrent

local VFXController = {}

type Crystal = { Part: BasePart, Base: CFrame, Phase: number }

local crystals: { [BasePart]: Crystal } = {}
local orb: BasePart? = nil
local orbBase: Vector3 = Vector3.zero
local clock = 0

local function addCrystal(instance: Instance)
	if instance:IsA("BasePart") and not crystals[instance] then
		crystals[instance] = { Part = instance, Base = instance.CFrame, Phase = math.random() * math.pi * 2 }
	end
end

local function removeCrystal(instance: Instance)
	if instance:IsA("BasePart") then
		crystals[instance] = nil
	end
end

local function floorId(): string
	local value = Workspace:GetAttribute("FloorId")
	return if type(value) == "string" and value ~= "" then value else "1"
end

local function clearOrb()
	if orb then
		orb:Destroy()
		orb = nil
	end
end

local function updateOrb(lost: any)
	clearOrb()
	if type(lost) ~= "table" or type(lost.Gold) ~= "number" or lost.Gold <= 0 then
		return
	end
	if lost.FloorId ~= floorId() or type(lost.Position) ~= "table" or #lost.Position ~= 3 then
		return
	end
	local position = Vector3.new(lost.Position[1], lost.Position[2], lost.Position[3])
	local part = Instance.new("Part")
	part.Name = "LostCurrent"
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.Neon
	part.Color = UITheme.Colors.Current
	part.Size = Vector3.one * L.OrbSize
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 0.15
	local light = Instance.new("PointLight")
	light.Color = UITheme.Colors.Current
	light.Range = L.LightRange
	light.Brightness = L.LightBrightness
	light.Parent = part
	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Color = ColorSequence.new(UITheme.Colors.Current)
	sparkles.LightEmission = 1
	sparkles.Size = NumberSequence.new(0.25, 0)
	sparkles.Lifetime = NumberRange.new(0.8, 1.4)
	sparkles.Rate = 12
	sparkles.Speed = NumberRange.new(1, 2)
	sparkles.SpreadAngle = Vector2.new(180, 180)
	sparkles.Parent = part
	orbBase = position + Vector3.new(0, L.OrbHeight, 0)
	part.Position = orbBase
	part.Parent = Workspace
	orb = part
end

local function step(dt: number)
	clock += dt
	local camera = Workspace.CurrentCamera
	local cameraPosition = if camera then camera.CFrame.Position else Vector3.zero

	for part, crystal in crystals do
		if not part.Parent then
			crystals[part] = nil
		elseif (crystal.Base.Position - cameraPosition).Magnitude <= W.CrystalAnimateRange then
			local t = clock * W.CrystalBobSpeed + crystal.Phase
			local bob = math.sin(t) * W.CrystalBob
			local spin = math.rad(clock * W.CrystalSpinDegreesPerSecond)
			part.CFrame = crystal.Base * CFrame.new(0, bob, 0) * CFrame.Angles(0, spin, 0)
		end
	end

	local orbPart = orb
	if orbPart then
		orbPart.Position = orbBase + Vector3.new(0, math.sin(clock * L.BobSpeed) * L.BobHeight, 0)
	end
end

function VFXController.Start()
	local tag = Attributes.Tags.WaystoneCrystal
	for _, instance in CollectionService:GetTagged(tag) do
		addCrystal(instance)
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(addCrystal)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(removeCrystal)

	DataController.Observe({ "LostCurrent" }, updateOrb)

	RunService.RenderStepped:Connect(step)
end

return VFXController
