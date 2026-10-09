# Paints assets/map/floor1_map.png from the samples render_map.luau wrote.
#   python3 render_map.py <map_samples.bin> <map_layout.json> <out.png>
# Image x = world X, image y = world Z (north = -Z at the top), the whole 3000 x 3000 floor.
import json
import math
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

samples_path, layout_path, out_path = sys.argv[1:4]
L = json.load(open(layout_path))
N = L["size"]
WORLD = L["world"]
SS = 2  # overlay supersampling
M = N * SS
SCALE = M / WORLD  # overlay pixels per stud

raw = np.frombuffer(open(samples_path, "rb").read(), dtype=np.uint8).reshape(N, N, 5).astype(np.float64)
height = (raw[:, :, 0] + raw[:, :, 1] * 256) / L["heightScale"] - L["heightBias"]
region = raw[:, :, 2].astype(np.int32)
surface = raw[:, :, 3].astype(np.int32)
water = raw[:, :, 4] > 0.5
REG = {name: i + 1 for i, name in enumerate(L["regions"])}
SURF = {"Canal": 1, "Plaza": 2, "Avenue": 3, "Street": 4, "Quay": 5, "Lot": 6}
step = WORLD / N


def rgb(r, g, b):
    return np.array([r, g, b], dtype=np.float64)


def lerp(a, b, t):
    return a + (b - a) * np.clip(t, 0, 1)[..., None]


# BASE COLOUR ------------------------------------------------------------------------------
img = np.zeros((N, N, 3))
hn = np.clip(height / 170.0, 0, 1)
palette = {
    "Downs": (rgb(86, 92, 68), rgb(132, 134, 108)),  # grey-olive, lighter with height
    "RustwoodForest": (rgb(52, 60, 32), rgb(118, 80, 42)),  # dark rust-green
    "TidepoolMarsh": (rgb(62, 78, 46), rgb(88, 92, 56)),  # muddy green
    "OldWharf": (rgb(128, 112, 80), rgb(150, 130, 92)),  # sandy shelf
    "Cistern": (rgb(66, 76, 82), rgb(96, 104, 108)),  # drowned slate
    "FirstGate": (rgb(136, 132, 118), rgb(168, 162, 142)),  # pale paved plateau
    "Harbour": (rgb(70, 86, 80), rgb(90, 104, 94)),  # shore rock just above water
    "Town": (rgb(104, 102, 96), rgb(140, 136, 124)),
}
for name, (lo, hi) in palette.items():
    mask = region == REG[name]
    if name == "TidepoolMarsh":
        tt = height / 8.0
    elif name in ("RustwoodForest", "Downs"):
        tt = (height - 108) / 62.0
    else:
        tt = hn
    img[mask] = lerp(lo, hi, tt)[mask]

