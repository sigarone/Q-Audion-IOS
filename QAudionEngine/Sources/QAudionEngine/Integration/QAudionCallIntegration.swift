import Foundation
import CryptoKit

public final class QAudionCallIntegration: @unchecked Sendable {
    /// Call state machine. `connecting` and `ringing` are finer-grained variants
    /// of `outgoingOffering` from the desktop CallController — they let the UI
    /// distinguish between "remote acked our offer" (processing) and "remote is
    /// now ringing" (ready). See bcrypto-server pre-negotiation flow.
    public enum CallState: String {
        case idle
        case capabilitySent
        case negotiating
        case connecting   // caller: remote sent call_processing
        case ringing      // caller: remote sent call_ready (now ringing locally)
        case active
        case fallback
        case error
    }

    private let lock = NSLock()
    private var state: CallState = .idle
    private let engine = QAudionEngine()
    private let pqc = PqcKeyExchange()
    private var localKeyPair: PqcKeyExchange.KeyPair?

    /// Local hybrid keys stashed for the originator path (iOS-as-caller)
    /// of an Android JSON HandshakeBundle handshake. Holds BOTH the
    /// ML-KEM keypair (for `pqc.decapsulate`) AND the ephemeral X25519
    /// private key (for `Curve25519.KeyAgreement.sharedSecretFromKey...`)
    /// so the JSON ACCEPT branch can complete the dual-hybrid combine.
    /// Keyed by callId per OpenRouter glm-5.1 review 2026-05-06 to
    /// avoid the race where two overlapping calls overwrite each other's
    /// privs and the first ACCEPT decapsulates with the wrong material.
    /// Cleared (and zeroized) after the session key is installed.
    private struct HybridLocalKeys {
        let pqcPair: PqcKeyExchange.KeyPair
        let x25519Priv: Curve25519.KeyAgreement.PrivateKey
    }
    private var localHybridKeysByCall: [String: HybridLocalKeys] = [:]

    /// Per-call double-ACCEPT guard. A second ACCEPT for the same call (a retransmit, or a duplicate
    /// delivered over another channel) must not call `engine.initSession` again: the second would
    /// overwrite the first with a different shared secret. This set is consulted before `initSession`
    /// and discards duplicates.
    private var sessionInitializedByCall: Set<String> = []

    /// I3 (2026-08-21) — content-based dedup for the Android-JSON OFFER
    /// responder path (`onAndroidBundleReceived`, `.offer` case). W529's
    /// `sessionInitializedByCall` above answers "have we EVER completed a
    /// handshake for this callId" — correct for the 30s pre-handshake
    /// timeout and the reconnect-replay window, but it cannot distinguish a
    /// byte-identical OFFER *retransmit* (adversarial review 2026-08-21
    /// corrected the original attribution here: Android's app layer is
    /// single-shot for the first handshake — one OFFER, `HANDSHAKE_TIMEOUT`,
    /// then hangup, no resend — and `performReKey` never retries a failed
    /// round either, it just waits for the next periodic tick with a FRESH
    /// keypair. The real source of a byte-identical redelivery is WS/push
    /// message-layer redelivery, e.g. the documented "W-PUSHWAKE
    /// buffered-offer redelivery" incident, call `c74487d2` — see this
    /// file's own W-PQCENTRY comment above `onAndroidBundleReceived`. That
    /// still MUST replay the same cached ACCEPT, never re-derive) from a
    /// genuinely NEW OFFER on the SAME callId carrying fresh ML-KEM/X25519
    /// public keys (a mid-call PQC
    /// re-key — Android's `ReKeyScheduler`/`performReKey`, WIRE_SPEC §3: a
    /// re-key OFFER is byte-identical in *shape* to the first handshake's,
    /// the only way to tell them apart is the key material itself).
    /// Before this fix, every OFFER after the first for a given callId hit
    /// `sessionInitializedByCall`'s callId-only check and was silently
    /// answered by replaying the STALE original ACCEPT, discarding the
    /// re-key's new keys entirely and desyncing the session key from the
    /// peer's. See `docs/security/I3_IOS_REKEY_DESIGN_2026-08-21.md` in the
    /// qaudion-android-new repo (cross-repo doc, not in this repo) for the
    /// full root-cause trace. Keyed by
    /// "<lowercased callId>#<base64 SHA-256(pqcPub || x25519Pub)>", cleared
    /// alongside `sessionInitializedByCall` at call teardown/reuse.
    private var processedOfferFingerprintsByCall: Set<String> = []
    /// ACCEPT wire bundle cached per entry in
    /// `processedOfferFingerprintsByCall`, so a retransmit of THAT SPECIFIC
    /// OFFER round replays the matching ACCEPT bytes — never a different
    /// round's (e.g. a stale retransmit of the ORIGINAL OFFER arriving
    /// after a re-key must still get the ORIGINAL ACCEPT back, not the
    /// re-key's).
    private var acceptWireByOfferFingerprint: [String: String] = [:]

    /// I3 §5 (2026-08-21) — content-based dedup for the CALLER's ACCEPT
    /// processing (`.accept` case), symmetric to
    /// `processedOfferFingerprintsByCall` on the responder side. The old
    /// "Double-ACCEPT guard" deduped by callId alone — harmless while iOS
    /// never re-sent an OFFER as caller, but `performPqcReKey` below now
    /// does exactly that, and a genuine re-key ACCEPT (fresh ciphertext,
    /// same callId) would otherwise hit the callId-only guard and be
    /// silently discarded as "already initialised" — the exact same bug
    /// class §4 fixed on the responder side, mirrored here. Keyed by
    /// "<lowercased callId>#<base64 SHA-256(ct.pqc || ct.x25519)>".
    private var processedAcceptFingerprintsByCall: Set<String> = []

    // MARK: - Transcript v6 — per-call handshake state

    /// This call's own random 64-bit freshness nonce, generated ONCE by `onAndroidCallSetupStarted`
    /// (round 1) and reused (never regenerated) by every `performPqcReKey` round this integration
    /// initiates. In-memory only, keyed by lowercased callId, exactly like `callId` itself is
    /// ephemeral process-lifetime state — never persisted, so a process restart mid-call safely
    /// starts a fresh nonce (and hence a fresh round-1). Cleared in `onCallEnded`.
    private var rekeyNonceByCall: [String: Data] = [:]

    /// This OFFERER's own outgoing round counter, keyed by lowercased callId.
    /// `onAndroidCallSetupStarted` sets it to 1; each `performPqcReKey` round increments it before
    /// building that round's OFFER. Cleared in `onCallEnded`.
    private var rekeyRoundByCall: [String: UInt32] = [:]

    /// The RESPONDER's own `(callId) -> lastAcceptedRound` ratchet: an inbound OFFER whose signed
    /// `rekeyRound` is <= the value stored here is a stale/replayed round and MUST be refused
    /// (never installed, never ACCEPTed). Written only after a signature verified. In-memory only,
    /// cleared in `onCallEnded`.
    private var lastAcceptedRekeyRoundByCall: [String: UInt32] = [:]

    /// The DTLS fingerprint (33 bytes) the PEER presented, pinned ONCE per call (WIRE_SPEC §3.4
    /// step 5): every later bundle (a re-key round) MUST carry the same one, else the call ends.
    /// Keyed by lowercased callId, cleared in `onCallEnded`.
    private var peerDtlsFingerprintByCall: [String: Data] = [:]

    /// R-SLOT: the signed `rekeyRound` of every session key this integration derived, per call
    /// (lowercased callId -> SHA-256(sessionKey) -> round). The key round epoch of a 1:1 call is
    /// `E = rekeyRound - 1`, taken from the round the handshake signed — never from a local
    /// counter, so a round that does not complete leaves a gap on both sides alike. Cleared in
    /// `onCallEnded`.
    private var keyRoundByCall: [String: [Data: UInt32]] = [:]

    /// Remember which signed round produced `key` (called right after the session is initialised,
    /// before any callback announces the key).
    ///
    /// `transcriptHash` is `SHA-256(ACCEPT_v6)` of that round. The SAS of a call is ALWAYS the round-1 SAS
    /// (R-COMMIT-SAS, held or not, before and after any rekey), so only the round-1 session key and
    /// accept hash are kept, in `sasCommit`; every later round leaves the words untouched.
    func recordKeyRound(callId: String, key: Data, round: UInt32, transcriptHash: Data? = nil) {
        let digest = Data(SHA256.hash(data: key))
        lock.withLock { keyRoundByCall[callId.lowercased(), default: [:]][digest] = round }
        if round == 1, let transcriptHash {
            sasCommit.recordRound1(callId: callId, sessionKey: key, acceptHash: transcriptHash)
        }
    }

    /// The signed `rekeyRound` (>= 1) of the handshake round that derived `key`, `nil` when this
    /// integration did not derive it.
    public func keyRound(forSessionKey key: Data, callId: String) -> UInt32? {
        let digest = Data(SHA256.hash(data: key))
        return lock.withLock { keyRoundByCall[callId.lowercased()]?[digest] }
    }

    /// R-SLOT: the key round epoch `E = rekeyRound - 1` (the initial round is E = 0). It selects the
    /// FrameCryptor ring slot (`E mod 16`) and is the `key_epoch` of §8.7 for audio and video alike.
    /// `nil` for a round below 1, which no valid handshake carries.
    public static func keyEpoch(forRekeyRound round: UInt32) -> Int32? {
        guard round >= 1, round - 1 <= UInt32(Int32.max) else { return nil }
        return Int32(round - 1)
    }

    /// True when this call's session key (and therefore its SAS words) is bound to the signed v6
    /// handshake transcript, which contains both signer identity keys and both DTLS fingerprints.
    /// Unconditional for every call that completed the JSON handshake; false only for calls that
    /// never ran it (the earbud-relay counterparty path).
    public func isSessionKeyTranscriptBound(callId: String) -> Bool {
        HandshakeTranscriptHashStore.shared.hash(forCallId: callId) != nil
    }

    /// Call-scoped SAS pin book (identity_unresolved rounds and the signer key the user confirmed by SAS).
    /// See `CallScopedSasPinBook`.
    public let sasPins = CallScopedSasPinBook()

    /// SAS commitment state of the call (WIRE_SPEC §3.7.4, round 1 only): the caller's nonce and
    /// commitment, the callee's stored commitment and REVEAL timer, and the round-1 SAS words.
    public let sasCommit = SasCommitBook()

    /// The 5 s REVEAL timer of each callee call (lowercased callId), armed at the FIRST send of the
    /// round-1 ACCEPT.
    private var sasRevealTimers: [String: Task<Void, Never>] = [:]

    /// The dedup key (`<callId>#<ciphertext fingerprint>`) of the round-1 ACCEPT the caller bound, so a
    /// byte-identical duplicate is recognised and answered with a REVEAL re-send, and any other round-1
    /// ACCEPT is dropped.
    private var boundRound1AcceptKeyByCall: [String: String] = [:]

    /// The signer key of the round that derived `sessionKey` when that round's identity could not be
    /// resolved (`identity_unresolved`) and the user has not confirmed a signer for this call yet. The
    /// app compares it with the stored pin and, on the user's explicit SAS confirmation, pins it
    /// (`confirmSasSigner`). `nil` when the session key's round is unknown or was authenticated.
    public func signerKeyAwaitingSas(callId: String, sessionKey: Data) -> Data? {
        sasPins.signerAwaitingSas(callId: callId, round: keyRound(forSessionKey: sessionKey, callId: callId))
    }

    /// What the user's SAS confirmation of the live round (`sessionKey`) does: `.refused` when the call
    /// is in SAS-PIN conflict (a round its unresolved signer key cannot vouch for), `.adopt(key)` when the
    /// live round was `identity_unresolved` (its signer key is pinned), `.notApplicable` otherwise.
    ///
    /// R-COMMIT-SAS: the words the user compared are ALWAYS the round-1 words, so the key adopted is the
    /// signer of the round whose session key those words derive from (round 1), whichever later same-key
    /// round is live.
    public func sasSignerAdoption(callId: String, sessionKey: Data) -> SasSignerAdoption {
        if sasPins.isConflicted(callId: callId) { return .refused }
        let compared = sasCommit.round1SessionKey(callId: callId) ?? sessionKey
        if let key = signerKeyAwaitingSas(callId: callId, sessionKey: compared) { return .adopt(key) }
        return .notApplicable
    }

    /// The round-1 SAS words of the call (uppercase-agnostic: as in the word list), or `nil` while they
    /// are not available: the caller before it bound an ACCEPT, the callee before a REVEAL verified.
    public func sasWords(callId: String) -> [String]? {
        sasCommit.words(callId: callId)
    }

    /// True while this device is a callee that sent its ACCEPT and still waits for the verified REVEAL:
    /// the UI shows "waiting for the security code" and the SAS confirmation stays disabled.
    public func isSasWaitingForReveal(callId: String) -> Bool {
        sasCommit.isWaitingForReveal(callId: callId)
    }

    /// The user confirmed the SAS words of the round whose signer key is `key`: it is now this call's
    /// pin, so later key rounds of the call verify under it.
    public func confirmSasSigner(callId: String, key: Data) {
        sasPins.confirm(callId: callId, key: key)
    }

    /// R-HELD-REKEY: lowercased callIds whose media is held pending the user's SAS confirmation (any
    /// handshake `.abort` verdict: `identity_unresolved`, `identity_key_mismatch`, ...). While a call is
    /// in this set the caller does not START rekeys; a rekey the peer starts is still answered and
    /// installed (the hold stays). Cleared by `releaseHold` (the confirmation) and when the call ends.
    private var heldCalls: Set<String> = []
    /// R-HELD-REKEY: calls whose caller-side rekey was skipped because the call was held, so the app can
    /// run it as soon as the hold is released.
    private var rekeyDeferredWhileHeld: Set<String> = []

    /// The handshake verdict of a round held this call's media behind the SAS confirmation.
    func markHeld(callId: String) {
        let id = callId.lowercased()
        guard !id.isEmpty else { return }
        lock.withLock { _ = heldCalls.insert(id) }
    }

    /// Test seam (R-HELD-REKEY): make this integration the ACTIVE caller of its call, the state a
    /// scheduled rekey tick finds it in.
    func configureAsActiveCallerForTesting() {
        lock.withLock { isCaller = true; state = .active }
    }

    /// True while the call's media is held pending the SAS confirmation.
    public func isMediaHeld(callId: String) -> Bool {
        lock.withLock { heldCalls.contains(callId.lowercased()) }
    }

    /// The SAS confirmation released the call's media: caller-side rekeys are no longer deferred.
    /// Returns true when a scheduled rekey was skipped while the call was held, i.e. the app should run
    /// one now (the periodic scheduler would otherwise only retry a whole period later).
    @discardableResult
    public func releaseHold(callId: String) -> Bool {
        let id = callId.lowercased()
        return lock.withLock { () -> Bool in
            heldCalls.remove(id)
            return rekeyDeferredWhileHeld.remove(id) != nil
        }
    }

    /// I3 §5 — one in-flight caller-initiated mid-call re-key attempt at a
    /// time (glare-avoidance: `performPqcReKey` only ever runs on the
    /// device that originated the call, mirrors Android's `!isInitiator`
    /// early-return in `performReKey`, `CallController.kt:6879`). Holds the
    /// FRESH ephemeral keypair generated for this round — deliberately
    /// separate from `localHybridKeysByCall`, which is zeroed and removed
    /// right after the ORIGINAL handshake's ACCEPT lands
    /// (`QAudionCallIntegration.swift`, `.accept` case, step 7) and must
    /// stay that way; reusing that slot for a re-key would risk a stale
    /// retransmit of the ORIGINAL ACCEPT decapsulating against the WRONG
    /// (re-key) private key. `resume` resolves the awaiting continuation
    /// exactly once — whichever of {a matching ACCEPT arrives, the attempt
    /// times out} fires first; the loser is a no-op because both paths
    /// clear `pendingReKeyAttempt` before calling `resume`.
    private struct PendingReKeyAttempt {
        let id: UUID
        let localKeys: HybridLocalKeys
        let resume: (Data?) -> Void
    }
    private var pendingReKeyAttempt: PendingReKeyAttempt?

    private var transportSelector: TransportSelector?
    private var capabilityExchange: QAudionCapabilityExchange?
    private let guardianMode = GuardianMode()
    private let voiceAnalysis = VoiceAnalysisEngine()
    /// Unified call UI — REAL remote-voice spectrum extractor (40 log-spaced
    /// bands over the decoded RX PCM, port of Android's SpectrumExtractor.kt).
    /// Fed inside `processIncomingAudio` on the SAME thread that already runs
    /// `guardianMode.processFrame` — no extra dispatch, no Task per frame
    /// (2026-07-04 never-block rules).
    private let spectrumExtractor = SpectrumExtractor()
    /// Monotonic uptime (ns) of the last spectrum compute — 66 ms source
    /// throttle so `onVoiceSpectrum` fires at ≤15 Hz regardless of the
    /// ~50 fps RX frame rate. Touched only on the RX processing thread
    /// (same single-thread contract as the extractor itself).
    private var lastSpectrumUptimeNs: UInt64 = 0
    /// Feature B ("voce verificata") — the in-flight per-contact
    /// call-time voice-learning session, if the user tapped "Avvia
    /// apprendimento voce" for THIS call. nil most of the time. Fed inside
    /// `processIncomingAudio` on the SAME thread as `guardianMode`/
    /// `voiceAnalysis` above — same never-block, no-extra-dispatch rule.
    private var voiceLearningSession: VoiceLearningSession?

    // MARK: - W-IOSAUDIOSTARVE (2026-08-02) — analysis off the audio path
    //
    // `processIncomingAudio` used to run the ENTIRE analysis stack inline,
    // synchronously, once per 20 ms RX frame: guardianMode.processFrame,
    // contactVoiceVerifier.feedContinuous, voiceLearningSession.processRxFrame,
    // voiceAnalysis.processFrame and spectrumExtractor.compute, on top of the
    // unseal + AES-GCM open + Opus decode that function already owes. And
    // `CallService` invokes the whole chain from `DispatchQueue.main.async`.
    //
    // The main queue is also what refills the playout node, and that node
    // holds `playoutInFlightTarget = 2` buffers = 40 ms. So any main-queue
    // hitch longer than 40 ms renders literal silence at the speaker — and it
    // is not even counted as a jitter-buffer underrun, because `pop()` is
    // never reached. At 50 frames/s the analysis stack had to fit in under
    // 20 ms every time, forever, with zero headroom.
    //
    // Measured on device 2026-08-02: choppy audio on iOS<->iOS calls as well
    // as Android->iOS (so NOT an interop problem — the receiver is the common
    // factor), with the handset becoming very hot, i.e. sustained CPU
    // saturation. The Android sender was verified clean in the same session
    // (MEDIADIAG tx enc+250 sent+250 every 5 s, zero DataChannel backpressure
    // drops, no transport oscillation), and Android->Android was fine because
    // Android had already fixed this exact class of bug one day earlier in
    // commit 074b8898, "spread voice-analysis CPU load to stop audio
    // starvation".
    //
    // The old comments here ("no extra dispatch, no Task per frame", "the
    // exact flood pattern that froze Android") were guarding against the
    // right hazard and drew the wrong conclusion: they removed per-frame
    // DISPATCH but kept per-frame WORK on the audio thread, which is the part
    // that actually starves playout. The fix is not to dispatch less, it is
    // to do less ON THIS THREAD.
    //
    // Now: `processIncomingAudio` decodes and returns. A copy of the PCM goes
    // into a bounded drop-oldest ring drained on the serial queue below.
    // Dropping under load is correct and deliberate — every consumer here is
    // an advisory UI/telemetry signal that self-throttles anyway; none of them
    // is a security gate, and none is worth a silent gap in the call audio.

    /// Serial queue owning every RX analysis consumer. `.utility` so it can
    /// never preempt audio; serial so the consumers keep the single-threaded
    /// contract their own docs already assume.
    private let rxAnalysisQueue = DispatchQueue(label: "qaudion.rx.analysis", qos: .utility)

    /// Bounded backlog of decoded RX PCM awaiting analysis. Guarded by
    /// `rxRingLock`; never grows past `rxRingCapacity` (oldest is dropped).
    private var rxRing: [Data] = []
    private let rxRingLock = NSLock()
    /// ~200 ms at 50 fps. Deep enough to ride out a scheduling hiccup on the
    /// analysis queue, shallow enough that analysis can never lag the call by
    /// a perceptible amount and start reporting stale state.
    private let rxRingCapacity = 10
    /// True while a drain is already scheduled — keeps the queue from being
    /// flooded with 50 no-op work items per second.
    private var rxDrainScheduled = false
    /// Tier 1 ("voce come chiave") — TX-side continuous owner-continuity
    /// self-check. Fed inside `processOutgoingAudio`, pre-encode, from the
    /// LOCAL mic — never RX/remote audio. Silently stays `.inactive`
    /// whenever no Voice-as-Key template is enrolled. Built in `init()`
    /// (needs a `SpeakerVerifier` pre-loaded with the owner's stored
    /// template, if any) and started there too.
    private let ownerContinuityMonitor: OwnerContinuityMonitor
    /// Tier 2 ("voce remota") — RX-side continuous per-contact
    /// verification. Activated via
    /// `activateContactVoiceVerification(contactId:)` once the call's peer
    /// is known; fed inside `processIncomingAudio` UNCONDITIONALLY (a cheap
    /// no-op with no active contact — see `ContactVoiceVerifier
    /// .feedContinuous`).
    private let contactVoiceVerifier = ContactVoiceVerifier()
    private var sendOpaque: ((Data) async throws -> Void)?
    private var resolvedBcryptoUserId: String?
    private var bcryptoUserIdCache: [String: String] = [:]  // recipientId -> BCrypto userId
    /// Tracks whether this client is the caller (true) or responder (false) for the
    /// current call. Used to gate pre-negotiation event handling.
    private var isCaller: Bool = false

    /// W-REKEYDISPSYNC (2026-09-11) — thread-safe read of [isCaller] for
    /// callers outside this class (AppState's confidence-feed gate). Mirrors
    /// Android's `CallController.currentIsInitiator()`. Same value
    /// `performPqcReKey`'s own guard already enforces — this just lets a
    /// caller check it BEFORE doing work that would otherwise be wasted on
    /// the responder leg (see that property's own doc for why responder-side
    /// confidence has no effect on a real re-key).
    public var currentIsCaller: Bool { lock.withLock { isCaller } }

    /// W574x — go-live gate for directional per-direction PQC RTP sealer keys
    /// (fixes the bidirectional AES-GCM nonce reuse on the relay path). Mirrors
    /// Android `PqcHandshake.SRTP_DIR_KEYS_ENABLED` / Desktop
    /// `AndroidBundleHandshake.SRTP_DIR_KEYS_ENABLED`.
    public static let srtpDirKeysEnabled = true

    /// MEDIA-3/MEDIA-4/MEDIA-5 (2026-09-02 protocol audit, backlog item 4) go-live
    /// gate for the inner sealed-audio wire's per-direction keys + AAD + replay
    /// window (`QAudionEngine.initSession`'s `innerAudioAadV1` param). Mirrors
    /// this platform's own `srtpDirKeysEnabled` pattern directly above, and
    /// Android/Desktop's equivalent constant for the
    /// SAME capability bit — grep either sibling repo for `innerAudioAadV1` or
    /// `INNER_AUDIO_AAD_V1_ENABLED` before flipping this.
    ///
    /// DEFAULT FALSE. This bit's exact construction (HKDF info-string pair,
    /// AAD byte layout, replay-window shape — see `QAudionEngine.swift`'s
    /// `W-INNERAUDIOAAD` block) was implemented on iOS alone in this session,
    /// with no live cross-platform KAT against Android/Desktop's own
    /// implementations of the same audit finding: a mismatched
    /// construction under the same wire capability bit position would make
    /// two peers that both advertise it derive different directional keys
    /// from each other, breaking the call (not a security downgrade — the
    /// call simply stops decrypting audio). Flip to `true` only after a real
    /// cross-platform KAT reconciliation pins one byte layout and all three
    /// platforms implement that exact layout.
    public static let innerAudioAadV1Enabled = false

    /// W574x — whether the PEER advertised `srtpDirKeyV1` in its last received
    /// OFFER/ACCEPT bundle (set in `onAndroidBundleReceived`, before
    /// `onRelaySessionReady` fires).
    private var peerAdvertisedSrtpDirKey: Bool = false

    /// MEDIA-3/4/5 — whether the PEER advertised `innerAudioAadV1` in its last
    /// received OFFER/ACCEPT bundle. Same set-site/timing as
    /// `peerAdvertisedSrtpDirKey` immediately above.
    private var peerAdvertisedInnerAudioAad: Bool = false

    /// W574x — directional sealer keys are used only when BOTH peers advertise
    /// support. Read by AppState at relay-sealer install time.
    public var negotiatedSrtpDirKey: Bool {
        Self.srtpDirKeysEnabled && peerAdvertisedSrtpDirKey
    }

    /// MEDIA-3/4/5 — the inner sealed-audio wire's per-direction-key/AAD/
    /// replay-window scheme is used only when BOTH peers advertise support
    /// (same AND-negotiation shape as `negotiatedSrtpDirKey`). Read internally
    /// at the `engine.initSession(...)` call sites below; with the kill
    /// switch off this is always `false` regardless of what any peer sends.
    public var negotiatedInnerAudioAadV1: Bool {
        Self.innerAudioAadV1Enabled && peerAdvertisedInnerAudioAad
    }

    /// MEDIA-3/4/5 — resolves THIS device's own user id, needed to compute
    /// `PqcRtpFrameSealer.selfIsRoleA(selfUserId:peerUserId:)` for the inner
    /// sealed-audio wire's per-direction key assignment (same role rule the
    /// outer M-15 sealer already uses — see `AppState.installRelaySealers`'s
    /// callers). `QAudionCallIntegration` has no notion of the app-level
    /// signed-in user itself; AppState wires this closure once at integration
    /// construction time, mirroring how it already resolves `currentUserId`
    /// for the outer sealer's own `selfIsRoleA` computation. `nil`/unset (or
    /// throwing) resolves to `""`, which is a safe, deterministic (if
    /// arbitrary) fallback role — inert in practice since the kill switch
    /// above keeps `negotiatedInnerAudioAadV1` false regardless.
    public var resolveSelfUserId: (() -> String)?

    /// W-STALESEALER (2026-09-26, fix-3) — resolves `CallService`'s monotonic
    /// call-generation counter (`currentCallGeneration()`), same wiring pattern
    /// as `resolveSelfUserId` above: AppState sets this once, at integration
    /// construction time, on BOTH the responder and the caller integration.
    ///
    /// Read exactly once per inbound handshake message, at the very TOP of
    /// `onAndroidBundleReceived` / `onCapabilityMessageReceived` /
    /// `completeEarbudCounterparty` — before any `await` in the async ones —
    /// and threaded from there through `fireRelaySessionReady`/
    /// `onRelaySessionReady`'s new `generation` parameter. This is NOT the same
    /// thing as reading it when `onRelaySessionReady` actually fires: some
    /// paths (`onAndroidBundleReceived`'s `.offer` case) `await` a network send
    /// BEFORE firing, so a call could end DURING that await — reading the
    /// generation only when the closure finally runs would then sample the
    /// POST-teardown value, which happens to still "match" whatever
    /// `installRelaySealers` compares it against later, silently resurrecting
    /// a sealer for a call that ended before this handshake message even
    /// finished being processed. Reading it here, at the moment processing of
    /// this specific message STARTS (before any await gives `endCall()` a
    /// chance to run), is what actually names a live call.
    ///
    /// `nil`/unset resolves to `-1`, a value no real generation (which starts
    /// at 0 and only increases) can ever equal — so an unwired closure fails
    /// CLOSED (every install for that call is dropped) rather than open.
    public var provideCallGeneration: (() -> Int)?

    /// Phase 18 — whether THIS build advertises the v4 PQ ratchet (`ratchetV4`)
    /// capability. Mirrors Android `selfCapabilities().ratchetV4 =
    /// MessageRatchet.V4_NATIVE_RATCHET_ENABLED && RatchetNative.available`
    /// (`PqcHandshake.kt:477`): we only signal v4 when the flag is ON and the real
    /// native core is linked, so we never claim v4 against a stub build that would
    /// fail-close `bootstrapV4AndPersist`. Folded into OFFER + ACCEPT capabilities.
    /// NOT part of the signed CAPS triplet (`ratchetV3,sframeV1,vkeyV1`), so adding
    /// it never perturbs the Ed25519 handshake signature.
    public static var advertisesRatchetV4: Bool {
        MessageRatchet.v4NativeRatchetEnabled && RatchetNative.available
    }

    /// Phase 18 — whether the PEER advertised `ratchetV4` in its last received
    /// OFFER/ACCEPT bundle (set in `onAndroidBundleReceived`, before the v4
    /// bootstrap fires). The v4 session is bootstrapped/used ONLY when BOTH ends
    /// advertise v4 — the same `self && peer` negotiation Android applies
    /// (`PqcHandshake.negotiate`: `ratchetV4 = self.ratchetV4 && safePeer.ratchetV4`).
    /// Without this AND, a one-sided v4 (iOS bootstraps, Android stays v3) would
    /// emit 0xE5 frames the peer routes to v3/v2 and cannot decrypt.
    private var peerAdvertisedRatchetV4: Bool = false

    /// Phase 18 — v4 is engaged only when BOTH peers advertise it (negotiated AND).
    public var negotiatedRatchetV4: Bool {
        Self.advertisesRatchetV4 && peerAdvertisedRatchetV4
    }

    // MARK: - W529 / W531: handshake retry & WS-reconnect replay state

    /// Last serialized OFFER wire bundle (`"<callId>|<JSON>"`) actually
    /// shipped by `onAndroidCallSetupStarted`. Stashed BEFORE the timer
    /// arms so a retry uses byte-identical bytes (same callId, same
    /// PQC public keys) — the responder must produce a deterministic
    /// re-ACCEPT keyed off these bytes.
    private var lastSentOfferWire: String?
    /// Last serialized ACCEPT wire bundle. Re-emitted on duplicate OFFER
    /// (so re-derivation doesn't happen and the caller decapsulates
    /// against the SAME ciphertext we already committed to).
    private var lastSentAcceptWire: String?
    // MARK: - W-MEDIAATACCEPT (option b) — I11: held responder ACCEPT

    /// One held (not-yet-sent) responder ACCEPT per call, captured at the
    /// moment the handshake computed it: the JSON (AndroidHandshakeEnvelope)
    /// wire. Released by `releaseHeldAccept(callId:)`, dropped by
    /// `dropHeldAccept(callId:)`/`onCallEnded()`.
    enum HeldAccept {
        case json(String)
    }
    private var heldAcceptByCall: [String: HeldAccept] = [:]

    /// Wired by AppState to `RingSignalingRegistry.shared.shouldHoldAccept(_:)`.
    /// `nil` (a caller-side integration instance, or a unit test that never
    /// wires it) never holds — every emission point below degrades to
    /// today's immediate-send behavior.
    public var shouldHoldResponderAccept: ((String) -> Bool)?
    /// Timestamp of the first OFFER/ACCEPT send for this call. Used to
    /// bound retries within the handshake window (default 30 s).
    private var handshakeStartedAt: Date?
    /// Captured caller-side sender closure so the W529 retry timer can
    /// re-emit without AppState plumbing each retry through.
    private var retrySenderClosure: ((String) async throws -> Void)?
    /// W529 retry task — fires at 5 s intervals up to handshakeTimeout.
    private var offerRetryTask: Task<Void, Never>?
    /// W-HSRINGDRIFT (2026-07-28) — MUST outlast the RING window, or a slow
    /// pickup silently produces a call with no session key.
    ///
    /// This was 30 s while the ring window is 45 s (Android's ring timeout is
    /// `OUTGOING_RING_TIMEOUT_MS = 45_000`, and iOS's own group ring in
    /// `armGroupCallRingTimeout` is likewise 45 s). The PQC await therefore
    /// expired FIFTEEN SECONDS BEFORE the phone stopped ringing: answer after a
    /// short hesitation and the transport still comes up on its own (ICE
    /// completes, the UI flips to connected) while the key exchange has already
    /// been abandoned — no decoded media, "Connecting…" forever on the other
    /// side. User-reported 2026-07-28 ("ho risposto con un po' di ritardo e non
    /// ha completato lo scambio chiavi"); Android carried the identical drift
    /// at 35 s and is fixed in the same pass (PqcHandshake.HANDSHAKE_TIMEOUT).
    ///
    /// 50 s = 45 s ring + 5 s margin, matching Android exactly. Unanswered
    /// calls are unaffected: the ring timeout still fires first and tears the
    /// call down, cancelling this await. Retune BOTH sides together or the
    /// invariant breaks again the same silent way.
    public let handshakeTimeoutSec: Double = 50.0
    public let offerRetryIntervalSec: UInt64 = 5
    /// Tracks whether the local UI/CallKit alert is already ringing for an
    /// incoming call. Lets `onCallRingReceived` (server "we told the caller you
    /// are ringing" ACK) fire a fallback ring only if setup was async-slow.
    private var isLocallyRinging: Bool = false

