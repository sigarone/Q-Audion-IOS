# Remote-voice analysis: binding specification

Version 1, 2026-10-19. This document, `ref.py` (reference implementation), `gen.py` (test-signal generator) and `vectors.json` (expected outputs) form one unit. If the text and `ref.py` ever disagree, the disagreement is a bug in this document; `vectors.json` was produced by `ref.py` and is the acceptance test for both apps.

The goal is that the Android and iOS engines produce the same numbers for the same received audio. Section 10 lists where this spec departs from the decisions D1 to D9 and why; the measurements were made with `ref.py` on the signals of `gen.py`.

Note on this copy. `ref.py`, `gen.py`, `build_vectors.py` and `gen_format_cases.py` are in `docs/voice-analysis/`. `python3 docs/voice-analysis/build_vectors.py out.json` rebuilds the vectors and `python3 docs/voice-analysis/gen_format_cases.py out.tsv` the cases of section 12. The expected outputs are in `QAudionEngine/Tests/QAudionEngineTests/Analysis/Resources/voicedsp-vectors.json` (the same bytes as `vectors.json`), appendix G is ported in `QAudionEngine/Tests/QAudionEngineTests/Analysis/VoiceDspVectorGenerator.swift`, and the cases of section 12 are in `QAudionAppTests/voice-analysis/display-format-cases.tsv`. On iOS the jitter and shimmer of the analysis are ratios (0.03 is 3 %); the screens multiply them by 100 in binary32 and hand the percentage to the formatter, whose inputs are the percentages of that table.

## 0. Conventions

All arithmetic is IEEE-754 binary64 (Kotlin `Double`, Swift `Double`), from the int16 input to the result. Float32 may be used only to store the final output fields. No fast-math, no fused multiply-add contraction requested by the code. Library functions (`sin`, `cos`, `exp`, `log`, `log10`, `sqrt`, `atan2`, `hypot`) are the platform's standard ones.

Summation order is not normative. Plain left-to-right sums, compensated sums and pairwise sums are all acceptable; the vector tolerances are 60 to 1000 times larger than the differences this causes together with float32 output storage (measured: at most 6e-8 relative). Every other operation, constant and comparison below is normative, including whether a comparison is strict.

Notation: `x[i]` is 0-based. "Window" always means the 60 ms analysis window, oldest sample first. "Step" is one analysis (every 100 ms of audio). `floor` is the mathematical floor.

## 1. Input, framing and cadence (D1)

Input is 48 kHz mono int16 PCM delivered in chunks of any length (1, 10, 20, 60 ms or anything else). Each sample becomes `v = s / 32768.0`. Audio at any other sample rate is not analysed.

The engine keeps a ring of the last `WIN = 2880` samples (60 ms) and a counter `seg` of samples received since the current segment started (a segment starts at engine creation, at `reset()` and at every discontinuity, section 2).

Samples are processed one at a time, in order, regardless of chunk boundaries. For every sample: write `v` into the ring; add `v*v` to the frame accumulator and, if this sample completes a 480-sample frame, close the frame (section 7.1); increment `seg`; if `seg` is a multiple of `HOP = 4800`, run one step (sections 3 to 8) on the ring contents. The frame that ends on a step's last sample is closed before that step runs, so every step has exactly 10 frames. So the first step of a segment happens 100 ms after its start (the window filled at 60 ms), and every step after that is exactly 4800 samples later. A step that falls inside a chunk is run at that exact sample, so the result list is identical for every chunking. The window of a step is the 2880 samples ending with the sample that triggered it.

Steps are numbered from 1 after each `reset()`; results are delivered in order, one per step.

## 2. Discontinuities and reset (D2)

`markDiscontinuity(missingSamples)` tells the engine that audio is missing between the last sample received and the next one (before any audio it has no effect). `missingSamples` is the length of the gap in 48 kHz samples (estimated from timestamps or the wall clock when not known exactly; 0 means "a splice of unknown length" and counts as short).

