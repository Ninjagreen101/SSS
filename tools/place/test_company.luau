--!nocheck
-- Offline test of Climber Company rules (Systems/CompanyService/Rules.lua) and the DataStore
-- wrapper (Systems/CompanyService/Store.lua) with the real Shared data and Config loaded from
-- src/. Covers (docs/PHASE12_MULTIPLAYER.md section 4):
--   - rank permissions: the action matrix, kick / promote / demote by rank, leadership handover,
--     the Leader can't leave, self-targeting and non-members refused
--   - name rules: trimming, length, characters, the case-insensitive index key, claim freedom
--   - storage invariants: stacking, the slot cap (a refusal changes nothing), returns past the
--     cap, take counts (0 = all, bad counts refused), undoing a deposit all-or-nothing, items are
--     conserved through every add / take, Disband needs an empty chest
--   - weekly quests: the roll is deterministic and distinct, Normalize only moves forward and
--     keeps last week, progress caps and completes, rewards are claimable once and only by
--     members who belonged when a quest completed
--   - the store: a conflicting write mid-UpdateAsync makes the transform re-run on the newer
--     record (rules re-checked), failed requests retry with doubling backoff, out of attempts =
--     "Failed", out of budget = "Busy", a mutate that errors writes nothing, and an attempt that
--     commits but errors is recognised on retry by its op id (no double deposit)
--   - every refusal reason has player text in Strings.Company.Errors
-- Every check is an assert; the run prints a summary.
--
--   lune run tools/place/test_company.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

-- A minimal module runtime (as in test_trade.luau): src/ folders become instance-like tables.
local function waitForChild(self, name: string)
	local child = rawget(self, name)
	assert(child, "missing child " .. tostring(name))
	return child
end

local function build(path: string, parent)
	local node = { __path = path, Parent = parent, WaitForChild = waitForChild, FindFirstChild = rawget }
	for _, entry in fs.readDir(path) do
		local full = path .. "/" .. entry
		if fs.isDir(full) then
			node[entry] = build(full, node)
		elseif entry == "init.lua" then
			node.__source = full
		else
			local name = string.match(entry, "^(.-)%.lua$")
			if name and not string.find(name, "%.") then
				node[name] = { __path = full, __source = full, Parent = node, WaitForChild = waitForChild }
			end
		end
	end
	return node
end

local services = {
	ReplicatedStorage = build("src/ReplicatedStorage", nil),
	ServerScriptService = build("src/ServerScriptService", nil),
}

local fakeGame = {}
function fakeGame:GetService(name: string)
	return assert(services[name], "no service " .. name)
end

local FakeRandom = {}
FakeRandom.__index = FakeRandom
function FakeRandom.new(seed: number?)
	return setmetatable({ State = (seed or 7) % 2147483647 + 1 }, FakeRandom)
end
function FakeRandom:NextNumber(min: number?, max: number?): number
	self.State = (self.State * 48271) % 2147483647
	local unit = self.State / 2147483647
	local lo, hi = min or 0, max or 1
	return lo + (hi - lo) * unit
end
function FakeRandom:NextInteger(min: number, max: number): number
	return math.min(max, min + math.floor(self:NextNumber() * (max - min + 1)))
end

local cache = {}
local function requireNode(node)
	if cache[node] ~= nil then
		return cache[node]
	end
	local sourcePath = assert(node.__source, "not a module: " .. tostring(node.__path))
	local env = setmetatable({
		script = node,
		game = fakeGame,
		require = requireNode,
		Random = FakeRandom,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		Color3 = roblox.Color3,
		CFrame = roblox.CFrame,
		Enum = roblox.Enum,
		NumberRange = roblox.NumberRange,
		NumberSequence = roblox.NumberSequence,
		ColorSequence = roblox.ColorSequence,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
	}, { __index = _G })
	local result = luau.load(fs.readFile(sourcePath), { debugName = sourcePath, environment = env })()
	cache[node] = result
	return result
end

local Shared = services.ReplicatedStorage.Shared
local Systems = services.ServerScriptService.Systems
local Config = requireNode(Shared.Config)
local Items = requireNode(Shared.Data.Items)
local Strings = requireNode(Shared.Strings)
local CompanyQuests = requireNode(Shared.Data.CompanyQuests)
local Rules = requireNode(Systems.CompanyService.Rules)
local Store = requireNode(Systems.CompanyService.Store)

