--!strict
--[[
	TradeRules
	The trade window as a pure state machine, plus the swap itself. No
	Instances, no clocks, no yielding: TradeService passes `now` in and owns
	the players, remotes and profiles, so tools/place/test_trade.luau runs
	exactly what the server runs.

	Flow (Config.Social.Trade):
	  Open      both sides place items (SetItem / RemoveItem) and gold
	            (SetGold) while their own side is unlocked
	  Countdown both sides locked: CountdownSeconds must pass
	  Confirm   both must Confirm; then TradeService plans and commits the swap
	  Closed    cancelled or done: every call is refused from then on (Close is
	            idempotent, so two cancels or a late confirm can't act twice)
	Any change to either offer unlocks BOTH sides, clears confirmations,
	stops a running countdown and bumps that side's Revision (the other
	client flashes the change). Unlocking either side drops back to Open.

	Offers keep the item exactly as it was offered (a snapshot: what the
	other player saw in the tooltip). At the final confirm every entry is
	re-checked item by item against the live profile: same uid, item,
	rarity, upgrade, durability, affixes and unique effect; at least the
	offered count; still unlocked, unequipped and tradeable. Gold is checked
	against the live balance, and each bag must fit what comes in after its
	own outgoing items have left.

	The swap runs on private drafts of both profiles (PlanSwap), so a failure
	anywhere changes nothing. Commit then swaps the drafted branches into the
	live profiles and, if anything fails part-way, puts every branch back.
	Reasons are keys in Strings.Trade.Errors.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Items = require(Shared.Data.Items)
local InventoryRules = require(Shared.Data.InventoryRules)
local TableUtil = require(Shared.Util.TableUtil)

type PlayerData = Types.PlayerData
type ItemInstance = Types.ItemInstance

export type Reason = string
export type Phase = "Open" | "Countdown" | "Confirm" | "Closed"

export type Entry = {
	Uid: string,
	Count: number,
	Snapshot: ItemInstance, -- the item as offered, Count = the offered count
}

export type Offer = {
	Entries: { Entry }, -- in the order they were offered
	Gold: number,
	Locked: boolean,
	Confirmed: boolean,
	Revision: number, -- bumps on every change to this offer
}

export type Session = {
	Phase: Phase,
	Offers: { Offer }, -- [1] the requester, [2] the player who accepted
	CountdownEndsAt: number, -- 0 = no countdown running
}

export type Limits = {
	MaxItems: number,
	MaxGold: number,
	CountdownSeconds: number,
}

-- What TradeService knows about a player when a trade starts or is checked.
export type Facts = {
	Loaded: boolean,
	Alive: boolean,
	InCombat: boolean,
	Busy: boolean, -- in a dungeon run, a Guardian fight or the tutorial
	Trading: boolean,
	TradeLocked: boolean,
	InTown: boolean,
}

-- Profile branches a swap may change. Everything else on a draft is the live table.
local SWAP_BRANCHES: { string } = { "Inventory", "Currencies", "ItemState", "RecipesKnown" }

local Rules = {}

Rules.SwapBranches = table.freeze(table.clone(SWAP_BRANCHES))

-- PLAYERS ----------------------------------------------------------------------------

-- Why this player can't trade right now, or nil.
function Rules.CheckPlayer(facts: Facts, townOnly: boolean): Reason?
	if not facts.Loaded then
		return "NotLoaded"
	elseif not facts.Alive then
		return "Dead"
	elseif facts.TradeLocked then
		return "Busy"
	elseif facts.Trading then
		return "AlreadyTrading"
	elseif facts.Busy then
		return "Busy"
	elseif facts.InCombat then
		return "Combat"
	elseif townOnly and not facts.InTown then
		return "NotInTown"
	end
	return nil
end

-- Distance between the two players (nil = one has no character).
function Rules.InRange(distance: number?, maxDistance: number): boolean
	return distance ~= nil and distance == distance and distance <= maxDistance
end

function Rules.CooldownReady(lastRequest: number?, now: number, cooldown: number): boolean
	return lastRequest == nil or now - lastRequest >= cooldown
end

-- SESSION ----------------------------------------------------------------------------

local function newOffer(): Offer
	return { Entries = {}, Gold = 0, Locked = false, Confirmed = false, Revision = 0 }
end

function Rules.NewSession(): Session
	return { Phase = "Open", Offers = { newOffer(), newOffer() }, CountdownEndsAt = 0 }
end

function Rules.Other(side: number): number
	return if side == 1 then 2 else 1
end

local function validSide(side: number): boolean
	return side == 1 or side == 2
end

-- Ends the session. Returns true only for the call that actually closed it.
function Rules.Close(session: Session): boolean
	if session.Phase == "Closed" then
		return false
	end
	session.Phase = "Closed"
	session.CountdownEndsAt = 0
	return true
end

function Rules.IsClosed(session: Session): boolean
	return session.Phase == "Closed"
end

local function isWhole(value: any): boolean
	return type(value) == "number" and value == value and value % 1 == 0
end

local function findEntry(offer: Offer, uid: string): (number?, Entry?)
	for index, entry in offer.Entries do
		if entry.Uid == uid then
			return index, entry
		end
	end
	return nil, nil
end

-- Back to Open with both sides unlocked and unconfirmed.
local function resetLocks(session: Session)
	for _, offer in session.Offers do
		offer.Locked = false
		offer.Confirmed = false
	end
	session.Phase = "Open"
	session.CountdownEndsAt = 0
end

-- `side` changed its offer: unlock BOTH, stop the countdown, flag the change.
local function changed(session: Session, side: number)
	resetLocks(session)
	session.Offers[side].Revision += 1
end

-- The item as it is offered: a deep copy carrying the offered count.
function Rules.Snapshot(item: ItemInstance, count: number): ItemInstance
	local copy = TableUtil.DeepCopy(item)
	copy.Count = count
	copy.New = false
	copy.Locked = false
	return copy
end

-- Item fields that may differ between the offered copy and the live item: the count is
-- checked on its own, and the receiver gets fresh Locked / New / AcquiredAt anyway.
local LOOSE_FIELDS: { [string]: boolean } = { Count = true, Locked = true, New = true, AcquiredAt = true }

local function deepEqual(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- Whether two copies are the same item to the player receiving it (count aside). Every
-- other field must match (uid, item, rarity, upgrade, durability, affixes, unique effect,
-- and any field added later), so what was shown is exactly what is delivered.
function Rules.SameItem(a: ItemInstance, b: ItemInstance): boolean
	local left, right = a :: any, b :: any
	for key, value in left do
		if not LOOSE_FIELDS[key] and not deepEqual(value, right[key]) then
			return false
		end
	end
	for key in right do
		if not LOOSE_FIELDS[key] and left[key] == nil then
			return false
		end
	end
	return true
end

-- Why `count` of bag item `uid` can't be offered, or nil.
function Rules.ItemProblem(data: PlayerData, uid: string, count: number): Reason?
	local item = data.Inventory.Items[uid]
	if not item then
		return "Missing"
	end
	local def = Items.Get(item.DefId)
	if not def then
		return "Missing"
	elseif not def.Tradeable then
		return "NotTradeable"
	elseif item.Locked then
		return "ItemLocked"
	elseif InventoryRules.EquippedSlot(data, uid) ~= nil then
		return "Equipped"
	elseif not InventoryRules.IsCount(count, item.Count) then
		return "Count"
	end
	return nil
end

-- Offers `count` of bag item `uid` (replacing the count if it's already offered).
function Rules.SetItem(session: Session, side: number, data: PlayerData, uid: string, count: number, limits: Limits): (boolean, Reason?)
	if session.Phase == "Closed" then
		return false, "Closed"
	elseif not validSide(side) or type(uid) ~= "string" or uid == "" or not isWhole(count) then
		return false, "Invalid"
	end
	local offer = session.Offers[side]
	if offer.Locked then
		return false, "YouLocked"
	end
	local problem = Rules.ItemProblem(data, uid, count)
	if problem then
		return false, problem
	end
	local snapshot = Rules.Snapshot(data.Inventory.Items[uid], count)
	local _, entry = findEntry(offer, uid)
	if entry then
		if entry.Count == count and Rules.SameItem(entry.Snapshot, snapshot) then
			return true, nil -- nothing changed
		end
		entry.Count = count
		entry.Snapshot = snapshot
	else
		if #offer.Entries >= limits.MaxItems then
			return false, "Slots"
		end
		table.insert(offer.Entries, { Uid = uid, Count = count, Snapshot = snapshot })
	end
	changed(session, side)
	return true, nil
end

function Rules.RemoveItem(session: Session, side: number, uid: string): (boolean, Reason?)
	if session.Phase == "Closed" then
		return false, "Closed"
	elseif not validSide(side) or type(uid) ~= "string" then
		return false, "Invalid"
	end
	local offer = session.Offers[side]
	if offer.Locked then
		return false, "YouLocked"
	end
	local index = findEntry(offer, uid)
	if not index then
		return false, "Missing"
	end
	table.remove(offer.Entries, index)
	changed(session, side)
	return true, nil
end

function Rules.SetGold(session: Session, side: number, data: PlayerData, gold: number, limits: Limits): (boolean, Reason?)
	if session.Phase == "Closed" then
		return false, "Closed"
	elseif not validSide(side) or not isWhole(gold) or gold < 0 or gold > limits.MaxGold then
		return false, "Invalid"
	end
	local offer = session.Offers[side]
	if offer.Locked then
		return false, "YouLocked"
	end
	if gold > data.Currencies.Gold then
		return false, "Funds"
	end
	if offer.Gold == gold then
		return true, nil
	end
	offer.Gold = gold
	changed(session, side)
	return true, nil
end

-- Locks one side. With both locked the countdown starts.
function Rules.Lock(session: Session, side: number, now: number, limits: Limits): (boolean, Reason?)
	if session.Phase == "Closed" then
		return false, "Closed"
	elseif not validSide(side) then
		return false, "Invalid"
	end
	local offer = session.Offers[side]
	if offer.Locked then
		return true, nil
	end
	local a, b = session.Offers[1], session.Offers[2]
	if #a.Entries == 0 and #b.Entries == 0 and a.Gold == 0 and b.Gold == 0 then
		return false, "Empty"
	end
	offer.Locked = true
	if session.Offers[Rules.Other(side)].Locked then
		session.Phase = "Countdown"
		session.CountdownEndsAt = now + limits.CountdownSeconds
	end
	return true, nil
end

-- Unlocks one side (the other keeps its lock); stops the countdown and clears confirmations.
function Rules.Unlock(session: Session, side: number): (boolean, Reason?)
	if session.Phase == "Closed" then
		return false, "Closed"
	elseif not validSide(side) then
		return false, "Invalid"
	end
	session.Offers[side].Locked = false
	for _, offer in session.Offers do
		offer.Confirmed = false
	end
	session.Phase = "Open"
	session.CountdownEndsAt = 0
	return true, nil
end

-- Moves a finished countdown on to Confirm. Returns true if the phase changed.
function Rules.Tick(session: Session, now: number): boolean
	if session.Phase == "Countdown" and now >= session.CountdownEndsAt then
		session.Phase = "Confirm"
		return true
	end
	return false
end

-- Confirms one side. Returns ok, reason, and whether both have now confirmed.
function Rules.Confirm(session: Session, side: number, now: number): (boolean, Reason?, boolean)
	if session.Phase == "Closed" then
		return false, "Closed", false
	elseif not validSide(side) then
		return false, "Invalid", false
	end
	Rules.Tick(session, now)
	if session.Phase == "Countdown" then
		return false, "Countdown", false
	elseif session.Phase ~= "Confirm" then
		return false, "NotLocked", false
	end
	session.Offers[side].Confirmed = true
	return true, nil, session.Offers[1].Confirmed and session.Offers[2].Confirmed
end

-- After the owner's profile changed mid-trade: drops entries that can no longer be
-- traded, refreshes snapshots that changed, lowers gold to what they still have.
-- Any change counts as an offer change (both sides unlock). Returns whether it changed.
function Rules.Revalidate(session: Session, side: number, data: PlayerData): boolean
	if session.Phase == "Closed" then
		return false
	end
	local offer = session.Offers[side]
	local dirty = false
	for index = #offer.Entries, 1, -1 do
		local entry = offer.Entries[index]
		if Rules.ItemProblem(data, entry.Uid, entry.Count) then
			table.remove(offer.Entries, index)
			dirty = true
		else
			local live = Rules.Snapshot(data.Inventory.Items[entry.Uid], entry.Count)
			if not Rules.SameItem(entry.Snapshot, live) then
				entry.Snapshot = live
				dirty = true
			end
		end
	end
	if offer.Gold > data.Currencies.Gold then
		offer.Gold = math.max(0, data.Currencies.Gold)
		dirty = true
	end
	if dirty then
		changed(session, side)
	end
	return dirty
end

-- SWAP -------------------------------------------------------------------------------

-- Final item-by-item check of one offer against its owner's live profile.
function Rules.ValidateOffer(offer: Offer, data: PlayerData, limits: Limits): (boolean, Reason?)
	if #offer.Entries > limits.MaxItems then
		return false, "Slots"
	end
	local seen: { [string]: boolean } = {}
	for _, entry in offer.Entries do
		if seen[entry.Uid] then
			return false, "Invalid"
		end
		seen[entry.Uid] = true
		local problem = Rules.ItemProblem(data, entry.Uid, entry.Count)
		if problem then
			return false, problem
		end
		if entry.Snapshot.Count ~= entry.Count then
			return false, "Changed"
		end
		if not Rules.SameItem(entry.Snapshot, Rules.Snapshot(data.Inventory.Items[entry.Uid], entry.Count)) then
			return false, "Changed"
		end
	end
	if not isWhole(offer.Gold) or offer.Gold < 0 or offer.Gold > limits.MaxGold then
		return false, "Invalid"
	end
	if offer.Gold > data.Currencies.Gold then
		return false, "Funds"
	end
	return true, nil
end

-- A private copy of the branches a swap changes (the rest stays shared with the live table).
local function makeDraft(data: PlayerData): PlayerData
	local live = data :: any
	local draft = table.clone(live)
	for _, branch in SWAP_BRANCHES do
		draft[branch] = TableUtil.DeepCopy(live[branch])
	end
	return draft :: PlayerData
end

-- What the receiver gets: the live item, fresh to them.
local function received(item: ItemInstance, now: number): ItemInstance
	local copy = TableUtil.DeepCopy(item)
	copy.Uid = ""
	copy.Locked = false
	copy.New = true
	copy.AcquiredAt = now
	return copy
end

--[[
	Plans the whole swap on drafts. Both sessions must be in Confirm with both
	sides confirmed. Returns ok, reason, the side the reason is about, and the
	two drafts. Nothing live is touched.
]]
function Rules.PlanSwap(
	live: { PlayerData },
	session: Session,
	limits: Limits,
	now: number
): (boolean, Reason?, number?, { PlayerData }?)
	if session.Phase ~= "Confirm" then
		return false, "NotLocked", nil, nil
	end
	for side = 1, 2 do
		local offer = session.Offers[side]
		if not (offer.Locked and offer.Confirmed) then
			return false, "NotLocked", side, nil
		end
		local ok, reason = Rules.ValidateOffer(offer, live[side], limits)
		if not ok then
			return false, reason, side, nil
		end
	end
	local drafts = { makeDraft(live[1]), makeDraft(live[2]) }

	-- 1. Everything outgoing leaves its owner's draft.
	for side = 1, 2 do
		local offer, draft = session.Offers[side], drafts[side]
		for _, entry in offer.Entries do
			local ok, reason = InventoryRules.Remove(draft, entry.Uid, entry.Count)
			if not ok then
				return false, reason or "Invalid", side, nil
			end
		end
		if offer.Gold > 0 then
			local ok, reason = InventoryRules.Pay(draft, "Gold", offer.Gold)
			if not ok then
				return false, reason or "Funds", side, nil
			end
		end
	end

	-- 2. Everything incoming lands in the other draft (it must fit; gold must not pass the cap).
	for side = 1, 2 do
		local from = Rules.Other(side)
		local offer, draft = session.Offers[from], drafts[side]
		for _, entry in offer.Entries do
			local item = received(live[from].Inventory.Items[entry.Uid], now)
			local ok, reason = InventoryRules.Add(draft, item, entry.Count)
			if not ok then
				return false, if reason == "Full" then "Full" else reason or "Invalid", side, nil
			end
		end
		if offer.Gold > 0 then
			if draft.Currencies.Gold + offer.Gold > limits.MaxGold then
				return false, "GoldCap", side, nil
			end
			draft.Currencies.Gold += offer.Gold
		end
	end
	return true, nil, nil, drafts
end

--[[
	Swaps the drafted branches into the live profiles. If anything fails
	part-way, every branch already swapped is restored, so the live profiles
	end exactly as they began. Must not yield (TradeService runs it inside
	DataService.RunAtomic). `beforeEach` is a fault-injection point for the
	offline test; the server passes nil.
]]
function Rules.Commit(live: { PlayerData }, drafts: { PlayerData }, beforeEach: ((side: number, branch: string) -> ())?): (boolean, string?)
	local undo: { { Data: any, Branch: string, Value: any } } = {}
	local ok, err = pcall(function()
		for side, data in live do
			local target = data :: any
			local draft = drafts[side] :: any
			for _, branch in SWAP_BRANCHES do
				if beforeEach then
					beforeEach(side, branch)
				end
				table.insert(undo, { Data = target, Branch = branch, Value = target[branch] })
				target[branch] = draft[branch]
			end
		end
	end)
	if not ok then
		for index = #undo, 1, -1 do
			local step = undo[index]
			step.Data[step.Branch] = step.Value
		end
		return false, tostring(err)
	end
	return true, nil
end

return table.freeze(Rules)
