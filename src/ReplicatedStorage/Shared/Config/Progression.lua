--!strict
-- Levels, stats and skill progression (Spec Section 9).

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

export type ArchetypeRule = {
	Id: string,
	Classes: { string }?,
	Attunements: { string }?,
	Share: { Stats: { string }, Min: number }?,
}

local archetypes: { ArchetypeRule } = {
	{ Id = "Depthbreaker", Classes = { "Greatblade" }, Attunements = { "Abyss" } },
	{ Id = "Stormrunner", Classes = { "Twinfangs" }, Attunements = { "Tempest" } },
	{ Id = "Warden", Attunements = { "Rime", "Bloom" }, Share = { Stats = { "Vitality", "Endurance" }, Min = 0.4 } },
	{ Id = "Currentweaver", Share = { Stats = { "Draw", "Density", "Control" }, Min = 0.5 } },
	{ Id = "Bladecaller" },
}

return TableUtil.DeepFreeze({
	LevelCap = 60,
	LevelsPerFloor = 12,

	-- XP to go from `level` to `level + 1` = floor(Base * level ^ Exponent)
	XP = {
		Base = 120,
		Exponent = 1.65,
	},

	StatPointsPerLevel = 3,
	SkillPointsPerLevel = 1,
	SkillPointsFromLevel = 15,
	GuardianBonusSkillPoints = 1,

	PartyXP = {
		ShareRadius = 150,
		BonusPerExtraMember = 0.10,
	},

	-- Per-point effects of each stat.
	Stats = {
		Vitality = { HealthPerPoint = 12, DamageReductionPerFivePoints = 0.01 },
		Endurance = { StaminaPerPoint = 4, StaminaRegenPerPoint = 0.4, EquipWeightPerPoint = 1.5 },
		Strength = { ScalingPerPoint = 0.025, PosturePerPoint = 0.015 },
		Finesse = { ScalingPerPoint = 0.025, CritChancePerPoint = 0.003, AttackSpeedPerPoint = 0.002 },
		Draw = { RegenPerPoint = 0.03, SiphonPerPoint = 0.02, VesselPerPoint = 3 },
		Density = { SpellDamagePerPoint = 0.025, ShieldPerPoint = 0.02, SpellPosturePerPoint = 0.015 },
		Control = { CastSpeedPerPoint = 0.004, AreaPerPoint = 0.006, CostReductionPerPoint = 0.003 },
	},

	-- Points beyond each threshold count for less: [0..40] = 100%, (40..60] = 50%, (60..] = 25%.
	SoftCaps = {
		{ Threshold = 40, Multiplier = 0.5 },
		{ Threshold = 60, Multiplier = 0.25 },
	},

	BaseEquipWeight = 40,

	Positions = {
		UnlockLevel = 15,
		StationKind = "Positions", -- the Hall of Positions in Lowharbor (a station with this StationKind)
	},

	-- Skill tree node costs in skill points (Shared/Data/Positions).
	NodeCosts = {
		Minor = 1,
		Notable = 2,
		Active = 2,
		Keystone = 3,
	},

	-- Caps on tree and gear bonuses that would break the game if stacked forever.
	BonusCaps = {
		BlockCost = 0.75, -- stamina for blocked damage, at most 75% cheaper
		GuardPosture = 0.75,
		DodgeCost = 0.6,
		AbilityCooldown = 0.5,
		MoveSpeed = 0.35,
	},

	-- Lancer "execution": blows on enemies at or below this health fraction
	-- deal +ExecuteDamage (and abilities' own Execute bonus).
	ExecuteThreshold = 0.35,

	-- Respec: stat points and the skill tree go back to unspent; the Position
	-- is kept unless the player also asks to change it (then they choose
	-- again at the Hall). Gold = GoldPerLevel x level; the first is free.
	Respec = {
		FirstFree = true,
		GoldPerLevel = 75,
	},

	-- First-time discoveries (Spec Section 9 XP sources).
	DiscoveryXP = {
		Waystone = 60, -- + PerLevel x the player's level
		Secret = 120, -- a hidden area (SecretService)
		Cache = 40, -- opening a hidden cache
		PerLevel = 10,
	},

	LevelUp = {
		FullHeal = true,
		PillarRadius = 120, -- players within this many studs see someone's level-up pillar
	},

	-- Stat allocation: the most points one request may move.
	MaxAllocationPerRequest = 200,

	-- Abilities (the Position key): cast like Weapon Arts.
	Abilities = {
		MinCooldown = 2, -- seconds, after AbilityCooldown reductions
	},

	-- Archetype names on the Character sheet (Spec Section 9 "Class identities").
	-- The first rule that matches names the build: Classes = equipped weapon
	-- class, Attunements = primary Attunement, Share = those stats hold at
	-- least Min of the player's own invested points (gear doesn't count).
	Archetypes = archetypes,
})