- `missingSamples < 96000` (shorter than 2 s): restart the segment. `seg = 0`; the partial 10 ms frame and the complete frames of the unfinished step are discarded (they never reach the speech-rate history); the ring needs no clearing because the next step comes 4800 samples later and the window is refilled by then. All histories are kept: HNR values and counters, formant medians, the speech-rate envelope, zig-zag state and nuclei, the stress histories and the display history. Missing audio does not count as time anywhere (all "time" in this spec is audio time measured in steps or frames).
- `missingSamples >= 96000`, `reset()`, or call end: clear everything (ring, segment, all histories, the display history). The engine is then in its initial state.

## 3. Front end (D3)

For each step, with `w[0..2879]` the window (oldest first):

1. Mean removal, once, at 48 kHz: `mean = (sum of w) / 2880`; `xc[i] = w[i] - mean`.
2. `rms = sqrt((sum of xc[i]^2) / 2880)`. This is the `rms` output and the stress input (section 8).
3. Anti-alias FIR and decimation by 3 to 16 kHz, valid outputs only:
   - `T = 63` taps, `wc = 2*pi*7000/48000`. For `k = 0..62`, `m = k - 31`: `ideal = wc/pi` if `m == 0`, else `sin(wc*m)/(pi*m)`; `h[k] = ideal * (0.54 - 0.46*cos(2*pi*k/62))`; then divide every `h[k]` by `sum of h`.
   - `y[n] = sum over k = 0..62 of h[k] * xc[3n + k]`, for `n = 0..939`. `N16 = 940`.
   - Why 63 taps and a Hamming window: `(2880 - 63)` is divisible by 3, so the last output ends exactly on the newest sample and no input sample is left over; the -6 dB point is 7 kHz; the passband ripple is 0.026 dB up to 5 kHz (3.2 kHz is the highest frequency any measurement uses); everything above 9.3 kHz, which folds into 0-6.7 kHz, is at least 58.7 dB down; 8 kHz is 31 dB down and the response stays below -50 dB from 8.26 kHz. With 49 taps (the first iOS version) the same figures are 0.033 dB, 57.3 dB, 22 dB and 8.63 kHz, for 22 % fewer multiplies; the cost difference is not material (about 59 k multiply-adds per step).
4. No second mean removal on the 16 kHz view. YIN is insensitive to a constant offset, the formant path has pre-emphasis (DC gain 0.03), and HNR works on `xc`.
5. Pre-emphasis exists only in the formant path (section 6), on the 16 kHz view.

## 4. Pitch and voicing (D4)

Constants: `SILENCE_RMS = 1e-4`, `TAU_MIN = 36`, `TAU_MAX = 270`, `W = N16 - TAU_MAX = 670`, `YIN_ABS = 0.15`, `YIN_REL = 0.05`, `VOICED_PERIODICITY = 0.45`, `F0_MIN = 60.0`, `F0_MAX = 400.0`.

1. If `rms < SILENCE_RMS`: unvoiced, `f0 = 0`, `periodicity = 0`. Skip the rest of this section.
2. Difference function, for `tau = 1..270`: `d[tau] = sum over j = 0..669 of (y[j] - y[j + tau])^2`. (The expanded form `E1 + E2 - 2*C` is allowed; the difference is far below tolerance.)
3. Cumulative mean normalised difference: `cm[0] = 1`; running sum `S` starts at 0; for `tau = 1..270`: `S = S + d[tau]`; `cm[tau] = d[tau] * tau / S` if `S > 0`, else `1`.
4. `gmin = min of cm[tau]` for `tau = 36..270`; `thr = max(0.15, gmin + 0.05)`.
5. Candidate: the first `tau` in `36..270` (ascending) with `cm[tau] < thr` starts a stretch; the stretch continues while the next `tau <= 270` also has `cm < thr`. `best` is the lowest point of that stretch: the first `tau` in the stretch with the smallest `cm` (strict `<` when scanning upward). A stretch always exists (`gmin < thr`), so there is no fallback.
6. Refinement: `lag = best`. If `36 < best < 270`: `a = cm[best-1]`, `b = cm[best]`, `c = cm[best+1]`, `den = a - 2b + c`; if `den > 0`: `lag = best + clamp(0.5*(a - c)/den, -0.5, 0.5)`.
7. `f0c = 16000 / lag`; `periodicity = clamp(1 - cm[best], 0, 1)` (at the integer lag).
8. Voiced iff `periodicity >= 0.45` AND `60.0 <= f0c <= 400.0` (and `rms >= SILENCE_RMS`, step 1). If voiced: `f0 = f0c`, `f0Valid = true`. Else `f0 = 0`, `f0Valid = false`. `periodicity` is reported in both cases.

