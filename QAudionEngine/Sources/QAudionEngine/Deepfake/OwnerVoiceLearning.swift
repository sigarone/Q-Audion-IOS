import Foundation

/// The rules by which the owner's voice template is learned from the owner's own calls ("Voce come chiave"): which
/// windows are kept, when there is enough of them for a first usable template (MIN), when the template is
/// refined and collection stops (REFINED), and how the windows become one template. Pure functions of embedding
/// vectors and timestamps: no storage, no model, no clock.
///
/// The unit is the 4 s window of `OwnerContinuityMonitor`: one embedding of 400 fbank frames, taken from the
/// local microphone only and only when the window holds speech (`OwnerContinuityMonitor.minSpeechMs`).
///
/// Nothing is rejected while windows are collected. All filtering happens once, at fusion, against the medoid (the
/// window most like all the others), which a minority of bad windows cannot move; a mean seeded by the first window
/// would let that window define the voice.
public enum OwnerVoiceLearning {

    /// One kept window: its embedding and where it came from.
    public struct Window: Equatable, Sendable {
        public let embedding: [Float]
        /// The call it was captured in: the key of the diversity rule.
        public let callId: String
        /// Wall clock at capture, in milliseconds since 1970: the key of the distinct-days rule.
        public let capturedAtEpochMs: Int64
        /// Milliseconds of audio the window stands for (its length), which is what the speech-time rule adds up.
        public let netSpeechMs: Int

        public init(embedding: [Float], callId: String, capturedAtEpochMs: Int64, netSpeechMs: Int) {
            self.embedding = embedding
            self.callId = callId
            self.capturedAtEpochMs = capturedAtEpochMs
            self.netSpeechMs = netSpeechMs
        }
    }

    /// How far the kept windows are from the gates, for the log and the tests.
    public struct GateStatus: Equatable, Sendable {
        public let windows: Int
        public let distinctCalls: Int
        public let distinctDays: Int
        public let netSpeechMs: Int
        /// MIN reached: enough for a first usable template.
        public let met: Bool

        /// How close the material is to MIN, in `0...1`: the furthest-behind of the four rules decides.
        public var fraction: Double {
            OwnerVoiceLearning.progress(
                self, windows: OwnerVoiceLearning.minWindows, calls: OwnerVoiceLearning.minDistinctCalls,
                days: OwnerVoiceLearning.minDistinctDays, speechMs: OwnerVoiceLearning.minNetSpeechMs)
        }
    }

    /// The template a set of windows gives.
    public struct FusionResult: Equatable, Sendable {
        public let centroid: [Float]
        public let survivorCount: Int
        public let trimmedCount: Int
        /// Mean pairwise raw cosine of the windows that survived the trim.
        public let meanPairwiseCosine: Float
    }

    /// Where the learning of an account stands.
    public enum Stage: Int, Comparable, Sendable {
        /// Less than MIN: no template yet from calls.
        case learning
        /// MIN reached: a usable template, which keeps improving.
        case min
        /// REFINED reached: the template is final and collection stops.
        case refined

        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    // MARK: - Rules

    /// MIN: the first usable template. 10 windows (40 s) from at least 2 calls.
    public static let minWindows = 10
    public static let minDistinctCalls = 2
    public static let minDistinctDays = 1
    public static let minNetSpeechMs = 40_000

    /// REFINED: the template that keeps improving until the material reaches 30 windows (120 s), 6 calls and 3 days.
    public static let refinedWindows = 30
    public static let refinedDistinctCalls = 6
    public static let refinedDistinctDays = 3
    public static let refinedNetSpeechMs = 120_000

    /// At most this many windows of one call count, so that one session cannot weigh more than the others and the
    /// rule of several calls means something. Also bounds the model work done during a call.
    public static let maxWindowsPerCall = 6

    /// Windows older than this are dropped, so a half-finished collection does not sit on the phone for ever.
    public static let progressMaxAgeMs: Int64 = 30 * 24 * 60 * 60 * 1000

    /// The most windows kept (about 2 KB each). When there are more, the oldest of the busiest calendar day go first,
    /// so every day keeps a window and the distinct-days rule can still be met by a person who calls a lot.
    public static let maxRetainedWindows = 90

    /// Fraction of the windows furthest from the medoid that is dropped at fusion.
    static let trimFraction: Float = 0.30
    /// Fewer survivors than this and nothing is fused: collection goes on.
    static let minSurvivors = 6
    /// Survivors that agree with each other less than this (raw cosine) are not one speaker in one condition: no
    /// template.
    static let minCoherenceCosine: Float = 0.35

    private static let msPerDay: Int64 = 24 * 60 * 60 * 1000

    // MARK: - Gates

    public static func gateStatus(_ windows: [Window]) -> GateStatus {
        let calls = Set(windows.map(\.callId)).count
        let days = Set(windows.map { $0.capturedAtEpochMs / msPerDay }).count
        let speech = windows.reduce(0) { $0 + $1.netSpeechMs }
        return GateStatus(
            windows: windows.count,
            distinctCalls: calls,
            distinctDays: days,
            netSpeechMs: speech,
            met: windows.count >= minWindows && calls >= minDistinctCalls && days >= minDistinctDays
                && speech >= minNetSpeechMs)
    }

