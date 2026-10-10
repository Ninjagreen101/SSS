--!nocheck
-- Offline test of the tutorial step machine (Systems/TutorialSteps.lua) with the real
-- Config.Quests.Tutorial rules loaded from src/. Checks that:
--   - feeding the expected actions in order completes all 8 steps
--   - out-of-order and irrelevant actions never advance
--   - a saved step resumes where it left off (and bad saves clamp)
--   - the Resonance card opens once and only Continue closes it
--   - Skip is refused before SkipAfterSeconds and finishes the tutorial after
-- Every check is an assert; the run prints a summary.
--
--   lune run tools/place/test_tutorial.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

-- Minimal module runtime (same idea as test_surge.luau): src/ folders become instance-like
-- tables that `require` can load.
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
local Quests = requireNode(Shared.Config.Quests)
local Steps = requireNode(Systems.TutorialSteps)

local TUT = Quests.Tutorial
local RULES = {
	ParriesNeeded = TUT.ParriesNeeded,
	SkipAfterSeconds = TUT.SkipAfterSeconds,
	CrabMob = TUT.CrabMob,
	TutorMob = TUT.TutorMob,
}

local checks = 0
local function check(condition: boolean, message: string)
	checks += 1
	assert(condition, message)
end

local function ev(kind: string, key: string?, sprinting: boolean?)
	return { Kind = kind, Key = key or "", Amount = 1, Sprinting = sprinting }
end

-- The happy path: one correct action per step (two parries), the card, then the tutor.
local function script(): { any }
	local list = {
		ev("Reach", "TutorialMove"),
		ev("Reach", "TutorialSprint", true),
		ev("Kill", TUT.CrabMob),
		ev("Dodge"),
	}
	for _ = 1, TUT.ParriesNeeded do
		table.insert(list, ev("Parry"))
	end
	table.insert(list, ev("Cast", TUT.PreviewSpell))
	table.insert(list, ev("Resonance"))
	table.insert(list, "Continue")
	table.insert(list, ev("Kill", TUT.TutorMob))
	return list
end

local function run(state, list)
	local results = {}
	for _, item in list do
		local result = if item == "Continue" then Steps.Continue(state) else Steps.Feed(state, item, RULES)
		table.insert(results, result)
	end
	return results
end

