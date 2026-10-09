"""
Renders a world plan (JSON from tools/harness) with the real kit meshes, so the
generators can be reviewed without Roblox Studio.

    python tools/blender/preview_plan.py --plan out.json --out shot.png \
        --cam 120,80,-160 --target 60,10,0 [--terrain terrain.json] [--night]
Multiple cameras: --shots "name:cx,cy,cz:tx,ty,tz:lens;name2:..."
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from palette import PALETTE  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def parse() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    p = argparse.ArgumentParser()
    p.add_argument("--plan", required=True)
    p.add_argument("--out", default="")
    p.add_argument("--shots", default="")
    p.add_argument("--cam", default="100,80,-150")
    p.add_argument("--target", default="0,10,0")
    p.add_argument("--lens", type=float, default=35)
    p.add_argument("--terrain", default="")
    p.add_argument("--night", action="store_true")
    p.add_argument("--samples", type=int, default=24)
    p.add_argument("--res", default="1280x720")
    p.add_argument("--colliders", action="store_true")
    p.add_argument("--clip", type=float, default=6000)
    p.add_argument("--blend", default="")
    return p.parse_args(argv)


def rb(x: float, y: float, z: float) -> Vector:
    return Vector((x, -z, y))


def hex_rgb(h: str) -> tuple[float, float, float]:
    h = h.lstrip("#")

    def lin(c: float) -> float:
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return (lin(int(h[0:2], 16) / 255), lin(int(h[2:4], 16) / 255), lin(int(h[4:6], 16) / 255))


ROUGH = {"Glass": 0.05, "Neon": 0.5, "Metal": 0.4, "Marble": 0.3, "Slate": 0.55, "Ice": 0.1}


def material(mat: str, color: str, transparency: float = 0.0, night: bool = False, tag: str = "") -> bpy.types.Material:
    key = f"pv_{mat}_{color}_{transparency:.2f}_{tag}_{int(night)}"
    m = bpy.data.materials.get(key)
    if m:
        return m
    m = bpy.data.materials.new(key)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    rgb = hex_rgb(PALETTE.get(color, color if len(color) == 6 else "808080"))
    bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Roughness"].default_value = ROUGH.get(mat, 0.75)
    if mat == "Metal":
        bsdf.inputs["Metallic"].default_value = 0.7
    glow = mat == "Neon" or (night and tag in ("WindowGlow",))
    if glow:
        gcol = rgb if mat == "Neon" else hex_rgb(PALETTE["WindowGlow"])
        bsdf.inputs["Emission Color"].default_value = (*gcol, 1.0)
        bsdf.inputs["Emission Strength"].default_value = 4.0 if mat == "Neon" else 3.0
    alpha = 1.0 - transparency
    if mat == "Glass" and not glow:
        alpha = min(alpha, 0.35)
    if alpha < 0.999:
        bsdf.inputs["Alpha"].default_value = alpha
        bsdf.inputs["Transmission Weight"].default_value = 0.0
    return m


def load_kit() -> dict[str, bpy.types.Mesh]:
    path = os.path.join(REPO, "assets", "kit", "kit.blend")
    with bpy.data.libraries.load(path, link=False) as (src, dst):
        dst.objects = list(src.objects)
    return {o.name: o.data for o in dst.objects if o is not None and o.type == "MESH"}


def manifest() -> dict[str, dict]:
    with open(os.path.join(REPO, "assets", "kit", "kit_manifest.json"), encoding="utf-8") as f:
        return {e["id"]: e for e in json.load(f)}


class Scene:
    def __init__(self, night: bool, colliders: bool) -> None:
        self.kit = load_kit()
        self.man = manifest()
        self.night = night
        self.colliders = colliders
        self.coll = bpy.data.collections.new("plan")
        bpy.context.scene.collection.children.link(self.coll)
        self.cube = self._prim_cube()
        self.wedge = self._prim_wedge()
        self.cyl = self._prim_cyl()
        self.mesh_mat_cache: dict[tuple[str, str], bpy.types.Mesh] = {}
        self.count = 0

    def _prim_cube(self) -> bpy.types.Mesh:
        me = bpy.data.meshes.new("pv_cube")
        v = [(-0.5, -0.5, -0.5), (0.5, -0.5, -0.5), (0.5, 0.5, -0.5), (-0.5, 0.5, -0.5),
             (-0.5, -0.5, 0.5), (0.5, -0.5, 0.5), (0.5, 0.5, 0.5), (-0.5, 0.5, 0.5)]
        f = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
        me.from_pydata(v, [], f)
        return me

    def _prim_wedge(self) -> bpy.types.Mesh:
        # Roblox WedgePart: full height at +Z (Blender -Y), zero at -Z (Blender +Y)
        me = bpy.data.meshes.new("pv_wedge")
        v = [(-0.5, 0.5, -0.5), (0.5, 0.5, -0.5), (0.5, -0.5, -0.5), (-0.5, -0.5, -0.5),
             (-0.5, -0.5, 0.5), (0.5, -0.5, 0.5)]
        f = [(0, 3, 2, 1), (3, 4, 5, 2), (0, 1, 5, 4), (0, 4, 3), (1, 2, 5)]
        me.from_pydata(v, [], f)
        return me

    def _prim_cyl(self) -> bpy.types.Mesh:
        me = bpy.data.meshes.new("pv_cyl")
        n = 16
        v = []
        for x in (-0.5, 0.5):
            for i in range(n):
                a = 2 * math.pi * i / n
                v.append((x, math.cos(a) * 0.5, math.sin(a) * 0.5))
        f = [tuple(range(n - 1, -1, -1)), tuple(range(n, 2 * n))]
        for i in range(n):
            j = (i + 1) % n
            f.append((i, j, n + j, n + i))
        me.from_pydata(v, [], f)
        return me

    def piece_mesh(self, kit: str, mat: str, color: str, tag: str) -> bpy.types.Mesh:
        key = (kit, mat + "|" + color + "|" + tag)
        me = self.mesh_mat_cache.get(key)
        if me:
            return me
        base = self.kit[kit]
        me = base.copy()
        me.materials.clear()
        me.materials.append(material(mat, color, 0.0, self.night, tag))
        self.mesh_mat_cache[key] = me
        return me

    def add(self, name: str, me: bpy.types.Mesh, loc: Vector, ry: float, scale: tuple[float, float, float], rx: float = 0.0, rz: float = 0.0) -> None:
        o = bpy.data.objects.new(name, me)
        o.location = loc
        o.rotation_mode = "ZXY"
        o.rotation_euler = (rx, -rz, ry)
        o.scale = scale
        self.coll.objects.link(o)
        self.count += 1

    def node(self, n: dict, fx: float, fy: float, fz: float, fry: float) -> None:
        c, s = math.cos(fry), math.sin(fry)

        def tx(x: float, y: float, z: float) -> tuple[float, float, float]:
            return fx + x * c + z * s, fy + y, fz - x * s + z * c

        for p in n.get("pieces", []):
            m = self.man.get(p["kit"])
            if not m:
                continue
            mat = p.get("material") or m["material"]
            col = p.get("color") or m["color"]
            me = self.piece_mesh(p["kit"], mat, col, p.get("tag") or "")
            x, y, z = tx(p["x"], p["y"], p["z"])
            sc = p.get("s") or 1.0
            sx, sy, sz = (p.get("sx") or 1.0) * sc, (p.get("sy") or 1.0) * sc, (p.get("sz") or 1.0) * sc
            self.add(p["kit"], me, rb(x, y, z), fry + p["ry"], (sx, sz, sy), p.get("rx") or 0.0, p.get("rz") or 0.0)
        for sd in n.get("solids", []):
            kind = sd["kind"]
            if kind in ("Collider", "Trigger") and not self.colliders:
                continue
            mat = sd.get("material") or ("Neon" if kind in ("Current", "Falls") else "SmoothPlastic")
            col = sd.get("color") or ("CurrentTeal" if kind in ("Current", "Falls") else "Stone")
            tr = sd.get("transparency") or 0.0
            if kind == "Collider":
                mat, col, tr = "SmoothPlastic", "Ember", 0.6
            if kind == "Current":
                mat, tr = "Neon", max(tr, 0.45)
            me0 = {"Block": self.cube, "Wedge": self.wedge, "Cylinder": self.cyl}.get(sd.get("shape", "Block"), self.cube)
            key = (me0.name, f"{mat}|{col}|{tr:.2f}|{sd.get('tag') or ''}")
            me = self.mesh_mat_cache.get(key)
            if not me:
                me = me0.copy()
                me.materials.append(material(mat, col, tr, self.night, sd.get("tag") or ""))
                self.mesh_mat_cache[key] = me
            x, y, z = tx(sd["x"], sd["y"], sd["z"])
            self.add("solid_" + kind, me, rb(x, y, z), fry + sd["ry"], (sd["sx"], sd["sz"], sd["sy"]), sd.get("rx") or 0.0, sd.get("rz") or 0.0)
        if self.night:
            for li in n.get("lights", []):
                x, y, z = tx(li["x"], li["y"], li["z"])
                ld = bpy.data.lights.new("l", "POINT")
                ld.color = hex_rgb(PALETTE.get(li["color"], "FFC27A"))
                ld.energy = li["brightness"] * li["range"] * li["range"] * 1.6
                ld.shadow_soft_size = 0.5
                ld.use_shadow = False
                lo = bpy.data.objects.new("light", ld)
                lo.location = rb(x, y, z)
                self.coll.objects.link(lo)
        for ch in n.get("children", []):
            x, y, z = tx(ch["x"], ch["y"], ch["z"])
            self.node(ch, x, y, z, fry + ch["ry"])


def build_terrain(path: str, night: bool) -> None:
    with open(path, encoding="utf-8") as f:
        t = json.load(f)
    nx, nz, step = t["nx"], t["nz"], t["step"]
    x0, z0 = t["x0"], t["z0"]
    heights, mats = t["heights"], t["materials"]
    names = t["materialNames"]
    colors = t["materialColors"]
    me = bpy.data.meshes.new("terrain")
    verts = []
    for j in range(nz):
        for i in range(nx):
            h = heights[j * nx + i]
            verts.append(rb(x0 + i * step, h, z0 + j * step))
    faces = []
    fmat = []
    for j in range(nz - 1):
        for i in range(nx - 1):
            a = j * nx + i
            faces.append((a, a + 1, a + nx + 1, a + nx))
            fmat.append(mats[j * nx + i])
    me.from_pydata(verts, [], faces)
    for name in names:
        me.materials.append(material("Terrain", colors[name], 0.0, night, ""))
    me.polygons.foreach_set("material_index", fmat)
    o = bpy.data.objects.new("terrain", me)
    bpy.context.scene.collection.objects.link(o)
    if t.get("water"):
        w = [v if isinstance(v, (int, float)) else None for v in t["water"]]
        wm = bpy.data.meshes.new("water")
        wv, wf = [], []
        for j in range(nz):
            for i in range(nx):
                wv.append(rb(x0 + i * step, w[j * nx + i] if w[j * nx + i] is not None else -999, z0 + j * step))
        for j in range(nz - 1):
            for i in range(nx - 1):
                a = j * nx + i
                if all(w[k] is not None for k in (a, a + 1, a + nx, a + nx + 1)):
                    wf.append((a, a + 1, a + nx + 1, a + nx))
        wm.from_pydata(wv, [], wf)
        wmat = bpy.data.materials.new("water")
        wmat.use_nodes = True
        b = wmat.node_tree.nodes["Principled BSDF"]
        b.inputs["Base Color"].default_value = (*hex_rgb(PALETTE["Water"]), 1)
        b.inputs["Roughness"].default_value = 0.08
        b.inputs["Alpha"].default_value = 0.8
        wm.materials.append(wmat)
        wo = bpy.data.objects.new("water", wm)
        bpy.context.scene.collection.objects.link(wo)


def setup_render(a: argparse.Namespace) -> None:
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = a.samples
    sc.cycles.use_denoising = True
    try:
        sc.cycles.denoiser = "OPENIMAGEDENOISE"
    except TypeError:
        pass
    sc.cycles.max_bounces = 4
    w, h = (int(v) for v in a.res.split("x"))
    sc.render.resolution_x, sc.render.resolution_y = w, h
    sc.view_settings.view_transform = "AgX" if "AgX" in [i.identifier for i in sc.view_settings.bl_rna.properties["view_transform"].enum_items] else "Filmic"
    world = bpy.data.worlds.new("w")
    sc.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    if a.night:
        bg.inputs[0].default_value = (0.012, 0.018, 0.035, 1)
        bg.inputs[1].default_value = 1.0
    else:
        bg.inputs[0].default_value = (0.45, 0.52, 0.62, 1)
        bg.inputs[1].default_value = 0.9
    sun = bpy.data.lights.new("sun", "SUN")
    sun.energy = 0.35 if a.night else 3.2
    sun.color = (0.6, 0.7, 1.0) if a.night else (1.0, 0.94, 0.86)
    sun.angle = math.radians(3)
    so = bpy.data.objects.new("sun", sun)
    so.rotation_euler = (math.radians(52), math.radians(8), math.radians(-38))
    sc.collection.objects.link(so)
    cam = bpy.data.cameras.new("cam")
    cam.clip_end = a.clip
    cam.clip_start = 0.5
    co = bpy.data.objects.new("cam", cam)
    sc.collection.objects.link(co)
    sc.camera = co


def shoot(name: str, cam_p: list[float], tgt: list[float], lens: float, out: str) -> None:
    co = bpy.context.scene.camera
    co.data.lens = lens
    co.location = rb(*cam_p)
    d = rb(*tgt) - co.location
    co.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.render.filepath = out
    bpy.ops.render.render(write_still=True)
    print("wrote", out)


def main() -> None:
    a = parse()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    setup_render(a)
    with open(a.plan, encoding="utf-8") as f:
        data = json.load(f)
    plan = data["plan"] if "plan" in data else data
    sc = Scene(a.night, a.colliders)
    sc.node(plan, plan.get("x", 0), plan.get("y", 0), plan.get("z", 0), plan.get("ry", 0))
    print("objects", sc.count)
    if a.terrain:
        build_terrain(a.terrain, a.night)
    if a.blend:
        bpy.ops.wm.save_as_mainfile(filepath=a.blend)
    if a.shots:
        for spec in a.shots.split(";"):
            if not spec.strip():
                continue
            name, cp, tp, lens = spec.split(":")
            shoot(name, [float(v) for v in cp.split(",")], [float(v) for v in tp.split(",")], float(lens),
                  os.path.join(a.out, name + ".png"))
    else:
        shoot("shot", [float(v) for v in a.cam.split(",")], [float(v) for v in a.target.split(",")], a.lens, a.out)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        import traceback
        traceback.print_exc()
        sys.stdout.flush()
        os._exit(1)
    sys.stdout.flush()
    os._exit(0)
