"""
Props, harbour/canal pieces, landmark pieces and nature for The Spire kit.
Same conventions as pieces_arch.py (Roblox space, origin at bottom-centre).
"""
from __future__ import annotations

import math
import random

from kitlib import Builder, Collider, PieceMeta, arch_pts
from pieces_arch import REGISTRY, piece, reg


# =================================================================== PROPS

@piece("crate_l")
def crate_l():
    b = Builder()
    b.box(-1.5, 0, -1.5, 1.5, 3, 1.5)
    for s in (-1, 1):
        b.box(-1.6, 0, s * 1.5 - 0.1, 1.6, 0.35, s * 1.5 + 0.1)
        b.box(-1.6, 2.65, s * 1.5 - 0.1, 1.6, 3.0, s * 1.5 + 0.1)
        b.beam((-1.3, 0.35, s * 1.58), (1.3, 2.65, s * 1.58), 0.3)
    return b, PieceMeta("crate_l", "prop", "WoodPlanks", "WoodLight", "Box", 0.06, footprint=[3, 3, 3])


@piece("crate_s")
def crate_s():
    b = Builder()
    b.box(-1, 0, -1, 1, 2, 1)
    for s in (-1, 1):
        b.box(-1.08, 0, s - 0.07, 1.08, 0.25, s + 0.07)
        b.box(-1.08, 1.75, s - 0.07, 1.08, 2.0, s + 0.07)
    return b, PieceMeta("crate_s", "prop", "WoodPlanks", "WoodLight", "Box", 0.05, footprint=[2, 2, 2])


@piece("barrel")
def barrel():
    b = Builder()
    b.frustum(0, 0, 0.95, 1.15, 0, 1.6, 12)
    b.frustum(0, 0, 1.15, 0.95, 1.6, 3.2, 12)
    for y in (0.35, 1.5, 2.85):
        b.frustum(0, 0, 1.06 + (0.1 if y == 1.5 else 0), 1.06 + (0.1 if y == 1.5 else 0), y, y + 0.22, 12)
    return b, PieceMeta("barrel", "prop", "Wood", "WoodLight", "Hull", 0.0, footprint=[2.3, 3.2, 2.3])


@piece("market_stall_frame")
def stall_frame():
    b = Builder()
    for x in (-3.8, 3.8):
        for z in (-2.3, 2.3):
            b.box(x - 0.25, 0, z - 0.25, x + 0.25, 7.2 if z > 0 else 6.2, z + 0.25)
    b.box(-4, 2.8, -2.5, 4, 3.4, 0.0)  # counter top
    b.box(-3.8, 0, -2.3, 3.8, 2.8, -1.9)  # counter front
    b.box(-4, 6.0, -2.5, 4, 6.3, -2.2)
    b.box(-4, 7.0, 2.2, 4, 7.3, 2.5)
    cols = [Collider("Box", 0, 1.7, -1.2, 8.0, 3.4, 2.6)]
    return b, PieceMeta("market_stall_frame", "prop", "Wood", "Wood", "Colliders", 0.04, colliders=cols, footprint=[8, 7.3, 5])


@piece("market_stall_canopy")
def stall_canopy():
    b = Builder()
    b.prism_zy([(-2.8, 6.2), (2.8, 7.3), (2.8, 7.55), (-2.8, 6.45)], -4.3, 4.3)
    for i in range(8):
        x = -4.3 + i * 8.6 / 8
        b.prism_xy([(x, 6.25), (x + 1.075, 6.25), (x + 0.54, 5.6)], -2.85, -2.7)
    return b, PieceMeta("market_stall_canopy", "prop", "Fabric", "ClothRed", "None", 0.0, footprint=[8.6, 2, 5.6])


@piece("lantern_post")
def lantern_post():
    b = Builder()
    b.frustum(0, 0, 0.7, 0.55, 0, 0.8, 8)
    b.cyl(0, 0, 0.25, 0.8, 9.0, 8)
    b.box(-0.15, 8.6, -1.6, 0.15, 8.85, 0.15)
    b.beam((0, 7.6, 0), (0, 8.6, -1.2), 0.15)
    b.frustum(0, -1.6, 0.55, 0.15, 8.3, 8.9, 6)  # cap
    b.box(-0.45, 6.9, -2.05, 0.45, 7.0, -1.15)  # base plate
    for dx, dz in ((-0.4, -2.0), (0.4, -2.0), (-0.4, -1.2), (0.4, -1.2)):
        b.box(dx - 0.05, 7.0, dz - 0.05, dx + 0.05, 8.3, dz + 0.05)
    m = PieceMeta("lantern_post", "prop", "Metal", "Iron", "Box", 0.0, footprint=[1.4, 9, 2.2])
    m.anchors["light"] = [0, 7.65, -1.6]
    return b, m


@piece("lantern_glass")
def lantern_glass():
    b = Builder()
    b.box(-0.33, 0, -0.33, 0.33, 1.2, 0.33)
    return b, PieceMeta("lantern_glass", "prop", "Neon", "LanternGlow", "None", 0.0, footprint=[0.66, 1.2, 0.66])


@piece("lantern_wall")
def lantern_wall():
    b = Builder()
    b.box(-0.35, -0.5, -0.12, 0.35, 0.5, 0.0)
    b.box(-0.08, 0.2, -1.4, 0.08, 0.35, 0)
    b.frustum(0, -1.4, 0.45, 0.1, 0.1, 0.6, 6)
    for dx, dz in ((-0.32, -1.72), (0.32, -1.72), (-0.32, -1.08), (0.32, -1.08)):
        b.box(dx - 0.04, -1.1, dz - 0.04, dx + 0.04, 0.1, dz + 0.04)
    b.box(-0.38, -1.2, -1.78, 0.38, -1.1, -1.02)
    m = PieceMeta("lantern_wall", "prop", "Metal", "Iron", "None", 0.0, footprint=[0.9, 1.8, 1.8])
    m.anchors["light"] = [0, -0.5, -1.4]
    return b, m


@piece("lantern_hanging")
def lantern_hanging():
    b = Builder()
    for i in range(4):
        y = -i * 0.6
        b.box(-0.06, y - 0.5, -0.06, 0.06, y, 0.06)
    b.frustum(0, 0, 0.5, 0.1, -2.6, -2.2, 6)
    for dx, dz in ((-0.35, -0.35), (0.35, -0.35), (-0.35, 0.35), (0.35, 0.35)):
        b.box(dx - 0.04, -3.8, dz - 0.04, dx + 0.04, -2.6, dz + 0.04)
    b.box(-0.42, -3.9, -0.42, 0.42, -3.8, 0.42)
    m = PieceMeta("lantern_hanging", "prop", "Metal", "Iron", "None", 0.0, footprint=[1, 3.9, 1])
    m.anchors["light"] = [0, -3.2, 0]
    return b, m


@piece("bench")
def bench():
    b = Builder()
    b.box(-3, 1.6, -0.8, 3, 1.95, 0.8)
    for x in (-2.4, 2.4):
        b.box(x - 0.25, 0, -0.65, x + 0.25, 1.6, 0.65)
    b.box(-3, 1.95, 0.55, 3, 3.6, 0.8)
    return b, PieceMeta("bench", "prop", "Wood", "Wood", "Box", 0.05, footprint=[6, 3.6, 1.6])


