--!strict
--[[
	BuildingGenerator (edit-time tool)
	Builds a complete building from the kit: foundation, walls with sensible door and window
	placement, corner posts, floors with real stairwells, stairs that connect every storey, a roof
	matched to the footprint (gable or hip, with gable ends, chimney and dormers), trim, and a
	furnished interior chosen by building type. The result is a static Model saved into the place.

	Building space: origin = centre of the footprint at street level, +Y up, the FRONT (street side,
	where the door is) faces +Z. The ground floor sits 2 studs up on the foundation.
	  storey k: walls from y = 2 + 13k to 2 + 13k + 12, its floor slab top at y = 2 + 13k.

	Usage:
	    local BG = require(game.ServerStorage.Tools.BuildingGenerator)
	    BG.Build({ Width = 24, Depth = 20, Storeys = 3, Style = "Mixed", Kind = "House", Seed = 7 },
	             CFrame.new(0, 0, 0), workspace)
	Width and Depth must be multiples of 4 and at least 8.
]]

local CollectionService = game:GetService("CollectionService")

local Kit = require(script.Parent.KitLibrary)

export type Kind = "House" | "Shop" | "Tavern" | "Smithy" | "Library" | "Barracks" | "Warehouse" | "Hall"
export type Style = "Stone" | "Timber" | "Mixed"

export type Spec = {
	Width: number, -- along the front (X), multiple of 4, >= 8
	Depth: number, -- front to back (Z), multiple of 4, >= 8
	Storeys: number, -- 1..4
	Style: Style?,
	Kind: Kind?,
	Wealth: number?, -- 0..1: richer = stone, arched windows, cornices, rune bands, dormers, balconies
	Roof: ("Gable" | "Hip")?,
	Seed: number?,
	InteriorAll: boolean?, -- furnish every storey (important buildings)
	Doors: { string }?, -- sides with a ground-floor door: "Front" (default), "Back", "Left", "Right"
	Plaster: Color3?,
	RoofColor: Color3?,
	Name: string?,
	Lit: boolean?,
	Sign: boolean?, -- hanging sign + awning (shops); default by Kind
	Smoke: ("Hearth" | "Forge")?, -- always build a chimney, smoking (Forge adds embers)
	Cloth: Color3?, -- awning, banner and rug colour (the Cloth channel)
	Balcony: boolean?, -- false = never add a front balcony (it would cover a signboard)
}

export type Result = {
	Model: Model,
	Doors: { CFrame }, -- world CFrame of each doorway (at the threshold, facing out)
	Height: number, -- top of the walls (building space y)
}

local BuildingGenerator = {}

local STOREY = 13
local WALL = 12
local BASE = 2

-- Weathered, salt-stained plasters and dark slate/verdigris roofs: the town has spent a long time
-- under a drowned sky. Kept muted so lit windows and the Current glow carry the night.
local PLASTERS = {
	Color3.fromHex("#8A826E"), Color3.fromHex("#7E7866"), Color3.fromHex("#76796E"), Color3.fromHex("#857660"),
	Color3.fromHex("#6E766E"), Color3.fromHex("#83746A"), Color3.fromHex("#958C78"),
}
local ROOFS = {
	Color3.fromHex("#272C34"), Color3.fromHex("#1F2328"), Color3.fromHex("#33302E"), Color3.fromHex("#3A2A26"),
	Color3.fromHex("#2C3E3C"), Color3.fromHex("#34504A"), -- the last two: verdigris copper
}

type Ctx = {
	spec: Spec,
	rng: Random,
	at: CFrame,
	model: Model,
	W: number,
	D: number,
	n: number,
	style: Style,
	kind: Kind,
	wealth: number,
	tint: { [string]: Color3 },
	lit: boolean,
	doors: { CFrame },
	stair: { x0: number, x1: number, z0: number, z1: number, spiral: boolean, alongX: boolean }?,
}