local K = Config.Social.Company
local RANKS = K.Ranks
local NOW = 1760000000 -- a fixed unix time

-- FIXTURES ---------------------------------------------------------------------------------

local ids = {}
for id in Items.Definitions do
	table.insert(ids, id)
end
table.sort(ids)
local GEAR, MATERIAL
for _, id in ids do
	local def = Items.Definitions[id]
	if not GEAR and def.Tradeable and def.StackSize == 1 then
		GEAR = id
	elseif not MATERIAL and def.Tradeable and def.StackSize >= 10 then
		MATERIAL = id
	end
end
assert(GEAR and MATERIAL, "fixture items not found")
local STACK = Items.Get(MATERIAL).StackSize

local function item(defId: string, count: number)
	return { Uid = "bag1", DefId = defId, Rarity = "Common", Count = count, Upgrade = 0, Affixes = {}, Durability = 100, Locked = false, New = false }
end

-- A record with a Leader (1), Officer (2), Member (3) and Recruit (4).
local function company()
	local record = Rules.NewRecord("abcdefghjk", "Tide Wardens", 3, "1", "Lead", NOW)
	record.Members["2"] = { Rank = "Officer", JoinedAt = NOW, Name = "Off", Claims = {} }
	record.Members["3"] = { Rank = "Member", JoinedAt = NOW, Name = "Mem", Claims = {} }
	record.Members["4"] = { Rank = "Recruit", JoinedAt = NOW, Name = "Rec", Claims = {} }
	return record
end

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, inner in value do
		out[key] = deepCopy(inner)
	end
	return out
end

local function total(record, defId: string): number
	return Rules.StorageCount(record, defId)
end

local function fails(expected: string, success, reason)
	assert(success == false or success == nil, `expected refusal {expected}, got success`)
	assert(reason == expected, `expected reason {expected}, got {tostring(reason)}`)
end

local reasonsSeen: { [string]: boolean } = {}

local passed = 0
local function case(name: string, body: () -> ())
	body()
	passed += 1
	print(`  ok  {name}`)
end

print(`test_company: gear {GEAR}, material {MATERIAL} (stack {STACK})`)

-- RANKS -------------------------------------------------------------------------------------

case("rank matrix", function()
	local expect = {
		Leader = { Invite = true, Kick = true, Promote = true, Demote = true, SetEmblem = true, Disband = true, Deposit = true, Withdraw = true },
		Officer = { Invite = true, Kick = true, Promote = true, Demote = true, SetEmblem = true, Disband = false, Deposit = true, Withdraw = true },
		Member = { Invite = false, Kick = false, Promote = false, Demote = false, SetEmblem = false, Disband = false, Deposit = true, Withdraw = true },
		Recruit = { Invite = false, Kick = false, Promote = false, Demote = false, SetEmblem = false, Disband = false, Deposit = true, Withdraw = false },
		Nobody = {},
	}
	for rank, actions in expect do
		for _, action in Rules.Actions do
			assert(Rules.Can(rank, action) == (actions[action] == true), `{rank} {action}`)
		end
		assert(not Rules.Can(rank, "Unknown"), "unknown action allowed")
	end
end)

case("kick: only strictly lower ranks", function()
	assert(Rules.CanKick("Leader", "Officer"))
	assert(Rules.CanKick("Officer", "Member"))
	assert(Rules.CanKick("Officer", "Recruit"))
	fails("Rank", Rules.CanKick("Officer", "Officer"))
	fails("Rank", Rules.CanKick("Officer", "Leader"))
	fails("Rank", Rules.CanKick("Member", "Recruit"))
	local record = company()
	fails("NotMember", Rules.Kick(record, "1", "1"))
	fails("NotMember", Rules.Kick(record, "1", "99"))
	fails("NotInCompany", Rules.Kick(record, "99", "3"))
	fails("Rank", Rules.Kick(record, "3", "4"))
	assert(Rules.Kick(record, "2", "4"))
	assert(record.Members["4"] == nil and Rules.MemberCount(record) == 3)
end)

