--!strict
-- LightingController: applies the floor's Lighting preset, blending its
-- time-of-day keyframes with the server-driven ClockTime, switches to zone
-- overrides (dungeons, caves) with a smooth crossfade, scales lantern lights
-- and lights up windows at night, toggles night-only emitters (fireflies,
-- beacon glow) and runs the rain around the camera on rainy floors.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Floors = require(Shared.Data.Floors)
local WorldFX = require(Shared.Util.WorldFX)
local Signal = require(Shared.Util.Signal)

local SettingsController = require(script.Parent.SettingsController)

type Preset = typeof(Config.Lighting.Presets.Lowharbor)
type Key = typeof(Config.Lighting.Presets.Lowharbor.keys[1])

local LC = Config.Lighting
local Palette = Config.Palette

local LightingController = {
	NightChanged = Signal.new() :: Signal.Signal<number>,
	NightFactor = 0,
}

local atmosphere: Atmosphere
local cc: ColorCorrectionEffect
local bloom: BloomEffect
local rays: SunRaysEffect
local rainPart: Part? = nil
local rainEmitter: ParticleEmitter? = nil

local currentPresetName = ""
local blendFrom: Key? = nil
local blendStart = 0
local lastApplied: Key? = nil
local nightApplied = -1
local glowOn: boolean? = nil

local function ensure<T>(className: string, name: string): T
	local inst = Lighting:FindFirstChild(name)
	if not inst then
		inst = Instance.new(className)
		inst.Name = name;
		(inst :: Instance).Parent = Lighting
	end
	return inst :: any
end

local function hex(h: string): Color3
	return Color3.fromHex(h)
end

local function lerpKey(a: Key, b: Key, t: number): Key
	local function n(x: number, y: number): number
		return x + (y - x) * t
	end
	local function c(x: string, y: string): string
		return hex(x):Lerp(hex(y), t):ToHex()
	end
	return {
		clock = n(a.clock, b.clock),
		ambient = c(a.ambient, b.ambient),
		outdoorAmbient = c(a.outdoorAmbient, b.outdoorAmbient),
		brightness = n(a.brightness, b.brightness),
		colorShift = c(a.colorShift, b.colorShift),
		fogColor = c(a.fogColor, b.fogColor),
		atmosphereDensity = n(a.atmosphereDensity, b.atmosphereDensity),
		atmosphereHaze = n(a.atmosphereHaze, b.atmosphereHaze),
		atmosphereGlare = n(a.atmosphereGlare, b.atmosphereGlare),
		atmosphereColor = c(a.atmosphereColor, b.atmosphereColor),
		atmosphereDecay = c(a.atmosphereDecay, b.atmosphereDecay),
		ccTint = c(a.ccTint, b.ccTint),
		ccSaturation = n(a.ccSaturation, b.ccSaturation),
		ccContrast = n(a.ccContrast, b.ccContrast),
		ccBrightness = n(a.ccBrightness, b.ccBrightness),
		bloomIntensity = n(a.bloomIntensity, b.bloomIntensity),
		sunRays = n(a.sunRays, b.sunRays),
		exposure = n(a.exposure, b.exposure),
		nightFactor = n(a.nightFactor, b.nightFactor),
	}
end

