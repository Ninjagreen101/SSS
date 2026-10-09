--!strict
-- Networking safety limits. Rate limits are token buckets: `Burst` calls may
-- arrive at once, refilling at `PerSecond`. Anything over is dropped and logged.

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

export type RateLimit = {
	Burst: number,
	PerSecond: number,
}

return TableUtil.DeepFreeze({
	DefaultRate = { Burst = 10, PerSecond = 5 },
	Rates = {
		RequestAttack = { Burst = 6, PerSecond = 5 },
		RequestHeavyAttack = { Burst = 3, PerSecond = 2 },
		RequestCast = { Burst = 4, PerSecond = 3 },
		RequestDodge = { Burst = 3, PerSecond = 2 },
		RequestBlock = { Burst = 6, PerSecond = 4 },
		RequestSprint = { Burst = 6, PerSecond = 4 },
		RequestInteract = { Burst = 4, PerSecond = 3 },
		RequestSaveSetting = { Burst = 20, PerSecond = 5 },
		ClientReady = { Burst = 2, PerSecond = 0.2 },
		RequestRespawn = { Burst = 3, PerSecond = 1 },
		RequestAttune = { Burst = 2, PerSecond = 0.5 },
		RequestEquipSpell = { Burst = 8, PerSecond = 4 },
		RequestChargeCast = { Burst = 4, PerSecond = 3 },
		RequestWeaponArt = { Burst = 3, PerSecond = 2 },
		RequestInfuse = { Burst = 2, PerSecond = 1 },
		RequestSetBeacon = { Burst = 8, PerSecond = 4 },
		RequestItemAction = { Burst = 12, PerSecond = 6 },
		RequestQuickItem = { Burst = 3, PerSecond = 2 },
		RequestStation = { Burst = 6, PerSecond = 4 },
		RequestPickup = { Burst = 30, PerSecond = 15 }, -- a big pile of drops is collected in a burst
		RequestAllocateStats = { Burst = 4, PerSecond = 2 },
		RequestChoosePosition = { Burst = 2, PerSecond = 0.5 },
		RequestUnlockNode = { Burst = 8, PerSecond = 4 },
		RequestEquipAbility = { Burst = 6, PerSecond = 3 },
		RequestRespec = { Burst = 2, PerSecond = 0.2 },
		RequestAbility = { Burst = 3, PerSecond = 2 },
	} :: { [string]: RateLimit },

	-- Anti-exploit strike system
	Strikes = {
		MalformedArgs = 3, -- strikes per malformed call
		RateLimited = 1, -- strikes per dropped call
		DecayPerSecond = 0.2, -- one strike forgiven every 5 s
		KickThreshold = 40,
		KickInStudio = false, -- in Studio we log instead of kicking
		LogCooldown = 2, -- seconds between log lines per player+remote
	},

	-- Server-side movement sanity checks (sampled, horizontal only).
	Movement = {
		SampleInterval = 0.25,
		SpeedTolerance = 1.35, -- allowed = state speed x this + SpeedSlack
		SpeedSlack = 6, -- studs/s for latency and slopes
		ViolationsBeforeRubberBand = 3,
		TeleportDistance = 60, -- a single sample moving further than this snaps back at once
		Strikes = 2,
	},

	MaxAimDirectionError = 0.02,
	MaxTargetDistance = 600,
})
