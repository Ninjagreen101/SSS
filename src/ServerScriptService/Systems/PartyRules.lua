--!strict
--[[
	PartyRules (helper, not a system)
	The pure rules of parties and raids (docs/PHASE12_MULTIPLAYER.md), with no Roblox instances so
	tools/place/test_party.luau can test them offline. PartyService owns the live state and calls
	these; every function returns (ok, reason) where it can refuse. Members are UserIds in join
	order (oldest first), so leadership passes to the oldest remaining member.

	Pending invites cover both directions:
	  Invite   From (a member, or a lone player) asks To to join From's party.
	  Request  From (a lone player, via the Finder) asks To (a listing's leader) to be let in.
	Either way the player who answers is `To`, and `Joiner` is who enters the party.
]]

export type Party = {
	Id: string,
	Leader: number,
	Members: { number }, -- UserIds, oldest first
	Raid: boolean,
	LootMode: string,
}

export type InviteKind = "Invite" | "Request"

export type Invite = {
	Kind: InviteKind,
	From: number,
	To: number,
	Expires: number,
}

export type Limits = {
	MaxMembers: number,
	RaidMaxMembers: number,
	InviteSeconds: number,
}

local PartyRules = {}

function PartyRules.new(id: string, leader: number, lootMode: string): Party
	return { Id = id, Leader = leader, Members = { leader }, Raid = false, LootMode = lootMode }
end

function PartyRules.Capacity(party: Party, limits: Limits): number
	return if party.Raid then limits.RaidMaxMembers else limits.MaxMembers
end

function PartyRules.IsMember(party: Party, userId: number): boolean
	return table.find(party.Members, userId) ~= nil
end

function PartyRules.IsFull(party: Party, limits: Limits): boolean
	return #party.Members >= PartyRules.Capacity(party, limits)
end

-- Whether `from` may invite `to`. `fromParty` is the inviter's party (nil = alone; accepting
-- then makes a new party with the inviter as leader). Any member may invite.
function PartyRules.CheckInvite(fromParty: Party?, from: number, to: number, toInParty: boolean, blocked: boolean, limits: Limits): (boolean, string?)
	if from == to then
		return false, "Self"
	end
	if toInParty then
		return false, "InParty"
	end
	if blocked then
		return false, "Unavailable"
	end
	if fromParty and PartyRules.IsFull(fromParty, limits) then
		return false, "Full"
	end
	return true, nil
end

function PartyRules.NewInvite(kind: InviteKind, from: number, to: number, now: number, limits: Limits): Invite
	return { Kind = kind, From = from, To = to, Expires = now + limits.InviteSeconds }
end

function PartyRules.IsExpired(invite: Invite, now: number): boolean
	return now >= invite.Expires
end

-- Who enters the party when `invite` is accepted, and whose party they enter.
function PartyRules.Sides(invite: Invite): (number, number)
	if invite.Kind == "Request" then
		return invite.From, invite.To -- joiner, host
	end
	return invite.To, invite.From
end

-- Whether an invite can be accepted now. `hostParty` is the host's current party (nil = alone),
-- `joinerInParty` whether the joiner already has one.
function PartyRules.CheckAccept(invite: Invite, now: number, hostParty: Party?, joinerInParty: boolean, limits: Limits): (boolean, string?)
	if PartyRules.IsExpired(invite, now) then
		return false, "Expired"
	end
	if joinerInParty then
		return false, "InParty"
	end
	if hostParty and PartyRules.IsFull(hostParty, limits) then
		return false, "Full"
	end
	if invite.Kind == "Request" and hostParty and hostParty.Leader ~= invite.To then
		return false, "NotLeader" -- the listing's owner stopped leading
	end
	return true, nil
end

function PartyRules.AddMember(party: Party, userId: number, limits: Limits): (boolean, string?)
	if PartyRules.IsMember(party, userId) then
		return false, "InParty"
	end
	if PartyRules.IsFull(party, limits) then
		return false, "Full"
	end
	table.insert(party.Members, userId)
	return true, nil
end