case("promote / demote ladders and leadership handover", function()
	assert(Rules.PromoteTo("Officer", "Recruit") == "Member")
	fails("Rank", Rules.PromoteTo("Officer", "Member")) -- an Officer can't make peers
	assert(Rules.PromoteTo("Leader", "Member") == "Officer")
	assert(Rules.PromoteTo("Leader", "Officer") == "Leader")
	fails("Rank", Rules.PromoteTo("Member", "Recruit"))
	assert(Rules.DemoteTo("Officer", "Member") == "Recruit")
	fails("LowestRank", Rules.DemoteTo("Officer", "Recruit"))
	fails("Rank", Rules.DemoteTo("Officer", "Officer"))
	assert(Rules.DemoteTo("Leader", "Officer") == "Member")

	local record = company()
	local ok, _, rank = Rules.Promote(record, "1", "2")
	assert(ok and rank == "Leader")
	assert(record.Members["2"].Rank == "Leader" and record.Members["1"].Rank == "Officer", "handover")
	local leaders = 0
	for _, member in record.Members do
		if member.Rank == RANKS[1] then
			leaders += 1
		end
	end
	assert(leaders == 1, "exactly one Leader after handover")
	fails("NotMember", Rules.Promote(record, "2", "2"))
	fails("NotMember", Rules.Demote(record, "2", "2"))
end)

case("leave: the Leader can't; others can", function()
	local record = company()
	fails("LeaderLeave", Rules.Leave(record, "1"))
	assert(Rules.Leave(record, "4"))
	fails("NotInCompany", Rules.Leave(record, "4"))
end)

