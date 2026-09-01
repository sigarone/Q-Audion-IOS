import Foundation

/// AS-Norm (adaptive symmetric score normalization) back-end for
/// `SpeakerVerifier`'s raw cosine score, against a fixed cohort of impostor
/// speaker prototypes bundled as a resource.
///
/// 2026-09-02 iOS port of Android's `deepfake/SpeakerCohortNormalizer.kt` —
/// see that file's kdoc for the full research/decision trail. Summary:
///
/// ## Why this exists
///
/// A population-scale offline measurement (LibriSpeech dev-clean speakers,
/// this app's real CAM++/fbank pipeline, 1560 ordered pairs) found that
/// raw-cosine speaker separation is highly pair-dependent: median 2.55
/// standard deviations, but the worst-decile pairs separated as poorly as
/// 0.16-0.56 sigma — smaller than the noise a single speaker's own voice
/// produces call-to-call. That is the textbook signature of embedding-space
/// "hubness" (Radovanović et al.; Schlüter 2013 names the speaker-recognition
/// case directly), not a threshold-tuning problem: `SpeakerChangeDetector`
/// already estimates its baseline online, per call, and the gap survives
/// that. The published fix for hubness in similarity spaces is exactly this
/// — re-score a trial relative to how the SAME two vectors score against a
/// broad, unrelated population, which cancels each vector's own "how
/// generically similar do I look to everyone" bias before comparing them to
/// each other.
///
/// Re-measuring with an 80-speaker disjoint cohort (never overlapping the
/// measured trial speakers) turned that same worst decile from 0.16-0.56
/// sigma into 0.60-1.07 sigma, and cut the population's under-1-sigma pair
/// fraction from 3.9% to 0.7% — a real, measured effect, not a projection.
/// The shipped cohort here (`speaker_cohort_v1.bin`, same bytes as Android's
/// `assets/models/speaker_cohort_v1.bin`) is 80 prototypes.
///
/// ## What this does NOT touch
///
/// `SpeakerVerifier.computeVerificationScore()`'s raw V-score — the input to
/// `ContactVoiceContinuityGate`'s absolute VERIFIED/MISMATCH thresholds — is
/// untouched. That gate's own thresholds were fitted to a single call with
/// no impostor trial ever measured against them; folding an unrelated scale
/// change (AS-Norm output is an unbounded z-score-like quantity, not a
/// `[0,1]` similarity) into that path would trade one unmeasured threshold
/// for another. This class exists to feed `SpeakerChangeDetector`
/// specifically — a RELATIVE detector that already estimates its own scale
/// online per call, so handing it a better-separated score stream in
/// different units costs nothing to recalibrate and only improves the
/// separation it has to detect.
///
/// ## Cost
///
/// The cohort is 80 prototypes x 512 floats = 163840 bytes, loaded once at
/// construction and kept resident. Scoring one embedding against it is 80
/// dot products of 512 floats — microseconds, dwarfed by the ONNX inference
/// that already runs on the same tick. No new inference pass.
public final class SpeakerCohortNormalizer: @unchecked Sendable {

    /// Process-wide shared instance — same "load an expensive resident asset
    /// once, never duplicate it" convention as `CamPlusSpeakerEmbedder.shared`
    /// / `DeepfakeClassifier.shared` in this same directory.
    /// `ContactVoiceVerifier` (the sole consumer, mirroring Android's
    /// `VoicePrintBridgeImpl`) injects THIS instance by default rather than
    /// constructing its own.
    public static let shared = SpeakerCohortNormalizer()

    private static let cohortAssetName = "speaker_cohort_v1"
    private static let cohortAssetExtension = "bin"
    private static let embeddingDim = 512
    private static let stdFloor: Float = 1e-4

    /// `[n][512]`, each row as stored in the asset (already L2-normalized
    /// upstream, same as every embedding this normalizer is ever handed).
    /// Empty if the asset failed to load.
    private let cohort: [[Float]]

    /// `true` once a non-empty cohort was loaded. Every public method below
    /// already degrades to `nil` on its own when this is `false`, so callers
    /// are never required to check it first.
    public var isLoaded: Bool { !cohort.isEmpty }

    /// - Parameter assetName: overridable for tests; production callers use
    ///   the default, which resolves `speaker_cohort_v1.bin` via
    ///   `Bundle.module` — the same lookup mechanism
    ///   `CamPlusSpeakerEmbedder.loadModel` uses for its ONNX asset.
    public init(assetName: String = SpeakerCohortNormalizer.cohortAssetName) {
        self.cohort = Self.tryLoad(assetName: assetName)
        if cohort.isEmpty {
            print("[SpeakerCohortNormalizer] cohort unavailable (asset=\(assetName)) — AS-Norm scoring disabled")
        } else {
            print("[SpeakerCohortNormalizer] loaded \(cohort.count) cohort prototypes from \(assetName)")
        }
    }

    /// Mean and (floored) standard deviation of `embedding`'s cosine
    /// similarity against every cohort prototype — the "how generically
    /// similar does this vector look to an unrelated population" term
    /// AS-Norm subtracts out. `embedding` must already be L2-normalized
    /// (both `CamPlusSpeakerEmbedder.embed` outputs and stored templates
    /// are).
    ///
    /// `nil` when the cohort failed to load — callers must fall back to the
    /// raw, unnormalized score rather than dividing by a phantom cohort.
    public func cohortStats(_ embedding: [Float]) -> (mean: Float, std: Float)? {
        guard !cohort.isEmpty else { return nil }
        var sum: Double = 0
        var sumSq: Double = 0
        for proto in cohort {
            var dot: Float = 0
            let n = min(embedding.count, proto.count)
            for i in 0..<n { dot += embedding[i] * proto[i] }
            sum += Double(dot)
            sumSq += Double(dot) * Double(dot)
        }
        let n = Double(cohort.count)
        let mean = Float(sum / n)
        let variance = (sumSq / n) - Double(mean) * Double(mean)
        let std = Float(max(variance, 0).squareRoot())
        return (mean, max(std, Self.stdFloor))
    }

    /// Symmetric AS-Norm score for a trial with raw cosine `rawScore`
    /// between a test embedding and an enroll template, given each side's
    /// own `cohortStats`. `nil` propagates from either side — a caller with
    /// only one side's stats available (e.g. cohort load failed after the
    /// enroll side was already cached) has no normalized score to give.
    public func asNormScore(
        rawScore: Float,
        testStats: (mean: Float, std: Float)?,
        enrollStats: (mean: Float, std: Float)?
    ) -> Float? {
        guard let testStats, let enrollStats else { return nil }
        let zTest = (rawScore - testStats.mean) / testStats.std
        let zEnroll = (rawScore - enrollStats.mean) / enrollStats.std
        return (zTest + zEnroll) / 2
    }

    // MARK: - Internals

    private static func tryLoad(assetName: String) -> [[Float]] {
        guard let url = Bundle.module.url(forResource: assetName, withExtension: cohortAssetExtension) else {
            return []
        }
        guard let data = try? Data(contentsOf: url) else { return [] }
        let rowBytes = embeddingDim * MemoryLayout<Float>.size
        guard !data.isEmpty, data.count % rowBytes == 0 else { return [] }
        let n = data.count / rowBytes
        var rows = [[Float]](repeating: [Float](repeating: 0, count: embeddingDim), count: n)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let floats = raw.bindMemory(to: Float.self)
            for r in 0..<n {
                for i in 0..<embeddingDim {
                    rows[r][i] = floats[r * embeddingDim + i]
                }
            }
        }
        return rows
    }
}
