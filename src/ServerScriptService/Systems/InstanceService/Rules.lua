--!strict
--[[
	InstanceService.Rules
	Every pure decision about reserved-server instances (docs/PHASE12_MULTIPLAYER.md, "Reserved
	servers"). No Roblox services: tools/place/test_instances.luau runs it under Lune.

	- UseReserved: whether a run may go to a reserved server at all (else the in-server copy runs).
	- InstanceData / ParseInstance: the teleport data a party carries into an instance server.
	  Teleport data travels through the client, so everything is re-validated on arrival.
	- Admit: who an instance server accepts. Membership is never taken from teleport data alone:
	  the arrival must be named in the record (set by the first valid arrival), must come from this
	  place (SourcePlaceId, set by Roblox), and its own data must name the same run.
	- ArrivalDecision: wait for the party, start with whoever came, or give up.
	- ReturnData / ParseReturn / SplitReturnTo: the way home and where to arrive on the floor.
	- Retry / ShouldRetry / RetryDelay / ReturnDelay: retry and timing rules.
]]

export type Mode = "Dungeon" | "Guardian"

export type Record = {
	Mode: Mode,
	Id: string,
	Members: { number }, -- UserIds
	ReturnPlaceId: number,
}

export type Limits = {
	PlaceId: number, -- this place: the only one an instance may return to
	MaxMembers: number,
	IsKnownId: (mode: Mode, id: string) -> boolean,
}

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
function Rules.InstanceData(mode: Mode, id: string, userIds: { number }, returnPlaceId: number): { [string]: any }
	return {
		Version = Rules.VERSION,
		Mode = mode,
		Id = id,
		Members = table.clone(userIds),
		ReturnPlaceId = returnPlaceId,
	}
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
	return { Mode = mode, Id = id, Members = list, ReturnPlaceId = returnPlaceId }, nil
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

-- The teleport data for players going home from an instance.
function Rules.ReturnData(returnTo: string?): { [string]: any }
	local kind = Rules.SplitReturnTo(returnTo)
	return { Version = Rules.VERSION, ReturnTo = if kind then returnTo else nil }
end

-- A public server reading an arrival's data: the validated ReturnTo, or nil. Only arrivals from
-- this place count (the point itself is checked against the floor by FloorService).
function Rules.ParseReturn(raw: any, sourcePlaceId: any, placeId: number): string?
	if type(raw) ~= "table" or raw.Version ~= Rules.VERSION then
		return nil
	end
	if not isPlaceId(sourcePlaceId) or sourcePlaceId ~= placeId then
		return nil
	end
	local kind = Rules.SplitReturnTo(raw.ReturnTo)
	return if kind then raw.ReturnTo else nil
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
