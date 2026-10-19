"""Deterministic synthetic test-signal generator for the voice-analysis vectors (docs/voice-analysis-spec.md, appendix G).

Pure Python, binary64, explicit operation order, so Kotlin and Swift ports give the same int16
samples (bit-exact in practice; vectors.json carries a checksum of every case to confirm).

Building blocks
    Rng            xorshift32 integer noise, uniform u = (x >> 8) * 2^-24, gauss = sum of 12 u - 6
    rosenberg()    Rosenberg glottal-flow derivative, phase accumulator, open phase tp, closing tn
    resonate()     Klatt second-order resonator, y = A*x + B*y1 + C*y2
    quantize()     q = floor(v * 32768 + 0.5), clamped to [-32768, 32767]

A case is a dict {"segments": [...], "gain": g, "events": [...]} (see build()).
"""
import math

FS = 48000

VOWELS = {
    "a": ((700.0, 80.0), (1220.0, 90.0), (2600.0, 120.0)),
    "i": ((270.0, 80.0), (2290.0, 90.0), (3010.0, 120.0)),
    "u": ((300.0, 80.0), (870.0, 90.0), (2240.0, 120.0)),
}


class Rng:
    def __init__(self, seed):
        self.x = seed & 0xFFFFFFFF
        if self.x == 0:
            self.x = 0x9E3779B9

    def u32(self):
        x = self.x
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        self.x = x
        return x

    def uniform(self):
        return (self.u32() >> 8) * (1.0 / 16777216.0)

    def gauss(self):
        s = 0.0
        for _ in range(12):
            s += self.uniform()
        return s - 6.0


def n_samples(dur_s):
    return int(math.floor(dur_s * FS + 0.5))


def rms_of(x):
    s = 0.0
    for v in x:
        s += v * v
    return math.sqrt(s / len(x))


def scale_to(x, target_rms):
    g = target_rms / rms_of(x)
    return [v * g for v in x]


def f0_track(spec, n):
    """f0 per sample. spec: number | {"steps": [[dur_s, f0], ...]} | {"glide": [f0a, f0b]}."""
    if isinstance(spec, (int, float)):
        return [float(spec)] * n
    if "steps" in spec:
        out = []
        for dur, f in spec["steps"]:
            out.extend([float(f)] * n_samples(dur))
        last = out[-1]
        while len(out) < n:
            out.append(last)
        return out[:n]
    if "glide" in spec:
        fa, fb = float(spec["glide"][0]), float(spec["glide"][1])
        k = math.log(fb / fa)
        return [fa * math.exp(k * i / n) for i in range(n)]
    raise ValueError(spec)


def rosenberg(f0s, tp=0.40, tn=0.16):
    """Glottal-flow derivative (per unit phase). Phase starts at 0; sample i uses the phase before
    the increment ph += f0[i] / 48000, wrapped by subtracting 1.0 once it reaches 1.0."""
    out = []
    ph = 0.0
    k_rise = math.pi / (2.0 * tp)
    k_fall = math.pi / (2.0 * tn)
    for f in f0s:
        if ph < tp:
            v = k_rise * math.sin(math.pi * ph / tp)
        elif ph < tp + tn:
            v = -k_fall * math.sin(math.pi * (ph - tp) / (2.0 * tn))
        else:
            v = 0.0
        out.append(v)
        ph = ph + f / FS
        if ph >= 1.0:
            ph = ph - 1.0
    return out


def resonate(x, freq, bw):
    c = -math.exp(-2.0 * math.pi * bw / FS)
    b = 2.0 * math.exp(-math.pi * bw / FS) * math.cos(2.0 * math.pi * freq / FS)
    a = 1.0 - b - c
    y1 = 0.0
    y2 = 0.0
    out = []
    for v in x:
        y = a * v + b * y1 + c * y2
        y2 = y1
        y1 = y
        out.append(y)
    return out


