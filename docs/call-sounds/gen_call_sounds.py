#!/usr/bin/env python3
"""Q-Audion call sounds: original, fully synthesized, deterministic.

Every sample is computed here from sine partials, FM and a seeded noise
source. No recordings, no existing melodies, no third-party audio of any
kind are used. Running this script twice yields byte-identical files.

Output (48 kHz, mono, 16-bit PCM WAV), written next to this script:
  ringtone_<id>_loop.wav   seamless loop unit (3.5 - 5.6 s)
  ringtone_<id>_28s.wav    the same loop tiled to exactly 28 s
  cue_*.wav                call-progress and state cues
  preview/                 listening copies and preview_all.wav

Usage: python gen_call_sounds.py
Requires: Python 3.9+, numpy.
"""
import hashlib
import os
import wave

import numpy as np

SR = 48_000
HERE = os.path.dirname(os.path.abspath(__file__))
PEAK_DBFS = -1.0
RING_LUFS = -14.0
CUE_LUFS = -16.0


# --------------------------------------------------------------------------
# Notes (D Dorian pentatonic family, same tonal centre as the existing synths)
# --------------------------------------------------------------------------
def midi(m):
    return 440.0 * 2.0 ** ((m - 69) / 12.0)


D4, E4, G4, A4, B4 = (midi(m) for m in (62, 64, 67, 69, 71))
C5, D5, E5, G5, A5, B5 = (midi(m) for m in (72, 74, 76, 79, 81, 83))
D6, E6 = midi(86), midi(88)


# --------------------------------------------------------------------------
# Mixing buffer. circular=True wraps notes around the end, which makes a
# perfectly periodic (seamless) loop: a ringing tail continues over the seam.
# --------------------------------------------------------------------------
class Mix:
    def __init__(self, seconds, circular):
        self.n = int(round(seconds * SR))
        self.buf = np.zeros(self.n)
        self.circular = circular

    def add(self, sig, t0=0.0):
        i0 = int(round(t0 * SR))
        if self.circular:
            idx = (np.arange(len(sig)) + i0) % self.n
            np.add.at(self.buf, idx, sig)
        else:
            end = min(self.n, i0 + len(sig))
            if end > i0:
                self.buf[i0:end] += sig[: end - i0]

    def echo(self, taps):
        """Circular feedback-free multi-tap echo, [(delay_s, gain), ...]."""
        out = self.buf.copy()
        for d, g in taps:
            out += g * np.roll(self.buf, int(round(d * SR)))
        self.buf = out


def tt(dur):
    return np.arange(int(round(dur * SR))) / SR


def shape(sig, att=0.003, rel=0.02):
    """Short attack ramp and release fade so no note ever clicks."""
    n = len(sig)
    a = max(1, int(att * SR))
    r = max(1, min(n, int(rel * SR)))
    sig = sig.copy()
    sig[:a] *= np.linspace(0, 1, a, endpoint=False)
    sig[n - r:] *= 0.5 * (1 + np.cos(np.linspace(0, np.pi, r)))
    return sig


# --------------------------------------------------------------------------
# Voices
# --------------------------------------------------------------------------
BELLS = {
    # ratios, amplitudes, decay multipliers (relative to tau)
    "glass": ([1.0, 2.0, 2.76, 5.40, 8.93], [1.0, 0.45, 0.40, 0.18, 0.07], [1.0, 0.7, 0.5, 0.3, 0.15]),
    "chime": ([1.0, 2.32, 4.25, 6.63], [1.0, 0.35, 0.22, 0.10], [1.0, 0.55, 0.35, 0.2]),
    "soft": ([1.0, 2.0, 3.0], [1.0, 0.40, 0.18], [1.0, 0.6, 0.4]),
}


def bell(freq, dur, amp=1.0, tau=0.5, kind="glass"):
    t = tt(dur)
    ratios, amps, decs = BELLS[kind]
    out = np.zeros_like(t)
    for r, a, d in zip(ratios, amps, decs):
        f = freq * r
        if f < 18_000:
            out += a * np.sin(2 * np.pi * f * t) * np.exp(-t / (tau * d))
    return amp * shape(out, 0.002, 0.03) / sum(amps[:3])


def mallet(freq, dur, amp=1.0, tau=0.22):
    """Wooden bar: strong fundamental, ~4x and ~9.2x partials, short thump."""
    t = tt(dur)
    out = (np.sin(2 * np.pi * freq * t) * np.exp(-t / tau)
           + 0.40 * np.sin(2 * np.pi * freq * 3.93 * t) * np.exp(-t / (tau * 0.28))
           + 0.14 * np.sin(2 * np.pi * freq * 9.2 * t) * np.exp(-t / (tau * 0.10)))
    thump = np.sin(2 * np.pi * freq * 0.5 * t) * np.exp(-t / 0.012) * 0.25
    return amp * shape(out + thump, 0.001, 0.03) / 1.4


