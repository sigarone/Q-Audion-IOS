"""Reference implementation of docs/voice-analysis-spec.md (remote-voice analysis, binding for Android and iOS).

Pure Python 3 (no numpy). Every section maps to the section of docs/voice-analysis-spec.md with the same number.
All arithmetic is IEEE-754 binary64. Python's built-in sum() of floats is compensated
(CPython >= 3.12); docs/voice-analysis-spec.md section 0 says summation order is not normative and the vector
tolerances absorb the difference.

Entry points
    eng = Engine()
    results = eng.process(chunk)       # chunk: sequence of int16 ints; returns list of Result dicts
    eng.discontinuity(gap_samples)     # audio missing between the last and the next chunk
    eng.reset()                        # call end / engine reset
    Display().push(result) -> dict     # SPEC section 9 (1 s validity-weighted mean)

Command line
    python ref.py <file.raw> [chunk_ms]   prints one TSV row per step (int16 LE mono 48 kHz input)
"""
import cmath
import math
import sys
from operator import mul, sub

# ----------------------------------------------------------------------------------------------
# 1. Framing and cadence
FS = 48000
WIN = 2880                 # 60 ms analysis window
HOP = 4800                 # one analysis per 100 ms of audio time
FRAME = 480                # 10 ms envelope frame
FRAMES_PER_STEP = HOP // FRAME
LONG_GAP_SAMPLES = 96000   # a gap of 2 s or more clears everything

# 3. Front end
DEC = 3
FS16 = FS // DEC
FIR_TAPS = 63
FIR_MID = (FIR_TAPS - 1) // 2
FIR_CUTOFF_HZ = 7000.0
N16 = (WIN - FIR_TAPS) // DEC + 1          # 940; (2880 - 63) is divisible by 3

# 4. Pitch and voicing
SILENCE_RMS = 1.0e-4
TAU_MIN = 36               # 444.4 Hz
TAU_MAX = 270              # 59.26 Hz
YIN_W = N16 - TAU_MAX      # 670-sample integration window
YIN_ABS = 0.15
YIN_REL = 0.05
VOICED_PERIODICITY = 0.45
F0_MIN = 60.0
F0_MAX = 400.0

# 5. HNR
HNR_HALF_SPAN = 2
R_MIN = 1.0e-4
R_MAX = 0.9999
HNR_CAP_DB = 40.0
HNR_KEEP = 5
HNR_MIN_VOICED = 3
HNR_HOLD_STEPS = 10

# 6. Formants
PRE_EMPHASIS = 0.97
LPC_ORDER = 18
WHITE_NOISE_CORRECTION = 1.0e-6
FORMANT_MIN_HZ = 90.0
BW_MAX_HZ = 300.0
F2_IGNORE_BW_HZ = 500.0    # roots this wide model spectral tilt, not a resonance (SPEC 6.5)
F1_LO, F1_HI = 200.0, 1100.0
F2_LO, F2_HI = 600.0, 3200.0
HARMONIC_RATIO = 2.5
MEDIAN_KEEP = 3
LAG_EPS = 1.0e-14          # Laguerre convergence scale
LAG_MR = 8
LAG_MT = 10
LAG_MAXIT = LAG_MR * LAG_MT
LAG_FRAC = (0.0, 0.5, 0.25, 0.75, 0.13, 0.38, 0.62, 0.88, 1.0)

# 7. Speech rate
SPAN_FRAMES = 600          # 6 s
LOOKBACK_FRAMES = 30       # 300 ms
RING_FRAMES = SPAN_FRAMES + LOOKBACK_FRAMES
ENERGY_FLOOR = 1.0e-10     # -100 dB
ACTIVE_RANGE_DB = 25.0
DIP_DB = 3.0
REFRACTORY_FRAMES = 10
PAUSE_MIN_FRAMES = 30      # an inactive run is a pause when LONGER than this
MIN_SPEAKING_FRAMES = 200  # 2 s
RATE_MAX = 12.0

# 9. Display
DISPLAY_STEPS = 10         # 1 s of audio time


