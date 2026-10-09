--!strict
--[[
	Environment: lighting through the day, weather, night lights and ambient sound (Spec Section 4).

	Keys are hours of the in-game clock (Lighting.ClockTime, 0..24). EnvironmentController blends
	between the two keyframes around the current time, then applies weather on top. Colours are
	hex strings so this table stays plain data.

	Sound ids are Roblox Creator Store audio (Pro Sound Effects library, free to use in experiences).
]]

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

export type Keyframe = {
	Time: number,
	Brightness: number,
	Ambient: string,
	OutdoorAmbient: string,
	Tint: string, -- ColorCorrection tint
	Contrast: number,
	Saturation: number,
	Exposure: number,
	AtmosphereColor: string,
	AtmosphereDecay: string,
	Density: number,
	Haze: number,
	Glare: number,
	Bloom: number, -- Bloom intensity
}

export type Weather = {
	Weight: number, -- chance of being picked next
	Minutes: { number }, -- how long it lasts (min, max)
	Density: number, -- added to atmosphere density
	Haze: number, -- added to haze
	Brightness: number, -- multiplies brightness
	Saturation: number, -- added to saturation
	Rain: number, -- 0..1 rain particle and sound strength
}

export type Ambience = {
	Day: string?, -- looping sound id by day
	Night: string?, -- by night
	Volume: number,
}

