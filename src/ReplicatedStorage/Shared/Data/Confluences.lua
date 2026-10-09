--!strict
--[[
	Confluences
	The Resonance payoff (Spec Section 8): at max Resonance the Weapon Art
	button becomes Confluence, a finisher that fuses the equipped weapon
	class with the primary Attunement. 6 classes x 5 Attunements = 30.

	Each weapon class has one motion (its animation, Config.Assets
	.Animations.Confluences.<Class>); the Attunement gives it its own shape,
	status, control effect and visuals. Every Confluence:
	  - costs Config.Current.Confluence.CurrentCost and consumes all stacks,
	  - starts with Config.Current.Confluence.Invulnerability seconds of
	    invincibility and has hyper armour throughout,
	  - lasts at most Config.Current.Confluence.MaxDuration seconds
	    (steps scheduled after Duration, such as Fields, keep going without
	    holding the caster).
	Hits apply the Attunement's status once unless a step says otherwise
	(Stacks / Apply). Names and descriptions: Strings.Confluences.
	The step format is Shared/Data/Moves.
]]

local Config = require(script.Parent.Parent.Config)
local Moves = require(script.Parent.Moves)

type Step = Moves.Step

export type ConfluenceDef = {
	Id: string, -- "<Class>_<Attunement>"
	Class: string,
	Attunement: string,
	Move: Moves.Move,
}

local MAX_DURATION = Config.Current.Confluence.MaxDuration

local confluences: { [string]: ConfluenceDef } = {}

local function add(class: string, attunement: string, duration: number, steps: { Step }, fallback: string, speed: number?)
	local id = `{class}_{attunement}`
	assert(duration <= MAX_DURATION, `{id} is longer than {MAX_DURATION} s`)
	confluences[id] = table.freeze({
		Id = id,
		Class = class,
		Attunement = attunement,
		Move = Moves.Define({
			Id = id,
			Duration = duration,
			HyperArmor = true,
			Animation = `Confluences.{class}`,
			FallbackAnimation = fallback,
			AnimationSpeed = speed,
			Steps = steps,
		}),
	})
end

-- LONGSWORD: a rising slash, then the blade is planted and the element erupts.
local function rise(): Step
	return { At = 0.3, Do = "Arc", Reach = 9, Arc = 150, Damage = 2, Posture = 2, Visual = "Rise", IFrames = 0 }
end

add("Longsword", "Tide", 1.6, {
	rise(),
	{ At = 1, Do = "Circle", Radius = 12, Damage = 2.5, Posture = 2.5, Visual = "TideRing", Camera = "Punch" },
	{ At = 1, Do = "Push", Radius = 12, Strength = 12, Duration = 0.35, Direction = "Out" },
}, "Light5")
add("Longsword", "Rime", 1.7, {
	rise(),
	{ At = 1, Do = "Circle", Radius = 11, Damage = 2.2, Posture = 2, Apply = "Frozen", Stacks = 0, Visual = "IceRing", Camera = "Punch" },
	{ At = 1.45, Do = "Circle", Radius = 11, Damage = 1.2, Posture = 1, Stacks = 0, Visual = "IceSpikes" },
}, "Light5")
add("Longsword", "Tempest", 1.8, {
	rise(),
	{ At = 1, Do = "Strikes", Radius = 18, Count = 3, Interval = 0.15, StrikeRadius = 4, Damage = 1.8, Posture = 1.5, Visual = "Lightning" },
	{ At = 1.45, Do = "Circle", Radius = 8, Damage = 1, Posture = 1, Visual = "Thunderclap", Camera = "Shake" },
}, "Light5")
add("Longsword", "Abyss", 1.8, {
	rise(),
	{ At = 0.9, Do = "Pull", Radius = 16, Strength = 10, Duration = 0.4, Direction = "In", Visual = "GravityPull" },
	{ At = 1.35, Do = "Circle", Radius = 9, Damage = 2.6, Posture = 3, Visual = "Implode", Camera = "Punch" },
}, "Light5")
-- Spec example: Verdant Oath, a rising slash that plants a blooming circle.
add("Longsword", "Bloom", 1.7, {
	rise(),
	{ At = 1, Do = "Circle", Radius = 12, Damage = 1.2, Posture = 1, Visual = "Bloom", Camera = "Punch" },
	{ At = 1, Do = "Heal", Fraction = 0.15, Allies = 12, Renewing = true },
	{ At = 1.05, Do = "Field", Radius = 12, Duration = 5, Interval = 1, Damage = 0.35, HealFraction = 0.04, Visual = "BloomCircle" },
}, "Light5")