local function place(ctx: Ctx, piece: string, cf: CFrame, opts: Kit.PlaceOptions?): { BasePart }
	local o: Kit.PlaceOptions = opts or {}
	o.Flatten = true
	o.Tint = o.Tint or ctx.tint
	if o.Lit == nil then
		o.Lit = ctx.lit
	end
	return (Kit.Place(piece, ctx.at * cf, ctx.model, o))
end

local function box(ctx: Ctx, name: string, centre: Vector3, size: Vector3)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = true
	p.CanQuery = true
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = size
	p.CFrame = ctx.at * CFrame.new(centre)
	p.Parent = ctx.model
end

-- Split a side length into kit panel widths (8, 12, 16), shuffled.
local function panels(rng: Random, length: number): { number }
	local out: { number } = {}
	local left = length
	while left > 0 do
		local options = {}
		for _, w in { 16, 12, 8 } do
			local rest = left - w
			if rest == 0 or rest >= 8 then
				table.insert(options, w)
			end
		end
		if #options == 0 then
			-- only 4 left over: widen the previous panel's neighbour by re-splitting
			table.insert(out, left)
			break
		end
		local w = options[rng:NextInteger(1, #options)]
		table.insert(out, w)
		left -= w
	end
	-- a 4 can only appear when length was 4 mod 8 with no fit: merge it into a 12 by turning an 8 into 12
	for i, w in out do
		if w == 4 then
			for j, v in out do
				if v == 8 then
					out[j] = 12
					table.remove(out, i)
					break
				end
			end
			break
		end
	end
	for i = #out, 2, -1 do
		local j = rng:NextInteger(1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

-- CFrame (building space) for the centre of a panel on a side, facing outward.
local function sideFrame(ctx: Ctx, side: string, along: number, y: number): CFrame
	local W, D = ctx.W, ctx.D
	if side == "Front" then
		return CFrame.new(along, y, D / 2)
	elseif side == "Back" then
		return CFrame.new(-along, y, -D / 2) * CFrame.Angles(0, math.pi, 0)
	elseif side == "Right" then
		return CFrame.new(W / 2, y, -along) * CFrame.Angles(0, math.pi / 2, 0)
	end
	return CFrame.new(-W / 2, y, along) * CFrame.Angles(0, -math.pi / 2, 0)
end

local function sideLength(ctx: Ctx, side: string): number
	return if side == "Front" or side == "Back" then ctx.W else ctx.D
end

local function family(ctx: Ctx, storey: number): string
	if ctx.style == "Stone" then
		return "Stone"
	elseif ctx.style == "Timber" then
		return "Timber"
	end
	return if storey == 0 then "Stone" else "Timber"
end

-- WALLS ------------------------------------------------------------------------------

local function wallKind(ctx: Ctx, fam: string, isDoor: boolean, storey: number): string
	if isDoor then
		return "Door"
	end
	local r = ctx.rng:NextNumber()
	if fam == "Stone" then
		if ctx.wealth > 0.6 and r < 0.45 then
			return "Arch"
		elseif r < 0.78 then
			return "Window"
		elseif ctx.wealth < 0.25 and r < 0.84 and storey > 0 then
			return "Damaged"
		end
		return "Plain"
	end
	return if r < 0.8 then "Window" else "Plain"
end

local function buildWalls(ctx: Ctx)
	local doorSides: { string } = ctx.spec.Doors or { "Front" }
	local isDoorSide: { [string]: boolean } = {}
	for _, s in ipairs(doorSides) do
		isDoorSide[s] = true
	end
	local doorRanges: { [string]: { { number } } } = {}
	for _, side in { "Front", "Back", "Left", "Right" } do
		local L = sideLength(ctx, side)
		local widths = panels(ctx.rng, L)
		-- the door goes in the panel nearest the middle of the side
		local doorIndex = -1
		if isDoorSide[side] then
			local best = math.huge
			local x = -L / 2
			for i, w in widths do
				local c = x + w / 2
				if math.abs(c) < best then
					best = math.abs(c)
					doorIndex = i
				end
				x += w
			end
		end
		doorRanges[side] = {}
		for storey = 0, ctx.n - 1 do
			local fam = family(ctx, storey)
			local y = BASE + storey * STOREY
			local x = -L / 2
			for i, w in widths do
				local c = x + w / 2
				local isDoor = storey == 0 and i == doorIndex
				local kind = wallKind(ctx, fam, isDoor, storey)
				if fam == "Timber" and kind ~= "Window" and kind ~= "Plain" and kind ~= "Door" then
					kind = "Window"
				end
				local name = `Wall_{fam}_{kind}_{w}`
				if not Kit.Has(name) then
					name = `Wall_{fam}_Plain_{w}`
				end
				-- panels are 12 tall but storeys are 13 apart (the floor slab sits in between), so every
				-- storey but the top is stretched to close the 1-stud seam between floors
				local stretch = if storey < ctx.n - 1 then STOREY / WALL else 1
				place(ctx, name, sideFrame(ctx, side, c, y), { Collision = false, Scale = Vector3.new(1, stretch, 1) })
				if isDoor then
					table.insert(doorRanges[side], { c - 2.5, c + 2.5 })
					local frame = sideFrame(ctx, side, c, BASE)
					table.insert(ctx.doors, ctx.at * frame)
				end
				-- trims on rich stone walls
				if fam == "Stone" and ctx.wealth > 0.55 then
					if storey == ctx.n - 1 and Kit.Has(`Cornice_{w}`) then
						place(ctx, `Cornice_{w}`, sideFrame(ctx, side, c, y + WALL - 0.4) * CFrame.new(0, 0, 0.5),
							{ Collision = false, Shadows = false })
					end
					if storey == 0 and ctx.wealth > 0.75 and not isDoor and Kit.Has(`RuneBand_{w}`) then
						place(ctx, `RuneBand_{w}`, sideFrame(ctx, side, c, y + 1.9) * CFrame.new(0, 0, 0.55),
							{ Collision = false, Shadows = false })
					end
				end
				x += w
			end
		end
		-- foundation: one stretched strip per side
		local fScale = Vector3.new(L / 16, 1, 1)
		place(ctx, "Foundation_16", sideFrame(ctx, side, 0, 0), { Scale = fScale })
	end
	-- corners: one post per corner and wall family, stretched over the storeys it covers
	-- (a stacked post per storey cost 4 extra parts per storey on every building)
	local runStart = 0
	for storey = 0, ctx.n - 1 do
		local fam = family(ctx, storey)
		local last = storey == ctx.n - 1 or family(ctx, storey + 1) ~= fam
		if last then
			local y = BASE + runStart * STOREY
			local height = (storey - runStart) * STOREY + WALL
			for _, sx in { -1, 1 } do
				for _, sz in { -1, 1 } do
					place(ctx, `Corner_{fam}`, CFrame.new(sx * ctx.W / 2, y, sz * ctx.D / 2),
						{ Collision = false, Scale = Vector3.new(1, height / WALL, 1) })
				end
			end
			runStart = storey + 1
		end
	end
	-- merged collision: per side, upper storeys as one slab; ground storey split around doors
	local top = BASE + (ctx.n - 1) * STOREY + WALL
	for _, side in { "Front", "Back", "Left", "Right" } do
		local L = sideLength(ctx, side) + 1
		local function slab(a: number, b: number, y0: number, y1: number)
			if b - a < 0.2 or y1 - y0 < 0.2 then
				return
			end
			local frame = sideFrame(ctx, side, (a + b) / 2, (y0 + y1) / 2)
			box(ctx, "WallCollision", frame.Position, if side == "Front" or side == "Back"
				then Vector3.new(b - a, y1 - y0, 1)
				else Vector3.new(1, y1 - y0, b - a))
		end
		if ctx.n > 1 then
			slab(-L / 2, L / 2, BASE + STOREY, top)
		end
		local cursor = -L / 2
		local groundTop = BASE + STOREY
		if ctx.n == 1 then
			groundTop = top
		end
		local ranges = doorRanges[side]
		table.sort(ranges, function(a, b)
			return a[1] < b[1]
		end)
		for _, r in ranges do
			slab(cursor, r[1], BASE, groundTop)
			slab(r[1], r[2], BASE + 8, groundTop)
			cursor = r[2]
		end
		slab(cursor, L / 2, BASE, groundTop)
	end
end

-- FLOORS AND STAIRS --------------------------------------------------------------------

-- Picks where the stair goes (inside, against the left wall, rising toward the back).
local function planStair(ctx: Ctx)
	if ctx.n < 2 then
		return
	end
	local W, D = ctx.W, ctx.D
	if D >= 24 then
		local z1 = D / 2 - 5 -- leave room inside the front door
		ctx.stair = { x0 = -W / 2 + 0.5, x1 = -W / 2 + 4.6, z0 = z1 - 16, z1 = z1, spiral = false, alongX = false }
	elseif W >= 24 then
		local x0 = -W / 2 + 4
		ctx.stair = { x0 = x0, x1 = x0 + 16, z0 = -D / 2 + 0.5, z1 = -D / 2 + 4.6, spiral = false, alongX = true }
	else
		ctx.stair = { x0 = -W / 2 + 0.5, x1 = -W / 2 + 9.5, z0 = -D / 2 + 0.5, z1 = -D / 2 + 9.5, spiral = true,
			alongX = false }
	end
end

local function floorRect(ctx: Ctx, piece: string, x0: number, x1: number, z0: number, z1: number, y: number)
	local w, d = x1 - x0, z1 - z0
	if w < 1.5 or d < 1.5 then
		return
	end
	place(ctx, piece, CFrame.new((x0 + x1) / 2, y, (z0 + z1) / 2), { Scale = Vector3.new(w / 16, 1, d / 16), Shadows = false })
end

local function buildFloors(ctx: Ctx)
	local W, D = ctx.W, ctx.D
	floorRect(ctx, "Floor_Stone", -W / 2, W / 2, -D / 2, D / 2, BASE)
	local s = ctx.stair
	for storey = 1, ctx.n do
		local y = BASE + storey * STOREY
		if storey == ctx.n then
			-- ceiling of the top storey: a plain slab the roof sits on
			floorRect(ctx, "Floor_Wood", -W / 2, W / 2, -D / 2, D / 2, y - 1 + 0.0)
			break
		end
		if s then
			-- everything except the stairwell
			floorRect(ctx, "Floor_Wood", -W / 2, s.x0, -D / 2, D / 2, y)
			floorRect(ctx, "Floor_Wood", s.x1, W / 2, -D / 2, D / 2, y)
			floorRect(ctx, "Floor_Wood", s.x0, s.x1, -D / 2, s.z0, y)
			floorRect(ctx, "Floor_Wood", s.x0, s.x1, s.z1, D / 2, y)
		else
			floorRect(ctx, "Floor_Wood", -W / 2, W / 2, -D / 2, D / 2, y)
		end
	end
	if s then
		for storey = 0, ctx.n - 2 do
			local y = BASE + storey * STOREY
			if s.spiral then
				place(ctx, "Stair_Spiral", CFrame.new((s.x0 + s.x1) / 2, y, (s.z0 + s.z1) / 2))
			elseif s.alongX then
				-- rises toward +X: rotate so the stair's back (-Z) points along +X
				place(ctx, "Stair_Straight", CFrame.new(s.x0, y, (s.z0 + s.z1) / 2) * CFrame.Angles(0, -math.pi / 2, 0))
			else
				place(ctx, "Stair_Straight", CFrame.new((s.x0 + s.x1) / 2, y, s.z1))
			end
		end
	end
end

-- ROOF -----------------------------------------------------------------------------------

-- A smoke plume (and embers for a forge) at the chimney's Smoke anchor. One invisible part.
local function chimneySmoke(ctx: Ctx, chimney: CFrame, kind: "Hearth" | "Forge")
	local anchor = Kit.Anchor("Chimney", "Smoke") or Vector3.new(0, 8, 0)
	local holder = Instance.new("Part")
	holder.Name = "ChimneySmoke"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.new(1.5, 0.2, 1.5)
	holder.CFrame = ctx.at * chimney * CFrame.new(anchor)
	holder.Parent = ctx.model
	local smoke = Instance.new("ParticleEmitter")
	smoke.Name = "Smoke"
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Color = ColorSequence.new(Color3.fromHex(if kind == "Forge" then "#2A2624" else "#5A5A58"))
	smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
	smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 7) })
	smoke.Lifetime = NumberRange.new(4, 6)
	smoke.Rate = if kind == "Forge" then 5 else 2.5
	smoke.Speed = NumberRange.new(3, 5)
	smoke.SpreadAngle = Vector2.new(12, 12)
	smoke.Acceleration = Vector3.new(1.5, 0.6, 0) -- a slow drift with the air current
	smoke.RotSpeed = NumberRange.new(-20, 20)
	smoke.Parent = holder
	if kind == "Forge" then
		local embers = Instance.new("ParticleEmitter")
		embers.Name = "Embers"
		embers.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		embers.Color = ColorSequence.new(Color3.fromHex("#FF7A2A"), Color3.fromHex("#FFC46A"))
		embers.LightEmission = 1
		embers.Size = NumberSequence.new(0.3, 0.05)
		embers.Lifetime = NumberRange.new(1.2, 2.2)
		embers.Rate = 6
		embers.Speed = NumberRange.new(6, 10)
		embers.SpreadAngle = Vector2.new(25, 25)
		embers.Acceleration = Vector3.new(0, -3, 0)
		embers.Parent = holder
	end
