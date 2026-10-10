--!strict
--[[
	TradeService
	Player-to-player trading (Phase 12, docs/PHASE12_MULTIPLAYER.md). The
	window's rules are the pure state machine in TradeRules; this service
	owns the players, the remotes and the profiles.

	- Request: the target must be in this server, within MaxDistance, and
	  both players in town (TownOnly), alive, out of combat, not in a dungeon
	  run, a Guardian fight or the tutorial, not already trading and not
	  blocked either way. One request per Cooldown. The target sees a
	  TradeRequest for RequestSeconds; Accept opens the window for both
	  (asking someone who already asked you accepts their request).
	- In the window: SetItem / RemoveItem / SetGold while your side is
	  unlocked, Lock / Unlock, then CountdownSeconds after both lock, both
	  Confirm. Any change by either side unlocks both. If an offered item or
	  the gold changes in its owner's profile mid-trade (sold, equipped,
	  locked, spent), the offer is cleaned up and that also unlocks both.
	- Final confirm: both players are checked again (town, range, alive,
	  combat, busy), then every offered item is re-validated against both
	  live profiles and the swap is planned on drafts (TradeRules.PlanSwap).
	  Only then are both profiles trade-locked (DataService.LockForTrade),
	  the drafts committed for both at once inside DataService.RunAtomic (no
	  yield anywhere between taking items out and putting them in; any
	  failure restores both profiles), unlocked and saved straight away.
	- Cancels: explicit Cancel (closing the window), leaving, the profile
	  being released, dying or respawning, entering combat, moving further
	  apart than MaxDistance (which also covers teleports), starting a run
	  (InstanceService.Begin cancels at once; a player being sent to another
	  server counts as busy).
	- TradeState goes to both players after every change: both offers with
	  full item instances (tooltips), gold, lock and confirm flags, the phase
	  and the countdown end (server time). TradeState(nil) closes the window.
	  Messages are Notify toasts from Strings.Trade.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Attributes = require(Shared.Attributes)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local TableUtil = require(Shared.Util.TableUtil)
local Log = require(Shared.Util.Log)

local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local AnalyticsService = require(script.Parent.AnalyticsService)
local DungeonService = require(script.Parent.DungeonService)
local GuardianService = require(script.Parent.GuardianService)
local QuestService = require(script.Parent.QuestService)
local TutorialService = require(script.Parent.TutorialService)
local InstanceService = require(script.Parent.InstanceService)
local TradeRules = require(script.Parent.TradeRules)

type PlayerData = Types.PlayerData

type Live = {
	Id: number,
	Players: { Player }, -- [1] requester, [2] the player who accepted
	State: TradeRules.Session, -- Phase "Closed" once cancelled or done
	Queued: boolean, -- a profile-change revalidation is scheduled
	Connections: { RBXScriptConnection },
}

local T = Config.Social.Trade
local A = Attributes.Names
local log = Log.new("TradeService")

local LIMITS: TradeRules.Limits = {
	MaxItems = T.MaxItems,
	MaxGold = Config.Economy.MaxGold,
	CountdownSeconds = T.CountdownSeconds,
}
local TOWN_REGION = "Town" -- region name in the baked grid (FloorBuilder.RegionLetters)
local WATCH_INTERVAL = 0.25 -- seconds between range / combat / countdown checks
-- Profile branches whose changes can touch an offer.
local WATCHED_BRANCHES: { [string]: boolean } = { Inventory = true, Equipped = true, Currencies = true }

local TradeService = {}

local sessions: { [Player]: Live } = {}
local requests: { [Player]: { [Player]: number } } = {} -- target -> requester -> expires at
local lastRequest: { [Player]: number } = {}
local nextId = 0

local function now(): number
	return Workspace:GetServerTimeNow()
end

-- MESSAGES ---------------------------------------------------------------------------

local function hasString(path: { string }): boolean
	local node: any = Strings.Trade
	for _, key in path do
		if type(node) ~= "table" then
			return false
		end
		node = node[key]
	end
	return type(node) == "string"
end

-- Toast from Strings.Trade.<group>.<reason>, falling back to <group>.Failed.
local function notify(player: Player, group: string, reason: string, args: { [string]: any }?, style: string?)
	local key = if hasString({ group, reason }) then reason else "Failed"
	Net.Fire("Notify", player, `Trade.{group}.{key}`, args or {}, style or "Warning")
end

-- FACTS ------------------------------------------------------------------------------

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function inCombat(player: Player): boolean
	local last = player:GetAttribute(A.LastCombat)
	return type(last) == "number" and now() - last < Config.Combat.Vitals.CombatTimeout
end

-- `inSession` ignores the player's own trade (checks made while it is open).
local function factsOf(player: Player, inSession: boolean): TradeRules.Facts
	local humanoid = humanoidOf(player)
	local root = rootOf(player)
	return {
		Loaded = DataService.IsLoaded(player),
		Alive = humanoid ~= nil and humanoid.Health > 0 and root ~= nil,
		InCombat = inCombat(player),
		Busy = DungeonService.GetRun(player) ~= nil
			or GuardianService.IsInFight(player)
			or TutorialService.IsActive(player)
			or InstanceService.IsTeleporting(player),
		Trading = not inSession and sessions[player] ~= nil,
		TradeLocked = DataService.IsTradeLocked(player),
		InTown = root ~= nil and QuestService.RegionAt(root.Position) == TOWN_REGION,
	}
end

local function distanceBetween(a: Player, b: Player): number?
	local rootA, rootB = rootOf(a), rootOf(b)
	if not rootA or not rootB then
		return nil
	end
	return (rootA.Position - rootB.Position).Magnitude
end

-- True if either player has blocked the other.
local function blocked(a: Player, b: Player): boolean
	local dataA, dataB = DataService.GetData(a), DataService.GetData(b)
	local aBlocks = dataA ~= nil and dataA.Social.Blocked[tostring(b.UserId)] == true
	local bBlocks = dataB ~= nil and dataB.Social.Blocked[tostring(a.UserId)] == true
	return aBlocks or bBlocks
end

-- Why `player` can't start a trade with `other` (from `player`'s side), or nil.
local function startProblem(player: Player, other: Player): string?
	local own = TradeRules.CheckPlayer(factsOf(player, false), T.TownOnly)
	if own then
		return own
	end
	if other.Parent ~= Players or TradeRules.CheckPlayer(factsOf(other, false), T.TownOnly) or blocked(player, other) then
		return "Unavailable"
	end
	if not TradeRules.InRange(distanceBetween(player, other), T.MaxDistance) then
		return "TooFar"
	end
	return nil
