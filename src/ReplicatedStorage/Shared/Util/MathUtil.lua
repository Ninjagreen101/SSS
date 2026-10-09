--!strict
--[[
	MathUtil
	Numeric helpers shared by client and server. IsFinite / IsFiniteVector3 are
	used by every remote validator to reject NaN and infinity from exploiters.
]]

local MathUtil = {}

-- NaN is the only value not equal to itself; inf fails the range check.
function MathUtil.IsFinite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

function MathUtil.IsFiniteVector3(value: Vector3): boolean
	return MathUtil.IsFinite(value.X) and MathUtil.IsFinite(value.Y) and MathUtil.IsFinite(value.Z)
end

function MathUtil.IsFiniteVector2(value: Vector2): boolean
	return MathUtil.IsFinite(value.X) and MathUtil.IsFinite(value.Y)
end

function MathUtil.Lerp(a: number, b: number, alpha: number): number
	return a + (b - a) * alpha
end

function MathUtil.InverseLerp(a: number, b: number, value: number): number
	if a == b then
		return 0
	end
	return (value - a) / (b - a)
end

function MathUtil.Remap(value: number, inMin: number, inMax: number, outMin: number, outMax: number): number
	return MathUtil.Lerp(outMin, outMax, MathUtil.InverseLerp(inMin, inMax, value))
end

-- Rounds to the nearest multiple of `step` (step 1 = integer rounding).
function MathUtil.Round(value: number, step: number?): number
	local s = step or 1
	return math.floor(value / s + 0.5) * s
end

-- Frame-rate independent smoothing: moves `current` toward `target`.
-- `speed` is roughly "fraction per second", so 10 settles in ~0.3 s at any FPS.
function MathUtil.ExpDecay(current: number, target: number, speed: number, dt: number): number
	return target + (current - target) * math.exp(-speed * dt)
end

function MathUtil.ExpDecayVector3(current: Vector3, target: Vector3, speed: number, dt: number): Vector3
	return target + (current - target) * math.exp(-speed * dt)
end

-- 1234 -> "1,234"; 1250000 -> "1.25M" when compact.
function MathUtil.FormatNumber(value: number, compact: boolean?): string
	local negative = value < 0
	local n = math.abs(value)
	local text: string
	if compact and n >= 1e9 then
		text = string.format("%.2fB", n / 1e9)
	elseif compact and n >= 1e6 then
		text = string.format("%.2fM", n / 1e6)
	elseif compact and n >= 1e4 then
		text = string.format("%.1fK", n / 1e3)
	else
		local whole = tostring(math.floor(n + 0.5))
		-- Insert thousands separators from the right.
		local formatted = whole:reverse():gsub("(%d%d%d)", "%1,"):reverse()
		if formatted:sub(1, 1) == "," then
			formatted = formatted:sub(2)
		end
		text = formatted
	end
	return if negative then "-" .. text else text
end

-- 75 -> "1:15"; 3725 -> "1:02:05"
function MathUtil.FormatDuration(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	local hours = s // 3600
	local minutes = (s % 3600) // 60
	local secs = s % 60
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, secs)
	end
	return string.format("%d:%02d", minutes, secs)
end

-- Returns the angle in degrees between two directions (0..180).
function MathUtil.AngleBetween(a: Vector3, b: Vector3): number
	if a.Magnitude < 1e-6 or b.Magnitude < 1e-6 then
		return 0
	end
	local dot = math.clamp(a.Unit:Dot(b.Unit), -1, 1)
	return math.deg(math.acos(dot))
end

-- Flattens a direction onto the XZ plane and normalizes it (zero if degenerate).
function MathUtil.FlatUnit(direction: Vector3): Vector3
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-6 then
		return Vector3.zero
	end
	return flat.Unit
end

return MathUtil
