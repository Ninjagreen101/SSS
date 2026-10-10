--!nocheck
-- Offline quest and achievement simulation (docs/PHASE11_QUESTS.md section 6). Loads the server's
-- pure decision modules (Systems/QuestService/Rules.lua, Systems/AchievementService/Rules.lua,
-- Systems/MapService/Fog.lua) with Shared.Data and Shared.Config straight from src/, then checks:
--   - content: every quest's Giver / TurnIn / Marker / targets / reward items exist (quest points
--     per docs section 3, NPCs, Waystones and secrets from Tools/Layouts/Floor1, mobs, items,
--     dungeons, Guardians), text in Strings, Requires acyclic, the main story one chain
--   - every main, side, daily and weekly quest: accept -> GameEvents -> ready -> turn in, with
--     Sequential gating, state credit (Facts), and the totals of its rewards (all grantable; a
--     full bag refuses them)
--   - dailies / weeklies: deterministic per player and day, one per daily pool, UTC resets,
--     rerolls
--   - achievements: every one unlocks at its Count (including a "Prefix:*" key), Stat seeding,
--     titles
--   - the map fog bitset round-trips
-- Every check is an assert; the run prints a summary.
--
--   lune run tools/place/sim_quests.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

-- A minimal module runtime: src/ directories become instance-like tables `require` can load.
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

-- Random (Roblox) for item rolls: a seeded LCG is enough here.
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
	local sourcePath = node.__source
	assert(sourcePath, "not a module: " .. tostring(node.__path))
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
local Quests = requireNode(Shared.Data.Quests)
local Npcs = requireNode(Shared.Data.Npcs)
local Achievements = requireNode(Shared.Data.Achievements)
local Items = requireNode(Shared.Data.Items)
local Mobs = requireNode(Shared.Data.Mobs)
local Guardians = requireNode(Shared.Data.Guardians)
local InventoryRules = requireNode(Shared.Data.InventoryRules)
local Enums = requireNode(Shared.Enums)
local Config = requireNode(Shared.Config)
local Strings = requireNode(Shared.Strings)
local TableUtil = requireNode(Shared.Util.TableUtil)
local Template = requireNode(Systems.DataService.Template)
local Rules = requireNode(Systems.QuestService.Rules)
local ARules = requireNode(Systems.AchievementService.Rules)
local Fog = requireNode(Systems.MapService.Fog)

local Q = Config.Quests
local checks = 0
local function check(condition: boolean, message: string)
	checks += 1
	assert(condition, message)
end

local function sortedKeys(map): { string }
	local out = {}
	for key in map do
		table.insert(out, key)
	end
	table.sort(out)
	return out
end

local function set(list): { [string]: boolean }
	local out = {}
	for _, value in list do
		out[value] = true
	end
	return out
end

-- WORLD IDS --------------------------------------------------------------------------------------

-- Quest points: docs/PHASE11_QUESTS.md section 3 (Tools.Floor1Npcs builds them).
local POINTS = set({
	"TutorialStart", "TutorialMove", "TutorialSprint", "TutorialArena", "TutorialExit",
	"GuildSteps", "RotundaDoor", "LibraryDoor", "CathedralDoor", "MarketFountain", "OldWharf",
	"BrinehulkLagoon", "CisternMouth", "GateApproach",
	"CanalNorthFalls", "CanalSouthFalls", "CanalMouth",
})

-- Ids inside one `<header> {` ... `}` block of a source file (lines `<indent>Id = "<id>"`).
local function idsInBlock(source: string, header: string, indent: string): { string }
	local start = string.find(source, header, 1, true)
	assert(start, "no block " .. header)
	local stop = string.find(source, "\n}", start, true) or #source
	local block = string.sub(source, start, stop)
	local out = {}
	for id in string.gmatch(block, "\n" .. indent .. "Id = \"([%w_]+)\"") do
		table.insert(out, id)
	end
	for id in string.gmatch(block, "{ Id = \"([%w_]+)\"") do
		if not table.find(out, id) then
			table.insert(out, id)
		end
	end
	return out
end

local layoutSource = fs.readFile("src/ServerStorage/Tools/Layouts/Floor1.lua")
local WAYSTONES = set(idsInBlock(layoutSource, "Layout.Waystones = {", "\t"))
local SECRETS = set(idsInBlock(layoutSource, "Layout.Secrets = {", "\t\t"))
check(next(WAYSTONES) ~= nil and next(SECRETS) ~= nil, "Layouts/Floor1 lists Waystones and Secrets")

-- The world tool must build every documented point and every Floor 1 NPC marker.
local npcToolSource = fs.readFile("src/ServerStorage/Tools/Floor1Npcs.lua")
for _, id in sortedKeys(POINTS) do
	check(string.find(npcToolSource, "\t" .. id .. " = ", 1, true) ~= nil, `Floor1Npcs has no radius for point {id}`)
