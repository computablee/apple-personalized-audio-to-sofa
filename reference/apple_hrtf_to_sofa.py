#!/usr/bin/env python3
"""
Reference converter: Apple personalized spatial audio HRTF (.dat from iCloud)
-> SOFA (AES69, SimpleFreeFieldHRIR 1.0).

Pure Python + numpy. Contains a minimal, dependency-free HDF5 writer that
emits the same structures netCDF-4 does (dimension scales, DIMENSION_LIST,
dense link storage) so the result loads in netCDF/HDF5 based tools
(python sofar/netCDF4/h5py, MATLAB SOFAtoolbox) and in libmysofa.

Apple .dat layout (as reverse-engineered):
  top-level binary plist (dict):
    HRIR_DFEQ   : data  -> minimum-phase HRIRs + per-ear ITD   (used here)
    HRIR_ITDMod : data  -> same magnitude, phase-aligned, ITD = 0
    EQ, device, version
  each HRIR blob:
    u32 LE  n            length of embedded metadata bplist
    n bytes bplist       {SampleRate, FilterLength, NumChannels,
                          TotalNumCoordinates, FilterScaleFactor,
                          CoefficientFormat=int16, DelayFormat=float32, ...}
    M records of 8 + C*(2*L + 4) bytes, little-endian:
        f32 elevation_deg, f32 azimuth_deg            (azimuth clockwise)
        per channel: L x int16 taps, f32 delay_samples
"""
import argparse, datetime, math, os, plistlib, struct, sys
import numpy as np

# ----------------------------------------------------------------------------
# Apple parsing
# ----------------------------------------------------------------------------

class AppleHRTF:
    def __init__(self, sr, coords, ir, delay, meta):
        self.sample_rate = sr          # float
        self.coords = coords           # (M,2) [elev, az_apple] degrees
        self.ir = ir                   # (M,C,L) float64, scaled
        self.delay = delay             # (M,C) samples
        self.meta = meta               # dict of strings for comments


def parse_apple_dat(path, blob_key="HRIR_DFEQ"):
    with open(path, "rb") as f:
        top = plistlib.load(f)
    if blob_key not in top:
        raise ValueError(f"{path}: no {blob_key} entry (keys: {list(top)})")
    b = top[blob_key]
    n = struct.unpack_from("<I", b, 0)[0]
    m = plistlib.loads(b[4:4 + n])
    if m.get("CoefficientFormat") != "int16" or m.get("DelayFormat") != "float32":
        raise ValueError("unsupported coefficient/delay format")
    M = int(m["TotalNumCoordinates"]); L = int(m["FilterLength"]); C = int(m["NumChannels"])
    rec = 8 + C * (2 * L + 4)
    raw = b[4 + n:]
    if len(raw) != M * rec:
        raise ValueError(f"payload size {len(raw)} != {M}*{rec}")
    r = np.frombuffer(raw, dtype=np.uint8).reshape(M, rec)
    coords = r[:, :8].copy().view("<f4").astype(np.float64)
    ir = np.empty((M, C, L)); dl = np.empty((M, C))
    for c in range(C):
        o = 8 + c * (2 * L + 4)
        ir[:, c, :] = r[:, o:o + 2 * L].copy().view("<i2")
        dl[:, c] = r[:, o + 2 * L:o + 2 * L + 4].copy().view("<f4")[:, 0]
    ir *= float(m["FilterScaleFactor"])
    ctf = [float(v) for v in m.get("UserData", {}).get("CTF", [])]
    meta = {"ctf": ctf if len(ctf) % C == 0 else [],
            "device": str(top.get("device", "")),
            "export_date": str(top.get("EQ", {}).get("ExportDate", "")),
            "source_file": os.path.basename(path), "blob": blob_key}
    return AppleHRTF(float(m["SampleRate"]), coords, ir, dl, meta)

# ----------------------------------------------------------------------------
# DSP: bake fractional ITD into the impulse responses
# ----------------------------------------------------------------------------

