import Foundation

public final class SpeakerVerifier {
    public enum State { case idle; case enrolling; case ready; case verifying }

    private let lfccExtractor = LfccExtractor()
    private var state: State = .idle
    private var enrollmentFrames: [[Float]] = []
    private var storedTemplate: [Float]?
    private let embeddingDimension = 128
    private let enrollmentMinFrames = 150  // ~3 seconds

    public init() {}

    public func startEnrollment() { state = .enrolling; enrollmentFrames.removeAll() }

    public func processEnrollmentFrame(_ pcmFrame: Data) {
        guard state == .enrolling else { return }
        let features = lfccExtractor.extract(pcmData: pcmFrame)
        if !features.isEmpty { enrollmentFrames.append(features) }
    }

    public func finishEnrollment() -> Bool {
        guard state == .enrolling, enrollmentFrames.count >= enrollmentMinFrames else { return false }
        storedTemplate = computeEmbedding(from: enrollmentFrames)
        state = .ready
        return true
    }

    public func verify(pcmFrame: Data) -> Float {
        guard state == .ready, let template = storedTemplate else { return 0 }
        let features = lfccExtractor.extract(pcmData: pcmFrame)
        guard !features.isEmpty else { return 0 }
        let embedding = computeEmbedding(from: [features])
        return cosineSimilarity(template, embedding)
    }

    public func getState() -> State { state }

    private func computeEmbedding(from features: [[Float]]) -> [Float] {
        guard !features.isEmpty else { return [Float](repeating: 0, count: embeddingDimension) }
        let dim = min(features[0].count, embeddingDimension)
        var mean = [Float](repeating: 0, count: dim)
        for f in features { for i in 0..<dim { mean[i] += f[i] } }
        let n = Float(features.count)
        for i in 0..<dim { mean[i] /= n }
        // L2 normalize
        let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { for i in 0..<dim { mean[i] /= norm } }
        // Pad to embeddingDimension
        if mean.count < embeddingDimension { mean.append(contentsOf: [Float](repeating: 0, count: embeddingDimension - mean.count)) }
        return mean
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        let dim = min(a.count, b.count)
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<dim { dot += a[i] * b[i]; normA += a[i] * a[i]; normB += b[i] * b[i] }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }
}
