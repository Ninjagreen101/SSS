"""
Architecture pieces: foundations, walls, timber overlays, corners/pillars,
beams, roofs, stairs, balconies, trims and opening fills.

Conventions (Roblox space):
  * Storey height H = 12, wall thickness 1, panel widths 8/12/16.
  * Wall panels: x in [-w/2, w/2], y in [0, 12], z in [-0.5, 0.5]; -Z faces outward.
  * Origins are at the bottom-centre of the piece's logical footprint.
"""
from __future__ import annotations

import math
import random

from kitlib import Builder, Collider, Opening, PieceMeta, arch_pts

H = 12.0
T = 1.0
WIDTHS = (8, 12, 16)
REGISTRY: dict[str, callable] = {}


def piece(pid: str):
    def deco(fn):
        REGISTRY[pid] = fn
        return fn
    return deco


def reg(pid: str, fn) -> None:
    REGISTRY[pid] = fn


# ----------------------------------------------------------------- openings

def openings_for(kind: str, w: int) -> list[Opening]:
    half = w / 2
    if kind == "window":
        xs = [(-6, -2), (2, 6)] if w == 16 else [(-2, 2)]
        return [Opening("window", a, b, 3.5, 8.5) for a, b in xs]
    if kind == "archwin":
        xs = [(-6, -2), (2, 6)] if w == 16 else [(-2, 2)]
        return [Opening("arch", a, b, 3.5, 8.0) for a, b in xs]
    if kind == "door":
        return [Opening("door", -2.5, 2.5, 0.0, 8.0)]
    if kind == "archdoor":
        return [Opening("archdoor", -3.0, 3.0, 0.0, 8.0)]
    if kind == "shop":
        return [Opening("shop", -(half - 1.5), half - 1.5, 2.5, 9.0)]
    if kind == "damaged":
        return [Opening("breach", -half + 2, half - 1.5, 9.0, 12.0)]
    return []


def _cut_openings(b: Builder, ops: list[Opening]) -> None:
    for o in ops:
        if o.kind in ("arch", "archdoor"):
            r = (o.x1 - o.x0) / 2
            b.prism_xy(arch_pts(o.x0, o.x1, o.y0 - (0.01 if o.y0 <= 0 else 0), o.y1, 10), -1.2, 1.2, cut=True)
        elif o.kind == "breach":
            continue
        else:
            b.box(o.x0, o.y0 - (0.01 if o.y0 <= 0 else 0), -1.2, o.x1, o.y1, 1.2, cut=True)


def _proud_stones(b: Builder, w: float, ops: list[Opening], rng: random.Random, count: int) -> None:
    placed = 0
    tries = 0
    while placed < count and tries < 60:
        tries += 1
        sx = rng.uniform(1.2, 2.2)
        sy = rng.uniform(0.6, 1.0)
        x = rng.uniform(-w / 2 + 1, w / 2 - 1 - sx)
        y = rng.uniform(1.2, 10.4 - sy)
        clash = False
        for o in ops:
            if x + sx > o.x0 - 0.4 and x < o.x1 + 0.4 and y + sy > o.y0 - 0.4 and y < o.y1 + 2.4:
                clash = True
                break
        if clash:
            continue
        b.box(x, y, -0.62, x + sx, y + sy, -0.3)
        placed += 1


