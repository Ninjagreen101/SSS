"""
Generates original, seamless PBR texture sets (SurfaceAppearance) for the hero kit.

    /tmp/claude-0/bpyenv/bin/python tools/textures/gen_pbr.py      (needs numpy + pillow)

Writes assets/textures/pbr/<set>_{color,normal,roughness,metalness}.png, 512x512.
 - color:     sRGB albedo
 - normal:    tangent-space, OpenGL style (+Y up / green = up), flat = (128,128,255)
 - roughness: grayscale, white = rough
 - metalness: grayscale, white = metal
Kit UVs are world-scale box projection, 1 UV = 8 studs, so one tile = 8x8 studs
(64 px per stud). All noise is periodic, all seeds fixed: output is deterministic
and tiles seamlessly on both axes.
"""
from __future__ import annotations

import os
import sys

import numpy as np
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "textures", "pbr")
N = 512


# --------------------------------------------------------------------------- helpers

def hexrgb(h: str) -> np.ndarray:
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float64) / 255.0


def vnoise(seed: int, fy: int, fx: int, octaves: int = 1, persistence: float = 0.5) -> np.ndarray:
    """Periodic value noise, 0..1. (fy, fx) = base lattice cells per tile; doubles per octave."""
    rng = np.random.default_rng(seed)
    acc = np.zeros((N, N))
    amp = 1.0
    for o in range(octaves):
        gy, gx = fy * 2 ** o, fx * 2 ** o
        grid = rng.random((gy, gx))
        ys = np.linspace(0, gy, N, endpoint=False)
        xs = np.linspace(0, gx, N, endpoint=False)
        y0 = np.floor(ys).astype(int)
        x0 = np.floor(xs).astype(int)
        ty = ys - y0
        tx = xs - x0
        ty = ty * ty * (3 - 2 * ty)
        tx = tx * tx * (3 - 2 * tx)
        y1 = (y0 + 1) % gy
        x1 = (x0 + 1) % gx
        a = grid[np.ix_(y0, x0)]
        b = grid[np.ix_(y0, x1)]
        c = grid[np.ix_(y1, x0)]
        d = grid[np.ix_(y1, x1)]
        top = a + (b - a) * tx[None, :]
        bot = c + (d - c) * tx[None, :]
        acc += (top + (bot - top) * ty[:, None]) * amp
        amp *= persistence
    acc -= acc.min()
    return acc / acc.max()


