--!strict
--[[
	RateLimiter
	Per-player, per-key token bucket. Each call spends one token; tokens refill
	continuously at `PerSecond` up to `Burst`. Lets legitimate bursts (a fast
	combo) through while capping sustained spam.
]]

local RateLimiter = {}
RateLimiter.__index = RateLimiter

type Bucket = {
	Tokens: number,
	Updated: number,
}

type LimiterData = {
	_buckets: { [Player]: { [string]: Bucket } },
}

export type RateLimiter = typeof(setmetatable({} :: LimiterData, RateLimiter))

function RateLimiter.new(): RateLimiter
	local self: LimiterData = { _buckets = {} }
	return setmetatable(self, RateLimiter)
end

-- Returns true and spends a token if the call is allowed.
function RateLimiter.Take(self: RateLimiter, player: Player, key: string, burst: number, perSecond: number): boolean
	local now = os.clock()
	local perPlayer = self._buckets[player]
	if not perPlayer then
		perPlayer = {}
		self._buckets[player] = perPlayer
	end
	local bucket = perPlayer[key]
	if not bucket then
		bucket = { Tokens = burst, Updated = now }
		perPlayer[key] = bucket
	else
		bucket.Tokens = math.min(burst, bucket.Tokens + (now - bucket.Updated) * perSecond)
		bucket.Updated = now
	end
	if bucket.Tokens >= 1 then
		bucket.Tokens -= 1
		return true
	end
	return false
end

function RateLimiter.ClearPlayer(self: RateLimiter, player: Player)
	self._buckets[player] = nil
end

return RateLimiter