The search starts at lag 36 (444 Hz) and ends at 270 (59.3 Hz) so that 400 Hz and 60 Hz lie inside the range and get the parabolic refinement; the range check in step 8 then decides. `voiced` and `f0Valid` are the same flag.

## 5. HNR and breathiness (D5)

Constants: `HNR_HALF_SPAN = 2`, `R_MIN = 0.0001`, `R_MAX = 0.9999`, `HNR_CAP = 40.0`, keep 5 values, valid after 3 voiced steps, hold 10 steps.

Per voiced step (on the 48 kHz window `xc`):

1. Hann window `g[i] = 0.5 - 0.5*cos(2*pi*(i + 0.5)/2880)`, `i = 0..2879`; `a[i] = xc[i] * g[i]`.
2. `ra(t) = sum over i = 0..2879-t of a[i]*a[i+t]`; `rw(t) = sum over i = 0..2879-t of g[i]*g[i+t]` (constant, may be tabulated).
3. `P = 48000 / f0` (with the binary64 `f0` of section 4); `lc = floor(P + 0.5)`.
4. For `t = lc-2 .. lc+2`: `r(t) = (ra(t)/ra(0)) / (rw(t)/rw(0))`.
5. `k` = index of the largest of the five (first one on ties, scanning upward). `r = r(k)`. If `k` is one of the three middle lags: `ya, yb, yc` = values at `k-1, k, k+1`; `den = ya - 2*yb + yc`; if `den < 0`: `r = yb - (ya - yc)^2 / (8*den)`.
6. `r = clamp(r, 0.0001, 0.9999)`; `hnrStep = min(40.0, 10*log10(r/(1 - r)))`.
7. Append `(hnrStep, r)` to a list that keeps the last 5 voiced values; increment `voicedCount`; set `sinceVoiced = 0`.

Per unvoiced step: if `sinceVoiced` is defined, increment it. Nothing else changes.

Output of every step: `hnrValid = voicedCount >= 3 AND sinceVoiced is defined AND sinceVoiced <= 10` (so a value survives up to 1 s of audio after the last voiced step). If valid: `HNR = mean of hnrStep` over the kept values (up to 5) and `breathiness = mean of (1 - r)` over the same values. If not valid: `HNR = 0`, `breathiness = 0`.

## 6. Formants (D6)

Constants: `PRE_EMPHASIS = 0.97`, `LPC_ORDER = 18`, `WNC = 1e-6`, `FORMANT_MIN = 90`, `BW_MAX = 300`, `F2_IGNORE_BW = 500`, `F1` range `[200, 1100]`, `F2` range `[600, 3200]`, `HARMONIC_RATIO = 2.5`, median of 3. All frequencies in Hz.

On an unvoiced step: clear both histories; `F1 = F2 = 0`, both not found. On a voiced step:

6.1 Pre-emphasis and window. `p[i] = y[i+1] - 0.97*y[i]` for `i = 0..938` (`M = 939` samples; the first 16 kHz sample has no predecessor and is dropped). `s[i] = p[i] * (0.54 - 0.46*cos(2*pi*i/938))`.

6.2 Autocorrelation `R[k] = sum over i = 0..938-k of s[i]*s[i+k]`, `k = 0..18`; then `R[0] = R[0] * (1 + 1e-6)`. If `R[0] <= 0`: root-finder failure (6.6).

6.3 Levinson-Durbin. `a = [1, 0, ..., 0]` (19 entries), `err = R[0]`. For `i = 1..18`: `acc = R[i] + sum over j = 1..i-1 of a[j]*R[i-j]`; `k = -acc/err`; if `|k| >= 1`: failure; `a[j] = a_old[j] + k*a_old[i-j]` for `j = 1..i-1` (using the values before this iteration); `a[i] = k`; `err = err*(1 - k*k)`; if `err <= 0`: failure.