    public var onStateChanged: ((CallState) -> Void)?
    public var onDeepfakeAlert: ((ConfidenceIndex.Level, Float) -> Void)?

    /// Unified call UI — fires ≤15 Hz with the REAL 40-band (0..1)
    /// log-magnitude spectrum of the decoded remote voice (RX PCM), computed
    /// by `SpectrumExtractor` inside `processIncomingAudio`. Same wiring
    /// pattern as `getVoiceAnalysis().onResult`: CallService forwards it to
    /// AppState, which hops to MainActor for the `@Published` write. Invoked
    /// SYNCHRONOUSLY on the RX processing thread — the sink must stay cheap
    /// and non-blocking (2026-07-04 never-block rules). While nil the FFT is
    /// skipped entirely (zero cost).
    public var onVoiceSpectrum: (([Float]) -> Void)?

    /// Feature B ("voce verificata") — fires whenever the in-flight
    /// `VoiceLearningSession` (see `startVoiceLearning(contactId:)`)
    /// changes state, INCLUDING every progress tick while `.inProgress`.
    /// nil sink ⇒ no session running ⇒ zero overhead (the RX tap still
    /// runs the guardian/voiceAnalysis work either way; only the extra
    /// `voiceLearningSession.processRxFrame` call is skipped, see
    /// `processIncomingAudio`). Invoked synchronously on the RX thread —
    /// same never-block contract as `onVoiceSpectrum`.
    public var onVoiceLearningStateChanged: ((VoiceLearningSession.State) -> Void)?

    /// Tier 1 ("voce come chiave") — fires whenever the TX-side owner-
    /// continuity self-check produces a new state. Invoked on
    /// `OwnerContinuityMonitor`'s OWN private queue, NOT the caller's
    /// thread (a deliberate difference from `onVoiceSpectrum`/
    /// `onVoiceLearningStateChanged` above, which fire synchronously on the
    /// RX/TX audio thread) — see that class's `onStateChanged` kdoc for
    /// why. Hop to your own thread before touching UI state.
    public var onOwnerContinuityStateChanged: ((OwnerContinuityMonitor.State) -> Void)?

    /// Tier 2 ("voce remota") — fires whenever the RX-side per-contact
    /// continuity gate's level changes. Same cross-thread contract as
    /// `onOwnerContinuityStateChanged` above (fires on
    /// `ContactVoiceVerifier`'s own private queue).
    public var onContactVoiceLevelChanged: ((ContactVoiceContinuityGate.Level) -> Void)?

    /// "Interlocutore cambiato" — fires when the receive-side change verdict
    /// actually changes. Informational: no muting, no teardown, no key
    /// action follows from it.
    public var onSpeakerChangeVerdict: ((RemoteSpeakerChangeMonitor.Verdict) -> Void)?

    /// Record the far end's own receive-side verdict about this device's
    /// user, as delivered over the `SPKCHG` control piggy-back.
    public func peerReportedSpeakerChange(_ changed: Bool) {
        contactVoiceVerifier.peerReportedSpeakerChange(changed)
    }

    /// Re-anchor the change detector after a media-path switch — see
    /// `ContactVoiceVerifier.acousticPathChanged` for why a path change must
    /// not be reported as a person walking in.
    public func acousticPathChanged() {
        contactVoiceVerifier.acousticPathChanged()
    }
    /// MASVS-CRYPTO remediation (2026-08-20/21) — see
    /// `ContactVoiceVerifier.onScoreUpdated` kdoc. Feeds `ReKeyScheduler`.
    public var onContactVoiceScoreUpdated: ((Float) -> Void)?
    /// W-GUARDIAN3SIG (2026-09-11) — pass-through of
    /// `ContactVoiceVerifier.onScoreBreakdown`. Diagnostics only.
    public var onContactVoiceScoreBreakdown: ((Float, Float, Float, Float) -> Void)?

    /// W389 — fired the moment the ML-KEM-1024 PQC handshake completes
    /// successfully on EITHER side (caller `case .accept` after
    /// `decapsulate`, responder `case .offer` after `encapsulate`). The
    /// 32-byte shared secret is exactly the value that
    /// `QAudionEngine.initSession(sharedSecret:)` is initialised with —
    /// i.e. the real session key — and is the cross-platform-stable
    /// input the SAS computation must use for parity with Android.
    ///
    /// App layer is expected to forward this into
    /// `CallSessionKeyBroker.shared.registerPqcSessionKey(_:for:)` so
    /// `AppState.callPqcSessionKey` swaps from the W369 transitional
    /// PSK-derived seed to the real ML-KEM secret. Once that swap
    /// happens the SAS panel re-renders with PQC-derived words, and any
    /// previously stored verification under the transitional fingerprint
    /// is auto-invalidated by `SasVerificationStore` (different
    /// fingerprint = new verification required).
    ///
    /// Fires at most once per call. The integration does not retain
    /// the secret; the caller is responsible for lifecycle.
    public var onPqcSessionKeyEstablished: ((Data) -> Void)?

    /// W-MEDIAATACCEPT (option b) — §4.5/§6: fires alongside EVERY
    /// ``onPqcSessionKeyEstablished`` call (responder and caller), carrying
    /// the `callId` that closure alone does not — `CallKeyStore` needs it
    /// to isolate the key per call rather than trusting a single shared
    /// slot. AppState wires this to `CallKeyStore.shared.put(callId:key:)`
    /// plus a refresh of the `callPqcSessionKey` read projection. No-op
    /// when nil (e.g. in unit tests that don't wire it).
    public var onSessionKeyForCall: ((Data, String) -> Void)?

    /// DISPLAY-ONLY companion to ``onPqcSessionKeyEstablished``. Fires the
    /// SAME 32-byte session key PLUS the negotiated sovereign-PSK
    /// fingerprint (the value mixed into the HKDF, see `selectedFp` on the
    /// responder OFFER path and `bundle.selectedPskFingerprint` on the
    /// caller ACCEPT path). `pskFingerprint == nil` ⇒ no PSK was mixed.
    /// The app layer resolves the human name + method label from this
    /// fingerprint via its own `SovereignKeyVault` (the engine has no
    /// vault-name in scope here — it only receives `eligiblePsks` keyed by
    /// fingerprint). Primitives only (Data + String?) so the AppState type
    /// never enters a parameter position (build landmine #16). Pure UI
    /// surface — does NOT affect any derivation. No-op when nil.
    public var onPqcSessionKeyEstablishedWithPsk: ((Data, String?) -> Void)?

    /// W-REKEYSYNC (2026-09-10) — fires ONLY on the RESPONDER leg of a
    /// re-key round (never round 1, never the initiator leg — this device
    /// already knows its own armed period there) when the inbound OFFER
    /// carried a validated `rekeyNextPeriodMs`. The app layer uses this to
    /// arm its own `ReKeyScheduler` from the SAME real deadline the
    /// initiator is acting on (`start(syncedDeadlineMs:syncedPeriodMs:)`),
    /// instead of continuing to display an independent local guess. See
    /// `AndroidHandshakeBundle.rekeyNextPeriodMs`'s doc for the full
    /// rationale and the live divergence this closes. DISPLAY-ONLY — never
    /// gates the actual re-key, which has already completed by the time
    /// this fires.
    public var onPeerRekeyPeriodAdvertised: ((Int64) -> Void)?

    /// Phase 18 — v4 bootstrap signal. Fires at every JSON handshake-completion
    /// site (OFFER accepted = responder, ACCEPT decapsulated = originator) AFTER
    /// ``onPqcSessionKeyEstablished``. Carries
    /// `(peerId, effectiveSecret, transcriptHash, selfIdentityPub, peerIdentityPub)`
    /// so the app layer can call
    /// ``MessageRatchet/bootstrapV4AndPersist(peerId:effectiveSecret:…)`` with the
    /// SAME §2.5 / chain-derivation inputs Android passes
    /// (`PqcHandshake.kt:894-901`), without needing access to the raw handshake
    /// internals:
    ///   - `transcriptHash` = the offer_binding (`SHA-256(offerTranscript)`) — the
    ///     responder's verified-OFFER binding, the initiator's sent-OFFER binding.
    ///   - `selfIdentityPub` = THIS device's raw 32-byte Ed25519 identity
    ///     (`localSignerIdentityKey`, == Android `handshakeSigner.localIdentityKey()`).
    ///   - `peerIdentityPub` = the OTHER device's raw 32-byte Ed25519 identity (the
    ///     bundle's `signerIdentityKey`, base64-decoded — the OFFER's on the
    ///     responder leg, the ACCEPT's on the initiator leg).
    /// The native bootstrap mixes `transcriptHash` into chain-key derivation and
    /// uses the two identity pubkeys for the §2.5 lex-order (is_lex_min → chain
    /// direction), so these MUST byte-match Android's — which they do, because they
    /// are the SAME values the shared signed-handshake binding already produces.
    /// Only fires on the signed JSON (AndroidHandshakeBundle) handshake. The integration SKIPS
    /// the fire (passes nothing) when any real input is missing (no signed
    /// handshake), so there is no v4 bootstrap rather than a divergent placeholder
    /// session. No-op when nil.
    public var onV4BootstrapReady: ((String, Data, Data, Data, Data) -> Void)?

    /// W574g — fires (sessionKey, callId) at EVERY session-init site, the
    /// instant the engine session key is set. The app wires this to
    /// `CallService.installRelaySealers` so the M-15 WS-relay sealer is
    /// installed deterministically on BOTH caller and callee.
    ///
    /// Why this and not `onPqcSessionKeyEstablished` + AppState guards:
    /// the responder's `onPqcSessionKeyEstablished` install was gated on
    /// `AppState.callContactId == peerId`, but on the CALLEE that flag is
    /// set in the call_incoming main-async block which RACES the inbound
    /// OFFER Task — when the OFFER's handshake completed first the install
    /// was skipped, so Android→iOS relay audio failed 100% AEAD decode
    /// (call 456c1a40: rx_dec_err=597/597) while iOS→Android worked (call
    /// ca28b4af, caller sets callContactId synchronously). This callback
    /// carries the callId from the handshake itself (race-free) and fires
    /// unconditionally, so caller and callee install identically.
    /// W-STALESEALER (2026-09-26, fix-3) — third parameter is the call
    /// generation `provideCallGeneration?()` returned at the START of
    /// processing the handshake message that produced this session key (see
    /// that property's doc). AppState passes it straight through to
    /// `CallService.installRelaySealers(expectedGeneration:)` instead of
    /// re-reading the generation itself when this closure runs.
    public var onRelaySessionReady: ((Data, String, Int) -> Void)?

    /// W-M15SEALERONCE (2026-09-20) — true ONLY while ``onRelaySessionReady`` is
    /// being invoked for a RE-KEY round (mid-call session-key rotation), false
    /// for the call's first handshake. The M-15 outer relay seal is a
    /// call-lifetime object bound to the FIRST handshake's key on every
    /// platform (Android installs it exactly once per call:
    /// `CallController.outerSealersInstalledOnce`); a re-key rotates the INNER
    /// audio key only. Re-deriving the outer pair here while the peer keeps its
    /// original one made both directions fail the M-15 open (`unseal
    /// failed/replay`) right after every re-key -- live call ab7f643b, 21:47:39Z:
    /// 100% of Android's frames dropped on iOS and 0 arriving on Android, until
    /// the call was hung up. The callback reads this flag SYNCHRONOUSLY, before
    /// it hops to another actor.
    public var relaySessionReadyIsReKey: Bool {
        lock.withLock { _relaySessionReadyIsReKey }
    }
    private var _relaySessionReadyIsReKey: Bool = false

    /// Fires ``onRelaySessionReady`` with ``relaySessionReadyIsReKey`` set for
    /// the duration of the call. `generation` is passed straight through to
    /// the callback — see ``provideCallGeneration``'s doc for why the CALLER
    /// of this function must have captured it at the start of processing the
    /// current handshake message, not read it fresh here.
    func fireRelaySessionReady(_ sessionKey: Data, callId: String, isReKey: Bool, generation: Int) {
        lock.withLock { _relaySessionReadyIsReKey = isReKey }
        onRelaySessionReady?(sessionKey, callId, generation)
        lock.withLock { _relaySessionReadyIsReKey = false }
    }

    /// W-KCMAC (multi-PSK-mixing SYNTHESIS.md ship step 5) — everything AppState
    /// needs to run the `KCMAC:` piggy-back exchange, fired at the SAME two
    /// handshake-completion sites as ``onPqcSessionKeyEstablished``
    /// (responder's OFFER-accept and initiator's ACCEPT-decapsulate), AFTER it.
    /// `N` stays ≤1 and nothing here reads/writes `PskMix` mixing state. AppState ends the
    /// call (`kcmac_mismatch`) when the peer's MAC of a round does not verify. `kcKey`/`transcript`
    /// are `nil` when the reconstructed offer/accept transcripts or either identity key aren't
    /// available — AppState must treat that as "kc_mac not attempted" (status `.absent`), never
    /// attempt to derive a MAC from empty/placeholder bytes.
    public struct KcMacReadyEvent {
        /// The other party in this call (regardless of who dialled).
        public let peerId: String
        public let callId: String
        /// `true` on the caller/initiator leg (sends `kc_mac_init`, verifies the
        /// peer's `kc_mac_resp`); `false` on the responder leg (the converse).
        public let isInitiator: Bool
        /// The post-PSK-mix session key (`K_kc = HKDF-Expand(sessionKey, …)`'s PRK).
        public let sessionKey: Data
        /// `K_kc`, already derived — `nil` when a transcript couldn't be built.
        public let kcKey: Data?
        /// `kc_transcript` — `nil` alongside `kcKey`.
        public let transcript: Data?
        /// Number of secrets mixed into this call's session key (`0` or `1` — `N`
        /// stays capped this step; see `KeyConfirmation`'s doc).
        public let n: Int
        /// Whether the PEER's own handshake capabilities advertised `pskMixV1` —
        /// the KCMAC wire exchange is gated on this (see the type doc).
        public let peerSupportsMix: Bool
        /// Whether THIS call's OFFER/ACCEPT Ed25519 transcript signature verified
        /// (`AssuranceState.decide`'s `sigOk` input).
        public let sigOk: Bool
        /// The peer's advertised per-fingerprint PSK roles, PRE-FILTERED to
        /// fingerprints this side also holds (`AssuranceState.decide`'s
        /// `peerAdvertisedRoles` input — this function does the fp-matching so
        /// `decide()` itself stays a pure function with no vault access).
        public let peerAdvertisedRoles: [Int]
        /// W-NFCBADGE — the hex fingerprint of the ONE PSK actually selected
        /// for this call's session-key mix (`selectedFp`/`selectedFpStr` at
        /// the two call sites below), `nil` when `n == 0`. This is the SAME
        /// string `AppState.resolvePskDisplayMeta(fingerprint:)` already
        /// resolves to a vault entry — carried here so the app layer can look
        /// up that entry's `PskOrigin` (NFC vs everything else) without a
        /// second, divergent selection computation. Local-only: never
        /// serialized to the wire, no capability flag.
        public let selectedFp: String?
        /// The signed `rekeyRound` (>= 1) of the key round this event arms. Round 1 has the longer KCMAC waits of
        /// `KcMacWindow` (A1 caller, A5 callee); every later round waits 5 s.
        public let round: UInt32

        public init(
            peerId: String, callId: String, isInitiator: Bool, sessionKey: Data,
            kcKey: Data?, transcript: Data?, n: Int, peerSupportsMix: Bool,
            sigOk: Bool, peerAdvertisedRoles: [Int], selectedFp: String? = nil, round: UInt32 = 1
        ) {
            self.peerId = peerId
            self.callId = callId
            self.isInitiator = isInitiator
            self.sessionKey = sessionKey
            self.kcKey = kcKey
            self.transcript = transcript
            self.n = n
            self.peerSupportsMix = peerSupportsMix
            self.sigOk = sigOk
            self.peerAdvertisedRoles = peerAdvertisedRoles
            self.selectedFp = selectedFp
            self.round = round
        }
    }
    public var onKcMacReady: ((KcMacReadyEvent) -> Void)?

    /// A2 — a newer round-1 OFFER replaced the unanswered one (the ACCEPT was never sent): the app drops what it
    /// queued or installed for the replaced round (deferred ring-time actions, the ring key, the identity gate).
    public var onUnansweredRound1Superseded: ((String) -> Void)?

    /// Set a BCryptoRestClient to enable userId pre-resolution before OFFER.
    /// Without this, OFFERs use the raw recipientId which may cause server routing failures.
    public var restClient: BCryptoRestClient?

    // MARK: - Pre-negotiation hooks (Android/Desktop interop)

    /// Send `call_processing` to the caller — invoked when this client (responder)
    /// receives a PQC OFFER. App layer wires this to BCryptoCallingApiImpl.
    /// Signature: (callId, callerId) -> Void
    public var sendCallProcessing: ((String, String) -> Void)?

    /// Send `call_ready` to the caller — invoked after PQC OFFER deserialisation
    /// completes on the responder side.
    public var sendCallReady: ((String, String) -> Void)?

    /// Triggered when an inbound call should start ringing locally (CallKit alert
    /// or AVAudioSession + UI notification). The app layer is responsible for the
    /// actual ring; this is a fallback path used when `call_ring` arrives before
    /// the local ring has been started.
    public var requestRingLocally: ((_ callId: String, _ callerId: String) -> Void)?

    /// Caller-side error sink: invoked when the server reports `call_peer_offline`
    /// for our outgoing call. App layer should terminate the call UI with a
    /// "Peer offline" error.
    public var onPeerOffline: ((_ callId: String, _ recipientId: String) -> Void)?

    /// Responder-side cancel sink: invoked when the caller hangs up before we
    /// answer (`call_cancel` from server). App layer should stop ringing.
    public var onIncomingCallCancelled: ((_ callId: String, _ reason: String?) -> Void)?

    /// Stash of in-flight call metadata so the responder can answer pre-negotiation
    /// ACKs with the right (callId, callerId) pair. Set when call_offer arrives.
    private var pendingResponderCallId: String?
    private var pendingResponderCallerId: String?

    /// Stash of caller's in-flight outgoing callId so peer_offline / cancel
    /// callbacks know which call they refer to.
    private var pendingOutgoingCallId: String?

    // MARK: - Desktop interop hooks (phase-2)

    /// Optional ContactKeyExchange handler — when set, incoming QUAD
    /// KEY_EXCHANGE_OFFER / KEY_EXCHANGE_ACCEPT frames are routed here so the
    /// iOS engine can derive + store the pairwise PSK (Desktop parity).
    public var contactKeyExchange: ContactKeyExchange?

    /// Delegate callback fired when a decrypted incoming chat body parses as
    /// a `{"qfile":…}` marker. Engine-level plumbing only — the app layer
    /// owns the actual download/UI.
    public var qaudionDidReceiveFile: ((_ marker: FileTransfer.FileMarker, _ from: String) -> Void)?

    // MARK: - Handshake signing, transcript v6 (WIRE_SPEC §3.7 / §3.8)
    //
    // Signing and verification are mandatory and the ONLY path: an integration without a signer
    // cannot start a call, and an inbound OFFER/ACCEPT without a valid-shaped `sigV6` /
    // `signerIdentityKey` / `dtlsFingerprint` ends the call. The properties below are primitives +
    // closures ONLY — never an AppState / SovereignIdentity engine type as a parameter, so the
    // wiring cannot trip the Swift-6 Sendable-inference silent build break (CLAUDE.md §16).

    /// The LOCAL call's own DTLS certificate fingerprint (33 bytes: `u8(1) || SHA-256(DER)`),
    /// resolved for a call id. Wired in AppState to `CallDtlsContextStore`: the per-call
    /// certificate is generated on first use, so the fingerprint exists BEFORE any SDP does.
    /// `nil` (or a malformed value) makes the handshake fail: a call is never set up without it.
    public var provideLocalDtlsFingerprint: ((String) -> Data?)?

    /// Fired the FIRST time a call's peer DTLS fingerprint is pinned (`callId`, 33-byte
    /// fingerprint), after the peer's bundle was verified (or held pending SAS). The app hands it
    /// to the call's PeerConnection, which until then buffers every remote SDP.
    public var onPeerDtlsFingerprintPinned: ((String, Data) -> Void)?

    /// Fired when the handshake must END the call (`callId`, reason): `handshake_malformed` (a
    /// required field is missing/malformed) or `dtls_fp_mismatch` (a re-key round presented a
    /// different DTLS fingerprint than the pinned one). The app ends the call with that reason.
    public var onHandshakeFatal: ((String, String) -> Void)?

    /// Sign a raw §3 transcript with the LOCAL long-term Ed25519 identity →
    /// 64-byte detached signature. `nil` (no identity loaded) → unsigned legacy
    /// path. Wired in `AppState` from `HandshakeTranscript.sign(transcript:
    /// signingPrivateKeyRaw:)` over `SovereignIdentity.signingPrivate`.
    public var signTranscript: ((Data) -> Data?)?

    /// The LOCAL signer's 32-byte raw Ed25519 public identity key, written into
    /// the bundle's `signerIdentityKey` field alongside the signature. `nil` →
    /// unsigned. Wired from `SovereignIdentity.signingPublic`.
    public var localSignerIdentityKey: Data?

    /// Resolve the TOFU-PINNED 32-byte Ed25519 key for a peer contactId, or nil
    /// if not pinned yet (spec §5c trust source, highest priority). Wired from a
    /// shared `PeerIdentityPinStore.pinnedKey`. LEGACY (no device id) — kept so
    /// existing wiring / tests compile; `resolvePinnedPeerKeyForDevice` is
    /// preferred when set.
    public var resolvePinnedPeerKey: ((String) -> Data?)?

    /// D11 per-(peer,device) pin lookup: `(peerContactId, senderDeviceId?) ->
    /// pinnedKey?`. A nil device id resolves to the legacy bare-contactId pin in
    /// the store (migration anchor / graceful fallback). Wired in `AppState` from
    /// `PeerIdentityPinStore.pinnedKey(contactId:deviceId:)`. When set, takes
    /// precedence over `resolvePinnedPeerKey`.
    public var resolvePinnedPeerKeyForDevice: ((String, String?) -> Data?)?

    /// Resolve the SERVER/QR-fetched 32-byte Ed25519 key for a peer contactId,
    /// used as the trust source on first contact when no pin exists yet (spec
    /// §5c). Wired from `ContactsStore.findPubkey`.
    public var resolveServerPeerKey: ((String) -> Data?)?

    /// D11 trust-on-publish floor: resolve the server-published per-device SET of
    /// Ed25519 keys (`GET …/identity-key?all=1`) for `(peerContactId,
    /// senderDeviceId?)`. A bundle key that differs from the pin but is ∈ this set
    /// is an AUTHENTICATED new device / rotation (silent re-pin), not a mismatch
    /// alarm. Returns an EMPTY set ⇒ "no floor" ⇒ degrade to legacy pin-only TOFU
    /// (NEVER a fatal mismatch). Wired in `AppState` from the thread-safe
    /// UserDefaults set cache warmed by `prefetchServerPeerKeySet(_:)`.
    public var resolvePublishedKeySet: ((String, String?) -> Set<Data>)?

    /// Commit a first-contact TOFU pin (contactId, 32-byte Ed25519 key) AFTER a
    /// signature verified under it (spec §2). Wired from
    /// `PeerIdentityPinStore.pinOrMatch`.
    ///
    /// D11: the optional third arg is the sender's `device_id` (server-stamped),
    /// so the pin is keyed per-(peer, device). nil → legacy bare-contactId pin
    /// (graceful fallback when `sender_device_id` is absent). The default-arg
    /// overload below keeps the legacy 2-arg call sites compiling.
    public var commitTofuPinForDevice: ((String, Data, String?) -> Void)?

    /// W-SASPIN (2026-09-08) — set-proven rotation commit for the D11
    /// `.authenticatedRepinFromPublished` verdict: the key was proven ∈ the
    /// server-published set AND self-signed, so the actuator may OVERWRITE an
    /// existing per-(peer, device) pin with it. Kept separate from
    /// `commitTofuPinForDevice` (which is write-once via `pinOrMatch`) so a plain
    /// `.authenticated` verdict can never overwrite a pin. nil ⇒ falls back to the
    /// write-once commit (the pre-fix behaviour: a no-op when a pin exists).
    public var commitSetProvenRepinForDevice: ((String, Data, String?) -> Void)?

    /// Legacy 2-arg TOFU-pin shim (no device id). Kept so existing wiring /
    /// tests that set `commitTofuPin` still work; the integration prefers
    /// `commitTofuPinForDevice` when both are set.
    public var commitTofuPin: ((String, Data) -> Void)?

    /// D11 UI advisory (W-NOBRICK): fired (peerContactId) when an inbound bundle
    /// presented an UNAUTHENTICATED identity-key change — the key differs from
    /// the per-(peer,device) pin AND is ∉ the server-published set. The call is
    /// NOT dropped and the observed key is NOT pinned; this only raises a
    /// non-blocking in-call banner ("verify SAS"). AppState marshals it to
    /// MainActor and sets a `@Published` flag the InCallScreen binds to. nil ⇒
    /// no UI wired (silent — behaviourally unchanged for tests / legacy paths).
    public var onUnauthenticatedIdentityChange: ((String) -> Void)?

    /// XC-1 — fired when a handshake bundle carried a signature that FAILED
    /// verification against the key we verify under (`sig_invalid`): a forgery
    /// against the established/published identity, distinct from an
    /// `identity_key_mismatch` key change. The call is NOT dropped (W-NOBRICK /
    /// signal-not-kill); AppState revokes the peer's stored SAS verification so
    /// the in-call SAS card becomes a REQUIRED re-confirmation (the real terminal
    /// anti-MITM gate). nil ⇒ no UI wired (silent — behaviourally unchanged).
    public var onInvalidHandshakeSignature: ((String) -> Void)?

    /// P0-3 (2026-08-05, coordinated fix plan cluster 3) — fired (callId)
    /// whenever the handshake identity verdict is `.abort` (any of
    /// `sig_invalid` / `identity_key_mismatch` / `sig_required_missing` /
    /// `sig_malformed` — a signature was required and did not verify).
    /// W-NOBRICK still lets the crypto handshake itself complete (the
    /// session key must become available so the SAS words exist to compare
    /// in the first place), but AppState uses this signal to hold back the
    /// ACTUAL media path (relay sealers + v4 ratchet bootstrap) until the
    /// user manually reconfirms the SAS in-call — this closes the fail-open
    /// gap where an unverified identity used to gate nothing but an
    /// advisory banner, matching the "blocking SAS gate" policy already
    /// shipped on Android/Desktop. Fired on BOTH the OFFER and ACCEPT
    /// verdict switches below, once per call leg. nil ⇒ no gate wired
    /// (silent — behaviourally unchanged for tests/legacy callers).
    /// The second argument is the verdict code (`identity_unresolved`, `identity_key_mismatch`,
    /// `sig_invalid`, ...): the app keeps it so a call closed while still held reports the right reason.
    public var onHandshakeIdentityUnverified: ((_ callId: String, _ code: String) -> Void)?

    /// Has this peer ever had a SIGNED v4 bundle verify (spec §4
    /// `v4_capable_pinned`)? Wired from a UserDefaults-backed set in AppState.
    public var isPeerV4Pinned: ((String) -> Bool)?

    /// Mark this peer v4-capable-pinned (set the first time a signed v4 bundle
    /// verifies, BEFORE handshake completion, never cleared — spec §4).
    public var setPeerV4Pinned: ((String) -> Void)?

    /// TOFU-pin analogue for the directional-SRTP-key (`srtpDirKeyV1`)
    /// capability (SRTP downgrade fix): has this peer ever had a SIGNED bundle
    /// verify while advertising `srtpDirKeyV1`? Wired from a UserDefaults-backed
    /// set in AppState, mirroring `isPeerV4Pinned`. Once true, an unauthenticated
    /// bundle that omits/strips the capability can no longer silently downgrade
    /// the negotiated directional-key usage back to legacy (see
    /// `onAndroidBundleReceived`'s `peerAdvertisedSrtpDirKey` assignment).
    public var isPeerSrtpDirKeyV1Pinned: ((String) -> Bool)?

    /// Mark this peer srtpDirKeyV1-capable-pinned (set the first time a signed
    /// bundle advertising the capability verifies, mirroring `setPeerV4Pinned`).
    public var setPeerSrtpDirKeyV1Pinned: ((String) -> Void)?

    /// Q-Audion Dual-Channel Ratchet v5, MUST-FIX #1 (security review 2026-09-16) —
    /// `ratchetV5_capable_pinned` analogue: has this peer ever had a SIGNED bundle verify while
    /// advertising `ratchetV5`? Wired from a UserDefaults-backed set in AppState, mirroring
    /// `isPeerV4Pinned`/`isPeerSrtpDirKeyV1Pinned`. Once true, a later validly-signed bundle
    /// that honestly claims `ratchetV5=false` is flagged as a possible downgrade rather than
    /// silently accepted (see `HandshakeSigningPolicy.evaluate`'s sticky downgrade check).
    public var isPeerRatchetV5Pinned: ((String) -> Bool)?

    /// Mark this peer ratchetV5-capable-pinned (set the first time a signed bundle advertising
    /// the capability verifies, mirroring `setPeerV4Pinned`/`setPeerSrtpDirKeyV1Pinned`).
    public var setPeerRatchetV5Pinned: ((String) -> Void)?

    /// Stash of the `OFFER_v6` transcript WE SENT, keyed by lowercased callId, so the offerer can
    /// recompute `offer_binding = SHA-256(OFFER_v6)` when it later verifies the matching ACCEPT.
    /// Overwritten by every re-key round (the ACCEPT of round N answers round N's OFFER). Cleared
    /// with the rest of the per-call state in `onCallEnded`.
    var sentOfferTranscriptByCall: [String: Data] = [:]

    /// W-KCMAC (ship step 5) — the RAW fingerprint list WE advertised in the OFFER
    /// (`onAndroidCallSetupStarted`'s `advertisedPskFingerprints`), stashed so the
    /// CALLER leg can later rebuild `KeyConfirmation`'s `initAdvert` (its own
    /// advertised order) once the matching ACCEPT arrives — mirrors
    /// `sentOfferTranscriptByCall`'s stash-at-send/consume-at-receive shape.
    /// Cleared with the rest of the per-call state in `onCallEnded`.
    private var sentOfferPskFingerprintsByCall: [String: [String]] = [:]

    /// W-KCMACROLES (2026-07-24) — the PARALLEL role list WE advertised in that
    /// same OFFER (`advertisedPskRoles`). Stashed for the SAME reason as the
    /// fingerprints above, and it is NOT optional: `KeyConfirmation.advEnc`
    /// length-prefixes `(role, fingerprint)` PAIRS, so the role bytes are part of
    /// the MAC'd transcript. The peer reconstructs `initAdvert` from the OFFER it
    /// RECEIVED — i.e. with our REAL roles — so rebuilding our own side with
    /// `roles: nil` (⇒ all-zero) silently diverges the transcript the moment any
    /// advertised key is NFC-origin (role=1), producing `kc_mac result=wrong` and
    /// a FALSE `S1_KC_FAILED` "active attack" verdict on an otherwise healthy
    /// call. Device-confirmed on call db4e5b20 (2026-07-24): iOS-initiator ↔
    /// Android-responder, one NFC key advertised, MAC mismatch on every such call.
    /// The old "nobody sets a non-zero role yet" assumption stopped being true
    /// when the OFFER started carrying real `pskRoles` (commit e3bd816).
    private var sentOfferPskRolesByCall: [String: [Int]] = [:]

