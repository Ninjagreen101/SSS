--!strict
-- Pure 2D/3D geometry helpers in Roblox axis conventions (Y up, yaw about +Y,
-- a yaw of 0 faces -Z). No Roblox globals: shared by the world planners,
-- the offline harness and runtime systems.

local Types = require(script.Parent.Parent.Types)

type Point2 = Types.Point2
type OBB = Types.OBB

local Geom = {}

-- Rotate (x, z) by yaw `ry` exactly like CFrame.Angles(0, ry, 0) does.
function Geom.rotate(x: number, z: number, ry: number): (number, number)
	local c, s = math.cos(ry), math.sin(ry)
	return x * c + z * s, -x * s + z * c
end

-- Yaw that makes a piece's front (-Z) face along direction (dx, dz).
function Geom.yawFacing(dx: number, dz: number): number
	return math.atan2(-dx, -dz)
end

-- Yaw whose local +X axis points along direction (dx, dz).
function Geom.yawAlong(dx: number, dz: number): number
	return math.atan2(-dz, dx)
end

function Geom.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function Geom.clamp01(t: number): number
	return math.clamp(t, 0, 1)
end

function Geom.smoothstep(e0: number, e1: number, x: number): number
	local t = math.clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

function Geom.dist2(ax: number, az: number, bx: number, bz: number): number
	local dx, dz = bx - ax, bz - az
	return math.sqrt(dx * dx + dz * dz)
end

-- Distance from point to segment, plus the clamped parameter t along it.
function Geom.distToSegment(px: number, pz: number, ax: number, az: number, bx: number, bz: number): (number, number)
	local dx, dz = bx - ax, bz - az
	local len2 = dx * dx + dz * dz
	local t = 0
	if len2 > 1e-9 then
		t = math.clamp(((px - ax) * dx + (pz - az) * dz) / len2, 0, 1)
	end
	local cx, cz = ax + dx * t, az + dz * t
	local ex, ez = px - cx, pz - cz
	return math.sqrt(ex * ex + ez * ez), t
end

export type PolylineHit = {
	distance: number,
	segment: number,
	t: number,
	along: number, -- distance along the polyline to the closest point
}

-- Closest point query against a polyline given as {x, ?, z} or {x, z} points.
-- `zIndex` is 3 for {x, y, z} points and 2 for {x, z} points.
function Geom.closestOnPolyline(px: number, pz: number, points: { { number } }, zIndex: number): PolylineHit
	local best: PolylineHit = { distance = math.huge, segment = 1, t = 0, along = 0 }
	local acc = 0
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local d, t = Geom.distToSegment(px, pz, a[1], a[zIndex], b[1], b[zIndex])
		local segLen = Geom.dist2(a[1], a[zIndex], b[1], b[zIndex])
		if d < best.distance then
			best = { distance = d, segment = i, t = t, along = acc + segLen * t }
		end
		acc += segLen
	end
	return best
end

function Geom.polylineLength(points: { { number } }, zIndex: number): number
	local total = 0
	for i = 1, #points - 1 do
		total += Geom.dist2(points[i][1], points[i][zIndex], points[i + 1][1], points[i + 1][zIndex])
	end
	return total
end

export type PolySample = {
	x: number,
	y: number,
	z: number,
	tx: number, -- unit tangent
	tz: number,
	along: number,
}

-- Walk a polyline in steps of `spacing`, returning interpolated samples.
-- Points may be {x, y, z} (zIndex 3, y interpolated) or {x, z} (zIndex 2, y = 0).
function Geom.samplePolyline(points: { { number } }, spacing: number, zIndex: number): { PolySample }
	local out: { PolySample } = {}
	local along = 0
	local nextAt = 0
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local ax, az, bx, bz = a[1], a[zIndex], b[1], b[zIndex]
		local ay = if zIndex == 3 then a[2] else 0
		local by = if zIndex == 3 then b[2] else 0
		local segLen = Geom.dist2(ax, az, bx, bz)
		if segLen > 1e-6 then
			local tx, tz = (bx - ax) / segLen, (bz - az) / segLen
			while nextAt <= along + segLen + 1e-6 do
				local t = (nextAt - along) / segLen
				table.insert(out, {
					x = ax + (bx - ax) * t,
					y = ay + (by - ay) * t,
					z = az + (bz - az) * t,
					tx = tx,
					tz = tz,
					along = nextAt,
				})
				nextAt += spacing
			end
			along += segLen
		end
	end
	return out
end

