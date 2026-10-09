"""
build_brinewarden: the Floor 1 Guardian's body, "The Brinewarden, Keeper of the First Gate".

    /tmp/claude-0/bpyenv/bin/python tools/blender/guardian/build_brinewarden.py --repo . [--no-render]

Writes
    assets/guardian/SpireKit_Guardians.fbx      the pieces + four calibration cubes (3D Importer)
    assets/guardian/SpireKit_Guardians.blend    the same scene, for hand edits
    tools/blender/guardian/guardian_manifest.json
    src/ServerStorage/Tools/KitManifestGuardians.lua   (merged into KitManifest)
    docs/previews/brinewarden_*.png             review renders (unless --no-render)

Space and naming follow the SpireKit (KitLibrary / KitManifest): Blender z up, the body FACES -y,
1 unit = 1 stud. Every mesh is <Piece>__<Channel>; channels map to KitLibrary.Channels.

The body is split into RIGID pieces, one per R15 body part (plus droppable shell, the core and the
back seam). Each piece's origin is the centre of its R15 part in a reference rig at the boss's scale,
so MobService/Builder can weld piece -> limb with no offset and the standard R15 animations drive it.

Reference rig: Roblox's default R15 body (HumanoidDescription defaults: BodyTypeScale 0.3, the
rest 1), measured from Workspace.SpireAnimationRig in SPIRE_NEW.rbxl. Part sizes and centres at
scale 1, character space (x right, y up, z back; feet bottom at y = 0.0076):

    part            size (x, y, z)              centre (x, y)
    Head            1.1590 1.1820 1.1606         0       4.8738
    UpperTorso      1.9432 1.6980 1.0040         0       3.4490
    LowerTorso      1.9914 0.4007 1.0040         0       2.3999
    *UpperArm       1.0011 1.2416 1.0019        -+1.4721 3.6276   (Left = -x)
    *LowerArm       1.0011 1.1175 1.0019        -+1.4721 2.9979
    *Hand           0.9843 0.3158 1.0283        -+1.4721 2.3341
    *UpperLeg       0.9928 1.3629 0.9727        -+0.5    1.7286
    *LowerLeg       0.9928 1.3007 0.9728        -+0.5    0.8661
    *Foot           1.0089 0.3120 1.0011        -+0.5    0.1636

Mobs.Brinewarden.Body.Scale = 3.4 scales that rig (5.46 studs) to 18.6 studs; helm crest and eye
stalks bring the Warden to about 20.7. Character -> Blender: x_b = -x_c * S, y_b = z_c * S,
z_b = (y_c - 0.0076) * S (front -y, the boss's LEFT is +x: the pincer side; its RIGHT, -x, holds
the greatsword along the hand's forward axis like every R15 weapon).
"""

import argparse
import json
import math
import os
import random
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import bpy  # noqa: E402  (bpy first: it provides bmesh and mathutils)
import bmesh  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

import meshkit as mk  # noqa: E402
from meshkit import Piece, align, mat  # noqa: E402

BODY = "Brinewarden"
FILE = "Guardians"
S = 3.4
GROUND = 0.0076
CALIB = 32.0

# size (x, y, z) and centre (x, y), character space, scale 1 (see the docstring)
REF = {
    "Head": ((1.1590, 1.1820, 1.1606), (0.0, 4.8738)),
    "UpperTorso": ((1.9432, 1.6980, 1.0040), (0.0, 3.4490)),
    "LowerTorso": ((1.9914, 0.4007, 1.0040), (0.0, 2.3999)),
    "UpperArm": ((1.0011, 1.2416, 1.0019), (1.4721, 3.6276)),
    "LowerArm": ((1.0011, 1.1175, 1.0019), (1.4721, 2.9979)),
    "Hand": ((0.9843, 0.3158, 1.0283), (1.4721, 2.3341)),
    "UpperLeg": ((0.9928, 1.3629, 0.9727), (0.5, 1.7286)),
    "LowerLeg": ((0.9928, 1.3007, 0.9728), (0.5, 0.8661)),
    "Foot": ((1.0089, 0.3120, 1.0011), (0.5, 0.1636)),
}

# Joint heights (character y, scale 1): the rig's attachments scaled by each part's size ratio.
JOINT_Y = {"Neck": 4.298, "Shoulder": 4.046, "Elbow": 3.273, "Wrist": 2.466, "Waist": 2.600,
           "Hip": 2.200, "Knee": 1.279, "Ankle": 0.270, "Grip": 2.2394}
SHOULDER_X = 0.9716
HIP_X = 0.5


def zc(y):
    return (y - GROUND) * S


def limb_info(limb):
    """(blender centre, roblox size (x, y up, z)) of an R15 part at the boss's scale."""
    side = 0.0
    key = limb
    if limb.startswith("Left"):
        side, key = 1.0, limb[4:]
    elif limb.startswith("Right"):
        side, key = -1.0, limb[5:]
    size, centre = REF[key]
    cx = abs(centre[0]) * side * S  # Left (character -x) -> blender +x
    return Vector((cx, 0.0, zc(centre[1]))), (size[0] * S, size[1] * S, size[2] * S)


def joint(name, side=0.0):
    x = 0.0
    if name == "Shoulder":
        x = SHOULDER_X * S * side
    elif name == "Hip":
        x = HIP_X * S * side
    elif name in ("Elbow", "Wrist", "Grip"):
        x = REF["UpperArm"][1][0] * S * side
    elif name in ("Knee", "Ankle"):
        x = HIP_X * S * side
    return Vector((x, 0.0, zc(JOINT_Y[name])))


# CHANNELS (KitLibrary.Channels): render colour, roughness, metallic, emission ---------------------
CHANNELS = {
    "Chitin": ("3E4A4D", 0.62, 0.0, 0.0),
    "ChitinDark": ("2B3436", 0.7, 0.0, 0.0),
    "ShellRed": ("8A4A36", 0.38, 0.0, 0.0),
    "ShellRust": ("A4553A", 0.6, 0.0, 0.0),
    "Coral": ("C46A5E", 0.8, 0.0, 0.0),
    "Bone": ("C9BFA8", 0.55, 0.0, 0.0),
    "Brass": ("A88A4F", 0.42, 1.0, 0.0),
    "Metal": ("3D4045", 0.45, 1.0, 0.0),
    "Rope": ("8C7853", 0.9, 0.0, 0.0),
    "Kelp": ("34452F", 0.85, 0.0, 0.0),
    "Sailcloth": ("5E5A4C", 0.9, 0.0, 0.0),
    "Glow": ("3FE0D0", 0.4, 0.0, 6.0),
}

PIECES = []

# Triangle budget per piece (Roblox allows 20k per MeshPart; the whole Warden aims at about 30k).
# Pieces over budget are collapse-decimated, Glow channels excepted.
BUDGET = {"Head": 2800, "UpperTorso": 3100, "ShellBack": 2700, "LowerTorso": 2500, "ShellPauldronL": 2700,
          "ShellPauldronR": 1700, "Sword": 3900, "LeftHand": 2400, "ShellChest": 900, "RightHand": 750,
          "LeftLowerLeg": 950, "RightLowerLeg": 950, "LeftUpperLeg": 850, "RightUpperLeg": 850}


def piece(name, limb, role, **meta):
    centre, _ = limb_info(limb)
    p = Piece(f"{BODY}_{name}", limb, role, centre, **meta)
    PIECES.append(p)
    return p


def rng(seed):
    return random.Random(seed)


def side_name(s):
    return "Left" if s > 0 else "Right"


# SHARED SHAPES ----------------------------------------------------------------------------------

def rivets(p, points, r=0.11, channel="Brass"):
    for q in points:
        p.add(channel, mk.sphere(r, r, r, 6, 4), mat(q))


def trim(p, points, r=0.09, flat=0.55, channel="Brass", sides=5):
    p.add(channel, mk.sweep(points, [r] * len(points), sides=sides, flat=flat))


def spike(p, base, direction, length, r, channel="ShellRust", segs=6, tip_channel=None):
    d = Vector(direction).normalized()
    if tip_channel:
        p.add(channel, mk.cone(r, length * 0.62, segs, r_tip=r * 0.45), align(base, d))
        p.add(tip_channel, mk.cone(r * 0.45, length * 0.38, segs), align(Vector(base) + d * length * 0.62, d))
    else:
        p.add(channel, mk.cone(r, length, segs), align(base, d))


def ell_arc(cx, cy, rx, ry, a0, a1, z, n=12, flare=0.0):
    """Points on an ellipse (angle 0 = -y front, positive toward +x) at height z."""
    pts = []
    for i in range(n + 1):
        a = a0 + (a1 - a0) * i / n
        pts.append((cx + (rx + flare) * math.sin(a), cy - (ry + flare) * math.cos(a), z))
    return pts


def curved_spike(p, base, direction, bend, length, r, channel="ShellRust", tip_channel="Bone", sides=6):
    """A horn-like spike: starts along `direction`, bends toward `bend` (both vectors), two channels."""
    d = Vector(direction).normalized()
    b = Vector(bend).normalized()
    pts = [Vector(base)]
    for i in range(1, 5):
        t = i / 4
        dirn = d.lerp(b, t * t).normalized()
        pts.append(pts[-1] + dirn * (length / 4))
    p.add(channel, mk.sweep(pts[:4], [r, r * 0.8, r * 0.6, r * 0.42], sides=sides, cap_start=False))
    p.add(tip_channel, mk.sweep(pts[3:] + [pts[4] + (pts[4] - pts[3]) * 0.4], [r * 0.42, r * 0.2, 0.0], sides=sides, tip=True))


def bumps(p, channel, host, count, size, seed, region=None):
    """Half-buried tubercles: the knobbly texture of a crab's shell."""
    mk.scatter(p, channel, host, count, size, seed, region=region, sink=0.55,
               make=lambda r, g: mk.sphere(r, r, r * 0.8, 6, 4))


# HEAD: the crab helm ------------------------------------------------------------------------------

