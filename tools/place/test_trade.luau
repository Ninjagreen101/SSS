--!nocheck
-- Offline test of the trade state machine and swap (Systems/TradeRules.lua) with the real
-- Shared.Data (Items, InventoryRules) and Config loaded from src/, on profiles built from
-- DataService.Template. Covers (docs/PHASE12_MULTIPLAYER.md section 4):
--   - start checks: combat, dead, busy, trading, trade-locked, town, range, cooldown
--   - offers: ownership, equipped, item-locked, untradeable, counts, slot cap, gold bounds
--     (negative, fractional, NaN, overflow, more than owned)
--   - any change unlocks BOTH sides and bumps the changer's revision; a locked side can't edit
--   - countdown: starts when both lock, Confirm refused until it ends, any unlock / change resets
--   - races: double lock / double confirm, a change racing a confirm, both cancelling, a late
--     confirm after close, replaying a finished swap
--   - final re-validation: item gone, gold spent, item equipped / locked / changed mid-trade,
--     bag full (and freed by outgoing items), gold cap; nothing live changes on failure
--   - a full swap conserves every item and all gold, gives fresh uids, handles the same uid
--     string on both sides, partial stacks
--   - Commit rolls every branch back when a fault is injected part-way
-- Every check is an assert; the run prints a summary.
--
--   lune run tools/place/test_trade.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

-- A minimal module runtime (as in sim_quests.luau): src/ folders become instance-like tables.
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
local Inv = requireNode(Shared.Data.InventoryRules)
local Strings = requireNode(Shared.Strings)
local TableUtil = requireNode(Shared.Util.TableUtil)
local Template = requireNode(Systems.DataService.Template)
local Rules = requireNode(Systems.TradeRules)

local T = Config.Social.Trade
local LIMITS = { MaxItems = T.MaxItems, MaxGold = Config.Economy.MaxGold, CountdownSeconds = T.CountdownSeconds }
local random = FakeRandom.new(11)

-- FIXTURES ---------------------------------------------------------------------------------

local ids = {}
for id in Items.Definitions do
	table.insert(ids, id)
end
table.sort(ids)
local GEAR, MATERIAL, UNTRADEABLE
for _, id in ids do
	local def = Items.Definitions[id]
	if not GEAR and def.Type == "Weapon" and def.Tradeable and def.StackSize == 1 and Items.AffixGroup(def) then
		GEAR = id
	elseif not MATERIAL and def.Type == "Material" and def.Tradeable and def.StackSize >= 10 then
		MATERIAL = id
	elseif not UNTRADEABLE and not def.Tradeable then
		UNTRADEABLE = id
	end
end
assert(GEAR and MATERIAL and UNTRADEABLE, "fixture items not found")

local function newPlayer(gold: number)
	local data = TableUtil.DeepCopy(Template)
	data.Inventory.Items = {}
	data.Currencies.Gold = gold
	for slot in data.Equipped do
		data.Equipped[slot] = ""
	end
	return data
end

-- Adds a fresh item; returns its uid.
local function give(data, defId: string, count: number, rarity: string?): string
	local before = {}
	for uid in data.Inventory.Items do
		before[uid] = true
	end
	assert(Inv.Grant(data, defId, count, random, rarity))
	for uid in data.Inventory.Items do
		if not before[uid] then
			return uid
		end
	end
	error("grant made no new stack")
end

local function slotOf(data, uid)
	return assert(Items.SlotsFor(Items.Get(data.Inventory.Items[uid].DefId))[1], "no slot")
end

-- Item count per "DefId|Rarity|Upgrade|affixes" plus gold, over both profiles.
local function census(list)
	local totals, gold = {}, 0
	for _, data in list do
		gold += data.Currencies.Gold
		for _, item in data.Inventory.Items do
			local parts = { item.DefId, item.Rarity, tostring(item.Upgrade), tostring(item.Durability), tostring(item.Unique) }
			for _, affix in item.Affixes do
				table.insert(parts, `{affix.Id}={affix.Value}`)
			end
			local key = table.concat(parts, "|")
			totals[key] = (totals[key] or 0) + item.Count
		end
	end
	return totals, gold
end

