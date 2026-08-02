import Foundation

/// "Voce come chiave" — Tier 1's TX-side continuous owner-continuity
/// self-check. 2026-08-01 port of Android's
/// `analysis/OwnerContinuityMonitor.kt`.
///
/// That answers "does the person SPEAKING INTO MY MICROPHONE right now
/// still match my own enrolled voice" — the RX-side signal
/// (`ContactVoiceContinuityGate`) and SAS/PQC crypto cannot catch this
/// threat class: the phone physically stolen or handed to someone else
/// mid-call, or a coerced/duress speaker substitution. SAS/PQC prove key
/// possession, not who is currently holding the device.
///
/// Fed EXCLUSIVELY from the TX/local-mic capture path (pre-encode, raw
/// captured PCM) — never RX/remote audio. `feed` enqueues onto this
/// monitor's own dedicated serial queue and returns immediately, mirroring
/// Android's non-blocking `Channel.trySend` contract: a slow CAM++
/// embedding pass can never stall the real-time audio capture thread that
/// calls it (this codebase's 2026-07-04 never-block rules — the same
/// discipline `CallService.txAudioQueue`/`GuardianMode` already follow).
///
/// Deliberately silent (state stays `.inactive`) whenever the injected
/// `SpeakerVerifier` is not `.ready` (no enrolled Voice-as-Key template) —
/// this must never nag or penalize a user who has not opted in.
///
/// Score scale — W-VSCORESCALE (2026-08-02). `verifier.verify(pcmFrame:)`
/// returns a RAW COSINE in `[-1, 1]`, and this class converts it to
/// `V_score = (cosine + 1) / 2` BEFORE thresholding, because
/// `verifiedThreshold`/`uncertainThreshold` are V_score-scale values.
///
/// The previous version of this doc asserted the opposite — that the
/// thresholds were calibrated against raw cosine and that a V-score must
/// NOT be fed here — and the code thresholded the raw cosine directly. That
/// was wrong in a way that disabled the whole signal. Those two constants
/// were carried over from Android's `OwnerContinuityMonitor`, which had in
/// turn carried them from `ContactVoiceContinuityGate`, and that gate is fed
/// `SpeakerVerifier.computeVerificationScore` — a V_score. The number
/// travelled across three classes and two platforms while its scale was
/// silently dropped on the way.
///
/// Consequence, measured on Android before the identical fix there: 0.62 on
/// raw cosine is V_score 0.81, a bar genuine speech never clears. The owner's
/// own voice scored raw cosine 0.056–0.539 (mean 0.336) across a real call —
/// as V_score, mean 0.668, comfortably over the 0.62 bar. Zero of 14 windows
/// passed on the wrong scale; 11 of 14 passed on the right one. On iOS this
/// surfaced as the peer's microphone shield sitting permanently on
/// `.uncertain` (purple) no matter how long the owner spoke.
public final class OwnerContinuityMonitor: @unchecked Sendable {
    public enum Level: String { case verified, uncertain, mismatch }
    public enum State: Equatable {
        case inactive
        case scored(score: Float, level: Level)
    }

    /// Cosine-similarity cutoffs — same family as
    /// `VoicePrintVault.THRESHOLD_CONSUMER`/`THRESHOLD_ENTERPRISE` on
    /// Android, kept independent so tuning one never silently retunes the
    /// other. `verifiedThreshold` carried over from Android's 2026-08-01
    /// real-device finding (confirmed on-device: 0.70 on the raw score
    /// almost never held for the genuine owner's own voice; 0.62 matched
    /// what a real trace showed). `uncertainThreshold` is unchanged /
    /// still provisional — no real cross-speaker (impersonation) CAM++
    /// data exists yet to justify moving the mismatch floor. Neither has
    /// been independently re-validated against a real iOS device call.
    private static let verifiedThreshold: Float = 0.62
    private static let uncertainThreshold: Float = 0.50

