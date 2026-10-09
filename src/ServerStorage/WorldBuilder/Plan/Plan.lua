--!strict
-- Plan: data-only scene description produced by the world planners.
-- A PlanNode becomes a Model when applied in Studio; everything inside a node is
-- expressed in that node's local space (yaw-only frames, Roblox conventions).
-- Pure Luau: runs in Studio (edit time) and in the offline Luau harness.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Geom = require(Shared.Util.Geom)
local KitManifest = require(Shared.Data.KitManifest)
local KitAssemblies = require(Shared.Data.KitAssemblies)

type PlanNode = Types.PlanNode
type PiecePlacement = Types.PiecePlacement
type SolidPlacement = Types.SolidPlacement
type MarkerValue = Types.MarkerValue
type PlanStats = Types.PlanStats

export type Frame = { x: number, y: number, z: number, ry: number, s: number }

local Plan = {}

function Plan.node(name: string, x: number, y: number, z: number, ry: number, streaming: string?): PlanNode
	return {
		name = name,
		x = x,
		y = y,
		z = z,
		ry = ry,
		streaming = streaming or "Default",
		pieces = {},
		solids = {},
		lights = {},
		emitters = {},
		markers = {},
		children = {},
		tags = {},
		attributes = {},
	}
end

function Plan.child(parent: PlanNode, child: PlanNode): PlanNode
	table.insert(parent.children, child)
	return child
end

function Plan.frame(x: number, y: number, z: number, ry: number, s: number?): Frame
	return { x = x, y = y, z = z, ry = ry, s = s or 1 }
end

-- Transform a point from frame space into the frame's parent space.
function Plan.tx(f: Frame, lx: number, ly: number, lz: number): (number, number, number)
	local rx, rz = Geom.rotate(lx * f.s, lz * f.s, f.ry)
	return f.x + rx, f.y + ly * f.s, f.z + rz
end

-- Compose two frames: `inner` expressed in `outer` space.
function Plan.compose(outer: Frame, inner: Frame): Frame
	local x, y, z = Plan.tx(outer, inner.x, inner.y, inner.z)
	return { x = x, y = y, z = z, ry = outer.ry + inner.ry, s = outer.s * inner.s }
end

export type PieceOpts = {
	s: number?,
	sx: number?,
	sy: number?,
	sz: number?,
	rx: number?,
	rz: number?,
	material: string?,
	color: string?,
	tag: string?,
	noCollide: boolean?,
	text: string?,
}

function Plan.piece(node: PlanNode, kit: string, x: number, y: number, z: number, ry: number, opts: PieceOpts?): PiecePlacement
	assert(KitManifest[kit] ~= nil, "unknown kit piece " .. kit)
	local o: PieceOpts = opts or {}
	local p: PiecePlacement = {
		kit = kit,
		x = x,
		y = y,
		z = z,
		ry = ry,
		s = o.s,
		sx = o.sx,
		sy = o.sy,
		sz = o.sz,
		rx = o.rx,
		rz = o.rz,
		material = o.material,
		color = o.color,
		tag = o.tag,
		noCollide = o.noCollide,
		text = o.text,
	}
	table.insert(node.pieces, p)
	return p
end

-- Place a kit piece using a frame plus a local offset/yaw (scale inherited).
function Plan.pieceIn(node: PlanNode, f: Frame, kit: string, lx: number, ly: number, lz: number, lry: number, opts: PieceOpts?): PiecePlacement
	local x, y, z = Plan.tx(f, lx, ly, lz)
	local o: PieceOpts = opts or {}
	local s = (o.s or 1) * f.s
	local merged: PieceOpts = {
		s = if s ~= 1 then s else nil,
		sx = o.sx,
		sy = o.sy,
		sz = o.sz,
		rx = o.rx,
		rz = o.rz,
		material = o.material,
		color = o.color,
		tag = o.tag,
		noCollide = o.noCollide,
		text = o.text,
	}
	return Plan.piece(node, kit, x, y, z, f.ry + lry, merged)
end

export type SolidOpts = {
	kind: string,
	shape: string?,
	material: string?,
	color: string?,
	transparency: number?,
	tag: string?,
	name: string?,
	text: string?,
	rx: number?,
	rz: number?,
}

function Plan.solid(node: PlanNode, x: number, y: number, z: number, sx: number, sy: number, sz: number, ry: number, opts: SolidOpts): SolidPlacement
	local s: SolidPlacement = {
		kind = opts.kind,
		shape = opts.shape or "Block",
		x = x,
		y = y,
		z = z,
		sx = sx,
		sy = sy,
		sz = sz,
		ry = ry,
		rx = opts.rx,
		rz = opts.rz,
		material = opts.material,
		color = opts.color,
		transparency = opts.transparency,
		tag = opts.tag,
		name = opts.name,
		text = opts.text,
	}
	table.insert(node.solids, s)
	return s
