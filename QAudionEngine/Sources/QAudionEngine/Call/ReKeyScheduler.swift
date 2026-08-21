import Foundation

/// MASVS-CRYPTO remediation (2026-08-20/21) — Swift port of Android's
/// `feature/feature-call/domain/ReKeyScheduler.kt`.
///
/// ⚠️ **UNVERIFIED — not tested on a live call.** This session has no Mac /
/// physical iOS device available (see `docs/security/
/// MASVS_ASSESSMENT_2026-08-20.md` item I3), so nothing below has been
/// exercised against a real call. The scheduler class itself (state machine:
/// adaptive deadline, confidence-driven period, tick emission) is a faithful,
/// self-contained port of the Android original and should be safe — it does
/// no I/O and touches no crypto material directly, only ever publishes
/// `ReKeyTick` events for a caller to act on.
///
/// **What this does NOT yet do — the actual gap this port closes only
/// partially:** Android's `CallController.performReKey` (the consumer of
/// these ticks) drives a genuine mid-call ML-KEM re-handshake — a fresh
/// OFFER/ACCEPT round-trip via the signaller, an atomic dual-key-grace swap
/// of both the audio and video session keys, with separate initiator/
/// responder roles and a glare guard. On iOS, `QAudionCallIntegration`'s
/// call-state machine (`onCallSetupStarted` et al.) is a strict one-shot
/// `.idle → .capabilitySent → … → .active` lifecycle — it throws
/// `invalidState` if re-entered mid-call, so it is NOT safely re-invocable
/// as a mid-call re-handshake trigger without real FSM surgery. Building
/// that surgery blind, with no way to test it against a live call or verify
/// wire compatibility with Android/desktop/server, was judged too risky to
/// attempt in this pass (see the session's MASVS remediation notes for the
/// reasoning). AppState currently logs every tick it receives instead of
/// acting on it — see `AppState`'s wiring for the loud, explicit warning.
/// **Closing this gap for real needs a scoped follow-up**: either a genuine
/// new `.reKeying` state in `QAudionCallIntegration`'s FSM that can coexist
/// with `.active`, or a parallel lightweight re-key primitive that reuses
/// `PqcKeyExchange`/`CallSessionKeyBroker` directly without touching the
/// one-shot setup FSM — reviewed and tested on a real device before it ships.
///
/// The next re-key deadline is a function of the live Confidence Index C
/// emitted by `ContactVoiceVerifier` (via `onScoreUpdated`, relayed through
/// `QAudionCallIntegration`/`CallService`/`AppState`):
///
///   period = basePeriod * clamp(C, cMin, cMax)
///
/// With `basePeriod = 5 min`, `cMin = 0.02`, `cMax = 1.0`:
/// - `C = 1.0` (safe voice) → re-key every 5 minutes (default pace)
/// - `C = 0.5` (ambiguous)  → re-key every 2.5 minutes
/// - `C = 0.2` (suspicious) → re-key every 1 minute
///
/// The scheduler never interrupts the active call itself; it only publishes
/// re-key requests via [onReKeyTick] and lets the caller drive the actual
/// handshake.
public final class ReKeyScheduler: @unchecked Sendable {

    public struct Status: Equatable {
        public let confidence: Float
        public let remainingMs: Int64
        public let periodMs: Int64
        public let reKeyCount: Int
        public let lastTriggerReason: String?
    }

    /// One re-key impulse. The caller is expected to drive the actual
    /// PQC handshake / key swap when this fires — see the file-level
    /// UNVERIFIED note above for the current state of that wiring on iOS.
    public struct ReKeyTick {
        public let reason: String
        public let confidenceAtTrigger: Float
        public let sequence: Int
        public let atEpochMs: Int64
    }