def build_head():
    p = piece("Head", "Head", "Helm", shadow=True, light={"range": 9, "brightness": 1.4})
    cz = p.origin.z  # 16.55
    # Carapace: wide and low like a crab's, open at the face.
    def dome(u, v):
        a = -2.62 + 5.24 * u
        e = -0.3 + 1.78 * v
        rx, ry, rz = 2.75, 2.5, 1.6
        bump = 1 + 0.04 * math.sin(a * 6) * math.cos(e)
        return (rx * math.sin(a) * math.cos(e) * bump, 0.25 + ry * math.cos(a) * math.cos(e) * bump,
                cz + 0.4 + rz * math.sin(e))
    bm = mk.shell(dome, 22, 8, 0.3, rim_bevel=0.06, inside=(0, 0.25, cz + 0.3))
    mk.roughen(bm, 0.07, 1.6, seed=3)
    mk.chip(bm, 0.05, 2.0, seed=3)
    p.add("ShellRed", bm)
    # Front margin over the face: a thick brow shelf.
    def brow(u, v):
        a = -1.05 + 2.1 * u
        r = 2.25 + 0.75 * v
        return (r * math.sin(a) * 1.08, 0.3 - r * math.cos(a), cz + 1.35 - 0.45 * v - 0.3 * (a / 1.05) ** 2)
    bm = mk.shell(brow, 14, 3, 0.32, rim_bevel=0.06, inside=(0, 0.3, cz))
    mk.roughen(bm, 0.05, 2.0, seed=4)
    p.add("ShellRed", bm)
    # Rostrum: two forward prongs between the horns, smaller teeth along the margin.
    for s in (-1, 1):
        spike(p, (s * 0.35, -2.55, cz + 0.95), (s * 0.25, -1.0, 0.1), 1.05, 0.26, "ShellRust", tip_channel="Bone")
        for k, a in enumerate((0.55, 0.85)):
            base = (s * 3.0 * math.sin(a) * 1.08, 0.3 - 3.0 * math.cos(a), cz + 0.9 - 0.3 * (a / 1.05) ** 2)
            spike(p, base, (s * math.sin(a), -math.cos(a), 0.0), 0.6, 0.2, "ShellRust")
    # Cheek guards hanging beside the visor.
    for s in (-1, 1):
        def cheek(u, v, s=s):
            a = s * (0.95 + 0.9 * u)
            r = 2.55 + 0.2 * v
            return (r * math.sin(a) * 1.05, 0.25 - r * math.cos(a), cz + 0.45 - 1.55 * v)
        bm = mk.shell(cheek, 6, 4, 0.26, rim_bevel=0.05, inside=(0, 0.25, cz))
        mk.roughen(bm, 0.05, 2.0, seed=5 + s)
        p.add("ShellRed", bm)
        trim(p, [Vector(cheek(i / 6, 1.0)) for i in range(7)], 0.1, 0.6, sides=4)
        for k, (a, ln) in enumerate([(1.55, 1.0), (1.95, 0.85)]):
            base = Vector((s * 2.85 * math.sin(a), 0.25 - 2.7 * math.cos(a), cz + 0.55 - 0.15 * k))
            spike(p, base, (s * 1.0, 0.45, 0.2), ln, 0.22, "ShellRust", tip_channel="Bone")
    # Face plate (visor) and the glowing eye slits under angry brow ridges.
    visor = mk.box(2.7, 0.8, 1.5)
    mk.bevel_sharp(visor, 0.14, 2)
    p.add("ChitinDark", visor, mat((0, -1.7, cz - 0.05), (8, 0, 0)))
    for s in (-1, 1):
        slit = mk.box(0.95, 0.25, 0.17)
        mk.bevel_sharp(slit, 0.05, 1)
        p.add("Glow", slit, mat((s * 0.6, -2.08, cz + 0.25), (0, s * -17, 0)))
        small = mk.box(0.4, 0.22, 0.12)
        p.add("Glow", small, mat((s * 1.18, -1.98, cz + 0.55), (0, s * -28, 0)))
        ridge = mk.box(1.3, 0.5, 0.32)
        mk.bevel_sharp(ridge, 0.1, 1)
        p.add("ShellRust", ridge, mat((s * 0.66, -2.15, cz + 0.55), (0, s * -18, 0)))
    p.anchor("EyeL", (0.6, -2.15, cz + 0.25))
    p.anchor("EyeR", (-0.6, -2.15, cz + 0.25))
    # Mouthparts: three pairs of jointed maxillipeds under the visor.
    for s in (-1, 1):
        for k in range(3):
            x = s * (0.3 + 0.38 * k)
            top = Vector((x, -1.8 + 0.12 * k, cz - 0.7))
            mid = top + Vector((s * 0.05, -0.4, -0.6 + 0.1 * k))
            end = mid + Vector((-s * 0.12, 0.22, -0.5 + 0.1 * k))
            p.add("ChitinDark" if k else "ShellRust", mk.sweep([top, mid, end], [0.18, 0.13, 0.0], sides=4, tip=True))
    # Gorget under the helm.
    p.add("ChitinDark", mk.lathe([(1.75, cz - 2.05), (1.95, cz - 1.5), (2.05, cz - 0.85), (1.8, cz - 0.6)], 12))
    # Crest: a dorsal fin with back-swept saw teeth.
    prof = [(-1.7, 0.0), (-1.2, 0.55), (-0.5, 1.15), (-0.15, 1.05), (0.3, 1.45), (0.65, 1.1), (1.05, 1.35), (1.4, 0.9),
            (1.8, 1.05), (2.15, 0.55), (2.5, 0.0)]
    fin = mk.prism(prof[::-1] if _area(prof) < 0 else prof, 0.26, bevel=0.06)
    p.add("ShellRust", fin, Matrix.Translation((0, 0.0, cz + 1.8)) @ Matrix(((0, 0, -1, 0), (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 0, 1))))
    # Eye-stalk horns: segmented, rising and sweeping back.
    for s in (-1, 1):
        pts = [Vector((s * 1.0, -1.55, cz + 1.25)), Vector((s * 1.2, -2.0, cz + 2.2)), Vector((s * 1.55, -1.85, cz + 3.1)),
               Vector((s * 2.1, -1.2, cz + 3.75)), Vector((s * 2.65, -0.3, cz + 4.0))]
        p.add("ShellRust", mk.sweep(pts, [0.5, 0.42, 0.34, 0.27, 0.22], sides=7, cap_start=False))
        tip = pts[-1] + Vector((s * 0.35, 0.75, -0.05))
        p.add("Bone", mk.sweep([pts[-1], pts[-1].lerp(tip, 0.5), tip], [0.22, 0.13, 0.0], sides=7, tip=True))
        for k in range(1, 4):
            ring = mk.lathe([(0.0, -0.09), (0.45 - 0.06 * k, 0.0), (0.0, 0.09)], 8)
            p.add("ChitinDark", ring, align(pts[k], pts[k + 1] - pts[k - 1]))
    # Brass circlet with rivets.
    trim(p, ell_arc(0, 0.25, 2.62, 2.42, -2.3, 2.3, cz + 0.05, 20), 0.13, 0.6)
    rivets(p, ell_arc(0, 0.25, 2.74, 2.54, -2.1, 2.1, cz + 0.05, 7), 0.1)
    host = mk.shell(dome, 16, 6, 0.3, inside=(0, 0.25, cz + 0.3))
    mk.scatter(p, "Bone", host, 6, 0.22, seed=11, region=lambda co, n: co.y > 0.5 and co.z > cz + 0.8)
    host.free()


# UPPER TORSO: carapace, breastplate, core socket ---------------------------------------------------

CORE = Vector((0.0, -1.95, 12.55))


def back_y(z):
    return 1.8 + 0.4 * math.sin(math.pi * max(0.0, min(1.0, (z - 9.3) / 5.4)))


