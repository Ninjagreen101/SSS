"""
Geometry helpers for The Spire building kit.

All coordinates passed to these helpers are in ROBLOX space (X right, Y up,
Z toward the viewer, front of a piece faces -Z). They are converted to Blender
space (Z up) internally, and the FBX exporter converts back, so the exported
file coordinates equal Roblox studs.
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass, field
from typing import Callable

import bmesh
import bpy
from mathutils import Vector


def rb(x: float, y: float, z: float) -> Vector:
    """Roblox (x, y, z) -> Blender (x, -z, y)."""
    return Vector((x, -z, y))


@dataclass
class Collider:
    shape: str  # "Box" or "Wedge"
    cx: float
    cy: float
    cz: float
    sx: float
    sy: float
    sz: float
    ry: float = 0.0  # yaw in degrees (Wedge slopes rise toward -Z before yaw)

    def to_dict(self) -> dict:
        return {
            "shape": self.shape,
            "c": [round(self.cx, 4), round(self.cy, 4), round(self.cz, 4)],
            "s": [round(self.sx, 4), round(self.sy, 4), round(self.sz, 4)],
            "ry": round(self.ry, 3),
        }


@dataclass
class Opening:
    kind: str  # "door" | "window" | "shop" | "arch"
    x0: float
    x1: float
    y0: float
    y1: float

    def to_dict(self) -> dict:
        return {"kind": self.kind, "x0": self.x0, "x1": self.x1, "y0": self.y0, "y1": self.y1}


@dataclass
class PieceMeta:
    id: str
    category: str
    material: str
    color: str
    collision: str = "Box"  # "Box" | "Hull" | "None" | "Colliders" | "Facade"
    bevel: float = 0.1
    weather: float = 0.0
    stretch: str = ""  # axes that may be stretched non-uniformly, e.g. "z" or "xyz"
    colliders: list[Collider] = field(default_factory=list)
    openings: list[Opening] = field(default_factory=list)
    anchors: dict[str, list[float]] = field(default_factory=dict)
    footprint: list[float] = field(default_factory=list)  # logical grid footprint [w, h, d]


class Builder:
    """Accumulates closed shells into one bmesh and optional boolean cutters."""

    def __init__(self) -> None:
        self.bm = bmesh.new()
        self.cut = bmesh.new()

    # ------------------------------------------------------------------ shells
    def _quad_shell(self, target: bmesh.types.BMesh, ring_a: list[Vector], ring_b: list[Vector]) -> None:
        va = [target.verts.new(p) for p in ring_a]
        vb = [target.verts.new(p) for p in ring_b]
        n = len(va)
        target.faces.new(list(reversed(va)))
        target.faces.new(vb)
        for i in range(n):
            j = (i + 1) % n
            target.faces.new((va[i], va[j], vb[j], vb[i]))

    def box(self, x0: float, y0: float, z0: float, x1: float, y1: float, z1: float, cut: bool = False) -> None:
        xa, xb = min(x0, x1), max(x0, x1)
        ya, yb = min(y0, y1), max(y0, y1)
        za, zb = min(z0, z1), max(z0, z1)
        ring_a = [rb(xa, ya, za), rb(xb, ya, za), rb(xb, ya, zb), rb(xa, ya, zb)]
        ring_b = [rb(xa, yb, za), rb(xb, yb, za), rb(xb, yb, zb), rb(xa, yb, zb)]
        self._quad_shell(self.cut if cut else self.bm, ring_a, ring_b)

    def cbox(self, cx: float, cy: float, cz: float, sx: float, sy: float, sz: float, cut: bool = False) -> None:
        self.box(cx - sx / 2, cy - sy / 2, cz - sz / 2, cx + sx / 2, cy + sy / 2, cz + sz / 2, cut)

    def prism_xy(self, pts: list[tuple[float, float]], z0: float, z1: float, cut: bool = False) -> None:
        """Polygon in the Roblox XY plane, extruded along Z."""
        ring_a = [rb(x, y, z0) for x, y in pts]
        ring_b = [rb(x, y, z1) for x, y in pts]
        self._quad_shell(self.cut if cut else self.bm, ring_a, ring_b)

    def prism_zy(self, pts: list[tuple[float, float]], x0: float, x1: float, cut: bool = False) -> None:
        """Polygon in the Roblox ZY plane (z, y), extruded along X."""
        ring_a = [rb(x0, y, z) for z, y in pts]
        ring_b = [rb(x1, y, z) for z, y in pts]
        self._quad_shell(self.cut if cut else self.bm, ring_a, ring_b)

    def prism_xz(self, pts: list[tuple[float, float]], y0: float, y1: float, cut: bool = False) -> None:
        """Polygon in the Roblox XZ plane (x, z), extruded along Y."""
        ring_a = [rb(x, y0, z) for x, z in pts]
        ring_b = [rb(x, y1, z) for x, z in pts]
        self._quad_shell(self.cut if cut else self.bm, ring_a, ring_b)

    def frustum(self, cx: float, cz: float, r0: float, r1: float, y0: float, y1: float, seg: int = 12, cut: bool = False) -> None:
        r1 = max(r1, 0.001)
        ring_a = [rb(cx + math.cos(a) * r0, y0, cz + math.sin(a) * r0) for a in _angles(seg)]
        ring_b = [rb(cx + math.cos(a) * r1, y1, cz + math.sin(a) * r1) for a in _angles(seg)]
        self._quad_shell(self.cut if cut else self.bm, ring_a, ring_b)

    def cyl(self, cx: float, cz: float, r: float, y0: float, y1: float, seg: int = 12, cut: bool = False) -> None:
        self.frustum(cx, cz, r, r, y0, y1, seg, cut)

    def ring(self, cx: float, cz: float, r_in: float, r_out: float, y0: float, y1: float, seg: int = 16) -> None:
        """Hollow vertical tube (annulus extruded along Y) built without booleans."""
        bm = self.bm
        def ringv(r: float, y: float) -> list:
            return [bm.verts.new(rb(cx + math.cos(a) * r, y, cz + math.sin(a) * r)) for a in _angles(seg)]
        ob, ot, ib, it = ringv(r_out, y0), ringv(r_out, y1), ringv(r_in, y0), ringv(r_in, y1)
        for i in range(seg):
            j = (i + 1) % seg
            bm.faces.new((ob[i], ob[j], ot[j], ot[i]))
            bm.faces.new((ib[j], ib[i], it[i], it[j]))
            bm.faces.new((ot[i], ot[j], it[j], it[i]))
            bm.faces.new((ib[i], ib[j], ob[j], ob[i]))

    def ring_z(self, cx: float, cy: float, r_in: float, r_out: float, z0: float, z1: float, seg: int = 24) -> None:
        """Annulus in the Roblox XY plane extruded along Z."""
        bm = self.bm
        def ringv(r: float, z: float) -> list:
            return [bm.verts.new(rb(cx + math.cos(a) * r, cy + math.sin(a) * r, z)) for a in _angles(seg)]
        of, ok, inf, ink = ringv(r_out, z0), ringv(r_out, z1), ringv(r_in, z0), ringv(r_in, z1)
        for i in range(seg):
            j = (i + 1) % seg
            bm.faces.new((of[i], of[j], ok[j], ok[i]))
            bm.faces.new((inf[j], inf[i], ink[i], ink[j]))
            bm.faces.new((ok[i], ok[j], ink[j], ink[i]))
            bm.faces.new((inf[i], inf[j], of[j], of[i]))

    def cyl_x(self, cy: float, cz: float, r: float, x0: float, x1: float, seg: int = 10) -> None:
        pts = [(cz + math.cos(a) * r, cy + math.sin(a) * r) for a in _angles(seg)]
        self.prism_zy(pts, x0, x1)

    def cyl_z(self, cx: float, cy: float, r: float, z0: float, z1: float, seg: int = 10) -> None:
        pts = [(cx + math.cos(a) * r, cy + math.sin(a) * r) for a in _angles(seg)]
        self.prism_xy(pts, z0, z1)

    def beam(self, a: tuple[float, float, float], b: tuple[float, float, float], thick: float) -> None:
        """Square beam between two Roblox points."""
        va, vb = rb(*a), rb(*b)
        axis = vb - va
        length = axis.length
        if length < 1e-4:
            return
        d = axis.normalized()
        up = Vector((0, 0, 1)) if abs(d.z) < 0.95 else Vector((1, 0, 0))
        s = d.cross(up).normalized() * (thick / 2)
        u = d.cross(s).normalized() * (thick / 2)
        ring_a = [va + s + u, va - s + u, va - s - u, va + s - u]
        ring_b = [vb + s + u, vb - s + u, vb - s - u, vb + s - u]
        self._quad_shell(self.bm, ring_a, ring_b)

    def blob(self, cx: float, cy: float, cz: float, rx: float, ry: float, rz: float, seed: int, rough: float = 0.18, subdiv: int = 1) -> None:
        """Irregular low-poly rock/canopy blob."""
        tmp = bmesh.new()
        bmesh.ops.create_icosphere(tmp, subdivisions=subdiv, radius=1.0)
        rng = random.Random(seed)
        for v in tmp.verts:
            k = 1.0 + rng.uniform(-rough, rough)
            x, y, z = v.co.x * rx * k, v.co.z * ry * k, v.co.y * rz * k
            v.co = rb(cx + x, cy + y, cz + z)
        _merge_into(self.bm, tmp)
        tmp.free()

    def dome(self, cx: float, cy: float, cz: float, r: float, rings: int = 5, seg: int = 16, height: float | None = None) -> None:
        h = r if height is None else height
        ringsv = []
        for i in range(rings + 1):
            t = (math.pi / 2) * i / rings
            rr = math.cos(t) * r
            yy = cy + math.sin(t) * h
            if i == rings:
                ringsv.append([rb(cx, yy, cz)])
            else:
                ringsv.append([rb(cx + math.cos(a) * rr, yy, cz + math.sin(a) * rr) for a in _angles(seg)])
        bm = self.bm
        rows = [[bm.verts.new(p) for p in ring] for ring in ringsv]
        bm.faces.new(list(reversed(rows[0])))
        for i in range(rings):
            a, b = rows[i], rows[i + 1]
            for j in range(seg):
                k = (j + 1) % seg
                if len(b) == 1:
                    bm.faces.new((a[j], a[k], b[0]))
                else:
                    bm.faces.new((a[j], a[k], b[k], b[j]))


def _angles(seg: int) -> list[float]:
    return [2 * math.pi * i / seg for i in range(seg)]


def _merge_into(dst: bmesh.types.BMesh, src: bmesh.types.BMesh) -> None:
    mapping = {}
    for v in src.verts:
        mapping[v] = dst.verts.new(v.co)
    for f in src.faces:
        dst.faces.new([mapping[v] for v in f.verts])


def arch_pts(x0: float, x1: float, y0: float, spring: float, seg: int = 8) -> list[tuple[float, float]]:
    """Polygon (Roblox XY) of an arched opening: rectangle to the spring line then a semicircle."""
    cx = (x0 + x1) / 2
    r = (x1 - x0) / 2
    pts = [(x0, y0), (x1, y0), (x1, spring)]
    for i in range(1, seg):
        a = math.pi * i / seg
        pts.append((cx + math.cos(a) * r, spring + math.sin(a) * r))
    pts.append((x0, spring))
    return pts


# ---------------------------------------------------------------------- finish

def finalize(name: str, b: Builder, meta: PieceMeta, rng_seed: int) -> bpy.types.Object:
    bm = b.bm
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-4)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)

    if len(b.cut.verts) > 0:
        cbm = b.cut
        bmesh.ops.recalc_face_normals(cbm, faces=cbm.faces)
        cmesh = bpy.data.meshes.new(name + "_cut")
        cbm.to_mesh(cmesh)
        cobj = bpy.data.objects.new(name + "_cut", cmesh)
        bpy.context.scene.collection.objects.link(cobj)
        mod = obj.modifiers.new("cut", "BOOLEAN")
        mod.operation = "DIFFERENCE"
        mod.solver = "EXACT"
        mod.use_self = True
        mod.use_hole_tolerant = True
        mod.object = cobj
        _apply_all(obj)
        bpy.data.objects.remove(cobj, do_unlink=True)
        bpy.data.meshes.remove(cmesh)
    b.cut.free()

    if meta.bevel > 0:
        mod = obj.modifiers.new("bevel", "BEVEL")
        mod.width = meta.bevel
        mod.segments = 1
        mod.limit_method = "ANGLE"
        mod.angle_limit = math.radians(35)
        mod.harden_normals = False
        mod.use_clamp_overlap = True
        _apply_all(obj)

    if meta.weather > 0:
        _weather(obj, meta.weather, rng_seed)

    _uv_box_project(obj, tile=8.0)
    obj.data.polygons.foreach_set("use_smooth", [False] * len(obj.data.polygons))
    return obj


def _apply_all(obj: bpy.types.Object) -> None:
    deps = bpy.context.evaluated_depsgraph_get()
    ev = obj.evaluated_get(deps)
    newmesh = bpy.data.meshes.new_from_object(ev)
    old = obj.data
    obj.modifiers.clear()
    obj.data = newmesh
    bpy.data.meshes.remove(old)


def _weather(obj: bpy.types.Object, amount: float, seed: int) -> None:
    """Edge chipping: jitter vertices that are not on the piece's bounding planes,
    so modular seams stay watertight while silhouettes feel hand-cut."""
    rng = random.Random(seed)
    vs = obj.data.vertices
    if len(vs) == 0:
        return
    xs = [v.co.x for v in vs]
    ys = [v.co.y for v in vs]
    zs = [v.co.z for v in vs]
    lo = Vector((min(xs), min(ys), min(zs)))
    hi = Vector((max(xs), max(ys), max(zs)))
    eps = 0.02
    for v in vs:
        c = v.co
        on_bound = (
            abs(c.x - lo.x) < eps or abs(c.x - hi.x) < eps
            or abs(c.y - lo.y) < eps or abs(c.y - hi.y) < eps
            or abs(c.z - lo.z) < eps or abs(c.z - hi.z) < eps
        )
        if on_bound:
            continue
        v.co = Vector((
            c.x + rng.uniform(-amount, amount),
            c.y + rng.uniform(-amount, amount),
            c.z + rng.uniform(-amount, amount),
        ))


def _uv_box_project(obj: bpy.types.Object, tile: float) -> None:
    """World-scale box projection: 1 UV unit = `tile` studs on every piece,
    which keeps texel density identical across the whole kit."""
    me = obj.data
    if not me.uv_layers:
        me.uv_layers.new(name="UVMap")
    uv = me.uv_layers.active.data
    for poly in me.polygons:
        n = poly.normal
        ax = max(range(3), key=lambda i: abs(n[i]))
        for li in poly.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            if ax == 0:
                u, v = co.y, co.z
            elif ax == 1:
                u, v = co.x, co.z
            else:
                u, v = co.x, co.y
            uv[li].uv = (u / tile, v / tile)


def bbox_roblox(obj: bpy.types.Object) -> tuple[list[float], list[float]]:
    """Return (size, center) of an object's mesh in Roblox axes."""
    vs = obj.data.vertices
    xs = [v.co.x for v in vs]
    ys = [-v.co.y for v in vs]  # roblox z
    zs = [v.co.z for v in vs]  # roblox y
    size = [max(xs) - min(xs), max(zs) - min(zs), max(ys) - min(ys)]
    center = [(max(xs) + min(xs)) / 2, (max(zs) + min(zs)) / 2, (max(ys) + min(ys)) / 2]
    return size, center


PieceFn = Callable[[], tuple[Builder, PieceMeta]]
