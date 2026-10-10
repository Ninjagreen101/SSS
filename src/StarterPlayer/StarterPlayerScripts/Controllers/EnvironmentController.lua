--!strict
--[[
	EnvironmentController
	The sky, light and sound of the floor, all computed on the client from a few server attributes
	(EnvironmentService), so nothing about the look of the world costs network traffic.

	- Clock: Lighting.ClockTime from Workspace.DayEpoch / DayLength and server time, every frame
	  (SetClockOverride pins a local hour instead, e.g. the tutorial's night).
	- Grade: brightness, ambient colours, atmosphere, colour correction and bloom blended between
	  the keyframes in Config.Environment, then weather applied on top (cross-faded over
	  WeatherBlendSeconds when the weather changes).
	- Night lights: parts tagged SpireNightLight (lamps, lanterns, candles; each has a PointLight)
	  and SpireWindow (building windows) switch on after dusk and off after dawn, each at a slightly
	  different moment. Switches are applied a batch per frame, and PointLights further than
	  LightCullRadius from the camera stay off, which keeps nights cheap on phones.
	- Beacons: the lighthouse (tag SpireBeacon) sweeps a beam across the bay at night.
	- Rain: a particle curtain that follows the camera, plus the rain bed.
	- Deep: marine snow drifting around the camera, slow glowing drifters in the wilds and soft
	  light shafts (SunRays) from the sea above; all scaled by graphics quality.
	- Ambience: the region under the player (ReplicatedStorage.FloorData.Regions grid) picks a
	  day or night sound bed, cross-faded; gulls call over the harbour by day; waterfalls (tag
	  SpireWaterfall) get a positional loop; the market bell tolls at dawn and dusk.
	  SetAmbienceDuck lowers every bed while music carries the scene (MusicController).
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local ENV = Config.Environment
local LIGHTS = ENV.Lights

local EnvironmentController = {}

local LIGHT_CULL_RADIUS = 260
local TAG_LIGHT = "SpireNightLight"
local TAG_WINDOW = "SpireWindow"
local TAG_BEACON = "SpireBeacon"
local TAG_WATERFALL = "SpireWaterfall"
local TAG_BELL = "SpireBell"

local localPlayer = Players.LocalPlayer

-- CLOCK ---------------------------------------------------------------------------------------

-- A local clock that replaces the shared day (the tutorial's night on the docks); nil = shared.
local clockOverride: number? = nil

local function clock(): number
	local override = clockOverride
	if override then
		return override
	end
	local epoch = Workspace:GetAttribute("DayEpoch")
	local length = Workspace:GetAttribute("DayLength")
	if type(epoch) ~= "number" or type(length) ~= "number" or length <= 0 then
		return Lighting.ClockTime
	end
	local t = (Workspace:GetServerTimeNow() - epoch) / length
	return (t - math.floor(t)) * 24
end
EnvironmentController.GetClock = clock

-- Pins this client's clock to `hour` (0..24) until called with nil. Light, grade, night lamps
-- and ambience all follow it; the server's day is unaffected.
function EnvironmentController.SetClockOverride(hour: number?)
	clockOverride = if hour then hour % 24 else nil
end

local function isNightAt(hour: number, offset: number): boolean
	return hour >= LIGHTS.On + offset or hour < LIGHTS.Off - offset
end

function EnvironmentController.IsNight(): boolean
	return isNightAt(clock(), 0)
end

-- GRADE ---------------------------------------------------------------------------------------

type Grade = {
	Brightness: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
	Tint: Color3,
	Contrast: number,
	Saturation: number,
	Exposure: number,
	AtmosphereColor: Color3,
	AtmosphereDecay: Color3,
	Density: number,
	Haze: number,
	Glare: number,
	Bloom: number,
}

local keyframes: { { Time: number, Grade: Grade } } = {}
for _, k in ENV.Keyframes do
	table.insert(keyframes, {
		Time = k.Time,
		Grade = {
			Brightness = k.Brightness,
			Ambient = Color3.fromHex(k.Ambient),
			OutdoorAmbient = Color3.fromHex(k.OutdoorAmbient),
			Tint = Color3.fromHex(k.Tint),
			Contrast = k.Contrast,
			Saturation = k.Saturation,
			Exposure = k.Exposure,
			AtmosphereColor = Color3.fromHex(k.AtmosphereColor),
			AtmosphereDecay = Color3.fromHex(k.AtmosphereDecay),
			Density = k.Density,
			Haze = k.Haze,
			Glare = k.Glare,
			Bloom = k.Bloom,
		},
	})
end
table.sort(keyframes, function(a, b)
	return a.Time < b.Time
end)

local function lerpGrade(a: Grade, b: Grade, t: number): Grade
	local function n(x: number, y: number): number
		return x + (y - x) * t
	end
	return {
		Brightness = n(a.Brightness, b.Brightness),
		Ambient = a.Ambient:Lerp(b.Ambient, t),
		OutdoorAmbient = a.OutdoorAmbient:Lerp(b.OutdoorAmbient, t),
		Tint = a.Tint:Lerp(b.Tint, t),
		Contrast = n(a.Contrast, b.Contrast),
		Saturation = n(a.Saturation, b.Saturation),
		Exposure = n(a.Exposure, b.Exposure),
		AtmosphereColor = a.AtmosphereColor:Lerp(b.AtmosphereColor, t),
		AtmosphereDecay = a.AtmosphereDecay:Lerp(b.AtmosphereDecay, t),
		Density = n(a.Density, b.Density),
		Haze = n(a.Haze, b.Haze),
		Glare = n(a.Glare, b.Glare),
		Bloom = n(a.Bloom, b.Bloom),
	}
end

local function gradeAt(hour: number): Grade
	local count = #keyframes
	for i = 1, count do
		local a = keyframes[i]
		local b = keyframes[i % count + 1]
		local t0, t1 = a.Time, b.Time
		if i == count then
			t1 += 24 -- wrap from the last keyframe to the first
		end
		local h = hour
		if h < t0 then
			h += 24
		end
		if h >= t0 and h <= t1 then
			local span = t1 - t0
			local t = if span > 0 then (h - t0) / span else 0
			t = t * t * (3 - 2 * t)
			return lerpGrade(a.Grade, b.Grade, t)
		end
	end
	return keyframes[1].Grade
end

type WeatherMix = { Density: number, Haze: number, Brightness: number, Saturation: number, Rain: number }

local function weatherMix(): WeatherMix
	local current = ENV.Weather[Workspace:GetAttribute("Weather") :: string? or "Clear"] or ENV.Weather.Clear
	local previous = ENV.Weather[Workspace:GetAttribute("WeatherPrevious") :: string? or "Clear"] or ENV.Weather.Clear
	local since = Workspace:GetAttribute("WeatherSince")
	local t = 1
	if type(since) == "number" then
		t = math.clamp((Workspace:GetServerTimeNow() - since) / ENV.WeatherBlendSeconds, 0, 1)
	end
	local function n(a: number, b: number): number
		return a + (b - a) * t
	end
	return {
		Density = n(previous.Density, current.Density),
		Haze = n(previous.Haze, current.Haze),
		Brightness = n(previous.Brightness, current.Brightness),
		Saturation = n(previous.Saturation, current.Saturation),
		Rain = n(previous.Rain, current.Rain),
	}
end

local atmosphere: Atmosphere
local grade: ColorCorrectionEffect
local bloom: BloomEffect

local function ensureEffects()
	local a = Lighting:FindFirstChildOfClass("Atmosphere")
	if not a then
		a = Instance.new("Atmosphere")
		a.Parent = Lighting
	end
	atmosphere = a :: Atmosphere
	local g = Lighting:FindFirstChild("SpireGrade")
	if not (g and g:IsA("ColorCorrectionEffect")) then
		local cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "SpireGrade"
		cc.Parent = Lighting
		g = cc
	end
	grade = g :: ColorCorrectionEffect
	local b = Lighting:FindFirstChildOfClass("BloomEffect")
	if not b then
		b = Instance.new("BloomEffect")
		b.Parent = Lighting
	end
	bloom = b :: BloomEffect
	bloom.Threshold = 1.6
	bloom.Size = 28
	local r = Lighting:FindFirstChildOfClass("SunRaysEffect")
	if not r then
		r = Instance.new("SunRaysEffect")
		r.Parent = Lighting
	end
	local rays = r :: SunRaysEffect
	rays.Intensity = ENV.Deep.SunRays.Intensity
	rays.Spread = ENV.Deep.SunRays.Spread
end

local function applyGrade(hour: number, mix: WeatherMix)
	local g = gradeAt(hour)
	Lighting.Brightness = g.Brightness * mix.Brightness
	Lighting.Ambient = g.Ambient
	Lighting.OutdoorAmbient = g.OutdoorAmbient
	Lighting.ExposureCompensation = g.Exposure
	grade.TintColor = g.Tint
	grade.Contrast = g.Contrast
	grade.Saturation = g.Saturation + mix.Saturation
	atmosphere.Color = g.AtmosphereColor
	atmosphere.Decay = g.AtmosphereDecay
	atmosphere.Density = math.clamp(g.Density + mix.Density, 0, 1)
	atmosphere.Haze = math.clamp(g.Haze + mix.Haze, 0, 10)
	atmosphere.Glare = g.Glare * (1 - mix.Rain)
	atmosphere.Offset = 0.25
	bloom.Intensity = g.Bloom
end

-- NIGHT LIGHTS --------------------------------------------------------------------------------

type LightState = {
	Part: BasePart,
	Offset: number, -- hours, so neighbours switch at slightly different times
	On: boolean?,
	Kind: "Lamp" | "Window",
	DayColor: Color3,
	NightColor: Color3,
	NightMaterial: Enum.Material,
	DayMaterial: Enum.Material,
	Light: PointLight?,
}

local lights: { LightState } = {}
local lightIndex: { [BasePart]: number } = {}
local cursor = 1
local windowColor = Color3.fromHex(LIGHTS.WindowColor)
local windowDay = Color3.fromHex(LIGHTS.WindowDayColor)

-- A stable pseudo-random offset per part (same on every client).
local function offsetFor(part: BasePart): number
	local p = part.Position
	local h = math.abs(math.sin(p.X * 12.9898 + p.Z * 78.233 + p.Y * 37.719) * 43758.5453)
	return (h - math.floor(h)) * LIGHTS.Stagger
end

local function track(part: Instance, kind: "Lamp" | "Window")
	if not part:IsA("BasePart") or lightIndex[part] then
		return
	end
	if kind == "Window" and part:GetAttribute("Unlit") == true then
		return -- empty houses stay dark
	end
	local state: LightState = {
		Part = part,
		Offset = offsetFor(part),
		On = nil,
		Kind = kind,
		DayColor = if kind == "Window" then windowDay else part.Color:Lerp(Color3.new(0, 0, 0), 0.45),
		NightColor = if kind == "Window" then windowColor else part.Color,
		NightMaterial = Enum.Material.Neon,
		DayMaterial = if kind == "Window" then Enum.Material.Glass else Enum.Material.SmoothPlastic,
		Light = part:FindFirstChildOfClass("PointLight"),
	}
	table.insert(lights, state)
	lightIndex[part] = #lights
end

local function untrack(part: Instance)
	if not part:IsA("BasePart") then
		return
	end
	local index = lightIndex[part]
	if not index then
		return
	end
	local last = lights[#lights]
	lights[index] = last
	lightIndex[last.Part] = index
	lights[#lights] = nil
	lightIndex[part :: BasePart] = nil
end

local function setLight(state: LightState, on: boolean, near: boolean)
	local part = state.Part
	if state.On ~= on then
		state.On = on
		part.Material = if on then state.NightMaterial else state.DayMaterial
		part.Color = if on then state.NightColor else state.DayColor
		if state.Kind == "Window" then
			part.Transparency = if on then 0 else 0.1
		end
	end
	local light = state.Light
	if light then
		local want = on and near
		if light.Enabled ~= want then
			light.Enabled = want
		end
	end
end

local function stepLights(hour: number)
	local count = #lights
	if count == 0 then
		return
	end
	local camera = Workspace.CurrentCamera
	local eye = if camera then camera.CFrame.Position else Vector3.zero
	local cull2 = LIGHT_CULL_RADIUS * LIGHT_CULL_RADIUS
	for _ = 1, math.min(LIGHTS.BatchPerFrame, count) do
		if cursor > count then
			cursor = 1
		end
		local state = lights[cursor]
		cursor += 1
		local part = state.Part
		if part.Parent == nil then
			continue
		end
		local d = part.Position - eye
		setLight(state, isNightAt(hour, state.Offset), d.X * d.X + d.Y * d.Y + d.Z * d.Z < cull2)
	end
end

-- BEACONS -------------------------------------------------------------------------------------

type Beacon = { Model: Model, Pivot: Attachment?, Beam: Beam?, Light: SpotLight? }
local beacons: { [Model]: Beacon } = {}

local function addBeacon(model: Instance)
	if not model:IsA("Model") or beacons[model] then
		return
	end
	-- the lantern room: the highest Light-channel part, else the model top
	local host: BasePart? = nil
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and CollectionService:HasTag(d, TAG_LIGHT) then
			if not host or d.Position.Y > host.Position.Y then
				host = d
			end
		end
	end
	if not host then
		return
	end
	local pivot = Instance.new("Attachment")
	pivot.Name = "BeaconPivot"
	pivot.Parent = host
	-- the beam's far end lives on the same part and is moved every frame with the sweep
	local far = Instance.new("Attachment")
	far.Name = "BeaconFar"
	far.Parent = host
	local beam = Instance.new("Beam")
	beam.Attachment0 = pivot
	beam.Attachment1 = far
	beam.Width0 = 4
	beam.Width1 = 46
	beam.FaceCamera = true
	beam.LightEmission = 1
	beam.Color = ColorSequence.new(Color3.fromHex("#FFE2A8"))
	beam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) })
	beam.Segments = 4
	beam.Enabled = false
	beam.Parent = host
	local spot = Instance.new("SpotLight")
	spot.Angle = 25
	spot.Range = 60
	spot.Brightness = 3
	spot.Color = Color3.fromHex("#FFE2A8")
	spot.Shadows = false
	spot.Enabled = false
	spot.Parent = pivot
	beacons[model] = { Model = model, Pivot = pivot, Beam = beam, Light = spot }
end

local function stepBeacons(hour: number)
	local night = isNightAt(hour, 0)
	local angle = (Workspace:GetServerTimeNow() / LIGHTS.BeaconSpinSeconds) * 2 * math.pi
	for model, beacon in beacons do
		if model.Parent == nil then
			beacons[model] = nil
			continue
		end
		local pivot = beacon.Pivot
		if not pivot or not pivot.Parent then
			continue
		end
		local host = pivot.Parent :: BasePart
		local far = host:FindFirstChild("BeaconFar") :: Attachment?
		if beacon.Beam then
			beacon.Beam.Enabled = night
		end
		if beacon.Light then
			beacon.Light.Enabled = night
		end
		if night and far then
			local dir = Vector3.new(math.cos(angle), -0.07, math.sin(angle))
			pivot.WorldCFrame = CFrame.lookAt(pivot.WorldPosition, pivot.WorldPosition + dir)
			far.WorldPosition = pivot.WorldPosition + dir * 260
		end
	end
end

-- RAIN --------------------------------------------------------------------------------------

local rainPart: Part? = nil
local rainEmitter: ParticleEmitter? = nil

local function ensureRain()
	if rainPart then
		return
	end
	local p = Instance.new("Part")
	p.Name = "SpireRain"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(160, 1, 160)
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/smoke_main.dds"
	e.Color = ColorSequence.new(Color3.fromHex("#C8DCE6"))
	e.Transparency = NumberSequence.new(0.55)
	e.Size = NumberSequence.new(0.18)
	e.Squash = NumberSequence.new(-3.5)
	e.Orientation = Enum.ParticleOrientation.VelocityParallel
	e.EmissionDirection = Enum.NormalId.Bottom
	e.Speed = NumberRange.new(90, 110)
	e.Lifetime = NumberRange.new(0.8, 1)
	e.LightInfluence = 1
	e.Rate = 0
	e.Parent = p
	p.Parent = Workspace.CurrentCamera
	rainPart = p
	rainEmitter = e
end

local function qualityScale(): number
	local ok, level = pcall(function()
		return UserSettings().GameSettings.SavedQualityLevel.Value
	end)
	if not ok or type(level) ~= "number" or level == 0 then
		return 0.6 -- automatic quality: be conservative
	end
	return math.clamp(level / 10, 0.2, 1)
end

local function stepRain(mix: WeatherMix)
	if mix.Rain <= 0.01 then
		if rainEmitter then
			rainEmitter.Rate = 0
		end
		return
	end
	ensureRain()
	local camera = Workspace.CurrentCamera
	if rainPart and camera then
		if rainPart.Parent ~= camera then
			rainPart.Parent = camera
		end
		rainPart.CFrame = CFrame.new(camera.CFrame.Position + Vector3.new(0, 70, 0))
	end
	if rainEmitter then
		rainEmitter.Rate = ENV.RainParticleRate * mix.Rain * qualityScale()
	end
end

-- AMBIENCE ------------------------------------------------------------------------------------

type Grid = { Data: string, Cell: number, Origin: Vector2, Columns: number, Legend: { [string]: string } }
local grid: Grid? = nil

local function loadGrid()
	local folder = ReplicatedStorage:FindFirstChild("FloorData")
	local value = folder and folder:FindFirstChild("Regions")
	if not (value and value:IsA("StringValue")) then
		return
	end
	local legend: { [string]: string } = {}
	local raw = value:GetAttribute("Legend")
	if type(raw) == "string" then
		for _, pair in string.split(raw, ",") do
			local parts = string.split(pair, "=")
			if #parts == 2 then
				legend[parts[1]] = parts[2]
			end
		end
	end
	local origin = value:GetAttribute("Origin")
	grid = {
		Data = value.Value,
		Cell = (value:GetAttribute("Cell") :: number?) or ENV.RegionCell,
		Origin = if typeof(origin) == "Vector2" then origin else Vector2.new(-1500, -1500),
		Columns = (value:GetAttribute("Columns") :: number?) or 60,
		Legend = legend,
	}
end

function EnvironmentController.RegionAt(position: Vector3): string?
	local g = grid
	if not g then
		return nil
	end
	local i = math.floor((position.X - g.Origin.X) / g.Cell)
	local k = math.floor((position.Z - g.Origin.Y) / g.Cell)
	if i < 0 or k < 0 or i >= g.Columns or k >= g.Columns then
		return nil
	end
	local index = k * g.Columns + i + 1
	return g.Legend[string.sub(g.Data, index, index)]
end

local bedGroup: SoundGroup
local beds: { [string]: Sound } = {}
local activeBed: string? = nil
local rainSound: Sound? = nil
local nextGull = 0
local region: string? = nil

local function bed(id: string): Sound
	local existing = beds[id]
	if existing then
		return existing
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Looped = true
	s.Volume = 0
	s.SoundGroup = bedGroup
	s.Parent = bedGroup
	beds[id] = s
	return s
end

local function fadeTo(sound: Sound, volume: number)
	if volume > 0 and not sound.IsPlaying then
		sound:Play()
	end
	local tween = TweenService:Create(sound, TweenInfo.new(ENV.AmbienceFadeSeconds), { Volume = volume })
	tween:Play()
	if volume <= 0 then
		tween.Completed:Once(function()
			if sound.Volume <= 0.001 then
				sound:Stop()
			end
		end)
	end
end

-- Lowers the whole ambience group by `fraction` (0 = full volume, 1 = silent), faded.
function EnvironmentController.SetAmbienceDuck(fraction: number)
	if not bedGroup then
		return
	end
	local goal = 1 - math.clamp(fraction, 0, 1)
	TweenService:Create(bedGroup, TweenInfo.new(ENV.Music.CrossfadeSeconds), { Volume = goal }):Play()
end

local function stepAmbience(hour: number, mix: WeatherMix)
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local position = if root then root.Position else (Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame.Position)
	if not position then
		return
	end
	region = EnvironmentController.RegionAt(position)
	local def = region and ENV.Ambience[region]
	local night = isNightAt(hour, 0)
	local id = def and (if night then def.Night else def.Day)
	-- under heavy rain the beds sink so the rain carries the scene
	local volume = (def and def.Volume or 0) * (1 - 0.5 * mix.Rain)
	if id ~= activeBed then
		if activeBed then
			fadeTo(bed(activeBed), 0)
		end
		activeBed = id
	end
	if id then
		local s = bed(id)
		if math.abs(s.Volume - volume) > 0.02 or not s.IsPlaying then
			fadeTo(s, volume)
		end
	end
	-- rain bed
	if mix.Rain > 0.01 and not rainSound then
		local s = Instance.new("Sound")
		s.SoundId = ENV.RainSound
		s.Looped = true
		s.Volume = 0
		s.Parent = bedGroup
		rainSound = s
	end
	if rainSound then
		local want = ENV.RainVolume * mix.Rain
		if want > 0.01 and not rainSound.IsPlaying then
			rainSound:Play()
		end
		rainSound.Volume = want
		if want <= 0.01 and rainSound.IsPlaying then
			rainSound:Stop()
		end
	end
	-- gulls over the harbour by day
	local t = os.clock()
	if (region == "Harbour" or region == "OldWharf" or region == "Town") and not night and t >= nextGull then
		nextGull = t + math.random(ENV.GullInterval[1], ENV.GullInterval[2])
		if region ~= "Town" or position.Y < 40 then
			local gull = Instance.new("Sound")
			gull.SoundId = ENV.Sounds.Gulls
			gull.Volume = 0.25
			gull.PlaybackSpeed = 0.9 + math.random() * 0.2
			gull.SoundGroup = bedGroup
			gull.Parent = bedGroup
			gull:Play()
			gull.Ended:Once(function()
				gull:Destroy()
			end)
		end
	end
end

local function addWaterfall(part: Instance)
	if not part:IsA("BasePart") or part:FindFirstChild("FallSound") then
		return
	end
	local s = Instance.new("Sound")
	s.Name = "FallSound"
	s.SoundId = ENV.Sounds.Waterfall
	s.Looped = true
	s.Volume = 0.5
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 10
	s.RollOffMaxDistance = 110
	s.Parent = part
	s:Play()
end

-- the bell tolls once at dawn and once at dusk
local lastBellHour = -1
local function stepBell(hour: number)
	for _, toll in { 6, 18 } do
		if hour >= toll and hour < toll + 0.25 and lastBellHour ~= toll then
			lastBellHour = toll
			for _, tower in CollectionService:GetTagged(TAG_BELL) do
				local host = if tower:IsA("BasePart") then tower else (tower:IsA("Model") and tower.PrimaryPart or tower:FindFirstChildWhichIsA("BasePart", true))
				if host then
					local s = Instance.new("Sound")
					s.SoundId = ENV.Sounds.Bell
					s.Volume = 1
					s.RollOffMode = Enum.RollOffMode.InverseTapered
					s.RollOffMinDistance = 40
					s.RollOffMaxDistance = 900
					s.Parent = host
					s:Play()
					s.Ended:Once(function()
						s:Destroy()
					end)
				end
			end
		end
	end
end

-- DEEP --------------------------------------------------------------------------------------
-- The drowned-world layer. Everything here is client-only and cosmetic: a box of marine snow that
-- follows the camera, and a handful of glowing drifters that wander near the camera outside town
-- (respawned ahead of the player when they fall behind). 1 emitter + ~10 parts in total.

local DEEP = ENV.Deep
local deepFolder: Folder? = nil
local snowBox: Part? = nil
local snowEmitter: ParticleEmitter? = nil

type Drifter = { Part: Part, Anchor: Vector3, Heading: Vector3, Phase: number }
local drifters: { Drifter } = {}
local drifterRandom = Random.new()
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = false

local function ensureDeep(): Folder
	if deepFolder and deepFolder.Parent then
		return deepFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "SpireDeep"
	folder.Parent = Workspace.CurrentCamera
	deepFolder = folder

	local box = Instance.new("Part")
	box.Name = "MarineSnow"
	box.Anchored = true
	box.CanCollide = false
	box.CanQuery = false
	box.CanTouch = false
	box.Transparency = 1
	box.Size = Vector3.new(110, 50, 110)
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Color = ColorSequence.new(Color3.fromHex(DEEP.SnowColor))
	e.LightEmission = 0.5
	e.LightInfluence = 0.4
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.25, 0.45),
		NumberSequenceKeypoint.new(0.8, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Size = NumberSequence.new(0.16, 0.08)
	e.Lifetime = NumberRange.new(6, 10)
	e.Speed = NumberRange.new(0.2, 0.8)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Acceleration = Vector3.new(0, -0.35, 0) -- sinks slowly, like silt
	e.Shape = Enum.ParticleEmitterShape.Box
	e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	e.Rate = 0
	e.Parent = box
	box.Parent = folder
	snowBox = box
	snowEmitter = e

	local color = Color3.fromHex(DEEP.DrifterColor)
	for i = 1, DEEP.Drifters do
		local part = Instance.new("Part")
		part.Name = `Drifter{i}`
		part.Shape = Enum.PartType.Ball
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = color
		part.Size = Vector3.one * drifterRandom:NextNumber(0.9, 1.8)
		part.Transparency = 1
		part.Parent = folder
		-- trailing tendrils: a short faint trail of motes below the bell
		local att = Instance.new("Attachment")
		att.Position = Vector3.new(0, -part.Size.Y / 2, 0)
		att.Parent = part
		local tail = Instance.new("ParticleEmitter")
		tail.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		tail.Color = ColorSequence.new(color)
		tail.LightEmission = 1
		tail.Size = NumberSequence.new(0.25, 0.05)
		tail.Transparency = NumberSequence.new(0.3, 1)
		tail.Lifetime = NumberRange.new(1, 1.6)
		tail.Speed = NumberRange.new(0.5, 1)
		tail.EmissionDirection = Enum.NormalId.Bottom
		tail.Rate = 4
		tail.Parent = att
		table.insert(drifters, { Part = part, Anchor = Vector3.zero, Heading = Vector3.zero, Phase = drifterRandom:NextNumber(0, 6.28) })
	end
	rayParams.FilterDescendantsInstances = { folder }
	return folder
end

-- Puts a drifter somewhere ahead of / around the camera, hovering 5-16 studs above the ground or water.
local function respawnDrifter(d: Drifter, around: Vector3)
	local angle = drifterRandom:NextNumber(0, 2 * math.pi)
	local dist = drifterRandom:NextNumber(20, DEEP.DrifterRadius)
	local probe = around + Vector3.new(math.cos(angle) * dist, 80, math.sin(angle) * dist)
	local exclude: { Instance } = { ensureDeep() }
	local character = localPlayer.Character
	if character then
		table.insert(exclude, character)
	end
	rayParams.FilterDescendantsInstances = exclude
	local hit = Workspace:Raycast(probe, Vector3.new(0, -200, 0), rayParams)
	local ground = if hit then hit.Position.Y else around.Y - 6
	d.Anchor = Vector3.new(probe.X, ground + drifterRandom:NextNumber(5, 16), probe.Z)
	local h = drifterRandom:NextNumber(0, 2 * math.pi)
	d.Heading = Vector3.new(math.cos(h), 0, math.sin(h)) * drifterRandom:NextNumber(0.6, 1.6)
end

local function stepDeep(dt: number, hour: number, mix: WeatherMix)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	ensureDeep()
	local quality = qualityScale()
	local nightBlend = if isNightAt(hour, 0) then 1 else 0
	local camPos = camera.CFrame.Position
	if snowBox and snowEmitter then
		snowBox.CFrame = CFrame.new(camPos + camera.CFrame.LookVector * 30)
		local boost = 1 + (DEEP.SnowNightBoost - 1) * nightBlend
		snowEmitter.Rate = DEEP.SnowRate * quality * boost * (1 - mix.Rain * 0.7)
	end
	-- drifters: hidden in town and on the lowest quality settings
	local wild = region ~= nil and region ~= "Town" and quality > 0.25
	local alpha = if wild
		then DEEP.DrifterDayTransparency + (DEEP.DrifterNightTransparency - DEEP.DrifterDayTransparency) * nightBlend
		else 1
	local now = os.clock()
	for _, d in drifters do
		if not wild then
			d.Part.Transparency = 1
			continue
		end
		local flat = Vector3.new(d.Anchor.X - camPos.X, 0, d.Anchor.Z - camPos.Z)
		if d.Anchor == Vector3.zero or flat.Magnitude > DEEP.DrifterRadius * 1.4 then
			respawnDrifter(d, camPos)
		end
		d.Anchor += d.Heading * dt
		-- a jellyfish pulse: slow bob plus a quick contraction every few seconds
		local bob = math.sin(now * 0.7 + d.Phase) * 1.4
		local pulse = math.max(0, math.sin(now * 2.2 + d.Phase)) ^ 6 * 0.6
		d.Part.CFrame = CFrame.new(d.Anchor + Vector3.new(0, bob + pulse, 0))
		d.Part.Transparency = alpha + (1 - alpha) * 0.25 * (1 - pulse)
	end
end

-- LIFECYCLE -----------------------------------------------------------------------------------

function EnvironmentController.Init()
	ensureEffects()
	bedGroup = Instance.new("SoundGroup")
	bedGroup.Name = "Ambience"
	bedGroup.Volume = 1
	bedGroup.Parent = SoundService
end

function EnvironmentController.Start()
	loadGrid()
	local folder = ReplicatedStorage:FindFirstChild("FloorData")
	if folder then
		folder.ChildAdded:Connect(loadGrid)
	end
	for _, tag in { TAG_LIGHT, TAG_WINDOW } do
		local kind: "Lamp" | "Window" = if tag == TAG_WINDOW then "Window" else "Lamp"
		for _, part in CollectionService:GetTagged(tag) do
			track(part, kind)
		end
		CollectionService:GetInstanceAddedSignal(tag):Connect(function(part)
			track(part, kind)
		end)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(untrack)
	end
	for _, model in CollectionService:GetTagged(TAG_BEACON) do
		addBeacon(model)
	end
	CollectionService:GetInstanceAddedSignal(TAG_BEACON):Connect(addBeacon)
	for _, part in CollectionService:GetTagged(TAG_WATERFALL) do
		addWaterfall(part)
	end
	CollectionService:GetInstanceAddedSignal(TAG_WATERFALL):Connect(addWaterfall)

	local slow = 0
	local ambienceTimer = 0
	local lastMix = weatherMix()
	RunService.RenderStepped:Connect(function(dt: number)
		local hour = clock()
		Lighting.ClockTime = hour
		stepLights(hour)
		stepBeacons(hour)
		stepDeep(dt, hour, lastMix)
		slow += dt
		ambienceTimer += dt
		if slow >= 1 / ENV.UpdateHz then
			slow = 0
			local mix = weatherMix()
			applyGrade(hour, mix)
			stepRain(mix)
			lastMix = mix
			stepBell(hour)
			if ambienceTimer >= 1 then
				ambienceTimer = 0
				stepAmbience(hour, mix)
			end
		end
	end)
end

return EnvironmentController