def build_torso():
    p = piece("UpperTorso", "UpperTorso", "Carapace", shadow=True)
    c = p.origin  # (0, 0, 11.70)
    # Inner body.
    bm = mk.sphere(3.05, 1.85, 3.0, 14, 9)
    mk.roughen(bm, 0.08, 1.2, seed=5)
    p.add("ChitinDark", bm, mat((0, 0.1, 11.85)))
    # Back ribs (seen once the back shell falls).
    for k in range(5):
        z = 10.0 + 0.85 * k
        pts = ell_arc(0, 0.1, 2.95 - 0.12 * abs(k - 2), back_y(z) - 0.1, 1.85, 4.43, z, 12)
        p.add("Chitin", mk.sweep(pts, [0.22] * len(pts), sides=4, flat=0.7))
    # Pectoral plates beside the core socket.
    for s in (-1, 1):
        def pec(u, v, s=s):
            a = s * (0.36 + 1.12 * u)
            z = 14.0 - 2.55 * v
            rx, ry = 3.35, 1.95 + 0.28 * math.sin(math.pi * v) * (1 - u * 0.6)
            flare = 0.12 * v
            return ((rx + flare) * math.sin(a), 0.05 - (ry + flare) * math.cos(a), z)
        bm = mk.shell(pec, 9, 5, 0.3, rim_bevel=0.07, inside=(0, 0.1, 12.0))
        mk.roughen(bm, 0.05, 1.5, seed=6 + s)
        p.add("Chitin", bm)
        trim(p, [Vector(pec(i / 8, 1.0)) + Vector((0, -0.04, 0.0)) for i in range(9)], 0.1, 0.6, sides=4)
        rivets(p, [Vector(pec(0.0, k / 4)) + Vector((-s * 0.12, -0.18, 0)) for k in range(1, 4)], 0.1)
    # Sternum plate above the socket.
    def stern(u, v):
        a = -0.42 + 0.84 * u
        z = 14.15 - 0.95 * v
        return (3.35 * math.sin(a), 0.0 - 2.15 * math.cos(a), z)
    bm = mk.shell(stern, 6, 3, 0.3, rim_bevel=0.06, inside=(0, 0.1, 12.0))
    p.add("Chitin", bm)
    # Abdomen bands: three overlapping segments, each flaring over the one below.
    for k in range(3):
        top = 11.45 - 0.78 * k
        def band(u, v, k=k, top=top):
            a = -1.38 + 2.76 * u
            z = top - 0.95 * v
            r = 1.0 - 0.04 * k
            rx, ry = 3.25 * r, 1.98 * r
            fl = 0.22 * v
            return ((rx + fl) * math.sin(a), 0.05 - (ry + fl) * math.cos(a), z)
        bm = mk.shell(band, 16, 2, 0.26, rim_bevel=0.06, inside=(0, 0.1, top - 0.5))
        mk.roughen(bm, 0.04, 1.8, seed=20 + k)
        p.add("Chitin", bm)
        trim(p, [Vector(band(i / 12, 1.0)) + Vector((0, 0, 0.02)) for i in range(13)], 0.085, 0.5, sides=4)
    # Side plates under the arms.
    for s in (-1, 1):
        def sidep(u, v, s=s):
            a = s * (1.45 + 0.55 * u)
            z = 13.3 - 3.6 * v
            return (3.15 * math.sin(a), 0.05 - 1.95 * math.cos(a), z)
        p.add("ChitinDark", mk.shell(sidep, 4, 5, 0.25, rim_bevel=0.05, inside=(0, 0.1, 11.5)))
    # Core socket: brass ring, dark cup, bone ribs gripping it.
    ring = mk.lathe([(1.0, -0.35), (1.35, -0.2), (1.38, 0.15), (1.15, 0.3), (0.95, 0.15)], 16)
    p.add("Brass", ring, align(CORE + Vector((0, 0.15, 0)), (0, -1, 0)))
    cup = mk.lathe([(0.0, -0.55), (0.6, -0.48), (0.95, -0.2), (1.0, 0.1)], 12, cap_top=False)
    p.add("ChitinDark", cup, align(CORE + Vector((0, 0.25, 0)), (0, -1, 0)))
    for s in (-1, 1):
        for k, ang in enumerate([-40, 0, 40]):
            a = math.radians(ang)
            start = CORE + Vector((s * 1.2 * math.cos(a), 0.1, 1.2 * math.sin(a)))
            mid = CORE + Vector((s * 1.75 * math.cos(a), -0.12, 1.65 * math.sin(a)))
            end = CORE + Vector((s * 2.15 * math.cos(a * 1.2), 0.25, 2.0 * math.sin(a * 1.2)))
            p.add("Bone", mk.sweep([start, mid, end], [0.17, 0.15, 0.06], sides=5, tip=True))
    # High collar behind the helm, with spines.
    def collar(u, v):
        a = -1.35 + 2.7 * u
        z = 13.7 + 2.2 * v
        r = 2.55 + 0.35 * v
        return (r * math.sin(a), 0.35 + r * math.cos(a) * 1.05, z)
    bm = mk.shell(collar, 12, 4, 0.3, rim_bevel=0.06, inside=(0, 0.2, 15.0))
    mk.roughen(bm, 0.06, 1.6, seed=31)
    p.add("Chitin", bm)
    trim(p, [Vector(collar(i / 12, 1.0)) for i in range(13)], 0.11, 0.6)
    for k in range(5):
        a = -1.1 + 2.2 * k / 4
        base = Vector((2.85 * math.sin(a), 0.35 + 2.95 * math.cos(a), 15.7))
        spike(p, base, (math.sin(a) * 0.5, 0.6, 1.0), 0.9 + 0.3 * (k % 2), 0.17, "ShellRust")
    # Barnacles on the shoulders and collar.
    host = mk.sphere(3.05, 1.95, 3.0, 12, 8)
    mk.transform(host, mat((0, 0.1, 11.85)))
    mk.scatter(p, "Bone", host, 7, 0.22, seed=41, region=lambda co, n: co.z > 13.6 and abs(co.x) > 1.6)
    host.free()
    p.anchor("Core", CORE)
    p.anchor("Neck", joint("Neck"))
    p.anchor("ShoulderL", joint("Shoulder", 1))
    p.anchor("ShoulderR", joint("Shoulder", -1))


def build_shell_chest():
    p = piece("ShellChest", "UpperTorso", "Shell", shadow=True)
    def plate(u, v):
        a = -1.2 + 2.4 * u
        w = 2.0 * (1 - 0.6 * v ** 1.6)
        bulge = 0.3 * math.sin(math.pi * v) * math.cos(a)
        return (w * math.sin(a), CORE.y - 0.3 - (0.75 + bulge) * math.cos(a) * (1 - 0.35 * v), CORE.z + 1.55 - 3.1 * v)
    bm = mk.shell(plate, 10, 8, 0.3, rim_bevel=0.07, inside=(0, CORE.y + 0.8, CORE.z))
    mk.roughen(bm, 0.08, 1.8, seed=51)
    mk.chip(bm, 0.06, 2.2, seed=52)
    p.add("ShellRed", bm)
    p.add("ShellRust", mk.sweep([Vector(plate(0.5, v / 6)) + Vector((0, -0.08, 0)) for v in range(0, 7)],
                                [0.1, 0.2, 0.24, 0.24, 0.2, 0.15, 0.06], sides=5))
    host = mk.shell(plate, 8, 6, 0.1, inside=(0, CORE.y + 0.8, CORE.z))
    bumps(p, "ShellRust", host, 7, 0.18, seed=53, region=lambda co, n: abs(co.x) > 0.4)
    host.free()
    for s in (-1, 1):
        spike(p, Vector(plate(0.5 + s * 0.42, 0.06)), (s * 0.6, -1, 0.5), 0.65, 0.16, "ShellRust")
    edge = [Vector(plate(u / 10, 0.0)) for u in range(11)] + [Vector(plate(1.0, v / 6)) for v in range(1, 7)] + \
        [Vector(plate(1 - u / 10, 1.0)) for u in range(1, 11)] + [Vector(plate(0.0, 1 - v / 6)) for v in range(1, 7)]
    trim(p, edge, 0.11, 0.6, sides=4)


def build_core():
    p = piece("Core", "UpperTorso", "Core", light={"range": 16, "brightness": 2.2})
    bm = mk.ico(0.82, 2)
    r = rng(61)
    for v in bm.verts:
        v.co *= 1.0 + 0.12 * r.random()
    p.add("Glow", bm, mat(CORE + Vector((0, 0.05, 0))))
    # Veins that crack out across the chest when the core is exposed (they hide with it).
    for k in range(7):
        a = 2 * math.pi * k / 7 + 0.3
        pts = [CORE + Vector((math.cos(a) * 1.35, -0.05, math.sin(a) * 1.35))]
        for i in range(3):
            prev = pts[-1]
            dirn = Vector((math.cos(a + 0.4 * (r.random() - 0.5)), 0, math.sin(a + 0.4 * (r.random() - 0.5))))
            nxt = prev + dirn * 0.55
            nxt.y = 0.05 - 2.05 * math.cos(math.asin(max(-0.95, min(0.95, nxt.x / 3.35)))) - 0.08
            pts.append(nxt)
        p.add("Glow", mk.sweep(pts, [0.1, 0.08, 0.06, 0.03], sides=4, flat=0.6, tip=True))
    p.anchor("Core", CORE)


def build_seam():
    p = piece("Seam", "UpperTorso", "Seam", light={"range": 8, "brightness": 1.0})
    pts = []
    for i in range(13):
        z = 9.9 + 4.2 * i / 12
        x = 0.1 * (1 if i % 2 else -1)
        pts.append(Vector((x, back_y(z) + 0.42, z)))
    p.add("Glow", mk.sweep(pts, [0.13] * 13, sides=5, flat=0.6))
    p.anchor("Seam", (0.0, back_y(12.0) + 0.45, 12.0))


def build_shell_back():
    p = piece("ShellBack", "UpperTorso", "Shell", shadow=True)
    C = Vector((0.0, 0.0, 11.75))
    A, B, H = 3.55, 2.75, 3.25
    bands = [(0.92, 0.36), (0.46, -0.12), (0.0, -0.62)]
    for s in (-1, 1):
        for k, (e0, e1) in enumerate(bands):
            def plate(u, v, e0=e0, e1=e1, k=k, s=s):
                ph = s * (0.07 + 1.45 * u)
                e = e0 + (e1 - e0) * v
                sc = (1.0 - 0.035 * k) * (1 + 0.075 * v)
                return (C.x + A * sc * math.cos(e) * math.sin(ph), C.y + B * sc * math.cos(e) * math.cos(ph),
                        C.z + H * math.sin(e))
            bm = mk.shell(plate, 10, 4, 0.3, rim_bevel=0.07, inside=C)
            mk.roughen(bm, 0.08, 1.4, seed=70 + k + 3 * s)
            mk.chip(bm, 0.06, 2.2, seed=k)
            p.add("ShellRed", bm)
            # lower edge trim and seam-side trim
            trim(p, [Vector(plate(i / 8, 1.0)) for i in range(9)], 0.09, 0.6, channel="ShellRust", sides=4)
            trim(p, [Vector(plate(0.0, j / 4)) for j in range(5)], 0.1, 0.6)
            # spines along the outer edge, pointing out and back
            q = Vector(plate(0.97, 0.5))
            spike(p, q, (s * 0.9, 0.55, -0.1), 0.85 + 0.25 * (2 - k), 0.2, "ShellRust", tip_channel="Bone")
            q2 = Vector(plate(0.55, 0.35))
            spike(p, q2, (s * 0.25, 1.0, 0.25), 0.55, 0.15, "ShellRust")
            for i in range(4):
                q3 = Vector(plate(0.15 + 0.22 * i, 1.0))
                spike(p, q3, (s * 0.3, 0.6, -1.0), 0.45, 0.13, "ShellRust", segs=4)
        host = mk.shell(lambda u, v, s=s: (C.x + A * math.cos(0.9 - 1.5 * v) * math.sin(s * (0.15 + 1.3 * u)),
                                           C.y + B * math.cos(0.9 - 1.5 * v) * math.cos(s * (0.15 + 1.3 * u)),
                                           C.z + H * math.sin(0.9 - 1.5 * v)), 10, 10, 0.1, inside=C)
        mk.scatter(p, "Bone", host, 6, 0.26, seed=80 + s, sink=0.0)
        host.free()
    mk.coral(p, "Coral", Vector((1.6, 2.55, 13.4)), (0.4, 0.6, 1.0), 1.4, 0.16, seed=91)
    mk.coral(p, "Coral", Vector((-2.1, 2.2, 10.6)), (-0.6, 0.7, 0.4), 1.0, 0.13, seed=92)