end

local function buildRoof(ctx: Ctx)
	local W, D = ctx.W, ctx.D
	local top = BASE + (ctx.n - 1) * STOREY + WALL
	local roofKind = ctx.spec.Roof or (if ctx.rng:NextNumber() < 0.75 then "Gable" else "Hip")
	local ridgeAlongX = W >= D
	local L, S = if ridgeAlongX then W else D, if ridgeAlongX then D else W
	local rot = if ridgeAlongX then CFrame.identity else CFrame.Angles(0, math.pi / 2, 0)
	local rise = (Kit.Meta("Roof_Gable").rise :: number? or 6.71) * (S / 16)
	if roofKind == "Hip" then
		place(ctx, "Roof_Hip", CFrame.new(0, top, 0) * rot, { Scale = Vector3.new(L / 16, S / 16, S / 16) })
	else
		place(ctx, "Roof_Gable", CFrame.new(0, top, 0) * rot, { Scale = Vector3.new(L / 16, S / 16, S / 16) })
		local endPiece = if family(ctx, ctx.n - 1) == "Stone" then "Roof_GableEnd_Stone" else "Roof_GableEnd_Plaster"
		for _, s in { -1, 1 } do
			local frame = if ridgeAlongX
				then CFrame.new(s * W / 2, top, 0) * CFrame.Angles(0, s * math.pi / 2, 0)
				else CFrame.new(0, top, s * D / 2) * CFrame.Angles(0, if s > 0 then 0 else math.pi, 0)
			place(ctx, endPiece, frame, { Scale = Vector3.new(S / 16, S / 16, 1) })
		end
	end
	-- chimney near one end of the ridge
	local smoke = ctx.spec.Smoke
	if smoke or ctx.rng:NextNumber() < 0.85 then
		local along = (L / 2 - 3) * (if ctx.rng:NextNumber() < 0.5 then -1 else 1)
		local off = S * 0.18
		local pos = if ridgeAlongX then Vector3.new(along, top + rise * 0.35, off) else Vector3.new(off, top + rise * 0.35, along)
		place(ctx, "Chimney", CFrame.new(pos))
		if smoke then
			chimneySmoke(ctx, CFrame.new(pos), smoke :: "Hearth" | "Forge")
		end
	end
	-- dormers on the front slope of rich, tall houses
	if roofKind == "Gable" and ridgeAlongX and ctx.wealth > 0.45 and S >= 16 and L >= 16 then
		local count = math.floor(L / 12)
		for i = 1, count do
			local x = -L / 2 + (i - 0.5) * (L / count)
			place(ctx, "Dormer", CFrame.new(x, top + rise * 0.42 - 1.0, S * 0.21))
		end
	end
