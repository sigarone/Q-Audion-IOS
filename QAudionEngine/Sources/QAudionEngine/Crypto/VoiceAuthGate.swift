import Foundation

public final class VoiceAuthGate {
    public enum AuthResult { case passed; case failed; case pending }

    private var isActive = false
    private var challenge: String?

    public init() {}

    public func startAuthentication(challenge: String) {
        self.challenge = challenge
        isActive = true
    }

    public func verify(pcmFrame: Data) -> AuthResult {
        guard isActive else { return .pending }
        // Stub: always passes. Real implementation uses VoiceprintAnalyzer.
        return .passed
    }

    public func cancel() { isActive = false; challenge = nil }
    public var active: Bool { isActive }
}
