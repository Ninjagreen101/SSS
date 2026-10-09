--!strict
-- Lighting presets. Each floor has a preset made of time-of-day keyframes that
-- the client blends between; zones (dungeons, caves) can override the preset.
-- Colours are hex strings so this module stays free of Roblox datatypes.

export type LightingKey = {
	clock: number, -- hours, 0..24
	ambient: string,
	outdoorAmbient: string,
	brightness: number,
	colorShift: string,
	fogColor: string,
	atmosphereDensity: number,
	atmosphereHaze: number,
	atmosphereGlare: number,
	atmosphereColor: string,
	atmosphereDecay: string,
	ccTint: string,
	ccSaturation: number,
	ccContrast: number,
	ccBrightness: number,
	bloomIntensity: number,
	sunRays: number,
	exposure: number,
	nightFactor: number, -- 0 day .. 1 night: scales lanterns, window glow and canal glow
}

export type Preset = {
	technology: string,
	environmentDiffuse: number,
	environmentSpecular: number,
	shadowSoftness: number,
	geographicLatitude: number,
	bloomThreshold: number,
	bloomSize: number,
	sunRaysSpread: number,
	rain: boolean,
	outdoor: boolean,
	keys: { LightingKey },
}

local Lowharbor: Preset = {
	technology = "Future",
	environmentDiffuse = 0.55,
	environmentSpecular = 0.9, -- wet stone reads as glossy
	shadowSoftness = 0.25,
	geographicLatitude = 38,
	bloomThreshold = 1.4,
	bloomSize = 28,
	sunRaysSpread = 0.6,
	rain = true,
	outdoor = true,
	keys = {
		{
			clock = 0, ambient = "#141A26", outdoorAmbient = "#22304A", brightness = 0.6, colorShift = "#2C4B6E",
			fogColor = "#0E1622", atmosphereDensity = 0.42, atmosphereHaze = 2.4, atmosphereGlare = 0,
			atmosphereColor = "#3A4E66", atmosphereDecay = "#1A2B40", ccTint = "#C8D6F0", ccSaturation = -0.18,
			ccContrast = 0.12, ccBrightness = -0.02, bloomIntensity = 0.9, sunRays = 0, exposure = 0.1, nightFactor = 1,
		},
		{
			clock = 5.5, ambient = "#1C2232", outdoorAmbient = "#384660", brightness = 1.1, colorShift = "#6E5A70",
			fogColor = "#2A2E3E", atmosphereDensity = 0.4, atmosphereHaze = 2.2, atmosphereGlare = 0.2,
			atmosphereColor = "#8A7E8E", atmosphereDecay = "#4A4660", ccTint = "#E8DCE6", ccSaturation = -0.12,
			ccContrast = 0.1, ccBrightness = 0, bloomIntensity = 0.7, sunRays = 0.05, exposure = 0.05, nightFactor = 0.6,
		},
		{
			clock = 8, ambient = "#2A2E36", outdoorAmbient = "#6C7280", brightness = 2.0, colorShift = "#B8B0A0",
			fogColor = "#5A6270", atmosphereDensity = 0.36, atmosphereHaze = 1.8, atmosphereGlare = 0.3,
			atmosphereColor = "#B4BCC6", atmosphereDecay = "#6E7A88", ccTint = "#F2F0EA", ccSaturation = -0.1,
			ccContrast = 0.08, ccBrightness = 0.02, bloomIntensity = 0.5, sunRays = 0.08, exposure = 0, nightFactor = 0,
		},
		{
			clock = 13, ambient = "#30343C", outdoorAmbient = "#7A808C", brightness = 2.3, colorShift = "#C8C2B4",
			fogColor = "#6A7280", atmosphereDensity = 0.34, atmosphereHaze = 1.6, atmosphereGlare = 0.35,
			atmosphereColor = "#C2C8D0", atmosphereDecay = "#78848E", ccTint = "#F4F2EC", ccSaturation = -0.08,
			ccContrast = 0.08, ccBrightness = 0.03, bloomIntensity = 0.45, sunRays = 0.1, exposure = 0, nightFactor = 0,
		},
		{
			clock = 17.5, ambient = "#2C2A30", outdoorAmbient = "#6A5E62", brightness = 1.7, colorShift = "#D89A6A",
			fogColor = "#5E4E50", atmosphereDensity = 0.38, atmosphereHaze = 2.0, atmosphereGlare = 0.6,
			atmosphereColor = "#C8967A", atmosphereDecay = "#6A4E5A", ccTint = "#F6E2CE", ccSaturation = -0.05,
			ccContrast = 0.1, ccBrightness = 0.01, bloomIntensity = 0.6, sunRays = 0.14, exposure = 0.02, nightFactor = 0.2,
		},
		{
			clock = 19.5, ambient = "#1A1E2C", outdoorAmbient = "#2E3A54", brightness = 0.9, colorShift = "#4A4E78",
			fogColor = "#161E2C", atmosphereDensity = 0.42, atmosphereHaze = 2.4, atmosphereGlare = 0.1,
			atmosphereColor = "#4C5A78", atmosphereDecay = "#22304A", ccTint = "#D2DCF2", ccSaturation = -0.15,
			ccContrast = 0.12, ccBrightness = -0.01, bloomIntensity = 0.85, sunRays = 0.02, exposure = 0.08, nightFactor = 0.9,
		},
	},
}

