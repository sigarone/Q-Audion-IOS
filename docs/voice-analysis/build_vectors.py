"""Builds vectors.json from gen.py + ref.py. Run: python3 build_vectors.py [out.json] [rawdir]

For every case: generate the int16 input, run ref.py with every chunk size listed (results must be
identical), check that no decision of any step sits within floating-point reach of its threshold
(docs/voice-analysis-spec.md appendix V), and store the expected per-step outputs.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen
import ref

A120 = {"type": "voice", "f0": 120.0, "vowel": "a"}


def voice(dur, **kw):
    d = {"type": "voice", "dur_s": dur, "rms": 0.1}
    d.update(kw)
    return d


SYL4 = {"rate": 4.0, "per_block": 6, "pause_s": 0.5}
SYL6 = {"rate": 6.0, "per_block": 9, "pause_s": 0.5}
SWEEP = [62, 70, 80, 90, 100, 110, 125, 140, 160, 180, 200, 225, 250, 280, 310, 340, 370, 395]

CASES = [
    # name, description, case, chunk sizes (ms), display?
    ("vowel_a_100", "/a/ 700/1220/2600 Hz, f0 100 Hz, rms 0.1", {"segments": [voice(1.2, f0=100.0, vowel="a")]}, [10, 20, 60], False),
    ("vowel_a_220", "/a/, f0 220 Hz", {"segments": [voice(1.2, f0=220.0, vowel="a")]}, [10, 20, 60], False),
    ("vowel_i_100", "/i/ 270/2290/3010 Hz, f0 100 Hz", {"segments": [voice(1.2, f0=100.0, vowel="i")]}, [10, 20, 60], False),
    ("vowel_i_220", "/i/, f0 220 Hz", {"segments": [voice(1.2, f0=220.0, vowel="i")]}, [10, 20, 60], False),
    ("vowel_u_100", "/u/ 300/870/2240 Hz, f0 100 Hz", {"segments": [voice(1.2, f0=100.0, vowel="u")]}, [10, 20, 60], False),
    ("vowel_u_220", "/u/, f0 220 Hz", {"segments": [voice(1.2, f0=220.0, vowel="u")]}, [10, 20, 60], False),
    ("vowel_u_360", "/u/, f0 360 Hz: F1 and F2 below 2.5 f0, neither may be reported (the 2nd harmonic pole at 746 Hz is not F2)",
     {"segments": [voice(1.2, f0=360.0, vowel="u")]}, [10, 20, 60], False),
    ("hnr_hold", "/a/ 120 Hz 0.6 s, silence 0.9 s, /a/ 0.6 s, silence 1.5 s, /a/ 0.3 s: HNR hold of 10 steps, histories cleared by unvoiced steps",
     {"segments": [voice(0.6, **A120), {"type": "silence", "dur_s": 0.9}, voice(0.6, **A120),
                   {"type": "silence", "dur_s": 1.5}, voice(0.3, **A120)]}, [10, 20, 60], True),
    ("pause_edges", "steady /a/ 120 Hz with a 300 ms gap of silence (not a pause) and a 310 ms one (a pause)",
     {"segments": [voice(2.4, **A120), {"type": "silence", "dur_s": 0.3}, voice(1.2, **A120),
                   {"type": "silence", "dur_s": 0.31}, voice(1.23, **A120)]}, [10, 20, 60], False),
    ("unvoiced_bursts", "0.2 s /a/ 120 Hz syllables alternating with 0.2 s white-noise bursts of the same rms: the bursts make envelope peaks that must not count as nuclei",
     {"segments": [seg for k in range(15) for seg in (voice(0.2, rms=0.15, syllables={"rate": 5.0, "per_block": 1, "pause_s": 0.0}, **A120),
                                                       {"type": "noise", "dur_s": 0.2, "rms": 0.1, "seed": 300 + k})]}, [10, 20, 60], False),
    ("pitch_steps", "/a/ with f0 held 0.2 s at each of 62..395 Hz (18 values), phase-continuous source",
     {"segments": [voice(3.6, f0={"steps": [[0.2, f] for f in SWEEP]}, vowel="a")]}, [10, 20, 60], False),
    ("pitch_glide", "/i/ with an exponential glide 62 -> 395 Hz over 3 s",
     {"segments": [voice(3.0, f0={"glide": [62.0, 395.0]}, vowel="i")]}, [10, 20, 60], False),
    ("snr20", "/a/ 120 Hz rms 0.1 + white noise at 20 dB SNR", {"segments": [voice(1.5, noise={"snr_db": 20.0, "seed": 101}, **A120)]}, [10, 20, 60], False),
    ("snr10", "/a/ 120 Hz rms 0.1 + white noise at 10 dB SNR", {"segments": [voice(1.5, noise={"snr_db": 10.0, "seed": 102}, **A120)]}, [10, 20, 60], True),
    ("snr3", "/a/ 120 Hz rms 0.1 + white noise at 3 dB SNR", {"segments": [voice(1.5, noise={"snr_db": 3.0, "seed": 103}, **A120)]}, [10, 20, 60], False),
    ("silence", "digital silence", {"segments": [{"type": "silence", "dur_s": 1.02}]}, [10, 20, 60], False),
    ("white_noise", "white noise rms 0.1", {"segments": [{"type": "noise", "dur_s": 1.02, "rms": 0.1, "seed": 7}]}, [10, 20, 60], False),
    ("lowpass_noise", "white noise through two one-pole low-passes at 1 kHz, rms 0.05",
     {"segments": [{"type": "noise", "dur_s": 1.5, "rms": 0.05, "seed": 5, "lowpass_hz": 1000.0, "order": 2}]}, [10, 20, 60], False),
    ("hum_50", "50 Hz sine, rms 0.05", {"segments": [{"type": "tone", "dur_s": 1.02, "freq": 50, "rms": 0.05}]}, [10, 20, 60], False),
    ("tone_420", "420 Hz sine, rms 0.05", {"segments": [{"type": "tone", "dur_s": 1.02, "freq": 420, "rms": 0.05}]}, [10, 20, 60], False),
    ("syl_4", "/a/ 120 Hz rms 0.15, blocks of 6 whole sin^2 syllables at 4/s + 0.5 s digital pause",
     {"segments": [voice(8.04, rms=0.15, syllables=SYL4, **A120)]}, [10, 20, 60], True),
    ("syl_6", "/a/ 120 Hz rms 0.15, blocks of 9 syllables at 6/s + 0.5 s pause",
     {"segments": [voice(8.04, rms=0.15, syllables=SYL6, **A120)]}, [10, 20, 60], False),
    ("gap_short", "syllables 4/s; 500 ms discontinuity at 4.2 s (histories kept, window and phase restart)",
     {"segments": [voice(7.2, rms=0.15, syllables=SYL4, **A120)], "events": [{"at_s": 4.2, "gap_ms": 500}]}, [10, 20, 60], True),
    ("gap_long", "syllables 4/s; 2500 ms discontinuity at 4.2 s (everything cleared)",
     {"segments": [voice(7.2, rms=0.15, syllables=SYL4, **A120)], "events": [{"at_s": 4.2, "gap_ms": 2500}]}, [10, 20, 60], True),
    ("amp_x0.5", "/a/ 120 Hz rms 0.1 + white noise at 10 dB SNR, gain 0.5 (rms about 0.05)",
     {"segments": [voice(1.5, rms=0.1, noise={"snr_db": 10.0, "seed": 104}, **A120)], "gain": 0.5}, [10, 20, 60], False),
    ("amp_x0.05", "same signal, gain 0.05 (rms about 0.005)",
     {"segments": [voice(1.5, rms=0.1, noise={"snr_db": 10.0, "seed": 104}, **A120)], "gain": 0.05}, [10, 20, 60], False),
    ("faint_voice", "/a/ 120 Hz at rms 6e-5 (about 2 LSB): below the 1e-4 digital-silence floor, nothing measured",
     {"segments": [voice(1.02, rms=6e-5, **A120)]}, [10, 20, 60], False),
    ("chunking", "mixed: /u/ 140 Hz, silence, /i/ 210 Hz with noise, 5/s syllables; run at 1, 7, 10, 20 and 60 ms chunks",
     {"segments": [voice(1.2, f0=140.0, vowel="u"), {"type": "silence", "dur_s": 0.36},
                   voice(1.2, f0=210.0, vowel="i", rms=0.05, noise={"snr_db": 15.0, "seed": 9}),
                   voice(3.0, rms=0.1, syllables={"rate": 5.0, "per_block": 5, "pause_s": 0.5}, f0=105.0, vowel="a")]},
     [1, 7, 10, 20, 60], False),
]

BOOL = {"f0Valid", "voiced", "F1Found", "F2Found", "hnrValid", "rateValid", "isSpeaking"}

# Margins below these are within reach of binary64 implementation differences (SPEC appendix V).
FRAGILE = {
    "rms_floor": 1e-6, "periodicity": 1e-7, "f0_range": 1e-6, "yin_tie": 1e-12, "hnr_lag_round": 1e-9,
    "hnr_max_tie": 1e-12, "zigzag": 1e-7, "zigzag_tie": 1e-9, "active": 1e-7, "root_mag": 1e-9,
}


def fragile(m):
    bad = [k for k, lim in FRAGILE.items() if k in m and m[k] < lim]
    if m.get("yin_pick_stable", 1.0) == 0.0:
        bad.append("yin_pick")
    if m.get("formant_stable", 1.0) == 0.0:
        bad.append("formant_select")
    if "root_fail" in m:
        bad.append("root_fail")
    return bad


def rnd(v):
    return float("%.9g" % v)


def run_case(case, chunk_ms, margins=False):
    pcm, events = gen.build(case)
    return pcm, events, ref.run(pcm, chunk_ms * 48, events, track_margins=margins)


def display_series(results, events, pcm_len):
    """SPEC 9: display history cleared together with the engine (long gap)."""
    # step k ends at a known sample position; a long-gap event resets the display
    disp = ref.Display()
    out = []
    long_at = sorted(at for at, gap in events if gap >= ref.LONG_GAP_SAMPLES)
    # recover step end positions: segments restart at every event
    cuts = sorted(set([0, pcm_len] + [at for at, _ in events]))
    ends = []
    for a, b in zip(cuts[:-1], cuts[1:]):
        k = ref.HOP
        while a + k <= b:
            ends.append(a + k)
            k += ref.HOP
    assert len(ends) == len(results), (len(ends), len(results))
    li = 0
    for end, r in zip(ends, results):
        while li < len(long_at) and long_at[li] < end:
            disp.reset()
            li += 1
        out.append(disp.push(r))
    return out


def pack(results, fields):
    exp = {}
    for k in fields:
        if k in BOOL:
            exp[k] = "".join("1" if r[k] else "0" for r in results)
        else:
            exp[k] = [rnd(r[k]) for r in results]
    return exp


def build(out_path, raw_dir=None):
    cases = []
    problems = []
    for name, desc, case, chunks, want_display in CASES:
        pcm, events, base = run_case(case, chunks[0], margins=True)
        frag = []
        for i, r in enumerate(base):
            b = fragile(r.pop("_margins"))
            if b:
                frag.append((i + 1, b))
        if frag:
            problems.append((name, frag[:8], len(frag)))
        rows = [[r[k] for k in ref.FIELDS] for r in base]
        for ms in chunks[1:]:
            _, _, other = run_case(case, ms)
            if [[r[k] for k in ref.FIELDS] for r in other] != rows:
                problems.append((name, "chunk %d ms differs" % ms))
        entry = {
            "name": name,
            "description": desc,
            "case": case,
            "n_samples": len(pcm),
            "pcm_fnv1a32": "0x%08x" % gen.fnv1a32(pcm),
            "pcm_sum": sum(pcm),
            "events_samples": [[at, gap] for at, gap in events],
            "chunk_ms": chunks,
            "steps": len(base),
            "expected": pack(base, ref.FIELDS),
        }
        if want_display:
            entry["display"] = pack(display_series(base, events, len(pcm)), ref.DISPLAY_FIELDS)
        cases.append(entry)
        if raw_dir:
            os.makedirs(raw_dir, exist_ok=True)
            gen.write_raw(pcm, os.path.join(raw_dir, name + ".raw"))
        print("%-14s steps %3d  fragile steps %d" % (name, len(base), len(frag)), flush=True)
    doc = {
        "format": "voicedsp-vectors/1",
        # Original wording kept, so a rebuild matches the committed vectors byte for byte.
        "spec": "SPEC.md in the same folder; generator gen.py; reference ref.py",
        "fields": list(ref.FIELDS),
        "compare": ("Run the engine on each case once per chunk size in chunk_ms, splitting a chunk at every event "
                    "sample and calling discontinuity(gap_samples) there. The result list must have exactly 'steps' "
                    "entries. Boolean fields must match exactly ('1'/'0' per step). A numeric field must satisfy "
                    "|got - expected| <= abs + rel * |expected| with the tolerance of that field. Numbers were rounded "
                    "to 9 significant digits. 'display' (when present) is SPEC section 9 applied to the expected results."),
        "tolerance": TOLERANCE,
        "cases": cases,
    }
    with open(out_path, "w") as fh:
        json.dump(doc, fh, separators=(",", ":"))
    print("written", out_path, os.path.getsize(out_path), "bytes")
    if problems:
        print("PROBLEMS:")
        for p in problems:
            print("  ", p)
    return problems


TOLERANCE = {
    "f0": {"abs": 0.001, "rel": 0.0},
    "periodicity": {"abs": 1e-5, "rel": 0.0},
    "F1": {"abs": 0.01, "rel": 0.0},
    "F2": {"abs": 0.01, "rel": 0.0},
    "HNR": {"abs": 0.001, "rel": 0.0},
    "breathiness": {"abs": 1e-6, "rel": 0.0},
    "rate": {"abs": 1e-4, "rel": 0.0},
    "pauseRatio": {"abs": 1e-5, "rel": 0.0},
    "rms": {"abs": 0.0, "rel": 1e-5},
}

if __name__ == "__main__":
    build(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "vectors.json"),
          sys.argv[2] if len(sys.argv) > 2 else None)