return TableUtil.DeepFreeze({
	-- One full day every DayNight.CycleMinutes (Config.World). The server owns the clock.
	StartHour = 9, -- clock time when server time is 0 (so a fresh server starts in the morning)
	UpdateHz = 4, -- client lighting blend updates per second

	-- Dark fantasy, drowned: the floor sits at the bottom of a flooded tower, so daylight arrives
	-- filtered through the sea above. Cold teal-grey by day, a bruised violet dusk, near-abyss
	-- nights. Saturation stays negative so the Current's teal glow is the brightest colour on
	-- screen; nights keep enough OutdoorAmbient to stay readable on phone screens.
	Keyframes = {
		{
			Time = 0,
			Brightness = 0.7,
			Ambient = "#122226",
			OutdoorAmbient = "#1E363C",
			Tint = "#9FD6D2",
			Contrast = 0.16,
			Saturation = -0.22,
			Exposure = -0.15,
			AtmosphereColor = "#14303A",
			AtmosphereDecay = "#061418",
			Density = 0.44,
			Haze = 2.2,
			Glare = 0,
			Bloom = 1.1,
		},
		{
			Time = 5.4,
			Brightness = 1.0,
			Ambient = "#1A2228",
			OutdoorAmbient = "#33444C",
			Tint = "#C8DCD6",
			Contrast = 0.14,
			Saturation = -0.16,
			Exposure = -0.08,
			AtmosphereColor = "#4E5C6A",
			AtmosphereDecay = "#2A2440",
			Density = 0.42,
			Haze = 2.6,
			Glare = 0.2,
			Bloom = 1.0,
		},
		{
			Time = 7.5,
			Brightness = 1.8,
			Ambient = "#26323A",
			OutdoorAmbient = "#5A6E74",
			Tint = "#DCEEEA",
			Contrast = 0.12,
			Saturation = -0.12,
			Exposure = -0.04,
			AtmosphereColor = "#6E8C92",
			AtmosphereDecay = "#2E4A50",
			Density = 0.38,
			Haze = 2.0,
			Glare = 0.1,
			Bloom = 0.8,
		},
		{
			Time = 13,
			Brightness = 2.2,
			Ambient = "#2C383E",
			OutdoorAmbient = "#667A7E",
			Tint = "#E4F4F0",
			Contrast = 0.12,
			Saturation = -0.1,
			Exposure = -0.02,
			AtmosphereColor = "#7A989C",
			AtmosphereDecay = "#38565A",
			Density = 0.36,
			Haze = 1.6,
			Glare = 0.05,
			Bloom = 0.7,
		},
		{
			Time = 17.3,
			Brightness = 1.8,
			Ambient = "#2E2C34",
			OutdoorAmbient = "#6A6070",
			Tint = "#E6D8E0",
			Contrast = 0.14,
			Saturation = -0.1,
			Exposure = -0.04,
			AtmosphereColor = "#7A6A80",
			AtmosphereDecay = "#3A2E48",
			Density = 0.4,
			Haze = 2.2,
			Glare = 0.3,
			Bloom = 0.9,
		},
		{
			Time = 19,
			Brightness = 1.0,
			Ambient = "#1C1E2A",
			OutdoorAmbient = "#383A52",
			Tint = "#C4C6E2",
			Contrast = 0.16,
			Saturation = -0.16,
			Exposure = -0.1,
			AtmosphereColor = "#3C3C5C",
			AtmosphereDecay = "#141A2C",
			Density = 0.43,
			Haze = 2.4,
			Glare = 0.1,
			Bloom = 1.1,
		},
		{
			Time = 21,
			Brightness = 0.7,
			Ambient = "#122226",
			OutdoorAmbient = "#1E363C",
			Tint = "#9FD6D2",
			Contrast = 0.16,
			Saturation = -0.22,
			Exposure = -0.15,
			AtmosphereColor = "#14303A",
			AtmosphereDecay = "#061418",
			Density = 0.44,
			Haze = 2.2,
			Glare = 0,
			Bloom = 1.1,
		},
	} :: { Keyframe },

	-- Lamps, windows and beacons light between these hours. Each light gets a random offset of
	-- up to LightStagger hours so a street lights up gradually rather than all at once.
	Lights = {
		On = 18.4,
		Off = 5.8,
		Stagger = 0.6,
		WindowColor = "#FFA85A",
		WindowDayColor = "#1B2229",
		LampBrightness = 1.6,
		BatchPerFrame = 120, -- light switches applied per frame (keeps dusk smooth on phones)
		BeaconSpinSeconds = 14, -- one sweep of the lighthouse beam
	},

	-- The drowned-world layer (EnvironmentController): marine snow drifting around the camera and
	-- slow glowing drifters (small jelly-like lights) in the wilds. Both scale with graphics quality.
	Deep = {
		SnowRate = 26, -- particles/s at full quality
		SnowColor = "#B8E8E0",
		SnowNightBoost = 1.6, -- multiplies the rate at night (the snow catches the Current light)
		Drifters = 10, -- glowing drifters kept around the camera outside town
		DrifterRadius = 90, -- they wander within this radius of the camera
		DrifterColor = "#3FE0D0",
		DrifterDayTransparency = 0.75, -- faint by day, bright at night
		DrifterNightTransparency = 0.15,
		SunRays = { Intensity = 0.08, Spread = 0.7 }, -- shafts of light from the sea above
	},

	-- Terrain look, applied by EnvironmentService when the server starts (so a rebuild never
	-- loses it): dark wet stone, mud-brown sand, bog grass and deep teal water.
	Terrain = {
		WaterColor = "#0E3A3C",
		WaterTransparency = 0.55,
		WaterReflectance = 0.6,
		WaterWaveSize = 0.08,
		WaterWaveSpeed = 6,
		Materials = {
			Grass = "#3C4A34",
			LeafyGrass = "#34402E",
			Mud = "#3A3428",
			Ground = "#40382E",
			Sand = "#6E6656",
			Rock = "#4A4C4E",
			Basalt = "#26282A",
			Slate = "#3E4446",
			Pavement = "#565A58",
			Cobblestone = "#4E504C",
			Limestone = "#7A766A",
			Sandstone = "#6A5E4E",
			Salt = "#9AA29E",
			Asphalt = "#2E3032",
			Glacier = "#5E8C8E",
		},
	},

	Weather = {
		Clear = { Weight = 60, Minutes = { 6, 12 }, Density = 0, Haze = 0, Brightness = 1, Saturation = 0, Rain = 0 },
		Overcast = { Weight = 25, Minutes = { 4, 8 }, Density = 0.06, Haze = 0.8, Brightness = 0.8, Saturation = -0.1, Rain = 0 },
		Rain = { Weight = 15, Minutes = { 3, 6 }, Density = 0.12, Haze = 1.4, Brightness = 0.65, Saturation = -0.18, Rain = 1 },
	} :: { [string]: Weather },
	WeatherBlendSeconds = 20, -- how long a weather change takes to fade in
	RainParticleRate = 450, -- at Rain = 1, scaled down on low graphics quality

	-- Music (MusicController). One layer plays at a time, cross-faded over CrossfadeSeconds; the
	-- MusicVolume setting scales it. A track id must be licensed audio (Creator Store); an empty id
	-- means that layer is silent and the ambience bed carries the moment alone.
	Music = {
		CrossfadeSeconds = 2,
		Volume = 0.5,
		-- The 3-phase Guardian track (Spec Section 13), one layer per phase, plus the victory sting.
		Guardian = {
			Brinewarden = { Phase1 = "", Phase2 = "", Phase3 = "", Victory = "" },
		} :: { [string]: { Phase1: string, Phase2: string, Phase3: string, Victory: string } },
	},

	-- Ambient beds per region (Layouts' Region names). One bed plays at a time, cross-faded.
	Ambience = {
		Town = { Day = "rbxassetid://9112903933", Night = "rbxassetid://9112764573", Volume = 0.22 },
		Harbour = { Day = "rbxassetid://9112829678", Night = "rbxassetid://9112829678", Volume = 0.35 },
		OldWharf = { Day = "rbxassetid://9112829678", Night = "rbxassetid://9112764573", Volume = 0.3 },
		TidepoolMarsh = { Day = "rbxassetid://9112865468", Night = "rbxassetid://9114894514", Volume = 0.35 },
		RustwoodForest = { Day = "rbxassetid://9112806209", Night = "rbxassetid://9112764573", Volume = 0.35 },
		Downs = { Day = "rbxassetid://9112761455", Night = "rbxassetid://9112764573", Volume = 0.3 },
		Cistern = { Day = "rbxassetid://9120505297", Night = "rbxassetid://9120505297", Volume = 0.4 },
		FirstGate = { Day = "rbxassetid://9112761455", Night = "rbxassetid://9112764573", Volume = 0.3 },
	} :: { [string]: Ambience },
	AmbienceFadeSeconds = 3,
	RainSound = "rbxassetid://9112856881",
	RainVolume = 0.45,
	Sounds = {
		Gulls = "rbxassetid://9118858002", -- one-shots over the harbour by day
		Waterfall = "rbxassetid://9120552550", -- looped at every canal waterfall
		Bell = "rbxassetid://9113804436", -- the market bell tower rings at dawn and dusk
	},
	GullInterval = { 18, 40 }, -- seconds between gull calls while in the harbour by day
	RegionCell = 50, -- studs per cell of the baked region grid (Workspace.FloorData.Regions)
})
