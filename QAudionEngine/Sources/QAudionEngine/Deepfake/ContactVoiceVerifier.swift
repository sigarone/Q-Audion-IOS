import Foundation

/// "Voce remota" (Tier 2 / Feature B) per-contact continuous verification —
/// 2026-08-01 iOS port of Android's `bridges/EngineBridges.kt`
/// `VoicePrintBridgeImpl`. Owns ONE `SpeakerVerifier` instance (never
/// shared with Tier 1 — `OwnerContinuityMonitor`/`VoiceAuthGate` each own
/// their own, matching Android's separate `VoicePrintVault` vs
/// `deepfake.SpeakerVerifier` class split) and switches its loaded
/// template whenever the active call's peer changes.
///
/// Self-healing auto-enrollment: if no stored template exists for a
/// contact, the first ~3s of real (VAD-gated) RX speech auto-enrolls one —
/// see `SpeakerVerifier.startAutoEnrollment`/`feedVerificationFrame`. This
/// is what makes template-format versioning (e.g. an algorithm migration
/// bumping the store's magic/version header) self-healing instead of
/// silently disabling "voce remota" for every previously-enrolled contact
/// until the user manually re-runs `VoiceLearningSession`.
///
/// Owns the ~1s-throttled score-compute cadence itself (a private
/// `DispatchSourceTimer` on its own queue) — Android's equivalent cadence
/// lives in `CallController.contactVoiceScoreJob`, a coroutine loop on a
/// dedicated dispatcher; iOS has no directly equivalent shared call-scoped
/// coroutine context, so this class is deliberately self-contained instead
/// (mirrors `OwnerContinuityMonitor`'s own self-paced design), giving the
/// app layer exactly two calls to make: `setActiveContact` once the peer
/// is known, `feedContinuous` on every RX frame (cheap, always safe to
/// call unconditionally — a no-op internally whenever no contact is
/// active, see `SpeakerVerifier.feedVerificationFrame`'s `.idle` branch).
public final class ContactVoiceVerifier: @unchecked Sendable {
    private static let scoreIntervalSeconds: Double = 1.0

    private let verifier: SpeakerVerifier
    private let store: VoiceprintStore
    private let gate = ContactVoiceContinuityGate()

    private let scoreQueue = DispatchQueue(label: "com.bcrypto.qaudion.contactVoiceScore", qos: .utility)
    private let lock = NSLock()
    private var loadedContactId: String?
    private var scoreTimer: DispatchSourceTimer?

    /// Fires on `scoreQueue` (not the caller's thread — same cross-thread
    /// callback contract as `OwnerContinuityMonitor.onStateChanged`; hop to
    /// your own thread before touching UI state) whenever the gate's level
    /// changes as a result of a new score tick.
    public var onLevelChanged: ((ContactVoiceContinuityGate.Level) -> Void)?

    public init(embedder: CamPlusSpeakerEmbedder = .shared, store: VoiceprintStore = VoiceprintStore()) {
        self.verifier = SpeakerVerifier(embedder: embedder)
        self.store = store
    }

    /// Switch the active contact (`nil` when the call ends / no peer is
    /// bound yet). Loads the stored template if one exists; otherwise
    /// starts auto-enrollment from live RX audio via `feedContinuous`. A
    /// no-op if `contactId` is already the active one (cheap to call
    /// redundantly, matching Android's `setActiveContact`).
    public func setActiveContact(_ contactId: String?) {
        lock.lock()
        guard contactId != loadedContactId else { lock.unlock(); return }
        loadedContactId = contactId
        stopTimerLocked()
        lock.unlock()

        gate.reset()
        guard let contactId else {
            verifier.reset()
            return
        }
        if let template = store.load(contactId: contactId) {
            verifier.importTemplate(template)
        } else {
            verifier.startAutoEnrollment(contactId: contactId)
        }

        lock.lock()
        startTimerLocked()
        lock.unlock()
    }

    /// Cheap — safe to call unconditionally on every decoded RX frame, even
    /// with no active contact (internally a no-op via `SpeakerVerifier`'s
    /// own state gate). Never triggers the expensive embedding recompute;
    /// pairs with the internal timer's own separately-throttled cadence.
    public func feedContinuous(_ pcmFrame: Data) {
        verifier.feedVerificationFrame(pcmFrame)
    }

    /// Current hysteresis level for the "voce remota" shield.
    public var level: ContactVoiceContinuityGate.Level { gate.level }

    /// Call when the call ends — equivalent to `setActiveContact(nil)`,
    /// named separately for readability at call-teardown sites.
    public func deactivate() {
        setActiveContact(nil)
    }

    // MARK: - Internals (MUST be called with `lock` held)

    private func startTimerLocked() {
        guard loadedContactId != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: scoreQueue)
        timer.schedule(deadline: .now() + Self.scoreIntervalSeconds, repeating: Self.scoreIntervalSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let score = self.verifier.computeVerificationScore()
            self.gate.feed(score)
            self.onLevelChanged?(self.gate.level)
        }
        timer.resume()
        scoreTimer = timer
    }

    private func stopTimerLocked() {
        scoreTimer?.cancel()
        scoreTimer = nil
    }
}
