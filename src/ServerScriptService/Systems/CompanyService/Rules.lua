--!strict
--[[
	CompanyService.Rules
	Every Climber Company rule as a pure function (Phase 12): ranks and what each may do, name
	rules, the saved record and every change to it, storage add / take, the weekly quest roll,
	quest progress and reward claims, and the state payload clients render.

	No yields and no Instances. CompanyService runs the record mutators inside DataStore
	UpdateAsync transforms, which may run more than once on fresh copies, so a mutator only reads
	the record it is given and either changes it and returns true, or returns false with a reason
	(Strings.Company.Errors key) having changed nothing. tools/place/test_company.luau runs them
	offline.

	The record (DataStore Config.Social.Company.DataStore, key "c_<id>"):
	  Version     bumped by every committed write (servers skip stale "changed" messages)
	  Id, Name, Emblem (1..Config Emblems), CreatedAt (unix)
	  Disbanded   a disbanded record is kept as a tombstone with no members
	  NextUid     storage stack ids are "s<n>"
	  Members     [userId string] = { Rank, JoinedAt, Name, Claims = { "<week>:<questId>" } }
	  Storage     dense array of item instances (Uid = storage stack id), at most StorageSlots
	  Quests      { Week, List = { { Id, Progress, DoneAt } }, Last = the previous week's block }
	  Ops         the last OPS_KEPT committed writes { Id, Out }: a retried UpdateAsync whose earlier
	              attempt had in fact committed finds its op id here and reuses its result instead
	              of applying the change twice
	The name index (key "n_<lowercase name>") = { Id, At }: Id "" once released.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Types = require(Shared.Types)
local Items = require(Shared.Data.Items)
local CompanyQuests = require(Shared.Data.CompanyQuests)
local QuestRules = require(script.Parent.Parent.QuestService.Rules)

type ItemInstance = Types.ItemInstance

local Company = Config.Social.Company

export type Reason = string

export type Member = {
	Rank: string,
	JoinedAt: number,
	Name: string,
	Claims: { string }, -- "<week>:<questId>" rewards already paid (this and last week only)
}

export type QuestEntry = {
	Id: string,
	Progress: number,
	DoneAt: number, -- unix time it completed (0 = not yet)
}

export type QuestWeek = {
	Week: number, -- QuestService week index (-1 = none)
	List: { QuestEntry },
}

export type QuestBlock = {
	Week: number,
	List: { QuestEntry },
	Last: QuestWeek, -- the week before, so members who were away can still claim it
}

-- One committed write: its op id and what it handed back (the stacks a deposit filled, the item a
-- withdraw took, the rewards a claim marked).
export type OpEntry = { Id: string, Out: any }

export type Record = {
	Version: number,
	Id: string,
	Name: string,
	Emblem: number,
	CreatedAt: number,
	Disbanded: boolean,
	NextUid: number,
	Members: { [string]: Member },
	Storage: { ItemInstance },
	Quests: QuestBlock,
	Ops: { OpEntry },
}

export type NameClaim = {
	Id: string, -- record id holding the name ("" = free)
	At: number, -- unix time it was claimed
}

-- One storage stack a deposit touched, and how many it added there.
export type Placed = { Uid: string, Count: number }

-- One weekly quest reward a member is owed.
export type Reward = { Key: string, Id: string, Gold: number, Shards: number }

local Rules = {}

local RANKS: { string } = table.clone(Company.Ranks)
local ID_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"
local ID_LENGTH = 10

-- A name claim whose record never appeared (the server stopped mid-create) is free after this.
Rules.StaleClaimSeconds = 600
-- Committed op ids kept per record (a retry happens within seconds of its first attempt).
Rules.OpsKept = 16

-- The lowest rank allowed each action. Kick, Promote and Demote also need the target strictly
-- below the actor (see CanKick / PromoteTo / DemoteTo).
local MIN_RANK: { [string]: string } = {
	Invite = "Officer",
	Kick = "Officer",
	Promote = "Officer",
	Demote = "Officer",
	SetEmblem = "Officer",
	Disband = "Leader",
	Deposit = "Recruit",
	Withdraw = "Member",
}
Rules.Actions = table.freeze({ "Invite", "Kick", "Promote", "Demote", "SetEmblem", "Disband", "Deposit", "Withdraw" })

-- KEYS AND IDS -------------------------------------------------------------------------------------

function Rules.RecordKey(id: string): string
	return "c_" .. id
end

function Rules.NameKey(name: string): string
	return "n_" .. string.lower(name)
end

-- A short random id (record key "c_<id>").
function Rules.NewId(random: Random): string
	local out = table.create(ID_LENGTH)
	for index = 1, ID_LENGTH do
		local pick = random:NextInteger(1, #ID_ALPHABET)
		out[index] = string.sub(ID_ALPHABET, pick, pick)
	end
	return table.concat(out)
end

-- Ids the server accepts from a client (Accept / Decline): exactly what NewId makes.
function Rules.IsId(value: string): boolean
	return #value == ID_LENGTH and string.match(value, "^[a-z0-9]+$") ~= nil
end

-- RANKS --------------------------------------------------------------------------------------------

-- 1 = Leader ... #Ranks = Recruit; anything unknown ranks below every real rank.
function Rules.RankIndex(rank: string): number
	return table.find(RANKS, rank) or (#RANKS + 1)
end

function Rules.Can(rank: string, action: string): boolean
	local minimum = MIN_RANK[action]
	if minimum == nil or Rules.RankIndex(rank) > #RANKS then
		return false
	end
	return Rules.RankIndex(rank) <= Rules.RankIndex(minimum)
end

function Rules.CanKick(actor: string, target: string): (boolean, Reason?)
	if not Rules.Can(actor, "Kick") then
		return false, "Rank"
	end
	if Rules.RankIndex(target) <= Rules.RankIndex(actor) then
		return false, "Rank"
	end
	return true, nil
end

-- The rank a promotion by `actor` moves `target` to. An Officer can only make Recruits Members;
-- the Leader promoting an Officer hands over leadership (the caller demotes the Leader to Officer).
function Rules.PromoteTo(actor: string, target: string): (string?, Reason?)
	if not Rules.Can(actor, "Promote") then
		return nil, "Rank"
	end
	local a, t = Rules.RankIndex(actor), Rules.RankIndex(target)
	if t > #RANKS or t <= a then
		return nil, "Rank"
	end
	local new = t - 1
	if new == a and actor ~= RANKS[1] then
		return nil, "Rank"
	end
	return RANKS[new], nil
end

function Rules.DemoteTo(actor: string, target: string): (string?, Reason?)
	if not Rules.Can(actor, "Demote") then
		return nil, "Rank"
	end
	local a, t = Rules.RankIndex(actor), Rules.RankIndex(target)
	if t > #RANKS or t <= a then
		return nil, "Rank"
	end
	if t == #RANKS then
		return nil, "LowestRank"
	end
	return RANKS[t + 1], nil
end

-- What `rank` may do, for the client's buttons (the server re-checks every action).
function Rules.Permissions(rank: string): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, action in Rules.Actions do
		out[action] = Rules.Can(rank, action)
	end
	return out
end

-- NAMES AND EMBLEMS --------------------------------------------------------------------------------

-- Trims and collapses spaces, then checks length and characters (letters, digits, spaces, single
-- apostrophes and hyphens, at least one letter). Returns the clean name or a reason.
function Rules.CleanName(raw: string): (string?, Reason?)
	if type(raw) ~= "string" then
		return nil, "NameChars"
	end
	local text = string.gsub(raw, "%s+", " ")
	text = string.match(text, "^%s*(.-)%s*$") or ""
	if #text < Company.NameMin or #text > Company.NameMax then
		return nil, "NameLength"
	end
	if string.match(text, "^[%w' %-]+$") == nil or string.find(text, "%a") == nil then
		return nil, "NameChars"
	end
	if string.find(text, "''", 1, true) or string.find(text, "--", 1, true) then
		return nil, "NameChars"
	end
	return text, nil
end

function Rules.ValidEmblem(value: any): boolean
	return type(value) == "number" and value % 1 == 0 and value >= 1 and value <= Company.Emblems
end

-- Can a create take the name index entry `claim` (nil = never claimed)? `holder` is the record the
-- claim points at (nil if it doesn't exist), read just before.
function Rules.ClaimIsFree(claim: NameClaim?, holder: Record?, now: number): boolean
	if claim == nil or claim.Id == "" then
		return true
	end
	if holder then
		return holder.Disbanded
	end
	return now - claim.At > Rules.StaleClaimSeconds
end

-- RECORDS ------------------------------------------------------------------------------------------

local function isCount(value: any, maximum: number): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and value >= 1 and value <= maximum
end

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, inner in value :: any do
		out[key] = deepCopy(inner)
	end
	return out :: any
end

local function number(value: any, default: number): number
	return if type(value) == "number" and value == value then value else default
end

local function str(value: any, default: string): string
	return if type(value) == "string" then value else default
end

local function sanitizeWeek(value: any): QuestWeek
	local week: QuestWeek = { Week = -1, List = {} }
	if type(value) ~= "table" then
		return week
	end
	week.Week = number(value.Week, -1)
	if type(value.List) == "table" then
		for _, entry in value.List do
			if type(entry) == "table" and type(entry.Id) == "string" then
				table.insert(week.List, { Id = entry.Id, Progress = number(entry.Progress, 0), DoneAt = number(entry.DoneAt, 0) })
			end
		end
	end
	return week
end

-- A record read from the DataStore, with every field checked and defaulted; nil if it isn't a
-- record at all. Lenient on purpose: a missing field must never cost a Company its members.
function Rules.Sanitize(value: any): Record?
	if type(value) ~= "table" or type(value.Id) ~= "string" or value.Id == "" then
		return nil
	end
	local members: { [string]: Member } = {}
	if type(value.Members) == "table" then
		for userId, member in value.Members do
			if type(userId) == "string" and type(member) == "table" then
				local claims: { string } = {}
				if type(member.Claims) == "table" then
					for _, key in member.Claims do
						if type(key) == "string" then
							table.insert(claims, key)
						end
					end
				end
				members[userId] = {
					Rank = if table.find(RANKS, member.Rank) then member.Rank else RANKS[#RANKS],
					JoinedAt = number(member.JoinedAt, 0),
					Name = str(member.Name, userId),
					Claims = claims,
				}
			end
		end
	end
	local storage: { ItemInstance } = {}
	if type(value.Storage) == "table" then
		for _, item in value.Storage do
			if type(item) == "table" and type(item.Uid) == "string" and type(item.DefId) == "string" and isCount(item.Count, 1e6) then
				table.insert(storage, item)
			end
		end
	end
	local ops: { OpEntry } = {}
	if type(value.Ops) == "table" then
		for _, op in value.Ops do
			if type(op) == "table" and type(op.Id) == "string" then
				table.insert(ops, { Id = op.Id, Out = deepCopy(op.Out) })
			end
		end
	end
	local quests = sanitizeWeek(value.Quests)
	return {
		Version = number(value.Version, 0),
		Id = value.Id,
		Name = str(value.Name, value.Id),
		Emblem = if Rules.ValidEmblem(value.Emblem) then value.Emblem else 1,
		CreatedAt = number(value.CreatedAt, 0),
		Disbanded = value.Disbanded == true,
		NextUid = math.max(1, number(value.NextUid, 1)),
		Members = members,
		Storage = storage,
		Quests = {
			Week = quests.Week,
			List = quests.List,
			Last = sanitizeWeek(if type(value.Quests) == "table" then value.Quests.Last else nil),
		},
		Ops = ops,
	}
end

function Rules.NewRecord(id: string, name: string, emblem: number, leaderId: string, leaderName: string, now: number): Record
	local record: Record = {
		Version = 1,
		Id = id,
		Name = name,
		Emblem = emblem,
		CreatedAt = now,
		Disbanded = false,
		NextUid = 1,
		Members = {
			[leaderId] = { Rank = RANKS[1], JoinedAt = now, Name = leaderName, Claims = {} },
		},
		Storage = {},
		Quests = { Week = -1, List = {}, Last = { Week = -1, List = {} } },
		Ops = {},
	}
	Rules.Normalize(record, Rules.WeekOf(now))
	return record
end

function Rules.MemberCount(record: Record): number
	local count = 0
	for _ in record.Members do
		count += 1
	end
	return count
end

-- The member `userId` of a live record, or nil.
function Rules.MemberOf(record: Record, userId: string): Member?
	if record.Disbanded then
		return nil
	end
	return record.Members[userId]
end

-- The committed write `opId`, if it is still remembered.
function Rules.FindOp(record: Record, opId: string): OpEntry?
	for _, op in record.Ops do
		if op.Id == opId then
			return op
		end
	end
	return nil
end

-- Remembers a committed write (oldest forgotten past OpsKept).
function Rules.PushOp(record: Record, opId: string, out: any)
	table.insert(record.Ops, { Id = opId, Out = deepCopy(out) })
	while #record.Ops > Rules.OpsKept do
		table.remove(record.Ops, 1)
	end
end

-- MEMBERSHIP ---------------------------------------------------------------------------------------

-- A new member joins as the lowest rank.
function Rules.AddMember(record: Record, userId: string, name: string, now: number): (boolean, Reason?)
	if record.Disbanded then
		return false, "NotFound"
	end
	if record.Members[userId] then
		return false, "AlreadyMember"
	end
	if Rules.MemberCount(record) >= Company.MaxMembers then
		return false, "Full"
	end
	record.Members[userId] = { Rank = RANKS[#RANKS], JoinedAt = now, Name = name, Claims = {} }
	return true, nil
end

-- The Leader can't leave: they promote someone (handing over leadership) or disband.
function Rules.Leave(record: Record, userId: string): (boolean, Reason?)
	local member = Rules.MemberOf(record, userId)
	if not member then
		return false, "NotInCompany"
	end
	if member.Rank == RANKS[1] then
		return false, "LeaderLeave"
	end
	record.Members[userId] = nil
	return true, nil
end

function Rules.Kick(record: Record, actorId: string, targetId: string): (boolean, Reason?)
	local actor = Rules.MemberOf(record, actorId)
	if not actor then
		return false, "NotInCompany"
	end
	local target = Rules.MemberOf(record, targetId)
	if not target or targetId == actorId then
		return false, "NotMember"
	end
	local ok, reason = Rules.CanKick(actor.Rank, target.Rank)
	if not ok then
		return false, reason
	end
	record.Members[targetId] = nil
	return true, nil
end

-- Returns ok, reason, the target's new rank.
function Rules.Promote(record: Record, actorId: string, targetId: string): (boolean, Reason?, string?)
	local actor = Rules.MemberOf(record, actorId)
	if not actor then
		return false, "NotInCompany", nil
	end
	local target = Rules.MemberOf(record, targetId)
	if not target or targetId == actorId then
		return false, "NotMember", nil
	end
	local new, reason = Rules.PromoteTo(actor.Rank, target.Rank)
	if not new then
		return false, reason, nil
	end
	if new == RANKS[1] then
		actor.Rank = RANKS[2] -- leadership handed over
	end
	target.Rank = new
	return true, nil, new
end

function Rules.Demote(record: Record, actorId: string, targetId: string): (boolean, Reason?, string?)
	local actor = Rules.MemberOf(record, actorId)
	if not actor then
		return false, "NotInCompany", nil
	end
	local target = Rules.MemberOf(record, targetId)
	if not target or targetId == actorId then
		return false, "NotMember", nil
	end
	local new, reason = Rules.DemoteTo(actor.Rank, target.Rank)
	if not new then
		return false, reason, nil
	end
	target.Rank = new
	return true, nil, new
end

function Rules.SetEmblem(record: Record, actorId: string, emblem: number): (boolean, Reason?)
	local actor = Rules.MemberOf(record, actorId)
	if not actor then
		return false, "NotInCompany"
	end
	if not Rules.Can(actor.Rank, "SetEmblem") then
		return false, "Rank"
	end
	if not Rules.ValidEmblem(emblem) then
		return false, "Emblem"
	end
	if record.Emblem == emblem then
		return false, "Unchanged"
	end
	record.Emblem = emblem
	return true, nil
end

-- Only the Leader, and only with an empty chest (nothing in it can be lost).
function Rules.Disband(record: Record, actorId: string): (boolean, Reason?)
	local actor = Rules.MemberOf(record, actorId)
	if not actor then
		return false, "NotInCompany"
	end
	if not Rules.Can(actor.Rank, "Disband") then
		return false, "Rank"
	end
	if #record.Storage > 0 then
		return false, "StorageNotEmpty"
	end
	record.Disbanded = true
	record.Members = {}
	return true, nil
end

-- Keeps a member's shown name current. Returns whether it changed.
function Rules.Rename(record: Record, userId: string, name: string): boolean
	local member = Rules.MemberOf(record, userId)
	if not member or member.Name == name then
		return false
	end
	member.Name = name
	return true
end

-- STORAGE ------------------------------------------------------------------------------------------

local function stacksWith(a: ItemInstance, b: ItemInstance): boolean
	return a.DefId == b.DefId
		and a.Rarity == b.Rarity
		and (a.Upgrade or 0) == (b.Upgrade or 0)
		and #(a.Affixes or {}) == 0
		and #(b.Affixes or {}) == 0
		and a.Unique == b.Unique
end

-- Adds `count` of `item` to the chest: tops up matching stacks first, then opens slots. Checks
-- the room first, so a refusal changes nothing. `actorId` nil = the server returning an item
-- (no rank check, a disbanded record still takes it and the slot cap is ignored: nothing may be
-- lost). Returns ok, reason, the stacks it touched.
function Rules.StorageAdd(record: Record, actorId: string?, item: ItemInstance, count: number): (boolean, Reason?, { Placed }?)
	local returning = actorId == nil
	if actorId then
		local actor = Rules.MemberOf(record, actorId)
		if not actor then
			return false, "NotInCompany", nil
		end
		if not Rules.Can(actor.Rank, "Deposit") then
			return false, "Rank", nil
		end
	end
	local def = Items.Get(item.DefId)
	if not def or not isCount(count, 1e6) then
		return false, "Invalid", nil
	end
	local stackSize = math.max(1, def.StackSize)

	-- Plan first: how much tops up existing stacks, how many new slots the rest needs.
	local plan: { { Index: number, Count: number } } = {}
	local remaining = count
	if stackSize > 1 then
		for index, existing in record.Storage do
			if remaining == 0 then
				break
			end
			if stacksWith(existing, item) and existing.Count < stackSize then
				local moved = math.min(remaining, stackSize - existing.Count)
				table.insert(plan, { Index = index, Count = moved })
				remaining -= moved
			end
		end
	end
	local newSlots = math.ceil(remaining / stackSize)
	if not returning and #record.Storage + newSlots > Company.StorageSlots then
		return false, "StorageFull", nil
	end

	local placed: { Placed } = {}
	for _, step in plan do
		local existing = record.Storage[step.Index]
		existing.Count += step.Count
		table.insert(placed, { Uid = existing.Uid, Count = step.Count })
	end
	while remaining > 0 do
		local entry = deepCopy(item)
		entry.Uid = "s" .. tostring(record.NextUid)
		record.NextUid += 1
		entry.Count = math.min(remaining, stackSize)
		entry.New = false
		entry.Locked = false
		table.insert(record.Storage, entry)
		table.insert(placed, { Uid = entry.Uid, Count = entry.Count })
		remaining -= entry.Count
	end
	return true, nil, placed
end

local function storageIndex(record: Record, uid: string): number?
	for index, entry in record.Storage do
		if entry.Uid == uid then
			return index
		end
	end
	return nil
end

-- Takes `count` (0 = the whole stack) from stack `uid`. `actorId` nil = the server (no rank
-- check). Returns ok, reason, a copy of what was taken (Count = how many).
function Rules.StorageTake(record: Record, actorId: string?, uid: string, count: number): (boolean, Reason?, ItemInstance?)
	if actorId then
		local actor = Rules.MemberOf(record, actorId)
		if not actor then
			return false, "NotInCompany", nil
		end
		if not Rules.Can(actor.Rank, "Withdraw") then
			return false, "Rank", nil
		end
	end
	local index = storageIndex(record, uid)
	if not index then
		return false, "Missing", nil
	end
	local entry = record.Storage[index]
	local take = if count == 0 then entry.Count else count
	if not isCount(take, entry.Count) then
		return false, "Invalid", nil
	end
	local out = deepCopy(entry)
	out.Count = take
	entry.Count -= take
	if entry.Count <= 0 then
		table.remove(record.Storage, index)
	end
	return true, nil, out
end

-- Undoes a deposit: takes back exactly what StorageAdd placed. All or nothing.
function Rules.StorageRemovePlaced(record: Record, placed: { Placed }): (boolean, Reason?)
	local need: { [string]: number } = {}
	for _, step in placed do
		need[step.Uid] = (need[step.Uid] or 0) + step.Count
	end
	for uid, amount in need do
		local index = storageIndex(record, uid)
		if not index or record.Storage[index].Count < amount then
			return false, "Missing"
		end
	end
	for uid, amount in need do
		local index = storageIndex(record, uid) :: number
		local entry = record.Storage[index]
		entry.Count -= amount
		if entry.Count <= 0 then
			table.remove(record.Storage, index)
		end
	end
	return true, nil
end

-- Total count of `defId` in the chest (tests and logs).
function Rules.StorageCount(record: Record, defId: string): number
	local total = 0
	for _, entry in record.Storage do
		if entry.DefId == defId then
			total += entry.Count
		end
	end
	return total
end

-- WEEKLY QUESTS ------------------------------------------------------------------------------------

-- Weeks start Monday 00:00 UTC, the same clock as personal weeklies (QuestService).
function Rules.WeekOf(now: number): number
	return QuestRules.WeekIndex(now)
end

function Rules.WeekEndsAt(now: number): number
	return QuestRules.NextWeeklyReset(now)
end

-- This week's quests for one Company: WeeklyQuests distinct ids, the same on every server.
function Rules.RollQuests(companyId: string, week: number): { string }
	local remaining = CompanyQuests.Ids()
	local out: { string } = {}
	local salt = QuestRules.Salt(companyId)
	for pick = 1, Company.WeeklyQuests do
		if #remaining == 0 then
			break
		end
		local index = QuestRules.Hash({ salt, week, pick }) % #remaining + 1
		table.insert(out, table.remove(remaining, index) :: string)
	end
	return out
end

local function claimWeek(key: string): number
	return tonumber(string.match(key, "^(%-?%d+):")) or -1
end

-- Rolls the record forward to `week` (never back: a server whose clock lags must not undo a
-- newer roll). The finished week is kept as Last if it was the one just before. Returns whether
-- anything changed.
function Rules.Normalize(record: Record, week: number): boolean
	local quests = record.Quests
	if quests.Week >= week then
		return false
	end
	if quests.Week == week - 1 then
		quests.Last = { Week = quests.Week, List = quests.List }
	else
		quests.Last = { Week = -1, List = {} }
	end
	local list: { QuestEntry } = {}
	for _, id in Rules.RollQuests(record.Id, week) do
		table.insert(list, { Id = id, Progress = 0, DoneAt = 0 })
	end
	quests.Week = week
	quests.List = list
	for _, member in record.Members do
		for index = #member.Claims, 1, -1 do
			if claimWeek(member.Claims[index]) < week - 1 then
				table.remove(member.Claims, index)
			end
		end
	end
	return true
end

-- The week's quest entries as seen at `week` (the stored list if current, else a fresh roll).
function Rules.QuestsFor(record: Record, week: number): { QuestEntry }
	if record.Quests.Week == week then
		return record.Quests.List
	end
	local list: { QuestEntry } = {}
	for _, id in Rules.RollQuests(record.Id, week) do
		table.insert(list, { Id = id, Progress = 0, DoneAt = 0 })
	end
	return list
end

-- Unfinished quest ids that events should feed this week.
function Rules.OpenQuests(record: Record?, companyId: string, week: number): { string }
	local out: { string } = {}
	if record and record.Quests.Week == week then
		for _, entry in record.Quests.List do
			if entry.DoneAt == 0 then
				table.insert(out, entry.Id)
			end
		end
		return out
	end
	return Rules.RollQuests(companyId, week)
end

-- Adds batched progress (quest id -> amount) gathered during `week`; progress from a week that
-- has already rolled over is dropped. Returns whether anything changed and the newly done ids.
function Rules.AddProgress(record: Record, week: number, deltas: { [string]: number }, now: number): (boolean, { string })
	local done: { string } = {}
	if record.Disbanded or record.Quests.Week ~= week then
		return false, done
	end
	local changed = false
	for _, entry in record.Quests.List do
		local amount = deltas[entry.Id]
		local def = CompanyQuests.Get(entry.Id)
		if def and entry.DoneAt == 0 and type(amount) == "number" and amount >= 1 then
			local before = entry.Progress
			entry.Progress = math.min(def.Objective.Count, before + math.floor(amount))
			if entry.Progress ~= before then
				changed = true
			end
			if entry.Progress >= def.Objective.Count then
				entry.DoneAt = now
				changed = true
				table.insert(done, entry.Id)
			end
		end
	end
	return changed, done
end

-- REWARDS ------------------------------------------------------------------------------------------

function Rules.ClaimKey(week: number, questId: string): string
	return `{week}:{questId}`
end

-- Rewards `userId` is owed: quests done this week or last week while they were a member, not yet
-- paid to them.
function Rules.Claimable(record: Record, userId: string): { Reward }
	local out: { Reward } = {}
	local member = Rules.MemberOf(record, userId)
	if not member then
		return out
	end
	local function scan(week: number, list: { QuestEntry })
		if week < 0 then
			return
		end
		for _, entry in list do
			local def = CompanyQuests.Get(entry.Id)
			if def and entry.DoneAt > 0 and member.JoinedAt <= entry.DoneAt then
				local key = Rules.ClaimKey(week, entry.Id)
				if not table.find(member.Claims, key) then
					table.insert(out, { Key = key, Id = entry.Id, Gold = def.Rewards.Gold, Shards = def.Rewards.Shards })
				end
			end
		end
	end
	scan(record.Quests.Week, record.Quests.List)
	scan(record.Quests.Last.Week, record.Quests.Last.List)
	return out
end

-- Marks every reward the listed members are owed as paid. Returns userId -> rewards marked.
function Rules.MarkClaims(record: Record, userIds: { string }): { [string]: { Reward } }
	local out: { [string]: { Reward } } = {}
	for _, userId in userIds do
		local rewards = Rules.Claimable(record, userId)
		local member = Rules.MemberOf(record, userId)
		if member and #rewards > 0 then
			for _, reward in rewards do
				table.insert(member.Claims, reward.Key)
			end
			out[userId] = rewards
		end
	end
	return out
end

-- Takes claim marks back (the member left before they could be paid). Returns whether any went.
function Rules.UnmarkClaims(record: Record, userId: string, keys: { string }): boolean
	local member = record.Members[userId]
	if not member then
		return false
	end
	local changed = false
	for _, key in keys do
		local index = table.find(member.Claims, key)
		if index then
			table.remove(member.Claims, index)
			changed = true
		end
	end
	return changed
end

-- CLIENT STATE -------------------------------------------------------------------------------------

-- What CompanyState sends `viewerId`: everything the Company tab draws. `online` = userIds known
-- to be in game (this server and others' presence).
function Rules.State(record: Record, viewerId: string, online: { [string]: boolean }, now: number): { [string]: any }
	local me = record.Members[viewerId]
	local rank = if me then me.Rank else ""
	local members: { { [string]: any } } = {}
	for userId, member in record.Members do
		table.insert(members, {
			UserId = tonumber(userId) or 0,
			Name = member.Name,
			Rank = member.Rank,
			JoinedAt = member.JoinedAt,
			Online = online[userId] == true,
		})
	end
	table.sort(members, function(a: { [string]: any }, b: { [string]: any }): boolean
		local ra, rb = Rules.RankIndex(a.Rank), Rules.RankIndex(b.Rank)
		if ra ~= rb then
			return ra < rb
		end
		if a.Online ~= b.Online then
			return a.Online
		end
		return string.lower(a.Name) < string.lower(b.Name)
	end)
	local week = Rules.WeekOf(now)
	local quests: { { [string]: any } } = {}
	for _, entry in Rules.QuestsFor(record, week) do
		local def = CompanyQuests.Get(entry.Id)
		if def then
			table.insert(quests, {
				Id = entry.Id,
				Progress = entry.Progress,
				Count = def.Objective.Count,
				Done = entry.DoneAt > 0,
				Gold = def.Rewards.Gold,
				Shards = def.Rewards.Shards,
			})
		end
	end
	return {
		Id = record.Id,
		Name = record.Name,
		Emblem = record.Emblem,
		CreatedAt = record.CreatedAt,
		MyRank = rank,
		Permissions = Rules.Permissions(rank),
		Members = members,
		MaxMembers = Company.MaxMembers,
		Storage = deepCopy(record.Storage),
		StorageSlots = Company.StorageSlots,
		Quests = quests,
		ResetsAt = Rules.WeekEndsAt(now),
	}
end

return table.freeze(Rules)