def lowpass1(x, fc):
    """One-pole low-pass y += k * (x - y), k = 1 - exp(-2 pi fc / fs)."""
    k = 1.0 - math.exp(-2.0 * math.pi * fc / FS)
    y = 0.0
    out = []
    for v in x:
        y = y + k * (v - y)
        out.append(y)
    return out


def noise(n, seed, lowpass_hz=None, order=1):
    rng = Rng(seed)
    x = [rng.gauss() for _ in range(n)]
    if lowpass_hz:
        for _ in range(order):
            x = lowpass1(x, lowpass_hz)
    return x


def syllable_envelope(n, rate, per_block, pause_s):
    """Blocks of per_block whole sin^2 syllables (each 1/rate s), then pause_s of zero."""
    syl = n_samples(1.0 / rate)
    speak = syl * per_block
    block = speak + n_samples(pause_s)
    env = []
    for i in range(n):
        t = i % block
        if t < speak:
            s = math.sin(math.pi * (t % syl) / syl)
            env.append(s * s)
        else:
            env.append(0.0)
    return env


def tone(n, freq, rms):
    peak = rms * math.sqrt(2.0)
    return [peak * math.sin(2.0 * math.pi * ((freq * i) % FS) / FS) for i in range(n)]


def segment(seg):
    n = n_samples(seg["dur_s"])
    kind = seg["type"]
    if kind == "silence":
        return [0.0] * n
    if kind == "noise":
        x = noise(n, seg["seed"], seg.get("lowpass_hz"), seg.get("order", 1))
        return scale_to(x, seg["rms"])
    if kind == "tone":
        return tone(n, int(seg["freq"]), seg["rms"])
    if kind == "voice":
        f0s = f0_track(seg["f0"], n)
        tp, tn = seg.get("shape", (0.40, 0.16))
        x = rosenberg(f0s, tp, tn)
        res = seg.get("formants") or VOWELS[seg["vowel"]]
        for fr, bw in res:
            x = resonate(x, fr, bw)
        x = scale_to(x, seg["rms"])
        env = seg.get("syllables")
        if env:
            e = syllable_envelope(n, env["rate"], env["per_block"], env["pause_s"])
            x = [a * b for a, b in zip(x, e)]
        nz = seg.get("noise")
        if nz:
            w = noise(n, nz["seed"], nz.get("lowpass_hz"), nz.get("order", 1))
            target = nz["rms"] if "rms" in nz else seg["rms"] / math.pow(10.0, nz["snr_db"] / 20.0)
            w = scale_to(w, target)
            x = [a + b for a, b in zip(x, w)]
        return x
    raise ValueError(kind)


def quantize(x, gain=1.0):
    out = []
    for v in x:
        q = int(math.floor(v * gain * 32768.0 + 0.5))
        if q > 32767:
            q = 32767
        elif q < -32768:
            q = -32768
        out.append(q)
    return out


def build(case):
    """Returns (pcm int16 list, events [(sample_index, gap_samples)])."""
    x = []
    for seg in case["segments"]:
        x.extend(segment(seg))
    pcm = quantize(x, case.get("gain", 1.0))
    events = [(n_samples(e["at_s"]), n_samples(e["gap_ms"] / 1000.0)) for e in case.get("events", [])]
    return pcm, events


def fnv1a32(pcm):
    """FNV-1a over the int16 little-endian bytes."""
    h = 0x811C9DC5
    for s in pcm:
        u = s & 0xFFFF
        for byte in (u & 0xFF, u >> 8):
            h ^= byte
            h = (h * 0x01000193) & 0xFFFFFFFF
    return h


def write_raw(pcm, path):
    import array
    arr = array.array("h", pcm)
    import sys
    if sys.byteorder != "little":
        arr.byteswap()
    with open(path, "wb") as fh:
        fh.write(arr.tobytes())


def impulses(f0s):
    """Validation-only source: unit pulse at the sample where the phase accumulator wraps."""
    out = []
    ph = 0.0
    for f in f0s:
        out.append(1.0 if ph == 0.0 else 0.0)
        ph = ph + f / FS
        if ph >= 1.0:
            ph = 0.0
    return out