-- 1. In order: all 8 steps complete.
do
	local state = Steps.New(nil, 0)
	check(state.Step == 1 and Steps.IsRunning(state), "a new tutorial starts at step 1")
	local results = run(state, script())
	check(results[#results] == "Finished", "the tutor kill finishes the tutorial")
	check(state.Done and not state.Skipped, "finished, not skipped")
	check(state.Step == Steps.Count + 1, "step counter runs past the last step")
	check(not Steps.IsRunning(state), "nothing runs once finished")
	check(Steps.Feed(state, ev("Dodge"), RULES) == "None", "events after the end are ignored")
	check(Steps.Count == 8 and #Steps.Names == 8, "eight steps")
end

-- 2. Out of order / irrelevant: nothing advances.
do
	local state = Steps.New(nil, 0)
	for _, event in {
		ev("Kill", TUT.CrabMob),
		ev("Parry"),
		ev("Cast", TUT.PreviewSpell),
		ev("Reach", "TutorialSprint", true),
		ev("Reach", "TutorialArena"),
		ev("Collect", "Driftwood"),
		ev("Kill", TUT.TutorMob),
	} do
		check(Steps.Feed(state, event, RULES) == "None", `step 1 ignores {event.Kind} {event.Key}`)
	end
	check(Steps.Continue(state) == "None", "Continue does nothing outside the card")
	check(state.Step == 1, "still on step 1")

	check(Steps.Feed(state, ev("Reach", "TutorialMove"), RULES) == "Advanced", "reaching the move point")
	check(Steps.Feed(state, ev("Reach", "TutorialSprint", false), RULES) == "None", "walking in doesn't count")
	check(Steps.Feed(state, ev("Reach", "TutorialSprint"), RULES) == "None", "unknown sprint state doesn't count")
	check(Steps.Feed(state, ev("Reach", "TutorialSprint", true), RULES) == "Advanced", "sprinting in counts")

	check(state.Step == 3, "on the crab")
	check(Steps.Feed(state, ev("Kill", TUT.TutorMob), RULES) == "None", "the wrong kill doesn't count")
	check(Steps.Feed(state, ev("Dodge"), RULES) == "None", "dodging early doesn't count")
	check(Steps.Feed(state, ev("Kill", TUT.CrabMob), RULES) == "Advanced", "the crab kill")

	check(Steps.Feed(state, ev("Parry"), RULES) == "None", "parry before the dodge step")
	check(Steps.Feed(state, ev("PerfectDodge"), RULES) == "Advanced", "a perfect dodge counts")

	check(state.Step == 5, "on parries")
	for index = 1, TUT.ParriesNeeded - 1 do
		check(Steps.Feed(state, ev("Parry"), RULES) == "Progress", `parry {index} is progress`)
		check(state.Count == index, "parry counter")
	end
	check(Steps.Feed(state, ev("Cast"), RULES) == "None", "casting before the spell step")
	check(Steps.Feed(state, ev("Parry"), RULES) == "Advanced", "the last parry advances")
	check(state.Count == 0, "counter resets on a new step")

	check(Steps.Feed(state, ev("Kill", TUT.TutorMob), RULES) == "None", "tutor kill before the spell")
	check(Steps.Feed(state, ev("Cast", TUT.PreviewSpell), RULES) == "Advanced", "the cast")

	check(state.Step == 7 and not state.CardOpen, "Resonance step waits for a stack")
	check(Steps.Continue(state) == "None", "Continue before the card is refused")
	check(Steps.Feed(state, ev("Kill", TUT.TutorMob), RULES) == "None", "tutor kill during the card step")
	check(Steps.Feed(state, ev("Resonance"), RULES) == "Progress", "first stack opens the card")
	check(state.CardOpen, "card open")
	check(Steps.Feed(state, ev("Resonance"), RULES) == "None", "the card opens once")
	check(Steps.Continue(state) == "Advanced", "Continue closes the card")
	check(state.Step == 8 and not state.CardOpen, "on the finish")
	check(Steps.Continue(state) == "None", "a second Continue does nothing")
	check(Steps.Feed(state, ev("Kill", TUT.CrabMob), RULES) == "None", "a crab kill doesn't finish")
	check(Steps.Feed(state, ev("Kill", TUT.TutorMob), RULES) == "Finished", "the tutor kill finishes")
end

-- 3. A stack gained earlier opens the card on entering step 7.
do
	local state = Steps.New(6, 0)
	check(Steps.Feed(state, ev("Resonance"), RULES) == "Progress", "an early stack is noted")
	check(state.Step == 6, "an early stack doesn't advance")
	check(Steps.Feed(state, ev("Cast"), RULES) == "Advanced", "the cast")
	check(state.Step == 7 and state.CardOpen, "card opens at once")
	check(Steps.Continue(state) == "Advanced", "and Continue closes it")
end

-- 4. Resume: every saved step resumes there and completes from there.
do
	for saved = 1, Steps.Count do
		local state = Steps.New(saved, 100)
		check(state.Step == saved, `resumes at step {saved}`)
		local list = script()
		local skip = ({ 0, 1, 2, 3, 4, 4 + TUT.ParriesNeeded, 5 + TUT.ParriesNeeded, 7 + TUT.ParriesNeeded })[saved]
		local rest = {}
		for index = skip + 1, #list do
			table.insert(rest, list[index])
		end
		local results = run(state, rest)
		check(results[#results] == "Finished" and state.Done, `finishes from step {saved}`)
	end
	check(Steps.New(0, 0).Step == 1, "step 0 starts at 1")
	check(Steps.New(-3, 0).Step == 1, "negative clamps to 1")
	check(Steps.New(99, 0).Step == Steps.Count, "too large clamps to the last step")
	check(Steps.New(0 / 0, 0).Step == 1, "NaN starts at 1")
	check(Steps.New(4.7, 0).Step == 4, "fractions floor")
	check(Steps.Anchor(1) == "TutorialStart" and Steps.Anchor(2) == "TutorialMove" and Steps.Anchor(6) == "TutorialSprint", "anchors")
	check(Steps.MobFor(2) == nil and Steps.MobFor(3) == "Crab" and Steps.MobFor(4) == "Tutor" and Steps.MobFor(8) == "Tutor", "mobs per step")
end

-- 5. Skip rules.
do
	local start = 1000
	local state = Steps.New(nil, start)
	check(Steps.SkipAt(state, RULES) == start + TUT.SkipAfterSeconds, "skip unlock time")
	check(not Steps.CanSkip(state, start, RULES), "no skip at once")
	check(not Steps.Skip(state, start + TUT.SkipAfterSeconds - 0.01, RULES), "no skip just before the timer")
	check(Steps.IsRunning(state) and not state.Skipped, "still running after a refused skip")
	check(Steps.Skip(state, start + TUT.SkipAfterSeconds, RULES), "skip at the timer")
	check(state.Done and state.Skipped and not Steps.IsRunning(state), "skipped means done")
	check(not Steps.Skip(state, start + 60, RULES), "can't skip twice")
	check(Steps.Feed(state, ev("Reach", "TutorialMove"), RULES) == "None", "skipped tutorial ignores events")

	local later = Steps.New(5, start)
	check(Steps.Skip(later, start + 30, RULES), "skip works on later steps too")
	local finished = Steps.New(8, start)
	Steps.Feed(finished, ev("Kill", TUT.TutorMob), RULES)
	check(not Steps.Skip(finished, start + 30, RULES) and not finished.Skipped, "no skip once finished")
end

print(`test_tutorial: {checks} checks passed`)