end

-- EXTERIOR EXTRAS ------------------------------------------------------------------------

local function buildExterior(ctx: Ctx)
	local kind = ctx.kind
	local signed = ctx.spec.Sign
	if signed == nil then
		signed = kind == "Shop" or kind == "Tavern" or kind == "Smithy"
	end
	for _, door in ctx.doors do
		local rel = ctx.at:ToObjectSpace(door)
		local outward = rel * CFrame.new(0, -BASE, 1.2)
		place(ctx, "Steps_Entrance", outward)
		if signed then
			place(ctx, "Awning", rel * CFrame.new(0, 9.4, 0.5), { Collision = false })
			place(ctx, "Sign_Hanging", rel * CFrame.new(4.4, 10.4, 0.5) * CFrame.Angles(0, math.pi / 2, 0),
				{ Collision = false })
		end
	end
	-- balconies on upper storeys of richer timber houses
	if ctx.spec.Balcony ~= false and ctx.n >= 2 and ctx.wealth > 0.5 and ctx.W >= 16 and ctx.rng:NextNumber() < 0.6 then
		local y = BASE + STOREY
		place(ctx, "Balcony", CFrame.new(0, y, ctx.D / 2 + 0.5))
	end
	-- a banner on guild-like buildings
	if kind == "Hall" or kind == "Library" or kind == "Barracks" then
		for _, s in { -1, 1 } do
			place(ctx, "Banner_Wall", CFrame.new(s * (ctx.W / 2 - 3), BASE + 11, ctx.D / 2 + 0.6), { Collision = false })
		end
	end
