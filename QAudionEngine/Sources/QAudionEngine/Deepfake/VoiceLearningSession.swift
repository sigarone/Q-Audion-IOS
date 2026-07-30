import Foundation

/// Per-contact, call-time voice-learning session — Feature B ("voce
/// verificata"). Wraps `SpeakerVerifier` (LFCC-mean-embedding speaker
/// matcher) + `VoiceprintStore` (Keychain-backed persistence) to build a
/// per-contact voiceprint template from the REMOTE peer's decoded RX audio
/// during a live call.
///
/// Mirrors the Android `VoiceLearningSession` design 1:1 for cross-platform
/// consistency: a manual "Avvia apprendimento voce" trigger in the live
/// in-call UI starts a session for the CURRENT call's peer; frames are fed
/// from the exact same tap point already used by the Guardian anti-spoof
/// pipeline (`QAudionCallIntegration.processIncomingAudio` → decoded RX
/// PCM) — no new audio capture path.
///
/// NEVER feed this local mic / TX audio — that is Feature A's
/// (`VoiceEnrollmentContainer` → `VoiceAuthGate`) job, a deliberately
/// different tap point for a deliberately different person's voice. Feeding
/// the wrong audio into the wrong session would silently learn/verify the
/// wrong speaker.
public final class VoiceLearningSession {
    public enum State: Equatable {
        case idle
        case inProgress(progress: Float)
        case completed(contactId: String)
        case failed
    }

    public private(set) var state: State = .idle

    private let verifier: SpeakerVerifier
    private let store: VoiceprintStore
    private var contactId: String?

    /// Frames required before `finishEnrollment()` can succeed — mirrors
    /// `SpeakerVerifier.enrollmentMinFrames` (150, ~3 s at 20 ms/frame) so
    /// the reported progress fraction reaches 1.0 exactly when enrollment
    /// becomes possible.
    private let requiredFrames = 150
    private var frameCount = 0

    public init(verifier: SpeakerVerifier = SpeakerVerifier(), store: VoiceprintStore = VoiceprintStore()) {
        self.verifier = verifier
        self.store = store
    }

    /// Begin learning `contactId`'s voice from this point forward. Resets
    /// any previous in-flight session (this instance is meant to be
    /// reconstructed per call/attempt, but `start` is idempotent-safe too).
    public func start(contactId: String) {
        self.contactId = contactId
        frameCount = 0
        verifier.startEnrollment()
        state = .inProgress(progress: 0)
    }

    /// Feed one decoded RX PCM frame — the REMOTE peer's decoded call audio
    /// (see type doc). No-op unless a session is currently `.inProgress`.
    public func processRxFrame(_ pcmFrame: Data) {
        guard case .inProgress = state, let contactId else { return }
        verifier.processEnrollmentFrame(pcmFrame)
        frameCount += 1
        let progress = min(1.0, Float(frameCount) / Float(requiredFrames))
        state = .inProgress(progress: progress)
        guard frameCount >= requiredFrames else { return }
        finish(contactId: contactId)
    }

    /// Cancel an in-flight session without persisting anything.
    public func cancel() {
        state = .idle
        contactId = nil
        frameCount = 0
    }

    private func finish(contactId: String) {
        guard verifier.finishEnrollment(), let template = verifier.exportTemplate() else {
            state = .failed
            return
        }
        store.save(contactId: contactId, template: template)
        state = .completed(contactId: contactId)
    }
}
