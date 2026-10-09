--!strict
--[[
	Moves
	The step format shared by Weapon Arts (Shared/Data/Arts), Confluences
	(Shared/Data/Confluences) and Position abilities (Shared/Data/Abilities). A move is a short timeline: each step happens
	`At` seconds after the move starts. ArtService runs the timeline on the
	server (every hit goes through CombatService); clients draw each step from
	the MoveStep remote. New moves are data only.

	Positions
	  The move keeps an Anchor: it starts at the caster's feet, and Leap /
	  Dash / Blink steps (and hit steps with SetAnchor) move it. A step's
	  Where says whether it happens at the caster ("Self") or the Anchor.
	  Aim is the caster's flat aim direction when the move started.

	Damage and posture are multiples of the move's Power (Arts: the weapon's
	scaled base damage; Confluences: that blended with spell power, see
	Config.Current.Confluence) and the weapon's base posture damage.

	Hit steps (deal damage; every target hit joins the move's Hit list)
	  Arc         cone of Reach and Arc degrees in front of Where
	  Circle      everything within Radius of Where
	  Line        a Length x Width line from Where along the aim (walls stop it)
	  Projectile  one travelling line per angle in Angles (degrees off aim):
	              Speed, Range, Radius; Pierce hits everything along it, else
	              only the first enemy; SetAnchor puts the Anchor at the impact
	  Dash        the caster rushes Distance along the aim over Duration,
	              hitting everything within Width of the path; Anchor = the end
	  Blink       the caster teleports beside up to MaxTargets enemies within
	              Range, one every Interval, hitting each; Anchor = the last
	  Strikes     Count bolts fall on enemies within Radius of Where, one
	              every Interval, each hitting StrikeRadius around it
	  Chain       from every target hit so far, jumps to up to Count others
	              within Range
	  Burst       after Delay, an explosion of Radius around every target hit
	              so far (or Where if none)
	  Field       a zone at Where for Duration: every Interval it hits enemies
	              inside (Damage) and heals allies (HealFraction of max health)
	  Hit options: Hits + Interval repeat the hit, Single hits only the nearest,
	  Stacks applies the element's status that many times (Confluences;
	  default 1), Apply forces a status (e.g. "Frozen"), Launch throws light
	  enemies up, Crit forces a critical hit, CritBonus adds crit chance.

	Other steps
	  Leap        the caster jumps Distance forward (Height) over Duration;
	              Anchor = the landing
	  Pull / Push enemies within Radius of Where (or OnlyHit: the Hit list)
	              move Strength studs toward / away from Where (Direction
	              "Aim" pushes along the aim instead) over Duration
	  Heal        heals the caster (and players within Allies studs) by
	              Fraction of max health; Renewing adds the Renewing status
	  Leech       heals the caster by Fraction of the damage this move dealt
	  Mark        targets hit so far take Bonus x Power extra from the
	              caster's next hit within Duration (it shatters the mark)
	  Taunt       enemies within Radius of Where turn on the caster and
	              stay on them for Duration (Config.Mobs.Threat.TauntBonus)
	  Buff        the caster (and players within Allies studs) gain the
	              Bonuses table for Duration s (same bonus ids as gear)
	  Shield      the caster (and players within Allies studs) get a
	              shield worth Fraction of their max health for Duration s
	  Refill      the caster regains Fraction of their max Current

	Execute (hit steps): +Execute damage on foes at or below
	Config.Progression.ExecuteThreshold health.

	Every step may set Visual (an effect key for clients), Camera ("Punch" or
	"Shake") and IFrames (seconds of invincibility for the caster).
]]

export type StepKind =
	"Arc"
	| "Circle"
	| "Line"
	| "Projectile"
	| "Dash"
	| "Blink"
	| "Strikes"
	| "Chain"
	| "Burst"
	| "Field"
	| "Leap"
	| "Pull"
	| "Push"
	| "Heal"
	| "Leech"
	| "Mark"
	| "Taunt"
	| "Buff"
	| "Shield"
	| "Refill"

export type Step = {
	At: number,
	Do: StepKind,
	Where: ("Self" | "Anchor")?,
	-- shapes
	Reach: number?,
	Arc: number?,
	Radius: number?,
	Length: number?,
	Width: number?,
	-- damage
	Damage: number?,
	Posture: number?,
	Hits: number?,
	Interval: number?,
	Single: boolean?,
	Stacks: number?,
	Apply: string?,
	Launch: number?,
	Crit: boolean?,
	CritBonus: number?,
	Execute: number?,
	SetAnchor: boolean?,
	-- movement
	Distance: number?,
	Duration: number?,
	Height: number?,
	-- projectiles / targets
	Speed: number?,
	Range: number?,
	Angles: { number }?,
	Pierce: boolean?,
	MaxTargets: number?,
	Count: number?,
	StrikeRadius: number?,
	Delay: number?,
	-- control / support
	Strength: number?,
	Direction: ("In" | "Out" | "Aim")?,
	OnlyHit: boolean?,
	Fraction: number?,
	HealFraction: number?,
	Allies: number?,
	Renewing: boolean?,
	Bonus: number?,
	Bonuses: { [string]: number }?,
	-- presentation
	Visual: string?,
	Camera: ("Punch" | "Shake")?,
	IFrames: number?,
}

export type Move = {
	Id: string,
	Duration: number, -- the caster is busy this long
	HyperArmor: boolean, -- hits don't interrupt it
	Animation: string, -- Config.Assets.Animations slot path, e.g. "Arts.Longsword"
	FallbackAnimation: string, -- sword clip used until that slot has an id
	AnimationSpeed: number?,
	Steps: { Step },
}

local Moves = {}

-- Freezes a move table (and its steps) after checking it is well formed.
-- Called by the data modules at load so a typo fails loudly in Studio.
function Moves.Define(move: Move): Move
	assert(move.Duration > 0, `{move.Id}: Duration must be positive`)
	local last = 0
	for index, step in move.Steps do
		assert(step.At >= 0 and step.At <= move.Duration + 1.5, `{move.Id} step {index}: At out of range`)
		assert(step.At >= last, `{move.Id} step {index}: steps must be in time order`)
		last = step.At
		if step.Angles then
			table.freeze(step.Angles)
		end
		if step.Bonuses then
			table.freeze(step.Bonuses)
		end
		table.freeze(step)
	end
	table.freeze(move.Steps)
	return table.freeze(move)
end

return table.freeze(Moves)