end

-- INTERIORS --------------------------------------------------------------------------------

type Slot = { cf: CFrame, w: number, d: number }

-- Free spots along the inside of the walls (facing into the room) on one storey.
local function wallSlots(ctx: Ctx, y: number): { Slot }
	local slots: { Slot } = {}
	local W, D = ctx.W, ctx.D
	local inset = 1.0
	local function blocked(x: number, z: number, r: number): boolean
		local s = ctx.stair
		if s and x + r > s.x0 - 1 and x - r < s.x1 + 1 and z + r > s.z0 - 1 and z - r < s.z1 + 1 then
			return true
		end
		for _, door in ctx.doors do
			local rel = ctx.at:ToObjectSpace(door).Position
			if math.abs(rel.Y - BASE) < 1 and math.abs(y - BASE) < 1 and (Vector2.new(rel.X, rel.Z) - Vector2.new(x, z)).Magnitude < r + 5 then
				return true
			end
		end
		return false
	end
	-- back wall (facing +Z into the room), side walls facing inward
	local step = 6
	local x = -W / 2 + 4
	while x <= W / 2 - 4 do
		if not blocked(x, -D / 2 + inset + 1, 3) then
			table.insert(slots, { cf = CFrame.new(x, y, -D / 2 + inset), w = 6, d = 2 })
		end
		if not blocked(x, D / 2 - inset - 1, 3) then
			table.insert(slots, { cf = CFrame.new(x, y, D / 2 - inset) * CFrame.Angles(0, math.pi, 0), w = 6, d = 2 })
		end
		x += step
	end
	local z = -D / 2 + 4
	while z <= D / 2 - 4 do
		if not blocked(-W / 2 + inset + 1, z, 3) then
			table.insert(slots, { cf = CFrame.new(-W / 2 + inset, y, z) * CFrame.Angles(0, math.pi / 2, 0), w = 6, d = 2 })
		end
		if not blocked(W / 2 - inset - 1, z, 3) then
			table.insert(slots, { cf = CFrame.new(W / 2 - inset, y, z) * CFrame.Angles(0, -math.pi / 2, 0), w = 6, d = 2 })
		end
		z += step
	end
	for i = #slots, 2, -1 do
		local j = ctx.rng:NextInteger(1, i)
		slots[i], slots[j] = slots[j], slots[i]
	end
	return slots
