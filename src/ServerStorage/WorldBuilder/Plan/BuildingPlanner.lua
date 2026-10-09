--!strict
-- BuildingPlanner: assembles a complete building from the modular kit.
--
-- Input is a footprint (w x d measured on the wall centrelines, multiples of
-- 4 * scale), storey count, style, wealth, kind and seed. Output is a PlanNode
-- in building space: origin at the footprint centre on the ground, front facade
-- facing -Z. The plan contains plinth, walls with sensible door/window
-- placement, half-timber overlays, frames and glass, floors with beams, stairs
-- that connect every storey, a roof matched to the footprint, trim, merged
-- facade colliders, exterior dressing and furnished interiors.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Rng = require(Shared.Util.Rng)
local Config = require(Shared.Config)
local KitManifest = require(Shared.Data.KitManifest)

local Plan = require(script.Parent.Plan)
local Styles = require(script.Parent.Styles)
local InteriorPlanner = require(script.Parent.InteriorPlanner)
local Facade = require(script.Parent.Facade)

type PlanNode = Types.PlanNode
type Rng = Rng.Rng
type Frame = Plan.Frame
type Style = Styles.Style

local Kit = Config.World.Kit
local B = Config.World.Buildings

export type BuildingSpec = {
	name: string,
	w: number,
	d: number,
	storeys: number,
	style: string,
	wealth: number,
	kind: string, -- house | shop | tavern | smithy | library | barracks | warehouse | hall | chapel | ruin
	seed: number,
	plinth: number,
	scale: number?,
	ridgeAxis: string?, -- "x" (default) | "z"
	roof: string?, -- "auto" | "gable" | "hip" | "none"
	interiorAll: boolean?,
	noInterior: boolean?,
	streaming: string?,
	damaged: number?, -- 0..1 chance a wall panel is broken (ruins)
	doorPanel: string?, -- override for the front door panel type
	windowPanel: string?, -- override for upper window panel type
}

type Side = Facade.Side

export type BuildingInfo = {
	node: PlanNode,
	doorWorldLocal: { number }, -- door threshold (building space) {x, y, z}
	footprint: { number }, -- outer extents {w, d}
	height: number,
}

local BuildingPlanner = {}

-- ------------------------------------------------------------ partitions

local function partitionFree(L: number, S: number, rng: Rng): { number }?
	if L == 0 then
		return {}
	end
	if L < 8 * S - 1e-6 then
		return nil
	end
	local options = {}
	for _, base in { 16, 12, 8 } do
		local w = base * S
		local rest = L - w
		if math.abs(rest) < 1e-6 or rest >= 8 * S - 1e-6 then
			table.insert(options, w)
		end
	end
	if #options == 0 then
		return nil
	end
	rng:shuffle(options)
	-- prefer wide panels (fewer instances, two-window rhythm), then 12s
	table.sort(options, function(a: number, b: number): boolean
		return a > b
	end)
	for i, w in options do
		if i > 1 and rng:chance(0.6) then
			continue
		end
		local rest = partitionFree(L - w, S, rng)
		if rest then
			table.insert(rest, 1, w)
			return rest
		end
	end
	for _, w in options do
		local rest = partitionFree(L - w, S, rng)
		if rest then
			table.insert(rest, 1, w)
			return rest
		end
	end
	return nil
end

-- Symmetric facade: mirrored halves around a centre panel when possible.
local function partition(L: number, S: number, rng: Rng, symmetric: boolean): { number }
	if symmetric and L > 16 * S then
		local centres = { 12 * S, 8 * S, 16 * S }
		for _, c in centres do
			local rest = (L - c) / 2
			if rest >= 8 * S - 1e-6 and math.abs(rest / (4 * S) - math.floor(rest / (4 * S) + 0.5)) < 1e-6 then
				local half = partitionFree(rest, S, rng)
				if half then
					local out = table.clone(half)
					table.insert(out, c)
					for i = #half, 1, -1 do
						table.insert(out, half[i])
					end
					return out
				end
			end
		end
	end
	local free = partitionFree(L, S, rng)
	assert(free, "cannot partition wall length " .. tostring(L))
	return free