6.4 Roots of `z^18 + a[1] z^17 + ... + a[18]`, ascending complex coefficients `c[j] = a[18-j]`, `j = 0..18`, by Laguerre's method with deflation and polishing, exactly as Numerical Recipes `zroots`/`laguer` with these parameters: `EPS = 1e-14`, `MR = 8`, `MT = 10`, `MAXIT = 80`, `frac = {0, 0.5, 0.25, 0.75, 0.13, 0.38, 0.62, 0.88, 1.0}`.
   - `laguer(c, m, x)`: for `it = 1..80`: `b = c[m]; err = |b|; d = f = 0; abx = |x|`; for `j = m-1 down to 0`: `f = x*f + d; d = x*d + b; b = x*b + c[j]; err = |b| + abx*err`. `err = err*EPS`. If `|b| <= err`: converged, return `x`. `g = d/b; g2 = g*g; h = g2 - 2*f/b; sq = sqrt((m-1)*(m*h - g2))` (principal complex square root); `gp = g + sq; gm = g - sq`; if `|gp| < |gm|`: `gp = gm`; `dx = m/gp` if `max(|gp|,|gm|) > 0` else `(1 + abx)*(cos(it) + i*sin(it))`; `x1 = x - dx`; if `x1 == x`: converged, return `x`; if `it mod 10 != 0`: `x = x1` else `x = x - frac[it/10]*dx`. After 80 iterations: failure.
   - Deflation: working copy `ad = c`. For `j = 18 down to 1`: `x = laguer(ad[0..j], j, 0)`; if `|Im x| <= 2*EPS*|Re x|`: `x = Re x`; store `x`; then `b = ad[j]`; for `jj = j-1 down to 0`: `t = ad[jj]; ad[jj] = b; b = x*b + t`.
   - Polishing: replace each stored root `x` by `laguer(c, 18, x)` on the original coefficients.
   - `|z|` is `hypot(Re, Im)`.

6.5 Selection. Keep the roots with `Im z > 0`; for each, `f = atan2(Im z, Re z) * 16000/(2*pi)` and `bw = -ln|z| * 16000/pi`; sort by `f` ascending. A root is "kept" when `|z| < 1` AND `f > 90` AND `bw < 300`.
   - Raw F1 candidate: the first kept root (ascending `f`) with `200 <= f <= 1100`. If none: neither F1 nor F2 is found in this step.
   - F1 found iff `f1raw >= 2.5 * f0`. A raw candidate below the gate is not replaced by a later root.
   - F2: scan the sorted roots upward, skipping every root with `bw >= 500`; the first remaining root with `f > f1raw` and `600 <= f <= 3200` is the F2 root. F2 is found iff such a root exists, it is kept (`|z| < 1`, `bw < 300`) and `f >= 2.5 * f0`. If that root fails, F2 is not found: a later root is never promoted.
   - The 2.5 gate uses the `f0` of this step; all comparisons are exactly as written (`>=`, `<=`, `<`, `>`).

6.6 Root-finder failure (6.2, 6.3 or 6.4): no formant is found in this step; the histories are not touched.

6.7 Smoothing. Each formant has a history of its last 3 found raw values. When F1 is found in a voiced step, append its raw value (drop the oldest beyond 3) and output `F1 = median` of the history (3 values: the middle one; 2 values: their mean; 1 value: itself), `F1Found = true`. When not found: `F1 = 0`, `F1Found = false`, history unchanged. Same for F2. Histories are cleared only by unvoiced steps, a long gap and reset.

## 7. Speech rate (D7)

Constants: span 600 frames (6 s), look-back 30 frames, energy floor `1e-10`, active range 25 dB, dip 3 dB, refractory 10 frames, pause = inactive run longer than 30 frames, valid from 200 speaking frames, rate clamp 0..12.

