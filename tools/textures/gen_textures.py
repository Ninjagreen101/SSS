"""
Generates the original, seamless Current water textures referenced by
src/ReplicatedStorage/Shared/Data/AssetManifest.lua.

    python tools/textures/gen_textures.py      (needs numpy + pillow)

assets/textures/current_flow.png   512x512 tileable flowing ripples (canal surface)
assets/textures/current_falls.png  256x512 tileable vertical streaks (waterfalls)
Both are white-on-transparent so Roblox tints them with Texture.Color3.
"""
from __future__ import annotations

import os

import numpy as np
from PIL import Image

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "textures")


def tileable_noise(w: int, h: int, octaves: int, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    acc = np.zeros((h, w))
    amp = 1.0
    for o in range(octaves):
        f = 2 ** (o + 2)
        grid = rng.random((f, f))
        ys = np.linspace(0, f, h, endpoint=False)
        xs = np.linspace(0, f, w, endpoint=False)
        x0 = np.floor(xs).astype(int)
        y0 = np.floor(ys).astype(int)
        tx = xs - x0
        ty = ys - y0
        tx = tx * tx * (3 - 2 * tx)
        ty = ty * ty * (3 - 2 * ty)
        x1 = (x0 + 1) % f
        y1 = (y0 + 1) % f
        a = grid[np.ix_(y0, x0)]
        b = grid[np.ix_(y0, x1)]
        c = grid[np.ix_(y1, x0)]
        d = grid[np.ix_(y1, x1)]
        top = a + (b - a) * tx[None, :]
        bot = c + (d - c) * tx[None, :]
        acc += (top + (bot - top) * ty[:, None]) * amp
        amp *= 0.5
    acc -= acc.min()
    return acc / acc.max()


def flow() -> Image.Image:
    w = h = 512
    n = tileable_noise(w, h, 5, 7)
    yy, xx = np.mgrid[0:h, 0:w] / w
    warp = n * 2.4
    ripples = np.sin((yy * 6 + warp) * 2 * np.pi) * 0.5 + 0.5
    ridges = np.clip(1 - np.abs(ripples - 0.5) * 6, 0, 1) ** 2
    caustic = np.clip(1 - np.abs(np.sin((xx * 4 + n * 1.5) * 2 * np.pi)) * 3, 0, 1) ** 3
    alpha = np.clip(ridges * 0.8 + caustic * 0.5, 0, 1)
    rgba = np.zeros((h, w, 4), dtype=np.uint8)
    rgba[..., :3] = 255
    rgba[..., 3] = (alpha * 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def falls() -> Image.Image:
    w, h = 256, 512
    n = tileable_noise(w, h, 4, 11)
    yy, xx = np.mgrid[0:h, 0:w]
    cols = tileable_noise(w, 8, 4, 13)[0]
    streak = np.clip((cols[None, :] - 0.45) * 3, 0, 1)
    breakup = np.clip(n * 1.6 - 0.3, 0, 1)
    alpha = np.clip(streak * breakup + n * 0.15, 0, 1)
    rgba = np.zeros((h, w, 4), dtype=np.uint8)
    rgba[..., :3] = 255
    rgba[..., 3] = (alpha * 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    flow().save(os.path.join(OUT, "current_flow.png"))
    falls().save(os.path.join(OUT, "current_falls.png"))
    print("textures written to", os.path.abspath(OUT))
