import Foundation

/// Voice-based authentication gate using speaker verification.
/// Accumulates PCM frames during authentication, compares against
/// enrolled voiceprint, and produces pass/fail verdict.
public final class VoiceAuthGate {
    public enum AuthResult { case passed; case failed; case pending }

    /// Minimum cosine similarity score to pass verification (0.0-1.0).
    public static let defaultThreshold: Float = 0.65
    /// Number of frames to accumulate before making a decision (~3 seconds).
    public static let requiredFrames = 150

    private var isActive = false
    private var challenge: String?
    private let verifier: SpeakerVerifier
    private let threshold: Float
    private var frameCount = 0
    private var cumulativeScore: Float = 0

    public init(verifier: SpeakerVerifier = SpeakerVerifier(embedder: CamPlusSpeakerEmbedder.shared), threshold: Float = VoiceAuthGate.defaultThreshold) {
        self.verifier = verifier
        self.threshold = threshold
    }

    /// Begin authentication with a challenge phrase.
    public func startAuthentication(challenge: String) {
        self.challenge = challenge
        isActive = true
        frameCount = 0
        cumulativeScore = 0
    }

    /// Process a PCM audio frame during authentication.
    /// Returns `.pending` until enough frames are collected, then `.passed` or `.failed`.
    public func verify(pcmFrame: Data) -> AuthResult {
        guard isActive else { return .pending }
        guard verifier.getState() == .ready else {
            // No enrolled voiceprint — cannot verify, pass through
            return .passed
        }

        let score = verifier.verify(pcmFrame: pcmFrame)
        frameCount += 1
        cumulativeScore += score

        guard frameCount >= Self.requiredFrames else { return .pending }

        let averageScore = cumulativeScore / Float(frameCount)
        let result: AuthResult = averageScore >= threshold ? .passed : .failed

        // Reset after decision
        isActive = false
        challenge = nil
        return result
    }

    public func cancel() {
        isActive = false
        challenge = nil
        frameCount = 0
        cumulativeScore = 0
    }

    public var active: Bool { isActive }
    public var progress: Float { Float(frameCount) / Float(Self.requiredFrames) }
    public var currentChallenge: String? { challenge }
}
