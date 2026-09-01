import Foundation

/// Speaker verification using CAM++ neural embeddings (Alibaba 3D-Speaker,
/// Apache-2.0, `campplus_sv_voxceleb_16k.onnx`).
///
/// 2026-08-01 REPLACES the previous classical LFCC-mean embedding
/// (arithmetic mean of stacked per-frame LFCC vectors, 128-dim, L2-normalized)
/// — the same category of classical statistical embedding Android's own
/// real-device test proved unable to reliably distinguish two related
/// speakers (father/daughter — logged cosine scores stayed 0.77-0.99
/// regardless of who was talking). This is the Android
/// `deepfake.SpeakerVerifier.kt` migration ported to iOS; see that file's
/// kdoc for the full research/decision trail behind choosing CAM++.
///
/// 2026-08-01 EXTENDED to match Android's full capability set: auto-
/// enrollment (`startAutoEnrollment`) and the cheap-feed/expensive-score
/// split (`feedVerificationFrame`/`computeVerificationScore`) that Feature
/// B's continuous per-contact "voce remota" verification needs — see
/// `ContactVoiceVerifier`, the iOS port of Android's `VoicePrintBridgeImpl`
/// and the only consumer of these new methods. Feature A's 3 existing call
/// sites (`VoiceEnrollmentContainer`/`VoiceUnlockController`/`VoiceAuthGate`)
/// use only the ORIGINAL manual-enrollment API
/// (`startEnrollment`/`processEnrollmentFrame`/`finishEnrollment`/`verify`/
/// `exportTemplate`/`importTemplate`), unchanged in behavior.
///
/// **Embedding computation (512 dimensions):**
/// 1. Concatenate accumulated raw PCM frames (48kHz, this app's native rate)
/// 2. Resample to 16kHz (the model's required input rate)
/// 3. Extract 80-dim log-mel fbank features via `KaldiFbankExtractor`
///    (Kaldi/sherpa-onnx-compatible frontend — a DIFFERENT feature type
///    from `LfccExtractor`, do not conflate the two)
/// 4. Run CAM++ ONNX inference via `CamPlusSpeakerEmbedder` -> L2-normalized
///    512-dim embedding
///
/// **Two verification scores, two different scales — do not conflate:**
/// - `verify(pcmFrame:)` (original, Tier 1 / Feature A): raw cosine
///   similarity, `[-1, 1]`. `OwnerContinuityMonitor` thresholds this
///   directly — confirmed against Android's `analysis/VoicePrintVault.kt`
///   `verify()`, which returns raw (clamped) cosine, not a mapped score.
/// - `computeVerificationScore()` (new, Tier 2 / Feature B): cosine mapped
///   to `[0, 1]` via `(cosine + 1) / 2` ("V-score"), matching Android's
///   `deepfake/SpeakerVerifier.kt` `computeVerificationScoreLocked` exactly.
///   `ContactVoiceContinuityGate`'s thresholds are calibrated against THIS
///   scale, not raw cosine. Mixing the two up silently miscalibrates
///   whichever gate receives the wrong one — verified against both real
///   Android source files before writing this, not assumed.
///
/// Thread-safety: a single `NSLock` guards ALL mutable state (mirrors
/// Android's `synchronized(lock)` on every method) — this instance is
/// touched from more than one thread once Tier 2 is wired
/// (`ContactVoiceVerifier` feeds it from the RX audio thread and scores it
/// from its own internal timer thread). Two different disciplines for the
/// expensive CAM++ embed call, both mirroring Android exactly:
/// - `computeVerificationScore()` holds `lock` across the embed call —
///   safe ONLY because it is the sole caller of the expensive path on the
///   `.ready` branch, throttled by its own owner (`ContactVoiceVerifier`)
///   to ~1/s; the other method touching this instance concurrently
///   (`feedVerificationFrame`) is cheap (buffer append only), so a brief
///   lock wait during that ~1/s tick is acceptable. Mirrors Android's
///   `computeVerificationScoreLocked`.
/// - Auto-enrollment completion runs the embed OUTSIDE `lock` (mirrors
///   Android's `completeAutoEnrollmentAsync`) because it is reachable from
///   the FAST per-frame `feedVerificationFrame` path — holding the lock
///   there would block every other frame for the embed's full duration.
public final class SpeakerVerifier: @unchecked Sendable {
    public enum State { case idle; case enrolling; case autoEnrolling; case ready; case verifying }

