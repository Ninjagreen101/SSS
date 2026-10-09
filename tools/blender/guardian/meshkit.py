"""
meshkit: small procedural-modelling helpers for the Guardian generators (bpy / bmesh).

Everything here works on bmesh objects in Blender space (z up, 1 unit = 1 stud) and never uses
bpy.ops, so it runs headless. A Piece collects geometry per material channel; the generator turns
each channel into one mesh object named <Piece>__<Channel> (one Roblox MeshPart per channel).
"""

import math
import random

import bpy  # noqa: F401  (bpy first: it provides bmesh and mathutils)
import bmesh
from mathutils import Matrix, Vector, noise


# TRANSFORMS -------------------------------------------------------------------------------------

def mat(loc=(0.0, 0.0, 0.0), rot=(0.0, 0.0, 0.0), scale=(1.0, 1.0, 1.0)):
    """Location, XYZ Euler rotation in DEGREES, per-axis scale -> 4x4 matrix."""
    rx, ry, rz = (math.radians(a) for a in rot)
    r = Matrix.Rotation(rz, 4, "Z") @ Matrix.Rotation(ry, 4, "Y") @ Matrix.Rotation(rx, 4, "X")
    s = Matrix.Diagonal((scale[0], scale[1], scale[2], 1.0))
    return Matrix.Translation(Vector(loc)) @ r @ s


def look_rot(direction, up=(0.0, 0.0, 1.0)):
    """4x4 rotation that maps local +Z onto `direction` (local +Y stays as close to `up` as it can)."""
    z = Vector(direction).normalized()
    upv = Vector(up)
    if abs(z.dot(upv.normalized())) > 0.98:
        upv = Vector((0.0, 1.0, 0.0)) if abs(z.y) < 0.9 else Vector((1.0, 0.0, 0.0))
    x = upv.cross(z).normalized()
    y = z.cross(x).normalized()
    m = Matrix((x, y, z)).transposed()
    return m.to_4x4()


def align(loc, direction, spin=0.0, scale=(1.0, 1.0, 1.0), up=(0.0, 0.0, 1.0)):
    """Matrix placing a +Z-pointing primitive at `loc`, pointing along `direction`."""
    s = Matrix.Diagonal((scale[0], scale[1], scale[2], 1.0))
    return Matrix.Translation(Vector(loc)) @ look_rot(direction, up) @ Matrix.Rotation(math.radians(spin), 4, "Z") @ s


# PRIMITIVES (each returns a fresh bmesh) -----------------------------------------------------------

def box(sx, sy, sz):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=(sx, sy, sz), verts=bm.verts)
    return bm


def sphere(rx, ry, rz, u=12, v=8):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=u, v_segments=v, radius=1.0)
    bmesh.ops.scale(bm, vec=(rx, ry, rz), verts=bm.verts)
    return bm


def ico(r, subdiv=1):
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=r)
    return bm


def lathe(profile, segs=12, cap_bottom=True, cap_top=True, phase=0.0):
    """Revolves [(radius, z), ...] (bottom to top) around +Z."""
    bm = bmesh.new()
    rings = []
    for r, z in profile:
        ring = []
        for i in range(segs):
            a = phase + 2 * math.pi * i / segs
            ring.append(bm.verts.new((r * math.cos(a), r * math.sin(a), z)))
        rings.append(ring)
    for a, b in zip(rings, rings[1:]):
        for i in range(segs):
            j = (i + 1) % segs
            bm.faces.new((a[i], a[j], b[j], b[i]))
    if cap_bottom and profile[0][0] > 1e-5:
        bm.faces.new(list(reversed(rings[0])))
    if cap_top and profile[-1][0] > 1e-5:
        bm.faces.new(rings[-1])
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


def cone(r_base, length, segs=6, r_tip=0.0):
    """A spike along +Z from z=0 (base) to z=length (tip)."""
    if r_tip <= 1e-5:
        bm = bmesh.new()
        ring = [bm.verts.new((r_base * math.cos(2 * math.pi * i / segs), r_base * math.sin(2 * math.pi * i / segs), 0.0)) for i in range(segs)]
        tip = bm.verts.new((0.0, 0.0, length))
        for i in range(segs):
            bm.faces.new((ring[i], ring[(i + 1) % segs], tip))
        bm.faces.new(list(reversed(ring)))
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        return bm
    return lathe([(r_base, 0.0), (r_tip, length)], segs)