7.1 Envelope. Frames are 480 consecutive samples of the segment (aligned to its start). `e = (sum of v*v over the frame) / 480`, on the raw normalised samples (not mean-removed); `L = 10*log10(max(e, 1e-10))`. Each step commits its 10 frames, in order, with `voiced` = the step's voiced flag, to a history that holds at least the last 630 frames. Frames are indexed `0, 1, 2, ...` by commit order since reset.

7.2 Nuclei (zig-zag with 3 dB hysteresis), run on each committed frame in order:
   - First frame since reset: `seekPeak = true; pk = L; pkIdx = idx; precValley = L`.
   - When seeking a peak: if `L > pk`: `pk = L; pkIdx = idx`. Else if `pk - L >= 3`: confirm the peak (below); then `seekPeak = false; vl = L`.
   - When seeking a valley: if `L < vl`: `vl = L`. Else if `L - vl >= 3`: `precValley = vl; seekPeak = true; pk = L; pkIdx = idx`.
   - Confirming a peak: it is a nucleus iff `pk - precValley >= 3` AND the frame `pkIdx` is voiced AND (`lastNucleus` undefined OR `pkIdx - lastNucleus >= 10`). A nucleus sets `lastNucleus = pkIdx` and is recorded by its frame index.

7.3 After committing the step's frames, with `nf` = frames committed since reset: span `n = min(nf, 600)`, `start = nf - n`.
   - `level` = the largest `L` among the voiced frames in `[start, nf)`. If there is none, no frame is active.
   - Frame `i` is active iff `level` exists AND `L[i] >= level - 25`.
   - Pauses: scan frames `i` from `max(0, start - 30)` to `nf - 1` and find the maximal runs of inactive frames. A run `[rs, re)` is a pause iff `re - rs > 30`; it contributes `re - max(rs, start)` frames when `re > start`. A run still open at `nf` is treated as ending at `nf`. (The 30-frame look-back lets a pause that began before the span keep its true length.) `pause` = total contributed frames.
   - `speaking = n - pause`; `nuclei` = recorded nuclei with index in `[start, nf)`.
   - `rateValid = speaking >= 200`. If valid: `rate = clamp(nuclei / (speaking * 0.01), 0, 12)` and `pauseRatio = pause / n`. Else `rate = 0`, `pauseRatio = 0`.
   - `isSpeaking` = at least one of the 10 frames just committed is active (computed whether or not the rate is valid).

`n` is 600 in steady state; during the first 6 s after reset it is the audio received so far (section 10, item 5).

## 8. Stress inputs (D8)

The jitter/shimmer inputs are the per-step values of voiced steps only: the `f0` sequence and the `rms` sequence of section 3 (mean-removed), last 25 voiced steps, cleared by a long gap or reset and kept across short gaps. The jitter, shimmer, stress-score and confidence formulas themselves are outside this spec (they are not yet the same on the two platforms).

## 9. Display (D9)

The UI never shows raw step results. After every step, the display value is computed from the last 10 results (1 s of audio time; fewer right after a reset). For each measured field, the display value is the arithmetic mean over the results whose own flag is set, and the field is valid iff at least one is; otherwise it is 0 with the flag false:

| Display field | Averaged over results with | Value when none |
|---|---|---|
| f0 | `f0Valid` | 0, invalid |
| F1, F2 | `F1Found`, `F2Found` | 0, not found |
| HNR, breathiness | `hnrValid` | 0, invalid |
| rate, pauseRatio | `rateValid` | 0, invalid |
| rms | all results | (always) |
| voiced, isSpeaking | majority: true iff more than half of the results are true | |

The display history is cleared together with the engine (long gap, reset); a short gap keeps it. An app may publish the latest display value at any UI rate (for example 4 Hz or once per second); it must not average on wall-clock batches. An invalid field is shown as a dash, never as 0.

## 10. Departures from the decisions and clarifications