    public static let embeddingDimension = CamPlusSpeakerEmbedder.embeddingDimension
    /// Native PCM sample rate this app's call pipeline captures/feeds at.
    public static let nativeSampleRate = LfccExtractor.sampleRate

    /// Frames per verification window for `feedVerificationFrame`/
    /// `computeVerificationScore` — ~1s at 20ms/frame, matches Android's
    /// `verificationWindowFrames` default (50).
    private static let verificationWindowFrames = 50

    /// Silence gate for the `.ready`-branch aggregate window AND the
    /// `.autoEnrolling` per-frame gate — same normalized-float RMS
    /// threshold Android derives from `AudioConstants.VAD_RMS_THRESHOLD_INT16
    /// / 32768` (360.0 / 32768.0). iOS has no shared cross-engine
    /// `AudioConstants` VAD constant to derive this from at this layer, so
    /// the same already-validated NUMERIC value is used directly rather
    /// than re-deriving/guessing a new one.
    private static let voiceActivityRmsThreshold: Float = 360.0 / 32_768.0

    private let embedder: any SpeakerEmbedding
    private let lock = NSLock()

    /// AS-Norm impostor-cohort back-end for `computeAsNormScore()` — see
    /// that method's kdoc and `SpeakerCohortNormalizer`'s class kdoc for why
    /// this exists and what it measurably buys `SpeakerChangeDetector`.
    /// `nil` (the default, and what every call site other than
    /// `ContactVoiceVerifier` passes) simply disables AS-Norm scoring for
    /// this instance — `computeAsNormScore()` returns `nil` and callers fall
    /// back to the raw score, same as when the asset fails to load at
    /// runtime. 2026-09-02 port of Android `SpeakerVerifier.kt`'s
    /// `cohortNormalizer` constructor parameter.
    private let cohortNormalizer: SpeakerCohortNormalizer?

    private var state: State = .idle
    private var enrollmentFrames: [[Float]] = []
    private var storedTemplate: [Float]?

    /// Bumped on every assignment to `storedTemplate` — the invalidation key
    /// for `cachedEnrollStats` below. Android's equivalent memoization keys
    /// off `activeTemplate`'s ARRAY REFERENCE IDENTITY (every assignment
    /// site there rebinds to a new `FloatArray` rather than mutating one in
    /// place, so `===` is a correct, dependency-free invalidation signal).
    /// Swift's `[Float]` is a value type with no `===` operator, so the same
    /// "every assignment is a fresh value" property is expressed here as a
    /// monotonic counter instead — every one of the three sites that assigns
    /// `storedTemplate` (`finishEnrollment`, `importTemplate`,
    /// `completeAutoEnrollment`) increments this alongside the assignment,
    /// so a stale cache entry's version can never coincidentally match a
    /// later, different template.
    private var templateVersion = 0
    private let enrollmentMinFrames = 150  // ~3 seconds at 20ms/frame

    // MARK: - Tier 2 (auto-enrollment + continuous verification) state

    private var verificationBuffer: [[Float]] = []
    private var autoEnrollContactId: String?
    private var autoEnrollCompletionInFlight = false
    /// Last real, computed V-score (`[0, 1]`) — cached for parity with
    /// Android's `cachedVerificationScore`; currently read only via
    /// `computeVerificationScore()`'s own return value (no separate
    /// cheap-read accessor exists yet — iOS's `verify(pcmFrame:)` is a
    /// DIFFERENT method serving Tier 1's different, raw-cosine contract).
    private var cachedVerificationScore: Float = 0.5

    /// AS-Norm score from the SAME pass that set `cachedVerificationScore`
    /// via `computeVerificationScore()` — see `computeAsNormScore()`. `nil`
    /// whenever `cohortNormalizer` is absent, its asset failed to load, or
    /// no score has been computed yet this call. Mirrors Android's
    /// `cachedAsNormScore`.
    private var cachedAsNormScore: Float?

