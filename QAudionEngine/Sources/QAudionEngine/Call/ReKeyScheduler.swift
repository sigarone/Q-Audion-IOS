import Foundation

/// MASVS-CRYPTO remediation (2026-08-20/21) — Swift port of Android's
/// `feature/feature-call/domain/ReKeyScheduler.kt`.
///
/// **UPDATE (2026-09-10) — the paragraph below is STALE, kept only as a
/// dated record of the 2026-08-21 state; do not trust it for current
/// behavior.** The FSM surgery it says was never attempted DID land (I3 §5,
/// see `docs/security/I3_IOS_REKEY_DESIGN_2026-08-21.md`, cross-repo doc in
/// `qaudion-android-new`): `AppState`'s `onReKeyTick` wiring drives a real
/// mid-call PQC re-handshake via `QAudionCallIntegration.performPqcReKey`,
/// and `QAudionCallIntegration`'s inbound-OFFER handler re-keys an
/// already-`.active` session in place (`engine.initSession` again, skipping
/// `engine.initialize()`) rather than throwing `invalidState`. Ticks are
/// NOT merely logged — see `AppState.swift`'s `reKeyScheduler.onReKeyTick`
/// closure for the actual call. This class itself does no I/O and touches
/// no crypto material directly, only ever publishes `ReKeyTick` events for
/// a caller to act on.
///
/// Original 2026-08-21 note, for history: "AppState currently logs every
/// tick it receives instead of acting on it — a genuine new `.reKeying`
/// state in `QAudionCallIntegration`'s FSM, or a parallel lightweight
/// re-key primitive, needs a scoped follow-up." That follow-up is done.
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
    /// W-REKEYFREEZE (2026-09-10) — the period [deadlineMs] was last (re)armed
    /// with. Port of Android's `ReKeyScheduler.armedPeriodMs` (same file/class
    /// name, `feature/feature-call/domain/ReKeyScheduler.kt`): live evidence
    /// there was a real, otherwise-healthy call whose on-screen RE-KEY
    /// countdown froze at the same value the whole call, because
    /// `observeConfidence` compared each sample's freshly-computed period
    /// against `remaining` (the countdown itself, shrinking every tick by
    /// construction) — routine confidence-score jitter made `newPeriod`
    /// fractionally lower than whatever was left almost every sample, so the
    /// deadline reset to a fresh full period essentially every tick and the
    /// countdown could never visibly drain. Comparing against the period the
    /// deadline was actually armed with (this field), not the live
    /// countdown, means only a genuine drop below that basis contracts it.
    private var armedPeriodMs: Int64
    private var reKeyCount: Int = 0
    private var lastTriggerReason: String?

    public init() {
        let initialPeriod = Self.basePeriodMs
        deadlineMs = Self.nowMs() + initialPeriod
        armedPeriodMs = initialPeriod
    }

    /// - Parameters:
    ///   - syncedDeadlineMs / syncedPeriodMs: W-REKEYSYNC (2026-09-10) — when
    ///     BOTH are given (this device adopting the peer's real advertised
    ///     next-rekey period off the wire, see `AndroidHandshakeBundle
    ///     .rekeyNextPeriodMs`'s doc), the countdown is armed directly from
    ///     them instead of this device's own confidence guess. Mirrors
    ///     Android's `ReKeyScheduler.start(syncedDeadlineMs:syncedPeriodMs:)`.
    ///     Either omitted (the call's first handshake, or a peer that hasn't
    ///     sent the field) falls back to the original confidence-based
    ///     `resetDeadlineLocked`, unchanged.
    public func start(syncedDeadlineMs: Int64? = nil, syncedPeriodMs: Int64? = nil) {
        stop()
        lock.lock()
        if let syncedDeadlineMs, let syncedPeriodMs, syncedPeriodMs > 0 {
            deadlineMs = syncedDeadlineMs
            armedPeriodMs = syncedPeriodMs
            lastTriggerReason = "peer-synced"
        } else {
            resetDeadlineLocked(confidence: lastConfidence, reason: "session-start")
        }
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
            // W-REKEYFREEZE — armedPeriodMs (the stable basis), not a fresh
            // periodForLocked(lastConfidence) recompute every tick; see that
            // field's kdoc for why the latter froze the on-screen countdown.
            status = Status(
                confidence: self.lastConfidence,
                remainingMs: remaining,
                periodMs: self.armedPeriodMs,
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

    /// Current status, readable synchronously at any time — e.g. so a
    /// caller about to send a re-key OFFER can advertise the period THIS
    /// device's scheduler is actually armed with (see
    /// `AndroidHandshakeBundle.rekeyNextPeriodMs`'s doc). Mirrors Android's
    /// `reKeyScheduler.status.value` (a `StateFlow`, readable the same way).
    public var currentStatus: Status {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, deadlineMs - Self.nowMs())
        return Status(
            confidence: lastConfidence,
            remainingMs: remaining,
            periodMs: armedPeriodMs,
            reKeyCount: reKeyCount,
            lastTriggerReason: lastTriggerReason)
    }

    /// Feed the current Confidence Index (0..1). Low values shrink the
    /// deadline (faster re-key pace); see the class kdoc's formula.
    public func observeConfidence(_ c: Float) {
        let clamped = max(0, min(1, c))
        lock.lock()
        lastConfidence = clamped
        let now = Self.nowMs()
        let newPeriod = periodForLocked(clamped)
        // W-REKEYFREEZE — shrink the deadline only on a genuine drop below
        // the period it was actually armed with, not against the live
        // countdown (see `armedPeriodMs`'s kdoc for why that froze the
        // on-screen timer).
        if newPeriod < armedPeriodMs {
            deadlineMs = now + newPeriod
            armedPeriodMs = newPeriod
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
        armedPeriodMs = newPeriod
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
        armedPeriodMs = newPeriod
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