    public init() {
        // Tier 1 — build a SpeakerVerifier pre-loaded with the owner's
        // stored Voice-as-Key template, if any (mirrors
        // `VoiceUnlockController`'s init pattern exactly). No template yet
        // ⇒ verifier stays `.idle` ⇒ `OwnerContinuityMonitor` stays
        // `.inactive` forever for this call, matching its own "never nag
        // an un-enrolled user" contract.
        let ownerVerifier = SpeakerVerifier(embedder: CamPlusSpeakerEmbedder.shared)
        if let ownerTemplate = VoiceprintStore().load(contactId: VoiceprintStore.deviceOwnerId) {
            ownerVerifier.importTemplate(ownerTemplate)
        }
        ownerContinuityMonitor = OwnerContinuityMonitor(verifier: ownerVerifier)

        guardianMode.onAlert = { [weak self] level, score in self?.onDeepfakeAlert?(level, score) }
        ownerContinuityMonitor.onStateChanged = { [weak self] state in self?.onOwnerContinuityStateChanged?(state) }
        contactVoiceVerifier.onLevelChanged = { [weak self] level in self?.onContactVoiceLevelChanged?(level) }
        contactVoiceVerifier.onSpeakerChanged = { [weak self] verdict in self?.onSpeakerChangeVerdict?(verdict) }
        // MASVS-CRYPTO remediation (2026-08-20/21) — relay the raw score
        // alongside the level, same pattern. See ContactVoiceVerifier's
        // `onScoreUpdated` kdoc.
        contactVoiceVerifier.onScoreUpdated = { [weak self] score in self?.onContactVoiceScoreUpdated?(score) }
        contactVoiceVerifier.onScoreBreakdown = { [weak self] df, lv, vp, combined in
            self?.onContactVoiceScoreBreakdown?(df, lv, vp, combined)
        }
        // Task #11 — head-start the ephemeral ML-KEM keypair off the
        // call-start critical path (the reused responder integration and
        // any caller integration created with lead time get it for free).
        prewarmKeyMaterial()
        // This `QAudionCallIntegration` instance can be REUSED across
        // multiple calls (see `onCallEnded`'s M-11 comment) — start once
        // here rather than per-call; `onCallEnded` stops it, and the next
        // call's `processOutgoingAudio` feed simply resumes accumulating
        // once whatever future call reuses this instance.
        ownerContinuityMonitor.start()
    }

    /// Resolve BCrypto userId for a contact. Call before onCallSetupStarted.
    public func resolveUserId(signalRecipientId: String, phoneHash: String) async {
        if let cached = bcryptoUserIdCache[signalRecipientId] {
            resolvedBcryptoUserId = cached
            return
        }
        guard let rest = restClient else { return }
        do {
            let data = try await rest.post("/api/v1/contacts/discover",
                body: try JSONSerialization.data(withJSONObject: ["hashes": [phoneHash]]))
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = json.first, let userId = first["userId"] as? String {
                resolvedBcryptoUserId = userId
                bcryptoUserIdCache[signalRecipientId] = userId
            }
        } catch { /* fallback: use signalRecipientId */ }
    }

    // MARK: - Task #11 — pre-warmed ephemeral ML-KEM keypair
    //
    // `pqc.generateKeyPair()` (ML-KEM-1024) is the single heaviest op on
    // the call-start critical path — the user-perceived "handshake is
    // slow". The keypair is a FRESH ephemeral key used exactly once per
    // handshake, so generating it AHEAD of the tap (in the background) is
    // cryptographically identical to generating it at the tap, just
    // earlier in time. We keep one warm keypair, consume it once at call
    // setup, then regenerate in the background for the next call.
    // No wire/KDF change — the bytes on the wire are unchanged.
    private let warmLock = NSLock()
    private var warmPqcKeyPair: PqcKeyExchange.KeyPair?
    private var warmInFlight = false

