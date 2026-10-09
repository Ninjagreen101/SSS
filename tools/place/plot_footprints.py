import json, sys
from PIL import Image, ImageDraw
d = json.load(open(sys.argv[1]))
x0, z0, x1, z1 = [float(v) for v in sys.argv[3:7]]
W = int(sys.argv[7]) if len(sys.argv) > 7 else 1600
s = W / (x1 - x0)
H = int((z1 - z0) * s)
img = Image.new("RGB", (W, H), (24, 30, 31))
dr = ImageDraw.Draw(img)
col = {"world": (90, 98, 96), "bld": (150, 140, 120), "polish": (90, 160, 200), "court": (240, 120, 60)}
order = ["world", "polish", "bld", "court"]
for k in order:
    for p in d["parts"]:
        if p["k"] != k: continue
        pts = [((x - x0) * s, (z - z0) * s) for x, z in p["pts"]]
        if all(px < 0 or px > W for px, _ in pts) or all(pz < 0 or pz > H for _, pz in pts): continue
        dr.polygon(pts, fill=col[k])
for sc in d["scenes"]:
    cx, cz = (sc["x"] - x0) * s, (sc["z"] - z0) * s
    r = 9 * s
    dr.rectangle([cx - r, cz - r, cx + r, cz + r], outline=(255, 210, 80))
    dr.line([cx, cz, cx - sc["lx"] * r * 1.6, cz - sc["lz"] * r * 1.6], fill=(255, 80, 80))  # front = +Z = -LookVector
img.save(sys.argv[2])
