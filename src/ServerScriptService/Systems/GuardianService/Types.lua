--!strict
-- Shared record types for GuardianService and its helpers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Guardians = require(Shared.Data.Guardians)
local Maid = require(Shared.Util.Maid)

local MobTypes = require(script.Parent.Parent.MobService.Types)
local Rules = require(script.Parent.Rules)

export type State = "Starting" | "Intro" | "Active" | "Victory" | "Wipe" | "Closed"

-- One party's copy of the arena (Arena.Create).
export type Arena = {
	Model: Model,
	Slot: number,
	Origin: CFrame,
	Radius: number, -- walkable radius (Bounds attribute Radius)
	BossSpawn: CFrame,
	PlayerSpawns: { CFrame },
	AddPools: { Vector3 },
	Water: BasePart?,
	WaterY: { [string]: number }, -- "Calm" | "High" | "Ebb" -> Y offset from Origin
	TideLines: { BasePart },
	LineDim: { [BasePart]: number }, -- each tide line's unlit Transparency (as built)
	PressureZone: BasePart?,
	Seal: BasePart?,
}

-- Everyone who entered the fight (kept after they die or leave, for the reward share).
export type Participant = {
	Player: Player,
	Name: string,
	Inside: number, -- seconds alive inside the arena
}

-- A player held in the Warden's claw.
export type Grab = {
	Victim: Player,
	Release: (throw: boolean) -> (),
}

-- The move the Warden is running.
export type MoveRun = {
	Id: string,
	Move: Guardians.GuardianMove,
	Target: Player,
	Thread: thread?,
	Cleanups: { () -> () },
}

export type Fight = {
	Id: number,
	GuardianId: string,
	Def: Guardians.GuardianDef,
	Gate: BasePart,
	Arena: Arena,
	Slot: number,
	State: State,

	Mob: MobTypes.Mob?,
	Model: Model?,
	Humanoid: Humanoid?,
	Root: BasePart?,
	MaxHealth: number,
	LockPoints: { [string]: Attachment },

	Members: { [Player]: boolean }, -- alive and fighting (also the adds' AllowedTargets)
	Participants: { [Player]: Participant },
	Names: { string },
	StartCount: number,

	Phase: number,
	Tide: Rules.Tide,
	StartedAt: number, -- server time the fight began (the intro's end)
	DormantUntil: number, -- intro and phase transitions: no moves before this
	NextMoveAt: number,
	Move: MoveRun?,
	Cooldowns: { [string]: number },
	LastMove: string?,
	Repeats: number,
	SweepMirrored: boolean,
	BlockedAt: { [Player]: number },
	Adds: { [Model]: number }, -- add model -> server time it leaves
	Hazards: { [thread]: boolean }, -- whirlpools and waves still running
	Grab: Grab?,
	Eligible: { Player },

	Random: Random,
	Maid: Maid.Maid,
}

return {}