# SHOULDERS -----------------------------------------------------------------------------------------

def pauldron(p, s, big):
    k = 1.0 if big else 0.74
    cx = s * (5.3 if big else 5.0)
    cz = 13.7 if big else 13.55
    prof = [(0.0, 2.6), (0.9, 2.5), (1.75, 2.15), (2.4, 1.55), (2.85, 0.8), (3.1, 0.0), (3.28, -0.48),
            (3.02, -0.42), (2.72, 0.3), (2.12, 1.2), (1.3, 1.9), (0.0, 2.15)]
    tilt = mat((cx, 0.05, cz), (0, s * 28, 0), (1.0, 1.12, 1.0))
    t3 = tilt.to_3x3()
    bm = mk.lathe([(r * k, z * k) for r, z in prof], 18)
    mk.roughen(bm, 0.2, 0.75, seed=100 + s)
    mk.chip(bm, 0.1, 1.6, seed=101 + s)
    p.add("ShellRed", bm, tilt)
    # Second tier: a flared skirt under the dome breaks the silhouette into layers.
    skirt = mk.lathe([(r * k, z * k) for r, z in [(2.85, -0.2), (3.35, -0.72), (3.62, -1.08), (3.38, -1.02), (3.08, -0.68), (2.65, -0.25)]], 18)
    mk.roughen(skirt, 0.08, 1.4, seed=103 + s)
    p.add("Chitin" if big else "ShellRed", skirt, tilt)
    if big:
        for i in range(5):
            a = math.radians(-70 + 35 * i)
            groove = [tilt @ Vector((math.cos(a) * s * rr, math.sin(a) * rr, zz + 0.04)) for rr, zz in [(0.7, 2.47), (1.5, 2.25), (2.2, 1.8), (2.75, 1.05), (3.08, 0.2)]]
            p.add("ChitinDark", mk.sweep(groove, [0.05, 0.09, 0.1, 0.09, 0.05], sides=4, flat=0.6))
    host = mk.lathe([(r * k, z * k) for r, z in prof[:7]], 12)
    mk.transform(host, tilt)
    # Rim trim and marginal teeth around the outer half.
    rim = [tilt @ Vector((3.6 * k * math.cos(a), 3.6 * k * math.sin(a), -1.06 * k)) for a in [2 * math.pi * i / 24 for i in range(25)]]
    trim(p, rim, 0.13, 0.6, sides=4)
    teeth = 9 if big else 6
    for i in range(teeth):
        a = math.radians(-80 + 160 * i / (teeth - 1))
        lx, ly = math.cos(a) * s, math.sin(a)
        base = tilt @ Vector((3.55 * k * lx, 3.55 * k * ly, -1.0 * k))
        d = (t3 @ Vector((lx, ly, 0.2))).normalized()
        spike(p, base, d, (0.6 + 0.25 * (i % 2)) * k, 0.21 * k, "ShellRust", segs=5)
    if big:
        # Crab-shell grooves (dark) and knobbly tubercles.
        bumps(p, "ShellRust", host, 18, 0.3, seed=105, region=lambda co, n: n.z > 0.0)
        # Great horn-spines along the crest, growing toward the outside.
        for i in range(3):
            t = (i + 0.6) / 3
            r = 2.5 * t
            h = 2.6 - 1.3 * t * t
            base = tilt @ Vector((s * r, 0.4 if i % 2 else -0.4, h - 0.15))
            up = t3 @ Vector((s * (0.15 + 0.5 * t), 0.0, 1.0))
            out = t3 @ Vector((s * 1.0, 0.2 * (1 if i % 2 else -1), 0.3))
            curved_spike(p, base, up, out, 1.7 + 1.8 * t, 0.38 + 0.14 * t)
        mk.scatter(p, "Bone", host, 10, 0.27, seed=120 + s, region=lambda co, n: n.z > 0.15)
        mk.coral(p, "Coral", tilt @ Vector((s * 0.4, 1.35, 2.2)), (s * -0.2, 0.4, 1.0), 1.8, 0.21, seed=131)
        mk.coral(p, "Coral", tilt @ Vector((s * 1.7, -1.3, 1.5)), (0.0, -0.5, 1.0), 1.1, 0.15, seed=132, depth=1)
        r = rng(140)
        for i in range(4):
            a = math.radians(-50 + 33 * i + r.uniform(-8, 8))
            top = tilt @ Vector((s * 3.15 * math.cos(a) * 0.95, 3.15 * math.sin(a), -0.5))
            pts = [top + Vector((s * 0.05 * math.sin(j), 0.12 * math.sin(j * 1.3 + i), -0.6 * j)) for j in range(5)]
            p.add("Kelp", mk.sweep(pts, [0.22, 0.2, 0.17, 0.12, 0.0], sides=4, flat=0.25, tip=True))
    else:
        # The sword shoulder is forged, not grown: a brass keel, rivets and two spines.
        keel = [tilt @ Vector((s * 0.2, 2.2 * k * math.sin(a), 2.6 * k * math.cos(a) * 0.95 + 0.06)) for a in [-1.0 + 2.0 * i / 8 for i in range(9)]]
        p.add("Brass", mk.sweep(keel, [0.08, 0.14, 0.18, 0.2, 0.2, 0.2, 0.18, 0.14, 0.08], sides=5, flat=0.7))
        rivets(p, [tilt @ Vector((2.85 * k * math.cos(a) * s, 2.85 * k * math.sin(a), -0.2)) for a in [math.radians(x) for x in range(-75, 76, 25)]], 0.11)
        for i in range(2):
            base = tilt @ Vector((s * (0.9 + 0.8 * i) * k, -0.3 + 0.6 * i, (2.35 - 0.5 * i) * k))
            curved_spike(p, base, t3 @ Vector((s * 0.3, 0, 1)), t3 @ Vector((s * 1, 0.1, 0.2)), (1.4 + 0.4 * i), 0.3)
        mk.scatter(p, "Bone", host, 4, 0.22, seed=121, region=lambda co, n: n.z > 0.2)
    host.free()
    # Two lames hanging over the upper arm.
    for j in range(2):
        def lame(u, v, j=j):
            a = -1.75 + 3.5 * u
            rr = (2.2 - 0.2 * j + 0.25 * v) * (k if big else 0.92)
            z = cz - (0.75 + 0.85 * j) * k - 0.95 * k * v
            return (cx + s * rr * math.cos(a) * 0.95 - s * 0.35, rr * math.sin(a) * 1.08, z)
        bm = mk.shell(lame, 12, 2, 0.24, rim_bevel=0.05, inside=(cx, 0, cz - 1.5))
        mk.roughen(bm, 0.05, 1.8, seed=110 + j + s)
        p.add("Chitin" if big or j else "ShellRed", bm)
        trim(p, [Vector(lame(i / 10, 1.0)) for i in range(11)], 0.08, 0.6, sides=4)


def build_pauldrons():
    for s in (1, -1):
        p = piece(f"ShellPauldron{'L' if s > 0 else 'R'}", f"{side_name(s)}UpperArm", "Shell", shadow=True)
        pauldron(p, s, s > 0)


# ARMS ------------------------------------------------------------------------------------------

def build_upper_arm(s):
    p = piece(f"{side_name(s)}UpperArm", f"{side_name(s)}UpperArm", "Armor", shadow=True)
    c = p.origin
    big = s > 0
    k = 1.12 if big else 1.0
    # Shoulder cop (stays when the pauldron falls).
    cop = mk.lathe([(0.0, 1.25), (0.9, 1.15), (1.6, 0.8), (2.0, 0.25), (2.1, -0.3), (1.85, -0.25), (1.65, 0.2), (1.1, 0.75), (0.0, 0.95)], 16)
    mk.roughen(cop, 0.06, 1.4, seed=150 + s)
    cop_m = mat((c.x + s * 0.15, 0, 13.0), (0, s * 22, 0), (k, k * 1.08, k))
    p.add("Chitin", cop, cop_m)
    trim(p, [cop_m @ Vector((2.08 * math.cos(a), 2.08 * math.sin(a), -0.28)) for a in [2 * math.pi * i / 16 for i in range(17)]], 0.1, 0.6, sides=4)
    spike(p, cop_m @ Vector((s * 0.9, 0, 1.15)), (s * 0.5, 0, 1), 0.6, 0.18, "ShellRust")
    # Sleeve: two overlapping segments.
    for j, (z0, z1, r0, r1) in enumerate([(13.0, 11.6, 1.55, 1.5), (11.95, 10.45, 1.48, 1.38)]):
        seg = mk.lathe([(r0 * k * 0.92, z0), (r0 * k, z0 - 0.2), (r1 * k * 1.05, z1 + 0.15), (r1 * k * 0.95, z1)], 14)
        mk.roughen(seg, 0.04, 2.0, seed=160 + j + s)
        p.add("Chitin" if j == 0 else "ChitinDark", seg, mat((c.x, 0, 0)))
    trim(p, [Vector((c.x + 1.55 * k * math.cos(a), 1.55 * k * math.sin(a), 11.65)) for a in [2 * math.pi * i / 16 for i in range(17)]], 0.1, 0.6)
    if big:
        mk.scatter(p, "Bone", _cyl_host(c.x, 1.55 * k, 10.6, 12.8), 7, 0.2, seed=170, region=lambda co, n: co.x > c.x)
    else:
        rivets(p, [Vector((c.x + 1.6 * math.cos(a), 1.6 * math.sin(a), 12.3)) for a in [math.pi + 0.8 * i - 1.2 for i in range(4)]], 0.1)
    p.anchor("Elbow", joint("Elbow", s))


def _cyl_host(x, r, z0, z1):
    return mk.transform(mk.lathe([(r, z0), (r, z1)], 12), mat((x, 0, 0)))