end

-- Pieces placed against walls are modelled with their back at +Y Blender (= -Z template) and their
-- front facing +Z, and a slot's +Z points into the room, so the piece is only pushed off the wall by
-- half its depth.
-- Furniture big enough to stand on or walk around keeps its collision; small clutter (barrels,
-- sacks, crates, rugs, racks) is visual only, which halves the parts in an interior.
local SOLID: { [string]: boolean } = {
	Bed = true,
	Bunk = true,
	Counter = true,
	Table = true,
	Bookshelf = true,
	Hearth = true,
	Forge = true,
	Cart = true,
	Crate_Stack = true,
	Anvil = true,
}

local function againstWall(ctx: Ctx, slots: { Slot }, piece: string, count: number)
	local size = Kit.Size(piece)
	for _ = 1, count do
		local slot = table.remove(slots, 1)
		if not slot then
			return
		end
		place(ctx, piece, slot.cf * CFrame.new(0, 0, size.Z / 2 + 0.1), { Shadows = false, Collision = SOLID[piece] == true })
	end
end

local function centrePieces(ctx: Ctx, y: number, list: { string })
	local W, D = ctx.W, ctx.D
	local cx, cz = 2, -1
	if ctx.stair and not ctx.stair.alongX then
		cx = 3
	end
	for i, piece in list do
		local ox = (i - 1) % 2 * 7 - 3.5
		local oz = math.floor((i - 1) / 2) * 6 - 3
		local x, z = cx + ox, cz + oz
		if math.abs(x) < W / 2 - 5 and math.abs(z) < D / 2 - 5 then
			place(ctx, piece, CFrame.new(x, y, z) * CFrame.Angles(0, ctx.rng:NextNumber(-0.1, 0.1), 0),
				{ Shadows = false, Collision = SOLID[piece] == true })
		end
	end