-- GREATBLADE: a towering leap and a slam, then the element follows through.
local function leap(): Step
	return { At = 0, Do = "Leap", Distance = 10, Duration = 0.8, Height = 9 }
end
local function slam(): Step
	return { At = 0.85, Do = "Circle", Where = "Anchor", Radius = 8, Damage = 2.4, Posture = 2.5, Visual = "Crater", Camera = "Shake" }
end

-- Spec example: Tidebreaker, a towering wave that crashes forward and drags enemies.
add("Greatblade", "Tide", 2, {
	leap(),
	slam(),
	{ At = 0.95, Do = "Line", Where = "Anchor", Length = 22, Width = 9, Damage = 1.8, Posture = 1.5, Visual = "TidalWave" },
	{ At = 0.95, Do = "Push", Where = "Anchor", Radius = 16, Strength = 12, Duration = 0.5, Direction = "Aim" },
}, "Heavy", 0.7)
add("Greatblade", "Rime", 1.9, {
	leap(),
	slam(),
	{ At = 1.3, Do = "Circle", Where = "Anchor", Radius = 13, Damage = 1.4, Posture = 1.5, Stacks = 2, Visual = "IceSpikes" },
}, "Heavy", 0.7)
add("Greatblade", "Tempest", 1.9, {
	leap(),
	slam(),
	{ At = 1.2, Do = "Circle", Where = "Anchor", Radius = 14, Damage = 1.6, Posture = 1.5, Visual = "LightningColumn", Camera = "Shake" },
	{ At = 1.25, Do = "Chain", Count = 3, Range = 14, Damage = 0.8, Posture = 0.5, Visual = "Chain" },
}, "Heavy", 0.7)
add("Greatblade", "Abyss", 2.1, {
	leap(),
	slam(),
	{ At = 0.95, Do = "Pull", Where = "Anchor", Radius = 18, Strength = 12, Duration = 0.5, Direction = "In", Visual = "GravityPull" },
	{ At = 1.55, Do = "Circle", Where = "Anchor", Radius = 10, Damage = 2.4, Posture = 3, Visual = "Implode", Camera = "Punch" },
}, "Heavy", 0.7)
add("Greatblade", "Bloom", 1.9, {
	leap(),
	slam(),
	{ At = 1.1, Do = "Line", Where = "Anchor", Length = 24, Width = 7, Damage = 1.6, Posture = 1.5, Visual = "RootLine" },
	{ At = 1.1, Do = "Heal", Fraction = 0.15, Allies = 10 },
}, "Heavy", 0.7)

-- TWINFANGS: blinking from enemy to enemy, cutting each one.
local function blink(maxTargets: number, interval: number, damage: number): Step
	return { At = 0.05, Do = "Blink", Range = 22, MaxTargets = maxTargets, Interval = interval, Damage = damage, Posture = 1, Visual = "BlinkSlash" }
end