# ----------------------------------------------------------------------------------------------
# 3. Front end
def _make_fir():
    wc = 2.0 * math.pi * FIR_CUTOFF_HZ / FS
    h = []
    for k in range(FIR_TAPS):
        m = k - FIR_MID
        ideal = wc / math.pi if m == 0 else math.sin(wc * m) / (math.pi * m)
        h.append(ideal * (0.54 - 0.46 * math.cos(2.0 * math.pi * k / (FIR_TAPS - 1))))
    g = sum(h)
    return [v / g for v in h]


FIR = _make_fir()


def front_end(window):
    """window: 2880 floats, oldest first. Returns (xc, rms, y16)."""
    mean = sum(window) / WIN
    xc = [v - mean for v in window]
    rms = math.sqrt(sum(map(mul, xc, xc)) / WIN)
    y = [sum(map(mul, FIR, xc[DEC * m:DEC * m + FIR_TAPS])) for m in range(N16)]
    return xc, rms, y


# ----------------------------------------------------------------------------------------------
# 4. Pitch and voicing (YIN on the 16 kHz view)
def yin_cmnd(y):
    head = y[:YIN_W]
    cm = [1.0] * (TAU_MAX + 1)
    run = 0.0
    for tau in range(1, TAU_MAX + 1):
        diff = list(map(sub, head, y[tau:tau + YIN_W]))
        d = sum(map(mul, diff, diff))
        run += d
        cm[tau] = d * tau / run if run > 0.0 else 1.0
    return cm


def yin_pick(cm, thr):
    """Lowest point of the first stretch of tau in [TAU_MIN, TAU_MAX] with cm < thr."""
    tau = TAU_MIN
    while cm[tau] >= thr:
        tau += 1
    best = tau
    tau += 1
    while tau <= TAU_MAX and cm[tau] < thr:
        if cm[tau] < cm[best]:
            best = tau
        tau += 1
    return best


def pitch(y, rms, margins=None):
    out = {"voiced": False, "f0": 0.0, "periodicity": 0.0, "lag16": 0.0}
    if rms < SILENCE_RMS:
        if margins is not None:
            margins["rms_floor"] = abs(rms - SILENCE_RMS) / SILENCE_RMS
        return out
    cm = yin_cmnd(y)
    gmin = min(cm[TAU_MIN:TAU_MAX + 1])
    thr = max(YIN_ABS, gmin + YIN_REL)
    best = yin_pick(cm, thr)
    lag = float(best)
    if TAU_MIN < best < TAU_MAX:
        a, b, c = cm[best - 1], cm[best], cm[best + 1]
        den = a - 2.0 * b + c
        if den > 0.0:
            lag = best + max(-0.5, min(0.5, 0.5 * (a - c) / den))
    f0c = FS16 / lag
    per = max(0.0, min(1.0, 1.0 - cm[best]))
    voiced = per >= VOICED_PERIODICITY and F0_MIN <= f0c <= F0_MAX
    out["periodicity"] = per
    out["lag16"] = lag
    out["f0_candidate"] = f0c
    if voiced:
        out["voiced"] = True
        out["f0"] = f0c
    if margins is not None:
        margins["rms_floor"] = abs(rms - SILENCE_RMS) / SILENCE_RMS
        margins["periodicity"] = abs(per - VOICED_PERIODICITY)
        margins["f0_range"] = min(abs(f0c - F0_MIN), abs(f0c - F0_MAX))
        # candidate stability under a tiny threshold change and near-ties inside the stretch
        stable = yin_pick(cm, thr * (1.0 + 1e-9)) == best and yin_pick(cm, thr * (1.0 - 1e-9)) == best
        margins["yin_pick_stable"] = 1.0 if stable else 0.0
        lo = best
        while lo > TAU_MIN and cm[lo - 1] < thr:
            lo -= 1
        hi = best
        while hi < TAU_MAX and cm[hi + 1] < thr:
            hi += 1
        tie = min([abs(cm[t] - cm[best]) for t in range(lo, hi + 1) if t != best] or [1.0])
        margins["yin_tie"] = tie
    return out


