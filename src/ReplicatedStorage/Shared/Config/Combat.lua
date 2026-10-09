--!strict
-- Sword combat tuning (Spec Section 7). Times in seconds unless noted.

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

local FRAME = 1 / 60 -- one animation frame at 60 FPS, used for frame-based windows

return TableUtil.DeepFreeze({
	Frame = FRAME,

	Health = {
		Base = 100,
		PerLevel = 8,
	},

	Stamina = {
		Max = 100,
		LightAttackCost = 8,
		HeavyAttackCost = 18,
		DodgeCost = 20,
		SprintCostPerSecond = 6,
		RegenPerSecond = 35,
		RegenDelay = 0.6, -- seconds without spending before regen starts
		WindedDuration = 1, -- at 0 stamina: slow walk, no dodge
		WindedWalkSpeedMultiplier = 0.5,
		SprintResumeStamina = 30, -- after running dry, sprint stays locked until stamina refills to this
		BlockCostPerDamage = 0.6, -- stamina lost per point of damage blocked
	},

	Posture = {
		Max = 100,
		BrokenDuration = 2,
		RecoveryDelay = 1.5, -- seconds without pressure before posture recovers
		RecoveryPerSecond = 22,
		BlockPostureFraction = 0.35, -- posture gained per blocked damage point
		ParriedPostureDamage = 45, -- posture an attacker takes when parried
	},

	Movement = {
		WalkSpeed = 16,
		SprintSpeed = 24,
		JumpPower = 45,
		-- The sprint animation (Assets.Animations.Movement.Sprint) plays only
		-- while sprinting on the ground. Its playback rate follows real speed so
		-- the stride roughly matches the ground covered, within these limits.
		SprintAnimation = {
			NaturalSpeed = 13, -- studs/s the clip's stride covers at 1x
			MinRate = 0.8,
			MaxRate = 1.5,
			MinSpeedFraction = 1.1, -- must be moving faster than walk speed x this
			FadeTime = 0.15,
		},
	},

	Combo = {
		ResetTime = 0.8, -- no attack for this long resets the light combo
		BufferFraction = 0.25, -- inputs in the last 25% of an animation queue
	},

	Dodge = {
		Duration = 0.4,
		IFrameStart = 2 * FRAME, -- invincibility begins on frame 2
		IFrameDuration = 0.25,
		Distance = 14,
		PerfectWindow = 0.12, -- dodge within this long before a hit lands
		PerfectSlowDuration = 0.5,
		PerfectSlowTimeScale = 0.35, -- world animations around the player slow to this
		PerfectStaminaRefund = 15,
	},

	Block = {
		DamageReduction = 0.7, -- default; weapon classes override (BlockReduction)
		FrontAngle = 140, -- degrees: only hits from in front can be blocked or parried
		WalkSpeedMultiplier = 0.5,
		-- Two-handed guard, solved with arm IK on every character (GuardPoseController)
		-- so both hands land on the grip whatever the avatar's proportions.
		-- Points are in upper-torso space for the default R15 body and scale with
		-- arm length (up / forward) and shoulder width (sideways).
		GuardPose = {
			GripOffset = Vector3.new(-0.35, 0.63, -0.73), -- the right hand's grip point
			BladeDirection = Vector3.new(0.71, 0.71, 0), -- up and to the right, across the body
			WristDirection = Vector3.new(0.565, -0.556, 0.61), -- the right hand's +Y (toward the wrist)
			RightPole = Vector3.new(1.2, -0.8, -0.6), -- elbows bend toward these points
			LeftPole = Vector3.new(-1.8, -0.8, -0.6),
			OffHandGap = 0.9, -- left hand sits this many hand-depths behind the right on the grip
			ReferenceArmLength = 1.728, -- shoulder to wrist on the default body
			ReferenceShoulderWidth = 1.944,
			BlendTime = 0.08, -- seconds to blend the arms into / out of the guard
		},
	},

	-- Weapon models built by WeaponService (see Shared/Util/WeaponGrip).
	WeaponModel = {
		GripDrop = 0.3, -- the grip's centre line sits this fraction of the hand's height below its centre
		OffHandMargin = 0.6, -- two-handed grips extend this fraction of the off hand's depth past it
	},

	-- Heavy attacks: tap for a quick heavy, hold past ChargeTime for a charged one.
	Heavy = {
		ChargeTime = 0.8,
		MaxCharge = 2.0, -- holding longer than this releases automatically
		ChargeMoveMultiplier = 0.4,
	},

	-- How long a hit interrupts the target (seconds).
	HitStun = {
		Light = 0.25,
		Heavy = 0.45,
		Parried = 0.7, -- an attacker whose blow was parried
		NpcLight = 0.3, -- dummy / mob blows on players
	},

	-- How quickly the character turns to face its aim / lock-on target (AlignOrientation).
	FacingResponsiveness = 40,

	-- Movement while acting (fraction of walk speed).
	ActionMove = {
		Attacking = 0.35,
		Staggered = 0.3,
		Broken = 0,
	},

	Parry = {
		Window = 0.18,
		TouchBonusFrames = 2, -- offsets touch latency on mobile
		CurrentRefillFraction = 0.2,
		RiposteWindow = 1.2,
		Cooldown = 0.35, -- spam guard between parry attempts
	},

	HitStop = {
		Light = 0.05,
		Heavy = 0.09,
		Riposte = 0.15,
		BrokenFinisher = 0.15,
	},

	CameraShake = {
		Light = 0.12,
		Heavy = 0.35,
		Slam = 0.8,
	},

	Damage = {
		BaseCritChance = 0.05,
		CritMultiplier = 1.5,
		DefenseCap = 0.8, -- target defense can never reduce more than 80%
		ComboMultipliers = { 1.0, 1.05, 1.1, 1.15, 1.3 }, -- light combo hit 1..5
		HeavyMultiplier = 1.6,
		ChargedHeavyMultiplier = 2.2,
		RiposteMultiplier = 3.0,
		DamageNumberVariance = 0.05,
	},

	HitValidation = {
		MaxRewind = 0.2, -- lag compensation window
		HistoryRate = 20, -- position samples per second kept for rewinding
		TargetRadius = 1.6, -- added to reach: hits land on a body, not a point
		VerticalReach = 6, -- studs above/below the attacker a blow can still land
		HistorySeconds = 0.5, -- how much position history the server keeps
		ReachTolerance = 3, -- extra studs allowed beyond weapon reach for latency
		MaxAimTurnDegreesPerSecond = 1440, -- faster aim changes are rejected
		TimingTolerance = 0.08, -- attacks may arrive this much earlier than animation allows
	},

	-- Per weapon-class traits from the class table in Section 7, plus swing
	-- timing. Light/Heavy: Windup = seconds until the blow lands, Recovery =
	-- seconds after it before the next action. AttackSpeed divides both.
	-- Arc = width of the swing in degrees (narrow = thrusts).
	WeaponClasses = {
		Longsword = {
			ParryBonusFrames = 2,
			ComboLength = 5,
			Reach = 7,
			AttackSpeed = 1,
			Arc = 110,
			BlockReduction = 0.7,
			Light = { Windup = 0.14, Recovery = 0.28 },
			Heavy = { Windup = 0.32, Recovery = 0.45 },
		},
		Greatblade = {
			HeavyHyperArmor = true,
			PostureDamageMultiplier = 1.8,
			ComboLength = 4,
			Reach = 8,
			AttackSpeed = 0.8,
			Arc = 140,
			BlockReduction = 0.85,
			Light = { Windup = 0.22, Recovery = 0.4 },
			Heavy = { Windup = 0.45, Recovery = 0.6 },
		},
		Twinfangs = {
			DoubleSiphonEveryHits = 5,
			ComboLength = 5,
			Reach = 5,
			AttackSpeed = 1.25,
			Arc = 90,
			BlockReduction = 0.55,
			Light = { Windup = 0.09, Recovery = 0.2 },
			Heavy = { Windup = 0.26, Recovery = 0.38 },
		},
		SpireLance = {
			DodgeCancelThrust = true,
			ThrustReachBonus = 2, -- attacking out of a dodge lunges further
			ComboLength = 4,
			Reach = 10,
			AttackSpeed = 0.95,
			Arc = 40,
			BlockReduction = 0.65,
			Light = { Windup = 0.16, Recovery = 0.3 },
			Heavy = { Windup = 0.34, Recovery = 0.48 },
		},
		Needle = {
			CritOnParriedMultiplier = 2.5, -- ripostes always crit, for this much
			ComboLength = 5,
			Reach = 7,
			AttackSpeed = 1.15,
			Arc = 50,
			BlockReduction = 0.6,
			Light = { Windup = 0.1, Recovery = 0.22 },
			Heavy = { Windup = 0.28, Recovery = 0.4 },
		},
		Arcblade = {
			SpellCooldownReductionPerHit = 0.3, -- used by the spell system (Phase 5)
			ComboLength = 4,
			Reach = 6.5,
			AttackSpeed = 1.05,
			Arc = 100,
			BlockReduction = 0.65,
			Light = { Windup = 0.13, Recovery = 0.27 },
			Heavy = { Windup = 0.3, Recovery = 0.44 },
		},
	},

	-- Combat feedback (damage numbers, swing visuals) is sent to players this close.
	FeedbackRadius = 120,

	Death = {
		RespawnDelay = 3, -- seconds before the Respawn button appears
		SlowMotionScale = 0.3, -- local animations slow to this on death
		Ragdoll = true,
		LostCurrentPickupRadius = 6,
		LostCurrentCheckInterval = 0.25,
	},

	Vitals = {
		TickRate = 10, -- Hz: server regen/drain tick and attribute replication
		CombatTimeout = 6, -- seconds after damage before you count as out of combat
		SprintMinSpeed = 2, -- studs/s: sprint stamina only drains while actually moving
	},

	-- Surge: sprint without a break for ChargeSeconds while out of combat
	-- (Vitals.CombatTimeout since the last blow, hit, cast or action) and the
	-- air breaks with a sonic boom: faster feet until the sprint stops or
	-- anything combat happens (then the charge starts again from 0).
	Surge = {
		ChargeSeconds = 10,
		Speed = 32, -- studs/s while Surging (Movement.SprintSpeed is 24); SpeedBonus still applies
		OutOfCombatCostMultiplier = 0.5, -- sprint stamina cost out of combat (Surging included)
		StopGrace = 0.4, -- standing still shorter than this (turning, a stumble) doesn't break the charge
		FieldOfView = 82, -- camera FOV while Surging (Camera.SprintFieldOfView is 76)
		AntiExploitGrace = 1, -- seconds Surge speed stays legal after it ends (latency)
		BoomFovPunch = 8, -- degrees, the local player's camera on the boom
		BoomShake = 0.2,
		-- Client wind visuals (SprintVFXController). Counts and rates are at High
		-- Effects Quality and scale down with the setting.
		Wind = {
			Range = 160, -- studs from the camera: runners further away draw no wind
			StreakWidth = 0.18, -- each wind streak (Trail) is this tall
			TrailLifetime = 0.22,
			SurgeTrailLifetime = 0.4,
			TrailTransparency = 0.7, -- at the head of a streak (fades to 1 at the tail)
			SurgeTrailTransparency = 0.4,
			WispRate = 26, -- air lines per second behind the torso at full sprint
			SurgeWispRate = 55,
			WispLifetime = 0.35,
			WispSpeed = 6, -- studs/s the air lines drift backwards
			SpeedLines = 18, -- local screen speed lines at full sprint
			SpeedLineSurgeMultiplier = 1.6,
			SpeedLineCycle = 0.45, -- seconds for one line to sweep out and fade
			BoomRadius = 14, -- ground shockwave ring
			BoomConeRadius = 7, -- the vertical wind ring around the runner
			BoomDuration = 0.55,
			BoomDust = 26, -- dust puffs kicked up
			BoomWisps = 30, -- wind lines blown out
			BoomPool = 4, -- booms that can play at once (pooled)
		},
	},
})
