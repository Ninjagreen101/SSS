--!strict
-- CanalController: brings the Current water to life. Flow textures scroll
-- along canals and down waterfalls, the water breathes with a slow colour
-- pulse, and it glows brighter at night.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local LightingController = require(script.Parent.LightingController)

local Palette = Config.Palette
local LC = Config.Lighting

local CanalController = {}

local surfaces: { [BasePart]: boolean } = {}
local textures: { [Texture]: boolean } = {}

local function track(inst: Instance)
	if inst:IsA("BasePart") then
		if inst:GetAttribute("BaseTransparency") == nil then
			inst:SetAttribute("BaseTransparency", inst.Transparency)
		end
		surfaces[inst] = true
	end
end

local function trackTexture(inst: Instance)
	if inst:IsA("Texture") then
		textures[inst] = true
	end
end

function CanalController.Init()
	for _, p in CollectionService:GetTagged("CurrentSurface") do
		track(p)
	end
	CollectionService:GetInstanceAddedSignal("CurrentSurface"):Connect(track)
	CollectionService:GetInstanceRemovedSignal("CurrentSurface"):Connect(function(p: Instance)
		if p:IsA("BasePart") then
			surfaces[p] = nil
		end
	end)
	for _, t in CollectionService:GetTagged("CurrentFlowTexture") do
		trackTexture(t)
	end
	CollectionService:GetInstanceAddedSignal("CurrentFlowTexture"):Connect(trackTexture)
	CollectionService:GetInstanceRemovedSignal("CurrentFlowTexture"):Connect(function(t: Instance)
		if t:IsA("Texture") then
			textures[t] = nil
		end
	end)
end

function CanalController.Start()
	local accum = 0
	RunService.RenderStepped:Connect(function(dt: number)
		for tex in textures do
			if tex.Parent then
				local falls = tex.Face == Enum.NormalId.Front
				tex.OffsetStudsV = (tex.OffsetStudsV + dt * (if falls then 14 else 3)) % tex.StudsPerTileV
			end
		end
		accum += dt
		if accum < 0.1 then
			return
		end
		accum = 0
		local night = LightingController.NightFactor
		local glow = LC.CanalGlowDay + (LC.CanalGlowNight - LC.CanalGlowDay) * night
		local pulse = 0.5 + 0.5 * math.sin(os.clock() * 0.8)
		local color = Palette.CurrentDeep:Lerp(Palette.CurrentTeal, math.clamp(0.45 + glow * 0.45 + pulse * 0.1, 0, 1))
		for part in surfaces do
			if part.Parent then
				local baseT = (part:GetAttribute("BaseTransparency") :: number?) or part.Transparency
				part.Color = color
				part.Transparency = math.clamp(baseT + (1 - glow) * 0.12, 0, 0.9)
			end
		end
	end)
end

return CanalController
