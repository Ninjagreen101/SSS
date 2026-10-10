--!strict
--[[
	QuestService Rules
	Every pure quest decision (docs/PHASE11_QUESTS.md), with no Roblox services, so the Lune
	simulation (tools/place/sim_quests.luau) runs exactly what the server runs.

	Quest state (Types.QuestState)
	  Progress  objective index as a string ("1", "2", ...) -> count so far (capped at its Count)
	  Stage     the first unfinished objective; #Objectives + 1 = ready to hand in. Sequential quests
	            only count events for the objective at Stage; the others count for any of them.

	Counting (Accumulate): most kinds add the event's amount; Resonance keeps the highest stack count
	reached, Combo counts full combos (its amount is the combo's length) and LevelUp keeps the
	highest level.

	Credit: objectives that describe a state the player may already be in (Discover a Waystone or a
	secret they already found, Attune when already attuned, Reach a point they stand in) are
	credited from that state (Facts) when the quest is accepted, on load and whenever its stage
	moves, so nobody is stuck on something they did before. Accepting from an NPC also counts as
	talking to them (a Talk objective for the giver is done at once).

	Book operations (Start, Feed, Refresh, Finish, RollDue, Reroll) work on the profile's Quests
	branch in place; QuestService wraps them with the NPC checks, rewards and replication.

	Dailies and weeklies are rolled per player and per period with an integer hash of (UserId, period
	index, pool), so the same player gets the same quests all day on every server: one per daily pool
	and WeeklyCount distinct weeklies. A reroll picks from the pool minus today's quests, seeded by how
	many rerolls were already used today. Periods start at DailyResetHourUTC (dailies) and on
	WeeklyResetWeekdayUTC at that hour (weeklies).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Quests = require(Shared.Data.Quests)
local QuestConfig = require(Shared.Config.Quests)

type QuestState = Types.QuestState
type QuestDef = Quests.QuestDef
type Objective = Quests.Objective

-- Why an action was refused (Strings.QuestUI.Errors keys).
export type Reason = "NotAvailable" | "LogFull" | "NotReady" | "NoRerolls" | "TooFar" | "BagFull"

-- What an accept is checked against: the player's quest branch (or a copy of it).
export type QuestBook = {
	Active: { [string]: QuestState },
	Completed: { [string]: number },
}

-- The quest branch with its rolled dailies and weeklies (Types.PlayerData.Quests minus Tracked).
export type Periods = {
	Active: { [string]: QuestState },
	Completed: { [string]: number },
	Dailies: { string },
	Weeklies: { string },
	Rerolls: number,
	DailyResetAt: number,
	WeeklyResetAt: number,
}

-- What state-like objectives are credited from (see Credit): built by QuestService from the
-- profile and the player's position, and by hand in the simulation.
export type Facts = {
	Waystones: { [string]: boolean }, -- discovered waystone ids
	Secrets: { [string]: boolean }, -- discovered secret area ids
	Attunements: { string }, -- the player's attunements ("" = none in that slot)
	Inside: { [string]: boolean }, -- quest points the player stands in right now
}

-- One quest an action moved: the objectives whose count changed, and whether it is now ready.
export type Moved = { Id: string, Objectives: { number }, Ready: boolean }

local Rules = {}

local DAY = 86400
local WEEK = 7 * DAY
local TWO32 = 4294967296

-- Daily pools in roll order (one quest from each, Config.Quests.DailyCount of them).
local DAILY_POOLS: { Quests.Pool } = { "Kill", "Gather", "Dungeon" }
local WEEKLY_POOL: Quests.Pool = "Weekly"
Rules.DailyPools = DAILY_POOLS
Rules.WeeklyPool = WEEKLY_POOL

-- Kinds that can be done again every period (and never block an accept by being Completed).
local REPEATABLE: { [string]: boolean } = { Daily = true, Weekly = true }

-- STATE ------------------------------------------------------------------------------------------

function Rules.NewState(def: QuestDef, now: number): QuestState
	local progress: { [string]: number } = {}
	for index in def.Objectives do
		progress[tostring(index)] = 0
	end
	local state: QuestState = { Stage = 1, Progress = progress, StartedAt = now }
	state.Stage = Rules.Stage(def, state)
	return state
end

function Rules.Progress(state: QuestState, index: number): number
	local value = state.Progress[tostring(index)]
	return if type(value) == "number" then value else 0
end

function Rules.IsDone(def: QuestDef, state: QuestState, index: number): boolean
	local objective = def.Objectives[index]
	return objective ~= nil and Rules.Progress(state, index) >= objective.Count
end

-- The first unfinished objective, or #Objectives + 1 when all are done.
function Rules.Stage(def: QuestDef, state: QuestState): number
	for index in def.Objectives do
		if not Rules.IsDone(def, state, index) then
			return index
		end
	end
	return #def.Objectives + 1
end

function Rules.IsReady(def: QuestDef, state: QuestState): boolean
	return Rules.Stage(def, state) > #def.Objectives
end

-- May objective `index` count events right now?
function Rules.Open(def: QuestDef, state: QuestState, index: number): boolean
	if Rules.IsDone(def, state, index) then
		return false
	end
	return not def.Sequential or index == state.Stage
end

-- How an event's amount adds to a count.
function Rules.Accumulate(kind: string, current: number, amount: number): number
	if kind == "Resonance" or kind == "LevelUp" then
		return math.max(current, amount)
	elseif kind == "Combo" then
		return current + 1
	end
	return current + math.max(0, amount)
end

-- Fixes a saved state that doesn't fit the quest any more (content changed, old draft): unknown
-- objective keys are dropped, counts clamped, the stage recomputed. Returns whether it changed.
function Rules.Repair(def: QuestDef, state: QuestState): boolean
	local changed = false
	local fixed: { [string]: number } = {}
	for index, objective in def.Objectives do
		local key = tostring(index)
		local value = state.Progress[key]
		local clean = if type(value) == "number" and value == value then math.clamp(math.floor(value), 0, objective.Count) else 0
		if clean ~= value then
			changed = true
		end
		fixed[key] = clean
	end
	for key in state.Progress do
		if fixed[key] == nil then
			changed = true
		end
	end
	state.Progress = fixed
	local stage = Rules.Stage(def, state)
	if state.Stage ~= stage then
		state.Stage = stage
		changed = true
	end
	if type(state.StartedAt) ~= "number" then
		state.StartedAt = 0
		changed = true
	end
	return changed
end

-- Feeds one GameEvents action to a quest. Mutates `state`; returns the objectives whose count
-- changed (empty when nothing did).
function Rules.Apply(def: QuestDef, state: QuestState, kind: string, key: string, amount: number): { number }
	local changed: { number } = {}
	for index, objective in def.Objectives do
		if Rules.Open(def, state, index) and Quests.Matches(objective, kind, key) then
			local before = Rules.Progress(state, index)
			local after = math.min(objective.Count, Rules.Accumulate(kind, before, amount))
			if after > before then
				state.Progress[tostring(index)] = after
				table.insert(changed, index)
			end
		end
	end
	if #changed > 0 then
		state.Stage = Rules.Stage(def, state)
	end
	return changed
end

-- Credits objectives from what the player already has: `known(index, objective)` returns how much
-- of it is already true (0 for event-only objectives). Sequential quests are credited stage by
-- stage. Mutates `state`; returns the objectives whose count changed.
function Rules.Credit(def: QuestDef, state: QuestState, known: (number, Objective) -> number): { number }
	local changed: { number } = {}
	local guard = #def.Objectives + 1
	repeat
		local moved = false
		for index, objective in def.Objectives do
			if Rules.Open(def, state, index) then
				local before = Rules.Progress(state, index)
				local value = math.min(objective.Count, math.floor(known(index, objective)))
				if value > before then
					state.Progress[tostring(index)] = value
					if not table.find(changed, index) then
						table.insert(changed, index)
					end
					moved = true
				end
			end
		end
		state.Stage = Rules.Stage(def, state)
		guard -= 1
	until not moved or not def.Sequential or guard <= 0
	return changed
end

-- ACCEPTING --------------------------------------------------------------------------------------

function Rules.IsRepeatable(def: QuestDef): boolean
	return REPEATABLE[def.Kind] == true
end

-- Main, side and tutorial quests count toward Config.Quests.MaxActive.
function Rules.CountsTowardLimit(def: QuestDef): boolean
	return not Rules.IsRepeatable(def)
end

function Rules.CanAbandon(def: QuestDef): boolean
	return def.Kind ~= "Main" and def.Kind ~= "Tutorial"
end

function Rules.RequiresMet(def: QuestDef, completed: { [string]: number }): boolean
	local requires = def.Requires
	if requires then
		for _, id in requires do
			if completed[id] == nil then
				return false
			end
		end
	end
	return true
end

-- Main / side / tutorial quests in the log right now (the MaxActive limit).
function Rules.ActiveCount(book: QuestBook): number
	local count = 0
	for id in book.Active do
		local def = Quests.Get(id)
		if def and Rules.CountsTowardLimit(def) then
			count += 1
		end
	end
	return count
end

-- May `id` (a main / side / tutorial quest) start? Dailies and weeklies only come from the roll.
function Rules.CanAccept(id: string, book: QuestBook): (boolean, Reason?)
	local def = Quests.Get(id)
	if not def or Rules.IsRepeatable(def) then
		return false, "NotAvailable"
	end
	if book.Active[id] ~= nil or book.Completed[id] ~= nil then
		return false, "NotAvailable"
	end
	if not Rules.RequiresMet(def, book.Completed) then
		return false, "NotAvailable"
	end
	if Rules.ActiveCount(book) >= QuestConfig.MaxActive then
		return false, "LogFull"
	end
	return true, nil
end

-- The main quest after `id` on its floor (by Order), if any.
function Rules.NextMain(id: string): string?
	local def = Quests.Get(id)
	if not def or def.Kind ~= "Main" or not def.Order then
		return nil
	end
	for _, other in Quests.OfKind("Main", def.Floor) do
		local otherDef = Quests.Get(other)
		if otherDef and otherDef.Order and otherDef.Order > def.Order then
			return other
		end
	end
	return nil
end

-- Who a quest is offered by and handed in to. Quests without a Giver are only given (the tutorial
-- hand-off) or rolled; quests without a TurnIn complete on the spot (npcId "").
function Rules.OfferedBy(def: QuestDef, npcId: string): boolean
	return def.Giver ~= nil and def.Giver == npcId
end

function Rules.TurnInAt(def: QuestDef, npcId: string): boolean
	return (def.TurnIn or "") == npcId
end

-- FACTS ------------------------------------------------------------------------------------------

-- How much of `objective` the facts already satisfy (0 for objectives only events can count).
function Rules.Known(objective: Objective, facts: Facts): number
	local target = objective.Target
	local count = 0
	if objective.Type == "Discover" then
		for id in facts.Waystones do
			if Quests.KeyMatches(target, `Waystone:{id}`) then
				count += 1
			end
		end
		for id in facts.Secrets do
			if Quests.KeyMatches(target, `Secret:{id}`) then
				count += 1
			end
		end
	elseif objective.Type == "Attune" then
		for _, name in facts.Attunements do
			if name ~= "" and Quests.KeyMatches(target, name) then
				count += 1
			end
		end
	elseif objective.Type == "Reach" then
		for id in facts.Inside do
			if Quests.KeyMatches(target, id) then
				count += 1
			end
		end
	end
	return count
end

local function knownFrom(facts: Facts?): (number, Objective) -> number
	return function(_index: number, objective: Objective): number
		return if facts then Rules.Known(objective, facts) else 0
	end
end

-- BOOK -------------------------------------------------------------------------------------------

-- A fresh state for `def`, accepted at `now` from npc `npcId` ("" = none). Accepting from an NPC
-- is talking to them, so a Talk objective for that NPC counts at once; then Credit from `facts`.
function Rules.Start(def: QuestDef, now: number, npcId: string, facts: Facts?): QuestState
	local state = Rules.NewState(def, now)
	if npcId ~= "" then
		Rules.Apply(def, state, "Talk", npcId, 1)
	end
	Rules.Credit(def, state, knownFrom(facts))
	return state
end

-- Credits every active quest from `facts` (on load, after a discovery). Returns what moved.
function Rules.Refresh(book: QuestBook, facts: Facts): { Moved }
	local moved: { Moved } = {}
	for id, state in book.Active do
		local def = Quests.Get(id)
		if def and not Rules.IsReady(def, state) then
			local changed = Rules.Credit(def, state, knownFrom(facts))
			if #changed > 0 then
				table.sort(changed)
				table.insert(moved, { Id = id, Objectives = changed, Ready = Rules.IsReady(def, state) })
			end
		end
	end
	table.sort(moved, function(a: Moved, b: Moved): boolean
		return a.Id < b.Id
	end)
	return moved
end

-- Feeds one GameEvents action to every active quest in `book`; a quest whose stage moved is then
-- credited from `facts` (its next objective may already be true). Mutates the states and returns
-- the quests that moved, sorted by id.
function Rules.Feed(book: QuestBook, kind: string, key: string, amount: number, facts: Facts?): { Moved }
	local moved: { Moved } = {}
	for id, state in book.Active do
		local def = Quests.Get(id)
		if not def or Rules.IsReady(def, state) then
			continue
		end
		local stage = state.Stage
		local changed = Rules.Apply(def, state, kind, key, amount)
		if #changed == 0 then
			continue
		end
		if state.Stage ~= stage and facts then
			for _, index in Rules.Credit(def, state, knownFrom(facts)) do
				if not table.find(changed, index) then
					table.insert(changed, index)
				end
			end
		end
		table.sort(changed)
		table.insert(moved, { Id = id, Objectives = changed, Ready = Rules.IsReady(def, state) })
	end
	table.sort(moved, function(a: Moved, b: Moved): boolean
		return a.Id < b.Id
	end)
	return moved
end

-- Hands `id` in: out of Active, into Completed at `now`. False unless it is active and ready.
function Rules.Finish(book: QuestBook, id: string, now: number): boolean
	local def = Quests.Get(id)
	local state = book.Active[id]
	if not def or not state or not Rules.IsReady(def, state) then
		return false
	end
	book.Active[id] = nil
	book.Completed[id] = now
	return true
end

-- May rolled quest `id` (re)start? It must be one of this period's rolls, not running and not done
-- this period (the Accept button after an abandon; rolls start on their own).
function Rules.CanAcceptRolled(id: string, book: Periods): (boolean, Reason?)
	local def = Quests.Get(id)
	if not def or not Rules.IsRepeatable(def) then
		return false, "NotAvailable"
	end
	local rolled = if def.Kind == "Daily" then book.Dailies else book.Weeklies
	if not table.find(rolled, id) or book.Active[id] ~= nil or book.Completed[id] ~= nil then
		return false, "NotAvailable"
	end
	return true, nil
end

-- PERIODS ----------------------------------------------------------------------------------------

local function dailyOffset(): number
	return QuestConfig.DailyResetHourUTC * 3600
end

-- 1970-01-01 was a Thursday (os.date wday 5): the first weekly reset is this many seconds after it.
local function weeklyOffset(): number
	return ((QuestConfig.WeeklyResetWeekdayUTC - 5) % 7) * DAY + dailyOffset()
end

function Rules.DayIndex(t: number): number
	return math.floor((t - dailyOffset()) / DAY)
end

function Rules.NextDailyReset(t: number): number
	return (Rules.DayIndex(t) + 1) * DAY + dailyOffset()
end

function Rules.WeekIndex(t: number): number
	return math.floor((t - weeklyOffset()) / WEEK)
end

function Rules.NextWeeklyReset(t: number): number
	return (Rules.WeekIndex(t) + 1) * WEEK + weeklyOffset()
end

-- When the period that `resetsAt` closes began (for "completed this period").
function Rules.DailyStart(resetsAt: number): number
	return resetsAt - DAY
end

function Rules.WeeklyStart(resetsAt: number): number
	return resetsAt - WEEK
end

-- ROLLS ------------------------------------------------------------------------------------------

-- (a * b) mod 2^32 without losing precision (doubles hold 53 bits).
local function mul32(a: number, b: number): number
	local aLo, aHi = a % 65536, math.floor(a / 65536)
	local bLo, bHi = b % 65536, math.floor(b / 65536)
	return (aLo * bLo + ((aHi * bLo + aLo * bHi) % 65536) * 65536) % TWO32
end

local function word(value: number): number
	return math.floor(value) % TWO32
end

-- A 32-bit FNV-1a hash of integers with a final avalanche (deterministic on every machine).
function Rules.Hash(values: { number }): number
	local h = 2166136261
	for _, value in values do
		local v = word(value)
		for _ = 1, 4 do
			h = bit32.bxor(h, v % 256)
			h = mul32(h, 16777619)
			v = math.floor(v / 256)
		end
	end
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = mul32(h, 0x85EBCA6B)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = mul32(h, 0xC2B2AE35)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h
end

function Rules.Salt(text: string): number
	local h = 0
	for index = 1, #text do
		h = (h * 31 + string.byte(text, index)) % TWO32
	end
	return h
end

local function seed(userId: number, period: number, salt: string, extra: number): number
	return Rules.Hash({ userId % TWO32, math.floor(userId / TWO32), period, Rules.Salt(salt), extra })
end

-- Today's dailies for one player: one quest from each daily pool (pools with no quests are skipped).
function Rules.RollDailies(userId: number, day: number): { string }
	local out: { string } = {}
	for index, pool in DAILY_POOLS do
		if index > QuestConfig.DailyCount then
			break
		end
		local ids = Quests.InPool(pool :: Quests.Pool)
		if #ids > 0 then
			table.insert(out, ids[seed(userId, day, pool, 0) % #ids + 1])
		end
	end
	return out
end

-- This week's weeklies: WeeklyCount distinct quests from the weekly pool (fewer if it's smaller).
function Rules.RollWeeklies(userId: number, week: number): { string }
	local remaining = table.clone(Quests.InPool(WEEKLY_POOL))
	local out: { string } = {}
	for pick = 1, QuestConfig.WeeklyCount do
		if #remaining == 0 then
			break
		end
		local index = seed(userId, week, WEEKLY_POOL, pick) % #remaining + 1
		table.insert(out, table.remove(remaining, index) :: string)
	end
	return out
end

-- A replacement for daily `old`: another quest from its pool that isn't one of `current`.
-- `used` = rerolls already spent today (so each reroll can land somewhere new). nil if none.
function Rules.RerollPick(userId: number, day: number, old: string, current: { string }, used: number): string?
	local def = Quests.Get(old)
	if not def or def.Kind ~= "Daily" or not def.Pool then
		return nil
	end
	local candidates: { string } = {}
	for _, id in Quests.InPool(def.Pool) do
		if id ~= old and not table.find(current, id) then
			table.insert(candidates, id)
		end
	end
	if #candidates == 0 then
		return nil
	end
	return candidates[seed(userId, day, def.Pool, 1000 + used) % #candidates + 1]
end

-- Drops every quest of one repeatable kind from Active and Completed (its period is over).
local function clearKind(book: Periods, kind: Quests.QuestKind)
	for id in book.Active do
		local def = Quests.Get(id)
		if def and def.Kind == kind then
			book.Active[id] = nil
		end
	end
	for id in book.Completed do
		local def = Quests.Get(id)
		if def and def.Kind == kind then
			book.Completed[id] = nil
		end
	end
end

local function startRolled(book: Periods, ids: { string }, now: number, facts: Facts?)
	for _, id in ids do
		local def = Quests.Get(id)
		if def then
			book.Active[id] = Rules.Start(def, now, "", facts)
		end
	end
end

-- Rolls new dailies and weeklies once their period is over: last period's leave Active (finished
-- or not) and Completed, and the new ones start at once. Returns (dailies rolled, weeklies rolled).
function Rules.RollDue(book: Periods, userId: number, now: number, facts: Facts?): (boolean, boolean)
	local daily, weekly = false, false
	if now >= book.DailyResetAt then
		clearKind(book, "Daily")
		book.Dailies = Rules.RollDailies(userId, Rules.DayIndex(now))
		book.Rerolls = 0
		book.DailyResetAt = Rules.NextDailyReset(now)
		startRolled(book, book.Dailies, now, facts)
		daily = true
	end
	if now >= book.WeeklyResetAt then
		clearKind(book, "Weekly")
		book.Weeklies = Rules.RollWeeklies(userId, Rules.WeekIndex(now))
		book.WeeklyResetAt = Rules.NextWeeklyReset(now)
		startRolled(book, book.Weeklies, now, facts)
		weekly = true
	end
	return daily, weekly
end

-- Swaps today's daily `old` (not finished) for another from its pool, started fresh. Returns the
-- new id, or nil and why not.
function Rules.Reroll(book: Periods, userId: number, now: number, old: string, facts: Facts?): (string?, Reason?)
	local index = table.find(book.Dailies, old)
	if not index or book.Completed[old] ~= nil then
		return nil, "NotAvailable"
	end
	if book.Rerolls >= QuestConfig.DailyRerolls then
		return nil, "NoRerolls"
	end
	local pick = Rules.RerollPick(userId, Rules.DayIndex(now), old, book.Dailies, book.Rerolls)
	local def = if pick then Quests.Get(pick) else nil
	if not pick or not def then
		return nil, "NotAvailable"
	end
	book.Dailies[index] = pick
	book.Rerolls += 1
	book.Active[old] = nil
	book.Active[pick] = Rules.Start(def, now, "", facts)
	return pick, nil
end

-- REWARDS ----------------------------------------------------------------------------------------

export type RewardTotals = { XP: number, Gold: number, Shards: number, Items: number }

function Rules.RewardTotals(def: QuestDef): RewardTotals
	local items = 0
	local list = def.Rewards.Items
	if list then
		for _, item in list do
			items += item.Count
		end
	end
	return { XP = def.Rewards.XP, Gold = def.Rewards.Gold, Shards = def.Rewards.Shards or 0, Items = items }
end

return Rules
