--!strict
--[[
	UISound
	Plays interface sounds from Config.Assets.Sounds with a small pool so rapid
	clicks never cut each other off. Volume follows the player's UI and
	Master volume settings (set by UIController when settings load/change).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Config = require(ReplicatedStorage:WaitForChild("Shared").Config)

export type SoundName =
	"UIClick"
	| "UIOpen"
	| "UIClose"
	| "UIConfirm"
	| "UIError"
	| "UIToast"
	| "ItemEquip"
	| "ItemPickup"
	| "GoldPickup"
	| "RareLoot"
	| "LegendaryLoot"
	| "CraftDone"
	| "UpgradeSuccess"
	| "UpgradeFail"
	| "ItemUse"
	| "LevelUp"
	| "LevelUpHigh"
	| "SkillUnlock"

local POOL_SIZE = 3

local UISound = {}

local pools: { [string]: { Sound } } = {}
local cursor: { [string]: number } = {}
local volumeScale = 0.56 -- default UI (0.7) x master (0.8)
local folder: Folder? = nil

local function getFolder(): Folder
	if folder then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "SpireUISounds"
	created.Parent = SoundService
	folder = created
	return created
end

local function getPool(name: string): { Sound }?
	local existing = pools[name]
	if existing then
		return existing
	end
	local info = (Config.Assets.Sounds :: any)[name]
	if not info then
		return nil
	end
	local pool = {}
	for index = 1, POOL_SIZE do
		local sound = Instance.new("Sound")
		sound.Name = `{name}_{index}`
		sound.SoundId = info.Id
		sound.Volume = info.Volume * volumeScale
		sound.PlaybackSpeed = info.Pitch
		sound.Parent = getFolder()
		table.insert(pool, sound)
	end
	pools[name] = pool
	cursor[name] = 1
	return pool
end

function UISound.Play(name: SoundName)
	local pool = getPool(name)
	if not pool or volumeScale <= 0 then
		return
	end
	local index = cursor[name]
	cursor[name] = index % #pool + 1
	local sound = pool[index]
	-- Tiny random pitch variation (5%) so repeated clicks don't sound robotic.
	local info = (Config.Assets.Sounds :: any)[name]
	sound.PlaybackSpeed = info.Pitch * (0.975 + math.random() * 0.05)
	sound.TimePosition = 0
	sound:Play()
end

-- volume = UiVolume x MasterVolume (0..1)
function UISound.SetVolume(volume: number)
	volumeScale = math.clamp(volume, 0, 1)
	for name, pool in pools do
		local info = (Config.Assets.Sounds :: any)[name]
		for _, sound in pool do
			sound.Volume = info.Volume * volumeScale
		end
	end
end

return UISound