-- Spec example: Stormdance, blinks between up to 6 enemies, ending with a lightning crack.
add("Twinfangs", "Tempest", 2.1, {
	blink(6, 0.2, 0.9),
	{ At = 1.5, Do = "Circle", Where = "Anchor", Radius = 10, Damage = 1.6, Posture = 1.5, Visual = "Thunderclap", Camera = "Shake" },
}, "Light2", 1.5)
add("Twinfangs", "Tide", 2, {
	blink(4, 0.24, 1),
	{ At = 1.2, Do = "Pull", Where = "Anchor", Radius = 14, Strength = 10, Duration = 0.4, Direction = "In", Visual = "Whirlpool" },
	{ At = 1.6, Do = "Circle", Where = "Anchor", Radius = 8, Damage = 1.6, Posture = 1.5, Visual = "TideRing", Camera = "Punch" },
}, "Light2", 1.5)
add("Twinfangs", "Rime", 1.9, {
	blink(5, 0.22, 0.9),
	{ At = 1.45, Do = "Burst", Delay = 0, Radius = 5, Damage = 1.1, Posture = 1, Visual = "IceShatter", Camera = "Punch" },
}, "Light2", 1.5)
add("Twinfangs", "Abyss", 2.1, {
	blink(5, 0.22, 0.9),
	{ At = 1.3, Do = "Pull", Where = "Anchor", Radius = 22, Strength = 14, Duration = 0.35, Direction = "In", OnlyHit = true, Visual = "GravityPull" },
	{ At = 1.7, Do = "Circle", Where = "Anchor", Radius = 7, Damage = 2, Posture = 2.5, Visual = "Implode", Camera = "Punch" },
}, "Light2", 1.5)
add("Twinfangs", "Bloom", 1.8, {
	blink(5, 0.22, 0.9),
	{ At = 1.3, Do = "Leech", Fraction = 0.35 },
	{ At = 1.3, Do = "Field", Where = "Anchor", Radius = 8, Duration = 4, Interval = 1, Damage = 0.3, HealFraction = 0.03, Visual = "BloomCircle" },
}, "Light2", 1.5)

-- SPIRE LANCE: the spear is hurled; the element shapes what happens where it lands.
local function hurl(pierce: boolean): Step
	return {
		At = 0.3,
		Do = "Projectile",
		Angles = { 0 },
		Speed = 90,
		Range = 36,
		Radius = if pierce then 2 else 1.5,
		Pierce = pierce,
		SetAnchor = true,
		Damage = 1.9,
		Posture = 2,
		Visual = "Spear",
	}
end

-- Spec example: Gravespear, the spear becomes a gravity well, pulls enemies in, then collapses.
add("SpireLance", "Abyss", 2, {
	hurl(false),
	{ At = 0.75, Do = "Pull", Where = "Anchor", Radius = 16, Strength = 12, Duration = 0.8, Direction = "In", Visual = "GravityWell" },
	{ At = 1.6, Do = "Circle", Where = "Anchor", Radius = 9, Damage = 2.6, Posture = 3, Visual = "Implode", Camera = "Punch" },
}, "Heavy", 0.8)
add("SpireLance", "Tide", 1.8, {
	hurl(true),
	{ At = 0.8, Do = "Pull", Radius = 40, Strength = 20, Duration = 0.4, Direction = "In", OnlyHit = true, Visual = "Harpoon" },
	{ At = 1.3, Do = "Arc", Reach = 8, Arc = 140, Damage = 1.8, Posture = 2, Visual = "Rise", Camera = "Punch" },
}, "Heavy", 0.8)
add("SpireLance", "Rime", 1.5, {
	hurl(true),
	{ At = 0.75, Do = "Circle", Where = "Anchor", Radius = 10, Damage = 1.2, Posture = 1.5, Apply = "Frozen", Stacks = 0, Visual = "IceRing", Camera = "Punch" },
}, "Heavy", 0.8)
add("SpireLance", "Tempest", 1.8, {
	hurl(false),
	{ At = 0.7, Do = "Strikes", Where = "Anchor", Radius = 12, Count = 4, Interval = 0.25, StrikeRadius = 4, Damage = 1, Posture = 1, Visual = "Lightning" },
}, "Heavy", 0.8)
add("SpireLance", "Bloom", 1.4, {
	hurl(false),
	{ At = 0.7, Do = "Circle", Where = "Anchor", Radius = 8, Damage = 0.8, Posture = 1, Visual = "Bloom" },
	{ At = 0.7, Do = "Field", Where = "Anchor", Radius = 12, Duration = 6, Interval = 1, Damage = 0.4, HealFraction = 0.04, Visual = "BloomCircle" },
}, "Heavy", 0.8)

-- NEEDLE: one deep, certain thrust; the element blooms from the wound.
local function thrust(damage: number, apply: string?): Step
	return {
		At = 0.25,
		Do = "Arc",
		Reach = 11,
		Arc = 30,
		Single = true,
		Crit = true,
		SetAnchor = true,
		Damage = damage,
		Posture = 2,
		Apply = apply,
		Stacks = if apply then 0 else nil,
		Visual = "Thrust",
		Camera = "Punch",
	}
