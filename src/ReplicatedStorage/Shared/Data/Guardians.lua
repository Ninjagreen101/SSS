--!strict
--[[
	Guardians
	Floor Guardian definitions (Spec Section 10). GuardianService runs the fight from this table;
	clients read names, phases and colours from it. Fight-wide tuning (health scaling, phase
	thresholds, weak-point multipliers) is Config.Mobs.Guardian. The design and the reasoning
	behind every number are in docs/PHASE10_GUARDIAN.md.

	Guardian fields:
	  MobId          body entry in Shared.Data.Mobs (built by MobService's Builder; no Moves there)
	  Floor          floor it guards ("1"); clearing it unlocks NextFloor
	  NextFloor      floor id unlocked on a member's first clear
	  Level          shown on the boss bar
	  BaseHealth     health for one player (Config.Mobs.Guardian scales it by party size)
	  MaxPosture     posture meter; full = Broken for BrokenDuration seconds
	  BrokenDuration seconds it kneels after a posture break
	  HitRadius      extra studs added to blows' reach against it (it is a big target)
	  HitHeight      extra vertical studs blows reach on it (and its blows reach down)
	  Arena          template name in ServerStorage.GuardianArenas
	  Intro          seconds of the intro (the Warden is dormant until it ends for everyone)
	  Transition     seconds a phase change takes (immune, current move cancelled)
	  Phases         per phase (index 1..3, thresholds in Config.Mobs.Guardian.PhaseThresholds):
	                   TelegraphScale  multiplies every telegraph (never below MinTelegraph)
	                   MoveGap         { min, max } seconds between moves
	                   WeakPoint       "Back" | "Front": where weak-point blows land
	                   Pressure        arena Pressure while the tide is Calm (nil: tide cycle runs)
	                   Flood           arena water height: "Calm" | "High"
	  Tide           the tide cycle (phases whose Pressure is nil): HighSeconds, EbbSeconds,
	                 WarnSeconds (tell before each change), HighPressure, EbbPressure,
	                 EbbPostureMultiplier (posture damage taken while the tide is out)
	  Adds           Bilgecrab summons: MobId, Base, PerTwoExtraPlayers, Max, Lifetime
	  Rewards        XP, GoldMin, GoldMax, Shards (first clear only), LootTable (Config.Loot.Mobs key)
	  Moves          see below

	Move fields:
	  Kind         "Sweep" | "Cleave" | "Grab" | "Rush" | "Stomp" | "Summon" | "Lances" | "Undertow"
	               | "Surge" | "Flurry" | "Pulse" | "Wave" (GuardianService has one runner per kind)
	  Phases       phases the move appears in
	  Weight       choice weight among usable moves
	  MinRange / MaxRange   target distance (from the Warden's root, flat) the move is used at
	  Cooldown     seconds before it can be used again
	  Telegraph    wind-up before the first blow (scaled by the phase's TelegraphScale)
	  Blows        animation slot per blow (MobController plays them from MobBlow)
	  BlowInterval seconds between blows of a string
	  Unparryable  per blow (true = red ember glint, Parryable false); a single boolean covers all
	  Blockable    false: block does not reduce it (grabs, waves)
	  Damage / Posture / HitStun   per blow (damage before the target's defence)
	  Recovery     seconds it stands open afterwards (the punish window)
	  Reach / Arc  Sweep, Flurry, Grab: swing size (studs, degrees)
	  Length / Width   Cleave, Rush, Lances: line size
	  Radius       Stomp, Pulse, Undertow: circle radius; Wave: how far the ring travels
	  Speed        Wave: studs per second the ring travels; Rush: charge speed
	  Count        Lances: lines (CountMany with 4+ players); Undertow: pools (max, one per player)
	  Tick / Duration   Undertow: damage every Tick seconds for Duration seconds
	  Hold / Crushes    Grab: seconds held, crush blows while held (Damage each), then thrown
	  BreakPosture Grab: posture damage the party must deal to the Warden while it holds someone
	               to free them early
	  Condition    "TargetBlocking" (weight x3 when the target has blocked within the last 1.5 s),
	               "PlayersBehind" (needs 2+ players behind it), "TargetFar" (beyond MinRange only),
	               "TideNotChanging" (Surge: not during a tide tell)
]]

export type MoveKind =
	"Sweep"
	| "Cleave"
	| "Grab"
	| "Rush"
	| "Stomp"
	| "Summon"
	| "Lances"
	| "Undertow"
	| "Surge"
	| "Flurry"
	| "Pulse"
	| "Wave"

export type Condition = "TargetBlocking" | "PlayersBehind" | "TargetFar" | "TideNotChanging"

export type GuardianMove = {
	Kind: MoveKind,
	Phases: { number },
	Weight: number,
	MinRange: number,
	MaxRange: number,
	Cooldown: number,
	Telegraph: number,
	Blows: { string },
	BlowInterval: number?,
	Unparryable: boolean | { boolean },
	Blockable: boolean,
	Damage: number,
	Posture: number,
	HitStun: number,
	Recovery: number,
	Reach: number?,
	Arc: number?,
	Length: number?,
	Width: number?,
	Radius: number?,
	Speed: number?,
	Count: number?,
	CountMany: number?,
	Tick: number?,
	Duration: number?,
	Hold: number?,
	Crushes: number?,
	BreakPosture: number?,
	Condition: Condition?,
}

export type GuardianPhase = {
	TelegraphScale: number,
	MoveGap: { number },
	WeakPoint: "Back" | "Front",
	Pressure: number?,
	Flood: "Calm" | "High",
}

export type GuardianDef = {
	MobId: string,
	Floor: string,
	NextFloor: string,
	Level: number,
	BaseHealth: number,
	MaxPosture: number,
	BrokenDuration: number,
	HitRadius: number,
	HitHeight: number,
	Arena: string,
	Intro: number,
	Transition: number,
	Phases: { GuardianPhase },
	Tide: {
		HighSeconds: number,
		EbbSeconds: number,
		WarnSeconds: number,
		HighPressure: number,
		EbbPressure: number,
		EbbPostureMultiplier: number,
	},
	Adds: { MobId: string, Base: number, PerTwoExtraPlayers: number, Max: number, Lifetime: number },
	Rewards: { XP: number, GoldMin: number, GoldMax: number, Shards: number, LootTable: string },
	Moves: { [string]: GuardianMove },
}

local Guardians: { [string]: GuardianDef } = {
	-- FLOOR 1: the Brinewarden, Keeper of the First Gate. A towering armoured crab-knight with a
	-- coral greatsword. Damage numbers assume a level 12 Climber (about 250 health): ordinary
	-- blows take 15-20%, heavy ones about 30%, red attacks 40-50%. Nothing is a guaranteed hit.
	Brinewarden = {
		MobId = "Brinewarden",
		Floor = "1",
		NextFloor = "2",
		Level = 12,
		BaseHealth = 7500,
		MaxPosture = 900,
		BrokenDuration = 4,
		HitRadius = 5,
		HitHeight = 9,
		Arena = "Brinewarden",
		Intro = 4.5,
		Transition = 3,
		Phases = {
			{ TelegraphScale = 1.0, MoveGap = { 0.9, 1.6 }, WeakPoint = "Back", Pressure = 3, Flood = "Calm" },
			{ TelegraphScale = 1.0, MoveGap = { 0.7, 1.3 }, WeakPoint = "Back", Pressure = nil, Flood = "High" },
			{ TelegraphScale = 0.85, MoveGap = { 0.45, 0.9 }, WeakPoint = "Front", Pressure = nil, Flood = "High" },
		},
		Tide = {
			HighSeconds = 14,
			EbbSeconds = 7,
			WarnSeconds = 1.5,
			HighPressure = 5,
			EbbPressure = 1,
			EbbPostureMultiplier = 1.5,
		},
		Adds = { MobId = "Bilgecrab", Base = 2, PerTwoExtraPlayers = 1, Max = 5, Lifetime = 60 },
		Rewards = { XP = 2400, GoldMin = 260, GoldMax = 340, Shards = 50, LootTable = "Brinewarden" },
		Moves = {
			-- 1. Two wide sweeps; the first opens from a random side (read the shoulder).
			CoralSweep = {
				Kind = "Sweep",
				Phases = { 1, 2, 3 },
				Weight = 3,
				MinRange = 0,
				MaxRange = 20,
				Cooldown = 0,
				Telegraph = 0.8,
				Blows = { "Light1", "Light2" },
				BlowInterval = 0.7,
				Unparryable = false,
				Blockable = true,
				Damage = 40,
				Posture = 28,
				HitStun = 0.45,
				Recovery = 1.1,
				Reach = 17,
				Arc = 200,
			},
			-- 2. A vertical slam down a line; the blade sticks in the flagstones (long punish).
			OverheadCleave = {
				Kind = "Cleave",
				Phases = { 1, 2, 3 },
				Weight = 2,
				MinRange = 4,
				MaxRange = 30,
				Cooldown = 5,
				Telegraph = 1.1,
				Blows = { "Heavy" },
				Unparryable = false,
				Blockable = false,
				Damage = 75,
				Posture = 40,
				HitStun = 0.7,
				Recovery = 2.2,
				Length = 34,
				Width = 7,
			},
			-- 3. The grab: mostly against a target who keeps blocking. Allies free the victim by
			-- breaking BreakPosture off the Warden while it holds them.
			ClawGrab = {
				Kind = "Grab",
				Phases = { 1, 2, 3 },
				Weight = 1.2,
				MinRange = 0,
				MaxRange = 12,
				Cooldown = 9,
				Telegraph = 0.9,
				Blows = { "Light4" },
				Unparryable = true,
				Blockable = false,
				Damage = 32,
				Posture = 0,
				HitStun = 0.6,
				Recovery = 1.6,
				Reach = 11,
				Arc = 60,
				Hold = 2,
				Crushes = 3,
				BreakPosture = 120,
				Condition = "TargetBlocking",
			},
			-- 4. Shell lowered, it rushes a far target down a line. Block it or dodge sideways.
			ShellRush = {
				Kind = "Rush",
				Phases = { 1, 2, 3 },
				Weight = 1.5,
				MinRange = 24,
				MaxRange = 70,
				Cooldown = 7,
				Telegraph = 1.0,
				Blows = { "Light5" },
				Unparryable = true,
				Blockable = true,
				Damage = 60,
				Posture = 45,
				HitStun = 0.6,
				Recovery = 1.8,
				Length = 60,
				Width = 12,
				Speed = 70,
				Condition = "TargetFar",
			},
			-- 5. Punishes crowding its back: a stomp ring around it.
			BrineStomp = {
				Kind = "Stomp",
				Phases = { 1, 2, 3 },
				Weight = 4,
				MinRange = 0,
				MaxRange = 18,
				Cooldown = 6,
				Telegraph = 0.85,
				Blows = { "Heavy" },
				Unparryable = false,
				Blockable = true,
				Damage = 45,
				Posture = 35,
				HitStun = 0.5,
				Recovery = 1.2,
				Radius = 14,
				Condition = "PlayersBehind",
			},
			-- 6. Phase 2: Bilgecrabs crawl out of the tide pools (count from Adds).
			CallOfTheBrine = {
				Kind = "Summon",
				Phases = { 2 },
				Weight = 1.5,
				MinRange = 0,
				MaxRange = 200,
				Cooldown = 30,
				Telegraph = 1.2,
				Blows = { "Heavy" },
				Unparryable = false,
				Blockable = true,
				Damage = 0,
				Posture = 0,
				HitStun = 0,
				Recovery = 2.0,
			},
			-- 7. Water-jet lances: line telegraphs toward players, then jets down each line.
			WaterLances = {
				Kind = "Lances",
				Phases = { 2, 3 },
				Weight = 2.2,
				MinRange = 0,
				MaxRange = 200,
				Cooldown = 8,
				Telegraph = 1.1,
				Blows = { "Light3" },
				Unparryable = true,
				Blockable = true,
				Damage = 48,
				Posture = 30,
				HitStun = 0.4,
				Recovery = 1.0,
				Length = 70,
				Width = 5,
				Count = 3,
				CountMany = 5,
			},
			-- 8. Area denial: whirlpools under players that drag and soak.
			Undertow = {
				Kind = "Undertow",
				Phases = { 2, 3 },
				Weight = 1.6,
				MinRange = 0,
				MaxRange = 200,
				Cooldown = 14,
				Telegraph = 1.2,
				Blows = { "Light3" },
				Unparryable = true,
				Blockable = false,
				Damage = 9,
				Posture = 0,
				HitStun = 0,
				Recovery = 0.8,
				Radius = 9,
				Count = 4,
				Tick = 0.5,
				Duration = 7,
			},
			-- 9. The Pressure-tide shift: forces the tide to turn now.
			TideSurge = {
				Kind = "Surge",
				Phases = { 2, 3 },
				Weight = 0.9,
				MinRange = 0,
				MaxRange = 200,
				Cooldown = 26,
				Telegraph = 1.0,
				Blows = { "Heavy" },
				Unparryable = false,
				Blockable = true,
				Damage = 0,
				Posture = 0,
				HitStun = 0,
				Recovery = 1.0,
				Condition = "TideNotChanging",
			},
			-- 10. Phase 3: a four-blow string; the last blow glows red.
			DesperateFlurry = {
				Kind = "Flurry",
				Phases = { 3 },
				Weight = 3,
				MinRange = 0,
				MaxRange = 20,
				Cooldown = 4,
				Telegraph = 0.6,
				Blows = { "Light1", "Light2", "Light3", "Heavy" },
				BlowInterval = 0.55,
				Unparryable = { false, false, false, true },
				Blockable = true,
				Damage = 34,
				Posture = 24,
				HitStun = 0.35,
				Recovery = 1.6,
				Reach = 16,
				Arc = 150,
			},
			-- 11. Phase 3: the exposed core bursts around it (punishes hugging the weak point).
			CorePulse = {
				Kind = "Pulse",
				Phases = { 3 },
				Weight = 2,
				MinRange = 0,
				MaxRange = 14,
				Cooldown = 7,
				Telegraph = 0.75,
				Blows = { "Heavy" },
				Unparryable = true,
				Blockable = true,
				Damage = 55,
				Posture = 40,
				HitStun = 0.5,
				Recovery = 1.4,
				Radius = 11,
			},
			-- 12. Phase 3: a ring of water sweeps from the Warden to the walls; only i-frames
			-- (a dodge timed as it passes) avoid it.
			TidalWave = {
				Kind = "Wave",
				Phases = { 3 },
				Weight = 1.2,
				MinRange = 0,
				MaxRange = 200,
				Cooldown = 22,
				Telegraph = 2.0,
				Blows = { "Heavy" },
				Unparryable = true,
				Blockable = false,
				Damage = 120,
				Posture = 0,
				HitStun = 0.8,
				Recovery = 2.0,
				Radius = 72,
				Speed = 34,
			},
		},
	},
}

local GuardiansModule = {}

function GuardiansModule.Get(id: string): GuardianDef?
	return Guardians[id]
end

function GuardiansModule.All(): { [string]: GuardianDef }
	return Guardians
end

-- Is blow `index` of `move` unparryable?
function GuardiansModule.BlowUnparryable(move: GuardianMove, index: number): boolean
	local flag = move.Unparryable
	if type(flag) == "table" then
		return flag[index] == true
	end
	return flag == true
end

-- The phase (1..#thresholds) for a health fraction, given descending thresholds { 1, 0.6, 0.25 }.
function GuardiansModule.PhaseFor(fraction: number, thresholds: { number }): number
	local phase = 1
	for index, threshold in thresholds do
		if fraction <= threshold then
			phase = index
		end
	end
	return phase
end

-- Health for a party: BaseHealth x (1 + scale x (players - 1)), players clamped to 1..maxPlayers.
function GuardiansModule.ScaledHealth(def: GuardianDef, players: number, scale: number, maxPlayers: number): number
	local n = math.clamp(players, 1, maxPlayers)
	return math.floor(def.BaseHealth * (1 + scale * (n - 1)) + 0.5)
end

-- Bilgecrabs summoned for a party.
function GuardiansModule.AddCount(def: GuardianDef, players: number): number
	local adds = def.Adds
	return math.min(adds.Max, adds.Base + adds.PerTwoExtraPlayers * math.floor(math.max(0, players - 1) / 2))
end

return table.freeze(GuardiansModule)
