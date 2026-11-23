#!/usr/bin/env python3
"""Reference for HRTFKit/HRTFAnalysis.swift: magnitude responses for fixed directions + diffuse field."""
import math, sys, plistlib, struct
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import apple_hrtf_to_sofa as A

FFT = 2048
POINTS = 320
FMIN, FMAX = 20.0, 23900.0
# Hammershøi & Møller (2008), Acta Acustica united with Acustica 94, Table II: diffuse-field ED and BE (dB)
EC_F = [100,125,160,200,250,315,400,500,630,800,1000,1250,1600,2000,2500,3150,4000,5000,6300,8000,10000,12500,16000]
EC_ED = [0,.2,.4,.6,.8,1.1,1.5,2.1,2.8,3.3,4.1,5.5,7.7,11.0,15.3,15.7,12.9,10.6,9.4,9.5,6.8,3.8,0.7]
EC_BE = [0,.2,.4,.6,.8,1.1,1.5,1.7,2.2,2.3,2.3,3.1,3.8,4.4,5.9,8.1,10.3,10.0,7.3,6.0,3.8,2.0,-0.2]


def ear_canal_db(f):
    c = np.array(EC_ED) - np.array(EC_BE)
    return np.interp(np.log(np.clip(f, EC_F[0], EC_F[-1])), np.log(EC_F), c)


DIRS = [("Front", 0.0, 0.0), ("45° left", 45.0, 0.0), ("45° right", 315.0, 0.0), ("45° down", 0.0, -45.0), ("45° up", 0.0, 45.0)]


def load_ctf(path):
    top = plistlib.load(open(path, "rb")); b = top["HRIR_DFEQ"]; n = struct.unpack("<I", b[:4])[0]
    m = plistlib.loads(b[4:4 + n]); return np.array(m.get("UserData", {}).get("CTF", []), float)


def weights(elev):
    w = np.zeros(len(elev))
    for e in np.unique(elev):
        idx = elev == e
        lo = max(-90.0, e - 2.5); hi = min(90.0, e + 2.5)
        w[idx] = (math.sin(math.radians(hi)) - math.sin(math.radians(lo))) / idx.sum()
    return w


def smooth(P, frac, df):
    if frac <= 0:
        return P.copy()
    half = len(P) - 1
    cs = np.concatenate([[0.0], np.cumsum(P)])
    out = P.copy()
    for k in range(1, half + 1):
        f = k * df
        lo = f * 2 ** (-1 / (2 * frac)); hi = f * 2 ** (1 / (2 * frac))
        klo = max(1, min(int(math.ceil(lo / df)), k)); khi = min(half, max(int(math.floor(hi / df)), k))
        out[k] = (cs[khi + 1] - cs[klo]) / (khi - klo + 1)
    return out


def analyze(path, mirror=False, frac=12, add_ctf=False, eardrum=False):
    add_ctf = add_ctf or eardrum
    h = A.parse_apple_dat(path)
    sr = h.sample_rate; df = sr / FFT
    el = h.coords[:, 0]; az = h.coords[:, 1] if mirror else 360.0 - h.coords[:, 1]
    chan = [1, 0] if mirror else [0, 1]
    P = np.abs(np.fft.rfft(h.ir, FFT, axis=2)) ** 2          # (M, C, FFT/2+1)
    ctf = load_ctf(path); nctf = len(ctf) // 2
    grid = FMIN * (FMAX / FMIN) ** (np.arange(POINTS) / (POINTS - 1))
    ux = np.cos(np.radians(el)) * np.cos(np.radians(az)); uy = np.cos(np.radians(el)) * np.sin(np.radians(az)); uz = np.sin(np.radians(el))
    w = weights(el)
    curves = {}
    for ear in (0, 1):
        c = chan[ear]
        specs = []
        for name, a, e in DIRS:
            d = ux * math.cos(math.radians(e)) * math.cos(math.radians(a)) + uy * math.cos(math.radians(e)) * math.sin(math.radians(a)) + uz * math.sin(math.radians(e))
            m = int(np.argmax(d)); specs.append((name, P[m, c]))
        specs.append(("Diffuse field", (w[:, None] * P[:, c, :]).sum(0) / w.sum()))
        for name, p in specs:
            db = 10 * np.log10(smooth(p, frac, df) + 1e-20)
            pos = grid / df; i0 = np.floor(pos).astype(int); t = pos - i0
            v = db[i0] * (1 - t) + db[i0 + 1] * t
            if add_ctf and nctf:
                cv = ctf[c * nctf:(c + 1) * nctf]; step = sr / 2 / nctf; q = grid / step
                j = np.minimum(np.floor(q).astype(int), nctf - 1); u = q - j
                v = v + np.where(j >= nctf - 1, cv[-1], cv[j] * (1 - u) + cv[np.minimum(j + 1, nctf - 1)] * u)
            if eardrum:
                v = v + ear_canal_db(grid)
            curves[("Left" if ear == 0 else "Right") + " " + name] = v
    return grid, curves


if __name__ == "__main__":
    g, c = analyze(sys.argv[1], add_ctf="--ctf" in sys.argv)
    for k, v in c.items():
        print(k, [round(float(v[np.argmin(abs(g - f))]), 2) for f in (100, 1000, 3000, 6000, 10000, 15000)])