end

-- Spec example: Frostbloom, freezes the target and grows ice spikes; the next hit shatters them.
add("Needle", "Rime", 1.2, {
	thrust(2.2, "Frozen"),
	{ At = 0.6, Do = "Circle", Where = "Anchor", Radius = 8, Damage = 0.8, Posture = 1, Visual = "IceSpikes" },
	{ At = 0.6, Do = "Mark", Duration = 4, Bonus = 2.5, Visual = "ShatterMark" },
}, "Light1", 0.6)
add("Needle", "Tide", 1, {
	thrust(2, nil),
	{ At = 0.35, Do = "Line", Length = 28, Width = 3, Damage = 1.6, Posture = 1.5, Visual = "WaterJet" },
}, "Light1", 0.6)
add("Needle", "Tempest", 1.1, {
	thrust(2, nil),
	{ At = 0.45, Do = "Chain", Count = 4, Range = 16, Damage = 1, Posture = 0.8, Visual = "Chain" },
}, "Light1", 0.6)
add("Needle", "Abyss", 1.5, {
	thrust(1.8, nil),
	{ At = 0.4, Do = "Burst", Delay = 0.85, Radius = 7, Damage = 3, Posture = 3, Visual = "Implode", Camera = "Punch" },
}, "Light1", 0.6)
add("Needle", "Bloom", 1, {
	thrust(2.2, nil),
	{ At = 0.4, Do = "Leech", Fraction = 0.6 },
	{ At = 0.4, Do = "Circle", Where = "Anchor", Radius = 6, Damage = 0.6, Posture = 0.5, Visual = "Bloom" },
}, "Light1", 0.6)

-- ARCBLADE: Overcurrent, three crescent waves of the element in a fan (spec example).
local function fan(angles: { number }, stacks: number?): Step
	return {
		At = 0.25,
		Do = "Projectile",
		Angles = angles,
		Speed = 75,
		Range = 34,
		Radius = 3,
		Pierce = true,
		SetAnchor = true,
		Damage = 1.5,
		Posture = 1.2,
		Stacks = stacks,
		Visual = "Crescent",
		Camera = "Punch",
	}
end

add("Arcblade", "Tide", 1.2, {
	fan({ -22, 0, 22 }, nil),
	{ At = 0.55, Do = "Push", Radius = 40, Strength = 10, Duration = 0.4, Direction = "Out", OnlyHit = true },
}, "Light5")
add("Arcblade", "Rime", 1.3, {
	fan({ -22, 0, 22 }, 2),
	{ At = 0.75, Do = "Field", Where = "Anchor", Radius = 9, Duration = 4, Interval = 1, Damage = 0.35, Visual = "FrostField" },
}, "Light5")
add("Arcblade", "Tempest", 1.2, {
	fan({ -22, 0, 22 }, nil),
	{ At = 0.6, Do = "Chain", Count = 2, Range = 14, Damage = 0.7, Posture = 0.5, Visual = "Chain" },
}, "Light5")
add("Arcblade", "Abyss", 1.6, {
	fan({ -30, 0, 30 }, nil),
	{ At = 0.75, Do = "Pull", Where = "Anchor", Radius = 16, Strength = 10, Duration = 0.4, Direction = "In", Visual = "GravityPull" },
	{ At = 1.2, Do = "Circle", Where = "Anchor", Radius = 8, Damage = 1.8, Posture = 2, Visual = "Implode", Camera = "Punch" },
}, "Light5")
add("Arcblade", "Bloom", 1.2, {
	fan({ -22, 0, 22 }, nil),
	{ At = 0.5, Do = "Heal", Fraction = 0.12, Allies = 34, Renewing = true },
}, "Light5")

table.freeze(confluences)

local Confluences = {}

function Confluences.Get(class: string, attunement: string): ConfluenceDef?
	return confluences[`{class}_{attunement}`]
end

function Confluences.All(): { [string]: ConfluenceDef }
	return confluences
end

return table.freeze(Confluences)