@piece("well_base")
def well_base():
    b = Builder()
    b.ring(0, 0, 2.3, 3.2, 0, 3.0, 16)
    b.cyl(0, 0, 2.35, 0, 0.6, 16)
    b.ring(0, 0, 2.2, 3.45, 2.7, 3.2, 16)
    cols = [Collider("Box", 0, 1.6, 0, 6.4, 3.2, 6.4)]
    return b, PieceMeta("well_base", "prop", "Cobblestone", "Stone", "Colliders", 0.05, 0.05, colliders=cols, footprint=[6.9, 3.2, 6.9])


@piece("well_roof")
def well_roof():
    b = Builder()
    for x in (-2.8, 2.8):
        b.box(x - 0.3, 3.0, -0.3, x + 0.3, 9.0, 0.3)
    b.box(-3.1, 6.6, -0.12, 3.1, 6.9, 0.12)
    b.cyl_x(6.0, 0, 0.35, -2.5, 2.5, 8)
    b.prism_zy([(-3.6, 8.4), (0, 11.2), (3.6, 8.4), (3.6, 8.9), (0, 11.7), (-3.6, 8.9)], -3.6, 3.6)
    return b, PieceMeta("well_roof", "prop", "Wood", "WoodDark", "None", 0.04, footprint=[7.2, 11.7, 7.2])


@piece("statue_plinth")
def statue_plinth():
    b = Builder()
    b.box(-3.5, 0, -3.5, 3.5, 1.2, 3.5)
    b.box(-2.8, 1.2, -2.8, 2.8, 5.0, 2.8)
    b.box(-3.1, 5.0, -3.1, 3.1, 5.7, 3.1)
    return b, PieceMeta("statue_plinth", "prop", "Granite", "StoneDark", "Box", 0.12, 0.05, footprint=[7, 5.7, 7])


@piece("statue_climber")
def statue_climber():
    """An original hooded Climber figure gazing upward, blade planted before it."""
    b = Builder()
    b.frustum(0, 0, 1.9, 1.3, 0, 6.5, 10)  # cloak body
    b.frustum(0, 0, 1.3, 1.1, 6.5, 8.5, 10)  # shoulders
    b.blob(0, 9.2, -0.15, 0.9, 1.05, 0.95, 11, 0.06, 1)  # hooded head
    b.frustum(0, 0.25, 1.0, 0.2, 9.6, 10.9, 8)  # hood point
    b.beam((-1.1, 7.8, -0.4), (-0.4, 5.6, -1.4), 0.55)  # arms reaching to hilt
    b.beam((1.1, 7.8, -0.4), (0.4, 5.6, -1.4), 0.55)
    b.box(-0.15, 0.2, -1.65, 0.15, 5.0, -1.35)  # blade
    b.box(-0.9, 5.0, -1.7, 0.9, 5.35, -1.3)  # crossguard
    b.box(-0.18, 5.35, -1.62, 0.18, 6.4, -1.38)  # grip
    return b, PieceMeta("statue_climber", "prop", "Marble", "Marble", "Hull", 0.03, footprint=[3.8, 11, 3.8])


@piece("cart")
def cart():
    b = Builder()
    b.box(-2.2, 1.8, -3.5, 2.2, 2.3, 3.5)
    for x in (-2.2, 2.2):
        b.box(x - 0.15, 2.3, -3.5, x + 0.15, 3.8, 3.5)
    b.box(-2.2, 2.3, 3.35, 2.2, 3.8, 3.5)
    for x in (-2.5, 2.5):
        b.cyl_x(1.6, 1.0, 1.6, x - 0.25, x + 0.25, 12)
    b.beam((-0.9, 2.0, -3.5), (-0.9, 1.6, -7.5), 0.25)
    b.beam((0.9, 2.0, -3.5), (0.9, 1.6, -7.5), 0.25)
    return b, PieceMeta("cart", "prop", "Wood", "WoodLight", "Hull", 0.03, footprint=[5.5, 3.8, 11])


@piece("bookshelf")
def bookshelf():
    b = Builder()
    b.box(-3, 0, 0.0, 3, 8, 0.2)
    for x in (-3, 2.75):
        b.box(x, 0, -1.6, x + 0.25, 8, 0.2)
    for y in (0, 2.0, 4.0, 6.0, 7.75):
        b.box(-3, y, -1.6, 3, y + 0.25, 0.2)
    return b, PieceMeta("bookshelf", "prop", "Wood", "WoodDark", "Box", 0.03, footprint=[6, 8, 1.8])


@piece("books")
def books():
    b = Builder()
    rng = random.Random(42)
    for y in (0.25, 2.25, 4.25, 6.25):
        x = -2.7
        while x < 2.5:
            w = rng.uniform(0.25, 0.45)
            h = rng.uniform(1.1, 1.6)
            if rng.random() < 0.12:
                x += 0.5
                continue
            b.box(x, y, -1.4, x + w, y + h, -0.1)
            x += w + 0.03
    return b, PieceMeta("books", "prop", "Fabric", "BookMixed", "None", 0.0, footprint=[5.4, 7.5, 1.3])


@piece("table")
def table():
    b = Builder()
    b.box(-3, 3.2, -1.6, 3, 3.6, 1.6)
    for x in (-2.6, 2.6):
        for z in (-1.2, 1.2):
            b.box(x - 0.2, 0, z - 0.2, x + 0.2, 3.2, z + 0.2)
    b.box(-2.6, 0.8, -0.1, 2.6, 1.1, 0.1)
    return b, PieceMeta("table", "prop", "Wood", "Wood", "Box", 0.04, footprint=[6, 3.6, 3.2])


@piece("table_round")
def table_round():
    b = Builder()
    b.cyl(0, 0, 2.2, 3.2, 3.6, 14)
    b.cyl(0, 0, 0.35, 0.3, 3.2, 8)
    b.frustum(0, 0, 1.2, 0.5, 0, 0.4, 8)
    return b, PieceMeta("table_round", "prop", "Wood", "Wood", "Hull", 0.02, footprint=[4.4, 3.6, 4.4])


@piece("chair")
def chair():
    b = Builder()
    b.box(-0.9, 1.8, -0.9, 0.9, 2.1, 0.9)
    for x in (-0.7, 0.7):
        for z in (-0.7, 0.7):
            b.box(x - 0.12, 0, z - 0.12, x + 0.12, 1.8, z + 0.12)
        b.box(x - 0.12, 2.1, 0.58, x + 0.12, 4.2, 0.82)
    b.box(-0.9, 3.3, 0.6, 0.9, 4.1, 0.8)
    return b, PieceMeta("chair", "prop", "Wood", "WoodLight", "Box", 0.03, footprint=[1.8, 4.2, 1.8])


@piece("stool")
def stool():
    b = Builder()
    b.cyl(0, 0, 0.8, 2.0, 2.3, 10)
    for a in (0, 2.1, 4.2):
        b.beam((math.cos(a) * 0.5, 2.0, math.sin(a) * 0.5), (math.cos(a) * 0.75, 0, math.sin(a) * 0.75), 0.18)
    return b, PieceMeta("stool", "prop", "Wood", "WoodLight", "Hull", 0.0, footprint=[1.6, 2.3, 1.6])


@piece("counter")
def counter():
    b = Builder()
    b.box(-4, 0, -1, 4, 3.4, 1)
    b.box(-4.2, 3.4, -1.2, 4.2, 3.8, 1.2)
    for x in (-2.7, 0, 2.7):
        b.box(x - 1.1, 0.5, -1.08, x + 1.1, 2.9, -1.0)
    return b, PieceMeta("counter", "prop", "Wood", "WoodDark", "Box", 0.04, footprint=[8.4, 3.8, 2.4])