def pluck(freq, dur, amp=1.0, tau=0.35):
    """Plucked string-like tone: harmonics 1..6, higher ones die faster."""
    t = tt(dur)
    out = np.zeros_like(t)
    for n in range(1, 7):
        out += (1.0 / n) * np.sin(2 * np.pi * freq * n * t) * np.exp(-t / (tau / (0.6 + 0.4 * n)))
    return amp * shape(out, 0.002, 0.03) / 1.6


def soft_pulse(freq, dur, amp=1.0):
    """Round pulse: sine plus a little 2nd/3rd, smooth raised-cosine body."""
    t = tt(dur)
    body = np.sin(np.pi * t / dur) ** 2
    out = np.sin(2 * np.pi * freq * t) + 0.35 * np.sin(2 * np.pi * 2 * freq * t) + 0.12 * np.sin(2 * np.pi * 3 * freq * t)
    return amp * out * body / 1.4


def fm_blip(freq, dur, amp=1.0, ratio=2.0, index=1.6, tau=0.07):
    """Clear digital blip: FM with a fast-decaying modulation index."""
    t = tt(dur)
    idx = index * np.exp(-t / (tau * 0.8))
    out = np.sin(2 * np.pi * freq * t + idx * np.sin(2 * np.pi * freq * ratio * t)) * np.exp(-t / tau)
    return amp * shape(out, 0.002, 0.012)


def warm_tone(freq, dur, amp=1.0):
    """Warm sustained tone: three detuned voices, harmonics 1-4, slow swell."""
    t = tt(dur)
    out = np.zeros_like(t)
    for det in (-1.4, 0.0, 1.6):
        f = freq + det * freq / 440.0
        for h, a in ((1, 1.0), (2, 0.45), (3, 0.22), (4, 0.08)):
            out += a * np.sin(2 * np.pi * f * h * t + 0.7 * det)
    return amp * out * np.sin(np.pi * t / dur) ** 2 / 5.0


def two_tone(f1, f2, dur, alt_hz, amp=1.0):
    """Burst that alternates between two pitches (classic phone cadence)."""
    t = tt(dur)
    sel = (np.floor(t * alt_hz * 2) % 2) == 0
    out = np.zeros_like(t)
    seg = np.where(sel, f1, f2)
    ph = 2 * np.pi * np.cumsum(seg) / SR
    out = np.sin(ph) + 0.22 * np.sin(2 * ph)
    # smooth every pitch switch with a short crossfade-like gate
    sw = np.abs(np.diff(sel.astype(float), prepend=sel[0]))
    gate = np.ones_like(t)
    w = int(0.004 * SR)
    for i in np.nonzero(sw)[0]:
        a, b = max(0, i - w), min(len(t), i + w)
        gate[a:b] = np.minimum(gate[a:b], 0.15 + 0.85 * np.abs(np.linspace(-1, 1, b - a)))
    return amp * shape(out * gate, 0.012, 0.02) / 1.2


def tone(freq, dur, amp=1.0, att=0.008, rel=0.008):
    t = tt(dur)
    return amp * shape(np.sin(2 * np.pi * freq * t), att, rel)


# --------------------------------------------------------------------------
# Ringtones. Each returns (loop_seconds, mix) and tiles exactly into 28 s.
# --------------------------------------------------------------------------
def rt_vetro():
    m = Mix(4.0, True)
    for t0, f, a in ((0.00, A4, .8), (0.30, D5, .85), (0.60, E5, .9), (0.90, A5, 1.0),
                     (2.10, A4, .5), (2.40, D5, .55), (2.70, E5, .6), (3.00, A5, .65)):
        m.add(bell(f, 1.6, a, tau=0.55), t0)
    m.echo([(0.19, 0.22), (0.41, 0.10)])
    return m


def rt_impulso():
    m = Mix(3.5, True)
    for t0, f, a in ((0.00, A4, .9), (0.26, E5, 1.0), (0.52, A4, .9), (0.78, E5, 1.0),
                     (1.75, D5, .7), (2.01, A5, .8), (2.27, D5, .7), (2.53, A5, .8)):
        m.add(soft_pulse(f, 0.20, a), t0)
    m.echo([(0.13, 0.28), (0.29, 0.12)])
    return m