# a little low-frequency mottling so big regions are not flat
rng = np.random.default_rng(11)
blot = rng.normal(size=(N // 16, N // 16))
blot = np.array(Image.fromarray(blot.astype(np.float32)).resize((N, N), Image.BICUBIC))
img *= (1.0 + 0.07 * blot)[..., None]

# town surfaces
town = region == REG["Town"]
terrace_t = np.clip((height - 6) / 96.0, 0, 1)
surf_colors = {
    "Lot": (rgb(96, 94, 88), rgb(128, 124, 112)),
    "Street": (rgb(150, 142, 124), rgb(172, 162, 138)),
    "Avenue": (rgb(176, 164, 136), rgb(198, 184, 148)),
    "Plaza": (rgb(172, 162, 140), rgb(190, 178, 150)),
    "Quay": (rgb(138, 134, 122), rgb(138, 134, 122)),
}
for name, (lo, hi) in surf_colors.items():
    mask = (surface == SURF[name]) & town
    img[mask] = lerp(lo, hi, terrace_t)[mask]

# water: depth-shaded teal-black sea, brighter Current teal in the canals, murky marsh pools
depth = np.clip(-height / 22.0, 0, 1)
sea = water & (region == REG["Harbour"])
img[sea] = lerp(rgb(34, 92, 92), rgb(6, 20, 26), depth)[sea]
canal = water & (surface == SURF["Canal"])
img[canal] = rgb(64, 176, 170)
pools = water & ~sea & ~canal
img[pools] = lerp(rgb(52, 84, 70), rgb(24, 46, 44), depth)[pools]

# HILLSHADE --------------------------------------------------------------------------------
gx = np.gradient(height, axis=1) / step
gz = np.gradient(height, axis=0) / step
EXAG = np.where(region == REG["Town"], 2.2, 6.0)
nx, ny, nz = -gx * EXAG, np.ones_like(height), -gz * EXAG
nlen = np.sqrt(nx * nx + ny * ny + nz * nz)
light = np.array([-0.55, 0.75, -0.55])  # from the north-west, up
light /= np.linalg.norm(light)
shade = (nx * light[0] + ny * light[1] + nz * light[2]) / nlen
flat = light[1]
factor = 0.80 + 0.85 * (shade - flat)
factor = np.clip(factor, 0.45, 1.45)
land_factor = np.where(water, 1.0 + 0.25 * (factor - 1.0), factor)
img *= land_factor[..., None]

# region borders: a faint darker seam so the biomes read
edge = np.zeros((N, N), dtype=bool)
edge[:, :-1] |= region[:, :-1] != region[:, 1:]
edge[:-1, :] |= region[:-1, :] != region[1:, :]
edge &= ~(water & (region == REG["Harbour"]))
img[edge] *= 0.82

# faint contour lines on the wild highlands
wild = (region != REG["Town"]) & ~water
contour = np.zeros((N, N), dtype=bool)
band_i = np.floor(height / 14.0)
contour[:, :-1] |= band_i[:, :-1] != band_i[:, 1:]
contour[:-1, :] |= band_i[:-1, :] != band_i[1:, :]
contour &= wild & (height > 12)
img[contour] *= 0.9

img = np.clip(img, 0, 255)
base = Image.fromarray(img.astype(np.uint8), "RGB").resize((M, M), Image.BICUBIC)
over = base.convert("RGBA")
draw = ImageDraw.Draw(over, "RGBA")


def px(x, z):
    return ((x + WORLD / 2) * SCALE, (z + WORLD / 2) * SCALE)


bay = (L["bay"]["x"], L["bay"]["z"])


def polar(r, a):
    return (bay[0] + math.cos(a) * r, bay[1] + math.sin(a) * r)


def arc_points(r, a0, a1, n=96):
    return [px(*polar(r, a0 + (a1 - a0) * i / n)) for i in range(n + 1)]


INK = (24, 17, 10, 255)
OCHRE = (222, 196, 128, 255)
TA = L["townAngle"]

# ROADS OUTSIDE TOWN
for road in L["roads"]:
    pts = [px(p["x"], p["z"]) for p in road["points"]]
    draw.line(pts, fill=(34, 26, 16, 150), width=int(road["width"] * SCALE) + 3, joint="curve")
    draw.line(pts, fill=(168, 148, 104, 235), width=max(2, int(road["width"] * SCALE)), joint="curve")

# BREAKWATERS
for arm in L["breakwaters"]:
    a, b = px(arm[0]["x"], arm[0]["z"]), px(arm[1]["x"], arm[1]["z"])
    draw.line([a, b], fill=(30, 28, 24, 255), width=int(36 * SCALE) + 3)
    draw.line([a, b], fill=(112, 112, 102, 255), width=int(30 * SCALE))

# TOWN: terrace walls as thin dark arcs, ring streets, quay, Climb, spokes, canals
for band in L["bands"]:
    draw.line(arc_points(band["r0"], -TA, TA), fill=(20, 16, 12, 200), width=3)
draw.line(arc_points(L["townOuter"], -TA, TA), fill=(20, 16, 12, 220), width=4)
for band in L["bands"]:
    w = max(2, int(20 * SCALE))
    draw.line(arc_points(band["street"], -TA, TA), fill=(176, 164, 136, 255), width=w, joint="curve")
for a in [L["climb"]["angle"]] + L["spokes"]:
    wid = L["climb"]["width"] if a == L["climb"]["angle"] else L["spokeWidth"]
    p0, p1 = px(*polar(L["quayRadius"] + 10, a)), px(*polar(L["townOuter"] - 8, a))
    draw.line([p0, p1], fill=(26, 20, 14, 230), width=int(wid * SCALE) + 4)
    draw.line([p0, p1], fill=(214, 198, 158, 255), width=max(3, int(wid * SCALE)))
    # step ticks where the avenue climbs each terrace wall
    for band in L["bands"][1:]:
        for k in range(4):
            t = band["r0"] + 6 + k * 9
            x, z = polar(t, a)
            cx, cz = px(x, z)
            nx_, nz_ = -math.sin(a), math.cos(a)
            hw = wid * SCALE * 0.5
            draw.line([(cx - nx_ * hw, cz - nz_ * hw), (cx + nx_ * hw, cz + nz_ * hw)], fill=(120, 106, 80, 255), width=2)
for a in L["canals"]:
    p0, p1 = px(*polar(L["quayRadius"], a)), px(*polar(L["canalEnd"], a))
    wid = int(L["canalWidth"] * SCALE)
    draw.line([p0, p1], fill=(14, 40, 44, 255), width=wid + 5)
    draw.line([p0, p1], fill=(72, 196, 190, 255), width=wid)
    draw.line([p0, p1], fill=(170, 240, 232, 150), width=max(1, wid // 4))
    # waterfalls at each terrace wall
    for band in L["bands"][1:]:
        x, z = polar(band["r0"], a)
        cx, cz = px(x, z)
        nx_, nz_ = -math.sin(a), math.cos(a)
        hw = wid * 0.9
        draw.line([(cx - nx_ * hw, cz - nz_ * hw), (cx + nx_ * hw, cz + nz_ * hw)], fill=(220, 250, 244, 255), width=3)
# the quay edge
draw.line(arc_points(L["quayRadius"], -TA, TA), fill=(210, 190, 140, 255), width=4)
# the plaza
pc = px(L["plaza"]["center"]["x"], L["plaza"]["center"]["z"])
pr = L["plaza"]["size"] / 2 * SCALE
draw.ellipse([pc[0] - pr, pc[1] - pr, pc[0] + pr, pc[1] + pr], fill=(196, 182, 148, 120), outline=(238, 220, 168, 255), width=3)
fr = 9 * SCALE
draw.ellipse([pc[0] - fr, pc[1] - fr, pc[0] + fr, pc[1] + fr], fill=(72, 196, 190, 255), outline=INK, width=2)

# the First Gate plateau and the Cistern basin: faint rings under their glyphs
gate = px(L["points"]["FirstGate"]["x"], L["points"]["FirstGate"]["z"])
gr = L["gate"]["radius"] * SCALE
draw.ellipse([gate[0] - gr, gate[1] - gr, gate[0] + gr, gate[1] + gr], outline=(226, 206, 150, 160), width=3)
cis = px(L["points"]["Cistern"]["x"], L["points"]["Cistern"]["z"])
cr = L["cistern"]["radius"] * SCALE
draw.ellipse([cis[0] - cr, cis[1] - cr, cis[0] + cr, cis[1] + cr], outline=(150, 190, 200, 200), width=3)

# GLYPHS -----------------------------------------------------------------------------------
G = 20 * SS  # glyph half-size in overlay pixels


def halo(c):
    r = G * 1.45
    draw.ellipse([c[0] - r, c[1] - r, c[0] + r, c[1] + r], fill=(14, 10, 6, 120))


def glyph_guild(c):  # a keep: block with three merlons and a door
    x, y = c
    draw.rectangle([x - G * 0.8, y - G * 0.4, x + G * 0.8, y + G * 0.8], fill=OCHRE, outline=INK, width=3)
    for dx in (-0.8, -0.1, 0.55):
        draw.rectangle([x + G * dx, y - G * 0.85, x + G * (dx + 0.25), y - G * 0.4], fill=OCHRE, outline=INK, width=3)
    draw.rectangle([x - G * 0.2, y + G * 0.15, x + G * 0.2, y + G * 0.8], fill=INK)


def glyph_cathedral(c):  # a Latin cross
    x, y = c
    t = G * 0.32
    draw.polygon([(x - t, y - G), (x + t, y - G), (x + t, y - G * 0.35), (x + G * 0.7, y - G * 0.35), (x + G * 0.7, y + G * 0.05),
                  (x + t, y + G * 0.05), (x + t, y + G), (x - t, y + G), (x - t, y + G * 0.05), (x - G * 0.7, y + G * 0.05),
                  (x - G * 0.7, y - G * 0.35), (x - t, y - G * 0.35)], fill=OCHRE, outline=INK)
    draw.line([(x - t, y - G), (x + t, y - G), (x + t, y - G * 0.35), (x + G * 0.7, y - G * 0.35), (x + G * 0.7, y + G * 0.05),
               (x + t, y + G * 0.05), (x + t, y + G), (x - t, y + G), (x - t, y + G * 0.05), (x - G * 0.7, y + G * 0.05),
               (x - G * 0.7, y - G * 0.35), (x - t, y - G * 0.35), (x - t, y - G)], fill=INK, width=3)


def glyph_rotunda(c):  # a domed drum: ring with a dome dot
    x, y = c
    draw.ellipse([x - G * 0.9, y - G * 0.9, x + G * 0.9, y + G * 0.9], fill=OCHRE, outline=INK, width=3)
    draw.ellipse([x - G * 0.5, y - G * 0.5, x + G * 0.5, y + G * 0.5], fill=(150, 126, 76, 255), outline=INK, width=3)
    draw.ellipse([x - G * 0.16, y - G * 0.16, x + G * 0.16, y + G * 0.16], fill=INK)


def glyph_lighthouse(c):  # a tapering tower with a lamp
    x, y = c
    draw.polygon([(x - G * 0.5, y + G), (x + G * 0.5, y + G), (x + G * 0.28, y - G * 0.5), (x - G * 0.28, y - G * 0.5)], fill=OCHRE, outline=INK)
    draw.line([(x - G * 0.5, y + G), (x + G * 0.5, y + G), (x + G * 0.28, y - G * 0.5), (x - G * 0.28, y - G * 0.5), (x - G * 0.5, y + G)], fill=INK, width=3)
    draw.rectangle([x - G * 0.38, y - G * 0.95, x + G * 0.38, y - G * 0.5], fill=(255, 238, 170, 255), outline=INK, width=3)
    for s in (-1, 1):
        draw.line([(x + s * G * 0.5, y - G * 0.72), (x + s * G * 1.1, y - G * 0.95)], fill=(255, 238, 170, 255), width=3)


def glyph_gate(c):  # an arch gate: two pillars and an arched lintel
    x, y = c
    pw = G * 0.34
    for s in (-1, 1):
        draw.rectangle([x + s * G * 0.62 - pw / 2, y - G * 0.2, x + s * G * 0.62 + pw / 2, y + G], fill=OCHRE, outline=INK, width=3)
    draw.pieslice([x - G * 0.95, y - G * 1.0, x + G * 0.95, y + G * 0.8], 180, 360, fill=OCHRE, outline=INK, width=3)
    draw.pieslice([x - G * 0.45, y - G * 0.45, x + G * 0.45, y + G * 0.45], 180, 360, fill=(20, 16, 12, 255))
    draw.rectangle([x - G * 0.45, y - G * 0.02, x + G * 0.45, y + G], fill=(20, 16, 12, 255))


def glyph_cistern(c):  # a well: rings around dark water
    x, y = c
    draw.ellipse([x - G * 0.9, y - G * 0.9, x + G * 0.9, y + G * 0.9], fill=OCHRE, outline=INK, width=3)
    draw.ellipse([x - G * 0.55, y - G * 0.55, x + G * 0.55, y + G * 0.55], fill=(30, 74, 78, 255), outline=INK, width=3)
    for dy in (-0.15, 0.2):
        draw.arc([x - G * 0.34, y + G * dy - G * 0.12, x + G * 0.34, y + G * dy + G * 0.12], 0, 180, fill=(120, 214, 208, 255), width=2)


lm = L["landmarks"]
glyphs = [
    (px(lm["ClimbersGuild"]["x"], lm["ClimbersGuild"]["z"]), glyph_guild),
    (px(lm["Cathedral"]["x"], lm["Cathedral"]["z"]), glyph_cathedral),
    (px(lm["AttunementShrine"]["x"], lm["AttunementShrine"]["z"]), glyph_rotunda),
    (px(L["points"]["Lighthouse"]["x"], L["points"]["Lighthouse"]["z"]), glyph_lighthouse),
    (gate, glyph_gate),
    (cis, glyph_cistern),
]
for c, fn in glyphs:
    halo(c)
for c, fn in glyphs:
    fn(c)

# FINISH: down-sample, then the parchment-dark vignette, frame and paper grain --------------
out = over.convert("RGB").resize((N, N), Image.LANCZOS)
arr = np.asarray(out).astype(np.float64)
yy, xx = np.mgrid[0:N, 0:N]
d = np.sqrt(((xx - N / 2) / (N / 2)) ** 2 + ((yy - N / 2) / (N / 2)) ** 2) / math.sqrt(2) * 1.35
t = np.clip((d - 0.55) / 0.5, 0, 1)
t = t * t * (3 - 2 * t)
parch = np.array([34, 24, 14], dtype=np.float64)
arr = arr * (1 - 0.55 * t)[..., None] + parch * (0.55 * t)[..., None]
arr *= 1.0 + 0.025 * rng.normal(size=(N, N))[..., None]  # paper grain
final = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")
fd = ImageDraw.Draw(final)
fd.rectangle([0, 0, N - 1, N - 1], outline=(20, 14, 8), width=6)
fd.rectangle([9, 9, N - 10, N - 10], outline=(122, 98, 58), width=2)
final.save(out_path)
print("rendered", out_path, final.size)