    /// EMA smoothing factor — 2026-08-01 fix carried from Android: the raw
    /// per-tick CAM++ score is too noisy to threshold directly (confirmed
    /// on-device — reacting to every tick made the badge flicker to
    /// `.mismatch` on ordinary noise dips even during genuine, continuous
    /// owner speech). Same value as `ContactVoiceContinuityGate.emaAlpha`.
    private static let emaAlpha: Float = 0.35

    /// 3 consecutive ~3s Mismatch windows (~9s sustained) before alerting —
    /// long enough that a brief mic hand-off/background noise burst can't
    /// false-positive. Matches Android's `MISMATCH_STREAK_FOR_ALERT`.
    private static let mismatchStreakForAlert = 3

    /// ~3s of native-rate audio buffered before each score — matches
    /// Android's `TARGET_SAMPLES_16K` (48_000 samples @ 16kHz = 3s) in
    /// WALL-CLOCK terms. Unlike Android (which pre-decimates to 16kHz
    /// itself before calling `VoicePrintVault.verify`), iOS's
    /// `SpeakerVerifier.verify(pcmFrame:)` already resamples 48kHz->16kHz
    /// internally (see its `computeEmbedding`) — buffering RAW native PCM
    /// here and letting `verify` resample once avoids a redundant
    /// double-resample.
    private static let targetWindowSeconds: Double = 3.0

    private let verifier: SpeakerVerifier
    /// Own dedicated serial queue — mirrors `CallService.txAudioQueue`'s
    /// "own queue, never the shared/main one" discipline, and Android's own
    /// dedicated single-thread dispatcher (`Dispatchers.IO
    /// .limitedParallelism(1)`, see `CallModule.kt`'s `ownerContinuity()`
    /// provider kdoc).
    private let queue = DispatchQueue(label: "com.bcrypto.qaudion.ownerContinuity", qos: .utility)
    private let lock = NSLock()

    // MARK: - Queue-confined state (only ever touched from `queue`, no lock needed)
    private var buffer = Data()
    private var targetBytes = 0
    private var ema: Float?
    private var enrolledCached = false

    // MARK: - Lock-guarded state (read from `shouldAlert()`/`currentState()`
    // on an arbitrary caller thread, written from `queue` inside `setState`)
    private var _mismatchStreak = 0
    private var _state: State = .inactive

    /// Fires on `queue` (NOT the caller's thread) whenever `state` changes —
    /// a deliberate difference from `GuardianMode`/`VoiceLearningSession`'s
    /// callbacks (which fire synchronously on the audio thread): this
    /// monitor's scoring is expensive and must never run on a shared
    /// real-time thread, so its callback necessarily fires from its own
    /// queue instead. Consumers must hop to their own thread (e.g. main)
    /// themselves before touching UI state, same as every other
    /// cross-thread callback in this codebase.
    public var onStateChanged: ((State) -> Void)?

    public init(verifier: SpeakerVerifier) {
        self.verifier = verifier
    }