# ----------------------------------------------------------------------------------------------
# 5. HNR (Boersma, 48 kHz window)
HANN = [0.5 - 0.5 * math.cos(2.0 * math.pi * (i + 0.5) / WIN) for i in range(WIN)]
_HANN_AC = {}


def hann_ac(tau):
    v = _HANN_AC.get(tau)
    if v is None:
        v = sum(map(mul, HANN[:WIN - tau], HANN[tau:]))
        _HANN_AC[tau] = v
    return v


def hnr_instant(xc, f0, margins=None):
    """Returns (hnr_db, r) for a voiced window."""
    a = list(map(mul, xc, HANN))
    ra0 = sum(map(mul, a, a))
    rw0 = hann_ac(0)
    period = FS / f0
    lc = int(math.floor(period + 0.5))
    taus = list(range(lc - HNR_HALF_SPAN, lc + HNR_HALF_SPAN + 1))
    rs = []
    for tau in taus:
        ra = sum(map(mul, a[:WIN - tau], a[tau:]))
        rs.append((ra / ra0) / (hann_ac(tau) / rw0))
    k = 0
    for i in range(1, len(rs)):
        if rs[i] > rs[k]:
            k = i
    r = rs[k]
    if 0 < k < len(rs) - 1:
        ya, yb, yc = rs[k - 1], rs[k], rs[k + 1]
        den = ya - 2.0 * yb + yc
        if den < 0.0:
            r = yb - (ya - yc) * (ya - yc) / (8.0 * den)
    r = max(R_MIN, min(R_MAX, r))
    h = min(HNR_CAP_DB, 10.0 * math.log10(r / (1.0 - r)))
    if margins is not None:
        frac = period - math.floor(period)
        margins["hnr_lag_round"] = abs(frac - 0.5)
        s = sorted(rs)
        margins["hnr_max_tie"] = s[-1] - s[-2]
    return h, r


class HnrTracker:
    def __init__(self):
        self.reset()

    def reset(self):
        self.vals = []           # (hnr_db, r) of the last HNR_KEEP voiced windows
        self.voiced_count = 0
        self.since_voiced = None  # steps since the last voiced window (None: never)

    def step(self, xc, p, margins=None):
        if p["voiced"]:
            h, r = hnr_instant(xc, p["f0"], margins)
            self.vals.append((h, r))
            if len(self.vals) > HNR_KEEP:
                self.vals.pop(0)
            self.voiced_count += 1
            self.since_voiced = 0
        elif self.since_voiced is not None:
            self.since_voiced += 1
        valid = (self.voiced_count >= HNR_MIN_VOICED and self.since_voiced is not None
                 and self.since_voiced <= HNR_HOLD_STEPS)
        if not valid:
            return 0.0, False, 0.0
        n = len(self.vals)
        hnr = sum(v[0] for v in self.vals) / n
        breath = sum(1.0 - v[1] for v in self.vals) / n
        return hnr, True, breath


# ----------------------------------------------------------------------------------------------
# 6. Formants (LPC on the 16 kHz view)
_M = N16 - 1
HAMMING_LPC = [0.54 - 0.46 * math.cos(2.0 * math.pi * i / (_M - 1)) for i in range(_M)]


def lpc(y):
    """Returns the 19 coefficients [1, a1..a18] or None."""
    p = [y[n] - PRE_EMPHASIS * y[n - 1] for n in range(1, N16)]
    s = list(map(mul, p, HAMMING_LPC))
    r = [sum(map(mul, s[:_M - k], s[k:])) for k in range(LPC_ORDER + 1)]
    r[0] *= 1.0 + WHITE_NOISE_CORRECTION
    if not r[0] > 0.0:
        return None
    a = [1.0] + [0.0] * LPC_ORDER
    err = r[0]
    for i in range(1, LPC_ORDER + 1):
        acc = r[i]
        for j in range(1, i):
            acc += a[j] * r[i - j]
        k = -acc / err
        if abs(k) >= 1.0:
            return None
        prev = a[:]
        for j in range(1, i):
            a[j] = prev[j] + k * prev[i - j]
        a[i] = k
        err *= 1.0 - k * k
        if not err > 0.0:
            return None
    return a