    /// True while the material is short of REFINED, so that more calls are still worth learning from.
    public static func shouldRefine(_ status: GateStatus) -> Bool {
        status.windows < refinedWindows || status.distinctCalls < refinedDistinctCalls
            || status.distinctDays < refinedDistinctDays || status.netSpeechMs < refinedNetSpeechMs
    }

    /// How close the material is to REFINED, in `0...1`, by the same rule as `GateStatus.fraction`.
    public static func maturity(_ status: GateStatus) -> Double {
        progress(status, windows: refinedWindows, calls: refinedDistinctCalls,
                 days: refinedDistinctDays, speechMs: refinedNetSpeechMs)
    }

    fileprivate static func progress(_ status: GateStatus, windows: Int, calls: Int, days: Int, speechMs: Int) -> Double {
        let axes = [Double(status.windows) / Double(windows),
                    Double(status.distinctCalls) / Double(calls),
                    Double(status.distinctDays) / Double(days),
                    Double(status.netSpeechMs) / Double(speechMs)]
        return min(max(axes.min() ?? 0, 0), 1)
    }

    public static func stage(_ status: GateStatus) -> Stage {
        if !shouldRefine(status) { return .refined }
        return status.met ? .min : .learning
    }

    // MARK: - Fusion

    /// The template the windows give, or `nil` when they do not justify one yet: MIN not reached, too few windows
    /// survive the trim, or the survivors do not agree with each other. Nothing unvouchable is ever stored.
    public static func fuse(_ windows: [Window]) -> FusionResult? {
        guard gateStatus(windows).met, let dim = windows.first?.embedding.count, dim > 0,
              windows.allSatisfy({ $0.embedding.count == dim }) else { return nil }
        let embeddings = windows.map(\.embedding)
        let medoid = embeddings[medoidIndex(embeddings)]

        // A fixed proportion and not a similarity cutoff, so how much is dropped does not depend on how much is bad.
        let ranked = embeddings.sorted { cosine($0, medoid) > cosine($1, medoid) }
        let keep = max(minSurvivors, Int(Float(ranked.count) * (1 - trimFraction)))
        let survivors = Array(ranked.prefix(keep))
        guard survivors.count >= minSurvivors else { return nil }

        let coherence = meanPairwiseCosine(survivors)
        guard coherence >= minCoherenceCosine else { return nil }
        return FusionResult(
            centroid: averageAndNormalize(survivors),
            survivorCount: survivors.count,
            trimmedCount: embeddings.count - survivors.count,
            meanPairwiseCosine: coherence)
    }

    /// The window with the highest total similarity to all the others: an observed window, so fewer than half bad
    /// windows cannot drag it.
    static func medoidIndex(_ embeddings: [[Float]]) -> Int {
        guard embeddings.count > 1 else { return 0 }
        var best = 0
        var bestSum = -Float.infinity
        for i in embeddings.indices {
            var sum: Float = 0
            for j in embeddings.indices where j != i { sum += cosine(embeddings[i], embeddings[j]) }
            if sum > bestSum { bestSum = sum; best = i }
        }
        return best
    }

    static func meanPairwiseCosine(_ embeddings: [[Float]]) -> Float {
        guard embeddings.count >= 2 else { return 1 }
        var sum: Float = 0
        var n = 0
        for i in embeddings.indices {
            for j in (i + 1)..<embeddings.count {
                sum += cosine(embeddings[i], embeddings[j])
                n += 1
            }
        }
        return n == 0 ? 1 : sum / Float(n)
    }

    /// Raw cosine in `[-1, 1]`; 0 for vectors of different length or without energy.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        let denom = na.squareRoot() * nb.squareRoot()
        guard denom > 0 else { return 0 }
        return Float(min(max(dot / denom, -1), 1))
    }

    /// Equal-weight mean, then L2 normalised: the convention of the template of the manual enrolment too.
    static func averageAndNormalize(_ embeddings: [[Float]]) -> [Float] {
        guard let dim = embeddings.first?.count else { return [] }
        var sum = [Float](repeating: 0, count: dim)
        for e in embeddings { for i in 0..<dim { sum[i] += e[i] } }
        let mean = sum.map { $0 / Float(embeddings.count) }
        let norm = mean.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return norm > 1e-9 ? mean.map { $0 / norm } : mean
    }

    // MARK: - Retention

    /// The windows to keep: those of the last `progressMaxAgeMs` before `now`, at most `maxRetainedWindows`.
    static func retained(_ windows: [Window], now: Int64) -> [Window] {
        var kept = windows.filter { now - $0.capturedAtEpochMs <= progressMaxAgeMs }
        while kept.count > maxRetainedWindows {
            var perDay: [Int64: Int] = [:]
            for w in kept { perDay[w.capturedAtEpochMs / msPerDay, default: 0] += 1 }
            guard let busiest = perDay.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key })?.key,
                  let index = kept.indices.filter({ kept[$0].capturedAtEpochMs / msPerDay == busiest })
                    .min(by: { kept[$0].capturedAtEpochMs < kept[$1].capturedAtEpochMs }) else { break }
            kept.remove(at: index)
        }
        return kept
    }
}