local SunkenCistern: Preset = {
	technology = "Future",
	environmentDiffuse = 0.2,
	environmentSpecular = 1,
	shadowSoftness = 0.35,
	geographicLatitude = 38,
	bloomThreshold = 1.2,
	bloomSize = 32,
	sunRaysSpread = 0,
	rain = false,
	outdoor = false,
	keys = {
		{
			clock = 0, ambient = "#0E1A20", outdoorAmbient = "#0A1418", brightness = 0, colorShift = "#000000",
			fogColor = "#081216", atmosphereDensity = 0.5, atmosphereHaze = 1.2, atmosphereGlare = 0,
			atmosphereColor = "#14363C", atmosphereDecay = "#0A1C22", ccTint = "#BEE8E4", ccSaturation = -0.1,
			ccContrast = 0.16, ccBrightness = -0.02, bloomIntensity = 1.1, sunRays = 0, exposure = 0.25, nightFactor = 1,
		},
	},
}

local Cave: Preset = {
	technology = "Future",
	environmentDiffuse = 0.25,
	environmentSpecular = 0.8,
	shadowSoftness = 0.3,
	geographicLatitude = 38,
	bloomThreshold = 1.2,
	bloomSize = 30,
	sunRaysSpread = 0,
	rain = false,
	outdoor = false,
	keys = {
		{
			clock = 0, ambient = "#161C22", outdoorAmbient = "#1A2028", brightness = 0.3, colorShift = "#000000",
			fogColor = "#0C1014", atmosphereDensity = 0.45, atmosphereHaze = 1.4, atmosphereGlare = 0,
			atmosphereColor = "#20282E", atmosphereDecay = "#101418", ccTint = "#DCE6E8", ccSaturation = -0.12,
			ccContrast = 0.14, ccBrightness = -0.01, bloomIntensity = 0.9, sunRays = 0, exposure = 0.15, nightFactor = 1,
		},
	},
}

local Lighting = {
	Presets = {
		Lowharbor = Lowharbor,
		SunkenCistern = SunkenCistern,
		Cave = Cave,
	} :: { [string]: Preset },
	-- zone ambience -> preset override (zones not listed use the floor preset)
	ZoneOverrides = {
		Cave = "Cave",
		Dungeon = "SunkenCistern",
	} :: { [string]: string },
	BlendSeconds = 1.5,
	NightLightBoost = 1.6,
	DayLightScale = 0.25,
	CanalGlowDay = 0.35,
	CanalGlowNight = 1.0,
}

return Lighting