    /// Enroll-side (template-against-cohort) AS-Norm stats, memoized against
    /// `templateVersion` at the time they were computed — see that
    /// property's kdoc for why a version counter stands in for Android's
    /// reference-identity check here.
    private var cachedEnrollStatsTemplateVersion: Int?
    private var cachedEnrollStats: (mean: Float, std: Float)?

    /// Captures what the auto-enrollment completion routine needs to run
    /// CAM++ inference OUTSIDE `lock` — mirrors Android's
    /// `PendingAutoEnrollComplete`.
    private struct PendingAutoEnrollComplete { let contactId: String; let frames: [[Float]] }

    /// - Parameter embedder: REQUIRED, no default. In the app this is
    ///   ALWAYS `CamPlusSpeakerEmbedder.shared` — a default-constructed
    ///   fallback would silently load a second ~30MB ONNX session per call
    ///   site, exactly the "processing weight/overload" outcome the Android
    ///   port was asked to avoid.
    ///
    ///   Typed as the `SpeakerEmbedding` protocol rather than the concrete
    ///   class (2026-08-02) so this state machine can be tested without a
    ///   live ONNX session. `CamPlusSpeakerEmbedder.loadModel` is
    ///   `#if !targetEnvironment(simulator) … #else return false`, so on a
    ///   simulator every embedding throws `.runtimeUnavailable` — which made
    ///   three SpeakerVerifierTests cases impossible to pass in CI and left
    ///   the whole suite red for 40+ runs, hiding real breakage elsewhere.
    ///   The production path is byte-identical; only the test target ever
    ///   passes anything else.
    /// - Parameter cohortNormalizer: AS-Norm back-end for
    ///   `computeAsNormScore()` — see that property's kdoc. `nil` by
    ///   default; only `ContactVoiceVerifier` (Tier 2 / Feature B) passes a
    ///   real one, matching Android's `VoicePrintBridgeImpl`-only wiring.
    ///   Every other call site (Tier 1 manual-enrollment-only instances)
    ///   takes the default and is unaffected.
    public init(embedder: any SpeakerEmbedding, cohortNormalizer: SpeakerCohortNormalizer? = nil) {
        self.embedder = embedder
        self.cohortNormalizer = cohortNormalizer
    }

    // MARK: - Manual enrollment (Tier 1 / Feature A)

    public func startEnrollment() {
        lock.lock(); defer { lock.unlock() }
        state = .enrolling
        enrollmentFrames.removeAll()
    }

    /// Feeds one raw PCM frame (Int16, mono, `Self.nativeSampleRate`) into
    /// the enrollment accumulator. Unlike a per-frame feature pipeline,
    /// this does NOT run any per-frame extraction — CAM++ embeds the WHOLE
    /// accumulated buffer at once in `finishEnrollment()`, so this just
    /// converts+buffers the raw samples.
    public func processEnrollmentFrame(_ pcmFrame: Data) {
        lock.lock(); defer { lock.unlock() }
        guard state == .enrolling else { return }
        let floats = Self.pcmToFloat(pcmFrame)
        guard !floats.isEmpty else { return }
        enrollmentFrames.append(floats)
    }

    public func finishEnrollment() -> Bool {
        lock.lock()
        guard state == .enrolling, enrollmentFrames.count >= enrollmentMinFrames else {
            lock.unlock()
            return false
        }
        let frames = enrollmentFrames
        lock.unlock()

        guard let embedding = try? computeEmbedding(from: frames) else {
            lock.lock(); state = .idle; lock.unlock()
            return false
        }
        lock.lock()
        storedTemplate = embedding
        templateVersion += 1
        state = .ready
        lock.unlock()
        return true
    }