def make_wall(kind: str, w: int):
    def build():
        b = Builder()
        half = w / 2
        ops = openings_for(kind, w)
        rng = random.Random(hash((kind, w)) & 0xFFFF)
        if kind == "damaged":
            # jagged broken top edge
            pts = [(-half, 0.0), (half, 0.0), (half, H)]
            x = half
            while x > -half + 2:
                x -= rng.uniform(1.0, 2.5)
                pts.append((max(x, -half + 2), rng.uniform(7.5, 10.5)))
            pts.append((-half + 2, 11.0))
            pts.append((-half, H))
            b.prism_xy(pts, -0.5, 0.5)
            # rubble chunks fallen at the base
            for _ in range(3):
                cx = rng.uniform(-half + 1, half - 1)
                b.blob(cx, 0.4, -1.4, rng.uniform(0.6, 1.1), 0.5, 0.7, rng.randint(0, 9999), 0.25, 0)
            b.box(-1.0, 4.0, -1.2, 0.6, 5.5, 1.2, cut=True)
        else:
            b.box(-half, 0, -0.5, half, H, 0.5)
            # base course and string course (both sides proud by 0.15)
            b.box(-half, 0, -0.65, half, 0.8, 0.65)
            b.box(-half, H - 0.6, -0.6, half, H, 0.6)
            _proud_stones(b, w, ops, rng, 2 + w // 6)
            _cut_openings(b, ops)
        collision = "Box"
        cols: list[Collider] = []
        if kind in ("door", "archdoor", "damaged"):
            # walkable or broken panels: explicit boxes around the opening
            collision = "Colliders"
            for o in ops:
                if o.x0 > -half + 0.05:
                    cols.append(Collider("Box", (-half + o.x0) / 2, H / 2, 0, o.x0 + half, H, 1.0))
                if o.x1 < half - 0.05:
                    cols.append(Collider("Box", (o.x1 + half) / 2, H / 2, 0, half - o.x1, H, 1.0))
                if o.kind == "breach":
                    cols.append(Collider("Box", (o.x0 + o.x1) / 2, o.y0 / 2, 0, o.x1 - o.x0, o.y0, 1.0))
                elif o.y1 < H:
                    cols.append(Collider("Box", (o.x0 + o.x1) / 2, (o.y1 + H) / 2, 0, o.x1 - o.x0, H - o.y1, 1.0))
        meta = PieceMeta(
            id=f"wall_{kind}_w{w}", category="wall", material="Slate", color="Stone",
            collision=collision, bevel=0.08, weather=0.05, colliders=cols, openings=ops, footprint=[w, H, T],
        )
        return b, meta
    return build


for _k in ("plain", "window", "archwin", "door", "archdoor", "shop", "damaged"):
    for _w in WIDTHS:
        reg(f"wall_{_k}_w{_w}", make_wall(_k, _w))


def make_timber(kind: str, w: int):
    """Half-timber frame overlay for plaster walls (sits on the outer face)."""
    def build():
        b = Builder()
        half = w / 2
        ops = [o for o in openings_for(kind, w) if o.kind != "breach"]
        z0, z1 = -0.85, -0.5
        t = 0.7
        b.box(-half, 0.0, z0, half, 0.9, z1)  # sole plate
        b.box(-half, H - 0.8, z0, half, H, z1)  # head plate
        b.box(-half, 0, z0, -half + t, H, z1)  # end posts
        b.box(half - t, 0, z0, half, H, z1)
        # posts flanking openings, rails above and below windows
        spans: list[tuple[float, float]] = []
        cursor = -half + t
        for o in sorted(ops, key=lambda o: o.x0):
            b.box(o.x0 - t, 0, z0, o.x0, H, z1)
            b.box(o.x1, 0, z0, o.x1 + t, H, z1)
            top = o.y1 + ((o.x1 - o.x0) / 2 if o.kind in ("arch", "archdoor") else 0)
            if top < H - 1.4:
                b.box(o.x0, top, z0, o.x1, top + t, z1)
            if o.y0 > 1.2:
                b.box(o.x0, o.y0 - t, z0, o.x1, o.y0, z1)
            spans.append((cursor, o.x0 - t))
            cursor = o.x1 + t
        spans.append((cursor, half - t))
        # mid rail and diagonal braces in solid spans
        for a, c in spans:
            if c - a < 1.0:
                continue
            b.box(a, 5.7, z0, c, 6.3, z1)
            if c - a >= 3.0:
                b.beam((a + 0.3, 0.9, (z0 + z1) / 2), (c - 0.3, 5.7, (z0 + z1) / 2), 0.55)
                b.beam((c - 0.3, 6.3, (z0 + z1) / 2), (a + 0.3, H - 0.8, (z0 + z1) / 2), 0.55)
        meta = PieceMeta(
            id=f"timber_{kind}_w{w}", category="trim", material="Wood", color="Wood",
            collision="None", bevel=0.05, footprint=[w, H, 0.35],
        )
        return b, meta
    return build


for _k in ("plain", "window", "archwin", "door", "shop"):
    for _w in WIDTHS:
        reg(f"timber_{_k}_w{_w}", make_timber(_k, _w))


# -------------------------------------------------------------- foundations

def make_plinth(h: int, w: int):
    def build():
        b = Builder()
        half = w / 2
        b.box(-half, 0, -0.9, half, h, 0.5)
        b.box(-half, h - 0.5, -1.1, half, h, 0.5)  # coping lip
        rng = random.Random(h * 100 + w)
        # rough ashlar blocks on the face
        y = 0.0
        while y < h - 0.6:
            row = min(rng.uniform(1.2, 1.8), h - 0.6 - y)
            x = -half
            off = rng.uniform(0, 1.5)
            x += off
            while x < half - 0.5:
                bw = rng.uniform(1.8, 3.2)
                x1 = min(x + bw, half)
                b.box(x + 0.08, y + 0.08, -1.0, x1 - 0.08, y + row - 0.08, -0.85)
                x = x1
            y += row
        meta = PieceMeta(
            id=f"plinth_h{h}_w{w}", category="foundation", material="Cobblestone", color="StoneShadow",
            collision="Box", bevel=0.1, weather=0.06, footprint=[w, h, 1.4],
        )
        return b, meta
    return build


for _h in (2, 4, 8):
    for _w in WIDTHS:
        reg(f"plinth_h{_h}_w{_w}", make_plinth(_h, _w))


# ---------------------------------------------------- corners, pillars, columns

def make_corner_quoin(h: int):
    def build():
        b = Builder()
        b.box(-0.8, 0, -0.8, 0.8, h, 0.8)
        for i in range(int(h / 2)):
            y = i * 2.0
            if i % 2 == 0:
                b.box(-1.0, y + 0.1, -1.0, 0.9, y + 1.9, 0.0)
            else:
                b.box(-1.0, y + 0.1, -1.0, 0.0, y + 1.9, 0.9)
        return b, PieceMeta(f"corner_quoin_h{h}", "corner", "Limestone", "StoneLight", "Box", 0.08, 0.04, footprint=[1.6, h, 1.6])
    return build


def make_corner_timber(h: int):
    def build():
        b = Builder()
        b.box(-0.7, 0, -0.7, 0.7, h, 0.7)
        for k in range(int(h / 12)):
            top = (k + 1) * 12
            b.box(-0.9, top - 1.0, -0.9, 0.9, top, 0.9)
        return b, PieceMeta(f"corner_timber_h{h}", "corner", "Wood", "Wood", "Box", 0.06, footprint=[1.4, h, 1.4])
    return build


for _h in (12, 24, 36, 48):
    reg(f"corner_quoin_h{_h}", make_corner_quoin(_h))
    reg(f"corner_timber_h{_h}", make_corner_timber(_h))


@piece("pillar_square_h12")
def pillar_square():
    b = Builder()
    b.box(-1.3, 0, -1.3, 1.3, 1.0, 1.3)
    b.box(-1.0, 1.0, -1.0, 1.0, H - 1.0, 1.0)
    b.box(-1.4, H - 1.0, -1.4, 1.4, H, 1.4)
    return b, PieceMeta("pillar_square_h12", "pillar", "Limestone", "StoneLight", "Box", 0.1, 0.03, footprint=[2.8, H, 2.8])


@piece("pillar_round_h12")
def pillar_round():
    b = Builder()
    b.box(-1.3, 0, -1.3, 1.3, 0.8, 1.3)
    b.cyl(0, 0, 1.0, 0.8, H - 0.8, 12)
    b.box(-1.4, H - 0.8, -1.4, 1.4, H, 1.4)
    return b, PieceMeta("pillar_round_h12", "pillar", "Limestone", "StoneLight", "Hull", 0.06, footprint=[2.8, H, 2.8])


@piece("column_h24")
def column():
    b = Builder()
    b.box(-2.2, 0, -2.2, 2.2, 1.2, 2.2)
    b.frustum(0, 0, 1.9, 1.7, 1.2, 2.2, 16)
    b.frustum(0, 0, 1.6, 1.4, 2.2, 21.6, 16)
    b.frustum(0, 0, 1.5, 2.0, 21.6, 22.8, 16)
    b.box(-2.4, 22.8, -2.4, 2.4, 24.0, 2.4)
    # fluting ribs for silhouette
    for i in range(8):
        a = i * math.pi / 4
        x, z = math.cos(a) * 1.55, math.sin(a) * 1.55
        b.cbox(x, 12.0, z, 0.35, 18.8, 0.35)
    return b, PieceMeta("column_h24", "pillar", "Marble", "Marble", "Hull", 0.06, footprint=[4.8, 24, 4.8])


@piece("buttress_h24")
def buttress():
    b = Builder()
    # stepped buttress against a wall at z=0, projecting toward -Z
    b.prism_zy([(0, 0), (-5, 0), (-5, 8), (-3.5, 12), (-3.5, 18), (-1.5, 24), (0, 24)], -1.2, 1.2)
    b.prism_zy([(-5.2, 7.6), (-5.2, 8.2), (-3.4, 12.3), (-3.4, 11.7)], -1.35, 1.35)
    return b, PieceMeta("buttress_h24", "pillar", "Slate", "Stone", "Hull", 0.1, 0.05, footprint=[2.4, 24, 5])


@piece("pilaster_h12")
def pilaster():
    b = Builder()
    b.box(-0.8, 0, -0.45, 0.8, H, 0.0)
    b.box(-1.0, H - 0.9, -0.65, 1.0, H, 0.0)
    b.box(-1.0, 0, -0.65, 1.0, 1.0, 0.0)
    return b, PieceMeta("pilaster_h12", "pillar", "Limestone", "StoneLight", "None", 0.06, footprint=[2, H, 0.65])


# ------------------------------------------------------------ beams / floors

@piece("beam_l8")
def beam_l8():
    b = Builder()
    b.box(-0.6, -1.0, -4, 0.6, 0, 4)
    return b, PieceMeta("beam_l8", "floor", "Wood", "WoodDark", "None", 0.08, stretch="z", footprint=[1.2, 1, 8])


@piece("corbel")
def corbel():
    b = Builder()
    b.prism_zy([(0, 0), (-1.2, 0), (-1.2, -0.4), (-0.3, -1.6), (0, -1.6)], -0.5, 0.5)
    return b, PieceMeta("corbel", "floor", "Wood", "WoodDark", "None", 0.05, footprint=[1, 1.6, 1.2])


# -------------------------------------------------------------------- roofs

PITCH_RUNS = (6, 8, 10, 12, 14, 16)
OVERHANG = 1.5


def make_slope(run: int, length: int):
    def build():
        b = Builder()
        half = length / 2
        e = run + OVERHANG
        # deck: underside line from eave (-e, -OH) to ridge (0, run)
        b.prism_zy([(-e, -OVERHANG), (0, run), (0, run + 0.7), (-e, -OVERHANG + 0.7)], -half, half)
        # shingle courses: small proud lips every 1.5 studs along the slope
        steps = int(e / 1.1)
        for i in range(steps):
            z = -e + i * 1.1
            y = -OVERHANG + (z + e)  # 45 degrees
            b.prism_zy([(z, y + 0.55), (z + 0.9, y + 1.45), (z + 0.9, y + 1.75), (z, y + 0.85)], -half, half)
        # barge board lip at the eave
        b.prism_zy([(-e - 0.2, -OVERHANG - 0.3), (-e + 0.6, -OVERHANG - 0.3), (-e + 0.6, -OVERHANG + 0.9), (-e - 0.2, -OVERHANG + 0.9)], -half, half)
        meta = PieceMeta(
            id=f"roof_slope_r{run}_l{length}", category="roof", material="Slate", color="RoofSlate",
            collision="Hull", bevel=0.04, footprint=[length, run, run],
        )
        return b, meta
    return build


for _r in PITCH_RUNS:
    for _l in (4, 8):
        reg(f"roof_slope_r{_r}_l{_l}", make_slope(_r, _l))


def make_gable(run: int, window: bool):
    def build():
        b = Builder()
        b.prism_xy([(-run, 0), (run, 0), (0, run)], -0.5, 0.5)
        b.prism_xy([(-run - 0.2, -0.4), (run + 0.2, -0.4), (run + 0.2, 0.2), (-run - 0.2, 0.2)], -0.65, 0.65)
        if window and run >= 8:
            cy = run * 0.42
            pts = [(math.cos(a) * 1.25, cy + math.sin(a) * 1.25) for a in [i * math.pi / 6 for i in range(12)]]
            b.prism_xy(pts, -1.2, 1.2, cut=True)
        pid = f"gable_{'win_' if window else ''}r{run}"
        meta = PieceMeta(pid, "roof", "Plaster", "Plaster", "Hull", 0.05, 0.03, footprint=[run * 2, run, 1])
        if window and run >= 8:
            meta.anchors["glow"] = [0, run * 0.42, 0]
        return b, meta
    return build


for _r in PITCH_RUNS:
    reg(f"gable_r{_r}", make_gable(_r, False))
    reg(f"gable_win_r{_r}", make_gable(_r, True))


def make_ridge(length: int):
    def build():
        b = Builder()
        half = length / 2
        b.cyl_x(0.25, 0, 0.55, -half, half, 8)
        for i in range(int(length / 2)):
            x = -half + 1 + i * 2
            b.cyl_x(0.3, 0, 0.66, x - 0.25, x + 0.25, 8)
        return b, PieceMeta(f"roof_ridge_l{length}", "roof", "Slate", "RoofSlateDark", "None", 0.0, footprint=[length, 1, 1])
    return build


for _l in (4, 8):
    reg(f"roof_ridge_l{_l}", make_ridge(_l))


def make_hipcap(run: int):
    def build():
        b = Builder()
        e = run + OVERHANG
        bm = b.bm
        from kitlib import rb
        apex = bm.verts.new(rb(0, run + 0.6, 0))
        c = [
            bm.verts.new(rb(0, -OVERHANG, -e)),
            bm.verts.new(rb(e, -OVERHANG, -e)),
            bm.verts.new(rb(e, -OVERHANG, e)),
            bm.verts.new(rb(0, -OVERHANG, e)),
        ]
        bm.faces.new((c[0], c[1], apex))
        bm.faces.new((c[1], c[2], apex))
        bm.faces.new((c[2], c[3], apex))
        bm.faces.new((c[3], c[0], apex))
        bm.faces.new((c[3], c[2], c[1], c[0]))
        return b, PieceMeta(f"roof_hipcap_r{run}", "roof", "Slate", "RoofSlate", "Hull", 0.04, footprint=[run, run, run * 2])
    return build


for _r in PITCH_RUNS:
    reg(f"roof_hipcap_r{_r}", make_hipcap(_r))


def make_cone(d: int):
    def build():
        b = Builder()
        r = d / 2 + 1.2
        h = d * 1.15
        b.frustum(0, 0, r, r * 0.92, 0, 0.8, 16)
        b.frustum(0, 0, r * 0.92, 0.25, 0.8, h, 16)
        b.cyl(0, 0, 0.3, h - 0.5, h + 3.0, 6)
        b.blob(0, h + 3.2, 0, 0.6, 0.6, 0.6, d, 0.0, 1)
        meta = PieceMeta(f"roof_cone_d{d}", "roof", "Slate", "RoofSlate", "Hull", 0.04, footprint=[d, h, d])
        return b, meta
    return build


for _d in (8, 12, 16, 24):
    reg(f"roof_cone_d{_d}", make_cone(_d))


def make_dome(d: int):
    def build():
        b = Builder()
        r = d / 2 + 0.5
        b.cyl(0, 0, r + 0.4, 0, 1.0, 24)
        b.dome(0, 1.0, 0, r, 6, 24, r * 0.9)
        b.cyl(0, 0, 0.8, r * 0.9 + 0.6, r * 0.9 + 3.5, 8)
        b.frustum(0, 0, 1.2, 0.1, r * 0.9 + 3.5, r * 0.9 + 6.0, 8)
        return b, PieceMeta(f"roof_dome_d{d}", "roof", "Metal", "Verdigris", "Hull", 0.0, footprint=[d, r, d])
    return build


for _d in (16, 24, 32):
    reg(f"roof_dome_d{_d}", make_dome(_d))


@piece("chimney")
def chimney():
    b = Builder()
    b.box(-1.25, 0, -1.25, 1.25, 9, 1.25)
    b.box(-1.5, 8.2, -1.5, 1.5, 8.8, 1.5)
    b.box(-0.5, 8.8, -0.5, 0.5, 10.0, 0.5)
    b.box(-1.0, 8.8, -1.0, -0.3, 9.6, -0.3)
    m = PieceMeta("chimney", "roof", "Brick", "Brick", "Box", 0.06, 0.04, footprint=[2.5, 10, 2.5])
    m.anchors["smoke"] = [0, 10.2, 0]
    return b, m


@piece("roof_dormer")
def dormer():
    b = Builder()
    # front face at z=0 facing -Z, body extends back into a 45 degree roof
    b.box(-2.2, 0, 0, 2.2, 4.2, 4.5)
    b.box(-1.2, 1.0, -0.6, 1.2, 3.4, 1.0, cut=True)
    b.prism_xy([(-2.8, 4.0), (2.8, 4.0), (0, 6.8)], -0.6, 5.0)
    m = PieceMeta("roof_dormer", "roof", "Plaster", "Plaster", "Hull", 0.05, footprint=[4.4, 6.8, 4.5])
    m.anchors["glow"] = [0, 2.2, 0.2]
    return b, m


# ------------------------------------------------------------------- stairs

@piece("stairs_switchback")
def stairs_switchback():
    b = Builder()
    run = 8.0 / 6
    for i in range(6):  # flight 1 rises toward +Z on the right half
        z0 = -6 + i * run
        b.box(0.1, 0, z0, 3.9, (i + 1), z0 + run)
    b.box(-4, 0, 2, 4, 6, 6)  # landing block
    for i in range(6):  # flight 2 rises toward -Z on the left half
        z1 = 2 - i * run
        b.box(-3.9, 6, z1 - run, -0.1, 6 + (i + 1), z1)
    b.box(-0.15, 0, -6, 0.15, 12, 2)  # central spine wall
    cols = [
        Collider("Wedge", 2.0, 3.0, -2.0, 3.8, 6.0, 8.0, 0.0),
        Collider("Box", 0.0, 3.0, 4.0, 8.0, 6.0, 4.0),
        Collider("Wedge", -2.0, 9.0, -2.0, 3.8, 6.0, 8.0, 180.0),
        Collider("Box", 0.0, 6.0, -2.0, 0.3, 12.0, 8.0),
    ]
    return b, PieceMeta("stairs_switchback", "stairs", "WoodPlanks", "Wood", "Colliders", 0.05, colliders=cols, footprint=[8, 12, 12])


@piece("stairs_straight")
def stairs_straight():
    b = Builder()
    n = 12
    for i in range(n):
        b.box(-2, 0, i * 1.0 - 6, 2, i + 1, i * 1.0 - 5)
    for x0, x1 in ((-2.3, -2.0), (2.0, 2.3)):
        b.prism_zy([(-6, 0), (-6, 1.6), (6, 13.0), (6, 11.2), (-4.6, 0)], x0, x1)
    cols = [Collider("Wedge", 0, 6, 0, 4, 12, 12, 0.0)]
    return b, PieceMeta("stairs_straight", "stairs", "WoodPlanks", "Wood", "Colliders", 0.04, colliders=cols, footprint=[4, 12, 12])


@piece("stairs_spiral_h12")
def stairs_spiral():
    b = Builder()
    b.cyl(0, 0, 0.7, 0, 12.5, 10)
    cols = []
    steps = 12
    for i in range(steps):
        a0 = i * (2 * math.pi * 0.9 / steps)
        a1 = a0 + (2 * math.pi * 0.9 / steps)
        y = i + 1.0
        pts = [(math.cos(a0) * 0.6, math.sin(a0) * 0.6), (math.cos(a0) * 4, math.sin(a0) * 4),
               (math.cos(a1) * 4, math.sin(a1) * 4), (math.cos(a1) * 0.6, math.sin(a1) * 0.6)]
        b.prism_xz(pts, y - 0.5, y)
        am = (a0 + a1) / 2
        cx, cz = math.cos(am) * 2.3, math.sin(am) * 2.3
        # yaw so local X points radially
        ry = -math.degrees(am)
        cols.append(Collider("Box", cx, y - 0.5, cz, 3.6, 1.0, 2.2, ry))
    return b, PieceMeta("stairs_spiral_h12", "stairs", "Slate", "Stone", "Colliders", 0.04, colliders=cols, footprint=[8, 12, 8])


def make_steps(w: int):
    def build():
        b = Builder()
        n = 4
        for i in range(n):
            z0 = -4 + i * 2
            b.box(-w / 2, 0, z0, w / 2, i + 1, 4)
        b.box(-w / 2 - 1, 0, -4, -w / 2, 4.6, 4)
        b.box(w / 2, 0, -4, w / 2 + 1, 4.6, 4)
        cols = [Collider("Wedge", 0, 2, 0, w, 4, 8, 0.0)]
        return b, PieceMeta(f"steps_stone_w{w}", "stairs", "Cobblestone", "Stone", "Colliders", 0.08, 0.05, colliders=cols, footprint=[w, 4, 8])
    return build


for _w in (8, 16, 24):
    reg(f"steps_stone_w{_w}", make_steps(_w))


# ---------------------------------------------- balconies, railings, awnings

def make_balcony(w: int):
    def build():
        b = Builder()
        half = w / 2
        b.box(-half, -0.6, -3.5, half, 0, -0.5)
        for x in (-half + 1, half - 1):
            b.prism_zy([(-0.5, 0), (-3, 0), (-0.5, -2.8)], x - 0.35, x + 0.35)
        b.box(-half, 3.2, -3.5, half, 3.6, -3.1)
        b.box(-half, 3.2, -3.5, -half + 0.4, 3.6, -0.5)
        b.box(half - 0.4, 3.2, -3.5, half, 3.6, -0.5)
        n = int(w / 1.0)
        for i in range(n + 1):
            x = -half + 0.2 + i * (w - 0.4) / n
            b.box(x - 0.12, 0, -3.42, x + 0.12, 3.2, -3.18)
        for z in (-2.5, -1.5):
            b.box(-half + 0.08, 0, z - 0.12, -half + 0.32, 3.2, z + 0.12)
            b.box(half - 0.32, 0, z - 0.12, half - 0.08, 3.2, z + 0.12)
        cols = [Collider("Box", 0, -0.3, -2.0, w, 0.6, 3.0), Collider("Box", 0, 2.0, -3.3, w, 4.0, 0.4),
                Collider("Box", -half + 0.2, 2.0, -2.0, 0.4, 4.0, 3.0), Collider("Box", half - 0.2, 2.0, -2.0, 0.4, 4.0, 3.0)]
        return b, PieceMeta(f"balcony_w{w}", "balcony", "Wood", "Wood", "Colliders", 0.04, colliders=cols, footprint=[w, 3.6, 3.5])
    return build


for _w in (8, 12):
    reg(f"balcony_w{_w}", make_balcony(_w))


def make_railing(l: int):
    def build():
        b = Builder()
        half = l / 2
        b.box(-half, 0, -0.4, half, 0.5, 0.4)
        b.box(-half, 3.0, -0.45, half, 3.5, 0.45)
        n = l
        for i in range(n):
            x = -half + 0.5 + i
            b.frustum(x, 0, 0.22, 0.16, 0.5, 1.6, 4)
            b.frustum(x, 0, 0.16, 0.24, 1.6, 3.0, 4)
        cols = [Collider("Box", 0, 1.75, 0, l, 3.5, 0.8)]
        return b, PieceMeta(f"railing_l{l}", "balcony", "Limestone", "StoneLight", "Colliders", 0.05, colliders=cols, footprint=[l, 3.5, 0.9])
    return build


for _l in (4, 8):
    reg(f"railing_l{_l}", make_railing(_l))


def make_awning(w: int):
    def build():
        b = Builder()
        half = w / 2
        b.prism_zy([(-0.5, 9.6), (-4.0, 7.6), (-4.0, 7.3), (-0.5, 9.3)], -half, half)
        n = int(w / 2)
        for i in range(n):
            x = -half + i * 2 + 1
            b.prism_xy([(x - 1, 7.6), (x + 1, 7.6), (x, 6.9)], -4.05, -3.85)
        for x in (-half + 0.3, half - 0.3):
            b.beam((x, 9.4, -0.5), (x, 7.4, -3.9), 0.18)
        return b, PieceMeta(f"awning_w{w}", "balcony", "Fabric", "ClothRed", "None", 0.0, footprint=[w, 2.8, 4])
    return build


for _w in (8, 12, 16):
    reg(f"awning_w{_w}", make_awning(_w))


@piece("banner_tall")
def banner_tall():
    b = Builder()
    b.cyl_x(0, 0, 0.18, -1.7, 1.7, 6)
    b.prism_xy([(-1.3, 0), (1.3, 0), (1.3, -7.0), (0, -6.0), (-1.3, -7.0)], -0.08, 0.08)
    return b, PieceMeta("banner_tall", "balcony", "Fabric", "ClothTeal", "None", 0.0, footprint=[3.4, 7, 0.4])


@piece("banner_wall")
def banner_wall():
    b = Builder()
    b.cyl_x(0, -0.8, 0.15, -1.4, 1.4, 6)
    b.prism_xy([(-1.1, 0), (1.1, 0), (1.1, -4.5), (0, -5.3), (-1.1, -4.5)], -0.88, -0.72)
    return b, PieceMeta("banner_wall", "balcony", "Fabric", "ClothNavy", "None", 0.0, footprint=[2.8, 5.3, 1])


@piece("sign_board")
def sign_board():
    b = Builder()
    b.box(-1.6, -2.0, -0.12, 1.6, 0, 0.12)
    b.box(-1.75, -0.25, -0.18, 1.75, 0.05, 0.18)
    return b, PieceMeta("sign_board", "balcony", "Wood", "WoodLight", "None", 0.04, footprint=[3.5, 2, 0.4])


@piece("sign_bracket")
def sign_bracket():
    b = Builder()
    b.box(-0.3, -0.6, -0.1, 0.3, 0.6, 0.1)
    b.box(-0.08, 0.1, -3.4, 0.08, 0.3, 0)
    b.beam((0, -0.5, -0.05), (0, 0.15, -2.2), 0.12)
    m = PieceMeta("sign_bracket", "balcony", "Metal", "Iron", "None", 0.0, footprint=[0.6, 1.2, 3.4])
    m.anchors["hang"] = [0, 0.1, -2.6]
    return b, m


# -------------------------------------------------------------------- trims

def make_cornice(l: int):
    def build():
        b = Builder()
        half = l / 2
        b.prism_zy([(0.5, 0), (-0.7, 0), (-0.7, 0.35), (-1.0, 0.6), (-1.0, 1.0), (0.5, 1.0)], -half, half)
        return b, PieceMeta(f"cornice_l{l}", "trim", "Limestone", "StoneLight", "None", 0.03, footprint=[l, 1, 1.5])
    return build


def make_runeband(l: int):
    def build():
        b = Builder()
        half = l / 2
        x = -half
        i = 0
        while x < half - 0.1:
            seg = 1.6 if i % 3 else 0.6
            x1 = min(x + seg, half)
            b.box(x + 0.1, 0, -0.62, x1 - 0.1, 0.35, -0.48)
            x = x1
            i += 1
        return b, PieceMeta(f"runeband_l{l}", "trim", "Neon", "CurrentTeal", "None", 0.0, footprint=[l, 0.35, 0.14])
    return build


for _l in WIDTHS:
    reg(f"cornice_l{_l}", make_cornice(_l))
    reg(f"runeband_l{_l}", make_runeband(_l))


def _frame_rect(b: Builder, w: float, h: float, sill: bool) -> None:
    t = 0.45
    b.box(-w / 2 - t, 0, -0.75, -w / 2, h, 0.75)
    b.box(w / 2, 0, -0.75, w / 2 + t, h, 0.75)
    b.box(-w / 2 - t - 0.2, h, -0.85, w / 2 + t + 0.2, h + 0.55, 0.75)
    if sill:
        b.box(-w / 2 - 0.4, -0.35, -1.05, w / 2 + 0.4, 0, 0.7)


def _frame_arch(b: Builder, w: float, spring: float, sill: bool) -> None:
    t = 0.45
    r = w / 2
    b.box(-r - t, 0, -0.75, -r, spring, 0.75)
    b.box(r, 0, -0.75, r + t, spring, 0.75)
    seg = 9
    for i in range(seg):
        a0 = math.pi * i / seg
        a1 = math.pi * (i + 1) / seg
        p0 = (math.cos(a0) * (r + t / 2), spring + math.sin(a0) * (r + t / 2), 0)
        p1 = (math.cos(a1) * (r + t / 2), spring + math.sin(a1) * (r + t / 2), 0)
        b.beam(p0, p1, t * 1.05)
    b.box(-0.35, spring + r - 0.1, -0.85, 0.35, spring + r + 0.9, 0.8)  # keystone
    if sill:
        b.box(-r - 0.4, -0.35, -1.05, r + 0.4, 0, 0.7)


def make_frame(kind: str, w: int = 0):
    def build():
        b = Builder()
        if kind == "window":
            _frame_rect(b, 4, 5, True)
            b.box(-0.12, 0, -0.1, 0.12, 5, 0.1)
            b.box(-2, 2.38, -0.1, 2, 2.62, 0.1)
            pid = "frame_window"
        elif kind == "arch":
            _frame_arch(b, 4, 4.5, True)
            b.box(-0.12, 0, -0.1, 0.12, 6.5, 0.1)
            pid = "frame_archwin"
        elif kind == "door":
            _frame_rect(b, 5, 8, False)
            pid = "frame_door"
        elif kind == "archdoor":
            _frame_arch(b, 6, 8, False)
            pid = "frame_archdoor"
        else:
            ow = w - 3
            _frame_rect(b, ow, 6.5, True)
            n = max(1, int(ow / 3))
            for i in range(1, n):
                x = -ow / 2 + i * ow / n
                b.box(x - 0.12, 0, -0.1, x + 0.12, 6.5, 0.1)
            b.box(-ow / 2, 4.6, -0.1, ow / 2, 4.8, 0.1)
            pid = f"frame_shop_w{w}"
        return b, PieceMeta(pid, "trim", "Wood", "WoodDark", "None", 0.03, footprint=[w or 6, 8, 1.5])
    return build


reg("frame_window", make_frame("window"))
reg("frame_archwin", make_frame("arch"))
reg("frame_door", make_frame("door"))
reg("frame_archdoor", make_frame("archdoor"))
for _w in WIDTHS:
    reg(f"frame_shop_w{_w}", make_frame("shop", _w))


def make_pane(kind: str, w: int = 0):
    def build():
        b = Builder()
        if kind == "window":
            b.box(-2, 0, -0.08, 2, 5, 0.08)
            pid = "pane_window"
        elif kind == "arch":
            b.prism_xy(arch_pts(-2, 2, 0, 4.5, 10), -0.08, 0.08)
            pid = "pane_archwin"
        else:
            ow = w - 3
            b.box(-ow / 2, 0, -0.08, ow / 2, 6.5, 0.08)
            pid = f"pane_shop_w{w}"
        return b, PieceMeta(pid, "trim", "Glass", "Glass", "None", 0.0, footprint=[w or 4, 6.5, 0.16])
    return build


reg("pane_window", make_pane("window"))
reg("pane_archwin", make_pane("arch"))
for _w in WIDTHS:
    reg(f"pane_shop_w{_w}", make_pane("shop", _w))


@piece("door_leaf")
def door_leaf():
    b = Builder()
    # hinge at x = 0, leaf spans +X
    for i in range(5):
        b.box(i * 1.0 + 0.03, 0, -0.18, i * 1.0 + 0.97, 7.95, 0.18)
    for y in (1.2, 6.6):
        b.box(0.1, y, -0.28, 4.6, y + 0.35, -0.18)
    b.cyl_z(4.2, 4.0, 0.25, -0.45, -0.18, 8)
    return b, PieceMeta("door_leaf", "trim", "Wood", "WoodDoor", "None", 0.03, footprint=[5, 8, 0.4])


@piece("door_leaf_arch")
def door_leaf_arch():
    b = Builder()
    b.prism_xy([(x + 3, y) for x, y in arch_pts(-3, 3, 0, 8, 10)], -0.2, 0.2)
    for y in (1.5, 7.0):
        b.box(0.2, y, -0.3, 5.8, y + 0.4, -0.2)
    b.cyl_z(5.2, 4.2, 0.3, -0.5, -0.2, 8)
    return b, PieceMeta("door_leaf_arch", "trim", "Wood", "WoodDoor", "None", 0.03, footprint=[6, 11, 0.4])


@piece("eave_bracket")
def eave_bracket():
    b = Builder()
    b.prism_zy([(0, 0), (-1.6, 0), (-1.6, -0.5), (-0.4, -1.8), (0, -1.8)], -0.3, 0.3)
    return b, PieceMeta("eave_bracket", "trim", "Wood", "WoodDark", "None", 0.04, footprint=[0.6, 1.8, 1.6])


@piece("moss_patch")
def moss_patch():
    b = Builder()
    b.blob(0, 0.08, 0, 1.6, 0.12, 1.1, 7, 0.35, 1)
    return b, PieceMeta("moss_patch", "trim", "Grass", "Moss", "None", 0.0, footprint=[3.2, 0.2, 2.2])


@piece("puddle")
def puddle():
    b = Builder()
    pts = []
    rng = random.Random(3)
    for i in range(12):
        a = i * math.pi / 6
        r = rng.uniform(1.6, 2.4)
        pts.append((math.cos(a) * r * 1.3, math.sin(a) * r))
    b.prism_xz(pts, 0.0, 0.06)
    return b, PieceMeta("puddle", "trim", "Glass", "Puddle", "None", 0.0, footprint=[6, 0.06, 5])