@piece("bed_frame")
def bed_frame():
    b = Builder()
    b.box(-2, 0.8, -3.6, 2, 1.4, 3.6)
    for x in (-1.8, 1.8):
        for z in (-3.4, 3.4):
            b.box(x - 0.2, 0, z - 0.2, x + 0.2, 1.4, z + 0.2)
    b.box(-2.1, 0, 3.4, 2.1, 4.2, 3.8)
    b.box(-2.1, 0, -3.8, 2.1, 2.6, -3.4)
    return b, PieceMeta("bed_frame", "prop", "Wood", "WoodDark", "Box", 0.04, footprint=[4.2, 4.2, 7.6])


@piece("bed_linen")
def bed_linen():
    b = Builder()
    b.box(-1.85, 1.4, -3.3, 1.85, 2.1, 3.3)
    b.box(-1.95, 1.0, -3.35, 1.95, 2.0, 1.4)
    b.blob(0, 2.3, 2.6, 1.3, 0.35, 0.6, 5, 0.1, 1)
    return b, PieceMeta("bed_linen", "prop", "Fabric", "Linen", "None", 0.0, footprint=[3.9, 2.6, 6.7])


@piece("weapon_rack")
def weapon_rack():
    b = Builder()
    for x in (-2.8, 2.8):
        b.box(x - 0.25, 0, -0.25, x + 0.25, 6, 0.25)
    for y in (1.0, 4.6):
        b.box(-3, y, -0.6, 3, y + 0.35, 0.25)
    return b, PieceMeta("weapon_rack", "prop", "Wood", "WoodDark", "Box", 0.04, footprint=[6, 6, 0.85])


@piece("weapon_set")
def weapon_set():
    b = Builder()
    for i, x in enumerate((-2.0, -1.0, 0.0, 1.0, 2.0)):
        tall = 5.6 if i % 2 == 0 else 4.8
        b.box(x - 0.1, 0.9, -0.5, x + 0.1, tall, -0.35)
        b.box(x - 0.45, tall - 1.3, -0.55, x + 0.45, tall - 1.1, -0.3)
        if i % 2 == 0:
            b.prism_xy([(x - 0.3, tall), (x + 0.3, tall), (x, tall + 0.8)], -0.5, -0.35)
    return b, PieceMeta("weapon_set", "prop", "Metal", "Steel", "None", 0.0, footprint=[4.5, 6.4, 0.3])


@piece("anvil")
def anvil():
    b = Builder()
    b.box(-1.0, 0, -0.8, 1.0, 1.0, 0.8)
    b.box(-0.6, 1.0, -0.5, 0.6, 2.2, 0.5)
    b.box(-1.5, 2.2, -0.7, 1.4, 3.0, 0.7)
    b.prism_xy([(1.4, 2.2), (2.6, 2.85), (1.4, 3.0)], -0.45, 0.45)
    return b, PieceMeta("anvil", "prop", "Metal", "Iron", "Box", 0.05, footprint=[4.1, 3, 1.6])


@piece("forge_body")
def forge_body():
    b = Builder()
    b.box(-4, 0, -3, 4, 3.6, 3)
    b.box(-3, 2.6, -2.2, 3, 3.8, 2.2, cut=True)
    b.frustum(0, 1.0, 3.2, 1.4, 3.6, 9.0, 4)
    b.box(-1.4, 9.0, -0.4, 1.4, 16.0, 2.4)
    cols = [Collider("Box", 0, 1.8, 0, 8, 3.6, 6)]
    m = PieceMeta("forge_body", "prop", "Brick", "Brick", "Colliders", 0.06, 0.05, colliders=cols, footprint=[8, 16, 6])
    m.anchors["light"] = [0, 3.4, 0]
    m.anchors["smoke"] = [0, 16.2, 1.0]
    return b, m


@piece("forge_coals")
def forge_coals():
    b = Builder()
    rng = random.Random(9)
    for _ in range(14):
        b.blob(rng.uniform(-2.5, 2.5), 0.25, rng.uniform(-1.7, 1.7), 0.45, 0.3, 0.45, rng.randint(0, 999), 0.2, 0)
    return b, PieceMeta("forge_coals", "prop", "Neon", "Ember", "None", 0.0, footprint=[6, 0.6, 4])


@piece("cooking_pot")
def cooking_pot():
    b = Builder()
    for a in (0, 2.1, 4.2):
        b.beam((math.cos(a) * 1.8, 0, math.sin(a) * 1.8), (0, 4.4, 0), 0.18)
    b.box(-0.04, 2.6, -0.04, 0.04, 4.3, 0.04)
    b.frustum(0, 0, 0.9, 1.25, 1.2, 1.9, 10)
    b.frustum(0, 0, 1.25, 1.0, 1.9, 2.6, 10)
    m = PieceMeta("cooking_pot", "prop", "Metal", "Iron", "None", 0.0, footprint=[3.6, 4.4, 3.6])
    m.anchors["fire"] = [0, 0.3, 0]
    return b, m


@piece("cookfire")
def cookfire():
    b = Builder()
    rng = random.Random(4)
    for i in range(6):
        a = i * math.pi / 3
        b.blob(math.cos(a) * 1.1, 0.25, math.sin(a) * 1.1, 0.4, 0.3, 0.35, rng.randint(0, 999), 0.2, 0)
    b.blob(0, 0.3, 0, 0.6, 0.35, 0.6, 77, 0.3, 0)
    return b, PieceMeta("cookfire", "prop", "Neon", "Ember", "None", 0.0, footprint=[3, 0.7, 3])


@piece("potted_plant_pot")
def potted_pot():
    b = Builder()
    b.frustum(0, 0, 0.7, 1.0, 0, 1.6, 10)
    b.frustum(0, 0, 1.08, 1.08, 1.4, 1.75, 10)
    return b, PieceMeta("potted_plant_pot", "prop", "Concrete", "Terracotta", "Hull", 0.0, footprint=[2.2, 1.75, 2.2])


@piece("potted_plant_leaves")
def potted_leaves():
    b = Builder()
    rng = random.Random(12)
    for i in range(5):
        a = i * 1.26
        b.blob(math.cos(a) * 0.5, 2.5 + rng.uniform(0, 0.8), math.sin(a) * 0.5, 0.7, 0.9, 0.7, rng.randint(0, 999), 0.25, 1)
    return b, PieceMeta("potted_plant_leaves", "prop", "LeafyGrass", "LeafGreen", "None", 0.0, footprint=[2.6, 3.8, 2.6])


@piece("hanging_chain")
def hanging_chain():
    b = Builder()
    for i in range(10):
        y = -i * 0.8
        if i % 2 == 0:
            b.box(-0.22, y - 0.85, -0.06, 0.22, y, 0.06)
        else:
            b.box(-0.06, y - 0.85, -0.22, 0.06, y, 0.22)
    b.prism_xy([(-0.1, -8.0), (0.1, -8.0), (0.7, -9.4), (0.4, -9.6), (0.0, -8.8), (-0.4, -9.6), (-0.7, -9.4)], -0.08, 0.08)
    return b, PieceMeta("hanging_chain", "prop", "Metal", "IronRust", "None", 0.0, footprint=[1.4, 9.6, 0.4])


@piece("rubble_pile")
def rubble_pile():
    b = Builder()
    rng = random.Random(21)
    for _ in range(9):
        r = rng.uniform(0.5, 1.3)
        b.blob(rng.uniform(-2.4, 2.4), r * 0.5, rng.uniform(-1.8, 1.8), r * 1.2, r * 0.8, r, rng.randint(0, 9999), 0.3, 0)
    b.box(-0.9, 0, -0.6, 1.6, 0.9, 0.5)
    return b, PieceMeta("rubble_pile", "prop", "Slate", "Stone", "Hull", 0.05, 0.05, footprint=[6, 2, 4.4])