end

-- Why an open trade can't go on, or nil. `final` adds the town rule (the last confirm).
local function sessionProblem(live: Live, final: boolean): string?
	for _, player in live.Players do
		if player.Parent ~= Players or not DataService.IsLoaded(player) then
			return "Left"
		end
		local reason = TradeRules.CheckPlayer(factsOf(player, true), final and T.TownOnly)
		if reason then
			return reason
		end
	end
	local a, b = live.Players[1], live.Players[2]
	if blocked(a, b) then
		return "Unavailable"
	end
	if not TradeRules.InRange(distanceBetween(a, b), T.MaxDistance) then
		return "TooFar"
	end
	return nil
end

-- STATE ------------------------------------------------------------------------------

local function sideOf(live: Live, player: Player): number
	return if live.Players[1] == player then 1 else 2
end

local function offerPayload(live: Live, side: number): { [string]: any }
	local offer = live.State.Offers[side]
	local player = live.Players[side]
	local items = {}
	for _, entry in offer.Entries do
		table.insert(items, TableUtil.DeepCopy(entry.Snapshot))
	end
	return {
		UserId = player.UserId,
		Name = player.DisplayName,
		Items = items,
		Gold = offer.Gold,
		Locked = offer.Locked,
		Confirmed = offer.Confirmed,
		Revision = offer.Revision,
	}
end

local function sendState(live: Live, player: Player)
	local side = sideOf(live, player)
	Net.Fire("TradeState", player, {
		Id = live.Id,
		Phase = live.State.Phase,
		CountdownEndsAt = live.State.CountdownEndsAt,
		MaxItems = LIMITS.MaxItems,
		You = offerPayload(live, side),
		Them = offerPayload(live, TradeRules.Other(side)),
	})
