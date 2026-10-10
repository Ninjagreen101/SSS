--!strict
--[[
	TutorialSteps (helper, not a system)
	The onboarding step machine (docs/PHASE11_QUESTS.md section 5), kept pure so Lune can test it
	(tools/place/test_tutorial.luau). TutorialService owns the world side (mobs, points, the
	profile) and feeds this machine the actions the server already decided happened.

	Steps (Steps.Names):
	  1 Move       Reach TutorialMove
	  2 Sprint     Reach TutorialSprint while sprinting
	  3 Combo      Kill the tutorial crab (Kill, key = rules.CrabMob)
	  4 Dodge      one Dodge or PerfectDodge
	  5 Parry      rules.ParriesNeeded Parry events
	  6 Spell      one Cast (the preview Tide Bolt)
	  7 Resonance  the big card opens on a Resonance stack (or at once if one was already gained
	               this session); Continue closes it
	  8 Finish     Kill the tutor (Kill, key = rules.TutorMob)
	Anything else, and anything out of order, is ignored. Skip is allowed rules.SkipAfterSeconds
	after the session started (the Skip button appears then) and finishes the tutorial at once.
]]

export type Event = {
	Kind: string, -- a GameEvents kind ("Reach", "Kill", "Parry", ...)
	Key: string,
	Amount: number,
	Sprinting: boolean?, -- Reach only: the player was sprinting when they arrived
}

export type Rules = {
	ParriesNeeded: number,
	SkipAfterSeconds: number,
	CrabMob: string,
	TutorMob: string,
}

export type State = {
	Step: number, -- 1..Count while running, Count + 1 once finished
	Count: number, -- progress inside the step (parries so far)
	ResonanceSeen: boolean, -- a Resonance stack was gained this session
	CardOpen: boolean, -- step 7: the big Resonance card is showing
	StartedAt: number, -- session start (Skip unlocks SkipAfterSeconds later)
	Done: boolean,
	Skipped: boolean,
}

-- The tutorial mob a step needs alive.
export type MobRole = "Crab" | "Tutor"

-- What a fed event did.
export type Result = "None" | "Progress" | "Advanced" | "Finished"

local Steps = {}

Steps.Count = 8
Steps.Names = table.freeze({ "Move", "Sprint", "Combo", "Dodge", "Parry", "Spell", "Resonance", "Finish" })

-- The quest point each step's waypoint marks (steps with a mob mark the mob instead).
Steps.Points = table.freeze({
	[1] = "TutorialMove",
	[2] = "TutorialSprint",
	[3] = "TutorialArena",
	[4] = "TutorialArena",
	[5] = "TutorialArena",
	[6] = "TutorialArena",
	[7] = "TutorialArena",
	[8] = "TutorialArena",
}) :: { [number]: string }

-- Where a (re)joining player is placed for a step.
function Steps.Anchor(step: number): string
	if step <= 1 then
		return "TutorialStart"
	elseif step == 2 then
		return "TutorialMove"
	end
	return "TutorialSprint"
end

-- Which tutorial mob a step needs alive: "Crab", "Tutor" or nil.
function Steps.MobFor(step: number): MobRole?
	if step == 3 then
		return "Crab"
	elseif step >= 4 and step <= Steps.Count then
		return "Tutor"
	end
	return nil
end

-- A fresh or resumed session. `savedStep` is the profile's Tutorial.Step (0 / nil = not started).
function Steps.New(savedStep: number?, now: number): State
	local step = 1
	if type(savedStep) == "number" and savedStep == savedStep then
		step = math.clamp(math.floor(savedStep), 1, Steps.Count)
	end
	return {
		Step = step,
		Count = 0,
		ResonanceSeen = false,
		CardOpen = false,
		StartedAt = now,
		Done = false,
		Skipped = false,
	}
end

function Steps.IsRunning(state: State): boolean
	return not state.Done and state.Step >= 1 and state.Step <= Steps.Count
end

-- Moves to the next step (or finishes). Entering step 7 opens the card at once if a stack was
-- already gained this session.
local function advance(state: State): Result
	state.Step += 1
	state.Count = 0
	state.CardOpen = false
	if state.Step > Steps.Count then
		state.Done = true
		return "Finished"
	end
	if state.Step == 7 and state.ResonanceSeen then
		state.CardOpen = true
	end
	return "Advanced"
end

-- Feeds one action. Returns what it changed.
function Steps.Feed(state: State, event: Event, rules: Rules): Result
	if not Steps.IsRunning(state) then
		return "None"
	end
	local step = state.Step
	local kind = event.Kind

	if kind == "Resonance" then
		local first = not state.ResonanceSeen
		state.ResonanceSeen = true
		if step == 7 and not state.CardOpen then
			state.CardOpen = true
			return "Progress"
		end
		return if first then "Progress" else "None"
	end

	if step == 1 then
		if kind == "Reach" and event.Key == Steps.Points[1] then
			return advance(state)
		end
	elseif step == 2 then
		if kind == "Reach" and event.Key == Steps.Points[2] and event.Sprinting == true then
			return advance(state)
		end
	elseif step == 3 then
		if kind == "Kill" and event.Key == rules.CrabMob then
			return advance(state)
		end
	elseif step == 4 then
		if kind == "Dodge" or kind == "PerfectDodge" then
			return advance(state)
		end
	elseif step == 5 then
		if kind == "Parry" then
			state.Count += 1
			if state.Count >= rules.ParriesNeeded then
				return advance(state)
			end
			return "Progress"
		end
	elseif step == 6 then
		if kind == "Cast" then
			return advance(state)
		end
	elseif step == 8 then
		if kind == "Kill" and event.Key == rules.TutorMob then
			return advance(state)
		end
	end
	return "None"
end

-- The player closed the Resonance card (RequestTutorial "Continue"). Only works while it's open.
function Steps.Continue(state: State): Result
	if not Steps.IsRunning(state) or state.Step ~= 7 or not state.CardOpen then
		return "None"
	end
	return advance(state)
end

-- Server time the Skip button unlocks.
function Steps.SkipAt(state: State, rules: Rules): number
	return state.StartedAt + rules.SkipAfterSeconds
end

function Steps.CanSkip(state: State, now: number, rules: Rules): boolean
	return Steps.IsRunning(state) and now >= Steps.SkipAt(state, rules)
end

-- Skips the rest (RequestTutorial "Skip"). Returns false when not allowed yet.
function Steps.Skip(state: State, now: number, rules: Rules): boolean
	if not Steps.CanSkip(state, now, rules) then
		return false
	end
	state.Skipped = true
	state.Done = true
	state.CardOpen = false
	return true
end

return Steps