def bessel_i0(x):
    s, t, k = 1.0, 1.0, 1
    while True:
        t *= (x / (2 * k)) ** 2
        s += t
        if t < 1e-12 * s:
            return s
        k += 1

FD_HALF = 16        # windowed-sinc half length (taps each side)
FD_BETA = 8.0       # Kaiser beta
PRE_DELAY = FD_HALF # common delay added to both ears so sinc pre-ringing isn't cut


def frac_delay_kernel(mu):
    """Taps for j = -FD_HALF+1 .. FD_HALF (2*FD_HALF taps), delay mu in [0,1)."""
    if mu == 0.0:
        k = [0.0] * (2 * FD_HALF); k[FD_HALF - 1] = 1.0
        return k
    i0b = bessel_i0(FD_BETA)
    out = []
    for j in range(-FD_HALF + 1, FD_HALF + 1):
        x = j - mu
        s = math.sin(math.pi * x) / (math.pi * x)
        r = x / FD_HALF
        w = bessel_i0(FD_BETA * math.sqrt(max(0.0, 1 - r * r))) / i0b
        out.append(s * w)
    tot = sum(out)
    return [v / tot for v in out]


def bake_delays(h):
    """Returns (ir (M,C,N), N). Output contains ITD; Data.Delay becomes 0."""
    M, C, L = h.ir.shape
    maxd = float(np.max(h.delay))
    N = L + PRE_DELAY + int(math.ceil(maxd)) + FD_HALF + 1
    N = 1 << (N - 1).bit_length()                     # next power of two
    out = np.zeros((M, C, N))
    for m in range(M):
        for c in range(C):
            d = PRE_DELAY + max(0.0, float(h.delay[m, c]))
            D = int(math.floor(d)); mu = d - D
            k = frac_delay_kernel(mu)
            y = np.convolve(h.ir[m, c], np.array(k))   # len L + 2*FD_HALF - 1
            start = D - FD_HALF + 1                    # index of kernel tap j=-FD_HALF+1
            out[m, c, start:start + len(y)] = y
    return out, N

# ----------------------------------------------------------------------------
# Raw eardrum mode: undo Apple's diffuse-field EQ (re-apply CTF) + population ear canal
# ----------------------------------------------------------------------------

# Hammershøi & Møller (2008), Acta Acustica united with Acustica 94, Table II, diffuse field (dB)
EC_F = [100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150,
        4000, 5000, 6300, 8000, 10000, 12500, 16000]
EC_ED = [0, .2, .4, .6, .8, 1.1, 1.5, 2.1, 2.8, 3.3, 4.1, 5.5, 7.7, 11.0, 15.3, 15.7, 12.9, 10.6,
         9.4, 9.5, 6.8, 3.8, 0.7]
EC_BE = [0, .2, .4, .6, .8, 1.1, 1.5, 1.7, 2.2, 2.3, 2.3, 3.1, 3.8, 4.4, 5.9, 8.1, 10.3, 10.0,
         7.3, 6.0, 3.8, 2.0, -0.2]
RAW_FIR_LEN = 256
RAW_DESIGN_FFT = 4096


def ear_canal_db(f):
    c = np.array(EC_ED) - np.array(EC_BE)
    return np.interp(np.log(np.clip(f, EC_F[0], EC_F[-1])), np.log(EC_F), c)