end

local function broadcast(live: Live)
	for _, player in live.Players do
		sendState(live, player)
	end
end

-- Ends a trade for both players. `by` is the player who cancelled it, if one did.
local function close(live: Live, reason: string, by: Player?)
	if not TradeRules.Close(live.State) then
		return -- already closed: a second cancel, or a cancel racing the swap
	end
	for _, connection in live.Connections do
		connection:Disconnect()
	end
	table.clear(live.Connections)
	for side, player in live.Players do
		if sessions[player] == live then
			sessions[player] = nil
		end
		Net.Fire("TradeState", player, nil)
		local other = live.Players[TradeRules.Other(side)]
		local args = { name = other.DisplayName }
		if reason == "Complete" then
			notify(player, "Done", "Complete", args, "Success")
		elseif by == player then
			notify(player, "Cancelled", "Self", args, "Info")
		elseif by ~= nil then
			notify(player, "Cancelled", "ByThem", args, "Warning")
		else
			notify(player, "Cancelled", reason, args, "Warning")
		end
	end
end

-- Cleans both offers against the live profiles; broadcasts if anything changed.
local function revalidate(live: Live): boolean
	local dirty = false
	for side, player in live.Players do
		local data = DataService.GetData(player)
		if data and TradeRules.Revalidate(live.State, side, data) then
			dirty = true
		end
	end
	return dirty
end

-- Watches what ends a trade early for one participant.
local function watch(live: Live, player: Player)
	local function bindCharacter(character: Model?)
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			table.insert(live.Connections, humanoid.Died:Connect(function()
				close(live, "Dead")
			end))
		end
	end
	bindCharacter(player.Character)
	table.insert(live.Connections, player.CharacterAdded:Connect(function()
		close(live, "Moved")
	end))
	table.insert(live.Connections, player:GetAttributeChangedSignal(A.LastCombat):Connect(function()
		if inCombat(player) then
			close(live, "Combat")
		end
	end))
end

local function openSession(a: Player, b: Player)
	nextId += 1
	local live: Live = {
		Id = nextId,
		Players = { a, b },
		State = TradeRules.NewSession(),
		Queued = false,
		Connections = {},
	}
	sessions[a] = live
	sessions[b] = live
	-- Requests to or from either player are void now.
	requests[a] = nil
	requests[b] = nil
	for _, list in requests do
		list[a] = nil
		list[b] = nil
	end
	watch(live, a)
	watch(live, b)
	broadcast(live)
	AnalyticsService.Custom(a, "TradeOpened")
end

-- THE SWAP ---------------------------------------------------------------------------

-- The final check failed and nothing changed: offers are cleaned against the live
-- profiles, both sides unlock, and each player hears why (`side` = whose problem).
local function refuse(live: Live, reason: string, side: number?)
	if TradeRules.IsClosed(live.State) then
		return
	end
	revalidate(live)
	TradeRules.Unlock(live.State, 1)
	TradeRules.Unlock(live.State, 2)
	for index, player in live.Players do
		local other = live.Players[TradeRules.Other(index)]
		local group = if side ~= nil and side ~= index then "Theirs" else "Errors"
		notify(player, group, reason, { name = other.DisplayName })
	end
	broadcast(live)
end

local function describe(live: Live, side: number): string
	local offer = live.State.Offers[side]
	local parts = {}
	for _, entry in offer.Entries do
		table.insert(parts, `{entry.Snapshot.DefId}[{entry.Snapshot.Rarity}]x{entry.Count}`)
	end
	table.insert(parts, `{offer.Gold}g`)
	return table.concat(parts, ", ")
end

local function newRecipes(before: PlayerData, after: PlayerData): { string }
	local learned = {}
	for recipeId in after.RecipesKnown do
		if not before.RecipesKnown[recipeId] then
			table.insert(learned, recipeId)
		end
	end
	table.sort(learned)
	return learned
end

