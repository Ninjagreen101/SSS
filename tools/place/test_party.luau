--!nocheck
-- Offline test of the party rules (Systems/PartyRules.lua) with the real Config.Social tuning
-- loaded from src/: size caps, raid conversion, leader handoff on leave, disband, invite expiry
-- and acceptance, kick / promote / loot-mode permissions, the kill-XP share and the SharedGold
-- split. Every check is an assert; the run prints a summary.
--
--   lune run tools/place/test_party.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

-- Minimal module runtime (same as test_surge.luau): src/ folders become instance-like tables.
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
local Rules = requireNode(Systems.PartyRules)

local SP = Social.Party
local LIMITS = { MaxMembers = SP.MaxMembers, RaidMaxMembers = SP.RaidMaxMembers, InviteSeconds = SP.InviteSeconds }

local passed = 0
local function case(name: string, body: () -> ())
	body()
	passed += 1
	print(`  ok  {name}`)
end

-- A party led by 1 with members 2..count.
local function partyOf(count: number)
	local party = Rules.new("P1", 1, "Personal")
	for userId = 2, count do
		assert(Rules.AddMember(party, userId, LIMITS))
	end
	return party
end

print(`PartyRules: party {SP.MaxMembers}, raid {SP.RaidMaxMembers}, invites {SP.InviteSeconds}s, share {SP.ShareRadius} studs +{SP.XPBonusPerMember * 100}%`)

case("tuning matches the spec", function()
	assert(SP.MaxMembers == 6 and SP.RaidMaxMembers == 8, "6 per party, 8 per raid")
	assert(SP.InviteSeconds == 30 and SP.ShareRadius == 150 and SP.XPBonusPerMember == 0.1)
	assert(SP.PingSeconds == 8 and SP.PingRange == 600)
end)

case("size cap", function()
	local party = partyOf(SP.MaxMembers)
	assert(Rules.IsFull(party, LIMITS))
	local ok, reason = Rules.AddMember(party, 99, LIMITS)
	assert(not ok and reason == "Full", "a 7th member is refused")
	local again, why = Rules.AddMember(partyOf(2), 2, LIMITS)
	assert(not again and why == "InParty", "no duplicates")
end)

case("raid conversion", function()
	local party = partyOf(SP.MaxMembers)
	assert(not Rules.ToggleRaid(party, 2, LIMITS), "only the leader converts")
	assert(Rules.ToggleRaid(party, 1, LIMITS) and party.Raid)
	assert(Rules.Capacity(party, LIMITS) == SP.RaidMaxMembers)
	for userId = SP.MaxMembers + 1, SP.RaidMaxMembers do
		assert(Rules.AddMember(party, userId, LIMITS), "raid takes up to RaidMaxMembers")
	end
	local ok, reason = Rules.AddMember(party, 99, LIMITS)
	assert(not ok and reason == "Full", "raid cap")
	local back, why = Rules.ToggleRaid(party, 1, LIMITS)
	assert(not back and why == "TooMany" and party.Raid, "can't shrink back while over the party cap")
	Rules.RemoveMember(party, SP.RaidMaxMembers)
	Rules.RemoveMember(party, SP.RaidMaxMembers - 1)
	assert(Rules.ToggleRaid(party, 1, LIMITS) and not party.Raid, "back to a party once it fits")
end)

