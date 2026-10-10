--!strict
--[[
	CompanyService
	Climber Companies (Phase 12, docs/PHASE12_MULTIPLAYER.md): guilds unlocked at
	Config.Social.Company.UnlockLevel with a name, a preset emblem, ranked members, a shared
	storage chest and weekly Company quests. Shared across every server.

	Persistence
	- Each Company is a record in DataStore Config.Social.Company.DataStore, key "c_<id>" (shape in
	  Rules), written only with UpdateAsync (Store: pcall, request budget, retries with backoff).
	  Every rule is re-checked inside the transform against the newest record, so two servers
	  acting at once can't break a rank rule or overfill the chest. Every write carries an op id
	  kept in the record (Rules.FindOp), so a retry after a request that errored but committed
	  reuses that commit instead of depositing, withdrawing or paying twice.
	- Names are unique through an index key "n_<lowercase name>" claimed with UpdateAsync after the
	  name passes Rules.CleanName and TextService filtering; disbanding releases it.
	- Members' profiles hold Social.CompanyId, a pointer only: the record's member list is the
	  truth. On join (and whenever a record changes) a pointer to a Company that no longer lists
	  the player, or that was disbanded, is cleared.
	- In-server cache per Company (CacheSeconds). After every write this server announces
	  "company <id> is now version N" on MessagingService topic Config Topic; other servers with
	  members online re-read it and push CompanyState to them. Members also announce presence so
	  the member list can show who is in game on any server.

	Actions (RequestCompany): Create, Invite (in this server or by UserId / name across servers),
	Accept / Decline, Leave (not the Leader), Kick / Promote / Demote / SetEmblem / Disband (rank
	rules in Rules), Deposit / Withdraw, Refresh. One action per player at a time.

	Storage is duplication-safe:
	- Deposit (Rules.RunDeposit): the item leaves the bag and the profile is saved (the save is
	  confirmed, DataService.SaveAndConfirm) BEFORE the UpdateAsync adds it to the chest. A write
	  that surely didn't commit gives it back to the bag; one whose outcome can't be known doesn't.
	  So a crash or an unknown outcome can lose an item (logged with its full instance) but never
	  duplicate it.
	- Withdraw: the UpdateAsync takes the item out of the chest first, then it is added to the bag;
	  if that fails it goes back with another UpdateAsync (and is logged).

	Weekly quests: rolled per Company each Monday 00:00 UTC (Rules.RollQuests, deterministic).
	Members' GameEvents are batched per Company and flushed every FLUSH_SECONDS with UpdateAsync.
	When one completes, every member who belonged at that moment is paid once (gold and Shards):
	online members at once by whichever server sees it, offline members on their next join. The
	claim is marked in the record before paying, so nothing is ever paid twice.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Attributes = require(Shared.Attributes)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Items = require(Shared.Data.Items)
local InventoryRules = require(Shared.Data.InventoryRules)
local CompanyQuests = require(Shared.Data.CompanyQuests)
local TableUtil = require(Shared.Util.TableUtil)
local Log = require(Shared.Util.Log)

local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local EconomyService = require(script.Parent.EconomyService)
local AnalyticsService = require(script.Parent.AnalyticsService)
local GameEvents = require(script.Parent.GameEvents)
local Rules = require(script.Rules)
local Store = require(script.Store)

type Record = Rules.Record
type PlayerData = Types.PlayerData
type ItemInstance = Types.ItemInstance

-- Record nil = confirmed not to exist. No entry at all = unknown (never read, or the read failed).
type CacheEntry = { Record: Record?, FetchedAt: number }

type Invite = {
	CompanyId: string,
	Name: string,
	From: string,
	FromId: number,
	ExpiresAt: number, -- unix (server) time
}

type Pending = { Week: number, Deltas: { [string]: number } }

type PresenceEntry = { Users: { string }, ExpiresAt: number }

type WriteOptions = {
	AllowDisbanded: boolean?,
	OpId: string?, -- the caller's op id (to look for it afterwards); a fresh one by default
}

-- Changes a record inside UpdateAsync: ok, a reason when refused, and an output kept with the op
-- (what a retry gets back if an earlier attempt of the same write had in fact committed).
type Mutator = (Record) -> (boolean, string?, any)

local A = Attributes.Names
local Company = Config.Social.Company
local log = Log.new("CompanyService")

-- Timing (not balance): how the service talks to DataStores and MessagingService.
local INVITE_SECONDS = 60 -- an invite expires after this (it may cross servers)
local FLUSH_SECONDS = 30 -- quest progress is batched and written this often
local PRESENCE_SECONDS = 60 -- each server re-announces its online members this often
local PRESENCE_TTL = 150 -- another server's announcement counts this long
local LOAD_ATTEMPTS = 4 -- reading a member's Company on join
local LOAD_RETRY_SECONDS = 15
local REFRESH_MAX_AGE = 2 -- Refresh re-reads a record older than this
local SAVE_CONFIRM_SECONDS = 15 -- a deposit waits this long for the bag without the item to be saved
local PUBLISH_BASE = 150 -- MessagingService sends per minute per server: 150 + 60 x players
local PUBLISH_PER_PLAYER = 60
local STORE_ATTEMPTS = 4
local STORE_BACKOFF = 1
local STORE_BUDGET_WAIT = 6

local CompanyService = {}

local store: Store.Store
local activeDataStore: DataStore? = nil
local memoryMode = false
local subscribed = false
local random = Random.new()

local cache: { [string]: CacheEntry } = {}
local reading: { [string]: boolean } = {}
local members: { [Player]: string } = {} -- online players attached to a Company here
local busy: { [Player]: boolean } = {}
local invites: { [Player]: { [string]: Invite } } = {}
local pending: { [string]: Pending } = {}
local presence: { [string]: { [string]: PresenceEntry } } = {} -- company -> server JobId -> users
local announce: { [string]: number } = {} -- company -> version to announce
local presenceDirty: { [string]: boolean } = {}
local pushDirty: { [string]: boolean } = {}
local claiming: { [string]: boolean } = {}
local claimAgain: { [string]: boolean } = {}
local publishWindow = { Start = 0, Count = 0 }
local flushing = false
local currentWeek = Rules.WeekOf(os.time())

local claimRewards: (id: string) -> ()

-- HELPERS ------------------------------------------------------------------------------------------

local function userKey(player: Player): string
	return tostring(player.UserId)
end

local function notify(player: Player, key: string, args: { [string]: any }?, style: string?)
	Net.Fire("Notify", player, `Company.{key}`, args or {}, style or "Info")
end

local function fail(player: Player, reason: string?)
	local key = reason or "Failed"
	if Strings.Company.Errors[key] == nil then
		key = "Failed"
	end
	notify(player, `Errors.{key}`, nil, "Warning")
end

local function itemName(defId: string): string
	local entry = Strings.Items[defId]
	return if entry then entry.Name else defId
end

local function questName(id: string): string
	local entry = Strings.Company.Quests[id]
	return if entry then entry.Name else id
end

local function rankName(rank: string): string
	return Strings.Company.Ranks[rank] or rank
end

local function profileCompany(player: Player): string
	local value = DataService.Get(player, { "Social", "CompanyId" })
	return if type(value) == "string" then value else ""
end

local function hasLocalMembers(id: string): boolean
	for _, companyId in members do
		if companyId == id then
			return true
		end
	end
	return false
end

local function localMembers(id: string): { Player }
	local out: { Player } = {}
	for player, companyId in members do
		if companyId == id then
			table.insert(out, player)
		end
	end
	return out
end

-- STORE ----------------------------------------------------------------------------------------------

local function makeStore(backend: Store.Backend): Store.Store
	return Store.new(backend, {
		Attempts = STORE_ATTEMPTS,
		Backoff = STORE_BACKOFF,
		BudgetWait = STORE_BUDGET_WAIT,
		Wait = function(seconds: number)
			task.wait(seconds)
		end,
		OnError = function(key: string, attempt: number, message: string)
			log:Warn(`DataStore {key} attempt {attempt}: {message}`)
		end,
	})
end

local function robloxBackend(dataStore: DataStore): Store.Backend
	local readOptions = Instance.new("DataStoreGetOptions")
	readOptions.UseCache = false
	return {
		Update = function(key: string, transform: (any) -> any): any
			return (dataStore:UpdateAsync(key, function(old: any): any
				return transform(old)
			end))
		end,
		Read = function(key: string): any
			return (dataStore:GetAsync(key, readOptions))
		end,
		Budget = function(kind: string): number
			local requestType = if kind == "Update" then Enum.DataStoreRequestType.UpdateAsync else Enum.DataStoreRequestType.GetAsync
			return DataStoreService:GetRequestBudgetForRequestType(requestType)
		end,
	}
end

local function useMemory(why: string)
	if memoryMode then
		return
	end
	memoryMode = true
	store = makeStore(Store.Memory().Backend)
	log:Warn(`Companies use an in-memory store ({why}): nothing is saved and nothing crosses servers`)
end

-- CACHE ----------------------------------------------------------------------------------------------

local function remember(record: Record)
	local entry = cache[record.Id]
	local cached = entry and entry.Record
	if cached and cached.Version > record.Version then
		return
	end
	cache[record.Id] = { Record = record, FetchedAt = os.clock() }
end

-- The record `id` from the cache when younger than `maxAge` (default CacheSeconds), else read.
-- Returns ok (false = it couldn't be read; any stale copy comes with it) and the record (nil when
-- it doesn't exist).
local function fetch(id: string, maxAge: number?): (boolean, Record?)
	local age = maxAge or Company.CacheSeconds
	local entry = cache[id]
	if entry and os.clock() - entry.FetchedAt < age then
		return true, entry.Record
	end
	local started = os.clock()
	while reading[id] do
		task.wait(0.05)
	end
	entry = cache[id]
	if entry and entry.FetchedAt >= started then
		return true, entry.Record
	end
	reading[id] = true
	local ok, value = store.Read(Rules.RecordKey(id))
	reading[id] = nil
	if not ok then
		return false, if entry then entry.Record else nil
	end
	local record = Rules.Sanitize(value)
	if record then
		remember(record)
	else
		cache[id] = { Record = nil, FetchedAt = os.clock() }
	end
	local now = cache[id]
	return true, if now then now.Record else nil
end

-- STATE TO CLIENTS -----------------------------------------------------------------------------------

local function onlineSet(id: string): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for player, companyId in members do
		if companyId == id then
			out[userKey(player)] = true
		end
	end
	local servers = presence[id]
	if servers then
		local now = os.clock()
		for jobId, entry in servers do
			if entry.ExpiresAt > now then
				for _, userId in entry.Users do
					out[userId] = true
				end
			else
				servers[jobId] = nil
			end
		end
	end
	return out
end

local function applyAttributes(player: Player, record: Record?)
	player:SetAttribute(A.CompanyName, if record then record.Name else "")
	player:SetAttribute(A.CompanyEmblem, if record then record.Emblem else 0)
end

local function sendState(player: Player, record: Record)
	applyAttributes(player, record)
	Net.Fire("CompanyState", player, Rules.State(record, userKey(player), onlineSet(record.Id), os.time()))
end

-- Drops `player` from their Company in this server. `clearId`: also clear the profile pointer if it
-- still points there. `toast`: Strings.Company.Toasts key to show.
local function detach(player: Player, clearId: string?, toast: string?)
	local id = members[player]
	members[player] = nil
	if id then
		presenceDirty[id] = true
		pushDirty[id] = true
	end
	applyAttributes(player, nil)
	if clearId and profileCompany(player) == clearId then
		DataService.Set(player, { "Social", "CompanyId" }, "")
	end
	Net.Fire("CompanyState", player, nil)
	if toast then
		notify(player, `Toasts.{toast}`, nil, "Warning")
	end
end

local function attach(player: Player, record: Record)
	if player.Parent ~= Players or not DataService.IsLoaded(player) then
		return
	end
	members[player] = record.Id
	presenceDirty[record.Id] = true
	pushDirty[record.Id] = true
	if profileCompany(player) ~= record.Id then
		DataService.Set(player, { "Social", "CompanyId" }, record.Id)
	end
	sendState(player, record)
end

-- Sends the cached record to this server's members of `id`; anyone it no longer lists is dropped
-- (their pointer cleared). `actor` (who caused the change) gets no "removed" toast.
local function pushState(id: string, actor: Player?)
	local entry = cache[id]
	if not entry then
		return
	end
	local record = entry.Record
	for _, player in localMembers(id) do
		if not record or record.Disbanded or record.Members[userKey(player)] == nil then
			local toast = if player == actor then nil elseif record and record.Disbanded then "Disbanded" else "Removed"
			detach(player, id, toast)
		else
			sendState(player, record)
		end
	end
end

-- WRITES ---------------------------------------------------------------------------------------------

-- One UpdateAsync on record `id`: normalizes the week, runs `mutate` (which re-checks its rules on
-- the newest record), records the op id and bumps Version. Returns ok, the committed record, the
-- refusal reason and mutate's output. Each write has its own op id, so when Store retries after an
-- attempt that errored yet committed, the retry finds the op in the record and returns the output
-- that attempt saved instead of applying the change twice. Only the cache is touched here;
-- `committed` does the rest.
local function write(id: string, mutate: Mutator, options: WriteOptions?): (boolean, Record?, string?, any)
	local allowDisbanded = options ~= nil and options.AllowDisbanded == true
	local week = Rules.WeekOf(os.time())
	local opId = if options and options.OpId then options.OpId else HttpService:GenerateGUID(false)
	local seen: Record? = nil
	local out: any = nil
	local applied: Rules.OpEntry? = nil
	local ok, value, reason = store.Update(Rules.RecordKey(id), function(old: any): (any, string?)
		out, applied = nil, nil
		local record = Rules.Sanitize(old)
		seen = record
		if record then
			local prior = Rules.FindOp(record, opId)
			if prior then
				applied = prior
				return nil, "Applied"
			end
		end
		if not record or (record.Disbanded and not allowDisbanded) then
			return nil, "NotFound"
		end
		Rules.Normalize(record, week)
		local done, why, result = mutate(record)
		if not done then
			return nil, why or "Failed"
		end
		out = result
		Rules.PushOp(record, opId, result)
		record.Version += 1
		return record, nil
	end)
	local prior = applied
	if not ok and reason == "Applied" and prior and seen then
		-- An earlier attempt of this write committed (its request errored afterwards).
		log:Warn(`Company {id}: op {opId} had already committed; using its result`)
		remember(seen)
		return true, seen, nil, prior.Out
	end
	if not ok then
		if reason == "NotFound" then
			-- Gone or disbanded: remember that, so members here are dropped.
			local tombstone = seen
			if tombstone then
				remember(tombstone)
			else
				cache[id] = { Record = nil, FetchedAt = os.clock() }
			end
		end
		return false, nil, reason, nil
	end
	local record = Rules.Sanitize(value)
	if not record then
		return false, nil, "Failed", nil
	end
	remember(record)
	return true, record, nil, out
end

-- After a committed write: tell other servers, refresh members here, pay any rewards now owed.
local function committed(record: Record, actor: Player?)
	announce[record.Id] = record.Version
	pushState(record.Id, actor)
	task.spawn(claimRewards, record.Id)
end

local function update(id: string, mutate: Mutator, actor: Player?, options: WriteOptions?): (boolean, Record?, string?, any)
	local ok, record, reason, out = write(id, mutate, options)
	if ok and record then
		committed(record, actor)
	elseif reason == "NotFound" then
		pushState(id, actor)
	end
	return ok, record, reason, out
end

-- REWARDS --------------------------------------------------------------------------------------------

local function pay(player: Player, rewards: { Rules.Reward })
	local gold, shards = 0, 0
	for _, reward in rewards do
		gold += reward.Gold
		shards += reward.Shards
	end
	if gold > 0 then
		local balance = DataService.Increment(player, { "Currencies", "Gold" }, gold, 0, Config.Economy.MaxGold)
		if balance then
			AnalyticsService.Economy(player, "Source", "Gold", gold, balance, "Gameplay", "CompanyQuest")
		end
	end
	if shards > 0 then
		EconomyService.GrantShards(player, shards, "CompanyQuest")
	end
	for _, reward in rewards do
		notify(player, "Toasts.QuestReward", { quest = questName(reward.Id), gold = reward.Gold, shards = reward.Shards }, "Success")
	end
end

-- Pays every member online here what they are owed: marks the claims in the record first (one
-- UpdateAsync for all of them), then pays. Someone who left meanwhile gets their marks taken back.
claimRewards = function(id: string)
	if claiming[id] then
		claimAgain[id] = true
		return
	end
	local entry = cache[id]
	local record = entry and entry.Record
	if not record or record.Disbanded then
		return
	end
	local owed: { string } = {}
	for _, player in localMembers(id) do
		if DataService.IsLoaded(player) and #Rules.Claimable(record, userKey(player)) > 0 then
			table.insert(owed, userKey(player))
		end
	end
	if #owed == 0 then
		return
	end
	claiming[id] = true
	local ok, newRecord, _, out = write(id, function(r: Record): (boolean, string?, any)
		local marked = Rules.MarkClaims(r, owed)
		return next(marked) ~= nil, "Nothing", marked
	end)
	claiming[id] = nil
	local paid: { [string]: { Rules.Reward } } = if type(out) == "table" then out else {}
	if ok and newRecord then
		for userId, rewards in paid do
			local player = Players:GetPlayerByUserId(tonumber(userId) or 0)
			if player and DataService.IsLoaded(player) and members[player] == id then
				pay(player, rewards)
			else
				local keys: { string } = {}
				for _, reward in rewards do
					table.insert(keys, reward.Key)
				end
				log:Warn(`{userId} left before Company {id} rewards were paid; unmarking {table.concat(keys, ", ")}`)
				local undone, undoneRecord = write(id, function(r: Record): (boolean, string?)
					return Rules.UnmarkClaims(r, userId, keys), "Nothing"
				end)
				if undone and undoneRecord then
					newRecord = undoneRecord
				end
			end
		end
		committed(newRecord :: Record, nil)
	end
	if claimAgain[id] then
		claimAgain[id] = nil
		claimRewards(id)
	end
end

-- MESSAGING ------------------------------------------------------------------------------------------

local function canPublish(): boolean
	local now = os.clock()
	if now - publishWindow.Start >= 60 then
		publishWindow.Start = now
		publishWindow.Count = 0
	end
	if publishWindow.Count >= PUBLISH_BASE + PUBLISH_PER_PLAYER * #Players:GetPlayers() then
		return false
	end
	publishWindow.Count += 1
	return true
end

-- Sends one message to every server (yields). False if messaging is off or over budget.
local function publish(message: { [string]: any }): boolean
	if memoryMode or not subscribed or not canPublish() then
		return false
	end
	local ok, err = pcall(function()
		MessagingService:PublishAsync(Company.Topic, message)
	end)
	if not ok then
		log:Warn(`PublishAsync failed: {tostring(err)}`)
	end
	return ok
end

local function deliverInvite(target: Player, offer: Invite): (boolean, string?)
	local data = DataService.GetData(target)
	if not data then
		return false, "NoSuchPlayer"
	end
	if data.Social.CompanyId ~= "" or members[target] then
		return false, "TargetInCompany"
	end
	if data.Level < Company.UnlockLevel then
		return false, "TargetLevel"
	end
	if data.Social.Blocked[tostring(offer.FromId)] then
		return true, nil -- dropped quietly: the inviter isn't told they're blocked
	end
	local list = invites[target]
	if not list then
		list = {}
		invites[target] = list
	end
	list[offer.CompanyId] = offer
	Net.Fire("CompanyInvite", target, offer.CompanyId, offer.Name, offer.From, offer.ExpiresAt)
	return true, nil
end

local function onMessage(message: any)
	local data = if type(message) == "table" then message.Data else nil
	if type(data) ~= "table" then
		return
	end
	local kind = data.K
	if kind == "C" then
		local id, version = data.Id, data.V
		if type(id) ~= "string" or data.S == game.JobId then
			return
		end
		if not hasLocalMembers(id) then
			cache[id] = nil
			return
		end
		local entry = cache[id]
		if entry and entry.Record and type(version) == "number" and entry.Record.Version >= version then
			return
		end
		task.spawn(function()
			local ok = fetch(id, 0)
			if ok then
				pushState(id)
				claimRewards(id)
			end
		end)
	elseif kind == "I" then
		local to = data.To
		local target = if type(to) == "number" then Players:GetPlayerByUserId(to) else nil
		if target and type(data.Id) == "string" and type(data.N) == "string" and type(data.F) == "string" and type(data.FU) == "number" and type(data.E) == "number" then
			deliverInvite(target, { CompanyId = data.Id, Name = data.N, From = data.F, FromId = data.FU, ExpiresAt = data.E })
		end
	elseif kind == "P" then
		local id, source, users = data.Id, data.S, data.U
		if type(id) ~= "string" or type(source) ~= "string" or source == game.JobId or type(users) ~= "table" or not hasLocalMembers(id) then
			return
		end
		local list: { string } = {}
		for _, userId in users do
			if type(userId) == "string" then
				table.insert(list, userId)
			end
		end
		local servers = presence[id]
		if not servers then
			servers = {}
			presence[id] = servers
		end
		if #list > 0 then
			servers[source] = { Users = list, ExpiresAt = os.clock() + PRESENCE_TTL }
		else
			servers[source] = nil
		end
		pushDirty[id] = true
	end
end

local function announcePresence(id: string)
	local users: { string } = {}
	for _, player in localMembers(id) do
		table.insert(users, userKey(player))
	end
	publish({ K = "P", Id = id, U = users, S = game.JobId })
end

-- NAMES ----------------------------------------------------------------------------------------------

local function filterName(name: string, userId: number): (boolean, string?)
	local ok, result = pcall(function(): TextFilterResult
		return TextService:FilterStringAsync(name, userId, Enum.TextFilterContext.PublicChat)
	end)
	if not ok then
		log:Warn(`FilterStringAsync failed: {tostring(result)}`)
		return false, "Failed"
	end
	local okText, text = pcall(function(): string
		return (result :: TextFilterResult):GetNonChatStringForBroadcastAsync()
	end)
	if not okText or type(text) ~= "string" then
		return false, "Failed"
	end
	if text ~= name then
		return false, "NameFiltered"
	end
	return true, nil
end

local function readClaim(value: any): Rules.NameClaim?
	if type(value) == "table" and type(value.Id) == "string" then
		return { Id = value.Id, At = if type(value.At) == "number" then value.At else 0 }
	end
	return nil
end

-- Claims name index `key` for record `id`, unless a live Company holds it.
local function claimName(key: string, id: string, now: number): (boolean, string?)
	local ok, value, reason = store.Read(key)
	if not ok then
		return false, reason
	end
	local claim = readClaim(value)
	local holder: Record? = nil
	if claim and claim.Id ~= "" then
		local okHolder, holderValue, holderWhy = store.Read(Rules.RecordKey(claim.Id))
		if not okHolder then
			return false, holderWhy
		end
		holder = Rules.Sanitize(holderValue)
	end
	if not Rules.ClaimIsFree(claim, holder, now) then
		return false, "NameTaken"
	end
	local expected = if claim then claim.Id else ""
	local written, _, why = store.Update(key, function(old: any): (any, string?)
		local current = readClaim(old)
		local currentId = if current then current.Id else ""
		if currentId ~= "" and currentId ~= expected and currentId ~= id then
			return nil, "NameTaken"
		end
		return { Id = id, At = now }, nil
	end)
	return written, why
end

local function releaseName(key: string, id: string)
	local ok, _, why = store.Update(key, function(old: any): (any, string?)
		local current = readClaim(old)
		if not current or current.Id ~= id then
			return nil, "NotHolder"
		end
		return { Id = "", At = os.time() }, nil
	end)
	if not ok and why ~= "NotHolder" then
		log:Warn(`could not release name {key} from {id}: {tostring(why)}`)
	end
end

-- A create that failed or couldn't be paid for: tombstone the record if create `opId` wrote it
-- (never someone else's record) and free the name.
local function rollbackCreate(id: string, nameKey: string, opId: string)
	local ok, _, why = store.Update(Rules.RecordKey(id), function(old: any): (any, string?)
		local record = Rules.Sanitize(old)
		if not record or not Rules.FindOp(record, opId) then
			return nil, "NotFound"
		end
		if record.Disbanded then
			return nil, "Done"
		end
		record.Disbanded = true
		record.Members = {}
		record.Version += 1
		return record, nil
	end)
	if not ok and why ~= "NotFound" and why ~= "Done" then
		log:Error(`could not roll back unpaid Company {id}: {tostring(why)}`)
	end
	cache[id] = nil
	releaseName(nameKey, id)
end

-- Resolves an invite target: a UserId, or a player name (this server first, then Roblox).
local function resolveTarget(text: string): (number?, string)
	local asNumber = tonumber(text)
	if asNumber and asNumber % 1 == 0 and asNumber > 0 then
		local here = Players:GetPlayerByUserId(asNumber)
		return asNumber, if here then here.Name else text
	end
	local lowered = string.lower(text)
	for _, other in Players:GetPlayers() do
		if string.lower(other.Name) == lowered or string.lower(other.DisplayName) == lowered then
			return other.UserId, other.Name
		end
	end
	if #text < 3 or #text > 20 or string.match(text, "^[%w_]+$") == nil then
		return nil, text
	end
	local ok, userId = pcall(function(): number
		return Players:GetUserIdFromNameAsync(text)
	end)
	if ok and type(userId) == "number" then
		return userId, text
	end
	return nil, text
end

-- ACTIONS --------------------------------------------------------------------------------------------

-- The acting player's Company record (cached) and their member entry.
local function standing(player: Player): (string?, Record?, Rules.Member?)
	local id = members[player]
	if not id then
		return nil, nil, nil
	end
	local _, record = fetch(id)
	if not record then
		return id, nil, nil
	end
	return id, record, Rules.MemberOf(record, userKey(player))
end

local function create(player: Player, rawName: string, emblem: number)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	if data.Level < Company.UnlockLevel then
		return fail(player, "Level")
	end
	if data.Social.CompanyId ~= "" or members[player] then
		return fail(player, "InCompany")
	end
	if not Rules.ValidEmblem(emblem) then
		return fail(player, "Emblem")
	end
	local name, why = Rules.CleanName(rawName)
	if not name then
		return fail(player, why)
	end
	if data.Currencies.Gold < Company.CreateCost then
		return fail(player, "Funds")
	end
	local clean, filterWhy = filterName(name, player.UserId)
	if not clean then
		return fail(player, filterWhy)
	end

	local now = os.time()
	local id = Rules.NewId(random)
	local nameKey = Rules.NameKey(name)
	local claimed, claimWhy = claimName(nameKey, id, now)
	if not claimed then
		return fail(player, claimWhy)
	end
	local fresh = Rules.NewRecord(id, name, emblem, userKey(player), player.Name, now)
	local opId = HttpService:GenerateGUID(false)
	Rules.PushOp(fresh, opId, nil)
	local existing: Record? = nil
	local created, value, createWhy = store.Update(Rules.RecordKey(id), function(old: any): (any, string?)
		existing = nil
		if old ~= nil then
			local prior = Rules.Sanitize(old)
			if prior and Rules.FindOp(prior, opId) then
				existing = prior -- an earlier attempt of this create committed
				return nil, "Applied"
			end
			return nil, "Collision" -- another Company has this id
		end
		return fresh, nil
	end)
	local record = if created then Rules.Sanitize(value) elseif createWhy == "Applied" then existing else nil
	if not record then
		if createWhy == "Collision" then
			releaseName(nameKey, id)
		else
			-- Failed or out of budget: an attempt may still have committed. Undo it if so.
			task.spawn(rollbackCreate, id, nameKey, opId)
		end
		return fail(player, "Failed")
	end

	-- The record is committed: take the gold now. No yield from here to the profile pointer.
	local paid: boolean, payWhy: string? = false, "Failed"
	if DataService.IsLoaded(player) and profileCompany(player) == "" then
		paid, payWhy = InventoryService.Spend(player, "Gold", Company.CreateCost, "CompanyCreate")
	end
	if not paid or not DataService.Set(player, { "Social", "CompanyId" }, id) then
		if paid then
			-- Paid but the pointer couldn't be written: give the gold back.
			DataService.Increment(player, { "Currencies", "Gold" }, Company.CreateCost, 0, Config.Economy.MaxGold)
		end
		task.spawn(rollbackCreate, id, nameKey, opId)
		return fail(player, payWhy)
	end
	remember(record)
	attach(player, record)
	DataService.SaveNow(player)
	notify(player, "Toasts.Created", { name = record.Name }, "Success")
end

local function invite(player: Player, target: string)
	local id, record, me = standing(player)
	if not id or not record or not me then
		return fail(player, "NotInCompany")
	end
	if not Rules.Can(me.Rank, "Invite") then
		return fail(player, "Rank")
	end
	if Rules.MemberCount(record) >= Company.MaxMembers then
		return fail(player, "Full")
	end
	local targetId, targetName = resolveTarget(target)
	if not targetId then
		return fail(player, "NoSuchPlayer")
	end
	if targetId == player.UserId then
		return fail(player, "Self")
	end
	if record.Members[tostring(targetId)] then
		return fail(player, "AlreadyMember")
	end
	local offer: Invite = {
		CompanyId = record.Id,
		Name = record.Name,
		From = player.Name,
		FromId = player.UserId,
		ExpiresAt = os.time() + INVITE_SECONDS,
	}
	local here = Players:GetPlayerByUserId(targetId)
	if here then
		local delivered, why = deliverInvite(here, offer)
		if not delivered then
			return fail(player, why)
		end
	elseif not publish({ K = "I", To = targetId, Id = offer.CompanyId, N = offer.Name, F = offer.From, FU = offer.FromId, E = offer.ExpiresAt }) then
		return fail(player, "NotOnline")
	end
	notify(player, "Toasts.InviteSent", { name = targetName }, "Info")
end

local function takeInvite(player: Player, companyId: string): Invite?
	local list = invites[player]
	local offer = list and list[companyId]
	if not list or not offer then
		return nil
	end
	list[companyId] = nil
	return if offer.ExpiresAt >= os.time() then offer else nil
end

local function accept(player: Player, companyId: string)
	if not Rules.IsId(companyId) then
		return fail(player, "InviteExpired")
	end
	local offer = takeInvite(player, companyId)
	if not offer then
		return fail(player, "InviteExpired")
	end
	local data = DataService.GetData(player)
	if not data then
		return
	end
	if data.Social.CompanyId ~= "" or members[player] then
		return fail(player, "InCompany")
	end
	if data.Level < Company.UnlockLevel then
		return fail(player, "Level")
	end
	local userId = userKey(player)
	local ok, record, why = update(companyId, function(r: Record): (boolean, string?)
		return Rules.AddMember(r, userId, player.Name, os.time())
	end, player)
	if not ok or not record then
		return fail(player, why)
	end
	if DataService.IsLoaded(player) and profileCompany(player) == "" then
		invites[player] = nil
		attach(player, record)
		notify(player, "Toasts.Joined", { name = record.Name }, "Success")
	else
		-- Left during the write: take the membership back so no one is a member without a pointer.
		update(companyId, function(r: Record): (boolean, string?)
			return Rules.Leave(r, userId)
		end, nil)
	end
end

local function decline(player: Player, companyId: string)
	local list = invites[player]
	if list then
		list[companyId] = nil
	end
end

local function leave(player: Player)
	local id = members[player] or (if profileCompany(player) ~= "" then profileCompany(player) else nil)
	if not id then
		return fail(player, "NotInCompany")
	end
	local userId = userKey(player)
	local ok, _, why = update(id, function(r: Record): (boolean, string?)
		return Rules.Leave(r, userId)
	end, player)
	if ok then
		detach(player, id, nil)
		notify(player, "Toasts.Left", nil, "Info")
		return
	end
	if why == "NotFound" or why == "NotInCompany" then
		detach(player, id, nil)
		notify(player, "Toasts.Left", nil, "Info")
		return
	end
	fail(player, why)
end

-- Kick / Promote / Demote one member by UserId string.
local function manage(player: Player, action: string, target: string)
	local id = members[player]
	if not id then
		return fail(player, "NotInCompany")
	end
	local targetNumber = tonumber(target)
	if not targetNumber or targetNumber % 1 ~= 0 then
		return fail(player, "NotMember")
	end
	local actorId, targetId = userKey(player), tostring(targetNumber)
	local _, before = fetch(id)
	local known = before and before.Members[targetId]
	local targetName = if known then known.Name else target
	local ok, _, why, out = update(id, function(r: Record): (boolean, string?, any)
		if action == "Kick" then
			return Rules.Kick(r, actorId, targetId)
		elseif action == "Promote" then
			return Rules.Promote(r, actorId, targetId)
		end
		return Rules.Demote(r, actorId, targetId)
	end, player)
	if not ok then
		return fail(player, why)
	end
	if action == "Kick" then
		notify(player, "Toasts.Kicked", { name = targetName }, "Info")
	else
		notify(player, "Toasts.RankChanged", { name = targetName, rank = rankName(if type(out) == "string" then out else "") }, "Info")
	end
end

local function disband(player: Player)
	local id = members[player]
	if not id then
		return fail(player, "NotInCompany")
	end
	local actorId = userKey(player)
	local ok, record, why = update(id, function(r: Record): (boolean, string?)
		return Rules.Disband(r, actorId)
	end, player)
	if not ok or not record then
		return fail(player, why)
	end
	releaseName(Rules.NameKey(record.Name), id)
	notify(player, "Toasts.DisbandedYou", { name = record.Name }, "Info")
end

local function setEmblem(player: Player, emblem: number)
	local id = members[player]
	if not id then
		return fail(player, "NotInCompany")
	end
	local ok, _, why = update(id, function(r: Record): (boolean, string?)
		return Rules.SetEmblem(r, userKey(player), emblem)
	end, player)
	if not ok then
		return fail(player, why)
	end
end

local function sameRolls(a: ItemInstance, b: ItemInstance): boolean
	if a.DefId ~= b.DefId or a.Rarity ~= b.Rarity or a.Upgrade ~= b.Upgrade or a.Durability ~= b.Durability or a.Unique ~= b.Unique then
		return false
	end
	if #a.Affixes ~= #b.Affixes then
		return false
	end
	for index, affix in a.Affixes do
		local other = b.Affixes[index]
		if affix.Id ~= other.Id or affix.Value ~= other.Value then
			return false
		end
	end
	return true
end

local function deposit(player: Player, uid: string, count: number)
	local id, _, me = standing(player)
	if not id or not me then
		return fail(player, "NotInCompany")
	end
	if not Rules.Can(me.Rank, "Deposit") then
		return fail(player, "Rank")
	end
	local data = DataService.GetData(player)
	local item = data and data.Inventory.Items[uid]
	if not data or not item then
		return fail(player, "Missing")
	end
	local def = Items.Get(item.DefId)
	if not def or not def.Tradeable then
		return fail(player, "Untradeable")
	end
	if item.Locked then
		return fail(player, "Locked")
	end
	if InventoryRules.EquippedSlot(data, uid) then
		return fail(player, "Equipped")
	end
	local take = if count == 0 then item.Count else count
	if not InventoryRules.IsCount(take, item.Count) then
		return fail(player, "Invalid")
	end
	local snapshot = TableUtil.DeepCopy(item)
	snapshot.Count = take
	local remaining = item.Count - take
	local actorId = userKey(player)
	local opId = HttpService:GenerateGUID(false)
	local record: Record? = nil

	-- Rules.RunDeposit's order: out of the bag and saved, then into the chest; a chest write that
	-- surely didn't happen gives the item back. A crash between the save and the chest write loses
	-- the item (the "left the bag" log line is what support restores it from); nothing is ever
	-- duplicated.
	local result, why = Rules.RunDeposit({
		Take = function(): (boolean, string?)
			return InventoryService.Transact(player, function(draft: PlayerData): (boolean, string?)
				local live = draft.Inventory.Items[uid]
				if not live or live.Locked or live.Count < take or not sameRolls(live, snapshot) or InventoryRules.EquippedSlot(draft, uid) then
					return false, "Missing"
				end
				return InventoryRules.Remove(draft, uid, take)
			end)
		end,
		Persist = function(): boolean
			return DataService.SaveAndConfirm(player, function(saved: any): boolean
				local inventory = saved.Inventory
				local items = type(inventory) == "table" and inventory.Items
				if type(items) ~= "table" then
					return false
				end
				local entry = items[uid]
				return entry == nil or (type(entry) == "table" and type(entry.Count) == "number" and entry.Count <= remaining)
			end, SAVE_CONFIRM_SECONDS)
		end,
		Write = function(): (Rules.WriteOutcome, string?)
			log:Info(`deposit {opId}: {player.Name} ({player.UserId}) {HttpService:JSONEncode(snapshot)} left the bag for Company {id}`)
			local ran, ok, written, reason = pcall(write, id, function(r: Record): (boolean, string?, any)
				local added, addWhy, where = Rules.StorageAdd(r, actorId, snapshot, take)
				return added, addWhy, where
			end, { OpId = opId })
			if not ran then
				-- write never throws (Store pcalls every request); if it somehow did, the outcome is unknown.
				log:Error(`deposit write errored for {player.Name}: {tostring(ok)}`)
				return "Unknown", "Failed"
			end
			if ok and written then
				record = written
				return "Committed", nil
			end
			if reason ~= "Failed" then
				return "Refused", reason -- refused by the rules or the mutate, or never sent ("Busy")
			end
			-- Every attempt errored, and one may still have committed: look for the op.
			local read, raw = store.Read(Rules.RecordKey(id))
			if not read then
				return "Unknown", reason
			end
			local current = Rules.Sanitize(raw)
			if current and Rules.FindOp(current, opId) then
				remember(current)
				record = current
				return "Committed", nil
			end
			return "Refused", reason
		end,
		GiveBack = function(): boolean
			local given = InventoryService.Transact(player, function(draft: PlayerData): (boolean, string?)
				return InventoryRules.Add(draft, TableUtil.DeepCopy(snapshot), take)
			end)
			if not given then
				-- The bag filled up meanwhile: back in past the slot cap (nothing may be lost).
				given = InventoryService.Transact(player, function(draft: PlayerData): (boolean, string?)
					local capacity = draft.Inventory.Capacity
					draft.Inventory.Capacity = math.huge
					local added, reason = InventoryRules.Add(draft, TableUtil.DeepCopy(snapshot), take)
					draft.Inventory.Capacity = capacity
					return added, reason
				end)
			end
			if given then
				DataService.SaveNow(player)
			end
			return given
		end,
	})
	if result == "Deposited" and record then
		committed(record, player)
		notify(player, "Toasts.Deposited", { item = itemName(snapshot.DefId), count = take }, "Success")
		return
	end
	if result == "Lost" then
		log:Error(`DEPOSIT LOST {opId}: {player.Name} ({player.UserId}) {HttpService:JSONEncode(snapshot)} for Company {id}: {tostring(why)}`)
	end
	fail(player, why)
end

local function withdraw(player: Player, uid: string, count: number)
	local id, _, me = standing(player)
	if not id or not me then
		return fail(player, "NotInCompany")
	end
	if not Rules.Can(me.Rank, "Withdraw") then
		return fail(player, "Rank")
	end
	local data = DataService.GetData(player)
	if not data then
		return
	end
	if DataService.IsTradeLocked(player) then
		return fail(player, "TradeLocked")
	end
	if InventoryRules.SlotsUsed(data.Inventory.Items) >= data.Inventory.Capacity then
		return fail(player, "BagFull")
	end

	local actorId = userKey(player)
	local ok, record, why, out = write(id, function(r: Record): (boolean, string?, any)
		return Rules.StorageTake(r, actorId, uid, count)
	end)
	if not ok or not record then
		return fail(player, why)
	end
	if type(out) ~= "table" or type(out.DefId) ~= "string" or type(out.Count) ~= "number" then
		log:Error(`withdraw {uid} from Company {id} for {player.Name} committed without an item`)
		committed(record, player)
		return fail(player, "Failed")
	end
	local item: ItemInstance = out

	-- Out of the chest: now into the bag. Withdrawing isn't "collecting" (no GameEvents).
	local given, giveWhy = InventoryService.Transact(player, function(draft: PlayerData): (boolean, string?)
		local copy = TableUtil.DeepCopy(item)
		copy.New = true
		copy.Locked = false
		return InventoryRules.Add(draft, copy, copy.Count)
	end)
	if given then
		DataService.SaveNow(player)
		committed(record, player)
		notify(player, "Toasts.Withdrew", { item = itemName(item.DefId), count = item.Count }, "Success")
		return
	end

	-- The bag refused it: put it back (past the slot cap if need be; nothing may be lost).
	local back, backRecord, backWhy = write(id, function(r: Record): (boolean, string?)
		local added, reason = Rules.StorageAdd(r, nil, item, item.Count)
		return added, reason
	end, { AllowDisbanded = true })
	if back and backRecord then
		log:Warn(`withdraw for {player.Name} returned to Company {id}: {tostring(giveWhy)}`)
		committed(backRecord, player)
	else
		log:Error(`WITHDRAW RETURN FAILED {player.Name} ({player.UserId}) {HttpService:JSONEncode(item)} from Company {id}: {tostring(backWhy)}`)
		committed(record, player)
	end
	fail(player, if giveWhy == "Full" then "BagFull" else giveWhy)
end

-- Re-reads membership from the profile pointer (join, or Refresh after a failed read).
local function loadMembership(player: Player)
	local id = profileCompany(player)
	if id == "" then
		applyAttributes(player, nil)
		Net.Fire("CompanyState", player, nil)
		return
	end
	for attempt = 1, LOAD_ATTEMPTS do
		local ok, record = fetch(id, 0)
		if player.Parent ~= Players or not DataService.IsLoaded(player) or profileCompany(player) ~= id then
			return
		end
		if ok then
			local userId = userKey(player)
			if record and Rules.MemberOf(record, userId) then
				attach(player, record)
				local member = record.Members[userId]
				if member and member.Name ~= player.Name then
					update(id, function(r: Record): (boolean, string?)
						return Rules.Rename(r, userId, player.Name), "Unchanged"
					end, player)
				end
				claimRewards(id)
			else
				detach(player, id, if record and record.Disbanded then "Disbanded" else "Removed")
			end
			return
		end
		if attempt < LOAD_ATTEMPTS then
			task.wait(LOAD_RETRY_SECONDS)
		end
	end
	log:Warn(`could not read Company {id} for {player.Name}; keeping the pointer`)
end

local function refresh(player: Player)
	local id = members[player]
	if id then
		local ok = fetch(id, REFRESH_MAX_AGE)
		if ok then
			pushState(id)
		end
	elseif profileCompany(player) ~= "" then
		loadMembership(player)
	else
		Net.Fire("CompanyState", player, nil)
	end
	local list = invites[player]
	if list then
		local now = os.time()
		for companyId, offer in list do
			if offer.ExpiresAt >= now then
				Net.Fire("CompanyInvite", player, offer.CompanyId, offer.Name, offer.From, offer.ExpiresAt)
			else
				list[companyId] = nil
			end
		end
	end
end

local HANDLERS: { [string]: (Player, string, number) -> () } = {
	Create = function(player: Player, text: string, number: number)
		create(player, text, number)
	end,
	Invite = function(player: Player, text: string, _number: number)
		invite(player, text)
	end,
	Accept = function(player: Player, text: string, _number: number)
		accept(player, text)
	end,
	Decline = function(player: Player, text: string, _number: number)
		decline(player, text)
	end,
	Leave = function(player: Player, _text: string, _number: number)
		leave(player)
	end,
	Kick = function(player: Player, text: string, _number: number)
		manage(player, "Kick", text)
	end,
	Promote = function(player: Player, text: string, _number: number)
		manage(player, "Promote", text)
	end,
	Demote = function(player: Player, text: string, _number: number)
		manage(player, "Demote", text)
	end,
	Disband = function(player: Player, _text: string, _number: number)
		disband(player)
	end,
	SetEmblem = function(player: Player, _text: string, number: number)
		setEmblem(player, number)
	end,
	Deposit = function(player: Player, text: string, number: number)
		deposit(player, text, number)
	end,
	Withdraw = function(player: Player, text: string, number: number)
		withdraw(player, text, number)
	end,
	Refresh = function(player: Player, _text: string, _number: number)
		refresh(player)
	end,
}

local function onRequest(player: Player, action: string, text: string, number: number)
	local handler = HANDLERS[action]
	if not handler or not DataService.IsLoaded(player) then
		return
	end
	if busy[player] then
		return fail(player, "Busy")
	end
	busy[player] = true
	local ok, err = xpcall(function()
		handler(player, text, number)
	end, debug.traceback)
	busy[player] = nil
	if not ok then
		log:Error(`{action} for {player.Name} errored: {tostring(err)}`)
		fail(player, "Failed")
	end
end

-- QUEST PROGRESS -------------------------------------------------------------------------------------

local function onGameEvent(player: Player, kind: GameEvents.Kind, key: string, amount: number)
	local id = members[player]
	if not id or amount < 1 then
		return
	end
	local week = Rules.WeekOf(os.time())
	local entry = cache[id]
	for _, questId in Rules.OpenQuests(entry and entry.Record, id, week) do
		if CompanyQuests.Matches(questId, kind, key) then
			local existing = pending[id]
			local bucket: Pending = if existing and existing.Week == week then existing else { Week = week, Deltas = {} }
			pending[id] = bucket
			bucket.Deltas[questId] = (bucket.Deltas[questId] or 0) + math.floor(amount)
		end
	end
end

-- Writes every batched delta (one UpdateAsync per Company). A failed write keeps its deltas for the
-- next flush; deltas from a week that has rolled over are dropped.
local function flush()
	if flushing then
		return
	end
	flushing = true
	local batch = pending
	pending = {}
	local now = os.time()
	for id, bucket in batch do
		local ok, _, why = update(id, function(r: Record): (boolean, string?)
			local changed = Rules.AddProgress(r, bucket.Week, bucket.Deltas, now)
			return changed, "Nothing"
		end, nil)
		if not ok and why ~= "Nothing" and why ~= "NotFound" and bucket.Week == Rules.WeekOf(os.time()) then
			local current = pending[id]
			if current and current.Week == bucket.Week then
				for questId, amount in bucket.Deltas do
					current.Deltas[questId] = (current.Deltas[questId] or 0) + amount
				end
			else
				pending[id] = bucket
			end
		end
	end
	flushing = false
end

-- HEARTBEAT ------------------------------------------------------------------------------------------

local function tick(elapsed: number)
	-- Announce committed versions (one message per Company per tick at most).
	local versions = announce
	announce = {}
	for id, version in versions do
		publish({ K = "C", Id = id, V = version, S = game.JobId })
	end
	-- Presence: on change, and a periodic heartbeat for every Company with members here.
	local heartbeat = elapsed % PRESENCE_SECONDS == 0
	local companies: { [string]: boolean } = {}
	for _, companyId in members do
		companies[companyId] = true
	end
	local dirty = presenceDirty
	presenceDirty = {}
	for id in companies do
		if heartbeat or dirty[id] then
			announcePresence(id)
		end
	end
	for id in dirty do
		if not companies[id] then
			announcePresence(id) -- the last member here left: tell others they're gone
		end
	end
	-- A new week rolls every Company's quests: re-send state.
	local week = Rules.WeekOf(os.time())
	if week ~= currentWeek then
		currentWeek = week
		for id in companies do
			pushDirty[id] = true
		end
	end
	local toPush = pushDirty
	pushDirty = {}
	for id in toPush do
		pushState(id)
	end
	if elapsed % FLUSH_SECONDS == 0 then
		task.spawn(flush)
	end
	-- Forget Companies nobody here belongs to.
	if elapsed % 60 == 0 then
		local now = os.clock()
		for id, entry in cache do
			if not companies[id] and now - entry.FetchedAt > Company.CacheSeconds then
				cache[id] = nil
				presence[id] = nil
			end
		end
	end
end

-- LIFECYCLE ------------------------------------------------------------------------------------------

local function onPlayerRemoving(player: Player)
	local id = members[player]
	members[player] = nil
	if id then
		presenceDirty[id] = true
		pushDirty[id] = true
	end
	invites[player] = nil
	busy[player] = nil
end

function CompanyService.Init()
	if game.PlaceId == 0 then
		useMemory("unpublished place")
	else
		local ok, result = pcall(function(): DataStore
			return DataStoreService:GetDataStore(Company.DataStore)
		end)
		if ok then
			activeDataStore = result
			store = makeStore(robloxBackend(result))
		else
			useMemory(tostring(result))
		end
	end
	Net.On("RequestCompany", onRequest)
end

function CompanyService.Start()
	-- Studio without API access: DataStore requests fail with 403; fall back to memory.
	local dataStore = activeDataStore
	if RunService:IsStudio() and dataStore and not memoryMode then
		task.spawn(function()
			local ok, err = pcall(function()
				dataStore:GetAsync("probe")
			end)
			if not ok and (string.find(tostring(err), "403") or string.find(tostring(err), "API")) then
				useMemory("Studio has no API access")
			end
		end)
	end
	if not memoryMode then
		task.spawn(function()
			local ok, err = pcall(function()
				MessagingService:SubscribeAsync(Company.Topic, onMessage)
			end)
			subscribed = ok
			if not ok then
				log:Warn(`SubscribeAsync failed: {tostring(err)} (Companies won't update across servers)`)
			end
		end)
	end

	GameEvents.Fired:Connect(onGameEvent)
	DataService.ProfileLoaded:Connect(function(player: Player)
		loadMembership(player)
	end)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		if DataService.IsLoaded(player) then
			task.spawn(loadMembership, player)
		end
	end

	task.spawn(function()
		local elapsed = 0
		while true do
			task.wait(1)
			elapsed += 1
			local ok, err = pcall(function()
				tick(elapsed)
			end)
			if not ok then
				log:Error(`tick failed: {tostring(err)}`)
			end
		end
	end)

	game:BindToClose(function()
		flush()
	end)
end

return CompanyService