def build_lower_arm(s):
    p = piece(f"{side_name(s)}LowerArm", f"{side_name(s)}LowerArm", "Armor", shadow=True)
    c = p.origin
    if s > 0:
        # Claw arm: the crab's merus, red and spiny, swelling toward the wrist.
        seg = mk.lathe([(1.35, 11.9), (1.55, 11.6), (1.75, 10.4), (2.0, 9.2), (1.95, 8.55), (1.7, 8.4)], 16)
        mk.roughen(seg, 0.08, 1.4, seed=180)
        mk.chip(seg, 0.05, 2.0, seed=181)
        p.add("ShellRed", seg, mat((c.x, 0, 0), (0, 0, 0), (1.0, 1.08, 1.0)))
        for j, z in enumerate((11.0, 9.6)):
            ring = mk.lathe([(1.65 + 0.15 * j, z - 0.18), (1.85 + 0.17 * j, z), (1.65 + 0.15 * j, z + 0.18)], 16)
            p.add("ChitinDark", ring, mat((c.x, 0, 0), (0, 0, 0), (1.0, 1.08, 1.0)))
        # serrated ridges (front and outer edges)
        for i in range(6):
            z = 11.4 - 0.5 * i
            r = 1.6 + 0.07 * i
            spike(p, (c.x, -r * 1.06, z), (0, -1, 0.35), 0.45 + 0.04 * i, 0.15, "ShellRust")
            spike(p, (c.x + r, 0.15, z - 0.2), (1, 0.2, 0.3), 0.5 + 0.05 * i, 0.16, "ShellRust")
        mk.scatter(p, "Bone", _cyl_host(c.x, 1.8, 8.8, 11.4), 8, 0.2, seed=182, region=lambda co, n: co.y > -0.4)
    else:
        # Sword arm: a plated vambrace with a finned outer ridge.
        seg = mk.lathe([(1.3, 11.9), (1.45, 11.5), (1.5, 9.4), (1.62, 8.6), (1.45, 8.35)], 16)
        mk.roughen(seg, 0.04, 2.0, seed=190)
        p.add("Chitin", seg, mat((c.x, 0, 0)))
        for z in (11.2, 8.75):
            trim(p, [Vector((c.x + 1.55 * math.cos(a), 1.55 * math.sin(a), z)) for a in [2 * math.pi * i / 16 for i in range(17)]], 0.11, 0.6)
        fin = mk.prism([(0.0, 0.0), (0.9, 0.35), (0.5, 0.75), (1.1, 1.15), (0.6, 1.55), (1.05, 2.0), (0.0, 2.35)], 0.22, bevel=0.05)
        p.add("ShellRust", fin, Matrix.Translation((c.x - 1.4, 0.3, 8.9)) @ Matrix(((-1, 0, 0, 0), (0, 0, 1, 0), (0, 1, 0, 0), (0, 0, 0, 1))))
        cop = mk.lathe([(0.0, 0.0), (0.75, 0.15), (0.85, 0.5), (0.0, 0.7)], 10)
        p.add("ShellRed", cop, align((c.x, 1.25, 11.25), (0, 1, 0.1)))
        spike(p, (c.x, 1.85, 11.3), (0, 1, -0.3), 0.7, 0.2, "ShellRust")
    p.anchor("Wrist", joint("Wrist", s))


# The pincer's frame: it reaches forward and down from the wrist.
CLAW_D = Vector((0.0, -0.74, -0.67)).normalized()    # along the claw
CLAW_P = Vector((0.0, -0.67, 0.74)).normalized()     # the dactyl side ("up" in the claw's plane)


