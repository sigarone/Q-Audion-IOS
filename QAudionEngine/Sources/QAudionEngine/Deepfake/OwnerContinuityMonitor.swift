import Foundation

/// "Voce come chiave" — Tier 1's TX-side continuous owner-continuity
/// self-check. 2026-08-01 port of Android's
/// `analysis/OwnerContinuityMonitor.kt`.
///
/// That answers "does the person SPEAKING INTO MY MICROPHONE right now
/// still match my own enrolled voice" — a question the RX-side checks and
/// SAS/PQC crypto do not answer: SAS/PQC prove key possession, not who is
/// currently holding the device.
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
/// Learning (`learner`, see `OwnerVoiceLearning` for the rules): the same windows that are scored are also the
/// material the owner's template is learned from, so a person who never enrolled by hand gets one from ordinary
/// calls with nothing asked of them. While a call runs the windows that pass the speech gate are embedded (one
/// embedding per window, reused for the score) and kept in memory, at most `OwnerVoiceLearning.maxWindowsPerCall`;
/// they are handed to the learner once, when the call ends, never one by one. The state stays `.inactive` until
/// a template exists. Only the local microphone is ever learned from: `feed` takes nothing else.
///
/// Only windows that hold speech count: a window with less than
/// `minSpeechMs` of it (a listening owner in a loud place, dead air) is
/// skipped before anything else, and so is a window the embedder gave no
/// embedding for — neither is a score, and neither touches the smoothed
/// value or the mismatch streak. See `speechDetector`.
///
/// Score scale — W-VSCORESCALE (2026-08-02). `verifier.cosine(pcm16k:)`
/// returns a RAW COSINE in `[-1, 1]`, and this class converts it to
/// `V_score = (cosine + 1) / 2` BEFORE thresholding, because
/// `verifiedThreshold`/`uncertainThreshold` are V_score-scale values.
///
/// The previous version of this doc asserted the opposite — that the
/// thresholds were calibrated against raw cosine and that a V-score must
/// NOT be fed here — and the code thresholded the raw cosine directly. That
/// was wrong in a way that disabled the whole signal. Those two constants
/// were carried over from Android's `OwnerContinuityMonitor`, which had in
/// turn carried them from the remote-voice gate of that time, which was fed
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

    /// Cutoffs on the smoothed V_score (`(cosine + 1) / 2`, see the class doc),
    /// kept independent of Android's `VoicePrintVault` bars so tuning one never
    /// silently retunes another.
    ///
    /// At or above `verifiedThreshold` the smoothed score reads as the owner's
    /// voice (`.verified`); under `uncertainThreshold` it reads as a different
    /// voice (`.mismatch`, which counts toward `mismatchStreakForAlert`); in
    /// between it is `.uncertain`. Both bars are set on the embedding the model
    /// gives for a 4 s window of 400 frames, scored against the template the
    /// enrolment builds (one embedding of the 9 s recorded in one sitting), on
    /// offline read speech (LibriSpeech and MLS Italian, windows from another
    /// sitting than the template's, clean and with room reverb and noise) with
    /// the smoothing of this class. Offline speech is a guide, not a phone
    /// call: the signal is a soft, advisory indicator.
    private static let verifiedThreshold: Float = 0.72
    static let uncertainThreshold: Float = 0.62

    /// EMA smoothing factor — 2026-08-01 fix carried from Android: the raw
    /// per-tick CAM++ score is too noisy to threshold directly (confirmed
    /// on-device — reacting to every tick made the badge flicker to
    /// `.mismatch` on ordinary noise dips even during genuine, continuous
    /// owner speech). One step per window, 4 s.
    private static let emaAlpha: Float = 0.35

    /// 3 consecutive 4 s Mismatch windows (~12 s sustained) before alerting —
    /// long enough that a brief mic hand-off/background noise burst can't
    /// false-positive. Matches Android's `MISMATCH_STREAK_FOR_ALERT`.
    private static let mismatchStreakForAlert = 3

    /// 4 s of native-rate audio buffered before each score — matches
    /// Android's `TARGET_SAMPLES_16K` (64_000 samples @ 16kHz = 4s) in
    /// WALL-CLOCK terms. 4 s at 16 kHz is 64,000 samples, which
    /// `KaldiFbankExtractor` (snip_edges=false) turns into round(64000 / 160) =
    /// 400 fbank frames, a multiple of 200: `CamPlusSpeakerEmbedder` gives the
    /// model every frame of the window. The monitor buffers RAW native PCM,
    /// resamples a finished window to 16 kHz once, and uses that one window
    /// for the speech gate and for the score.
    private static let targetWindowSeconds: Double = 4.0

    /// The least speech, in milliseconds of the 4 s window, that a window must
    /// hold to be scored: the gate of `speechDetector` (Silero VAD, a 32 ms chunk
    /// counts at a probability of 0.5). The bars above are set on windows of
    /// speech, and a window without enough of it is not a sample of anybody's
    /// voice, so the gate keeps it out of the score: an owner who listens in a
    /// car, a street or a café is not scored.
    ///
    /// The value is set offline on 4 s windows, with the Silero model and
    /// threshold of the voice bundle, on windows of read speech (LibriSpeech and
    /// MLS Italian, clean and with room reverb and noise) and on windows of noise
    /// without voices (MUSAN and DNS-challenge Freesound noise and pink noise, at
    /// several levels).
    static let minSpeechMs = 1_500

    private let verifier: SpeakerVerifier
    /// Learns the owner's template from the windows of the calls; `nil` keeps the monitor to scoring against whatever
    /// template the verifier was given.
    private let learner: OwnerVoiceLearner?
    /// The signed-in account, read on the monitor's queue when a call's first window arrives: the learning belongs to
    /// it (`OwnerVoiceLearner`). Empty or unset: nothing is learned.
    public var userIdProvider: (() -> String)?
    /// The speech gate: a window with less than `minSpeechMs` of speech in it is
    /// skipped, whatever its energy.
    private let speechDetector: any WindowSpeechDetector
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
    private var nativeRateHz = SpeakerVerifier.nativeSampleRate
    private var ema: Float?
    private var enrolledCached = false
    /// Last state actually handed to `onStateChanged` since the latest
    /// `start()`. `nil` right after `start()`, so the first state produced
    /// after a (re)start is always delivered once; afterwards only a repeated
    /// `.inactive` is suppressed (see `setState`).
    private var lastNotified: State?
    /// The learning of the current call (queue-confined). `sessionPrepared` is false from `start()` until the first
    /// window has asked the learner for the template of the account.
    private var sessionPrepared = false
    private var learning = false
    private var collectForRefinement = false
    private var sessionUserId = ""
    private var sessionId = UUID().uuidString
    private var pendingWindows: [OwnerVoiceLearning.Window] = []
    /// While the call's collection is open and a template exists: the number of windows judged below the lower bar
    /// against it (not kept). A call that is mostly mismatch is dropped at the end (`flushPendingWindows`).
    private var mismatchCount = 0

    // MARK: - Lock-guarded state (read from `shouldAlert()`/`currentState()`
    // on an arbitrary caller thread, written from `queue` inside `setState`)
    private var _mismatchStreak = 0
    private var _state: State = .inactive
    /// Mirror of `enrolledCached` readable from the capture thread, so `feed`
    /// can decide WITHOUT enqueueing whether a chunk can matter at all.
    private var _enrolled = false
    /// True once the (single) "not registered" state has been queued since the
    /// latest `start()` — see `feed`.
    private var _inactiveQueued = false
    /// Number of chunks `feed` actually enqueued (test observability only).
    private var _enqueuedChunks = 0
    /// True once there is nothing left to learn or score in this call (no template and the call's windows are all
    /// kept, or nothing can be learned), so `feed` stops enqueuing.
    private var _learnDone = false

    /// Fires on `queue` (NOT the caller's thread) whenever `state` changes —
    /// a deliberate difference from `GuardianMode`'s
    /// callbacks (which fire synchronously on the audio thread): this
    /// monitor's scoring is expensive and must never run on a shared
    /// real-time thread, so its callback necessarily fires from its own
    /// queue instead. Consumers must hop to their own thread (e.g. main)
    /// themselves before touching UI state, same as every other
    /// cross-thread callback in this codebase.
    public var onStateChanged: ((State) -> Void)?

    /// - Parameter speechDetector: the speech gate, see `minSpeechMs`. The default is the Silero VAD of the
    ///   voice bundle, shared by the app.
    /// - Parameter learner: learns the owner's template from the windows of the calls, see the type's doc. `nil` (the
    ///   default) leaves the monitor as a scorer of the template the verifier already has.
    public init(
        verifier: SpeakerVerifier,
        speechDetector: any WindowSpeechDetector = SileroWindowSpeechDetector.shared,
        learner: OwnerVoiceLearner? = nil
    ) {
        self.verifier = verifier
        self.speechDetector = speechDetector
        self.learner = learner
    }

    /// (Re)starts the monitor. `nativeSampleRateHz` is the TX capture
    /// pipeline's sample rate (48kHz for this app's call pipeline).
    /// Caches `verifier.getState() == .ready` ONCE here — mirrors Android's
    /// W-OWNERCONTINUITY-PERF fix: `SpeakerVerifier` state cannot change
    /// mid-call (a separate UI-driven flow), so re-checking it on every fed
    /// chunk would be pure waste, not correctness.
    public func start(nativeSampleRateHz: Int = 48_000) {
        // Decided here, not on the queue, so `feed` (capture thread) never sees
        // a stale value between this call and the queued block below.
        let enrolledNow = verifier.getState() == .ready
        lock.lock()
        _enrolled = enrolledNow
        _inactiveQueued = false
        _learnDone = false
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            // The windows of a call that was not stopped first are handed over before the new call starts.
            self.flushPendingWindows()
            self.sessionPrepared = false
            self.learning = false
            self.collectForRefinement = false
            self.sessionId = UUID().uuidString
            self.buffer.removeAll(keepingCapacity: true)
            self.targetBytes = Int(Double(nativeSampleRateHz) * Self.targetWindowSeconds) * MemoryLayout<Int16>.size
            self.nativeRateHz = nativeSampleRateHz
            self.ema = nil
            self.enrolledCached = enrolledNow
            self.lastNotified = nil
            self.lock.lock()
            self._mismatchStreak = 0
            let wasInactive = self._state == .inactive
            self.lock.unlock()
            // A reset from a scored state is a real change and is announced
            // right away. From `.inactive` there is nothing to announce here:
            // the first state produced after the start is delivered by
            // `setState` (lastNotified is nil), as before.
            if !wasInactive { self.setState(.inactive) }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.removeAll(keepingCapacity: true)
            self.flushPendingWindows()
        }
    }

    /// Feed a chunk of RAW TX PCM (Int16, mono, little-endian, captured
    /// PRE-encode from the LOCAL microphone — never RX/remote audio). Safe
    /// to call every capture frame; enqueues onto `queue` and returns
    /// immediately (never blocks the caller — see class doc's never-block
    /// note). Internally buffered and only scored once a 4 s window of audio
    /// has accumulated (`targetWindowSeconds`).
    public func feed(pcmFrame: Data) {
        guard !pcmFrame.isEmpty else { return }
        // Not registered (no Voice-as-Key template): the state can only be
        // `.inactive` and no chunk will ever be scored, so only the FIRST chunk
        // after a start is queued (to deliver that state once); every later
        // chunk returns here without queueing anything (up to 100 per second).
        lock.lock()
        if !_enrolled && !(learner != nil && !_learnDone) {
            if _inactiveQueued { lock.unlock(); return }
            _inactiveQueued = true
        }
        _enqueuedChunks += 1
        lock.unlock()
        queue.async { [weak self] in self?.process(pcmFrame) }
    }

    /// Chunks that `feed` actually enqueued. Test observability only.
    internal var enqueuedChunkCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _enqueuedChunks
    }

    /// Blocks until everything queued so far has run. Test use only.
    internal func drainForTesting() {
        queue.sync {}
    }

    /// Runs `setState` on the monitor's queue. Test use only.
    internal func applyStateForTesting(_ state: State) {
        queue.sync { setState(state) }
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
        if learner != nil, !sessionPrepared { prepareSession() }
        guard enrolledCached || learning else {
            setState(.inactive)
            return
        }
        // No template yet and this call's windows are all kept: nothing more to do until the call ends.
        if !enrolledCached, pendingWindows.count >= OwnerVoiceLearning.maxWindowsPerCall {
            buffer.removeAll(keepingCapacity: true)
            markLearnDone()
            return
        }
        buffer.append(pcmFrame)
        guard targetBytes > 0, buffer.count >= targetBytes else { return }
        let chunk = buffer
        buffer.removeAll(keepingCapacity: true)

        // The finished window at the embedder's rate, once: the speech gate and
        // the score both use this one. A window that goes over the target by up
        // to one chunk keeps its extra audio; the embedder uses the first 400
        // frames.
        let window = SpeakerVerifier.resampleTo16k(SpeakerVerifier.pcmToFloat(chunk), fromHz: nativeRateHz)

        // The speech gate (see `minSpeechMs`): a window without speech in it is
        // no sample of anybody's voice, so it reaches neither the score nor the
        // smoothing nor the streak.
        guard speechDetector.speechMs(pcm16k: window) >= Self.minSpeechMs else { return }

        // One embedding per window, whatever wants it: it is kept as learning material while there is no template or
        // the template is not final, and scored against the template when there is one. A window the embedder gave no
        // embedding for is neither: skipped like the windows above, EMA and streak untouched, and it does not use up
        // the call's share of windows.
        let collecting = learning && (!enrolledCached || collectForRefinement)
            && pendingWindows.count < OwnerVoiceLearning.maxWindowsPerCall
        let windowEmbedding = (collecting || enrolledCached) ? verifier.embed(pcm16k: window) : nil
        let windowCosine = windowEmbedding.flatMap { enrolledCached ? verifier.cosine(embedding: $0) : nil }
        // With a template, another voice must not become part of it: while the call's collection is open, a window
        // below the lower bar is not kept and is counted (`flushPendingWindows` drops a call that is mostly
        // mismatch). Windows after the cap are not judged for learning. With no template yet the phone's user is
        // taken to be the owner, so every window is kept.
        var keep = true
        if collecting, enrolledCached, let windowCosine {
            if (windowCosine + 1) / 2 < Self.uncertainThreshold { mismatchCount += 1; keep = false }
        }
        if collecting, keep, let windowEmbedding {
            pendingWindows.append(OwnerVoiceLearning.Window(
                embedding: windowEmbedding,
                callId: sessionId,
                capturedAtEpochMs: Int64(Date().timeIntervalSince1970 * 1000),
                netSpeechMs: window.count * 1000 / 16_000))
        }
        // Learning without a template is silent: the state stays `.inactive`.
        guard enrolledCached else { return }
        guard let cosine = windowCosine else { return }

        // W-VSCORESCALE — convert to the scale the thresholds actually live
        // on before comparing. `cosine` is a raw cosine; the constants
        // are V_score values inherited (via Android) from the remote-voice
        // gate of that time, which was fed
        // SpeakerVerifier.computeVerificationScore. Thresholding the cosine
        // directly made the effective bar V_score 0.81 and pinned the signal
        // at .uncertain/.mismatch forever. See the class doc for the measured
        // numbers. The conversion is affine and monotonic, so it changes no
        // ordering — only that the value and the bar are finally in the same
        // units. Smooth AFTER converting so `ema` is a V_score too.
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
        // The level only, no score: the line says which state a window was
        // in and nothing about the voice itself.
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
        // `level.rawValue` — `lv=uncertain` is exactly 12 and would vanish.
        let lv: String
        switch level {
        case .verified:  lv = "ver"
        case .uncertain: lv = "unc"
        case .mismatch:  lv = "mis"
        }
        print("[OwnerCont] lv=" + lv)
        lock.lock()
        _mismatchStreak = (level == .mismatch) ? _mismatchStreak + 1 : 0
        lock.unlock()
        setState(.scored(score: smoothed, level: level))
    }

    /// Once per call, on the first window: asks the learner for the template of the signed-in account and whether this
    /// call's windows are still worth keeping. When it cannot say (`.unavailable`) the monitor keeps whatever template
    /// the verifier holds and learns nothing.
    private func prepareSession() {
        sessionPrepared = true
        guard let learner else { return }
        let userId = userIdProvider?() ?? ""
        switch learner.prepare(userId: userId) {
        case .unavailable:
            learning = false
        case .ready(let template, let collect):
            learning = true
            sessionUserId = userId
            collectForRefinement = collect
            if let template {
                verifier.importTemplate(template)
                enrolledCached = true
            } else {
                verifier.reset()
                enrolledCached = false
            }
            lock.lock()
            _enrolled = enrolledCached
            lock.unlock()
        }
        if !enrolledCached {
            if !learning { markLearnDone() }
            setState(.inactive)
        }
    }

    private func markLearnDone() {
        lock.lock()
        _learnDone = true
        lock.unlock()
    }

    /// Hands the call's kept windows to the learner, once. `print`, not RTLog, like the line in `process`: this
    /// package cannot reach RTLog. The line says how far the learning is and nothing about the voice.
    private func flushPendingWindows() {
        let mismatches = mismatchCount
        mismatchCount = 0
        guard !pendingWindows.isEmpty else { return }
        let batch = pendingWindows
        pendingWindows.removeAll()
        // At least 2 mismatches and at least a third of the windows judged: another voice on the phone. One noise
        // burst among good windows does not cost the call.
        if mismatches >= 2, mismatches * 3 >= mismatches + batch.count {
            print("[OwnerCont] learn st=drop")
            return
        }
        guard learning, let learner,
              let stage = learner.record(windows: batch, userId: sessionUserId) else { return }
        let code: String
        switch stage {
        case .learning: code = "lrn"
        case .min:      code = "min"
        case .refined:  code = "ref"
        }
        print("[OwnerCont] learn st=" + code)
    }

    /// Stores the state and notifies the observer, except that a repeated
    /// `.inactive` (the unregistered monitor, up to 100 per second) is delivered
    /// only once since `start()`: it neither calls `onStateChanged`
    /// nor causes any downstream UI publish.
    private func setState(_ newState: State) {
        lock.lock()
        _state = newState
        lock.unlock()
        // Only the repeated "not registered" state is suppressed. A scored state
        // is delivered for EVERY evaluated window, even when it equals the
        // previous one: the consumer reads `shouldAlert()` (the mismatch streak)
        // at delivery time, so the third identical mismatch window must still
        // reach it.
        if newState == State.inactive, lastNotified == State.inactive { return }
        lastNotified = newState
        onStateChanged?(newState)
    }
}