local function complete(live: Live)
	local a, b = live.Players[1], live.Players[2]
	local dataA, dataB = DataService.GetData(a), DataService.GetData(b)
	if not dataA or not dataB then
		close(live, "Left")
		return
	end
	local liveData = { dataA :: PlayerData, dataB :: PlayerData }
	local ok, reason, side, drafts = TradeRules.PlanSwap(liveData, live.State, LIMITS, os.time())
	if not ok or not drafts then
		refuse(live, reason or "Failed", side)
		return
	end
	local learned = { newRecipes(liveData[1], drafts[1]), newRecipes(liveData[2], drafts[2]) }
	local goldA, goldB = live.State.Offers[1].Gold, live.State.Offers[2].Gold
	local summary = `#{live.Id} {a.Name} gave [{describe(live, 1)}]; {b.Name} gave [{describe(live, 2)}]`

	if not DataService.LockForTrade({ a, b }) then
		refuse(live, "Busy", nil)
		return
	end
	local committed, err = DataService.RunAtomic({ a, b }, function()
		local done, why = TradeRules.Commit(liveData, drafts, nil)
		if not done then
			error(why or "commit failed", 0)
		end
	end)
	if not committed then
		DataService.UnlockTrade({ a, b }, false)
		log:Error(`trade {summary} failed to commit: {err or "?"}`)
		refuse(live, "Failed", nil)
		return
	end

	-- Released first (nothing below may leave the profiles locked) and saved both now.
	DataService.UnlockTrade({ a, b }, true)
	-- Closed before replicating, so the profile-change watcher ignores the swap itself.
	close(live, "Complete")
	for index, player in live.Players do
		for _, branch in TradeRules.SwapBranches do
			DataService.Replicate(player, { branch })
		end
		if #learned[index] > 0 then
			InventoryService.Result(player, true, "RecipeLearned", { Recipes = learned[index] })
		end
		AnalyticsService.Custom(player, "TradeComplete")
	end
	if goldA > 0 then
		AnalyticsService.Economy(a, "Sink", "Gold", goldA, dataA.Currencies.Gold, "Gameplay", "Trade")
		AnalyticsService.Economy(b, "Source", "Gold", goldA, dataB.Currencies.Gold, "Gameplay", "Trade")
	end
	if goldB > 0 then
		AnalyticsService.Economy(b, "Sink", "Gold", goldB, dataB.Currencies.Gold, "Gameplay", "Trade")
		AnalyticsService.Economy(a, "Source", "Gold", goldB, dataA.Currencies.Gold, "Gameplay", "Trade")
	end
	log:Info(`trade {summary}`)
end

-- REQUESTS ---------------------------------------------------------------------------

local function playerFromText(text: string): Player?
	local userId = tonumber(text)
	if not userId or userId % 1 ~= 0 or userId <= 0 then
		return nil
	end
	return Players:GetPlayerByUserId(userId)
end

local function accept(player: Player, requester: Player)
	local list = requests[player]
	local expiresAt = list and list[requester]
	if not list or not expiresAt or expiresAt < now() then
		if list then
			list[requester] = nil
		end
		notify(player, "Errors", "Expired")
		return
	end
	list[requester] = nil
	local problem = startProblem(player, requester)
	if problem then
		notify(player, "Errors", problem, { name = requester.DisplayName })
		return
	end
	openSession(requester, player)
end

local function request(player: Player, text: string)
	local target = playerFromText(text)
	if not target or target == player then
		notify(player, "Errors", "NotFound")
		return
	end
	-- They already asked us: this is an accept.
	local incoming = requests[player]
	if incoming and incoming[target] and incoming[target] >= now() then
		accept(player, target)
		return
	end
	local t = now()
	if not TradeRules.CooldownReady(lastRequest[player], t, T.Cooldown) then
		notify(player, "Errors", "Cooldown")
		return
	end
	local problem = startProblem(player, target)
	if problem then
		notify(player, "Errors", problem, { name = target.DisplayName })
		return
	end
	lastRequest[player] = t
	local list = requests[target]
	if not list then
		list = {}
		requests[target] = list
	end
	local expiresAt = t + T.RequestSeconds
	list[player] = expiresAt
	Net.Fire("TradeRequest", target, player.UserId, player.DisplayName, expiresAt)
	notify(player, "Done", "Sent", { name = target.DisplayName }, "Info")
end

