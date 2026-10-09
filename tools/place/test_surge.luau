--!nocheck
-- Offline test of the sprint Surge state machine (Systems/SurgeState.lua) with the real
-- Config.Combat tuning loaded from src/. Steps it at the server vitals tick rate through:
-- charge -> Surge, a hit cancels and resets, stopping the sprint resets, a combat mark stops
-- the charge, short stops are forgiven, and the out-of-combat stamina budget reaches a Surge.
-- Every check is an assert; the run prints a summary.
--
--   lune run tools/place/test_surge.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

-- Minimal module runtime (same idea as sim_guardian.luau): src/ folders become
-- instance-like tables that `require` can load.
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
local Combat = requireNode(Shared.Config.Combat)
local SurgeState = requireNode(Systems.SurgeState)

local SURGE = Combat.Surge
local TUNING = {
	ChargeSeconds = SURGE.ChargeSeconds,
	StopGrace = SURGE.StopGrace,
	CombatTimeout = Combat.Vitals.CombatTimeout,
}
local DT = 1 / Combat.Vitals.TickRate
local START = 1000 -- server time at the start of each case; LastCombat 0 = long ago

local passed = 0
local function case(name: string, body: () -> ())
	body()
	passed += 1
	print(`  ok  {name}`)
end

-- Steps `seconds` of ticks; returns the time reached and the first event seen.
local function run(state, t: number, seconds: number, sprinting: boolean, moving: boolean, lastCombat: number)
	local first = nil
	local ticks = math.floor(seconds / DT + 0.5)
	for _ = 1, ticks do
		t += DT
		local event = SurgeState.Step(state, TUNING, DT, sprinting, moving, t, lastCombat)
		if event and not first then
			first = event
		end
	end
	return t, first
end

print(`SurgeState: charge {SURGE.ChargeSeconds}s, speed {SURGE.Speed}, tick {DT}s`)

case("tuning sanity", function()
	assert(SURGE.Speed > Combat.Movement.SprintSpeed, "Surge must be faster than a sprint")
	assert(SURGE.ChargeSeconds == 10, "brief: 10 s charge")
	assert(SURGE.OutOfCombatCostMultiplier > 0 and SURGE.OutOfCombatCostMultiplier < 1)
end)

case("charge 10 s -> Surge", function()
	local s = SurgeState.new()
	local t, event = run(s, START, SURGE.ChargeSeconds - 0.5, true, true, 0)
	assert(event == nil and not s.Surging, "no Surge before the charge completes")
	t, event = run(s, t, 0.6, true, true, 0)
	assert(event == "Started" and s.Surging, "Surge starts at the charge")
	t, event = run(s, t, 5, true, true, 0)
	assert(event == nil and s.Surging, "Surge holds while sprinting on")
end)

case("hit cancels and resets", function()
	local s = SurgeState.new()
	local t = run(s, START, SURGE.ChargeSeconds + 0.2, true, true, 0)
	assert(s.Surging)
	-- VitalsService breaks the Surge the moment damage lands (enterCombat -> Cancel)...
	assert(SurgeState.Cancel(s) == "Ended", "Cancel reports the end")
	assert(not s.Surging and s.Charge == 0, "charge reset")
	-- ...and the stamped LastCombat keeps the charge at 0 for the combat timeout.
	local hitAt = t
	local event
	t, event = run(s, t, TUNING.CombatTimeout - 0.5, true, true, hitAt)
	assert(event == nil and s.Charge == 0 and not s.Surging, "no charge while in combat")
	t = run(s, t, 1, true, true, hitAt)
	assert(s.Charge > 0 and s.Charge < 1, "charge restarts from 0 once out of combat")
	t, event = run(s, t, SURGE.ChargeSeconds, true, true, hitAt)
	assert(event == "Started", "a full new charge is needed")
end)

case("hit during the charge resets it", function()
	local s = SurgeState.new()
	local t = run(s, START, 8, true, true, 0)
	assert(s.Charge > 7.9)
	local event
	t, event = run(s, t, DT, true, true, t) -- LastCombat stamped this tick
	assert(event == nil and s.Charge == 0, "in-combat step resets the charge")
end)

case("stop sprint -> reset", function()
	local s = SurgeState.new()
	local t = run(s, START, SURGE.ChargeSeconds + 1, true, true, 0)
	assert(s.Surging)
	local event
	t, event = run(s, t, DT, false, true, 0)
	assert(event == "Ended" and not s.Surging and s.Charge == 0, "letting go of sprint ends it")
	t = run(s, t, 6, true, true, 0)
	assert(not s.Surging and s.Charge > 5.9 and s.Charge < 6.1, "charge counts again from 0")
end)

case("combat mark -> no charge", function()
	local s = SurgeState.new()
	local markedAt = START
	local early, none = run(s, START, TUNING.CombatTimeout + SURGE.ChargeSeconds - 0.5, true, true, markedAt)
	assert(none == nil, "the first CombatTimeout seconds don't count")
	local t, event = run(s, early, 1, true, true, markedAt)
	assert(event == "Started", "Surge after the combat timeout plus a full charge")
	assert(t - markedAt >= TUNING.CombatTimeout + SURGE.ChargeSeconds - DT)
	local s2 = SurgeState.new()
	local markEvery = 0
	local t2 = START
	for _ = 1, 200 do -- a fight: marked every 2 s for 20 s
		markEvery += DT
		local mark = if markEvery >= 2 then t2 else t2 - 2
		if markEvery >= 2 then
			markEvery = 0
		end
		t2 += DT
		SurgeState.Step(s2, TUNING, DT, true, true, t2, mark)
		assert(s2.Charge == 0 and not s2.Surging, "never charges mid-fight")
	end
end)

case("short stops are forgiven, long stops reset", function()
	local s = SurgeState.new()
	local t = run(s, START, 5, true, true, 0)
	t = run(s, t, TUNING.StopGrace - DT, true, false, 0)
	assert(s.Charge > 4.9, "a short stop keeps the charge")
	t = run(s, t, 1, true, true, 0)
	assert(s.Charge > 5.9, "and the charge continues")
	t = run(s, t, TUNING.StopGrace + 2 * DT, true, false, 0)
	assert(s.Charge == 0, "a real stop resets")
end)

case("out-of-combat stamina reaches a Surge", function()
	local cost = Combat.Stamina.SprintCostPerSecond * SURGE.OutOfCombatCostMultiplier
	local seconds = Combat.Stamina.Max / cost
	assert(seconds >= SURGE.ChargeSeconds * 2, `base stamina lasts {seconds}s: enough to charge and then Surge`)
end)

print(`all {passed} cases passed`)
