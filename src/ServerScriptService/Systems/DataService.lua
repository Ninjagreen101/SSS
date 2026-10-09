--!strict
-- DataService: one session-locked profile per player (ProfileStore-style
-- locking on DataStoreService.UpdateAsync), a versioned schema with a migration
-- per version bump, autosave every Config.Data.AutosaveSeconds, save on leave
-- and on shutdown, and a save block used while trades confirm.
-- When DataStores are unavailable (Studio without API access) profiles live in
-- memory for the session and a warning is printed once.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Signal = require(Shared.Util.Signal)

local DC = Config.Data

export type Profile = {
	DataVersion: number,
	Level: number,
	XP: number,
	StatPoints: number,
	SkillPoints: number,
	Position: string,
	Stats: { [string]: number },
	SkillTree: { [string]: boolean },
	Attunements: { Primary: string, Secondary: string },
	Inventory: { Capacity: number, Items: { { id: string, count: number } } },
	Equipped: { [string]: string },
	Hotbar: { string },
	Currencies: { Gold: number, Shards: number, FloorTokens: { [string]: number } },
	Quests: { [string]: { [string]: any } },
	UnlockedFloors: { number },
	Waystones: { [string]: { string } },
	LastWaystone: { [string]: string },
	Chests: { [string]: boolean },
	DungeonClears: { [string]: number },
	Cosmetics: { [string]: boolean },
	Settings: { [string]: any },
	Tutorial: { [string]: boolean },
	PlayStats: { PlayTime: number, Deaths: number, Joins: number },
	Purchases: { [string]: boolean },
}

local function template(): Profile
	return {
		DataVersion = DC.DataVersion,
		Level = 1,
		XP = 0,
		StatPoints = 0,
		SkillPoints = 0,
		Position = "",
		Stats = { Vitality = 0, Endurance = 0, Strength = 0, Finesse = 0, Draw = 0, Density = 0, Control = 0 },
		SkillTree = {},
		Attunements = { Primary = "", Secondary = "" },
		Inventory = { Capacity = 40, Items = {} },
		Equipped = {},
		Hotbar = {},
		Currencies = { Gold = 0, Shards = 0, FloorTokens = {} },
		Quests = {},
		UnlockedFloors = { 1 },
		Waystones = {},
		LastWaystone = {},
		Chests = {},
		DungeonClears = {},
		Cosmetics = {},
		Settings = {},
		Tutorial = {},
		PlayStats = { PlayTime = 0, Deaths = 0, Joins = 0 },
		Purchases = {},
	}
end

-- Migrations: MIGRATIONS[n] upgrades a profile from version n to n + 1.
local MIGRATIONS: { [number]: (data: { [string]: any }) -> () } = {
	[0] = function(data: { [string]: any })
		-- pre-release test profiles had no version and no world progress
		data.Waystones = data.Waystones or {}
		data.LastWaystone = data.LastWaystone or {}
		data.Chests = data.Chests or {}
		data.DungeonClears = data.DungeonClears or {}
	end,
}

local function reconcile(data: { [string]: any }, tpl: { [string]: any })
	for k, v in tpl do
		if data[k] == nil then
			data[k] = if type(v) == "table" then table.clone(v) else v
		elseif type(v) == "table" and type(data[k]) == "table" and next(v) ~= nil and #v == 0 then
			reconcile(data[k], v)
		end
	end
end

local function migrate(data: { [string]: any }): { [string]: any }
	local version = tonumber(data.DataVersion) or 0
	while version < DC.DataVersion do
		local step = MIGRATIONS[version]
		if step then
			step(data)
		end
		version += 1
		data.DataVersion = version
	end
	reconcile(data, template() :: any)
	return data
end

type Session = {
	data: Profile,
	key: string,
	dirty: boolean,
	saveBlocked: boolean,
	joinedAt: number,
	released: boolean,
}

local DataService = {
	ProfileLoaded = Signal.new() :: Signal.Signal<Player, Profile>,
	ProfileReleasing = Signal.new() :: Signal.Signal<Player, Profile>,
}

local store: DataStore? = nil
local storeWarned = false
local sessions: { [Player]: Session } = {}
local loading: { [Player]: boolean } = {}
local jobId = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)

local function now(): number
	return os.time()
end

local function warnStoreOnce(err: any)
	if not storeWarned then
		storeWarned = true
		warn("[DataService] DataStores unavailable, profiles are session-only: " .. tostring(err))
	end
end

local function loadProfile(player: Player): Profile?
	local key = "Player_" .. player.UserId
	if not store then
		return migrate(template() :: any) :: any
	end
	for attempt = 1, DC.LoadRetries do
		local result: { [string]: any }? = nil
		local ok, err = pcall(function()
			(store :: DataStore):UpdateAsync(key, function(old: any): any
				local record = if type(old) == "table" then old else { Data = nil, Lock = nil }
				local lock = record.Lock
				local stale = lock == nil or (now() - (tonumber(lock.Time) or 0)) > DC.SessionLockSeconds
				local ours = lock ~= nil and lock.Job == jobId
				if not stale and not ours and attempt < DC.LoadRetries then
					result = nil
					return nil -- leave the record untouched; another server holds the session
				end
				record.Lock = { Job = jobId, Time = now() }
				record.Data = migrate(if type(record.Data) == "table" then record.Data else template() :: any)
				result = record.Data
				return record
			end)
		end)
		if not ok then
			if RunService:IsStudio() then
				-- Studio without API access: fall back to a session-only profile
				warnStoreOnce(err)
				store = nil
				return migrate(template() :: any) :: any
			end
			warn(string.format("[DataService] load failed for %s (attempt %d): %s", key, attempt, tostring(err)))
		end
		if result then
			return result :: any
		end
		task.wait(DC.LoadRetryDelay)
		if not player.Parent then
			return nil
		end
	end
	return nil
