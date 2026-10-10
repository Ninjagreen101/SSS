--!strict
--[[
	PartyService
	Parties, raid groups, party chat, pings and the Party Finder (Phase 12,
	docs/PHASE12_MULTIPLAYER.md). The rules themselves live in PartyRules (pure, tested by
	tools/place/test_party.luau); this module owns the live state and the remotes.

	- RequestParty (action, arg):
	    Invite  arg = target UserId. The target must be in this server, not in a party and not
	            have blocked you (profile Social.Blocked). The invite lasts Party.InviteSeconds.
	    Accept / Decline  arg = the UserId whose invite (or Finder join request) you answer.
	    Leave   a leaving leader hands over to the oldest member; a party left with one member
	            disbands.
	    Kick / Promote  arg = target UserId (leader only). Disband (leader only).
	    Raid    the leader toggles a raid group (Party.RaidMaxMembers); back only if it fits.
	    LootMode  arg = "Personal" | "SharedGold" (leader only; also saved as their preference).
	  Every member gets PartyState on any change (nil once out) and the player attribute PartyId.
	- Party chat: a TextChatService TextChannel "Party" per party (TextChatService/PartyChannels/
	  <partyId>/Party); members are added with AddUserAsync and their TextSource removed on leave.
	- RequestPing (position, kind): party members only, Party.PingCooldown apart, at most
	  Party.MaxPings live per player, within Party.PingRange of the pinger -> Ping to the party.
	- RequestFinder (action, arg, note): List (arg = activity, note filtered with TextService),
	  Unlist, Join (arg = listing id; asks the listing's owner, who answers like an invite) and
	  Refresh (sends the board and keeps sending updates for Finder.WatchSeconds).

	Public: GetParty, MembersNear, IsRaid, IsLeader, SharedGoldGroups, Describe, Regroup, Changed
	(fires with each player whose party changed).
	Reserved runs (InstanceService): the sending server describes the group's party (Describe) in
	the teleport data; the instance server rebuilds it from whoever arrived (Regroup).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Attributes = require(Shared.Attributes)
local Log = require(Shared.Util.Log)

local DataService = require(script.Parent.DataService)
local PartyRules = require(script.Parent.PartyRules)

type Party = PartyRules.Party
type Invite = PartyRules.Invite

type Listing = {
	Id: string,
	Owner: number,
	OwnerName: string,
	Activity: string,
	Note: string,
	Expires: number,
}

export type ListingView = {
	Id: string,
	Owner: number,
	OwnerName: string,
	Activity: string,
	Note: string,
	Members: number,
	Capacity: number,
	Expires: number,
}

export type MemberView = { UserId: number, Name: string }

export type PartyView = {
	Id: string,
	Leader: number,
	Raid: boolean,
	LootMode: string,
	Capacity: number,
	Members: { MemberView },
}

local SP = Config.Social.Party
local SF = Config.Social.Finder
local A = Attributes.Names
local log = Log.new("PartyService")

local LIMITS: PartyRules.Limits = {
	MaxMembers = SP.MaxMembers,
	RaidMaxMembers = SP.RaidMaxMembers,
	InviteSeconds = SP.InviteSeconds,
}
local SWEEP_INTERVAL = 1

local PartyService = {}

-- Fires with every player whose party (membership, leader, raid or loot mode) changed.
PartyService.Changed = Signal.new() :: Signal.Signal<Player>

local parties: { [string]: Party } = {}
local partyOf: { [number]: string } = {} -- UserId -> party id
local invites: { [number]: { [number]: Invite } } = {} -- to -> from -> invite
local channels: { [string]: Folder } = {}
local pingTimes: { [Player]: { number } } = {} -- expiry times of a player's live pings
local lastPing: { [Player]: number } = {}
local listings: { [string]: Listing } = {}
local listingOf: { [number]: string } = {} -- owner UserId -> listing id
local watchers: { [Player]: number } = {}
local nextId = 0

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function newId(prefix: string): string
	nextId += 1
	return `{prefix}{nextId}`
end

local function playerById(userId: number): Player?
	local player = Players:GetPlayerByUserId(userId)
	return if player and player.Parent == Players then player else nil
end

local function notify(player: Player, key: string, args: { [string]: any }?, style: string?)
	Net.Fire("Notify", player, key, args or {}, style or "Info")
end

local function fail(player: Player, reason: string?)
	notify(player, `Party.Errors.{reason or "Unavailable"}`, nil, "Warning")
end

local function partyFor(userId: number): Party?
	local id = partyOf[userId]
	return if id then parties[id] else nil
end

local function memberPlayers(party: Party): { Player }
	local list = {}
	for _, userId in party.Members do
		local member = playerById(userId)
		if member then
			table.insert(list, member)
		end
	end
	return list
end

local function nameOf(userId: number): string
	local player = playerById(userId)
	return if player then player.DisplayName else tostring(userId)
end

local function aliveRoot(player: Player): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function isBlocked(by: Player, who: number): boolean
	local blocked = DataService.Get(by, { "Social", "Blocked" })
	return type(blocked) == "table" and blocked[tostring(who)] == true
end

local function preferredLootMode(player: Player): string
	local mode = DataService.Get(player, { "Social", "LootMode" })
	return if type(mode) == "string" and table.find(SP.LootModes, mode) then mode else SP.LootModes[1]
end

-- PARTY CHAT ----------------------------------------------------------------------------------

local function channelRoot(): Folder
	local existing = TextChatService:FindFirstChild("PartyChannels")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "PartyChannels"
	folder.Parent = TextChatService
	return folder
end

local function channelOf(partyId: string): TextChannel?
	local folder = channels[partyId]
	local channel = folder and folder:FindFirstChild("Party")
	return if channel and channel:IsA("TextChannel") then channel else nil
end

local function openChannel(party: Party)
	local ok, err = pcall(function()
		local folder = Instance.new("Folder")
		folder.Name = party.Id
		local channel = Instance.new("TextChannel")
		channel.Name = "Party"
		channel.Parent = folder
		folder.Parent = channelRoot()
		channels[party.Id] = folder
	end)
	if not ok then
		log:Warn(`party channel failed: {tostring(err)}`)
	end
end

local function removeFromChannel(partyId: string, userId: number)
	local channel = channelOf(partyId)
	if not channel then
		return
	end
	for _, child in channel:GetChildren() do
		if child:IsA("TextSource") and child.UserId == userId then
			child:Destroy()
		end
	end
end

local function addToChannel(party: Party, userId: number)
	local channel = channelOf(party.Id)
	if not channel then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			channel:AddUserAsync(userId)
		end)
		if not ok then
			log:Warn(`party channel add failed: {tostring(err)}`)
		end
		-- They may have left while AddUserAsync yielded.
		if partyOf[userId] ~= party.Id then
			removeFromChannel(party.Id, userId)
		end
	end)
end

local function closeChannel(partyId: string)
	local folder = channels[partyId]
	channels[partyId] = nil
	if folder then
		folder:Destroy()
	end
end

-- STATE ---------------------------------------------------------------------------------------

local function view(party: Party): PartyView
	local members: { MemberView } = {}
	for _, userId in party.Members do
		table.insert(members, { UserId = userId, Name = nameOf(userId) })
	end
	return {
		Id = party.Id,
		Leader = party.Leader,
		Raid = party.Raid,
		LootMode = party.LootMode,
		Capacity = PartyRules.Capacity(party, LIMITS),
		Members = members,
	}
end

local function sendState(party: Party)
	local payload = view(party)
	for _, member in memberPlayers(party) do
		member:SetAttribute(A.PartyId, party.Id)
		Net.Fire("PartyState", member, payload)
		PartyService.Changed:Fire(member)
	end
end

local function clearMember(userId: number)
	partyOf[userId] = nil
	local player = playerById(userId)
	if player then
		player:SetAttribute(A.PartyId, "")
		Net.Fire("PartyState", player, nil)
		PartyService.Changed:Fire(player)
	end
end

-- FINDER --------------------------------------------------------------------------------------

local function listingView(listing: Listing): ListingView
	local party = partyFor(listing.Owner)
	return {
		Id = listing.Id,
		Owner = listing.Owner,
		OwnerName = listing.OwnerName,
		Activity = listing.Activity,
		Note = listing.Note,
		Members = if party then #party.Members else 1,
		Capacity = if party then PartyRules.Capacity(party, LIMITS) else SP.MaxMembers,
		Expires = listing.Expires,
	}
end

local function boardView(): { ListingView }
	local list: { ListingView } = {}
	for _, listing in listings do
		table.insert(list, listingView(listing))
	end
	table.sort(list, function(a: ListingView, b: ListingView): boolean
		return a.Expires > b.Expires
	end)
	return list
end

local function broadcastBoard()
	local time = now()
	local targets = {}
	for watcher, expires in watchers do
		if expires > time and watcher.Parent == Players then
			table.insert(targets, watcher)
		end
	end
	if #targets > 0 then
		Net.FireList("FinderListings", targets, boardView())
	end
end

local function removeListing(ownerId: number): boolean
	local id = listingOf[ownerId]
	if not id then
		return false
	end
	listingOf[ownerId] = nil
	listings[id] = nil
	return true
end

-- A listing belongs to a solo player or a party leader; anyone else loses theirs.
local function checkListing(userId: number)
	local party = partyFor(userId)
	if party and party.Leader ~= userId and removeListing(userId) then
		broadcastBoard()
	end
end

-- MEMBERSHIP ----------------------------------------------------------------------------------

local function disband(party: Party)
	parties[party.Id] = nil
	local members = table.clone(party.Members)
	table.clear(party.Members)
	for _, userId in members do
		local player = playerById(userId)
		if player then
			notify(player, "Party.Notify.Disbanded")
		end
		clearMember(userId)
	end
	closeChannel(party.Id)
	broadcastBoard()
end

local function removeMember(party: Party, userId: number, key: string)
	local oldLeader = party.Leader
	local removed, mustDisband = PartyRules.RemoveMember(party, userId)
	if not removed then
		return
	end
	local name = nameOf(userId)
	removeFromChannel(party.Id, userId)
	clearMember(userId)
	if mustDisband then
		disband(party)
		return
	end
	for _, member in memberPlayers(party) do
		notify(member, key, { name = name })
		if party.Leader ~= oldLeader then
			notify(member, "Party.Notify.NewLeader", { name = nameOf(party.Leader) })
		end
	end
	sendState(party)
	checkListing(party.Leader)
	broadcastBoard()
end

local function join(host: Player, joiner: Player): (boolean, string?)
	local party = partyFor(host.UserId)
	if not party then
		local created = PartyRules.new(newId("P"), host.UserId, preferredLootMode(host))
		parties[created.Id] = created
		partyOf[host.UserId] = created.Id
		openChannel(created)
		addToChannel(created, host.UserId)
		party = created
	end
	local live = party :: Party
	local ok, reason = PartyRules.AddMember(live, joiner.UserId, LIMITS)
	if not ok then
		return false, reason
	end
	partyOf[joiner.UserId] = live.Id
	addToChannel(live, joiner.UserId)
	for _, member in memberPlayers(live) do
		notify(member, "Party.Notify.Joined", { name = joiner.DisplayName }, "Success")
	end
	sendState(live)
	checkListing(joiner.UserId)
	broadcastBoard()
	return true, nil
end

local function clearInvitesOf(userId: number)
	invites[userId] = nil
	for _, incoming in invites do
		incoming[userId] = nil
	end
end

-- Stores an invite or join request and shows it to its recipient.
local function sendInvite(kind: PartyRules.InviteKind, from: Player, to: Player): (boolean, string?)
	local incoming = invites[to.UserId]
	if not incoming then
		incoming = {}
		invites[to.UserId] = incoming
	end
	local existing = (incoming :: { [number]: Invite })[from.UserId]
	if existing and not PartyRules.IsExpired(existing, now()) then
		return false, "Pending"
	end
	local invite = PartyRules.NewInvite(kind, from.UserId, to.UserId, now(), LIMITS)
	;(incoming :: { [number]: Invite })[from.UserId] = invite
	Net.Fire("PartyInvite", to, from.UserId, from.DisplayName, invite.Expires, kind)
	return true, nil
end

-- REQUESTS ------------------------------------------------------------------------------------

local function targetOf(arg: string): Player?
	local userId = tonumber(arg)
	return if userId then playerById(userId) else nil
end

local function onInvite(player: Player, arg: string)
	local target = targetOf(arg)
	if not target or not DataService.IsLoaded(target) then
		fail(player, "NotFound")
		return
	end
	local ok, reason = PartyRules.CheckInvite(
		partyFor(player.UserId),
		player.UserId,
		target.UserId,
		partyFor(target.UserId) ~= nil,
		isBlocked(target, player.UserId) or isBlocked(player, target.UserId),
		LIMITS
	)
	if ok then
		ok, reason = sendInvite("Invite", player, target)
	end
	if ok then
		notify(player, "Party.Notify.InviteSent", { name = target.DisplayName })
	else
		fail(player, reason)
	end
end

local function onAnswer(player: Player, arg: string, accept: boolean)
	local fromId = tonumber(arg)
	local incoming = invites[player.UserId]
	local invite = if fromId and incoming then incoming[fromId] else nil
	if not invite or not incoming or not fromId then
		fail(player, "Expired")
		return
	end
	incoming[fromId] = nil
	local sender = playerById(invite.From)
	if not accept then
		if sender then
			notify(sender, if invite.Kind == "Request" then "Party.Notify.RequestDeclined" else "Party.Notify.Declined", { name = player.DisplayName })
		end
		return
	end
	local joinerId, hostId = PartyRules.Sides(invite)
	local joiner, host = playerById(joinerId), playerById(hostId)
	if not joiner or not host then
		fail(player, "NotFound")
		return
	end
	local ok, reason = PartyRules.CheckAccept(invite, now(), partyFor(hostId), partyFor(joinerId) ~= nil, LIMITS)
	if ok then
		ok, reason = join(host, joiner)
	end
	if not ok then
		fail(player, reason)
		if sender and sender ~= player then
			fail(sender, reason)
		end
	end
end

local function onLeader(player: Player, action: string, arg: string)
	local party = partyFor(player.UserId)
	if not party then
		fail(player, "NoParty")
		return
	end
	local live = party :: Party
	local targetId = tonumber(arg) or 0
	local ok, reason
	if action == "Kick" then
		ok, reason = PartyRules.Kick(live, player.UserId, targetId)
		if ok then
			local target = playerById(targetId)
			if target then
				notify(target, "Party.Notify.YouWereKicked", nil, "Warning")
			end
			removeMember(live, targetId, "Party.Notify.Kicked")
		end
	elseif action == "Promote" then
		ok, reason = PartyRules.Promote(live, player.UserId, targetId)
		if ok then
			for _, member in memberPlayers(live) do
				notify(member, "Party.Notify.NewLeader", { name = nameOf(targetId) })
			end
			sendState(live)
			checkListing(player.UserId)
		end
	elseif action == "Disband" then
		ok, reason = PartyRules.CheckLeader(live, player.UserId)
		if ok then
			disband(live)
		end
	elseif action == "Raid" then
		ok, reason = PartyRules.ToggleRaid(live, player.UserId, LIMITS)
		if ok then
			for _, member in memberPlayers(live) do
				notify(member, if live.Raid then "Party.Notify.RaidOn" else "Party.Notify.RaidOff", { max = SP.RaidMaxMembers })
			end
			sendState(live)
			broadcastBoard()
		end
	elseif action == "LootMode" then
		ok, reason = PartyRules.SetLootMode(live, player.UserId, arg, SP.LootModes)
		if ok then
			DataService.Set(player, { "Social", "LootMode" }, arg)
			for _, member in memberPlayers(live) do
				notify(member, `Party.Notify.Loot{arg}`)
			end
			sendState(live)
		end
	end
	if not ok then
		fail(player, reason)
	end
end

local function onParty(player: Player, action: string, arg: string)
	if not DataService.IsLoaded(player) then
		return
	end
	if action == "Invite" then
		onInvite(player, arg)
	elseif action == "Accept" or action == "Decline" then
		onAnswer(player, arg, action == "Accept")
	elseif action == "Leave" then
		local party = partyFor(player.UserId)
		if party then
			notify(player, "Party.Notify.YouLeft")
			removeMember(party, player.UserId, "Party.Notify.Left")
		end
	else
		onLeader(player, action, arg)
	end
end

-- PINGS ---------------------------------------------------------------------------------------

local function onPing(player: Player, position: Vector3, kind: string)
	local party = partyFor(player.UserId)
	local root = aliveRoot(player)
	if not party or not root then
		return
	end
	local clock = os.clock()
	if clock - (lastPing[player] or -math.huge) < SP.PingCooldown then
		return
	end
	if (root.Position - position).Magnitude > SP.PingRange then
		fail(player, "PingTooFar")
		return
	end
	local time = now()
	local live: { number } = {}
	local previous: { number } = pingTimes[player] or {}
	for _, expires in previous do
		if expires > time then
			table.insert(live, expires)
		end
	end
	if #live >= SP.MaxPings then
		pingTimes[player] = live
		return
	end
	lastPing[player] = clock
	local expires = time + SP.PingSeconds
	table.insert(live, expires)
	pingTimes[player] = live
	Net.FireList("Ping", memberPlayers(party), player.UserId, position, kind, expires)
end

-- FINDER REQUESTS -----------------------------------------------------------------------------

local function filterNote(player: Player, text: string): string
	local clean = string.gsub(text, "%c", " ")
	clean = string.sub(string.match(clean, "^%s*(.-)%s*$") or "", 1, SF.NoteMax)
	if clean == "" then
		return ""
	end
	local ok, result = pcall(function(): string
		local filtered = TextService:FilterStringAsync(clean, player.UserId, Enum.TextFilterContext.PublicChat)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	return if ok and type(result) == "string" then result else ""
end

local function watch(player: Player)
	watchers[player] = now() + SF.WatchSeconds
end

local function onList(player: Player, activity: string, note: string)
	if not table.find(SF.Activities, activity) then
		fail(player, "BadActivity")
		return
	end
	local party = partyFor(player.UserId)
	if party and party.Leader ~= player.UserId then
		fail(player, "NotLeader")
		return
	end
	local count = 0
	for _ in listings do
		count += 1
	end
	if not listingOf[player.UserId] and count >= SF.MaxListings then
		fail(player, "BoardFull")
		return
	end
	local filtered = filterNote(player, note)
	if player.Parent ~= Players then
		return
	end
	-- Re-check after the filter yielded.
	local after = partyFor(player.UserId)
	if after and after.Leader ~= player.UserId then
		fail(player, "NotLeader")
		return
	end
	local id = listingOf[player.UserId] or newId("L")
	listingOf[player.UserId] = id
	listings[id] = {
		Id = id,
		Owner = player.UserId,
		OwnerName = player.DisplayName,
		Activity = activity,
		Note = filtered,
		Expires = now() + SF.ListingSeconds,
	}
	watch(player)
	notify(player, "Finder.Notify.Listed", nil, "Success")
	broadcastBoard()
end

local function onJoin(player: Player, listingId: string)
	local listing = listings[listingId]
	local owner = if listing then playerById(listing.Owner) else nil
	if not listing or not owner or listing.Expires <= now() then
		fail(player, "ListingGone")
		return
	end
	local live = listing :: Listing
	local host = owner :: Player
	if partyFor(player.UserId) then
		fail(player, "InParty")
		return
	end
	if host == player then
		fail(player, "Self")
		return
	end
	local party = partyFor(live.Owner)
	if party and PartyRules.IsFull(party, LIMITS) then
		fail(player, "Full")
		return
	end
	if isBlocked(host, player.UserId) or isBlocked(player, host.UserId) then
		fail(player, "Unavailable")
		return
	end
	local ok, reason = sendInvite("Request", player, host)
	if ok then
		notify(player, "Finder.Notify.RequestSent", { name = host.DisplayName })
	else
		fail(player, reason)
	end
end

local function onFinder(player: Player, action: string, arg: string, note: string)
	if not DataService.IsLoaded(player) then
		return
	end
	if action == "List" then
		onList(player, arg, note)
	elseif action == "Unlist" then
		if removeListing(player.UserId) then
			notify(player, "Finder.Notify.Unlisted")
			broadcastBoard()
		end
	elseif action == "Join" then
		onJoin(player, arg)
	elseif action == "Refresh" then
		watch(player)
		Net.Fire("FinderListings", player, boardView())
	end
end

-- PUBLIC API ----------------------------------------------------------------------------------

-- The players in `player`'s party (including them), or nil when they have none.
function PartyService.GetParty(player: Player): { Player }?
	local party = partyFor(player.UserId)
	return if party then memberPlayers(party) else nil
end

-- Living party members other than `player` within `radius` studs of them.
function PartyService.MembersNear(player: Player, radius: number): { Player }
	local list = {}
	local party = partyFor(player.UserId)
	local root = party and aliveRoot(player)
	if not party or not root then
		return list
	end
	for _, member in memberPlayers(party) do
		local other = if member ~= player then aliveRoot(member) else nil
		if other and DataService.IsLoaded(member) and (other.Position - root.Position).Magnitude <= radius then
			table.insert(list, member)
		end
	end
	return list
end

function PartyService.IsRaid(player: Player): boolean
	local party = partyFor(player.UserId)
	return party ~= nil and party.Raid
end

function PartyService.IsLeader(player: Player): boolean
	local party = partyFor(player.UserId)
	return party ~= nil and party.Leader == player.UserId
end

-- Groups of two or more of `players` who share a party set to SharedGold (LootService pools
-- their kill gold and splits it evenly).
function PartyService.SharedGoldGroups(players: { Player }): { { Player } }
	local byParty: { [string]: { Player } } = {}
	for _, player in players do
		local party = partyFor(player.UserId)
		if party and party.LootMode == "SharedGold" then
			local group = byParty[party.Id] or {}
			table.insert(group, player)
			byParty[party.Id] = group
		end
	end
	local groups = {}
	for _, group in byParty do
		if #group >= 2 then
			table.insert(groups, group)
		end
	end
	return groups
end

export type PartyInfo = { Leader: number, Members: { number }, LootMode: string }

-- `player`'s party as plain data (leader, members oldest first, loot mode), or nil.
function PartyService.Describe(player: Player): PartyInfo?
	local party = partyFor(player.UserId)
	if not party then
		return nil
	end
	return { Leader = party.Leader, Members = table.clone(party.Members), LootMode = party.LootMode }
end

-- Instance servers: puts `players` (members of one source party, oldest first) back into one
-- party. The first call with two or more of them creates it, led by `leaderId` if present; later
-- calls add whoever arrived since and isn't in a party (players who joined another party here, or
-- left it, are left alone).
function PartyService.Regroup(players: { Player }, leaderId: number, lootMode: string)
	local host: Party? = nil
	local loose: { number } = {}
	for _, player in players do
		if player.Parent ~= Players then
			continue
		end
		local party = partyFor(player.UserId)
		if not party then
			table.insert(loose, player.UserId)
		elseif not host then
			host = party
		end
	end
	if #loose == 0 then
		return
	end
	local mode = if table.find(SP.LootModes, lootMode) then lootMode else SP.LootModes[1]
	local isNew = host == nil
	local party, added = PartyRules.Regroup(host, newId("P"), loose, leaderId, mode, LIMITS)
	if not party or #added == 0 then
		return
	end
	if isNew then
		parties[party.Id] = party
		openChannel(party)
	end
	for _, userId in added do
		partyOf[userId] = party.Id
		addToChannel(party, userId)
	end
	sendState(party)
	broadcastBoard()
end

-- LIFECYCLE -----------------------------------------------------------------------------------

local function onPlayerRemoving(player: Player)
	local userId = player.UserId
	local party = partyFor(userId)
	if party then
		removeMember(party, userId, "Party.Notify.Left")
	end
	clearInvitesOf(userId)
	if removeListing(userId) then
		broadcastBoard()
	end
	watchers[player] = nil
	lastPing[player] = nil
	pingTimes[player] = nil
end

local function sweep()
	local time = now()
	for to, incoming in invites do
		for from, invite in incoming do
			if PartyRules.IsExpired(invite, time) then
				incoming[from] = nil
			end
		end
		if next(incoming) == nil then
			invites[to] = nil
		end
	end
	local expired = false
	for id, listing in listings do
		if listing.Expires <= time then
			listings[id] = nil
			if listingOf[listing.Owner] == id then
				listingOf[listing.Owner] = nil
			end
			expired = true
		end
	end
	for watcher, expires in watchers do
		if expires <= time or watcher.Parent ~= Players then
			watchers[watcher] = nil
		end
	end
	if expired then
		broadcastBoard()
	end
end

function PartyService.Init()
	Net.On("RequestParty", onParty)
	Net.On("RequestPing", onPing)
	Net.On("RequestFinder", onFinder)
end

function PartyService.Start()
	local function added(player: Player)
		player:SetAttribute(A.PartyId, "")
	end
	Players.PlayerAdded:Connect(added)
	for _, player in Players:GetPlayers() do
		added(player)
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	task.spawn(function()
		while true do
			task.wait(SWEEP_INTERVAL)
			sweep()
		end
	end)
end

return PartyService