local function decline(player: Player, text: string)
	local requester = playerFromText(text)
	local list = requests[player]
	if not requester or not list or not list[requester] then
		return
	end
	list[requester] = nil
	notify(requester, "Done", "Declined", { name = player.DisplayName }, "Info")
end

-- WINDOW ACTIONS ---------------------------------------------------------------------

local function onWindowAction(player: Player, live: Live, action: string, text: string, amount: number)
	local side = sideOf(live, player)
	local state = live.State
	local data = DataService.GetData(player)
	if not data then
		return
	end
	local ok, reason = false, nil :: string?
	if action == "SetItem" then
		ok, reason = TradeRules.SetItem(state, side, data, text, amount, LIMITS)
	elseif action == "RemoveItem" then
		ok, reason = TradeRules.RemoveItem(state, side, text)
	elseif action == "SetGold" then
		ok, reason = TradeRules.SetGold(state, side, data, amount, LIMITS)
	elseif action == "Lock" then
		ok, reason = TradeRules.Lock(state, side, now(), LIMITS)
	elseif action == "Unlock" then
		ok, reason = TradeRules.Unlock(state, side)
	elseif action == "Confirm" then
		local problem = sessionProblem(live, true)
		if problem then
			close(live, problem)
			return
		end
		local both
		ok, reason, both = TradeRules.Confirm(state, side, now())
		if ok and both then
			complete(live)
			return
		end
	end
	if not ok then
		notify(player, "Errors", reason or "Invalid")
		sendState(live, player) -- resync the client that asked
		return
	end
	broadcast(live)
end

local function onRequestTrade(player: Player, action: string, text: string, amount: number)
	if action == "Request" then
		request(player, text)
		return
	elseif action == "Accept" then
		local requester = playerFromText(text)
		if requester then
			accept(player, requester)
		end
		return
	elseif action == "Decline" then
		decline(player, text)
		return
	end
	local live = sessions[player]
	if not live or TradeRules.IsClosed(live.State) then
		return
	end
	if action == "Cancel" then
		close(live, "Cancelled", player)
		return
	end
	onWindowAction(player, live, action, text, amount)
end

-- LIFECYCLE --------------------------------------------------------------------------

local function onProfileChanged(player: Player, path: { string })
	local live = sessions[player]
	if not live or TradeRules.IsClosed(live.State) or live.Queued or not WATCHED_BRANCHES[path[1]] then
		return
	end
	live.Queued = true
	task.defer(function()
		live.Queued = false
		if not TradeRules.IsClosed(live.State) and revalidate(live) then
			broadcast(live)
		end
	end)
end

local function onLeaving(player: Player)
	local live = sessions[player]
	if live then
		close(live, "Left")
	end
	requests[player] = nil
	lastRequest[player] = nil
	for _, list in requests do
		list[player] = nil
	end
end

local function watchLoop()
	while true do
		task.wait(WATCH_INTERVAL)
		local t = now()
		local open: { Live } = {}
		for _, live in sessions do
			if not table.find(open, live) then
				table.insert(open, live)
			end
		end
		for _, live in open do
			if not TradeRules.IsClosed(live.State) then
				local problem = sessionProblem(live, false)
				if problem then
					close(live, problem)
				elseif TradeRules.Tick(live.State, t) then
					broadcast(live)
				end
			end
		end
		for target, list in requests do
			for requester, expiresAt in list do
				if expiresAt < t then
					list[requester] = nil
				end
			end
			if next(list) == nil then
				requests[target] = nil
			end
		end
	end
end

-- PUBLIC API -------------------------------------------------------------------------

function TradeService.IsTrading(player: Player): boolean
	return sessions[player] ~= nil
end

-- Ends `player`'s trade, if any (other systems: e.g. before a teleport).
function TradeService.Cancel(player: Player)
	local live = sessions[player]
	if live then
		close(live, "Moved")
	end
end

function TradeService.Init()
	Net.On("RequestTrade", onRequestTrade)
end

function TradeService.Start()
	InstanceService.Leaving:Connect(TradeService.Cancel)
	DataService.Changed:Connect(onProfileChanged)
	DataService.ProfileReleased:Connect(onLeaving)
	Players.PlayerRemoving:Connect(onLeaving)
	task.spawn(watchLoop)
end

return TradeService