-- Instance servers: rebuilds a run's party from the players there. `party` is the one the run
-- already has (nil before it exists); `loose` are present members of the source party who are in
-- no party, in the source party's order. A new party needs two or more and is led by `leaderId`
-- when they are among them (else the first). Grows into a raid when it outgrows a party; anyone
-- past the raid cap stays out. Returns the party (nil if none yet) and the UserIds added to it.
function PartyRules.Regroup(party: Party?, id: string, loose: { number }, leaderId: number, lootMode: string, limits: Limits): (Party?, { number })
	local added: { number } = {}
	local group = party
	if not group then
		if #loose < 2 then
			return nil, added
		end
		local leader = if table.find(loose, leaderId) then leaderId else loose[1]
		group = PartyRules.new(id, leader, lootMode)
		table.insert(added, leader)
	end
	local live = group :: Party
	for _, userId in loose do
		if PartyRules.IsMember(live, userId) then
			continue
		end
		if not live.Raid and #live.Members >= limits.MaxMembers then
			live.Raid = true
		end
		if PartyRules.AddMember(live, userId, limits) then
			table.insert(added, userId)
		end
	end
	return live, added
end

-- Removes a member. Returns whether they were in it, and whether the party must now disband
-- (fewer than two members left). A leaving leader hands over to the oldest remaining member.
function PartyRules.RemoveMember(party: Party, userId: number): (boolean, boolean)
	local index = table.find(party.Members, userId)
	if not index then
		return false, false
	end
	table.remove(party.Members, index)
	if party.Leader == userId and #party.Members > 0 then
		party.Leader = party.Members[1]
	end
	return true, #party.Members < 2
end

function PartyRules.CheckLeader(party: Party, actor: number): (boolean, string?)
	if party.Leader ~= actor then
		return false, "NotLeader"
	end
	return true, nil
end

function PartyRules.Kick(party: Party, actor: number, target: number): (boolean, string?)
	local ok, reason = PartyRules.CheckLeader(party, actor)
	if not ok then
		return false, reason
	end
	if target == actor or not PartyRules.IsMember(party, target) then
		return false, "NotMember"
	end
	return true, nil
end

function PartyRules.Promote(party: Party, actor: number, target: number): (boolean, string?)
	local ok, reason = PartyRules.CheckLeader(party, actor)
	if not ok then
		return false, reason
	end
	if target == actor or not PartyRules.IsMember(party, target) then
		return false, "NotMember"
	end
	party.Leader = target
	return true, nil
end

-- The leader toggles raid mode. Back to a party only while the members fit in one.
function PartyRules.ToggleRaid(party: Party, actor: number, limits: Limits): (boolean, string?)
	local ok, reason = PartyRules.CheckLeader(party, actor)
	if not ok then
		return false, reason
	end
	if party.Raid and #party.Members > limits.MaxMembers then
		return false, "TooMany"
	end
	party.Raid = not party.Raid
	return true, nil
end

function PartyRules.SetLootMode(party: Party, actor: number, mode: string, modes: { string }): (boolean, string?)
	local ok, reason = PartyRules.CheckLeader(party, actor)
	if not ok then
		return false, reason
	end
	if not table.find(modes, mode) then
		return false, "BadMode"
	end
	party.LootMode = mode
	return true, nil
end

-- Kill XP for one player with `othersInRange` party members nearby: +bonus per other member.
-- With nobody in range it is exactly `xp` (non-party kills are unchanged).
function PartyRules.ShareXP(xp: number, othersInRange: number, bonusPerMember: number): number
	if othersInRange <= 0 then
		return xp
	end
	return math.floor(xp * (1 + bonusPerMember * othersInRange) + 1e-6) -- epsilon: 0.1 steps aren't exact
end

-- Splits `total` gold evenly over `count` players; the remainder goes one each to the first.
function PartyRules.SplitGold(total: number, count: number): { number }
	local shares = {}
	if count <= 0 then
		return shares
	end
	local whole = math.max(0, math.floor(total))
	local base = whole // count
	local extra = whole - base * count
	for index = 1, count do
		shares[index] = base + (if index <= extra then 1 else 0)
	end
	return shares
end

return PartyRules
