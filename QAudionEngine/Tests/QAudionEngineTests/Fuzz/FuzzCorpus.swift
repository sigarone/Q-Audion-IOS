import Foundation

/// Deterministic input generator shared by the parser fuzz suites.
///
/// Goals:
/// - **Reproducible**: a fixed seed PRNG so a CI failure is replayable.
/// - **Adversarial**: covers empty / 1-byte / MAXLEN / MAXLEN+1 /
///   all-0x00 / all-0xFF / random / structurally-mutated inputs.
/// - **Cheap**: plain XCTest, no libFuzzer / sanitizer build needed,
///   so it runs in the existing `engine-tests.yml` pipeline.
///
/// The contract every parser under test must satisfy: for ANY input
/// it returns `nil` / throws cleanly / produces a value — it must
/// NEVER crash, read out of bounds, or hang. The XCTest process
/// aborting on a Swift trap (precondition / index OOB / `Int64(inf)`)
/// is itself the failure signal; no extra assertion is required to
/// catch a crash.
struct FuzzRng {
    private var state: UInt64

    init(seed: UInt64) {
        // SplitMix64 — small, fast, good distribution, fully
        // deterministic across platforms (no Foundation RNG drift).
        self.state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func byte() -> UInt8 {
        return UInt8(next() & 0xFF)
    }

    /// Uniform integer in `0..<bound` (bound > 0).
    mutating func int(_ bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        return Int(next() % UInt64(bound))
    }

    /// Random buffer of the given length.
    mutating func bytes(_ count: Int) -> Data {
        guard count > 0 else { return Data() }
        var d = Data(count: count)
        for i in 0..<count { d[i] = byte() }
        return d
    }
}

enum FuzzCorpus {
    /// Boundary lengths every byte-buffer parser should be probed at.
    /// `maxLen` is the parser's own declared upper structural bound.
    static func boundaryLengths(maxLen: Int) -> [Int] {
        var lens = [0, 1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 33, 63, 64, 65]
        lens.append(maxLen - 1)
        lens.append(maxLen)
        lens.append(maxLen + 1)
        lens.append(maxLen * 2)
        return lens.filter { $0 >= 0 }
    }

    /// Fixed-fill buffers (all-0x00, all-0xFF, all-0x80, all-0x7F)
    /// at every boundary length — these surface off-by-one and
    /// sign-extension bugs that random data misses.
    static func fillCorpus(maxLen: Int) -> [Data] {
        var out: [Data] = []
        let fills: [UInt8] = [0x00, 0xFF, 0x80, 0x7F, 0xE3, 0x01]
        for len in boundaryLengths(maxLen: maxLen) where len >= 0 {
            for f in fills {
                out.append(Data(repeating: f, count: len))
            }
        }
        return out
    }

    /// Random buffers across the boundary length set, seeded so the
    /// exact corpus is identical on every CI run.
    static func randomCorpus(maxLen: Int, perLength: Int, seed: UInt64) -> [Data] {
        var rng = FuzzRng(seed: seed)
        var out: [Data] = []
        for len in boundaryLengths(maxLen: maxLen) where len >= 0 {
            for _ in 0..<perLength {
                out.append(rng.bytes(len))
            }
        }
        // A spray of fully random length+content too.
        for _ in 0..<(perLength * 8) {
            let len = rng.int(maxLen + 2)
            out.append(rng.bytes(len))
        }
        return out
    }

    /// Bit/byte-level mutations of a known-good seed: flip a byte,
    /// truncate, extend, zero a region, splice. Catches parsers that
    /// only validate a happy path and trust internal length fields.
    static func mutations(of seed: Data, count: Int, rngSeed: UInt64) -> [Data] {
        guard !seed.isEmpty else { return [] }
        var rng = FuzzRng(seed: rngSeed)
        var out: [Data] = []
        let base = Array(seed)
        for _ in 0..<count {
            var m = base
            switch rng.int(7) {
            case 0:                                   // single byte flip
                let i = rng.int(m.count)
                m[i] = m[i] ^ UInt8(1 << rng.int(8))
            case 1:                                   // truncate
                let keep = rng.int(m.count)
                m = Array(m.prefix(keep))
            case 2:                                   // extend with junk
                let extra = 1 + rng.int(32)
                for _ in 0..<extra { m.append(rng.byte()) }
            case 3:                                   // zero a region
                let a = rng.int(m.count)
                let b = min(m.count, a + 1 + rng.int(8))
                for i in a..<b { m[i] = 0 }
            case 4:                                   // 0xFF a region
                let a = rng.int(m.count)
                let b = min(m.count, a + 1 + rng.int(8))
                for i in a..<b { m[i] = 0xFF }
            case 5:                                   // overwrite length-ish prefix
                for i in 0..<min(8, m.count) { m[i] = rng.byte() }
            default:                                  // random splice
                let i = rng.int(m.count)
                m[i] = rng.byte()
            }
            out.append(Data(m))
        }
        return out
    }

    /// Wrap a buffer in a non-zero-`startIndex` `Data` slice. Swift
    /// `Data` slicing keeps absolute indices; a parser that does
    /// `subdata(in: absoluteRange)` or integer index math against a
    /// slice OOB-reads or decodes garbage. This generator exercises
    /// exactly that hazard.
    static func sliced(_ d: Data, prefixPad: Int = 7) -> Data {
        var padded = Data(repeating: 0xAB, count: prefixPad)
        padded.append(d)
        return padded.suffix(d.count)   // non-zero startIndex view
    }
}