def build_claw():
    p = piece("LeftHand", "LeftHand", "Claw", shadow=True)
    c = p.origin  # (5.0, 0, 7.91)
    x = c.x + 0.15
    wrist = Vector((x, -0.1, 8.35))
    D, P = CLAW_D, CLAW_P
    X = Vector((1, 0, 0))
    frame = Matrix((X, D, P)).transposed().to_4x4()   # local x = across, y = along, z = dactyl side
    def at(along, up, across=0.0):
        return wrist + D * along + P * up + X * across
    p.add("Brass", mk.lathe([(1.75, 8.1), (2.0, 8.3), (2.0, 8.65), (1.75, 8.85)], 14), mat((c.x, 0, 0)))
    # Palm (propodus): long, laterally flattened, swelling toward the fingers.
    palm = mk.lathe([(0.0, -0.4), (1.2, -0.2), (1.85, 0.6), (2.3, 1.9), (2.45, 3.3), (2.3, 4.6), (1.9, 5.6), (1.2, 6.2), (0.0, 6.4)], 14)
    mk.transform(palm, Matrix.Diagonal((0.78, 1.0, 1.0, 1.0)))   # flatten across
    palm.verts.ensure_lookup_table()
    # lathe axis is +Z: turn it so +Z runs along D and local y -> P
    lathe_to_frame = Matrix(((1, 0, 0, 0), (0, 0, 1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))  # (x, y, z) -> (x, z, y)
    pm = Matrix.Translation(wrist) @ frame @ lathe_to_frame
    mk.roughen(palm, 0.12, 1.1, seed=200)
    mk.chip(palm, 0.08, 1.5, seed=201)
    p.add("ShellRed", palm, pm)
    # Keels of spines along the upper and lower edges, tubercles on the outer face.
    for i in range(6):
        t = 0.8 + 0.85 * i
        spike(p, at(t, 2.2 + 0.15 * math.sin(t), 0.0), P + D * 0.35, 0.6 + 0.04 * i, 0.21, "ShellRust", segs=5)
    for i in range(4):
        t = 1.4 + 1.1 * i
        spike(p, at(t, -2.25, 0.0), -P + D * 0.3, 0.45, 0.18, "ShellRust", segs=5)
    host = mk.lathe([(1.2, -0.2), (1.85, 0.6), (2.3, 1.9), (2.45, 3.3), (2.3, 4.6), (1.9, 5.6)], 10)
    mk.transform(host, Matrix.Diagonal((0.78, 1.0, 1.0, 1.0)))
    mk.transform(host, pm)
    bumps(p, "ShellRust", host, 12, 0.24, seed=202, region=lambda co, n: n.x > 0.3)
    mk.scatter(p, "Bone", host, 12, 0.27, seed=210, region=lambda co, n: n.x > 0.1 or n.dot(P) > 0.5)
    host.free()
    mk.coral(p, "Coral", at(2.2, 2.0, 0.6), P * 0.8 + X * 0.6 - D * 0.2, 1.6, 0.19, seed=211)
    # Fixed finger (pollex) continues the lower edge; the dactyl hinges from the upper edge,
    # opened a little, and both curve in so the tips cross.
    def finger(start_up, open_deg, curl, length, r0, ch_tip, flip):
        d0 = (Matrix.Rotation(math.radians(open_deg), 3, X) @ D).normalized()
        pts = [at(5.5, start_up)]
        dirn = d0
        for i in range(5):
            pts.append(pts[-1] + dirn * (length / 5))
            dirn = (Matrix.Rotation(math.radians(curl), 3, X) @ dirn).normalized()
        radii = [r0, r0 * 0.9, r0 * 0.76, r0 * 0.6, r0 * 0.42, 0.0]
        p.add("ShellRed", mk.sweep(pts[:4], radii[:4], sides=8, flat=1.35, cap_start=False))
        p.add(ch_tip, mk.sweep(pts[3:], radii[3:], sides=8, flat=1.35, tip=True))
        # teeth along the inner edge
        for i in range(6):
            t = 0.1 + 0.75 * i / 5
            seg = t * 5
            j = min(int(seg), 4)
            q = pts[j].lerp(pts[j + 1], seg - j)
            inward = (Matrix.Rotation(math.radians(90 * flip), 3, X) @ (pts[j + 1] - pts[j]).normalized())
            rr = radii[j] * 1.25
            spike(p, q + inward * rr, inward, 0.65 * (1.1 - 0.5 * t), 0.2, "Bone", segs=4)
        return pts
    poll = finger(-1.0, 6, -9, 4.4, 1.05, "ChitinDark", -1)
    dac = finger(1.15, -24, 12, 4.6, 0.95, "ChitinDark", 1)
    p.add("ChitinDark", mk.sphere(0.8, 0.8, 0.8, 8, 6), mat(at(5.4, 1.15, 0.0)))
    p.anchor("Tip", poll[-1].lerp(dac[-1], 0.5))


def build_gauntlet():
    p = piece("RightHand", "RightHand", "Gauntlet", shadow=True)
    c = p.origin  # (-5.0, 0, 7.91)
    gz = zc(JOINT_Y["Grip"])
    p.add("Brass", mk.lathe([(1.6, 8.2), (1.85, 8.4), (1.85, 8.75), (1.6, 8.9)], 14), mat((c.x, 0, 0)))
    # Back of the hand: overlapping chitin plates over a dark iron glove.
    glove = mk.sphere(1.0, 1.45, 1.05, 10, 6)
    p.add("Metal", glove, mat((c.x - 0.35, 0.0, gz + 0.35)))
    for j in range(3):
        def plate(u, v, j=j):
            a = -1.3 + 2.6 * u
            y = -1.2 + 0.85 * j + 0.95 * v
            return (c.x - 0.3 - 1.12 * math.cos(a), y, gz + 0.45 + 1.12 * math.sin(a) * 0.9)
        bm = mk.shell(plate, 6, 1, 0.18, rim_bevel=0.04, inside=(c.x - 0.3, 0, gz + 0.4))
        p.add("Chitin", bm)
    for i in range(4):
        y = -0.95 + 0.63 * i
        roll = mk.sweep([Vector((c.x - 0.9, y, gz + 0.6)), Vector((c.x - 0.3, y, gz - 0.6)),
                         Vector((c.x + 0.6, y, gz - 0.5)), Vector((c.x + 0.8, y, gz + 0.15))],
                        [0.32, 0.33, 0.3, 0.26], sides=6)
        p.add("Metal", roll)
        p.add("Brass", mk.sphere(0.2, 0.2, 0.2, 6, 4), mat((c.x - 1.0, y, gz + 0.55)))
        spike(p, (c.x - 1.15, y, gz + 0.7), (-1, 0, 0.35), 0.5, 0.14, "ShellRust", segs=5)
    thumb = mk.sweep([Vector((c.x + 0.4, -1.2, gz + 0.9)), Vector((c.x + 0.8, -1.4, gz + 0.35)), Vector((c.x + 0.75, -1.1, gz - 0.15))],
                     [0.33, 0.3, 0.22], sides=6)
    p.add("Metal", thumb)


# Blade space: local x = across the blade (world z, the edge points down), local y = along it (world y),
# local z = through the flats (world -x).
BLADE_M = Matrix(((0, 0, -1, 0), (0, 1, 0, 0), (1, 0, 0, 0), (0, 0, 0, 1)))


def build_sword():
    """A massive two-handed coral greatsword: about 14.5 studs of blade (70% of the Warden's height),
    2.9 wide at the base, a thick bone spine, coral and barnacles grown along it, a heavy bone and
    brass guard and pommel. The edge points down (blade width is vertical)."""
    p = piece("Sword", "RightHand", "Greatsword", shadow=True, light={"range": 12, "brightness": 1.2})
    c = p.origin
    gx, gz = c.x, zc(JOINT_Y["Grip"])
    at = Matrix.Translation((gx, 0, gz)) @ BLADE_M  # blade space -> world
    a3 = at.to_3x3()
    r = rng(300)
    # Two-handed grip: bone core, cord wraps, brass collars.
    p.add("Bone", mk.lathe([(0.4, -1.6), (0.44, 3.3)], 8), align((gx, 0.0, gz), (0, 1, 0)))
    for i in range(10):
        y = -1.25 + 0.46 * i
        p.add("Rope", mk.lathe([(0.0, -0.13), (0.5, -0.08), (0.5, 0.08), (0.0, 0.13)], 7), align((gx, y, gz), (0, 1, 0)))
    for y in (-1.45, 3.3):
        p.add("Brass", mk.lathe([(0.0, -0.18), (0.62, -0.12), (0.66, 0.0), (0.62, 0.12), (0.0, 0.18)], 10), align((gx, y, gz), (0, 1, 0)))
    # Pommel: a heavy bone knuckle in a brass cage, a Current pearl and bone spurs.
    p.add("Bone", mk.sphere(0.85, 0.75, 0.9, 10, 7), mat((gx, 4.05, gz)))
    for k in range(4):
        ang = math.pi / 4 + k * math.pi / 2
        q = [Vector((gx + 0.92 * math.cos(ang), 3.45, gz + 0.92 * math.sin(ang))), Vector((gx + 0.98 * math.cos(ang), 4.05, gz + 0.98 * math.sin(ang))),
             Vector((gx + 0.55 * math.cos(ang), 4.7, gz + 0.55 * math.sin(ang)))]
        p.add("Brass", mk.sweep(q, [0.13, 0.13, 0.1], sides=4))
    p.add("Glow", mk.sphere(0.3, 0.3, 0.3, 8, 5), mat((gx, 4.85, gz)))
    for s in (-1, 1):
        curved_spike(p, (gx, 4.2, gz + s * 0.65), (0, 0.3, s * 1.0), (0, 1, s * 0.3), 1.0, 0.2, channel="Bone", tip_channel="Bone")
    # Crossguard: a heavy brass bar wrapped in bone, quillons curling forward like a pincer.
    gy = -2.0
    block = mk.box(1.4, 1.1, 2.6)
    mk.bevel_sharp(block, 0.25, 2)
    p.add("Brass", block, mat((gx, gy, gz)))
    collar = mk.box(1.0, 0.8, 3.3)
    mk.bevel_sharp(collar, 0.3, 2)
    mk.roughen(collar, 0.06, 2.0, seed=302)
    p.add("Bone", collar, mat((gx, gy - 0.65, gz)))
    for s in (-1, 1):
        q = [Vector((gx, gy, gz + s * 1.1)), Vector((gx, gy - 0.05, gz + s * 2.3)), Vector((gx, gy - 0.6, gz + s * 3.15)),
             Vector((gx, gy - 1.5, gz + s * 3.45)), Vector((gx, gy - 2.25, gz + s * 3.05))]
        p.add("Brass", mk.sweep(q, [0.5, 0.44, 0.35, 0.24, 0.0], sides=6, flat=0.7, tip=True))
        curved_spike(p, (gx, gy + 0.2, gz + s * 1.2), (0, 1, s * 0.6), (0, 0.6, s * 1.0), 1.4, 0.26, channel="Bone", tip_channel="Bone")
        rivets(p, [Vector((gx + side * 0.72, gy, gz + s * 0.8)) for side in (-1, 1)], 0.14)
    # Blade: a broad coral slab, notched edges, forked tip.
    L0 = gy - 0.9
    L1 = L0 - 13.0
    n = 18
    right, left = [], []
    for i in range(n + 1):
        t = i / n
        y = L0 + (L1 - L0) * t
        w = 1.45 - 0.6 * t + 0.16 * math.sin(math.pi * t * 0.9)
        nr = -0.24 if i % 3 == 1 else (0.08 if i % 3 == 2 else 0.0)
        nl = -0.26 if i % 4 == 2 else (0.1 if i % 4 == 3 else 0.0)
        right.append((w + nr * (0.4 + t), y))
        left.append((-(w + nl * (0.4 + t)), y))
    tip = [(0.75, L1 - 0.75), (0.28, L1 - 0.25), (0.0, L1 - 1.6), (-0.3, L1 - 0.4), (-0.8, L1 - 1.05)]
    poly = right + tip + left[::-1]
    poly = poly[::-1] if _area(poly) < 0 else poly
    blade = mk.prism(poly, 0.62, bevel=0.2, segments=1)
    mk.roughen(blade, 0.05, 2.0, seed=301)
    p.add("Coral", blade, at)
    # Thick bone spine on both flats; teal veins wander out from it toward both edges.
    for side in (-1, 1):
        sp = [Vector((0.0, y, side * 0.28)) for y in (L0 + 0.3, L0 - 3.5, L0 - 7.0, L0 - 10.0, L0 - 11.5)]
        p.add("Bone", mk.sweep(sp, [0.36, 0.32, 0.26, 0.16, 0.0], sides=6, flat=0.5, tip=True), at)
        for i in range(10):
            y0 = L0 - 0.6 - 1.1 * i - r.uniform(0, 0.3)
            s = 1 if (i + (side > 0)) % 2 else -1
            ang = math.radians(r.uniform(30, 60))
            pts = [Vector((s * 0.3, y0, side * 0.32))]
            for j in range(3):
                ang += math.radians(r.uniform(-20, 20))
                ln = r.uniform(0.25, 0.4) * (1 - 0.04 * i)
                pts.append(pts[-1] + Vector((s * math.sin(ang) * ln, -math.cos(ang) * ln, 0.0)))
            p.add("Glow", mk.sweep(pts, [0.075, 0.06, 0.045, 0.0], sides=4, flat=0.5, tip=True), at)
            if r.random() < 0.5:
                q = pts[2]
                p.add("Glow", mk.sweep([q, q + Vector((s * 0.15, -0.3, 0.0))], [0.045, 0.0], sides=4, flat=0.5, tip=True), at)
    # Branching coral along both edges and out of the flats.
    growths = [(1.35, -0.6, 1.0, -0.2, 0.3, 1.9, 0.24, 2), (-1.4, -2.0, -1.0, -0.4, -0.3, 1.7, 0.22, 2),
               (1.25, -4.4, 1.0, -0.6, 0.2, 1.5, 0.2, 1), (-1.2, -6.3, -1.0, -0.5, 0.3, 1.3, 0.18, 1),
               (1.05, -8.6, 1.0, -0.7, -0.2, 1.0, 0.15, 1), (0.6, -1.4, 0.3, -0.2, 1.0, 1.2, 0.17, 1),
               (-0.5, -3.6, -0.3, -0.3, -1.0, 1.1, 0.16, 1)]
    for i, (lx, ly, dx, dy, dz, ln, rad, depth) in enumerate(growths):
        mk.coral(p, "Coral", at @ Vector((lx, L0 + ly, 0.0)), a3 @ Vector((dx, dy, dz)), ln, rad, seed=310 + i, depth=depth)
    # Barnacle clusters on the flats.
    for cl, (cx, cy) in enumerate([(0.75, -1.2), (-0.8, -3.0), (0.6, -5.6), (-0.55, -7.8)]):
        side = 1 if cl % 2 else -1
        for k in range(4):
            q = Vector((cx + r.uniform(-0.3, 0.3), L0 + cy + r.uniform(-0.35, 0.35), side * 0.3))
            nrm = a3 @ Vector((0, 0, side))
            p.add("Bone", mk.barnacle(0.18 + 0.1 * r.random(), 0.26), align(at @ q, nrm))
    p.anchor("Tip", at @ Vector((0.0, L1 - 1.6, 0.0)))
    p.anchor("Pommel", (gx, 4.9, gz))


def _area(poly):
    a = 0.0
    for (x0, y0), (x1, y1) in zip(poly, poly[1:] + poly[:1]):
        a += x0 * y1 - x1 * y0
    return a / 2


# HIPS ------------------------------------------------------------------------------------------

def cloth(p, channel, width, length, top_point, outward, sag, seed, columns=9):
    """A torn cloth panel hung from top_point: a grid whose columns end at ragged lengths."""
    r = rng(seed)
    o = Vector(outward).normalized()
    across = Vector((0, 0, 1)).cross(o).normalized()
    ends = [length * (0.6 + 0.4 * r.random()) if i % 2 else length * (0.85 + 0.15 * r.random()) for i in range(columns + 1)]

    def fn(u, v):
        i = u * columns
        lo = int(min(i, columns - 1))
        f = i - lo
        end = ends[lo] * (1 - f) + ends[lo + 1] * f
        depth = end * v
        x = (u - 0.5) * width * (1 + 0.08 * v)
        wave = 0.1 * math.sin(x * 2.7 + depth * 1.6 + seed)
        return Vector(top_point) + across * x - Vector((0, 0, depth)) + o * (sag * depth * depth * 0.08 + wave)

    bm = mk.shell(fn, columns, 5, 0.1, inside=Vector(top_point) - o * 2.0)
    mk.roughen(bm, 0.03, 3.0, seed=seed)
    p.add(channel, bm)


def build_lower_torso():
    p = piece("LowerTorso", "LowerTorso", "Tassets", shadow=True)
    p.add("ChitinDark", mk.sphere(3.05, 1.9, 1.15, 12, 6), mat((0, 0.05, 8.5)))
    belt = mk.lathe([(1.0, 8.15), (1.06, 8.35), (1.06, 8.95), (1.0, 9.15)], 20)
    p.add("Brass", belt, mat((0, 0.05, 0), (0, 0, 0), (3.2, 1.98, 1.0)))
    buckle = mk.lathe([(0.0, 0.0), (0.75, 0.05), (0.85, 0.25), (0.6, 0.38), (0.0, 0.42)], 10)
    p.add("Brass", buckle, align((0, -2.0, 8.6), (0, -1, 0), scale=(1.3, 1.0, 1.0)))
    p.add("Bone", mk.sphere(0.28, 0.28, 0.28, 8, 5), mat((0, -2.45, 8.6)))
    for s in (-1, 1):
        spike(p, (s * 0.9, -2.05, 8.6), (s * 1, -0.4, 0.1), 0.6, 0.16, "Brass", segs=5)
    for a0 in (-2.65, -1.75, -0.8, 0.8, 1.75, 2.65):
        def tas(u, v, a0=a0):
            a = a0 + (-0.36 + 0.72 * u)
            z = 8.3 - 2.1 * v
            r = 1.0 + 0.16 * v
            return (3.3 * r * math.sin(a), 0.05 - 2.05 * r * math.cos(a), z)
        bm = mk.shell(tas, 4, 2, 0.22, rim_bevel=0.05, inside=(0, 0.05, 7.5))
        mk.roughen(bm, 0.04, 2.0, seed=int(a0 * 10) + 400)
        p.add("Chitin", bm)
        trim(p, [Vector(tas(i / 4, 1.0)) for i in range(5)], 0.08, 0.6, sides=4)
    cloth(p, "Sailcloth", 2.5, 4.6, (0, -2.35, 8.35), (0, -1, 0), 0.35, 401)
    cloth(p, "Sailcloth", 3.0, 5.2, (0, 2.3, 8.35), (0, 1, 0), 0.5, 402)
    r = rng(410)
    for i in range(7):
        x = r.uniform(-2.8, 2.8)
        front = -1 if i % 2 else 1
        top = Vector((x, front * 2.25, 8.3))
        ln = r.uniform(2.0, 3.6)
        pts = [top + Vector((0.12 * math.sin(j * 1.7 + i), front * (0.12 + 0.05 * j), -ln * j / 4)) for j in range(5)]
        p.add("Kelp", mk.sweep(pts, [0.22, 0.2, 0.16, 0.1, 0.0], sides=4, flat=0.25, tip=True))
    for s in (-1, 1):
        for k in range(2):
            pts = [Vector((s * (2.5 - 0.1 * k), 1.35 + 0.35 * k, 8.5 - 0.5 * k)),
                   Vector((s * (5.0 - 0.3 * k), 2.75 + 0.55 * k, 10.3 - 1.2 * k)),
                   Vector((s * (7.0 - 0.5 * k), 3.45 + 0.6 * k, 7.9 - 1.3 * k)),
                   Vector((s * (7.25 - 0.6 * k), 3.0 + 0.6 * k, 5.6 - 1.2 * k))]
            radii = [0.5, 0.42, 0.34]
            for j in range(3):
                a, b = pts[j], pts[j + 1]
                last = j == 2
                seg = mk.sweep([a, a.lerp(b, 0.5) + Vector((0, 0.15, 0.18)), b],
                               [radii[j], radii[j] * 1.15, radii[j] * (0.0 if last else 0.85)], sides=6, flat=0.75, tip=last,
                               cap_start=False)
                p.add("ChitinDark" if last else "ShellRed", seg)
                p.add("ShellRust", mk.sphere(radii[j] * 1.08, radii[j] * 1.08, radii[j] * 1.08, 6, 4), mat(a))
                if not last:
                    for q in (0.35, 0.7):
                        spike(p, a.lerp(b, q) + Vector((0, 0.2, 0.3)), (s * 0.15, 0.4, 1), 0.45, 0.11, "ShellRust", segs=4)
    p.anchor("HipL", joint("Hip", 1))
    p.anchor("HipR", joint("Hip", -1))


# LEGS ------------------------------------------------------------------------------------------

def build_upper_leg(s):
    p = piece(f"{side_name(s)}UpperLeg", f"{side_name(s)}UpperLeg", "Armor", shadow=True)
    x = p.origin.x
    thigh = mk.lathe([(1.45, 8.0), (1.75, 7.5), (1.65, 6.0), (1.35, 4.8), (1.25, 4.3)], 12)
    mk.roughen(thigh, 0.05, 1.8, seed=500 + s)
    p.add("ChitinDark", thigh, mat((x, 0, 0)))
    def cuisse(u, v):
        a = -1.25 + 2.5 * u
        z = 7.6 - 2.9 * v
        r = 1.8 + 0.12 * v
        return (x + r * math.sin(a), -0.1 - r * math.cos(a) * (1.05 + 0.2 * v), z)
    bm = mk.shell(cuisse, 8, 4, 0.26, rim_bevel=0.05, inside=(x, 0.0, 6.0))
    mk.roughen(bm, 0.05, 1.8, seed=510 + s)
    p.add("Chitin", bm)
    trim(p, [Vector(cuisse(i / 8, 1.0)) for i in range(9)], 0.09, 0.6, sides=4)
    trim(p, [Vector(cuisse(i / 8, 0.0)) for i in range(9)], 0.09, 0.6, sides=4)
    def outer(u, v):
        a = s * (1.0 + 1.1 * u)
        z = 7.7 - 2.4 * v
        return (x + 1.85 * math.sin(a), -1.85 * math.cos(a), z)
    p.add("Chitin", mk.shell(outer, 5, 3, 0.22, rim_bevel=0.05, inside=(x, 0, 6.0)))
    rivets(p, [Vector(outer(0.5, v)) + Vector((s * 0.12, 0, 0)) for v in (0.2, 0.5, 0.8)], 0.1)
    # Knee cop: a big forward-jutting red shell with a spike (the digitigrade knee).
    knee = mk.lathe([(0.0, 0.0), (1.0, 0.15), (1.3, 0.55), (1.05, 0.95), (0.0, 1.1)], 12)
    mk.roughen(knee, 0.05, 2.0, seed=520 + s)
    p.add("ShellRed", knee, align((x, -1.25, 4.4), (0, -1, 0.25), scale=(1.0, 1.15, 1.0)))
    curved_spike(p, (x, -2.25, 4.55), (0, -1, 0.2), (0, -0.4, 1.0), 1.4, 0.3)
    p.anchor("Knee", joint("Knee", s))


def build_lower_leg(s):
    p = piece(f"{side_name(s)}LowerLeg", f"{side_name(s)}LowerLeg", "Armor", shadow=True)
    x = p.origin.x
    path = [Vector((x, -0.75, 5.0)), Vector((x, -0.1, 3.9)), Vector((x, 0.6, 2.6)), Vector((x, 0.45, 1.6)), Vector((x, -0.1, 0.75))]
    shin = mk.sweep(path, [1.3, 1.25, 1.1, 1.05, 1.1], sides=10, flat=0.9)
    mk.roughen(shin, 0.05, 1.8, seed=530 + s)
    p.add("ChitinDark", shin)
    for j in range(3):
        z0 = 4.95 - 1.35 * j
        def greave(u, v, z0=z0):
            a = -1.3 + 2.6 * u
            z = z0 - 1.5 * v
            t = (5.0 - z) / 4.3
            cy = -0.8 + 1.3 * math.sin(math.pi * min(1, t) * 0.8) - 0.1
            rr = 1.42 + 0.14 * v
            return (x + rr * math.sin(a), cy - rr * math.cos(a), z)
        bm = mk.shell(greave, 8, 2, 0.24, rim_bevel=0.05, inside=(x, 0.3, z0 - 0.8))
        mk.roughen(bm, 0.05, 2.0, seed=540 + j + s)
        p.add("Chitin" if j != 1 else "ShellRed", bm)
        trim(p, [Vector(greave(i / 8, 1.0)) for i in range(9)], 0.08, 0.6, sides=4)
        spike(p, Vector(greave(0.5, 0.3)), (0, -1, 0.75), 0.85 - 0.12 * j, 0.22, "ShellRust", tip_channel="Bone")
    curved_spike(p, (x, 1.5, 2.6), (0, 1, -0.2), (0, 0.6, -1.0), 1.8, 0.36)
    spike(p, (x + s * 1.2, 0.6, 3.0), (s * 1, 0.6, -0.2), 0.7, 0.2, "ShellRust")
    mk.scatter(p, "Bone", _cyl_host(x, 1.3, 1.4, 4.4), 3, 0.18, seed=550 + s, region=lambda co, n: co.y > 0.3)
    p.anchor("Ankle", joint("Ankle", s))


def build_foot(s):
    p = piece(f"{side_name(s)}Foot", f"{side_name(s)}Foot", "Armor", shadow=False)
    x = p.origin.x
    base = mk.box(2.8, 3.4, 0.95)
    mk.bevel_sharp(base, 0.3, 2)
    mk.roughen(base, 0.04, 2.0, seed=560 + s)
    p.add("ChitinDark", base, mat((x, -0.55, 0.48)))
    for j in range(3):
        lame = mk.box(2.7 - 0.2 * j, 1.15, 0.38)
        mk.bevel_sharp(lame, 0.12, 1)
        p.add("Chitin" if j % 2 == 0 else "ShellRed", lame, mat((x, -0.2 - 0.85 * j, 1.08 - 0.2 * j), (-14 - 4 * j, 0, 0)))
    p.add("Brass", mk.lathe([(1.3, 0.9), (1.45, 1.05), (1.45, 1.35), (1.3, 1.45)], 12), mat((x, 0.1, 0)))
    # Three long forward claws and a back spur.
    for i, dx in enumerate((-0.95, 0.0, 0.95)):
        base_pt = Vector((x + dx, -2.0, 0.5))
        tip = Vector((x + dx * 1.45, -4.4 + 0.3 * abs(dx), 0.08))
        mid = base_pt.lerp(tip, 0.45) + Vector((0, 0, 0.35))
        p.add("Chitin", mk.sweep([base_pt, mid], [0.42, 0.34], sides=6, flat=0.8))
        p.add("Bone", mk.sweep([mid, mid.lerp(tip, 0.6) + Vector((0, 0, 0.05)), tip], [0.34, 0.2, 0.0], sides=6, flat=0.8, tip=True))
    curved_spike(p, (x, 1.0, 0.6), (0, 1, -0.1), (0, 0.6, -0.8), 1.2, 0.28, channel="Chitin")


# BUILD -------------------------------------------------------------------------------------------

def build_all():
    build_head()
    build_torso()
    build_shell_chest()
    build_core()
    build_seam()
    build_shell_back()
    build_pauldrons()
    for s in (1, -1):
        build_upper_arm(s)
        build_lower_arm(s)
        build_upper_leg(s)
        build_lower_leg(s)
        build_foot(s)
    build_claw()
    build_gauntlet()
    build_sword()
    build_lower_torso()


def fit_budget(p):
    budget = BUDGET.get(p.name[len(BODY) + 1:])
    if not budget:
        return
    tris = p.tris()
    total = sum(tris.values())
    fixed = tris.get("Glow", 0)
    if total <= budget:
        return
    ratio = max(0.3, (budget - fixed) / max(1, total - fixed))
    for ch, bm in p.channels.items():
        if ch != "Glow" and tris[ch] > 60:
            bmesh.ops.triangulate(bm, faces=bm.faces)
            mk.decimate(bm, ratio)


def make_materials():
    mats = {}
    for name, (hexcol, rough, metal, emit) in CHANNELS.items():
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        bsdf = m.node_tree.nodes.get("Principled BSDF")
        rgb = tuple(int(hexcol[i:i + 2], 16) / 255 for i in (0, 2, 4))
        lin = tuple(((c + 0.055) / 1.055) ** 2.4 if c > 0.04045 else c / 12.92 for c in rgb)
        bsdf.inputs["Base Color"].default_value = (*lin, 1.0)
        bsdf.inputs["Roughness"].default_value = rough
        bsdf.inputs["Metallic"].default_value = metal
        if emit > 0:
            bsdf.inputs["Emission Color"].default_value = (*lin, 1.0)
            bsdf.inputs["Emission Strength"].default_value = emit
        m.diffuse_color = (*lin, 1.0)
        mats[name] = m
    return mats


def finish_mesh(bm):
    """Hard edges at creases, smooth elsewhere (split normals by edge split)."""
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-4)
    bmesh.ops.dissolve_degenerate(bm, edges=bm.edges, dist=1e-5)
    bmesh.ops.triangulate(bm, faces=bm.faces)
    sharp = [e for e in bm.edges if e.is_manifold and e.calc_face_angle(0.0) > math.radians(42)]
    if sharp:
        bmesh.ops.split_edges(bm, edges=sharp)
    for f in bm.faces:
        f.smooth = True


