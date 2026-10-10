--!nocheck
-- Offline test of the reserved-server rules (Systems/InstanceService/Rules.lua) with the real
-- Config.Social.Instances tuning loaded from src/: the fallback decision (Studio, unpublished,
-- disabled, nested), teleport-data building and parsing (malformed data of every kind), who an
-- instance server admits (non-members, wrong source place, mismatched runs), the source party
-- carried in, the arrival timeout, the way home (never from teleport data: the profile's
-- PendingReturn, used once and only while fresh), and the retry rules. Every check is an assert;
-- the run prints a summary.
--
--   lune run tools/place/test_instances.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

-- Minimal module runtime (same as test_party.luau): src/ folders become instance-like tables.
local function build(path: string, parent)
	local node = { __path = path, Parent = parent }
	for _, entry in fs.readDir(path) do
		local full = path .. "/" .. entry
		if fs.isDir(full) then
			node[entry] = build(full, node)
		elseif entry == "init.lua" then
			node.__source = full
		else
			local name = string.match(entry, "^(.-)%.lua$")
			if name and not string.find(name, "%.") then
				node[name] = { __path = full, __source = full, Parent = node }
			end
		end
	end
	return node
end

local cache = {}
local function requireNode(node)
	if cache[node] ~= nil then
		return cache[node]
	end
	local sourcePath = assert(node.__source, "not a module: " .. tostring(node.__path))
	local env = setmetatable({
		script = node,
		require = requireNode,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		Color3 = roblox.Color3,
		CFrame = roblox.CFrame,
		Enum = roblox.Enum,
	}, { __index = _G })
	local result = luau.load(fs.readFile(sourcePath), { debugName = sourcePath, environment = env })()
	cache[node] = result
	return result
end

local Shared = build("src/ReplicatedStorage/Shared", nil)
local Systems = build("src/ServerScriptService/Systems", nil)
local Social = requireNode(Shared.Config.Social)
local Rules = requireNode(Systems.InstanceService.Rules)

local I = Social.Instances
local PLACE = 123456789
local OTHER_PLACE = 987654321

local LIMITS = {
	PlaceId = PLACE,
	MaxMembers = 8,
	IsKnownId = function(mode, id)
		if mode == "Dungeon" then
			return id == "SunkenCistern"
		end
		return id == "Brinewarden"
	end,
	LootModes = Social.Party.LootModes,
}

local passed = 0
local function case(name: string, body: () -> ())
	local ok, err = pcall(body)
	if not ok then
		error(`FAIL {name}: {err}`, 0)
	end
	passed += 1
end

local function env(overrides)
	local e = { Enabled = true, PlaceId = PLACE, IsStudio = false, InInstance = false }
	for key, value in overrides or {} do
		e[key] = value
	end
	return e
end

local function good(overrides)
	local data = Rules.InstanceData("Dungeon", "SunkenCistern", { 101, 202, 303 }, PLACE)
	for key, value in overrides or {} do
		data[key] = value
	end
	return data
end

local function rejects(raw, reason: string)
	local record, why = Rules.ParseInstance(raw, LIMITS)
	assert(record == nil, `accepted malformed data (expected {reason})`)
	assert(why == reason, `expected {reason}, got {tostring(why)}`)
end

-- CONFIG -------------------------------------------------------------------------------------

case("config tuning is sane", function()
	assert(type(I.UseReservedServers) == "boolean", "UseReservedServers")
	assert(type(I.TeleportRetries) == "number" and I.TeleportRetries >= 1, "TeleportRetries")
	assert(I.ReturnTimeout > 0 and I.ArrivalTimeout > 0, "timeouts")
	assert(I.TeleportDeadline >= I.ArrivalTimeout, "a slow teleport gets at least the arrival timeout")
	assert(I.ReturnWindow > I.ReturnTimeout, "a pending return outlives the trip home")
end)

-- FALLBACK DECISION ---------------------------------------------------------------------------

case("published live server uses a reserved server", function()
	local ok, why = Rules.UseReserved(env())
	assert(ok == true and why == "Ok", why)
end)