@piece("chest")
def chest():
    b = Builder()
    b.box(-1.6, 0, -1.0, 1.6, 1.6, 1.0)
    b.cyl_x(1.6, 0, 1.0, -1.6, 1.6, 10)
    for x in (-1.1, 1.1):
        b.box(x - 0.15, 0, -1.08, x + 0.15, 2.65, 1.08)
    b.box(-0.3, 1.0, -1.15, 0.3, 1.7, -1.0)
    m = PieceMeta("chest", "prop", "Wood", "WoodChest", "Box", 0.04, footprint=[3.2, 2.6, 2])
    m.anchors["lid"] = [0, 1.6, 1.0]
    return b, m


@piece("rug")
def rug():
    b = Builder()
    b.box(-3, 0, -2, 3, 0.08, 2)
    for x in (-3.2, 3.0):
        for i in range(8):
            z = -1.9 + i * 0.52
            b.box(x, 0, z, x + 0.2, 0.05, z + 0.12)
    return b, PieceMeta("rug", "prop", "Fabric", "ClothRed", "None", 0.0, footprint=[6.4, 0.08, 4])


@piece("fishing_net")
def fishing_net():
    b = Builder()
    b.blob(0, 0.5, 0, 2.6, 0.6, 1.8, 17, 0.35, 1)
    return b, PieceMeta("fishing_net", "prop", "Fabric", "Rope", "None", 0.0, footprint=[5.2, 1.1, 3.6])


@piece("rope_coil")
def rope_coil():
    b = Builder()
    for i in range(3):
        y = i * 0.28
        r = 1.0 - i * 0.12
        b.ring(0, 0, r - 0.32, r, y, y + 0.3, 14)
    return b, PieceMeta("rope_coil", "prop", "Fabric", "Rope", "None", 0.0, footprint=[2, 0.9, 2])


@piece("fish_rack")
def fish_rack():
    b = Builder()
    for x in (-3, 3):
        b.beam((x, 0, -1.2), (x, 5.4, 0), 0.3)
        b.beam((x, 0, 1.2), (x, 5.4, 0), 0.3)
    b.cyl_x(5.2, 0, 0.15, -3.4, 3.4, 6)
    for i in range(6):
        x = -2.5 + i
        b.prism_xy([(x - 0.2, 5.1), (x + 0.2, 5.1), (x + 0.3, 3.4), (x, 3.0), (x - 0.3, 3.4)], -0.1, 0.1)
    return b, PieceMeta("fish_rack", "prop", "Wood", "WoodDark", "None", 0.0, footprint=[6.8, 5.4, 2.4])


@piece("bollard")
def bollard():
    b = Builder()
    b.cyl(0, 0, 0.6, 0, 2.0, 10)
    b.cyl(0, 0, 0.85, 2.0, 2.4, 10)
    return b, PieceMeta("bollard", "prop", "Metal", "Iron", "Hull", 0.0, footprint=[1.7, 2.4, 1.7])


# ========================================================= HARBOUR & CANALS

@piece("pier_deck_8")
def pier_deck():
    b = Builder()
    for i in range(8):
        x = -4 + i
        b.box(x + 0.04, -0.8, -4, x + 0.96, 0, 4)
    for z in (-3.5, 3.5):
        b.box(-4, -1.6, z - 0.4, 4, -0.8, z + 0.4)
    cols = [Collider("Box", 0, -0.4, 0, 8, 0.8, 8)]
    return b, PieceMeta("pier_deck_8", "harbor", "WoodPlanks", "WoodWet", "Colliders", 0.03, colliders=cols, footprint=[8, 1.6, 8])


@piece("pier_piling")
def pier_piling():
    b = Builder()
    b.cyl(0, 0, 0.65, -16, 0, 8)
    b.cyl(0, 0, 0.75, -6, -5.2, 8)
    return b, PieceMeta("pier_piling", "harbor", "Wood", "WoodWet", "Hull", 0.0, footprint=[1.5, 16, 1.5])


@piece("boat_row")
def boat_row():
    b = Builder()
    prof = [(-5.5, 1.6), (-4.5, 0.4), (-2, 0), (2, 0), (4.5, 0.4), (5.5, 1.8), (5.2, 2.0), (-5.2, 1.8)]
    b.prism_zy(prof, -1.8, 1.8)
    b.prism_zy([(-4.8, 1.0), (4.8, 1.0), (4.8, 2.3), (-4.8, 2.3)], -1.45, 1.45, cut=True)
    for z in (-1.5, 1.2):
        b.box(-1.6, 1.2, z - 0.4, 1.6, 1.5, z + 0.4)
    return b, PieceMeta("boat_row", "harbor", "Wood", "WoodLight", "Hull", 0.04, footprint=[3.6, 2.2, 11])


@piece("ship_hull")
def ship_hull():
    """A three-masted Lowharbor trader moored in the bay (60 studs long)."""
    b = Builder()
    prof_side = [(-31, 13), (-27, 6), (-22, 2), (20, 2), (26, 5), (30, 13), (30, 15.5), (-31, 15.0)]
    b.prism_zy(prof_side, -7, 7)
    b.prism_zy([(-29, 6), (28, 6), (28, 16), (-29, 16)], -6.2, 6.2, cut=True)
    b.box(-6.6, 9.5, -27, 6.6, 10.2, 27)  # main deck
    b.box(-6.6, 15.0, 18, 6.6, 15.6, 29.5)  # sterncastle deck
    b.box(-6.9, 13.2, 17.5, 6.9, 18.5, 18.2)
    b.box(-6.9, 15.6, 29.3, 6.9, 18.5, 30.0)
    b.beam((0, 14, -31), (0, 19, -42), 0.9)  # bowsprit
    cols = [Collider("Box", 0, 8.0, 0, 14, 4.0, 56), Collider("Box", 0, 12.5, 24, 13, 6, 12)]
    return b, PieceMeta("ship_hull", "harbor", "Wood", "WoodDark", "Colliders", 0.06, colliders=cols, footprint=[14, 19, 73])


@piece("ship_mast")
def ship_mast():
    b = Builder()
    b.cyl(0, 0, 0.7, 0, 52, 8)
    for y, w in ((20, 15), (34, 12), (46, 8)):
        b.cyl_x(y, 0, 0.35, -w, w, 6)
    b.cyl(0, 0, 1.6, 30, 31, 8)
    return b, PieceMeta("ship_mast", "harbor", "Wood", "WoodDark", "None", 0.0, footprint=[30, 52, 3.2])


@piece("ship_sail")
def ship_sail():
    b = Builder()
    for y0, y1, w0, w1 in ((20, 33, 14.5, 11.5), (34, 45, 11.5, 7.5)):
        b.prism_xy([(-w0, y0 - 0.3), (w0, y0 - 0.3), (w1, y1), (-w1, y1)], -1.3, -1.0)
        b.prism_xy([(-w0 * 0.9, y0 + 1), (w0 * 0.9, y0 + 1), (w1 * 0.9, y1 - 1), (-w1 * 0.9, y1 - 1)], -1.9, -1.3)
    return b, PieceMeta("ship_sail", "harbor", "Fabric", "Sail", "None", 0.0, footprint=[29, 25, 1])