def rt_arpeggio():
    m = Mix(4.0, True)
    run1 = (D4, A4, D5, E5, G5, A5, E5, D5, A4)
    for i, f in enumerate(run1):
        m.add(pluck(f, 0.9, 0.9 if i < 6 else 0.7, tau=0.30), i * 0.14)
    run2 = (G4, D5, G5, A5, D6)
    for i, f in enumerate(run2):
        m.add(pluck(f, 1.2, 0.75 + 0.05 * i, tau=0.38), 2.05 + i * 0.14)
    m.echo([(0.21, 0.20), (0.42, 0.09)])
    return m


def rt_calore():
    m = Mix(5.6, True)
    # two swells: Dm(add9) then Gsus-like, each 2.2 s, a bell on top of each peak
    for t0, notes in ((0.00, (D4, A4, E5)), (2.80, (G4, D5, A5))):
        for f in notes:
            m.add(warm_tone(f, 2.4, 1.0), t0)
        m.add(bell(notes[2] * 2 if notes[2] * 2 < 1600 else notes[2], 2.0, 0.28, tau=0.7, kind="soft"), t0 + 0.9)
    m.echo([(0.31, 0.18)])
    return m


def rt_digitale():
    m = Mix(3.5, True)
    for g in (0.0, 1.3):
        for i, (f, d) in enumerate(((D5, 0.10), (A5, 0.10), (D6, 0.30))):
            m.add(fm_blip(f, d + 0.12, 0.9, ratio=2.0, index=1.5, tau=0.07 + 0.05 * (i == 2)), g + i * 0.13)
    m.echo([(0.17, 0.2)])
    return m


def rt_legno():
    m = Mix(4.0, True)
    for t0, f, a in ((0.00, D5, .9), (0.22, A5, 1.0), (0.44, G5, .9), (0.66, E5, 1.0),
                     (1.60, E5, .8), (1.82, G5, .85), (2.04, A5, .9), (2.26, D6, 1.0)):
        m.add(mallet(f, 0.9, a), t0)
    m.echo([(0.27, 0.16)])
    return m


def rt_duetto():
    m = Mix(4.0, True)
    for t0 in (0.0, 1.1):
        m.add(two_tone(A5, E5, 0.8, 16.0, 1.0), t0)
    m.echo([(0.15, 0.10)])
    return m


RINGTONES = [
    # id, Italian name, builder, description
    ("vetro", "Vetro", rt_vetro, "Glass bell, rising four-note figure and a softer echo phrase"),
    ("impulso", "Impulso", rt_impulso, "Soft rounded pulses in two rising pairs"),
    ("arpeggio", "Arpeggio", rt_arpeggio, "Minimal plucked arpeggio, up then down, then a short lift"),
    ("calore", "Calore", rt_calore, "Warm swelling chords with a quiet bell on top"),
    ("digitale", "Digitale", rt_digitale, "Clear three-note FM blips, repeated"),
    ("legno", "Legno", rt_legno, "Wooden marimba-like bars, two short phrases"),
    ("duetto", "Duetto", rt_duetto, "Two-tone phone-like warble, original timbre and pitches"),
]


# --------------------------------------------------------------------------
# Cues
# --------------------------------------------------------------------------
def cue_connecting():
    m = Mix(2.0, True)
    for t0, f, a in ((0.0, D5, 1.0), (0.5, A4, 0.9), (1.0, D5, 1.0), (1.5, E5, 1.0)):
        m.add(pluck(f, 0.45, a, tau=0.16), t0)
    m.echo([(0.12, 0.18)])
    return m


def cue_key_exchange():
    m = Mix(1.6, True)
    for i, f in enumerate((D5, E5, G5, A5, D6)):
        m.add(bell(f, 1.0, 0.7 + 0.07 * i, tau=0.28, kind="chime"), i * 0.10)
    return m


def cue_ringback():
    m = Mix(4.0, True)
    m.add(tone(425.0, 1.0, 1.0, att=0.06, rel=0.12), 0.0)
    return m


def cue_busy():
    m = Mix(3.0, False)
    for k in range(3):
        m.add(tone(425.0, 0.5, 1.0, att=0.008, rel=0.008), k * 1.0)
    return m


def cue_connected():
    m = Mix(0.85, False)
    for t0, f, a in ((0.00, D5, .8), (0.09, A5, .9), (0.18, D6, 1.0)):
        m.add(bell(f, 0.7, a, tau=0.20, kind="chime"), t0)
    return m


