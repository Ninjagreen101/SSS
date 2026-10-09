# python3 plot_footprints.py <in.json> <out.png> x0 z0 x1 z1 [width] [ring radii, comma-separated]
import json, sys
from PIL import Image, ImageDraw
d = json.load(open(sys.argv[1]))
x0, z0, x1, z1 = [float(v) for v in sys.argv[3:7]]
W = int(sys.argv[7]) if len(sys.argv) > 7 else 1600
rings = [float(r) for r in sys.argv[8].split(",")] if len(sys.argv) > 8 else []
s = W / (x1 - x0)


def hull(points):
    pts = sorted(set(map(tuple, points)))
    if len(pts) <= 2:
        return pts
    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


H = int((z1 - z0) * s)
img = Image.new("RGB", (W, H), (24, 30, 31))
dr = ImageDraw.Draw(img)
col = {"world": (90, 98, 96), "bld": (150, 140, 120), "polish": (90, 160, 200), "court": (240, 120, 60),
       "floor": (52, 60, 60), "visual": (110, 120, 112), "neon": (60, 230, 210), "collide": (235, 110, 60),
       "barrier": (200, 60, 200), "marker": (255, 230, 80), "water": (40, 90, 160)}
order = ["floor", "world", "polish", "bld", "visual", "water", "neon", "collide", "barrier", "marker", "court"]
for k in order:
    for p in d["parts"]:
        if p["k"] != k: continue
        pts = [((x - x0) * s, (z - z0) * s) for x, z in (hull(p["pts"]) if len(p["pts"]) == 8 else p["pts"])]
        if len(pts) < 3: continue
        xs, zs = [px for px, _ in pts], [pz for _, pz in pts]
        if max(xs) < 0 or min(xs) > W or max(zs) < 0 or min(zs) > H: continue
        if k in ("collide", "barrier", "marker"):
            dr.polygon(pts, outline=col[k])
        else:
            dr.polygon(pts, fill=col[k])
for r in rings:
    cx, cz = -x0 * s, -z0 * s
    dr.ellipse([cx - r * s, cz - r * s, cx + r * s, cz + r * s], outline=(255, 255, 255))
for sc in d["scenes"]:
    cx, cz = (sc["x"] - x0) * s, (sc["z"] - z0) * s
    r = 9 * s
    dr.rectangle([cx - r, cz - r, cx + r, cz + r], outline=(255, 210, 80))
    dr.line([cx, cz, cx - sc["lx"] * r * 1.6, cz - sc["lz"] * r * 1.6], fill=(255, 80, 80))  # front = +Z = -LookVector
img.save(sys.argv[2])