local function sameTable(a, b): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not sameTable(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function ok(...)
	local success, reason = ...
	assert(success, "expected success, got " .. tostring(reason))
	return ...
end

local function fails(expected: string, success, reason)
	assert(not success, `expected failure {expected}, got success`)
	assert(reason == expected, `expected {expected}, got {tostring(reason)}`)
	assert(Strings.Trade.Errors[reason] ~= nil, `no Strings.Trade.Errors.{reason}`)
end

-- Both lock, the countdown runs out, both confirm. Returns the time used.
local function lockAndConfirm(session, t: number): number
	ok(Rules.Lock(session, 1, t, LIMITS))
	ok(Rules.Lock(session, 2, t, LIMITS))
	assert(session.Phase == "Countdown")
	t += T.CountdownSeconds
	assert(Rules.Tick(session, t))
	ok(Rules.Confirm(session, 1, t))
	local _, _, both = ok(Rules.Confirm(session, 2, t))
	assert(both == true)
	return t
end

local passed = 0
local function case(name: string, body: () -> ())
	body()
	passed += 1
	print(`  ok  {name}`)
end

print(`test_trade: gear {GEAR}, material {MATERIAL}, untradeable {UNTRADEABLE}`)

-- CASES ------------------------------------------------------------------------------------

case("start checks: dead, combat, busy, trading, trade-locked, town, range, cooldown", function()
	local good = { Loaded = true, Alive = true, InCombat = false, Busy = false, Trading = false, TradeLocked = false, InTown = true }
	assert(Rules.CheckPlayer(good, true) == nil)
	local function with(key, value)
		local facts = table.clone(good)
		facts[key] = value
		return Rules.CheckPlayer(facts, true)
	end
	assert(with("Loaded", false) == "NotLoaded")
	assert(with("Alive", false) == "Dead")
	assert(with("InCombat", true) == "Combat")
	assert(with("Busy", true) == "Busy")
	assert(with("Trading", true) == "AlreadyTrading")
	assert(with("TradeLocked", true) == "Busy")
	assert(with("InTown", false) == "NotInTown")
	local outside = table.clone(good)
	outside.InTown = false
	assert(Rules.CheckPlayer(outside, false) == nil, "TownOnly off allows outside town")
	assert(Rules.InRange(T.MaxDistance, T.MaxDistance))
	assert(not Rules.InRange(T.MaxDistance + 0.01, T.MaxDistance))
	assert(not Rules.InRange(nil, T.MaxDistance))
	assert(not Rules.InRange(0 / 0, T.MaxDistance))
	assert(Rules.CooldownReady(nil, 100, T.Cooldown))
	assert(not Rules.CooldownReady(100, 100 + T.Cooldown - 0.1, T.Cooldown))
	assert(Rules.CooldownReady(100, 100 + T.Cooldown, T.Cooldown))
end)

case("offer validation: missing, equipped, locked, untradeable, counts, slot cap", function()
	local a = newPlayer(100)
	local sword = give(a, GEAR, 1, "Epic")
	local ore = give(a, MATERIAL, 7)
	local quest = give(a, UNTRADEABLE, 1)
	local session = Rules.NewSession()
	fails("Missing", Rules.SetItem(session, 1, a, "nope", 1, LIMITS))
	fails("Invalid", Rules.SetItem(session, 1, a, "", 1, LIMITS))
	fails("Invalid", Rules.SetItem(session, 3, a, sword, 1, LIMITS))
	fails("NotTradeable", Rules.SetItem(session, 1, a, quest, 1, LIMITS))
	fails("Count", Rules.SetItem(session, 1, a, ore, 8, LIMITS))
	fails("Count", Rules.SetItem(session, 1, a, ore, 0, LIMITS))
	fails("Invalid", Rules.SetItem(session, 1, a, ore, 1.5, LIMITS))
	fails("Invalid", Rules.SetItem(session, 1, a, ore, 0 / 0, LIMITS))
	a.Equipped[slotOf(a, sword)] = sword
	fails("Equipped", Rules.SetItem(session, 1, a, sword, 1, LIMITS))
	a.Equipped[slotOf(a, sword)] = ""
	a.Inventory.Items[sword].Locked = true
	fails("ItemLocked", Rules.SetItem(session, 1, a, sword, 1, LIMITS))
	a.Inventory.Items[sword].Locked = false
	ok(Rules.SetItem(session, 1, a, sword, 1, LIMITS))
	ok(Rules.SetItem(session, 1, a, ore, 7, LIMITS))
	ok(Rules.SetItem(session, 1, a, ore, 3, LIMITS)) -- re-setting replaces the count
	assert(#session.Offers[1].Entries == 2 and session.Offers[1].Entries[2].Count == 3)
	assert(session.Offers[1].Entries[2].Snapshot.Count == 3)
	-- Slot cap.
	local b = newPlayer(0)
	local s2 = Rules.NewSession()
	for _ = 1, LIMITS.MaxItems do
		ok(Rules.SetItem(s2, 2, b, give(b, GEAR, 1), 1, LIMITS))
	end
	fails("Slots", Rules.SetItem(s2, 2, b, give(b, GEAR, 1), 1, LIMITS))
	ok(Rules.RemoveItem(s2, 2, s2.Offers[2].Entries[1].Uid))
	fails("Missing", Rules.RemoveItem(s2, 2, "nope"))
end)

case("gold bounds: negative, fractional, NaN, overflow, more than owned", function()
	local a = newPlayer(500)
	local session = Rules.NewSession()
	fails("Invalid", Rules.SetGold(session, 1, a, -1, LIMITS))
	fails("Invalid", Rules.SetGold(session, 1, a, 2.5, LIMITS))
	fails("Invalid", Rules.SetGold(session, 1, a, 0 / 0, LIMITS))
	fails("Invalid", Rules.SetGold(session, 1, a, math.huge, LIMITS))
	fails("Invalid", Rules.SetGold(session, 1, a, LIMITS.MaxGold + 1, LIMITS))
	fails("Funds", Rules.SetGold(session, 1, a, 501, LIMITS))
	ok(Rules.SetGold(session, 1, a, 500, LIMITS))
	assert(session.Offers[1].Gold == 500)
	ok(Rules.SetGold(session, 1, a, 0, LIMITS))
	assert(session.Offers[1].Gold == 0)
end)

case("any change unlocks both, bumps the changer's revision; locked side can't edit", function()
	local a, b = newPlayer(100), newPlayer(100)
	local sword = give(a, GEAR, 1)
	local ore = give(b, MATERIAL, 5)
	local session = Rules.NewSession()
	fails("Empty", Rules.Lock(session, 1, 0, LIMITS))
	ok(Rules.SetItem(session, 1, a, sword, 1, LIMITS))
	assert(session.Offers[1].Revision == 1 and session.Offers[2].Revision == 0)
	ok(Rules.Lock(session, 1, 0, LIMITS))
	assert(session.Offers[1].Locked and session.Phase == "Open")
	fails("YouLocked", Rules.RemoveItem(session, 1, sword))
	fails("YouLocked", Rules.SetGold(session, 1, a, 5, LIMITS))
	fails("YouLocked", Rules.SetItem(session, 1, a, sword, 1, LIMITS))
	-- B (unlocked) changes: A's lock drops too.
	ok(Rules.SetItem(session, 2, b, ore, 5, LIMITS))
	assert(not session.Offers[1].Locked and not session.Offers[2].Locked)
	assert(session.Offers[2].Revision == 1)
	-- Setting the same thing again is not a change.
	ok(Rules.Lock(session, 1, 0, LIMITS))
	ok(Rules.SetItem(session, 2, b, ore, 5, LIMITS))
	assert(session.Offers[1].Locked and session.Offers[2].Revision == 1)
	ok(Rules.SetGold(session, 2, b, 0, LIMITS))
	assert(session.Offers[1].Locked)
end)

case("countdown: starts on both locks, confirm only after it, unlock or change resets", function()
	local a, b = newPlayer(100), newPlayer(100)
	local sword = give(a, GEAR, 1)
	local session = Rules.NewSession()
	ok(Rules.SetItem(session, 1, a, sword, 1, LIMITS))
	fails("NotLocked", Rules.Confirm(session, 1, 0))
	ok(Rules.Lock(session, 1, 10, LIMITS))
	fails("NotLocked", Rules.Confirm(session, 1, 10))
	ok(Rules.Lock(session, 2, 10, LIMITS))
	assert(session.Phase == "Countdown" and session.CountdownEndsAt == 10 + T.CountdownSeconds)
	-- A repeated lock doesn't restart the countdown.
	ok(Rules.Lock(session, 2, 11, LIMITS))
	assert(session.CountdownEndsAt == 10 + T.CountdownSeconds)
	fails("Countdown", Rules.Confirm(session, 1, 10 + T.CountdownSeconds - 0.01))
	assert(not Rules.Tick(session, 10 + T.CountdownSeconds - 0.01))
	-- Unlock mid-countdown: back to Open, countdown gone.
	ok(Rules.Unlock(session, 2))
	assert(session.Phase == "Open" and session.CountdownEndsAt == 0 and session.Offers[1].Locked)
	ok(Rules.Lock(session, 2, 20, LIMITS))
	assert(session.CountdownEndsAt == 20 + T.CountdownSeconds)
	-- Confirm moves a finished countdown on by itself (no Tick needed).
	local _, _, both = ok(Rules.Confirm(session, 1, 20 + T.CountdownSeconds))
	assert(both == false and session.Phase == "Confirm")
	-- A change after one side confirmed clears it and needs a fresh countdown.
	ok(Rules.Unlock(session, 1))
	ok(Rules.SetGold(session, 1, a, 10, LIMITS))
	assert(session.Phase == "Open" and not session.Offers[1].Confirmed and not session.Offers[2].Locked)
	fails("NotLocked", Rules.Confirm(session, 2, 100))
end)

case("races: double confirm, change racing a confirm, both cancel, late confirm, replayed swap", function()
	local a, b = newPlayer(1000), newPlayer(0)
	local sword = give(a, GEAR, 1, "Rare")
	local session = Rules.NewSession()
	ok(Rules.SetItem(session, 1, a, sword, 1, LIMITS))
	ok(Rules.Lock(session, 1, 0, LIMITS))
	ok(Rules.Lock(session, 2, 0, LIMITS))
	Rules.Tick(session, T.CountdownSeconds)
	local _, _, first = ok(Rules.Confirm(session, 1, T.CountdownSeconds))
	local _, _, again = ok(Rules.Confirm(session, 1, T.CountdownSeconds))
	assert(first == false and again == false, "one side confirming twice never completes")
	-- B unlocks while A's confirm is in flight: A's confirmation is gone, B's confirm refused.
	ok(Rules.Unlock(session, 2))
	assert(not session.Offers[1].Confirmed)
	fails("NotLocked", Rules.Confirm(session, 2, 100))
	-- Both cancel: only the first close acts; everything after is refused.
	assert(Rules.Close(session) == true)
	assert(Rules.Close(session) == false)
	fails("Closed", Rules.Confirm(session, 2, 100))
	fails("Closed", Rules.SetGold(session, 1, a, 1, LIMITS))
	fails("Closed", Rules.Lock(session, 1, 100, LIMITS))
	assert(not Rules.Revalidate(session, 1, a))
	assert(not (Rules.PlanSwap({ a, b }, session, LIMITS, 0)))
	-- A finished swap can't be replayed: the second plan finds the items gone.
	local s2 = Rules.NewSession()
	ok(Rules.SetItem(s2, 1, a, sword, 1, LIMITS))
	ok(Rules.SetGold(s2, 1, a, 400, LIMITS))
	lockAndConfirm(s2, 0)
	local planned, _, _, drafts = Rules.PlanSwap({ a, b }, s2, LIMITS, 0)
	assert(planned)
	ok(Rules.Commit({ a, b }, drafts))
	local replay, reason, side = Rules.PlanSwap({ a, b }, s2, LIMITS, 0)
	assert(not replay and reason == "Missing" and side == 1, `replay: {tostring(reason)}`)
	assert(a.Currencies.Gold == 600 and b.Currencies.Gold == 400)
end)

case("re-validation at confirm: item gone, gold spent, equipped, locked, changed; nothing live changes", function()
	local function setup()
		local a, b = newPlayer(300), newPlayer(50)
		local sword = give(a, GEAR, 1, "Epic")
		local ore = give(b, MATERIAL, 6)
		local session = Rules.NewSession()
		ok(Rules.SetItem(session, 1, a, sword, 1, LIMITS))
		ok(Rules.SetGold(session, 1, a, 200, LIMITS))
		ok(Rules.SetItem(session, 2, b, ore, 4, LIMITS))
		lockAndConfirm(session, 0)
		return a, b, sword, ore, session
	end
	local function refused(expected: string, expectedSide: number, mutate)
		local a, b, sword, ore, session = setup()
		mutate(a, b, sword, ore)
		local beforeA, beforeB = TableUtil.DeepCopy(a), TableUtil.DeepCopy(b)
		local planned, reason, side = Rules.PlanSwap({ a, b }, session, LIMITS, 0)
		assert(not planned and reason == expected and side == expectedSide, `{expected}: got {tostring(reason)} side {tostring(side)}`)
		assert(sameTable(a, beforeA) and sameTable(b, beforeB), "a refused plan changed live data")
	end
	refused("Missing", 1, function(a, _, sword)
		a.Inventory.Items[sword] = nil
	end)
	refused("Funds", 1, function(a)
		a.Currencies.Gold = 199
	end)
	refused("Equipped", 1, function(a, _, sword)
		a.Equipped[slotOf(a, sword)] = sword
	end)
	refused("ItemLocked", 1, function(a, _, sword)
		a.Inventory.Items[sword].Locked = true
	end)
	refused("Changed", 1, function(a, _, sword)
		a.Inventory.Items[sword].Upgrade += 1
	end)
	refused("Changed", 1, function(a, _, sword)
		local item = a.Inventory.Items[sword]
		if #item.Affixes > 0 then
			item.Affixes[1].Value += 1
		else
			item.Rarity = "Legendary"
		end
	end)
	refused("Count", 2, function(_, b, _, ore)
		b.Inventory.Items[ore].Count = 3
	end)
	-- Bigger stack than offered is fine (only the offered count moves).
	local a, b, _, ore, session = setup()
	b.Inventory.Items[ore].Count = 9
	assert(Rules.PlanSwap({ a, b }, session, LIMITS, 0))
end)

case("bag space: full receiver refused, outgoing items free room", function()
	local a, b = newPlayer(0), newPlayer(0)
	local sword = give(a, GEAR, 1)
	for _ = 1, b.Inventory.Capacity do
		give(b, GEAR, 1)
	end
	local session = Rules.NewSession()
	ok(Rules.SetItem(session, 1, a, sword, 1, LIMITS))
	lockAndConfirm(session, 0)
	local planned, reason, side = Rules.PlanSwap({ a, b }, session, LIMITS, 0)
	assert(not planned and reason == "Full" and side == 2, `full: {tostring(reason)}`)
	-- B offers one of its own items back: that slot frees first, so it fits.
	local s2 = Rules.NewSession()
	ok(Rules.SetItem(s2, 1, a, sword, 1, LIMITS))
	local _, anyUid = next(b.Inventory.Items)
	ok(Rules.SetItem(s2, 2, b, anyUid.Uid, 1, LIMITS))
	lockAndConfirm(s2, 0)
	assert(Rules.PlanSwap({ a, b }, s2, LIMITS, 0))
end)

case("gold cap: receiving past MaxGold refused", function()
	local a, b = newPlayer(1000), newPlayer(LIMITS.MaxGold - 10)
	local session = Rules.NewSession()
	ok(Rules.SetGold(session, 1, a, 11, LIMITS))
	lockAndConfirm(session, 0)
	local planned, reason, side = Rules.PlanSwap({ a, b }, session, LIMITS, 0)
	assert(not planned and reason == "GoldCap" and side == 2)
	assert(Strings.Trade.Theirs.GoldCap ~= nil)
end)

case("full swap: conservation, fresh uids, same uid on both sides, partial stacks", function()
	local a, b = newPlayer(900), newPlayer(40)
	local swordA = give(a, GEAR, 1, "Epic")
	local oreA = give(a, MATERIAL, 10)
	local swordB = give(b, GEAR, 1, "Legendary")
	assert(swordA == swordB, "fixture: both profiles use the same uid string")
	local swordItemA = TableUtil.DeepCopy(a.Inventory.Items[swordA])
	local swordItemB = TableUtil.DeepCopy(b.Inventory.Items[swordB])
	local beforeTotals, beforeGold = census({ a, b })
	local session = Rules.NewSession()
	ok(Rules.SetItem(session, 1, a, swordA, 1, LIMITS))
	ok(Rules.SetItem(session, 1, a, oreA, 4, LIMITS))
	ok(Rules.SetGold(session, 1, a, 250, LIMITS))
	ok(Rules.SetItem(session, 2, b, swordB, 1, LIMITS))
	ok(Rules.SetGold(session, 2, b, 40, LIMITS))
	lockAndConfirm(session, 0)
	local planned, reason, _, drafts = Rules.PlanSwap({ a, b }, session, LIMITS, 1234)
	assert(planned, tostring(reason))
	assert(sameTable(census({ a, b }), beforeTotals), "planning touched live data")
	ok(Rules.Commit({ a, b }, drafts))
	local afterTotals, afterGold = census({ a, b })
	assert(sameTable(afterTotals, beforeTotals), "items not conserved")
	assert(afterGold == beforeGold, "gold not conserved")
	assert(a.Currencies.Gold == 900 - 250 + 40 and b.Currencies.Gold == 40 - 40 + 250)
	assert(a.Inventory.Items[oreA].Count == 6, "partial stack stays")
	-- A now holds B's sword (and not its own); B the other way round, plus 4 ore.
	local function holds(data, original)
		for _, item in data.Inventory.Items do
			if item.DefId == original.DefId and item.Rarity == original.Rarity and sameTable(item.Affixes, original.Affixes) then
				return item
			end
		end
		return nil
	end
	local got = assert(holds(a, swordItemB), "A didn't get B's sword")
	assert(got.New == true and got.Locked == false and got.AcquiredAt == 1234)
	assert(holds(b, swordItemA), "B didn't get A's sword")
	assert(Inv.Count(b, MATERIAL) == 4)
	-- Uids stay unique per profile.
	for _, data in { a, b } do
		local seen = {}
		for uid, item in data.Inventory.Items do
			assert(uid == item.Uid and not seen[uid])
			seen[uid] = true
		end
	end
end)

case("profile changed mid-trade: offer cleaned, both unlocked", function()
	local a, b = newPlayer(100), newPlayer(0)
	local sword = give(a, GEAR, 1)
	local ore = give(a, MATERIAL, 5)
	local session = Rules.NewSession()
	ok(Rules.SetItem(session, 1, a, sword, 1, LIMITS))
	ok(Rules.SetItem(session, 1, a, ore, 5, LIMITS))
	ok(Rules.SetGold(session, 1, a, 100, LIMITS))
	ok(Rules.Lock(session, 1, 0, LIMITS))
	ok(Rules.Lock(session, 2, 0, LIMITS))
	assert(not Rules.Revalidate(session, 1, a), "no change, no reset")
	assert(session.Phase == "Countdown")
	local revision = session.Offers[1].Revision
	a.Inventory.Items[ore].Count = 2 -- sold some
	a.Currencies.Gold = 30 -- spent some
	a.Inventory.Items[sword].Upgrade = 1 -- upgraded at the forge
	assert(Rules.Revalidate(session, 1, a))
	local offer = session.Offers[1]
	assert(#offer.Entries == 1 and offer.Entries[1].Uid == sword and offer.Entries[1].Snapshot.Upgrade == 1)
	assert(offer.Gold == 30 and offer.Revision == revision + 1)
	assert(session.Phase == "Open" and not offer.Locked and not session.Offers[2].Locked)
	-- The refreshed snapshot validates.
	lockAndConfirm(session, 0)
	assert(Rules.PlanSwap({ a, b }, session, LIMITS, 0))
end)

case("commit fault: every branch rolled back", function()
	local a, b = newPlayer(500), newPlayer(500)
	local sword = give(a, GEAR, 1)
	local ore = give(b, MATERIAL, 3)
	local session = Rules.NewSession()
	ok(Rules.SetItem(session, 1, a, sword, 1, LIMITS))
	ok(Rules.SetItem(session, 2, b, ore, 3, LIMITS))
	ok(Rules.SetGold(session, 2, b, 120, LIMITS))
	lockAndConfirm(session, 0)
	local planned, _, _, drafts = Rules.PlanSwap({ a, b }, session, LIMITS, 0)
	assert(planned)
	local beforeA, beforeB = TableUtil.DeepCopy(a), TableUtil.DeepCopy(b)
	local refA, refB = a.Inventory, b.Inventory
	for faultSide = 1, 2 do
		for faultIndex, faultBranch in Rules.SwapBranches do
			local committed, err = Rules.Commit({ a, b }, drafts, function(side, branch)
				if side == faultSide and branch == faultBranch then
					error("injected fault", 0)
				end
			end)
			assert(not committed and err == "injected fault", `fault {faultSide}/{faultIndex}`)
			assert(sameTable(a, beforeA) and sameTable(b, beforeB), `rollback incomplete at {faultSide}/{faultBranch}`)
			assert(a.Inventory == refA and b.Inventory == refB, "rollback must restore the original tables")
		end
	end
	-- And a clean commit afterwards still works.
	ok(Rules.Commit({ a, b }, drafts))
	assert(a.Currencies.Gold == 620 and b.Currencies.Gold == 380)
end)

print(`test_trade: {passed} cases passed`)
