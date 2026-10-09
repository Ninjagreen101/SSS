--!strict
-- The Current magic system tuning (Spec Sections 6 and 8).

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

return TableUtil.DeepFreeze({
	Vessel = {
		Base = 100,
		PerLevel = 2,
		PerDrawPoint = 3,
	},

	Regen = {
		BasePerSecond = 4,
		DrawScalingPerPoint = 0.03, -- +3% regen per Draw point (soft caps apply)
		SiphonPerHit = 5, -- Current gained per landed sword hit
		PoolRefillPerSecond = 25, -- standing in a Current pool
		CanalRefillPerSecond = 10, -- near a canal
		CanalRadius = 18,
	},

	-- Zones (parts in Workspace.PressureZones with a Pressure attribute 1..5)
	-- set the level where a player stands; outside every zone it's Neutral.
	Pressure = {
		Min = 1,
		Max = 5,
		Neutral = 3,
		SampleInterval = 0.5, -- seconds between zone checks per player
		SpellPowerPerLevelAboveNeutral = 0.10,
		RefillMultiplier = { 0.5, 0.75, 1.0, 1.4, 1.8 }, -- by pressure level 1..5
		-- "Cheaper Siphon": sword-hit Current gain is divided by this (0.7 = +43%).
		LowPressureSiphonCostMultiplier = { 0.7, 0.85, 1.0, 1.0, 1.0 },
		LowPressureMeleeBonus = { 0.15, 0.08, 0, 0, 0 },
	},

	Saturation = {
		Max = 100,
		PerCastFraction = 0.6, -- saturation gained = spell cost * this
		DrainPerSecond = 8,
		DrainDelay = 2,
	},

	Overflow = {
		Duration = 8,
		DensityBonus = 0.25,
		FreeSpells = true, -- spells cost no Current during Overflow
	},

	Burnout = {
		Duration = 6,
		CastSpeedPenalty = 0.2,
		StopsRegen = true, -- no passive Current regeneration during Burnout
	},

	Resonance = {
		MaxStacks = 5,
		LinkWindow = 2.5, -- sword->spell or spell->sword within this many seconds
		DamagePerStack = 0.06,
		DecayDelay = 4, -- seconds without a qualifying hit before one stack decays
		DecayInterval = 1,
		GlowStacks = 3, -- sword trail switches to Attunement colour at this many stacks
		ParryStacks = 1, -- a successful parry adds this many stacks at once
	},

	-- At max Resonance the Weapon Art button becomes Confluence (Shared/Data/Confluences).
	Confluence = {
		CurrentCost = 30,
		Invulnerability = 0.4,
		Cooldown = 25,
		MaxDuration = 2.2,
		-- Confluence power = weapon base damage x (1 - DensityShare + DensityShare x spell power).
		DensityShare = 0.5,
		BannerTime = 1.6, -- seconds the name banner stays on screen
	},

	-- Holding the Weapon Art button Infuses the blade with the primary Attunement.
	Infusion = {
		HoldTime = 0.6,
		Duration = 10,
		Cost = 25,
		SiphonBonus = 0.5,
	},

	-- Weapon Arts (tap the Weapon Art button below max Resonance): Shared/Data/Arts.
	Arts = {
		CancelIntoDodge = true, -- a finished Art can be rolled out of during its recovery
	},

	Beacons = {
		StartSlots = 1,
		MaxSlots = 4,
		ControlThresholds = { 20, 40, 60 }, -- extra slot at each
		OrbitRadiusIdle = 3.2,
		OrbitRadiusCombat = 2.2,
		OrbitSpeed = 1.6, -- radians per second
		BobHeight = 0.35,
		Height = 1.6, -- studs above the root part
		UnlockWithAttunement = true, -- Beacons are shaped Current: you need an Attunement first
		Sentry = {
			Interval = 1.6, -- seconds between shots while you're in combat
			Range = 36,
			Damage = 5, -- before Density
			Posture = 2,
			Speed = 70,
			Radius = 0.6,
		},
		Aegis = {
			Recharge = 12, -- seconds after breaking before it can absorb again
		},
		Lantern = {
			LightRange = 26,
			LightBrightness = 1.6,
			RevealRadius = 40, -- hidden things (tag LanternReveal) show inside this
		},
		Relay = {
			Cooldown = 8, -- minimum seconds between Relay recasts
		},
	},

	Attunement = {
		PrimaryLevel = 8,
		SecondaryLevel = 30,
	},

	Status = {
		SoakedSlow = 0.15,
		SoakedDuration = 5,
		ChilledStacksToFreeze = 4,
		ChilledDuration = 4,
		FrozenStun = 1.5,
		ShockedDuration = 4,
		ShockChainRadius = 14,
		HeavyDefenseDown = 0.2,
		HeavyDuration = 4,
		RootedDuration = 2.5,
		RenewingDuration = 6,
		RenewingHealPerSecond = 4,
		ShockChainFraction = 0.4, -- a Tempest hit on a Shocked target jumps for this much damage...
		ShockChainTargets = 2, -- ...to this many other enemies within ShockChainRadius
		ReactionDamageMultiplier = 1.75, -- Soaked+Tempest, Chilled+Abyss, Rooted+Tide
	},

	Casting = {
		MobileAutoTargetConeDegrees = 30,
		MaxCastRange = 120,
		CancelIntoDodgeAfterRelease = true,
		CastMoveMultiplier = 0.5, -- walk speed while casting
		StepWallMargin = 2, -- Step stops this far short of a wall
		ShrineDistance = 14, -- how close you must be to the Attunement Shrine to choose
		ChargeMoveMultiplier = 0.4, -- walk speed while charging a Lance
		ChargeTolerance = 0.15, -- seconds of latency allowed when measuring a charge
		AimedLineWidth = 0.35, -- aimed-cast reticle line thickness (studs)
	},
})
