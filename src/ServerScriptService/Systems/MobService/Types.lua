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

-- A per-mob weak point (overrides Def.WeakPoint): blows landing within Arc degrees of its
-- Side deal Damage x and Posture x. Floor Guardians move theirs between phases.
export type WeakPointSpec = {
	Side: "Back" | "Front",
	Arc: number,
	Damage: number,
	Posture: number,
}

-- Optional extras for MobService.Spawn.
export type SpawnOptions = {
	Scripted: boolean?, -- driven by its owner (GuardianService): never thinks, no kill rewards or respawn
	MaxHealth: number?, -- overrides the def (and elite) health
	MaxPosture: number?,
	HitRadius: number?, -- big bodies (TargetService.SetHitSize)
	HitHeight: number?,
	Facing: Vector3?, -- initial look direction (default: random)
	AllowedTargets: { [Player]: boolean }?, -- only these players are noticed, chased or taunt it (live set)
	OnDied: ((Mob) -> ())?, -- runs once when it dies (after rewards for normal mobs)
	DamageMultiplier: number?, -- scales every blow it deals (on top of the elite multiplier)
	TelegraphScale: number?, -- scales its moves' telegraphs (still at least Mobs.AI.MinTelegraph)
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

	Scripted: boolean, -- its owner drives it (Floor Guardians): Brain never thinks for it
	AllowedTargets: { [Player]: boolean }?, -- nil: anyone; else only these players
	WeakPoint: WeakPointSpec?, -- overrides Def.WeakPoint
	PostureTaken: number, -- multiplies posture damage it takes (a Guardian's ebb tide)
	TelegraphScale: number, -- multiplies every move's telegraph (Spawn option; tutorial tutors are slower)
	OnDied: ((Mob) -> ())?,
}

return {}