end

-- Solid given by a centre in frame space (size is scaled by the frame).
function Plan.solidIn(node: PlanNode, f: Frame, lx: number, ly: number, lz: number, sx: number, sy: number, sz: number, lry: number, opts: SolidOpts): SolidPlacement
	local x, y, z = Plan.tx(f, lx, ly, lz)
	return Plan.solid(node, x, y, z, sx * f.s, sy * f.s, sz * f.s, f.ry + lry, opts)
end

function Plan.light(node: PlanNode, x: number, y: number, z: number, color: string, range: number, brightness: number, night: boolean)
	table.insert(node.lights, { x = x, y = y, z = z, color = color, range = range, brightness = brightness, night = night })
end

function Plan.emitter(node: PlanNode, preset: string, x: number, y: number, z: number, sx: number?, sy: number?, sz: number?, ry: number?)
	table.insert(node.emitters, { preset = preset, x = x, y = y, z = z, sx = sx, sy = sy, sz = sz, ry = ry })
end

function Plan.marker(node: PlanNode, kind: string, id: string, x: number, y: number, z: number, ry: number, attributes: { [string]: any }?)
	table.insert(node.markers, { kind = kind, id = id, x = x, y = y, z = z, ry = ry, attributes = attributes })
end

export type AssemblyOpts = {
	s: number?,
	color: string?, -- overrides the colour of fabric parts (awnings, canopies)
	material: string?,
	noLights: boolean?,
	noCollide: boolean?,
	tag: string?,
}

-- Expand a KitAssemblies entry into `node` at frame-space position.
function Plan.assembly(node: PlanNode, f: Frame, name: string, lx: number, ly: number, lz: number, lry: number, opts: AssemblyOpts?)
	local a = KitAssemblies[name]
	assert(a ~= nil, "unknown assembly " .. name)
	local o: AssemblyOpts = opts or {}
	local s = o.s or 1
	local af = Plan.compose(f, Plan.frame(lx, ly, lz, lry, s))
	local firstIndex = #node.pieces + 1
	for _, part in a.parts do
		local m = KitManifest[part.kit]
		local recolor = o.color ~= nil and m ~= nil and m.material == "Fabric"
		Plan.pieceIn(node, af, part.kit, part.x, part.y, part.z, part.ry or 0, {
			s = part.s,
			color = if recolor then o.color else part.color,
			material = part.material,
			noCollide = o.noCollide,
			tag = o.tag,
		})
	end
	if not o.noLights and a.lights then
		for _, l in a.lights do
			local x, y, z = Plan.tx(af, l.x, l.y, l.z)
			Plan.light(node, x, y, z, l.color, l.range * af.s, l.brightness, l.night)
			if l.attach then
				node.lights[#node.lights].piece = firstIndex + (l.attach :: number) - 1
			end
		end
	end
	if a.emitters then
		for _, e in a.emitters do
			local x, y, z = Plan.tx(af, e.x, e.y, e.z)
			Plan.emitter(node, e.preset, x, y, z, nil, nil, nil, af.ry)
		end
	end
end

-- Instance count estimate for budget checks (mirrors PlanApplier output).
function Plan.stats(root: PlanNode): PlanStats
	local st: PlanStats = { pieces = 0, solids = 0, lights = 0, emitters = 0, markers = 0, models = 0, instances = 0, tris = 0 }
	local function walk(n: PlanNode)
		st.models += 1
		st.instances += 1
		for _, p in n.pieces do
			st.pieces += 1
			st.instances += 1
			local m = KitManifest[p.kit]
			if m then
				st.tris += m.tris
				if m.collision == "Colliders" and not p.noCollide then
					st.instances += #m.colliders
				end
			end
		end
		st.solids += #n.solids
		st.instances += #n.solids
		st.lights += #n.lights
		for _, l in n.lights do
			st.instances += if l.piece then 1 else 2
		end
		st.emitters += #n.emitters
		st.instances += #n.emitters * 2
		st.markers += #n.markers
		st.instances += #n.markers
		for _, c in n.children do
			walk(c)
		end
	end
	walk(root)
	return st
end

-- Visit every node with its accumulated world frame.
function Plan.walk(root: PlanNode, visit: (node: PlanNode, world: Frame) -> ())
	local function go(n: PlanNode, parent: Frame)
		local w = Plan.compose(parent, Plan.frame(n.x, n.y, n.z, n.ry, 1))
		visit(n, w)
		for _, c in n.children do
			go(c, w)
		end
	end
	go(root, Plan.frame(0, 0, 0, 0, 1))
end

return Plan
