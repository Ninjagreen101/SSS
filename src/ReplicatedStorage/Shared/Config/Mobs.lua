--!strict
-- Enemy AI and Guardian tuning (Spec Section 10).

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

return TableUtil.DeepFreeze({
	AI = {
		TickRateNear = 10, -- Hz while a player is within NearRadius
		TickRateFar = 1, -- Hz while a player is within SleepRadius
		NearRadius = 200,
		SleepRadius = 400, -- no player within this: mob sleeps
		PathRecomputeInterval = 0.5,
		LeashRadius = 120,
		MaxAttackersPerPlayer = 2,
		MaxSameAttackRepeats = 2, -- a move may not be used 3 times in a row
		MinTelegraph = 0.4,
		AnimationCullRadius = 250, -- clients only animate mobs within this
		ReturnHealFraction = 1,
	},

	Visual = {
		HitFlashDuration = 0.08,
		RagdollDuration = 0.5,
		DissolveDuration = 1.2,
		HealthBarDistance = 90,
	},

	Threat = {
		DamageMultiplier = 1,
		HealingMultiplier = 0.5,
		TauntBonus = 1000,
		DecayPerSecond = 0.02,
	},

	-- Floor Guardians (Phase 10). Per-Guardian data lives in Shared.Data.Guardians.
	Guardian = {
		HealthScalePerExtraPlayer = 0.75, -- BaseHP * (1 + 0.75 * (players - 1))
		MaxPlayers = 8,
		PhaseThresholds = { 1.0, 0.6, 0.25 },
		IntroDuration = 4, -- default when a Guardian sets no Intro
		WeakPointDamageMultiplier = 1.5,
		WeakPointPostureMultiplier = 2,
		WeakPointArc = 90, -- degrees, centred on the weak side (back, or front in a core phase)
		MinTelegraph = 0.4, -- spec: no attack winds up faster than this, whatever the phase scale
		GatherSeconds = 10, -- after the first challenger, others at the gate have this long to join
		GatherRadius = 60, -- studs from the gate's prompt that count as "at the gate"
		ArenaOrigin = Vector3.new(-5200, -300, 0), -- arena copies are laid out from here (opposite side from the dungeons)
		ArenaSpacing = 700, -- along +Z
		MaxArenas = 8,
		CloseAfterSeconds = 6, -- after a victory or wipe, the arena closes this long later
		ContributionDamage = 0.02, -- reward share: this much of the max health dealt...
		ContributionSeconds = 45, -- ...or this long alive inside the arena
		BlockingMemory = 1.5, -- a target that blocked this recently counts as "blocking" (grab bait)
		VictorySlowMo = 1.6, -- seconds of the client's slow-motion defeat moment
		AnnounceTopic = "SpireGuardianCleared", -- MessagingService topic for cross-server banners
		AnnounceCooldown = 30, -- seconds between this server's cross-server publishes
	},

	Elite = {
		HealthMultiplier = 3,
		DamageMultiplier = 1.5,
		PostureMultiplier = 1.5,
		RewardMultiplier = 3, -- XP and gold
		ScaleMultiplier = 1.12, -- elites stand a little taller
		GlowColor = Color3.fromHex("#E8B84A"),
	},

	-- Spawn points: Parts in Workspace.MobSpawns with a MobId attribute
	-- (optional: Count, Elite, RespawnTime, PatrolRadius). See MobService.
	Spawning = {
		Folder = "MobSpawns",
		DefaultRespawnTime = 30, -- seconds after a death before a replacement appears
		ScatterRadius = 6, -- several mobs on one point spread out this far
		DefaultPatrolRadius = 14,
	},

	Perception = {
		NoticeTime = 0.45, -- pause (turning to face you) between spotting a player and chasing
		PackRadius = 30, -- an alerted mob wakes others this close
		SightHeight = 2.5, -- eye height for line-of-sight checks
		LoseTargetTime = 6, -- seconds without a valid target before giving up and walking home
		DamageThreat = 1, -- threat per point of damage dealt (times Threat.DamageMultiplier)
		ProximityThreat = 5, -- threat for being spotted first
	},

	Movement = {
		ArriveDistance = 2.5,
		WaypointReach = 3,
		RepathDistance = 4, -- recompute the path when the goal moves this far
		CircleRadius = 11, -- mobs waiting for an attack slot circle at this distance
		CircleSpeedMultiplier = 0.55, -- of walk speed
		PatrolInterval = { 4, 9 }, -- seconds between patrol walks
		TurnResponsiveness = 14, -- how quickly mobs turn to face their target
		TrackCutoff = 0.15, -- mobs stop turning toward you this long before a blow lands
		LungeTime = 0.15, -- seconds before contact a lunge moves the mob forward
		LungeStopDistance = 3, -- a lunge stops this far from its target (studs, scaled by body size)
		ReturnArriveDistance = 4,
		ObstacleCheckHeight = 1.5,
	},

	-- Breathing room: after a move ends a mob waits this long (random in the
	-- range) before starting another, repositioning meanwhile. This is the
	-- player's window to punish or heal.
	Pacing = {
		MoveGap = { 0.6, 1.5 },
		RangedMoveGap = { 1.2, 2.4 }, -- mobs with KeepAway
	},

	Projectile = {
		MaxLifetime = 4,
		StepRate = 30, -- simulation steps per second
	},

	-- When the moment of contact happens in each animation slot (seconds at
	-- speed 1). Clients stretch the windup so contact matches the server.
	AnimationContact = {
		Light1 = 0.14,
		Light2 = 0.14,
		Light3 = 0.14,
		Light4 = 0.14,
		Light5 = 0.14,
		Heavy = 0.32,
	},

	-- Roblox's standard R15 locomotion (free for every experience).
	Locomotion = {
		Idle = "rbxassetid://507766388",
		Walk = "rbxassetid://507777826",
		Run = "rbxassetid://507767714",
		RunThreshold = 11, -- studs/s: faster than this plays Run
		WalkAnimSpeed = 9, -- studs/s the walk clip covers at 1x
		RunAnimSpeed = 16,
	},
})
