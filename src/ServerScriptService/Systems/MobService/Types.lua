--!strict
-- Shared record types for MobService and its helpers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local Mobs = require(Shared.Data.Mobs)

export type SpawnPoint = {
	Part: BasePart,
	MobId: string,
	Count: number,
	Elite: boolean,
	RespawnTime: number,
	PatrolRadius: number,
	Alive: number,
	NightOnly: boolean,
}

export type NavState = {
	Path: Path,
	Waypoints: { PathWaypoint },
	Index: number,
	Goal: Vector3?,
	ComputedAt: number,
	Computing: boolean,
}

export type Mob = {
	Serial: number,
	MobId: string,
	Def: Mobs.MobDef,
	Elite: boolean,
	Model: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Align: AlignOrientation,
	Spawn: SpawnPoint?,
	Home: Vector3,
	PatrolRadius: number,
	DamageMultiplier: number,
	EmpowerUntil: number, -- a Lantern Acolyte's Kindle: extra damage until this server time
	EmpowerBonus: number,

	State: Enums.MobState,
	Target: Player?,
	Threat: { [Player]: number },
	TauntedBy: Player?, -- a Taunt (Harbor Bell) forces this target until TauntUntil
	TauntUntil: number,
	Contributors: { [Player]: number }, -- damage dealt, for kill rewards
	LastTargetAt: number,
	NoticeUntil: number,
	NextPatrolAt: number,
	Cooldowns: { [string]: number }, -- move id -> time it can be used again
	LastMove: string?,
	MoveRepeats: number,
	NextMoveAt: number, -- no new move before this (Mobs.Pacing)
	Acting: boolean, -- a move is running (it owns the mob until it ends)
	ActionThread: thread?,
	Token: Player?, -- the player whose attack slot this mob holds

	NextThinkAt: number,
	LastThinkAt: number,
	Asleep: boolean,
	Nav: NavState,
	Dead: boolean,
}

return {}