1. D6, F2 rule. Decision: "F2 = the first root (kept or not) above the raw F1 candidate". Measured: an 18th-order LPC fit always contains a few very wide roots that model the spectral tilt, not a resonance (bandwidth 1 to 2 kHz). Taken literally, the rule lets them block F2 on clean vowels: /i/ at 100 Hz never reports F2 (a 1443 Hz root with 1911 Hz bandwidth sits between F1 and F2), and over 2992 voiced grid windows F2 is found correctly in 1187 and missing in 1726. Change: roots with bandwidth of 500 Hz or more are skipped in the F2 scan. Roots narrower than that still block (no promotion), so the F3-for-F2 error stays fixed. With the change: 2545 correct, 85 wrong (79 with the literal rule; the 6 extra are all at f0 350 Hz), 362 missing. /a/ at 220 Hz still reports no F2, as under the literal rule: its first root above F1 is a 386 Hz-wide pole on the 4th harmonic, which the rule treats as a formant it cannot measure. 500 Hz is where the bandwidth histogram of roots lying near a true formant falls to its chance floor.
2. D3: 63 taps, Hamming, cutoff 7 kHz; mean removal only on the 48 kHz window; pre-emphasis only in the formant path, first 16 kHz sample dropped, Hamming over the 939 remaining samples.
3. D4: digital-silence floor `rms < 1e-4` (-80 dBFS, about 3 LSB; 1-LSB dither stays below it); lag search 36..270 at 16 kHz; YIN integration window 670 samples (so every one of the 940 samples is used at the largest lag); periodicity taken at the integer lag.
4. D5: `P = 48000/f0` and `lc = floor(P + 0.5)`; Hann `0.5 - 0.5cos(2pi(i + 0.5)/2880)`.
5. D7: during the first 6 s after reset, the span and the pause-ratio denominator are the audio received so far (`n = min(frames, 600)`), not a fixed 6 s, so that "6 s minus pauses" does not count audio that never arrived. Steady state is unchanged.
6. D2: the frames of an unfinished step are discarded at a short discontinuity, so the speech-rate history only ever holds frames of completed steps, each with a voiced flag.
7. D9: the 1 s window is defined in audio time (the last 10 results), breathiness falls back to 0 (not 1.0 as in the first iOS version), and boolean fields take the majority as in the first iOS version.

## 11. Outputs of one step

| Field | Type | Meaning when its flag is false |
|---|---|---|
| f0 | Hz | 0 |
| f0Valid, voiced | bool | (same flag) |
| periodicity | 0..1 | always reported; 0 below the silence floor |
| F1, F1Found; F2, F2Found | Hz, bool | 0 |
| HNR, hnrValid | dB, bool | 0 |
| breathiness | 0..1 | 0 (follows hnrValid) |
| rate, rateValid | syllables/s, bool | 0 |
| pauseRatio | 0..1 | 0 (follows rateValid) |
| isSpeaking | bool | |
| rms | full scale 1.0 | always reported |

## 12. Display formatting

The same display value (section 9) must print as the same text on both apps, wherever it is shown: the tone row of the call screen, the technical block and any diagnostics view. Section 9 decides which values exist; this section decides how they are written.

The platform's number formatting (`printf`, `String.format`, `NumberFormat`) is not used to round or to place digits, because the platforms disagree on exact ties and on how a binary32 value is read. Rounding is the explicit rule R of 12.1, and the digits are written from an integer in plain ASCII: no grouping separator, no plus sign, no locale digits. The platform supplies only the decimal separator (12.2).

A shown number comes from one field of the display value and is shown only while that field's own flag is set; otherwise its place shows the dash "—" (U+2014), never 0. As a second line of defence a value is also treated as missing when it is not finite, or not positive for f0, F1 and F2, or negative for the rate, jitter and shimmer. The fields are the binary32 values of section 11; they are widened to binary64 before any arithmetic below, and each operation is one IEEE-754 binary64 operation.

12.1 Rounding. `R(v)` is round half away from zero: the integer nearest to `v`, an exact tie going to the integer of larger absolute value. With `a = |v|` and `f = floor(a)`: `R(v) = f + 1` if `a - f >= 0.5`, else `f`; negated when `v < 0` (`a - f` is exact in binary64). So `R(2.5) = 3`, `R(-2.5) = -3`, `R(-0.4) = 0`, and the integer 0 is written "0", never "-0".
   - f0 and HNR are whole numbers: `R(x)`.
   - F1 and F2 are rounded to the nearest 10 Hz by the same rule: `10 * R(x / 10)`.
   - Rate, jitter and shimmer have one decimal: `n = R(x * 10)`, written as `|n| div 10`, the decimal separator, `|n| mod 10`, with a leading "-" only when `n < 0`. The multiplication acts on the widened binary32 value, so 4.25 gives "4,3" and 4.35, which is 4.3499999... in binary32, gives "4,3".

