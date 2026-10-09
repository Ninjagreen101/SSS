--!nocheck
-- Offline Guardian fight simulation (docs/PHASE10_GUARDIAN.md section 5). Loads GuardianService's
-- pure decision module (Systems/GuardianService/Rules.lua) with Shared.Data.Guardians and
-- Shared.Config.Mobs straight from src/, then drives scripted fights for 1, 4 and 8 players:
-- phase gates and the health clamp, move choice per phase, party scaling, the tide schedule and
-- the reward share. Every check is an assert; the run prints a summary.
--
--   lune run tools/place/sim_guardian.luau [guardianId] [seed]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local GUARDIAN = process.args[1] or "Brinewarden"
local SEED = tonumber(process.args[2] or "") or 1001

-- A minimal module runtime: src/ directories become instance-like tables `require` can load.
-- (The tree is read up front: Lune's file calls can't run inside metamethods.)
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
		Vector3 = roblox.Vector3,
		Color3 = roblox.Color3,
		CFrame = roblox.CFrame,
		Enum = roblox.Enum,
	}, { __index = _G })
	local result = luau.load(fs.readFile(sourcePath), { debugName = sourcePath, environment = env })()
	cache[node] = result
	return result
end

local Shared = services.ReplicatedStorage.Shared
local Rules = requireNode(services.ServerScriptService.Systems.GuardianService.Rules)
local Guardians = requireNode(Shared.Data.Guardians)
local MobsConfig = requireNode(Shared.Config.Mobs)
local Vector3 = roblox.Vector3

local G = MobsConfig.Guardian
local def = Guardians.Get(GUARDIAN)
assert(def, "unknown Guardian " .. GUARDIAN)

local checks = 0
local function check(condition: boolean, message: string)
	checks += 1
	assert(condition, message)
end

-- STATIC CHECKS ----------------------------------------------------------------------------------

local moveIds = {}
for id in def.Moves do
	table.insert(moveIds, id)
end
table.sort(moveIds)

for _, id in moveIds do
	local move = def.Moves[id]
	for phase = 1, Rules.PhaseCount() do
		if Rules.InPhase(move, phase) then
			local telegraph = Rules.Telegraph(def, move, phase)
			check(telegraph >= G.MinTelegraph - 1e-9, `{id} phase {phase}: telegraph {telegraph} < MinTelegraph`)
			if #move.Blows > 1 then
				local interval = Rules.Interval(def, move, phase)
				check(interval >= G.MinTelegraph - 1e-9, `{id} phase {phase}: blow interval {interval} < MinTelegraph`)
			end
		end
	end
end