def raw_eardrum_target_db(h, c, nfft=RAW_DESIGN_FFT):
    ctf = np.array(h.meta["ctf"]); n = len(ctf) // h.ir.shape[1]
    f = np.arange(nfft // 2 + 1) * h.sample_rate / nfft
    cv = ctf[c * n:(c + 1) * n]; step = h.sample_rate / 2 / n; q = f / step
    j = np.minimum(np.floor(q).astype(int), n - 1); u = q - j
    ctfdb = np.where(j >= n - 1, cv[-1], cv[j] * (1 - u) + cv[np.minimum(j + 1, n - 1)] * u)
    return ctfdb + ear_canal_db(np.maximum(f, 1e-9))


def minimum_phase_fir(db, L, fade=32):
    nfft = 2 * (len(db) - 1)
    logm = np.log(10 ** (db / 20)); full = np.concatenate([logm, logm[-2:0:-1]])
    cep = np.fft.ifft(full).real
    fold = np.zeros(nfft); fold[0] = cep[0]; fold[1:nfft // 2] = 2 * cep[1:nfft // 2]; fold[nfft // 2] = cep[nfft // 2]
    h = np.fft.ifft(np.exp(np.fft.fft(fold))).real[:L].copy()
    h[-fade:] *= 0.5 * (1 + np.cos(np.pi * np.arange(1, fade + 1) / fade))
    return h


def apply_raw_eardrum(h):
    """Returns a copy of h whose IRs include Apple's CTF and a population-average ear canal."""
    if not h.meta.get("ctf"):
        raise ValueError("file has no CTF; cannot undo Apple's diffuse-field EQ")
    M, C, L = h.ir.shape
    firs = [minimum_phase_fir(raw_eardrum_target_db(h, c), RAW_FIR_LEN) for c in range(C)]
    ir = np.empty((M, C, L + RAW_FIR_LEN - 1))
    for m in range(M):
        for c in range(C):
            ir[m, c] = np.convolve(h.ir[m, c], firs[c])
    return AppleHRTF(h.sample_rate, h.coords, ir, h.delay, h.meta)

# ----------------------------------------------------------------------------
# Jenkins lookup3 (HDF5 metadata checksum and link-name hash)
# ----------------------------------------------------------------------------

def _rot(x, k):
    return ((x << k) | (x >> (32 - k))) & 0xffffffff


def lookup3(data, initval=0):
    length = len(data)
    a = b = c = (0xdeadbeef + length + initval) & 0xffffffff
    i = 0
    M32 = 0xffffffff
    while length > 12:
        a = (a + (data[i] | data[i+1] << 8 | data[i+2] << 16 | data[i+3] << 24)) & M32
        b = (b + (data[i+4] | data[i+5] << 8 | data[i+6] << 16 | data[i+7] << 24)) & M32
        c = (c + (data[i+8] | data[i+9] << 8 | data[i+10] << 16 | data[i+11] << 24)) & M32
        a = (a - c) & M32; a ^= _rot(c, 4);  c = (c + b) & M32
        b = (b - a) & M32; b ^= _rot(a, 6);  a = (a + c) & M32
        c = (c - b) & M32; c ^= _rot(b, 8);  b = (b + a) & M32
        a = (a - c) & M32; a ^= _rot(c, 16); c = (c + b) & M32
        b = (b - a) & M32; b ^= _rot(a, 19); a = (a + c) & M32
        c = (c - b) & M32; c ^= _rot(b, 4);  b = (b + a) & M32
        length -= 12; i += 12
    if length == 0:
        return c
    w = [0, 0, 0]
    for j in range(length):
        w[j // 4] |= data[i + j] << (8 * (j % 4))
    a = (a + w[0]) & M32; b = (b + w[1]) & M32; c = (c + w[2]) & M32
    c ^= b; c = (c - _rot(b, 14)) & M32
    a ^= c; a = (a - _rot(c, 11)) & M32
    b ^= a; b = (b - _rot(a, 25)) & M32
    c ^= b; c = (c - _rot(b, 16)) & M32
    a ^= c; a = (a - _rot(c, 4)) & M32
    b ^= a; b = (b - _rot(a, 14)) & M32
    c ^= b; c = (c - _rot(b, 24)) & M32
    return c

# ----------------------------------------------------------------------------
# Minimal HDF5 / netCDF-4 writer
# ----------------------------------------------------------------------------

UNDEF = 0xffffffffffffffff
p8 = lambda v: struct.pack("<B", v)
p16 = lambda v: struct.pack("<H", v)
p32 = lambda v: struct.pack("<I", v)
p64 = lambda v: struct.pack("<Q", v)

# datatype messages (all version 1)
DT_F64 = bytes([0x11, 0x20, 0x3f, 0x00]) + p32(8) + p16(0) + p16(64) + bytes([52, 11, 0, 52]) + p32(1023)
DT_F32 = bytes([0x11, 0x20, 0x1f, 0x00]) + p32(4) + p16(0) + p16(32) + bytes([23, 8, 0, 23]) + p32(127)
DT_I32 = bytes([0x10, 0x08, 0x00, 0x00]) + p32(4) + p16(0) + p16(32)
DT_REF = bytes([0x17, 0x00, 0x00, 0x00]) + p32(8)
DT_VLEN_REF = bytes([0x19, 0x00, 0x00, 0x00]) + p32(16) + DT_REF


def dt_str(n):
    return bytes([0x13, 0x00, 0x00, 0x00]) + p32(n)


def _cmpd_member_v1(name, offset, dt):
    nb = name.encode() + b"\0"
    nb += b"\0" * ((-len(nb)) % 8)
    return nb + p32(offset) + p8(0) + b"\0" * 3 + p32(0) + p32(0) + b"\0" * 16 + dt


DT_REFLIST = (bytes([0x16, 0x02, 0x00, 0x00]) + p32(16)
              + _cmpd_member_v1("dataset", 0, DT_REF)
              + _cmpd_member_v1("dimension", 8, DT_I32))

DS_SCALAR = bytes([2, 0, 0, 0])


def ds_simple(dims):
    return bytes([2, len(dims), 0, 1]) + b"".join(p64(d) for d in dims)


def msg(mtype, body):
    return p8(mtype) + p16(len(body)) + p8(0) + body


def attr_msg(name, dt, ds, data):
    nb = name.encode() + b"\0"
    body = (p8(3) + p8(0) + p16(len(nb)) + p16(len(dt)) + p16(len(ds)) + p8(0)
            + nb + dt + ds + data)
    return msg(0x0C, body)


MAX_TEXT = 64   # libmysofa rejects any datatype larger than 64 bytes (incl. strings)


def clip_utf8(value, limit=MAX_TEXT):
    v = value.encode("utf-8")
    while len(v) > limit:
        value = value[:-1]; v = value.encode("utf-8")
    return v


def text_attr(name, value):
    v = clip_utf8(value)
    if not v:
        v = b" "
    return attr_msg(name, dt_str(len(v)), DS_SCALAR, v)


def cstr_attr(name, value):      # null-terminated (HDF5 dimension-scale style)
    v = value.encode() + b"\0"
    return attr_msg(name, dt_str(len(v)), DS_SCALAR, v)


def ohdr(messages):
    body = b"".join(messages)
    h = b"OHDR" + p8(2) + p8(0x02) + p32(len(body)) + body
    return h + p32(lookup3(h))


FILL_MSG = msg(0x05, bytes([3, 0x09]))          # v3, alloc early, write if-set


def layout_msg(addr, size):
    return msg(0x08, bytes([3, 1]) + p64(addr) + p64(size))


def align8(x):
    return (x + 7) & ~7


class SOFAWriter:
    """Collects netCDF dims, variables and attributes; writes HDF5."""

    def __init__(self):
        self.dims = []          # (name, length)
        self.vars = []          # (name, dimnames, np.float64 array, {attr: str})
        self.gattrs = []        # (name, value)

    def add_dim(self, name, n): self.dims.append((name, int(n)))
    def add_var(self, name, dimnames, data, attrs=None):
        data = np.ascontiguousarray(data, dtype="<f8")
        shape = tuple(dict(self.dims)[d] for d in dimnames)
        assert data.shape == shape, (name, data.shape, shape)
        self.vars.append((name, dimnames, data, attrs or {}))
    def add_gattr(self, name, value): self.gattrs.append((name, value))

    # -- build all metadata blobs given an address table ---------------------
    def _build(self, A):
        dimidx = {n: i for i, (n, _) in enumerate(self.dims)}
        blobs = {}
        # global heap: one object per (var, dim position) holding a reference
        gobjs = []          # (var_name, k) -> heap index
        gindex = {}
        for vname, dnames, _, _ in self.vars:
            for k, dn in enumerate(dnames):
                gobjs.append(A["dim:" + dn]); gindex[(vname, k)] = len(gobjs)
        g = b"GCOL" + p8(1) + b"\0\0\0" + p64(0)
        for i, ref in enumerate(gobjs, 1):
            g += p16(i) + p16(0) + p32(0) + p64(8) + p64(ref)
        gsize = max(4096, align8(len(g) + 16))
        g = g[:8] + p64(gsize) + g[16:]
        g += p16(0) + p16(0) + p32(0) + p64(gsize - len(g))
        g += b"\0" * (gsize - len(g))
        blobs["gcol"] = g

        # dimension scale datasets
        for di, (dn, n) in enumerate(self.dims):
            refs = [(A["var:" + vn], k) for vn, dns, _, _ in self.vars
                    for k, d in enumerate(dns) if d == dn]
            rl = b"".join(p64(a) + p32(k) + p32(0) for a, k in refs)
            m = [msg(0x01, ds_simple([n])), msg(0x03, DT_F32), FILL_MSG,
                 layout_msg(A["data:dim:" + dn], 4 * n),
                 cstr_attr("CLASS", "DIMENSION_SCALE"),
                 cstr_attr("NAME", "This is a netCDF dimension but not a netCDF variable.%10d" % n),
                 attr_msg("_Netcdf4Dimid", DT_I32, DS_SCALAR, p32(di))]
            if refs:
                m.append(attr_msg("REFERENCE_LIST", DT_REFLIST, ds_simple([len(refs)]), rl))
            blobs["dim:" + dn] = ohdr(m)

        # variables
        for vn, dns, data, attrs in self.vars:
            dl = b"".join(p32(1) + p64(A["gcol"]) + p32(gindex[(vn, k)]) for k in range(len(dns)))
            m = [msg(0x01, ds_simple(list(data.shape))), msg(0x03, DT_F64), FILL_MSG,
                 layout_msg(A["data:var:" + vn], data.nbytes),
                 attr_msg("DIMENSION_LIST", DT_VLEN_REF, ds_simple([len(dns)]), dl)]
            for an, av in attrs.items():
                m.append(text_attr(an, av))
            blobs["var:" + vn] = ohdr(m)

        # links: dims first (libmysofa resolves DIMENSION_LIST names in order)
        links = [(dn, A["dim:" + dn]) for dn, _ in self.dims] + \
                [(vn, A["var:" + vn]) for vn, _, _, _ in self.vars]
        DBLK = 4096
        hdr_len = 4 + 1 + 8 + 4
        dblk = b"FHDB" + p8(0) + p64(A["frhp"]) + p32(0)
        heap_ids = []
        for corder, (name, addr) in enumerate(links):
            nb = name.encode()
            lm = p8(1) + p8(0x04) + p64(corder) + p8(len(nb)) + nb + p64(addr)
            heap_ids.append((nb, p8(0) + p32(len(dblk)) + p16(len(lm))))
            dblk += lm
        assert len(dblk) < DBLK - 1
        used = len(dblk) - hdr_len
        dblk += b"\0" * (DBLK - len(dblk))
        blobs["fhdb"] = dblk

        f = (b"FRHP" + p8(0) + p16(7) + p16(0) + p8(0) + p32(4096)
             + p64(0) + p64(UNDEF)                       # next huge id, huge btree
             + p64(DBLK - hdr_len - used) + p64(UNDEF)   # free space, fs manager
             + p64(DBLK) + p64(DBLK) + p64(DBLK)         # managed, allocated, iterator
             + p64(len(links))                           # managed objects
             + p64(0) + p64(0) + p64(0) + p64(0)         # huge size/num, tiny size/num
             + p16(4) + p64(DBLK) + p64(65536) + p16(32) + p16(1)
             + p64(A["fhdb"]) + p16(0))
        blobs["frhp"] = f + p32(lookup3(f))

        recs = sorted((lookup3(nb), nb, hid) for nb, hid in heap_ids)
        hashes = [r[0] for r in recs]
        assert len(set(hashes)) == len(hashes), "link name hash collision"
        leaf = b"BTLF" + p8(0) + p8(5) + b"".join(p32(h) + hid for h, _, hid in recs)
        leaf += p32(lookup3(leaf))
        leaf += b"\0" * (512 - len(leaf))
        blobs["btlf"] = leaf
        bh = (b"BTHD" + p8(0) + p8(5) + p32(512) + p16(11) + p16(0) + p8(100) + p8(40)
              + p64(A["btlf"]) + p16(len(recs)) + p64(len(recs)))
        blobs["bthd"] = bh + p32(lookup3(bh))

        # root group
        m = [msg(0x02, p8(0) + p8(0x01) + p64(len(links)) + p64(A["frhp"]) + p64(A["bthd"])),
             msg(0x0A, bytes([0, 0]))]
        for an, av in self.gattrs:
            m.append(text_attr(an, av))
        blobs["root"] = ohdr(m)
        return blobs

    def write(self, path):
        keys = (["root"] + ["dim:" + d for d, _ in self.dims] + ["var:" + v[0] for v in self.vars]
                + ["frhp", "fhdb", "bthd", "btlf", "gcol"])
        A0 = {k: 0 for k in keys}
        for d, _ in self.dims: A0["data:dim:" + d] = 0
        for v in self.vars: A0["data:var:" + v[0]] = 0
        sizes = {k: len(b) for k, b in self._build(A0).items()}
        A = {}; pos = 48
        for k in keys:
            A[k] = pos; pos = align8(pos + sizes[k])
        raw = []
        for d, n in self.dims:
            A["data:dim:" + d] = pos; raw.append((pos, b"\0" * (4 * n))); pos = align8(pos + 4 * n)
        for vn, _, data, _ in self.vars:
            A["data:var:" + vn] = pos; raw.append((pos, data.tobytes())); pos = align8(pos + data.nbytes)
        eof = pos
        blobs = self._build(A)
        assert {k: len(b) for k, b in blobs.items()} == sizes
        sb = (b"\x89HDF\r\n\x1a\n" + p8(2) + p8(8) + p8(8) + p8(0)
              + p64(0) + p64(UNDEF) + p64(eof) + p64(A["root"]))
        sb += p32(lookup3(sb))
        out = bytearray(eof)
        out[0:48] = sb
        for k in keys:
            out[A[k]:A[k] + len(blobs[k])] = blobs[k]
        for a, b in raw:
            out[a:a + len(b)] = b
        with open(path, "wb") as f:
            f.write(out)

# ----------------------------------------------------------------------------
# SOFA assembly
# ----------------------------------------------------------------------------

def build_sofa(h, bake=True, mirror=False, distance=1.0, listener="AppleHRTF",
               date=None, app_version="1.0", raw_eardrum=False):
    if raw_eardrum:
        h = apply_raw_eardrum(h)
    M = h.coords.shape[0]
    elev = h.coords[:, 0]; az_apple = h.coords[:, 1]
    if mirror:
        # interpret Apple azimuth as counter-clockwise, channel 1 = left ear
        az = np.mod(az_apple, 360.0); left, right = 1, 0
    else:
        # default: Apple azimuth clockwise (90 = right), channel 0 = left ear
        az = np.mod(360.0 - az_apple, 360.0); left, right = 0, 1
    src = np.stack([az, elev, np.full(M, distance)], axis=1)
    if bake:
        ir, N = bake_delays(h)
        ir = ir[:, [left, right], :]
        delay = np.zeros((1, 2)); delay_dims = ("I", "R")
    else:
        ir = h.ir[:, [left, right], :]; N = ir.shape[2]
        delay = h.delay[:, [left, right]].copy(); delay_dims = ("M", "R")

    now = date or datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    w = SOFAWriter()
    for name, n in [("I", 1), ("C", 3), ("R", 2), ("E", 1), ("N", N), ("M", M)]:
        w.add_dim(name, n)
    gattrs = [("Conventions", "SOFA"), ("Version", "2.1"),
              ("SOFAConventions", "SimpleFreeFieldHRIR"), ("SOFAConventionsVersion", "1.0"),
              ("APIName", "HRTFToSOFA"), ("APIVersion", app_version),
              ("ApplicationName", "HRTFToSOFA"), ("ApplicationVersion", app_version),
              ("AuthorContact", "unknown"), ("Organization", "unknown"),
              ("License", "No license provided, ask the author for permission"),
              ("DataType", "FIR"), ("RoomType", "free field"),
              ("DateCreated", now), ("DateModified", now),
              ("Title", f"Personalized HRTF ({listener})"),
              ("DatabaseName", "Apple Personalized Spatial Audio"),
              ("ListenerShortName", listener), ("Origin", "Apple Personalized Spatial Audio"),
              ("References", "none"), ("History", "Converted by HRTFToSOFA"),
              ("Comment", "Converted from an Apple personalized spatial audio profile"),
              ("AppleSourceFile", h.meta["source_file"]), ("AppleHRIRBlob", h.meta["blob"]),
              ("AppleDevice", h.meta["device"] or "unknown"),
              ("AppleExportDate", h.meta["export_date"] or "unknown"),
              ("ITDHandling", "baked into Data.IR" if bake else "in Data.Delay; Data.IR is minimum-phase"),
              ("EarMapping", "mirrored" if mirror else "standard"),
              ("HRTFEqualization", "none (Apple CTF re-applied)" if raw_eardrum else "Apple diffuse-field EQ (as stored)"),
              ("HRTFReferencePoint", "eardrum (approximate)" if raw_eardrum else "blocked ear-canal entrance (assumed)"),
              ("EarCanalModel", "population avg: Hammershoi & Moller 2008, Table II ED-BE" if raw_eardrum else "none")]
    for k, v in gattrs:
        w.add_gattr(k, v)
    cart = {"Type": "cartesian", "Units": "metre"}
    w.add_var("ListenerPosition", ("I", "C"), np.zeros((1, 3)), cart)
    w.add_var("ReceiverPosition", ("R", "C", "I"),
              np.array([[[0.0], [0.09], [0.0]], [[0.0], [-0.09], [0.0]]]), cart)
    w.add_var("SourcePosition", ("M", "C"), src, {"Type": "spherical", "Units": "degree, degree, metre"})
    w.add_var("EmitterPosition", ("E", "C", "I"), np.zeros((1, 3, 1)), cart)
    w.add_var("ListenerUp", ("I", "C"), np.array([[0.0, 0.0, 1.0]]))
    w.add_var("ListenerView", ("I", "C"), np.array([[1.0, 0.0, 0.0]]), cart)
    w.add_var("Data.IR", ("M", "R", "N"), ir)
    w.add_var("Data.SamplingRate", ("I",), np.array([h.sample_rate]), {"Units": "hertz"})
    w.add_var("Data.Delay", delay_dims, delay)
    return w


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("-o", "--outdir", default=".")
    ap.add_argument("--keep-delays", action="store_true", help="store ITD in Data.Delay instead of baking")
    ap.add_argument("--mirror", action="store_true", help="swap ear/azimuth interpretation")
    ap.add_argument("--distance", type=float, default=1.0)
    ap.add_argument("--listener", default="AppleHRTF")
    ap.add_argument("--date", default=None, help="fixed DateCreated/DateModified (for reproducible output)")
    ap.add_argument("--raw-eardrum", action="store_true",
                    help="undo Apple's diffuse-field EQ and add a population-average ear canal (-raw-eardrum.sofa)")
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    for p in a.inputs:
        h = parse_apple_dat(p)
        w = build_sofa(h, bake=not a.keep_delays, mirror=a.mirror, distance=a.distance,
                       listener=a.listener, date=a.date, raw_eardrum=a.raw_eardrum)
        out = os.path.join(a.outdir, os.path.splitext(os.path.basename(p))[0]
                           + ("-raw-eardrum" if a.raw_eardrum else "") + ".sofa")
        w.write(out)
        print(f"{p} -> {out}")


if __name__ == "__main__":
    main()