case("leader leaving hands over to the oldest member", function()
	local party = partyOf(4)
	local removed, disband = Rules.RemoveMember(party, 1)
	assert(removed and not disband)
	assert(party.Leader == 2, "oldest remaining member leads")
	Rules.RemoveMember(party, 3)
	assert(party.Leader == 2, "a member leaving keeps the leader")
	local _, last = Rules.RemoveMember(party, 2)
	assert(last and party.Leader == 4 and #party.Members == 1, "down to one: disband")
	local gone = Rules.RemoveMember(party, 42)
	assert(not gone, "removing a stranger does nothing")
end)

case("invite checks", function()
	assert(Rules.CheckInvite(nil, 1, 2, false, false, LIMITS), "a lone player may invite")
	local _, selfReason = Rules.CheckInvite(nil, 1, 1, false, false, LIMITS)
	assert(selfReason == "Self")
	local _, partied = Rules.CheckInvite(nil, 1, 2, true, false, LIMITS)
	assert(partied == "InParty")
	local _, blocked = Rules.CheckInvite(nil, 1, 2, false, true, LIMITS)
	assert(blocked == "Unavailable")
	local _, full = Rules.CheckInvite(partyOf(SP.MaxMembers), 1, 50, false, false, LIMITS)
	assert(full == "Full")
	assert(Rules.CheckInvite(partyOf(3), 3, 50, false, false, LIMITS), "any member may invite")
end)

case("invite expiry and acceptance", function()
	local invite = Rules.NewInvite("Invite", 1, 2, 100, LIMITS)
	assert(invite.Expires == 100 + SP.InviteSeconds)
	assert(not Rules.IsExpired(invite, 100 + SP.InviteSeconds - 0.01))
	assert(Rules.IsExpired(invite, 100 + SP.InviteSeconds))
	local joiner, host = Rules.Sides(invite)
	assert(joiner == 2 and host == 1, "the invited player joins the inviter")
	assert(Rules.CheckAccept(invite, 110, nil, false, LIMITS))
	local _, late = Rules.CheckAccept(invite, 100 + SP.InviteSeconds + 1, nil, false, LIMITS)
	assert(late == "Expired")
	local _, busy = Rules.CheckAccept(invite, 110, nil, true, LIMITS)
	assert(busy == "InParty")
	local _, full = Rules.CheckAccept(invite, 110, partyOf(SP.MaxMembers), false, LIMITS)
	assert(full == "Full", "the party filled up meanwhile")
	-- Finder join request: 7 asks the listing's owner 1.
	local request = Rules.NewInvite("Request", 7, 1, 100, LIMITS)
	local rJoiner, rHost = Rules.Sides(request)
	assert(rJoiner == 7 and rHost == 1, "the asker joins the owner")
	local promoted = partyOf(3)
	promoted.Leader = 2
	local _, notLeader = Rules.CheckAccept(request, 110, promoted, false, LIMITS)
	assert(notLeader == "NotLeader", "a request lapses when its owner stops leading")
end)

case("kick, promote and loot mode are leader only", function()
	local party = partyOf(3)
	local _, a = Rules.Kick(party, 2, 3)
	assert(a == "NotLeader")
	local _, b = Rules.Kick(party, 1, 1)
	assert(b == "NotMember", "can't kick yourself")
	local _, c = Rules.Kick(party, 1, 99)
	assert(c == "NotMember")
	assert(Rules.Kick(party, 1, 3))
	local _, d = Rules.Promote(party, 3, 2)
	assert(d == "NotLeader")
	assert(Rules.Promote(party, 1, 2) and party.Leader == 2)
	local _, e = Rules.Promote(party, 1, 3)
	assert(e == "NotLeader", "the old leader lost the rights")
	local _, f = Rules.SetLootMode(party, 1, "SharedGold", SP.LootModes)
	assert(f == "NotLeader")
	local _, g = Rules.SetLootMode(party, 2, "Everything", SP.LootModes)
	assert(g == "BadMode")
	assert(Rules.SetLootMode(party, 2, "SharedGold", SP.LootModes) and party.LootMode == "SharedGold")
end)

case("kill XP share math", function()
	local bonus = SP.XPBonusPerMember
	assert(Rules.ShareXP(37, 0, bonus) == 37, "no party nearby: unchanged")
	assert(Rules.ShareXP(100, 1, bonus) == 110, "+10% for one other member")
	assert(Rules.ShareXP(100, 5, bonus) == 150, "+50% for a full party")
	assert(Rules.ShareXP(100, SP.RaidMaxMembers - 1, bonus) == 170, "raid: +70%")
	assert(Rules.ShareXP(15, 2, bonus) == 18, "rounds down")
end)

case("SharedGold split", function()
	local shares = Rules.SplitGold(100, 3)
	assert(shares[1] == 34 and shares[2] == 33 and shares[3] == 33, "remainder to the first")
	local total = 0
	for _, share in Rules.SplitGold(997, 6) do
		total += share
	end
	assert(total == 997, "no gold made or lost")
	assert(#Rules.SplitGold(10, 0) == 0)
	local small = Rules.SplitGold(2, 4)
	assert(small[1] == 1 and small[2] == 1 and small[3] == 0 and small[4] == 0)
end)

print(`all {passed} cases passed`)