def objects_from_pieces(mats, collection):
    objs = []
    for p in PIECES:
        for ch, bm in sorted(p.channels.items()):
            finish_mesh(bm)
            bmesh.ops.translate(bm, vec=-p.origin, verts=bm.verts)
            me = bpy.data.meshes.new(f"{p.name}__{ch}")
            bm.to_mesh(me)
            bmesh.ops.translate(bm, vec=p.origin, verts=bm.verts)
            me.materials.append(mats[ch])
            ob = bpy.data.objects.new(f"{p.name}__{ch}", me)
            ob.location = p.origin
            collection.objects.link(ob)
            ob["piece"] = p.name
            ob["limb"] = p.limb
            objs.append(ob)
    return objs


def calibration(collection, mats):
    out = []
    for tag, pos, size in (("O", (0, 0, 0), 2.0), ("X", (CALIB, 0, 0), 1.0), ("Y", (0, CALIB, 0), 1.0), ("Z", (0, 0, CALIB), 1.0)):
        bm = mk.box(size, size, size)
        me = bpy.data.meshes.new(f"Calib_{FILE}__{tag}")
        bm.to_mesh(me)
        bm.free()
        me.materials.append(mats["Brass"])
        ob = bpy.data.objects.new(f"Calib_{FILE}__{tag}", me)
        ob.location = pos
        collection.objects.link(ob)
        out.append(ob)
    return out