    /// Verifies one raw PCM frame against the stored template. Returns raw
    /// cosine similarity in `[-1, 1]`, or `0` if not ready / embedding
    /// fails — matches this method's pre-existing "0 = not a real score"
    /// contract (callers that need to distinguish "no template" from "a
    /// real low score" should check `getState()` first).
    ///
    /// Expensive — runs the FULL CAM++ embedding computation on every call.
    /// Callers on a real-time audio path MUST NOT call this per-frame;
    /// throttle to at most ~1/s (`OwnerContinuityMonitor` does this via its
    /// own ~3s buffering window, never per-frame). For CONTINUOUS
    /// (per-frame) feeding, use `feedVerificationFrame`/
    /// `computeVerificationScore` instead — this method's own inline embed
    /// makes it unsuitable for that cadence.
    public func verify(pcmFrame: Data) -> Float {
        lock.lock()
        guard state == .ready, storedTemplate != nil else { lock.unlock(); return 0 }
        lock.unlock()

        let floats = Self.pcmToFloat(pcmFrame)
        guard !floats.isEmpty else { return 0 }
        guard let embedding = try? computeEmbedding(from: [floats]) else { return 0 }

        // Re-read the template AFTER the (unlocked, potentially slow) embed
        // call — a concurrent reset()/re-enrollment could have changed or
        // cleared it while this was running.
        lock.lock()
        let currentTemplate = storedTemplate
        lock.unlock()
        guard let currentTemplate else { return 0 }
        return cosineSimilarity(currentTemplate, embedding)
    }

    public func getState() -> State { lock.lock(); defer { lock.unlock() }; return state }

    /// Export the enrolled template for external persistence (e.g.
    /// `VoiceprintStore`). `nil` while not yet `.ready`. Callers own what
    /// happens to the returned vector — this class never persists anything
    /// itself.
    public func exportTemplate() -> [Float]? { lock.lock(); defer { lock.unlock() }; return storedTemplate }

    /// Restore a previously-persisted template into a freshly-constructed
    /// verifier so it can serve `verify(pcmFrame:)` calls without
    /// re-running enrollment. Moves straight to `.ready`.
    public func importTemplate(_ template: [Float]) {
        lock.lock()
        storedTemplate = template
        templateVersion += 1
        state = .ready
        lock.unlock()
    }

    /// Resets to `.idle`, clearing every piece of mutable state (mirrors
    /// Android's `reset()`). Does NOT cancel an already-in-flight
    /// auto-enrollment completion (there is no cancellable handle, same as
    /// Android) — that routine detects supersession itself via
    /// `autoEnrollContactId`/`state`, see `completeAutoEnrollment`.
    public func reset() {
        lock.lock()
        state = .idle
        enrollmentFrames.removeAll()
        storedTemplate = nil
        verificationBuffer.removeAll()
        autoEnrollContactId = nil
        cachedVerificationScore = 0.5
        cachedAsNormScore = nil
        lock.unlock()
    }

    // MARK: - Tier 2: auto-enrollment + continuous verification (Feature B, `ContactVoiceVerifier` only)

    /// Starts automatic enrollment for `contactId`. The caller
    /// (`ContactVoiceVerifier`) has already confirmed no stored template
    /// exists for this contact (or chose to force re-enrollment) — this
    /// method never touches persistence itself, matching this class's
    /// existing persistence-agnostic contract (`exportTemplate`/
    /// `importTemplate` already push that job to the caller).
    public func startAutoEnrollment(contactId: String) {
        lock.lock()
        autoEnrollContactId = contactId
        autoEnrollCompletionInFlight = false
        enrollmentFrames.removeAll()
        state = .autoEnrolling
        lock.unlock()
    }

    /// Cheap half of continuous verification — safe to call on every RX
    /// frame (mirrors Android's `feedVerificationFrame`). During
    /// `.autoEnrolling`, VAD-gates PER-FRAME before accumulating (matches
    /// Android: enrollment only needs to pick ~150 individually-good frames
    /// out of a longer stretch, not track a continuously-sliding window).
    /// During `.ready`, accumulates every frame UNCONDITIONALLY into a
    /// sliding window and instead gates the WHOLE window's aggregate energy
    /// at score-compute time (matches Android's `feedVerificationFrameLocked`
    /// exactly — real-device finding: per-frame gating at this granularity
    /// starves the window on ordinary micro-gaps between syllables during
    /// genuine continuous speech). Never calls the expensive embed itself.
    public func feedVerificationFrame(_ pcmFrame: Data) {
        let floats = Self.pcmToFloat(pcmFrame)
        guard !floats.isEmpty else { return }

        lock.lock()
        var pending: PendingAutoEnrollComplete?
        switch state {
        case .autoEnrolling:
            if rms(floats) >= Self.voiceActivityRmsThreshold {
                enrollmentFrames.append(floats)
                if enrollmentFrames.count >= enrollmentMinFrames, !autoEnrollCompletionInFlight,
                   let contactId = autoEnrollContactId {
                    autoEnrollCompletionInFlight = true
                    pending = PendingAutoEnrollComplete(contactId: contactId, frames: enrollmentFrames)
                }
            }
        case .ready:
            verificationBuffer.append(floats)
            if verificationBuffer.count > Self.verificationWindowFrames {
                verificationBuffer.removeFirst()
            }
        case .idle, .enrolling, .verifying:
            break
        }
        lock.unlock()

        if let pending { completeAutoEnrollment(pending) }
    }