def _frames(points):
    """Parallel-transport frames along a polyline: list of (tangent, normal, binormal)."""
    pts = [Vector(p) for p in points]
    tangents = []
    for i in range(len(pts)):
        if i == 0:
            t = pts[1] - pts[0]
        elif i == len(pts) - 1:
            t = pts[-1] - pts[-2]
        else:
            t = (pts[i + 1] - pts[i - 1])
        tangents.append(t.normalized())
    ref = Vector((0.0, 0.0, 1.0))
    if abs(tangents[0].dot(ref)) > 0.9:
        ref = Vector((1.0, 0.0, 0.0))
    n = tangents[0].cross(ref).normalized()
    frames = []
    for i, t in enumerate(tangents):
        if i > 0:
            prev = tangents[i - 1]
            axis = prev.cross(t)
            if axis.length > 1e-6:
                ang = prev.angle(t)
                n = (Matrix.Rotation(ang, 3, axis.normalized()) @ n).normalized()
        b = t.cross(n).normalized()
        n = b.cross(t).normalized()
        frames.append((t, n, b))
    return pts, frames


def sweep(points, radii, sides=6, flat=1.0, cap_start=True, cap_end=True, tip=False, twist=0.0):
    """Tube along a polyline. radii: one per point. flat < 1 squashes the section along the binormal.
    tip=True closes the end into a point."""
    pts, frames = _frames(points)
    bm = bmesh.new()
    rings = []
    count = len(pts)
    for i, (p, (t, n, b)) in enumerate(zip(pts, frames)):
        r = radii[i]
        if tip and i == count - 1:
            rings.append([bm.verts.new(p)])
            continue
        ring = []
        tw = twist * i / max(1, count - 1)
        for k in range(sides):
            a = 2 * math.pi * k / sides + tw
            off = n * (math.cos(a) * r) + b * (math.sin(a) * r * flat)
            ring.append(bm.verts.new(p + off))
        rings.append(ring)
    for a, c in zip(rings, rings[1:]):
        if len(c) == 1:
            for k in range(sides):
                bm.faces.new((a[k], a[(k + 1) % sides], c[0]))
        else:
            for k in range(sides):
                j = (k + 1) % sides
                bm.faces.new((a[k], a[j], c[j], c[k]))
    if cap_start:
        bm.faces.new(list(reversed(rings[0])))
    if cap_end and not tip:
        bm.faces.new(rings[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


def shell(fn, nu, nv, thick, rim_bevel=0.0, inside=None):
    """Solid shell from a parametric surface fn(u, v) -> (x, y, z) with u, v in [0, 1].
    The outer face is the surface; the inner face sits `thick` behind it along the surface normal.
    With `inside` (a point), the normal is turned to face away from it, so the shell always grows
    toward that point whatever the parametrisation's winding."""
    grid = [[Vector(fn(i / nu, j / nv)) for j in range(nv + 1)] for i in range(nu + 1)]

    def normal(i, j):
        i0, i1 = max(0, i - 1), min(nu, i + 1)
        j0, j1 = max(0, j - 1), min(nv, j + 1)
        du = grid[i1][j] - grid[i0][j]
        dv = grid[i][j1] - grid[i][j0]
        n = du.cross(dv)
        n = n.normalized() if n.length > 1e-9 else Vector((0.0, 0.0, 1.0))
        if inside is not None and n.dot(grid[i][j] - Vector(inside)) < 0:
            n = -n
        return n

    bm = bmesh.new()
    outer = [[bm.verts.new(grid[i][j]) for j in range(nv + 1)] for i in range(nu + 1)]
    inner = [[bm.verts.new(grid[i][j] - normal(i, j) * thick) for j in range(nv + 1)] for i in range(nu + 1)]
    for i in range(nu):
        for j in range(nv):
            bm.faces.new((outer[i][j], outer[i + 1][j], outer[i + 1][j + 1], outer[i][j + 1]))
            bm.faces.new((inner[i][j + 1], inner[i + 1][j + 1], inner[i + 1][j], inner[i][j]))
    for i in range(nu):
        bm.faces.new((outer[i][0], inner[i][0], inner[i + 1][0], outer[i + 1][0]))
        bm.faces.new((outer[i + 1][nv], inner[i + 1][nv], inner[i][nv], outer[i][nv]))
    for j in range(nv):
        bm.faces.new((outer[0][j + 1], inner[0][j + 1], inner[0][j], outer[0][j]))
        bm.faces.new((outer[nu][j], inner[nu][j], inner[nu][j + 1], outer[nu][j + 1]))
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    if rim_bevel > 0:
        bevel_sharp(bm, rim_bevel, 1, 50)
    return bm


def prism(poly, depth, bevel=0.0, segments=1):
    """A 2D polygon [(x, y), ...] (counter-clockwise, in the XY plane) extruded along Z
    from -depth/2 to +depth/2, optionally bevelled."""
    bm = bmesh.new()
    bottom = [bm.verts.new((x, y, -depth / 2)) for x, y in poly]
    top = [bm.verts.new((x, y, depth / 2)) for x, y in poly]
    n = len(poly)
    bm.faces.new(list(reversed(bottom)))
    bm.faces.new(top)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((bottom[i], bottom[j], top[j], top[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    if bevel > 0:
        bevel_sharp(bm, bevel, segments, 30)
    bmesh.ops.triangulate(bm, faces=[f for f in bm.faces if len(f.verts) > 4])
    return bm


# OPERATIONS -------------------------------------------------------------------------------------

def bevel_sharp(bm, offset, segments=1, angle_deg=30.0):
    edges = [e for e in bm.edges if e.is_manifold and e.calc_face_angle(0.0) > math.radians(angle_deg)]
    if edges:
        bmesh.ops.bevel(bm, geom=edges, offset=offset, offset_type="OFFSET", segments=segments, profile=0.5,
                        affect="EDGES", clamp_overlap=True)
    return bm


def transform(bm, m):
    bmesh.ops.transform(bm, matrix=m, verts=bm.verts)
    return bm


def roughen(bm, amount, freq=1.0, seed=0, mask=None):
    """Pushes vertices along their normals by fractal noise: dents, chips and worn edges."""
    bm.normal_update()
    off = Vector((seed * 13.17, seed * 7.31, seed * 3.77))
    for v in bm.verts:
        if mask is not None and not mask(v.co):
            continue
        p = v.co * freq + off
        d = noise.fractal(p, 0.6, 2.2, 3, noise_basis="PERLIN_ORIGINAL")
        v.co += v.normal * (d * amount)
    return bm


def chip(bm, amount, freq=2.5, seed=0, threshold=0.35):
    """Cellular dents: vertices inside Voronoi cell borders sink, which reads as chipped plate."""
    bm.normal_update()
    off = Vector((seed * 5.1, seed * 9.7, seed * 2.3))
    for v in bm.verts:
        dist = noise.voronoi(v.co * freq + off, distance_metric="DISTANCE")[0]
        f = dist[1] - dist[0] if len(dist) > 1 else 1.0
        if f < threshold:
            v.co -= v.normal * amount * (1 - f / threshold)
    return bm


def tri_count(bm):
    return sum(len(f.verts) - 2 for f in bm.faces)


def merge_into(dst, src):
    me = bpy.data.meshes.new("_tmp")
    src.to_mesh(me)
    dst.from_mesh(me)
    bpy.data.meshes.remove(me)


# PIECES -----------------------------------------------------------------------------------------

class Piece:
    """One rigid body piece: geometry per material channel, in Blender world space (rest pose)."""

    def __init__(self, name, limb, role, origin, **meta):
        self.name = name
        self.limb = limb
        self.role = role
        self.origin = Vector(origin)
        self.meta = meta
        self.channels = {}
        self.anchors = {}

    def add(self, channel, bm, m=None):
        if m is not None:
            transform(bm, m)
        dst = self.channels.get(channel)
        if dst is None:
            dst = bmesh.new()
            self.channels[channel] = dst
        merge_into(dst, bm)
        bm.free()

    def anchor(self, name, pos, yaw=0.0):
        self.anchors[name] = (Vector(pos), yaw)

    def tris(self):
        return {ch: tri_count(bm) for ch, bm in self.channels.items()}


# SCATTER ----------------------------------------------------------------------------------------

def barnacle(r, h, segs=6):
    """A volcano-shaped barnacle: wide plated base, narrow open crater."""
    prof = [(r, 0.0), (r * 0.8, h * 0.55), (r * 0.42, h), (r * 0.2, h * 0.6)]
    bm = lathe(prof, segs, cap_bottom=False, cap_top=True)
    return bm


def surface_points(bm, count, rng, region=None, min_dot=None, up=None):
    """Area-weighted random points (position, normal) on a bmesh's faces."""
    bm.normal_update()
    faces = []
    weights = []
    for f in bm.faces:
        c = f.calc_center_median()
        if region is not None and not region(c, f.normal):
            continue
        if min_dot is not None and up is not None and f.normal.dot(Vector(up)) < min_dot:
            continue
        a = f.calc_area()
        if a <= 1e-6:
            continue
        faces.append(f)
        weights.append(a)
    if not faces:
        return []
    total = sum(weights)
    out = []
    for _ in range(count):
        x = rng.random() * total
        acc = 0.0
        chosen = faces[-1]
        for f, w in zip(faces, weights):
            acc += w
            if acc >= x:
                chosen = f
                break
        vs = [v.co for v in chosen.verts]
        a, b = rng.random(), rng.random()
        if a + b > 1:
            a, b = 1 - a, 1 - b
        p = vs[0] + (vs[1] - vs[0]) * a + (vs[-1] - vs[0]) * b
        out.append((p.copy(), chosen.normal.copy()))
    return out


def scatter(piece, channel, host_bm, count, size, seed, region=None, sink=0.12, segs=6, min_dot=None, up=None,
            make=None):
    """Grows `count` barnacles (or `make(r, rng)` shapes) on the host surface, aligned to its normal."""
    rng = random.Random(seed)
    for p, n in surface_points(host_bm, count, rng, region, min_dot, up):
        r = size * (0.55 + rng.random() * 0.6)
        shape = make(r, rng) if make else barnacle(r, r * (0.9 + rng.random() * 0.6), segs)
        piece.add(channel, shape, align(p - n * sink * r, n, spin=rng.random() * 360))


def coral(piece, channel, base, direction, length, radius, seed, depth=2, branches=3, sides=4):
    """A small branching coral growth (tapered tubes forking at random, blunt rounded tips)."""
    rng = random.Random(seed)

    def grow(p, d, length, radius, level):
        d = Vector(d).normalized()
        n = 3
        pts = [Vector(p)]
        for i in range(1, n + 1):
            jitter = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1))) * 0.25
            d = (d + jitter * 0.6).normalized()
            pts.append(pts[-1] + d * (length / n))
        radii = [radius * (1 - 0.5 * i / n) for i in range(n + 1)]
        pts.append(pts[-1] + d * radii[-1] * 0.9)
        radii.append(radii[-1] * 0.45)
        piece.add(channel, sweep(pts, radii, sides=sides, cap_start=False, cap_end=True))
        if level < depth:
            for _ in range(branches if level == 0 else max(1, branches - 1)):
                k = rng.randint(1, n - 1)
                side = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-0.2, 1))).normalized()
                nd = (d + side * 0.9).normalized()
                grow(pts[k], nd, length * 0.55, radii[k] * 0.8, level + 1)

    grow(base, direction, length, radius, 0)


def decimate(bm, ratio):
    """Collapse-decimates a bmesh in place (Blender's Decimate modifier, evaluated headless)."""
    if ratio >= 0.999:
        return bm
    me = bpy.data.meshes.new("_dec")
    bm.to_mesh(me)
    ob = bpy.data.objects.new("_dec", me)
    bpy.context.scene.collection.objects.link(ob)
    mod = ob.modifiers.new("dec", "DECIMATE")
    mod.decimate_type = "COLLAPSE"
    mod.ratio = ratio
    mod.use_collapse_triangulate = True
    dg = bpy.context.evaluated_depsgraph_get()
    ev = ob.evaluated_get(dg)
    out = ev.to_mesh()
    bm.clear()
    bm.from_mesh(out)
    ev.to_mesh_clear()
    bpy.data.objects.remove(ob)
    bpy.data.meshes.remove(me)
    return bm
