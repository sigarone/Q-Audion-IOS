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
/// W-GUARDIAN3SIG (2026-09-11) — this class now reproduces Android's full
/// `DeepfakeMonitor` 3-signal fusion (deepfake classifier + liveness +
/// voiceprint), not just the voiceprint sub-score alone. See that class's
/// kdoc for the reference formulas this ports verbatim: weighted combine
/// (0.4/0.3/0.3), per-sub-score `calibrate()` remap, and a whole-tick VAD
/// gate. The deepfake classifier (`DeepfakeClassifier`) and its 16kHz
/// resampler (`SpeakerVerifier.resampleTo16k`) already existed on iOS but
/// were unwired outside their own files; liveness has no separate ML model
/// on Android either — it's `heuristicLiveness` below, a direct port of
/// Android's `OnnxDeepfakeClassifier.heuristicLiveness` (RMS → dBFS →
/// sigmoid, no model needed).
///
/// Owns the ~3s-throttled score-compute cadence itself (a private
/// `DispatchSourceTimer` on its own queue) — Android's equivalent cadence
/// lives in `CallController.contactVoiceScoreJob`, a coroutine loop on a
/// dedicated dispatcher; iOS has no directly equivalent shared call-scoped
/// coroutine context, so this class is deliberately self-contained instead
/// (mirrors `OwnerContinuityMonitor`'s own self-paced design), giving the
/// app layer exactly two calls to make: `setActiveContact` once the peer
/// is known, `feedContinuous` on every RX frame (cheap, always safe to
/// call unconditionally — a no-op internally whenever no contact is
/// active, see `SpeakerVerifier.feedVerificationFrame`'s `.idle` branch).
///
/// Interval widened from the original 1.0s to 3.0s (2026-09-11, matches
/// Android's `SCORE_INTERVAL_MS`) — a tick now does THREE sequential
/// passes (deepfake ONNX inference + liveness arithmetic + CAM++
/// embedding), the same shape of work Android's own comment on
/// `SCORE_INTERVAL_MS` says caused real speech loss at a tighter interval
/// on a live call. No reason to assume iOS's ONNX/CoreML path is cheaper.
public final class ContactVoiceVerifier: @unchecked Sendable {
    private static let scoreIntervalSeconds: Double = 3.0

    /// Deepfake-classifier rolling window — the model wants ~4.04s
    /// (`DeepfakeClassifier.modelInputLength` samples @ 16kHz); shorter
    /// buffers get zero-padded by the classifier itself, but a full window
    /// gives it real context instead of mostly silence on every early tick.
    private static let deepfakeWindowSamples = DeepfakeClassifier.modelInputLength
    /// Minimum buffered samples before a tick even attempts scoring — 1s
    /// @ 16kHz, matching Android's `MIN_WINDOW_SAMPLES`.
    private static let deepfakeMinSamples = KaldiFbankExtractor.sampleRate

    /// Same weighting Android's `DeepfakeMonitor.combine()` uses.
    private static let wDeepfake: Float = 0.4
    private static let wLiveness: Float = 0.3
    private static let wVoiceprint: Float = 0.3

    /// Same calibration constants as Android's `DeepfakeMonitor.calibrate()`
    /// — see that function's kdoc for the reasoning (genuine-speech AASIST
    /// output clusters well below 1.0 by design; this remaps it so a
    /// genuine caller consistently reads C ≥ 0.90 without inflating an
    /// actual deepfake signal).
    private static let genuineFloor: Float = 0.20
    private static let displayFloor: Float = 0.95

    private let verifier: SpeakerVerifier
    private let store: VoiceprintStore
    private let gate = ContactVoiceContinuityGate()

    /// "Interlocutore cambiato" — relative change detection over the SAME
    /// score stream `gate` consumes. A second consumer, never a second
    /// embedding pass: the expensive work is the CAM++ inference the timer
    /// below already triggers, and this adds only arithmetic on its result.
    ///
    /// Both signals are worth showing and they answer different questions.
    /// The gate asks whether the voice matches the stored template for this
    /// contact, an absolute judgement resting on thresholds never validated
    /// against a real impostor. This asks only whether the voice changed
    /// during the call, measured against the call's own audio and therefore
    /// unaffected by codec, room or handset.
    ///
    /// Deliberately fed the raw voiceprint/AS-Norm score only, NEVER the
    /// deepfake+liveness+voiceprint combine below — "did the physical
    /// speaker change" and "does this audio look synthetic" are different
    /// questions, exactly like Android keeps `SpeakerChangeDetector`
    /// (relative CUSUM) entirely separate from `DeepfakeMonitor` (3-signal
    /// fusion). Mixing the two here would blur a signal this class already
    /// documents as scoped to speaker identity alone.
    private let speakerChange = RemoteSpeakerChangeMonitor()