end
for _, id in sortedKeys(Npcs.All()) do
	check(Npcs.Get(id).Floor ~= "1" or string.find(npcToolSource, `"{id}"`, 1, true) ~= nil, `Floor1Npcs places no marker for {id}`)
end

local DO_EVENTS = set({ "Parry", "PerfectDodge", "Dodge", "Combo", "Cast", "Resonance", "Confluence" })
local KINDS = set({
	"Kill", "Collect", "Craft", "Discover", "Attune", "Clear", "Reach", "Talk", "Parry", "PerfectDodge",
	"Dodge", "Combo", "Cast", "Resonance", "Confluence", "LevelUp", "Region", "Gold", "Quest", "Death",
})
local ATTUNEMENTS = set(Enums.Attunement)

-- STATIC CONTENT CHECKS --------------------------------------------------------------------------

local function isMarker(id: string): boolean
	return POINTS[id] == true or Npcs.Get(id) ~= nil or WAYSTONES[id] == true
end

local function prefixed(target: string, prefix: string): string?
	if string.sub(target, 1, #prefix) == prefix then
		return string.sub(target, #prefix + 1)
	end
	return nil
end

local function checkTarget(id: string, index: number, objective)
	local where = `{id} objective {index}`
	local kind, target = objective.Type, objective.Target
	check(type(objective.Count) == "number" and objective.Count >= 1 and objective.Count % 1 == 0, `{where}: Count`)
	if objective.Type == "Do" then
		check(DO_EVENTS[objective.Event] == true, `{where}: Do Event '{tostring(objective.Event)}'`)
		return
	end
	if target == nil or target == "" then
		check(kind == "Kill" or kind == "Attune" or kind == "Craft" or kind == "Collect", `{where}: {kind} needs a Target`)
		return
	end
	if kind == "Kill" then
		check(Mobs.Get(target) ~= nil, `{where}: unknown mob {target}`)
	elseif kind == "Collect" or kind == "Craft" then
		check(Items.Get(target) ~= nil, `{where}: unknown item {target}`)
	elseif kind == "Discover" then
		local waystone, secret = prefixed(target, "Waystone:"), prefixed(target, "Secret:")
		check(
			target == "Waystone:*" or target == "Secret:*" or (waystone and WAYSTONES[waystone]) or (secret and SECRETS[secret]),
			`{where}: unknown discovery {target}`
		)
	elseif kind == "Attune" then
		check(ATTUNEMENTS[target] == true, `{where}: unknown attunement {target}`)
	elseif kind == "Clear" then
		local dungeon, guardian = prefixed(target, "Dungeon:"), prefixed(target, "Guardian:")
		check((dungeon and Config.Dungeons.Dungeons[dungeon]) or (guardian and Guardians.Get(guardian)), `{where}: unknown clear {target}`)
	elseif kind == "Reach" then
		check(POINTS[target] == true, `{where}: unknown quest point {target}`)
	elseif kind == "Talk" then
		check(Npcs.Get(target) ~= nil, `{where}: unknown npc {target}`)
	end
end

local allIds = sortedKeys(Quests.All())
local counts = { Main = 0, Side = 0, Daily = 0, Weekly = 0, Tutorial = 0 }
for _, id in allIds do
	local def = Quests.Get(id)
	counts[def.Kind] += 1
	check(def.Floor == "1", `{id}: Floor`)
	local text = Strings.Quests[id]
	check(text ~= nil and type(text.Name) == "string" and text.Name ~= "", `{id}: Strings.Quests entry with a Name`)
	check(type(text.Objectives) == "table" and #text.Objectives == #def.Objectives, `{id}: one Strings objective line per objective`)
	check(#def.Objectives >= 1, `{id}: has objectives`)
	if def.Giver then
		local giver = Npcs.Get(def.Giver)
		check(giver ~= nil, `{id}: unknown Giver {def.Giver}`)
		check(table.find(giver.Gives, id) ~= nil, `{id}: Npcs.{def.Giver}.Gives doesn't list it`)
	end
	if def.TurnIn then
		check(Npcs.Get(def.TurnIn) ~= nil, `{id}: unknown TurnIn {def.TurnIn}`)
	end
	if Rules.IsRepeatable(def) then
		check(def.Giver == nil and def.TurnIn == nil, `{id}: dailies / weeklies are rolled and complete on the spot`)
		check(def.Pool ~= nil, `{id}: repeatable without a Pool`)
		check((def.Kind == "Weekly") == (def.Pool == "Weekly"), `{id}: Pool matches Kind`)
	else
		check(def.Giver ~= nil, `{id}: a {def.Kind} quest needs a Giver (Give is for the tutorial hand-off)`)
		check(def.Pool == nil, `{id}: only repeatables have a Pool`)
	end
	for index, objective in def.Objectives do
		checkTarget(id, index, objective)
		if objective.Marker then
			check(isMarker(objective.Marker), `{id} objective {index}: unknown Marker {objective.Marker}`)
		end
	end
	for _, item in def.Rewards.Items or {} do
		check(Items.Get(item.Id) ~= nil, `{id}: unknown reward item {item.Id}`)
		check(item.Count >= 1 and item.Count % 1 == 0, `{id}: reward count {item.Id}`)
		check(item.Rarity == nil or table.find(Enums.Rarity, item.Rarity) ~= nil, `{id}: reward rarity {tostring(item.Rarity)}`)
	end
	check(def.Rewards.XP >= 0 and def.Rewards.Gold >= 0 and (def.Rewards.Shards or 0) >= 0, `{id}: rewards are non-negative`)
end
for _, npcId in sortedKeys(Npcs.All()) do
	check(Strings.Npcs[npcId] ~= nil and type(Strings.Npcs[npcId].Name) == "string", `Strings.Npcs.{npcId}.Name`)
	for _, questId in Npcs.Get(npcId).Gives do
		local def = Quests.Get(questId)
		check(def ~= nil and def.Giver == npcId, `Npcs.{npcId}.Gives {questId}, but its Giver is someone else`)
	end
end
check(counts.Main >= 10 and counts.Main <= 15, "10-15 main quests")
check(counts.Side >= 8 and counts.Side <= 12, "8-12 side quests")

-- Requires: known ids, acyclic, and the main story is one chain by Order.
local visiting, visited = {}, {}
local function walk(id: string, path: { string })
	check(not visiting[id], `Requires cycle: {table.concat(path, " -> ")} -> {id}`)
	if visited[id] then
		return
	end
	visiting[id] = true
	local def = Quests.Get(id)
	check(def ~= nil, `Requires names unknown quest {id}`)
	table.insert(path, id)
	for _, other in def.Requires or {} do
		walk(other, path)
	end
	table.remove(path)
	visiting[id] = nil
	visited[id] = true
end
for _, id in allIds do
	walk(id, {})
end
local mains = Quests.OfKind("Main", "1")
for position, id in mains do
	local def = Quests.Get(id)
	check(def.Order == position, `{id}: main Order {tostring(def.Order)} should be {position}`)
	local requires = def.Requires or {}
	if position == 1 then
		check(#requires == 0, `{id}: the first main quest requires nothing`)
	else
		check(#requires == 1 and requires[1] == mains[position - 1], `{id}: requires exactly the previous main quest`)
	end
	check(Rules.NextMain(id) == mains[position + 1], `{id}: NextMain`)
end
for _, id in allIds do
	local def = Quests.Get(id)
	for _, other in def.Requires or {} do
		local required = Quests.Get(other)
		check(not Rules.IsRepeatable(required), `{id} requires a repeatable quest {other}`)
		if def.Kind == "Main" then
			check(required.Kind == "Main", `{id}: a main quest requires side quest {other}`)
		end
	end
end

-- PLAYING EVERY QUEST ----------------------------------------------------------------------------

local NOW = 1760054400 -- 2025-10-10 00:00 UTC (a Friday)
local USER = 123456789

local function noFacts()
	return { Waystones = {}, Secrets = {}, Attunements = { "", "" }, Inside = {} }
end

-- Distinct real keys for a Target pattern (for "Prefix:*" and "any").
local function keysFor(objective, count: number): { string }
	local target = objective.Target
	local out = {}
	if objective.Type == "Discover" and target == "Waystone:*" then
		for _, id in sortedKeys(WAYSTONES) do
			table.insert(out, "Waystone:" .. id)
		end
	elseif objective.Type == "Discover" and target == "Secret:*" then
		for _, id in sortedKeys(SECRETS) do
			table.insert(out, "Secret:" .. id)
		end
	elseif target == nil or target == "" then
		local default = if objective.Type == "Kill" then "Bilgecrab" elseif objective.Type == "Attune" then "Tide" else ""
		for _ = 1, count do
			table.insert(out, default)
		end
	else
		for _ = 1, count do
			table.insert(out, target)
		end
	end
	check(#out >= (if objective.Type == "Discover" then count else 1), `not enough distinct keys for {tostring(target)}`)
	return out
end

-- The GameEvents actions that finish one objective: { kind, key, amount }.
local function actionsFor(objective): { { any } }
	local kind = if objective.Type == "Do" then objective.Event else objective.Type
	local out = {}
	if kind == "Collect" then
		table.insert(out, { kind, objective.Target, objective.Count }) -- one stack of Count
	elseif kind == "Resonance" or kind == "LevelUp" then
		table.insert(out, { kind, "", objective.Count })
	elseif kind == "Combo" then
		for _ = 1, objective.Count do
			table.insert(out, { kind, "", 4 })
		end
	else
		local keys = keysFor(objective, objective.Count)
		for n = 1, objective.Count do
			table.insert(out, { kind, keys[(n - 1) % #keys + 1], 1 })
		end
	end
	return out
end

-- Completed set for a quest: every quest it needs, recursively.
local function prerequisites(id: string, into: { [string]: number })
	for _, other in Quests.Get(id).Requires or {} do
		into[other] = NOW - 100
		prerequisites(other, into)
	end
	return into
end

local totals = {}
local function addTotals(kind: string, def)
	local t = Rules.RewardTotals(def)
	local bucket = totals[kind] or { XP = 0, Gold = 0, Shards = 0, Items = 0, Quests = 0 }
	totals[kind] = bucket
	bucket.XP += t.XP
	bucket.Gold += t.Gold
	bucket.Shards += t.Shards
	bucket.Items += t.Items
	bucket.Quests += 1
	local items = 0
	for _, item in def.Rewards.Items or {} do
		items += item.Count
	end
	check(t.Items == items and t.XP == def.Rewards.XP and t.Gold == def.Rewards.Gold and t.Shards == (def.Rewards.Shards or 0), "RewardTotals adds up")
end

-- Grants the rewards on a draft the way QuestService's complete() does; false + reason if refused.
local function grantRewards(data, def): (boolean, string?)
	for _, item in def.Rewards.Items or {} do
		local ok, why = InventoryRules.Grant(data, item.Id, item.Count, FakeRandom.new(3), item.Rarity)
		if not ok then
			return false, why
		end
	end
	InventoryRules.Earn(data, "Gold", def.Rewards.Gold)
	return true, nil
end

local fresh = TableUtil.DeepCopy(Template)
local full = TableUtil.DeepCopy(Template)
do
	-- Fill the bag with single gear pieces until it refuses one.
	local filler = "TideforgedLongsword"
	local refused = nil
	for _ = 1, 1000 do
		local ok, why = InventoryRules.Grant(full, filler, 1, FakeRandom.new(9), nil)
		if not ok then
			refused = why
			break
		end
	end
	check(refused == "Full", `a full bag refuses with Full (got {tostring(refused)})`)
end

local function playQuest(id: string)
	local def = Quests.Get(id)
	local book = { Active = {}, Completed = prerequisites(id, {}), Dailies = {}, Weeklies = {}, Rerolls = 0, DailyResetAt = NOW + 86400, WeeklyResetAt = NOW + 86400 }
	local giver = def.Giver or ""
	if Rules.IsRepeatable(def) then
		check(not Rules.CanAccept(id, book), `{id}: a repeatable can't be accepted from an NPC`)
		if def.Kind == "Daily" then
			book.Dailies = { id }
		else
			book.Weeklies = { id }
		end
		check(Rules.CanAcceptRolled(id, book), `{id}: today's roll can be (re)started`)
	else
		check(Rules.OfferedBy(def, giver), `{id}: offered by its Giver`)
		check(not Rules.OfferedBy(def, "Nobody"), `{id}: not offered by anyone else`)
		local ok, reason = Rules.CanAccept(id, book)
		check(ok, `{id}: can be accepted once its Requires are done ({tostring(reason)})`)
		if def.Requires and #def.Requires > 0 then
			local early = { Active = {}, Completed = {} }
			check(not Rules.CanAccept(id, early), `{id}: can't be accepted before its Requires`)
		end
	end
	local state = Rules.Start(def, NOW, giver, noFacts())
	book.Active[id] = state
	check(Rules.Stage(def, state) == state.Stage, `{id}: Stage is the first unfinished objective`)
	if not Rules.IsRepeatable(def) then
		check(not Rules.CanAccept(id, book), `{id}: can't be accepted twice`)
	end

	for index, objective in def.Objectives do
		-- Sequential: a later objective's actions do nothing before its turn.
		if def.Sequential and index < #def.Objectives and not Rules.IsDone(def, state, index) then
			local later = def.Objectives[index + 1]
			local snapshot = table.clone(state.Progress)
			local probe = actionsFor(later)[1]
			Rules.Feed(book, probe[1], probe[2], probe[3], nil)
			local same = Rules.Progress(state, index + 1) == (snapshot[tostring(index + 1)] or 0)
			check(same or Quests.Matches(objective, probe[1], probe[2]), `{id}: Sequential objective {index + 1} counted early`)
		end
		local actions = actionsFor(objective)
		for n, action in actions do
			check(not Rules.IsReady(def, state) or Rules.IsDone(def, state, index), `{id}: ready before objective {index} was done`)
			Rules.Feed(book, action[1], action[2], action[3], noFacts())
			if n < #actions then
				check(Rules.IsDone(def, state, index) == false or objective.Count == 1, `{id} objective {index}: done after {n} of {#actions} actions`)
			end
		end
		check(Rules.IsDone(def, state, index), `{id} objective {index} ({objective.Type} {tostring(objective.Target or objective.Event)}) didn't finish`)
		check(Rules.Progress(state, index) == objective.Count, `{id} objective {index}: progress is capped at Count`)
		-- Extra actions never push past Count.
		local extra = actions[1]
		Rules.Feed(book, extra[1], extra[2], extra[3], noFacts())
		check(Rules.Progress(state, index) == objective.Count, `{id} objective {index}: stays at Count`)
	end
	check(Rules.IsReady(def, state), `{id}: ready after every objective`)
	check(state.Stage == #def.Objectives + 1, `{id}: Stage past the last objective`)

	-- Turn in: at its TurnIn NPC (or on the spot), rewards granted whole or refused whole.
	local turnIn = def.TurnIn or ""
	check(Rules.TurnInAt(def, turnIn), `{id}: hands in at {turnIn}`)
	if def.TurnIn then
		check(not Rules.TurnInAt(def, ""), `{id}: can't be handed in without its NPC`)
	end
	local okGrant, why = grantRewards(TableUtil.DeepCopy(fresh), def)
	check(okGrant, `{id}: rewards fit a fresh bag ({tostring(why)})`)
	if def.Rewards.Items and #def.Rewards.Items > 0 then
		local refused, reason = grantRewards(TableUtil.DeepCopy(full), def)
		check(not refused and reason == "Full", `{id}: a full bag refuses the rewards (got {tostring(reason)})`)
	end
	check(Rules.Finish(book, id, NOW + 10), `{id}: Finish`)
	check(book.Active[id] == nil and book.Completed[id] == NOW + 10, `{id}: moved to Completed`)
	check(not Rules.Finish(book, id, NOW + 11), `{id}: can't be handed in twice`)
	if not Rules.IsRepeatable(def) then
		check(not Rules.CanAccept(id, book), `{id}: can't be accepted again once done`)
		if Rules.CanAbandon(def) then
			check(def.Kind == "Side", `{id}: only side quests (and repeatables) can be abandoned`)
		end
	else
		check(not Rules.CanAcceptRolled(id, book), `{id}: done for this period`)
	end
	addTotals(def.Kind, def)
end

for _, id in allIds do
	playQuest(id)
end

-- The whole main story in one profile, in order, each unlocking the next.
do
	local book = { Active = {}, Completed = {} }
	for position, id in mains do
		for later = position + 1, #mains do
			check(not Rules.CanAccept(mains[later], book), `{mains[later]} available before {id} is done`)
		end
		check(Rules.CanAccept(id, book), `{id}: available after the previous main quest`)
		local def = Quests.Get(id)
		local state = Rules.Start(def, NOW, def.Giver, noFacts())
		book.Active[id] = state
		for _, objective in def.Objectives do
			for _, action in actionsFor(objective) do
				Rules.Feed(book, action[1], action[2], action[3], noFacts())
			end
		end
		check(Rules.Finish(book, id, NOW), `{id}: finishes in the chain`)
	end
end

-- Accepting from the giver counts as talking to them; state objectives are credited on accept.
do
	local m01 = Quests.Get("F1_M01")
	check(Rules.IsReady(m01, Rules.Start(m01, NOW, "Brannoc", noFacts())), "F1_M01: talking to Brannoc to accept it is the Talk")
	check(not Rules.IsReady(m01, Rules.Start(m01, NOW, "", noFacts())), "F1_M01: given by the tutorial, it still needs the Talk")

	local facts = noFacts()
	facts.Waystones = { F1_ClimbersRest = true, F1_TidewatchSteps = true }
	check(Rules.IsReady(Quests.Get("F1_M03"), Rules.Start(Quests.Get("F1_M03"), NOW, "Ysolde", facts)), "F1_M03: known Waystones count on accept")
	facts.Attunements = { "Tide", "" }
	check(Rules.IsReady(Quests.Get("F1_M05"), Rules.Start(Quests.Get("F1_M05"), NOW, "Ysolde", facts)), "F1_M05: an existing Attunement counts")
	facts.Waystones.F1_ReedwardenPost = true
	local m06 = Quests.Get("F1_M06")
	local state = Rules.Start(m06, NOW, "Ysolde", facts)
	check(Rules.IsDone(m06, state, 1) and state.Stage == 2, "F1_M06: Sequential stage 1 credited from a known Waystone")

	-- A Sequential quest whose next stage is already true is credited when the stage moves.
	local m11 = Quests.Get("F1_M11")
	local book = { Active = {}, Completed = {} }
	book.Active.F1_M11 = Rules.Start(m11, NOW, "", noFacts())
	check(book.Active.F1_M11.Stage == 1, "F1_M11 given without its NPC starts at the Talk")
	local known = noFacts()
	known.Waystones = { F1_GateApproach = true }
	local moved = Rules.Feed(book, "Talk", "Ysolde", 1, known)
	check(#moved == 1 and moved[1].Ready, "F1_M11: the known Waystone is credited when the Talk moves the stage")

	-- Refresh on load credits Reach from where the player stands.
	local s10 = Quests.Get("F1_S10")
	local sbook = { Active = { F1_S10 = Rules.Start(s10, NOW, "Fen", noFacts()) }, Completed = {} }
	local inside = noFacts()
	inside.Inside = { CanalMouth = true }
	local refreshed = Rules.Refresh(sbook, inside)
	check(#refreshed == 1 and Rules.Progress(sbook.Active.F1_S10, 3) == 1, "Refresh credits a Reach the player stands in")

	-- Repair clamps a damaged save.
	local broken = { Stage = 9, Progress = { ["1"] = 999, junk = 4 }, StartedAt = "x" }
	check(Rules.Repair(Quests.Get("F1_M04"), broken), "Repair reports a change")
	check(broken.Progress["1"] == 6 and broken.Progress.junk == nil and broken.Stage == 2 and broken.StartedAt == 0, "Repair clamps and recomputes")
end

-- The quest log limit.
do
	local book = { Active = {}, Completed = {} }
	local filled = 0
	for _, id in allIds do
		local def = Quests.Get(id)
		if Rules.CountsTowardLimit(def) then
			book.Active[id] = Rules.NewState(def, NOW)
			filled += 1
		end
	end
	check(Rules.ActiveCount(book) == filled, "ActiveCount counts main and side quests")
	for _, id in Quests.OfKind("Daily") do
		book.Active[id] = Rules.NewState(Quests.Get(id), NOW)
	end
	check(Rules.ActiveCount(book) == filled, "dailies don't count toward MaxActive")
	check(filled < Q.MaxActive, "every main and side quest fits in the log at once")
end

-- DAILIES AND WEEKLIES ---------------------------------------------------------------------------

do
	local day = Rules.DayIndex(NOW)
	local seen = {}
	for _, pool in Rules.DailyPools do
		seen[pool] = {}
		check(#Quests.InPool(pool) >= 2, `daily pool {pool} has at least two quests (rerolls need one more)`)
	end
	check(#Quests.InPool(Rules.WeeklyPool) >= Q.WeeklyCount, "the weekly pool covers WeeklyCount")
	for user = 1, 40 do
		for d = day, day + 30 do
			local roll = Rules.RollDailies(user, d)
			local again = Rules.RollDailies(user, d)
			check(#roll == Q.DailyCount, "DailyCount dailies")
			for index, id in roll do
				check(again[index] == id, "dailies are deterministic")
				local def = Quests.Get(id)
				check(def.Kind == "Daily" and def.Pool == Rules.DailyPools[index], "one daily from each pool, in order")
				seen[def.Pool][id] = true
			end
		end
		local weekly = Rules.RollWeeklies(user, Rules.WeekIndex(NOW))
		check(#weekly == Q.WeeklyCount and weekly[1] ~= weekly[2], "WeeklyCount distinct weeklies")
		for _, id in weekly do
			check(Quests.Get(id).Kind == "Weekly", "weeklies come from the weekly pool")
		end
	end
	for _, pool in Rules.DailyPools do
		for _, id in Quests.InPool(pool) do
			check(seen[pool][id], `daily {id} is rolled at some point`)
		end
	end
	local differs = false
	for d = day, day + 6 do
		local a, b = Rules.RollDailies(USER, d), Rules.RollDailies(USER, d + 1)
		if table.concat(a, ",") ~= table.concat(b, ",") then
			differs = true
		end
	end
	check(differs, "dailies change from day to day")
	check(Rules.Hash({ 1, 2, 3 }) == Rules.Hash({ 1, 2, 3 }) and Rules.Hash({ 1, 2, 3 }) ~= Rules.Hash({ 3, 2, 1 }), "Hash is stable and order-sensitive")

	-- Reset times: dailies at DailyResetHourUTC, weeklies on WeeklyResetWeekdayUTC.
	local book = { Active = {}, Completed = {}, Dailies = {}, Weeklies = {}, Rerolls = 3, DailyResetAt = 0, WeeklyResetAt = 0 }
	local t = NOW + 5 * 3600 + 17
	local daily, weekly = Rules.RollDue(book, USER, t, noFacts())
	check(daily and weekly, "a new profile rolls both")
	check(book.Rerolls == 0, "rerolls reset with the dailies")
	local dr = os.date("!*t", book.DailyResetAt)
	check(dr.hour == Q.DailyResetHourUTC and dr.min == 0 and dr.sec == 0, "dailies reset at the UTC hour")
	check(book.DailyResetAt > t and book.DailyResetAt <= t + 86400, "the next daily reset is within a day")
	local wr = os.date("!*t", book.WeeklyResetAt)
	check(wr.wday == Q.WeeklyResetWeekdayUTC and wr.hour == Q.DailyResetHourUTC and wr.min == 0, "weeklies reset on the UTC weekday")
	check(book.WeeklyResetAt > t and book.WeeklyResetAt <= t + 7 * 86400, "the next weekly reset is within a week")
	for _, id in book.Dailies do
		check(book.Active[id] ~= nil, `rolled daily {id} starts on its own`)
	end
	for _, id in book.Weeklies do
		check(book.Active[id] ~= nil, `rolled weekly {id} starts on its own`)
	end
	check(table.concat(book.Dailies, ",") == table.concat(Rules.RollDailies(USER, Rules.DayIndex(t)), ","), "the roll is the player's deterministic roll")
	local d2, w2 = Rules.RollDue(book, USER, t + 60, noFacts())
	check(not d2 and not w2, "nothing rolls again inside the period")

	-- Reroll: one a day, same pool, never today's other quests; a done daily can't be rerolled.
	local old = book.Dailies[1]
	local pick, why = Rules.Reroll(book, USER, t + 70, old, noFacts())
	check(pick ~= nil and pick ~= old, `reroll picks another daily ({tostring(why)})`)
	check(Quests.Get(pick).Pool == Quests.Get(old).Pool, "a reroll stays in its pool")
	check(book.Active[old] == nil and book.Active[pick] ~= nil and book.Dailies[1] == pick, "the reroll replaces it")
	check(book.Rerolls == 1, "a reroll is counted")
	local copy = { Active = {}, Completed = {}, Dailies = Rules.RollDailies(USER, Rules.DayIndex(t)), Weeklies = {}, Rerolls = 0, DailyResetAt = book.DailyResetAt, WeeklyResetAt = book.WeeklyResetAt }
	check(Rules.Reroll(copy, USER, t + 999, old, nil) == pick, "rerolls are deterministic too")
	local second, reason = Rules.Reroll(book, USER, t + 80, book.Dailies[2], noFacts())
	check(second == nil and reason == (if Q.DailyRerolls <= 1 then "NoRerolls" else reason), "rerolls are limited per day")
	local doneBook = { Active = {}, Completed = { [book.Dailies[3]] = t }, Dailies = table.clone(book.Dailies), Weeklies = {}, Rerolls = 0, DailyResetAt = book.DailyResetAt, WeeklyResetAt = book.WeeklyResetAt }
	check(Rules.Reroll(doneBook, USER, t, book.Dailies[3], nil) == nil, "a finished daily can't be rerolled")
	check(Rules.Reroll(doneBook, USER, t, "F1_M01", nil) == nil, "only today's dailies can be rerolled")

	-- Finish one, then the next day: last period's quests leave Active and Completed.
	local first = book.Dailies[2]
	local def = Quests.Get(first)
	for _, objective in def.Objectives do
		for _, action in actionsFor(objective) do
			Rules.Feed(book, action[1], action[2], action[3], noFacts())
		end
	end
	check(Rules.Finish(book, first, t + 100), "a daily finishes on the spot")
	check(not Rules.CanAcceptRolled(first, book), "a finished daily can't restart this period")
	local d3 = Rules.RollDue(book, USER, book.DailyResetAt, noFacts())
	check(d3, "the dailies roll at the reset")
	check(book.Completed[first] == nil, "yesterday's completed daily is cleared")
	for id, _ in book.Active do
		local kind = Quests.Get(id).Kind
		check(kind ~= "Daily" or table.find(book.Dailies, id) ~= nil, "only today's dailies are active")
	end
	check(book.Rerolls == 0, "rerolls come back at the reset")

	-- Abandoned dailies can be restarted from the log.
	local again = book.Dailies[1]
	book.Active[again] = nil
	check(Rules.CanAcceptRolled(again, book), "an abandoned daily can be restarted")
	check(not Rules.CanAcceptRolled("F1_DK01", { Active = {}, Completed = {}, Dailies = {}, Weeklies = {}, Rerolls = 0 }) , "a daily not rolled today can't be started")
end

-- ACHIEVEMENTS -----------------------------------------------------------------------------------

do
	local stats = Template.PlayStats
	local prefixKeys = 0
	for _, id in Achievements.Ordered() do
		local def = Achievements.Get(id)
		local text = Strings.Achievements.List[id]
		check(text ~= nil and type(text.Name) == "string" and type(text.Description) == "string", `Strings.Achievements.List.{id}`)
		if def.Title then
			check(type(Strings.Achievements.Titles[id]) == "string", `Strings.Achievements.Titles.{id}`)
		end
		check(KINDS[def.Event] == true, `{id}: unknown Event {def.Event}`)
		check(def.Stat == nil or stats[def.Stat] ~= nil, `{id}: unknown PlayStats field {tostring(def.Stat)}`)
		check(def.Count >= 1 and def.Shards >= 0, `{id}: Count and Shards`)
		local key = def.Key or ""
		if string.sub(key, -1) == "*" then
			prefixKeys += 1
		end

		-- Feed matching actions one at a time: it unlocks exactly at Count.
		local progress, unlocked = {}, {}
		local facts = { Stats = {}, Level = 1 }
		local probe = { Type = if def.Event == "Discover" then "Discover" else def.Event, Target = key }
		local keys = if def.Event == "Discover" and string.sub(key, -1) == "*" then keysFor(probe, def.Count) else { if key == "*" then "" else key }
		local steps = if def.Event == "LevelUp" or def.Event == "Gold" then 1 else def.Count
		local amount = if def.Event == "LevelUp" or def.Event == "Gold" then def.Count else (if def.Event == "Combo" then 4 else 1)
		local unlockedAt = nil
		for n = 1, steps do
			local outcome = ARules.Feed(progress, unlocked, def.Event, keys[(n - 1) % #keys + 1], amount, facts)
			if table.find(outcome.Unlocked, id) then
				unlockedAt = n
				unlocked[id] = NOW
				progress[id] = nil
				break
			end
			check(table.find(outcome.Progressed, id) ~= nil, `{id}: action {n} counts`)
		end
		check(unlockedAt == steps, `{id}: unlocks at its Count ({tostring(unlockedAt)} of {steps})`)
		local after = ARules.Feed(progress, unlocked, def.Event, keys[1], amount, facts)
		check(table.find(after.Unlocked, id) == nil, `{id}: unlocks once`)
		check(ARules.CanWearTitle(id, unlocked) == (def.Title == true), `{id}: title wearable once unlocked iff it grants one`)
		check(not ARules.CanWearTitle(id, {}), `{id}: no title before unlocking`)
	end
	check(prefixKeys >= 1, "at least one achievement uses a Prefix:* key")

	-- The prefix key counts every Waystone and nothing else.
	local progress = {}
	local before = ARules.Feed(progress, {}, "Discover", "Secret:F1_SmugglersCove", 1, { Stats = {}, Level = 1 })
	check(progress.WaystoneWanderer == nil and table.find(before.Unlocked, "SmugglersFriend") ~= nil, "a secret isn't a Waystone; its own achievement unlocks")
	ARules.Feed(progress, {}, "Discover", "Waystone:F1_RustwoodCamp", 1, { Stats = {}, Level = 1 })
	check(progress.WaystoneWanderer == 1, "Waystone:* counts a Waystone")

	-- Seeding from PlayStats and level on join.
	local seeded = {}
	local outcome = ARules.SeedAll(seeded, {}, { Stats = { Parries = 150, Kills = 3, Deaths = 4 }, Level = 10 })
	local unlockedSet = set(outcome.Unlocked)
	check(unlockedSet.ParryMaster and unlockedSet.FirstBlood and unlockedSet.Level5 and unlockedSet.Level10, "Stat and level seeding unlock on join")
	check(not unlockedSet.Level12 and seeded.Level12 == 10, "Level12 is seeded to the level")
	check(seeded.TideTaken == 4, "Deaths seed TideTaken")
	check(ARules.TitlePath("ParryMaster") == "Achievements.Titles.ParryMaster" and ARules.TitlePath("") == "", "TitlePath")
	check(ARules.CanWearTitle("", {}), "no title is always allowed")
	check(not ARules.CanWearTitle("FirstBlood", { FirstBlood = NOW }), "an achievement without a title can't be worn")
end

-- MAP FOG ----------------------------------------------------------------------------------------

do
	local cells = Q.Map.Cells
	local square = Config.World.Maps["1"]
	check(square ~= nil and square.Size > 0, "Config.World.Maps['1'] has a map square")
	local grid = Fog.Decode("", cells)
	check(#grid == Fog.Digits(cells) and Fog.Encode(grid) == "", "an empty grid encodes as ''")
	local row, col = Fog.Cell(square.Center.X, square.Center.Y, square.Center.X, square.Center.Y, square.Size, cells)
	check(row == cells / 2 and col == cells / 2, "the map centre is the middle cell")
	check(Fog.Reveal(grid, cells, row, col, Q.Map.RevealRadius), "the first reveal is new")
	check(not Fog.Reveal(grid, cells, row, col, Q.Map.RevealRadius), "the same reveal again writes nothing")
	local hex = Fog.Encode(grid)
	check(#hex == Fog.Digits(cells), "a hex digit per four cells")
	local back = Fog.Decode(hex, cells)
	local revealed = 0
	for r = 0, cells - 1 do
		for c = 0, cells - 1 do
			if Fog.IsSet(back, cells, r, c) then
				revealed += 1
			end
		end
	end
	check(revealed == (2 * Q.Map.RevealRadius + 1) ^ 2, "a 3x3 block round-trips")
	check(Fog.Reveal(back, cells, 0, 0, 1), "a corner reveal clips at the edge")
	local outside = Fog.Cell(square.Center.X + square.Size, square.Center.Y, square.Center.X, square.Center.Y, square.Size, cells)
	check(outside == nil, "outside the map square there is no cell")
	check(#Fog.Decode("zz", cells) == Fog.Digits(cells), "a malformed save decodes as unexplored")
end

-- SUMMARY ----------------------------------------------------------------------------------------

print(`Quest simulation: {checks} checks passed`)
print(`  quests: {counts.Main} main, {counts.Side} side, {counts.Daily} daily, {counts.Weekly} weekly`)
for _, kind in { "Main", "Side", "Daily", "Weekly" } do
	local t = totals[kind]
	if t then
		print(`  {kind}: {t.Quests} quests, {t.XP} XP, {t.Gold} gold, {t.Shards} Shards, {t.Items} items`)
	end
end
print(`  achievements: {#Achievements.Ordered()}; waystones {#sortedKeys(WAYSTONES)}, secrets {#sortedKeys(SECRETS)}, points {#sortedKeys(POINTS)}`)