-- Catmull-Rom smoothing of a {x, y, z} polyline (keeps end points).
function Geom.smoothPolyline(points: { { number } }, subdivisions: number): { { number } }
	if #points < 3 then
		return points
	end
	local out: { { number } } = {}
	local n = #points
	for i = 1, n - 1 do
		local p0 = points[math.max(i - 1, 1)]
		local p1 = points[i]
		local p2 = points[i + 1]
		local p3 = points[math.min(i + 2, n)]
		for s = 0, subdivisions - 1 do
			local t = s / subdivisions
			local t2, t3 = t * t, t * t * t
			local pt = {}
			for k = 1, #p1 do
				pt[k] = 0.5
					* (
						(2 * p1[k])
						+ (-p0[k] + p2[k]) * t
						+ (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * t2
						+ (-p0[k] + 3 * p1[k] - 3 * p2[k] + p3[k]) * t3
					)
			end
			table.insert(out, pt)
		end
	end
	table.insert(out, points[n])
	return out
end

function Geom.pointInPolygon(x: number, z: number, poly: { Point2 }): boolean
	local inside = false
	local n = #poly
	local j = n
	for i = 1, n do
		local xi, zi = poly[i][1], poly[i][2]
		local xj, zj = poly[j][1], poly[j][2]
		if ((zi > z) ~= (zj > z)) and (x < (xj - xi) * (z - zi) / (zj - zi) + xi) then
			inside = not inside
		end
		j = i
	end
	return inside
end

-- Signed-ish distance to a polygon edge (positive outside, negative inside).
function Geom.polygonDistance(x: number, z: number, poly: { Point2 }): number
	local best = math.huge
	local n = #poly
	for i = 1, n do
		local a = poly[i]
		local b = poly[(i % n) + 1]
		local d = Geom.distToSegment(x, z, a[1], a[2], b[1], b[2])
		if d < best then
			best = d
		end
	end
	return if Geom.pointInPolygon(x, z, poly) then -best else best
end

export type Bounds = { minX: number, minZ: number, maxX: number, maxZ: number }

function Geom.polygonBounds(poly: { Point2 }): Bounds
	local b = { minX = math.huge, minZ = math.huge, maxX = -math.huge, maxZ = -math.huge }
	for _, p in poly do
		b.minX = math.min(b.minX, p[1])
		b.maxX = math.max(b.maxX, p[1])
		b.minZ = math.min(b.minZ, p[2])
		b.maxZ = math.max(b.maxZ, p[2])
	end
	return b
end

function Geom.polygonCentroid(poly: { Point2 }): (number, number)
	local sx, sz = 0, 0
	for _, p in poly do
		sx += p[1]
		sz += p[2]
	end
	return sx / #poly, sz / #poly
end

function Geom.obbCorners(o: OBB): { Point2 }
	local out: { Point2 } = {}
	for _, s in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		local lx, lz = Geom.rotate(s[1] * o.hw, s[2] * o.hd, o.ry)
		table.insert(out, { o.x + lx, o.z + lz })
	end
	return out
end

local function project(corners: { Point2 }, ax: number, az: number): (number, number)
	local lo, hi = math.huge, -math.huge
	for _, c in corners do
		local d = c[1] * ax + c[2] * az
		lo = math.min(lo, d)
		hi = math.max(hi, d)
	end
	return lo, hi
end

-- Separating-axis overlap test for two 2D oriented boxes.
function Geom.obbOverlap(a: OBB, b: OBB, margin: number?): boolean
	local m = margin or 0
	local ea: OBB = { x = a.x, z = a.z, hw = a.hw + m, hd = a.hd + m, ry = a.ry }
	local ca, cb = Geom.obbCorners(ea), Geom.obbCorners(b)
	for _, ry in { a.ry, b.ry } do
		local ux, uz = Geom.rotate(1, 0, ry)
		local vx, vz = Geom.rotate(0, 1, ry)
		for _, axis in { { ux, uz }, { vx, vz } } do
			local a0, a1 = project(ca, axis[1], axis[2])
			local b0, b1 = project(cb, axis[1], axis[2])
			if a1 < b0 or b1 < a0 then
				return false
			end
		end
	end
	return true
end

function Geom.obbContainsPoint(o: OBB, x: number, z: number): boolean
	local lx, lz = Geom.rotate(x - o.x, z - o.z, -o.ry)
	return math.abs(lx) <= o.hw and math.abs(lz) <= o.hd
end

-- Points spread around an OBB's perimeter (for clearance tests).
function Geom.obbPerimeter(o: OBB, step: number): { Point2 }
	local out: { Point2 } = {}
	local corners = Geom.obbCorners(o)
	for i = 1, 4 do
		local a, b = corners[i], corners[(i % 4) + 1]
		local len = Geom.dist2(a[1], a[2], b[1], b[2])
		local n = math.max(1, math.ceil(len / step))
		for k = 0, n - 1 do
			local t = k / n
			table.insert(out, { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t })
		end
	end
	table.insert(out, { o.x, o.z })
	return out
end

-- ================================================================== noise

-- Integer lattice hash. Every product stays below 2^53 so the arithmetic is
-- exact in doubles (larger multipliers silently lose bits and cause banding).
local function hash2(ix: number, iz: number, seed: number): number
	local h = (ix * 1619 + iz * 31337 + seed * 6971 + 1013) % 2147483647
	h = (h * 48271) % 2147483647
	h = (h * 48271 + 11) % 2147483647
	h = ((h + iz * 7919) * 16807) % 2147483647
	h = (h * 48271) % 2147483647
	return h / 2147483647
end

local function valueNoise(x: number, z: number, seed: number): number
	local ix, iz = math.floor(x), math.floor(z)
	local fx, fz = x - ix, z - iz
	local ux = fx * fx * (3 - 2 * fx)
	local uz = fz * fz * (3 - 2 * fz)
	local a = hash2(ix, iz, seed)
	local b = hash2(ix + 1, iz, seed)
	local c = hash2(ix, iz + 1, seed)
	local d = hash2(ix + 1, iz + 1, seed)
	return (a + (b - a) * ux + (c - a) * uz + (a - b - c + d) * ux * uz) * 2 - 1
end

-- Fractal value noise in roughly [-1, 1].
function Geom.fbm(x: number, z: number, seed: number, octaves: number): number
	local amp, freq, sum, norm = 1, 1, 0, 0
	for o = 1, octaves do
		sum += valueNoise(x * freq, z * freq, seed + o * 131) * amp
		norm += amp
		amp *= 0.5
		freq *= 2.03
	end
	return sum / norm
end

-- Ridged noise in [0, 1], good for crags and cliff bands.
function Geom.ridged(x: number, z: number, seed: number, octaves: number): number
	local amp, freq, sum, norm = 1, 1, 0, 0
	for o = 1, octaves do
		local n = 1 - math.abs(valueNoise(x * freq, z * freq, seed + o * 977))
		sum += n * n * amp
		norm += amp
		amp *= 0.5
		freq *= 2.1
	end
	return sum / norm
end

return Geom