def cue_ended():
    m = Mix(0.9, False)
    for t0, f, a in ((0.00, A5, 1.0), (0.16, E5, .9), (0.32, D5, .9)):
        m.add(bell(f, 0.58, a, tau=0.17, kind="soft"), t0)
    return m


def cue_tick(rng):
    m = Mix(0.05, False)
    t = tt(0.05)
    click = np.sin(2 * np.pi * 1800 * t) * np.exp(-t / 0.004) + 0.5 * np.sin(2 * np.pi * 900 * t) * np.exp(-t / 0.006)
    noise = rng.standard_normal(len(t))
    noise = np.diff(noise, prepend=0.0) * np.exp(-t / 0.0012) * 0.15
    m.add(shape(click + noise, 0.0003, 0.012))
    return m


# id, filename, purpose
CUES = [
    ("connecting", "cue_connecting.wav", "Outgoing call being set up (looped)", True),
    ("ringback", "cue_ringback.wav", "Far end is ringing, 425 Hz, 1 s on / 3 s off (looped)", True),
    ("key_exchange", "cue_key_exchange.wav", "Keys being exchanged (looped)", True),
    ("connected", "cue_connected.wav", "Call connected, one shot", False),
    ("ended", "cue_ended.wav", "Call ended, one shot", False),
    ("busy", "cue_busy.wav", "Busy, 425 Hz 0.5 s on/off, 3 s", False),
    ("tick", "cue_dialing_tick.wav", "Dialing tick, played once when a call starts", False),
]


# --------------------------------------------------------------------------
# Loudness (ITU-R BS.1770 K-weighting, applied in the frequency domain, with
# absolute and relative gating) and level normalisation
# --------------------------------------------------------------------------
def k_weight(x):
    n = len(x)
    f = np.fft.rfftfreq(n, 1 / SR)
    z = np.exp(-1j * 2 * np.pi * f / SR)

    def H(b, a):
        return (b[0] + b[1] * z + b[2] * z ** 2) / (a[0] + a[1] * z + a[2] * z ** 2)

    h = H([1.53512485958697, -2.69169618940638, 1.19839281085285], [1.0, -1.69065929318241, 0.73248077421585])
    h *= H([1.0, -2.0, 1.0], [1.0, -1.99004745483398, 0.99007225036621])
    return np.fft.irfft(np.fft.rfft(x) * h, n)


def lufs(x):
    y = k_weight(x)
    blk, hop = int(0.4 * SR), int(0.1 * SR)
    if len(y) <= blk:
        ms = np.array([np.mean(y ** 2)])
    else:
        ms = np.array([np.mean(y[i:i + blk] ** 2) for i in range(0, len(y) - blk + 1, hop)])
    ms = np.maximum(ms, 1e-12)
    l = -0.691 + 10 * np.log10(ms)
    keep = l > -70
    if not keep.any():
        return -70.0
    rel = -0.691 + 10 * np.log10(ms[keep].mean()) - 10
    keep &= l > rel
    return -0.691 + 10 * np.log10(ms[keep].mean())


def soft_limit(x, ceil, knee=0.6):
    k = knee * ceil
    a = np.abs(x)
    over = a > k
    y = x.copy()
    y[over] = np.sign(x[over]) * (k + (ceil - k) * np.tanh((a[over] - k) / (ceil - k)))
    return y


def normalise(x, target_lufs=None, peak_only=False):
    ceil = 10 ** (PEAK_DBFS / 20)
    if peak_only:
        return x * (ceil / np.max(np.abs(x)))
    x = x / np.max(np.abs(x))
    for _ in range(6):
        g = 10 ** ((target_lufs - lufs(x)) / 20)
        x = soft_limit(x * g, ceil)
    # final safety: exact peak ceiling
    p = np.max(np.abs(x))
    if p > ceil:
        x = x * (ceil / p)
    return x


# --------------------------------------------------------------------------
# I/O and checks
# --------------------------------------------------------------------------
def to_pcm(x):
    return np.clip(np.round(x * 32767), -32768, 32767).astype(np.int16)


def write_wav(path, pcm):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.astype("<i2").tobytes())


def seam_check(pcm):
    """Loop seam continuity on the final 16-bit data.

    Compares the step across the wrap (last -> first sample) with the largest
    ordinary sample-to-sample step within 10 ms either side of the seam.
    Pass when the seam step is not larger than that local maximum (or both
    are essentially silent).
    """
    x = pcm.astype(float) / 32768
    w = int(0.010 * SR)
    seam = abs(x[0] - x[-1])
    around = np.concatenate([x[-w:], x[:w]])
    d = np.abs(np.diff(around))
    d = np.delete(d, w - 1)  # remove the seam step itself
    local = d.max()
    ok = seam <= max(local, 2e-4)
    return seam, local, ok