case("membership: duplicates, cap, disbanded", function()
	local record = company()
	fails("AlreadyMember", Rules.AddMember(record, "3", "Mem", NOW))
	for index = 5, K.MaxMembers do
		assert(Rules.AddMember(record, tostring(index), "P" .. index, NOW))
	end
	assert(Rules.MemberCount(record) == K.MaxMembers)
	fails("Full", Rules.AddMember(record, "999", "Late", NOW))
	assert(record.Members[tostring(K.MaxMembers)].Rank == RANKS[#RANKS], "joins as Recruit")
	local other = company()
	assert(Rules.Disband(other, "1"))
	fails("NotFound", Rules.AddMember(other, "50", "X", NOW))
	fails("NotInCompany", Rules.Leave(other, "2"))
end)

case("emblems", function()
	local record = company()
	fails("Rank", Rules.SetEmblem(record, "3", 5))
	fails("Emblem", Rules.SetEmblem(record, "2", 0))
	fails("Emblem", Rules.SetEmblem(record, "2", K.Emblems + 1))
	fails("Emblem", Rules.SetEmblem(record, "2", 2.5))
	fails("Unchanged", Rules.SetEmblem(record, "2", 3))
	assert(Rules.SetEmblem(record, "2", K.Emblems) and record.Emblem == K.Emblems)
end)

-- NAMES -------------------------------------------------------------------------------------

case("name rules", function()
	assert(Rules.CleanName("  Tide   Wardens ") == "Tide Wardens")
	assert(Rules.CleanName("O'Malley's Crew") == "O'Malley's Crew")
	assert(Rules.CleanName("Salt-Born 7") == "Salt-Born 7")
	fails("NameLength", Rules.CleanName("ab"))
	fails("NameLength", Rules.CleanName(string.rep("a", K.NameMax + 1)))
	assert(Rules.CleanName(string.rep("a", K.NameMax)) ~= nil)
	fails("NameChars", Rules.CleanName("Tide<b>"))
	fails("NameChars", Rules.CleanName("1234"))
	fails("NameChars", Rules.CleanName("Tide--Wardens"))
	fails("NameChars", Rules.CleanName("Tide''s"))
	fails("NameChars", Rules.CleanName("Tíde"))
	fails("NameChars", Rules.CleanName(nil))
	assert(Rules.NameKey("Tide Wardens") == Rules.NameKey("tIDE wARDENS"), "index is case-insensitive")
	assert(Rules.RecordKey("abc") == "c_abc" and string.sub(Rules.NameKey("X"), 1, 2) == "n_")
end)

case("name claims", function()
	local live = company()
	local gone = company()
	gone.Disbanded = true
	assert(Rules.ClaimIsFree(nil, nil, NOW))
	assert(Rules.ClaimIsFree({ Id = "", At = NOW }, nil, NOW))
	assert(not Rules.ClaimIsFree({ Id = live.Id, At = NOW }, live, NOW))
	assert(Rules.ClaimIsFree({ Id = gone.Id, At = NOW }, gone, NOW))
	assert(not Rules.ClaimIsFree({ Id = "zzzz", At = NOW }, nil, NOW + 5), "a fresh claim mid-create is held")
	assert(Rules.ClaimIsFree({ Id = "zzzz", At = NOW }, nil, NOW + Rules.StaleClaimSeconds + 1), "stale claims free")
end)

case("ids", function()
	local random = FakeRandom.new(3)
	local seen = {}
	for _ = 1, 200 do
		local id = Rules.NewId(random)
		assert(Rules.IsId(id), id)
		assert(not seen[id], "id repeated")
		seen[id] = true
	end
	assert(not Rules.IsId("ABCDEFGHJK") and not Rules.IsId("short") and not Rules.IsId("abcdefghjk1"))
end)

-- STORAGE -----------------------------------------------------------------------------------

case("deposit stacks and conserves", function()
	local record = company()
	local ok, _, placed = Rules.StorageAdd(record, "4", item(MATERIAL, STACK - 2), STACK - 2) -- Recruits may deposit
	assert(ok and #record.Storage == 1 and #placed == 1)
	ok, _, placed = Rules.StorageAdd(record, "3", item(MATERIAL, 5), 5)
	assert(ok, "second deposit")
	assert(#record.Storage == 2, "tops up then opens one slot")
	assert(total(record, MATERIAL) == STACK + 3)
	assert(record.Storage[1].Count == STACK)
	local uids = {}
	for _, entry in record.Storage do
		assert(not uids[entry.Uid], "storage uids unique")
		uids[entry.Uid] = true
		assert(entry.Count >= 1 and entry.Count <= STACK)
	end
	fails("NotInCompany", Rules.StorageAdd(record, "99", item(MATERIAL, 1), 1))
	fails("Invalid", Rules.StorageAdd(record, "3", item(MATERIAL, 1), 0))
	fails("Invalid", Rules.StorageAdd(record, "3", item(MATERIAL, 1), -1))
	fails("Invalid", Rules.StorageAdd(record, "3", item(MATERIAL, 1), 1.5))
	fails("Invalid", Rules.StorageAdd(record, "3", item(MATERIAL, 1), 0 / 0))
	fails("Invalid", Rules.StorageAdd(record, "3", item("NoSuchItem", 1), 1))
end)

case("slot cap: a refusal changes nothing; server returns may exceed it", function()
	local record = company()
	for _ = 1, K.StorageSlots do
		assert(Rules.StorageAdd(record, "3", item(GEAR, 1), 1))
	end
	assert(#record.Storage == K.StorageSlots)
	local before = deepCopy(record)
	fails("StorageFull", Rules.StorageAdd(record, "3", item(GEAR, 1), 1))
	fails("StorageFull", Rules.StorageAdd(record, "3", item(MATERIAL, 1), 1))
	assert(#record.Storage == K.StorageSlots and record.NextUid == before.NextUid, "refusal changed nothing")
	assert(Rules.StorageAdd(record, nil, item(GEAR, 1), 1), "a server return ignores the cap")
	assert(#record.Storage == K.StorageSlots + 1)
end)

case("withdraw counts, ranks and conservation", function()
	local record = company()
	assert(Rules.StorageAdd(record, "3", item(MATERIAL, 7), 7))
	local uid = record.Storage[1].Uid
	fails("Rank", Rules.StorageTake(record, "4", uid, 1))
	fails("NotInCompany", Rules.StorageTake(record, "99", uid, 1))
	fails("Missing", Rules.StorageTake(record, "3", "s999", 1))
	fails("Invalid", Rules.StorageTake(record, "3", uid, 8))
	fails("Invalid", Rules.StorageTake(record, "3", uid, -1))
	fails("Invalid", Rules.StorageTake(record, "3", uid, 0.5))
	assert(total(record, MATERIAL) == 7, "refusals took nothing")
	local ok, _, taken = Rules.StorageTake(record, "3", uid, 3)
	assert(ok and taken.Count == 3 and taken.DefId == MATERIAL)
	assert(total(record, MATERIAL) == 4)
	ok, _, taken = Rules.StorageTake(record, "2", uid, 0)
	assert(ok and taken.Count == 4, "0 takes the stack")
	assert(#record.Storage == 0, "empty stacks are removed")
	-- put back by the server: lands even in a disbanded record
	assert(Rules.Disband(record, "1"))
	assert(Rules.StorageAdd(record, nil, taken, taken.Count))
	assert(total(record, MATERIAL) == 4)
end)

case("undo a deposit: all or nothing", function()
	local record = company()
	assert(Rules.StorageAdd(record, "3", item(MATERIAL, STACK - 1), STACK - 1))
	local ok, _, placed = Rules.StorageAdd(record, "3", item(MATERIAL, 4), 4)
	assert(ok)
	local snapshot = deepCopy(record)
	assert(Rules.StorageRemovePlaced(record, placed))
	assert(total(record, MATERIAL) == STACK - 1, "exactly the deposit came back out")
	-- someone withdrew part of it meanwhile: the undo refuses and changes nothing
	record = snapshot
	local newest = record.Storage[#record.Storage]
	assert(Rules.StorageTake(record, "3", newest.Uid, newest.Count))
	local before = total(record, MATERIAL)
	fails("Missing", Rules.StorageRemovePlaced(record, placed))
	assert(total(record, MATERIAL) == before)
end)

case("disband needs the Leader and an empty chest", function()
	local record = company()
	assert(Rules.StorageAdd(record, "3", item(GEAR, 1), 1))
	fails("Rank", Rules.Disband(record, "2"))
	fails("StorageNotEmpty", Rules.Disband(record, "1"))
	assert(Rules.StorageTake(record, "1", record.Storage[1].Uid, 0))
	assert(Rules.Disband(record, "1"))
	assert(record.Disbanded and Rules.MemberCount(record) == 0)
	assert(Rules.MemberOf(record, "1") == nil)
end)

case("sanitize: garbage in, a safe record out", function()
	assert(Rules.Sanitize(nil) == nil and Rules.Sanitize("x") == nil and Rules.Sanitize({ Id = "" }) == nil)
	local record = Rules.Sanitize({
		Id = "abcdefghjk",
		Version = "9",
		Emblem = 999,
		Members = { ["5"] = { Rank = "Emperor", Name = 4, Claims = { 1, "3:CQ_Slayers" } }, [6] = {} },
		Storage = { { Uid = "s1", DefId = GEAR, Count = 1 }, { Uid = "s2", DefId = GEAR, Count = 0 }, "junk" },
		Quests = "nope",
		Ops = { { Id = "op1", Out = { Count = 2 } }, { Out = 1 } },
	})
	assert(record and record.Version == 0 and record.Emblem == 1)
	assert(record.Members["5"].Rank == RANKS[#RANKS] and record.Members["5"].Name == "5")
	assert(#record.Members["5"].Claims == 1 and record.Members[6] == nil)
	assert(#record.Storage == 1, "bad stacks dropped")
	assert(record.Quests.Week == -1 and #record.Ops == 1 and Rules.FindOp(record, "op1").Out.Count == 2)
end)

-- WEEKLY QUESTS -----------------------------------------------------------------------------

case("weekly roll is deterministic and distinct", function()
	local pool = #CompanyQuests.Ids()
	local differs = false
	local week = Rules.WeekOf(NOW)
	for offset = 0, 20 do
		local a = Rules.RollQuests("abcdefghjk", week + offset)
		local b = Rules.RollQuests("abcdefghjk", week + offset)
		assert(#a == math.min(K.WeeklyQuests, pool))
		local seen = {}
		for index, id in a do
			assert(id == b[index], "same inputs, same roll")
			assert(CompanyQuests.Get(id), id)
			assert(not seen[id], "distinct quests")
			seen[id] = true
		end
		local other = Rules.RollQuests("mnpqrstuvw", week + offset)
		if table.concat(other, ",") ~= table.concat(a, ",") then
			differs = true
		end
	end
	assert(differs, "different Companies roll differently")
	-- weeks start Monday 00:00 UTC
	local resetsAt = Rules.WeekEndsAt(NOW)
	assert(Rules.WeekOf(resetsAt) == week + 1 and Rules.WeekOf(resetsAt - 1) == week)
	assert(os.date("!%w %H:%M:%S", resetsAt) == "1 00:00:00", "Monday 00:00 UTC")
end)

case("normalize: forward only, keeps last week, prunes claims", function()
	local record = company()
	local week = record.Quests.Week
	assert(week == Rules.WeekOf(NOW) and #record.Quests.List == K.WeeklyQuests)
	record.Members["3"].Claims = { Rules.ClaimKey(week - 3, "CQ_Old"), Rules.ClaimKey(week, record.Quests.List[1].Id) }
	assert(not Rules.Normalize(record, week - 1), "never backwards")
	assert(not Rules.Normalize(record, week))
	local list = record.Quests.List
	assert(Rules.Normalize(record, week + 1))
	assert(record.Quests.Week == week + 1 and record.Quests.Last.Week == week and record.Quests.Last.List == list)
	assert(#record.Members["3"].Claims == 1, "claims older than last week pruned")
	assert(Rules.Normalize(record, week + 5))
	assert(record.Quests.Last.Week == -1, "a gap forgets the old week")
end)

case("progress caps, completes and pays each member once", function()
	local record = company()
	local week = record.Quests.Week
	local quest = record.Quests.List[1]
	local def = CompanyQuests.Get(quest.Id)
	-- a member who joins after completion isn't owed it
	local changed, done = Rules.AddProgress(record, week - 1, { [quest.Id] = 5 }, NOW)
	assert(not changed and #done == 0, "stale-week progress dropped")
	changed, done = Rules.AddProgress(record, week, { [quest.Id] = def.Objective.Count - 1, Bogus = 5 }, NOW + 10)
	assert(changed and #done == 0 and quest.Progress == def.Objective.Count - 1)
	assert(#Rules.Claimable(record, "3") == 0, "nothing owed before completion")
	changed, done = Rules.AddProgress(record, week, { [quest.Id] = 50 }, NOW + 20)
	assert(changed and #done == 1 and quest.Progress == def.Objective.Count and quest.DoneAt == NOW + 20, "capped and done")
	changed = Rules.AddProgress(record, week, { [quest.Id] = 5 }, NOW + 30)
	assert(not changed, "a done quest takes no more progress")
	assert(Rules.AddMember(record, "7", "Late", NOW + 25))
	assert(#Rules.Claimable(record, "7") == 0, "joined after it completed")
	local owed = Rules.Claimable(record, "3")
	assert(#owed == 1 and owed[1].Gold == def.Rewards.Gold and owed[1].Shards == def.Rewards.Shards)
	local marked = Rules.MarkClaims(record, { "1", "2", "3", "4", "7", "99" })
	assert(marked["1"] and marked["4"] and not marked["7"] and not marked["99"])
	assert(next(Rules.MarkClaims(record, { "1", "2", "3", "4" })) == nil, "paid once")
	-- an absent member can still claim last week's completion after the roll
	record.Members["8"] = { Rank = "Member", JoinedAt = NOW, Name = "Away", Claims = {} }
	Rules.Normalize(record, week + 1)
	assert(#Rules.Claimable(record, "8") == 1, "last week still claimable")
	assert(Rules.UnmarkClaims(record, "3", { marked["3"][1].Key }))
	assert(#Rules.Claimable(record, "3") == 1, "unmarked claims are owed again")
end)

case("client state", function()
	local record = company()
	local state = Rules.State(record, "2", { ["1"] = true, ["2"] = true }, NOW)
	assert(state.MyRank == "Officer" and state.Permissions.Kick and not state.Permissions.Disband)
	assert(#state.Members == 4 and state.Members[1].Rank == "Leader" and state.Members[1].Online)
	assert(#state.Quests == K.WeeklyQuests and state.StorageSlots == K.StorageSlots)
	local stranger = Rules.State(record, "99", {}, NOW)
	assert(stranger.MyRank == "" and not stranger.Permissions.Deposit)
end)

-- STORE --------------------------------------------------------------------------------------

local waits = {}
local function newStore(backend, attempts: number?)
	return Store.new(backend, {
		Attempts = attempts or 4,
		Backoff = 1,
		BudgetWait = 2,
		Wait = function(seconds: number)
			table.insert(waits, seconds)
		end,
	})
end

-- The CompanyService write pattern: an op id per write, kept in the record; mutate re-checks rules.
local opCounter = 0
local function write(store, key: string, mutate)
	opCounter += 1
	local opId = "op" .. opCounter
	local out, applied = nil, nil
	local ok, value, reason = store.Update(key, function(old)
		out, applied = nil, nil
		local record = Rules.Sanitize(old)
		if record then
			local prior = Rules.FindOp(record, opId)
			if prior then
				applied = prior
				return nil, "Applied"
			end
		end
		if not record then
			return nil, "NotFound"
		end
		local done, why, result = mutate(record)
		if not done then
			return nil, why
		end
		out = result
		Rules.PushOp(record, opId, result)
		record.Version += 1
		return record, nil
	end)
	if not ok and reason == "Applied" then
		return true, nil, nil, applied.Out
	end
	return ok, Rules.Sanitize(value), reason, out
end

case("conflict mid-update: the transform re-runs on the newer record", function()
	local memory = Store.Memory()
	local store = newStore(memory.Backend)
	local key = Rules.RecordKey("abcdefghjk")
	local record = company()
	for _ = 1, K.StorageSlots - 1 do
		assert(Rules.StorageAdd(record, "3", item(GEAR, 1), 1))
	end
	memory.Data[key] = deepCopy(record)
	-- another server fills the last slot while our deposit is in flight
	memory.Conflicts[key] = function(current)
		local other = Rules.Sanitize(current)
		assert(Rules.StorageAdd(other, "2", item(GEAR, 1), 1))
		other.Version += 1
		return other
	end
	local ok, _, reason = write(store, key, function(r)
		return Rules.StorageAdd(r, "3", item(GEAR, 1), 1)
	end)
	fails("StorageFull", ok, reason)
	assert(memory.Calls[key] == 2, "transform ran again on the newer value")
	local stored = Rules.Sanitize(memory.Data[key])
	assert(#stored.Storage == K.StorageSlots and stored.Version == record.Version + 1, "only the other write landed")

	-- a conflicting kick of the target: our promote re-checks and refuses
	memory.Conflicts[key] = function(current)
		local other = Rules.Sanitize(current)
		assert(Rules.Kick(other, "1", "4"))
		return other
	end
	ok, _, reason = write(store, key, function(r)
		return Rules.Promote(r, "2", "4")
	end)
	fails("NotMember", ok, reason)
end)

case("concurrent withdrawals can't take one stack twice", function()
	local memory = Store.Memory()
	local store = newStore(memory.Backend)
	local key = Rules.RecordKey("abcdefghjk")
	local record = company()
	assert(Rules.StorageAdd(record, "3", item(GEAR, 1), 1))
	local uid = record.Storage[1].Uid
	memory.Data[key] = deepCopy(record)
	memory.Conflicts[key] = function(current)
		local other = Rules.Sanitize(current)
		assert(Rules.StorageTake(other, "2", uid, 0))
		return other
	end
	local ok, _, reason, out = write(store, key, function(r)
		return Rules.StorageTake(r, "3", uid, 0)
	end)
	fails("Missing", ok, reason)
	assert(out == nil, "the losing transform's output is discarded")
	assert(#Rules.Sanitize(memory.Data[key]).Storage == 0)
end)

case("failed requests retry with doubling backoff", function()
	local memory = Store.Memory()
	local store = newStore(memory.Backend)
	local key = Rules.RecordKey("abcdefghjk")
	memory.Data[key] = deepCopy(company())
	table.clear(waits)
	memory.Failures[key] = 2
	local ok, _, _, placed = write(store, key, function(r)
		return Rules.StorageAdd(r, "3", item(MATERIAL, 3), 3)
	end)
	assert(ok and #placed == 1, "third attempt committed")
	assert(#waits == 2 and waits[1] == 1 and waits[2] == 2, "backoff doubles")
	assert(Rules.StorageCount(Rules.Sanitize(memory.Data[key]), MATERIAL) == 3, "deposited once")

	memory.Failures[key] = 10
	local before = deepCopy(memory.Data[key])
	local okRead, _, why = store.Read(key)
	fails("Failed", okRead, why)
	memory.Failures[key] = 10
	local okWrite, _, whyWrite = write(store, key, function(r)
		return Rules.StorageAdd(r, "3", item(MATERIAL, 1), 1)
	end)
	fails("Failed", okWrite, whyWrite)
	memory.Failures[key] = 0
	assert(Rules.StorageCount(Rules.Sanitize(memory.Data[key]), MATERIAL) == Rules.StorageCount(Rules.Sanitize(before), MATERIAL))
end)

case("a mutate that errors writes nothing", function()
	local memory = Store.Memory()
	local store = newStore(memory.Backend)
	local key = Rules.RecordKey("abcdefghjk")
	memory.Data[key] = deepCopy(company())
	local before = deepCopy(memory.Data[key])
	local ok, _, reason = store.Update(key, function(_old)
		error("boom")
	end)
	fails("Invalid", ok, reason)
	assert(memory.Data[key].Version == before.Version)
end)

case("out of request budget = Busy", function()
	local memory = Store.Memory()
	local backend = table.clone(memory.Backend)
	backend.Budget = function(_kind)
		return 0
	end
	local store = newStore(backend)
	table.clear(waits)
	local ok, _, reason = store.Update("c_x", function(old)
		return old
	end)
	fails("Busy", ok, reason)
	assert(#waits >= 1, "waited for budget before giving up")
end)

case("an attempt that commits then errors is not applied twice", function()
	local memory = Store.Memory()
	local key = Rules.RecordKey("abcdefghjk")
	memory.Data[key] = deepCopy(company())
	-- the first request commits, then its response is lost
	local lose = 1
	local backend = table.clone(memory.Backend)
	backend.Update = function(k, transform)
		local result = memory.Backend.Update(k, transform)
		if lose > 0 then
			lose -= 1
			error("response lost after commit")
		end
		return result
	end
	local store = newStore(backend)
	local ok, _, _, placed = write(store, key, function(r)
		return Rules.StorageAdd(r, "3", item(MATERIAL, 4), 4)
	end)
	assert(ok, "the retry reports the earlier commit as success")
	assert(type(placed) == "table" and #placed == 1 and placed[1].Count == 4, "with that commit's output")
	local stored = Rules.Sanitize(memory.Data[key])
	assert(Rules.StorageCount(stored, MATERIAL) == 4, "deposited exactly once")

	-- same for a withdraw: the retry hands back the item the first attempt took
	lose = 1
	local uid = stored.Storage[1].Uid
	local okTake, _, _, taken = write(store, key, function(r)
		return Rules.StorageTake(r, "3", uid, 0)
	end)
	assert(okTake and taken and taken.Count == 4 and taken.DefId == MATERIAL)
	assert(#Rules.Sanitize(memory.Data[key]).Storage == 0, "taken exactly once")

	-- op ids are bounded
	local record = Rules.Sanitize(memory.Data[key])
	for index = 1, Rules.OpsKept + 5 do
		Rules.PushOp(record, "x" .. index, nil)
	end
	assert(#record.Ops == Rules.OpsKept and Rules.FindOp(record, "x1") == nil and Rules.FindOp(record, "x" .. (Rules.OpsKept + 5)))
end)

case("every refusal reason has player text", function()
	for _, reason in {
		"Rank", "LowestRank", "LeaderLeave", "NotInCompany", "NotMember", "AlreadyMember", "Full", "Emblem",
		"Unchanged", "NameLength", "NameChars", "NameTaken", "NameFiltered", "StorageFull", "StorageNotEmpty",
		"Missing", "Invalid", "NotFound", "Busy", "Failed",
	} do
		reasonsSeen[reason] = true
	end
	for reason in reasonsSeen do
		assert(Strings.Company.Errors[reason], `Strings.Company.Errors.{reason} missing`)
	end
	for _, id in CompanyQuests.Ids() do
		local text = Strings.Company.Quests[id]
		assert(text and text.Name and text.Summary, `Strings.Company.Quests.{id} missing`)
	end
	for _, rank in RANKS do
		assert(Strings.Company.Ranks[rank], rank)
	end
end)

print(`test_company: {passed} cases passed`)