def smooth(e0: float, e1: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def blur(a: np.ndarray, sigma: float) -> np.ndarray:
    """Periodic gaussian blur via FFT."""
    f = np.fft.fftfreq(N)
    k = np.exp(-2 * (np.pi * sigma) ** 2 * (f[:, None] ** 2 + f[None, :] ** 2))
    return np.real(np.fft.ifft2(np.fft.fft2(a) * k))


def norm01(a: np.ndarray) -> np.ndarray:
    a = a - a.min()
    return a / max(a.max(), 1e-9)


def partition(rng, total: int, n: int, jitter: float) -> np.ndarray:
    w = 1 + (rng.random(n) - 0.5) * jitter
    e = np.concatenate([[0], np.round(np.cumsum(w / w.sum() * total))]).astype(int)
    e[-1] = total
    return e


def normal_from_height(h: np.ndarray, strength: float) -> np.ndarray:
    """Periodic Sobel -> OpenGL tangent-space normal map (uint8 RGB)."""
    def r(dy, dx):
        return np.roll(np.roll(h, dy, 0), dx, 1)
    # image x -> +U (right); image row index grows downward
    gx = (r(-1, -1) * -1 + r(-1, 1) * 1 + r(0, -1) * -2 + r(0, 1) * 2 + r(1, -1) * -1 + r(1, 1) * 1) / 8.0
    gr = (r(-1, -1) * -1 + r(1, -1) * 1 + r(-1, 0) * -2 + r(1, 0) * 2 + r(-1, 1) * -1 + r(1, 1) * 1) / 8.0
    nx = -gx * strength
    ny = gr * strength  # +Y up: up = decreasing row index, so dh/dup = -gr, ny = -dh/dup = gr
    nz = np.ones_like(h)
    ln = np.sqrt(nx * nx + ny * ny + nz * nz)
    out = np.stack([nx / ln, ny / ln, nz / ln], -1) * 0.5 + 0.5
    return np.round(out * 255).astype(np.uint8)


def fit_mean(color: np.ndarray, base: np.ndarray, weight: np.ndarray | None = None) -> np.ndarray:
    """Scale per channel so the (weighted) mean equals base."""
    if weight is None:
        weight = np.ones(color.shape[:2])
    m = (color * weight[..., None]).sum((0, 1)) / weight.sum()
    return np.clip(color * (base / m), 0, 1)


def mix(a, b, t):
    t = np.asarray(t)
    a = np.asarray(a)
    if t.ndim == 2 and (a.ndim == 3 or np.ndim(b) == 3):
        t = t[..., None]
    return a + (b - a) * t


def gray8(a: np.ndarray) -> np.ndarray:
    return np.round(np.clip(a, 0, 1) * 255).astype(np.uint8)


def tint_jitter(rng, amount: float) -> np.ndarray:
    return 1 + (rng.random(3) - 0.5) * 2 * amount


def finish(name, color, height, rough, metal, nstrength):
    return name, gray8(color), normal_from_height(height, nstrength), gray8(rough), gray8(metal)


def brick_layout(rng, row_edges, per_row, jitter, stagger=True):
    """Returns per-pixel arrays: dl, dr (px to tile left/right edge), yin (px below row top),
    rowh, tile id, row index. Rows wrap periodically in x with a random offset per row."""
    dl = np.zeros((N, N)); dr = np.zeros((N, N)); yin = np.zeros((N, N))
    rowh = np.zeros((N, N)); tid = np.zeros((N, N), dtype=int); rid = np.zeros((N, N), dtype=int)
    cnt = 0
    xs_all = np.arange(N)
    for r in range(len(row_edges) - 1):
        y0, y1 = row_edges[r], row_edges[r + 1]
        nb = per_row[r] if hasattr(per_row, "__len__") else per_row
        e = partition(rng, N, nb, jitter)
        off = int(rng.integers(0, N))
        xs = (xs_all - off) % N
        b = np.searchsorted(e, xs, side="right") - 1
        dl[y0:y1] = (xs - e[b])[None, :]
        dr[y0:y1] = (e[b + 1] - xs)[None, :]
        yin[y0:y1] = (np.arange(y0, y1) - y0)[:, None]
        rowh[y0:y1] = y1 - y0
        tid[y0:y1] = (b + cnt)[None, :]
        rid[y0:y1] = r
        cnt += nb
    return dl, dr, yin, rowh, tid, rid, cnt


# --------------------------------------------------------------------------- sets

def ashlar_stone():
    base = hexrgb("#6E6A63"); mortar_c = hexrgb("#2B2A28"); moss_c = hexrgb("#4C5A36")
    rng = np.random.default_rng(101)
    row_edges = partition(rng, N, 8, 0.45)
    dl, dr, yin, rowh, tid, rid, cnt = brick_layout(rng, row_edges, 4, 0.7)
    dtop = yin; dbot = rowh - 1 - yin
    d = np.minimum(np.minimum(dl, dr), np.minimum(dtop, dbot))
    tone = (0.84 + rng.random(cnt) * 0.32)[tid]
    tints = np.stack([tint_jitter(rng, 0.045) for _ in range(cnt)])[tid]
    bofs = (rng.random(cnt) - 0.5)[tid]

    fine = vnoise(102, 96, 96, 3)
    mid = vnoise(103, 8, 8, 4)
    chipn = vnoise(104, 48, 48, 2)
    chipn2 = vnoise(105, 20, 20, 3)
    drip = vnoise(106, 2, 28, 3)

    de = d + (chipn - 0.5) * 11 + (vnoise(107, 14, 14, 2) - 0.5) * 6
    mw = 4.5
    mortar = 1 - smooth(mw - 1.5, mw + 1.5, de)
    bev = smooth(mw, mw + 12, de)
    chip = smooth(0.62, 0.74, chipn2) * (1 - smooth(14, 26, de)) * (1 - mortar)

    moss_n = vnoise(108, 6, 6, 4)
    moss = np.clip(smooth(0.56, 0.78, moss_n) * (mortar + 0.45 * (1 - bev) * (1 - mortar)), 0, 1)

    lum = tone * (0.86 + 0.28 * mid) * (0.9 + 0.2 * fine) * (0.78 + 0.22 * bev)
    lum *= 1 - 0.28 * smooth(0.55, 0.9, drip) * (1 - mortar)
    col = base * lum[..., None] * tints
    col = mix(col, col * 1.28 * np.array([1.03, 1.0, 0.94]), chip * 0.8)
    mcol = mortar_c * (0.8 + 0.5 * vnoise(109, 64, 64, 3))[..., None]
    col = mix(col, mcol, mortar)
    col = mix(col, moss_c * (0.75 + 0.5 * fine)[..., None], moss * 0.5)
    col = fit_mean(col, base, (1 - mortar) * (1 - moss))

    h = 0.15 + 0.5 * bev + 0.22 * fine + 0.1 * mid + bofs * 0.06
    h = mix(h[..., None], (0.02 + 0.1 * fine)[..., None], mortar)[..., 0]
    h = h - 0.22 * chip + 0.05 * moss * fine
    rough = 0.85 + 0.12 * (fine - 0.5) + 0.04 * mortar - 0.0 * chip
    rough = mix(rough, 0.95, moss * 0.6)
    return finish("ashlar_stone", col, h, rough, np.zeros((N, N)), 14)


def plaster():
    base = hexrgb("#BDB4A2")
    grain = vnoise(201, 128, 128, 3)
    blotch = vnoise(202, 5, 5, 4)
    trowel = vnoise(203, 12, 12, 3)
    # cracks: thin level-set of warped low-freq noise
    warp = (vnoise(204, 6, 6, 3) - 0.5) * 0.12
    c1 = np.abs(vnoise(205, 3, 3, 4) + warp - 0.5)
    c2 = np.abs(vnoise(206, 4, 4, 4) + warp - 0.5)
    mask = vnoise(207, 4, 4, 2)
    crack = np.maximum(1 - smooth(0.0, 0.012, c1), 1 - smooth(0.0, 0.009, c2) * 1.0)
    crack *= smooth(0.45, 0.65, mask)
    crack = blur(crack, 0.6)
    crack = np.clip(crack * 1.6, 0, 1)
    # stains: damp bloom + vertical runoff
    stain = smooth(0.52, 0.8, vnoise(208, 4, 4, 4))
    runoff = smooth(0.5, 0.85, vnoise(209, 2, 26, 3)) * smooth(0.35, 0.7, vnoise(210, 3, 3, 2))
    stain_tot = np.clip(stain * 0.6 + runoff * 0.7, 0, 1)

    lum = (0.9 + 0.2 * blotch) * (0.94 + 0.12 * grain) * (0.97 + 0.06 * trowel)
    col = base * lum[..., None]
    col = mix(col, col * np.array([0.72, 0.68, 0.6]), stain_tot * 0.8)
    col = mix(col, hexrgb("#3A3530"), crack * 0.75)
    col = fit_mean(col, base)

    h = 0.5 * trowel + 0.35 * grain + 0.25 * blotch - 0.6 * crack
    rough = 0.9 + 0.08 * (grain - 0.5) - 0.04 * stain_tot + 0.04 * crack
    return finish("plaster", col, h, rough, np.zeros((N, N)), 10)


def timber():
    base = hexrgb("#4A3426")
    rng = np.random.default_rng(301)
    nplank = 8
    pe = partition(rng, N, nplank, 0.0)
    plank = np.zeros((N, N), dtype=int); yin = np.zeros((N, N)); ph = np.zeros((N, N))
    for i in range(nplank):
        plank[pe[i]:pe[i + 1]] = i
        yin[pe[i]:pe[i + 1]] = (np.arange(pe[i], pe[i + 1]) - pe[i])[:, None]
        ph[pe[i]:pe[i + 1]] = pe[i + 1] - pe[i]
    ptone = (0.82 + rng.random(nplank) * 0.36)[plank]
    pshift = rng.random(nplank)[plank]
    ptint = np.stack([tint_jitter(rng, 0.05) for _ in range(nplank)])[plank]

    yy, xx = np.mgrid[0:N, 0:N].astype(np.float64)
    # knots: periodic radial distortion of ring pattern
    rings_warp = np.zeros((N, N))
    knots = []
    for _ in range(5):
        kx, ky = rng.random() * N, rng.random() * N
        r = 14 + rng.random() * 14
        dx = (xx - kx + N / 2) % N - N / 2
        dy = ((yy - ky + N / 2) % N - N / 2) * 2.2
        dist = np.sqrt(dx * dx + dy * dy)
        rings_warp += np.exp(-(dist / r) ** 2) * (3 + 4 * rng.random())
        knots.append(np.exp(-(dist / (r * 0.45)) ** 2))
    knot = np.clip(sum(knots), 0, 1)

    g1 = vnoise(302, 70, 3, 3)          # long fibres along U
    g2 = vnoise(303, 160, 4, 2)         # fine pores
    wob = (vnoise(304, 14, 2, 3) - 0.5) * 2.4
    ringcoord = (yy / 64.0) * 6 + wob + rings_warp + pshift * 10
    ring = 0.5 + 0.5 * np.sin(ringcoord * 2 * np.pi)
    ring = ring ** 1.5
    split = np.abs(vnoise(305, 90, 3, 2) - 0.5)
    check = (1 - smooth(0.0, 0.006, split)) * smooth(0.55, 0.75, vnoise(306, 3, 3, 2))
    edge = np.minimum(yin, ph - 1 - yin)
    gap = 1 - smooth(1.5, 4.0, edge + (vnoise(307, 24, 4, 2) - 0.5) * 2)
    bevel = smooth(2.0, 9.0, edge)

    lum = ptone * (0.72 + 0.28 * ring) * (0.88 + 0.24 * g1) * (0.92 + 0.16 * g2)
    lum *= 1 - 0.45 * knot
    lum *= 0.82 + 0.18 * bevel
    col = base * lum[..., None] * ptint
    col = mix(col, hexrgb("#16100C"), np.clip(check * 0.8 + gap, 0, 1))
    col = fit_mean(col, base)

    h = 0.35 * (1 - ring) + 0.3 * g1 + 0.12 * g2 + 0.35 * bevel - 0.4 * check - 0.9 * gap + 0.15 * knot
    rough = 0.75 + 0.1 * (g2 - 0.5) + 0.08 * (ring - 0.5) + 0.1 * gap + 0.05 * check
    return finish("timber", col, h, rough, np.zeros((N, N)), 9)


def slate_roof():
    base = hexrgb("#474B53")
    rng = np.random.default_rng(401)
    row_edges = partition(rng, N, 8, 0.0)  # 64 px = 1 stud rows
    dl, dr, yin, rowh, tid, rid, cnt = brick_layout(rng, row_edges, 10, 0.3)
    jag = (vnoise(402, 40, 40, 2) - 0.5) * 3
    side = np.minimum(dl, dr) + jag
    t = yin / rowh
    tone = (0.8 + rng.random(cnt) * 0.4)[tid]
    tints = np.stack([tint_jitter(rng, 0.06) * np.array([1.0, 1.0, 1.04]) for _ in range(cnt)])[tid]
    tilt = ((rng.random(cnt) - 0.5) * 0.12)[tid]
    xc = np.minimum(dl, dr) / 26.0

    layers = vnoise(403, 10, 5, 4)
    fine = vnoise(404, 96, 96, 3)
    pit = smooth(0.7, 0.85, vnoise(405, 40, 40, 2))
    gap = 1 - smooth(1.0, 3.0, side)
    lipcurve = 0.25 + 0.6 * t ** 1.4
    h = lipcurve + tilt * (1 - xc.clip(0, 1)) + 0.1 * layers + 0.05 * fine - 0.5 * gap - 0.08 * pit
    # sharp underlap shadow just below each row's lip
    ao = 0.45 + 0.55 * smooth(0.0, 14.0, yin)
    lipedge = smooth(rowh - 5, rowh - 1, yin)   # bright worn lip edge

    lum = tone * (0.85 + 0.3 * layers) * (0.92 + 0.16 * fine) * ao
    lum *= 1 + 0.18 * lipedge
    col = base * lum[..., None] * tints
    col = mix(col, hexrgb("#17181B"), gap * 0.85)
    col = mix(col, col * 1.2, pit * 0.5)
    col = fit_mean(col, base)

    rough = 0.6 + ((rng.random(cnt) - 0.5) * 0.14)[tid] + 0.08 * (fine - 0.5) + 0.3 * gap - 0.06 * lipedge
    return finish("slate_roof", col, h, rough, np.zeros((N, N)), 14)


def clay_roof():
    base = hexrgb("#7A4A3A")
    rng = np.random.default_rng(501)
    ncol, tw = 8, 64
    row_edges = partition(rng, N, 8, 0.0)
    yy, xx = np.mgrid[0:N, 0:N]
    rid = np.zeros((N, N), dtype=int); yin = np.zeros((N, N)); rowh = np.zeros((N, N))
    for r in range(8):
        y0, y1 = row_edges[r], row_edges[r + 1]
        rid[y0:y1] = r; yin[y0:y1] = (np.arange(y0, y1) - y0)[:, None]; rowh[y0:y1] = y1 - y0
    stag = np.where(rid % 2 == 1, tw // 2, 0)
    xs = (xx + stag) % N
    col_i = xs // tw
    u = (xs % tw + 0.5) / tw
    tid = rid * ncol + col_i
    tone = (0.78 + rng.random(8 * ncol) * 0.44)[tid]
    tints = np.stack([tint_jitter(rng, 0.06) * np.array([1.0, 0.97, 0.95]) for _ in range(8 * ncol)])[tid]
    t = yin / rowh

    curve = np.sin(np.pi * u) ** 0.8
    seam = 1 - smooth(0.0, 0.1, np.minimum(u, 1 - u))
    fine = vnoise(502, 96, 96, 3)
    mott = vnoise(503, 12, 12, 4)
    soot = smooth(0.55, 0.85, vnoise(504, 5, 5, 4))
    ao = 0.45 + 0.55 * smooth(0.0, 12.0, yin)
    lip = smooth(rowh - 6, rowh - 1, yin)

    h = 0.1 + 0.55 * curve * (0.7 + 0.3 * t) + 0.22 * t ** 1.5 + 0.06 * fine - 0.25 * seam
    lum = tone * (0.84 + 0.32 * mott) * (0.92 + 0.16 * fine) * ao * (0.78 + 0.22 * curve)
    lum *= 1 - 0.22 * seam
    lum *= 1 + 0.12 * lip
    col = base * lum[..., None] * tints
    col = mix(col, col * np.array([0.55, 0.55, 0.55]), soot * 0.55)
    col = mix(col, hexrgb("#8A8574"), smooth(0.8, 0.95, vnoise(505, 30, 30, 3)) * 0.35)  # lichen flecks
    col = fit_mean(col, base)

    rough = 0.7 + ((rng.random(8 * ncol) - 0.5) * 0.1)[tid] + 0.1 * (fine - 0.5) + 0.08 * soot - 0.05 * lip
    return finish("clay_roof", col, h, rough, np.zeros((N, N)), 12)


def bronze():
    base = hexrgb("#7D6234"); verd = hexrgb("#4E7E72")
    hammer = vnoise(601, 20, 20, 3)
    fine = vnoise(602, 128, 128, 3)
    dents = smooth(0.45, 0.65, vnoise(603, 26, 26, 1))
    big = vnoise(604, 5, 5, 4)
    pits = smooth(0.78, 0.9, vnoise(605, 64, 64, 2))
    h = 0.4 * hammer + 0.15 * fine + 0.15 * big - 0.12 * dents
    # verdigris collects in recesses
    recess = 1 - norm01(blur(h, 1.5))
    patch = vnoise(606, 8, 8, 4)
    v = smooth(0.62, 0.86, recess * 0.6 + patch * 0.55 + (pits * 0.3))
    v = np.clip(v, 0, 1)
    crust = vnoise(607, 90, 90, 3)
    lum = (0.8 + 0.4 * big) * (0.9 + 0.2 * hammer) * (0.94 + 0.12 * fine)
    col = base * lum[..., None]
    vc = verd * (0.78 + 0.44 * crust)[..., None]
    col = mix(col, vc, v)
    col = mix(col, hexrgb("#E0B766") * 0.8, smooth(0.78, 0.95, hammer) * 0.25 * (1 - v))  # worn highlights
    col = fit_mean(col, base, (1 - v) + 1e-3)
    h = h + 0.18 * v * crust
    rough = 0.45 + 0.1 * (fine - 0.5) + 0.2 * (1 - hammer) * (1 - v) * 0.5
    rough = mix(rough, 0.7 + 0.08 * (crust - 0.5), v)
    metal = mix(0.85 + 0.05 * (fine - 0.5), 0.1 + 0.05 * crust, v)
    return finish("bronze", col, h, np.clip(rough, 0.45, 0.72), metal, 10)


def iron():
    base = hexrgb("#3A3B3D"); rust_c = hexrgb("#5C4232")
    forge = vnoise(701, 4, 22, 3)        # drawn-out forging streaks along U
    hammer = vnoise(702, 18, 18, 3)
    fine = vnoise(703, 128, 128, 3)
    scale = smooth(0.5, 0.75, vnoise(704, 9, 9, 3))
    # rust speckle: high-freq threshold gated by low-freq mask
    spk = vnoise(705, 110, 110, 2)
    gate = vnoise(706, 5, 5, 4)
    rust = smooth(0.68, 0.8, spk) * smooth(0.25, 0.6, gate)
    rust = np.clip(rust + 0.55 * smooth(0.68, 0.85, vnoise(707, 7, 7, 4)) * smooth(0.4, 0.7, vnoise(708, 24, 24, 2)), 0, 1)
    rust = blur(rust, 0.5)
    rust = np.clip(rust * 1.5, 0, 1)

    lum = (0.8 + 0.4 * hammer) * (0.88 + 0.24 * forge) * (0.92 + 0.16 * fine) * (1 - 0.18 * scale)
    col = base * lum[..., None]
    rc = rust_c * (0.7 + 0.6 * vnoise(709, 60, 60, 3))[..., None]
    col = mix(col, rc, rust)
    col = fit_mean(col, base, (1 - rust) + 1e-3)

    h = 0.4 * hammer + 0.25 * forge + 0.1 * fine - 0.1 * scale + 0.2 * rust * fine
    rough = 0.5 + 0.12 * (fine - 0.5) + 0.1 * scale
    rough = mix(rough, 0.85, rust)
    metal = mix(0.8 + 0.05 * (hammer - 0.5), 0.2, rust)
    return finish("iron", col, h, rough, metal, 9)


SETS = [ashlar_stone, plaster, timber, slate_roof, clay_roof, bronze, iron]


# --------------------------------------------------------------------------- driver

def seam_report(name, color):
    c = color.astype(np.float64)
    out = []
    for axis in (1, 0):
        a = np.moveaxis(c, axis, 0)  # axis index first
        wrap = np.abs(a[0] - a[-1]).mean()
        adj = np.abs(a[1:] - a[:-1]).mean(axis=tuple(range(1, a.ndim)))
        out.append((wrap, adj[1:-1].mean()))
    return out


def preview(colors, path):
    cell, tile = 256, 128
    cols = 4
    rows = (len(colors) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell, rows * cell), (20, 20, 20))
    d = ImageDraw.Draw(sheet)
    for i, (name, arr) in enumerate(colors):
        t = Image.fromarray(arr).resize((tile, tile), Image.LANCZOS)
        cx, cy = (i % cols) * cell, (i // cols) * cell
        for ty in range(2):
            for tx in range(2):
                sheet.paste(t, (cx + tx * tile, cy + ty * tile))
        d.text((cx + 4, cy + 4), name, fill=(255, 255, 255))
    sheet.save(path)


def main():
    os.makedirs(OUT, exist_ok=True)
    colors, count = [], 0
    for fn in SETS:
        name, col, nrm, rough, metal = fn()
        Image.fromarray(col, "RGB").save(os.path.join(OUT, f"{name}_color.png"))
        Image.fromarray(nrm, "RGB").save(os.path.join(OUT, f"{name}_normal.png"))
        Image.fromarray(rough, "L").save(os.path.join(OUT, f"{name}_roughness.png"))
        Image.fromarray(metal, "L").save(os.path.join(OUT, f"{name}_metalness.png"))
        count += 4
        colors.append((name, col))
        (cw, ca), (rw, ra) = seam_report(name, col)
        mean = col.reshape(-1, 3).mean(0).round().astype(int)
        print(f"{name:13s} mean RGB {tuple(mean)}  col wrap {cw:5.2f} vs adj {ca:5.2f} | row wrap {rw:5.2f} vs adj {ra:5.2f}")
    print(f"wrote {count} files to {os.path.normpath(OUT)}")
    if len(sys.argv) > 1:
        preview(colors, sys.argv[1])
        print("preview ->", sys.argv[1])


if __name__ == "__main__":
    main()
