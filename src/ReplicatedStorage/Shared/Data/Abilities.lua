--!strict
--[[
	Abilities
	The active skills of the five Positions (Spec Section 9): one per skill
	tree branch, unlocked by that branch's Active node (Shared/Data/Positions)
	and cast with the Position key (B / LT+RB / the touch button). One is
	equipped at a time, from the Skill Tree menu.

	An ability is a Move (Shared/Data/Moves) cast like a Weapon Art: it costs
	Current, has its own cooldown and every blow goes through CombatService.

	Power (the damage of a 1.0 step) =
	  weapon damage x (1 - DensityShare + DensityShare x SpellPower(Density))
	  x (1 + AbilityPower bonus)
	so striker abilities grow with the weapon and caster abilities with
	Density. Element "Primary" carries the caster's primary Attunement
	(colour, and statuses on steps that set Stacks or Apply).

	Cooldown is reduced by the AbilityCooldown bonus (capped in
	Config.Progression.BonusCaps), never below Abilities.MinCooldown.

	Names and descriptions: Strings.Abilities. Animations:
	Config.Assets.Animations.Abilities.<Id>.
]]

local Moves = require(script.Parent.Moves)

export type AbilityDef = {
	Id: string,
	Position: string,
	Cost: number, -- Current
	Cooldown: number, -- seconds
	DensityShare: number, -- 0 = pure weapon power, 1 = pure spell power
	Element: "Primary"?, -- carries the primary Attunement
	Move: Moves.Move,
}

local define = Moves.Define

