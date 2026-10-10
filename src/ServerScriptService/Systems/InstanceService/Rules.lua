--!strict
--[[
	InstanceService.Rules
	Every pure decision about reserved-server instances (docs/PHASE12_MULTIPLAYER.md, "Reserved
	servers"). No Roblox services: tools/place/test_instances.luau runs it under Lune.

	- UseReserved: whether a run may go to a reserved server at all (else the in-server copy runs).
	- InstanceData / ParseInstance: the teleport data a party carries into an instance server
	  (written by the sending server; Party = the source party to rebuild there). Everything is
	  re-validated on arrival all the same.
	- Admit: who an instance server accepts. Membership is never taken from teleport data alone:
	  the arrival must be named in the record (set by the first valid arrival), must come from this
	  place (SourcePlaceId, set by Roblox), and its own data must name the same run.
	- ArrivalDecision: wait for the party, start with whoever came, or give up.
	- ReturnData: the teleport data for the way home. It never says where to arrive: a client can
	  teleport itself to this place with any data it likes. The destination goes in the player's
	  profile instead (PendingReturn / TakePending / SplitReturnTo), written by the instance server.
	- Retry / ShouldRetry / RetryDelay / ReturnDelay: retry and timing rules.
]]

export type Mode = "Dungeon" | "Guardian"

-- The party the run's players were in before the teleport (two or more of the Members).
export type PartyData = {
	Leader: number, -- its leader, or the oldest member going when the leader stayed behind
	Members: { number }, -- UserIds, oldest first
	LootMode: string,
}

export type Record = {
	Mode: Mode,
	Id: string,
	Members: { number }, -- UserIds
	ReturnPlaceId: number,
	Party: PartyData?,
}

export type Limits = {
	PlaceId: number, -- this place: the only one an instance may return to
	MaxMembers: number,
	IsKnownId: (mode: Mode, id: string) -> boolean,
	LootModes: { string }, -- Config.Social.Party.LootModes
}

-- A profile's PendingReturn (Types.PlayerData.PendingReturn).
export type Pending = { To: string, At: number }

export type Environment = {
	Enabled: boolean, -- Config.Social.Instances.UseReservedServers
	PlaceId: number, -- game.PlaceId (0 while unpublished)
	IsStudio: boolean,
	InInstance: boolean, -- this server is itself an instance (never nest)
}

export type ArrivalDecision = "Wait" | "Start" | "Abandon"

local Rules = {}

Rules.VERSION = 1
Rules.MAX_ID_LENGTH = 48
Rules.MAX_RETURN_LENGTH = 64
-- Seconds a PendingReturn may be stamped in the future (servers' clocks differ a little).
Rules.CLOCK_SKEW = 30
-- Seconds before retry n (n >= 2) of a failed reserve or teleport: RETRY_BASE x (n - 1).
Rules.RETRY_BASE = 2
-- Teleport results worth another try; anything else (Unauthorized, GameNotFound...) won't change.
Rules.RETRYABLE = { Failure = true, Flooded = true, GameFull = true } :: { [string]: boolean }
-- Return reasons that end a run normally (the party gets ReturnTimeout to finish up).
Rules.RUN_END = { Cleared = true, Victory = true, Wipe = true } :: { [string]: boolean }

local MAX_USER_ID = 2 ^ 53

local function isMode(value: any): boolean
	return value == "Dungeon" or value == "Guardian"
end

local function isName(value: any, maxLength: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maxLength and string.match(value, "^[%w_]+$") ~= nil
end

local function isUserId(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value < MAX_USER_ID and value % 1 == 0
end

local function isPlaceId(value: any): boolean
	return type(value) == "number" and value > 0 and value < MAX_USER_ID and value % 1 == 0
end

-- A dense array of numbers: no holes, no extra keys.
local function arrayLength(value: { [any]: any }): number?
	local count = 0
	for key in value do
		if type(key) ~= "number" then
			return nil
		end
		count += 1
	end
	if count ~= #value then
		return nil
	end
	return count
end

-- May this run use a reserved server? Returns the reason when it may not.
function Rules.UseReserved(env: Environment): (boolean, string)
	if not env.Enabled then
		return false, "Disabled"
	end
	if env.IsStudio then
		return false, "Studio"
	end
	if env.PlaceId == 0 then
		return false, "Unpublished"
	end
	if env.InInstance then
		return false, "InInstance"
	end
	return true, "Ok"
end

-- The teleport data for a party going into an instance.
function Rules.InstanceData(mode: Mode, id: string, userIds: { number }, returnPlaceId: number, party: PartyData?): { [string]: any }
	return {
		Version = Rules.VERSION,
		Mode = mode,
		Id = id,
		Members = table.clone(userIds),
		ReturnPlaceId = returnPlaceId,
		Party = if party then { Leader = party.Leader, Members = table.clone(party.Members), LootMode = party.LootMode } else nil,
	}
end

-- A dense list of distinct UserIds, each one of `allowed`; nil if anything is off.
local function userIdList(value: any, allowed: { number }): { number }?
	if type(value) ~= "table" then
		return nil
	end
	local count = arrayLength(value)
	if not count or count == 0 then
		return nil
	end
	local seen: { [number]: boolean } = {}
	local list: { number } = {}
	for _, userId in ipairs(value) do
		if not isUserId(userId) or seen[userId] or not table.find(allowed, userId) then
			return nil
		end
		seen[userId] = true
		table.insert(list, userId)
	end
	return list
end

-- The optional Party block: two or more of the run's members, its leader among them.
local function parseParty(raw: any, members: { number }, lootModes: { string }): (boolean, PartyData?)
	if raw == nil then
		return true, nil
	end
	if type(raw) ~= "table" then
		return false, nil
	end
	local list = userIdList(raw.Members, members)
	if not list or #list < 2 or not isUserId(raw.Leader) or not table.find(list, raw.Leader) then
		return false, nil
	end
	if type(raw.LootMode) ~= "string" or not table.find(lootModes, raw.LootMode) then
		return false, nil
	end
	return true, { Leader = raw.Leader, Members = list, LootMode = raw.LootMode }
end

-- Validates arriving teleport data; nil and the reason if anything is off.
function Rules.ParseInstance(raw: any, limits: Limits): (Record?, string?)
	if type(raw) ~= "table" then
		return nil, "NotTable"
	end
	if raw.Version ~= Rules.VERSION then
		return nil, "Version"
	end
	local mode, id, members, returnPlaceId = raw.Mode, raw.Id, raw.Members, raw.ReturnPlaceId
	if not isMode(mode) then
		return nil, "Mode"
	end
	if not isName(id, Rules.MAX_ID_LENGTH) or not limits.IsKnownId(mode, id) then
		return nil, "Id"
	end
	if type(members) ~= "table" then
		return nil, "Members"
	end
	local count = arrayLength(members)
	if not count or count == 0 or count > limits.MaxMembers then
		return nil, "Members"
	end
	local seen: { [number]: boolean } = {}
	local list: { number } = {}
	for _, userId in ipairs(members) do
		if not isUserId(userId) or seen[userId] then
			return nil, "Members"
		end
		seen[userId] = true
		table.insert(list, userId)
	end
	if not isPlaceId(returnPlaceId) or returnPlaceId ~= limits.PlaceId then
		return nil, "ReturnPlace"
	end
	local partyOk, party = parseParty(raw.Party, list, limits.LootModes)
	if not partyOk then
		return nil, "Party"
	end
	return { Mode = mode, Id = id, Members = list, ReturnPlaceId = returnPlaceId, Party = party }, nil
end

-- Does an instance server with this record accept this arrival? `raw` is the arrival's own data.
function Rules.Admit(record: Record, userId: number, sourcePlaceId: any, placeId: number, raw: any): (boolean, string?)
	if not table.find(record.Members, userId) then
		return false, "NotMember"
	end
	if not isPlaceId(sourcePlaceId) or sourcePlaceId ~= placeId then
		return false, "WrongSource"
	end
	if type(raw) ~= "table" or raw.Version ~= Rules.VERSION or raw.Mode ~= record.Mode or raw.Id ~= record.Id then
		return false, "Mismatch"
	end
	return true, nil
end

-- While an instance waits for its party: start once all are in, or after the timeout with
-- whoever came; give up if nobody came by then.
function Rules.ArrivalDecision(expected: number, ready: number, elapsed: number, timeout: number): ArrivalDecision
	if ready >= expected and ready > 0 then
		return "Start"
	end
	if elapsed >= timeout then
		return if ready > 0 then "Start" else "Abandon"
	end
	return "Wait"
end

-- "Waystone:<id>" or "Gate:<GuardianId>": where a returning player arrives on the floor.
function Rules.SplitReturnTo(returnTo: any): (string?, string?)
	if type(returnTo) ~= "string" or #returnTo > Rules.MAX_RETURN_LENGTH then
		return nil, nil
	end
	local kind, id = string.match(returnTo, "^(%a+):([%w_]+)$")
	if (kind == "Waystone" or kind == "Gate") and id and #id <= Rules.MAX_ID_LENGTH then
		return kind, id
	end
	return nil, nil
end

-- The teleport data for players going home from an instance: only the version. Where they arrive
-- is never in teleport data (a client can teleport itself here carrying any data); it is the
-- profile's PendingReturn.
function Rules.ReturnData(): { [string]: any }
	return { Version = Rules.VERSION }
end

-- The PendingReturn an instance server writes into a profile before sending the player home
-- (To "" when there is no valid destination).
function Rules.PendingReturn(returnTo: string?, now: number): Pending
	if Rules.SplitReturnTo(returnTo) then
		return { To = returnTo :: string, At = now }
	end
	return { To = "", At = 0 }
end

-- A public server reading a profile's PendingReturn: the destination ("Waystone"/"Gate", id) if it
-- is valid and was written within `window` seconds, and the value to store back, which always
-- clears it (it is used at most once; stale or malformed ones are dropped). `cleared` is nil when
-- there was nothing to clear.
function Rules.TakePending(pending: any, now: number, window: number): (string?, string?, Pending?)
	if type(pending) ~= "table" or (pending.To == "" and pending.At == 0) then
		return nil, nil, nil
	end
	local cleared: Pending = { To = "", At = 0 }
	local at = pending.At
	if type(at) ~= "number" or at ~= at then
		return nil, nil, cleared
	end
	local age = now - at
	if age > window or age < -Rules.CLOCK_SKEW then
		return nil, nil, cleared
	end
	local kind, id = Rules.SplitReturnTo(pending.To)
	return kind, id, cleared
end

-- Seconds to wait before attempt `attempt` (the first attempt waits nothing).
function Rules.RetryDelay(attempt: number): number
	return math.max(0, attempt - 1) * Rules.RETRY_BASE
end

-- After `attempts` failed teleports with this result, try again?
function Rules.ShouldRetry(resultName: string, attempts: number, maxAttempts: number): boolean
	return Rules.RETRYABLE[resultName] == true and attempts < maxAttempts
end

-- Calls `fn` until it succeeds, at most `maxAttempts` times (at least once), sleeping
-- RetryDelay between attempts. Returns ok, the result or the last error, and the attempts made.
function Rules.Retry<T>(maxAttempts: number, fn: () -> T, sleep: (number) -> ()): (boolean, T | string, number)
	local attempts = math.max(1, math.floor(maxAttempts))
	local lastError = "no attempt"
	for attempt = 1, attempts do
		if attempt > 1 then
			sleep(Rules.RetryDelay(attempt))
		end
		local ok, result = pcall(fn)
		if ok then
			return true, result, attempt
		end
		lastError = tostring(result)
	end
	return false, lastError, attempts
end

-- How long an instance waits before sending everyone home: a finished run gives the party time
-- to collect loot; failures go at once.
function Rules.ReturnDelay(reason: string, returnTimeout: number): number
	return if Rules.RUN_END[reason] then returnTimeout else 0
end

return Rules
