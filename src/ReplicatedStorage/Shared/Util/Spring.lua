--!strict
--[[
	Spring
	Analytic damped spring (exact solution, stable at any frame rate).
	Used for camera follow, lock-on swing, UI bounce and recoil.
	Damper 1 = critically damped (no overshoot), < 1 = bouncy.
	Speed = how fast it reaches the target (angular frequency).
]]

local Spring = {}
Spring.__index = Spring

type SpringData = {
	Position: Vector3,
	Velocity: Vector3,
	Target: Vector3,
	Speed: number,
	Damper: number,
}

export type Spring = typeof(setmetatable({} :: SpringData, Spring))

function Spring.new(initial: Vector3, speed: number?, damper: number?): Spring
	local self: SpringData = {
		Position = initial,
		Velocity = Vector3.zero,
		Target = initial,
		Speed = speed or 12,
		Damper = damper or 1,
	}
	return setmetatable(self, Spring)
end

-- Advances the spring by dt seconds and returns the new position.
function Spring.Update(self: Spring, dt: number): Vector3
	local w = self.Speed
	local d = self.Damper
	local offset = self.Position - self.Target
	local v = self.Velocity
	if dt <= 0 or w <= 0 then
		return self.Position
	end

	local newOffset: Vector3
	local newVelocity: Vector3
	if d >= 1 then
		-- Critically damped / overdamped (treated as critical for stability).
		local decay = math.exp(-w * dt)
		local c2 = v + offset * w
		newOffset = (offset + c2 * dt) * decay
		newVelocity = (c2 - (offset + c2 * dt) * w) * decay
	else
		-- Underdamped: oscillates around the target while decaying.
		local wd = w * math.sqrt(1 - d * d)
		local decay = math.exp(-d * w * dt)
		local cos = math.cos(wd * dt)
		local sin = math.sin(wd * dt)
		local c2 = (v + offset * (d * w)) / wd
		newOffset = (offset * cos + c2 * sin) * decay
		newVelocity = ((c2 * wd - offset * (d * w)) * cos - (offset * wd + c2 * (d * w)) * sin) * decay
	end

	self.Position = self.Target + newOffset
	self.Velocity = newVelocity
	return self.Position
end

-- Adds an instant velocity kick (camera shake, recoil).
function Spring.Impulse(self: Spring, velocity: Vector3)
	self.Velocity += velocity
end

-- Snaps to a position with no motion.
function Spring.Reset(self: Spring, position: Vector3)
	self.Position = position
	self.Target = position
	self.Velocity = Vector3.zero
end

-- Convenience wrapper for single numbers (stored in the X axis).
function Spring.newNumber(initial: number, speed: number?, damper: number?): Spring
	return Spring.new(Vector3.new(initial, 0, 0), speed, damper)
end

return Spring