    /// (Re)starts the monitor. `nativeSampleRateHz` is the TX capture
    /// pipeline's sample rate (48kHz for this app's call pipeline).
    /// Caches `verifier.getState() == .ready` ONCE here — mirrors Android's
    /// W-OWNERCONTINUITY-PERF fix: `SpeakerVerifier` state cannot change
    /// mid-call (a separate UI-driven flow), so re-checking it on every fed
    /// chunk would be pure waste, not correctness.
    public func start(nativeSampleRateHz: Int = 48_000) {
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.removeAll(keepingCapacity: true)
            self.targetBytes = Int(Double(nativeSampleRateHz) * Self.targetWindowSeconds) * MemoryLayout<Int16>.size
            self.ema = nil
            self.enrolledCached = self.verifier.getState() == .ready
            self.lock.lock(); self._mismatchStreak = 0; self.lock.unlock()
            self.setState(.inactive)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.buffer.removeAll(keepingCapacity: true)
        }
    }

    /// Feed a chunk of RAW TX PCM (Int16, mono, little-endian, captured
    /// PRE-encode from the LOCAL microphone — never RX/remote audio). Safe
    /// to call every capture frame; enqueues onto `queue` and returns
    /// immediately (never blocks the caller — see class doc's never-block
    /// note). Internally buffered and only scored once ~3s of audio has
    /// accumulated.
    public func feed(pcmFrame: Data) {
        guard !pcmFrame.isEmpty else { return }
        queue.async { [weak self] in self?.process(pcmFrame) }
    }

    public func currentState() -> State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// True after `mismatchStreakForAlert` consecutive low-scoring windows
    /// — the actual alert trigger, hysteresis-gated like Guardian's own
    /// alerts.
    public func shouldAlert() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _mismatchStreak >= Self.mismatchStreakForAlert
    }

    // MARK: - Internals (queue-confined — only ever called from `queue`)

    private func process(_ pcmFrame: Data) {
        guard enrolledCached else {
            setState(.inactive)
            return
        }
        buffer.append(pcmFrame)
        guard targetBytes > 0, buffer.count >= targetBytes else { return }
        let chunk = buffer
        buffer.removeAll(keepingCapacity: true)

        // W-VSCORESCALE — convert to the scale the thresholds actually live
        // on before comparing. `verify` returns a raw cosine; the constants
        // are V_score values inherited (via Android) from
        // ContactVoiceContinuityGate, which is fed
        // SpeakerVerifier.computeVerificationScore. Thresholding the cosine
        // directly made the effective bar V_score 0.81 and pinned the signal
        // at .uncertain/.mismatch forever. See the class doc for the measured
        // numbers. The conversion is affine and monotonic, so it changes no
        // ordering — only that the value and the bar are finally in the same
        // units. Smooth AFTER converting so `ema` is a V_score too.
        let cosine = verifier.verify(pcmFrame: chunk)
        let vScore = min(max((cosine + 1) / 2, 0), 1)
        let smoothed = ema.map { Self.emaAlpha * vScore + (1 - Self.emaAlpha) * $0 } ?? vScore
        ema = smoothed

        let level: Level
        if smoothed >= Self.verifiedThreshold {
            level = .verified
        } else if smoothed >= Self.uncertainThreshold {
            level = .uncertain
        } else {
            level = .mismatch
        }
        // Log BOTH numbers, same shape as SpeakerVerifier's own line and
        // Android's — so no future trace can be read on the wrong scale
        // again, which is the mistake that produced this bug and then a
        // wrong diagnosis of it.
        //
        // `print` and not RTLog: RTLog lives in the app target
        // (RuntimeLogSink.swift) and this file is in the QAudionEngine
        // package, which cannot import it. print() rides the stdout tee,
        // whose "stdout" tag is in ship-ios-logs.py's allow-list, so this
        // actually reaches Loki — RTLog.debug would not have (DEBUG is
        // dropped before shipping).
        //
        // Field widths obey the 12-character rule (see CallService's note):
        // every `key=value` token must stay under 12 chars or the shipper's
        // RE_BASE64_BLOB eats it. Hence the 3-letter level codes rather than
        // `level.rawValue` — `lv=uncertain` is exactly 12 and would vanish,
        // while `lv=verified`/`lv=mismatch` would survive, i.e. the log would
        // have silently dropped precisely the state we are debugging.
        // Verified against the shipper's real redact_body for all three.
        let c = String(format: "%.3f", cosine)
        let v = String(format: "%.3f", vScore)
        let lv: String
        switch level {
        case .verified:  lv = "ver"
        case .uncertain: lv = "unc"
        case .mismatch:  lv = "mis"
        }
        print("[OwnerCont] cos=" + c + " v=" + v + " lv=" + lv)
        lock.lock()
        _mismatchStreak = (level == .mismatch) ? _mismatchStreak + 1 : 0
        lock.unlock()
        setState(.scored(score: smoothed, level: level))
    }

    private func setState(_ newState: State) {
        lock.lock()
        _state = newState
        lock.unlock()
        onStateChanged?(newState)
    }
}
