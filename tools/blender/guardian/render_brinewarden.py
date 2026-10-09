"""
render_brinewarden: review renders for the Brinewarden body (Cycles CPU; Eevee/Workbench need a GPU).

    docs/previews/brinewarden_turnaround.png   battle pose: front, 3/4, side, back
    docs/previews/brinewarden_closeup.png      helm and pincer
    docs/previews/brinewarden_rest.png         the R15 rest pose exactly as the rig wears it

The battle pose rotates each rigid piece about its R15 joint (the same joints the in-game
animations drive), so a pose that looks right here also tells us the pieces survive animation.
"""

import math
import os
import time

import bpy
from mathutils import Matrix, Vector

import build_brinewarden as B

PARENT = {
    "LowerTorso": None, "UpperTorso": "LowerTorso", "Head": "UpperTorso",
    "LeftUpperArm": "UpperTorso", "LeftLowerArm": "LeftUpperArm", "LeftHand": "LeftLowerArm",
    "RightUpperArm": "UpperTorso", "RightLowerArm": "RightUpperArm", "RightHand": "RightLowerArm",
    "LeftUpperLeg": "LowerTorso", "LeftLowerLeg": "LeftUpperLeg", "LeftFoot": "LeftLowerLeg",
    "RightUpperLeg": "LowerTorso", "RightLowerLeg": "RightUpperLeg", "RightFoot": "RightLowerLeg",
}


def pivot(limb):
    side = 1.0 if limb.startswith("Left") else (-1.0 if limb.startswith("Right") else 0.0)
    if limb == "LowerTorso":
        return B.limb_info("LowerTorso")[0]
    if limb == "UpperTorso":
        return B.joint("Waist")
    if limb == "Head":
        return B.joint("Neck")
    for key, j in (("UpperArm", "Shoulder"), ("LowerArm", "Elbow"), ("Hand", "Wrist"), ("UpperLeg", "Hip"),
                   ("LowerLeg", "Knee"), ("Foot", "Ankle")):
        if limb.endswith(key):
            return B.joint(j, side)
    raise KeyError(limb)


# Battle pose (degrees about the joint; +x tilts a limb's lower end backward, see the notes in code).
BATTLE = {
    "UpperTorso": (9, 0, -6),
    "Head": (-12, 0, 6),
    "RightUpperArm": (-14, 16, 0),
    "RightLowerArm": (-30, 0, 0),
    "RightHand": (60, 20, -70),
    "LeftUpperArm": (-12, -22, 0),
    "LeftLowerArm": (-34, 0, 10),
    "LeftHand": (-10, 0, 0),
    "LeftUpperLeg": (-14, -7, 0),
    "LeftLowerLeg": (18, 0, 0),
    "LeftFoot": (-4, 0, 0),
    "RightUpperLeg": (10, 7, 0),
    "RightLowerLeg": (10, 0, 0),
    "RightFoot": (-20, 0, 0),
}


def euler(rot):
    rx, ry, rz = (math.radians(a) for a in rot)
    return Matrix.Rotation(rz, 4, "Z") @ Matrix.Rotation(ry, 4, "Y") @ Matrix.Rotation(rx, 4, "X")


def limb_matrices(pose):
    out = {}

    def get(limb):
        if limb in out:
            return out[limb]
        parent = PARENT[limb]
        base = get(parent) if parent else Matrix.Identity(4)
        pv = pivot(limb)
        m = base @ Matrix.Translation(pv) @ euler(pose.get(limb, (0, 0, 0))) @ Matrix.Translation(-pv)
        out[limb] = m
        return m

    for limb in PARENT:
        get(limb)
    return out


def apply_pose(pieces, objs, pose):
    ms = limb_matrices(pose)
    by_name = {p.name: p for p in pieces}
    for ob in objs:
        p = by_name[ob["piece"]]
        ob.matrix_world = ms[p.limb] @ Matrix.Translation(p.origin)
    bpy.context.view_layer.update()
    # keep the feet on the ground (a planted sword tip may dip into it)
    feet = [ob for ob in objs if by_name[ob["piece"]].limb.endswith("Foot")]
    low = min((ob.matrix_world @ Vector(c)).z for ob in feet for c in ob.bound_box)
    for ob in objs:
        ob.matrix_world = Matrix.Translation((0, 0, -low)) @ ob.matrix_world
    bpy.context.view_layer.update()


def setup_scene():
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 28
    scene.cycles.use_denoising = True
    scene.cycles.denoiser = "OPENIMAGEDENOISE"
    scene.cycles.max_bounces = 4
    scene.render.film_transparent = False
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.look = "AgX - Medium High Contrast"
    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.018, 0.028, 0.034, 1)
    bg.inputs["Strength"].default_value = 1.0
    scene.world = world
    # ground
    me = bpy.data.meshes.new("Ground")
    import bmesh
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=500)
    bm.to_mesh(me)
    bm.free()
    gm = bpy.data.materials.new("GroundMat")
    gm.use_nodes = True
    gb = gm.node_tree.nodes["Principled BSDF"]
    gb.inputs["Base Color"].default_value = (0.006, 0.008, 0.009, 1)
    gb.inputs["Roughness"].default_value = 0.9
    gb.inputs["Specular IOR Level"].default_value = 0.0
    me.materials.append(gm)
    ground = bpy.data.objects.new("Ground", me)
    scene.collection.objects.link(ground)
    # camera rig: camera + lights turn together so every view is lit the same way
    rig = bpy.data.objects.new("CamRig", None)
    scene.collection.objects.link(rig)
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    scene.collection.objects.link(cam)
    cam.parent = rig
    scene.camera = cam

    def sun(name, rot, strength, color, angle=0.15):
        ld = bpy.data.lights.new(name, "SUN")
        ld.energy = strength
        ld.color = color
        ld.angle = angle
        ob = bpy.data.objects.new(name, ld)
        scene.collection.objects.link(ob)
        ob.parent = rig
        ob.rotation_euler = [math.radians(a) for a in rot]
        return ob

    sun("Key", (55, 0, -35), 3.2, (1.0, 0.93, 0.85))
    sun("Rim", (-60, 0, 20), 4.0, (0.55, 0.9, 1.0))
    sun("Fill", (70, 0, 70), 0.7, (0.75, 0.85, 1.0), 0.5)
    return scene, rig, cam, ground