    /// Expensive half — recomputes the CAM++ embedding over the ENTIRE
    /// current sliding window and returns the cosine similarity mapped to
    /// `[0, 1]` ("V-score", see class doc), ALSO caching it. `nil` when not
    /// ready / window not yet full / window too quiet — deliberately
    /// distinct from a fabricated `0`/`0.5`, so `ContactVoiceContinuityGate`
    /// can tell "no real score yet" apart from a real low score.
    ///
    /// CALLERS MUST THROTTLE THIS THEMSELVES to ~1/s — see class doc's
    /// thread-safety note for why that budget is what makes holding `lock`
    /// across the embed call here safe.
    public func computeVerificationScore() -> Float? {
        lock.lock(); defer { lock.unlock() }
        guard state == .ready, let template = storedTemplate else { return nil }
        guard verificationBuffer.count >= Self.verificationWindowFrames else { return nil }
        guard aggregateRms(verificationBuffer) >= Self.voiceActivityRmsThreshold else { return nil }
        guard let liveEmbedding = try? computeEmbedding(from: verificationBuffer) else { return nil }

        let similarity = cosineSimilarity(liveEmbedding, template)
        let vScore = min(1.0, max(0.0, (similarity + 1.0) / 2.0))
        cachedVerificationScore = vScore
        cachedAsNormScore = computeAsNormScoreLocked(liveEmbedding: liveEmbedding, template: template, rawScore: similarity)
        return vScore
    }

    /// AS-Norm-normalized companion to `computeVerificationScore()` — a pure
    /// read of the value that method already cached as a side effect of its
    /// ONE embed call, exactly like `verify(pcmFrame:)`'s Tier-1 contract
    /// reads a value someone else already computed. MUST be called AFTER
    /// `computeVerificationScore()` on the same tick, never as a substitute
    /// for it — `computeVerificationScore()` always recomputes the embedding
    /// unconditionally (no "already computed this tick" cache-hit guard, see
    /// its own kdoc and the class-level thread-safety note above for the
    /// real-device lock-contention regression that shape of double-invocation
    /// has caused before), so calling this method first, or on its own, only
    /// ever returns a stale or `nil` value — it never triggers a fresh pass
    /// itself.
    ///
    /// `nil` whenever `computeVerificationScore()` itself was `nil` this tick
    /// (not ready, no template, window not full, silent window), OR no
    /// `cohortNormalizer` was injected, OR its asset failed to load — a
    /// caller MUST fall back to the raw score in that last case, exactly the
    /// same defensive pattern this codebase already uses everywhere a model
    /// asset might be missing. Mirrors Android's `computeAsNormScore()`.
    public func computeAsNormScore() -> Float? {
        lock.lock(); defer { lock.unlock() }
        return cachedAsNormScore
    }

    /// Must be called with `lock` held. `nil` when `cohortNormalizer` is
    /// absent or its asset didn't load. `rawScore` is the SAME cosine
    /// already computed by the caller — this only adds cohort-relative
    /// normalization on top, not a second inference.
    ///
    /// The enroll side (`template`-against-cohort) is memoized against
    /// `templateVersion` — see that property's kdoc — so a long call
    /// re-scoring the same template every tick pays the cohort dot-products
    /// for the LIVE embedding only, not for the template too.
    private func computeAsNormScoreLocked(liveEmbedding: [Float], template: [Float], rawScore: Float) -> Float? {
        guard let normalizer = cohortNormalizer else { return nil }
        guard let testStats = normalizer.cohortStats(liveEmbedding) else { return nil }
        let enrollStats: (mean: Float, std: Float)?
        if cachedEnrollStatsTemplateVersion == templateVersion {
            enrollStats = cachedEnrollStats
        } else {
            enrollStats = normalizer.cohortStats(template)
            cachedEnrollStatsTemplateVersion = templateVersion
            cachedEnrollStats = enrollStats
        }
        guard let enrollStats else { return nil }
        return normalizer.asNormScore(rawScore: rawScore, testStats: testStats, enrollStats: enrollStats)
    }