@piece("canal_wall_l16")
def canal_wall():
    """Stone canal edge. Origin at street level on the canal-side lip; the wall
    drops 8 studs to the canal bed toward -Y on the -Z (water) side."""
    b = Builder()
    b.box(-8, -8, -0.4, 8, 0, 1.6)
    b.box(-8, -0.6, -0.9, 8, 0.4, 1.6)  # coping
    rng = random.Random(16)
    for i in range(10):
        x = rng.uniform(-7, 6)
        y = rng.uniform(-7, -2)
        b.box(x, y, -0.6, x + rng.uniform(1.2, 2.0), y + 0.8, -0.3)
    b.box(-6.5, -6.0, -1.2, -5.5, -5.0, -0.4)  # mooring ring block
    cols = [Collider("Box", 0, -3.8, 0.6, 16, 8.4, 2.0)]
    return b, PieceMeta("canal_wall_l16", "canal", "Slate", "StoneWet", "Colliders", 0.06, 0.05, stretch="x", colliders=cols, footprint=[16, 8.4, 2.5])


@piece("bridge_arch_l16")
def bridge_arch():
    """Stone footbridge spanning a 16-stud canal along local Z, deck 10 wide."""
    b = Builder()
    outer = [(-12, 0), (-12, -8), (-8, -8)]
    for i in range(1, 12):
        a = math.pi - math.pi * i / 12
        outer.append((math.cos(a) * 8, -8 + 1 + math.sin(a) * 5.4))
    outer += [(8, -8), (12, -8), (12, 0), (12, 0.6), (-12, 0.6)]
    b.prism_zy(outer, -5, 5)
    b.box(-5.6, 0.6, -12, -4.6, 3.6, 12)
    b.box(4.6, 0.6, -12, 5.6, 3.6, 12)
    b.box(-5.8, 3.6, -12.2, -4.4, 4.1, 12.2)
    b.box(4.4, 3.6, -12.2, 5.8, 4.1, 12.2)
    cols = [Collider("Box", 0, 0.1, 0, 10, 1.0, 24), Collider("Box", -5.1, 2.4, 0, 1.0, 3.6, 24), Collider("Box", 5.1, 2.4, 0, 1.0, 3.6, 24)]
    return b, PieceMeta("bridge_arch_l16", "canal", "Cobblestone", "Stone", "Colliders", 0.08, 0.05, colliders=cols, footprint=[11.6, 12, 24])


@piece("waterfall_lip")
def waterfall_lip():
    b = Builder()
    b.box(-8, -1.5, -1.5, 8, 0, 1.5)
    b.box(-8.5, -1.5, -1.5, -7, 1.2, 2.0)
    b.box(7, -1.5, -1.5, 8.5, 1.2, 2.0)
    return b, PieceMeta("waterfall_lip", "canal", "Slate", "StoneWet", "Box", 0.08, 0.05, stretch="x", footprint=[17, 2.7, 3.5])


# ================================================================ LANDMARKS

@piece("waystone")
def waystone():
    b = Builder()
    b.cyl(0, 0, 4.5, 0, 0.8, 8)
    b.cyl(0, 0, 3.6, 0.8, 1.6, 8)
    b.frustum(0, 0, 1.6, 1.0, 1.6, 11.0, 4)
    b.frustum(0, 0, 1.0, 0.05, 11.0, 13.0, 4)
    for a in range(4):
        ang = a * math.pi / 2 + math.pi / 4
        b.beam((math.cos(ang) * 3.4, 1.6, math.sin(ang) * 3.4), (math.cos(ang) * 1.5, 4.5, math.sin(ang) * 1.5), 0.8)
    m = PieceMeta("waystone", "landmark", "Basalt", "StoneDark", "Hull", 0.1, 0.05, footprint=[9, 13, 9])
    m.anchors["ring"] = [0, 8.0, 0]
    m.anchors["light"] = [0, 6.0, 0]
    return b, m


@piece("waystone_ring")
def waystone_ring():
    b = Builder()
    b.ring(0, 0, 2.6, 3.0, -0.2, 0.2, 24)
    for i in range(6):
        a = i * math.pi / 3
        b.cbox(math.cos(a) * 2.8, 0, math.sin(a) * 2.8, 0.6, 0.6, 0.6)
    return b, PieceMeta("waystone_ring", "landmark", "Neon", "CurrentTeal", "None", 0.0, footprint=[6, 0.6, 6])


@piece("waystone_runes")
def waystone_runes():
    b = Builder()
    for side in range(4):
        for i in range(5):
            y = 3.0 + i * 1.5
            k = 1.0 - (y - 1.6) / 9.4 * 0.38
            off = 1.6 * k + 0.02
            if side == 0:
                b.box(-0.25, y, -off - 0.05, 0.25, y + 0.9, -off + 0.05)
            elif side == 1:
                b.box(off - 0.05, y, -0.25, off + 0.05, y + 0.9, 0.25)
            elif side == 2:
                b.box(-0.25, y, off - 0.05, 0.25, y + 0.9, off + 0.05)
            else:
                b.box(-off - 0.05, y, -0.25, -off + 0.05, y + 0.9, 0.25)
    return b, PieceMeta("waystone_runes", "landmark", "Neon", "CurrentTeal", "None", 0.0, footprint=[3.3, 9.9, 3.3])


@piece("arch_l16")
def arch_l16():
    """Free-standing stone arch, 16 clear span, 20 high, 3 deep."""
    b = Builder()
    pts = [(-11, 0), (11, 0), (11, 22), (-11, 22)]
    b.prism_xy(pts, -1.5, 1.5)
    b.prism_xy(arch_pts(-8, 8, -0.1, 12, 14), -2.0, 2.0, cut=True)
    b.box(-11.6, 20.8, -2.0, 11.6, 22.6, 2.0)
    b.box(-0.9, 19.0, -1.9, 0.9, 21.2, 1.9)
    cols = [Collider("Box", -9.5, 11, 0, 3, 22, 3), Collider("Box", 9.5, 11, 0, 3, 22, 3), Collider("Box", 0, 21.2, 0, 22, 2.8, 3)]
    return b, PieceMeta("arch_l16", "landmark", "Slate", "Stone", "Colliders", 0.1, 0.05, colliders=cols, footprint=[22, 22, 3])


@piece("gate_leaf")
def gate_leaf():
    """One leaf of the sealed Guardian gate: 20 wide, 60 tall, hinge at x = 0."""
    b = Builder()
    b.box(0, 0, -1.5, 20, 60, 1.5)
    for y in range(4, 60, 8):
        b.box(0.5, y, -2.0, 19.5, y + 1.2, -1.5)
    for x in (2, 18):
        b.box(x - 0.6, 0, -2.0, x + 0.6, 60, -1.5)
    for y in range(8, 58, 6):  # rivet columns either side of the central seam
        for x in (4.5, 15.5):
            b.cyl_z(x, y, 0.55, -2.3, -1.5, 6)
    return b, PieceMeta("gate_leaf", "landmark", "Metal", "Bronze", "Box", 0.15, footprint=[20, 60, 3])


@piece("gate_rune")
def gate_rune():
    b = Builder()
    b.ring_z(0, 0, 9.8, 10.5, -0.3, 0.3, 32)
    for i in range(6):
        a = i * math.pi / 3
        b.beam((math.cos(a) * 9.8, math.sin(a) * 9.8, 0), (math.cos(a + 2.1) * 9.8, math.sin(a + 2.1) * 9.8, 0), 0.5)
    b.cyl_z(0, 0, 2.2, -0.4, 0.4, 16)
    return b, PieceMeta("gate_rune", "landmark", "Neon", "CurrentTeal", "None", 0.0, footprint=[21, 21, 0.8])