12.2 Decimal separator. It is the one of the app's own language, not of the device region: "," in Italian, German, Spanish, French and Brazilian Portuguese, "." in English. The app language is the language of the text the screen shows, fallback included: when the device language is not one the app has, the text falls back to the app's default language (Italian) and the separator falls back with it. A platform therefore takes the separator from the same place as the text (the app-language setting, or the same resource set as the strings), never from the device locale, whose region can change it (it-CH and de-CH use "."). It is the same in the tone row, the technical block and any diagnostics view.

12.3 f0. Wherever f0 is shown (the tone, the technical block, diagnostics) it is `R(f0)`; it is never truncated. 142.7 and 142.5 both give 143.

12.4 Technical block. Three rows, plain text.
   - Jitter / shimmer: "3,0% / 8,5%". The two values are valid together (the stress flag of section 9); when either is missing the row is one dash. Both values are percentages. How they are computed is outside this spec, so the two apps can still show different numbers for them; this section fixes only how a given percentage is written.
   - Pitch / rate: "142 Hz · 4,2 sill/s". Each part has its own dash and the unit goes with its number: "— · 4,2 sill/s", "142 Hz · —", "— · —".
   - HNR: "18 dB", or one dash.

12.5 Tone row. The tone is `R(f0)` followed by " Hz" ("143 Hz"), or the dash alone, without the unit. The details line is the four fields in this order, separated by " · " (space, U+00B7, space): "F1 520 · F2 1480 · 4,2 sill/s · HNR 18 dB". A missing field shows the dash in place of its number: "F1 —", "F2 —", "— sill/s" (the rate keeps its unit), "HNR —" (no "dB"). "F1", "F2", "HNR", "Hz" and "dB" are symbols and are the same in every language. The rate unit is the abbreviation of the app language: "sill/s" (it), "syl/s" (en), "Silb./s" (de), "síl/s" (es), "syll/s" (fr), and "síl/s" (pt-BR, a language only the iOS app has). The widest possible line is "F1 1100 · F2 3200 · 12,0 sill/s · HNR -40 dB" (F1 up to 1100, F2 up to 3200, rate up to 12, HNR from -40 to 40); a screen that fits the text to its width sizes it on that line, on both platforms, so the size does not change when a dash becomes a number.

Conformance. Both apps pin this section with the same table of inputs and expected strings in Italian and English (`display-format-cases.tsv`, one file, identical in both repositories). Some of its rows:

| Field | Value | Shown (it) | Shown (en) |
|---|---|---|---|
| f0, the number (tone row and technical block) | 142.5 | 143 | 143 |
| HNR | -2.5 | -3 dB | -3 dB |
| HNR | -0.4 | 0 dB | 0 dB |
| F1 | 1475 | 1480 | 1480 |
| F2 | 1474.9 | 1470 | 1470 |
| rate | 4.25 | 4,3 sill/s | 4.3 syl/s |
| rate | 4.35 | 4,3 sill/s | 4.3 syl/s |
| rate | 0.05 | 0,1 sill/s | 0.1 syl/s |
| shimmer | 8.45 | 8,4% | 8.4% |
| jitter / shimmer | 1.2 / 3.1 | 1,2% / 3,1% | 1.2% / 3.1% |
| pitch / rate, f0 missing | 4.24 | — · 4,2 sill/s | — · 4.2 syl/s |
| tone, f0 missing | | — | — |
| tone row, everything missing | | F1 — · F2 — · — sill/s · HNR — | F1 — · F2 — · — syl/s · HNR — |

## Appendix G. Test-signal generator (`gen.py`)

