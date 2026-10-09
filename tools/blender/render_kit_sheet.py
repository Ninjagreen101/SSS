"""
Renders a contact sheet of every kit piece (one framed thumbnail each) so the
kit can be reviewed without opening Blender or Studio.

    python tools/blender/render_kit_sheet.py --repo . --out assets/kit/previews
"""
from __future__ import annotations

import argparse
import math
import os
import sys

import bpy
from mathutils import Vector


def parse() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    p = argparse.ArgumentParser()
    p.add_argument("--repo", default=".")
    p.add_argument("--out", default="assets/kit/previews")
    p.add_argument("--size", type=int, default=192)
    p.add_argument("--prefix", default="")
    return p.parse_args(argv)


def setup_scene(size: int) -> tuple[bpy.types.Object, bpy.types.Object]:
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 12
    scene.cycles.use_denoising = False
    scene.render.resolution_x = size
    scene.render.resolution_y = size
    scene.render.film_transparent = False
    world = bpy.data.worlds.new("w") if not scene.world else scene.world
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.05, 0.06, 0.08, 1)
    world.node_tree.nodes["Background"].inputs[1].default_value = 1.6
    cam_data = bpy.data.cameras.new("cam")
    cam = bpy.data.objects.new("cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    sun_data = bpy.data.lights.new("sun", "SUN")
    sun_data.energy = 5.0
    sun = bpy.data.objects.new("sun", sun_data)
    sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(-35))
    scene.collection.objects.link(sun)
    return cam, sun


def main() -> None:
    a = parse()
    repo = os.path.abspath(a.repo)
    out = os.path.join(repo, a.out)
    os.makedirs(out, exist_ok=True)
    bpy.ops.wm.open_mainfile(filepath=os.path.join(repo, "assets", "kit", "kit.blend"))
    cam, _ = setup_scene(a.size)
    pieces = sorted([o for o in bpy.data.objects if o.type == "MESH"], key=lambda o: o.name)
    if a.prefix:
        pieces = [p for p in pieces if p.name.startswith(a.prefix)]
    for o in pieces:
        o.hide_render = True
    for o in pieces:
        o.hide_render = False
        corners = [o.matrix_world @ Vector(c) for c in o.bound_box]
        lo = Vector((min(c.x for c in corners), min(c.y for c in corners), min(c.z for c in corners)))
        hi = Vector((max(c.x for c in corners), max(c.y for c in corners), max(c.z for c in corners)))
        center = (lo + hi) / 2
        radius = max((hi - lo).length / 2, 0.5)
        # view from the piece's front (Roblox -Z == Blender +Y), above and to the right
        direction = Vector((0.55, 1.0, 0.55)).normalized()
        cam.data.lens = 50
        dist = radius / math.tan(cam.data.angle / 2) * 1.05
        cam.location = center + direction * dist
        cam.rotation_euler = (center - cam.location).to_track_quat("-Z", "Y").to_euler()
        cam.data.clip_end = dist * 4
        bpy.context.scene.render.filepath = os.path.join(out, o.name + ".png")
        bpy.ops.render.render(write_still=True)
        o.hide_render = True
    print(f"rendered {len(pieces)} thumbnails")


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