local list: { AbilityDef } = {
	-- VANGUARD -------------------------------------------------------------------

	-- Bulwark: a wall of water shoves foes back and shields you and nearby allies.
	{
		Id = "Seawall",
		Position = "Vanguard",
		Cost = 25,
		Cooldown = 24,
		DensityShare = 0,
		Move = define({
			Id = "Seawall",
			Duration = 0.65,
			HyperArmor = true,
			Animation = "Abilities.Seawall",
			FallbackAnimation = "Heavy",
			AnimationSpeed = 1.2,
			Steps = {
				{ At = 0.2, Do = "Circle", Radius = 7, Damage = 0.4, Posture = 1.5, Visual = "Seawall", Camera = "Punch" },
				{ At = 0.2, Do = "Push", Radius = 8, Strength = 8 },
				{ At = 0.25, Do = "Shield", Fraction = 0.25, Duration = 8, Allies = 18 },
				{ At = 0.25, Do = "Buff", Bonuses = { Armor = 0.12 }, Duration = 8, Allies = 18 },
			},
		}),
	},
	-- Challenge: a bell-toll every enemy nearby must answer.
	{
		Id = "HarborBell",
		Position = "Vanguard",
		Cost = 15,
		Cooldown = 18,
		DensityShare = 0,
		Move = define({
			Id = "HarborBell",
			Duration = 0.55,
			HyperArmor = true,
			Animation = "Abilities.HarborBell",
			FallbackAnimation = "Light4",
			Steps = {
				{ At = 0.2, Do = "Taunt", Radius = 22, Duration = 6, Visual = "Bell", Camera = "Shake" },
				{ At = 0.2, Do = "Circle", Radius = 10, Damage = 0.3, Posture = 1.2 },
				{ At = 0.25, Do = "Buff", Bonuses = { Armor = 0.1, GuardPosture = 0.3 }, Duration = 6 },
			},
		}),
	},
	-- Breaker: a leaping hull-splitting smash that shreds posture.
	{
		Id = "Keelbreaker",
		Position = "Vanguard",
		Cost = 20,
		Cooldown = 14,
		DensityShare = 0,
		Move = define({
			Id = "Keelbreaker",
			Duration = 1,
			HyperArmor = true,
			Animation = "Abilities.Keelbreaker",
			FallbackAnimation = "Heavy",
			AnimationSpeed = 0.8,
			Steps = {
				{ At = 0.1, Do = "Leap", Distance = 10, Duration = 0.45, Height = 7 },
				{ At = 0.55, Do = "Circle", Where = "Anchor", Radius = 9, Damage = 1.6, Posture = 4, Launch = 4, Visual = "Keelbreaker", Camera = "Shake" },
			},
		}),
	},

	-- LANCER ---------------------------------------------------------------------

	-- Edge: a flurry of glinting cuts that leaps to nearby foes.
	{
		Id = "Glintstorm",
		Position = "Lancer",
		Cost = 20,
		Cooldown = 12,
		DensityShare = 0,
		Move = define({
			Id = "Glintstorm",
			Duration = 1.05,
			HyperArmor = false,
			Animation = "Abilities.Glintstorm",
			FallbackAnimation = "Light2",
			AnimationSpeed = 1.4,
			Steps = {
				{ At = 0.15, Do = "Arc", Reach = 8, Arc = 120, Damage = 0.45, Posture = 0.6, Hits = 4, Interval = 0.13, CritBonus = 0.25, Visual = "Glint" },
				{ At = 0.8, Do = "Chain", Count = 3, Range = 12, Damage = 0.6, CritBonus = 0.25 },
			},
		}),
	},
	-- Surge: a riptide dash through the line, then a sweeping cut where you land.
	{
		Id = "RiptideLunge",
		Position = "Lancer",
		Cost = 15,
		Cooldown = 8,
		DensityShare = 0,
		Move = define({
			Id = "RiptideLunge",
			Duration = 0.6,
			HyperArmor = false,
			Animation = "Abilities.RiptideLunge",
			FallbackAnimation = "Light5",
			Steps = {
				{ At = 0.05, Do = "Dash", Distance = 18, Duration = 0.3, Width = 4, Damage = 1.2, Posture = 1.2, IFrames = 0.35, Visual = "Riptide" },
				{ At = 0.45, Do = "Arc", Where = "Anchor", Reach = 7, Arc = 140, Damage = 0.6, Posture = 0.8 },
			},
		}),
	},
	-- Reaper: one long severing thrust that doubles on the nearly dead.
	{
		Id = "Severance",
		Position = "Lancer",
		Cost = 25,
		Cooldown = 15,
		DensityShare = 0,
		Move = define({
			Id = "Severance",
			Duration = 0.9,
			HyperArmor = true,
			Animation = "Abilities.Severance",
			FallbackAnimation = "Light3",
			AnimationSpeed = 0.8,
			Steps = {
				{ At = 0.35, Do = "Line", Length = 12, Width = 3, Damage = 2.4, Posture = 2, CritBonus = 0.15, Execute = 1, Visual = "Severance", Camera = "Punch" },
			},
		}),
	},

	-- TIDECALLER -----------------------------------------------------------------

	-- Wellspring: drink deep from the Current; spells hit harder and come faster.
	{
		Id = "Floodtide",
		Position = "Tidecaller",
		Cost = 0,
		Cooldown = 30,
		DensityShare = 1,
		Element = "Primary",
		Move = define({
			Id = "Floodtide",
			Duration = 0.5,
			HyperArmor = false,
			Animation = "Abilities.Floodtide",
			FallbackAnimation = "Casting.Cast2H",
			Steps = {
				{ At = 0.2, Do = "Refill", Fraction = 0.35, Visual = "Floodtide" },
				{ At = 0.2, Do = "Buff", Bonuses = { SpellDamage = 0.2, CastSpeed = 0.15 }, Duration = 10 },
			},
		}),
	},
	-- Maelstrom: a thrown vortex drags foes together and grinds them down.
	{
		Id = "Maelstrom",
		Position = "Tidecaller",
		Cost = 35,
		Cooldown = 20,
		DensityShare = 0.8,
		Element = "Primary",
		Move = define({
			Id = "Maelstrom",
			Duration = 0.7,
			HyperArmor = false,
			Animation = "Abilities.Maelstrom",
			FallbackAnimation = "Casting.Cast2H",
			Steps = {
				{ At = 0.25, Do = "Projectile", Speed = 60, Range = 26, Radius = 2, Damage = 0.5, Posture = 0.5, SetAnchor = true, Stacks = 1 },
				{ At = 0.65, Do = "Pull", Where = "Anchor", Radius = 14, Strength = 10, Duration = 0.4 },
				{ At = 0.7, Do = "Field", Where = "Anchor", Radius = 9, Duration = 4, Interval = 0.5, Damage = 0.3, Posture = 0.3, Stacks = 1, Visual = "Maelstrom" },
			},
		}),
	},
	-- Catalyst: a pulse that soaks everything nearby in your element, then detonates.
	{
		Id = "CatalystPulse",
		Position = "Tidecaller",
		Cost = 30,
		Cooldown = 16,
		DensityShare = 0.8,
		Element = "Primary",
		Move = define({
			Id = "CatalystPulse",
			Duration = 0.9,
			HyperArmor = false,
			Animation = "Abilities.CatalystPulse",
			FallbackAnimation = "Casting.Cast1H",
			Steps = {
				{ At = 0.3, Do = "Circle", Radius = 12, Damage = 0.6, Posture = 0.6, Stacks = 2, Visual = "Catalyst" },
				{ At = 0.85, Do = "Burst", Radius = 5, Delay = 0.3, Damage = 0.9, Posture = 1, Stacks = 1 },
			},
		}),
	},

	-- BEACONKEEPER ---------------------------------------------------------------

	-- Lightkeeper: your Beacons flare - Sentries hit harder, Aegis and Relay recover faster.
	{
		Id = "Kindle",
		Position = "Beaconkeeper",
		Cost = 20,
		Cooldown = 25,
		DensityShare = 0.8,
		Element = "Primary",
		Move = define({
			Id = "Kindle",
			Duration = 0.5,
			HyperArmor = false,
			Animation = "Abilities.Kindle",
			FallbackAnimation = "Casting.Cast1H",
			Steps = {
				{ At = 0.2, Do = "Buff", Bonuses = { SentryDamage = 0.5, AegisRecharge = 0.4, RelayCooldown = 0.3 }, Duration = 12 },
				{ At = 0.2, Do = "Circle", Radius = 9, Damage = 0.5, Posture = 0.5, Visual = "Kindle" },
			},
		}),
	},
	-- Wellkeeper: a healing spring that mends allies and stings foes standing in it.
	{
		Id = "Tidewell",
		Position = "Beaconkeeper",
		Cost = 30,
		Cooldown = 24,
		DensityShare = 1,
		Element = "Primary",
		Move = define({
			Id = "Tidewell",
			Duration = 0.6,
			HyperArmor = false,
			Animation = "Abilities.Tidewell",
			FallbackAnimation = "Casting.Cast2H",
			Steps = {
				{ At = 0.3, Do = "Field", Radius = 10, Duration = 6, Interval = 1, Damage = 0.25, Posture = 0.2, HealFraction = 0.04, Visual = "Tidewell" },
			},
		}),
	},
	-- Lanternguard: a lantern-flare heals and steadies everyone around you.
	{
		Id = "GuidingLantern",
		Position = "Beaconkeeper",
		Cost = 25,
		Cooldown = 30,
		DensityShare = 1,
		Move = define({
			Id = "GuidingLantern",
			Duration = 0.55,
			HyperArmor = false,
			Animation = "Abilities.GuidingLantern",
			FallbackAnimation = "Casting.Cast1H",
			Steps = {
				{ At = 0.3, Do = "Heal", Fraction = 0.18, Allies = 30, Renewing = true, Visual = "Lantern" },
				{ At = 0.3, Do = "Buff", Bonuses = { StaminaRegen = 0.3, Armor = 0.08 }, Duration = 10, Allies = 30 },
			},
		}),
	},

	-- PATHFINDER -----------------------------------------------------------------

	-- Trailblazer: a slipping dash through danger, then quicker feet for a while.
	{
		Id = "Windstep",
		Position = "Pathfinder",
		Cost = 10,
		Cooldown = 9,
		DensityShare = 0,
		Move = define({
			Id = "Windstep",
			Duration = 0.45,
			HyperArmor = false,
			Animation = "Abilities.Windstep",
			FallbackAnimation = "Dodge",
			Steps = {
				{ At = 0.02, Do = "Dash", Distance = 20, Duration = 0.25, Width = 3, Damage = 0.4, Posture = 0.4, IFrames = 0.3, Visual = "Windstep" },
				{ At = 0.3, Do = "Buff", Bonuses = { MoveSpeed = 0.25, DodgeCost = 0.3 }, Duration = 5 },
			},
		}),
	},
	-- Snare: a thrown trap of wire roots anything that walks over it.
	{
		Id = "Tanglewire",
		Position = "Pathfinder",
		Cost = 20,
		Cooldown = 18,
		DensityShare = 0,
		Move = define({
			Id = "Tanglewire",
			Duration = 0.6,
			HyperArmor = false,
			Animation = "Abilities.Tanglewire",
			FallbackAnimation = "Light1",
			Steps = {
				{ At = 0.3, Do = "Projectile", Speed = 50, Range = 18, Radius = 1.5, Damage = 0.3, Posture = 0.3, SetAnchor = true },
				{ At = 0.6, Do = "Field", Where = "Anchor", Radius = 7, Duration = 8, Interval = 1, Damage = 0.35, Posture = 0.5, Apply = "Rooted", Visual = "Tanglewire" },
			},
		}),
	},
	-- Seeker: a marking bolt that finds the seam in a foe's guard.
	{
		Id = "ExposeWeakness",
		Position = "Pathfinder",
		Cost = 15,
		Cooldown = 14,
		DensityShare = 0,
		Move = define({
			Id = "ExposeWeakness",
			Duration = 0.55,
			HyperArmor = false,
			Animation = "Abilities.ExposeWeakness",
			FallbackAnimation = "Light1",
			Steps = {
				{ At = 0.25, Do = "Projectile", Speed = 90, Range = 40, Radius = 1.5, Damage = 0.6, Posture = 0.6, Visual = "Seeker" },
				-- After the bolt can have landed (40 studs at 90 studs/s).
				{ At = 0.75, Do = "Mark", Duration = 10, Bonus = 2.5 },
			},
		}),
	},
}

local byId: { [string]: AbilityDef } = {}
for _, def in list do
	assert(byId[def.Id] == nil, `ability {def.Id} defined twice`)
	byId[def.Id] = table.freeze(def)
end

local Abilities = {}

Abilities.List = table.freeze(list)

function Abilities.Get(id: string): AbilityDef?
	return byId[id]
end

return table.freeze(Abilities)