    private let scoreQueue = DispatchQueue(label: "com.bcrypto.qaudion.contactVoiceScore", qos: .utility)
    private let lock = NSLock()
    private var loadedContactId: String?
    private var scoreTimer: DispatchSourceTimer?

    /// Guards against a slow tick (ONNX inference stall) overlapping the
    /// next timer fire — ticks are skipped, never queued, matching this
    /// class's existing "a missed tick just holds the last value" contract.
    private var tickInFlight = false

    /// Ring buffer for the deepfake classifier's 16kHz input — same
    /// fixed-size ring + wraparound-index shape as Android's
    /// `OnnxDeepfakeClassifier.rollingBuf`/`rollingPos`/`rollingCount`,
    /// chosen for the same reason: this fills on every RX frame (~50/s),
    /// and an array-shift buffer (`removeFirst`) would mean an O(n)
    /// memmove per frame instead of O(1).
    private var pcm16kRingBuf = [Float](repeating: 0, count: ContactVoiceVerifier.deepfakeWindowSamples)
    private var pcm16kRingPos = 0
    private var pcm16kRingCount = 0

    /// Fires on `scoreQueue` (not the caller's thread — same cross-thread
    /// callback contract as `OwnerContinuityMonitor.onStateChanged`; hop to
    /// your own thread before touching UI state) whenever the gate's level
    /// changes as a result of a new score tick.
    public var onLevelChanged: ((ContactVoiceContinuityGate.Level) -> Void)?

    /// MASVS-CRYPTO remediation (2026-08-20/21) — the raw 0..1 continuity
    /// score, fired alongside [onLevelChanged] on the same `scoreQueue`
    /// tick. `onLevelChanged` only exposes the 3-band hysteresis level
    /// (green/yellow/red), which is too coarse for
    /// `ReKeyScheduler.observeConfidence` — Android's adaptive re-key
    /// period formula needs the continuous value. Additive: does not
    /// change any existing consumer's behavior.
    ///
    /// W-GUARDIAN3SIG (2026-09-11) — now the calibrated, weighted 3-signal
    /// combine (deepfake + liveness + voiceprint), not the raw voiceprint
    /// score alone. Same value Android's `guardian.index`/`confidence` Flow
    /// carries into its own `ReKeyScheduler.observeConfidence` call.
    public var onScoreUpdated: ((Float) -> Void)?

    /// Fires on `scoreQueue` whenever the speaker-change verdict actually
    /// changes. Informational: the app layer shows it and does nothing else
    /// with it — no muting, no teardown, no key action.
    public var onSpeakerChanged: ((RemoteSpeakerChangeMonitor.Verdict) -> Void)?

    /// Current speaker-change verdict for the trust badges.
    public var speakerChangeVerdict: RemoteSpeakerChangeMonitor.Verdict { speakerChange.verdict }

    /// Record the far end's own receive-side verdict about this device's
    /// user, as delivered over the in-call control channel.
    public func peerReportedSpeakerChange(_ changed: Bool) {
        speakerChange.onPeerReportedChange(changed)
    }

    /// Discard the change detector's reference and rebuild it on whoever is
    /// speaking now.
    ///
    /// Call this on a media-path switch. A change of path — direct to relay
    /// and back, or an ICE recovery — changes what the received audio sounds
    /// like: different loss, different concealment, more of the far end's
    /// speech reconstructed rather than transmitted. The detector measures
    /// against a reference built earlier in this call, so a path switch
    /// invalidates it, and a detector that did not know would report the
    /// network event as a person walking in. Re-anchoring costs the warm-up
    /// again and is the honest answer.
    public func acousticPathChanged() {
        speakerChange.reanchor()
    }

