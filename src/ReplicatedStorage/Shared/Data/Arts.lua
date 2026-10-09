--!strict
--[[
	Arts
	Weapon Arts (Spec Section 7): every weapon class has one, cast by tapping
	the Weapon Art button (R / LT+RT / the glowing touch button) while
	Resonance is below max. Each costs Current and has a cooldown. The step
	format is Shared/Data/Moves. Names and descriptions: Strings.Arts.

	Damage and Posture in steps are multiples of the weapon's own scaled base
	damage / posture, so an Art grows with the weapon and the player's stats.
]]

local Moves = require(script.Parent.Moves)

export type ArtDef = {
	Id: string,
	Class: string,
	Cost: number, -- Current
	Cooldown: number,
	Move: Moves.Move,
}

local define = Moves.Define

local Arts: { [string]: ArtDef } = {
	-- Longsword: a rising launcher slash that throws light enemies into the air.
	Longsword = {
		Id = "RisingArc",
		Class = "Longsword",
		Cost = 20,
		Cooldown = 8,
		Move = define({
			Id = "RisingArc",
			Duration = 0.75,
			HyperArmor = false,
			Animation = "Arts.Longsword",
			FallbackAnimation = "Light5",
			Steps = {
				{ At = 0.22, Do = "Arc", Reach = 8, Arc = 130, Damage = 1.8, Posture = 2.2, Launch = 9, Visual = "RisingArc" },
			},
		}),
	},
	-- Greatblade: a leaping overhead smash with a shockwave where it lands.
	Greatblade = {
		Id = "Crater",
		Class = "Greatblade",
		Cost = 25,
		Cooldown = 10,
		Move = define({
			Id = "Crater",
			Duration = 1.05,
			HyperArmor = true,
			Animation = "Arts.Greatblade",
			FallbackAnimation = "Heavy",
			AnimationSpeed = 0.75,
			Steps = {
				{ At = 0, Do = "Leap", Distance = 8, Duration = 0.5, Height = 6 },
				{ At = 0.5, Do = "Circle", Where = "Anchor", Radius = 9, Damage = 2.2, Posture = 2.6, Visual = "Crater", Camera = "Shake" },
			},
		}),
	},
	-- Twinfangs: a spinning dash that cuts everything along the way twice.
	Twinfangs = {
		Id = "Whirl",
		Class = "Twinfangs",
		Cost = 20,
		Cooldown = 8,
		Move = define({
			Id = "Whirl",
			Duration = 0.7,
			HyperArmor = false,
			Animation = "Arts.Twinfangs",
			FallbackAnimation = "Light3",
			Steps = {
				{ At = 0.05, Do = "Dash", Distance = 12, Duration = 0.45, Width = 3.5, Damage = 0.9, Posture = 1, Hits = 2, Interval = 0.2, Visual = "Whirl" },
			},
		}),
	},
	-- Spire Lance: a charging thrust that pierces every enemy in its path.
	SpireLance = {
		Id = "SkewerRush",
		Class = "SpireLance",
		Cost = 22,
		Cooldown = 9,
		Move = define({
			Id = "SkewerRush",
			Duration = 0.85,
			HyperArmor = false,
			Animation = "Arts.SpireLance",
			FallbackAnimation = "Heavy",
			Steps = {
				{ At = 0.1, Do = "Dash", Distance = 16, Duration = 0.5, Width = 3, Damage = 2, Posture = 2, Visual = "Skewer" },
			},
		}),
	},
	-- Needle: a flurry of six quick thrusts, each likelier to crit.
	Needle = {
		Id = "ThousandPoints",
		Class = "Needle",
		Cost = 22,
		Cooldown = 9,
		Move = define({
			Id = "ThousandPoints",
			Duration = 1,
			HyperArmor = false,
			Animation = "Arts.Needle",
			FallbackAnimation = "Light1",
			AnimationSpeed = 2.5,
			Steps = {
				{ At = 0.12, Do = "Arc", Reach = 7.5, Arc = 40, Damage = 0.45, Posture = 0.4, Hits = 6, Interval = 0.12, CritBonus = 0.2, Visual = "Flurry" },
			},
		}),
	},
	-- Arcblade: the blade's Current flies off as a piercing crescent.
	Arcblade = {
		Id = "EdgeRelease",
		Class = "Arcblade",
		Cost = 20,
		Cooldown = 7,
		Move = define({
			Id = "EdgeRelease",
			Duration = 0.7,
			HyperArmor = false,
			Animation = "Arts.Arcblade",
			FallbackAnimation = "Light5",
			Steps = {
				{ At = 0.2, Do = "Projectile", Angles = { 0 }, Speed = 70, Range = 36, Radius = 3, Pierce = true, Damage = 1.6, Posture = 1.4, Visual = "Crescent" },
			},
		}),
	},
}

for _, art in Arts do
	table.freeze(art)
end

local ArtsModule = {}

-- The Weapon Art of a weapon class.
function ArtsModule.ForClass(class: string): ArtDef?
	return Arts[class]
end

function ArtsModule.All(): { [string]: ArtDef }
	return Arts
end

return table.freeze(ArtsModule)
