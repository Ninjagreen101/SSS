"""
Renders the Instances produced by the real PlanApplier (dumped from Lune by
tools/lune/build_world.luau) so applier transforms - piece origins, centre
offsets, scale, collider boxes and wedges - can be checked visually against
the plan renderer.

    python tools/blender/preview_parts.py --parts build/Lowharbor_world.rbxl.parts.json \
        --out shot.png --cam 150,70,980 --target 20,25,800 [--colliders]
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import preview_plan as pp  # noqa: E402

P = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))  # roblox -> blender
PI = P.inverted()


def parse() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    p = argparse.ArgumentParser()
    p.add_argument("--parts", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--cam", default="150,70,980")
    p.add_argument("--target", default="20,25,800")
    p.add_argument("--lens", type=float, default=30)
    p.add_argument("--colliders", action="store_true")
    p.add_argument("--samples", type=int, default=16)
    p.add_argument("--res", default="1280x720")
    p.add_argument("--night", action="store_true")
    p.add_argument("--terrain", default="")
    p.add_argument("--clip", type=float, default=4000)
    return p.parse_args(argv)


def roblox_matrix(cf: list[float], scale: tuple[float, float, float]) -> Matrix:
    x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf
    m = Matrix(((r00, r01, r02, x), (r10, r11, r12, y), (r20, r21, r22, z), (0, 0, 0, 1)))
    s = Matrix.Diagonal((scale[0], scale[1], scale[2], 1))
    return P @ m @ s @ PI


def unit_mesh(kind: str) -> bpy.types.Mesh:
    me = bpy.data.meshes.new("unit_" + kind)
    if kind == "wedge":
        rv = [(-0.5, -0.5, -0.5), (0.5, -0.5, -0.5), (0.5, -0.5, 0.5), (-0.5, -0.5, 0.5), (-0.5, 0.5, 0.5), (0.5, 0.5, 0.5)]
        f = [(0, 3, 2, 1), (3, 4, 5, 2), (0, 1, 5, 4), (0, 4, 3), (1, 2, 5)]
    elif kind == "cyl":
        n = 16
        rv = []
        for xx in (-0.5, 0.5):
            for i in range(n):
                a = 2 * math.pi * i / n
                rv.append((xx, math.cos(a) * 0.5, math.sin(a) * 0.5))
        f = [tuple(range(n - 1, -1, -1)), tuple(range(n, 2 * n))]
        for i in range(n):
            j = (i + 1) % n
            f.append((i, j, n + j, n + i))
    else:
        rv = [(-0.5, -0.5, -0.5), (0.5, -0.5, -0.5), (0.5, -0.5, 0.5), (-0.5, -0.5, 0.5),
              (-0.5, 0.5, -0.5), (0.5, 0.5, -0.5), (0.5, 0.5, 0.5), (-0.5, 0.5, 0.5)]
        f = [(0, 1, 2, 3), (4, 7, 6, 5), (0, 4, 5, 1), (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)]
    me.from_pydata([tuple(pp.rb(*v)) for v in rv], [], f)
    me.validate()
    return me


def main() -> None:
    a = parse()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    pp.setup_render(argparse.Namespace(samples=a.samples, res=a.res, night=a.night, clip=a.clip))
    kit = pp.load_kit()
    man = pp.manifest()
    prims = {"Block": unit_mesh("box"), "Wedge": unit_mesh("wedge"), "Cylinder": unit_mesh("cyl")}
    cache: dict[tuple, bpy.types.Mesh] = {}
    coll = bpy.data.collections.new("parts")
    bpy.context.scene.collection.children.link(coll)
    with open(a.parts, encoding="utf-8") as f:
        parts = json.load(f)
    shown = 0
    for p in parts:
        name = p["name"]
        is_collider = name.endswith("_Collider") or (p["transparency"] >= 0.999 and p["collide"])
        if is_collider and not a.colliders:
            continue
        if p["transparency"] >= 0.999 and not is_collider:
            continue
        mat_name = p["material"]
        color = p["color"]
        tr = p["transparency"]
        if is_collider:
            mat_name, color, tr = "SmoothPlastic", "E2483D", 0.5
        m = man.get(name)
        if m and p["class"] == "Part" and not is_collider and name in kit and p["shape"] == "Block":
            # kit piece: the part is the piece's bounding box; recover the origin
            sx = p["size"][0] / max(m["size"][0], 1e-6)
            sy = p["size"][1] / max(m["size"][1], 1e-6)
            sz = p["size"][2] / max(m["size"][2], 1e-6)
            key = ("kit", name, mat_name, color)
            me = cache.get(key)
            if not me:
                me = kit[name].copy()
                me.materials.clear()
                me.materials.append(pp.material(mat_name, color, 0.0, a.night, ""))
                cache[key] = me
            mtx = roblox_matrix(p["cf"], (1, 1, 1))
            origin = mtx @ (P @ Matrix.Translation((-m["center"][0] * sx, -m["center"][1] * sy, -m["center"][2] * sz)) @ PI)
            mtx = origin @ (P @ Matrix.Diagonal((sx, sy, sz, 1)) @ PI)
        else:
            shape = "Wedge" if p["class"] == "WedgePart" else ("Cylinder" if p["shape"] == "Cylinder" else "Block")
            key = ("prim", shape, mat_name, color, round(tr, 2))
            me = cache.get(key)
            if not me:
                me = prims[shape].copy()
                me.materials.append(pp.material(mat_name, color, tr, a.night, ""))
                cache[key] = me
            mtx = roblox_matrix(p["cf"], tuple(p["size"]))
        o = bpy.data.objects.new(name, me)
        o.matrix_world = mtx
        coll.objects.link(o)
        shown += 1
    print("shown", shown)
    if a.terrain:
        pp.build_terrain(a.terrain, a.night)
    pp.shoot("shot", [float(v) for v in a.cam.split(",")], [float(v) for v in a.target.split(",")], a.lens, a.out)


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
