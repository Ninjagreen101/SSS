--!strict
--[[
	EnvironmentService
	Owns the floor's clock and weather so every player sees the same sky.

	Clock: one in-game day every Config.World.DayNight.CycleMinutes real minutes. The server
	publishes Workspace attribute DayEpoch (the server time at which the clock read 0:00); clients
	compute the time themselves from Workspace:GetServerTimeNow(), so the sun moves smoothly with
	no replication jitter. The server also keeps Lighting.ClockTime current for server logic and
	for players whose client has not started its environment yet.

	Weather: Clear / Overcast / Rain, picked by weight (Config.Environment.Weather) and held for a
	random number of minutes. Published as Workspace attributes Weather, WeatherPrevious and
	WeatherSince (server time of the change) so clients can cross-fade.

	Terrain look: ApplyTerrainLook() sets water and material colours from Config.Environment.Terrain
	at server start (also callable from the build tools in edit mode), so the palette lives in data
	and survives terrain rebuilds.

	Other systems ask IsNight() (night-only spawns such as the Drowned Sailors on the Old Wharf)
	or listen to NightChanged.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Signal = require(Shared.Util.Signal)
local Log = require(Shared.Util.Log)

local ENV = Config.Environment
local log = Log.new("EnvironmentService")

local EnvironmentService = {}

EnvironmentService.NightChanged = Signal.new()

local dayEpoch = 0
local weather = "Clear"
local weatherUntil = 0
local night = false
local random = Random.new()

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function daySeconds(): number
	return Config.World.DayNight.CycleMinutes * 60
end

-- Current clock time (hours, 0..24).
function EnvironmentService.GetClock(): number
	local t = (now() - dayEpoch) / daySeconds()
	return (t - math.floor(t)) * 24
end

function EnvironmentService.IsNight(): boolean
	local clock = EnvironmentService.GetClock()
	return clock >= Config.World.DayNight.NightStart or clock < Config.World.DayNight.NightEnd
end

function EnvironmentService.GetWeather(): string
	return weather
end

-- Jumps the clock to `hour` (Studio testing and future story events).
function EnvironmentService.SetClock(hour: number)
	hour = math.clamp(hour, 0, 23.999)
	dayEpoch = now() - hour / 24 * daySeconds()
	Workspace:SetAttribute("DayEpoch", dayEpoch)
end

function EnvironmentService.SetWeather(name: string, minutes: number?)
	local def = ENV.Weather[name]
	if not def then
		log:Warn(`Unknown weather '{name}'`)
		return
	end
	Workspace:SetAttribute("WeatherPrevious", weather)
	weather = name
	Workspace:SetAttribute("Weather", name)
	Workspace:SetAttribute("WeatherSince", now())
	local span = minutes or random:NextNumber(def.Minutes[1], def.Minutes[2])
	weatherUntil = now() + span * 60
end

local function pickWeather(): string
	local names = {}
	local total = 0
	for name, def in ENV.Weather do
		if name ~= weather then
			table.insert(names, name)
			total += def.Weight
		end
	end
	table.sort(names)
	local roll = random:NextNumber() * total
	for _, name in names do
		roll -= ENV.Weather[name].Weight
		if roll <= 0 then
			return name
		end
	end
	return names[#names]
end

-- Water and terrain material colours from Config.Environment.Terrain. Bad hex strings or
-- materials are skipped with a warning rather than stopping the server.
function EnvironmentService.ApplyTerrainLook()
	local look = ENV.Terrain
	local terrain = Workspace.Terrain
	terrain.WaterColor = Color3.fromHex(look.WaterColor)
	terrain.WaterTransparency = look.WaterTransparency
	terrain.WaterReflectance = look.WaterReflectance
	terrain.WaterWaveSize = look.WaterWaveSize
	terrain.WaterWaveSpeed = look.WaterWaveSpeed
	for materialName, hex in look.Materials do
		local ok, err = pcall(function()
			terrain:SetMaterialColor((Enum.Material :: any)[materialName], Color3.fromHex(hex :: string))
		end)
		if not ok then
			log:Warn(`terrain colour {tostring(materialName)}: {tostring(err)}`)
		end
	end
end

function EnvironmentService.Init()
	EnvironmentService.ApplyTerrainLook()
	-- The clock starts at StartHour when the server boots.
	EnvironmentService.SetClock(ENV.StartHour)
	weather = "Clear"
	Workspace:SetAttribute("Weather", weather)
	Workspace:SetAttribute("WeatherPrevious", weather)
	Workspace:SetAttribute("WeatherSince", now())
	Workspace:SetAttribute("DayLength", daySeconds())
	weatherUntil = now() + random:NextNumber(ENV.Weather.Clear.Minutes[1], ENV.Weather.Clear.Minutes[2]) * 60
	night = EnvironmentService.IsNight()
end

function EnvironmentService.Start()
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < 0.5 then
			return
		end
		accumulator = 0
		Lighting.ClockTime = EnvironmentService.GetClock()
		local isNight = EnvironmentService.IsNight()
		if isNight ~= night then
			night = isNight
			EnvironmentService.NightChanged:Fire(isNight)
		end
		if now() >= weatherUntil then
			EnvironmentService.SetWeather(pickWeather())
		end
	end)
end

return EnvironmentService