Everything in binary64 with the operation order written here; the int16 output is bit-exact across languages in practice, and `vectors.json` carries an FNV-1a hash (`pcm_fnv1a32`) and the plain sum (`pcm_sum`) of every case so a port can check itself.

- Durations: `samples(d) = floor(d*48000 + 0.5)`.
- Noise: xorshift32 with state `x` (a zero seed becomes `0x9E3779B9`): `x ^= x << 13; x ^= x >> 17; x ^= x << 5` on 32-bit unsigned values. `uniform = (x >> 8) * 2^-24`. `gauss = (sum of 12 consecutive uniforms) - 6` (exact in binary64).
- One-pole low-pass: `k = 1 - exp(-2*pi*fc/48000)`, `y = y + k*(x - y)`, `y` starts at 0; `order` cascaded passes.
- Rosenberg glottal-flow derivative, per sample `n`: phase `ph` starts at 0; value = `(pi/(2*tp)) * sin(pi*ph/tp)` if `ph < tp`; `-(pi/(2*tn)) * sin(pi*(ph - tp)/(2*tn))` if `tp <= ph < tp + tn`; else 0. Then `ph = ph + f0[n]/48000`; if `ph >= 1`: `ph = ph - 1`. Default `tp = 0.40`, `tn = 0.16`.
- f0 track: a constant; or `steps` (hold each value for `samples(dur)` samples, last value extended); or `glide [fa, fb]`: `f0[n] = fa*exp(ln(fb/fa)*n/N)`.
- Resonator (Klatt): `C = -exp(-2*pi*B/48000)`, `Bc = 2*exp(-pi*B/48000)*cos(2*pi*F/48000)`, `A = 1 - Bc - C`; `y[n] = A*x[n] + Bc*y[n-1] + C*y[n-2]` evaluated left to right, state starts at 0. Vowels are three cascaded resonators in the order F1, F2, F3: /a/ (700, 80) (1220, 90) (2600, 120); /i/ (270, 80) (2290, 90) (3010, 120); /u/ (300, 80) (870, 90) (2240, 120).
- Scaling to a target rms: `g = target / sqrt((sum of x^2)/N)` over the whole segment; every sample multiplied by `g`.
- Voice segment: source, resonators, scale to `rms`; then an optional syllable envelope (blocks of `per_block` whole syllables of `samples(1/rate)` samples, each `sin^2(pi*t/len)`, followed by `samples(pause_s)` zeros, repeated); then optional additive noise scaled to `rms` (absolute) or to `rms / 10^(snr_db/20)` of the voice's target rms.
- Tone: `peak = rms*sqrt(2)`, `x[n] = peak*sin(2*pi*((freq*n) mod 48000)/48000)` with integer `freq`.
- Silence: zeros. Noise segment: noise (optionally low-passed) scaled to `rms`.
- Case: segments concatenated, multiplied by `gain`, then `q = floor(v*32768 + 0.5)` clamped to [-32768, 32767].
- Events: `{"at_s": t, "gap_ms": g}` means `markDiscontinuity(samples(g/1000))` before sample `samples(t)`.
- `impulses()` in `gen.py` is a validation-only source (unit pulses where the phase wraps); no vector uses it.

## Appendix V. Using `vectors.json`

Each case gives the generator parameters, the chunk sizes to run (`chunk_ms`), the gap events (`events_samples`), the number of steps and the expected value of every field at every step (`expected`; booleans as a string of `0`/`1`). Run the engine once per chunk size; split a chunk at every event sample and call `markDiscontinuity` there. Booleans must match exactly; a number passes when `|got - expected| <= abs + rel*|expected|` with the tolerance of its field (top-level `tolerance`). Cases with `display` also give the section-9 display series computed from the expected results.

No step of any case has a decision (voicing, range checks, root selection, HNR lag, zig-zag, activity) within reach of floating-point noise: `build_vectors.py` checks every comparison margin and every root-selection threshold perturbed by 0.01 Hz, and refuses fragile cases. Tolerances are 60 to 1000 times the largest difference between `ref.py` and a variant with plain left-to-right sums and float32 outputs; 55 of 56 deliberate one-rule deviations are caught, and the one that is not (the envelope's energy floor) has no observable effect.
