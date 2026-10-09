--!strict
-- Per-remote rate limits (token bucket: `rate` tokens per second, `burst` max).

export type Limit = { rate: number, burst: number }

local Net = {
	DefaultLimit = { rate = 10, burst = 20 } :: Limit,
	Limits = {
		RequestWaystoneTravel = { rate = 0.5, burst = 2 },
		RequestWaystoneAttune = { rate = 2, burst = 4 },
		RequestOpenChest = { rate = 2, burst = 4 },
		RequestDungeonEnter = { rate = 0.5, burst = 2 },
		RequestDungeonLeave = { rate = 0.5, burst = 2 },
		RequestWorldState = { rate = 1, burst = 3 },
	} :: { [string]: Limit },
	ViolationLogThreshold = 20,
}

return Net