def shoot(scene, rig, cam, path, yaw, res, ortho=None, target=(0, 0, 10), dist=48, lens=60, elev=8):
    scene.render.resolution_x, scene.render.resolution_y = res
    scene.render.resolution_percentage = 100
    rig.location = Vector(target)
    rig.rotation_euler = (0, 0, math.radians(yaw))
    e = math.radians(elev)
    cam.location = (0, -dist * math.cos(e), dist * math.sin(e))
    cam.rotation_euler = (math.radians(90) - e, 0, 0)
    if ortho:
        cam.data.type = "ORTHO"
        cam.data.ortho_scale = ortho
    else:
        cam.data.type = "PERSP"
        cam.data.lens = lens
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def sheet(paths, out, labels):
    from PIL import Image, ImageDraw, ImageFont
    ims = [Image.open(p).convert("RGB") for p in paths]
    w = sum(i.width for i in ims)
    h = max(i.height for i in ims)
    canvas = Image.new("RGB", (w, h), (8, 12, 14))
    x = 0
    draw = ImageDraw.Draw(canvas)
    try:
        font = ImageFont.load_default(size=22)
    except TypeError:
        font = ImageFont.load_default()
    for im, label in zip(ims, labels):
        canvas.paste(im, (x, 0))
        draw.text((x + 12, 10), label, fill=(200, 210, 205), font=font)
        x += im.width
    canvas.save(out)
    for p in paths:
        os.remove(p)


def show_phase(pieces, objs, phase):
    """Phase 1-2 look: shell on, core hidden. Phase 3: shell gone, core lit."""
    roles = {p.name: p.role for p in pieces}
    for ob in objs:
        role = roles[ob["piece"]]
        ob.hide_render = (role == "Core" and phase < 3) or (role == "Shell" and phase >= 3)


def render_all(repo, pieces, objs, calib, mats, only=""):
    t0 = time.time()
    for ob in calib:
        ob.hide_render = True
    show_phase(pieces, objs, 1)
    scene, rig, cam, ground = setup_scene()
    out = os.path.join(repo, "docs/previews")
    os.makedirs(out, exist_ok=True)
    tmp = os.path.join(out, "_tmp")
    os.makedirs(tmp, exist_ok=True)
    want = set(only.split(",")) if only else {"turnaround", "closeup", "rest"}

    if "turnaround" in want:
        apply_pose(pieces, objs, BATTLE)
        views = [("front", 0), ("three-quarter", -38), ("side (pincer)", 90), ("back", 180)]
        paths = []
        for i, (label, yaw) in enumerate(views):
            path = os.path.join(tmp, f"t{i}.png")
            shoot(scene, rig, cam, path, yaw, (480, 600), ortho=31, target=(0, -2.5, 10.2))
            paths.append(path)
        sheet(paths, os.path.join(out, "brinewarden_turnaround.png"), [v[0] for v in views])
        print(f"turnaround {time.time() - t0:.1f}s")

    if "closeup" in want:
        apply_pose(pieces, objs, BATTLE)
        ms = limb_matrices(BATTLE)
        head = ms["Head"] @ B.limb_info("Head")[0]
        claw = ms["LeftHand"] @ (B.limb_info("LeftHand")[0] + Vector((0, -2.0, -2.5)))
        low = min((ob.matrix_world @ Vector(c)).z for ob in objs for c in ob.bound_box)
        p1 = os.path.join(tmp, "c0.png")
        p2 = os.path.join(tmp, "c1.png")
        p3 = os.path.join(tmp, "c2.png")
        shoot(scene, rig, cam, p1, -28, (560, 560), target=head + Vector((0, 0, 1.0)), dist=17, lens=55, elev=6)
        shoot(scene, rig, cam, p2, 42, (560, 560), target=claw, dist=19, lens=55, elev=14)
        show_phase(pieces, objs, 3)
        shoot(scene, rig, cam, p3, -20, (440, 560), target=(0, -1, 11.5), dist=30, lens=50, elev=8)
        show_phase(pieces, objs, 1)
        sheet([p1, p2, p3], os.path.join(out, "brinewarden_closeup.png"), ["helm", "pincer", "phase 3: shell off, core"])
        print(f"closeup {time.time() - t0:.1f}s")

    if "rest" in want:
        apply_pose(pieces, objs, {})
        views = [("rest: front", 0), ("rest: side", 90), ("rest: back", 180)]
        paths = []
        for i, (label, yaw) in enumerate(views):
            path = os.path.join(tmp, f"r{i}.png")
            shoot(scene, rig, cam, path, yaw, (360, 480), ortho=27, target=(0, -3, 10.3))
            paths.append(path)
        sheet(paths, os.path.join(out, "brinewarden_rest.png"), [v[0] for v in views])
        print(f"rest {time.time() - t0:.1f}s")

    os.rmdir(tmp)
    # back to the rest pose for the saved .blend; the render helpers leave the scene
    apply_pose(pieces, objs, {})
    for ob in objs:
        p = next(q for q in pieces if q.name == ob["piece"])
        ob.matrix_world = Matrix.Translation(p.origin)
    for ob in calib + objs:
        ob.hide_render = False