def _laguer(a, m, x):
    """Numerical Recipes laguer: one root of sum a[j] x^j (j = 0..m), started at x. (root, ok)."""
    for it in range(1, LAG_MAXIT + 1):
        b = a[m]
        err = abs(b)
        d = 0j
        f = 0j
        abx = abs(x)
        for j in range(m - 1, -1, -1):
            f = x * f + d
            d = x * d + b
            b = x * b + a[j]
            err = abs(b) + abx * err
        err *= LAG_EPS
        if abs(b) <= err:
            return x, True
        g = d / b
        g2 = g * g
        h = g2 - 2.0 * f / b
        sq = cmath.sqrt((m - 1) * (m * h - g2))
        gp = g + sq
        gm = g - sq
        abp = abs(gp)
        abm = abs(gm)
        if abp < abm:
            gp = gm
        if max(abp, abm) > 0.0:
            dx = m / gp
        else:
            dx = (1.0 + abx) * complex(math.cos(it), math.sin(it))
        x1 = x - dx
        if x1 == x:
            return x, True
        if it % LAG_MT != 0:
            x = x1
        else:
            x = x - LAG_FRAC[it // LAG_MT] * dx
    return x, False


def poly_roots(a):
    """Roots of z^18 + a1 z^17 + ... + a18 (a = [1, a1..a18]). None if Laguerre failed."""
    m = LPC_ORDER
    asc = [complex(a[m - j], 0.0) for j in range(m + 1)]
    ad = asc[:]
    roots = []
    for j in range(m, 0, -1):
        x, ok = _laguer(ad, j, 0j)
        if not ok:
            return None
        if abs(x.imag) <= 2.0 * LAG_EPS * abs(x.real):
            x = complex(x.real, 0.0)
        roots.append(x)
        b = ad[j]
        for jj in range(j - 1, -1, -1):
            c = ad[jj]
            ad[jj] = b
            b = x * b + c
    out = []
    for z in roots:
        x, ok = _laguer(asc, m, z)
        if not ok:
            return None
        out.append(x)
    return out


def root_table(y):
    """Upper-half-plane roots as sorted [(freq_hz, bw_hz, mag)], or None on failure."""
    a = lpc(y)
    if a is None:
        return None
    roots = poly_roots(a)
    if roots is None:
        return None
    tab = []
    for z in roots:
        if not z.imag > 0.0:
            continue
        mag = abs(z)
        freq = math.atan2(z.imag, z.real) * FS16 / (2.0 * math.pi)
        bw = -math.log(mag) * FS16 / math.pi if mag > 0.0 else float("inf")
        tab.append((freq, bw, mag))
    tab.sort()
    return tab


def select_formants(tab, f0, d=None):
    """SPEC 6.5. d: optional threshold perturbations {name: delta} for the stability check."""
    d = d or {}
    fmin = FORMANT_MIN_HZ + d.get("fmin", 0.0)
    bwmax = BW_MAX_HZ + d.get("bw", 0.0)
    f1lo, f1hi = F1_LO + d.get("f1lo", 0.0), F1_HI + d.get("f1hi", 0.0)
    f2lo, f2hi = F2_LO + d.get("f2lo", 0.0), F2_HI + d.get("f2hi", 0.0)
    gate = HARMONIC_RATIO * f0 + d.get("gate", 0.0)
    ignore = F2_IGNORE_BW_HZ + d.get("ignore", 0.0)

    def kept(e):
        return e[2] < 1.0 and e[0] > fmin and e[1] < bwmax

    f1raw = None
    for e in tab:
        if kept(e) and f1lo <= e[0] <= f1hi:
            f1raw = e
            break
    if f1raw is None:
        return None, None
    f1 = f1raw[0] if f1raw[0] >= gate else None
    f2 = None
    for e in tab:
        if e[1] >= ignore:
            continue
        if e[0] > f1raw[0] and f2lo <= e[0] <= f2hi:
            if kept(e) and e[0] >= gate:
                f2 = e[0]
            break
    return f1, f2


_PERTURB = [{k: s * v} for k, v in (("fmin", 0.01), ("bw", 0.01), ("f1lo", 0.01), ("f1hi", 0.01),
                                    ("f2lo", 0.01), ("f2hi", 0.01), ("gate", 0.01), ("ignore", 0.01)) for s in (1.0, -1.0)]


def _median(h):
    s = sorted(h)
    n = len(s)
    return s[n // 2] if n % 2 == 1 else 0.5 * (s[n // 2 - 1] + s[n // 2])


class FormantTracker:
    def __init__(self):
        self.reset()

    def reset(self):
        self.h1 = []
        self.h2 = []

    def step(self, y, p, margins=None, debug=None):
        if not p["voiced"]:
            self.h1 = []
            self.h2 = []
            return 0.0, False, 0.0, False
        tab = root_table(y)
        if debug is not None:
            debug["roots"] = tab
        if tab is None:
            if margins is not None:
                margins["root_fail"] = 1.0
            return 0.0, False, 0.0, False
        f1, f2 = select_formants(tab, p["f0"])
        if margins is not None:
            stable = True
            for dd in _PERTURB:
                g1, g2 = select_formants(tab, p["f0"], dd)
                if (g1 is None) != (f1 is None) or (g2 is None) != (f2 is None) or \
                        (g1 is not None and g1 != f1) or (g2 is not None and g2 != f2):
                    stable = False
                    break
            margins["formant_stable"] = 1.0 if stable else 0.0
            margins["root_mag"] = min([1.0 - e[2] for e in tab] or [1.0])
        out1 = (0.0, False)
        out2 = (0.0, False)
        if f1 is not None:
            self.h1.append(f1)
            if len(self.h1) > MEDIAN_KEEP:
                self.h1.pop(0)
            out1 = (_median(self.h1), True)
        if f2 is not None:
            self.h2.append(f2)
            if len(self.h2) > MEDIAN_KEEP:
                self.h2.pop(0)
            out2 = (_median(self.h2), True)
        return out1[0], out1[1], out2[0], out2[1]


# ----------------------------------------------------------------------------------------------
# 7. Speech rate
class RateTracker:
    def __init__(self):
        self.reset()

    def reset(self):
        self.db = [0.0] * RING_FRAMES
        self.vo = [False] * RING_FRAMES
        self.nf = 0                  # committed frames since reset
        self.started = False
        self.seek_peak = True
        self.pk = 0.0
        self.pk_idx = 0
        self.vl = 0.0
        self.prec_valley = 0.0
        self.last_nucleus = None
        self.nuclei = []

    def _zigzag(self, i, margins):
        x = self.db[i % RING_FRAMES]
        if not self.started:
            self.started = True
            self.seek_peak = True
            self.pk = x
            self.pk_idx = i
            self.prec_valley = x
            return
        if margins is not None and x != (self.pk if self.seek_peak else self.vl):
            _mm(margins, "zigzag_tie", abs(x - (self.pk if self.seek_peak else self.vl)))
        if self.seek_peak:
            if x > self.pk:
                self.pk = x
                self.pk_idx = i
            else:
                if margins is not None and self.pk - x != 0.0:
                    _mm(margins, "zigzag", abs(self.pk - x - DIP_DB))
                if self.pk - x >= DIP_DB:
                    self._confirm(margins)
                    self.seek_peak = False
                    self.vl = x
        else:
            if x < self.vl:
                self.vl = x
            else:
                if margins is not None and x - self.vl != 0.0:
                    _mm(margins, "zigzag", abs(x - self.vl - DIP_DB))
                if x - self.vl >= DIP_DB:
                    self.prec_valley = self.vl
                    self.seek_peak = True
                    self.pk = x
                    self.pk_idx = i

    def _confirm(self, margins):
        p = self.pk_idx
        if margins is not None:
            _mm(margins, "zigzag", abs(self.pk - self.prec_valley - DIP_DB))
        if self.pk - self.prec_valley < DIP_DB:
            return
        if not self.vo[p % RING_FRAMES]:
            return
        if self.last_nucleus is not None and p - self.last_nucleus < REFRACTORY_FRAMES:
            return
        self.last_nucleus = p
        self.nuclei.append(p)

    def step(self, frame_energies, voiced, margins=None):
        for e in frame_energies:
            i = self.nf
            self.db[i % RING_FRAMES] = 10.0 * math.log10(e if e > ENERGY_FLOOR else ENERGY_FLOOR)
            self.vo[i % RING_FRAMES] = voiced
            self.nf += 1
        for i in range(self.nf - len(frame_energies), self.nf):
            self._zigzag(i, margins)
        nf = self.nf
        n = min(nf, SPAN_FRAMES)
        start = nf - n
        while self.nuclei and self.nuclei[0] < start:
            self.nuclei.pop(0)
        level = None
        for i in range(start, nf):
            if self.vo[i % RING_FRAMES]:
                v = self.db[i % RING_FRAMES]
                if level is None or v > level:
                    level = v
        lb = max(0, start - LOOKBACK_FRAMES)

        def active(i):
            if level is None:
                return False
            v = self.db[i % RING_FRAMES]
            if margins is not None:
                _mm(margins, "active", abs(v - (level - ACTIVE_RANGE_DB)))
            return v >= level - ACTIVE_RANGE_DB

        pause = 0
        run_start = None
        for i in range(lb, nf):
            if active(i):
                if run_start is not None and i - run_start > PAUSE_MIN_FRAMES and i > start:
                    pause += i - max(run_start, start)
                run_start = None
            elif run_start is None:
                run_start = i
        if run_start is not None and nf - run_start > PAUSE_MIN_FRAMES:
            pause += nf - max(run_start, start)
        speaking = n - pause
        speaking_now = any(active(i) for i in range(nf - FRAMES_PER_STEP, nf))
        if speaking < MIN_SPEAKING_FRAMES:
            return 0.0, False, 0.0, speaking_now
        count = len(self.nuclei)
        rate = max(0.0, min(RATE_MAX, count / (speaking * 0.01)))
        return rate, True, pause / n, speaking_now


def _mm(margins, key, v):
    old = margins.get(key)
    if old is None or v < old:
        margins[key] = v


# ----------------------------------------------------------------------------------------------
# 1, 2, 8. Engine
FIELDS = ("f0", "f0Valid", "voiced", "periodicity", "F1", "F1Found", "F2", "F2Found",
          "HNR", "hnrValid", "breathiness", "rate", "rateValid", "pauseRatio", "isSpeaking", "rms")


DISPLAY_FIELDS = tuple(k for k in FIELDS if k != "periodicity")


class Engine:
    def __init__(self, track_margins=False, debug=False):
        self.track_margins = track_margins
        self.debug = debug
        self.formants = FormantTracker()
        self.hnr = HnrTracker()
        self.rate = RateTracker()
        self.reset()

    def reset(self):
        """Call end, engine reset, or a gap of 2 s or more: clears everything."""
        self.ring = [0.0] * WIN
        self.wpos = 0
        self._restart()
        self.formants.reset()
        self.hnr.reset()
        self.rate.reset()
        self.stress_rms = []      # SPEC 8: voiced-only mean-removed window RMS
        self.step_index = 0

    def _restart(self):
        self.seg = 0              # samples since the segment started
        self.frame_acc = 0.0
        self.frame_n = 0
        self.frames = []          # energies of the complete frames of the current step

    def discontinuity(self, gap_samples):
        """Audio of length gap_samples (48 kHz samples) is missing before the next chunk."""
        if gap_samples >= LONG_GAP_SAMPLES:
            self.reset()
        else:
            self._restart()

    def process(self, chunk):
        out = []
        ring = self.ring
        for s in chunk:
            v = s / 32768.0
            ring[self.wpos] = v
            self.wpos += 1
            if self.wpos == WIN:
                self.wpos = 0
            self.frame_acc += v * v
            self.frame_n += 1
            if self.frame_n == FRAME:
                self.frames.append(self.frame_acc / FRAME)
                self.frame_acc = 0.0
                self.frame_n = 0
            self.seg += 1
            if self.seg % HOP == 0:
                out.append(self._analyze())
        return out

    def _analyze(self):
        m = {} if self.track_margins else None
        dbg = {} if self.debug else None
        window = self.ring[self.wpos:] + self.ring[:self.wpos]
        xc, rms, y = front_end(window)
        p = pitch(y, rms, m)
        f1, f1ok, f2, f2ok = self.formants.step(y, p, m, dbg)
        hnr, hnr_ok, breath = self.hnr.step(xc, p, m)
        rate, rate_ok, pause, speaking = self.rate.step(self.frames, p["voiced"], m)
        self.frames = []
        if p["voiced"]:
            self.stress_rms.append(rms)
            if len(self.stress_rms) > 25:
                self.stress_rms.pop(0)
        res = {
            "f0": p["f0"], "f0Valid": p["voiced"], "voiced": p["voiced"],
            "periodicity": p["periodicity"],
            "F1": f1, "F1Found": f1ok, "F2": f2, "F2Found": f2ok,
            "HNR": hnr, "hnrValid": hnr_ok, "breathiness": breath,
            "rate": rate, "rateValid": rate_ok, "pauseRatio": pause, "isSpeaking": speaking,
            "rms": rms,
        }
        if m is not None:
            res["_margins"] = m
        if dbg is not None:
            dbg["f0_candidate"] = p.get("f0_candidate", 0.0)
            res["_debug"] = dbg
        self.step_index += 1
        return res


# ----------------------------------------------------------------------------------------------
# 9. Display: 1 s validity-weighted mean over the last 10 results
class Display:
    def __init__(self):
        self.reset()

    def reset(self):
        self.hist = []

    def push(self, r):
        self.hist.append(r)
        if len(self.hist) > DISPLAY_STEPS:
            self.hist.pop(0)
        h = self.hist

        def vmean(flag, key):
            vals = [x[key] for x in h if x[flag]]
            return (sum(vals) / len(vals), True) if vals else (0.0, False)

        f0, f0ok = vmean("f0Valid", "f0")
        f1, f1ok = vmean("F1Found", "F1")
        f2, f2ok = vmean("F2Found", "F2")
        hnr, hok = vmean("hnrValid", "HNR")
        br, _ = vmean("hnrValid", "breathiness")
        rate, rok = vmean("rateValid", "rate")
        pr, _ = vmean("rateValid", "pauseRatio")
        n = len(h)
        return {
            "f0": f0, "f0Valid": f0ok,
            "voiced": sum(1 for x in h if x["voiced"]) * 2 > n,
            "F1": f1, "F1Found": f1ok, "F2": f2, "F2Found": f2ok,
            "HNR": hnr, "hnrValid": hok, "breathiness": br,
            "rate": rate, "rateValid": rok, "pauseRatio": pr,
            "isSpeaking": sum(1 for x in h if x["isSpeaking"]) * 2 > n,
            "rms": sum(x["rms"] for x in h) / n,
        }


def run(pcm, chunk_samples, events=None, track_margins=False):
    """Feed pcm (list of int16) in chunks; events: list of (sample_index, gap_samples)."""
    eng = Engine(track_margins=track_margins)
    ev = sorted(events or [])
    cuts = sorted(set([0, len(pcm)] + [e[0] for e in ev]))
    out = []
    ei = 0
    for a, b in zip(cuts[:-1], cuts[1:]):
        while ei < len(ev) and ev[ei][0] == a:
            eng.discontinuity(ev[ei][1])
            ei += 1
        i = a
        while i < b:
            j = min(b, i + chunk_samples)
            out.extend(eng.process(pcm[i:j]))
            i = j
    return out


def _read_raw(path):
    import array
    arr = array.array("h")
    with open(path, "rb") as fh:
        arr.frombytes(fh.read())
    if sys.byteorder != "little":
        arr.byteswap()
    return arr.tolist()


if __name__ == "__main__":
    pcm = _read_raw(sys.argv[1])
    ms = int(sys.argv[2]) if len(sys.argv) > 2 else 10
    print("\t".join(FIELDS))
    for r in run(pcm, ms * 48):
        print("\t".join(("1" if r[k] else "0") if isinstance(r[k], bool) else "%.9g" % r[k] for k in FIELDS))