end

local function centreIndex(widths: { number }): number
	return math.floor((#widths + 1) / 2)
end

local function openingsFor(panelKind: string, w: number): { Types.KitOpening }
	local id = string.format("wall_%s_w%d", panelKind, w)
	local m = KitManifest[id]
	assert(m, "missing wall piece " .. id)
	return m.openings
end

-- -------------------------------------------------------------- helpers

local function sideFrame(side: Side, u: number, y: number, S: number): Frame
	return Plan.frame(side.ax + side.dx * u, y, side.az + side.dz * u, side.ry, S)
end

local makeSide = Facade.makeSide

local function decomposePlinth(p: number): { number }
	local out: { number } = {}
	local rest = p
	for _, h in { 8, 4, 2 } do
		while rest >= h - 1e-6 do
			table.insert(out, h)
			rest -= h
		end
	end
	return out
end

local function chooseRoof(spec: BuildingSpec, style: Style, rng: Rng, L: number, D: number): string
	if spec.roof and spec.roof ~= "auto" then
		return spec.roof
	end
	if L >= D and rng:chance(style.hipChance + spec.wealth * 0.15) then
		return "hip"
	end
	return "gable"
end

-- ------------------------------------------------------------------ roof

local function planRoof(node: PlanNode, spec: BuildingSpec, style: Style, rng: Rng, roofBase: number, S: number, topMaterial: string, topColor: string)
	local ridgeZ = spec.ridgeAxis == "z"
	local L = if ridgeZ then spec.d else spec.w
	local D = if ridgeZ then spec.w else spec.d
	local run = D / (2 * S)
	local runKey = math.floor(run + 0.5)
	local valid = false
	for _, r in Kit.PitchRuns do
		if r == runKey then
			valid = true
		end
	end
	assert(valid, string.format("%s: roof run %d not in kit (depth %d)", spec.name, runKey, D))
	local kind = chooseRoof(spec, style, rng, L, D)
	if kind == "none" then
		return
	end
	local rf = Plan.frame(0, roofBase, 0, if ridgeZ then -math.pi / 2 else 0, S)
	local roofColor = rng:pick(style.roofColors)
	local roofOpts = { material = style.roofMaterial, color = roofColor }

	-- One slope piece per roof face, stretched along the ridge (shingle courses
	-- run along X, so stretching keeps them intact). x0/x1 in unscaled roof units.
	local function tileRun(x0: number, x1: number, fn: (xc: number, len: number) -> ())
		if x1 - x0 > 0.01 then
			fn((x0 + x1) / 2, x1 - x0)
		end
	end

	local halfL = L / (2 * S)
	local ridgeY = run + 0.35
	if kind == "hip" then
		local hc = (L - D) / (2 * S)
		if hc > 0.01 then
			tileRun(-hc, hc, function(xc: number, len: number)
				local id = string.format("roof_slope_r%d_l8", runKey)
				local o = { material = roofOpts.material, color = roofOpts.color, sx = len / 8 }
				Plan.pieceIn(node, rf, id, xc, 0, 0, 0, o)
				Plan.pieceIn(node, rf, id, xc, 0, 0, math.pi, o)
				Plan.pieceIn(node, rf, "roof_ridge_l8", xc, ridgeY, 0, 0, { color = "RoofSlateDark", sx = len / 8 })
			end)
		end
		Plan.pieceIn(node, rf, string.format("roof_hipcap_r%d", runKey), hc, 0, 0, 0, roofOpts)
		Plan.pieceIn(node, rf, string.format("roof_hipcap_r%d", runKey), -hc, 0, 0, math.pi, roofOpts)
	else
		tileRun(-halfL - 2, halfL + 2, function(xc: number, len: number)
			local id = string.format("roof_slope_r%d_l8", runKey)
			local o = { material = roofOpts.material, color = roofOpts.color, sx = len / 8 }
			Plan.pieceIn(node, rf, id, xc, 0, 0, 0, o)
			Plan.pieceIn(node, rf, id, xc, 0, 0, math.pi, o)
			Plan.pieceIn(node, rf, "roof_ridge_l8", xc, ridgeY, 0, 0, { color = "RoofSlateDark", sx = len / 8 })
		end)
		local attic = spec.storeys >= 2 and runKey >= 8 and rng:chance(0.6)
		local gid = string.format("%sr%d", if attic then "gable_win_" else "gable_", runKey)
		local gOpts = { material = topMaterial, color = topColor }
		Plan.pieceIn(node, rf, gid, -halfL, 0, 0, math.pi / 2, gOpts)
		Plan.pieceIn(node, rf, gid, halfL, 0, 0, -math.pi / 2, gOpts)
		if attic then
			for _, sgn in { -1, 1 } do
				local x, y, z = Plan.tx(rf, sgn * (halfL + 0.4), runKey * 0.42, 0)
				Plan.light(node, x, y, z, "WindowGlow", 8 * S, 0.6, true)
			end
		end
		-- dormers on the front slope
		if runKey >= 8 and rng:chance(style.dormerChance + spec.wealth * 0.1) then
			local t = 3
			local step = 8
			local x = -halfL + step
			while x <= halfL - step + 0.01 do
				Plan.pieceIn(node, rf, "roof_dormer", x, t - 0.6, -(runKey - t) - 0.3, 0, { color = topColor, material = topMaterial })
				x += step
			end
		end
	end
	-- chimneys poking through the ridge
	if spec.kind ~= "warehouse" and rng:chance(style.chimneyChance) then
		local count = if L >= 24 * S and rng:chance(0.4) then 2 else 1
		for i = 1, count do
			local cx = (if count == 1 then rng:range(-0.3, 0.3) else (i == 1 and -0.32 or 0.32)) * L / S
			local cz = rng:range(-0.3, 0.3) * run
			Plan.pieceIn(node, rf, "chimney", cx, run - 3 - math.abs(cz), cz, 0, { color = "Brick" })
			local x, y, z = Plan.tx(rf, cx, run - 3 - math.abs(cz) + 10.3, cz)
			Plan.emitter(node, "ChimneySmoke", x, y, z)
		end
	end
	-- roof perch markers for gulls and rooftop clutter
	local px, py, pz = Plan.tx(rf, rng:range(-0.4, 0.4) * L / S, run + 0.9, 0)
	Plan.marker(node, "BirdPerch", spec.name .. "_perch", px, py, pz, 0)
end

-- --------------------------------------------------------------- planner

function BuildingPlanner.plan(spec: BuildingSpec, x: number, y: number, z: number, ry: number): BuildingInfo
	local S = spec.scale or 1
	local style = Styles[spec.style]
	assert(style, "unknown style " .. spec.style)
	assert(spec.w % (4 * S) == 0 and spec.d % (4 * S) == 0, spec.name .. ": footprint must be on the kit grid")
	assert(spec.w >= 8 * S and spec.d >= 8 * S, spec.name .. ": footprint too small")
	local rng = Rng.new(spec.seed)
	local node = Plan.node(spec.name, x, y, z, ry, spec.streaming or "Atomic")
	node.attributes.Kind = spec.kind
	node.attributes.Style = spec.style
	table.insert(node.tags, "Building")

	local w, d = spec.w, spec.d
	local hw, hd = w / 2, d / 2
	local SH = Kit.StoreyHeight * S
	local T = Kit.WallThickness * S
	local p = spec.plinth
	local storeys = spec.storeys
	local top = p + storeys * SH
	local damaged = spec.damaged or 0

	-- sides: front (-Z), right (+X), back (+Z), left (-X); A -> B is panel +X
	local sides: { Side } = {
		makeSide("front", -hw, -hd, hw, -hd, 0),
		makeSide("right", hw, -hd, hw, hd, -math.pi / 2),
		makeSide("back", hw, hd, -hw, hd, math.pi),
		makeSide("left", -hw, hd, -hw, -hd, math.pi / 2),
	}
	for _, side in sides do
		side.widths = partition(side.length, S, rng:fork(side.id), side.id == "front" or side.id == "back")
	end

	-- stair cell (back-left corner)
	local hasStairs = storeys > 1 and w >= 12 * S
	local spiral = d < 16 * S
	local cellW = 8 * S
	local cellD = if spiral then 8 * S else 12 * S
	local cell = {
		x0 = -hw + 0.5 * T,
		x1 = -hw + 0.5 * T + cellW,
		z1 = hd - 0.5 * T,
		z0 = hd - 0.5 * T - cellD,
	}

	-- ------------------------------------------------------------ plinth
	for _, side in sides do
		local f = sideFrame(side, side.length / 2, 0, S)
		local yy = 0
		for _, h in decomposePlinth(p / S) do
			Plan.pieceIn(node, f, string.format("plinth_h%d_w16", h), 0, yy / S, 0, 0, {
				material = style.plinthMaterial,
				sx = side.length / (16 * S),
			})
			yy += h * S
		end
	end
	-- foundation fill doubles as the ground-floor surface
	Plan.solid(node, 0, (p - 4) / 2, 0, w, p + 4, d, 0, {
		kind = "Surface",
		material = style.groundFloorMaterial,
		color = if style.groundFloorMaterial == "WoodPlanks" then style.floorColor else "StoneLight",
	})

	-- ------------------------------------------------------------- walls
	local doorInfo = { x = 0, y = p, z = -hd }
	local isShopKind = spec.kind == "shop" or spec.kind == "tavern" or spec.kind == "smithy"
	local glowChance = B.WindowGlowChance
	for storey = 0, storeys - 1 do
		local sy = p + storey * SH
		local timber = style.timberFrom ~= nil and storey >= (style.timberFrom :: number) and S == 1
		local mat = if storey == 0 then style.groundMaterial else style.upperMaterial
		local col = if storey == 0 then style.groundColor else style.upperColor
		if timber then
			mat, col = "Plaster", "Plaster"
		end
		for _, side in sides do
			local u = 0
			local ci = centreIndex(side.widths)
			for i, pw in side.widths do
				local base = pw / S
				local kind: string
				if side.id == "front" then
					if storey == 0 then
						if i == ci then
							kind = spec.doorPanel or (if spec.kind == "warehouse" or spec.kind == "hall" or spec.kind == "chapel" then "archdoor" else "door")
						elseif isShopKind and spec.kind == "shop" then
							kind = "shop"
						else
							kind = if rng:chance(style.archChance) then "archwin" else "window"
						end
					else
						kind = spec.windowPanel or (if rng:chance(style.archChance) then "archwin" else "window")
						if i == ci and storey == 1 and base <= 12 and rng:chance(style.balconyChance + spec.wealth * 0.2) then
							kind = "door"
						end
					end
				else
					local chance = style.windowChance * (if side.id == "back" then 0.7 else 1)
					local hidesStair = hasStairs and side.id == "left" and u + pw > side.length - cellD - 0.5
					if hidesStair or not rng:chance(chance) then
						kind = "plain"
					else
						kind = spec.windowPanel or (if rng:chance(style.archChance) then "archwin" else "window")
					end
				end
				if damaged > 0 and kind ~= "door" and kind ~= "archdoor" and rng:chance(damaged) then
					kind = "damaged"
				end
				local f = sideFrame(side, u + pw / 2, sy, S)
				Plan.pieceIn(node, f, string.format("wall_%s_w%d", kind, base), 0, 0, 0, 0, { material = mat, color = col })
				if timber and kind ~= "damaged" and kind ~= "archdoor" then
					Plan.pieceIn(node, f, string.format("timber_%s_w%d", kind, base), 0, 0, 0, 0, {})
				end
				-- openings: frames, glass, doors, colliders, dressing
				for _, o in openingsFor(kind, base) do
					local ox = (o.x0 + o.x1) / 2
					-- windows stay solid (glass); only walkable openings cut the facade collider
					if o.kind == "door" or o.kind == "archdoor" or o.kind == "breach" then
						table.insert(side.openings, {
							u0 = u + pw / 2 + o.x0 * S,
							u1 = u + pw / 2 + o.x1 * S,
							v0 = sy + o.y0 * S,
							v1 = sy + o.y1 * S,
						})
					end
					if o.kind == "window" then
						if side.id ~= "back" then
							Plan.pieceIn(node, f, "frame_window", ox, o.y0, 0, 0, {})
						end
						local glow = rng:chance(glowChance)
						Plan.pieceIn(node, f, "pane_window", ox, o.y0, 0, 0, { tag = if glow then "WindowGlow" else nil })
						if storey > 0 and rng:chance(style.plantChance) then
							Plan.assembly(node, f, "potted_plant", ox, o.y0, -0.95, 0, { s = 0.42 })
						end
					elseif o.kind == "arch" then
						if side.id ~= "back" then
							Plan.pieceIn(node, f, "frame_archwin", ox, o.y0, 0, 0, {})
						end
						local glow = rng:chance(glowChance)
						Plan.pieceIn(node, f, "pane_archwin", ox, o.y0, 0, 0, { tag = if glow then "WindowGlow" else nil })
					elseif o.kind == "shop" then
						Plan.pieceIn(node, f, string.format("frame_shop_w%d", base), 0, o.y0, 0, 0, {})
						Plan.pieceIn(node, f, string.format("pane_shop_w%d", base), 0, o.y0, 0, 0, { tag = "WindowGlow" })
						Plan.pieceIn(node, f, string.format("awning_w%d", base), 0, 0, 0, 0, { color = rng:pick(style.awningColors) })
					elseif o.kind == "door" then
						Plan.pieceIn(node, f, "frame_door", ox, o.y0, 0, 0, {})
						if storey == 0 then
							Plan.pieceIn(node, f, "door_leaf", o.x0, o.y0, 0.3, -1.75, {})
						else
							Plan.pieceIn(node, f, string.format("balcony_w%d", math.min(base, 12)), 0, 0, 0, 0, {
								material = style.railingMaterial,
							})
							Plan.pieceIn(node, f, "door_leaf", o.x0, o.y0, 0.3, -1.6, {})
						end
					elseif o.kind == "archdoor" then
						Plan.pieceIn(node, f, "frame_archdoor", ox, o.y0, 0, 0, {})
						Plan.pieceIn(node, f, "door_leaf_arch", o.x0, o.y0, 0.3, -1.75, {})
					end
					if storey == 0 and side.id == "front" and i == ci and (o.kind == "door" or o.kind == "archdoor") then
						local dx, dy, dz = Plan.tx(f, ox, 0, 0)
						doorInfo = { x = dx, y = dy, z = dz }
						-- lantern beside the door, sign on the other side for trades
						Plan.assembly(node, f, "wall_lantern", ox + (o.x1 - o.x0) / 2 + 1.6, 9.6, -0.5, 0)
						if spec.kind == "shop" or spec.kind == "tavern" or spec.kind == "smithy" then
							Plan.assembly(node, f, "hanging_sign", ox - (o.x1 - o.x0) / 2 - 1.6, 10.2, -0.5, 0)
						end
						-- entrance steps up to the ground floor
						if p >= 2 then
							local stepId = if p <= 2 then "steps_stone_w16" elseif p <= 4 then "steps_stone_w8" else "steps_stone_w8"
							local ss = if p <= 2 then 0.5 elseif p <= 4 then 1 else p / 4
							local fx, _, fz = Plan.tx(f, ox, 0, 0)
							local nx, nz = -math.sin(side.ry), -math.cos(side.ry)
							local dist = 0.9 * S + 4 * ss
							Plan.piece(node, stepId, fx + nx * dist, 0, fz + nz * dist, side.ry, { s = ss, material = style.plinthMaterial })
						end
					end
				end
				-- trim
				if style.cornice and storey == storeys - 1 and (side.id == "front" or side.id == "back") then
					Plan.pieceIn(node, f, string.format("cornice_l%d", base), 0, 11, 0, 0, {})
				end
				if style.runeband and storey == 0 and side.id == "front" then
					Plan.pieceIn(node, f, string.format("runeband_l%d", base), 0, 1.0, 0, 0, { tag = "RuneGlow" })
				end
				if style.bannerChance > 0 and storey >= 1 and side.id == "front" and i ~= ci and kind == "plain" and rng:chance(style.bannerChance) then
					Plan.pieceIn(node, f, "banner_wall", 0, 10.5, 0, 0, { color = rng:pick({ "ClothTeal", "ClothNavy" }) })
				end
				u += pw
			end
		end
	end

	-- corners: one full-height piece per corner when the kit has one
	local cornerBase = if style.corner == "corner_timber_h12" then "corner_timber_h" else "corner_quoin_h"
	local tall = S == 1 and storeys <= 4
	for _, c in { { -hw, -hd }, { hw, -hd }, { hw, hd }, { -hw, hd } } do
		local opts = {
			s = if S ~= 1 then S else nil,
			material = if cornerBase == "corner_timber_h" then "Wood" else style.groundMaterial,
			color = if cornerBase == "corner_timber_h" then "WoodDark" else "StoneLight",
		}
		if tall then
			Plan.piece(node, cornerBase .. tostring(12 * storeys), c[1], p, c[2], 0, opts)
		else
			for storey = 0, storeys - 1 do
				Plan.piece(node, cornerBase .. "12", c[1], p + storey * SH, c[2], 0, opts)
			end
		end
	end

	-- Walls collide through their own pieces: solid panels use box collision and
	-- door panels carry explicit colliders around the opening (see KitManifest).

	-- ----------------------------------------------------------- floors
	local ix0, ix1 = -hw + 0.5 * T, hw - 0.5 * T
	local iz0, iz1 = -hd + 0.5 * T, hd - 0.5 * T
	local slabT = 1 * S
	local function slabRects(withHole: boolean): { { number } }
		if not withHole or not hasStairs then
			return { { ix0, ix1, iz0, iz1 } }
		end
		return {
			{ cell.x1, ix1, iz0, iz1 }, -- right of the stair cell, full depth
			{ ix0, cell.x1, iz0, cell.z0 }, -- in front of the cell
		}
	end
	for storey = 1, storeys do
		local fy = p + storey * SH
		local hole = storey < storeys
		for _, r in slabRects(hole) do
			local sx, sz = r[2] - r[1], r[4] - r[3]
			if sx > 0.1 and sz > 0.1 then
				Plan.solid(node, (r[1] + r[2]) / 2, fy - slabT / 2, (r[3] + r[4]) / 2, sx, slabT, sz, 0, {
					kind = "Surface",
					material = style.floorMaterial,
					color = style.floorColor,
				})
			end
		end
		-- ceiling beams under the slab
		local spacing = B.BeamSpacing * S
		local bx = ix0 + spacing / 2
		while bx < ix1 - 1 do
			local inHole = hole and hasStairs and bx > cell.x0 - 0.5 and bx < cell.x1 + 0.5
			if not inHole then
				Plan.piece(node, "beam_l8", bx, fy - slabT, 0, 0, {
					s = if S ~= 1 then S else nil,
					sz = (iz1 - iz0) / (8 * S),
				})
			end
			bx += spacing
		end
	end

	-- ----------------------------------------------------------- stairs
	if hasStairs then
		for storey = 0, storeys - 2 do
			local sy = p + storey * SH
			local cx = (cell.x0 + cell.x1) / 2
			local cz = (cell.z0 + cell.z1) / 2
			Plan.piece(node, if spiral then "stairs_spiral_h12" else "stairs_switchback", cx, sy, cz, 0, {
				s = if S ~= 1 then S else nil,
				material = if style.groundFloorMaterial == "Marble" then "Slate" else nil,
			})
			-- railings around the hole on the floor above
			local fy = sy + SH
			local railOpts = { s = if S ~= 1 then S else nil, material = style.railingMaterial }
			-- one balustrade along the open long side of the stair hole
			Plan.piece(node, "railing_l8", cell.x1, fy, if spiral then cz else cell.z0 + 6 * S, -math.pi / 2, {
				s = railOpts.s,
				material = railOpts.material,
				sx = if spiral then nil else 1.5,
			})
		end
	end

	-- ------------------------------------------------------------- roof
	local topMat = if style.timberFrom ~= nil and S == 1 then "Plaster" else style.upperMaterial
	local topCol = if style.timberFrom ~= nil and S == 1 then "Plaster" else style.upperColor
	planRoof(node, spec, style, rng:fork("roof"), top, S, topMat, topCol)

	-- --------------------------------------------------------- interiors
	if not spec.noInterior then
		for storey = 0, storeys - 1 do
			local furnish = storey == 0 or spec.interiorAll or rng:chance(B.UpperFloorFurnishChance)
			if furnish then
				local fy = p + storey * SH
				InteriorPlanner.furnish(node, {
					x0 = ix0 + 0.4,
					x1 = ix1 - 0.4,
					z0 = iz0 + 0.4,
					z1 = iz1 - 0.4,
					y = fy,
					ceiling = fy + SH - slabT,
					doorX = if storey == 0 then doorInfo.x else nil,
					stair = if hasStairs then { x0 = cell.x0, x1 = cell.x1, z0 = cell.z0, z1 = cell.z1 } else nil,
					stairEntryX = if hasStairs then (if spiral then cell.x1 else cell.x0 + 6 * S) else nil,
					stairEntryZ = if hasStairs then (if spiral then cell.z0 else cell.z0) else nil,
					lit = storey == 0,
				}, spec.kind, storey, rng:fork("int" .. storey))
			end
		end
	end

	-- --------------------------------------------------- exterior dressing
	if rng:chance(0.5) then
		local side = rng:pick(sides)
		local u = rng:range(1.5, side.length - 1.5)
		local f = sideFrame(side, u, 0, S)
		Plan.pieceIn(node, f, "moss_patch", 0, 0.02, -1.6, rng:range(0, math.pi), { s = rng:range(0.6, 1.2) })
	end
	if spec.kind == "warehouse" or spec.kind == "shop" or spec.kind == "smithy" then
		local f = sideFrame(sides[1], rng:pick({ 2.5, sides[1].length - 2.5 }), 0, S)
		Plan.pieceIn(node, f, rng:pick({ "barrel", "crate_l", "crate_s" }), 0, 0, -2.4, rng:range(0, 0.6), {})
		if rng:chance(0.6) then
			Plan.pieceIn(node, f, rng:pick({ "barrel", "crate_s" }), rng:range(-2.6, 2.6), 0, -2.2, rng:range(0, 0.6), {})
		end
	end

	return {
		node = node,
		doorWorldLocal = { doorInfo.x, doorInfo.y, doorInfo.z },
		footprint = { w + 2.4 * S, d + 2.4 * S },
		height = top + d / 2,
	}
end

return BuildingPlanner