end

local function writeProfile(session: Session, release: boolean): boolean
	if not store or session.saveBlocked then
		return false
	end
	local data = session.data
	for attempt = 1, DC.SaveRetries do
		local ok, err = pcall(function()
			(store :: DataStore):UpdateAsync(session.key, function(old: any): any
				local record = if type(old) == "table" then old else {}
				local lock = record.Lock
				if lock and lock.Job ~= jobId then
					return nil -- the session moved to another server; never overwrite it
				end
				record.Data = data
				record.Lock = if release then nil else { Job = jobId, Time = now() }
				return record
			end)
		end)
		if ok then
			session.dirty = false
			return true
		end
		warn(string.format("[DataService] save failed for %s (attempt %d): %s", session.key, attempt, tostring(err)))
		task.wait(1 + attempt)
	end
	return false
end

local function onPlayerAdded(player: Player)
	if sessions[player] or loading[player] then
		return
	end
	loading[player] = true
	local data = loadProfile(player)
	loading[player] = nil
	if not data then
		player:Kick("Your profile is still open on another server. Please rejoin in a moment.")
		return
	end
	if not player.Parent then
		if store then
			writeProfile({ data = data, key = "Player_" .. player.UserId, dirty = true, saveBlocked = false, joinedAt = now(), released = false }, true)
		end
		return
	end
	data.PlayStats.Joins += 1
	sessions[player] = {
		data = data,
		key = "Player_" .. player.UserId,
		dirty = true,
		saveBlocked = false,
		joinedAt = now(),
		released = false,
	}
	player:SetAttribute("ProfileLoaded", true)
	DataService.ProfileLoaded:Fire(player, data)
end

local function release(player: Player)
	local session = sessions[player]
	if not session or session.released then
		return
	end
	session.released = true
	DataService.ProfileReleasing:Fire(player, session.data)
	session.data.PlayStats.PlayTime += now() - session.joinedAt
	session.saveBlocked = false
	writeProfile(session, true)
	sessions[player] = nil
end

function DataService.Init()
	local ok, result = pcall(function(): DataStore
		return DataStoreService:GetDataStore(DC.StoreName)
	end)
	if ok then
		store = result
	else
		warnStoreOnce(result)
	end
end

function DataService.Start()
	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(onPlayerAdded, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerRemoving:Connect(release)
	game:BindToClose(function()
		for player in sessions do
			task.spawn(release, player)
		end
		local deadline = os.clock() + 25
		while next(sessions) ~= nil and os.clock() < deadline do
			task.wait(0.25)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(DC.AutosaveSeconds)
			for player, session in sessions do
				if session.dirty and not session.saveBlocked then
					task.spawn(writeProfile, session, false)
				end
			end
		end
	end)
end

function DataService.Get(player: Player): Profile?
	local s = sessions[player]
	return if s then s.data else nil
end

function DataService.WaitFor(player: Player, timeout: number?): Profile?
	local deadline = os.clock() + (timeout or 30)
	while player.Parent and os.clock() < deadline do
		local s = sessions[player]
		if s then
			return s.data
		end
		task.wait(0.1)
	end
	return nil
end

-- Mutate a profile; marks it dirty for the next autosave.
function DataService.Update(player: Player, fn: (data: Profile) -> ()): boolean
	local s = sessions[player]
	if not s then
		return false
	end
	fn(s.data)
	s.dirty = true
	return true
end

function DataService.SaveNow(player: Player): boolean
	local s = sessions[player]
	if not s then
		return false
	end
	return writeProfile(s, false)
end

-- Trades lock both profiles: no saves until the swap commits.
function DataService.SetSaveBlocked(player: Player, blocked: boolean)
	local s = sessions[player]
	if s then
		s.saveBlocked = blocked
	end
end

function DataService.AddGold(player: Player, amount: number): boolean
	return DataService.Update(player, function(data: Profile)
		data.Currencies.Gold = math.max(0, data.Currencies.Gold + math.floor(amount))
	end)
end

function DataService.AddFloorTokens(player: Player, floorId: string, amount: number): boolean
	return DataService.Update(player, function(data: Profile)
		local t = data.Currencies.FloorTokens
		t[floorId] = (t[floorId] or 0) + math.floor(amount)
	end)
end

-- Adds a stackable item; returns false when the inventory is full.
function DataService.AddItem(player: Player, itemId: string, count: number): boolean
	local added = false
	DataService.Update(player, function(data: Profile)
		for _, entry in data.Inventory.Items do
			if entry.id == itemId then
				entry.count += count
				added = true
				return
			end
		end
		if #data.Inventory.Items < data.Inventory.Capacity then
			table.insert(data.Inventory.Items, { id = itemId, count = count })
			added = true
		end
	end)
	return added
end

return DataService