-- sample a preset's keyframes cyclically at clock time t
local function sample(preset: Preset, t: number): Key
	local keys = preset.keys
	if #keys == 1 then
		return keys[1]
	end
	for i = 1, #keys do
		local a = keys[i]
		local b = keys[(i % #keys) + 1]
		local ta, tb = a.clock, b.clock
		if tb <= ta then
			tb += 24
		end
		local tt = t
		if tt < ta then
			tt += 24
		end
		if tt >= ta and tt <= tb then
			return lerpKey(a, b, (tt - ta) / (tb - ta))
		end
	end
	return keys[1]
end

local function presetFor(player: Player): (string, Preset)
	local floorId = Workspace:GetAttribute("FloorId")
	local floor = if type(floorId) == "string" then Floors.ById[floorId] else Floors.ByIndex[1]
	local base = if floor then floor.lightingPreset else "Lowharbor"
	local ambience = player:GetAttribute("ZoneAmbience")
	local kind = player:GetAttribute("ZoneKind")
	local override = (type(ambience) == "string" and LC.ZoneOverrides[ambience]) or (type(kind) == "string" and LC.ZoneOverrides[kind]) or nil
	local name = override or base
	return name, LC.Presets[name] or LC.Presets.Lowharbor
end

local function apply(k: Key, preset: Preset)
	Lighting.Ambient = hex(k.ambient)
	Lighting.OutdoorAmbient = hex(k.outdoorAmbient)
	Lighting.Brightness = k.brightness
	Lighting.ColorShift_Top = hex(k.colorShift)
	Lighting.FogColor = hex(k.fogColor)
	Lighting.ExposureCompensation = k.exposure
	Lighting.EnvironmentDiffuseScale = preset.environmentDiffuse
	Lighting.EnvironmentSpecularScale = preset.environmentSpecular
	Lighting.ShadowSoftness = preset.shadowSoftness
	Lighting.GeographicLatitude = preset.geographicLatitude
	atmosphere.Density = k.atmosphereDensity
	atmosphere.Haze = k.atmosphereHaze
	atmosphere.Glare = k.atmosphereGlare
	atmosphere.Color = hex(k.atmosphereColor)
	atmosphere.Decay = hex(k.atmosphereDecay)
	atmosphere.Offset = 0.1
	cc.TintColor = hex(k.ccTint)
	cc.Saturation = k.ccSaturation
	cc.Contrast = k.ccContrast
	cc.Brightness = k.ccBrightness
	bloom.Intensity = k.bloomIntensity
	bloom.Threshold = preset.bloomThreshold
	bloom.Size = preset.bloomSize
	rays.Intensity = k.sunRays
	rays.Spread = preset.sunRaysSpread
end

-- ---------------------------------------------------------- night dressing

local function lightBrightness(light: Instance, night: number)
	if not light:IsA("PointLight") then
		return
	end
	local base = (light:GetAttribute("BaseBrightness") :: number?) or light.Brightness
	local q = SettingsController.Quality()
	local scale = LC.DayLightScale + (LC.NightLightBoost - LC.DayLightScale) * night
	light.Brightness = base * scale
	light.Enabled = q ~= "Low" or night > 0.5
end

local function windowGlow(part: Instance, on: boolean)
	if not part:IsA("BasePart") then
		return
	end
	if on then
		part.Material = Enum.Material.Neon
		part.Color = Palette.WindowGlow
		part.Transparency = 0.15
	else
		local mat = part:GetAttribute("BaseMaterial")
		part.Material = if type(mat) == "string" then (Enum.Material :: any)[mat] else Enum.Material.Glass
		local col = part:GetAttribute("BaseColor")
		part.Color = if typeof(col) == "Color3" then col else Palette.Glass
		part.Transparency = (part:GetAttribute("BaseTransparency") :: number?) or 0.3
	end
end

local function nightEmitter(e: Instance, on: boolean)
	if e:IsA("ParticleEmitter") then
		e.Enabled = on
	end
end

local function applyNight(night: number)
	if math.abs(night - nightApplied) < 0.05 then
		return
	end
	nightApplied = night
	LightingController.NightFactor = night
	for _, l in CollectionService:GetTagged("NightLight") do
		lightBrightness(l, night)
	end
	local on = night > 0.5
	if glowOn ~= on then
		glowOn = on
		for _, p in CollectionService:GetTagged("WindowGlow") do
			windowGlow(p, on)
		end
		for _, e in CollectionService:GetTagged("NightEmitter") do
			nightEmitter(e, on)
		end
	end
	LightingController.NightChanged:Fire(night)
end

-- ------------------------------------------------------------------ rain

local function updateRain(preset: Preset, camera: Camera)
	local q = SettingsController.Quality()
	local rate = (Config.World.Ambient.RainRate :: any)[q] or 0
	local want = preset.rain and preset.outdoor and rate > 0
	if not want then
		if rainEmitter then
			(rainEmitter :: ParticleEmitter).Enabled = false
		end
		return
	end
	if not rainPart then
		local p = Instance.new("Part")
		p.Name = "RainVolume"
		p.Size = Vector3.new(140, 1, 140)
		p.Transparency = 1
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		local e = WorldFX.emitter("Rain", 1)
		e.Parent = p
		p.Parent = camera
		rainPart = p
		rainEmitter = e
	end
	local e = rainEmitter :: ParticleEmitter
	e.Enabled = true
	e.Rate = rate
	local cam = camera.CFrame.Position
	local volume = rainPart :: Part
	volume.CFrame = CFrame.new(cam.X, cam.Y + 40, cam.Z)
end

function LightingController.Init()
	atmosphere = ensure("Atmosphere", "SpireAtmosphere")
	cc = ensure("ColorCorrectionEffect", "SpireColor")
	bloom = ensure("BloomEffect", "SpireBloom")
	rays = ensure("SunRaysEffect", "SpireSunRays")
end

function LightingController.Start()
	local player = Players.LocalPlayer
	CollectionService:GetInstanceAddedSignal("NightLight"):Connect(function(l: Instance)
		lightBrightness(l, LightingController.NightFactor)
	end)
	CollectionService:GetInstanceAddedSignal("WindowGlow"):Connect(function(p: Instance)
		if glowOn then
			windowGlow(p, true)
		end
	end)
	CollectionService:GetInstanceAddedSignal("NightEmitter"):Connect(function(e: Instance)
		nightEmitter(e, glowOn == true)
	end)
	SettingsController.Changed:Connect(function()
		nightApplied = -1
	end)

	local accum = 0
	RunService.RenderStepped:Connect(function(dt: number)
		accum += dt
		if accum < 0.1 then
			return
		end
		accum = 0
		local name, preset = presetFor(player)
		local target = sample(preset, Lighting.ClockTime)
		if name ~= currentPresetName then
			blendFrom = lastApplied
			blendStart = os.clock()
			currentPresetName = name
		end
		local k = target
		if blendFrom then
			local t = math.clamp((os.clock() - blendStart) / LC.BlendSeconds, 0, 1)
			k = lerpKey(blendFrom :: Key, target, t)
			if t >= 1 then
				blendFrom = nil
			end
		end
		apply(k, preset)
		lastApplied = k
		applyNight(k.nightFactor)
		local camera = Workspace.CurrentCamera
		if camera then
			updateRain(preset, camera)
		end
	end)
end

return LightingController