def make_tower_ring(d: int, window: bool):
    def build():
        b = Builder()
        r = d / 2
        b.ring(0, 0, r - 0.5, r + 0.5, 0, 12, 16)
        b.ring(0, 0, r - 0.5, r + 0.75, 0, 0.8, 16)
        if window:
            for i in range(4):
                a = i * math.pi / 2 + math.pi / 4
                cx, cz = math.cos(a) * r, math.sin(a) * r
                pts = arch_pts(-1.5, 1.5, 4, 8, 6)
                # cutter oriented radially: build in local XY then rotate by placing points
                ring_a, ring_b = [], []
                for px, py in pts:
                    tx, tz = -math.sin(a) * px, math.cos(a) * px
                    ring_a.append((cx + tx + math.cos(a) * -1.5, py, cz + tz + math.sin(a) * -1.5))
                    ring_b.append((cx + tx + math.cos(a) * 1.5, py, cz + tz + math.sin(a) * 1.5))
                from kitlib import rb
                b._quad_shell(b.cut, [rb(*p) for p in ring_a], [rb(*p) for p in ring_b])
        meta = PieceMeta(f"tower_ring{'_win' if window else ''}_d{d}", "landmark", "Slate", "Stone",
                         "Colliders", 0.06, 0.04, footprint=[d + 1.5, 12, d + 1.5])
        n = 12
        for i in range(n):
            a = 2 * math.pi * i / n
            seg_len = 2 * math.pi * r / n + 0.4
            meta.colliders.append(Collider("Box", math.cos(a) * r, 6, math.sin(a) * r, seg_len, 12, 1.0, -math.degrees(a) + 90))
        return b, meta
    return build


for _d in (12, 16):
    reg(f"tower_ring_d{_d}", make_tower_ring(_d, False))
    reg(f"tower_ring_win_d{_d}", make_tower_ring(_d, True))


@piece("window_rose")
def window_rose():
    b = Builder()
    b.ring_z(0, 0, 5.6, 6.6, -0.8, 0.8, 24)
    for i in range(8):
        a = i * math.pi / 4
        b.beam((math.cos(a) * 1.2, math.sin(a) * 1.2, 0), (math.cos(a) * 5.8, math.sin(a) * 5.8, 0), 0.4)
    b.cyl_z(0, 0, 1.3, -0.5, 0.5, 12)
    return b, PieceMeta("window_rose", "landmark", "Limestone", "StoneLight", "None", 0.05, footprint=[13.2, 13.2, 1.6])


@piece("pane_rose")
def pane_rose():
    b = Builder()
    b.prism_xy([(math.cos(a) * 5.7, math.sin(a) * 5.7) for a in [i * math.pi / 12 for i in range(24)]], -0.1, 0.1)
    return b, PieceMeta("pane_rose", "landmark", "Glass", "GlassTeal", "None", 0.0, footprint=[11.4, 11.4, 0.2])


@piece("bell")
def bell():
    b = Builder()
    b.frustum(0, 0, 3.0, 2.4, 0, 0.6, 16)
    b.frustum(0, 0, 2.4, 1.5, 0.6, 4.2, 16)
    b.dome(0, 4.2, 0, 1.5, 3, 16, 0.9)
    b.box(-0.3, 5.0, -0.3, 0.3, 6.0, 0.3)
    return b, PieceMeta("bell", "landmark", "Metal", "Bronze", "Hull", 0.0, footprint=[6, 6, 6])


@piece("tower_wall_segment")
def tower_wall_segment():
    """Colossal arcade bay of the Spire's inner wall (skybox ring). 400 wide, 900 tall,
    concave toward -Z (the playable floor). Window bays show the drowned world."""
    b = Builder()
    w, h, t = 400.0, 900.0, 40.0
    b.box(-w / 2, 0, 0, w / 2, h, t)
    for bx in (-120.0, 0.0, 120.0):
        b.prism_xy(arch_pts(bx - 45, bx + 45, 120, 420, 10), -1, t + 1, cut=True)
        b.box(bx - 58, 0, -18, bx - 45, 520, 0)
        b.box(bx + 45, 0, -18, bx + 58, 520, 0)
    for y in (100, 520, 700, 860):
        b.box(-w / 2, y, -24, w / 2, y + 14, 0)
    return b, PieceMeta("tower_wall_segment", "landmark", "Basalt", "TowerStone", "None", 0.0, stretch="x", footprint=[400, 900, 64])


@piece("current_falls")
def current_falls():
    """Thin sheet of falling Current, 40 wide, 600 tall, faces -Z."""
    b = Builder()
    rng = random.Random(5)
    x = -20.0
    while x < 20:
        sw = rng.uniform(2.5, 5)
        x1 = min(x + sw, 20)
        b.box(x, rng.uniform(-20, 0), -0.4 - rng.uniform(0, 1.2), x1, 600, 0.4)
        x = x1 + 0.3
    return b, PieceMeta("current_falls", "landmark", "Neon", "CurrentFalls", "None", 0.0, footprint=[40, 620, 2])


@piece("floor_underside")
def floor_underside():
    """The underside of Floor 2, glimpsed far overhead (inverted stalactite disc)."""
    b = Builder()
    b.frustum(0, 0, 600, 900, -120, 0, 24)
    rng = random.Random(8)
    for _ in range(40):
        a = rng.uniform(0, 2 * math.pi)
        r = rng.uniform(80, 760)
        b.frustum(math.cos(a) * r, math.sin(a) * r, rng.uniform(20, 55), 1.0, -120, -120 - rng.uniform(60, 260), 6)
    return b, PieceMeta("floor_underside", "landmark", "Basalt", "TowerStone", "None", 0.0, footprint=[1800, 380, 1800])


# =================================================================== NATURE

for _i, _s in enumerate((2, 4, 8, 14, 24), start=1):
    def _rock(i: int = _i, s: float = _s):
        def build():
            b = Builder()
            rng = random.Random(i * 31)
            b.blob(0, s * 0.35, 0, s * 0.55, s * 0.45, s * 0.48, i * 101, 0.22, 1)
            if s >= 8:
                b.blob(s * 0.35, s * 0.18, s * 0.2, s * 0.3, s * 0.25, s * 0.3, i * 7, 0.25, 0)
            mat = "Rock" if s < 14 else "Basalt"
            return b, PieceMeta(f"rock_{i}", "nature", mat, "Rock", "Hull", 0.0, footprint=[s * 1.2, s * 0.8, s])
        return build
    reg(f"rock_{_i}", _rock())


def make_cliff(name: str, w: float, h: float, d: float, seed: int):
    def build():
        b = Builder()
        rng = random.Random(seed)
        # stacked faceted slabs give a crisp stratified cliff silhouette
        y = 0.0
        while y < h:
            sh = rng.uniform(h * 0.12, h * 0.22)
            inset = rng.uniform(-2, 3)
            pts = []
            n = 9
            for i in range(n):
                t = i / (n - 1)
                pts.append((-w / 2 + t * w, -d / 2 + inset + rng.uniform(-1.5, 1.5)))
            pts += [(w / 2 - rng.uniform(0, 3), d / 2), (-w / 2 + rng.uniform(0, 3), d / 2)]
            b.prism_xz(pts, y, min(y + sh, h))
            y += sh * 0.92
        cols = [Collider("Box", 0, h / 2, 1.0, w * 0.96, h, d - 2)]
        return b, PieceMeta(name, "nature", "Rock", "Cliff", "Colliders", 0.25, 0.4, colliders=cols, footprint=[w, h, d])
    return build


reg("cliff_a", make_cliff("cliff_a", 40, 60, 20, 1))
reg("cliff_b", make_cliff("cliff_b", 60, 40, 24, 2))
reg("cliff_c", make_cliff("cliff_c", 30, 90, 20, 3))