end

local FURNITURE: { [string]: { wall: { { any } }, centre: { string } } } = {
	House = { wall = { { "Hearth", 1 }, { "Bed", 1 }, { "Bookshelf", 1 }, { "Shelf_Wall", 1 }, { "Chest", 1 }, { "Barrel", 1 } },
		centre = { "Table", "Rug" } },
	Shop = { wall = { { "Shelf_Wall", 2 }, { "Crate_Stack", 1 }, { "Sacks", 1 }, { "Barrel", 2 } }, centre = { "Counter" } },
	Tavern = { wall = { { "Hearth", 1 }, { "Barrel", 3 }, { "Shelf_Wall", 1 }, { "Counter", 1 } },
		centre = { "Table", "Table", "Table", "Table" } },
	Smithy = { wall = { { "Forge", 1 }, { "Weapon_Rack", 2 }, { "Barrel", 1 }, { "Crate", 1 } }, centre = { "Anvil" } },
	Library = { wall = { { "Bookshelf", 5 }, { "Hearth", 1 } }, centre = { "Table", "Table", "Rug" } },
	Barracks = { wall = { { "Bunk", 4 }, { "Weapon_Rack", 1 }, { "Chest", 2 } }, centre = { "Table" } },
	Warehouse = { wall = { { "Crate_Stack", 3 }, { "Barrel", 3 }, { "Sacks", 2 } }, centre = { "Cart", "Crate_Stack" } },
	Hall = { wall = { { "Bookshelf", 2 }, { "Weapon_Rack", 2 }, { "Hearth", 1 }, { "Banner_Wall", 2 } },
		centre = { "Table", "Table", "Rug" } },
}

