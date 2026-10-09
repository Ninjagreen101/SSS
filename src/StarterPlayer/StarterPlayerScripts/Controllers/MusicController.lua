--!strict
--[[
	MusicController
	Layered music (Spec Section 13). One layer plays at a time; changing layer cross-fades over
	Config.Environment.Music.CrossfadeSeconds. Everything plays through one SoundGroup whose volume
	is Music.Volume x the MusicVolume x MasterVolume settings, so a settings change never touches
	a fade in progress.

	  MusicController.Play(layerKey, soundId)  -- same key again is a no-op; "" = a silent layer
	  MusicController.Stop(fade?)              -- fades the current layer out
	  MusicController.Sting(soundId, pitch?)   -- a one-shot over the music (victory, bells)
	  MusicController.GetLayer()               -- the current layer key, or nil

	Track ids are licensed Creator Store audio chosen by the place owner; an empty id plays nothing
	and never errors. While an audible layer plays, the ambience beds duck
	(EnvironmentController.SetAmbienceDuck) so the two don't fight.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local DataController = require(script.Parent.DataController)
local EnvironmentController = require(script.Parent.EnvironmentController)

local MUSIC = Config.Environment.Music

local MusicController = {}

local AMBIENCE_DUCK = 0.6 -- the ambience beds drop to 40% under an audible layer
local STING_POOL = 3

local group: SoundGroup? = nil
local tracks: { [string]: Sound } = {} -- by sound id, reused across layers
local fades: { [Sound]: Tween } = {}
local layer: string? = nil
local layerSound: Sound? = nil
local stings: { Sound } = {}
local stingCursor = 1
local ducked = false

local function getGroup(): SoundGroup
	local existing = group
	if existing then
		return existing
	end
	local created = Instance.new("SoundGroup")
	created.Name = "SpireMusic"
	created.Volume = MUSIC.Volume
	created.Parent = SoundService
	group = created
	return created
end

local function number(key: string, fallback: number): number
	local value = DataController.GetSetting(key)
	return if type(value) == "number" then value else fallback
end

local function applyVolume()
	getGroup().Volume = MUSIC.Volume * math.clamp(number("MusicVolume", 0.6), 0, 1) * math.clamp(number("MasterVolume", 0.8), 0, 1)
end

local function setDuck(on: boolean)
	if on == ducked then
		return
	end
	ducked = on
	EnvironmentController.SetAmbienceDuck(if on then AMBIENCE_DUCK else 0)
end

local function trackFor(soundId: string): Sound
	local existing = tracks[soundId]
	if existing then
		return existing
	end
	local sound = Instance.new("Sound")
	sound.Name = "Track"
	sound.SoundId = soundId
	sound.Looped = true
	sound.Volume = 0
	sound.SoundGroup = getGroup()
	sound.Parent = getGroup()
	tracks[soundId] = sound
	return sound
end

local function fade(sound: Sound, volume: number, seconds: number)
	local previous = fades[sound]
	if previous then
		previous:Cancel()
		fades[sound] = nil
	end
	if volume > 0 and not sound.IsPlaying then
		sound:Play()
	end
	if seconds <= 0 then
		sound.Volume = volume
		if volume <= 0 then
			sound:Stop()
		end
		return
	end
	local tween = TweenService:Create(sound, TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { Volume = volume })
	fades[sound] = tween
	tween.Completed:Once(function(state: Enum.PlaybackState)
		if fades[sound] == tween then
			fades[sound] = nil
		end
		if state == Enum.PlaybackState.Completed and volume <= 0 then
			sound:Stop()
		end
	end)
	tween:Play()
end

-- Cross-fades to `layerKey`. An empty `soundId` makes the layer silent (the old one still fades).
function MusicController.Play(layerKey: string, soundId: string)
	if layer == layerKey then
		return
	end
	layer = layerKey
	local seconds = MUSIC.CrossfadeSeconds
	local nextSound = if soundId ~= "" then trackFor(soundId) else nil
	local previous = layerSound
	if previous and previous ~= nextSound then
		fade(previous, 0, seconds)
	end
	layerSound = nextSound
	if nextSound then
		if previous ~= nextSound then
			nextSound.TimePosition = 0
		end
		fade(nextSound, 1, seconds)
	end
	setDuck(nextSound ~= nil)
end

-- Fades the current layer out (default: the cross-fade time).
function MusicController.Stop(fadeSeconds: number?)
	local current = layerSound
	layer = nil
	layerSound = nil
	if current then
		fade(current, 0, if fadeSeconds ~= nil then math.max(0, fadeSeconds) else MUSIC.CrossfadeSeconds)
	end
	setDuck(false)
end

-- One-shot over the music. Empty ids are ignored.
function MusicController.Sting(soundId: string, pitch: number?)
	if soundId == "" then
		return
	end
	local sound = stings[stingCursor]
	stingCursor = stingCursor % STING_POOL + 1
	sound:Stop()
	sound.SoundId = soundId
	sound.PlaybackSpeed = pitch or 1
	sound.TimePosition = 0
	sound:Play()
end

function MusicController.GetLayer(): string?
	return layer
end

function MusicController.Init()
	local parent = getGroup()
	for index = 1, STING_POOL do
		local sound = Instance.new("Sound")
		sound.Name = `Sting{index}`
		sound.Volume = 1
		sound.SoundGroup = parent
		sound.Parent = parent
		stings[index] = sound
	end
end

function MusicController.Start()
	DataController.Observe({ "Settings" }, function()
		applyVolume()
	end)
	applyVolume()
end

return MusicController