TREE_SIZES = {"s": 0.6, "m": 1.0, "l": 1.6}


def _trunk(b: Builder, rng: random.Random, k: float, height: float, lean: float, branches: int) -> list[tuple[float, float, float]]:
    tips = []
    top = (rng.uniform(-lean, lean) * k, height * k, rng.uniform(-lean, lean) * k)
    b.frustum(0, 0, 1.3 * k, 0.9 * k, 0, height * 0.35 * k, 8)
    b.beam((0, height * 0.3 * k, 0), top, 1.4 * k)
    tips.append(top)
    for i in range(branches):
        a = rng.uniform(0, 2 * math.pi)
        y0 = height * rng.uniform(0.45, 0.8) * k
        r = rng.uniform(3, 6) * k
        tip = (math.cos(a) * r, y0 + rng.uniform(2, 5) * k, math.sin(a) * r)
        b.beam((top[0] * y0 / (height * k), y0, top[2] * y0 / (height * k)), tip, 0.6 * k)
        tips.append(tip)
    for i in range(4):  # root flare
        a = i * math.pi / 2 + 0.4
        b.beam((0, 1.2 * k, 0), (math.cos(a) * 2.4 * k, 0, math.sin(a) * 2.4 * k), 0.6 * k)
    return tips


def make_tree(species: str, size: str):
    k = TREE_SIZES[size]

    def tips_for(seed: int) -> tuple[Builder, list[tuple[float, float, float]]]:
        b = Builder()
        rng = random.Random(seed)
        if species == "rustwood":
            tips = _trunk(b, rng, k, 16, 2.0, 4)
        elif species == "willow":
            tips = _trunk(b, rng, k, 12, 3.0, 5)
        else:
            tips = _trunk(b, rng, k, 22, 0.6, 0)
        return b, tips

    seed = hash((species, size)) & 0xFFFF

    def trunk():
        b, _ = tips_for(seed)
        return b, PieceMeta(f"tree_{species}_{size}_trunk", "nature", "Wood", "Bark" if species != "rustwood" else "BarkRust",
                            "Colliders", 0.0, colliders=[Collider("Box", 0, 6 * k, 0, 2.4 * k, 12 * k, 2.4 * k)],
                            footprint=[3 * k, 16 * k, 3 * k])

    def crown():
        _, tips = tips_for(seed)
        b = Builder()
        rng = random.Random(seed + 1)
        if species == "pine":
            for i in range(5):
                y = (8 + i * 3.4) * k
                r = (6.5 - i * 1.15) * k
                b.frustum(0, 0, r, 0.4 * k, y, y + 5.5 * k, 9)
            color = "LeafPine"
        else:
            for t in tips:
                b.blob(t[0], t[1] + 1.5 * k, t[2], 5.6 * k, 4.0 * k, 5.6 * k, rng.randint(0, 9999), 0.25, 1)
            if species == "willow":
                for t in tips:
                    for i in range(6):
                        a = i * math.pi / 3 + rng.uniform(-0.3, 0.3)
                        r = 3.6 * k
                        x, z = t[0] + math.cos(a) * r, t[2] + math.sin(a) * r
                        top = t[1] + 0.5 * k
                        b.prism_xz([(x - 0.35 * k, z), (x + 0.35 * k, z), (x, z + 0.35 * k)], top - rng.uniform(5, 8) * k, top)
            color = "LeafRust" if species == "rustwood" else "LeafWillow"
        return b, PieceMeta(f"tree_{species}_{size}_crown", "nature", "LeafyGrass", color, "None", 0.0,
                            footprint=[14 * k, 20 * k, 14 * k])

    return trunk, crown


for _sp in ("rustwood", "willow", "pine"):
    for _sz in ("s", "m", "l"):
        _t, _c = make_tree(_sp, _sz)
        reg(f"tree_{_sp}_{_sz}_trunk", _t)
        reg(f"tree_{_sp}_{_sz}_crown", _c)


@piece("bush_a")
def bush_a():
    b = Builder()
    rng = random.Random(1)
    for _ in range(4):
        b.blob(rng.uniform(-1.2, 1.2), rng.uniform(1.0, 1.8), rng.uniform(-1.2, 1.2), 1.4, 1.1, 1.4, rng.randint(0, 999), 0.25, 1)
    return b, PieceMeta("bush_a", "nature", "LeafyGrass", "LeafGreen", "None", 0.0, footprint=[5, 3, 5])


@piece("bush_b")
def bush_b():
    b = Builder()
    rng = random.Random(2)
    for _ in range(6):
        b.blob(rng.uniform(-2, 2), rng.uniform(0.8, 1.4), rng.uniform(-1.4, 1.4), 1.2, 0.9, 1.2, rng.randint(0, 999), 0.3, 1)
    return b, PieceMeta("bush_b", "nature", "LeafyGrass", "LeafRust", "None", 0.0, footprint=[6.5, 2.4, 5])


@piece("grass_clump")
def grass_clump():
    b = Builder()
    rng = random.Random(3)
    for _ in range(14):
        a = rng.uniform(0, 2 * math.pi)
        r = rng.uniform(0, 1.0)
        x, z = math.cos(a) * r, math.sin(a) * r
        h = rng.uniform(1.2, 2.4)
        lean = rng.uniform(-0.5, 0.5)
        b.prism_xy([(x - 0.12, 0), (x + 0.12, 0), (x + lean, h)], z - 0.04, z + 0.04)
    return b, PieceMeta("grass_clump", "nature", "Grass", "GrassTuft", "None", 0.0, footprint=[2.4, 2.4, 2.4])


@piece("reeds")
def reeds():
    b = Builder()
    rng = random.Random(4)
    for _ in range(12):
        x, z = rng.uniform(-1.4, 1.4), rng.uniform(-1.4, 1.4)
        h = rng.uniform(3.5, 6.0)
        b.cyl(x, z, 0.08, 0, h, 4)
        if rng.random() < 0.5:
            b.cyl(x, z, 0.2, h - 1.0, h - 0.2, 5)
    return b, PieceMeta("reeds", "nature", "Grass", "Reed", "None", 0.0, footprint=[3, 6, 3])


@piece("flowers")
def flowers():
    b = Builder()
    rng = random.Random(5)
    for _ in range(9):
        x, z = rng.uniform(-1, 1), rng.uniform(-1, 1)
        h = rng.uniform(0.8, 1.6)
        b.cyl(x, z, 0.06, 0, h, 4)
        b.blob(x, h + 0.15, z, 0.25, 0.18, 0.25, rng.randint(0, 999), 0.1, 0)
    return b, PieceMeta("flowers", "nature", "Fabric", "Flower", "None", 0.0, footprint=[2.3, 1.9, 2.3])


@piece("roots")
def roots():
    b = Builder()
    rng = random.Random(6)
    for i in range(5):
        a = i * 1.25 + rng.uniform(-0.2, 0.2)
        r = rng.uniform(3, 5)
        mid = (math.cos(a) * r * 0.5, 1.4, math.sin(a) * r * 0.5)
        b.beam((0, 0.6, 0), mid, 0.7)
        b.beam(mid, (math.cos(a) * r, -0.3, math.sin(a) * r), 0.45)
    return b, PieceMeta("roots", "nature", "Wood", "Bark", "None", 0.0, footprint=[10, 2, 10])


@piece("log_fallen")
def log_fallen():
    b = Builder()
    b.cyl_x(1.2, 0, 1.2, -7, 7, 9)
    b.beam((2, 1.8, 0), (4, 4.0, 1.0), 0.5)
    return b, PieceMeta("log_fallen", "nature", "Wood", "Bark", "Hull", 0.0, footprint=[14, 4, 2.6])