local function furnish(ctx: Ctx, storey: number)
	local y = BASE + storey * STOREY + (if storey == 0 then 0.1 else 0)
	local plan = FURNITURE[ctx.kind] or FURNITURE.House
	local slots = wallSlots(ctx, y)
	for _, entry in plan.wall do
		againstWall(ctx, slots, entry[1] :: string, entry[2] :: number)
	end
	centrePieces(ctx, y, plan.centre)
	-- a few chairs/stools around the first table and candles on it
	if table.find(plan.centre, "Table") then
		local x0 = (if ctx.stair and not ctx.stair.alongX then 3 else 2) - 3.5
		local z0 = -4
		for _, off in { Vector3.new(0, 0, -2.6), Vector3.new(0, 0, 2.6) } do
			local seat = if ctx.kind == "Tavern" then "Stool" else "Chair"
			local facing = if off.Z < 0 then 0 else math.pi
			place(ctx, seat, CFrame.new(x0 + off.X, y, z0 + off.Z) * CFrame.Angles(0, facing, 0), { Collision = false, Shadows = false })
		end
		place(ctx, "Candles", CFrame.new(x0 + 1.2, y + 3.0, z0), { Collision = false, Shadows = false })
	end
	-- ceiling lantern
	place(ctx, "Lantern_Hanging", CFrame.new(0, y + WALL, 0), { Collision = false, Shadows = false })
end

-- BUILD -------------------------------------------------------------------------------------

function BuildingGenerator.Build(spec: Spec, at: CFrame, parent: Instance): Result
	assert(spec.Width % 4 == 0 and spec.Width >= 8, "Width must be a multiple of 4, at least 8")
	assert(spec.Depth % 4 == 0 and spec.Depth >= 8, "Depth must be a multiple of 4, at least 8")
	local rng = Random.new(spec.Seed or 1)
	local model = Instance.new("Model")
	model.Name = spec.Name or `{spec.Kind or "House"}_{spec.Width}x{spec.Depth}`
	model:SetAttribute("Kind", spec.Kind or "House")
	model:SetAttribute("Storeys", spec.Storeys)
	local tint: { [string]: Color3 } = {
		Plaster = spec.Plaster or PLASTERS[rng:NextInteger(1, #PLASTERS)],
		Roof = spec.RoofColor or ROOFS[rng:NextInteger(1, #ROOFS)],
	}
	if spec.Cloth then
		tint.Cloth = spec.Cloth
	end
	local ctx: Ctx = {
		spec = spec,
		rng = rng,
		at = at,
		model = model,
		W = spec.Width,
		D = spec.Depth,
		n = math.clamp(spec.Storeys, 1, 4),
		style = spec.Style or "Mixed",
		kind = spec.Kind or "House",
		wealth = spec.Wealth or rng:NextNumber(0.2, 0.8),
		tint = tint,
		lit = if spec.Lit ~= nil then spec.Lit else rng:NextNumber() < 0.7,
		doors = {},
		stair = nil,
	}
	planStair(ctx)
	buildWalls(ctx)
	buildFloors(ctx)
	buildRoof(ctx)
	buildExterior(ctx)
	furnish(ctx, 0)
	if spec.InteriorAll then
		for storey = 1, ctx.n - 1 do
			furnish(ctx, storey)
		end
	end
	model.WorldPivot = at
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model.Parent = parent
	CollectionService:AddTag(model, "SpireBuilding")
	return { Model = model, Doors = ctx.doors, Height = BASE + (ctx.n - 1) * STOREY + WALL }
end

-- Instance count of a built model (for budgets).
function BuildingGenerator.Count(model: Instance): number
	return #model:GetDescendants()
end

return BuildingGenerator