    /// - Parameter cohortNormalizer: AS-Norm impostor-cohort back-end fed
    ///   into the owned `SpeakerVerifier` — see `SpeakerCohortNormalizer`'s
    ///   class kdoc and `SpeakerVerifier.computeAsNormScore()`'s kdoc.
    ///   Defaults to the process-wide `.shared` instance; `ContactVoiceVerifier`
    ///   is the ONLY `SpeakerVerifier` call site in this codebase that wants
    ///   AS-Norm scoring (mirrors Android's `VoicePrintBridgeImpl`-only
    ///   wiring — Tier 1's manual-enrollment-only verifiers stay on the
    ///   `nil` default).
    public init(
        embedder: CamPlusSpeakerEmbedder = .shared,
        store: VoiceprintStore = VoiceprintStore(),
        cohortNormalizer: SpeakerCohortNormalizer = .shared
    ) {
        self.verifier = SpeakerVerifier(embedder: embedder, cohortNormalizer: cohortNormalizer)
        self.store = store
        speakerChange.onVerdictChanged = { [weak self] verdict in
            self?.onSpeakerChanged?(verdict)
        }
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
        resetRingLocked()
        lock.unlock()

        gate.reset()
        speakerChange.reset()
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
    ///
    /// Also feeds this class's own 16kHz ring buffer for the deepfake
    /// classifier — a second, independent accumulation from the SAME PCM
    /// frame, since `SpeakerVerifier`'s own buffer is scoped to CAM++
    /// embedding windows, not the deepfake model's window shape.
    public func feedContinuous(_ pcmFrame: Data) {
        verifier.feedVerificationFrame(pcmFrame)

        let floats = SpeakerVerifier.pcmToFloat(pcmFrame)
        guard !floats.isEmpty else { return }
        let resampled = SpeakerVerifier.resampleTo16k(floats, fromHz: SpeakerVerifier.nativeSampleRate)
        guard !resampled.isEmpty else { return }

        lock.lock()
        for s in resampled {
            pcm16kRingBuf[pcm16kRingPos] = s
            pcm16kRingPos = (pcm16kRingPos + 1) % pcm16kRingBuf.count
            if pcm16kRingCount < pcm16kRingBuf.count { pcm16kRingCount += 1 }
        }
        lock.unlock()
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
            self?.runTick()
        }
        timer.resume()
        scoreTimer = timer
    }

    private func stopTimerLocked() {
        scoreTimer?.cancel()
        scoreTimer = nil
    }

    private func resetRingLocked() {
        pcm16kRingPos = 0
        pcm16kRingCount = 0
    }

    /// Unwraps the ring buffer into chronological order — same shape as
    /// Android's `OnnxDeepfakeClassifier`'s own rolling-buffer read path.
    private func snapshotRingLocked() -> [Float] {
        if pcm16kRingCount < pcm16kRingBuf.count {
            return Array(pcm16kRingBuf[0..<pcm16kRingCount])
        }
        var out = [Float](repeating: 0, count: pcm16kRingBuf.count)
        let tailLen = pcm16kRingBuf.count - pcm16kRingPos
        out.replaceSubrange(0..<tailLen, with: pcm16kRingBuf[pcm16kRingPos...])
        out.replaceSubrange(tailLen..<pcm16kRingBuf.count, with: pcm16kRingBuf[0..<pcm16kRingPos])
        return out
    }

