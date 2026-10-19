# Independent generator of display-format-cases.tsv from docs/voice-analysis-spec.md section 12.
# Python floats are binary64; binary32 inputs are made with struct (round to nearest even), as the apps' Float is.
import math, struct, sys

DASH = "—"
SEP = " · "


def f32(text):
    if text == "-":
        return None
    v = float(text)           # NaN / Infinity parse here
    return struct.unpack("<f", struct.pack("<f", v))[0] if math.isfinite(v) else v


def R(v):                     # 12.1: round half away from zero, exact on binary64
    a = abs(v)
    f = math.floor(a)
    r = f + 1 if a - f >= 0.5 else f
    return -r if v < 0 else r


def whole(x):
    return str(int(R(x)))


def tens(x):
    return str(int(R(x / 10.0)) * 10)


def one(x, sep):
    n = int(R(x * 10.0))
    a = abs(n)
    return ("-" if n < 0 else "") + str(a // 10) + sep + str(a % 10)


def ok_pos(x):
    return x is not None and math.isfinite(x) and x > 0        # f0, F1, F2


def ok_nonneg(x):
    return x is not None and math.isfinite(x) and x >= 0       # rate, jitter, shimmer


def ok_fin(x):
    return x is not None and math.isfinite(x)                  # HNR


def render(f0, f1, f2, rate, hnr, jit, shim, sep, unit):
    tone = whole(f0) if ok_pos(f0) else DASH
    det = SEP.join([
        "F1 " + (tens(f1) if ok_pos(f1) else DASH),
        "F2 " + (tens(f2) if ok_pos(f2) else DASH),
        (one(rate, sep) if ok_nonneg(rate) else DASH) + " " + unit,
        "HNR " + (whole(hnr) + " dB" if ok_fin(hnr) else DASH),
    ])
    pr = (whole(f0) + " Hz" if ok_pos(f0) else DASH) + SEP + (one(rate, sep) + " " + unit if ok_nonneg(rate) else DASH)
    js = (one(jit, sep) + "% / " + one(shim, sep) + "%") if (ok_nonneg(jit) and ok_nonneg(shim)) else DASH
    hn = whole(hnr) + " dB" if ok_fin(hnr) else DASH
    return tone, det, pr, js, hn


BASE = dict(f0="142.7", f1="524", f2="1478", rate="4.24", hnr="18.4", jit="1.2", shim="3.1")
ROWS = [
    ("typical", {}),
    ("f0_tie_half", dict(f0="142.5")),
    ("f0_below_half", dict(f0="142.49")),
    ("f0_low_edge", dict(f0="60")),
    ("f0_high_tie", dict(f0="399.5")),
    ("formant_tie_up", dict(f1="1475", f2="1485")),
    ("formant_below_tie", dict(f1="1474.9", f2="1484.9")),
    ("formant_ties_low", dict(f1="205", f2="605")),
    ("formant_low_edge", dict(f1="200", f2="600")),
    ("formant_high_edge", dict(f1="1100", f2="3200")),
    ("rate_tie_4_25", dict(rate="4.25")),
    ("rate_tie_4_75", dict(rate="4.75")),
    ("rate_binary32_below_4_35", dict(rate="4.35")),
    ("rate_binary32_above_3_45", dict(rate="3.45")),
    ("rate_tie_small_0_05", dict(rate="0.05")),
    ("rate_zero_is_a_value", dict(rate="0")),
    ("rate_integer", dict(rate="5")),
    ("rate_max", dict(rate="12")),
    ("hnr_tie_pos", dict(hnr="2.5")),
    ("hnr_tie_neg", dict(hnr="-2.5")),
    ("hnr_tie_neg_3_5", dict(hnr="-3.5")),
    ("hnr_half_pos", dict(hnr="0.5")),
    ("hnr_half_neg", dict(hnr="-0.5")),
    ("hnr_no_negative_zero", dict(hnr="-0.4")),
    ("hnr_zero_is_a_value", dict(hnr="0")),
    ("hnr_17_5", dict(hnr="17.5")),
    ("hnr_low_edge", dict(hnr="-40")),
    ("hnr_high_edge", dict(hnr="40")),
    ("jitter_tie_0_25", dict(jit="0.25", shim="0.75")),
    ("shimmer_binary32_below_8_45", dict(jit="0.15", shim="8.45")),
    ("jitter_shimmer_zero", dict(jit="0", shim="0")),
    ("jitter_shimmer_hundred", dict(jit="100.05", shim="99.95")),
    ("widest_line", dict(f0="399.5", f1="1100", f2="3200", rate="12", hnr="-40")),
    ("all_missing", dict(f0="-", f1="-", f2="-", rate="-", hnr="-", jit="-", shim="-")),
    ("f0_missing", dict(f0="-")),
    ("f1_missing", dict(f1="-")),
    ("f2_missing", dict(f2="-")),
    ("rate_missing", dict(rate="-")),
    ("hnr_missing", dict(hnr="-")),
    ("jitter_missing", dict(jit="-")),
    ("shimmer_missing", dict(shim="-")),
    ("stress_missing_only", dict(jit="-", shim="-")),
    ("f0_and_rate_missing", dict(f0="-", rate="-")),
    ("guard_f0_zero", dict(f0="0")),
    ("guard_f0_nan", dict(f0="NaN")),
    ("guard_f1_zero", dict(f1="0")),
    ("guard_f1_nan", dict(f1="NaN")),
    ("guard_f2_negative", dict(f2="-5")),
    ("guard_f2_infinity", dict(f2="Infinity")),
    ("guard_rate_negative", dict(rate="-1")),
    ("guard_rate_nan", dict(rate="NaN")),
    ("guard_hnr_nan", dict(hnr="NaN")),
    ("guard_hnr_infinity", dict(hnr="Infinity")),
    ("guard_jitter_negative", dict(jit="-0.1")),
    ("guard_shimmer_nan", dict(shim="NaN")),
]

HEADER = [
    "# Display formatting cases (docs/voice-analysis-spec.md, section 12). One file, byte for byte the same in the Android and iOS repositories.",
    "# UTF-8, tab separated, one case per line; lines starting with # are comments. The first line after the comments is the column header.",
    "# Inputs (decimal text, read as binary32): f0 [Hz], f1 and f2 [Hz], rate [syllables/s], hnr [dB], jitter and shimmer [%].",
    "#   A single dash is a field whose flag is not set (a missing field); NaN and Infinity are read as they are.",
    "# Expected strings, in Italian (decimal comma, unit sill/s) and English (decimal point, unit syl/s):",
    "#   tone = the f0 of the tone row; details = the details line of the tone row; pitch_rate = the pitch / rate row of the technical block;",
    "#   jitter_shimmer = its jitter / shimmer row; hnr_row = its HNR row (the same in both languages).",
    "# Generated from the rules of section 12 by an independent script; do not edit by hand.",
]
COLS = ["id", "f0", "f1", "f2", "rate", "hnr", "jitter", "shimmer", "tone", "details_it", "details_en",
        "pitch_rate_it", "pitch_rate_en", "jitter_shimmer_it", "jitter_shimmer_en", "hnr_row"]


def main(out):
    lines = list(HEADER) + ["\t".join(COLS)]
    for name, over in ROWS:
        d = dict(BASE)
        d.update(over)
        v = {k: f32(t) for k, t in d.items()}
        ti, di, pi, ji, hi = render(v["f0"], v["f1"], v["f2"], v["rate"], v["hnr"], v["jit"], v["shim"], ",", "sill/s")
        te, de, pe, je, he = render(v["f0"], v["f1"], v["f2"], v["rate"], v["hnr"], v["jit"], v["shim"], ".", "syl/s")
        assert ti == te and hi == he
        lines.append("\t".join([name, d["f0"], d["f1"], d["f2"], d["rate"], d["hnr"], d["jit"], d["shim"],
                                ti, di, de, pi, pe, ji, je, hi]))
    with open(out, "w", encoding="utf-8", newline="") as fh:
        fh.write("\n".join(lines) + "\n")
    print(len(ROWS), "cases")


if __name__ == "__main__":
    main(sys.argv[1])