case("Studio falls back to the in-server run", function()
	local ok, why = Rules.UseReserved(env({ IsStudio = true }))
	assert(ok == false and why == "Studio", why)
end)

case("unpublished place (PlaceId 0) falls back", function()
	local ok, why = Rules.UseReserved(env({ PlaceId = 0 }))
	assert(ok == false and why == "Unpublished", why)
end)

case("Config switch off falls back", function()
	local ok, why = Rules.UseReserved(env({ Enabled = false }))
	assert(ok == false and why == "Disabled", why)
end)

case("an instance server never nests another", function()
	local ok, why = Rules.UseReserved(env({ InInstance = true }))
	assert(ok == false and why == "InInstance", why)
end)

case("Studio with the real Config always falls back", function()
	local ok = Rules.UseReserved(env({ Enabled = I.UseReservedServers, IsStudio = true }))
	assert(ok == false)
	ok = Rules.UseReserved(env({ Enabled = I.UseReservedServers, PlaceId = 0 }))
	assert(ok == false)
end)

-- TELEPORT DATA -------------------------------------------------------------------------------

case("instance data round-trips", function()
	local members = { 101, 202 }
	local data = Rules.InstanceData("Guardian", "Brinewarden", members, PLACE)
	assert(data.Version == 1 and data.Mode == "Guardian" and data.Id == "Brinewarden" and data.ReturnPlaceId == PLACE)
	assert(data.Members ~= members, "members list must be a copy")
	local record, why = Rules.ParseInstance(data, LIMITS)
	assert(record, why)
	assert(record.Mode == "Guardian" and record.Id == "Brinewarden" and #record.Members == 2 and record.ReturnPlaceId == PLACE)
	assert(record.Members[1] == 101 and record.Members[2] == 202)
end)

case("malformed: not a table / wrong version", function()
	rejects(nil, "NotTable")
	rejects("Dungeon", "NotTable")
	rejects(42, "NotTable")
	rejects(good({ Version = 2 }), "Version")
	rejects(good({ Version = "1" }), "Version")
end)

case("malformed: mode", function()
	rejects(good({ Mode = "Raid" }), "Mode")
	rejects(good({ Mode = "dungeon" }), "Mode")
	rejects(good({ Mode = 1 }), "Mode")
end)

case("malformed: id", function()
	rejects(good({ Id = "" }), "Id")
	rejects(good({ Id = "Sunken Cistern" }), "Id")
	rejects(good({ Id = "../SunkenCistern" }), "Id")
	rejects(good({ Id = string.rep("a", Rules.MAX_ID_LENGTH + 1) }), "Id")
	rejects(good({ Id = "UnknownDungeon" }), "Id")
	rejects(good({ Id = 7 }), "Id")
	-- a Guardian id under the Dungeon mode is unknown to that mode
	rejects(good({ Id = "Brinewarden" }), "Id")
end)

case("malformed: members", function()
	rejects(good({ Members = "101" }), "Members")
	rejects(good({ Members = {} }), "Members")
	rejects(good({ Members = { 101, 101 } }), "Members")
	rejects(good({ Members = { 101, -5 } }), "Members")
	rejects(good({ Members = { 101, 0 } }), "Members")
	rejects(good({ Members = { 101, 2.5 } }), "Members")
	rejects(good({ Members = { 101, 0 / 0 } }), "Members")
	rejects(good({ Members = { 101, math.huge } }), "Members")
	rejects(good({ Members = { 101, "202" } }), "Members")
	rejects(good({ Members = { [1] = 101, [3] = 303 } }), "Members")
	rejects(good({ Members = { 101, Extra = 202 } }), "Members")
	local many = {}
	for index = 1, LIMITS.MaxMembers + 1 do
		many[index] = 1000 + index
	end
	rejects(good({ Members = many }), "Members")
	many[LIMITS.MaxMembers + 1] = nil
	assert(Rules.ParseInstance(good({ Members = many }), LIMITS), "a full party is fine")
end)

case("the source party rides along and is checked", function()
	local party = { Leader = 202, Members = { 202, 101 }, LootMode = "SharedGold" }
	local data = Rules.InstanceData("Dungeon", "SunkenCistern", { 101, 202, 303 }, PLACE, party)
	assert(data.Party ~= party and data.Party.Members ~= party.Members, "party data must be a copy")
	local record, why = Rules.ParseInstance(data, LIMITS)
	assert(record and record.Party, why)
	assert(record.Party.Leader == 202 and #record.Party.Members == 2 and record.Party.LootMode == "SharedGold")
	assert(Rules.ParseInstance(good(), LIMITS).Party == nil, "no party: solo or strangers")
	local function badParty(value)
		rejects(good({ Party = value }), "Party")
	end
	badParty("202")
	badParty({ Leader = 202, Members = { 202 }, LootMode = "Personal" }) -- a party of one
	badParty({ Leader = 404, Members = { 202, 101 }, LootMode = "Personal" }) -- leader outside it
	badParty({ Leader = 202, Members = { 202, 404 }, LootMode = "Personal" }) -- not a run member
	badParty({ Leader = 202, Members = { 202, 202 }, LootMode = "Personal" })
	badParty({ Leader = 202, Members = { 202, 101 }, LootMode = "Everything" })
	badParty({ Leader = 202, Members = { 202, 101 } })
	badParty({ Leader = "202", Members = { 202, 101 }, LootMode = "Personal" })
	badParty({ Leader = 202, Members = { [1] = 202, [3] = 101 }, LootMode = "Personal" })
end)

case("malformed: return place", function()
	rejects(good({ ReturnPlaceId = OTHER_PLACE }), "ReturnPlace")
	rejects(good({ ReturnPlaceId = 0 }), "ReturnPlace")
	rejects(good({ ReturnPlaceId = PLACE + 0.5 }), "ReturnPlace")
	rejects(good({ ReturnPlaceId = tostring(PLACE) }), "ReturnPlace")
	local data = good()
	data.ReturnPlaceId = nil
	rejects(data, "ReturnPlace")
end)

-- ADMISSION -----------------------------------------------------------------------------------

case("members from this place carrying the same run are admitted", function()
	local raw = good()
	local record = assert(Rules.ParseInstance(raw, LIMITS))
	for _, userId in { 101, 202, 303 } do
		local ok, why = Rules.Admit(record, userId, PLACE, PLACE, raw)
		assert(ok == true and why == nil, why)
	end
end)

case("non-members are turned away", function()
	local raw = good()
	local record = assert(Rules.ParseInstance(raw, LIMITS))
	local ok, why = Rules.Admit(record, 404, PLACE, PLACE, raw)
	assert(ok == false and why == "NotMember")
	-- naming yourself in your own data doesn't help: the record is fixed by the first arrival
	local forged = good({ Members = { 404 } })
	ok, why = Rules.Admit(record, 404, PLACE, PLACE, forged)
	assert(ok == false and why == "NotMember")
end)

case("arrivals from another place (or no source) are turned away", function()
	local raw = good()
	local record = assert(Rules.ParseInstance(raw, LIMITS))
	for _, source in { OTHER_PLACE, nil, 0, tostring(PLACE), PLACE + 0.5 } do
		local ok, why = Rules.Admit(record, 101, source, PLACE, raw)
		assert(ok == false and why == "WrongSource", `source {tostring(source)}`)
	end
end)

case("a member carrying a different run is turned away", function()
	local record = assert(Rules.ParseInstance(good(), LIMITS))
	for _, raw in { good({ Id = "Other" }), good({ Mode = "Guardian" }), good({ Version = 9 }), nil, "x" } do
		local ok, why = Rules.Admit(record, 101, PLACE, PLACE, raw)
		assert(ok == false and why == "Mismatch")
	end
end)

-- ARRIVALS ------------------------------------------------------------------------------------

case("arrival decision", function()
	local timeout = I.ArrivalTimeout
	assert(Rules.ArrivalDecision(3, 0, 0, timeout) == "Wait")
	assert(Rules.ArrivalDecision(3, 2, timeout - 1, timeout) == "Wait")
	assert(Rules.ArrivalDecision(3, 3, 1, timeout) == "Start")
	assert(Rules.ArrivalDecision(3, 2, timeout, timeout) == "Start")
	assert(Rules.ArrivalDecision(3, 0, timeout, timeout) == "Abandon")
	assert(Rules.ArrivalDecision(0, 0, 1, timeout) == "Wait")
end)

-- THE WAY HOME --------------------------------------------------------------------------------

case("ReturnTo split and validation", function()
	local kind, id = Rules.SplitReturnTo("Waystone:F1_CisternGate")
	assert(kind == "Waystone" and id == "F1_CisternGate")
	kind, id = Rules.SplitReturnTo("Gate:Brinewarden")
	assert(kind == "Gate" and id == "Brinewarden")
	for _, bad in { "Town:Square", "Waystone:", "Waystone", "Waystone:a b", "Gate:../x", 5, nil, "Gate:" .. string.rep("a", 70) } do
		kind, id = Rules.SplitReturnTo(bad)
		assert(kind == nil and id == nil, `accepted {tostring(bad)}`)
	end
end)

local NOW = 1_700_000_000
local WINDOW = I.ReturnWindow

case("ReturnTo in teleport data is ignored", function()
	-- The way home carries no destination, and nothing reads one from teleport data: a client can
	-- TeleportService:Teleport(game.PlaceId, nil, { Version = 1, ReturnTo = "Gate:..." }) itself.
	local data = Rules.ReturnData()
	assert(data.Version == 1 and data.ReturnTo == nil)
	local count = 0
	for _ in data do
		count += 1
	end
	assert(count == 1, "only the version")
	assert(Rules.ParseReturn == nil, "no teleport-data reader for the way home")
	-- forged join data shaped like the old ReturnTo is not a pending return either
	local forged = { Version = 1, ReturnTo = "Gate:Brinewarden" }
	local kind, id = Rules.TakePending(forged, NOW, WINDOW)
	assert(kind == nil and id == nil, "teleport data is not a PendingReturn")
end)

case("pending return: written by the instance, consumed once", function()
	local profile = { PendingReturn = { To = "", At = 0 } }
	profile.PendingReturn = Rules.PendingReturn("Gate:Brinewarden", NOW)
	assert(profile.PendingReturn.To == "Gate:Brinewarden" and profile.PendingReturn.At == NOW)
	-- what InstanceService.TakeReturnTo does with the profile value
	local function take(at: number)
		local kind, id, cleared = Rules.TakePending(profile.PendingReturn, at, WINDOW)
		if cleared then
			profile.PendingReturn = cleared
		end
		return kind, id
	end
	local kind, id = take(NOW + 12)
	assert(kind == "Gate" and id == "Brinewarden", "first spawn after the run")
	assert(profile.PendingReturn.To == "" and profile.PendingReturn.At == 0, "cleared")
	kind, id = take(NOW + 13)
	assert(kind == nil and id == nil, "second spawn: back to the usual Waystone")
	local _, _, cleared = Rules.TakePending(profile.PendingReturn, NOW + 14, WINDOW)
	assert(cleared == nil, "an empty one needs no write")
	-- a dungeon exit
	profile.PendingReturn = Rules.PendingReturn("Waystone:F1_CisternGate", NOW)
	kind, id = take(NOW + WINDOW)
	assert(kind == "Waystone" and id == "F1_CisternGate", "valid right up to the window")
end)

case("stale, future or malformed pending returns are ignored (and cleared)", function()
	local function ignored(pending, at: number, label: string)
		local kind, id, cleared = Rules.TakePending(pending, at, WINDOW)
		assert(kind == nil and id == nil, `honoured {label}`)
		assert(cleared and cleared.To == "" and cleared.At == 0, `not cleared: {label}`)
	end
	local good = Rules.PendingReturn("Gate:Brinewarden", NOW)
	ignored(good, NOW + WINDOW + 1, "stale")
	ignored(good, NOW - Rules.CLOCK_SKEW - 1, "stamped in the future")
	ignored({ To = "Town:Square", At = NOW }, NOW, "unknown kind")
	ignored({ To = "Gate:../x", At = NOW }, NOW, "bad id")
	ignored({ To = 5, At = NOW }, NOW, "non-string")
	ignored({ To = "Gate:Brinewarden", At = "now" }, NOW, "non-number time")
	ignored({ To = "Gate:Brinewarden", At = 0 / 0 }, NOW, "NaN time")
	ignored({ To = "Gate:Brinewarden" }, NOW, "no time")
	for _, empty in { false, "Gate:Brinewarden", { To = "", At = 0 } } do
		local kind, _, cleared = Rules.TakePending(empty, NOW, WINDOW)
		assert(kind == nil and cleared == nil)
	end
	local kind, _, cleared = Rules.TakePending(nil, NOW, WINDOW)
	assert(kind == nil and cleared == nil, "no profile value")
	-- no destination (refused / non-member): nothing to honour
	for _, destination in { nil, "Bogus", "Somewhere:Else" } do
		local pending = Rules.PendingReturn(destination, NOW)
		assert(pending.To == "" and pending.At == 0, tostring(destination))
	end
end)

-- RETRIES -------------------------------------------------------------------------------------

local function sleeper()
	local slept = {}
	return slept, function(seconds: number)
		table.insert(slept, seconds)
	end
end

case("retry: first success makes one attempt and never sleeps", function()
	local slept, sleep = sleeper()
	local ok, result, attempts = Rules.Retry(I.TeleportRetries, function()
		return "code"
	end, sleep)
	assert(ok == true and result == "code" and attempts == 1 and #slept == 0)
end)

case("retry: transient failures are retried with growing waits", function()
	local slept, sleep = sleeper()
	local calls = 0
	local ok, result, attempts = Rules.Retry(3, function()
		calls += 1
		if calls < 3 then
			error("HTTP 503")
		end
		return "code"
	end, sleep)
	assert(ok == true and result == "code" and attempts == 3 and calls == 3)
	assert(#slept == 2 and slept[1] == Rules.RETRY_BASE and slept[2] == Rules.RETRY_BASE * 2)
end)

case("retry: gives up after the Config retries with the last error", function()
	local slept, sleep = sleeper()
	local calls = 0
	local ok, result, attempts = Rules.Retry(I.TeleportRetries, function()
		calls += 1
		error(`fail {calls}`, 0)
	end, sleep)
	assert(ok == false and attempts == I.TeleportRetries and calls == I.TeleportRetries)
	assert(result == `fail {I.TeleportRetries}`, tostring(result))
	assert(#slept == I.TeleportRetries - 1)
end)

case("retry: at least one attempt even with a bad count", function()
	local _, sleep = sleeper()
	local calls = 0
	local ok, _, attempts = Rules.Retry(0, function()
		calls += 1
		return true
	end, sleep)
	assert(ok == true and attempts == 1 and calls == 1)
end)

case("teleport failure results: retry only what can change", function()
	assert(Rules.ShouldRetry("Failure", 1, 3) == true)
	assert(Rules.ShouldRetry("Flooded", 2, 3) == true)
	assert(Rules.ShouldRetry("GameFull", 1, 3) == true)
	assert(Rules.ShouldRetry("Failure", 3, 3) == false)
	assert(Rules.ShouldRetry("Unauthorized", 1, 3) == false)
	assert(Rules.ShouldRetry("GameNotFound", 1, 3) == false)
	assert(Rules.RetryDelay(1) == 0 and Rules.RetryDelay(2) == Rules.RETRY_BASE)
end)

case("return delay: a finished run waits, a failure goes at once", function()
	for _, reason in { "Cleared", "Victory", "Wipe" } do
		assert(Rules.ReturnDelay(reason, I.ReturnTimeout) == I.ReturnTimeout, reason)
	end
	for _, reason in { "Failed", "NoParty", "Exit" } do
		assert(Rules.ReturnDelay(reason, I.ReturnTimeout) == 0, reason)
	end
end)

print(`test_instances: {passed} cases passed`)
