import Foundation

/// The three decorative drums of the full level, stepped like the rotors I, II, III of a historical Enigma I (left,
/// middle, right). Graphics only: the cipher of the app is AES-256-GCM and has nothing to do with this.
///
/// Everything here is a pure function of one number, the advance index `k` (how many characters have been resolved so
/// far). No key, nonce, text or cipher byte can reach it, and it keeps no state: the same `k` always gives the same drums.
///
/// Positions are 0...25 (A...Z) and travel packed in one Int (`(left * 26 + middle) * 26 + right`).
///
/// Mechanism, as in the machine: on every press the right drum steps. The middle drum steps when the right drum was on
/// its notch (rotor III: V -> W) and also, in the famous anomaly (double step), whenever the middle drum itself sits on
/// its own notch (rotor II: E -> F); in that same press the left drum steps too. The notch of the left drum (rotor I,
/// Q -> R) would act on a fourth drum that this machine does not have, so it moves nothing.
public enum EnigmaRotors {
    /// Notch of the right drum (rotor III): V.
    public static let notchRight: Int = 21
    /// Notch of the middle drum (rotor II): E.
    public static let notchMiddle: Int = 4
    /// Notch of the left drum (rotor I): Q. It drives nothing.
    public static let notchLeft: Int = 16

    /// Presses after which the whole mechanism repeats (26 * 25 * 26: the double step skips one middle position).
    public static let period: Int = 26 * 25 * 26

    /// Fixed starting window "PDU": close to the notches, so even a short message shows a carry and a double step.
    public static let start: Int = (15 * 26 + 3) * 26 + 20

    private static let leftWeight: Int = 26 * 26
    private static let bounce: Double = 1.2

    public static func pack(left: Int, middle: Int, right: Int) -> Int {
        (left * 26 + middle) * 26 + right
    }

    public static func left(_ p: Int) -> Int { (max(0, p) / leftWeight) % 26 }

    public static func middle(_ p: Int) -> Int { (max(0, p) / 26) % 26 }

    public static func right(_ p: Int) -> Int { max(0, p) % 26 }

    /// Drums after `k` resolved characters, from the fixed `start` window. Negative `k` counts as 0.
    public static func step(_ k: Int) -> Int { stepFrom(start, k) }

    /// Same as `step` from another start window (the tests compare it with a literal model of the mechanism).
    public static func stepFrom(_ startWindow: Int, _ k: Int) -> Int {
        var n = k < 0 ? 0 : k
        // The mechanism is periodic from the very first presses on: keep the loop short whatever k is.
        if n >= 2 * period { n -= (n / period - 1) * period }
        var p = startWindow
        while n > 0 {
            p = advance(p)
            n -= 1
        }
        return p
    }

    /// One press of the key.
    static func advance(_ p: Int) -> Int {
        let l = left(p)
        let m = middle(p)
        let r = right(p)
        let middleOnNotch = (m == notchMiddle)
        let nl = middleOnNotch ? (l + 1) % 26 : l
        let nm = (middleOnNotch || r == notchRight) ? (m + 1) % 26 : m
        return (nl * 26 + nm) * 26 + (r + 1) % 26
    }

    /// The click of a drum moving by one position, `f` = 0...1 along the move: it starts at rest (0), leaves quickly,
    /// overshoots by about 5 % and settles on 1 (a ratchet snapping into its tooth). Outside 0...1 it is clamped.
    public static func snap(_ f: Double) -> Double {
        if f.isNaN || f <= 0.0 { return 0.0 }
        if f >= 1.0 { return 1.0 }
        let t = f - 1.0
        let s = 1.0 + (bounce + 1.0) * t * t * t + bounce * t * t
        return s < 0.0 ? 0.0 : s
    }

    /// Where the three drums are drawn for the continuous advance index `kf`: on a whole index they sit exactly on `step`;
    /// between two whole indexes the drums that are about to move roll toward their next position with the `snap` curve
    /// (so the right drum clicks for every character, the middle one at its carry, the left one at the double step).
    /// Returns left, middle, right as letter positions in 0..<26 (fractions mean "between two letters").
    public static func visual(_ kf: Double) -> (left: Double, middle: Double, right: Double) {
        visualFrom(start, kf)
    }

    public static func visualFrom(_ startWindow: Int, _ kf: Double) -> (left: Double, middle: Double, right: Double) {
        let x: Double = (kf.isNaN || kf < 0.0) ? 0.0 : min(kf, 1.0e9)
        let k = Int(x)
        let f = x - Double(k)
        let cur = stepFrom(startWindow, k)
        let next = advance(cur)
        let s = snap(f)
        let l = place(left(cur), left(next), s)
        let m = place(middle(cur), middle(next), s)
        let r = place(right(cur), right(next), s)
        return (l, m, r)
    }

    private static func place(_ cur: Int, _ next: Int, _ s: Double) -> Double {
        if cur == next { return Double(cur) }
        var v = Double(cur) + s
        if v >= 26.0 { v -= 26.0 }
        return v < 0.0 ? 0.0 : v
    }
}

/// Upload panel: the position of the decorative drums while a file uploads. A function of the real progress fraction
/// (bytes already on the server out of the total: counts, never content) and of nothing else.
public enum EnigmaUpload {
    /// Clicks of the right drum over a whole upload (the drums turn at the pace of the real progress, not of a clock).
    public static let span: Double = 120.0

    /// Continuous advance index of the drums for a progress `fraction` (anything outside 0...1, or NaN, is clamped).
    public static func rotorIndex(_ fraction: Double) -> Double { clamp(fraction) * span }

    /// Whole percent for the label, 0...100.
    public static func percent(_ fraction: Double) -> Int {
        let value = EnigmaFrame.safeInt(clamp(fraction) * 100.0)
        return min(100, max(0, value))
    }

    /// The panel only ever goes forward: the "sealing" and "uploading" stages of a transfer may each report a count that
    /// starts again at zero, and a panel that went backwards would lie.
    public static func monotonic(previous: Double, next: Double) -> Double {
        let p = clamp(previous)
        let n = clamp(next)
        return n > p ? n : p
    }

    private static func clamp(_ f: Double) -> Double { f.isNaN ? 0.0 : min(1.0, max(0.0, f)) }
}

/// The file name as the scene shows it: the name the bubble already shows, cleaned of characters that could bend the
/// layout (bidirectional overrides, zero-width marks, line and paragraph separators, controls).
public enum EnigmaText {
    /// `raw` without control and format characters, whitespace runs folded to one space, trimmed. The joiners (ZWJ, ZWNJ)
    /// stay: they keep emoji sequences and Persian words whole. Empty when nothing is left (no scene then).
    public static func sceneName(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        var lastSpace = true
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            if value == 0x200C || value == 0x200D {
                out.append(scalar)
                lastSpace = false
                continue
            }
            let props = scalar.properties
            if props.isWhitespace || props.generalCategory == .spaceSeparator {
                if !lastSpace { out.append(" ") }
                lastSpace = true
                continue
            }
            switch props.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned:
                continue
            default:
                out.append(scalar)
                lastSpace = false
            }
        }
        var result = String(out)
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }
}
