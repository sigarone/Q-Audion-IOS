import Foundation

/// The frame function: pure and deterministic. The same (units, p, level, seed, frameIndex) gives the same string, and at
/// p >= 1 it gives exactly the target, whatever the seed.
///
/// Decorative characters come from a seeded integer hash of (seed, frameIndex, position) and a fixed ASCII alphabet.
/// Nothing here can see a key, a nonce or any derived material: the seed is drawn from a plain random source when the
/// scene is created (see `EnigmaEffect`).
public enum EnigmaFrame {
    public static let charset: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=#$%&*<>{}[]"
    private static let alphabet: [Character] = Array(charset)

    /// Width of the band of scrambled characters in front of the revealed prefix (full level only).
    private static let bandFull: Int = 6
    private static let tailNoise: Double = 0.15
    private static let noiseSalt: UInt64 = 0x5DEECE66D

    public static func ease(_ p: Double) -> Double {
        let clamped = p.isNaN ? 0.0 : min(1.0, max(0.0, p))
        return 1.0 - pow(1.0 - clamped, 2.2)
    }

    /// Finite Double to Int, never trapping (NaN and infinities read as 0).
    static func safeInt(_ value: Double) -> Int {
        if !value.isFinite { return 0 }
        if value > 1.0e9 { return 1_000_000_000 }
        if value < -1.0e9 { return -1_000_000_000 }
        return Int(value)
    }

    /// Writes one frame of the transformation `from` -> `to` at progress `p` (0...1) into `out` (cleared first) and
    /// returns the number of revealed units (the only input of the decorative rotors).
    ///
    /// `suffix` is appended unchanged: the part of the plain text beyond the 240 animated units.
    @discardableResult
    public static func render(
        into out: inout String,
        from: EnigmaUnits,
        to: EnigmaUnits,
        p: Double,
        full: Bool,
        seed: UInt64,
        frameIndex: Int,
        suffix: String
    ) -> Int {
        out.removeAll(keepingCapacity: true)
        let pp: Double = p.isNaN ? 0.0 : min(1.0, max(0.0, p))
        let n = to.count
        let m = from.count
        let e = ease(pp)
        let reveal: Int = pp >= 1.0 ? n : min(n, max(0, safeInt((e * Double(n)).rounded(.down))))
        let band = full ? bandFull : 0
        let tail: Int = pp >= 1.0 ? 0 : max(0, safeInt(((1.0 - e) * Double(max(0, m - n))).rounded()))
        var i = 0
        while i < n {
            if i < reveal {
                to.append(to: &out, index: i)
            } else if i < reveal + band {
                out.append(randomChar(seed: seed, frameIndex: frameIndex, i: i))
            } else if i < m {
                from.append(to: &out, index: i)
            } else if full {
                out.append(randomChar(seed: seed, frameIndex: frameIndex, i: i))
            }
            i += 1
        }
        var t = n
        let end = n + tail
        while t < end {
            if full && fraction(seed: seed, frameIndex: frameIndex, i: t) < tailNoise {
                out.append(randomChar(seed: seed, frameIndex: frameIndex, i: t))
            } else if t < m {
                from.append(to: &out, index: t)
            }
            t += 1
        }
        out.append(suffix)
        return reveal
    }

    /// Convenience for tests and one-off use.
    public static func frame(
        from: EnigmaUnits, to: EnigmaUnits, p: Double, full: Bool, seed: UInt64, frameIndex: Int, suffix: String
    ) -> String {
        var out = ""
        render(into: &out, from: from, to: to, p: p, full: full, seed: seed, frameIndex: frameIndex, suffix: suffix)
        return out
    }

    /// Decorative rotor `k` (0...2) position 0...25, a function of the reveal index only (the flat fallback; the
    /// historical drums use `EnigmaRotors`).
    public static func rotor(_ k: Int, reveal: Int) -> Int {
        let r = max(0, reveal)
        switch k {
        case 0: return r % 26
        case 1: return (r / 3 + 7) % 26
        default: return (r / 9 + 19) % 26
        }
    }

    static func randomChar(seed: UInt64, frameIndex: Int, i: Int) -> Character {
        let h = mix(seed: seed, frameIndex: frameIndex, i: i)
        let count = UInt64(alphabet.count)
        let index = Int((h >> 33) % count)
        return alphabet[index]
    }

    private static func fraction(seed: UInt64, frameIndex: Int, i: Int) -> Double {
        let h = mix(seed: seed ^ noiseSalt, frameIndex: frameIndex, i: i)
        let top: UInt64 = h >> 11
        let denominator: Double = Double(UInt64(1) << 53)
        return Double(top) / denominator
    }

    /// splitmix64 finalizer over (seed, frameIndex, i).
    static func mix(seed: UInt64, frameIndex: Int, i: Int) -> UInt64 {
        let a: UInt64 = UInt64(truncatingIfNeeded: frameIndex) << 24
        let b: UInt64 = UInt64(truncatingIfNeeded: i)
        let golden: UInt64 = 0x9E37_79B9_7F4A_7C15
        var z: UInt64 = seed &+ ((a ^ b) &* golden)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