    public static let basePeriodMs: Int64 = 5 * 60 * 1000
    public static let cMin: Float = 0.02
    public static let cMax: Float = 1.0
    /// Matches Android: the confidence-crash hard trigger is present but
    /// intentionally never armed below — see Android's own kdoc on
    /// `IMMEDIATE_TRIGGER_THRESHOLD` for why (uncalibrated deepfake model
    /// producing false positives that tore calls down). Kept here for
    /// parity/documentation, not wired to an active trigger path.
    public static let immediateTriggerThreshold: Float = 0.5
    private static let tickIntervalSeconds: Double = 0.25

    /// Fires on a private background queue — hop to your own thread/actor
    /// before touching UI or `@MainActor` state, same cross-thread contract
    /// as `ContactVoiceVerifier.onLevelChanged`.
    public var onStatusChanged: ((Status) -> Void)?
    /// See the UNVERIFIED note above — currently only ever logged, not
    /// acted on, by every wired consumer in this app.
    public var onReKeyTick: ((ReKeyTick) -> Void)?

    private let lock = NSLock()
    private let tickQueue = DispatchQueue(label: "com.bcrypto.qaudion.reKeyScheduler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastConfidence: Float = 1.0
    private var deadlineMs: Int64
    private var reKeyCount: Int = 0
    private var lastTriggerReason: String?

    public init() {
        deadlineMs = Self.nowMs() + Self.basePeriodMs
    }

    public func start() {
        stop()
        lock.lock()
        resetDeadlineLocked(confidence: lastConfidence, reason: "session-start")
        lock.unlock()

        let t = DispatchSource.makeTimerSource(queue: tickQueue)
        t.schedule(deadline: .now() + Self.tickIntervalSeconds, repeating: Self.tickIntervalSeconds)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Self.nowMs()
            var shouldTrigger = false
            var status: Status?
            self.lock.lock()
            let remaining = max(0, self.deadlineMs - now)
            status = Status(
                confidence: self.lastConfidence,
                remainingMs: remaining,
                periodMs: self.periodForLocked(self.lastConfidence),
                reKeyCount: self.reKeyCount,
                lastTriggerReason: self.lastTriggerReason)
            if remaining == 0 { shouldTrigger = true }
            self.lock.unlock()
            if let status { self.onStatusChanged?(status) }
            if shouldTrigger { self.trigger(reason: "period-elapsed") }
        }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Feed the current Confidence Index (0..1). Low values shrink the
    /// deadline (faster re-key pace); see the class kdoc's formula.
    public func observeConfidence(_ c: Float) {
        let clamped = max(0, min(1, c))
        lock.lock()
        lastConfidence = clamped
        let now = Self.nowMs()
        let newPeriod = periodForLocked(clamped)
        let remaining = deadlineMs - now
        if newPeriod < remaining {
            deadlineMs = now + newPeriod
        }
        lock.unlock()
    }

    public func forceReKey(reason: String) {
        trigger(reason: reason)
    }

    public func release() {
        stop()
    }

    private func trigger(reason: String) {
        let now = Self.nowMs()
        lock.lock()
        let newPeriod = periodForLocked(lastConfidence)
        deadlineMs = now + newPeriod
        reKeyCount += 1
        lastTriggerReason = reason
        let sequence = reKeyCount
        let confidenceAtTrigger = lastConfidence
        lock.unlock()

        onReKeyTick?(ReKeyTick(
            reason: reason,
            confidenceAtTrigger: confidenceAtTrigger,
            sequence: sequence,
            atEpochMs: now))
    }

    /// MUST be called with `lock` held.
    private func resetDeadlineLocked(confidence: Float, reason: String) {
        let newPeriod = periodForLocked(confidence)
        deadlineMs = Self.nowMs() + newPeriod
        lastTriggerReason = reason
    }

    /// MUST be called with `lock` held.
    private func periodForLocked(_ c: Float) -> Int64 {
        let clamped = max(Self.cMin, min(Self.cMax, c))
        return Int64(Float(Self.basePeriodMs) * clamped)
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