    // MARK: - Internals

    /// MUST be called with `lock` NOT held — see class doc's thread-safety
    /// note. Only re-acquires `lock` briefly to commit the result, and only
    /// if this contact/attempt is still current (a `reset()` or a new
    /// `startAutoEnrollment()` for a different contact in the meantime
    /// supersedes it — the result is discarded, not corrupted into the new
    /// state). Mirrors Android's `completeAutoEnrollmentAsync` exactly.
    private func completeAutoEnrollment(_ pending: PendingAutoEnrollComplete) {
        let embedding = try? computeEmbedding(from: pending.frames)
        lock.lock()
        defer { lock.unlock() }
        guard autoEnrollContactId == pending.contactId, state == .autoEnrolling else {
            autoEnrollCompletionInFlight = false
            return
        }
        guard let embedding else {
            // Embedding failed (model unavailable/inference error) — stay
            // in .autoEnrolling so a later frame can retry, matching this
            // class's existing "never fabricate a template" discipline.
            autoEnrollCompletionInFlight = false
            return
        }
        storedTemplate = embedding
        templateVersion += 1
        verificationBuffer.removeAll()
        cachedVerificationScore = 0.5
        state = .ready
        autoEnrollContactId = nil
        autoEnrollCompletionInFlight = false
    }

    private func computeEmbedding(from frames: [[Float]]) throws -> [Float] {
        var signal: [Float] = []
        signal.reserveCapacity(frames.reduce(0) { $0 + $1.count })
        for f in frames { signal.append(contentsOf: f) }
        let resampled = Self.resampleTo16k(signal, fromHz: Self.nativeSampleRate)
        return try embedder.embed(pcm16kMono: resampled)
    }

    /// Downsample to 16kHz via simple block-averaging — no anti-alias
    /// filter; acceptable for a speaker-embedding frontend the same way
    /// it's acceptable for the deepfake models that already do this. No-op
    /// if already at 16kHz.
    private static func resampleTo16k(_ signal: [Float], fromHz: Int) -> [Float] {
        guard fromHz != KaldiFbankExtractor.sampleRate, !signal.isEmpty else { return signal }
        let factor = max(fromHz / KaldiFbankExtractor.sampleRate, 1)
        let outLen = signal.count / factor
        guard outLen > 0 else { return [] }
        var out = [Float](repeating: 0, count: outLen)
        for i in 0..<outLen {
            var sum: Float = 0
            let base = i * factor
            for j in 0..<factor { sum += signal[base + j] }
            out[i] = sum / Float(factor)
        }
        return out
    }

    private static func pcmToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        var floats = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let int16Ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<count { floats[i] = Float(int16Ptr[i]) / 32768.0 }
        }
        return floats
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        let dim = min(a.count, b.count)
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<dim { dot += a[i] * b[i]; normA += a[i] * a[i]; normB += b[i] * b[i] }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    /// Root-mean-square energy of one normalized `[-1, 1]` PCM frame.
    private func rms(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for s in frame { sumSquares += s * s }
        return sqrt(sumSquares / Float(frame.count))
    }

    /// RMS across an ENTIRE list of frames (one aggregate value) — see
    /// `feedVerificationFrame` kdoc for why the `.ready` path needs this
    /// coarser granularity instead of per-frame `rms`.
    private func aggregateRms(_ frames: [[Float]]) -> Float {
        var sumSquares: Float = 0
        var count = 0
        for frame in frames {
            for s in frame { sumSquares += s * s }
            count += frame.count
        }
        guard count > 0 else { return 0 }
        return sqrt(sumSquares / Float(count))
    }
}
