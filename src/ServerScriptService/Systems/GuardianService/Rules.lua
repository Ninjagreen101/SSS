--!strict
--[[
	Rules (GuardianService)
	The fight's pure decisions, with no instances: the phase for a health value and the clamp at
	each threshold, party scaling, which move to use next, telegraph timing, the tide schedule,
	who earned a share of the rewards, and the ground shapes area moves hit. GuardianService feeds
	it numbers and positions; tools/place/sim_guardian.luau drives it offline through whole fights.

	Inputs come from Shared.Data.Guardians (per Guardian) and Config.Mobs.Guardian / AI (fight-wide).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MobsConfig = require(Shared.Config.Mobs)
local Guardians = require(Shared.Data.Guardians)

type GuardianDef = Guardians.GuardianDef
type GuardianMove = Guardians.GuardianMove
type GuardianPhase = Guardians.GuardianPhase

local G = MobsConfig.Guardian
local AI = MobsConfig.AI

-- Values the Guardian data documents in prose (Shared/Data/Guardians.lua, move fields).
local BLOCKING_WEIGHT = 3 -- Condition "TargetBlocking": weight x3 against a target that blocked recently
local PLAYERS_BEHIND = 2 -- Condition "PlayersBehind": needs this many players behind it
local MANY_PLAYERS = 4 -- Lances use CountMany from this many players
-- Humanoid health is a 32-bit float: thresholds compare within half a point of health.
local HEALTH_EPSILON = 0.5

export type TideName = "Calm" | "High" | "Ebb"
export type Tide = { State: TideName, EndsAt: number, Warned: boolean }
export type TideEvent = "Warn" | "Change"
export type WaterLevel = "Calm" | "High" | "Ebb"

export type WeakPoint = { Side: "Back" | "Front", Arc: number, Damage: number, Posture: number }

-- What the fight looks like when it picks a move.
export type Context = {
	Phase: number,
	Now: number,
	Distance: number, -- flat studs, the Warden's root to its target
	Cooldowns: { [string]: number }, -- move id -> server time it is ready
	LastMove: string?,
	Repeats: number, -- times LastMove has run in a row
	TargetBlocking: boolean, -- the target blocked within Config BlockingMemory
	Behind: { number }, -- flat distances of living members behind the Warden
	TideRunning: boolean,
	TideChanging: boolean, -- a tide tell is playing (or would start during this move's wind-up)
	AddsAlive: number,
	AddsWanted: number,
}

export type Option = { Id: string, Move: GuardianMove, Weight: number }

local Rules = {}

Rules.MinTelegraph = G.MinTelegraph
Rules.MaxRepeats = AI.MaxSameAttackRepeats

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- PHASES ---------------------------------------------------------------------------------------

function Rules.PhaseCount(): number
	return #G.PhaseThresholds
end

function Rules.PhaseDef(def: GuardianDef, phase: number): GuardianPhase
	return def.Phases[math.clamp(phase, 1, #def.Phases)]
end

function Rules.IsLastPhase(phase: number): boolean
	return phase >= #G.PhaseThresholds
end

-- The phase a health value belongs to (thresholds descending: 1.0, 0.6, 0.25 of max health).
function Rules.PhaseForHealth(health: number, maxHealth: number): number
	local phase = 1
	for index, threshold in G.PhaseThresholds do
		if health <= threshold * maxHealth + HEALTH_EPSILON then
			phase = index
		end
	end
	return phase
end

-- The lowest health the Guardian can drop to while in `phase`: the next phase's threshold (0 in
-- the last phase). Health is clamped here until the transition starts, so burst can't skip a phase.
function Rules.HealthFloor(phase: number, maxHealth: number): number
	local nextThreshold = G.PhaseThresholds[phase + 1]
	return if nextThreshold then nextThreshold * maxHealth else 0
end

function Rules.ClampHealth(health: number, phase: number, maxHealth: number): number
	return math.max(health, Rules.HealthFloor(phase, maxHealth))
end

-- The phase to move to after a hit (one step at a time), or nil to stay.
function Rules.NextPhase(health: number, phase: number, maxHealth: number): number?
	if Rules.PhaseForHealth(health, maxHealth) > phase and not Rules.IsLastPhase(phase) then
		return phase + 1
	end
	return nil
end

-- SCALING --------------------------------------------------------------------------------------

function Rules.MaxHealth(def: GuardianDef, players: number): number
	return Guardians.ScaledHealth(def, players, G.HealthScalePerExtraPlayer, G.MaxPlayers)
end

function Rules.AddCount(def: GuardianDef, players: number): number
	return Guardians.AddCount(def, math.clamp(players, 1, G.MaxPlayers))
end

function Rules.LanceCount(move: GuardianMove, players: number): number
	if players >= MANY_PLAYERS and move.CountMany then
		return move.CountMany
	end
	return move.Count or 1
end

-- Undertow: one whirlpool per player, up to the move's Count.
function Rules.PoolCount(move: GuardianMove, players: number): number
	return math.max(1, math.min(move.Count or 1, players))
end

-- TIMING ---------------------------------------------------------------------------------------

-- Wind-up before a move's first blow: the move's Telegraph x the phase's TelegraphScale, never
-- under Config MinTelegraph.
function Rules.Telegraph(def: GuardianDef, move: GuardianMove, phase: number): number
	return math.max(move.Telegraph * Rules.PhaseDef(def, phase).TelegraphScale, G.MinTelegraph)
end

-- Wind-up of each later blow in a string (scaled the same way, same floor).
function Rules.Interval(def: GuardianDef, move: GuardianMove, phase: number): number
	local interval = move.BlowInterval or 0
	if interval <= 0 then
		return 0
	end
	return math.max(interval * Rules.PhaseDef(def, phase).TelegraphScale, G.MinTelegraph)
end

-- Breathing room after a move (`roll` in [0, 1)).
function Rules.MoveGap(def: GuardianDef, phase: number, roll: number): number
	local gap = Rules.PhaseDef(def, phase).MoveGap
	return gap[1] + (gap[2] - gap[1]) * math.clamp(roll, 0, 1)
end

-- MobBlow telegraph field for blow `index`: 2 unparryable (red ember glint), 1 the move's first
-- blow (warning glow), 0 nothing.
function Rules.BlowFlag(move: GuardianMove, index: number): number
	if Guardians.BlowUnparryable(move, index) then
		return 2
	end
	return if index == 1 then 1 else 0
end

-- Coral Sweep opens from alternating sides: the string plays mirrored on every other use.
function Rules.SweepBlows(move: GuardianMove, mirrored: boolean): { string }
	if not mirrored then
		return move.Blows
	end
	local out = {}
	for index = #move.Blows, 1, -1 do
		table.insert(out, move.Blows[index])
	end
	return out
end

-- MOVE CHOICE ----------------------------------------------------------------------------------

function Rules.InPhase(move: GuardianMove, phase: number): boolean
	return table.find(move.Phases, phase) ~= nil
end

-- A move's weight right now (0: not usable).
function Rules.Weight(id: string, move: GuardianMove, ctx: Context): number
	if not Rules.InPhase(move, ctx.Phase) then
		return 0
	end
	if ctx.Distance < move.MinRange or ctx.Distance > move.MaxRange then
		return 0
	end
	if (ctx.Cooldowns[id] or 0) > ctx.Now then
		return 0
	end
	if ctx.LastMove == id and ctx.Repeats >= AI.MaxSameAttackRepeats then
		return 0
	end
	if move.Kind == "Summon" and ctx.AddsAlive >= ctx.AddsWanted then
		return 0
	end
	local weight = move.Weight
	local condition = move.Condition
	if condition == "TargetBlocking" then
		if ctx.TargetBlocking then
			weight *= BLOCKING_WEIGHT
		end
	elseif condition == "PlayersBehind" then
		local reach = move.Radius or move.MaxRange
		local count = 0
		for _, distance in ctx.Behind do
			if distance <= reach then
				count += 1
			end
		end
		if count < PLAYERS_BEHIND then
			return 0
		end
	elseif condition == "TargetFar" then
		if ctx.Distance <= move.MinRange then
			return 0
		end
	elseif condition == "TideNotChanging" then
		if not ctx.TideRunning or ctx.TideChanging then
			return 0
		end
	end
	return weight
end

-- Every usable move with its weight, in a stable order (sorted by id).
function Rules.Options(def: GuardianDef, ctx: Context): { Option }
	local ids = {}
	for id in def.Moves do
		table.insert(ids, id)
	end
	table.sort(ids)
	local options: { Option } = {}
	for _, id in ids do
		local move = def.Moves[id]
		local weight = Rules.Weight(id, move, ctx)
		if weight > 0 then
			table.insert(options, { Id = id, Move = move, Weight = weight })
		end
	end
	return options
end

-- Weighted pick (`roll` in [0, 1)); nil if nothing is usable.
function Rules.Choose(def: GuardianDef, ctx: Context, roll: number): Option?
	local options = Rules.Options(def, ctx)
	local total = 0
	for _, option in options do
		total += option.Weight
	end
	if total <= 0 then
		return nil
	end
	local pick = math.clamp(roll, 0, 1) * total
	for _, option in options do
		if pick < option.Weight then
			return option
		end
		pick -= option.Weight
	end
	return options[#options]
end

-- THE TIDE -------------------------------------------------------------------------------------

-- The tide cycle runs in phases without a fixed Pressure.
function Rules.TideRuns(def: GuardianDef, phase: number): boolean
	return Rules.PhaseDef(def, phase).Pressure == nil
end

function Rules.CalmTide(): Tide
	return { State = "Calm", EndsAt = 0, Warned = false }
end

function Rules.TideSeconds(def: GuardianDef, state: TideName): number
	if state == "High" then
		return def.Tide.HighSeconds
	elseif state == "Ebb" then
		return def.Tide.EbbSeconds
	end
	return 0
end

function Rules.NextTide(state: TideName): TideName
	if state == "High" then
		return "Ebb"
	end
	return "High"
end

-- The cycle starts at high tide `delay` seconds from `t` (after a phase transition).
function Rules.StartTide(def: GuardianDef, t: number, delay: number): Tide
	return { State = "High", EndsAt = t + delay + def.Tide.HighSeconds, Warned = false }
end

-- Advances the tide to time `t`: "Warn" when the tell before a change starts, "Change" when the
-- tide turns (the state, EndsAt and Warned are updated in place).
function Rules.TickTide(def: GuardianDef, tide: Tide, t: number): TideEvent?
	if tide.State == "Calm" then
		return nil
	end
	if t >= tide.EndsAt then
		local nextState: TideName = Rules.NextTide(tide.State)
		local endsAt = tide.EndsAt + Rules.TideSeconds(def, nextState)
		tide.State = nextState
		tide.EndsAt = if endsAt > t then endsAt else t + Rules.TideSeconds(def, nextState)
		tide.Warned = false
		return "Change"
	end
	if not tide.Warned and t >= tide.EndsAt - def.Tide.WarnSeconds then
		tide.Warned = true
		return "Warn"
	end
	return nil
end

-- True while a tide tell is playing, or one would start within `lead` seconds.
function Rules.TideChanging(def: GuardianDef, tide: Tide, t: number, lead: number): boolean
	if tide.State == "Calm" then
		return false
	end
	return tide.Warned or tide.EndsAt - t <= def.Tide.WarnSeconds + lead
end

-- Tide Surge: the tide turns `lead` seconds from now (never with less than the WarnSeconds tell).
-- Returns false if there is no tide or it is already turning.
function Rules.ForceTide(def: GuardianDef, tide: Tide, t: number, lead: number): boolean
	if tide.State == "Calm" or Rules.TideChanging(def, tide, t, 0) then
		return false
	end
	tide.EndsAt = t + math.max(lead, def.Tide.WarnSeconds)
	tide.Warned = true
	return true
end

function Rules.TidePressure(def: GuardianDef, phase: number, state: TideName): number
	if state == "High" then
		return def.Tide.HighPressure
	elseif state == "Ebb" then
		return def.Tide.EbbPressure
	end
	return Rules.PhaseDef(def, phase).Pressure or def.Tide.HighPressure
end

-- Water height in the arena: the tide's, or the phase's Flood while the tide is calm.
function Rules.WaterLevel(def: GuardianDef, phase: number, state: TideName): WaterLevel
	if state == "High" or state == "Ebb" then
		return state
	end
	return Rules.PhaseDef(def, phase).Flood
end

-- Posture the Guardian takes is multiplied by this (its shell dries out at ebb tide).
function Rules.PostureTaken(def: GuardianDef, state: TideName): number
	return if state == "Ebb" then def.Tide.EbbPostureMultiplier else 1
end

function Rules.WeakPoint(def: GuardianDef, phase: number): WeakPoint
	return {
		Side = Rules.PhaseDef(def, phase).WeakPoint,
		Arc = G.WeakPointArc,
		Damage = G.WeakPointDamageMultiplier,
		Posture = G.WeakPointPostureMultiplier,
	}
end

-- REWARDS --------------------------------------------------------------------------------------

-- A share of the rewards: ContributionDamage of the max health dealt, or ContributionSeconds
-- alive inside the arena (support players qualify by being there).
function Rules.Eligible(damage: number, maxHealth: number, secondsInside: number): boolean
	return damage >= G.ContributionDamage * maxHealth or secondsInside >= G.ContributionSeconds
end

-- GROUND SHAPES (flat: heights are ignored) ----------------------------------------------------

function Rules.FlatDistance(a: Vector3, b: Vector3): number
	return flat(a - b).Magnitude
end

function Rules.InCircle(center: Vector3, radius: number, point: Vector3, pad: number): boolean
	return flat(point - center).Magnitude <= radius + pad
end

-- A strip `length` long from `origin` along the flat unit `direction`, `width` wide.
function Rules.InLine(origin: Vector3, direction: Vector3, length: number, width: number, point: Vector3, pad: number): boolean
	local offset = flat(point - origin)
	local along = offset:Dot(direction)
	if along < -pad or along > length + pad then
		return false
	end
	return (offset - direction * along).Magnitude <= width / 2 + pad
end

function Rules.InCone(origin: Vector3, look: Vector3, radius: number, arc: number, point: Vector3, pad: number): boolean
	local offset = flat(point - origin)
	local distance = offset.Magnitude
	if distance > radius + pad then
		return false
	end
	local facing = flat(look)
	if distance <= pad or facing.Magnitude < 1e-3 then
		return true
	end
	local angle = math.deg(math.acos(math.clamp(facing.Unit:Dot(offset.Unit), -1, 1)))
	return angle <= arc / 2
end

-- Behind the Warden: in the half-plane at its back.
function Rules.IsBehind(origin: Vector3, look: Vector3, point: Vector3): boolean
	return flat(point - origin):Dot(flat(look)) < 0
end

-- Flat distance from `point` to the segment a-b (a charge sweeping between two samples).
function Rules.SegmentDistance(a: Vector3, b: Vector3, point: Vector3): number
	local ab = flat(b - a)
	local ap = flat(point - a)
	local lengthSq = ab:Dot(ab)
	if lengthSq < 1e-6 then
		return ap.Magnitude
	end
	local t = math.clamp(ap:Dot(ab) / lengthSq, 0, 1)
	return (ap - ab * t).Magnitude
end

-- How far a line from `start` along flat unit `direction` can run (up to `length`) before it
-- leaves the circle (`center`, `radius`). 0 if it starts outside.
function Rules.ClipToCircle(start: Vector3, direction: Vector3, length: number, center: Vector3, radius: number): number
	local offset = flat(start - center)
	local b = offset:Dot(direction)
	local c = offset:Dot(offset) - radius * radius
	if c > 0 then
		return 0
	end
	local exit = -b + math.sqrt(math.max(0, b * b - c))
	return math.clamp(exit, 0, length)
end

-- Flat unit aims for `count` water lances at `targets` from `origin`. Repeated targets get extra
-- lances fanned out beside them, about two line widths apart where the target stands.
function Rules.LanceAims(origin: Vector3, targets: { Vector3 }, count: number, width: number, fallback: Vector3): { Vector3 }
	local aims: { Vector3 } = {}
	local base = flat(fallback)
	base = if base.Magnitude > 1e-3 then base.Unit else Vector3.new(0, 0, -1)
	for index = 1, count do
		local aim = base
		local distance = width
		if #targets > 0 then
			local toTarget = flat(targets[(index - 1) % #targets + 1] - origin)
			if toTarget.Magnitude > 1e-3 then
				aim = toTarget.Unit
				distance = math.max(toTarget.Magnitude, width)
			end
		end
		local round = if #targets > 0 then (index - 1) // #targets else index - 1
		if round > 0 then
			-- +1, -1, +2, -2 ... steps either side of the target
			local step = math.ceil(round / 2) * (if round % 2 == 1 then 1 else -1)
			local angle = step * 2 * math.atan(width / distance)
			local c, s = math.cos(angle), math.sin(angle)
			aim = Vector3.new(aim.X * c - aim.Z * s, 0, aim.X * s + aim.Z * c)
		end
		table.insert(aims, aim)
	end
	return aims
end

-- Seconds after release that a wave front moving at `speed` reaches `distance`.
function Rules.WaveDelay(distance: number, speed: number): number
	return distance / math.max(speed, 1e-3)
end

return table.freeze(Rules)