@piece("stump")
def stump():
    b = Builder()
    b.frustum(0, 0, 1.8, 1.4, 0, 2.2, 9)
    for i in range(4):
        a = i * math.pi / 2 + 0.3
        b.beam((0, 1.0, 0), (math.cos(a) * 2.4, 0, math.sin(a) * 2.4), 0.5)
    return b, PieceMeta("stump", "nature", "Wood", "Bark", "Hull", 0.0, footprint=[5, 2.2, 5])


@piece("mushrooms")
def mushrooms():
    b = Builder()
    rng = random.Random(7)
    for _ in range(5):
        x, z = rng.uniform(-1, 1), rng.uniform(-1, 1)
        h = rng.uniform(0.6, 1.4)
        b.cyl(x, z, 0.15, 0, h, 5)
        b.dome(x, h, z, rng.uniform(0.35, 0.6), 2, 8, 0.35)
    return b, PieceMeta("mushrooms", "nature", "Neon", "Glowcap", "None", 0.0, footprint=[2.6, 1.8, 2.6])


@piece("lily_pads")
def lily_pads():
    b = Builder()
    rng = random.Random(8)
    for _ in range(6):
        x, z = rng.uniform(-3, 3), rng.uniform(-3, 3)
        r = rng.uniform(0.6, 1.1)
        pts = [(x + math.cos(a) * r, z + math.sin(a) * r) for a in [i * math.pi / 5 for i in range(9)]]
        pts.append((x, z))
        b.prism_xz(pts, 0, 0.05)
    return b, PieceMeta("lily_pads", "nature", "Grass", "LeafWillow", "None", 0.0, footprint=[8, 0.05, 8])


for _n, _s in (("s", 1.0), ("m", 2.0), ("l", 3.4)):
    def _crystal(n: str = _n, s: float = _s):
        def build():
            b = Builder()
            rng = random.Random(int(s * 10))
            for i in range(5):
                a = i * 1.3
                tilt_x, tilt_z = math.cos(a) * 1.2 * s, math.sin(a) * 1.2 * s
                h = rng.uniform(3.0, 5.5) * s * (1.4 if i == 0 else 1.0)
                base = (math.cos(a) * 0.4 * s if i else 0, 0, math.sin(a) * 0.4 * s if i else 0)
                tip = (base[0] + (tilt_x if i else 0), h, base[2] + (tilt_z if i else 0))
                b.beam(base, (tip[0] * 0.85, h * 0.8, tip[2] * 0.85), 0.9 * s)
                b.frustum(tip[0] * 0.85, tip[2] * 0.85, 0.55 * s, 0.02, h * 0.8, h, 6)
            m = PieceMeta(f"crystal_{n}", "nature", "Glass", "CrystalTeal", "Hull", 0.0, footprint=[4 * s, 6 * s, 4 * s])
            m.anchors["light"] = [0, 2.5 * s, 0]
            return b, m
        return build
    reg(f"crystal_{_n}", _crystal())


__all__ = ["REGISTRY"]


# ============================================================ AMBIENT LIFE

@piece("fish")
def fish():
    b = Builder()
    b.blob(0, 0, 0, 0.28, 0.32, 0.9, 3, 0.05, 1)
    b.prism_zy([(0.75, 0), (1.35, 0.4), (1.35, -0.4)], -0.04, 0.04)
    return b, PieceMeta("fish", "ambient", "SmoothPlastic", "Steel", "None", 0.0, footprint=[0.6, 0.8, 2.7])


@piece("gull")
def gull():
    b = Builder()
    b.blob(0, 0, 0, 0.35, 0.35, 1.1, 5, 0.05, 1)
    b.blob(0, 0.25, -1.0, 0.25, 0.25, 0.3, 6, 0.0, 0)
    b.prism_xz([(0.2, -0.4), (2.4, 0.1), (2.6, 0.5), (0.2, 0.4)], 0.0, 0.08)
    b.prism_xz([(-0.2, -0.4), (-2.4, 0.1), (-2.6, 0.5), (-0.2, 0.4)], 0.0, 0.08)
    b.prism_zy([(0.9, 0.0), (1.6, 0.15), (1.6, -0.1)], -0.3, 0.3)
    return b, PieceMeta("gull", "ambient", "SmoothPlastic", "Linen", "None", 0.0, footprint=[5.2, 0.7, 3.2])


def make_townsfolk(variant: str):
    def build():
        """Stylised cloaked townsperson used by the client-side ambient walkers."""
        b = Builder()
        if variant == "a":
            b.frustum(0, 0, 1.15, 0.85, 0, 3.6, 10)
            b.frustum(0, 0, 0.85, 0.7, 3.6, 4.4, 10)
            b.blob(0, 4.95, 0, 0.55, 0.62, 0.58, 2, 0.04, 1)
            b.frustum(0, 0.2, 0.62, 0.15, 5.2, 5.9, 8)
        else:
            b.frustum(0, 0, 1.0, 0.8, 0, 2.2, 10)
            b.frustum(0, 0, 0.8, 0.95, 2.2, 4.3, 10)
            b.blob(0, 4.85, 0, 0.5, 0.55, 0.52, 4, 0.04, 1)
            b.box(-0.6, 1.0, -1.05, 0.6, 3.6, -0.85)  # apron
            b.cyl(0, 0, 0.62, 5.15, 5.35, 10)  # cap brim
        b.beam((-0.95, 4.1, 0), (-1.15, 2.4, -0.3), 0.36)
        b.beam((0.95, 4.1, 0), (1.15, 2.4, -0.3), 0.36)
        return b, PieceMeta(f"townsfolk_{variant}", "ambient", "Fabric", "Linen", "None", 0.0, footprint=[2.3, 5.9, 2.3])
    return build


reg("townsfolk_a", make_townsfolk("a"))
reg("townsfolk_b", make_townsfolk("b"))


@piece("tent")
def tent():
    b = Builder()
    b.prism_zy([(-4, 0), (4, 0), (0, 6)], -3.5, 3.5)
    b.prism_zy([(-3.6, 0.01), (3.6, 0.01), (0, 5.4)], -3.6, 3.6, cut=True)
    b.prism_xy([(-1.4, -0.1), (1.4, -0.1), (0, 3.8)], -3.7, -3.4, cut=True)
    return b, PieceMeta("tent", "prop", "Fabric", "Sail", "Hull", 0.0, footprint=[8, 6, 7])


@piece("valve_wheel")
def valve_wheel():
    b = Builder()
    b.ring_z(0, 0, 1.4, 1.75, -0.15, 0.15, 16)
    for i in range(3):
        a = i * math.pi / 3
        b.beam((math.cos(a) * 1.5, math.sin(a) * 1.5, 0), (-math.cos(a) * 1.5, -math.sin(a) * 1.5, 0), 0.22)
    b.cyl_z(0, 0, 0.35, -0.2, 1.4, 8)
    return b, PieceMeta("valve_wheel", "prop", "Metal", "Bronze", "None", 0.0, footprint=[3.5, 3.5, 1.6])


@piece("sluice_gate")
def sluice_gate():
    b = Builder()
    b.box(-6, 0, -0.6, 6, 12, 0.6)
    for y in range(1, 12, 2):
        b.box(-6, y, -0.85, 6, y + 0.4, -0.6)
    for x in (-4, 0, 4):
        b.box(x - 0.3, 0, -0.85, x + 0.3, 12, -0.6)
    return b, PieceMeta("sluice_gate", "landmark", "Metal", "IronRust", "Box", 0.06, footprint=[12, 12, 1.7])
