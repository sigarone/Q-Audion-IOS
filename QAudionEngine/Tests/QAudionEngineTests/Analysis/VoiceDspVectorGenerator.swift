import Foundation

/// Port of the test-signal generator of the voice-analysis specification
/// (docs/voice-analysis-spec.md, appendix G). Everything is binary64 with the operation order written in the
/// specification, so the int16 output is bit-exact with the reference
/// implementation's: `voicedsp-vectors.json` carries a hash and the plain sum of
/// every case so this port can check itself before an engine is blamed.
///
/// A case is `{"segments": [...], "gain": g, "events": [...]}` as decoded from the
/// vectors file (`[String: Any]`); see `build(_:)`.
enum VoiceDspVectorGenerator {
    static let sampleRate = 48_000.0

    /// F1/F2/F3 and their bandwidths, the cascade order of the vowels.
    static let vowels: [String: [(Double, Double)]] = [
        "a": [(700.0, 80.0), (1220.0, 90.0), (2600.0, 120.0)],
        "i": [(270.0, 80.0), (2290.0, 90.0), (3010.0, 120.0)],
        "u": [(300.0, 80.0), (870.0, 90.0), (2240.0, 120.0)],
    ]

    // MARK: - Noise

    /// xorshift32; a zero seed becomes 0x9E3779B9.
    struct Rng {
        private var x: UInt32

        init(seed: UInt32) {
            x = seed == 0 ? 0x9E37_79B9 : seed
        }

        private mutating func next() -> UInt32 {
            x ^= x << 13
            x ^= x >> 17
            x ^= x << 5
            return x
        }

        mutating func uniform() -> Double {
            Double(next() >> 8) * (1.0 / 16_777_216.0)
        }

        /// Sum of 12 consecutive uniforms minus 6 (exact in binary64).
        mutating func gauss() -> Double {
            var s = 0.0
            for _ in 0..<12 { s += uniform() }
            return s - 6.0
        }
    }

    static func samples(_ seconds: Double) -> Int {
        Int((seconds * sampleRate + 0.5).rounded(.down))
    }

    static func rms(_ x: [Double]) -> Double {
        var s = 0.0
        for v in x { s += v * v }
        return (s / Double(x.count)).squareRoot()
    }

    static func scale(_ x: [Double], toRms target: Double) -> [Double] {
        let g = target / rms(x)
        return x.map { $0 * g }
    }

    /// One-pole low-pass `y += k (x - y)`, `k = 1 - exp(-2 pi fc / fs)`, `order` passes.
    static func lowpass(_ x: [Double], cutoff fc: Double) -> [Double] {
        let k = 1.0 - exp(-2.0 * Double.pi * fc / sampleRate)
        var y = 0.0
        var out = [Double](repeating: 0, count: x.count)
        for i in 0..<x.count {
            y = y + k * (x[i] - y)
            out[i] = y
        }
        return out
    }

    static func noise(_ n: Int, seed: UInt32, lowpassHz: Double?, order: Int) -> [Double] {
        var rng = Rng(seed: seed)
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n { x[i] = rng.gauss() }
        if let fc = lowpassHz {
            for _ in 0..<order { x = lowpass(x, cutoff: fc) }
        }
        return x
    }

    // MARK: - Voice

    /// f0 per sample: a number, `{"steps": [[dur_s, f0], ...]}` (each value held for its
    /// duration, the last one extended) or `{"glide": [fa, fb]}` (exponential).
    static func f0Track(_ spec: Any, count n: Int) -> [Double] {
        if let value = number(spec) { return [Double](repeating: value, count: n) }
        guard let dict = spec as? [String: Any] else { fatalError("bad f0 spec") }
        if let steps = dict["steps"] as? [Any] {
            var out: [Double] = []
            for step in steps {
                let pair = numbers(step)!
                out.append(contentsOf: [Double](repeating: pair[1], count: samples(pair[0])))
            }
            let last = out[out.count - 1]
            while out.count < n { out.append(last) }
            return Array(out[0..<n])
        }
        if let glide = numbers(dict["glide"]) {
            let fa = glide[0]
            let k = log(glide[1] / fa)
            var out = [Double](repeating: 0, count: n)
            for i in 0..<n { out[i] = fa * exp(k * Double(i) / Double(n)) }
            return out
        }
        fatalError("bad f0 spec")
    }

    /// Rosenberg glottal-flow derivative; the phase starts at 0 and sample `i` uses the
    /// phase before the increment.
    static func rosenberg(_ f0s: [Double], tp: Double, tn: Double) -> [Double] {
        var out = [Double](repeating: 0, count: f0s.count)
        var ph = 0.0
        let rise = Double.pi / (2.0 * tp)
        let fall = Double.pi / (2.0 * tn)
        for i in 0..<f0s.count {
            if ph < tp {
                out[i] = rise * sin(Double.pi * ph / tp)
            } else if ph < tp + tn {
                out[i] = -fall * sin(Double.pi * (ph - tp) / (2.0 * tn))
            } else {
                out[i] = 0
            }
            ph = ph + f0s[i] / sampleRate
            if ph >= 1.0 { ph = ph - 1.0 }
        }
        return out
    }