    /// Best-effort, non-throwing background pre-generation. Safe to call
    /// repeatedly; coalesces (one in-flight gen at a time).
    public func prewarmKeyMaterial() {
        warmLock.lock()
        if warmPqcKeyPair != nil || warmInFlight {
            warmLock.unlock()
            return
        }
        warmInFlight = true
        warmLock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let t0 = DispatchTime.now()
            let kp = try? self.pqc.generateKeyPair()
            let ns = DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds
            self.warmLock.lock()
            self.warmInFlight = false
            if let kp { self.warmPqcKeyPair = kp }
            self.warmLock.unlock()
            self.logTiming("mlkem-prewarm", msInt: Int(ns / 1_000_000), ok: kp != nil)
        }
    }

    /// Returns the warm keypair if one is ready (and kicks a background
    /// re-warm for the next call); otherwise generates inline (timed).
    private func consumeOrGenerateKeyPair() throws -> PqcKeyExchange.KeyPair {
        warmLock.lock()
        if let warm = warmPqcKeyPair {
            warmPqcKeyPair = nil
            warmLock.unlock()
            logTiming("mlkem-warmhit", msInt: 0, ok: true)
            prewarmKeyMaterial()
            return warm
        }
        warmLock.unlock()
        let t0 = DispatchTime.now()
        let kp = try pqc.generateKeyPair()
        let ns = DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds
        logTiming("mlkem-coldpath", msInt: Int(ns / 1_000_000), ok: true)
        prewarmKeyMaterial()
        return kp
    }

    /// Timing log built at function-body scope (NOT in a closure) per
    /// CLAUDE.md §13 — the call-start latency shows up in device
    /// telemetry (re-enabled for TestFlight builds).
    private func logTiming(_ label: String, msInt: Int, ok: Bool) {
        let okStr: String = ok ? "ok" : "FAIL"
        let msStr: String = String(describing: msInt)
        let line: String = "[CallTiming] " + label + " " + msStr + "ms " + okStr
        print(line)
    }

    /// Originator entry point that emits the signed OFFER_v6 JSON HandshakeBundle (literal
    /// `"<callId>|<JSON>"` string), the only 1:1 handshake dialect on every platform.
    /// WIRE_SPEC.md §3.1.
    ///
    /// - A send failure surfaces to the caller.
    /// - Stash the local hybrid keys keyed by callId (race-safe across
    ///   overlapping calls; cleared on session-key install).
    /// - Add explicit logging at every guard return in the ACCEPT path
    ///   so cross-platform debugging isn't blind.
    public func onAndroidCallSetupStarted(
        callId: String,
        sendOpaqueRaw: @escaping (String) async throws -> Void,
        sendOpaqueBinary: @escaping (Data) async throws -> Void
    ) async throws {
        try lock.withLock {
            guard state == .idle else { throw IntegrationError.invalidState(state) }
            isCaller = true
        }

        try engine.initialize()
        let pqcKp = try consumeOrGenerateKeyPair()
        let x25519Priv = Curve25519.KeyAgreement.PrivateKey()

        // INVARIANT (per OpenRouter glm-5.1 review 2026-05-06 P0 #2):
        // STASH PRIVATE KEYS BEFORE INVOKING ANY SEND CLOSURE. The
        // ACCEPT can arrive on the WS dispatcher as soon as the OFFER
        // bytes leave the wire — if we sent first and stashed second,
        // the ACCEPT handler would race-lookup `localHybridKeysByCall`
        // and find nil, then bail out on the verbose-logging guard.
        //
        // W461: also stash under the lowercase variant of callId.
        // iOS UUID().uuidString generates uppercase ("550E8400-…") but
        // Android echoes the callId lowercased ("550e8400-…") in the
        // ACCEPT wire prefix. Without the lowercase alias the lookup
        // at onAndroidBundleReceived(.accept) fails silently → the
        // 30s fallback fires even though A50 sent a valid ACCEPT.
        lock.withLock {
            localKeyPair = pqcKp
            pendingOutgoingCallId = callId
            let keys = HybridLocalKeys(pqcPair: pqcKp, x25519Priv: x25519Priv)
            localHybridKeysByCall[callId] = keys
            let lc = callId.lowercased()
            if lc != callId { localHybridKeysByCall[lc] = keys }
            state = .capabilitySent
        }
        onStateChanged?(.capabilitySent)

        // Build the Android JSON HandshakeBundle OFFER.
        let pqcRawPub = try PqcKeyExchange.extractRawPublicKey(pqcKp.publicKey)
        let x25519RawPub = Data(x25519Priv.publicKey.rawRepresentation)
        // W-PSKMIX step 3 (iOS hygiene) — advertised list is filtered,
        // ordered, and normalised (see `PskAdvertising`): device-internal
        // bookkeeping entries (`__device.*`/`__kmsname.*`) are excluded
        // (mirrors the filter `resolvePskDisplayMeta`/`resolvePskBytes`
        // already apply — this call site previously had none), the order is
        // now stable across repeated calls to the same peer instead of raw
        // Keychain enumeration order, and every fingerprint is recomputed
        // from the entry's raw key material rather than trusted from its
        // Keychain label — so an entry mislabelled in the 16-hex or
        // dotted-group display form (`AppState.installKmsPreBootstrapPsk`,
        // `KeyRotationCoordinator`) is advertised in the WIRE_SPEC §3.3
        // canonical 64-hex form instead of a value the responder's gate can
        // never match.
        let pskVault = SovereignKeyVault()
        let pskAdvertEntries: [PskAdvertising.Entry] = pskVault.listPskEntries().compactMap { entry in
            guard let raw = (try? pskVault.loadPsk(name: entry.name)) ?? nil, !raw.isEmpty else { return nil }
            return PskAdvertising.Entry(
                name: entry.name,
                origin: pskVault.origin(name: entry.name),
                material: raw,
                createdAt: entry.createdAt
            )
        }
        // W-PSKBLIND — the OFFER's dialect. Phase A keeps `offerAdvertDialect` at
        // `.v2Static`, so these bytes are byte-identical to before this change; the
        // responder detects whichever dialect arrives and mirrors it, so no
        // negotiation and no capability bit is involved. Flipping that constant to
        // `.v3Blinded` is phase B and is the ONLY edit that changes the wire.
        //
        // `PskAdvertising.candidatesForAdvertisement` applies the SAME eligibility
        // filter and order as `fingerprintsForAdvertisement`, so a v3 tag list and a
        // static fingerprint list describe the same secrets in the same priority
        // positions — which the responder is required to honour.
        let advert = PskAdvertResolver.buildAdvertisement(
            dialect: Self.offerAdvertDialect,
            callId: callId,
            ownEphemeralX25519Pub: x25519RawPub,
            candidates: PskAdvertising.candidatesForAdvertisement(pskAdvertEntries)
        )
        let advertisedPskFingerprints: [String] = advert.fingerprints
        // W-NFCVISIBLE — parallel role array, same order (both derive from the
        // same `pskAdvertEntries`).
        // W-PSKBLIND — nil under v3, where the roles live inside the tags. `advEnc`
        // already treats an absent array as all-zero, so the signed transcript bytes
        // are the same either way.
        // Kept OPTIONAL rather than defaulted to `[]`: under v3 the field must be
        // ABSENT on the wire, matching Android and Desktop byte for byte. `[]` would
        // decode to the same all-zero meaning but is not the same JSON, and wire
        // parity across the three clients is not a thing to leave to chance.
        let advertisedPskRoles: [Int]? = advert.roles
        // This call's round 1: generate the call's own random freshness nonce ONCE, in memory, and
        // start this offerer's own round counter at 1. Both are reused (never regenerated) by every
        // `performPqcReKey` round this integration later initiates for the SAME callId.
        let rekeyNonceRound1 = Self.generateRekeyNonce()
        lock.withLock {
            rekeyNonceByCall[callId.lowercased()] = rekeyNonceRound1
            rekeyRoundByCall[callId.lowercased()] = 1
        }

        // W-KCMAC (ship step 5) — stash the advert list itself (not just the transcript bytes) so
        // the matching ACCEPT's `onKcMacReady` can rebuild `initAdvert` in the EXACT order we sent
        // it. W-KCMACROLES — the roles ride along in the SAME stash operation: they are part of
        // the MAC'd `advEnc` pairs, so losing them here is exactly as fatal as losing the
        // fingerprints (see `sentOfferPskRolesByCall`'s own doc).
        lock.withLock {
            sentOfferPskFingerprintsByCall[callId.lowercased()] = advertisedPskFingerprints
            // nil (v3) stashes as empty — `toKcAdverts` reads a missing role as 0, which is
            // exactly what `advEnc` bound for an absent wire array.
            sentOfferPskRolesByCall[callId.lowercased()] = advertisedPskRoles ?? []
        }

        // R-COMMIT-NONCE: the caller draws the call's SAS nonce ONCE, before the round-1 OFFER is signed,
        // and commits to it (`sasCommit`, signed inside OFFER_v6). The nonce stays in `sasCommit`'s call
        // context only (never logged, persisted or reused) and is revealed only after the callee's ACCEPT
        // was bound. An OFFER retransmission re-sends `lastSentOfferWire`: the same bytes, the same
        // commitment, never a re-sign with a new nonce. There is no fallback if the CSPRNG fails.
        guard let sasCommitRound1 = sasCommit.beginCaller(callId: callId) else {
            throw IntegrationError.handshakeAborted(code: "sas_nonce_unavailable")
        }
        // Transcript v6 (WIRE_SPEC §3.7): build, SIGN and stash the OFFER. The call's own DTLS
        // certificate fingerprint is bound into it, so the certificate exists before this point
        // (`provideLocalDtlsFingerprint`); a call without one or without a signer is never started.
        let bundleToSend = try buildSignedOffer(
            callId: callId, pqcRawPub: pqcRawPub, x25519RawPub: x25519RawPub,
            advertisedPskFingerprints: advertisedPskFingerprints, advertisedPskRoles: advertisedPskRoles,
            rekeyNonce: rekeyNonceRound1, rekeyRound: 1, rekeyNextPeriodMs: nil,
            sasCommit: sasCommitRound1)
        let jsonWire = AndroidHandshakeEnvelope.serialize(callId: callId, bundle: bundleToSend)

        // Ship the signed JSON OFFER. A failure here propagates back to the caller.
        // W529: stash the EXACT bytes BEFORE sending so a WS-reconnect
        // replay (W531) or a 5 s retry timer uses byte-identical
        // bytes (same callId, same PQC pubkeys). The retry sender
        // closure is also captured so we don't need AppState in the
        // loop.
        lock.withLock {
            lastSentOfferWire = jsonWire
            handshakeStartedAt = Date()
            retrySenderClosure = sendOpaqueRaw
        }
        try await sendOpaqueRaw(jsonWire)
        // W-HSROUNDTIMING (2026-09-09) — first of three round-boundary
        // breadcrumbs (offer-send-confirmed / accept-received /
        // derive-complete). Before this, a stuck handshake only had two
        // observable points — "offer sent" and "30s later, still nothing"
        // — with no way to tell whether the offer never left the device,
        // never reached the peer, the peer never answered, or the ACCEPT
        // came back but decapsulation/derivation failed silently. This
        // marks the `sendOpaqueRaw` call actually returning (local
        // dispatch confirmed, not just attempted) — see the paired
        // breadcrumbs at the `.accept` case entry and after
        // `engine.initSession` below.
        logTiming("hs-offer-sent", msInt: 0, ok: true)
        // W529: arm the 5 s idempotent retry loop. Cancels on
        // session-key install (success) or call end (handshake.reset).
        armOfferRetryTimer()

        // The binary QUAD OFFER is not sent: the signed JSON bundle is the only 1:1 handshake
        // (WIRE_SPEC §3). Two handshake dialects for one call would let the two ends install
        // different session keys.

        // Pre-handshake fallback timeout — if no ACCEPT lands in 30s
        // (session not initialised) flip to .fallback. CallService used to
        // call endCall() on .fallback which caused the exact 30s drop bug;
        // W461 changed that handler to just log, so the call continues.
        // W461: check both original and lowercase callId (Android echo case).
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let lc = callId.lowercased()
            let alreadyDone = self.sessionInitializedByCall.contains(callId)
                           || self.sessionInitializedByCall.contains(lc)
            let currentState = self.state
            if !alreadyDone && currentState == .capabilitySent {
                self.state = .fallback
                self.lock.unlock()
                print("[QAudionCallIntegration] Android JSON OFFER 30s timeout — no ACCEPT for callId=\(callId.prefix(8))… stashedKeys=\(self.localHybridKeysByCall.keys.map { $0.prefix(8) }.joined(separator: ","))")
                self.onStateChanged?(.fallback)
            } else {
                self.lock.unlock()
                print("[QAudionCallIntegration] 30s timer: skipped (alreadyDone=\(alreadyDone) state=\(currentState.rawValue)) for callId=\(callId.prefix(8))…")
            }
        }
    }

    /// I3 §5 (2026-08-21) — mid-call PQC re-key, INITIATOR side. Mirrors
    /// Android's `performReKey` (`CallController.kt:6860`): reuses the
    /// SAME `AndroidHandshakeBundle` OFFER shape as
    /// `onAndroidCallSetupStarted` (fresh ephemeral ML-KEM+X25519 keypair,
    /// same PSK-advertisement/signing steps), sent over the SAME
    /// `opaque_message` channel — but deliberately skips every ONE-TIME
    /// call-SETUP side effect that function has: no `engine.initialize()`
    /// (would reset the negotiated audio profile — see the `isReKeyRound`
    /// guard in the `.offer` case's own doc), no `state` transition away
    /// from `.active`, no 30s pre-handshake fallback timer, no touch to
    /// `localKeyPair`/`pendingOutgoingCallId` (those belong to the
    /// ORIGINAL handshake's own bookkeeping).
    ///
    /// Glare-avoidance: only ever call this on the device that originated
    /// the call. There is no `isInitiator`-equivalent enforcement inside
    /// this function beyond the `isCaller` guard below — the CALLER of
    /// this function (the app layer, driven by `ReKeyScheduler`'s ticks)
    /// is responsible for not calling it on a responder integration.
    ///
    /// Returns `true` if a new key was derived and installed, `false` on
    /// any failure (timeout, network error, keygen failure) — in every
    /// failure case the call is left running on whatever key was active
    /// before this call, exactly like Android's `performReKey.onFailure`
    /// ("NEVER brick an otherwise-healthy call over one failed periodic
    /// re-key round"). There is no Android-style "provisional swap + revert
    /// on no-confirmation" watchdog here because there is no need for one:
    /// unlike Android's `installRekeyedAudioKey`, this function never
    /// installs anything until AFTER a real ACCEPT has been received and
    /// the key derived from it — the swap is naturally deferred, not
    /// optimistic, so there is nothing to revert if the ACCEPT never
    /// arrives.
    /// - Parameter armedPeriodMs: W-REKEYSYNC (2026-09-10) — this device's
    ///   own `ReKeyScheduler` period (ms) at the moment this round starts,
    ///   i.e. how long until this device's OWN scheduler would next fire.
    ///   Echoed on the OFFER as `rekeyNextPeriodMs` so the responder can
    ///   track the SAME real deadline instead of guessing independently —
    ///   see `AndroidHandshakeBundle.rekeyNextPeriodMs`'s doc. `nil` omits
    ///   the field (byte-identical wire to a peer that hasn't shipped this).
    @discardableResult
    public func performPqcReKey(callId: String, peerId: String, timeoutSec: Double = 8.0, armedPeriodMs: Int64? = nil) async -> Bool {
        let (canProceed, sendOpaqueRaw) = lock.withLock { () -> (Bool, ((String) async throws -> Void)?) in
            // R-REKEY-INIT: only the caller ever initiates a rekey; the callee only responds.
            let held = heldCalls.contains(callId.lowercased())
            guard RekeyRolePolicy.mayInitiateRekey(
                isCaller: isCaller, isActive: state == .active, hasPendingAttempt: pendingReKeyAttempt != nil,
                isHeld: held)
            else {
                // R-HELD-REKEY: a rekey the caller would have started is deferred, not dropped.
                if held && isCaller && state == .active && pendingReKeyAttempt == nil {
                    rekeyDeferredWhileHeld.insert(callId.lowercased())
                }
                return (false, nil)
            }
            return (true, retrySenderClosure)
        }
        guard canProceed, let sendOpaqueRaw else {
            print("[QAudionCallIntegration] performPqcReKey skipped (isCaller/state/in-flight guard) callId=\(callId.prefix(8))… peer=\(peerId.prefix(8))…")
            return false
        }

        let pqcKp: PqcKeyExchange.KeyPair
        let x25519Priv = Curve25519.KeyAgreement.PrivateKey()
        let pqcRawPub: Data
        do {
            // consumeOrGenerateKeyPair has no one-shot restriction — safe
            // to call again mid-call (verified by reading it: it either
            // returns a pre-warmed keypair or generates a fresh one cold).
            pqcKp = try consumeOrGenerateKeyPair()
            pqcRawPub = try PqcKeyExchange.extractRawPublicKey(pqcKp.publicKey)
        } catch {
            print("[QAudionCallIntegration] performPqcReKey keygen failed callId=\(callId.prefix(8))…: \(error)")
            return false
        }
        let localKeys = HybridLocalKeys(pqcPair: pqcKp, x25519Priv: x25519Priv)
        let x25519RawPub = Data(x25519Priv.publicKey.rawRepresentation)

        // Same PSK-advertisement construction as onAndroidCallSetupStarted
        // — a re-key OFFER re-advertises the caller's current PSK
        // catalogue exactly like the original handshake did (Android does
        // the same: PqcHandshake.initiate() re-runs the full PSK
        // negotiation on every round, not just the first).
        let pskVault = SovereignKeyVault()
        let pskAdvertEntries: [PskAdvertising.Entry] = pskVault.listPskEntries().compactMap { entry in
            guard let raw = (try? pskVault.loadPsk(name: entry.name)) ?? nil, !raw.isEmpty else { return nil }
            return PskAdvertising.Entry(
                name: entry.name, origin: pskVault.origin(name: entry.name),
                material: raw, createdAt: entry.createdAt)
        }
        let advert = PskAdvertResolver.buildAdvertisement(
            dialect: Self.offerAdvertDialect, callId: callId,
            ownEphemeralX25519Pub: x25519RawPub,
            candidates: PskAdvertising.candidatesForAdvertisement(pskAdvertEntries))
        // CALL-3 — this OFFERER's own next round: reuse the nonce round 1
        // established (never regenerate mid-call) and increment the round
        // counter. A call that somehow never went through
        // `onAndroidCallSetupStarted` for this callId (should not happen —
        // `performPqcReKey`'s own `isCaller`/`state == .active` guard already
        // requires a completed original handshake) falls back to round 2 with
        // a freshly-generated nonce rather than crashing; a responder that has
        // no round-1 record for this callId simply treats this round's
        // `hsTranscriptBindV1` path as unavailable (falls back to legacy KDF/SAS
        // — see the `.offer` case's round-freshness gate).
        // ITEM 2/3 FOLLOW-UP — `thisRoundNonce` is now returned alongside the round
        // number: the OFFER resends the SAME nonce on every round (see
        // `HandshakeTranscript.offerV3`'s doc), so this leg needs the actual bytes
        // here, not just the round-1 existence check the prior version only used to
        // decide whether to (re)generate.
        let (thisRound, thisRoundNonce): (UInt32, Data) = lock.withLock {
            let next = (rekeyRoundByCall[callId.lowercased()] ?? 1) + 1
            rekeyRoundByCall[callId.lowercased()] = next
            let nonce: Data
            if let existing = rekeyNonceByCall[callId.lowercased()] {
                nonce = existing
            } else {
                nonce = Self.generateRekeyNonce()
                rekeyNonceByCall[callId.lowercased()] = nonce
            }
            return (next, nonce)
        }
        // Stash the advert list (KCMAC needs it, same as the original handshake) — deliberately
        // OVERWRITING the ORIGINAL handshake's stash (callId-keyed, not round-keyed): by the time a
        // re-key round starts, the original handshake is long complete (glare-guard above requires
        // `state == .active`) and its stashed transcript is never read again — the ACCEPT-verify
        // path for THIS round needs THIS round's transcript.
        lock.withLock {
            sentOfferPskFingerprintsByCall[callId.lowercased()] = advert.fingerprints
            sentOfferPskRolesByCall[callId.lowercased()] = advert.roles ?? []
        }
        // W-REKEYSYNC — see this function's `armedPeriodMs` param doc. Untrusted-input clamp
        // mirrors Android: no legitimate ReKeyScheduler period ever falls outside
        // (0, basePeriodMs].
        let nextPeriodMs: Int? = armedPeriodMs.flatMap { period -> Int? in
            guard period > 0, period <= ReKeyScheduler.basePeriodMs else { return nil }
            return Int(period)
        }
        let bundleToSend: AndroidHandshakeBundle
        do {
            // Every re-key round re-signs a FRESH v6 OFFER carrying the SAME DTLS fingerprint as
            // round 1 (the certificate is constant per call; WIRE_SPEC §3.4 step 5). A rekey OFFER
            // carries NO SAS commitment (R-COMMIT-SCOPE: only round 1 has one).
            bundleToSend = try buildSignedOffer(
                callId: callId, pqcRawPub: pqcRawPub, x25519RawPub: x25519RawPub,
                advertisedPskFingerprints: advert.fingerprints, advertisedPskRoles: advert.roles,
                rekeyNonce: thisRoundNonce, rekeyRound: thisRound, rekeyNextPeriodMs: nextPeriodMs,
                sasCommit: nil)
        } catch {
            print("[QAudionCallIntegration] performPqcReKey OFFER build failed callId=\(callId.prefix(8))…: \(error)")
            return false
        }
        let jsonWire = AndroidHandshakeEnvelope.serialize(callId: callId, bundle: bundleToSend)

        // Arm the pending-attempt continuation BEFORE sending — a
        // same-machine-speed ACCEPT can never race ahead of
        // pendingReKeyAttempt being ready to receive it. Whichever of
        // {the .accept dispatch below, the timeout task} resolves first
        // wins; both clear pendingReKeyAttempt atomically before calling
        // resume, so the other is guaranteed a no-op.
        let attemptId = UUID()
        let combined: Data? = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            lock.withLock {
                pendingReKeyAttempt = PendingReKeyAttempt(id: attemptId, localKeys: localKeys) { value in
                    cont.resume(returning: value)
                }
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await sendOpaqueRaw(jsonWire)
                } catch {
                    print("[QAudionCallIntegration] performPqcReKey send failed callId=\(callId.prefix(8))…: \(error)")
                    let resume: ((Data?) -> Void)? = self.lock.withLock {
                        guard self.pendingReKeyAttempt?.id == attemptId else { return nil }
                        let r = self.pendingReKeyAttempt?.resume
                        self.pendingReKeyAttempt = nil
                        return r
                    }
                    resume?(nil)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                guard let self else { return }
                let resume: ((Data?) -> Void)? = self.lock.withLock {
                    guard self.pendingReKeyAttempt?.id == attemptId else { return nil }
                    let r = self.pendingReKeyAttempt?.resume
                    self.pendingReKeyAttempt = nil
                    return r
                }
                if resume != nil {
                    print("[QAudionCallIntegration] performPqcReKey timed out after \(timeoutSec)s callId=\(callId.prefix(8))… — keeping current key")
                }
                resume?(nil)
            }
        }

        guard combined != nil else { return false }
        // The .accept dispatch (onAndroidBundleReceived's rekey completion
        // branch) already ran engine.initSession() and fired the session-
        // key-rotation callbacks before resolving this continuation — see
        // that branch's own doc for why nothing further is needed here.
        print("[QAudionCallIntegration] performPqcReKey completed callId=\(callId.prefix(8))… peer=\(peerId.prefix(8))…")
        return true
    }

    public func onCapabilityMessageReceived(data: Data, fromSenderId: String = "", sendOpaqueMessage: @escaping (Data) async throws -> Void) throws {
        guard let message = QAudionCapabilityExchange.parse(data) else { return }
        // W-STALESEALER — this function is not `async` (no `await` is possible
        // anywhere below), so reading the generation here is equivalent to
        // reading it at the exact instant `onRelaySessionReady` fires further
        // down — see `provideCallGeneration`'s doc for why that distinction
        // matters on the `async` paths (`onAndroidBundleReceived`).
        let entryGeneration = provideCallGeneration?() ?? -1

        switch message {
        case .offer, .accept:
            // The binary QUAD 1:1 OFFER/ACCEPT dialect is RETIRED (WIRE_SPEC §3): it carries no
            // signature and no DTLS certificate fingerprint, so it can never establish a call
            // under transcript v6. Ignored — a peer that still sends it simply never connects.
            print("[QAudionCallIntegration] retired QUAD OFFER/ACCEPT ignored")

        case .keyExchangeOffer(let payload):
            // Peer is initiating first-contact PSK derivation.
            // `payload` = peer's X25519 public key (32B).
            // `fromSenderId` is threaded from AppState's WS dispatcher.
            if let ke = contactKeyExchange {
                let sid: String = fromSenderId
                Task { await ke.handleOffer(senderId: sid, peerPubKey: payload) }
            }

        case .keyExchangeAccept(let payload):
            if let ke = contactKeyExchange {
                let sid: String = fromSenderId
                Task { await ke.handleAccept(senderId: sid, peerPubKey: payload) }
            }

        case .audioData, .voiceAnalysis, .dcSdpOffer, .dcSdpAnswer, .dcIce, .callHangup:
            // .callHangup (QUAD 0x08) is decoded on purpose and then dropped
            // here: call teardown is carried by the WS `call_hangup` path, the
            // id-gated opaque `HANGUP:` piggy-back and the in-band 0x03
            // control frame, and no client sends 0x08. The parser stays
            // because WIRE_SPEC requires the codec to keep decoding it.
            // If it is ever wired to a teardown, it MUST first gate on
            // sender == call peer and callId == the active call.
            break
        }
    }

    // MARK: - Android JSON HandshakeBundle interop

    /// Process an Android-format JSON HandshakeBundle (the wire shape
    /// described in `AndroidHandshakeBundle.swift`). Replaces the
    /// previous Path-B fail-fast path in
    /// `AppState.wireOpaqueMessageHandler` (which sent a `call_hangup`
    /// the moment it spotted the JSON shape, just to free the Android
    /// side from its 35 s timeout). Now we actually consume the bundle:
    ///
    /// - .offer (responder side):
    ///     1. Decode the JSON public-key fields (pqcPublicKey,
    ///        x25519PublicKey, dualCurvePublicKey?, strongBoxPublicKey?).
    ///     2. iOS supports the dual-hybrid (PQC + X25519) primitives
    ///        natively; X448 (`dualCurvePublicKey`) and Android
    ///        StrongBox-bound P-256 (`strongBoxPublicKey`) are NOT yet
    ///        wired into `deriveHybridSessionKey`, so we silently drop
    ///        those legs. The session key still combines ML-KEM-1024 +
    ///        X25519, which IS the cross-platform floor.
    ///     3. PSK fingerprint negotiation: deterministic lex-sort of
    ///        the intersection (offerSet ∩ localEligible) and pick [0]
    ///        (WIRE_SPEC.md §3.3). For now iOS has no SovereignKeyVault
    ///        equivalent so the `localEligible` set is empty (passed in
    ///        as a parameter to keep this composable for the future).
    ///     4. Encapsulate, build the JSON ACCEPT (with `ciphertext.pqc`
    ///        + `ciphertext.x25519` + `selectedPskFingerprint`), wrap
    ///        in `"<callId>|<json>"` and send via the same
    ///        `sendOpaqueMessage` closure.
    ///     5. Fire `onPqcSessionKeyEstablished` with the combined
    ///        shared secret so the broker swaps in the real session
    ///        key (§5.4).
    ///
    /// - .accept (caller side, only fires when iOS originated the call
    ///   in JSON format — not yet wired into the iOS originator path
    ///   but the decode logic is here for symmetry).
    ///
    /// Throws on any decoder/crypto failure. The caller (AppState's
    /// `routeInboundAndroidOffer`) is expected to catch and log.
    public func onAndroidBundleReceived(
        bundle: AndroidHandshakeBundle,
        callId: String,
        callerId: String = "",
        callerDeviceId: String? = nil,
        envelopeSenderDeviceId: String? = nil,
        eligiblePsks: [String: Data] = [:],
        sendOpaqueRaw: @escaping (String) async throws -> Void
    ) async throws {
        // W-PQCENTRY (2026-07-13) — unconditional entry breadcrumb, BEFORE any
        // guard/switch below can early-return or throw. Added after a muted
        // call (server-confirmed c74487d2, 2026-07-13: callee's WS bounced at
        // setup → W-PUSHWAKE buffered-offer redelivery fired → callee's PQC
        // responder eventually completed 10s late → but the CALLER's
        // initiator-side PQC_DIAG_V4 print further below in the `.accept` case
        // never fired at all, and NO Loki-tagged line for this call_id ever
        // appeared from the caller device, in either attribute-filter or raw
        // line-grep mode) where it was impossible to tell, after the fact,
        // whether this function was ever entered for that call — i.e. whether
        // the peer's ACCEPT bundle was lost in transit/never relayed, or
        // arrived and was silently dropped by a guard before this dispatcher
        // even ran. This line is pure diagnostics (print only, no behaviour
        // change) so the NEXT occurrence is diagnosable with certainty instead
        // of inferred from its absence.
        print("[PQC_DIAG_V4] onAndroidBundleReceived ENTRY kind=\(bundle.kind) callId=\(callId.prefix(8))… callerId=\(callerId.isEmpty ? "?" : String(callerId.prefix(8)))")
        // W-STALESEALER (2026-09-26, fix-3) — capture the call generation HERE,
        // at the very start of processing this inbound bundle, before the
        // `await sendOpaqueRaw(...)` further down in the `.offer`/`.accept`
        // cases can let `endCall()` run and bump it. See
        // `provideCallGeneration`'s doc for the full reasoning: reading the
        // generation only when `fireRelaySessionReady` actually fires (after
        // that await) would sample the POST-teardown value, which then
        // spuriously "matches" the current generation and lets a stale sealer
        // install through.
        let entryGeneration = provideCallGeneration?() ?? -1
        // W574x — capture the peer's directional-PQC-RTP-key advertisement so
        // the relay sealer can be built directional when both sides support it.
        // This runs before onRelaySessionReady fires for this bundle.
        // SRTP downgrade fix: OR in the TOFU-pinned capability so a peer that
        // has PROVEN (signed) srtpDirKeyV1 support before cannot be silently
        // downgraded by a later unauthenticated bundle that omits/strips the
        // field — additive-only (can only flip false→true), never gates on an
        // unauthenticated claim alone.
        self.peerAdvertisedSrtpDirKey = (bundle.capabilities?.srtpDirKeyV1 ?? false)
            || (isPeerSrtpDirKeyV1Pinned?(callerId) ?? false)
        // Phase 18 — capture the peer's v4 advertisement so the v4 bootstrap is
        // gated on the negotiated AND (`negotiatedRatchetV4`). A bundle that omits
        // the field (older peer / un-opted-in) decodes nil → false → v4 stays off
        // for the pair, exactly like Android's `safePeer.ratchetV4` default.
        self.peerAdvertisedRatchetV4 = (bundle.capabilities?.ratchetV4 ?? false)
        // MEDIA-3/4/5 — capture the peer's inner-sealed-audio-AAD advertisement,
        // same additive/AND-negotiated shape as srtpDirKeyV1/ratchetV4 above. No
        // TOFU-pin OR here (unlike srtpDirKeyV1) — this bit has no pinning store
        // of its own, and with `Self.innerAudioAadV1Enabled` false the AND in
        // `negotiatedInnerAudioAadV1` keeps this inert either way.
        self.peerAdvertisedInnerAudioAad = (bundle.capabilities?.innerAudioAadV1 ?? false)

        switch bundle.kind {
        case .offer:
            // Pre-negotiation: emit
            // `call_processing` the moment the OFFER lands so the Android
            // caller's UI flips "Calling…" → "Connecting…". The Android
            // JSON path previously skipped BOTH call_processing AND
            // call_ready, so the iPad-as-callee NEVER acked the OFFER on the
            // signalling channel — confirmed in server logs (device
            // ef91920d emits no call_ready/call_processing in any call).
            // The server also uses this ack to decide whether the WS
            // delivery of `call_incoming` actually landed (vs a zombie WS),
            // gating a backup VoIP push. callerId may be "" when the
            // dispatcher could not supply it — guard the emit on non-empty.
            if !callerId.isEmpty {
                sendCallProcessing?(callId, callerId)
            }
            // 1. Validate callId match (loose — responder hasn't seen it
            // yet, so we just keep the value the bundle carries).
            // 2. Decode public keys from base64.
            guard let pqcPubB64 = bundle.pqcPublicKey,
                  let x25519PubB64 = bundle.x25519PublicKey else {
                print("[QAudionCallIntegration] OFFER missing pqcPublicKey or x25519PublicKey for callId=\(callId.prefix(8))…")
                throw IntegrationError.invalidState(state)
            }
            guard let pqcPub = Data(base64Encoded: pqcPubB64),
                  let x25519Pub = Data(base64Encoded: x25519PubB64) else {
                print("[QAudionCallIntegration] OFFER base64 decode failed for callId=\(callId.prefix(8))… pqcLen=\(pqcPubB64.count) x25519Len=\(x25519PubB64.count)")
                throw IntegrationError.invalidState(state)
            }

            // Transcript v6 (WIRE_SPEC §3.7 / §3.8) — the single, MANDATORY verification path,
            // run BEFORE any crypto work (`pqc.encapsulate`) or ACCEPT emission.
            //   * `.malformed` (a required field is missing or malformed): the call ENDS.
            //   * `.abort` (invalid signature, unknown identity key — W-NOBRICK): the call is NOT
            //     dropped and the observed key is NOT pinned; media is held behind a blocking SAS
            //     reconfirmation (`onHandshakeIdentityUnverified`). The session key still derives
            //     from the v6 transcript built under the bundle's OWN key, so a legitimate-but-
            //     unpinned peer still converges and the SAS words exist to compare.
            //   * `.authenticated` / `.authenticatedRepinFromPublished`: commit the per-(peer,
            //     device) pin + capability pins.
            // R-COMMIT-FIRST-ROUND: the first OFFER a callee sees for a callId must be round 1; any other
            // first round is malformed and ends the call without an ACCEPT.
            // A2 (WIRE_SPEC §3.7.4): a callee takes the commitment from the OFFER it actually ANSWERS. While this
            // device has NOT sent its round-1 ACCEPT (the default signalling-only ring holds it until the human
            // answers) the newest valid round-1 OFFER replaces the one already processed: the unanswered round is
            // wiped and this OFFER runs as the first one. After the ACCEPT is out a different round-1 OFFER is
            // dropped as before (the stale-round refusal below) and the frozen commitment stays.
            let replacementOfferKey = callId.lowercased() + "#" + Data(SHA256.hash(data: pqcPub + x25519Pub)).base64EncodedString()
            // A2, invalid OFFER: while the answered OFFER is held (its ACCEPT not sent yet) an OFFER that is not a
            // valid round-1 OFFER (another round, a missing or malformed commitment, a §3.1 malformed bundle) is
            // dropped silently: no state, no hangup, no ACCEPT. The held round stays untouched.
            let (holdsCallContext, isKnownOfferRetransmit) = lock.withLock { () -> (Bool, Bool) in
                (sessionInitializedByCall.contains(callId.lowercased()),
                 processedOfferFingerprintsByCall.contains(replacementOfferKey))
            }
            let acceptNotYetSent = sasCommit.calleeCanBeSuperseded(callId: callId)
            let replacementCommitmentCode = HandshakeSigningPolicy.sasCommitMalformedCode(
                isOffer: true, round: bundle.rekeyRound, sasCommitB64: bundle.sasCommit)
            if Self.isInvalidOfferWhileUnanswered(
                round: bundle.rekeyRound, commitmentCode: replacementCommitmentCode,
                hasCallContext: holdsCallContext, isKnownRetransmit: isKnownOfferRetransmit,
                acceptNotYetSent: acceptNotYetSent) {
                print("[QAudionCallIntegration] OFFER dropped — not a valid round-1 OFFER while the answered one is held callId=\(callId.prefix(8))…")
                return
            }
            let replacesUnansweredOffer = Self.isUnansweredRound1Replacement(
                round: bundle.rekeyRound, commitmentCode: replacementCommitmentCode,
                hasCallContext: holdsCallContext, isKnownRetransmit: isKnownOfferRetransmit,
                acceptNotYetSent: acceptNotYetSent)
            if replacesUnansweredOffer {
                // Only a VALID OFFER replaces the held one: one the malformed checks refuse is dropped here, before
                // anything of the held round is touched. The probe leaves no state behind for a malformed bundle;
                // for a valid one its call-scoped pin notes go with the wiped round and the real check below makes
                // them again.
                if case .malformed = evaluateInbound(
                    bundle: bundle, callId: callId, peerId: callerId, peerDeviceId: callerDeviceId,
                    expectedOfferBinding: nil).verdict {
                    print("[QAudionCallIntegration] OFFER dropped — a malformed OFFER never replaces the held one callId=\(callId.prefix(8))…")
                    return
                }
                print("[QAudionCallIntegration] a newer round-1 OFFER replaces the unanswered one callId=\(callId.prefix(8))…")
                supersedeUnansweredRound1(callId: callId)
            }
            let isFirstOfferOfCall = lock.withLock { !sessionInitializedByCall.contains(callId.lowercased()) }
            if let code = HandshakeSigningPolicy.firstRoundMalformedCode(
                isFirstOfferOfCall: isFirstOfferOfCall, round: bundle.rekeyRound) {
                print("[QAudionCallIntegration] OFFER malformed code=\(code) peer=\(callerId.prefix(8))… callId=\(callId.prefix(8))… — ending the call")
                reportHandshakeFatal(callId: callId, reason: "handshake_malformed")
                throw IntegrationError.handshakeAborted(code: code)
            }
            let offerCheck = evaluateInbound(
                bundle: bundle, callId: callId, peerId: callerId, peerDeviceId: callerDeviceId,
                expectedOfferBinding: nil)
            // W-KCMAC — `AssuranceState.decide`'s `sigOk` input: true only for the two verdicts that
            // actually confirm the Ed25519 transcript signature.
            var offerSigOk = false
            switch offerCheck.verdict {
            case .malformed(let code):
                print("[QAudionCallIntegration] OFFER malformed code=\(code) peer=\(callerId.prefix(8))… callId=\(callId.prefix(8))… — ending the call")
                reportHandshakeFatal(callId: callId, reason: "handshake_malformed")
                throw IntegrationError.handshakeAborted(code: code)
            case .abort(let code):
                // W-NOBRICK (user directive): a handshake-sig verdict must NEVER hard-drop the
                // call. The SAS (6 words from the session key) is the REAL anti-MITM gate.
                print("[QAudionCallIntegration] ⚠️ OFFER verify code=\(code) peer=\(callerId.prefix(8))… callId=\(callId.prefix(8))… — NOT dropping; proceeding, VERIFY THE SAS")
                if code == "identity_key_mismatch" {
                    onUnauthenticatedIdentityChange?(callerId)
                }
                // XC-1 — a present-but-INVALID signature is a forgery against the key we verify
                // under: revoke the peer's SAS verification so the in-call SAS becomes a required
                // re-confirmation.
                if code == "sig_invalid" {
                    onInvalidHandshakeSignature?(callerId)
                }
                // P0-3 — hold MEDIA (not the handshake) behind a blocking SAS reconfirmation.
                markHeld(callId: callId)
                onHandshakeIdentityUnverified?(callId, code)
            case .authenticated(let tofuPinKey, let v4Capable, let srtpDirKeyV1Capable, let ratchetV5Capable):
                applyAuthenticatedSideEffects(peerId: callerId, deviceId: callerDeviceId, tofuPinKey: tofuPinKey, v4Capable: v4Capable, srtpDirKeyV1Capable: srtpDirKeyV1Capable, ratchetV5Capable: ratchetV5Capable)
                offerSigOk = true
            case .authenticatedRepinFromPublished(let deviceKey, let v4Capable, let srtpDirKeyV1Capable, let ratchetV5Capable):
                // D11 trust-on-publish: bundle key ≠ pin but ∈ the server's published set AND its
                // own signature verified. Silent additive re-pin per-(peer, device); NO banner.
                print("[QAudionCallIntegration] OFFER set-proven rotation peer=\(callerId.prefix(8))… dev=\((callerDeviceId ?? "—").prefix(8))… — silent re-pin, proceeding")
                applyAuthenticatedSideEffects(peerId: callerId, deviceId: callerDeviceId, tofuPinKey: deviceKey, v4Capable: v4Capable, srtpDirKeyV1Capable: srtpDirKeyV1Capable, setProven: true, ratchetV5Capable: ratchetV5Capable)
                offerSigOk = true
            }
            // Every non-malformed verdict carries the transcript, the parsed peer fingerprint and
            // the signer key (the policy returns `.malformed` otherwise).
            guard let offerT = offerCheck.transcript, let peerFp = offerCheck.peerFingerprint else {
                reportHandshakeFatal(callId: callId, reason: "handshake_malformed")
                throw IntegrationError.handshakeAborted(code: "transcript_unbuildable")
            }
            // `offer_binding = SHA-256(OFFER_v6)`: bound into the ACCEPT, and the KCMAC / v4-bootstrap
            // input. Built under the bundle's own key, so even the hold paths stay convergent.
            let verifiedOfferBinding = HandshakeTranscript.offerBinding(offerT)
            // Pin the offerer's DTLS fingerprint (once per call; a re-key round MUST carry the same
            // one — F9). Until it is pinned the PeerConnection applies no remote SDP.
            guard pinPeerDtlsFingerprint(callId: callId, fingerprint: peerFp) else {
                throw IntegrationError.handshakeAborted(code: "dtls_fp_mismatch")
            }

            // Re-key round freshness (every round, unconditionally): refuse an OFFER whose signed
            // `rekeyRound` is not strictly greater than the last one this responder ACCEPTED for
            // the call (a stale/replayed round). W-NOBRICK: the call is NEVER dropped over a
            // refused round — it keeps running on its current key. A byte-identical RETRANSMIT of
            // the currently-active round is let through (the cached ACCEPT is replayed below).
            let normalizedOIdV3 = callId.lowercased()
            let isReKeyRoundV3 = lock.withLock { sessionInitializedByCall.contains(normalizedOIdV3) }
            let offerFingerprintV3 = Data(SHA256.hash(data: pqcPub + x25519Pub)).base64EncodedString()
            let isKnownRetransmitV3 = lock.withLock {
                processedOfferFingerprintsByCall.contains(normalizedOIdV3 + "#" + offerFingerprintV3)
            }
            let round = UInt32(truncatingIfNeeded: bundle.rekeyRound ?? 0)
            let lastAccepted = lock.withLock { lastAcceptedRekeyRoundByCall[normalizedOIdV3] }
            if Self.shouldRefuseStaleRekeyRound(
                isReKeyRound: isReKeyRoundV3, isKnownRetransmit: isKnownRetransmitV3,
                round: round, lastAccepted: lastAccepted
            ) {
                print("[QAudionCallIntegration] refusing stale/replayed re-key round=\(round) (last accepted=\(lastAccepted.map(String.init) ?? "—")) callId=\(callId.prefix(8))… peer=\(callerId.prefix(8))… — call continues on its current key")
                return
            }
            // Only a VERIFIED round advances the ratchet: an unauthenticated OFFER must never be
            // able to push the watermark and starve the real peer's later rounds.
            if offerSigOk {
                lock.withLock { lastAcceptedRekeyRoundByCall[normalizedOIdV3] = round }
            }

            // 3. iOS dual-hybrid encapsulate — drop X448 + StrongBox legs.
            let pqcResult = try pqc.encapsulate(remotePublicKey: pqcPub)
            let x25519Result = try Self.x25519Encap(remotePub: x25519Pub)

            // 4. PSK selection — CALLER'S PRIORITY COMMANDS (revised
            // 2026-06-02, WIRE_SPEC §3.3). The initiator advertises its
            // fingerprints ORDERED BY PRIORITY (highest first); the responder
            // picks the FIRST one in the OFFER's order that it also holds —
            // NOT a lexicographic sort. The choice is sent back
            // (selectedPskFingerprint) and the initiator honors it, so both
            // ends agree regardless of platform. MUST iterate the OFFER's
            // order, NOT the local catalogue order. Selected BEFORE deriving
            // the session key: the PSK is the HKDF Extract salt of the single
            // corrected derivation (schema :2).
            //
            // W-PSKBLIND: the rule above is UNCHANGED, but the advertised values may
            // now be per-call blinded tags (§3.3.1) instead of static fingerprints.
            // `PskAdvertResolver.resolve` tries v3 first, then static, and reports
            // which dialect matched — no capability bit and no negotiation, because
            // the advertisement describes its own dialect. Three distinct values come
            // out of it and they must not be confused:
            //   * `wireValue` → echoed VERBATIM in selectedPskFingerprint. Echoing the
            //     static form under v3 would put the selected key's permanent
            //     correlator back on the wire every call and defeat the whole section.
            //   * `staticFp`  → everything downstream (§D4 intersect, kc_mac
            //     mixedFingerprints, the session-KDF selected_fp, the UI).
            //   * `dialect`   → mirrored in our OWN ACCEPT advertisement, which is what
            //     removes any mixed window on this leg.
            var selectedFp: String?
            var selectedPsk: Data?
            let resolvedAdvert = PskAdvertResolver.resolve(
                receivedAdvert: bundle.pskFingerprints,
                receivedRoles: bundle.pskRoles,
                callId: callId,
                // The INITIATOR's ephemeral — the sender of the advertisement we are
                // matching. Using our own key here is the mistake that makes two v3
                // peers silently fail to find a secret they both hold.
                senderEphemeralX25519Pub: x25519Pub,
                // Sorted, because `eligiblePsks` is a Dictionary and Swift does not
                // specify its iteration order. Selection itself is driven by the
                // RECEIVED order so it is deterministic either way, but an unordered
                // candidate list makes `localIndex` and the mutual-set order vary
                // between runs — the kind of nondeterminism that turns a bug into an
                // intermittent one.
                candidates: eligiblePsks.keys.sorted().map {
                    PskAdvertResolver.Candidate(staticFp: $0, psk: eligiblePsks[$0] ?? Data(), localRole: 0)
                },
                // §3.3.1.1 — THE decisive read. This resolve is what admits a
                // static-dialect PSK into the session key on this leg, so this is where
                // the forceable downgrade is actually denied.
                refuseStaticFallback: Self.pskDialectLatch.hasSpokenBlindedAdvert(contactId: callerId)
            )
            // The peer's OWN advertisement resolved under the peer's OWN ephemeral key, so
            // a v3 result here is a fact about THEIR build and is safe to latch.
            if resolvedAdvert.dialect == .v3Blinded {
                Self.pskDialectLatch.rememberSpokeBlindedAdvert(contactId: callerId)
            }
            if resolvedAdvert.dialect == .v2StaticRefused {
                // §3.3.1.1 — loud on purpose. This is the ONLY signature of the forceable
                // downgrade: a contact known to speak the blinded advertisement has sent a
                // static one. The call proceeds without a PSK (W-NOBRICK: never dropped)
                // and n=0 carries it into the assurance state and the trust bar exactly as
                // any other no-PSK call.
                print("[QAudionCallIntegration] REFUSED static PSK advertisement from "
                    + "\(callerId.prefix(8))… — this contact has spoken the blinded advertisement "
                    + "before, so a static one is a downgrade (relay substituting logged "
                    + "fingerprints, or a genuine rollback). Session key derives WITHOUT a PSK; "
                    + "call NOT dropped. WIRE_SPEC §3.3.1.1")
            }
            if let advertised = bundle.pskFingerprints {
                if let staticFp = resolvedAdvert.staticFp,
                   let gated = Self.pskIfFingerprintMatches(eligiblePsks[staticFp], staticFp) {
                    // Symmetric-null convergence: select + echo ONLY when
                    // SHA-256(rawPsk)==staticFp, so the initiator never mixes a PSK we
                    // dropped — both ends mix the byte-equal PSK or both fall back to
                    // the no-PSK key (fixes the iOS↔desktop sealed-audio AEAD mismatch).
                    // W-PSKBLIND: the gate is applied to the STATIC fingerprint, which
                    // is dialect-independent. Checking it against a per-call tag would
                    // be a category error — the tag is an HMAC over the key, not a hash
                    // of it, so the gate would reject every v3 selection.
                    selectedFp = staticFp
                    selectedPsk = gated
                } else if !advertised.isEmpty {
                    // W-PSKMIX — bare log only, mirroring the ACCEPT (caller) path's
                    // own "no local PSK for fp" print below: previously this branch
                    // left selectedFp/selectedPsk nil with NO trace anywhere. The
                    // user-facing side of this silent downgrade is NOT this print —
                    // it is AssuranceState.decide()'s S7 (`expectedNfcStripped`)
                    // branch, which `emitKeyConfirmationTelemetry` already reaches
                    // automatically from this call's real n=0/mixRoles=[] outcome
                    // (fed by `onKcMacReady` unconditionally, whether or not a PSK
                    // was found) whenever this contact's `presenceFloor` or the
                    // peer's advertised roles say an NFC/PSK secret was expected —
                    // this print just makes the underlying cause visible in device
                    // logs instead of leaving no trace at all.
                    print("[QAudionCallIntegration] OFFER: peer advertised \(advertised.count) PSK fp(s), none held locally or SHA-256 gate failed — session key mixes NO psk callId=\(callId.prefix(8))…")
                }
            }

            // W-NFCCOMMON (2026-07-24, Pavel correction, device-confirmed bug) —
            // REINSTATED after being removed at W-TRANSCRIPTV2 (the old comment here
            // said "nothing actually consumes it", which stopped being true the
            // moment the mutual-NFC-in-common signal shipped: the INITIATOR's own
            // `mutualPeerAdvertisedRoles` computation reads THIS side's advertised
            // `pskFingerprints`/`pskRoles` from the peer's ACCEPT bundle exactly like
            // it reads the OFFER's — an ACCEPT that omits them makes the initiator's
            // "do we hold a matching NFC secret" signal go permanently false whenever
            // iOS is the RESPONDER, even though the secret genuinely exists on both
            // sides. Confirmed live 2026-07-24: Android-initiator↔iOS-responder call
            // reached S2 on iOS (which reads Android's OFFER advert fine) but S8 with
            // no mutual-NFC signal on Android (whose peer advert — this ACCEPT — was
            // empty). Same `pskAdvertEntries`/`fingerprintsForAdvertisement`/
            // `rolesForAdvertisement` computation the OFFER above uses (see that call
            // site's comment) — PSK selection is UNCHANGED (still single-selection via
            // `selectedPskFingerprint`), this is advert metadata only.
            let acceptPskVault = SovereignKeyVault()
            let acceptPskAdvertEntries: [PskAdvertising.Entry] = acceptPskVault.listPskEntries().compactMap { entry in
                guard let raw = (try? acceptPskVault.loadPsk(name: entry.name)) ?? nil, !raw.isEmpty else { return nil }
                return PskAdvertising.Entry(
                    name: entry.name,
                    origin: acceptPskVault.origin(name: entry.name),
                    material: raw,
                    createdAt: entry.createdAt
                )
            }
            // W-PSKBLIND — MIRROR the dialect the OFFER used. That is what gives this
            // leg no mixed window at all: whatever the initiator speaks, we answer in.
            //
            // W-UNKNOWNMIRROR (2026-07-25) — `.unknown` used to mirror as STATIC on the
            // reasoning that "with no shared secret there is no PSK for the static form to
            // expose". That was wrong: `.unknown` means nothing matched THE PEER'S
            // ADVERTISEMENT, not that we hold nothing, so this leg shipped the static
            // fingerprint of every key we hold plus the role array marking the NFC-tapped
            // ones. It is now blinded for every dialect except a real legacy peer — see
            // `PskAdvertResolver.buildAdvertisement`.
            let acceptAdvert = PskAdvertResolver.buildAdvertisement(
                dialect: resolvedAdvert.dialect,
                callId: callId,
                // OUR ephemeral for this leg — the one that goes out in
                // `ciphertext.x25519`, which is what the peer will derive our nonce
                // from. Anything else here and the initiator matches nothing.
                ownEphemeralX25519Pub: x25519Result.ephemeralPublicKey,
                candidates: PskAdvertising.candidatesForAdvertisement(acceptPskAdvertEntries)
            )
            let acceptAdvertisedPskFingerprints: [String] = acceptAdvert.fingerprints
            let acceptAdvertisedPskRoles: [Int]? = acceptAdvert.roles

            // W-UNKNOWNMIRROR — the notice iOS never had. Android and Desktop both warn
            // when they hold candidates and still end up with no PSK; this leg degraded in
            // total silence. ABSENT is the case that matters most: deleting the OFFER's
            // advert field needs no key material and forges nothing, so it is the cheapest
            // move a relay has. Signal only — nothing here touches the call (W-NOBRICK).
            if resolvedAdvert.dialect == .unknown,
               !PskAdvertising.candidatesForAdvertisement(acceptPskAdvertEntries).isEmpty {
                let n = bundle.pskFingerprints?.count
                // force-unwrap safe: reaching the innermost branch already
                // establishes n != nil (outer ternary) and n != 0 (inner
                // ternary) from the conditions themselves.
                // swiftlint:disable:next force_unwrapping
                let shape = n == nil ? "ABSENT" : (n == 0 ? "EMPTY" : "\(n!) entries in neither dialect")
                print("[QAudionCallIntegration] no PSK this call: peer advert \(shape) "
                    + "while we hold keys — session key derives WITHOUT a PSK. ABSENT can "
                    + "mean a relay stripped the field. WIRE_SPEC §3.3.1")
            }

            // 7. Build ACCEPT JSON.
            // W527: Android's kotlinx.serialization HandshakeBundle data
            // class declares `pqcPublicKey` and `x25519PublicKey` as
            // non-nullable `String` with NO default → both fields are
            // REQUIRED at parse time. Passing nil here makes
            // JSONEncoder omit them entirely, and Android then throws
            // `MissingFieldException: Fields [pqcPublicKey,
            // x25519PublicKey] are required for type with serial name
            // HandshakeBundle` (confirmed in A50 logcat 22:48:58 —
            // CallController$startOutgoing$$inlined$transitionHandshake).
            // Android's own ACCEPT path sets these to "" — match that
            // wire shape so the deserializer is happy.
            let accept = AndroidHandshakeBundle(
                kind: .accept,
                callId: callId,
                pqcPublicKey: "",
                x25519PublicKey: "",
                ciphertext: AndroidHandshakeBundle.Ciphertext(
                    pqc: pqcResult.ciphertext.base64EncodedString(),
                    x25519: x25519Result.ephemeralPublicKey.base64EncodedString()
                ),
                capabilities: Self.selfCapabilities(),
                pskFingerprints: acceptAdvertisedPskFingerprints,
                // W-PSKBLIND — the RECEIVED wire value, verbatim, not our static
                // fingerprint. Dialect-agnostic: the initiator resolves it through the
                // advertisement it composed. `selectedFp` (the static form) stays the
                // value everything downstream uses.
                selectedPskFingerprint: selectedPsk != nil ? resolvedAdvert.wireValue : nil,
                pskRoles: acceptAdvertisedPskRoles,
                // Echo the OFFER's own (rekeyNonce, rekeyRound) pair: both are bound into the
                // ACCEPT transcript, so a tampered/replayed round or nonce invalidates it.
                rekeyNonce: bundle.rekeyNonce,
                rekeyRound: bundle.rekeyRound
            )

            // Transcript v6: build and SIGN the ACCEPT, binding it to the verified OFFER
            // (`offerBinding = SHA-256(OFFER_v6)`, mandatory and non-empty) and carrying OUR OWN
            // DTLS certificate fingerprint. Through `offerBinding` this transcript — and so the
            // session key, the SAS and the KCMAC derived below — covers BOTH fingerprints.
            // W527 INVARIANT PRESERVED: `accept` keeps pqcPublicKey:""/x25519PublicKey:"" exactly;
            // `signedBundle` copies every other field verbatim.
            let fpSelf = try localDtlsFingerprint(callId: callId)
            guard let signerKey = localSignerIdentityKey, signerKey.count == 32,
                  let acceptT = Self.acceptTranscript(
                      from: accept, callId: callId, signerKeyRaw: signerKey,
                      offerBinding: verifiedOfferBinding, dtlsFingerprint: fpSelf) else {
                throw IntegrationError.handshakeAborted(code: "sign_unavailable")
            }
            let acceptToSend = try signedBundle(of: accept, transcript: acceptT, fingerprint: fpSelf)
            // `SHA-256(ACCEPT_v6)`: the KDF / SAS / KCMAC binding (F4 — unconditional).
            let acceptBinding = HandshakeTranscript.offerBinding(acceptT)
            let combined = Self.deriveTranscriptBoundSessionKey(
                pqcSharedSecret: pqcResult.sharedSecret,
                x25519Shared: x25519Result.sharedSecret,
                psk: selectedPsk,
                transcriptHash: acceptBinding
            )
            let wire = AndroidHandshakeEnvelope.serialize(callId: callId, bundle: acceptToSend)

            let normalizedOId = callId.lowercased()
            // I3 fix (2026-08-21) — content-based dedup, see
            // processedOfferFingerprintsByCall's doc for the full
            // rationale. sessionInitializedByCall (callId-only) is kept
            // for the 30s-timeout / reconnect-replay checks elsewhere,
            // which legitimately only care about "any handshake ever
            // completed for this call" — the duplicate-vs-fresh DECISION
            // below now also looks at the OFFER's own key material, so a
            // genuine re-key OFFER (fresh pqcPub/x25519Pub, same callId)
            // falls through to full reprocessing instead of being
            // discarded as a stale retransmit.
            let offerFingerprint = Data(SHA256.hash(data: pqcPub + x25519Pub)).base64EncodedString()
            let offerDedupKey = normalizedOId + "#" + offerFingerprint
            // isReKeyRound: this callId already completed a FULL handshake
            // round before this one arrived — i.e. this OFFER's key material
            // is new but the call itself is not. Distinguishing this matters
            // because `engine.initialize()` below does far more than key
            // rotation: it allocates BRAND NEW SessionManager instances and
            // rebuilds `audioProcessor`, resetting `audioProfileLatched` to
            // false and `audioProfile` to `.defaultProfile` — silently
            // discarding a call's negotiated long-audio-profile latch
            // mid-call (exactly the "wire-format change mid-call" the
            // constant-rate property forbids — see W-LONGAUDIO/W-ALL60 in
            // QAudionEngine.swift). Android's own re-key path never touches
            // its equivalent of this reset (`performReKey` calls
            // `pqcHandshake.initiate()` directly, never `startOutgoing`) —
            // a re-key round here must skip `engine.initialize()` the same
            // way and go straight to `engine.initSession()`, which is
            // already safe to call again mid-session (`state ==
            // .sessionActive` is an explicit allowed transition — see
            // QAudionEngine.initSession's guard — and SessionManager
            // .initSession is a pure key-derivation + atomic swap, safe to
            // re-run). See docs/security/I3_IOS_REKEY_DESIGN_2026-08-21.md
            // in the qaudion-android-new repo (cross-repo doc).
            let (alreadyInit, isReKeyRound) = lock.withLock { () -> (Bool, Bool) in
                let dup = processedOfferFingerprintsByCall.contains(offerDedupKey)
                let wasAlreadyHandshaked = sessionInitializedByCall.contains(normalizedOId)
                if !dup {
                    processedOfferFingerprintsByCall.insert(offerDedupKey)
                    acceptWireByOfferFingerprint[offerDedupKey] = wire
                    sessionInitializedByCall.insert(normalizedOId)
                    if handshakeStartedAt == nil { handshakeStartedAt = Date() }
                    // Capture the responder-side sender closure for
                    // W531 (WS-reconnect replay) so we don't depend on
                    // AppState re-supplying it.
                    retrySenderClosure = sendOpaqueRaw
                }
                return (dup, wasAlreadyHandshaked && !dup)
            }
            if alreadyInit {
                // Idempotent replay — re-emit the SAME bundle THIS OFFER
                // round produced (looked up by its own fingerprint, never a
                // different round's — a stale retransmit of the ORIGINAL
                // OFFER arriving after a later re-key must still get the
                // ORIGINAL ACCEPT back, not the re-key's).
                if let cached = lock.withLock({ acceptWireByOfferFingerprint[offerDedupKey] }) {
                    print("[QAudionCallIntegration] OFFER duplicate for callId=\(callId.prefix(8))… — replaying cached ACCEPT")
                    // W-MEDIAATACCEPT (option b) — I11: a duplicate-OFFER
                    // replay must obey the SAME hold gate as the first
                    // send — "mentre trattiene, niente replay, solo log".
                    try await emitJsonAccept(callId: callId, wire: cached, sendOpaqueRaw: sendOpaqueRaw, isRound1: round == 1)
                } else {
                    print("[QAudionCallIntegration] OFFER duplicate for callId=\(callId.prefix(8))… — session already initialised, skipping initSession")
                }
                return
            }
            print("[QAudionCallIntegration] OFFER for callId=\(callId.prefix(8))… — processing (fingerprint=\(offerFingerprint.prefix(12))…, reKey=\(isReKeyRound), roundsSeen=\(processedOfferFingerprintsByCall.count))")
            // Marker that this call's session key is bound to the signed transcript (read by
            // `isSessionKeyTranscriptBound`). Stored BEFORE any callback announces the new key, and only
            // for a round that is really accepted (never for a duplicate OFFER, whose
            // re-encapsulation differs).
            HandshakeTranscriptHashStore.shared.set(acceptBinding, forCallId: callId)
            // R-COMMIT-CHECK: the commitment of the round-1 OFFER this device answers, with the hash of
            // the ACCEPT it built for it (held until the human accept on the default path). Stored
            // before the ACCEPT can leave: a REVEAL only ever follows a SENT ACCEPT, and the first one
            // stored wins (a later different OFFER never replaces the answered commitment).
            if !isReKeyRound {
                guard let commitText = bundle.sasCommit,
                      let commitRaw = SasCommit.decodeCanonicalBase64(commitText, expectedLength: SasCommit.commitLength) else {
                    reportHandshakeFatal(callId: callId, reason: "handshake_malformed")
                    throw IntegrationError.handshakeAborted(code: "commit_missing")
                }
                sasCommit.beginCallee(callId: callId, commit: commitRaw)
                sasCommit.calleeSetAccept(callId: callId, acceptHash: acceptBinding)
            }
            // W-MEDIAATACCEPT (option b) — I11: the first responder ACCEPT
            // for this call. Held (not sent) when `mode == 1` and the human
            // has not accepted yet; the derivation/session-init below is
            // UNCHANGED either way — only the wire send is gated.
            try await emitJsonAccept(callId: callId, wire: wire, sendOpaqueRaw: sendOpaqueRaw, isRound1: !isReKeyRound)
            if !isReKeyRound {
                if replacesUnansweredOffer {
                    // The replaced round already initialised the engine, and a second `initialize()` from an active
                    // session is refused; `initSession` below re-keys it in place. An engine the replaced round
                    // never got to initialise is initialised here.
                    try? engine.initialize()
                } else {
                    try engine.initialize()
                }
            }
            // W479 — Android peer: use AdaptivePaddingController-compatible
            // audio scheme (static session key, no AAD, 2-byte len + 120B padding).
            // Byte-identical to Android FrameRelayTransport.send/decode +
            // AdaptivePaddingController.sealAudio/openAudio.
            // I3 — on a re-key round this re-keys the EXISTING session
            // managers in place (state == .sessionActive is an explicit
            // allowed transition) without touching the audio profile latch
            // or rebuilding the codec — see the isReKeyRound doc above.
            // MEDIA-3/4/5 — per-direction inner-audio keys/AAD/replay window,
            // only actually applied when negotiated (kill switch default
            // false — see `negotiatedInnerAudioAadV1`'s doc). Role assignment
            // reuses the SAME rule the outer M-15 sealer uses
            // (`PqcRtpFrameSealer.selfIsRoleA`, lexicographically-smaller
            // userId), so a future go-live can't disagree with the outer
            // layer about which side is "A". `epoch` reuses this round's
            // already-agreed CALL-3 re-key round number (both peers derive
            // the SAME value from the signed bundle) rather than a fresh,
            // possibly-divergent counter.
            let innerAadNegotiated = negotiatedInnerAudioAadV1
            let innerAadSelfIsRoleA = innerAadNegotiated
                ? PqcRtpFrameSealer.selfIsRoleA(resolveSelfUserId?() ?? "", callerId)
                : false
            let innerAadEpoch = UInt32(max(1, min(bundle.rekeyRound ?? 1, Int(UInt32.max))))
            try engine.initSession(sharedSecret: combined, adaptivePadding: true,
                                   innerAudioAadV1: innerAadNegotiated, callId: callId,
                                   selfIsRoleA: innerAadSelfIsRoleA, epoch: innerAadEpoch)
            recordKeyRound(callId: callId, key: combined, round: innerAadEpoch, transcriptHash: acceptBinding)
            // W-M15SEALERONCE: a re-key round must NOT rebuild the M-15 outer pair.
            fireRelaySessionReady(combined, callId: callId, isReKey: isReKeyRound, generation: entryGeneration)
            lock.withLock { state = .active }
            // W529: handshake reached active — kill the retry loop.
            offerRetryTask?.cancel()
            offerRetryTask = nil
            onStateChanged?(.active)
            onPqcSessionKeyEstablished?(combined)
            // W-MEDIAATACCEPT (option b) — §6: JSON responder OFFER path.
            onSessionKeyForCall?(combined, callId)
            // DISPLAY-ONLY: surface the PSK fingerprint negotiated on this
            // responder OFFER path (`selectedFp`, in scope from step 4).
            onPqcSessionKeyEstablishedWithPsk?(combined, selectedFp)
            // W-REKEYSYNC — only on a re-key round (never round 1, both
            // sides already share the same ReKeyScheduler default there),
            // and only when the peer sent a validated period. Untrusted
            // network input: clamp to the same (0, basePeriodMs] range
            // Android enforces before treating it as absent/fall back.
            if isReKeyRound, let peerPeriod = bundle.rekeyNextPeriodMs,
               peerPeriod > 0, Int64(peerPeriod) <= ReKeyScheduler.basePeriodMs {
                onPeerRekeyPeriodAdvertised?(Int64(peerPeriod))
            }
            // Phase 18 — v4 bootstrap (responder leg). Mirrors Android
            // PqcHandshake.kt:819-826 (`v4Ready`): self = our identity, peer = the
            // OFFER's signerIdentityKey (base64-decoded), transcriptHash = the
            // verified OFFER binding. `verifiedOfferBinding` is the SAME value our
            // ACCEPT signature bound (step (c) above) — byte-identical to Android's
            // `offerBindingForAccept`. NOTE: we deliberately do NOT gate on an
            // "authenticated verdict" (`v4OfferAuthenticated`). Android's `v4Ready`
            // requires ONLY that the identity pubkeys + the transcript binding are
            // present — NOT a `Decision.Ok` verdict — so it ALSO bootstraps v4 on
            // the W-NOBRICK warn/repin proceed paths (e.g. a freshly reinstalled
            // peer with a new identity → warn/repin verdict). If iOS additionally
            // required `v4OfferAuthenticated` it would SKIP the bootstrap while the
            // peer bootstraps and sends 0xE5 → iOS has no session → "non leggibile"
            // (BUG 2 asymmetry). A non-empty signed binding already proves a signed
            // OFFER; the SAS remains the terminal security gate (W-NOBRICK), exactly
            // as on Android. SKIP (no v4 bootstrap) unless ALL real inputs exist;
            // a placeholder would diverge and break interop.
            // `negotiatedRatchetV4` is the cross-platform AND (this build advertises
            // v4 AND the peer advertised it) — without it a one-sided v4 would send
            // 0xE5 frames the peer can't decrypt.
            let v4SelfIdPresent = (localSignerIdentityKey != nil)
            let v4PeerSik = bundle.signerIdentityKey.flatMap { Data(base64Encoded: $0) }
            let v4PeerIdValid = (v4PeerSik?.count == 32)
            let v4BindingPresent = !verifiedOfferBinding.isEmpty
            // I3 — v4 message-ratchet bootstrap must fire only on the
            // call's first handshake, never on a re-key round. See the
            // matching guard + full rationale in the .accept case's
            // v4InitFire below (same fix, both directions of the handshake).
            let v4Fire = negotiatedRatchetV4 && v4SelfIdPresent && v4PeerIdValid && v4BindingPresent && !isReKeyRound
            print("[PQC_DIAG_V4] responder callId=\(callId.prefix(8)) negotiatedV4=\(negotiatedRatchetV4) available=\(RatchetNative.available) selfId=\(v4SelfIdPresent) peer=\(v4PeerIdValid) bindingEmpty=\(verifiedOfferBinding.isEmpty) reKey=\(isReKeyRound) → fire=\(v4Fire)")
            if v4Fire,
               let selfId = localSignerIdentityKey,
               let peerId = v4PeerSik {
                onV4BootstrapReady?(callerId, combined, verifiedOfferBinding, selfId, peerId)
            }
            // W-KCMAC (ship step 5) — responder leg. Fires AFTER the session key
            // and the ACCEPT's binding both exist. `kcKey`/`transcript` stay
            // nil unless BOTH transcript bindings (`verifiedOfferBindingV2`
            // from step (b)/`acceptBindingV2ForKc` from step (c) above) and BOTH
            // identity keys are real — AppState must read that as "not attempted"
            // (`.absent`), never derive a MAC over placeholder/empty bytes.
            let kcPeerSupportsMix = bundle.capabilities?.pskMixV1 ?? false
            let kcN: Int
            let kcMixFingerprints: [Data]
            if let fp = selectedFp, let raw = DeviceRenewBlob.hexDecode(fp), raw.count == 32 {
                kcN = 1
                kcMixFingerprints = [raw]
            } else {
                kcN = 0
                kcMixFingerprints = []
            }
            var kcKeyForEvent: Data?
            var kcTranscriptForEvent: Data?
            if let ikResp = localSignerIdentityKey, let ikInit = v4PeerSik, ikInit.count == 32 {
                // initAdvert = the OFFER's OWN advert (the initiator's, in the
                // exact order it arrived on the wire). respAdvert = OUR OWN ACCEPT
                // advert, rebuilt from the SAME values we just put on the wire.
                //
                // W-KCMACROLES (2026-07-24) — this used to hardcode BOTH to nil with a
                // comment saying the ACCEPT "no longer advertises". That became false in
                // the same session the ACCEPT started advertising again (W-NFCCOMMON):
                // the peer rebuilds `respAdvert` from the ACCEPT it RECEIVED (non-empty),
                // so leaving ours empty diverges the `advEnc` bytes and fails kc_mac with
                // a FALSE S1_KC_FAILED verdict — the exact mirror of the initiator-side
                // bug fixed at the other transcript site. Both sides of the transcript
                // must always be rebuilt from what was ACTUALLY sent.
                let initEntries = KeyConfirmation.pskAdvertEntries(
                    fingerprintsHex: bundle.pskFingerprints, roles: bundle.pskRoles)
                let respEntries = KeyConfirmation.pskAdvertEntries(
                    fingerprintsHex: acceptAdvertisedPskFingerprints.isEmpty ? nil : acceptAdvertisedPskFingerprints,
                    roles: (acceptAdvertisedPskRoles?.isEmpty ?? true) ? nil : acceptAdvertisedPskRoles)
                if let t = KeyConfirmation.transcript(
                    offerBinding: verifiedOfferBinding,
                    acceptBinding: acceptBinding,
                    initAdvert: initEntries,
                    respAdvert: respEntries,
                    mixFingerprints: kcMixFingerprints,
                    mixId: Data(),
                    ikInit: ikInit,
                    ikResp: ikResp
                ) {
                    kcTranscriptForEvent = t
                    kcKeyForEvent = KeyConfirmation.deriveKcKey(sessionKey: combined)
                }
            }
            // W-PSKBLIND — read the ALREADY-RESOLVED mutual set instead of re-deriving
            // it from the wire. `mutualPeerAdvertisedRoles` intersected the peer's
            // advertised fingerprints with ours, which is only correct while the wire
            // carries static fingerprints: under §3.3.1 those values are per-call HMAC
            // tags, the intersection empties, and the "NFC in comune" chip goes dark on
            // precisely the calls it describes — silently, call still connected. The
            // roles here are the PEER's, recovered from which preimage reproduced its
            // tag rather than read off an array v3 does not send.
            let kcPeerAdvertisedRoles = Array(resolvedAdvert.mutualPeerRoles)
            onKcMacReady?(KcMacReadyEvent(
                peerId: callerId, callId: callId, isInitiator: false, sessionKey: combined,
                kcKey: kcKeyForEvent, transcript: kcTranscriptForEvent, n: kcN,
                peerSupportsMix: kcPeerSupportsMix, sigOk: offerSigOk,
                peerAdvertisedRoles: kcPeerAdvertisedRoles, selectedFp: selectedFp,
                round: innerAadEpoch
            ))

            // Pre-negotiation: the PQC OFFER is fully deserialised and our ACCEPT is on the
            // wire — tell the Android caller we are ringing locally so its
            // UI flips to "Ringing" and the server marks the WS-delivered
            // `call_incoming` as acknowledged (suppressing the backup VoIP
            // push). Sent AFTER the ACCEPT so the crypto round-trip is
            // already in flight when the caller starts ringing.
            // I3 — this is a call-SETUP signal ("we are now ringing"),
            // meaningless (and actively confusing to the caller's UI) once
            // the call is already Active. Only send it on the first round;
            // a re-key round must not re-announce "ringing" on an
            // already-connected call. Found by adversarial review, not the
            // original pass — see I3_IOS_REKEY_DESIGN_2026-08-21.md §8 in
            // the qaudion-android-new repo (cross-repo doc).
            if !callerId.isEmpty && !isReKeyRound {
                sendCallReady?(callId, callerId)
            }

        case .accept:
            // Originator side — completes the dual-hybrid combine using
            // the local hybrid privs we stashed in onAndroidCallSetupStarted.
            // W461: look up with both original and lowercase callId because
            // Android may echo a lowercase UUID even when iOS sent uppercase.
            //
            // I3 §5 — a re-key ACCEPT must decapsulate against the FRESH
            // keypair `performPqcReKey` generated for THIS round, never
            // against `localHybridKeysByCall` (zeroed and removed right
            // after the ORIGINAL handshake, step 7 below — reusing that
            // slot for a re-key would also risk a stale retransmit of the
            // ORIGINAL ACCEPT decapsulating with the WRONG private key).
            // `pendingReKeyAttempt` only exists while a re-key round this
            // integration itself initiated is in flight (single-call
            // architecture — one integration instance handles one call at
            // a time, same invariant `localHybridKeysByCall`'s own lookup
            // already relies on).
            let rekeyAttempt = lock.withLock { pendingReKeyAttempt }
            let isReKeyAccept = rekeyAttempt != nil
            // W-HSROUNDTIMING — second breadcrumb: ACCEPT reached this
            // side's dispatch. Skipped for re-key rounds (`handshakeStartedAt`
            // times the ORIGINAL handshake only, not each re-key round) so
            // this stays a clean signal for "did the peer's ACCEPT for the
            // opening handshake ever arrive" — see the send-confirmed and
            // derive-complete siblings.
            if !isReKeyAccept, let startedAt = lock.withLock({ handshakeStartedAt }) {
                logTiming("hs-accept-received", msInt: Int(Date().timeIntervalSince(startedAt) * 1000), ok: true)
            }
            let localKeys = rekeyAttempt?.localKeys
                         ?? localHybridKeysByCall[callId]
                         ?? localHybridKeysByCall[callId.lowercased()]
            guard let local = localKeys else {
                let stashed: String = localHybridKeysByCall.keys.map { String($0.prefix(8)) }.joined(separator: ",")
                print("[QAudionCallIntegration] ACCEPT for callId=\(callId.prefix(8))… but no local hybrid keys stashed (stashedCallIds=[\(stashed)]) — was onAndroidCallSetupStarted ever called?")
                return
            }
            guard let ct = bundle.ciphertext else {
                print("[QAudionCallIntegration] ACCEPT for callId=\(callId.prefix(8))… missing ciphertext block")
                return
            }
            guard let pqcCt = Data(base64Encoded: ct.pqc) else {
                print("[QAudionCallIntegration] ACCEPT base64-decode of ciphertext.pqc failed (\(ct.pqc.count) chars)")
                return
            }
            guard let x25519EphPub = Data(base64Encoded: ct.x25519) else {
                print("[QAudionCallIntegration] ACCEPT base64-decode of ciphertext.x25519 failed (\(ct.x25519.count) chars)")
                return
            }

            // I3 §5 — early duplicate short-circuit, found by adversarial
            // review (2026-08-21). `sentOfferTranscriptByCall` (read a few
            // lines below by the verify step) is keyed by plain callId, and
            // `performPqcReKey` OVERWRITES it with each new round's own
            // transcript. A RETRANSMIT of an ACCEPT from an EARLIER round
            // (e.g. the original handshake's ACCEPT, redelivered late after
            // a re-key has since started) would otherwise be verified
            // against the WRONG (current round's) offer_binding — a
            // spurious `sig_invalid`/`identity_key_mismatch` that clears
            // the peer's stored SAS and forces re-confirmation on an
            // otherwise-healthy, already-rekeyed call (W-NOBRICK keeps the
            // call itself alive, but the UX regression is real and was
            // fully avoidable). The content-fingerprint dedup a few lines
            // below already correctly identifies a retransmit as a
            // duplicate — computed here, earlier, so a duplicate skips
            // verification entirely instead of running it against a
            // transcript that no longer belongs to it. A genuinely NEW
            // ACCEPT (first arrival of the original's, of any re-key
            // round's) is unaffected — it always verifies against whatever
            // is CURRENTLY stashed, which is correct because it IS the
            // current round.
            let normalizedIdForDedup = callId.lowercased()
            let acceptFingerprint = Data(SHA256.hash(data: pqcCt + x25519EphPub)).base64EncodedString()
            let acceptDedupKey = normalizedIdForDedup + "#" + acceptFingerprint
            if lock.withLock({ processedAcceptFingerprintsByCall.contains(acceptDedupKey) }) {
                print("[QAudionCallIntegration] ACCEPT duplicate (pre-verify) for callId=\(callId.prefix(8))… — skipping verify + initSession")
                // R-COMMIT-REVEAL: a byte-identical duplicate of the BOUND round-1 ACCEPT (a callee-side
                // retransmit) means its REVEAL may have been lost: re-send the identical REVEAL, within
                // the per-call budget. A duplicate of any other (rekey) ACCEPT never triggers one.
                let isBoundAccept = lock.withLock { boundRound1AcceptKeyByCall[normalizedIdForDedup] == acceptDedupKey }
                if !isReKeyAccept, isBoundAccept, let wire = sasCommit.callerResendReveal(callId: callId) {
                    await sendSasReveal(wire, callId: callId, resend: true)
                }
                return
            }
            // R-COMMIT-BIND: once round 1 is bound to an ACCEPT, any OTHER round-1 ACCEPT (a sibling
            // device, a forgery) is dropped here, before it is verified: it is never used for keys, SAS
            // or REVEAL, and it cannot taint the call's identity bookkeeping.
            if !isReKeyAccept, sasCommit.callerHasBound(callId: callId) {
                print("[QAudionCallIntegration] ACCEPT for callId=\(callId.prefix(8))… is a different round-1 ACCEPT after binding — dropped")
                return
            }
            // R-COMMIT-BIND: a re-key attempt in flight only ever answers a round >= 2. An ACCEPT that echoes
            // round 1 while one is in flight is a sibling's or a forged round-1 ACCEPT arriving late: it must
            // not be taken for the re-key's answer (verified against the wrong OFFER and decapsulated with
            // the re-key's keys), so it is dropped like every other non-bound round-1 ACCEPT.
            if Self.isStrayRound1Accept(isReKeyAccept: isReKeyAccept, echoedRound: bundle.rekeyRound) {
                print("[QAudionCallIntegration] ACCEPT for callId=\(callId.prefix(8))… echoes round 1 while a re-key is in flight — dropped")
                return
            }
            // A round-1 ACCEPT echoes the OFFER's round: anything else with no re-key attempt in flight is a
            // stale or forged round and is never bound.
            if !isReKeyAccept, bundle.rekeyRound != 1 {
                print("[QAudionCallIntegration] ACCEPT for callId=\(callId.prefix(8))… echoes round \(bundle.rekeyRound ?? 0) with no re-key attempt in flight — dropped")
                return
            }

            // Transcript v6 — VERIFY the incoming ACCEPT (+ offer_binding) BEFORE any crypto work or
            // session init. The expected binding is recomputed from the `OFFER_v6` WE SENT (stashed
            // at send time), so a real ACCEPT cannot be paired with a forged OFFER (WIRE_SPEC §3.7,
            // threat model). `.malformed` ENDS the call; `.abort` (invalid signature / unknown
            // identity — W-NOBRICK) fires `onHandshakeIdentityUnverified` and STILL falls through to
            // decapsulate + initSession: the crypto session (and therefore the SAS words) must exist
            // for the user to have anything to reconfirm, while MEDIA is held behind that
            // reconfirmation. `.authenticated` commits the pin / capability pins.
            let sentOfferT: Data? = lock.withLock { sentOfferTranscriptByCall[callId.lowercased()] }
            guard let sentOfferTranscript = sentOfferT else {
                print("[QAudionCallIntegration] ACCEPT for callId=\(callId.prefix(8))… but no sent-OFFER transcript is stashed — ignoring")
                return
            }
            let expectedOfferBinding = HandshakeTranscript.offerBinding(sentOfferTranscript)
            let acceptCheck = evaluateInbound(
                bundle: bundle, callId: callId, peerId: callerId, peerDeviceId: callerDeviceId,
                expectedOfferBinding: expectedOfferBinding)
            // R-COMMIT-BIND: bind round 1 ATOMICALLY (under the book's lock, before any suspension point)
            // to the first ACCEPT that parsed and passed the malformed checks. An invalid signature or an
            // unresolved identity still binds: the call then goes held, and the SAS is exactly what it
            // needs. A malformed ACCEPT (handled by the switch below) never binds and never reveals.
            var round1RevealWire: String?
            if !isReKeyAccept, let boundTranscript = acceptCheck.transcript {
                var isMalformedVerdict = false
                if case .malformed = acceptCheck.verdict { isMalformedVerdict = true }
                if !isMalformedVerdict {
                    let (decision, revealWire) = sasCommit.callerOnAccept(
                        callId: callId, acceptHash: HandshakeTranscript.offerBinding(boundTranscript),
                        senderDeviceId: envelopeSenderDeviceId)
                    switch decision {
                    case .bindAndReveal:
                        round1RevealWire = revealWire
                        lock.withLock { boundRound1AcceptKeyByCall[normalizedIdForDedup] = acceptDedupKey }
                    case .resendReveal, .drop:
                        print("[QAudionCallIntegration] ACCEPT for callId=\(callId.prefix(8))… lost the round-1 binding race — dropped")
                        return
                    }
                }
            }
            // W-KCMAC — `AssuranceState.decide`'s `sigOk` input for this leg.
            var acceptSigOk = false
            switch acceptCheck.verdict {
            case .malformed(let code):
                print("[QAudionCallIntegration] ACCEPT malformed code=\(code) peer=\(callerId.prefix(8))… callId=\(callId.prefix(8))… — ending the call")
                reportHandshakeFatal(callId: callId, reason: "handshake_malformed")
                throw IntegrationError.handshakeAborted(code: code)
            case .abort(let code):
                print("[QAudionCallIntegration] ⚠️ ACCEPT verify code=\(code) peer=\(callerId.prefix(8))… callId=\(callId.prefix(8))… — NOT aborting; proceeding, VERIFY THE SAS")
                if code == "identity_key_mismatch" {
                    onUnauthenticatedIdentityChange?(callerId)
                }
                // XC-1 — present-but-INVALID signature (forgery): revoke the peer's SAS
                // verification so the in-call SAS re-confirmation is required.
                if code == "sig_invalid" {
                    onInvalidHandshakeSignature?(callerId)
                }
                // P0-3 — same media-hold signal as the OFFER side.
                markHeld(callId: callId)
                onHandshakeIdentityUnverified?(callId, code)
            case .authenticated(let tofuPinKey, let v4Capable, let srtpDirKeyV1Capable, let ratchetV5Capable):
                applyAuthenticatedSideEffects(peerId: callerId, deviceId: callerDeviceId, tofuPinKey: tofuPinKey, v4Capable: v4Capable, srtpDirKeyV1Capable: srtpDirKeyV1Capable, ratchetV5Capable: ratchetV5Capable)
                acceptSigOk = true
            case .authenticatedRepinFromPublished(let deviceKey, let v4Capable, let srtpDirKeyV1Capable, let ratchetV5Capable):
                // D11 trust-on-publish: set-proven rotation → silent additive re-pin per-(peer,
                // device); NO banner.
                print("[QAudionCallIntegration] ACCEPT set-proven rotation peer=\(callerId.prefix(8))… dev=\((callerDeviceId ?? "—").prefix(8))… — silent re-pin, proceeding")
                applyAuthenticatedSideEffects(peerId: callerId, deviceId: callerDeviceId, tofuPinKey: deviceKey, v4Capable: v4Capable, srtpDirKeyV1Capable: srtpDirKeyV1Capable, setProven: true, ratchetV5Capable: ratchetV5Capable)
                acceptSigOk = true
            }
            guard let acceptT = acceptCheck.transcript, let peerFp = acceptCheck.peerFingerprint else {
                reportHandshakeFatal(callId: callId, reason: "handshake_malformed")
                throw IntegrationError.handshakeAborted(code: "transcript_unbuildable")
            }
            // `SHA-256(ACCEPT_v6)`: the KDF / SAS / KCMAC binding (F4 — unconditional).
            let acceptBinding = HandshakeTranscript.offerBinding(acceptT)
            // Pin the acceptor's DTLS fingerprint (once per call; a re-key round MUST carry the same
            // one — F9). Until it is pinned the PeerConnection applies no remote SDP (the answer SDP
            // may arrive before this bundle: it is buffered).
            guard pinPeerDtlsFingerprint(callId: callId, fingerprint: peerFp) else {
                throw IntegrationError.handshakeAborted(code: "dtls_fp_mismatch")
            }

            // 1. ML-KEM-1024 decapsulate with our local PQC priv.
            let pqcSs = try pqc.decapsulate(ciphertext: pqcCt, privateKey: local.pqcPair.privateKey)

            // 2. X25519 ECDH against the responder's ephemeral pub
            //    (carried in `ciphertext.x25519`) using our local
            //    long-term X25519 priv stashed at OFFER time.
            let remoteEph: Curve25519.KeyAgreement.PublicKey
            do {
                remoteEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: x25519EphPub)
            } catch {
                print("[QAudionCallIntegration] ACCEPT remote X25519 pub parse failed: \(error)")
                return
            }
            let x25519Secret = try local.x25519Priv.sharedSecretFromKeyAgreement(with: remoteEph)
            let x25519Ss = x25519Secret.withUnsafeBytes { Data($0) }

            // 3. The PSK the responder selected (its `selectedPskFingerprint`, echoed verbatim in the
            // dialect WE advertised) resolved back to our own vault PSK. Getting this wrong is not a
            // downgrade, it is a BREAK: the responder already derived WITH the PSK, so a miss here
            // diverges the session key and every received frame fails to unseal.
            let selectedFpStr = bundle.selectedPskFingerprint ?? ""
            let selectedPskAccept: Data? = Self.pskForEchoedSelection(
                echo: selectedFpStr,
                callId: callId,
                ownEphemeralX25519Pub: local.x25519Priv.publicKey.rawRepresentation
            )
            if selectedFpStr.isEmpty {
                print("[QAudionCallIntegration] ACCEPT — selectedPskFingerprint empty, session key mixes NO psk callId=\(callId.prefix(8))…")
            }

            // 4. Derive the session key from the transcript-bound KDF (F4 — unconditional): the
            // `SHA-256(ACCEPT_v6)` binds both signers' identity keys, both DTLS fingerprints, the
            // ciphertexts and the selected PSK, so any substitution — even with stripped
            // signatures — gives the two legs different keys, SAS words and KCMACs.
            let combined = Self.deriveTranscriptBoundSessionKey(
                pqcSharedSecret: pqcSs,
                x25519Shared: x25519Ss,
                psk: selectedPskAccept,
                transcriptHash: acceptBinding
            )

            // I3 §5 — stale-attempt guard, found by adversarial review
            // (2026-08-21): `rekeyAttempt` above was snapshotted BEFORE the
            // crypto work this case just did, some of which can suspend. If this
            // round's OWN timeout fires WHILE this function is suspended there,
            // `pendingReKeyAttempt` gets cleared and performPqcReKey already
            // returned `false` to its caller — but this ACCEPT, still
            // in-flight, would otherwise reach `engine.initSession()` below
            // and install ITS key anyway (ML-KEM decapsulation doesn't throw
            // on a stale-but-structurally-valid ciphertext, it just returns
            // SOME shared secret), silently overriding the "never brick"
            // property `performPqcReKey`'s deferred-swap design was supposed
            // to guarantee. Worse: if a NEW re-key round had already started
            // in the meantime, this stale ACCEPT's resolution would grab and
            // wrongly resolve THAT round's continuation (see the resolve-time
            // `.id` check below) with THIS round's key. Bail out before
            // touching the engine or any dedup/session state — a stale
            // ACCEPT for an attempt that's no longer the live one is
            // discarded, exactly like a lost/never-arriving ACCEPT is
            // (performPqcReKey already returned false for it).
            if isReKeyAccept {
                let stillLive = lock.withLock { pendingReKeyAttempt?.id == rekeyAttempt?.id }
                guard stillLive else {
                    print("[QAudionCallIntegration] ACCEPT for callId=\(callId.prefix(8))… arrived for a re-key attempt that already resolved/timed out — discarding stale ACCEPT")
                    return
                }
            }

            // 5. Double-ACCEPT guard — the AUTHORITATIVE, atomic check-and-insert
            //    (the early return right after ct/x25519EphPub decode above is
            //    only a cheap pre-verify optimization for the common retransmit
            //    case; two near-simultaneous copies of the same ACCEPT could
            //    both pass that early check before either inserts, so this
            //    lock-guarded check-and-insert is what actually prevents a
            //    double session-install). I3 §5 — content-based dedup, symmetric
            //    to the OFFER-side fix (see processedAcceptFingerprintsByCall's
            //    doc): keyed by the ACCEPT's own ciphertext, not callId alone,
            //    so a genuine re-key ACCEPT (fresh ciphertext, same callId) is
            //    NOT mistaken for a duplicate of the ORIGINAL ACCEPT and
            //    silently discarded — the same bug class §4 fixed on the
            //    responder side.
            let alreadyInit = lock.withLock {
                let r = processedAcceptFingerprintsByCall.contains(acceptDedupKey)
                if !r {
                    processedAcceptFingerprintsByCall.insert(acceptDedupKey)
                    sessionInitializedByCall.insert(normalizedIdForDedup)
                }
                return r
            }
            if alreadyInit {
                print("[QAudionCallIntegration] ACCEPT duplicate for callId=\(callId.prefix(8))… — session already initialised, skipping initSession")
                return
            }
            print("[QAudionCallIntegration] ACCEPT accepted for callId=\(callId.prefix(8))… reKey=\(isReKeyAccept) — initialising session")
            // SAS: the in-call words derive from the session key AND this transcript hash. Stored
            // BEFORE any callback announces the new key.
            HandshakeTranscriptHashStore.shared.set(acceptBinding, forCallId: callId)

            // 6. Initialise the audio session and fire the broker hook. No
            //    engine.initialize() call in this case (unlike the .offer
            //    case) — engine.initSession() alone is already safe to call
            //    again mid-session, so this step needed no isReKeyRound
            //    guard to begin with.
            // W479 — Android peer (caller side): same AdaptivePadding scheme.
            // MEDIA-3/4/5 — same negotiated per-direction inner-audio keys/AAD/
            // replay window as the .offer branch above; see its comment.
            let innerAadNegotiatedCaller = negotiatedInnerAudioAadV1
            let innerAadSelfIsRoleACaller = innerAadNegotiatedCaller
                ? PqcRtpFrameSealer.selfIsRoleA(resolveSelfUserId?() ?? "", callerId)
                : false
            let innerAadEpochCaller = UInt32(max(1, min(bundle.rekeyRound ?? 1, Int(UInt32.max))))
            try engine.initSession(sharedSecret: combined, adaptivePadding: true,
                                   innerAudioAadV1: innerAadNegotiatedCaller, callId: callId,
                                   selfIsRoleA: innerAadSelfIsRoleACaller, epoch: innerAadEpochCaller)
            recordKeyRound(callId: callId, key: combined, round: innerAadEpochCaller, transcriptHash: acceptBinding)
            // R-COMMIT-REVEAL: the REVEAL leaves right after the round-1 session is installed and BEFORE
            // this leg's KCMAC (`onKcMacReady` below), awaited so the two share the socket in this order;
            // it does not wait for `call_accepted` or any UI step.
            if let wire = round1RevealWire {
                await sendSasReveal(wire, callId: callId, resend: false)
            }
            // W-HSROUNDTIMING — third breadcrumb: decapsulation + session-key
            // derivation actually completed (engine.initSession didn't
            // throw). Paired with hs-offer-sent/hs-accept-received above —
            // a stuck-in-.fallback call missing ONLY this one now points
            // straight at decap/derivation, not the network legs.
            if !isReKeyAccept, let startedAt = lock.withLock({ handshakeStartedAt }) {
                logTiming("hs-derive-complete", msInt: Int(Date().timeIntervalSince(startedAt) * 1000), ok: true)
            }
            // W-M15SEALERONCE: a re-key round must NOT rebuild the M-15 outer pair.
            fireRelaySessionReady(combined, callId: callId, isReKey: isReKeyAccept, generation: entryGeneration)
            lock.withLock {
                state = .active
                // 7. Zero the stashed privs immediately — the session key is
                //    now in the engine, the ephemeral keys are no longer
                //    needed. Clearing the dictionary entry releases the
                //    PqcKeyExchange.KeyPair (which has its own destroy hook)
                //    and the Curve25519 PrivateKey (CryptoKit will deinit
                //    the wrapped opaque handle on dealloc). Zeroing
                //    earlier risks the second-ACCEPT branch trying to
                //    decap with empty bytes. No-op on a re-key round (this
                //    slot was already removed after the ORIGINAL handshake).
                localHybridKeysByCall.removeValue(forKey: callId)
            }
            // I3 §5 — resolve performPqcReKey's awaiting continuation now
            // that the new key is installed. The `stillLive` gate above
            // already guarantees `pendingReKeyAttempt?.id == rekeyAttempt?.id`
            // at this point (nothing between there and here can start a NEW
            // re-key round — that only happens from a fresh
            // performPqcReKey call, and the glare guard there requires
            // `pendingReKeyAttempt == nil`, which isn't true again until
            // THIS resolution clears it a few lines down). The `.id` check
            // is repeated here anyway, matching the send-failure/timeout
            // paths' own pattern exactly, rather than relying on that
            // invariant holding across a future edit to either function.
            if isReKeyAccept {
                let resume: ((Data?) -> Void)? = lock.withLock {
                    guard pendingReKeyAttempt?.id == rekeyAttempt?.id else { return nil }
                    let r = pendingReKeyAttempt?.resume
                    pendingReKeyAttempt = nil
                    return r
                }
                resume?(combined)
            }
            onStateChanged?(.active)
            onPqcSessionKeyEstablished?(combined)
            // W-MEDIAATACCEPT (option b) — §6: JSON caller ACCEPT-received path.
            onSessionKeyForCall?(combined, callId)
            // The consumers match on the STATIC fingerprint of the PSK (the in-call key panel's
            // vault lookup and the key-confirmation transcript), not on the wire echo.
            // `selectedFpStr` is `bundle.selectedPskFingerprint` = the W-PSKBLIND **wire** value:
            // since bb8affd that is a per-call blinded HMAC tag, NOT the static SHA-256(psk)
            // fingerprint, so it would never resolve there. Resolve the echo to the actual PSK
            // (same helper both derivation branches above already use) and hand over that PSK's
            // canonical static fingerprint. The responder path was already correct: it emits
            // `selectedFp`, kept in static form precisely for this.
            let establishedPskFp: String? = Self.pskForEchoedSelection(
                echo: selectedFpStr,
                callId: callId,
                ownEphemeralX25519Pub: local.x25519Priv.publicKey.rawRepresentation
            ).map { PskAdvertising.canonicalFingerprint(forPsk: $0) }
            if !selectedFpStr.isEmpty && establishedPskFp == nil {
                print("[QAudionCallIntegration] ⚠️ ACCEPT echoed selection did not resolve to a vault PSK callId=\(callId.prefix(8))… — the PSK panel and the key confirmation will not see it")
            }
            onPqcSessionKeyEstablishedWithPsk?(combined, establishedPskFp)
            // Phase 18 — v4 bootstrap (initiator leg). Mirrors Android
            // PqcHandshake.kt:333-335: self = our identity, peer = the ACCEPT's
            // signerIdentityKey (base64-decoded), transcriptHash = the binding of
            // the OFFER WE SENT. We recompute that binding from the stashed sent-
            // OFFER transcript (`sentOfferTranscriptByCall`, populated only when we
            // actually signed the OFFER) via the SAME `HandshakeTranscript.
            // offerBinding` helper the responder/verify path uses — so it byte-
            // matches Android's `sentOfferBinding` (== the responder's
            // `offerBindingForAccept`). Split into explicit steps so the type-
            // checker never explores the `withLock`→`map`→`??` chain as one
            // expression (CLAUDE.md §13). SKIP the v4 bootstrap
            // unless ALL three real inputs exist; a placeholder would diverge from
            // the peer's v4 session and break interop.
            // `negotiatedRatchetV4` is the cross-platform AND (this build advertises
            // v4 AND the responder's ACCEPT advertised it, captured at the top of
            // onAndroidBundleReceived) — without it a one-sided v4 would diverge.
            // NOTE: this initiator gate already mirrors Android's `v4Ready`
            // (PqcHandshake.kt:819-826) — it does NOT require an "authenticated
            // verdict"; the presence of our sent-OFFER transcript binding already
            // proves WE signed the OFFER, so a non-empty `sentBinding` is the
            // initiator's equivalent of `handshakeTranscriptHash != null`. The SAS
            // remains the terminal security gate (W-NOBRICK), as on Android.
            let sentOfferTForV4: Data? = lock.withLock { sentOfferTranscriptByCall[callId.lowercased()] }
            let v4InitSelfIdPresent = (localSignerIdentityKey != nil)
            let v4InitPeerSik = bundle.signerIdentityKey.flatMap { Data(base64Encoded: $0) }
            let v4InitPeerIdValid = (v4InitPeerSik?.count == 32)
            let v4InitBindingPresent = (sentOfferTForV4 != nil)
            // I3 (2026-08-21) — v4 message-ratchet bootstrap must fire ONLY
            // on the call's very first handshake, never on a re-key round.
            // onV4BootstrapReady's consumer (AppState.sharedV4Ratchet
            // .bootstrapV4AndPersist) unconditionally OVERWRITES the
            // persisted v4 CHAT ratchet session for this contact — that is
            // the message layer, not the call's audio/video key. Re-firing
            // it every ~5 minutes during a call would silently reset a
            // contact's chat ratchet chain state mid-call, making any chat
            // message in flight at that moment permanently undecryptable
            // (confirmed by reading MessageRatchet's decrypt path: fail-
            // closed, no fallback, no state kept on failure). Real gap
            // found investigating a spun-off follow-up from the I3 re-key
            // fix — same root pattern (Android's finalize()/
            // persistMessagePsk() has the identical unconditional call and
            // needs the mirrored isReKeyRound guard there too).
            let v4InitFire = negotiatedRatchetV4 && v4InitSelfIdPresent && v4InitPeerIdValid && v4InitBindingPresent && !isReKeyAccept
            print("[PQC_DIAG_V4] initiator callId=\(callId.prefix(8)) negotiatedV4=\(negotiatedRatchetV4) available=\(RatchetNative.available) selfId=\(v4InitSelfIdPresent) peer=\(v4InitPeerIdValid) bindingEmpty=\(!v4InitBindingPresent) reKey=\(isReKeyAccept) → fire=\(v4InitFire)")
            if v4InitFire,
               let selfId = localSignerIdentityKey,
               let peerId = v4InitPeerSik,
               let sentOfferT = sentOfferTForV4 {
                let sentBinding = HandshakeTranscript.offerBinding(sentOfferT)
                onV4BootstrapReady?(callerId, combined, sentBinding, selfId, peerId)
            }
            // W-KCMAC (ship step 5) — initiator leg, the CALLER-side twin of the
            // responder's fire above. `offerBindingV2ForKc` is OUR OWN sent-OFFER
            // binding (hoisted out of the `if verificationEnabled` block above
            // at step (d)); `acceptBindingV2ForKc` is reconstructed HERE (the
            // ACCEPT's own transcript wasn't stashed — only its byte-length-
            // prefixed pieces were used transiently inside `evaluateVerdict`)
            // using the SAME "continuity, not trust" convention the OFFER-verify
            // abort branch above already uses: the bundle's OWN carried
            // `signerIdentityKey`, not necessarily the pinned/set-proven key —
            // KCMAC is a redundant integrity check on top of, not a substitute
            // for, the Ed25519 signature verdict already evaluated above.
            let kcCallerPeerSupportsMix = bundle.capabilities?.pskMixV1 ?? false
            let kcCallerN: Int
            let kcCallerMixFingerprints: [Data]
            // W-KCMACBLIND — same defect class as the static-fingerprint fix above,
            // same file, found by the follow-up sweep for other consumers of
            // `selectedFpStr`. The RESPONDER'S mirror of this block (:1817-1819)
            // hex-decodes `selectedFp`, the STATIC form; using the raw wire echo
            // here made the two legs hash different `kc_mac` transcripts on
            // every PSK call iOS placed — a false S1 KC_FAILED "active attack"
            // verdict, which `ContactsStore.applyAssuranceOutcome` then persists
            // as a suspended contact. `establishedPskFp` (:2177) is the same
            // already-resolved static fingerprint the PSK panel uses —
            // reusing it here is also what makes `kcCallerN` agree with whether
            // a PSK actually entered the session key, instead of reporting 1
            // whenever the echo was merely non-empty.
            if let fp = establishedPskFp, let raw = DeviceRenewBlob.hexDecode(fp), raw.count == 32 {
                kcCallerN = 1
                kcCallerMixFingerprints = [raw]
            } else {
                kcCallerN = 0
                kcCallerMixFingerprints = []
            }
            var kcCallerKeyForEvent: Data?
            var kcCallerTranscriptForEvent: Data?
            // `v4InitPeerSik` (computed just above for the v4 bootstrap gate) is
            // the SAME decoded peer identity key KCMAC needs — reused, not
            // re-decoded.
            if let ikInit = localSignerIdentityKey,
               let ikResp = v4InitPeerSik, ikResp.count == 32 {
                // initAdvert = OUR OWN OFFER's advert (stashed at send time, step
                // (a)'s `sentOfferPskFingerprintsByCall` + `sentOfferPskRolesByCall`),
                // rebuilt with the REAL roles we put on the wire.
                // respAdvert = the ACCEPT's OWN advert (the responder's, exactly as
                // received on the wire).
                //
                // W-KCMACROLES (2026-07-24) — `roles:` was hardcoded `nil` here, with a
                // comment claiming "the OFFER bundle itself never carr[ies] a pskRoles
                // array today". That stopped being true when the OFFER started sending
                // real roles (commit e3bd816): the peer rebuilds `initAdvert` from the
                // received OFFER (real roles) while we rebuilt ours all-zero, so the
                // `advEnc` pair bytes diverged and every call advertising an NFC-origin
                // key (role=1) failed kc_mac -> FALSE S1_KC_FAILED "active attack"
                // verdict + a persisted suspended-badge security event on the contact.
                // Device-confirmed on call db4e5b20.
                let (sentInitFps, sentInitRoles) = lock.withLock {
                    (sentOfferPskFingerprintsByCall[callId.lowercased()],
                     sentOfferPskRolesByCall[callId.lowercased()])
                }
                let initEntries = KeyConfirmation.pskAdvertEntries(
                    fingerprintsHex: (sentInitFps?.isEmpty ?? true) ? nil : sentInitFps,
                    roles: (sentInitRoles?.isEmpty ?? true) ? nil : sentInitRoles)
                let respEntries = KeyConfirmation.pskAdvertEntries(
                    fingerprintsHex: bundle.pskFingerprints, roles: bundle.pskRoles)
                if let t = KeyConfirmation.transcript(
                    offerBinding: expectedOfferBinding,
                    acceptBinding: acceptBinding,
                    initAdvert: initEntries,
                    respAdvert: respEntries,
                    mixFingerprints: kcCallerMixFingerprints,
                    mixId: Data(),
                    ikInit: ikInit,
                    ikResp: ikResp
                ) {
                    kcCallerTranscriptForEvent = t
                    kcCallerKeyForEvent = KeyConfirmation.deriveKcKey(sessionKey: combined)
                }
            }
            // W-PSKBLIND — the RESPONDER's own advertised list, resolved in whichever
            // dialect it used, so the "NFC in comune" signal survives the blinded
            // advertisement. This used to intersect the peer's wire fingerprints with a
            // locally-rebuilt fingerprint set; under §3.3.1 those wire values are
            // per-call tags and the intersection empties, blanking the chip silently.
            //
            // Preserved from the set it replaces: `.callDerived` rows are excluded, and
            // fingerprints are recomputed FRESH from the raw material rather than read
            // from the cached Keychain label (W-STALEFP), which can predate
            // `canonicalFingerprint` becoming the write-time label.
            //
            // The responder's ephemeral for ITS leg is the one inside the ciphertext,
            // NOT `bundle.x25519PublicKey` (empty on an ACCEPT) — the wrong one here
            // yields a silently empty result.
            let kcCallerVault = SovereignKeyVault()
            let kcCallerCandidates: [PskAdvertResolver.Candidate] = kcCallerVault.listPskNames()
                .sorted()
                .compactMap { name in
                    guard PskAdvertising.isEligibleMatchCandidate(origin: kcCallerVault.origin(name: name)),
                          let raw = (try? kcCallerVault.loadPsk(name: name)) ?? nil, !raw.isEmpty
                    else { return nil }
                    return PskAdvertResolver.Candidate(
                        staticFp: PskAdvertising.canonicalFingerprint(forPsk: raw),
                        psk: raw,
                        localRole: 0
                    )
                }
            let kcCallerResolved = PskAdvertResolver.resolve(
                receivedAdvert: bundle.pskFingerprints,
                receivedRoles: bundle.pskRoles,
                callId: callId,
                senderEphemeralX25519Pub: x25519EphPub,
                candidates: kcCallerCandidates,
                // §3.3.1.1 — the responder's own advertisement is subject to the same
                // refusal. Its selection is not used on this leg (the echo is), but its
                // MUTUAL set feeds the §D4 gate and the NFC-in-common chip, and those must
                // not act on an advertisement we would have refused.
                refuseStaticFallback: Self.pskDialectLatch.hasSpokenBlindedAdvert(contactId: callerId)
            )
            // Same reasoning as the responder leg: this is the RESPONDER's own advert under
            // the RESPONDER's own ephemeral key, so a v3 result is a fact about their build.
            if kcCallerResolved.dialect == .v3Blinded {
                Self.pskDialectLatch.rememberSpokeBlindedAdvert(contactId: callerId)
            }
            let kcCallerPeerAdvertisedRoles = Array(kcCallerResolved.mutualPeerRoles)
            onKcMacReady?(KcMacReadyEvent(
                peerId: callerId, callId: callId, isInitiator: true, sessionKey: combined,
                kcKey: kcCallerKeyForEvent, transcript: kcCallerTranscriptForEvent, n: kcCallerN,
                peerSupportsMix: kcCallerPeerSupportsMix, sigOk: acceptSigOk,
                peerAdvertisedRoles: kcCallerPeerAdvertisedRoles,
                // W-KCMACBLIND — static form, matching the responder leg (:1872)
                // and what AppState.resolvePskDisplayMeta/resolveNfcMixInputs
                // actually match against. The raw wire echo (`selectedFpStr`)
                // never resolves there, which silently forced the NFC-in-common
                // branch of AssuranceState.decide() unreachable whenever iOS
                // placed the call — see establishedPskFp's derivation at :2177.
                selectedFp: establishedPskFp,
                round: innerAadEpochCaller
            ))

            // W529: caller's ACCEPT decapsulation succeeded → cancel
            // any outstanding 5 s OFFER retry.
            offerRetryTask?.cancel()
            offerRetryTask = nil
        }
    }

    // MARK: - Transcript v6 helpers (WIRE_SPEC §3.7 / §3.8)
    //
    // Pure helpers keep the wire insertion points (OFFER sign, OFFER verify, ACCEPT sign, ACCEPT
    // verify) short so the big `onAndroid…`/`onAndroidBundleReceived` bodies don't grow another
    // type-checker-heavy branch (CLAUDE.md §13/§14).
    //
    // EPOCH NOTE: the signed transcript binds a 16-byte per-direction epochId that the wire bundle
    // does NOT carry; every platform feeds `HandshakeSigningPolicy.placeholderEpochId` (16 zero
    // bytes).

    /// This build's own advertised capabilities — identical on every OFFER and ACCEPT. Nine of the
    /// flags are SIGNED (CAPS9); `innerAudioAadV1` only gates local behaviour.
    private static func selfCapabilities() -> AndroidHandshakeBundle.Capabilities {
        return AndroidHandshakeBundle.Capabilities(
            ratchetV3: true,
            // sframeV1 + vkeyV1 are advertised EXPLICITLY: the verifier reconstructs CAPS from the
            // RECEIVED bundle, and a peer that decodes an absent flag to its own default would
            // otherwise rebuild a different signed byte.
            sframeV1: true,
            vkeyV1: true,
            // v4 ONLY when this build can actually do it (flag ON + native core linked).
            ratchetV4: advertisesRatchetV4 ? true : nil,
            srtpDirKeyV1: srtpDirKeysEnabled ? true : nil,
            pskMixV1: true,
            // The transcript-bound KDF/SAS/KCMAC is unconditional (F4); the bit stays advertised
            // because it is part of the signed CAPS9.
            hsTranscriptBindV1: true,
            // MEDIA-3/4/5 — gated by innerAudioAadV1Enabled (default false).
            innerAudioAadV1: innerAudioAadV1Enabled ? true : nil
        )
    }

    /// CAPS9 reconstructed from a bundle (spec §5b: absent OR null capabilities → false).
    private static func caps9(from caps: AndroidHandshakeBundle.Capabilities?) -> HandshakeTranscript.Caps9 {
        return HandshakeTranscript.Caps9(
            ratchetV3: caps?.ratchetV3 ?? false,
            sframeV1: caps?.sframeV1 ?? false,
            vkeyV1: caps?.vkeyV1 ?? false,
            sessionKdfV3: caps?.sessionKdfV3 ?? false,
            ratchetV4: caps?.ratchetV4 ?? false,
            srtpDirKeyV1: caps?.srtpDirKeyV1 ?? false,
            pskMixV1: caps?.pskMixV1 ?? false,
            hsTranscriptBindV1: caps?.hsTranscriptBindV1 ?? false,
            ratchetV5: caps?.ratchetV5 ?? false
        )
    }

    /// Decode a bundle's `rekeyNonce` (base64) to its raw 8 bytes. `nil` for an absent field AND
    /// for any present-but-malformed value (wrong length, bad base64): a missing/malformed
    /// peer-controlled nonce means the transcript cannot be built, never a trap.
    private static func rekeyNonceRaw(from b64: String?) -> Data? {
        guard let b64, let raw = Data(base64Encoded: b64), raw.count == 8 else { return nil }
        return raw
    }

    /// Build `OFFER_v6` from an OFFER bundle's RAW (base64-decoded) fields. `signerKeyRaw` is the
    /// signer's identity key (the LOCAL pub when signing, the bundle's own key when verifying) and
    /// `dtlsFingerprint` the OFFERER's certificate fingerprint. Returns nil if a required field
    /// fails to decode or the round/nonce is absent. R-ROUND: `rekeyRound` MUST be present and >= 1
    /// (the initial round is 1); a missing or 0 round is malformed (nil), never defaulted.
    static func offerTranscript(
        from bundle: AndroidHandshakeBundle,
        callId: String,
        signerKeyRaw: Data,
        dtlsFingerprint: Data
    ) -> Data? {
        guard let pqcB64 = bundle.pqcPublicKey, let pqcRaw = Data(base64Encoded: pqcB64),
              let x25B64 = bundle.x25519PublicKey, let x25Raw = Data(base64Encoded: x25B64),
              let roundInt = bundle.rekeyRound, roundInt >= 1, roundInt <= Int(UInt32.max),
              let nonceRaw = rekeyNonceRaw(from: bundle.rekeyNonce) else {
            return nil
        }
        // R-COMMIT-FIELD: round 1 carries exactly 32 canonical-base64 bytes, every other round none.
        let commitRaw: Data?
        if roundInt == 1 {
            guard let text = bundle.sasCommit,
                  let decoded = SasCommit.decodeCanonicalBase64(text, expectedLength: SasCommit.commitLength) else {
                return nil
            }
            commitRaw = decoded
        } else {
            guard bundle.sasCommit == nil else { return nil }
            commitRaw = nil
        }
        let strongBox = bundle.strongBoxPublicKey.flatMap { Data(base64Encoded: $0) }
        let dualCurve = bundle.dualCurvePublicKey.flatMap { Data(base64Encoded: $0) }
        return HandshakeTranscript.offer(
            callId: callId,
            signerIdentityKey: signerKeyRaw,
            epochId: HandshakeSigningPolicy.placeholderEpochId,
            pqcPublicKey: pqcRaw,
            x25519PublicKey: x25Raw,
            strongBoxPublicKey: strongBox,
            dualCurvePublicKey: dualCurve,
            caps: caps9(from: bundle.capabilities),
            ratchetV: HandshakeSigningPolicy.ratchetV,
            suiteId: HandshakeSigningPolicy.suiteId,
            pskFingerprints: bundle.pskFingerprints,
            pskRoles: bundle.pskRoles,
            rekeyNonce: nonceRaw,
            rekeyRound: UInt32(roundInt),
            dtlsFingerprint: dtlsFingerprint,
            sasCommit: commitRaw
        )
    }

    /// Build `ACCEPT_v6` from an ACCEPT bundle's RAW ciphertext fields, the `offerBinding`
    /// (`SHA-256(OFFER_v6)`, 32 bytes) it must answer and the ACCEPTOR's certificate fingerprint.
    /// `bundle.pskFingerprints`/`pskRoles` are THIS ACCEPT's own advertised list; the nonce/round
    /// are the echo of the OFFER's. Returns nil if a required field fails to decode or the round
    /// is missing or < 1 (R-ROUND).
    static func acceptTranscript(
        from bundle: AndroidHandshakeBundle,
        callId: String,
        signerKeyRaw: Data,
        offerBinding: Data,
        dtlsFingerprint: Data
    ) -> Data? {
        guard let ct = bundle.ciphertext,
              let pqcRaw = Data(base64Encoded: ct.pqc),
              let x25Raw = Data(base64Encoded: ct.x25519),
              let roundInt = bundle.rekeyRound, roundInt >= 1, roundInt <= Int(UInt32.max),
              let nonceRaw = rekeyNonceRaw(from: bundle.rekeyNonce) else {
            return nil
        }
        let strongBox = ct.strongBox.flatMap { Data(base64Encoded: $0) }
        let dualCurve = ct.dualCurve.flatMap { Data(base64Encoded: $0) }
        return HandshakeTranscript.accept(
            callId: callId,
            signerIdentityKey: signerKeyRaw,
            epochId: HandshakeSigningPolicy.placeholderEpochId,
            ctPqc: pqcRaw,
            ctX25519: x25Raw,
            ctStrongBox: strongBox,
            ctDualCurve: dualCurve,
            caps: caps9(from: bundle.capabilities),
            ratchetV: HandshakeSigningPolicy.ratchetV,
            suiteId: HandshakeSigningPolicy.suiteId,
            selectedPskFingerprint: bundle.selectedPskFingerprint,
            offerBinding: offerBinding,
            responderPskFingerprints: bundle.pskFingerprints,
            responderPskRoles: bundle.pskRoles,
            rekeyNonce: nonceRaw,
            rekeyRound: UInt32(roundInt),
            dtlsFingerprint: dtlsFingerprint
        )
    }

    /// This call's own DTLS certificate fingerprint (33 bytes). A handshake never starts without
    /// it: the certificate is generated before anything is signed (WIRE_SPEC §3.4 step 1).
    func localDtlsFingerprint(callId: String) throws -> Data {
        guard let fp = provideLocalDtlsFingerprint?(callId), DtlsFingerprint.isWellFormedBinary(fp) else {
            // R-CERT: a call that already signed a bundle (it sent an OFFER, or completed its first
            // round) never gets a second certificate. Its context missing now means it must not be
            // replaced silently: the call ends with `dtls_fp_mismatch`. A call that never signed
            // simply cannot start (no certificate).
            let key = callId.lowercased()
            let signedBefore = lock.withLock {
                sentOfferTranscriptByCall[key] != nil
                    || sessionInitializedByCall.contains(callId) || sessionInitializedByCall.contains(key)
            }
            if signedBefore { reportHandshakeFatal(callId: callId, reason: "dtls_fp_mismatch") }
            throw IntegrationError.handshakeAborted(code: signedBefore ? "dtls_fp_mismatch" : "dtls_cert_unavailable")
        }
        return fp
    }

    /// Attach `signerIdentityKey`, `sigV6` and `dtlsFingerprint` to a bundle by signing
    /// `transcript`. Signing is mandatory: any failure throws (a call is never started with an
    /// unsigned handshake). Every other field is copied verbatim — this rebuilds the bundle field
    /// by field, so a field omitted here would silently vanish from the wire.
    private func signedBundle(of bundle: AndroidHandshakeBundle, transcript: Data, fingerprint: Data) throws -> AndroidHandshakeBundle {
        guard let idKey = localSignerIdentityKey, idKey.count == 32, let sign = signTranscript,
              let sig = sign(transcript), sig.count == 64,
              let fingerprintText = DtlsFingerprint.canonicalText(fingerprint) else {
            throw IntegrationError.handshakeAborted(code: "sign_unavailable")
        }
        return AndroidHandshakeBundle(
            kind: bundle.kind,
            callId: bundle.callId,
            pqcPublicKey: bundle.pqcPublicKey,
            x25519PublicKey: bundle.x25519PublicKey,
            strongBoxPublicKey: bundle.strongBoxPublicKey,
            dualCurvePublicKey: bundle.dualCurvePublicKey,
            ciphertext: bundle.ciphertext,
            capabilities: bundle.capabilities,
            pskFingerprints: bundle.pskFingerprints,
            selectedPskFingerprint: bundle.selectedPskFingerprint,
            pskRoles: bundle.pskRoles,
            signerIdentityKey: idKey.base64EncodedString(),
            sigV6: sig.base64EncodedString(),
            dtlsFingerprint: fingerprintText,
            // R-COMMIT-FIELD: the round-1 OFFER's commitment travels verbatim (it is signed in the
            // transcript); an ACCEPT or a rekey OFFER carries none.
            sasCommit: bundle.sasCommit,
            rekeyNonce: bundle.rekeyNonce,
            rekeyRound: bundle.rekeyRound,
            // W-REKEYSYNC — carried through verbatim, or it would silently drop from every OFFER.
            rekeyNextPeriodMs: bundle.rekeyNextPeriodMs
        )
    }

    /// Build, SIGN and stash an OFFER (round 1 or a re-key round). The stash is what lets the
    /// offerer recompute `offer_binding = SHA-256(OFFER_v6)` when the matching ACCEPT arrives.
    private func buildSignedOffer(
        callId: String,
        pqcRawPub: Data,
        x25519RawPub: Data,
        advertisedPskFingerprints: [String],
        advertisedPskRoles: [Int]?,
        rekeyNonce: Data,
        rekeyRound: UInt32,
        rekeyNextPeriodMs: Int?,
        sasCommit: Data?
    ) throws -> AndroidHandshakeBundle {
        let fpSelf = try localDtlsFingerprint(callId: callId)
        guard let idKey = localSignerIdentityKey, idKey.count == 32 else {
            throw IntegrationError.handshakeAborted(code: "sign_unavailable")
        }
        let unsigned = AndroidHandshakeBundle(
            kind: .offer,
            callId: callId,
            pqcPublicKey: pqcRawPub.base64EncodedString(),
            x25519PublicKey: x25519RawPub.base64EncodedString(),
            capabilities: Self.selfCapabilities(),
            pskFingerprints: advertisedPskFingerprints,
            pskRoles: advertisedPskRoles,
            // Resent IDENTICALLY on every round of the call (round 1 and every re-key round).
            sasCommit: sasCommit?.base64EncodedString(),
            rekeyNonce: rekeyNonce.base64EncodedString(),
            rekeyRound: Int(rekeyRound),
            rekeyNextPeriodMs: rekeyNextPeriodMs
        )
        guard let transcript = Self.offerTranscript(
            from: unsigned, callId: callId, signerKeyRaw: idKey, dtlsFingerprint: fpSelf) else {
            throw IntegrationError.handshakeAborted(code: "transcript_unbuildable")
        }
        let signed = try signedBundle(of: unsigned, transcript: transcript, fingerprint: fpSelf)
        lock.withLock { sentOfferTranscriptByCall[callId.lowercased()] = transcript }
        return signed
    }

    /// What `evaluateInbound` learned from a received bundle.
    struct InboundCheck {
        let verdict: HandshakeSigningPolicy.Verdict
        /// The v6 transcript rebuilt from the RECEIVED bundle, under the bundle's own signer key.
        let transcript: Data?
        /// The peer's DTLS fingerprint parsed from the bundle (33 bytes), when well-formed.
        let peerFingerprint: Data?
    }

    /// Apply the policy to a received bundle. The v6 transcript is rebuilt under the bundle's own
    /// `signerIdentityKey` (the signer signed its own key; the policy only ever verifies under a
    /// key equal to it), together with the peer fingerprint parsed from the bundle and — for an
    /// ACCEPT — the `expectedOfferBinding` of the OFFER we sent.
    func evaluateInbound(
        bundle: AndroidHandshakeBundle,
        callId: String,
        peerId: String,
        peerDeviceId: String?,
        expectedOfferBinding: Data?
    ) -> InboundCheck {
        // R-COMMIT-FIELD: the SAS commitment rules are malformed codes, checked before anything else
        // (no pin, no key and no transcript is touched for a bundle the call ends on anyway).
        if let code = HandshakeSigningPolicy.sasCommitMalformedCode(
            isOffer: bundle.kind == .offer, round: bundle.rekeyRound, sasCommitB64: bundle.sasCommit) {
            return InboundCheck(verdict: .malformed(code: code), transcript: nil, peerFingerprint: nil)
        }
        // D11: the pin is keyed per-(peer, device); a nil device id resolves to the legacy
        // bare-contactId pin inside the store.
        // The stored pin wins; the call-scoped pin (the signer key the user confirmed by SAS earlier in
        // THIS call) only fills in when there is none, so a later key round of the call verifies under it.
        let pinned = CallScopedSasPinBook.effectivePin(
            stored: peerPinStoreLookup(peerId: peerId, deviceId: peerDeviceId),
            callScoped: sasPins.confirmedSigner(callId: callId))
        let server = resolveServerPeerKey?(peerId)
        // D11 trust-on-publish floor: the server's published per-device SET. An empty set (no
        // floor / fetch failed) makes the policy degrade to pin-only TOFU — never a fatal mismatch.
        let publishedSet = resolvePublishedKeySet?(peerId, peerDeviceId) ?? []
        let bundleKey: Data? = bundle.signerIdentityKey.flatMap { Data(base64Encoded: $0) }
        let peerFingerprint: Data? = bundle.dtlsFingerprint.flatMap { DtlsFingerprint.parseCanonical($0) }
        var transcript: Data?
        if let key = bundleKey, key.count == 32, let fp = peerFingerprint {
            switch bundle.kind {
            case .offer:
                transcript = Self.offerTranscript(
                    from: bundle, callId: callId, signerKeyRaw: key, dtlsFingerprint: fp)
            case .accept:
                if let binding = expectedOfferBinding {
                    transcript = Self.acceptTranscript(
                        from: bundle, callId: callId, signerKeyRaw: key,
                        offerBinding: binding, dtlsFingerprint: fp)
                }
            }
        }
        let advertisedV4 = (HandshakeSigningPolicy.ratchetV >= 0x04)
            && (HandshakeSigningPolicy.suiteId == 0x01)
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: bundle.signerIdentityKey,
            sigV6B64: bundle.sigV6,
            dtlsFingerprintText: bundle.dtlsFingerprint,
            transcript: transcript,
            pinnedKey: pinned,
            serverFetchedKey: server,
            publishedKeySet: publishedSet.isEmpty ? nil : publishedSet,
            advertisedV4: advertisedV4,
            advertisedSrtpDirKeyV1: bundle.capabilities?.srtpDirKeyV1 ?? false,
            advertisedRatchetV5: bundle.capabilities?.ratchetV5 ?? false,
            ratchetV5CapablePinned: isPeerRatchetV5Pinned?(peerId) ?? false
        )
        // No pin and no server key: the round's signer key (its signature verified under it) is
        // remembered, never trusted, so that the user's SAS confirmation of THIS round can pin it. Any
        // other abort of the call before that confirmation is a round the key cannot vouch for
        // (`CallScopedSasPinBook` conflict rule).
        if case .abort(let code) = verdict {
            if code == "identity_unresolved" {
                sasPins.noteUnresolved(callId: callId, round: bundle.rekeyRound, signerKey: bundleKey)
            } else {
                sasPins.noteOtherAbort(callId: callId)
            }
        }
        return InboundCheck(verdict: verdict, transcript: transcript, peerFingerprint: peerFingerprint)
    }

    /// Pin the peer's DTLS fingerprint for this call (WIRE_SPEC §3.4 step 5): the first bundle
    /// pins it (and tells the app, which hands it to the PeerConnection); every later bundle (a
    /// re-key round) MUST carry the same one. A different one ends the call (`dtls_fp_mismatch`)
    /// and returns false.
    private func pinPeerDtlsFingerprint(callId: String, fingerprint: Data) -> Bool {
        let key = callId.lowercased()
        let known: Data? = lock.withLock { () -> Data? in
            if let existing = peerDtlsFingerprintByCall[key] { return existing }
            peerDtlsFingerprintByCall[key] = fingerprint
            return nil
        }
        guard let pinned = known else {
            onPeerDtlsFingerprintPinned?(callId, fingerprint)
            return true
        }
        if pinned == fingerprint { return true }
        print("[QAudionCallIntegration] peer DTLS fingerprint changed within the call callId=\(callId.prefix(8))… — ending the call")
        reportHandshakeFatal(callId: callId, reason: "dtls_fp_mismatch")
        return false
    }

    /// The handshake cannot continue and the call must end. Verdict-only: no value leaves here.
    private func reportHandshakeFatal(callId: String, reason: String) {
        print("[QAudionCallIntegration] handshake fatal reason=\(reason) callId=\(callId.prefix(8))…")
        onHandshakeFatal?(callId, reason)
    }

    /// D11 per-(peer,device) pin lookup. `resolvePinnedPeerKey` is the legacy
    /// bare-contactId closure (kept for back-compat); `resolvePinnedPeerKeyForDevice`
    /// is the device-aware one wired in AppState. Prefer the device-aware closure
    /// when set so a 2nd device resolves to its own pin (or the migrated legacy
    /// pin) rather than always the first device's.
    private func peerPinStoreLookup(peerId: String, deviceId: String?) -> Data? {
        if let perDevice = resolvePinnedPeerKeyForDevice {
            return perDevice(peerId, deviceId)
        }
        return resolvePinnedPeerKey?(peerId)
    }

    /// Commit the side effects of a `.authenticated` /
    /// `.authenticatedRepinFromPublished` verdict (spec §2 / §4 / D11):
    /// first-contact-or-set-proven TOFU pin (per-(peer, device)), then
    /// v4-capable-pin — BOTH before the handshake completes. Pure side-effect;
    /// safe to call when closures are nil. `deviceId` keys the pin per-device
    /// (nil → legacy bare-contactId pin via the store's migration anchor).
    private func applyAuthenticatedSideEffects(
        peerId: String,
        deviceId: String?,
        tofuPinKey: Data?,
        v4Capable: Bool,
        srtpDirKeyV1Capable: Bool = false,
        setProven: Bool = false,
        ratchetV5Capable: Bool = false
    ) {
        if let pinKey = tofuPinKey {
            // W-SASPIN — a set-proven rotation is the ONE case allowed to
            // overwrite an existing pin; everything else stays write-once.
            if setProven, let repin = commitSetProvenRepinForDevice {
                repin(peerId, pinKey, deviceId)
            } else if let perDevice = commitTofuPinForDevice {
                perDevice(peerId, pinKey, deviceId)
            } else {
                commitTofuPin?(peerId, pinKey)
            }
        }
        if v4Capable {
            setPeerV4Pinned?(peerId)
        }
        if srtpDirKeyV1Capable {
            setPeerSrtpDirKeyV1Pinned?(peerId)
        }
        if ratchetV5Capable {
            setPeerRatchetV5Pinned?(peerId)
        }
    }

    /// X25519 ephemeral encapsulation (responder side): generate a
    /// fresh X25519 keypair, ECDH against the remote pub, return both
    /// the shared secret and the ephemeral pub the remote needs to
    /// reproduce the same secret.
    private static func x25519Encap(
        remotePub: Data
    ) throws -> (sharedSecret: Data, ephemeralPublicKey: Data) {
        let ephPriv = Curve25519.KeyAgreement.PrivateKey()
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePub)
        let secret = try ephPriv.sharedSecretFromKeyAgreement(with: remoteKey)
        let ss = secret.withUnsafeBytes { Data($0) }
        let pub = Data(ephPriv.publicKey.rawRepresentation)
        return (ss, pub)
    }

    /// Corrected cross-platform hybrid session-key derivation (schema :2).
    ///
    /// Byte-identical to firmware `qa_session_handshake_complete` (hybrid
    /// path), Android `HybridPqcKeyExchange.deriveSessionKey` and Desktop
    /// `deriveHybridSessionKey`. Pinned by
    /// tools/kat/hybrid-combine/hybrid-combine-kat.json; spec in
    /// apps/qaudion-firmware/docs/CROSS_PLATFORM_HYBRID_KDF.md.
    ///
    ///   ct_bind = HMAC-SHA256("q-audion-ct-bind-v1", pqcCiphertext)  [32B]
    ///   ikm     = pqcSs(32) || x25519Ss(32)                          [64B]
    ///   salt    = psk            if (psk != nil && !psk.isEmpty)
    ///             else "q-audion-hybrid-pqc-v1"                      [22B]
    ///   info    = "q-audion-session-key"(20) || ct_bind(32)          [52B]
    ///   key     = HKDF-SHA256(ikm, salt, info, 32)
    ///
    /// Folding the ciphertext-binding HMAC into `info` closes the
    /// ciphertext-substitution / re-encapsulation MITM that the prior
    /// 2-leg combine (no binding, schema :1) was vulnerable to. The PSK
    /// is the HKDF Extract salt (never a secret KEM output) —
    /// independently security-reviewed (NVIDIA Nemotron + DeepSeek):
    /// NIST SP 800-56C Rev.2 compliant, strictly stronger.
    /// `internal` (not `private`) so the cross-platform KAT can exercise
    /// this exact production path via `@testable import`.
    static func deriveHybridSessionKey(
        pqcSs: Data,
        x25519Ss: Data,
        pqcCiphertext: Data,
        psk: Data?
    ) -> Data {
        let ctBind = Data(
            HMAC<SHA256>.authenticationCode(
                for: pqcCiphertext,
                using: SymmetricKey(data: HkdfLabels.hybridCtBindV1)
            )
        )

        var ikm = Data(capacity: pqcSs.count + x25519Ss.count)
        ikm.append(pqcSs)
        ikm.append(x25519Ss)

        let salt: Data
        if let psk = psk, !psk.isEmpty {
            salt = psk
        } else {
            salt = HkdfLabels.hybridPqcSaltV1
        }

        var info = Data(capacity: HkdfLabels.hybridPqcSessionKey.count + ctBind.count)
        info.append(HkdfLabels.hybridPqcSessionKey)
        info.append(ctBind)

        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// Symmetric-null convergence gate (iOS↔desktop sealed-audio AEAD fix). Returns
    /// `psk` IFF its canonical fingerprint `lc_hex(SHA-256(psk))` byte-equals `fp`
    /// (computed exactly as the PSK fingerprint is stored/advertised), else nil. A
    /// matching `fp` proves — by collision resistance — that both ends hold the SAME
    /// raw bytes, so each side mixes the PSK as the schema:2 HKDF Extract salt only
    /// when this gate passes against the negotiated fingerprint. On any miss (no PSK /
    /// lookup miss / a drifted Keychain entry whose label no longer hashes to its
    /// bytes) both ends fall back to the no-PSK key and CONVERGE — instead of silently
    /// mixing divergent salts (which makes every relay-audio frame fail AES-GCM auth).
    /// Android is unaffected: it always holds the byte-equal established PSK, so the
    /// gate passes on both ends and the session key stays byte-identical to interop.
    /// W-PSKBLIND — the dialect THIS build's OFFER advertises (WIRE_SPEC §3.3.1
    /// "Rollout"). The single switch for phase B, and the only thing here that
    /// changes what goes on the wire.
    ///
    /// Phase A (this value) emits §3.3 static fingerprints, so the OFFER is
    /// byte-identical to every build before the blinded advertisement landed. The
    /// RECEIVE side is already dual-dialect on both legs, and the responder mirrors
    /// whatever dialect it detected — so a peer of any vintage keeps working and this
    /// constant is the whole of the risk.
    ///
    /// Flipping it to `.v3Blinded` is safe once phase A is live on Android, iOS and
    /// Desktop. Against a peer that predates phase A the OFFER's tags match nothing,
    /// the session key derives without a PSK, and the call still connects — which is
    /// why the responder path logs that case explicitly rather than in silence.
    static let offerAdvertDialect: PskAdvertResolver.Dialect = .v3Blinded

    /// W-PSKBLIND (§3.3.1.1) — the per-contact blinded-advertisement latch. See
    /// [PskAdvertDialectLatchStore] for why it is its own Keychain namespace and for the
    /// accepted limits (keyed by contact not device; not restored to a new device).
    private static let pskDialectLatch = PskAdvertDialectLatchStore()

    /// W-PSKBLIND — resolve the responder's echoed `selectedPskFingerprint` back to
    /// the local PSK material, in EITHER dialect.
    ///
    /// The echo is a WIRE value in whatever dialect WE advertised. Under §3.3 it is a
    /// static fingerprint and this is the vault lookup it always was; under §3.3.1 it
    /// is OUR OWN per-call tag, so it is resolved by handing it BACK to the resolver
    /// as a one-element advertisement under our own ephemeral key — we sent the
    /// advertisement it was picked from, so our key is the right nonce source. Same
    /// mechanism on Android and Desktop.
    ///
    /// Getting this wrong is not a downgrade, it is a BREAK: the responder already
    /// derived WITH the PSK, so failing to resolve it here diverges the session key
    /// and every received frame fails to unseal while the call still shows connected.
    /// That is why the two derivation branches (V4 and schema:2) share this one
    /// function instead of each carrying its own copy of the lookup.
    ///
    /// Preserved from the two copies it replaces:
    ///  * `.callDerived` vault rows are never match candidates (W-PSKMIX step 5) —
    ///    the consuming-side twin of the advertise-side exclusion.
    ///  * fingerprints are recomputed fresh from the raw material, never read from
    ///    the cached Keychain label (W-STALEFP), which can predate
    ///    `canonicalFingerprint` becoming the write-time label.
    ///  * the `pskIfFingerprintMatches` convergence gate still has the last word, so
    ///    a drifted entry whose bytes no longer hash to its fingerprint is rejected.
    static func pskForEchoedSelection(
        echo: String,
        callId: String,
        ownEphemeralX25519Pub: Data
    ) -> Data? {
        guard !echo.isEmpty else { return nil }
        let vault = SovereignKeyVault()
        let candidates: [PskAdvertResolver.Candidate] = vault.listPskNames()
            .sorted()
            .compactMap { name in
                guard PskAdvertising.isEligibleMatchCandidate(origin: vault.origin(name: name)),
                      let raw = (try? vault.loadPsk(name: name)) ?? nil, !raw.isEmpty
                else { return nil }
                return PskAdvertResolver.Candidate(
                    staticFp: PskAdvertising.canonicalFingerprint(forPsk: raw),
                    psk: raw,
                    localRole: 0
                )
            }
        // parseSelection keeps tolerating a future comma-joined multi-selection; only
        // the first entry is acted on, exactly as before.
        //
        // §3.3.1.1 is deliberately NOT applied here, and this must never latch. The value
        // being resolved is OUR OWN advertised element under OUR OWN ephemeral key, so its
        // dialect reports what THIS build emitted, not what the peer can speak. Refusing
        // here would reject our own static advertisement back to ourselves; latching here
        // would arm every contact the instant `offerAdvertDialect` flips, including peers
        // that only ever spoke static, which we would then refuse forever. This function
        // deliberately takes no contactId, which is what makes both mistakes impossible
        // rather than merely discouraged — do not add one.
        let selection = Self.parseSelection(echo)
        let resolved = PskAdvertResolver.resolve(
            receivedAdvert: selection,
            receivedRoles: nil,
            callId: callId,
            senderEphemeralX25519Pub: ownEphemeralX25519Pub,
            candidates: candidates
        )
        guard let staticFp = resolved.staticFp else {
            print("[QAudionCallIntegration] echoed selection \(echo.prefix(16))… resolves to no local PSK in either dialect — session key mixes NO psk callId=\(callId.prefix(8))…")
            return nil
        }
        return Self.pskIfFingerprintMatches(resolved.psk, staticFp)
    }

    static func pskIfFingerprintMatches(_ psk: Data?, _ fp: String?) -> Data? {
        guard let psk = psk, !psk.isEmpty, let fp = fp, !fp.isEmpty else { return nil }
        // W-PSKMIX step 3 — reuse the same canonical-fingerprint computation
        // the advert builder uses (`PskAdvertising.canonicalFingerprint`)
        // instead of duplicating the inline SHA-256-hex here; byte-identical
        // to the prior local computation.
        let h = PskAdvertising.canonicalFingerprint(forPsk: psk)
        // PSK-mix ship-step-2 (parse-only): `fp` may now be a single 64-hex
        // fingerprint (today's only real case — `parseSelection` returns
        // exactly `[fp]`, so membership is byte-for-byte the same test as
        // the old `h == fp`) OR a comma-joined multi-selection (not yet
        // emitted by any peer). A malformed `fp` parses to `[]`, so the
        // gate fails closed exactly as it already does on a hash mismatch —
        // no new acceptance path, only a wider (still exact) match set.
        return parseSelection(fp).contains(h) ? psk : nil
    }

    /// Parse the wire `selectedPskFingerprint` value into the list of
    /// fingerprints it names. Pure, side-effect free — mirrors the
    /// Kotlin/TypeScript `parseSelection` equivalents landing on Android and
    /// Desktop in this same ship step.
    ///
    /// - `nil` or `""` → `[]` (N=0, no PSK selected — today's other real
    ///   case besides N=1, unchanged).
    /// - a single well-formed 64-char lowercase-hex fingerprint → `[fp]`
    ///   (N=1, today's only OTHER real case — byte-identical to the
    ///   pre-existing bare `== fp` compare it replaces in the gate above).
    /// - `"<fp1>,<fp2>[,<fp3>][,<fp4>]"` → the parsed list, ONLY when every
    ///   entry is a well-formed 64-char lowercase-hex fingerprint, joined by
    ///   exactly one `,` with no spaces and no empty/trailing entries, and
    ///   the total count is between 2 and 4 inclusive (N>=2 — not emitted by
    ///   any client yet; parsed here so a later ship step doesn't need a
    ///   flag-day on this file).
    /// - anything else — odd/empty entries (`"a,,b"`, `"a,b,"`), uppercase
    ///   hex, wrong length, 5+ entries, or any other malformed shape — →
    ///   `[]`. REJECTED, never silently truncated or half-parsed: an
    ///   unparseable selection is treated exactly like "no PSK selected",
    ///   the same fail-closed convergence the gate already falls back to on
    ///   a hash mismatch.
    static func parseSelection(_ raw: String?) -> [String] {
        guard let raw = raw, !raw.isEmpty else { return [] }
        func isFingerprint(_ s: Substring) -> Bool {
            guard s.utf8.count == 64 else { return false }
            return s.allSatisfy { c in
                switch c {
                case "0"..."9", "a"..."f": return true
                default: return false
                }
            }
        }
        if !raw.contains(",") {
            return isFingerprint(raw[...]) ? [raw] : []
        }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 4 else { return [] }
        guard parts.allSatisfy(isFingerprint) else { return [] }
        return parts.map(String.init)
    }

    // MARK: - CALL-4/HSID-002 (2026-09-02 protocol audit) — transcript-bound
    // session key, canonical single-pass construction (ITEM 2/3 FOLLOW-UP,
    // reconciled to Android's HybridPqcKeyExchange.kt
    // deriveSessionKeyTranscriptBound — the DESIGNATED CANONICAL construction
    // across all three platforms, see this fix's own commit message)

    /// The session-key KDF of a 1:1 call (transcript v6, F4 — the ONLY derivation):
    ///
    ///   ikm  = pqcSharedSecret(32) || x25519Shared(32)                  [64B]
    ///   salt = psk                if (psk != nil && !psk.isEmpty)
    ///          else HkdfLabels.hybridPqcSaltV1  // "q-audion-hybrid-pqc-v1"
    ///   info = HkdfLabels.hybridPqcSessionKey(20) || transcriptHash(32) [52B]
    ///   key  = HKDF-SHA256(ikm, salt, info, 32)
    ///
    /// `transcriptHash = SHA-256(ACCEPT_v6)`: the transcript already embeds the raw ML-KEM
    /// ciphertext, the selected PSK fingerprint, both signers' identity keys, both DTLS
    /// fingerprints (through the OFFER binding) and the round/nonce, so re-adding them here would
    /// be redundant. A fingerprint substitution — even with stripped signatures — gives the two
    /// legs different transcripts, hence different keys, SAS words and KCMACs.
    ///
    /// `transcriptHash` MUST be exactly 32 bytes — `precondition`-checked; callers only ever pass
    /// `HandshakeTranscript.offerBinding(_:)`'s own 32-byte output, never peer-controlled bytes.
    ///
    /// `internal` so the cross-platform KAT can exercise this exact production path.
    static func deriveTranscriptBoundSessionKey(
        pqcSharedSecret: Data,
        x25519Shared: Data,
        psk: Data?,
        transcriptHash: Data
    ) -> Data {
        precondition(transcriptHash.count == 32, "transcriptHash must be 32 bytes")
        var ikm = Data(capacity: pqcSharedSecret.count + x25519Shared.count)
        ikm.append(pqcSharedSecret)
        ikm.append(x25519Shared)
        let salt: Data
        if let psk = psk, !psk.isEmpty {
            salt = psk
        } else {
            salt = HkdfLabels.hybridPqcSaltV1
        }
        var info = Data(capacity: HkdfLabels.hybridPqcSessionKey.count + transcriptHash.count)
        info.append(HkdfLabels.hybridPqcSessionKey)
        info.append(transcriptHash)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - CALL-3 (2026-09-02 protocol audit) — re-key round freshness

    /// CALL-3 — the nonce-scoped re-key round freshness value the audit's fix
    /// design specifies: `HKDF(ikm: callId || rekeyNonce, info:
    /// "rekey-round"(11) || round_number as u32_BE(4), L: 32)`. NOT itself a
    /// wire field on `offerV3`/`acceptV3` today — those sign the raw
    /// `(rekeyNonce, rekeyRound)` pair directly (Ed25519-authenticated, which
    /// is what actually makes a replayed stale round detectable; see those
    /// functions' docs), so re-deriving an opaque blob from the same two
    /// inputs would be redundant for THAT property. This function exists as a
    /// ready, tested, byte-exact implementation of the literal formula the
    /// external security review specified, for whichever future consumer
    /// wants an opaque per-round freshness token (e.g. the day
    /// `HandshakeSigningPolicy.placeholderEpochId` is replaced by a real
    /// per-round epoch — see that constant's own EPOCH NOTE) rather than the
    /// call-site round/nonce pair directly.
    ///
    /// `internal` (not `private`) so a future KAT test can exercise it via
    /// `@testable import`.
    /// CALL-3 — generate the call's own random 64-bit (8-byte) `rekeyNonce`.
    /// `SecRandomCopyBytes` against `kSecRandomDefault`, matching every other
    /// CSPRNG call site in this engine (`MessageCrypto.randomBytes`,
    /// `SessionManager`, `StunClient`, …). `private` — the only callers are
    /// `onAndroidCallSetupStarted` (round 1, generates it once per call) and
    /// tests (via a dedicated seam, not this raw generator).
    private static func generateRekeyNonce() -> Data {
        var bytes = Data(count: 8)
        let status = bytes.withUnsafeMutableBytes { buf -> OSStatus in
            guard let base = buf.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, 8, base)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }

    /// CALL-3 — the pure round-monotonicity DECISION: does an inbound v3-verified
    /// re-key OFFER's `round` get REFUSED as stale/replayed? `true` ⇒ refuse (do
    /// not install, do not ACCEPT — the call keeps running on its current key).
    ///
    /// - `isReKeyRound`: this call already completed a full handshake before
    ///   (round 1's OFFER itself is NEVER refused — there is no "last accepted"
    ///   to compare against yet).
    /// - `isKnownRetransmit`: this EXACT bundle's content-fingerprint has already
    ///   been processed once (a WS/push redelivery of the CURRENTLY-active
    ///   round) — MUST be let through so the caller's existing "replay the
    ///   cached ACCEPT" path runs, never refused here (a retransmit of the
    ///   active round legitimately carries `round == lastAccepted`, which the
    ///   raw `round <= lastAccepted` rule below would otherwise catch).
    /// - `round`: this OFFER's own signed, v3-verified round number.
    /// - `lastAccepted`: the last round THIS side has accepted for this call
    ///   (nil ⇒ no prior state ⇒ never refuse — TOFU-accept the baseline).
    ///
    /// `internal` (not `private`) so a KAT/unit test can exercise this exact
    /// decision via `@testable import` without standing up the full async
    /// handshake machinery.
    static func shouldRefuseStaleRekeyRound(
        isReKeyRound: Bool,
        isKnownRetransmit: Bool,
        round: UInt32,
        lastAccepted: UInt32?
    ) -> Bool {
        guard !isKnownRetransmit, isReKeyRound else { return false }
        // R-ROUND / R-COMMIT-FIRST-ROUND: a call whose first handshake already ran never restarts round 1
        // (or accepts round 0): a different round-1 OFFER for it is dropped, whether or not any round was
        // verified yet, so the commitment answered at the first ACCEPT is never replaced.
        if round <= 1 { return true }
        guard let last = lastAccepted else { return false }
        return round <= last
    }

    /// R-COMMIT-BIND: true for an ACCEPT that echoes round 1 while a re-key attempt (rounds >= 2) is in
    /// flight. Round 1 is bound exactly once, so such an ACCEPT is never the answer to anything.
    /// `internal` so a unit test can pin the decision.
    static func isStrayRound1Accept(isReKeyAccept: Bool, echoedRound: Int?) -> Bool {
        isReKeyAccept && echoedRound == 1
    }

    /// A2: true for a round-1 OFFER that replaces the unanswered round-1 OFFER this callee already processed:
    /// round 1 with a valid commitment (`commitmentCode == nil`), for a call that has a context, which is not a
    /// retransmit of an OFFER already processed (that one re-sends the cached ACCEPT), and only while this device
    /// has not sent its ACCEPT. After the ACCEPT is sent it is false: the OFFER is dropped as a stale round.
    /// `internal` so a unit test can pin the decision.
    static func isUnansweredRound1Replacement(round: Int?, commitmentCode: String?, hasCallContext: Bool,
                                              isKnownRetransmit: Bool, acceptNotYetSent: Bool) -> Bool {
        round == 1 && commitmentCode == nil && hasCallContext && !isKnownRetransmit && acceptNotYetSent
    }

    /// A2: true for an OFFER that must be dropped silently because this callee holds an answered round-1 OFFER
    /// whose ACCEPT it has not sent yet, and the new one is not a valid round-1 OFFER (any other round, or a
    /// missing / malformed commitment). No hangup and no state: the held round stays. A retransmit of an OFFER
    /// already processed is not concerned (it re-sends the cached ACCEPT), and once the ACCEPT is out the
    /// ordinary rules apply again. `internal` so a unit test can pin the decision.
    static func isInvalidOfferWhileUnanswered(round: Int?, commitmentCode: String?, hasCallContext: Bool,
                                              isKnownRetransmit: Bool, acceptNotYetSent: Bool) -> Bool {
        hasCallContext && !isKnownRetransmit && acceptNotYetSent && (round != 1 || commitmentCode != nil)
    }

    /// A2: wipe the round-1 handshake state of a call whose ACCEPT was never sent, so the newest round-1 OFFER can
    /// be processed as the first one (WIRE_SPEC §3.7.4). The dedup and freshness bookkeeping, the pinned DTLS
    /// fingerprint, the key-round map, the held ACCEPT, the held-media flag, the call-scoped SAS pins and the whole
    /// SAS commitment context of the replaced round go; `onUnansweredRound1Superseded` lets the app drop what it
    /// queued for the replaced round (deferred ring-time actions, the ring key, the identity gate).
    func supersedeUnansweredRound1(callId: String) {
        let id = callId.lowercased()
        let prefix = id + "#"
        cancelSasRevealTimer(callId: callId)
        lock.withLock {
            sessionInitializedByCall.remove(id)
            processedOfferFingerprintsByCall = processedOfferFingerprintsByCall.filter { !$0.hasPrefix(prefix) }
            acceptWireByOfferFingerprint = acceptWireByOfferFingerprint.filter { !$0.key.hasPrefix(prefix) }
            lastAcceptedRekeyRoundByCall.removeValue(forKey: id)
            peerDtlsFingerprintByCall.removeValue(forKey: id)
            keyRoundByCall.removeValue(forKey: id)
            heldAcceptByCall.removeValue(forKey: id)
            heldCalls.remove(id)
        }
        sasPins.clear(callId: callId)
        sasCommit.clear(callId: callId)
        onUnansweredRound1Superseded?(callId)
    }

    static func rekeyFreshnessValue(callId: String, rekeyNonce: Data, round: UInt32) -> Data {
        precondition(rekeyNonce.count == 8, "rekeyNonce must be 8 bytes")
        var ikm = Data(callId.utf8)
        ikm.append(rekeyNonce)
        var info = Data("rekey-round".utf8)
        info.append(UInt8((round >> 24) & 0xFF))
        info.append(UInt8((round >> 16) & 0xFF))
        info.append(UInt8((round >> 8) & 0xFF))
        info.append(UInt8(round & 0xFF))
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data(),
            info: info,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// Surface a decrypted incoming chat body. If the body parses as a
    /// `{"qfile":…}` file marker, emit a delegate event; otherwise no-op
    /// (regular chat text is handled by the messaging stack).
    ///
    /// The WS dispatcher should call this after `MessageCrypto.decrypt`
    /// returns plaintext.
    public func onIncomingChatText(_ plaintext: String, from senderId: String) {
        if let marker = FileTransfer.tryParseMarker(text: plaintext) {
            qaudionDidReceiveFile?(marker, senderId)
        }
    }

    public func processOutgoingAudio(pcmFrame: Data) throws -> Data {
        // Tier 1 ("voce come chiave") — RAW pre-encode TX PCM, the LOCAL
        // mic. Enqueues onto its own private queue and returns immediately
        // (never blocks this real-time path) — see `OwnerContinuityMonitor
        // .feed` kdoc.
        ownerContinuityMonitor.feed(pcmFrame: pcmFrame)
        return try engine.processOutgoingAudio(pcmFrame: pcmFrame)
    }

    /// Tier 2 ("voce remota") — switch the active contact for continuous
    /// per-contact RX verification (auto-enrolls from live call audio if
    /// no template exists yet for `contactId`). Call once the call's peer
    /// is known; safe to call redundantly (a no-op if `contactId` is
    /// already active). See `deactivateContactVoiceVerification` for the
    /// call-end counterpart.
    public func activateContactVoiceVerification(contactId: String) {
        contactVoiceVerifier.setActiveContact(contactId)
    }

    /// Tier 2 counterpart to `activateContactVoiceVerification` — stops the
    /// continuous per-contact check without persisting anything partial.
    public func deactivateContactVoiceVerification() {
        contactVoiceVerifier.deactivate()
    }

    /// True after `OwnerContinuityMonitor`'s own hysteresis streak has
    /// actually tripped (3 consecutive Mismatch windows), not just the
    /// current tick. The app layer consults this when mapping a fresh
    /// `.mismatch` tick for the `OWNER_CONT` wire announce — mirrors
    /// Android's `onConnected` watcher, which downgrades a single noisy
    /// Mismatch tick to `Uncertain` on the wire unless this has tripped, so
    /// the PEER is never false-alarmed by one bad window.
    public func ownerContinuityShouldAlert() -> Bool {
        ownerContinuityMonitor.shouldAlert()
    }

    /// Feature B ("voce verificata") — start learning `contactId`'s voice
    /// from THIS call's decoded RX audio, from this point forward. Replaces
    /// any previously in-flight session for this integration instance
    /// (there is only ever one active call per integration).
    /// W-IOSAUDIOSTARVE thread-safety note: `voiceLearningSession` and the
    /// `VoiceLearningSession` it points at are owned EXCLUSIVELY by
    /// `rxAnalysisQueue`. Unlike its siblings (`GuardianMode`,
    /// `ContactVoiceVerifier`, `VoiceAnalysisEngine`, `SpectrumExtractor`)
    /// that class carries no internal lock, and `processRxFrame` now runs on
    /// the analysis queue — so start/cancel must hop onto that same queue
    /// rather than mutating it from whatever thread the UI happens to call
    /// from. Before this change every one of these ran on the main queue and
    /// the single-thread assumption held for free; it no longer does.
    public func startVoiceLearning(contactId: String) {
        rxAnalysisQueue.async { [weak self] in
            guard let self else { return }
            let session = VoiceLearningSession()
            self.voiceLearningSession = session
            session.start(contactId: contactId)
            let state = session.state
            DispatchQueue.main.async { self.onVoiceLearningStateChanged?(state) }
        }
    }

    /// Cancel an in-flight voice-learning session without persisting
    /// anything partial. See `startVoiceLearning` for why this hops queues.
    public func cancelVoiceLearning() {
        rxAnalysisQueue.async { [weak self] in
            guard let self else { return }
            self.voiceLearningSession?.cancel()
            self.voiceLearningSession = nil
            DispatchQueue.main.async { self.onVoiceLearningStateChanged?(.idle) }
        }
    }

    /// Decode one incoming audio frame and return the PCM.
    ///
    /// AUDIO-CRITICAL PATH — keep this function to unseal + decode + return.
    /// It runs on the caller's thread, which today is the MAIN queue (see
    /// `CallService`), and that same queue refills a playout node holding only
    /// 40 ms. Anything expensive added here is rendered as silence at the
    /// speaker. Analysis belongs on `rxAnalysisQueue` — see the
    /// W-IOSAUDIOSTARVE note on that property for the measured incident.
    public func processIncomingAudio(serializedFrame: Data) throws -> Data {
        let pcm = try engine.processIncomingAudio(serializedFrame: serializedFrame)
        enqueueForAnalysis(pcm)
        return pcm
    }

    /// IOS-C4b / PCM-TAP PARITY (2026-08-26) — the native-audio-srtp RX
    /// counterpart of `processIncomingAudio`, for a call that negotiated
    /// `CallCapabilities.audioSrtpV1`. On such a call the peer sends real
    /// SRTP, never a serialized DataChannel/WS frame, so
    /// `processIncomingAudio` above is NEVER called for its whole
    /// life — without this method every RX consumer it feeds
    /// (`guardianMode`, `contactVoiceVerifier`, `voiceLearningSession`,
    /// `voiceAnalysis`, `spectrumExtractor`) would silently see zero frames.
    /// See `NativeAudioPcmTap`'s own doc for the full incident this exists
    /// to avoid (Android's real, shipped `W-AUDIOSRTPFEATUREPARITY`
    /// incident, confirmed present on iOS by tracing this exact call chain).
    ///
    /// Wired from `QAudionWebRtcCallController.onNativeAudioSrtpRxPcm` via
    /// `CallService`. `pcm` is already little-endian Int16 mono 48 kHz —
    /// the SAME layout `enqueueForAnalysis`'s callers assume — so this
    /// reuses the identical bounded-ring / rxAnalysisQueue machinery with
    /// zero new consumer code, only a new PRODUCER.
    public func feedNativeAudioSrtpRxPcm(_ pcm: Data) {
        enqueueForAnalysis(pcm)
    }

    /// TX/local-mic counterpart — mirrors `processOutgoingAudio`'s
    /// `ownerContinuityMonitor.feed(pcmFrame:)` call, minus the Opus encode
    /// (native SRTP owns encoding on this path). Wired from
    /// `QAudionWebRtcCallController.onNativeAudioSrtpTxPcm`.
    public func feedNativeAudioSrtpTxPcm(_ pcm: Data) {
        ownerContinuityMonitor.feed(pcmFrame: pcm)
    }

    /// Hand decoded RX PCM to the analysis queue. Bounded and drop-oldest:
    /// under load this discards analysis frames rather than letting the
    /// backlog grow or blocking the audio thread. Every consumer downstream
    /// is an advisory signal that already self-throttles, so a dropped frame
    /// costs nothing a listener can hear — unlike the alternative.
    private func enqueueForAnalysis(_ pcm: Data) {
        var shouldSchedule = false
        rxRingLock.lock()
        rxRing.append(pcm)
        if rxRing.count > rxRingCapacity {
            rxRing.removeFirst(rxRing.count - rxRingCapacity)
        }
        if !rxDrainScheduled {
            rxDrainScheduled = true
            shouldSchedule = true
        }
        rxRingLock.unlock()

        guard shouldSchedule else { return }
        rxAnalysisQueue.async { [weak self] in
            self?.drainAnalysisRing()
        }
    }

    /// Drain the RX ring on `rxAnalysisQueue`. Serial by construction, so the
    /// consumers below keep the single-thread contract their own docs assume —
    /// it is simply no longer the audio thread.
    private func drainAnalysisRing() {
        while true {
            rxRingLock.lock()
            guard let pcm = rxRing.first else {
                rxDrainScheduled = false
                rxRingLock.unlock()
                return
            }
            rxRing.removeFirst()
            rxRingLock.unlock()
            analyze(pcm)
        }
    }

    /// The former body of `processIncomingAudio`, now off the audio path.
    private func analyze(_ pcm: Data) {
        guardianMode.processFrame(pcm)
        // Tier 2 ("voce remota") — cheap continuous feed, safe to call
        // unconditionally (a no-op unless `activateContactVoiceVerification`
        // has set an active contact — see `ContactVoiceVerifier
        // .feedContinuous` kdoc). Never triggers the expensive embedding
        // recompute; that runs on `ContactVoiceVerifier`'s own internal
        // ~1s-throttled timer, off this thread entirely.
        contactVoiceVerifier.feedContinuous(pcm)
        // Feature B — feed the SAME decoded RX PCM used by the guardian tap
        // above into the per-contact learning session, if one is running.
        // Deliberately the RX path, never TX/mic — see `VoiceLearningSession`'s
        // type doc for why that distinction matters.
        if let session = voiceLearningSession {
            session.processRxFrame(pcm)
            let state = session.state
            // UI-facing: hop to main. The callback drives SwiftUI state and
            // must not be invoked from the analysis queue.
            DispatchQueue.main.async { [weak self] in
                self?.onVoiceLearningStateChanged?(state)
            }
            switch state {
            case .completed, .failed:
                voiceLearningSession = nil
            case .idle, .inProgress:
                break
            }
        }
        // Unified call UI — voice biometrics (pitch/stress/HNR) of the REMOTE
        // party. Moved here from processOutgoingAudio (2026-07-04): it used to
        // analyze the TX mic (YOUR OWN voice), while the Guardian ribbon
        // gauges are explicitly about the INTERLOCUTOR — Android has always
        // analyzed the decoded RX path (CallAudioBridge → feedVoiceAnalysis).
        // The engine self-throttles (analysisRate) and runs synchronously.
        voiceAnalysis.processFrame(pcm)
        // Unified call UI — REAL remote-voice spectrum, ≤15 Hz (66 ms
        // monotonic throttle). Skipped entirely while nothing is wired to
        // consume it.
        if let spectrumSink = onVoiceSpectrum {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if nowNs &- lastSpectrumUptimeNs >= 66_000_000 {
                lastSpectrumUptimeNs = nowNs
                // Little-endian Int16 PCM @ 48 kHz — the same layout + rate
                // the sibling analysis DSP assumes (see PitchExtractor).
                let samples: [Int16] = pcm.withUnsafeBytes { raw in
                    Array(raw.bindMemory(to: Int16.self))
                }
                let bands = spectrumExtractor.compute(samples, sampleRate: 48_000)
                DispatchQueue.main.async { spectrumSink(bands) }
            }
        }
    }

    public func onCallEnded() {
        engine.destroySession()
        engine.release()
        // W-IOSAUDIOSTARVE — drop any decoded RX audio still queued for
        // analysis. It is plaintext call audio and must not outlive the call,
        // and analysing the tail of a finished call against the NEXT call's
        // contact would be wrong anyway.
        rxRingLock.lock()
        rxRing.removeAll()
        rxRingLock.unlock()
        // Feature B — drop any in-flight per-contact voice-learning session
        // so a straggling reference never bleeds into the next call (which
        // may be with a different peer entirely). On rxAnalysisQueue, which
        // owns this object — see startVoiceLearning's note.
        rxAnalysisQueue.async { [weak self] in
            self?.voiceLearningSession = nil
        }
        // Tier 1/Tier 2 — this integration instance can be REUSED for a
        // later call (see M-11 comment below), so neither monitor gets a
        // fresh `init()` next time: deactivate the per-contact verifier
        // (Tier 2) and stop+immediately restart the owner-continuity
        // monitor's buffering (Tier 1) here instead, so whichever call
        // reuses this instance starts with clean, empty buffers rather than
        // straddling into a prior, unrelated call's leftover audio.
        contactVoiceVerifier.deactivate()
        ownerContinuityMonitor.stop()
        ownerContinuityMonitor.start()
        // M-15 — cancel any pending capability-exchange fallback so it
        // cannot fire on a later, unrelated call.
        lock.lock()
        state = .idle
        localKeyPair = nil
        isCaller = false
        isLocallyRinging = false
        pendingResponderCallId = nil
        pendingResponderCallerId = nil
        pendingOutgoingCallId = nil
        // M-11 — a reused integration instance must not skip PQC on a
        // later call: clear all per-callId state so the next call
        // re-runs key generation + session init from scratch.
        sessionInitializedByCall.removeAll()
        // I3 — same reasoning as sessionInitializedByCall above: a reused
        // integration instance must not carry a prior call's OFFER
        // fingerprints/cached ACCEPTs into the next call.
        processedOfferFingerprintsByCall.removeAll()
        acceptWireByOfferFingerprint.removeAll()
        // I3 §5 — same reasoning; also resolve (never leak) an in-flight
        // re-key attempt's continuation if the call ends while one is
        // outstanding, so performPqcReKey's awaiter returns `false` instead
        // of hanging until its own timeout fires on a dead call.
        processedAcceptFingerprintsByCall.removeAll()
        let orphanedReKeyResume = pendingReKeyAttempt?.resume
        pendingReKeyAttempt = nil
        orphanedReKeyResume?(nil)
        localHybridKeysByCall.removeAll()
        // Phase-10b: clear the stashed sent-OFFER transcripts so a reused
        // integration does not leak a prior call's offer_binding into the next
        // call's ACCEPT verification.
        sentOfferTranscriptByCall.removeAll()
        // The round/nonce ratchets and the pinned peer DTLS fingerprint: a reused integration
        // instance must not carry a prior call's nonce, accepted-round watermark or fingerprint
        // pin into the next call — clearing unconditionally is the same "never trust stale
        // per-call state" discipline every dictionary in this block follows.
        rekeyNonceByCall.removeAll()
        rekeyRoundByCall.removeAll()
        lastAcceptedRekeyRoundByCall.removeAll()
        peerDtlsFingerprintByCall.removeAll()
        keyRoundByCall.removeAll()
        sasPins.clearAll()
        heldCalls.removeAll()
        rekeyDeferredWhileHeld.removeAll()
        // W-KCMAC — same reasoning, the stashed sent-OFFER PSK advert list.
        sentOfferPskFingerprintsByCall.removeAll()
        // W-KCMACROLES — the parallel role list is stashed and cleared in lockstep
        // with the fingerprints above; a stale role array would mis-MAC the next call
        // exactly like a stale fingerprint array would.
        sentOfferPskRolesByCall.removeAll()
        // R-COMMIT-NONCE: the SAS nonce is zeroised and every commitment state dropped with the call,
        // whatever the outcome; the REVEAL timers die with it.
        sasCommit.clearAll()
        boundRound1AcceptKeyByCall.removeAll()
        let orphanedRevealTimers = Array(sasRevealTimers.values)
        sasRevealTimers.removeAll()
        // W529 / W531: clear handshake retry state so the next call
        // starts with a fresh stash.
        lastSentOfferWire = nil
        lastSentAcceptWire = nil
        handshakeStartedAt = nil
        retrySenderClosure = nil
        // W-MEDIAATACCEPT (option b) — I13: a held-but-never-released
        // ACCEPT (call ended while still ringing) must never survive into
        // whatever call reuses this integration instance next.
        heldAcceptByCall.removeAll()
        lock.unlock()
        for timer in orphanedRevealTimers { timer.cancel() }
        offerRetryTask?.cancel()
        offerRetryTask = nil
        onStateChanged?(.idle)
    }

    // MARK: - earbud-relay-v1 (HW firmware) counterparty install

    /// earbud-relay-v1 counterparty install — RETIRED under transcript v6 (fail-closed).
    ///
    /// The earbud-relay-v1 counterparty handshake (`EarbudHandshakeResponder`) yields a key with no
    /// signed OFFER_v6/ACCEPT_v6 behind it: there is no transcript to bind the session key, the SAS
    /// and the key confirmation to, and no signed DTLS certificate fingerprint to pin. Under the v5
    /// hard switch such a session would be weaker than every other 1:1 call, so no session is
    /// installed and the call keeps no key (the app logs the failure). Re-enabling it needs a v5
    /// counterparty handshake on the earbud side (a firmware change).
    public func completeEarbudCounterparty(callId: String, sessionKey: Data) throws {
        print("[QAudionCallIntegration] earbud counterparty key NOT installed (retired under transcript v6) callId=\(callId.prefix(8))…")
        throw IntegrationError.handshakeAborted(code: "earbud_relay_retired")
    }

    // MARK: - SAS commitment: REVEAL send, REVEAL timer, REVEAL handling (WIRE_SPEC §3.7.4)

    /// Send the caller's REVEAL (or its byte-identical re-send) through the string channel the OFFER
    /// used. A send failure is logged as a verdict and never throws: the re-send paths (a duplicate of
    /// the bound ACCEPT, a WS re-auth) recover it, and a callee that never gets it ends the call itself
    /// (`sas_reveal_timeout`). Verdict-only: no nonce, binding or word ever reaches a log.
    private func sendSasReveal(_ wire: String, callId: String, resend: Bool) async {
        guard let sender = lock.withLock({ retrySenderClosure }) else {
            print("[QAudionCallIntegration] sas_commit reveal not sent (no sender) callId=\(callId.prefix(8))…")
            return
        }
        // A1: "sent" is the hand-over to the transport. The caller's 15 s wait for the callee's round-1 KCMAC
        // (`KcMacWindow`) runs from here, before the write completes.
        sasCommit.callerRevealHanded(callId: callId, nowMs: SasCommit.monotonicNowMs())
        do {
            try await sender(wire)
            print("[QAudionCallIntegration] sas_commit \(resend ? "resent" : "revealed") callId=\(callId.prefix(8))…")
        } catch {
            print("[QAudionCallIntegration] sas_commit reveal send failed callId=\(callId.prefix(8))…")
        }
    }

    /// The round-1 ACCEPT is actually on the wire: the FIRST such send starts the callee's 5 s REVEAL
    /// timer. Later sends (retransmissions, cached replays) never restart it, and a call that is not a
    /// callee of a round-1 OFFER (no commitment stored) is a no-op.
    private func noteResponderAcceptSent(callId: String) {
        guard sasCommit.calleeAcceptSent(callId: callId, nowMs: SasCommit.monotonicNowMs()) else { return }
        armSasRevealTimer(callId: callId)
    }

    private func armSasRevealTimer(callId: String) {
        let id = callId.lowercased()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(SasCommit.revealTimeoutMs) * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            self.sasRevealTimerFired(callId: id)
        }
        let previous: Task<Void, Never>? = lock.withLock {
            let old = sasRevealTimers[id]
            sasRevealTimers[id] = task
            return old
        }
        previous?.cancel()
    }

    private func sasRevealTimerFired(callId: String) {
        lock.withLock { _ = sasRevealTimers.removeValue(forKey: callId) }
        if case .end(let reason) = sasCommit.calleeTimerFired(callId: callId) {
            print("[QAudionCallIntegration] sas_commit timeout callId=\(callId.prefix(8))…")
            reportHandshakeFatal(callId: callId, reason: reason)
        }
    }

    private func cancelSasRevealTimer(callId: String) {
        let timer: Task<Void, Never>? = lock.withLock { sasRevealTimers.removeValue(forKey: callId.lowercased()) }
        timer?.cancel()
    }

    /// What the app does with a REVEAL this device received from the call peer.
    public enum SasRevealResult: Equatable {
        /// Dropped silently (no call, no sent ACCEPT, a verified duplicate, another tag): nothing to do.
        case dropped
        /// The nonce opened the commitment: the round-1 words are now available.
        case sasReady
        /// The call ends with this security reason and the peer is notified.
        case ended(reason: String)
        /// This device's ACCEPT was not the one the caller bound: leave the call locally and do NOT
        /// notify the peer (no `call_hangup`, no `HANGUP:`), stop KCMAC handling.
        case leftLocally
    }

    /// A `SASREVEAL:` opaque message from the call peer (the app checks the sender). `data` is the whole
    /// literal `opaque_message.data`.
    public func handleSasReveal(callId: String, data: String) -> SasRevealResult {
        let outcome = sasCommit.calleeOnReveal(callId: callId, data: data, nowMs: SasCommit.monotonicNowMs())
        switch outcome {
        case .none, .dropped:
            return .dropped
        case .sasReady:
            cancelSasRevealTimer(callId: callId)
            print("[QAudionCallIntegration] sas_commit ok callId=\(callId.prefix(8))…")
            return .sasReady
        case .end(let reason):
            cancelSasRevealTimer(callId: callId)
            print("[QAudionCallIntegration] sas_commit mismatch callId=\(callId.prefix(8))…")
            return .ended(reason: reason)
        case .leaveLocally:
            cancelSasRevealTimer(callId: callId)
            print("[QAudionCallIntegration] sas_commit sibling callId=\(callId.prefix(8))…")
            return .leftLocally
        }
    }

    /// Forget everything the SAS commitment knows about `callId` (cancelled, declined or superseded while
    /// ringing, or ended): the nonce and commitment, the held round-1 material, the REVEAL timer.
    public func wipeSasCommitState(callId: String) {
        cancelSasRevealTimer(callId: callId)
        sasCommit.clear(callId: callId)
        _ = lock.withLock { boundRound1AcceptKeyByCall.removeValue(forKey: callId.lowercased()) }
    }

    /// False once this device left the call as a sibling (or ended on a SAS-commit failure): the app
    /// stops judging key-confirmation MACs for it, so the loser never ends the real call.
    public func acceptsKeyConfirmation(callId: String) -> Bool {
        sasCommit.calleeAcceptsKeyConfirmation(callId: callId)
    }

    /// True when this device is the CALLER of `callId`: it never processes a REVEAL.
    public func isSasCaller(callId: String) -> Bool {
        sasCommit.isCaller(callId: callId)
    }

    /// True when this device is a callee of `callId` that sent its round-1 ACCEPT.
    public func isSasCallee(callId: String) -> Bool {
        sasCommit.isCallee(callId: callId)
    }

    // MARK: - W529: idempotent OFFER retry timer

    /// Arm a 5 s retry loop that re-emits the EXACT same OFFER bundle
    /// every interval while the handshake hasn't completed (state
    /// stays `.capabilitySent`) and we're still inside the
    /// handshakeTimeout window. On Android/iOS the responder's
    /// `sessionInitializedByCall` dedup turns each duplicate OFFER
    /// into a cached-ACCEPT replay (see W529 changes in
    /// onAndroidBundleReceived.offer), so retries are byte-identical
    /// at the network layer and idempotent at the crypto layer.
    private func armOfferRetryTimer() {
        offerRetryTask?.cancel()
        offerRetryTask = Task { [weak self] in
            // Wait the first interval BEFORE re-sending — the
            // happy-path ACCEPT typically arrives in ~1 s on Wi-Fi,
            // so retrying too eagerly would cost bandwidth.
            let interval = self?.offerRetryIntervalSec ?? 5
            let timeout = self?.handshakeTimeoutSec ?? 30.0
            var elapsed: Double = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                if Task.isCancelled { return }
                elapsed += Double(interval)
                if elapsed > timeout { return }
                guard let self = self else { return }
                // Snapshot the state + cached wire + sender under the lock.
                let snapshot: (state: CallState, wire: String?, sender: ((String) async throws -> Void)?) =
                    self.lock.withLock {
                        (self.state, self.lastSentOfferWire, self.retrySenderClosure)
                    }
                // W540-A: keep retrying the OFFER for ANY pre-active
                // handshake state. The original W529 guard was
                // `state == .capabilitySent` only, which stopped
                // retrying as soon as the integration advanced to
                // `.connecting` (call_processing received from the
                // peer). Confirmed in iPhone→S24 call a7ab0514:
                // peer ACK'd OFFER with call_processing → integration
                // went to .connecting → retry loop bailed out → ACCEPT
                // then never arrived → silent 30 s timeout.
                //
                // The right invariant: retry while we DON'T have a
                // session key yet, regardless of which pre-active
                // state we're in. As soon as ACCEPT decapsulates we
                // hit .active and cancelHandshakeRetries fires from
                // the session-key path; here we just enumerate the
                // pre-active states explicitly so future enum cases
                // can't accidentally suppress retries.
                let preActive: Bool
                switch snapshot.state {
                case .capabilitySent, .negotiating, .connecting, .ringing:
                    preActive = true
                case .idle, .active, .fallback, .error:
                    preActive = false
                }
                guard preActive,
                      let wire = snapshot.wire,
                      let sender = snapshot.sender else { return }
                let elapsedSec: Int = Int(elapsed)
                let stateStr: String = String(describing: snapshot.state)
                let logLine: String = "[QAudionCallIntegration] W529: retrying OFFER (elapsed=" + String(describing: elapsedSec) + "s state=" + stateStr + ")"
                print(logLine)
                try? await sender(wire)
            }
        }
    }

    /// W529 / W531: explicit cancel hook for the retry loop. Called by
    /// AppState (or any caller path) the moment we know the handshake
    /// has succeeded — i.e. when onPqcSessionKeyEstablished fires for
    /// the caller, or when the call ends.
    public func cancelHandshakeRetries() {
        offerRetryTask?.cancel()
        offerRetryTask = nil
    }

    // MARK: - W-MEDIAATACCEPT (option b) — I11: held responder ACCEPT

    /// Single gate for a JSON responder ACCEPT — first computation
    /// (`case .offer`'s `sendOpaqueRaw(wire)`) AND the duplicate-OFFER
    /// replay (`sendOpaqueRaw(cached)`) both funnel through here. Holds
    /// (stores, does not send) when `shouldHoldResponderAccept` says so;
    /// otherwise sends immediately — today's behavior when that closure is
    /// nil or returns false. Never touches the surrounding crypto/session
    /// derivation, only the wire send.
    ///
    /// `isRound1`: this is the round-1 ACCEPT. Its FIRST actual send freezes the answered commitment and
    /// starts the callee's 5 s REVEAL timer (`noteResponderAcceptSent`); a held ACCEPT starts it when it
    /// is released, not before.
    private func emitJsonAccept(callId: String, wire: String, sendOpaqueRaw: @escaping (String) async throws -> Void, isRound1: Bool) async throws {
        let cid = callId.lowercased()
        if !cid.isEmpty, shouldHoldResponderAccept?(cid) == true {
            lock.withLock { heldAcceptByCall[cid] = .json(wire) }
            print("[QAudionCallIntegration] W-MEDIAATACCEPT ACCEPT held (json) callId=\(cid.prefix(8))…")
            await releaseIfHoldLifted(cid)
            return
        }
        // WIRE_SPEC §3.7.4: the ACCEPT counts as SENT from the moment it is handed to the transport,
        // before the write completes, so a REVEAL processed right after cannot look early.
        if isRound1 { noteResponderAcceptSent(callId: callId) }
        try await sendOpaqueRaw(wire)
    }

    /// Review fix — closes the check-then-store race of the two gates above:
    /// the app may lift the hold (ACCEPT released after its own call_answer,
    /// or a `mode == 0` latch) on another thread BETWEEN the
    /// `shouldHoldResponderAccept` read and the `heldAcceptByCall` store; its
    /// `releaseHeldAccept` then found nothing and nobody would ever send this
    /// ACCEPT (caller without a key, silent call). Re-reading the gate after
    /// the store and releasing here makes that interleaving harmless;
    /// `releaseHeldAccept`'s locked take-and-clear guarantees a single send
    /// if both sides race.
    private func releaseIfHoldLifted(_ cid: String) async {
        guard shouldHoldResponderAccept?(cid) != true else { return }
        _ = await releaseHeldAccept(callId: cid)
    }

    /// AppState calls this once the callee's own `call_answer` for this
    /// call has been sent (or the 5 s reserve timer elapsed) — I11. Sends
    /// whatever ACCEPT is currently held for `callId`, if any, using the
    /// sender captured at computation time. Returns whether a held ACCEPT
    /// was actually found and sent; a `false` with no held entry is the
    /// ordinary case for a call that was never in `mode == 1` (nothing was
    /// ever held) or was already released.
    @discardableResult
    public func releaseHeldAccept(callId: String) async -> Bool {
        let cid = callId.lowercased()
        let held: HeldAccept? = lock.withLock {
            let v = heldAcceptByCall[cid]
            heldAcceptByCall[cid] = nil
            return v
        }
        guard let held = held else { return false }
        do {
            switch held {
            case .json(let wire):
                guard let sender = lock.withLock({ retrySenderClosure }) else {
                    print("[QAudionCallIntegration] W-MEDIAATACCEPT release(json) callId=\(cid.prefix(8))… no sender")
                    return false
                }
                // The held ACCEPT is the round-1 ACCEPT: this is its first actual send (it counts as
                // sent from the hand-over to the transport, WIRE_SPEC §3.7.4).
                noteResponderAcceptSent(callId: cid)
                try await sender(wire)
            }
            print("[QAudionCallIntegration] W-MEDIAATACCEPT ACCEPT released callId=\(cid.prefix(8))…")
            return true
        } catch {
            // W-SIGSWALLOW parity — never silently drop a release failure.
            print("[QAudionCallIntegration] W-MEDIAATACCEPT ACCEPT release send fail callId=\(cid.prefix(8))… err=\(error)")
            return false
        }
    }

    /// Drops a held ACCEPT without sending it — call ended/rejected/
    /// cancelled/superseded while still ringing (I13). Safe no-op if
    /// nothing is held for `callId`.
    public func dropHeldAccept(callId: String) {
        let cid = callId.lowercased()
        lock.withLock { heldAcceptByCall[cid] = nil }
    }

    // MARK: - W531: WS-reconnect handshake replay

    /// Re-emit the last unACKed handshake bundle if we're still in
    /// the handshake window. Idempotent at the wire level (caller
    /// re-sends same OFFER bytes, responder re-sends same ACCEPT
    /// bytes — both sides ignore dups). Called by AppState when
    /// BCryptoWS state transitions back to `.authenticated` during a
    /// call that's in `.capabilitySent` (caller) state OR has not yet
    /// reached `.active` (responder).
    public func replayPendingHandshake() async {
        let snapshot: (started: Date?, state: CallState, offer: String?, accept: String?, isCaller: Bool, sender: ((String) async throws -> Void)?, responderCallId: String?) =
            lock.withLock {
                (handshakeStartedAt, state, lastSentOfferWire, lastSentAcceptWire, isCaller, retrySenderClosure, pendingResponderCallId)
            }
        guard let startedAt = snapshot.started else { return }
        guard Date().timeIntervalSince(startedAt) < handshakeTimeoutSec else { return }
        // R-COMMIT-REVEAL: a caller that already bound its round-1 ACCEPT re-sends the byte-identical
        // REVEAL on a WS re-auth inside the handshake window (the callee drops duplicates silently), at
        // most `SasCommit.maxRevealResends` times per call. This runs whatever the state: the caller is
        // `.active` as soon as its session key is installed, long before the callee has the REVEAL.
        if snapshot.isCaller, let callId = lock.withLock({ pendingOutgoingCallId }),
           let revealWire = sasCommit.callerResendReveal(callId: callId) {
            await sendSasReveal(revealWire, callId: callId, resend: true)
        }
        // Skip if the handshake is already done — caller transitions
        // to .active when ACCEPT decapsulates, responder also moves
        // through .active. Also bail on terminal/reset states. Replay
        // only makes sense in the handshake-in-flight window
        // (.capabilitySent, .negotiating, .connecting, .ringing).
        switch snapshot.state {
        case .idle, .active, .fallback, .error:
            return
        case .capabilitySent, .negotiating, .connecting, .ringing:
            break  // proceed to replay
        }
        guard let sender = snapshot.sender else { return }
        let toReplay: String? = snapshot.isCaller ? snapshot.offer : snapshot.accept
        guard let wire = toReplay else { return }
        let role: String = snapshot.isCaller ? "OFFER" : "ACCEPT"
        // W-MEDIAATACCEPT (option b) — I11: the responder branch of this
        // replay is subject to the SAME hold gate as every other ACCEPT
        // emission point. The caller's own OFFER replay is never held.
        //
        // G5 fix (adversarial review of 7825c191) — `emitJsonAccept`'s hold
        // gate is `if !cid.isEmpty, shouldHoldResponderAccept?(cid) == true`:
        // an EMPTY `callId` makes that condition false regardless of what
        // the gate closure would have said, so it falls straight through to
        // `sendOpaqueRaw(wire)` — i.e. an unknown call id used to BYPASS
        // I11's hold entirely instead of defaulting to the safe side.
        // `snapshot.responderCallId` is expected to already be set by this
        // point for every real responder handshake (see
        // `pendingResponderCallId`'s own doc), so this should be dead code
        // in practice — but "should never happen" is exactly the case a
        // fail-CLOSED default exists for: hold (do not send) rather than
        // risk disclosing this device's ACCEPT, and therefore its
        // media-plane readiness, for a call this replay cannot identify.
        if !snapshot.isCaller {
            guard let responderCallId = snapshot.responderCallId, !responderCallId.isEmpty else {
                print("[QAudionCallIntegration] W-MEDIAATACCEPT W531 replay(ACCEPT) held — unknown responderCallId, failing closed")
                return
            }
            try? await emitJsonAccept(callId: responderCallId, wire: wire, sendOpaqueRaw: sender, isRound1: false)
            let logLine: String = "[QAudionCallIntegration] W531: replaying " + role + " on WS reconnect"
            print(logLine)
            return
        }
        let logLine: String = "[QAudionCallIntegration] W531: replaying " + role + " on WS reconnect"
        print(logLine)
        try? await sender(wire)
    }

    // MARK: - Pre-negotiation event entry points
    // These are invoked by the WS dispatch layer (BCryptoWebSocketClient
    // callbacks) so the integration can drive the state machine and the UI
    // without owning the socket directly.

    /// Caller side — called right after `sendCallOffer` so the integration knows
    /// which callId to associate with subsequent pre-negotiation events.
    public func didSendOutgoingCallOffer(callId: String) {
        lock.lock()
        pendingOutgoingCallId = callId
        isCaller = true
        lock.unlock()
    }

    /// Responder side — called when an inbound `call_offer` envelope is parsed,
    /// BEFORE the matching opaque PQC OFFER arrives. Stashes IDs so the OFFER
    /// case in onCapabilityMessageReceived can emit pre-negotiation ACKs.
    public func didReceiveIncomingCallOffer(callId: String, callerId: String) {
        lock.lock()
        pendingResponderCallId = callId
        pendingResponderCallerId = callerId
        isCaller = false
        lock.unlock()
    }

    /// Tell the integration that the local UI/CallKit alert is now ringing for
    /// an incoming call, so the `call_ring` server ack doesn't trigger a
    /// duplicate fallback ring.
    public func setLocallyRinging(_ ringing: Bool) {
        lock.lock(); isLocallyRinging = ringing; lock.unlock()
    }

    /// Caller-side handler for inbound `call_processing`. Bumps state to
    /// `.connecting` so the UI can show "Connecting…".
    public func onCallProcessingReceived(callId: String, receiverId: String) {
        lock.lock()
        guard isCaller, callId.lowercased() == pendingOutgoingCallId?.lowercased() else { lock.unlock(); return }
        state = .connecting
        lock.unlock()
        onStateChanged?(.connecting)
    }

    /// Caller-side handler for inbound `call_ready`. Bumps state to `.ringing`
    /// so the UI can show "Ringing…" and (optionally) start the local ringback tone.
    public func onCallReadyReceived(callId: String, receiverId: String, deviceId: String?) {
        lock.lock()
        guard isCaller, callId.lowercased() == pendingOutgoingCallId?.lowercased() else { lock.unlock(); return }
        state = .ringing
        lock.unlock()
        onStateChanged?(.ringing)
    }

    /// Responder-side handler for inbound `call_ring` (server ack confirming
    /// the caller has been told we are ringing). If the local UI hasn't already
    /// kicked off a ring (e.g. setup ran async-slow), trigger the fallback ring.
    public func onCallRingReceived(callId: String, callerId: String) {
        lock.lock()
        let alreadyRinging = isLocallyRinging
        lock.unlock()
        guard !alreadyRinging else { return }
        // App layer wires CallKit / AVAudioSession ring + UI notification.
        requestRingLocally?(callId, callerId)
    }

    /// Caller-side handler for inbound `call_peer_offline`. Surfaces an error
    /// to the app layer so the call UI can be torn down.
    public func onPeerOfflineReceived(callId: String, recipientId: String) {
        lock.lock()
        guard isCaller, callId.lowercased() == pendingOutgoingCallId?.lowercased() else { lock.unlock(); return }
        state = .error
        lock.unlock()
        onStateChanged?(.error)
        onPeerOffline?(callId, recipientId)
    }

    /// Responder-side handler for inbound `call_cancel`. The caller hung up
    /// before we picked up — stop ringing locally.
    public func onCallCancelReceived(callId: String, reason: String?) {
        lock.lock()
        let isOurIncoming = !isCaller && callId.lowercased() == pendingResponderCallId?.lowercased()
        lock.unlock()
        guard isOurIncoming else { return }
        onIncomingCallCancelled?(callId, reason)
        onCallEnded()
    }

    public func getState() -> CallState { lock.lock(); defer { lock.unlock() }; return state }
    public func getGuardianMode() -> GuardianMode { guardianMode }
    public func getVoiceAnalysis() -> VoiceAnalysisEngine { voiceAnalysis }

    /// Reconfigure the Opus encoder after engine.initialize() has run.
    /// Safe to call from onStateChanged(.active) or from activateIncomingCallAudio.
    /// No-op before the engine is initialized.
    public func reconfigureAudioCodec(bitrateKbps: Int, plp: Int) {
        engine.reconfigureAudioCodec(bitrateKbps: bitrateKbps, plp: plp)
    }

    /// W-FECDECODE (2026-08-25) — forwards `engine.onFecRecoveredAudio`. A
    /// computed proxy rather than a copied closure: `engine` is a `let`
    /// constant for this integration's whole life, so there is no rebuild to
    /// go stale against, unlike `engine`'s own forwarding to `audioProcessor`.
    public var onFecRecoveredAudio: ((Data) -> Void)? {
        get { engine.onFecRecoveredAudio }
        set { engine.onFecRecoveredAudio = newValue }
    }

    /// W-FECDECODE — cumulative FEC recovery counters, for the rate-limited
    /// `fec_rec=<n> fec_fail=<n>` diagnostic.
    public func rxFecStats() -> (recovered: Int64, failed: Int64) {
        engine.rxFecStats()
    }

    /// W-PLPFEEDBACK — cumulative inbound-loss snapshot, for the periodic
    /// PLP: report timer.
    public func rxLossSnapshot() -> (expected: Int64, lost: Int64) {
        engine.rxLossSnapshot()
    }

    /// W-LONGAUDIO (2026-08-10) — latch this call's audio profile on the engine.
    /// Once per call, after the handshake, before capture starts. See
    /// `QAudionEngine.latchAudioProfile` for why it is terminal.
    @discardableResult
    public func latchAudioProfile(_ profile: AudioProfile) -> Bool {
        engine.latchAudioProfile(profile)
    }

    /// The profile this call is sealing into. `.standard` until latched.
    public var activeAudioProfile: AudioProfile { engine.activeAudioProfile }
}

public enum IntegrationError: Error {
    case invalidState(QAudionCallIntegration.CallState)
    /// Phase-10b fail-closed handshake abort (spec §4). `code` is one of
    /// `sig_invalid`, `identity_key_mismatch`, `sig_required_missing`,
    /// `sig_malformed`. Thrown BEFORE any session-key derivation / `initSession`,
    /// so an aborted handshake never installs a session.
    case handshakeAborted(code: String)
}
