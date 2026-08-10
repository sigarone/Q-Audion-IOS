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

    /// Per-call double-ACCEPT guard. Pre-fix the responder might emit
    /// BOTH a QUAD ACCEPT (legacy iOS↔iOS) AND a JSON ACCEPT (when iOS
    /// is talking to Android via the JSON path); on the originator
    /// side both branches would call `engine.initSession` in sequence,
    /// the second overwriting the first with a different shared secret.
    /// This set is consulted before `initSession` and discards
    /// duplicates. Per OpenRouter glm-5.1 review 2026-05-06.
    private var sessionInitializedByCall: Set<String> = []

    /// M-15 — handle for the 15s capability-exchange fallback timer so
    /// it can be cancelled when the call ends (otherwise it fires on a
    /// stale/unrelated subsequent call and forces it into `.fallback`).
    private var capabilityTimeoutWorkItem: DispatchWorkItem?

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

    /// W574x — go-live gate for directional per-direction PQC RTP sealer keys
    /// (fixes the bidirectional AES-GCM nonce reuse on the relay path). Mirrors
    /// Android `PqcHandshake.SRTP_DIR_KEYS_ENABLED` / Desktop
    /// `AndroidBundleHandshake.SRTP_DIR_KEYS_ENABLED`.
    public static let srtpDirKeysEnabled = true

    /// W574x — whether the PEER advertised `srtpDirKeyV1` in its last received
    /// OFFER/ACCEPT bundle (set in `onAndroidBundleReceived`, before
    /// `onRelaySessionReady` fires).
    private var peerAdvertisedSrtpDirKey: Bool = false

    /// W574x — directional sealer keys are used only when BOTH peers advertise
    /// support. Read by AppState at relay-sealer install time.
    public var negotiatedSrtpDirKey: Bool {
        Self.srtpDirKeysEnabled && peerAdvertisedSrtpDirKey
    }

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
    /// Same idea as `lastSentAcceptWire` but for the legacy QUAD binary
    /// `case .offer` responder path (2026-07-11: that path had no
    /// double-OFFER guard at all — see the fix at its call site).
    private var lastSentLegacyAcceptWire: Data?
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
    /// Only fires on the JSON (AndroidHandshakeBundle) paths — not the QUAD or
    /// earbud paths, where v4 capability is not negotiated. The integration SKIPS
    /// the fire (passes nothing) when any real input is missing (no signed
    /// handshake), leaving the v3 fallback rather than a divergent placeholder
    /// session. No-op when nil.
    public var onV4BootstrapReady: ((String, Data, Data, Data, Data) -> Void)?

    /// `vkey-v1` — fired alongside ``onPqcSessionKeyEstablished`` at every
    /// handshake-completion site. Carries the SAME 32-byte post-PSK-mix
    /// session key, which is the **IKM** for the dedicated earbud-video
    /// key K_video.
    ///
    /// IMPORTANT — why this carries the session key and NOT K_video:
    /// K_video = `HKDF(sessionKey, salt, info)` where `info` binds the
    /// negotiated capability tags (`transcriptHash`). The integration
    /// completes the PQC handshake BEFORE the WebRTC capability
    /// negotiation result (`peerNegotiated()`) is necessarily available,
    /// and it never holds the agreed-tag set. So the actual K_video
    /// derivation happens in
    /// `QAudionWebRtcCallController.ensureVideoSealerInternal()`, which is
    /// the single component that holds BOTH the session key (via
    /// `pqcSessionKey`) AND the negotiated tags (via `peerNegotiated()`).
    /// This callback exists so the app layer can mirror the
    /// `onPqcSessionKeyEstablished → broker → callPqcSessionKey` plumbing
    /// for any future video-key-specific surface (e.g. the dual-trust UI
    /// indicator) without re-plumbing the session key through a second
    /// path.
    ///
    /// Use ``deriveVideoKey(sessionKey:agreedTags:psk:)`` to compute the
    /// final K_video from this IKM once the negotiated tags are known.
    /// Fires at most once per call.
    public var onVideoKeyEstablished: ((Data) -> Void)?

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
    public var onRelaySessionReady: ((Data, String) -> Void)?

    /// W-KCMAC (multi-PSK-mixing SYNTHESIS.md ship step 5) — everything AppState
    /// needs to run the `KCMAC:` piggy-back exchange, fired at the SAME two
    /// handshake-completion sites as ``onPqcSessionKeyEstablished``
    /// (responder's OFFER-accept and initiator's ACCEPT-decapsulate), AFTER it.
    /// PURE OBSERVATION — `N` stays ≤1, nothing here reads/writes `PskMix` mixing
    /// state, and AppState must never let a wrong/absent/unattempted `kc_mac`
    /// gate the call (W-NOBRICK); the verdict is telemetry/`AssuranceState` input
    /// only. `kcKey`/`transcript` are `nil` when the reconstructed offer/accept v2
    /// transcripts or either identity key aren't available (unsigned/legacy peer,
    /// or this side hasn't wired transcript-v2 signing) — AppState must treat that
    /// as "kc_mac not attempted" (status `.absent`), never attempt to derive a MAC
    /// from empty/placeholder bytes.
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

        public init(
            peerId: String, callId: String, isInitiator: Bool, sessionKey: Data,
            kcKey: Data?, transcript: Data?, n: Int, peerSupportsMix: Bool,
            sigOk: Bool, peerAdvertisedRoles: [Int], selectedFp: String? = nil
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
        }
    }
    public var onKcMacReady: ((KcMacReadyEvent) -> Void)?

    /// Phase B — earbud GATT proxy for fp_adv operations (c8).
    /// Set by AppState from `earbudGattProxy` before a call starts.
    /// Nil when no earbud is bonded/connected → keyClass falls back to 0.
    public var earbudPairingGattProxy: (any EarbudPairingGattProxy)?

    /// Phase B — pending FPSET continuation per callId. One per in-flight
    /// call; resolved by `handleInboundFpSet` when the peer's FPSET arrives.
    /// Keyed by lowercased callId (same normalisation as sessionInitializedByCall).
    private var fpSetContinuationByCall:
        [String: CheckedContinuation<Data, Never>] = [:]

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

    // MARK: - Phase-1 live-call seam (D4 abort / D6 v2-v3 KDF selection)

    /// Result type for `phase1DeriveSessionKey`.
    public enum Phase1Result {
        case success(Data)
        case abort(String)
    }

    /// Whether this client advertises KMS-rotation-v2 schema:3 KDF support.
    /// Wired `true` by AppState when the local version supports schema:3.
    /// Left `false` (default) in tests that exercise the legacy schema:2 path.
    public var localSupportsSessionKdfV3: Bool = false

    /// D4 abort gate resolver for hw_only contacts.
    /// Signature: `(peerId: String) -> (isHwOnly: Bool, expectedFp: String?)`.
    /// When `isHwOnly == true` and the negotiated `selectedFp` does NOT match
    /// `expectedFp`, `phase1DeriveSessionKey` returns `.abort("hw_only_required")`.
    /// `nil` (default) → non-hw_only path, no abort.
    public var resolveHwOnlyContact: ((String) -> (Bool, String?))?

    /// D4 + D6 live-call session-key derivation seam.
    ///
    /// 1. (D4) If `resolveHwOnlyContact` is set and returns `(true, expectedFp)` but
    ///    `selectedFp != expectedFp` → `.abort("hw_only_required")`.
    /// 2. (D6) If `localSupportsSessionKdfV3 && peerSupportsV3` → schema:3 key.
    /// 3. Otherwise → schema:2 key (legacy path, mixed fleet / old peer).
    ///
    /// All parameters mirror the Android `HybridPqcKeyExchange.phase1DeriveSessionKey` signature.
    public func phase1DeriveSessionKey(
        peerId: String,
        pqcSs: Data,
        x25519Ss: Data,
        pqcCiphertext: Data,
        selectedFp: String?,
        selectedPsk: Data?,
        peerSupportsV3: Bool
    ) -> Phase1Result {
        // D4 abort gate — hw_only contact with wrong/missing fp.
        if let resolve = resolveHwOnlyContact {
            let (isHwOnly, expectedFp) = resolve(peerId)
            if isHwOnly, selectedFp != expectedFp {
                return .abort("hw_only_required")
            }
        }
        // D6 KDF selection.
        let key: Data
        if localSupportsSessionKdfV3 && peerSupportsV3 {
            key = QAudionCallIntegration.deriveHybridSessionKeyV3(
                pqcSs: pqcSs, x25519Ss: x25519Ss, pqcCiphertext: pqcCiphertext,
                psk: selectedPsk)
        } else {
            key = QAudionCallIntegration.deriveHybridSessionKey(
                pqcSs: pqcSs, x25519Ss: x25519Ss, pqcCiphertext: pqcCiphertext,
                psk: selectedPsk)
        }
        return .success(key)
    }

    // MARK: - Phase-10b handshake signing (additive, all nil/off by default)
    //
    // HANDSHAKE-SIGNING-SPEC.md §2–§6. EVERY property below is nil/false by
    // default. When `signTranscript` / `localSignerIdentityKey` are nil the
    // OFFER/ACCEPT are sent UNSIGNED (the two optional bundle fields stay nil →
    // JSONEncoder omits them → wire bytes byte-identical to the legacy path).
    // When the verify closures are nil an inbound bundle is treated as a legacy
    // unsigned peer (proceed; no abort). So an integration constructed without
    // wiring these (tests, legacy call paths) behaves EXACTLY as before.
    //
    // CLAUDE.md §16: these are primitives + closures ONLY — never an AppState /
    // SovereignIdentity engine type as a parameter, so the new wiring cannot
    // trip the Swift-6 Sendable-inference silent build break.

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
    public var onHandshakeIdentityUnverified: ((String) -> Void)?

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

    /// Is the channel to this peer trust ≥ VERIFIED_CHANNEL (spec §4 — verified
    /// contacts MUST always present a valid signature)? Wired from the existing
    /// SAS-verification state.
    public var isPeerVerifiedChannel: ((String) -> Bool)?

    /// Global `require_signed_handshake` enforcement flag (spec §4). DEFAULT ON
    /// (Gate #16 enabled 2026-06-18) — no legacy unsigned peers in the fleet.
    public var requireSignedHandshakeFlag: Bool = true

    /// Stash of the OFFER transcript WE SENT, keyed by lowercased callId, so the
    /// initiator can recompute `offer_binding = SHA-256(offerTranscript)` when it
    /// later verifies the matching ACCEPT (spec §3 / step (d)). Only populated
    /// when we actually signed the OFFER (signing wired). Cleared with the rest
    /// of the per-call state in `onCallEnded`.
    private var sentOfferTranscriptByCall: [String: Data] = [:]

    /// W-TRANSCRIPTV2 (multi-PSK-mixing SYNTHESIS.md ship step 4) — v2 sibling of
    /// `sentOfferTranscriptByCall`: the OFFER's v2 transcript WE SENT, keyed the same way, so
    /// the initiator can recompute the v2 `offer_binding` when it later verifies the
    /// matching ACCEPT's `sigV2`. Populated only when we actually signed the OFFER AND the
    /// v2 transcript was buildable (see `HandshakeTranscript.advEnc`'s doc for when it isn't).
    /// Cleared with the rest of the per-call state in `onCallEnded`.
    private var sentOfferTranscriptV2ByCall: [String: Data] = [:]

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

    public func onCallSetupStarted(sendOpaqueMessage: @escaping (Data) async throws -> Void) throws {
        lock.lock()
        guard state == .idle else { lock.unlock(); throw IntegrationError.invalidState(state) }
        sendOpaque = sendOpaqueMessage
        // Caller path — flag so pre-negotiation events are interpreted correctly.
        isCaller = true
        lock.unlock()

        try engine.initialize()
        let keyPair = try consumeOrGenerateKeyPair()
        lock.lock()
        localKeyPair = keyPair
        state = .capabilitySent
        lock.unlock()
        onStateChanged?(.capabilitySent)

        // Use raw public key (no ASN.1) for cross-platform compat with Android
        let rawPublicKey = try PqcKeyExchange.extractRawPublicKey(keyPair.publicKey)
        let offer = QAudionCapabilityExchange.createOffer(publicKey: rawPublicKey, pskFingerprints: [])
        Task { try? await sendOpaqueMessage(offer) }

        // M-15 — cancellable 15s capability-exchange fallback. The
        // previous fire-and-forget asyncAfter kept firing after the
        // call ended (or on the wrong subsequent call); store the
        // work item so onCallEnded() can cancel it.
        capabilityTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.state == .capabilitySent {
                self.state = .fallback
                self.lock.unlock()
                self.onStateChanged?(.fallback)
            } else {
                self.lock.unlock()
            }
        }
        capabilityTimeoutWorkItem = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: work)
    }

    /// Originator entry point that emits the Android JSON HandshakeBundle
    /// OFFER (literal `"<callId>|<JSON>"` string) AND the legacy QUAD
    /// binary OFFER. Use this instead of `onCallSetupStarted` when the
    /// outgoing call must reach an Android peer — the Android dispatch
    /// layer rejects QUAD-only OFFERs as "malformed opaque envelope"
    /// because no `|` separator. WIRE_SPEC.md §3.1.
    ///
    /// Both formats are sent because:
    /// - Android peers parse the JSON envelope (their native format).
    /// - Desktop peers parse EITHER (the `handleAndroidBundle` path was
    ///   added in an earlier commit).
    /// - iOS peers parse the QUAD via `onCapabilityMessageReceived` for
    ///   backwards compat with older iOS builds that don't yet have the
    ///   JSON responder; the JSON envelope is dropped silently in their
    ///   dispatch (no `|` after base64 decode → handler returns).
    ///
    /// Per OpenRouter glm-5.1 review 2026-05-06:
    /// - Send sequentially so a JSON failure surfaces (Android-critical).
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
        let offerBundle = AndroidHandshakeBundle(
            kind: .offer,
            callId: callId,
            pqcPublicKey: pqcRawPub.base64EncodedString(),
            x25519PublicKey: x25519RawPub.base64EncodedString(),
            capabilities: AndroidHandshakeBundle.Capabilities(
                ratchetV3: true,
                // ROOT-CAUSE FIX (2026-06-23, cross-platform sig_invalid): advertise
                // sframeV1 + vkeyV1 EXPLICITLY. iOS supports both (CallCapabilities
                // .local = [sframe-v1, ratchet-v3, vkey-v1, …]) and the signed CAPS
                // triplet is (ratchetV3, sframeV1, vkeyV1). Omitting them made iOS
                // sign (true,false,false) [capsFromBundle: absent → false], but
                // Android decodes absent caps to its data-class DEFAULTS
                // (sframeV1=true, vkeyV1=true) → it reconstructs (true,true,true) →
                // the Ed25519 signature fails over the diverging transcript
                // (hs-sig OFFER abort: sig_invalid) → no PQC session → call dropped.
                // Sending them true makes the signed CAPS == the reconstructed CAPS.
                sframeV1: true,
                vkeyV1: true,
                // Phase 18 — advertise v4 ONLY when this build can actually do v4
                // (flag ON + native core linked). nil when not → JSONEncoder omits
                // the key → byte-identical pre-v4 wire, and Android negotiates v4
                // off for us (its `safePeer.ratchetV4` default). NOT in the signed
                // CAPS triplet, so the OFFER signature is unaffected.
                ratchetV4: Self.advertisesRatchetV4 ? true : nil,
                srtpDirKeyV1: Self.srtpDirKeysEnabled ? true : nil,
                // W-NFCVISIBLE go-live — Pavel: AssuranceState/kc_mac has been fully
                // wired since W-NFCBADGE but stayed permanently inert because nobody
                // ever advertised this bit (see this field's own doc a few lines
                // above: "nobody sets this true yet; that's a later ship step").
                // N stays capped at <=1 (nothing in this codebase drives it higher
                // yet), so flipping this is additive/safe — an unflipped peer simply
                // omits the bit and both sides keep computing S0 exactly as before.
                // Mirrored in Android's SELF_CAPABILITIES in the same commit series.
                pskMixV1: true
            ),
            pskFingerprints: advertisedPskFingerprints,
            pskRoles: advertisedPskRoles
        )

        // W-KCMAC (ship step 5) — stash the advert list itself (not just the
        // transcript bytes) so the matching ACCEPT's `onKcMacReady` can rebuild
        // `initAdvert` in the EXACT order we sent it. Unconditional (not gated on
        // `signingEnabled`): harmless to stash even when the KCMAC gate later finds
        // no offer_binding to pair it with (empty ⇒ no KCMAC attempted, see
        // `onKcMacReady`'s doc).
        // W-KCMACROLES — the roles ride along in the SAME stash operation: they are
        // part of the MAC'd `advEnc` pairs, so losing them here is exactly as fatal
        // as losing the fingerprints (see `sentOfferPskRolesByCall`'s own doc).
        lock.withLock {
            sentOfferPskFingerprintsByCall[callId.lowercased()] = advertisedPskFingerprints
            // nil (v3) stashes as empty — `toKcAdverts` reads a missing role as 0,
            // which is exactly what `advEnc` bound for an absent wire array.
            sentOfferPskRolesByCall[callId.lowercased()] = advertisedPskRoles ?? []
        }

        // Phase-10b (a) — SIGN the OFFER over the §3 transcript before serialize.
        // No-op when signing is not wired → `bundleToSend == offerBundle` and the
        // two sig fields stay nil → byte-identical legacy wire (additive). The
        // transcript is built from OUR OWN bundle fields + SELF caps and the
        // placeholder epoch (see the EPOCH NOTE on the signing helpers). We stash
        // it keyed by the lowercased callId so that, on the matching ACCEPT, the
        // initiator recomputes `offer_binding = SHA-256(offerTranscript)` to bind
        // the two halves (spec §3, step (d)). Stash only when we actually signed.
        var bundleToSend = offerBundle
        if signingEnabled, let idKey = localSignerIdentityKey,
           let offerT = Self.offerTranscript(from: offerBundle, callId: callId, signerKeyRaw: idKey) {
            // W-TRANSCRIPTV2 — best-effort v2 sibling transcript (nil on a pathological
            // >255-fp OFFER — see HandshakeTranscript.advEnc's doc); signedCopy signs it
            // alongside (never instead of) the v1 signature above.
            let offerTV2 = Self.offerTranscriptV2(from: offerBundle, callId: callId, signerKeyRaw: idKey)
            bundleToSend = signedCopy(of: offerBundle, transcript: offerT, transcriptV2: offerTV2)
            // Only stash when the sig actually attached (signedCopy returns the
            // input unchanged on signer failure → don't claim a signed OFFER).
            if bundleToSend.signature != nil {
                lock.withLock {
                    sentOfferTranscriptByCall[callId.lowercased()] = offerT
                    // W-TRANSCRIPTV2 — stash the v2 sibling too (nil-safe: absent when the
                    // v2 transcript build failed) so the matching ACCEPT's verify can bind
                    // to SHA-256(offerTV2) as the v2 offer_binding.
                    if let offerTV2 { sentOfferTranscriptV2ByCall[callId.lowercased()] = offerTV2 }
                }
            }
        }
        let jsonWire = AndroidHandshakeEnvelope.serialize(callId: callId, bundle: bundleToSend)

        // 1. Ship JSON OFFER FIRST so any Android-peer dispatch race
        //    sees the parseable envelope before the QUAD bytes
        //    (which their dispatcher rejects). Failure here propagates
        //    back to the caller — the JSON path is the
        //    Android-interop-critical one.
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
        // W529: arm the 5 s idempotent retry loop. Cancels on
        // session-key install (success) or call end (handshake.reset).
        armOfferRetryTimer()

        // 2. Legacy QUAD binary OFFER — REMOVED (2026-07-12, dual-path
        //    key-derivation race). Sending both a JSON OFFER and a QUAD
        //    OFFER for the same call let the responder answer either one
        //    (whichever `sessionInitializedByCall` saw first), and the
        //    caller independently race its own JSON vs QUAD ACCEPT
        //    processing. The two paths derive the session key
        //    DIFFERENTLY — JSON/`deriveHybridSessionKey`(V4) mixes
        //    PQC+X25519+ciphertext-binding via HKDF; QUAD uses the raw
        //    `pqc.encapsulate().sharedSecret` with no mixing at all — so
        //    if one side's OFFER-race winner differs from the other
        //    side's ACCEPT-race winner, the two ends install different
        //    keyfp and every AEAD frame (audio) and SFrame (video) fails
        //    to open for the whole call. Root-caused on call 5f56a6ab
        //    (2026-07-12): a double `startCall`/`call_incoming` (UI
        //    double-fire) triggered exactly this cross-path split —
        //    iPad installed keyfp=da41a653 (JSON/hybrid), iPhone
        //    installed keyfp=f8d5aadc (QUAD/raw) for the SAME call_id.
        //    No pre-v4 iOS peers remain in the fleet (confirmed), so the
        //    QUAD OFFER send is dead weight that only creates this race
        //    — removed rather than re-patching the guard timing.
        //    `.offer`/`.accept` QUAD receive handlers are left in place
        //    (harmless, unreachable without a QUAD OFFER on the wire).

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

    public func onCapabilityMessageReceived(data: Data, fromSenderId: String = "", sendOpaqueMessage: @escaping (Data) async throws -> Void) throws {
        guard let message = QAudionCapabilityExchange.parse(data) else { return }

        switch message {
        case .offer(let remotePublicKey, _, _):
            // Responder path — flag and grab stashed pre-negotiation IDs.
            lock.lock()
            isCaller = false
            let stashedCallId = pendingResponderCallId
            let stashedCallerId = pendingResponderCallerId
            lock.unlock()

            // Pre-negotiation step 1: ack receipt of OFFER immediately so the
            // caller can flip its UI to "Connecting" before our heavy PQC work
            // runs. See bcrypto-server pre-negotiation flow.
            if let cid = stashedCallId, let from = stashedCallerId {
                sendCallProcessing?(cid, from)
            }

            // Double-OFFER guard (2026-07-11 — same sessionInitializedByCall
            // set the Android JSON-OFFER responder path already uses, see
            // ~line 1260). The caller ships BOTH a JSON OFFER and this
            // legacy QUAD OFFER for the same call (sendOfferAsCaller: JSON
            // first, QUAD second, for older-iOS-peer compat) — without this
            // guard the QUAD copy unconditionally re-runs `pqc.encapsulate()`,
            // which is RANDOMIZED, producing a second, different session key
            // and re-firing `onRelaySessionReady` after the JSON copy already
            // installed one. CallService's relay-sealer install has no way to
            // tell this apart from a legitimate re-key, so it silently swaps
            // to the new key with a fresh AES-GCM counter while the peer keeps
            // decrypting under the old one — permanent AEAD-failure storm for
            // the rest of the call. Whichever OFFER format lands first wins;
            // the second is replayed from the cached ACCEPT instead of
            // re-derived.
            let normalizedOfferCid = (stashedCallId ?? "").lowercased()
            let offerAlreadyInit = lock.withLock {
                let r = !normalizedOfferCid.isEmpty && sessionInitializedByCall.contains(normalizedOfferCid)
                if !r, !normalizedOfferCid.isEmpty {
                    sessionInitializedByCall.insert(normalizedOfferCid)
                }
                return r
            }
            if offerAlreadyInit {
                if let cached = lock.withLock({ lastSentLegacyAcceptWire }) {
                    print("[QAudionCallIntegration] QUAD OFFER duplicate for callId=\(normalizedOfferCid.prefix(8))… — replaying cached ACCEPT")
                    Task { try? await sendOpaqueMessage(cached) }
                } else {
                    print("[QAudionCallIntegration] QUAD OFFER duplicate for callId=\(normalizedOfferCid.prefix(8))… — session already initialised, skipping")
                }
                return
            }

            // Note: keyPair is generated implicitly inside encapsulate via
            // the embedded PQC stack — we don't need a local copy. (Was an
            // unused init from a refactor leftover.)
            let result = try pqc.encapsulate(remotePublicKey: remotePublicKey)
            try engine.initialize()
            try engine.initSession(sharedSecret: result.sharedSecret)
            onRelaySessionReady?(result.sharedSecret, stashedCallId ?? "")
            let accept = QAudionCapabilityExchange.createAccept(ciphertext: result.ciphertext, pskFingerprint: nil)
            lock.withLock { lastSentLegacyAcceptWire = accept }
            Task { try? await sendOpaqueMessage(accept) }
            lock.lock(); state = .active; lock.unlock()
            // W529: handshake reached active — kill the retry loop.
            offerRetryTask?.cancel()
            offerRetryTask = nil
            onStateChanged?(.active)
            // W389: surface the real ML-KEM-1024 session key so the app
            // layer can swap the W369 transitional PSK seed for the
            // PQC-derived secret in `AppState.callPqcSessionKey`. Fired
            // AFTER engine.initSession so the audio pipeline is already
            // active under the same key — observers can rely on it.
            onPqcSessionKeyEstablished?(result.sharedSecret)
            // vkey-v1: same 32 bytes are the IKM for K_video. Fired so the
            // app/controller layer can derive K_video once the negotiated
            // tags are known (see onVideoKeyEstablished docs).
            onVideoKeyEstablished?(result.sharedSecret)

            // Pre-negotiation step 2: PQC OFFER fully deserialised — tell the
            // caller we are ringing locally so its UI flips to "Ringing".
            if let cid = stashedCallId, let from = stashedCallerId {
                sendCallReady?(cid, from)
            }

        case .accept(let ciphertext, _):
            guard let kp = localKeyPair else { return }
            // Double-ACCEPT guard (2026-07-11 — same sessionInitializedByCall
            // set the Android JSON-ACCEPT originator path already uses, see
            // ~line 1563). Not a key-confusion bug on its own — `pqc.decapsulate`
            // is deterministic, so a duplicate ACCEPT yields the identical
            // sharedSecret and CallService's keyFp-equality check would no-op
            // the relay-sealer reinstall anyway — but without this guard
            // `engine.initSession()` and the onPqcSessionKeyEstablished /
            // onVideoKeyEstablished callbacks still redundantly re-fire and
            // tear down + rebuild the engine's own session state for no
            // reason. Added for symmetry with every other handshake path in
            // this file, all of which already guard on this set.
            let normalizedAcceptCid = (lock.withLock { pendingOutgoingCallId } ?? "").lowercased()
            let acceptAlreadyInit = lock.withLock {
                let r = !normalizedAcceptCid.isEmpty && sessionInitializedByCall.contains(normalizedAcceptCid)
                if !r, !normalizedAcceptCid.isEmpty {
                    sessionInitializedByCall.insert(normalizedAcceptCid)
                }
                return r
            }
            if acceptAlreadyInit {
                print("[QAudionCallIntegration] QUAD ACCEPT duplicate for callId=\(normalizedAcceptCid.prefix(8))… — session already initialised, skipping")
                return
            }
            let sharedSecret = try pqc.decapsulate(ciphertext: ciphertext, privateKey: kp.privateKey)
            try engine.initSession(sharedSecret: sharedSecret)
            onRelaySessionReady?(sharedSecret, (lock.withLock { pendingOutgoingCallId }) ?? "")
            lock.lock(); state = .active; lock.unlock()
            // W529: handshake reached active — kill the retry loop.
            offerRetryTask?.cancel()
            offerRetryTask = nil
            onStateChanged?(.active)
            // W389: caller side — same surface as the responder branch.
            // After this fires, both ends hold the same 32 bytes for
            // SAS derivation.
            onPqcSessionKeyEstablished?(sharedSecret)
            // vkey-v1: caller side — same IKM surface as the responder.
            onVideoKeyEstablished?(sharedSecret)

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
            // TODO(desktop-interop): route callHangup to hangup handler
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
    ///        `sendOpaqueMessage` closure used by the QUAD path.
    ///     5. Fire `onPqcSessionKeyEstablished` with the combined
    ///        shared secret so the broker swaps in the real session
    ///        key (§5.4 same as the QUAD branch).
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

        switch bundle.kind {
        case .offer:
            // Pre-negotiation parity with the iOS-native (QUAD) responder
            // path (`onCapabilityMessageReceived` .offer): emit
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

            // Phase-10b (b) — VERIFY the incoming OFFER BEFORE crypto work
            // (`pqc.encapsulate`) or ACCEPT emission (spec §4). When verification
            // is not wired we skip entirely (legacy behaviour). The peer is
            // `callerId`. D11 + W-NOBRICK: the identity verdict NEVER hard-drops the
            // call (it used to THROW here; that bricked calls on a stale pin). `.abort`
            // (e.g. identity_key_mismatch — bundle key ∉ the server-published set)
            // raises a non-blocking in-call alert and PROCEEDS WITHOUT pinning the
            // observed key — SAS is the terminal anti-MITM gate. `.authenticated`
            // (key == pinned/server) and `.authenticatedRepinFromPublished` (a
            // set-PROVEN rotation) commit the per-(peer,device) pin + v4 flag and
            // yield the offer_binding the ACCEPT must carry (spec §3).
            // `.proceedUnsignedWarn` logs and continues with an EMPTY binding
            // (legacy/unsigned-peer migration path).
            var verifiedOfferBinding = Data()  // empty == "no signed offer to bind"
            // W-TRANSCRIPTV2 — v2 sibling of `verifiedOfferBinding` (SHA-256 of the OFFER's
            // v2 transcript), computed alongside it in every branch below; stays empty when
            // the v2 transcript wasn't available (pathological psk-list, or an unsigned/
            // warn-legacy peer). Bound into the ACCEPT's `sigV2` further below.
            var verifiedOfferBindingV2 = Data()
            // W-KCMAC — `AssuranceState.decide`'s `sigOk` input: true only for the
            // two verdicts that actually confirm the Ed25519 transcript signature
            // (`.authenticated`/`.authenticatedRepinFromPublished`) — `.abort` and
            // `.proceedUnsignedWarn` leave it false (forged / absent signature).
            var offerSigOk = false
            // Phase 18 — v4 bootstrap (BUG 2 fix): we mirror Android's `v4Ready`
            // (PqcHandshake.kt:819-826), which does NOT require an "authenticated
            // verdict". The single real input the bootstrap gate needs is a NON-EMPTY
            // `verifiedOfferBinding` (== Android's `handshakeTranscriptHash != null`).
            // That binding is rebuilt on EVERY proceeding verdict below — including the
            // W-NOBRICK abort/warn paths — so a freshly-reinstalled peer (new identity →
            // warn/repin verdict) STILL bootstraps v4, matching the peer that does the
            // same. The SAS is the terminal anti-MITM gate. (We previously gated on a
            // now-removed `v4OfferAuthenticated` flag, which made iOS stricter than
            // Android → asymmetry → no iOS v4 session → "messaggio non leggibile".)
            if verificationEnabled {
                let verdict = evaluateVerdict(
                    bundle: bundle, peerId: callerId, peerDeviceId: callerDeviceId,
                    transcriptFor: { key in Self.offerTranscript(from: bundle, callId: callId, signerKeyRaw: key) },
                    transcriptForV2: { key in Self.offerTranscriptV2(from: bundle, callId: callId, signerKeyRaw: key) }
                )
                switch verdict {
                case .abort(let code):
                    // W-NOBRICK (user directive): a handshake-sig verdict must NEVER
                    // hard-drop the call — "segnala un cambiamento, non droppare".
                    // The SAS (6 words from the session key) is the REAL anti-MITM
                    // gate; the Ed25519 identity verdict is advisory. (D11) We DO NOT
                    // blind-re-pin the bundle's own (untrusted) key any more — an
                    // `identity_key_mismatch` here means the bundle key is ∉ the
                    // server-published set (an UNAUTHENTICATED change). We raise a
                    // non-blocking in-call alert and PROCEED with media WITHOUT
                    // pinning the observed key. (A set-PROVEN rotation never reaches
                    // this case — it returns `.authenticatedRepinFromPublished`.)
                    print("[QAudionCallIntegration] ⚠️ OFFER verify code=\(code) peer=\(callerId.prefix(8))… callId=\(callId.prefix(8))… — NOT dropping; proceeding, VERIFY THE SAS")
                    if code == "identity_key_mismatch" {
                        onUnauthenticatedIdentityChange?(callerId)
                    }
                    // XC-1 — a present-but-INVALID signature is a forgery against
                    // the key we verify under (not a key change). Revoke the peer's
                    // SAS verification so the in-call SAS becomes a required
                    // re-confirmation. Still PROCEED (W-NOBRICK / signal-not-kill).
                    if code == "sig_invalid" {
                        onInvalidHandshakeSignature?(callerId)
                    }
                    // P0-3 — hold MEDIA (not the handshake) behind a blocking SAS
                    // reconfirmation. Fired for every abort code: the crypto session
                    // still completes below so the SAS words exist, but AppState
                    // won't install the relay sealers / v4 bootstrap until the user
                    // confirms.
                    onHandshakeIdentityUnverified?(callId)
                    // Protocol continuity only: build the offer_binding under the
                    // bundle's carried key so the ACCEPT we emit stays internally
                    // consistent. This pins NOTHING and trusts NOTHING — the verdict
                    // is already advisory and the SAS is terminal.
                    if let sikB64 = bundle.signerIdentityKey,
                       let bundleKey = Data(base64Encoded: sikB64), bundleKey.count == 32 {
                        if let offerT = Self.offerTranscript(from: bundle, callId: callId, signerKeyRaw: bundleKey) {
                            verifiedOfferBinding = HandshakeTranscript.offerBinding(offerT)
                        }
                        // W-TRANSCRIPTV2 — v2 sibling, same continuity-only rationale.
                        if let offerTV2 = Self.offerTranscriptV2(from: bundle, callId: callId, signerKeyRaw: bundleKey) {
                            verifiedOfferBindingV2 = HandshakeTranscript.offerBinding(offerTV2)
                        }
                    }
                case .authenticated(let tofuPinKey, let v4Capable, let srtpDirKeyV1Capable):
                    applyAuthenticatedSideEffects(peerId: callerId, deviceId: callerDeviceId, tofuPinKey: tofuPinKey, v4Capable: v4Capable, srtpDirKeyV1Capable: srtpDirKeyV1Capable)
                    offerSigOk = true
                    // The signed OFFER's binding the ACCEPT will carry. Rebuilt
                    // under the trusted key (= the bundle's signerIdentityKey,
                    // which the verdict already confirmed == pinned/server key).
                    if let sikB64 = bundle.signerIdentityKey, let trustedKey = Data(base64Encoded: sikB64) {
                        if let offerT = Self.offerTranscript(from: bundle, callId: callId, signerKeyRaw: trustedKey) {
                            verifiedOfferBinding = HandshakeTranscript.offerBinding(offerT)
                        }
                        // W-TRANSCRIPTV2 — v2 sibling, same trusted key.
                        if let offerTV2 = Self.offerTranscriptV2(from: bundle, callId: callId, signerKeyRaw: trustedKey) {
                            verifiedOfferBindingV2 = HandshakeTranscript.offerBinding(offerTV2)
                        }
                    }
                case .authenticatedRepinFromPublished(let deviceKey, let v4Capable, let srtpDirKeyV1Capable):
                    // D11 trust-on-publish: bundle key ≠ pin but ∈ the server's
                    // published set AND its own signature verified. Silent additive
                    // re-pin per-(peer, device); NO banner. The binding is rebuilt
                    // under the SET-PROVEN device key (the key the policy verified).
                    print("[QAudionCallIntegration] OFFER set-proven rotation peer=\(callerId.prefix(8))… dev=\((callerDeviceId ?? "—").prefix(8))… — silent re-pin, proceeding")
                    applyAuthenticatedSideEffects(peerId: callerId, deviceId: callerDeviceId, tofuPinKey: deviceKey, v4Capable: v4Capable, srtpDirKeyV1Capable: srtpDirKeyV1Capable)
                    offerSigOk = true
                    if let offerT = Self.offerTranscript(from: bundle, callId: callId, signerKeyRaw: deviceKey) {
                        verifiedOfferBinding = HandshakeTranscript.offerBinding(offerT)
                    }
                    // W-TRANSCRIPTV2 — v2 sibling, same set-proven device key.
                    if let offerTV2 = Self.offerTranscriptV2(from: bundle, callId: callId, signerKeyRaw: deviceKey) {
                        verifiedOfferBindingV2 = HandshakeTranscript.offerBinding(offerTV2)
                    }
                case .proceedUnsignedWarn(let reason):
                    print("[QAudionCallIntegration] OFFER unsigned-legacy peer=\(callerId.prefix(8))… callId=\(callId.prefix(8))… — proceeding: \(reason)")
                }
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

            // 5. Phase B — fp_adv exchange for hw_only (schema:4 V4 KDF).
            // This block runs BEFORE building the ACCEPT so the FPSET wire
            // message and the ACCEPT can race in parallel on the network.
            // Responder role: OUR earbud produces fp_adv (fpSetResp),
            // the OFFER side's fp_adv is fpSetInit (arrives via FPSET piggy-back).
            let keyClass: UInt8
            let fpSetInit: Data   // OFFER side fp_adv
            let fpSetResp: Data   // ACCEPT side fp_adv (ours)
            let pqcCtForBind = pqcResult.ciphertext
            let gatt = earbudPairingGattProxy
            let isHwOnly = (selectedPsk != nil)
            if let gatt = gatt, isHwOnly {
                // ct_bind = HMAC-SHA256("q-audion-ct-bind-v1", pqcCiphertext)
                let ctBind = Data(
                    HMAC<SHA256>.authenticationCode(
                        for: pqcCtForBind,
                        using: SymmetricKey(data: HkdfLabels.hybridCtBindV1)
                    )
                )
                // Write ct_bind to c8; earbud derives fp_adv in-SE.
                // Best-effort: GATT failure → fall back to schema:2 (keyClass 0).
                var ownFpAdv: Data?
                do {
                    try await gatt.writeFpAdvSeed(ctBind)
                    let (readFpAdv, _) = try await gatt.readFpAdv()
                    ownFpAdv = readFpAdv
                } catch {
                    print("[QAudionCallIntegration] FPSET GATT read failed (responder) callId=\(callId.prefix(8))…: \(error) — falling back to schema:2")
                }
                if let localFp = ownFpAdv {
                    // Send our fp_adv to the initiator BEFORE awaiting theirs
                    // (both sides send in parallel to minimise latency).
                    sendFpSet(callId: callId, fpAdv: localFp,
                              sendOpaqueRaw: sendOpaqueRaw)
                    fpSetResp = localFp
                    // Now wait up to 5 s for the initiator's FPSET.
                    fpSetInit = await awaitFpSet(callId: callId, timeoutSec: 5.0)
                    keyClass = 2  // hw_only
                } else {
                    // GATT failed → zeros → keyClass 0 → schema:2 derivation
                    fpSetResp = Data(repeating: 0, count: 32)
                    fpSetInit = Data(repeating: 0, count: 32)
                    keyClass  = 0
                }
            } else {
                // No earbud or no PSK → schema:2 path.
                fpSetInit = Data(repeating: 0, count: 32)
                fpSetResp = Data(repeating: 0, count: 32)
                keyClass  = 0
            }

            // Derive session key — V4 when keyClass != 0, schema:2 otherwise.
            let combined: Data
            if keyClass != 0 {
                let nd = Self.negDigest(fpSetInit: fpSetInit, fpSetResp: fpSetResp)
                let selFpRaw: Data
                if let psk = selectedPsk, !psk.isEmpty {
                    selFpRaw = Data(SHA256.hash(data: psk))
                } else {
                    selFpRaw = Data(repeating: 0, count: 32)
                }
                combined = Self.deriveHybridSessionKeyV4(
                    pqcSs: pqcResult.sharedSecret,
                    x25519Ss: x25519Result.sharedSecret,
                    pqcCiphertext: pqcCtForBind,
                    psk: selectedPsk,
                    selectedFp: selFpRaw,
                    keyClass: keyClass,
                    negDigest: nd
                )
                print("[QAudionCallIntegration] OFFER V4 KDF keyClass=\(keyClass) callId=\(callId.prefix(8))…")
            } else {
                // Corrected schema:2 derivation — byte-identical to Android /
                // Desktop / firmware. The ML-KEM ciphertext is bound via HKDF info.
                combined = Self.deriveHybridSessionKey(
                    pqcSs: pqcResult.sharedSecret,
                    x25519Ss: x25519Result.sharedSecret,
                    pqcCiphertext: pqcCtForBind,
                    psk: selectedPsk
                )
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
                capabilities: AndroidHandshakeBundle.Capabilities(
                    ratchetV3: true,
                    // ROOT-CAUSE FIX (2026-06-23): advertise sframeV1 + vkeyV1
                    // explicitly on the ACCEPT too — same reason as the OFFER above.
                    // Otherwise iOS signs CAPS (true,false,false) while the peer
                    // reconstructs (true,true,true) from its true-defaults →
                    // hs-sig ACCEPT abort: sig_invalid → handshake fails.
                    sframeV1: true,
                    vkeyV1: true,
                    // Phase 18 — advertise v4 on the ACCEPT too (same self && peer
                    // negotiation): nil when this build can't do v4 → wire unchanged.
                    // Not part of the signed CAPS triplet → ACCEPT signature intact.
                    ratchetV4: Self.advertisesRatchetV4 ? true : nil,
                    srtpDirKeyV1: Self.srtpDirKeysEnabled ? true : nil,
                    // W-NFCVISIBLE go-live — same flip as the OFFER above, see its
                    // comment for the full rationale.
                    pskMixV1: true
                ),
                pskFingerprints: acceptAdvertisedPskFingerprints,
                // W-PSKBLIND — the RECEIVED wire value, verbatim, not our static
                // fingerprint. Dialect-agnostic: the initiator resolves it through the
                // advertisement it composed. `selectedFp` (the static form) stays the
                // value everything downstream uses.
                selectedPskFingerprint: selectedPsk != nil ? resolvedAdvert.wireValue : nil,
                pskRoles: acceptAdvertisedPskRoles
            )

            // Phase-10b (c) — SIGN the ACCEPT, binding it to the verified OFFER
            // (`verifiedOfferBinding` from step (b); EMPTY when the OFFER was
            // unsigned/legacy). W527 INVARIANT PRESERVED: `accept` keeps
            // pqcPublicKey:""/x25519PublicKey:"" EXACTLY — `signedCopy` only
            // APPENDS the two sig fields and copies every other field verbatim
            // (including the "" pubkeys), so Android's kotlinx deserializer never
            // sees them as absent. No-op (acceptToSend == accept, sig fields nil)
            // when signing is not wired → byte-identical legacy ACCEPT.
            //
            // BINDING-FORGERY NOTE (mirrors the Android reference): binding to
            // EMPTY when the OFFER was unsigned is NOT a hole. A signing-capable
            // initiator recomputes its REAL sent-offer binding, so our
            // empty-binding ACCEPT signature MISMATCHES on its side → it aborts
            // (a MITM that strips the OFFER signature is caught initiator-side).
            // A genuinely-legacy initiator does not verify at all. callId + the
            // signed ciphertext already bind the ACCEPT to this exact call.
            var acceptToSend = accept
            // W-KCMAC — `kc_transcript`'s `accept_binding`: `SHA-256` of the SAME v2
            // ACCEPT transcript object `acceptTV2` below (never raw JSON bytes — see
            // `KeyConfirmation.transcript`'s doc). Stays empty when the v2 transcript
            // wasn't buildable (signing not wired / pathological psk-list), which the
            // KCMAC gate below treats as "kc_mac not attempted" (status `.absent`).
            var acceptBindingV2ForKc = Data()
            if signingEnabled, let idKey = localSignerIdentityKey,
               let acceptT = Self.acceptTranscript(from: accept, callId: callId, signerKeyRaw: idKey, offerBinding: verifiedOfferBinding) {
                // W-TRANSCRIPTV2 — v2 sibling, binds to the v2 offer_binding computed
                // alongside the v1 one above (empty when the OFFER's v2 transcript wasn't
                // available).
                let acceptTV2 = Self.acceptTranscriptV2(from: accept, callId: callId, signerKeyRaw: idKey, offerBindingV2: verifiedOfferBindingV2)
                acceptToSend = signedCopy(of: accept, transcript: acceptT, transcriptV2: acceptTV2)
                if let acceptTV2 { acceptBindingV2ForKc = HandshakeTranscript.offerBinding(acceptTV2) }
            }
            let wire = AndroidHandshakeEnvelope.serialize(callId: callId, bundle: acceptToSend)

            // W529 — stash the ACCEPT wire BEFORE checking the
            // session-init guard so a duplicate OFFER replays this
            // EXACT same bundle (same ciphertext, same shared secret)
            // instead of deriving a fresh one. Re-deriving on every
            // duplicate OFFER would produce a different ML-KEM
            // ciphertext (encapsulation is randomized) and the caller
            // would race between two valid-but-different ACCEPTs.
            let normalizedOId = callId.lowercased()
            let alreadyInit = lock.withLock {
                let r = sessionInitializedByCall.contains(normalizedOId)
                if !r {
                    sessionInitializedByCall.insert(normalizedOId)
                    lastSentAcceptWire = wire
                    if handshakeStartedAt == nil { handshakeStartedAt = Date() }
                    // Capture the responder-side sender closure for
                    // W531 (WS-reconnect replay) so we don't depend on
                    // AppState re-supplying it.
                    retrySenderClosure = sendOpaqueRaw
                }
                return r
            }
            if alreadyInit {
                // W529: idempotent replay — re-emit the SAME bundle the
                // first OFFER produced. Caller will recognise it via
                // their own session-init guard and discard.
                if let cached = lock.withLock({ lastSentAcceptWire }) {
                    print("[QAudionCallIntegration] OFFER duplicate for callId=\(callId.prefix(8))… — replaying cached ACCEPT")
                    try await sendOpaqueRaw(cached)
                } else {
                    print("[QAudionCallIntegration] OFFER duplicate for callId=\(callId.prefix(8))… — session already initialised, skipping initSession")
                }
                return
            }
            try await sendOpaqueRaw(wire)
            try engine.initialize()
            // W479 — Android peer: use AdaptivePaddingController-compatible
            // audio scheme (static session key, no AAD, 2-byte len + 120B padding).
            // Byte-identical to Android FrameRelayTransport.send/decode +
            // AdaptivePaddingController.sealAudio/openAudio.
            try engine.initSession(sharedSecret: combined, adaptivePadding: true)
            onRelaySessionReady?(combined, callId)
            lock.withLock { state = .active }
            // W529: handshake reached active — kill the retry loop.
            offerRetryTask?.cancel()
            offerRetryTask = nil
            onStateChanged?(.active)
            onPqcSessionKeyEstablished?(combined)
            // DISPLAY-ONLY: surface the PSK fingerprint negotiated on this
            // responder OFFER path (`selectedFp`, in scope from step 4).
            onPqcSessionKeyEstablishedWithPsk?(combined, selectedFp)
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
            // as on Android. SKIP (leave v3 fallback) unless ALL real inputs exist;
            // a placeholder would diverge and break interop.
            // `negotiatedRatchetV4` is the cross-platform AND (this build advertises
            // v4 AND the peer advertised it) — without it a one-sided v4 would send
            // 0xE5 frames the peer can't decrypt.
            let v4SelfIdPresent = (localSignerIdentityKey != nil)
            let v4PeerSik = bundle.signerIdentityKey.flatMap { Data(base64Encoded: $0) }
            let v4PeerIdValid = (v4PeerSik?.count == 32)
            let v4BindingPresent = !verifiedOfferBinding.isEmpty
            let v4Fire = negotiatedRatchetV4 && v4SelfIdPresent && v4PeerIdValid && v4BindingPresent
            print("[PQC_DIAG_V4] responder callId=\(callId.prefix(8)) negotiatedV4=\(negotiatedRatchetV4) available=\(RatchetNative.available) selfId=\(v4SelfIdPresent) peer=\(v4PeerIdValid) bindingEmpty=\(verifiedOfferBinding.isEmpty) → fire=\(v4Fire)")
            if v4Fire,
               let selfId = localSignerIdentityKey,
               let peerId = v4PeerSik {
                onV4BootstrapReady?(callerId, combined, verifiedOfferBinding, selfId, peerId)
            }
            // vkey-v1: JSON responder — `combined` is the post-PSK-mix
            // session key and the IKM for K_video.
            onVideoKeyEstablished?(combined)

            // W-KCMAC (ship step 5) — responder leg. Fires AFTER the session key
            // and the ACCEPT's v2 binding both exist. `kcKey`/`transcript` stay
            // nil unless BOTH transcript-v2 bindings (`verifiedOfferBindingV2`
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
            if !verifiedOfferBindingV2.isEmpty, !acceptBindingV2ForKc.isEmpty,
               let ikResp = localSignerIdentityKey, let ikInit = v4PeerSik, ikInit.count == 32 {
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
                    offerBinding: verifiedOfferBindingV2,
                    acceptBinding: acceptBindingV2ForKc,
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
                peerAdvertisedRoles: kcPeerAdvertisedRoles, selectedFp: selectedFp
            ))

            // Pre-negotiation parity (mirror of the QUAD .offer branch):
            // the PQC OFFER is fully deserialised and our ACCEPT is on the
            // wire — tell the Android caller we are ringing locally so its
            // UI flips to "Ringing" and the server marks the WS-delivered
            // `call_incoming` as acknowledged (suppressing the backup VoIP
            // push). Sent AFTER the ACCEPT so the crypto round-trip is
            // already in flight when the caller starts ringing.
            if !callerId.isEmpty {
                sendCallReady?(callId, callerId)
            }

        case .accept:
            // Originator side — completes the dual-hybrid combine using
            // the local hybrid privs we stashed in onAndroidCallSetupStarted.
            // W461: look up with both original and lowercase callId because
            // Android may echo a lowercase UUID even when iOS sent uppercase.
            let localKeys = localHybridKeysByCall[callId]
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

            // Phase-10b (d) — VERIFY the incoming ACCEPT (+ offer_binding) BEFORE
            // any crypto work or session init (spec §4). Skipped entirely when
            // verification is not wired (legacy behaviour). The peer is
            // `callerId` (AppState threads `senderId` into this path). We
            // recompute the binding from the OFFER WE SENT (stashed in step (a))
            // so the policy rebuilds the ACCEPT transcript with the SAME
            // expected binding the responder signed; a real ACCEPT cannot be
            // paired with a forged OFFER (spec §3 / threat §7). `.abort` LOGS,
            // fires `onHandshakeIdentityUnverified` (P0-3), and — W-NOBRICK —
            // STILL FALLS THROUGH to decapsulate + initSession exactly like
            // `.authenticated`: the crypto session (and therefore the SAS words)
            // must exist for the user to have anything to reconfirm. What is now
            // actually held back is MEDIA — AppState won't install the relay
            // sealers / v4 ratchet bootstrap for this call until the user
            // reconfirms the SAS. `.authenticated` commits the pin / v4 flag,
            // then falls through to the same decapsulate + initSession.
            // W-KCMAC — hoisted to case-scope (was a local of the `if
            // verificationEnabled` block) so the KCMAC gate below can read our
            // OWN sent-OFFER v2 binding (`kc_transcript`'s `offer_binding`) even
            // though it's computed here, before the ACCEPT's own v2 transcript is
            // known. Stays empty ⇒ "kc_mac not attempted" when verification is
            // off or we sent an unsigned/pathological OFFER.
            var offerBindingV2ForKc = Data()
            // W-KCMAC — `AssuranceState.decide`'s `sigOk` input for this leg.
            var acceptSigOk = false
            if verificationEnabled {
                // Recompute the binding from the OFFER we sent (empty when we
                // sent an unsigned OFFER / no stash). Split into explicit steps so
                // the type-checker never explores the `withLock`→`map`→`??` chain
                // as one expression (CLAUDE.md §13).
                let sentOfferT: Data? = lock.withLock { sentOfferTranscriptByCall[callId.lowercased()] }
                var expectedBinding = Data()
                if let t = sentOfferT {
                    expectedBinding = HandshakeTranscript.offerBinding(t)
                }
                // W-TRANSCRIPTV2 — v2 sibling of `expectedBinding`, from the v2 OFFER
                // transcript WE SENT (stashed alongside the v1 one at OFFER-send time).
                let sentOfferTV2: Data? = lock.withLock { sentOfferTranscriptV2ByCall[callId.lowercased()] }
                var expectedBindingV2 = Data()
                if let t2 = sentOfferTV2 {
                    expectedBindingV2 = HandshakeTranscript.offerBinding(t2)
                }
                offerBindingV2ForKc = expectedBindingV2
                let verdict = evaluateVerdict(
                    bundle: bundle, peerId: callerId, peerDeviceId: callerDeviceId,
                    transcriptFor: { key in Self.acceptTranscript(from: bundle, callId: callId, signerKeyRaw: key, offerBinding: expectedBinding) },
                    transcriptForV2: { key in Self.acceptTranscriptV2(from: bundle, callId: callId, signerKeyRaw: key, offerBindingV2: expectedBindingV2) }
                )
                switch verdict {
                case .abort(let code):
                    // W-NOBRICK (user directive): never hard-drop on a handshake-sig
                    // verdict. (D11) No more blind re-pin of the bundle's own
                    // (untrusted) key — an `identity_key_mismatch` means the bundle
                    // key is ∉ the server-published set (an UNAUTHENTICATED change).
                    // Raise a non-blocking in-call alert, PROCEED to initialise the
                    // session WITHOUT pinning the observed key; the SAS is the real
                    // anti-MITM gate. (A set-PROVEN rotation returns
                    // `.authenticatedRepinFromPublished`, not this case.)
                    print("[QAudionCallIntegration] ⚠️ ACCEPT verify code=\(code) peer=\(callerId.prefix(8))… callId=\(callId.prefix(8))… — NOT aborting; proceeding, VERIFY THE SAS")
                    if code == "identity_key_mismatch" {
                        onUnauthenticatedIdentityChange?(callerId)
                    }
                    // XC-1 — present-but-INVALID signature (forgery). Revoke the
                    // peer's SAS verification → in-call SAS re-confirmation required.
                    // Still PROCEED (W-NOBRICK / signal-not-kill).
                    if code == "sig_invalid" {
                        onInvalidHandshakeSignature?(callerId)
                    }
                    // P0-3 — same media-hold signal as the OFFER side above.
                    onHandshakeIdentityUnverified?(callId)
                case .authenticated(let tofuPinKey, let v4Capable, let srtpDirKeyV1Capable):
                    applyAuthenticatedSideEffects(peerId: callerId, deviceId: callerDeviceId, tofuPinKey: tofuPinKey, v4Capable: v4Capable, srtpDirKeyV1Capable: srtpDirKeyV1Capable)
                    acceptSigOk = true
                case .authenticatedRepinFromPublished(let deviceKey, let v4Capable, let srtpDirKeyV1Capable):
                    // D11 trust-on-publish: set-proven rotation → silent additive
                    // re-pin per-(peer, device); NO banner. Proceed to init the
                    // session (the policy already verified the ACCEPT signature
                    // under this set-proven device key).
                    print("[QAudionCallIntegration] ACCEPT set-proven rotation peer=\(callerId.prefix(8))… dev=\((callerDeviceId ?? "—").prefix(8))… — silent re-pin, proceeding")
                    applyAuthenticatedSideEffects(peerId: callerId, deviceId: callerDeviceId, tofuPinKey: deviceKey, v4Capable: v4Capable, srtpDirKeyV1Capable: srtpDirKeyV1Capable)
                    acceptSigOk = true
                case .proceedUnsignedWarn(let reason):
                    print("[QAudionCallIntegration] ACCEPT unsigned-legacy peer=\(callerId.prefix(8))… callId=\(callId.prefix(8))… — proceeding: \(reason)")
                }
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

            // 3. Phase B — fp_adv exchange for hw_only (schema:4 V4 KDF).
            // Originator role: OUR earbud produces fp_adv (fpSetInit),
            // the ACCEPT side's fp_adv is fpSetResp (arrives via FPSET piggy-back).
            // We must use the ACCEPT's `selectedPskFingerprint` to determine
            // whether hw_only is active. iOS originator has no SovereignKeyVault
            // yet (WIRE_SPEC §5 P1), so we can only do V4 when the peer selected
            // a PSK fingerprint that the earbud can bind (future: look up psk by fp).
            // For now: V4 only when earbudPairingGattProxy is set AND
            // selectedPskFingerprint is non-empty (indicating HW key was negotiated).
            let selectedFpStr = bundle.selectedPskFingerprint ?? ""
            let callerIsHwOnly = !selectedFpStr.isEmpty
            if callerIsHwOnly {
                print("[QAudionCallIntegration] ACCEPT carried selectedPskFingerprint=\(selectedFpStr.prefix(16))… — attempting V4 via earbud GATT")
            }
            let keyClassAccept: UInt8
            let fpSetInitAccept: Data   // Our (originator) fp_adv
            let fpSetRespAccept: Data   // Responder fp_adv
            let gattAccept = earbudPairingGattProxy
            if let gatt = gattAccept, callerIsHwOnly {
                let ctBind = Data(
                    HMAC<SHA256>.authenticationCode(
                        for: pqcCt,
                        using: SymmetricKey(data: HkdfLabels.hybridCtBindV1)
                    )
                )
                var ownFpAdv: Data?
                do {
                    try await gatt.writeFpAdvSeed(ctBind)
                    let (readFpAdv, _) = try await gatt.readFpAdv()
                    ownFpAdv = readFpAdv
                } catch {
                    print("[QAudionCallIntegration] FPSET GATT read failed (originator) callId=\(callId.prefix(8))…: \(error) — falling back to schema:2")
                }
                if let localFp = ownFpAdv {
                    // Send our fp_adv to the responder.
                    if let sender = lock.withLock({ retrySenderClosure }) {
                        sendFpSet(callId: callId, fpAdv: localFp,
                                  sendOpaqueRaw: sender)
                    }
                    fpSetInitAccept = localFp
                    // Wait for responder's FPSET (already sent by the OFFER path).
                    fpSetRespAccept = await awaitFpSet(callId: callId, timeoutSec: 5.0)
                    keyClassAccept  = 2  // hw_only
                } else {
                    fpSetInitAccept = Data(repeating: 0, count: 32)
                    fpSetRespAccept = Data(repeating: 0, count: 32)
                    keyClassAccept  = 0
                }
            } else {
                if callerIsHwOnly {
                    print("[QAudionCallIntegration] ACCEPT: hw_only but no earbud GATT proxy — falling back to schema:2 (will diverge from peer if peer did V4)")
                }
                fpSetInitAccept = Data(repeating: 0, count: 32)
                fpSetRespAccept = Data(repeating: 0, count: 32)
                keyClassAccept  = 0
            }

            // 4. Derive session key — V4 when keyClass != 0, schema:2 otherwise.
            let combined: Data
            if keyClassAccept != 0 {
                let nd = Self.negDigest(fpSetInit: fpSetInitAccept, fpSetResp: fpSetRespAccept)
                // WIRE_SPEC §5 P1 fix: look up PSK by fingerprint from SovereignKeyVault.
                let vaultPsk: Data? = Self.pskForEchoedSelection(
                    echo: selectedFpStr,
                    callId: callId,
                    ownEphemeralX25519Pub: local.x25519Priv.publicKey.rawRepresentation
                )
                let selFpRaw: Data
                if let psk = vaultPsk, !psk.isEmpty {
                    selFpRaw = Data(SHA256.hash(data: psk))
                } else {
                    print("[QAudionCallIntegration] ACCEPT V4: no local PSK for fp=\(selectedFpStr.prefix(16))… — selFpRaw=zeros (will diverge)")
                    selFpRaw = Data(repeating: 0, count: 32)
                }
                combined = Self.deriveHybridSessionKeyV4(
                    pqcSs: pqcSs,
                    x25519Ss: x25519Ss,
                    pqcCiphertext: pqcCt,
                    psk: vaultPsk,
                    selectedFp: selFpRaw,
                    keyClass: keyClassAccept,
                    negDigest: nd
                )
                print("[QAudionCallIntegration] ACCEPT V4 KDF keyClass=\(keyClassAccept) callId=\(callId.prefix(8))…")
            } else {
                // Schema:2 — byte-identical to Android / Desktop / firmware.
                // W574n: if the responder selected a PSK (selectedFpStr non-empty) and
                // we fell back to schema:2 from the hw_only V4 attempt (no earbud GATT
                // proxy on a phone↔phone call), we MUST still mix that PSK. The
                // responder's schema:2 derivation (OFFER path above) uses `selectedPsk`,
                // so passing psk:nil here derives a DIFFERENT session key → the M-15
                // relay sealer keys diverge → every RX audio frame fails to unseal →
                // the call connects but no audio is heard. Look the PSK up from our own
                // vault by the responder's selected fingerprint (same lookup the V4
                // branch uses) so both sides mix the identical PSK.
                let fallbackPsk: Data? = {
                    guard !selectedFpStr.isEmpty else {
                        // W-PSKMIX step 3 — bare log only (no UI notice: the
                        // S7 AssuranceState this should eventually surface
                        // through doesn't exist yet, later ship step). Makes
                        // today's silent no-PSK downgrade visible in device
                        // logs instead of leaving no trace at all.
                        print("[QAudionCallIntegration] ACCEPT schema:2 — selectedPskFingerprint empty, session key mixes NO psk callId=\(callId.prefix(8))…")
                        return nil
                    }
                    // Same resolution as the V4 branch above — one helper, so the two
                    // derivation paths cannot disagree about which PSK the responder
                    // picked. They disagreeing is not a cosmetic bug: the responder
                    // already derived WITH the PSK, so a miss here diverges the session
                    // key and every RX frame fails to unseal.
                    return Self.pskForEchoedSelection(
                        echo: selectedFpStr,
                        callId: callId,
                        ownEphemeralX25519Pub: local.x25519Priv.publicKey.rawRepresentation
                    )
                }()
                combined = Self.deriveHybridSessionKey(
                    pqcSs: pqcSs,
                    x25519Ss: x25519Ss,
                    pqcCiphertext: pqcCt,
                    psk: fallbackPsk
                )
            }

            // 5. Double-ACCEPT guard — normalise to lowercase so both the
            //    original-case and lowercase-echo paths converge on one key.
            let normalizedId = callId.lowercased()
            let alreadyInit = lock.withLock {
                let r = sessionInitializedByCall.contains(normalizedId)
                if !r { sessionInitializedByCall.insert(normalizedId) }
                return r
            }
            if alreadyInit {
                print("[QAudionCallIntegration] ACCEPT duplicate for callId=\(callId.prefix(8))… — session already initialised, skipping initSession")
                return
            }
            print("[QAudionCallIntegration] ACCEPT accepted for callId=\(callId.prefix(8))… — initialising session")

            // 6. Initialise the audio session and fire the broker hook.
            // W479 — Android peer (caller side): same AdaptivePadding scheme.
            try engine.initSession(sharedSecret: combined, adaptivePadding: true)
            onRelaySessionReady?(combined, callId)
            lock.withLock {
                state = .active
                // 7. Zero the stashed privs immediately — the session key is
                //    now in the engine, the ephemeral keys are no longer
                //    needed. Clearing the dictionary entry releases the
                //    PqcKeyExchange.KeyPair (which has its own destroy hook)
                //    and the Curve25519 PrivateKey (CryptoKit will deinit
                //    the wrapped opaque handle on dealloc). Zeroing
                //    earlier risks the second-ACCEPT branch trying to
                //    decap with empty bytes.
                localHybridKeysByCall.removeValue(forKey: callId)
            }
            onStateChanged?(.active)
            onPqcSessionKeyEstablished?(combined)
            // NOT display-only (it used to be, hence the old comment here).
            // AppState feeds this straight into `resolvePskBytes`, which is the
            // HKDF *salt* for K_video — so a value that fails to resolve there
            // silently swaps the salt for the literal fallback and the two legs
            // derive different video keys (purple screen, AES-GCM open failures,
            // no other symptom). `selectedFpStr` is `bundle.selectedPskFingerprint`
            // = the W-PSKBLIND **wire** value: since bb8affd that is a per-call
            // blinded HMAC tag, NOT the static SHA-256(psk) fingerprint the
            // consumer matches on — so it never resolved and iOS-as-initiator
            // always fell back to the literal salt while Android salted with the
            // raw PSK. Resolve the echo to the actual PSK (same helper both
            // derivation branches above already use) and hand over that PSK's
            // canonical static fingerprint, which is what the consumer expects.
            // The responder path (line ~1772) was already correct: it emits
            // `selectedFp`, kept in static form precisely for this.
            let establishedPskFp: String? = Self.pskForEchoedSelection(
                echo: selectedFpStr,
                callId: callId,
                ownEphemeralX25519Pub: local.x25519Priv.publicKey.rawRepresentation
            ).map { PskAdvertising.canonicalFingerprint(forPsk: $0) }
            if !selectedFpStr.isEmpty && establishedPskFp == nil {
                print("[QAudionCallIntegration] ⚠️ ACCEPT echoed selection did not resolve to a vault PSK callId=\(callId.prefix(8))… — K_video will use the literal salt and WILL diverge from the peer")
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
            // expression (CLAUDE.md §13). SKIP the v4 bootstrap (leave v3 fallback)
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
            let v4InitFire = negotiatedRatchetV4 && v4InitSelfIdPresent && v4InitPeerIdValid && v4InitBindingPresent
            print("[PQC_DIAG_V4] initiator callId=\(callId.prefix(8)) negotiatedV4=\(negotiatedRatchetV4) available=\(RatchetNative.available) selfId=\(v4InitSelfIdPresent) peer=\(v4InitPeerIdValid) bindingEmpty=\(!v4InitBindingPresent) → fire=\(v4InitFire)")
            if v4InitFire,
               let selfId = localSignerIdentityKey,
               let peerId = v4InitPeerSik,
               let sentOfferT = sentOfferTForV4 {
                let sentBinding = HandshakeTranscript.offerBinding(sentOfferT)
                onV4BootstrapReady?(callerId, combined, sentBinding, selfId, peerId)
            }
            // vkey-v1: JSON caller — `combined` is the IKM for K_video.
            onVideoKeyEstablished?(combined)

            // W-KCMAC (ship step 5) — initiator leg, the CALLER-side twin of the
            // responder's fire above. `offerBindingV2ForKc` is OUR OWN sent-OFFER
            // v2 binding (hoisted out of the `if verificationEnabled` block above
            // at step (d)); `acceptBindingV2ForKc` is reconstructed HERE (the
            // ACCEPT's own v2 transcript wasn't stashed — only its byte-length-
            // prefixed pieces were used transiently inside `evaluateVerdict`)
            // using the SAME "continuity, not trust" convention the OFFER-verify
            // abort branch above already uses: the bundle's OWN carried
            // `signerIdentityKey`, not necessarily the pinned/set-proven key —
            // KCMAC is a redundant integrity check on top of, not a substitute
            // for, the Ed25519 signature verdict already evaluated above.
            let kcCallerPeerSupportsMix = bundle.capabilities?.pskMixV1 ?? false
            let kcCallerN: Int
            let kcCallerMixFingerprints: [Data]
            // W-KCMACBLIND — same defect class as the K_video salt fix above,
            // same file, found by the follow-up sweep for other consumers of
            // `selectedFpStr`. The RESPONDER'S mirror of this block (:1817-1819)
            // hex-decodes `selectedFp`, the STATIC form; using the raw wire echo
            // here made the two legs hash different `kc_mac` transcripts on
            // every PSK call iOS placed — a false S1 KC_FAILED "active attack"
            // verdict, which `ContactsStore.applyAssuranceOutcome` then persists
            // as a suspended contact. `establishedPskFp` (:2177) is the same
            // already-resolved static fingerprint the K_video salt now uses —
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
            if !offerBindingV2ForKc.isEmpty,
               let ikInit = localSignerIdentityKey,
               let ikResp = v4InitPeerSik, ikResp.count == 32,
               let acceptTV2ForKc = Self.acceptTranscriptV2(
                   from: bundle, callId: callId, signerKeyRaw: ikResp, offerBindingV2: offerBindingV2ForKc) {
                let acceptBindingV2ForKc = HandshakeTranscript.offerBinding(acceptTV2ForKc)
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
                    offerBinding: offerBindingV2ForKc,
                    acceptBinding: acceptBindingV2ForKc,
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
                selectedFp: establishedPskFp
            ))

            // W529: caller's ACCEPT decapsulation succeeded → cancel
            // any outstanding 5 s OFFER retry.
            offerRetryTask?.cancel()
            offerRetryTask = nil
        }
    }

    // MARK: - Phase-10b handshake-signing helpers (additive)
    //
    // HANDSHAKE-SIGNING-SPEC.md §3–§5. These pure helpers keep the four wire
    // insertion points (OFFER sign, OFFER verify, ACCEPT sign, ACCEPT verify)
    // to a few lines each so the big `onAndroidBundleReceived`/`onAndroid…`
    // bodies don't grow another type-checker-heavy branch (CLAUDE.md §13/§14).
    //
    // EPOCH NOTE (READ — this is a documented cross-platform divergence): the
    // signed transcript binds a 16-byte per-direction epochId that the wire
    // bundle does NOT carry. iOS feeds `HandshakeSigningPolicy.placeholderEpochId`
    // (16 zero bytes), exactly as the iOS baseline + the transcript KAT builder
    // were authored. Android derives `SHA-256("qaudion-hs-epoch-v1"||role||callId)`
    // and Desktop derives `SHA-256("qaudion-hs-epoch-v1"||callId||role)` — these
    // three DISAGREE, so a SIGNED bundle from Android/Desktop will NOT verify on
    // iOS (and Android↔Desktop already mismatch each other). This is harmless
    // TODAY because the `require_signed_handshake` flag defaults OFF on every
    // platform AND no platform emits signed bundles in production yet, so the
    // only inbound bundles are unsigned → WarnLegacy → proceed. It becomes a
    // HARD cross-platform interop break the moment ANY platform starts emitting
    // signed bundles: a present-but-(epoch-)mismatched signature is fatal by
    // spec §4 (anti-downgrade — intentionally NOT relaxed here). The epochId
    // derivation MUST be unified across all three platforms BEFORE signing is
    // turned on anywhere. Tracked as the release-gating blocker in the wiring
    // report. Until then iOS only ever SENDS signed bundles when explicitly
    // wired (closures set), and only ABORTS on a cryptographically-invalid
    // present signature, never on a missing one.

    /// Capability triplet reconstructed from a received bundle (spec §5b:
    /// absent OR null capabilities → false).
    private static func capsFromBundle(
        _ caps: AndroidHandshakeBundle.Capabilities?
    ) -> (ratchetV3: Bool, sframeV1: Bool, vkeyV1: Bool, sessionKdfV3: Bool, ratchetV4: Bool, srtpDirKeyV1: Bool) {
        return (
            ratchetV3: caps?.ratchetV3 ?? false,
            sframeV1: caps?.sframeV1 ?? false,
            vkeyV1: caps?.vkeyV1 ?? false,
            sessionKdfV3: caps?.sessionKdfV3 ?? false,  // XC-3: bound into the signed transcript (4th CAPS byte)
            ratchetV4: caps?.ratchetV4 ?? false,  // XC-4: bound into the signed transcript (5th CAPS byte)
            srtpDirKeyV1: caps?.srtpDirKeyV1 ?? false  // XC-4: bound into the signed transcript (6th CAPS byte)
        )
    }

    /// W-TRANSCRIPTV2 — 7-tuple sibling of `capsFromBundle`, adding `pskMixV1` (bound into
    /// the v2 transcript's 7th CAPS byte ONLY — `capsFromBundle`/v1's 6-byte CAPS is
    /// completely untouched). Absent/null capabilities → false, same rule as `capsFromBundle`.
    private static func capsFromBundle7(
        _ caps: AndroidHandshakeBundle.Capabilities?
    ) -> (ratchetV3: Bool, sframeV1: Bool, vkeyV1: Bool, sessionKdfV3: Bool, ratchetV4: Bool, srtpDirKeyV1: Bool, pskMixV1: Bool) {
        let c6 = capsFromBundle(caps)
        return (c6.ratchetV3, c6.sframeV1, c6.vkeyV1, c6.sessionKdfV3, c6.ratchetV4, c6.srtpDirKeyV1, caps?.pskMixV1 ?? false)
    }

    /// Build the §3 OFFER transcript from an OFFER bundle's RAW (base64-decoded)
    /// fields, signed/verified under `signerKeyRaw` (the LOCAL pub when signing,
    /// the PINNED/server peer pub when verifying — NEVER blindly the bundle key).
    /// Returns nil if a required public-key field fails to base64-decode.
    private static func offerTranscript(
        from bundle: AndroidHandshakeBundle,
        callId: String,
        signerKeyRaw: Data
    ) -> Data? {
        guard let pqcB64 = bundle.pqcPublicKey, let pqcRaw = Data(base64Encoded: pqcB64),
              let x25B64 = bundle.x25519PublicKey, let x25Raw = Data(base64Encoded: x25B64) else {
            return nil
        }
        let strongBox = bundle.strongBoxPublicKey.flatMap { Data(base64Encoded: $0) }
        let dualCurve = bundle.dualCurvePublicKey.flatMap { Data(base64Encoded: $0) }
        let caps = capsFromBundle(bundle.capabilities)
        return HandshakeTranscript.offer(
            callId: callId,
            signerIdentityKey: signerKeyRaw,
            epochId: HandshakeSigningPolicy.placeholderEpochId,
            pqcPublicKey: pqcRaw,
            x25519PublicKey: x25Raw,
            strongBoxPublicKey: strongBox,
            dualCurvePublicKey: dualCurve,
            ratchetV3: caps.ratchetV3,
            sframeV1: caps.sframeV1,
            vkeyV1: caps.vkeyV1,
            sessionKdfV3: caps.sessionKdfV3,
            ratchetV4: caps.ratchetV4,
            srtpDirKeyV1: caps.srtpDirKeyV1,
            ratchetV: HandshakeSigningPolicy.ratchetV,
            suiteId: HandshakeSigningPolicy.suiteId,
            pskFingerprints: bundle.pskFingerprints
        )
    }

    /// W-TRANSCRIPTV2 (multi-PSK-mixing SYNTHESIS.md ship step 4) — v2 sibling of
    /// `offerTranscript`. Same base64-decode guards; additionally returns `nil` when
    /// `HandshakeTranscript.offerV2` itself does (a pathological `pskFingerprints` list —
    /// see its doc).
    private static func offerTranscriptV2(
        from bundle: AndroidHandshakeBundle,
        callId: String,
        signerKeyRaw: Data
    ) -> Data? {
        guard let pqcB64 = bundle.pqcPublicKey, let pqcRaw = Data(base64Encoded: pqcB64),
              let x25B64 = bundle.x25519PublicKey, let x25Raw = Data(base64Encoded: x25B64) else {
            return nil
        }
        let strongBox = bundle.strongBoxPublicKey.flatMap { Data(base64Encoded: $0) }
        let dualCurve = bundle.dualCurvePublicKey.flatMap { Data(base64Encoded: $0) }
        let caps = capsFromBundle7(bundle.capabilities)
        return HandshakeTranscript.offerV2(
            callId: callId,
            signerIdentityKey: signerKeyRaw,
            epochId: HandshakeSigningPolicy.placeholderEpochId,
            pqcPublicKey: pqcRaw,
            x25519PublicKey: x25Raw,
            strongBoxPublicKey: strongBox,
            dualCurvePublicKey: dualCurve,
            ratchetV3: caps.ratchetV3,
            sframeV1: caps.sframeV1,
            vkeyV1: caps.vkeyV1,
            sessionKdfV3: caps.sessionKdfV3,
            ratchetV4: caps.ratchetV4,
            srtpDirKeyV1: caps.srtpDirKeyV1,
            pskMixV1: caps.pskMixV1,
            ratchetV: HandshakeSigningPolicy.ratchetV,
            suiteId: HandshakeSigningPolicy.suiteId,
            pskFingerprints: bundle.pskFingerprints,
            pskRoles: bundle.pskRoles
        )
    }

    /// Build the §3 ACCEPT transcript from an ACCEPT bundle's RAW (base64-decoded)
    /// ciphertext fields + the `offerBinding` it must answer. Returns nil if a
    /// required ciphertext field fails to base64-decode.
    private static func acceptTranscript(
        from bundle: AndroidHandshakeBundle,
        callId: String,
        signerKeyRaw: Data,
        offerBinding: Data
    ) -> Data? {
        guard let ct = bundle.ciphertext,
              let pqcRaw = Data(base64Encoded: ct.pqc),
              let x25Raw = Data(base64Encoded: ct.x25519) else {
            return nil
        }
        let strongBox = ct.strongBox.flatMap { Data(base64Encoded: $0) }
        let dualCurve = ct.dualCurve.flatMap { Data(base64Encoded: $0) }
        let caps = capsFromBundle(bundle.capabilities)
        return HandshakeTranscript.accept(
            callId: callId,
            signerIdentityKey: signerKeyRaw,
            epochId: HandshakeSigningPolicy.placeholderEpochId,
            ctPqc: pqcRaw,
            ctX25519: x25Raw,
            ctStrongBox: strongBox,
            ctDualCurve: dualCurve,
            ratchetV3: caps.ratchetV3,
            sframeV1: caps.sframeV1,
            vkeyV1: caps.vkeyV1,
            sessionKdfV3: caps.sessionKdfV3,
            ratchetV4: caps.ratchetV4,
            srtpDirKeyV1: caps.srtpDirKeyV1,
            ratchetV: HandshakeSigningPolicy.ratchetV,
            suiteId: HandshakeSigningPolicy.suiteId,
            selectedPskFingerprint: bundle.selectedPskFingerprint,
            offerBinding: offerBinding
        )
    }

    /// W-TRANSCRIPTV2 (multi-PSK-mixing SYNTHESIS.md ship step 4) — v2 sibling of
    /// `acceptTranscript`. `offerBindingV2` MUST be `SHA-256` of the OFFER's **v2**
    /// transcript (from `offerTranscriptV2`/`HandshakeTranscript.offerBinding`) — distinct
    /// from the v1 `offerBinding` this ACCEPT bundle's `acceptTranscript` binds to.
    /// `bundle.pskFingerprints`/`bundle.pskRoles` are THIS ACCEPT bundle's OWN advertised
    /// list (the responder's `advEnc(resp_advert)` binding — see
    /// `HandshakeTranscript.acceptV2`). Returns `nil` when `HandshakeTranscript.acceptV2`
    /// does.
    private static func acceptTranscriptV2(
        from bundle: AndroidHandshakeBundle,
        callId: String,
        signerKeyRaw: Data,
        offerBindingV2: Data
    ) -> Data? {
        guard let ct = bundle.ciphertext,
              let pqcRaw = Data(base64Encoded: ct.pqc),
              let x25Raw = Data(base64Encoded: ct.x25519) else {
            return nil
        }
        let strongBox = ct.strongBox.flatMap { Data(base64Encoded: $0) }
        let dualCurve = ct.dualCurve.flatMap { Data(base64Encoded: $0) }
        let caps = capsFromBundle7(bundle.capabilities)
        return HandshakeTranscript.acceptV2(
            callId: callId,
            signerIdentityKey: signerKeyRaw,
            epochId: HandshakeSigningPolicy.placeholderEpochId,
            ctPqc: pqcRaw,
            ctX25519: x25Raw,
            ctStrongBox: strongBox,
            ctDualCurve: dualCurve,
            ratchetV3: caps.ratchetV3,
            sframeV1: caps.sframeV1,
            vkeyV1: caps.vkeyV1,
            sessionKdfV3: caps.sessionKdfV3,
            ratchetV4: caps.ratchetV4,
            srtpDirKeyV1: caps.srtpDirKeyV1,
            pskMixV1: caps.pskMixV1,
            ratchetV: HandshakeSigningPolicy.ratchetV,
            suiteId: HandshakeSigningPolicy.suiteId,
            selectedPskFingerprint: bundle.selectedPskFingerprint,
            offerBinding: offerBindingV2,
            responderPskFingerprints: bundle.pskFingerprints,
            responderPskRoles: bundle.pskRoles
        )
    }

    /// Compute `require_signed(peer)` (spec §4) from the wired policy closures.
    private func requireSigned(forPeer peerId: String) -> Bool {
        let v4 = isPeerV4Pinned?(peerId) ?? false
        let verified = isPeerVerifiedChannel?(peerId) ?? false
        return HandshakeSigningPolicy.requireSigned(
            v4CapablePinned: v4,
            flagForcesSigned: requireSignedHandshakeFlag,
            peerVerifiedChannel: verified
        )
    }

    /// Whether THIS integration is configured to sign (local identity wired).
    /// When false the OFFER/ACCEPT go out UNSIGNED (legacy byte-identical wire).
    private var signingEnabled: Bool {
        return signTranscript != nil && localSignerIdentityKey != nil
    }

    /// Whether THIS integration is configured to VERIFY inbound bundles. When
    /// false an inbound bundle is treated as a legacy unsigned peer (proceed —
    /// no abort), so an unwired integration is behaviourally unchanged.
    private var verificationEnabled: Bool {
        return resolvePinnedPeerKey != nil
            || resolvePinnedPeerKeyForDevice != nil
            || resolveServerPeerKey != nil
    }

    /// Attach `signerIdentityKey` + `signature` (+ W-TRANSCRIPTV2's `sigV2`, best-effort) to
    /// a bundle by signing `transcript` (v1, unconditional) and, when supplied, `transcriptV2`
    /// (v2, best-effort — a v2-specific failure NEVER blocks `signature` from being attached,
    /// same isolation guarantee as Android `HandshakeSigner.signOffer/signAccept` / Desktop
    /// `signOffer/signAccept`). Returns the ORIGINAL bundle unchanged when the v1 signature
    /// itself fails (degrade to unsigned) so signing can never break a call. No-op (returns
    /// input) when signing is not wired.
    private func signedCopy(of bundle: AndroidHandshakeBundle, transcript: Data, transcriptV2: Data? = nil) -> AndroidHandshakeBundle {
        guard let idKey = localSignerIdentityKey, let sign = signTranscript,
              let sig = sign(transcript), sig.count == 64 else {
            return bundle
        }
        var sigV2B64: String?
        if let t2 = transcriptV2, let sig2 = sign(t2), sig2.count == 64 {
            sigV2B64 = sig2.base64EncodedString()
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
            signature: sig.base64EncodedString(),
            sigV2: sigV2B64
        )
    }

    /// Apply the spec §4 verdict to a received bundle for `peerId`, rebuilding
    /// the §3 transcript via `transcriptFor(trustedKey)`. Returns the policy
    /// verdict; the caller acts on it (abort / pin / warn). `advertisedV4` is
    /// whether the bundle advertised v4+suite-1 (here always our advertised
    /// values, since the wire carries no ratchetV/suiteId and both ends agree on
    /// the placeholder constants).
    private func evaluateVerdict(
        bundle: AndroidHandshakeBundle,
        peerId: String,
        peerDeviceId: String?,
        transcriptFor: (Data) -> Data?,
        transcriptForV2: (Data) -> Data?
    ) -> HandshakeSigningPolicy.Verdict {
        // D11: pin is keyed per-(peer, device). A nil/absent device id resolves
        // to the legacy bare-contactId pin (migration anchor / graceful fallback)
        // inside the store, so this is safe when `sender_device_id` is absent.
        // `peerPinStoreLookup` itself returns nil when neither pin closure is set.
        let pinned = peerPinStoreLookup(peerId: peerId, deviceId: peerDeviceId)
        let server = resolveServerPeerKey?(peerId)
        // D11 trust-on-publish floor: the server's published per-device SET. An
        // empty set (no floor / fetch failed) makes the policy degrade to legacy
        // pin-only TOFU — never a fatal mismatch.
        let publishedSet = resolvePublishedKeySet?(peerId, peerDeviceId) ?? []

        // Parse the bundle's carried key so we can pick the SAME authoritative
        // key the policy will verify under, and build the transcript under it
        // (the transcript binds `signerIdentityKey`, so a set-proven rotation
        // MUST be rebuilt under the bundle key — never the stale pin).
        let bundleKey: Data? = bundle.signerIdentityKey.flatMap { Data(base64Encoded: $0) }
        let verifyKey = HandshakeSigningPolicy.verifyKeyHint(
            bundleKey: bundleKey,
            pinnedKey: pinned,
            serverFetchedKey: server,
            publishedKeySet: publishedSet
        ) ?? Data()  // empty → policy ABSENT/malformed branch (transcript irrelevant)

        let transcript = transcriptFor(verifyKey) ?? Data()
        // W-TRANSCRIPTV2 — nil (NOT defaulted to empty Data) is meaningful here: it signals
        // "the v2 transcript could not be rebuilt" and `HandshakeSigningPolicy.evaluate`'s
        // dual-signature check must fail CLOSED on a present `sigV2` rather than silently
        // falling back to v1 — see its doc.
        let transcriptV2 = transcriptForV2(verifyKey)
        let advertisedV4 = (HandshakeSigningPolicy.ratchetV >= 0x04)
            && (HandshakeSigningPolicy.suiteId == 0x01)
        // SRTP downgrade fix: whether THIS bundle advertised the directional-
        // SRTP-key capability — only meaningful once the signature verifies
        // (evaluate() only threads it into the .authenticated* verdicts).
        let advertisedSrtpDirKeyV1 = bundle.capabilities?.srtpDirKeyV1 ?? false
        return HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: bundle.signerIdentityKey,
            signatureB64: bundle.signature,
            transcript: transcript,
            pinnedKey: pinned,
            serverFetchedKey: server,
            requireSigned: requireSigned(forPeer: peerId),
            advertisedV4: advertisedV4,
            publishedKeySet: publishedSet.isEmpty ? nil : publishedSet,
            advertisedSrtpDirKeyV1: advertisedSrtpDirKeyV1,
            sigV2B64: bundle.sigV2,
            transcriptV2: transcriptV2
        )
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
        srtpDirKeyV1Capable: Bool = false
    ) {
        if let pinKey = tofuPinKey {
            if let perDevice = commitTofuPinForDevice {
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

    // MARK: - Schema:3 session KDF primitives

    /// selected_fp_or_zero32 = SHA-256(selectedPsk) if non-nil/non-empty, else 32×0x00.
    ///
    /// Byte-identical to Android `HybridPqcKeyExchange.selectedFpOrZero32` and
    /// firmware path in `qa_session_info_v3`. `internal` so KAT tests can exercise it.
    static func selectedFpOrZero32(selectedPsk: Data?) -> Data {
        guard let psk = selectedPsk, !psk.isEmpty else {
            return Data(repeating: 0, count: 32)
        }
        return Data(SHA256.hash(data: psk))
    }

    /// info_v3 = "q-audion-session-key"(20) || ct_bind(32) || selected_fp_or_zero32(32) [84B]
    ///
    /// Extends schema:2 `info` with the 32-byte fp tail, producing a distinct
    /// HKDF output that a schema:2 peer cannot accidentally derive.
    static func sessionInfoV3(ctBind: Data, selectedFpOrZero32: Data) -> Data {
        precondition(selectedFpOrZero32.count == 32, "selectedFpOrZero32 must be 32 bytes")
        var info = Data(capacity: HkdfLabels.hybridPqcSessionKey.count + ctBind.count + 32)
        info.append(HkdfLabels.hybridPqcSessionKey)
        info.append(ctBind)
        info.append(selectedFpOrZero32)
        return info
    }

    /// Schema:3 hybrid session-key derivation.
    ///
    /// Byte-identical to Android `HybridPqcKeyExchange.deriveSessionKeyV3` and
    /// firmware `qa_session_handshake_complete` (v3 path).
    /// Pinned by `session-key-v3-kat.json` (3 vectors: no-psk / K1 / K2).
    ///
    ///   ct_bind            = HMAC-SHA256("q-audion-ct-bind-v1", pqcCiphertext) [32B]
    ///   selected_fp_or_z32 = SHA-256(psk) if non-nil/non-empty else 32×0x00   [32B]
    ///   ikm                = pqcSs(32) || x25519Ss(32)                         [64B]
    ///   salt               = psk  if non-nil/non-empty else "q-audion-hybrid-pqc-v1"
    ///   info_v3            = "q-audion-session-key"(20) || ct_bind(32) || sel_fp_z32(32) [84B]
    ///   key                = HKDF-SHA256(ikm, salt, info_v3, 32)
    ///
    /// `internal` so `SessionKeyV3KatTests` can exercise it via `@testable import`.
    static func deriveHybridSessionKeyV3(
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
        let selFp = selectedFpOrZero32(selectedPsk: psk)
        let info = sessionInfoV3(ctBind: ctBind, selectedFpOrZero32: selFp)

        var ikm = Data(capacity: pqcSs.count + x25519Ss.count)
        ikm.append(pqcSs)
        ikm.append(x25519Ss)

        let salt: Data
        if let psk = psk, !psk.isEmpty {
            salt = psk
        } else {
            salt = HkdfLabels.hybridPqcSaltV1
        }

        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - Schema:4 session KDF primitives

    /// neg_digest = SHA-256(fp_set_init(32) || fp_set_resp(32))
    ///
    /// Binds the full negotiated fingerprint set from both sides into the
    /// session-key info, preventing downgrade-via-fp-selection attacks.
    /// Byte-identical to Android `HybridPqcKeyExchange.negDigest` and
    /// firmware `qa_session_neg_digest_v4`.
    /// `internal` so `SessionV4KatTests` can exercise it via `@testable import`.
    static func negDigest(fpSetInit: Data, fpSetResp: Data) -> Data {
        var combined = Data(capacity: fpSetInit.count + fpSetResp.count)
        combined.append(fpSetInit)
        combined.append(fpSetResp)
        return Data(SHA256.hash(data: combined))
    }

    /// info_v4 = "q-audion-session-key"(20) || ct_bind(32) || selected_fp(32) || key_class(1) || neg_digest(32) [117B]
    ///
    /// The schema:4 HKDF info vector.  Extends schema:2 info with three
    /// new fields that bind the earbud-exclusive key negotiation result
    /// (`selected_fp`, `key_class`, `neg_digest`) so the session key
    /// commits to the full fp-and-key-class transcript.
    ///
    /// - Parameters:
    ///   - ctBind:     HMAC-SHA256("q-audion-ct-bind-v1", pqcCiphertext)  [32B]
    ///   - selectedFp: SHA-256(psk) if psk non-nil/non-empty else 32×0x00  [32B]
    ///   - keyClass:   0=none, 1=shared, 2=hw_only                          [1B]
    ///   - negDigest:  SHA-256(fp_set_init || fp_set_resp)                 [32B]
    /// `internal` so `SessionV4KatTests` can exercise it via `@testable import`.
    static func sessionInfoV4(
        ctBind: Data,
        selectedFp: Data,
        keyClass: UInt8,
        negDigest: Data
    ) -> Data {
        precondition(selectedFp.count == 32, "selectedFp must be 32 bytes")
        precondition(negDigest.count  == 32, "negDigest must be 32 bytes")
        var info = Data(capacity: 20 + 32 + 32 + 1 + 32)
        info.append(HkdfLabels.hybridPqcSessionKey)  // "q-audion-session-key" [20B]
        info.append(ctBind)                           // ct_bind               [32B]
        info.append(selectedFp)                       // selected_fp           [32B]
        info.append(keyClass)                         // key_class             [ 1B]
        info.append(contentsOf: negDigest)            // neg_digest            [32B]
        return info                                   // total                [117B]
    }

    /// Schema:4 hybrid session-key derivation.
    ///
    /// Byte-identical to Android `HybridPqcKeyExchange.deriveSessionKeyV4` and
    /// firmware `qa_session_handshake_complete` (v4 path).
    /// Pinned by the `session_v4` array in `earbud-excl-v2-kat.json`
    /// (3 vectors: none / shared-K / exclusive-Kpp).
    ///
    ///   ct_bind     = HMAC-SHA256("q-audion-ct-bind-v1", pqcCiphertext)    [32B]
    ///   ikm         = pqcSs(32) || x25519Ss(32)                            [64B]
    ///   salt        = psk        if (psk != nil && !psk.isEmpty)
    ///                 else "q-audion-hybrid-pqc-v1"                        [22B]
    ///   selected_fp = SHA-256(psk) if (psk != nil && !psk.isEmpty)
    ///                 else 32×0x00                                          [32B]
    ///   info        = sessionInfoV4(ctBind, selectedFp, keyClass, negDigest)[117B]
    ///   key         = HKDF-SHA256(ikm, salt, info, 32)
    ///
    /// `internal` so `SessionV4KatTests` can exercise it via `@testable import`.
    static func deriveHybridSessionKeyV4(
        pqcSs: Data,
        x25519Ss: Data,
        pqcCiphertext: Data,
        psk: Data?,
        selectedFp: Data,
        keyClass: UInt8,
        negDigest: Data
    ) -> Data {
        let ctBind = Data(
            HMAC<SHA256>.authenticationCode(
                for: pqcCiphertext,
                using: SymmetricKey(data: HkdfLabels.hybridCtBindV1)
            )
        )

        var ikm = Data(capacity: 64)
        ikm.append(pqcSs)
        ikm.append(x25519Ss)

        let salt: Data
        if let psk = psk, !psk.isEmpty {
            salt = psk
        } else {
            salt = HkdfLabels.hybridPqcSaltV1
        }

        let info = sessionInfoV4(
            ctBind: ctBind,
            selectedFp: selectedFp,
            keyClass: keyClass,
            negDigest: negDigest
        )

        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// `vkey-v1` — derive the dedicated 32-byte earbud-video key K_video.
    ///
    /// Byte-identical to Android `deriveVideoKey` and the Desktop port.
    /// Pinned by `PhoneVideoKeyKatTests` against the frozen KAT vectors.
    /// Spec (frozen, android-crypto + gemini-verified):
    ///
    ///   transcriptHash = SHA-256( agreedTags.distinct().sorted()
    ///                              .joined(",") as UTF-8 )             [32B]
    ///   IKM            = sessionKey (32-byte post-PSK-mix session key)
    ///   salt           = psk(32)        if (psk != nil && !psk.isEmpty)
    ///                    else UTF8("Q-AUDION-PHONE-VIDEO-SALT-V1")     [28B]
    ///   info           = UTF8("Q-AUDION-PHONE-VIDEO-V1")(23)
    ///                    || transcriptHash(32)                        [55B]
    ///   K_video        = HKDF-SHA256(IKM, salt, info, 32)
    ///
    /// `agreedTags` is the negotiated capability intersection
    /// (`CallCapabilities.Negotiated.agreedTags`). It is re-normalised
    /// here (`Set` → `sorted`) so the transcript hash is independent of
    /// the caller's ordering — identical to Android
    /// `negotiatedTags.distinct().sorted()`.
    ///
    /// `internal` (not `private`) so `PhoneVideoKeyKatTests` can exercise
    /// the exact production path via `@testable import`.
    static func deriveVideoKey(
        sessionKey: Data,
        agreedTags: [String],
        psk: Data?
    ) -> Data {
        // transcriptHash = SHA-256( sorted-deduped-tags joined by "," ).
        let normalized = Array(Set(agreedTags)).sorted()
        let transcriptString = normalized.joined(separator: ",")
        let transcriptHash = Data(
            SHA256.hash(data: Data(transcriptString.utf8))
        )

        let salt: Data
        if let psk = psk, !psk.isEmpty {
            salt = psk
        } else {
            salt = HkdfLabels.phoneVideoSaltV1
        }

        var info = Data(capacity: HkdfLabels.phoneVideoV1.count + transcriptHash.count)
        info.append(HkdfLabels.phoneVideoV1)
        info.append(transcriptHash)

        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sessionKey),
            salt: salt,
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
        capabilityTimeoutWorkItem?.cancel()
        capabilityTimeoutWorkItem = nil
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
        localHybridKeysByCall.removeAll()
        // Phase-10b: clear the stashed sent-OFFER transcripts so a reused
        // integration does not leak a prior call's offer_binding into the next
        // call's ACCEPT verification.
        sentOfferTranscriptByCall.removeAll()
        // W-TRANSCRIPTV2 — same reasoning, v2 sibling.
        sentOfferTranscriptV2ByCall.removeAll()
        // W-KCMAC — same reasoning, the stashed sent-OFFER PSK advert list.
        sentOfferPskFingerprintsByCall.removeAll()
        // W-KCMACROLES — the parallel role list is stashed and cleared in lockstep
        // with the fingerprints above; a stale role array would mis-MAC the next call
        // exactly like a stale fingerprint array would.
        sentOfferPskRolesByCall.removeAll()
        // Phase B: drain any pending FPSET continuations with zeros so
        // awaiting tasks don't leak across call teardown.
        for (_, cont) in fpSetContinuationByCall {
            cont.resume(returning: Data(repeating: 0, count: 32))
        }
        fpSetContinuationByCall.removeAll()
        // W529 / W531: clear handshake retry state so the next call
        // starts with a fresh stash.
        lastSentOfferWire = nil
        lastSentAcceptWire = nil
        handshakeStartedAt = nil
        retrySenderClosure = nil
        lock.unlock()
        offerRetryTask?.cancel()
        offerRetryTask = nil
        onStateChanged?(.idle)
    }

    // MARK: - earbud-relay-v1 (HW firmware) counterparty install

    /// Install the session key produced by the earbud counterparty
    /// handshake (`EarbudHandshakeResponder.Step.done`) — the
    /// earbud-relay-v1 equivalent of the PQC OFFER/ACCEPT completion
    /// branches above.
    ///
    /// On an `earbud-relay-v1` call the peer phone NEVER runs the SW
    /// PqcHandshake (its key lives in the earbud firmware), so none of
    /// the opaque OFFER/ACCEPT paths fire: this method is the single
    /// completion site. It mirrors the JSON-responder branch
    /// byte-for-byte: AdaptivePadding audio scheme (the wire the
    /// firmware/Android relay speaks), `.active` transition, and the
    /// same key-established callbacks so SAS + K_video derivation reuse
    /// the existing app wiring. K_counter == K_spe (CRUX KAT), so
    /// `ComputeSasUseCase.invoke(sessionKey:)` yields the SAME 6 words
    /// the earbud side derives via `nsc_get_sas_entropy`.
    ///
    /// Idempotent per callId via `sessionInitializedByCall` (same dedup
    /// the OFFER paths use).
    public func completeEarbudCounterparty(callId: String, sessionKey: Data) throws {
        let normalized = callId.lowercased()
        let alreadyInit = lock.withLock { () -> Bool in
            let r = sessionInitializedByCall.contains(normalized)
            if !r { sessionInitializedByCall.insert(normalized) }
            return r
        }
        if alreadyInit {
            print("[QAudionCallIntegration] earbud counterparty: session already initialised for callId=\(callId.prefix(8))… — skipping")
            return
        }
        try engine.initialize()
        try engine.initSession(sharedSecret: sessionKey, adaptivePadding: true)
        onRelaySessionReady?(sessionKey, callId)
        lock.withLock { state = .active }
        offerRetryTask?.cancel()
        offerRetryTask = nil
        onStateChanged?(.active)
        onPqcSessionKeyEstablished?(sessionKey)
        // vkey-v1: K_counter is the IKM for the phone-level K_video on
        // sovereign-earbud calls (parallel handshake gating happens in
        // the app layer via the negotiated tags).
        onVideoKeyEstablished?(sessionKey)
        print("[QAudionCallIntegration] earbud counterparty COMPLETE for callId=\(callId.prefix(8))… — session active (CRUX K_counter installed)")
    }

    // MARK: - Phase B: FPSET signaling helpers

    /// Called by AppState when a `FPSET:` piggy-back arrives from the call peer.
    /// Resumes any pending `awaitFpSet` continuation on the handshake task.
    /// Thread-safe; safe to call from @MainActor or a Task.
    public func handleInboundFpSet(callId: String, fpAdv: Data) {
        let key = callId.lowercased()
        let cont: CheckedContinuation<Data, Never>? = lock.withLock {
            fpSetContinuationByCall.removeValue(forKey: key)
        }
        cont?.resume(returning: fpAdv)
    }

    /// Build and send the FPSET piggy-back for this call via `sendOpaqueRaw`.
    /// Fires-and-forgets; errors are logged and do not abort the handshake.
    private func sendFpSet(
        callId: String,
        fpAdv: Data,
        sendOpaqueRaw: @escaping (String) async throws -> Void
    ) {
        let wire = CallPiggyBack.serializeFpSet(callId: callId, fpAdv: fpAdv)
        Task {
            do { try await sendOpaqueRaw(wire) } catch { print("[QAudionCallIntegration] FPSET send failed (\(callId.prefix(8))…): \(error)") }
        }
    }

    /// Wait up to `timeoutSec` seconds for the remote FPSET to arrive.
    /// Returns the 32-byte remote fp_adv, or 32 zero bytes on timeout/error.
    ///
    /// Implementation: wraps a `CheckedContinuation` that `handleInboundFpSet`
    /// resumes when the FPSET piggy-back lands. A separate timeout Task resumes
    /// it with zeros after `timeoutSec` if the peer is silent. Because the
    /// continuation must be resumed EXACTLY ONCE, the first résumé (FPSET or
    /// timeout) atomically removes it from the dict — the second attempt finds
    /// nil and is a no-op.
    private func awaitFpSet(callId: String, timeoutSec: Double = 5.0) async -> Data {
        let zeros = Data(repeating: 0, count: 32)
        let key = callId.lowercased()

        return await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            // Arm the timeout BEFORE registering the continuation so there is
            // no window where both the timeout AND handleInboundFpSet try to
            // resume it: the first to remove from the dict wins.
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                guard let self = self else { return }
                let removed: CheckedContinuation<Data, Never>? = self.lock.withLock {
                    self.fpSetContinuationByCall.removeValue(forKey: key)
                }
                removed?.resume(returning: zeros)
            }

            // Register the continuation so handleInboundFpSet can find it.
            // If the FPSET already arrived (handleInboundFpSet was called
            // between the timeout arm and here), the dict insert races with
            // the FPSET removal.  In that edge case the FPSET wins (it ran
            // first and removed a nil, so it did nothing), and the timeout
            // will eventually fire and resume with zeros.  Acceptable: the
            // call survives with keyClass=0.
            lock.withLock {
                fpSetContinuationByCall[key] = cont
            }
            // Keep the timeout task alive — it is the only thing that will
            // resume the continuation when no FPSET arrives.
            _ = timeoutTask
        }
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

    // MARK: - W531: WS-reconnect handshake replay

    /// Re-emit the last unACKed handshake bundle if we're still in
    /// the handshake window. Idempotent at the wire level (caller
    /// re-sends same OFFER bytes, responder re-sends same ACCEPT
    /// bytes — both sides ignore dups). Called by AppState when
    /// BCryptoWS state transitions back to `.authenticated` during a
    /// call that's in `.capabilitySent` (caller) state OR has not yet
    /// reached `.active` (responder).
    public func replayPendingHandshake() async {
        let snapshot: (started: Date?, state: CallState, offer: String?, accept: String?, isCaller: Bool, sender: ((String) async throws -> Void)?) =
            lock.withLock {
                (handshakeStartedAt, state, lastSentOfferWire, lastSentAcceptWire, isCaller, retrySenderClosure)
            }
        guard let startedAt = snapshot.started else { return }
        guard Date().timeIntervalSince(startedAt) < handshakeTimeoutSec else { return }
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