    /// Klatt second-order resonator.
    static func resonate(_ x: [Double], frequency: Double, bandwidth: Double) -> [Double] {
        let c = -exp(-2.0 * Double.pi * bandwidth / sampleRate)
        let b = 2.0 * exp(-Double.pi * bandwidth / sampleRate) * cos(2.0 * Double.pi * frequency / sampleRate)
        let a = 1.0 - b - c
        var y1 = 0.0
        var y2 = 0.0
        var out = [Double](repeating: 0, count: x.count)
        for i in 0..<x.count {
            let y = a * x[i] + b * y1 + c * y2
            y2 = y1
            y1 = y
            out[i] = y
        }
        return out
    }

    /// Blocks of `perBlock` whole sin^2 syllables of `1/rate` seconds, then `pause` seconds of zeros.
    static func syllableEnvelope(_ n: Int, rate: Double, perBlock: Int, pause: Double) -> [Double] {
        let syl = samples(1.0 / rate)
        let speak = syl * perBlock
        let block = speak + samples(pause)
        var env = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = i % block
            if t < speak {
                let s = sin(Double.pi * Double(t % syl) / Double(syl))
                env[i] = s * s
            }
        }
        return env
    }

    static func tone(_ n: Int, frequency: Int, rms: Double) -> [Double] {
        let peak = rms * 2.0.squareRoot()
        let rate = Int(sampleRate)
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = peak * sin(2.0 * Double.pi * Double((frequency * i) % rate) / sampleRate)
        }
        return out
    }

    // MARK: - Cases

    /// A JSON number as a Double (an integer literal decodes as Int on some platforms).
    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func numbers(_ any: Any?) -> [Double]? {
        guard let array = any as? [Any] else { return nil }
        var out: [Double] = []
        for element in array {
            guard let v = number(element) else { return nil }
            out.append(v)
        }
        return out
    }

    static func segment(_ seg: [String: Any]) -> [Double] {
        let n = samples(number(seg["dur_s"])!)
        let kind = seg["type"] as! String
        switch kind {
        case "silence":
            return [Double](repeating: 0, count: n)
        case "noise":
            let x = noise(n, seed: UInt32(number(seg["seed"])!), lowpassHz: number(seg["lowpass_hz"]),
                          order: Int(number(seg["order"]) ?? 1))
            return scale(x, toRms: number(seg["rms"])!)
        case "tone":
            return tone(n, frequency: Int(number(seg["freq"])!), rms: number(seg["rms"])!)
        case "voice":
            let f0s = f0Track(seg["f0"]!, count: n)
            var tp = 0.40
            var tn = 0.16
            if let shape = numbers(seg["shape"]) {
                tp = shape[0]
                tn = shape[1]
            }
            var x = rosenberg(f0s, tp: tp, tn: tn)
            var resonators = vowels[(seg["vowel"] as? String) ?? ""] ?? []
            if let formants = seg["formants"] as? [Any] {
                resonators = formants.map { (numbers($0)![0], numbers($0)![1]) }
            }
            for (frequency, bandwidth) in resonators {
                x = resonate(x, frequency: frequency, bandwidth: bandwidth)
            }
            x = scale(x, toRms: number(seg["rms"])!)
            if let env = seg["syllables"] as? [String: Any] {
                let e = syllableEnvelope(n, rate: number(env["rate"])!, perBlock: Int(number(env["per_block"])!),
                                         pause: number(env["pause_s"])!)
                for i in 0..<n { x[i] = x[i] * e[i] }
            }
            if let nz = seg["noise"] as? [String: Any] {
                var w = noise(n, seed: UInt32(number(nz["seed"])!), lowpassHz: number(nz["lowpass_hz"]),
                              order: Int(number(nz["order"]) ?? 1))
                let target: Double
                if let absolute = number(nz["rms"]) {
                    target = absolute
                } else {
                    target = number(seg["rms"])! / pow(10.0, number(nz["snr_db"])! / 20.0)
                }
                w = scale(w, toRms: target)
                for i in 0..<n { x[i] = x[i] + w[i] }
            }
            return x
        default:
            fatalError("unknown segment type \(kind)")
        }
    }

    /// The value that is floored to give each int16 sample: segments concatenated, multiplied by
    /// `gain`, then `v * 32768 + 0.5`.
    static func quantiserInput(_ spec: [String: Any]) -> [Double] {
        var x: [Double] = []
        for seg in spec["segments"] as! [[String: Any]] { x.append(contentsOf: segment(seg)) }
        let gain = number(spec["gain"]) ?? 1.0
        for i in 0..<x.count { x[i] = x[i] * gain * 32768.0 + 0.5 }
        return x
    }

    /// `floor` of the quantiser input, clamped to int16.
    static func quantise(_ input: [Double]) -> [Int16] {
        var pcm = [Int16](repeating: 0, count: input.count)
        for i in 0..<input.count {
            pcm[i] = Int16(max(-32768.0, min(32767.0, input[i].rounded(.down))))
        }
        return pcm
    }

    /// Segments concatenated, multiplied by `gain`, then `floor(v * 32768 + 0.5)` clamped to int16.
    /// `events` are `(sampleIndex, gapSamples)`: a discontinuity of that many missing samples
    /// before that sample.
    static func build(_ spec: [String: Any]) -> (pcm: [Int16], events: [(at: Int, gap: Int)]) {
        let pcm = quantise(quantiserInput(spec))
        var events: [(at: Int, gap: Int)] = []
        for e in (spec["events"] as? [[String: Any]]) ?? [] {
            events.append((samples(number(e["at_s"])!), samples(number(e["gap_ms"])! / 1000.0)))
        }
        return (pcm, events)
    }

    /// FNV-1a over the little-endian bytes of the int16 samples.
    static func fnv1a32(_ pcm: [Int16]) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        for s in pcm {
            let u = UInt16(bitPattern: s)
            h ^= UInt32(u & 0xFF)
            h = h &* 0x0100_0193
            h ^= UInt32(u >> 8)
            h = h &* 0x0100_0193
        }
        return h
    }

    /// Why the hash of a case may differ from the reference's, for the message of a failing test.
    ///
    /// The generator is bit-exact because every operation is IEEE-754 binary64 in the order of the
    /// specification, except `sin`, `cos`, `exp`, `log` and `pow`, which come from the platform's libm and may
    /// differ from the reference's by one ulp. That can change an int16 sample only when the value that is
    /// floored lies within a few ulps (about 1e-11 LSB, after the filters) of an integer. This lists the
    /// samples within `margin` LSB of one, and looks for the sample, or the pair of samples, that came out on
    /// the other side of the boundary and so reproduces the expected hash: that names the sample that differs.
    /// No sample near a boundary means the difference is not libm noise but a real difference in the port.
    static func explainHashMismatch(quantiserInput input: [Double], expectedHash: UInt32,
                                    margin: Double = 1e-7, maxCandidates: Int = 24) -> String {
        var candidates: [Int] = []
        for i in 0..<input.count where abs(input[i] - input[i].rounded()) <= margin { candidates.append(i) }
        if candidates.isEmpty {
            return "no sample lies within \(margin) LSB of a rounding boundary, so a one-ulp libm difference "
                + "cannot explain it: this is a difference in the port or in the input, not libm noise"
        }
        var pcm = quantise(input)
        let out = "\(candidates.count) sample(s) lie within \(margin) LSB of a rounding boundary: "
            + candidates.prefix(maxCandidates).map { "\($0) (floor of \(input[$0]))" }.joined(separator: ", ")
        guard candidates.count <= maxCandidates else {
            return out + "; too many to search for the flipped one"
        }
        /// The int16 on the other side of the boundary.
        func other(_ i: Int) -> Int16 {
            let boundary = input[i].rounded()
            let flipped = input[i] >= boundary ? boundary - 1 : boundary
            return Int16(max(-32768.0, min(32767.0, flipped)))
        }
        for i in candidates {
            let kept = pcm[i]
            pcm[i] = other(i)
            if fnv1a32(pcm) == expectedHash {
                return out + "; the expected hash is reproduced by rounding sample \(i) the other way (\(kept) "
                    + "became \(pcm[i])): the reference and this libm differ by one ulp there"
            }
            pcm[i] = kept
        }
        for (n, i) in candidates.enumerated() {
            for j in candidates[(n + 1)...] {
                let keptI = pcm[i]
                let keptJ = pcm[j]
                pcm[i] = other(i)
                pcm[j] = other(j)
                if fnv1a32(pcm) == expectedHash {
                    return out + "; the expected hash is reproduced by rounding samples \(i) and \(j) the other "
                        + "way: the reference and this libm differ by one ulp there"
                }
                pcm[i] = keptI
                pcm[j] = keptJ
            }
        }
        return out + "; flipping one or two of them does not reproduce the expected hash, so the difference "
            + "is not (only) libm noise"
    }

    /// Little-endian int16 bytes, as the engine receives them.
    static func data(_ pcm: ArraySlice<Int16>) -> Data {
        var d = Data(capacity: pcm.count * 2)
        for s in pcm {
            let u = UInt16(bitPattern: s)
            d.append(UInt8(u & 0xFF))
            d.append(UInt8(u >> 8))
        }
        return d
    }
}