def band_fraction(x, lo, hi):
    s = np.abs(np.fft.rfft(x)) ** 2
    f = np.fft.rfftfreq(len(x), 1 / SR)
    return s[(f >= lo) & (f <= hi)].sum() / s.sum()


def db(v):
    return 20 * np.log10(max(v, 1e-9))


def main():
    rng = np.random.default_rng(20261020)
    os.makedirs(HERE, exist_ok=True)
    prev = os.path.join(HERE, "preview")
    os.makedirs(prev, exist_ok=True)

    order = []   # (preview name, samples as float) in CALL_SOUNDS.md order
    rows = []

    def record(name, x, pcm, loop):
        pk = np.max(np.abs(pcm)) / 32768
        rms = np.sqrt(np.mean((pcm / 32768.0) ** 2))
        l = lufs(pcm / 32768.0)
        row = [name, len(pcm) / SR, db(pk), db(rms), l]
        if loop:
            s, loc, ok = seam_check(pcm)
            row += [s, loc, "OK" if ok else "FAIL"]
        rows.append(row)

    # ringtones
    for rid, label, builder, _ in RINGTONES:
        m = builder()
        x = normalise(m.buf, RING_LUFS)
        pcm = to_pcm(x)
        write_wav(os.path.join(HERE, f"ringtone_{rid}_loop.wav"), pcm)
        record(f"ringtone_{rid}_loop", x, pcm, True)
        reps = int(round(28.0 / (len(pcm) / SR)))
        assert abs(reps * len(pcm) - 28 * SR) < 1, rid
        full = np.tile(pcm.astype(float), reps)
        # 28 s file: tiny fade-in, short fade-out so it also ends cleanly
        full[: int(0.003 * SR)] *= np.linspace(0, 1, int(0.003 * SR), endpoint=False)
        r = int(0.05 * SR)
        full[-r:] *= 0.5 * (1 + np.cos(np.linspace(0, np.pi, r)))
        pcm28 = np.round(full).astype(np.int16)
        write_wav(os.path.join(HERE, f"ringtone_{rid}_28s.wav"), pcm28)
        record(f"ringtone_{rid}_28s", None, pcm28, False)
        order.append((f"ringtone_{rid}", pcm.astype(float) / 32768, True))

    # cues
    builders = {
        "connecting": cue_connecting, "ringback": cue_ringback, "key_exchange": cue_key_exchange,
        "connected": cue_connected, "ended": cue_ended, "busy": cue_busy, "tick": lambda: cue_tick(rng),
    }
    for cid, fname, _, loop in CUES:
        m = builders[cid]()
        if cid == "tick":
            x = normalise(m.buf, peak_only=True)
        else:
            x = normalise(m.buf, CUE_LUFS)
        pcm = to_pcm(x)
        write_wav(os.path.join(HERE, fname), pcm)
        record(fname[:-4], x, pcm, loop)
        order.append((fname[:-4], pcm.astype(float) / 32768, loop))
        if cid == "connecting":
            band = band_fraction(x, 400, 2500)
            low = band_fraction(x, 0, 300)
            print(f"connecting band energy 400-2500 Hz: {band:.1%}, below 300 Hz: {low:.2%}")

    # previews: loops repeated to >= 8 s so the loop point can be heard
    gap = np.zeros(SR)
    allp = []
    for name, x, loop in order:
        if loop:
            reps = int(np.ceil(8.0 / (len(x) / SR)))
            x = np.tile(x, reps)
        write_wav(os.path.join(prev, f"{name}.wav"), to_pcm(x))
        allp += [x, gap]
    write_wav(os.path.join(prev, "preview_all.wav"), to_pcm(np.concatenate(allp[:-1])))

    print(f"{'file':32s} {'sec':>6s} {'peak':>7s} {'rms':>7s} {'LUFS':>7s}  seam(step/local/ok)")
    for r in rows:
        tail = f"  {r[5]:.5f} / {r[6]:.5f} / {r[7]}" if len(r) > 5 else ""
        print(f"{r[0]:32s} {r[1]:6.3f} {r[2]:7.2f} {r[3]:7.2f} {r[4]:7.2f}{tail}")
    with open(os.path.abspath(__file__), "rb") as f:
        print("generator sha256:", hashlib.sha256(f.read()).hexdigest())


if __name__ == "__main__":
    main()