-- Health clamp: a single blow far bigger than the phase can never skip a phase.
for _, players in { 1, 4, 8 } do
	local maxHealth = Rules.MaxHealth(def, players)
	local health, phase = maxHealth, 1
	local seen = { 1 }
	for _ = 1, 10 do
		health = Rules.ClampHealth(health - maxHealth * 0.9, phase, maxHealth)
		local nextPhase = Rules.NextPhase(health, phase, maxHealth)
		if nextPhase then
			check(nextPhase == phase + 1, "phases advance one at a time")
			local threshold = G.PhaseThresholds[nextPhase]
			check(math.abs(health - threshold * maxHealth) < 1, `clamped at the {threshold} threshold`)
			phase = nextPhase
			table.insert(seen, phase)
		end
	end
	check(#seen == Rules.PhaseCount(), `{players}p: burst still visits every phase`)
	check(health == 0 and phase == Rules.PhaseCount(), `{players}p: only the last phase can reach 0`)
end

-- Reward share.
check(Rules.Eligible(G.ContributionDamage * 10000, 10000, 0), "damage share qualifies")
check(Rules.Eligible(0, 10000, G.ContributionSeconds), "time inside qualifies")
check(not Rules.Eligible(G.ContributionDamage * 10000 - 1, 10000, G.ContributionSeconds - 1), "neither: no share")

-- Geometry.
local origin = Vector3.new(0, 0, 0)
local forward = Vector3.new(0, 0, -1)
check(Rules.InLine(origin, forward, 34, 7, Vector3.new(3, 5, -30), 0), "inside the cleave line")
check(not Rules.InLine(origin, forward, 34, 7, Vector3.new(4, 0, -30), 0), "beside the cleave line")
check(not Rules.InLine(origin, forward, 34, 7, Vector3.new(0, 0, 5), 0), "behind the cleave line")
check(Rules.InCone(origin, forward, 11, 60, Vector3.new(2, 0, -8), 0), "inside the grab cone")
check(not Rules.InCone(origin, forward, 11, 60, Vector3.new(8, 0, -2), 0), "outside the grab cone")
check(Rules.IsBehind(origin, forward, Vector3.new(1, 0, 3)), "behind")
check(math.abs(Rules.ClipToCircle(origin, forward, 200, origin, 70) - 70) < 1e-6, "charge clipped at the wall")
check(math.abs(Rules.SegmentDistance(Vector3.new(0, 0, 0), Vector3.new(0, 0, -10), Vector3.new(3, 0, -5)) - 3) < 1e-6, "segment distance")
local aims = Rules.LanceAims(origin, { Vector3.new(0, 0, -20) }, 3, 5, forward)
check(#aims == 3 and aims[1].Z < -0.99 and aims[2].X > 0 and aims[3].X < 0, "extra lances fan out either side")

-- FIGHT SIMULATION -------------------------------------------------------------------------------

local DT = 0.1 -- the server loop runs at 10 Hz
-- Party model: sustained damage per level-12 member (light combos ~25-30 a hit with stamina
-- breaks, dodging and repositioning, spells and the odd weak-point hit), plus finisher bursts.
local PLAYER_DPS = 30
local REAL_BURST = { Every = 30, Fraction = 0.03 } -- a posture-break finisher now and then
local STRESS_BURST = { Every = 12, Fraction = 0.45 } -- absurd bursts: the clamp must still hold
local FIGHTS = 25 -- realistic fights per party size for the move histogram

-- Where the target stands, flat studs from the Warden: mostly in melee, sometimes kiting.
local function targetDistance(): number
	local roll = math.random()
	if roll < 0.7 then
		return 3 + math.random() * 12
	elseif roll < 0.9 then
		return 15 + math.random() * 15
	end
	return 30 + math.random() * 30
end

local function simulate(players: number, seed: number, burst)
	math.randomseed(seed)
	local maxHealth = Rules.MaxHealth(def, players)
	local health = maxHealth
	local phase = 1
	local t = 0
	local startedAt = def.Intro
	local dormantUntil = startedAt
	local nextMoveAt = startedAt
	local busyUntil = 0
	local cooldowns = {}
	local lastMove, repeats = nil, 0
	local adds = {} -- times they die
	local tide = Rules.CalmTide()
	local tideLog = {}
	local phaseLog = {}
	local histogram = { {}, {}, {} }
	local clamps = 0
	local nextBurst = startedAt + burst.Every
	local surges = 0
	local lastWarnAt = nil
	local lastChangeAt = nil

	while health > 0 and t < 3600 do
		t += DT
		-- tide
		local event = Rules.TickTide(def, tide, t)
		if event == "Warn" then
			lastWarnAt = t
			table.insert(tideLog, string.format("%6.1f warn -> %s", t, Rules.NextTide(tide.State)))
		elseif event == "Change" then
			check(lastWarnAt ~= nil and t - lastWarnAt >= def.Tide.WarnSeconds - DT - 1e-6, `tide turned at {t} without a full tell`)
			if lastChangeAt then
				local held = t - lastChangeAt
				check(held >= def.Tide.WarnSeconds - DT, "a tide lasts at least its tell")
			end
			lastWarnAt = nil
			lastChangeAt = t
			table.insert(tideLog, string.format("%6.1f %s until %.1f", t, tide.State, tide.EndsAt))
		end
		-- adds die off
		for index = #adds, 1, -1 do
			if t >= adds[index] then
				table.remove(adds, index)
			end
		end
		-- party damage (nothing lands while it is dormant: intro and transitions grant i-frames)
		if t >= dormantUntil then
			local damage = PLAYER_DPS * players * DT * (0.5 + math.random())
			if t >= nextBurst then
				nextBurst = t + burst.Every
				damage += maxHealth * burst.Fraction
			end
			health -= damage
			local floor = Rules.HealthFloor(phase, maxHealth)
			if health < floor then
				health = floor
				clamps += 1
			end
			local nextPhase = Rules.NextPhase(health, phase, maxHealth)
			if nextPhase then
				check(nextPhase == phase + 1, "one phase at a time")
				phase = nextPhase
				table.insert(phaseLog, string.format("%6.1f phase %d at %.0f%% health", t, phase, health / maxHealth * 100))
				check(math.abs(health / maxHealth - G.PhaseThresholds[phase]) < 1e-3, "phase starts exactly at its threshold")
				dormantUntil = t + def.Transition
				busyUntil = 0 -- the running move is cancelled
				nextMoveAt = math.max(nextMoveAt, dormantUntil)
				if Rules.TideRuns(def, phase) and tide.State == "Calm" then
					tide = Rules.StartTide(def, t, def.Transition)
					lastChangeAt = t
					table.insert(tideLog, string.format("%6.1f %s until %.1f (phase %d)", t, tide.State, tide.EndsAt, phase))
				end
			end
		end
		-- the Warden's next move
		if t >= dormantUntil and t >= busyUntil and t >= nextMoveAt then
			local behind = {}
			for _ = 1, math.random(0, math.max(0, players - 1)) do
				table.insert(behind, math.random() * 24)
			end
			local alive = #adds
			local ctx = {
				Phase = phase,
				Now = t,
				Distance = targetDistance(),
				Cooldowns = cooldowns,
				LastMove = lastMove,
				Repeats = repeats,
				TargetBlocking = math.random() < 0.3,
				Behind = behind,
				TideRunning = tide.State ~= "Calm",
				TideChanging = Rules.TideChanging(def, tide, t, 0),
				AddsAlive = alive,
				AddsWanted = Rules.AddCount(def, players),
			}
			local option = Rules.Choose(def, ctx, math.random())
			if option then
				local move = option.Move
				check(Rules.InPhase(move, phase), `{option.Id} used in phase {phase}`)
				check(not (lastMove == option.Id and repeats >= Rules.MaxRepeats), `{option.Id} used 3 times in a row`)
				check(ctx.Distance >= move.MinRange and ctx.Distance <= move.MaxRange, `{option.Id} out of range`)
				histogram[phase][option.Id] = (histogram[phase][option.Id] or 0) + 1
				cooldowns[option.Id] = t + move.Cooldown
				if lastMove == option.Id then
					repeats += 1
				else
					lastMove, repeats = option.Id, 1
				end
				local telegraph = Rules.Telegraph(def, move, phase)
				local busy = telegraph + Rules.Interval(def, move, phase) * (#move.Blows - 1) + move.Recovery
				if move.Kind == "Grab" then
					busy += (move.Hold or 0) + move.HitStun
				elseif move.Kind == "Summon" then
					for _ = 1, Rules.AddCount(def, players) - alive do
						table.insert(adds, t + math.min(def.Adds.Lifetime, 8 + math.random() * 20))
					end
				elseif move.Kind == "Surge" then
					check(Rules.ForceTide(def, tide, t, telegraph), "Tide Surge only when the tide can turn")
					surges += 1
					lastWarnAt = t
					table.insert(tideLog, string.format("%6.1f warn -> %s (Surge)", t, Rules.NextTide(tide.State)))
				end
				busyUntil = t + busy
				nextMoveAt = busyUntil + Rules.MoveGap(def, phase, math.random())
			end
		end
	end
	check(health <= 0, `{players}p: the fight ends`)
	check(#phaseLog == Rules.PhaseCount() - 1, `{players}p: every phase gate crossed once`)
	return {
		Players = players,
		MaxHealth = maxHealth,
		Seconds = t - startedAt,
		Phases = phaseLog,
		Histogram = histogram,
		Tide = tideLog,
		Clamps = clamps,
		Surges = surges,
	}
end

print(string.format("Guardian %s: BaseHealth %d, thresholds %s, MinTelegraph %.2f, %d dps per member",
	GUARDIAN, def.BaseHealth, table.concat(G.PhaseThresholds, "/"), G.MinTelegraph, PLAYER_DPS))
for _, players in { 1, 4, 8 } do
	-- the clamp under absurd burst damage
	local stress = simulate(players, SEED * 7 + players, STRESS_BURST)
	-- realistic fights: one timeline shown, moves counted over all of them
	local results = {}
	local totals = { {}, {}, {} }
	local seconds = 0
	for index = 1, FIGHTS do
		local result = simulate(players, SEED + players * 1000 + index, REAL_BURST)
		table.insert(results, result)
		seconds += result.Seconds
		for phase = 1, Rules.PhaseCount() do
			for id, count in result.Histogram[phase] do
				totals[phase][id] = (totals[phase][id] or 0) + count
			end
		end
	end
	local result = results[1]
	print(string.rep("-", 78))
	print(string.format("%d player(s): max health %d, adds %d, lances %d, whirlpools %d",
		players, result.MaxHealth, Rules.AddCount(def, players), Rules.LanceCount(def.Moves.WaterLances, players),
		Rules.PoolCount(def.Moves.Undertow, players)))
	print(string.format("  fight length (after the intro): mean %.0fs over %d fights; stress run clamped %d time(s), phases %s",
		seconds / FIGHTS, FIGHTS, stress.Clamps, table.concat(stress.Phases, " |")))
	for _, line in result.Phases do
		print("  " .. line)
	end
	for phase = 1, Rules.PhaseCount() do
		local parts = {}
		for _, id in moveIds do
			local count = totals[phase][id]
			if count then
				table.insert(parts, `{id} {count}`)
			end
			if not Rules.InPhase(def.Moves[id], phase) then
				check(count == nil, `{id} must not appear in phase {phase}`)
			end
		end
		print(string.format("  phase %d moves (%d fights): %s", phase, FIGHTS, table.concat(parts, ", ")))
	end
	print(string.format("  tide (fight 1, %d Tide Surge(s)):", result.Surges))
	for index, line in result.Tide do
		if index > 8 then
			print(string.format("    ... %d more", #result.Tide - 8))
			break
		end
		print("    " .. line)
	end
end
print(string.rep("-", 78))
print(string.format("all %d checks passed", checks))
