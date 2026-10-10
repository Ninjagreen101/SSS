--!strict
--[[
	DataService
	Owns every player's saved profile (ProfileStore, session-locked).

	- Loads the profile when a player joins, runs migrations, reconciles new
	  fields, and kicks with a friendly message if loading fails or the
	  profile is newer than this server build.
	- Autosaves every Config.Data.AutosaveSeconds (ProfileStore's periodic
	  save), and saves on leave and on server shutdown (BindToClose inside
	  ProfileStore). SaveNow() forces a save after purchases and trades.
	- Replicates the player's own data to their client: one full snapshot
	  once the client says it's ready, then batched per-frame path changes.
	- Trade lock: profiles in a trade can't be force-saved mid-confirmation,
	  and RunAtomic() applies a swap to several profiles without yielding.

	Other systems must change data only through Set / Update / Increment so the
	client replica stays in sync.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Promise = require(Shared.Util.Promise)
local TableUtil = require(Shared.Util.TableUtil)
local Log = require(Shared.Util.Log)
local SettingsSchema = require(Shared.Data.SettingsSchema)

local ProfileStore = require(script.Parent.Parent.Packages.ProfileStore) :: any
local Template = require(script.Template)
local Migrations = require(script.Migrations)

type PlayerData = Types.PlayerData
type Profile = any -- ProfileStore.Profile<PlayerData>; the package isn't strictly typed

local log = Log.new("DataService")

-- Paths (dot-joined prefixes) that never replicate to the client.
local SERVER_ONLY_PREFIXES = { "Purchases.Receipts" }

local DataService = {}

DataService.ProfileLoaded = Signal.new() :: Signal.Signal<Player, PlayerData>
DataService.ProfileReleased = Signal.new() :: Signal.Signal<Player>
DataService.Changed = Signal.new() :: Signal.Signal<Player, { string }, any>

local store: any = nil
local profiles: { [Player]: Profile } = {}
local clientReady: { [Player]: boolean } = {}
local snapshotSent: { [Player]: boolean } = {}
local pendingChanges: { [Player]: { Types.DataChange } } = {}
local flushScheduled: { [Player]: boolean } = {}
local sessionStart: { [Player]: number } = {}
local tradeLocked: { [Player]: boolean } = {}
local saveDeferred: { [Player]: boolean } = {}
local waiting: { [Player]: { (PlayerData?) -> () } } = {}

local function isServerOnly(path: { string }): boolean
	local joined = table.concat(path, ".")
	for _, prefix in SERVER_ONLY_PREFIXES do
		if string.sub(joined, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

-- Copy of the data with server-only branches removed.
local function buildSnapshot(data: PlayerData): { [string]: any }
	local copy = TableUtil.DeepCopy(data) :: any
	copy.Purchases.Receipts = {}
	return copy
end

local function flushChanges(player: Player)
	flushScheduled[player] = nil
	local list = pendingChanges[player]
	pendingChanges[player] = nil
	if list and #list > 0 and snapshotSent[player] then
		Net.Fire("DataChanged", player, list)
	end
end

local function queueChange(player: Player, path: { string }, value: any)
	if not snapshotSent[player] or isServerOnly(path) then
		return
	end
	local list = pendingChanges[player]
	if not list then
		list = {}
		pendingChanges[player] = list
	end
	table.insert(list, { Path = table.clone(path), Value = TableUtil.DeepCopy(value) })
	if not flushScheduled[player] then
		flushScheduled[player] = true
		task.defer(flushChanges, player)
	end
end

local function trySendSnapshot(player: Player)
	if snapshotSent[player] or not clientReady[player] then
		return
	end
	local profile = profiles[player]
	if not profile then
		return
	end
	snapshotSent[player] = true
	Net.Fire("DataSnapshot", player, buildSnapshot(profile.Data :: PlayerData))
end

local function resolveWaiters(player: Player, data: PlayerData?)
	local list = waiting[player]
	waiting[player] = nil
	if list then
		for _, resolve in list do
			resolve(data)
		end
	end
end

local function flushPlayTime(player: Player)
	local profile = profiles[player]
	local started = sessionStart[player]
	if profile and started then
		local now = os.clock()
		local data = profile.Data :: PlayerData
		data.PlayStats.PlaySeconds += math.floor(now - started)
		sessionStart[player] = now
	end
end

local function cleanupPlayer(player: Player)
	profiles[player] = nil
	clientReady[player] = nil
	snapshotSent[player] = nil
	pendingChanges[player] = nil
	flushScheduled[player] = nil
	sessionStart[player] = nil
	tradeLocked[player] = nil
	saveDeferred[player] = nil
	resolveWaiters(player, nil)
end

local function loadPlayer(player: Player)
	local key = Config.Data.KeyPrefix .. tostring(player.UserId)
	local started = os.clock()
	local profile: Profile = store:StartSessionAsync(key, {
		Cancel = function(): boolean
			-- Stop retrying if the player left or loading took too long.
			return player.Parent ~= Players or os.clock() - started > Config.Data.LoadRetryKickSeconds
		end,
	})

	if profile == nil then
		if player.Parent == Players then
			log:Warn(`Profile load failed for {player.Name}`)
			player:Kick(Strings.Data.LoadFailedKick)
		end
		resolveWaiters(player, nil)
		return
	end

	profile:AddUserId(player.UserId) -- GDPR association

	local result, reason = Migrations.Run(profile.Data :: any)
	if result ~= "Ok" then
		log:Warn(`Migration {result} for {player.Name}: {reason or "?"}`)
		profile:EndSession()
		if player.Parent == Players then
			player:Kick(if result == "Newer" then Strings.Data.OutdatedServer else Strings.Data.LoadFailedKick)
		end
		resolveWaiters(player, nil)
		return
	end
	profile:Reconcile()

	profile.OnSessionEnd:Connect(function()
		local wasLoaded = profiles[player] == profile
		if wasLoaded then
			cleanupPlayer(player)
			DataService.ProfileReleased:Fire(player)
		end
		-- Session ended while the player is still here: another server took it.
		if player.Parent == Players then
			player:Kick(Strings.Data.SessionTakenKick)
		end
	end)

	if player.Parent ~= Players then
		-- Left while loading.
		profile:EndSession()
		resolveWaiters(player, nil)
		return
	end

	local data = profile.Data :: PlayerData
	local now = os.time()
	if data.PlayStats.FirstJoin == 0 then
		data.PlayStats.FirstJoin = now
	end
	data.PlayStats.LastJoin = now
	data.PlayStats.Sessions += 1

	profiles[player] = profile
	sessionStart[player] = os.clock()
	log:Debug(`Loaded {player.Name} (v{data.DataVersion}, session {data.PlayStats.Sessions}, mock={tostring(store == nil)})`)

	DataService.ProfileLoaded:Fire(player, data)
	resolveWaiters(player, data)
	trySendSnapshot(player)
end

local function onPlayerRemoving(player: Player)
	local profile = profiles[player]
	if profile then
		flushPlayTime(player)
		profile:EndSession() -- saves and releases the session lock
	end
	-- OnSessionEnd handles the rest; if loading never finished, clean up here.
	if not profile then
		cleanupPlayer(player)
	end
end

local function onSaveSetting(player: Player, key: string, value: any)
	local validator = SettingsSchema.Validators[key]
	if not validator then
		Net.Violation:Fire(player, "RequestSaveSetting", "Malformed", `unknown setting '{key}'`)
		return
	end
	local ok, reason = validator(value)
	if not ok then
		Net.Violation:Fire(player, "RequestSaveSetting", "Malformed", `{key}: {reason or "invalid"}`)
		return
	end
	if not profiles[player] then
		return
	end
	DataService.Set(player, { "Settings", key }, TableUtil.DeepCopy(value))
end

-- PUBLIC API ----------------------------------------------------------------

-- Live data for a loaded player, or nil while loading / after leaving.
function DataService.GetData(player: Player): PlayerData?
	local profile = profiles[player]
	return if profile then profile.Data :: PlayerData else nil
end

function DataService.IsLoaded(player: Player): boolean
	return profiles[player] ~= nil
end

-- Resolves with the data once loaded, or nil if the player leaves / load fails.
function DataService.WaitForData(player: Player): Promise.Promise<PlayerData?>
	local data = DataService.GetData(player)
	if data then
		return Promise.resolve(data :: PlayerData?)
	end
	return Promise.new(function(resolve: (PlayerData?) -> ())
		if player.Parent ~= Players then
			resolve(nil)
			return
		end
		local list = waiting[player]
		if not list then
			list = {}
			waiting[player] = list
		end
		table.insert(list, resolve)
	end)
end

function DataService.Get(player: Player, path: { string }): any
	local data = DataService.GetData(player)
	if not data then
		return nil
	end
	return TableUtil.GetPath(data :: any, path)
end

-- Sets a value at a path and replicates it. Returns false if not loaded.
function DataService.Set(player: Player, path: { string }, value: any): boolean
	local data = DataService.GetData(player)
	if not data then
		return false
	end
	if not TableUtil.SetPath(data :: any, path, value) then
		log:Warn(`Set blocked at {table.concat(path, ".")} for {player.Name}`)
		return false
	end
	queueChange(player, path, value)
	DataService.Changed:Fire(player, path, value)
	return true
end

-- Read-modify-write. `transform` must not yield.
function DataService.Update(player: Player, path: { string }, transform: (any) -> any): (boolean, any)
	local data = DataService.GetData(player)
	if not data then
		return false, nil
	end
	local newValue = transform(TableUtil.GetPath(data :: any, path))
	return DataService.Set(player, path, newValue), newValue
end

-- Adds `delta` to a number at `path`, clamped to [min, max]. Returns the new value.
function DataService.Increment(player: Player, path: { string }, delta: number, min: number?, max: number?): number?
	local data = DataService.GetData(player)
	if not data then
		return nil
	end
	local current = TableUtil.GetPath(data :: any, path)
	if type(current) ~= "number" then
		current = 0
	end
	local value = math.clamp(current + delta, min or -math.huge, max or math.huge)
	DataService.Set(player, path, value)
	return value
end

-- Re-sends a branch after a system mutated it directly (bulk edits).
function DataService.Replicate(player: Player, path: { string })
	local data = DataService.GetData(player)
	if data then
		local value = TableUtil.GetPath(data :: any, path)
		queueChange(player, path, value)
		DataService.Changed:Fire(player, path, value)
	end
end

-- Forces a save now (after purchases, trades). Deferred while trade-locked.
function DataService.SaveNow(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end
	if tradeLocked[player] then
		saveDeferred[player] = true
		return
	end
	flushPlayTime(player)
	profile:Save()
end

-- Before a cross-server teleport (InstanceService): false if the profile isn't loaded or is
-- trade-locked (don't send them); otherwise saves now and returns true. The session lock is
-- deliberately kept: it is released on PlayerRemoving like any leave, and ProfileStore's
-- session-conflict messaging asks this server to end it as soon as the destination starts
-- loading. Ending it here would kick the player (OnSessionEnd) if the teleport then failed.
function DataService.PrepareTeleport(player: Player): boolean
	if not profiles[player] or tradeLocked[player] then
		return false
	end
	DataService.SaveNow(player)
	return true
end

-- Locks profiles for a trade confirmation window. Returns false if any is
-- missing or already locked (no partial locks are left behind).
function DataService.LockForTrade(players: { Player }): boolean
	for _, player in players do
		if not profiles[player] or tradeLocked[player] then
			return false
		end
	end
	for _, player in players do
		tradeLocked[player] = true
	end
	return true
end

-- Releases trade locks; saves any that were requested during the lock.
function DataService.UnlockTrade(players: { Player }, saveNow: boolean?)
	for _, player in players do
		tradeLocked[player] = nil
		if saveNow or saveDeferred[player] then
			saveDeferred[player] = nil
			DataService.SaveNow(player)
		end
	end
end

function DataService.IsTradeLocked(player: Player): boolean
	return tradeLocked[player] == true
end

-- Runs `mutate` across several loaded profiles with no yielding allowed, so
-- an autosave can never observe a half-applied swap. Returns ok, error.
function DataService.RunAtomic(players: { Player }, mutate: () -> ()): (boolean, string?)
	for _, player in players do
		if not profiles[player] or not profiles[player]:IsActive() then
			return false, "profile not active"
		end
	end
	local thread = coroutine.create(mutate)
	local ok, err = coroutine.resume(thread)
	if coroutine.status(thread) ~= "dead" then
		-- The mutation yielded: a programming error. Kill it and report.
		coroutine.close(thread)
		return false, "atomic mutation yielded"
	end
	if not ok then
		return false, tostring(err)
	end
	return true
end

-- Profile metadata for diagnostics (Studio command bar / admin tools).
function DataService.GetProfileInfo(player: Player): { [string]: any }?
	local profile = profiles[player]
	if not profile then
		return nil
	end
	return {
		Key = profile.Key,
		SessionLoadCount = profile.SessionLoadCount,
		FirstSessionTime = profile.FirstSessionTime,
		DataStoreState = ProfileStore.DataStoreState,
	}
end

-- LIFECYCLE -----------------------------------------------------------------

function DataService.Init()
	ProfileStore.SetConstant("AUTO_SAVE_PERIOD", Config.Data.AutosaveSeconds)
	store = ProfileStore.New(Config.Data.StoreName, Template)

	ProfileStore.OnError:Connect(function(message: string, storeName: string, key: string)
		log:Warn(`ProfileStore error ({storeName}/{key}): {message}`)
	end)
	ProfileStore.OnCriticalToggle:Connect(function(isCritical: boolean)
		log:Warn(`ProfileStore critical state: {tostring(isCritical)}`)
	end)
	ProfileStore.OnOverwrite:Connect(function(storeName: string, key: string)
		log:Warn(`ProfileStore overwrote non-profile data at {storeName}/{key}`)
	end)

	Net.On("ClientReady", function(player: Player)
		clientReady[player] = true
		trySendSnapshot(player)
	end)
	Net.On("RequestSaveSetting", onSaveSetting)
end

function DataService.Start()
	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(loadPlayer, player)
	end)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	-- Players who joined before Start (Play Solo can do this).
	for _, player in Players:GetPlayers() do
		task.spawn(loadPlayer, player)
	end

	-- Record session time for everyone before ProfileStore's shutdown save.
	game:BindToClose(function()
		for player in profiles do
			flushPlayTime(player)
		end
		if RunService:IsStudio() then
			log:Debug("BindToClose: play time flushed")
		end
	end)
end

return DataService