    /// One scoring pass. The cheap, synchronous part (voiceprint score,
    /// `gate`/`speakerChange` feed, VAD gate) runs directly on `scoreQueue`
    /// via the timer, preserving this class's existing "these callbacks
    /// fire on scoreQueue" contract. Only the deepfake classifier call is
    /// `async` (ONNX/CoreML inference) — that part runs in a `Task`, and
    /// its result is hopped BACK onto `scoreQueue` before `onScoreUpdated`
    /// fires, so every public closure still fires from the same queue.
    /// `tickInFlight` keeps two ticks from ever overlapping if inference
    /// runs long.
    private func runTick() {
        lock.lock()
        guard !tickInFlight else { lock.unlock(); return }
        tickInFlight = true
        let window = snapshotRingLocked()
        lock.unlock()

        // Voiceprint score first — cheap-ish CAM++ pass, and its own nil
        // ("not enough audio yet" / "template not ready") is meaningful on
        // its own, exactly as before this class combined signals.
        //
        // `gate` is fed ONLY the raw voiceprint score, never the 3-signal
        // combine below — per its own kdoc, "voce remota" specifically asks
        // whether this voice matches the STORED TEMPLATE, a narrower
        // question than "does this audio look synthetic". Feeding it twice
        // per tick (raw, then combined) would also double-count into its
        // internal EMA and desync its hysteresis from its own documented
        // calibration.
        let vp = verifier.computeVerificationScore()
        let asNorm = verifier.computeAsNormScore()
        gate.feed(vp)
        speakerChange.feed(asNorm ?? vp)

        // Whole-tick VAD gate on the deepfake-classifier window — mirrors
        // Android's `DeepfakeMonitor.feed()`: silence/comfort-noise skips
        // the WHOLE tick (no update at all), it doesn't degrade the score.
        // Matches the pre-existing contract too: no meaningful combine
        // without a real voiceprint reading this tick either.
        let windowRms = Self.rms(window)
        guard window.count >= Self.deepfakeMinSamples,
              windowRms >= SpeakerVerifier.voiceActivityRmsThreshold,
              let vp
        else {
            lock.lock(); tickInFlight = false; lock.unlock()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let genuineProb: Float
            do {
                let result = try await DeepfakeClassifier.shared.score(pcm16kMono: window)
                genuineProb = (1 - result.spoofProbability).clamped01()
            } catch {
                // Matches Android's `safeScore` catch-all: default to fully
                // trusted rather than penalizing a caller for a model/
                // runtime failure that has nothing to do with them.
                genuineProb = 1
            }
            let liveness = Self.heuristicLiveness(window)
            let combined = (
                Self.wDeepfake * Self.calibrate(genuineProb)
                    + Self.wLiveness * Self.calibrate(liveness)
                    + Self.wVoiceprint * Self.calibrate(vp)
            ).clamped01()

            self.scoreQueue.async {
                self.onScoreUpdated?(combined)
                self.lock.lock()
                self.tickInFlight = false
                self.lock.unlock()
            }
        }
    }

    /// Below `genuineFloor` is left unchanged (deepfake zone — no
    /// inflation of a real attack signal); `[genuineFloor, 1.0]` is
    /// linearly remapped to `[displayFloor, 1.0]`. Verbatim port of
    /// Android's `DeepfakeMonitor.calibrate()`.
    private static func calibrate(_ raw: Float) -> Float {
        guard raw >= genuineFloor else { return raw }
        return displayFloor + (raw - genuineFloor) / (1 - genuineFloor) * (1 - displayFloor)
    }

    /// Verbatim port of Android's `OnnxDeepfakeClassifier.heuristicLiveness`
    /// — no ML model on either platform, just RMS → dBFS → a soft knee at
    /// -45 dBFS. Operates on the SAME 16kHz window as the deepfake
    /// classifier (both need the resampled buffer; unlike Android, which
    /// re-derives it from the same PCM chunk it already has in hand).
    private static func heuristicLiveness(_ pcm: [Float]) -> Float {
        guard !pcm.isEmpty else { return 0 }
        var sumSquares: Double = 0
        for v in pcm { sumSquares += Double(v) * Double(v) }
        let rmsVal = Float(sqrt(sumSquares / Double(pcm.count)))
        let dbfs: Float = rmsVal <= 1e-7 ? -120 : (20 * log10f(rmsVal))
        return sigmoid((dbfs + 45) / 10).clamped01()
    }

    /// Numerically stable sigmoid — same branch-on-sign shape as Android's
    /// `OnnxDeepfakeClassifier.sigmoid` (avoids overflow on very negative x).
    private static func sigmoid(_ x: Float) -> Float {
        if x >= 0 {
            let e = expf(-x)
            return 1 / (1 + e)
        }
        let e = expf(x)
        return e / (1 + e)
    }

    private static func rms(_ pcm: [Float]) -> Float {
        guard !pcm.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for v in pcm { sumSquares += v * v }
        return (sumSquares / Float(pcm.count)).squareRoot()
    }
}

private extension Float {
    func clamped01() -> Float { min(1, max(0, self)) }
}