def r2(v):
    return round(float(v), 3)


def manifest_entry(p):
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for bm in p.channels.values():
        for v in bm.verts:
            q = v.co - p.origin
            lo = Vector((min(lo.x, q.x), min(lo.y, q.y), min(lo.z, q.z)))
            hi = Vector((max(hi.x, q.x), max(hi.y, q.y), max(hi.z, q.z)))
    _, size = limb_info(p.limb)
    meta = {"body": BODY, "limb": p.limb, "role": p.role, "rigScale": S, "pieces": len(PIECES),
            "limbSize": [r2(size[0]), r2(size[1]), r2(size[2])],
            "shadow": bool(p.meta.get("shadow", False))}
    if "light" in p.meta:
        meta["light"] = p.meta["light"]
    anchors = {}
    for name, (pos, yaw) in p.anchors.items():
        q = Vector(pos) - p.origin
        anchors[name] = [r2(q.x), r2(q.y), r2(q.z), r2(yaw)]
    return {"File": FILE, "Category": "Guardian", "Position": [r2(p.origin.x), r2(p.origin.y), r2(p.origin.z)],
            "Bounds": [[r2(lo.x), r2(lo.y), r2(lo.z)], [r2(hi.x), r2(hi.y), r2(hi.z)]],
            "Size": [r2(hi.x - lo.x), r2(hi.y - lo.y), r2(hi.z - lo.z)], "Collision": [], "Anchors": anchors, "Meta": meta}


LUA_HEADER = """--!strict
--[[
	KitManifestGuardians (generated by tools/blender/guardian/build_brinewarden.py; do not edit by hand)
	Floor Guardian body pieces from SpireKit_Guardians.fbx, in the KitManifest schema (Blender space:
	z up, the body faces -y, 1 unit = 1 stud). KitManifest merges these into its Files and Pieces, so
	KitLibrary.Prepare() builds a template for each piece once the FBX is imported.

	Each piece is rigid and rides one R15 part: Position is that part's centre in a reference rig at
	Meta.rigScale (Roblox default R15 x rigScale, feet on z = 0), so the template origin IS the limb
	centre. Like every kit piece the body faces template +Z, so MobService/Builder turns each piece
	180 degrees about Y onto its limb (an R15 part faces -Z). Meta: body (MobDef Body.MeshBody), limb
	(R15 part), role (Part name in the boss Model: Shell / Core / Seam / Claw / Helm / ...), rigScale,
	pieces (how many make the body), limbSize (studs, x y-up z), shadow, light.
]]

local HttpService = game:GetService("HttpService")

local DATA = [==[
"""

LUA_FOOTER = """
]==]

return HttpService:JSONDecode(DATA)
"""


def write_manifest(repo, entries, files_info):
    data = {"Files": {FILE: files_info}, "Pieces": entries}
    path_json = os.path.join(HERE, "guardian_manifest.json")
    with open(path_json, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
    text = json.dumps(data, separators=(",", ":"), sort_keys=True)
    # wrap like KitManifest (lines of about 200 characters, split after commas)
    lines = []
    cur = ""
    for chunk in text.split(","):
        piece_ = chunk + ","
        if len(cur) + len(piece_) > 200:
            lines.append(cur)
            cur = ""
        cur += piece_
    cur = cur[:-1]
    lines.append(cur)
    lua = LUA_HEADER + "\n".join(lines) + LUA_FOOTER
    with open(os.path.join(repo, "src/ServerStorage/Tools/KitManifestGuardians.lua"), "w") as f:
        f.write(lua)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".")
    ap.add_argument("--no-render", action="store_true")
    ap.add_argument("--only-render", default="")
    args, _ = ap.parse_known_args()
    repo = os.path.abspath(args.repo)
    t0 = time.time()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.scale_length = 1.0
    mats = make_materials()
    build_all()
    coll = bpy.data.collections.new("SpireKit_Guardians")
    scene.collection.children.link(coll)
    # tri counts before export (triangulated)
    report = []
    total = 0
    entries = {}
    for p in PIECES:
        fit_budget(p)
        entries[p.name] = manifest_entry(p)
    objs = objects_from_pieces(mats, coll)
    for p in PIECES:
        t = sum(len(o.data.polygons) for o in objs if o["piece"] == p.name)
        total += t
        report.append((p.name, t, sorted(p.channels.keys())))
    calib = calibration(coll, mats)
    meshes = len(objs)
    write_manifest(repo, entries, {"pieces": len(PIECES), "tris": total, "meshes": meshes, "optional": 1})
    out_dir = os.path.join(repo, "assets/guardian")
    os.makedirs(out_dir, exist_ok=True)
    fbx = os.path.join(out_dir, "SpireKit_Guardians.fbx")
    bpy.ops.export_scene.fbx(filepath=fbx, use_selection=False, object_types={"MESH"}, apply_unit_scale=True,
                             apply_scale_options="FBX_SCALE_UNITS", axis_forward="-Z", axis_up="Y",
                             bake_space_transform=True, mesh_smooth_type="FACE", use_mesh_modifiers=True,
                             use_triangles=True, add_leaf_bones=False, bake_anim=False, path_mode="STRIP")
    for name, t, chans in report:
        print(f"  {name:32s} {t:6d} tris  {', '.join(chans)}")
        if os.environ.get("GUARDIAN_VERBOSE"):
            for o in objs:
                if o["piece"] == name:
                    print(f"      {o.name:44s} {len(o.data.polygons):6d}")
    print(f"TOTAL {total} tris, {meshes} meshes, {len(PIECES)} pieces  ({time.time() - t0:.1f}s)")
    if not args.no_render:
        import render_brinewarden
        render_brinewarden.render_all(repo, PIECES, objs, calib, mats, args.only_render)
    bpy.context.preferences.filepaths.save_version = 0  # no .blend1 backups next to the asset
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out_dir, "SpireKit_Guardians.blend"), compress=True)
    print(f"done in {time.time() - t0:.1f}s")


if __name__ == "__main__":
    # bpy can hang on interpreter exit, so leave with os._exit (non-zero on failure).
    code = 0
    try:
        main()
    except Exception:  # noqa: BLE001
        import traceback
        traceback.print_exc()
        code = 1
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(code)
