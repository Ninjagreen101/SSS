#!/usr/bin/env python3
"""Synthesize the original zone ambience loops for The Spire.

Writes assets/audio/ambience_<Name>.ogg (44.1 kHz stereo Vorbis, 40 s,
seamlessly loopable, peak about -3 dBFS after decoding). Everything is generated from noise,
filters, envelopes and oscillators; no samples are used.

Seamless looping is built in rather than patched on afterwards: all noise is
shaped in the frequency domain (circular), slow modulators are circular noise
or whole-cycle sines, oscillators sit on whole cycles per loop, one-shot events
wrap around the loop end and reverb is a circular convolution. The last sample
therefore flows straight into the first one. The loop point is then rotated onto
the smoothest sample with matching head/tail level, so the wrap is inaudible.

Run:  python tools/audio/gen_ambience.py [Name ...]
Needs numpy, scipy and soundfile.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import lfilter

SR = 44100
DUR = 40
N = SR * DUR
PEAK_DB = -3.0
OUT_DIR = Path(__file__).resolve().parents[2] / "assets" / "audio"
FREQS = np.fft.rfftfreq(N, 1.0 / SR)
T = np.arange(N) / SR


# ---------------------------------------------------------------- primitives
def white(rng):
    return rng.standard_normal(N)


def unit(x):
    return x / (np.sqrt(np.mean(x * x)) + 1e-12)


def shape(x, lo=None, hi=None, order=2):
    """Circular zero-phase Butterworth-style band shaping via the FFT."""
    X = np.fft.rfft(x)
    H = np.ones_like(FREQS)
    if hi:
        H /= np.sqrt(1.0 + (FREQS / hi) ** (2 * order))
    if lo:
        f = np.maximum(FREQS, 1e-9)
        H /= np.sqrt(1.0 + (lo / f) ** (2 * order))
    X = X * H
    X[0] = 0.0
    return np.fft.irfft(X, N)


def noise(rng, lo=None, hi=None, order=2):
    """Unit-RMS band-limited noise."""
    return unit(shape(white(rng), lo, hi, order))


def bed(rng, lo=None, hi=None, order=2):
    """Stereo (2, N) decorrelated band-limited noise."""
    return np.stack([noise(rng, lo, hi, order), noise(rng, lo, hi, order)])


def env(rng, cutoff, depth):
    """Slow positive modulator with mean 1 (circular)."""
    g = noise(rng, None, cutoff, 2)
    e = np.exp(depth * np.clip(g, -2.5, 2.5))
    return e / e.mean()


def lfo(cycles, phase=0.0):
    """Sine with a whole number of cycles per loop."""
    return np.sin(2 * np.pi * cycles * T / DUR + phase)


def qf(f):
    """Quantize a frequency to a whole number of cycles per loop."""
    return max(1, round(f * DUR)) / DUR


def tone(f_inst, phase0=0.0):
    """Oscillator from an instantaneous-frequency array, phase closed over the loop."""
    ph = 2 * np.pi * (np.cumsum(f_inst) - f_inst) / SR
    total = 2 * np.pi * np.sum(f_inst) / SR
    ph -= (total - 2 * np.pi * round(total / (2 * np.pi))) * np.arange(N) / N
    return np.sin(ph + phase0)


def pan_gains(pan):
    a = (pan + 1.0) * np.pi / 4.0
    return np.cos(a), np.sin(a)


def place(buf, start, sig, pan=0.0, gain=1.0):
    """Add an event at `start` samples, wrapping past the loop end."""
    idx = (int(start) + np.arange(len(sig))) % N
    gl, gr = pan_gains(pan)
    buf[0, idx] += gl * gain * sig
    buf[1, idx] += gr * gain * sig


def ev_times(rng, count, margin=0.0):
    return np.sort(rng.uniform(margin, DUR - margin, count)) * SR


def reverb(buf, rng, rt=1.5, wet=0.6, dry=0.5, predelay=0.012, damp=0.35):
    """Circular convolution with an exponentially decaying noise impulse."""
    n_ir = int(rt * SR)
    t = np.arange(n_ir) / SR
    out = np.zeros_like(buf)
    for c in range(2):
        ir = rng.standard_normal(n_ir) * np.exp(-6.91 * t / rt)
        ir = lfilter([damp], [1.0, -(1.0 - damp)], ir)  # darker tail
        ir /= np.sqrt(np.sum(ir * ir))
        full = np.zeros(N)
        pd = int(predelay * SR)
        full[pd:pd + n_ir] = ir
        out[c] = np.fft.irfft(np.fft.rfft(buf[c]) * np.fft.rfft(full), N)
    return dry * buf + wet * out


# ---------------------------------------------------------------- one-shots
def tick(rng, f, dur, tau):
    n = int(dur * SR)
    t = np.arange(n) / SR
    s = np.sin(2 * np.pi * f * t) * np.exp(-t / tau)
    s[: int(0.0006 * SR)] *= np.linspace(0, 1, int(0.0006 * SR))
    return s


def drip(rng, f0):
    n = int(0.3 * SR)
    t = np.arange(n) / SR
    f = f0 * (1.0 + 0.6 * (1.0 - np.exp(-t / 0.03)))
    ph = 2 * np.pi * np.cumsum(f) / SR
    s = np.sin(ph) * np.exp(-t / 0.045)
    s += 0.25 * np.sin(2 * ph) * np.exp(-t / 0.02)
    s[:40] *= np.linspace(0, 1, 40)
    return s


def creak(rng, fc, dur, q=0.996):
    """Stick-slip impulses through a resonator: a short wood/rope creak."""
    n = int(dur * SR)
    exc = np.zeros(n)
    pos, rate = 0, rng.uniform(35, 70)
    while pos < n:
        exc[pos] = rng.uniform(0.5, 1.0)
        rate = np.clip(rate + rng.normal(0, 4), 25, 90)
        pos += max(1, int(SR / rate * rng.uniform(0.8, 1.2)))
    exc += 0.08 * rng.standard_normal(n)
    out = np.zeros(n)
    for mult, g in ((1.0, 1.0), (1.63, 0.5), (2.4, 0.25)):
        w = 2 * np.pi * fc * mult / SR
        out += g * lfilter([1 - q], [1.0, -2 * q * np.cos(w), q * q], exc)
    t = np.arange(n) / SR
    e = np.sin(np.pi * t / dur) ** 2 * (1.0 + 0.4 * np.sin(2 * np.pi * rng.uniform(3, 7) * t))
    out *= e
    return out / (np.max(np.abs(out)) + 1e-9)


def gull(rng, f0=1500.0, dur=0.55):
    n = int(dur * SR)
    t = np.arange(n) / SR
    u = t / dur
    f = f0 * (0.8 + 0.9 * np.sin(np.pi * np.minimum(u * 1.3, 1.0)) ** 0.8 - 0.25 * u)
    f *= 1.0 + 0.03 * np.sin(2 * np.pi * 26 * t)
    ph = 2 * np.pi * np.cumsum(f) / SR
    s = np.sin(ph) + 0.45 * np.sin(2 * ph) + 0.2 * np.sin(3 * ph)
    s *= np.minimum(t / 0.05, 1.0) * np.exp(-2.4 * u)
    return s / np.max(np.abs(s))


def chirp(rng, f0, f1, dur):
    n = int(dur * SR)
    t = np.arange(n) / SR
    f = f0 + (f1 - f0) * (t / dur) ** 0.8
    ph = 2 * np.pi * np.cumsum(f) / SR
    s = np.sin(ph) + 0.15 * np.sin(2 * ph)
    return s * np.sin(np.pi * t / dur) ** 2


def frog(rng, f0=130.0, dur=0.28):
    n = int(dur * SR)
    t = np.arange(n) / SR
    f = f0 * (1.15 - 0.3 * t / dur)
    ph = 2 * np.pi * np.cumsum(f) / SR
    s = np.zeros(n)
    for h in range(1, 14):
        centre = 520.0
        s += np.exp(-(((h * f0) - centre) / 420.0) ** 2) * np.sin(h * ph) / h ** 0.3
    pulses = 0.5 + 0.5 * np.sin(2 * np.pi * 34 * t - 1.2)
    s *= pulses ** 1.5 * np.sin(np.pi * t / dur) ** 0.7
    return s / np.max(np.abs(s))


def clink(rng, f0):
    n = int(0.9 * SR)
    t = np.arange(n) / SR
    s = np.zeros(n)
    for ratio, g, tau in ((1.0, 1.0, 0.30), (2.76, 0.6, 0.18), (5.4, 0.4, 0.10), (8.93, 0.25, 0.05)):
        s += g * np.sin(2 * np.pi * f0 * ratio * t + rng.uniform(0, 6.28)) * np.exp(-t / tau)
    s[:30] *= np.linspace(0, 1, 30)
    return s / np.max(np.abs(s))


# ---------------------------------------------------------------- shared textures
def wind(rng, lo, hi, gust_cut=0.12, depth=0.6, order=2):
    return bed(rng, lo, hi, order) * np.stack([env(rng, gust_cut, depth), env(rng, gust_cut, depth)])


def sub_rumble(rng, hi=90.0):
    return bed(rng, 18, hi, 3) * np.stack([env(rng, 0.2, 0.5), env(rng, 0.2, 0.5)])


# ---------------------------------------------------------------- zones
def town_rain(rng):
    out = np.zeros((2, N))
    for c in range(2):
        hiss = noise(rng, 1500, 9500) * env(rng, 220, 0.35)
        body = noise(rng, 250, 1400) * env(rng, 40, 0.3)
        out[c] += 0.55 * hiss + 0.4 * body
    out *= env(rng, 0.25, 0.15)
    for t0 in ev_times(rng, 1100):  # droplet ticks on slate
        place(out, t0, tick(rng, rng.uniform(1800, 7500), 0.02, rng.uniform(0.002, 0.006)),
              rng.uniform(-1, 1), rng.lognormal(-1.6, 0.5))
    for t0 in ev_times(rng, 170):  # heavier drops on stone
        place(out, t0, tick(rng, rng.uniform(600, 2400), 0.07, rng.uniform(0.008, 0.02)),
              rng.uniform(-1, 1), rng.lognormal(-1.8, 0.5))
    canal = bed(rng, 500, 2200) * np.stack([env(rng, 14, 1.0), env(rng, 14, 1.0)]) * env(rng, 0.2, 0.3)
    out += 0.07 * canal * np.array([[1.0], [0.45]])  # distant canal, left side
    return out


def harbor(rng):
    out = np.zeros((2, N))
    for c in range(2):  # 6.7-10 s swells (4, 5 and 6 cycles per loop)
        ph = 0.5 * c
        sw = np.clip(0.5 + 0.35 * lfo(5, 0.7 + ph) + 0.22 * lfo(6, 2.1 - ph) + 0.15 * lfo(4, 4.0), 0.03, None)
        out[c] += 1.3 * noise(rng, 25, 160, 3) * sw
        out[c] += 0.7 * noise(rng, 180, 1400, 2) * sw ** 2.2 * env(rng, 3.0, 0.3)  # wash
    for c in range(2):  # lapping on wood
        lap = noise(rng, 250, 1100, 2) * np.clip(noise(rng, None, 1.6, 2) * 0.6 + 0.5, 0.0, None) ** 2
        out[c] += 0.45 * lap * env(rng, 0.4, 0.4)
        out[c] += 0.18 * noise(rng, 2500, 6500) * np.clip(noise(rng, None, 0.9, 2) + 0.4, 0, None) * 0.3
    for t0 in ev_times(rng, 6, 2):
        place(out, t0, creak(rng, rng.uniform(260, 620), rng.uniform(0.5, 1.1)),
              rng.uniform(-0.8, 0.8), rng.uniform(0.12, 0.22))
    for t0, pan in zip((6.5 * SR, 21.0 * SR, 31.5 * SR), (-0.5, 0.6, 0.1)):
        place(out, t0 + rng.uniform(-1, 1) * SR, gull(rng, rng.uniform(1350, 1700)), pan, 0.035)
    return out


def marsh(rng):
    out = 0.55 * wind(rng, 90, 700, 0.1, 0.7)
    out += 0.35 * wind(rng, 700, 2600, 0.14, 0.9)
    for c in range(2):
        lap = noise(rng, 200, 900) * np.clip(noise(rng, None, 1.2, 2) * 0.6 + 0.5, 0, None) ** 2
        out[c] += 0.22 * lap * env(rng, 0.3, 0.4)
    # insect trills: AM narrowband tones in bursts
    for k, (fc, rate, level) in enumerate(((4300, 36, 0.05), (5200, 29, 0.04), (3500, 24, 0.045), (6100, 41, 0.025))):
        carrier = np.sin(2 * np.pi * qf(fc) * T + k) + 0.5 * np.sin(2 * np.pi * qf(fc * 1.01) * T)
        trill = np.clip(np.sin(2 * np.pi * qf(rate) * T), 0, None) ** 1.5
        burst = np.clip(env(rng, 0.45, 2.2) - 0.9, 0, None)
        burst = burst / (burst.max() + 1e-9)
        sig = carrier * trill * burst
        gl, gr = pan_gains(rng.uniform(-0.8, 0.8))
        out += level * np.stack([gl * sig, gr * sig])
    for t0 in ev_times(rng, 7, 1.5):
        for rep in range(rng.integers(1, 3)):
            place(out, t0 + rep * 0.38 * SR, frog(rng, rng.uniform(95, 150)),
                  rng.uniform(-0.9, 0.9), rng.uniform(0.12, 0.2) if rep == 0 else 0.09)
    return out


def forest(rng):
    out = 0.6 * wind(rng, 500, 4200, 0.13, 0.8)
    out += 0.3 * wind(rng, 2200, 7500, 0.2, 1.1) * np.stack([env(rng, 25, 0.6), env(rng, 25, 0.6)])
    out += 0.35 * wind(rng, 60, 300, 0.1, 0.7)
    for t0 in ev_times(rng, 4, 2):
        place(out, t0, creak(rng, rng.uniform(380, 800), rng.uniform(0.5, 1.0)),
              rng.uniform(-0.8, 0.8), rng.uniform(0.08, 0.14))
    for t0 in ev_times(rng, 8, 1.5):
        base = rng.uniform(2600, 4600)
        pan = rng.uniform(-0.9, 0.9)
        gap = rng.uniform(0.11, 0.17)
        for i in range(rng.integers(2, 5)):
            place(out, t0 + i * gap * SR, chirp(rng, base, base * rng.uniform(1.15, 1.45), rng.uniform(0.05, 0.09)),
                  pan, rng.uniform(0.025, 0.04))
    return out


def highland(rng):
    g = env(rng, 0.14, 0.9)
    out = np.zeros((2, N))
    for c in range(2):
        gc = env(rng, 0.14, 0.9) * 0.5 + g * 0.5
        out[c] += 0.9 * noise(rng, 60, 700, 2) * gc
        out[c] += 0.6 * noise(rng, 500, 2600, 2) * gc ** 1.8
        out[c] += 0.12 * noise(rng, 2800, 7000, 2) * gc ** 2.5
    # hollow whistle: wandering low tone with breath noise, swelling with gusts
    f_inst = 420.0 + 22.0 * lfo(3, 0.4) + 11.0 * lfo(7, 1.3)
    whistle = tone(f_inst) + 0.12 * tone(2 * f_inst, 0.7)
    breath = noise(rng, 330, 560, 2) * 1.2
    w_env = np.clip((g - 0.9) * 1.6, 0, None) ** 1.2
    w_env = np.clip(w_env + 0.12 * (1.0 + lfo(4, 2.0)), 0, None)
    sig = (0.7 * whistle + 0.5 * breath) * w_env
    out += 0.17 * np.stack([sig, np.roll(sig, int(0.011 * SR))])
    return out


def gate(rng):
    out = np.zeros((2, N))
    # deep drone with slow beating (frequencies on whole cycles per loop)
    for f, g, pan in ((45.0, 1.0, -0.2), (45.25, 0.9, 0.2), (55.0, 0.55, 0.3), (55.125, 0.5, -0.3), (41.0, 0.5, 0.0)):
        s = np.sin(2 * np.pi * qf(f) * T + rng.uniform(0, 6.28))
        gl, gr = pan_gains(pan)
        out += g * 0.9 * np.stack([gl * s, gr * s])
    for f, g in ((90.0, 0.17), (135.25, 0.1), (110.125, 0.1)):  # audible on small speakers
        s = np.sin(2 * np.pi * qf(f) * T + rng.uniform(0, 6.28)) * (0.6 + 0.4 * lfo(2, rng.uniform(0, 6)))
        out += g * np.stack([s, np.roll(s, 90)])
    out *= (0.85 + 0.15 * lfo(1, 0.3))
    # shimmering high harmonic hum
    shimmer = np.zeros((2, N))
    for i, base in enumerate((880.0, 1320.0, 1760.0, 2640.0, 3520.0, 5280.0)):
        for det, c in ((0.0, 0), (0.125 * (i + 1), 1)):
            s = np.sin(2 * np.pi * qf(base + det) * T + rng.uniform(0, 6.28))
            trem = 0.55 + 0.45 * lfo(int(rng.integers(2, 10)), rng.uniform(0, 6.28))
            shimmer[c] += s * trem / (1 + 0.55 * i)
            shimmer[1 - c] += 0.35 * s * trem / (1 + 0.55 * i)
    out += 0.045 * shimmer
    out += 0.05 * bed(rng, 3000, 7000, 2) * np.stack([np.clip(0.5 + 0.5 * lfo(7, 1.0 + k), 0, None) ** 2 for k in range(2)])
    out += 0.28 * wind(rng, 80, 600, 0.1, 0.6)  # distant wind
    return out


def _cave_dry(rng, drips, drip_gain):
    dry = np.zeros((2, N))
    for t0 in ev_times(rng, drips):
        place(dry, t0, drip(rng, rng.uniform(650, 2300)), rng.uniform(-0.8, 0.8), rng.uniform(0.5, 1.0) * drip_gain)
    return dry


def cave(rng):
    wet = reverb(_cave_dry(rng, 20, 1.0), rng, rt=1.5, wet=1.1, dry=0.5)
    wet += 0.35 * sub_rumble(rng, 85)
    wet += 0.012 * wind(rng, 200, 1800, 0.08, 0.5)  # faint air
    return wet


def dungeon(rng):
    dry = _cave_dry(rng, 14, 0.9)
    for t0 in ev_times(rng, 3, 3):
        place(dry, t0, clink(rng, rng.uniform(1100, 1700)), rng.uniform(-0.9, 0.9), 0.18)
    out = reverb(dry, rng, rt=1.6, wet=1.1, dry=0.45)
    out += 0.3 * sub_rumble(rng, 80)
    pulse = (0.5 + 0.5 * np.sin(2 * np.pi * 8 * T / DUR - 1.2)) ** 1.5  # 0.2 Hz Current pulse
    for f, g in ((55.0, 0.55), (110.25, 0.3), (165.0, 0.14)):
        s = np.sin(2 * np.pi * qf(f) * T + rng.uniform(0, 6.28)) * (0.35 + 0.65 * pulse)
        out += g * np.stack([s, np.roll(s, 60)])
    hum = np.sin(2 * np.pi * qf(330.0) * T) * (0.2 + 0.8 * pulse) * 0.03
    out += np.stack([hum, np.roll(hum, 80)])
    return out


ZONES = {
    "TownRain": (town_rain, 101),
    "Harbor": (harbor, 202),
    "Marsh": (marsh, 303),
    "Forest": (forest, 404),
    "Highland": (highland, 505),
    "Gate": (gate, 606),
    "Cave": (cave, 707),
    "Dungeon": (dungeon, 808),
}


# ---------------------------------------------------------------- finishing
def pick_cut(x):
    """Roll the (circular) signal so the loop point sits on a quiet, smooth sample.

    Synthesis is already circular, so any rotation loops perfectly; choose the
    one with the smallest step across the wrap and matching head/tail energy.
    """
    step = np.max(np.abs(x - np.roll(x, 1, axis=0)), axis=1)  # step into sample k
    e = np.concatenate([[0.0], np.cumsum(np.sum(x * x, axis=1))])
    n50 = int(0.05 * SR)
    best, best_score = 0, 1e9
    for k in np.argsort(step)[:400]:
        k = int(k)
        idx = (k + np.arange(0, n50)) % N
        jdx = (k - n50 + np.arange(0, n50)) % N
        head = np.sum(x[idx] ** 2) + 1e-12
        tail = np.sum(x[jdx] ** 2) + 1e-12
        db = abs(10 * np.log10(head / tail))
        score = step[k] + 0.01 * db
        if db < 1.5 and score < best_score:
            best, best_score = k, score
    return np.roll(x, -best, axis=0)


def finish(buf):
    x = buf - buf.mean(axis=1, keepdims=True)
    # gentle soft limiter so rare events don't force the bed down
    rms = np.sqrt(np.mean(x * x))
    c = 4.5 * rms
    x = c * np.tanh(x / c)
    x *= 10 ** (PEAK_DB / 20) / np.max(np.abs(x))
    return pick_cut(x.T).astype(np.float32)  # (N, 2)


def write_ogg(path, data):
    with sf.SoundFile(str(path), "w", samplerate=SR, channels=2, format="OGG", subtype="VORBIS") as f:
        try:
            f.compression_level = 0.35
        except Exception:
            pass
        f.write(data)


def write_leveled(path, data):
    """Encode, then trim gain so the *decoded* peak lands on PEAK_DB (Vorbis overshoots)."""
    for _ in range(3):
        write_ogg(path, data)
        dec, _sr = sf.read(str(path), always_2d=True)
        err = PEAK_DB - 20 * np.log10(np.max(np.abs(dec)) + 1e-12)
        if abs(err) < 0.15:
            return
        data = (data * 10 ** (err / 20)).astype(np.float32)


def verify(path, name):
    info = sf.info(str(path))
    x, _ = sf.read(str(path), always_2d=True)
    n50 = int(0.05 * SR)
    r_head = np.sqrt(np.mean(x[:n50] ** 2))
    r_tail = np.sqrt(np.mean(x[-n50:] ** 2))
    db = 20 * np.log10((r_head + 1e-12) / (r_tail + 1e-12))
    jump = np.max(np.abs(x[0] - x[-1]))
    typical = np.max(np.abs(np.diff(x, axis=0)))
    ok = abs(db) <= 3.0 and jump <= 0.1
    print(f"{name:9s} {path.stat().st_size / 1024:6.0f} KB  {info.duration:5.2f}s  {info.samplerate} Hz x{info.channels}  "
          f"peak {20 * np.log10(np.max(np.abs(x))):5.2f} dB  head/tail {db:+.2f} dB  wrap jump {jump:.4f} "
          f"(max step {typical:.3f})  {'OK' if ok else 'CHECK'}")
    return ok


def main(argv):
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    names = argv or list(ZONES)
    all_ok = True
    t_start = time.time()
    for name in names:
        fn, seed = ZONES[name]
        data = finish(fn(np.random.default_rng(seed)))
        path = OUT_DIR / f"ambience_{name}.ogg"
        write_leveled(path, data)
        all_ok &= verify(path, name)
    print(f"done in {time.time() - t_start:.1f}s")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
