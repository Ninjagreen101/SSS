--!strict
--[[
	SurgeState
	Pure state machine for the sprint Surge (no Roblox APIs, so the Lune test
	tools/place/test_surge.luau can drive it). VitalsService owns one per
	player and steps it on its vitals tick.

	- Charge builds only while sprinting, moving and out of combat (the last
	  combat event is at least CombatTimeout old). A stop shorter than
	  StopGrace (turning on the spot, a stumble) pauses the charge instead of
	  breaking it.
	- At ChargeSeconds the Surge starts (Step returns "Started").
	- Stopping the sprint, a stop longer than StopGrace, or any combat ends
	  the Surge and resets the charge to 0 (Step / Cancel report "Ended" when a
	  Surge was running).
]]

export type Tuning = {
	ChargeSeconds: number,
	StopGrace: number,
	CombatTimeout: number,
}

export type State = {
	Charge: number, -- seconds of qualifying sprint so far
	Stopped: number, -- seconds standing still during the current sprint
	Surging: boolean,
}

export type Event = "Started" | "Ended"

local SurgeState = {}

function SurgeState.new(): State
	return { Charge = 0, Stopped = 0, Surging = false }
end

-- Resets the charge and ends any Surge. Returns "Ended" if one was running.
function SurgeState.Cancel(state: State): Event?
	local was = state.Surging
	state.Charge = 0
	state.Stopped = 0
	state.Surging = false
	return if was then "Ended" else nil
end

function SurgeState.InCombat(tuning: Tuning, now: number, lastCombat: number): boolean
	return now - lastCombat < tuning.CombatTimeout
end

-- Advances the machine by `dt` seconds. `sprinting` is the server's sprint
-- state (intent allowed, not winded or locked); `moving` is real ground speed.
function SurgeState.Step(
	state: State,
	tuning: Tuning,
	dt: number,
	sprinting: boolean,
	moving: boolean,
	now: number,
	lastCombat: number
): Event?
	if not sprinting or SurgeState.InCombat(tuning, now, lastCombat) then
		return SurgeState.Cancel(state)
	end
	if not moving then
		state.Stopped += dt
		if state.Stopped > tuning.StopGrace then
			return SurgeState.Cancel(state)
		end
		return nil
	end
	state.Stopped = 0
	if state.Surging then
		return nil
	end
	state.Charge += dt
	if state.Charge >= tuning.ChargeSeconds then
		state.Surging = true
		return "Started"
	end
	return nil
end

return table.freeze(SurgeState)
