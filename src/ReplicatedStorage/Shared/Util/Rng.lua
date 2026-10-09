--!strict
-- Deterministic pseudo-random generator (Park–Miller minimal standard).
-- Pure Luau with no Roblox globals so world planners produce identical results
-- in Studio and in the offline Luau test harness.

local MODULUS = 2147483647
local MULTIPLIER = 48271

export type Rng = {
	state: number,
	next: (self: Rng) -> number,
	range: (self: Rng, a: number, b: number) -> number,
	int: (self: Rng, a: number, b: number) -> number,
	chance: (self: Rng, p: number) -> boolean,
	pick: <T>(self: Rng, list: { T }) -> T,
	weighted: (self: Rng, weights: { [string]: number }) -> string,
	shuffle: <T>(self: Rng, list: { T }) -> (),
	fork: (self: Rng, salt: string | number) -> Rng,
}

local Rng = {}
Rng.__index = Rng

local function hashString(s: string): number
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % MODULUS
	end
	return h
end

local function normaliseSeed(seed: number): number
	local s = math.floor(math.abs(seed)) % MODULUS
	if s == 0 then
		s = 1
	end
	return s
end

function Rng.new(seed: number | string): Rng
	local numeric = if type(seed) == "string" then hashString(seed) else seed :: number
	local self = setmetatable({ state = normaliseSeed(numeric) }, Rng) :: any
	-- discard a few values to decorrelate nearby seeds
	for _ = 1, 3 do
		self:next()
	end
	return self :: Rng
end

function Rng.hash(s: string): number
	return hashString(s)
end

function Rng.next(self: Rng): number
	self.state = (self.state * MULTIPLIER) % MODULUS
	return (self.state - 1) / (MODULUS - 1)
end

function Rng.range(self: Rng, a: number, b: number): number
	return a + (b - a) * self:next()
end

function Rng.int(self: Rng, a: number, b: number): number
	return math.min(b, a + math.floor(self:next() * (b - a + 1)))
end

function Rng.chance(self: Rng, p: number): boolean
	return self:next() < p
end

function Rng.pick<T>(self: Rng, list: { T }): T
	return list[self:int(1, #list)]
end

function Rng.weighted(self: Rng, weights: { [string]: number }): string
	local keys = {}
	local total = 0
	for k, w in weights do
		if w > 0 then
			table.insert(keys, k)
			total += w
		end
	end
	table.sort(keys) -- deterministic iteration order
	local roll = self:next() * total
	for _, k in keys do
		roll -= weights[k]
		if roll <= 0 then
			return k
		end
	end
	return keys[#keys]
end

function Rng.shuffle<T>(self: Rng, list: { T })
	for i = #list, 2, -1 do
		local j = self:int(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

function Rng.fork(self: Rng, salt: string | number): Rng
	local s = if type(salt) == "string" then hashString(salt) else salt :: number
	return Rng.new((self.state + s * 7919) % MODULUS)
end

return Rng
