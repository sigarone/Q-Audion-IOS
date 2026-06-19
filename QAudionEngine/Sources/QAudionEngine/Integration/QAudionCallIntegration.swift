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
    private var sendOpaque: ((Data) async throws -> Void)?
    private var resolvedBcryptoUserId: String?
    private var bcryptoUserIdCache: [String: String] = [:]  // recipientId -> BCrypto userId
    /// Tracks whether this client is the caller (true) or responder (false) for the
    /// current call. Used to gate pre-negotiation event handling.
    private var isCaller: Bool = false

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
    /// Timestamp of the first OFFER/ACCEPT send for this call. Used to
    /// bound retries within the handshake window (default 30 s).
    private var handshakeStartedAt: Date?
    /// Captured caller-side sender closure so the W529 retry timer can
    /// re-emit without AppState plumbing each retry through.
    private var retrySenderClosure: ((String) async throws -> Void)?
    /// W529 retry task — fires at 5 s intervals up to handshakeTimeout.
    private var offerRetryTask: Task<Void, Never>?
    public let handshakeTimeoutSec: Double = 30.0
    public let offerRetryIntervalSec: UInt64 = 5
    /// Tracks whether the local UI/CallKit alert is already ringing for an
    /// incoming call. Lets `onCallRingReceived` (server "we told the caller you
    /// are ringing" ACK) fire a fallback ring only if setup was async-slow.
    private var isLocallyRinging: Bool = false

    public var onStateChanged: ((CallState) -> Void)?
    public var onDeepfakeAlert: ((ConfidenceIndex.Level, Float) -> Void)?

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
    public var resolveHwOnlyContact: ((String) -> (Bool, String?))? = nil

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
    /// shared `PeerIdentityPinStore.pinnedKey`.
    public var resolvePinnedPeerKey: ((String) -> Data?)?

    /// Resolve the SERVER/QR-fetched 32-byte Ed25519 key for a peer contactId,
    /// used as the trust source on first contact when no pin exists yet (spec
    /// §5c). Wired from `ContactsStore.findPubkey`.
    public var resolveServerPeerKey: ((String) -> Data?)?

    /// Commit a first-contact TOFU pin (contactId, 32-byte Ed25519 key) AFTER a
    /// signature verified under it (spec §2). Wired from
    /// `PeerIdentityPinStore.pinOrMatch`.
    public var commitTofuPin: ((String, Data) -> Void)?

    /// Has this peer ever had a SIGNED v4 bundle verify (spec §4
    /// `v4_capable_pinned`)? Wired from a UserDefaults-backed set in AppState.
    public var isPeerV4Pinned: ((String) -> Bool)?

    /// Mark this peer v4-capable-pinned (set the first time a signed v4 bundle
    /// verifies, BEFORE handshake completion, never cleared — spec §4).
    public var setPeerV4Pinned: ((String) -> Void)?

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

    public init() {
        guardianMode.onAlert = { [weak self] level, score in self?.onDeepfakeAlert?(level, score) }
        // Task #11 — head-start the ephemeral ML-KEM keypair off the
        // call-start critical path (the reused responder integration and
        // any caller integration created with lead time get it for free).
        prewarmKeyMaterial()
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
        let offerBundle = AndroidHandshakeBundle(
            kind: .offer,
            callId: callId,
            pqcPublicKey: pqcRawPub.base64EncodedString(),
            x25519PublicKey: x25519RawPub.base64EncodedString(),
            capabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true),
            pskFingerprints: SovereignKeyVault().listPskNames().compactMap {
                SovereignKeyVault().getFingerprint(name: $0)
            }
        )

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
            bundleToSend = signedCopy(of: offerBundle, transcript: offerT)
            // Only stash when the sig actually attached (signedCopy returns the
            // input unchanged on signer failure → don't claim a signed OFFER).
            if bundleToSend.signature != nil {
                lock.withLock { sentOfferTranscriptByCall[callId.lowercased()] = offerT }
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

        // 2. Ship the legacy QUAD binary OFFER for older iOS peers.
        //    Failure here is non-fatal for Android interop (the JSON
        //    already went out), so log and continue.
        let quadOffer = QAudionCapabilityExchange.createOffer(
            publicKey: pqcRawPub,
            pskFingerprints: []
        )
        do {
            try await sendOpaqueBinary(quadOffer)
        } catch {
            print("[QAudionCallIntegration] QUAD OFFER send failed (non-fatal — JSON OFFER already shipped): \(error)")
        }

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
                print("[QAudionCallIntegration] Android JSON OFFER 30s timeout — no ACCEPT for callId=\(callId.prefix(8))… stashedKeys=\(self.localHybridKeysByCall.keys.map { $0.prefix(8) }.joined(separator:","))")
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

            // Note: keyPair is generated implicitly inside encapsulate via
            // the embedded PQC stack — we don't need a local copy. (Was an
            // unused init from a refactor leftover.)
            let result = try pqc.encapsulate(remotePublicKey: remotePublicKey)
            try engine.initialize()
            try engine.initSession(sharedSecret: result.sharedSecret)
            onRelaySessionReady?(result.sharedSecret, stashedCallId ?? "")
            let accept = QAudionCapabilityExchange.createAccept(ciphertext: result.ciphertext, pskFingerprint: nil)
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
        eligiblePsks: [String: Data] = [:],
        sendOpaqueRaw: @escaping (String) async throws -> Void
    ) async throws {

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

            // Phase-10b (b) — VERIFY the incoming OFFER fail-closed BEFORE any
            // crypto work (`pqc.encapsulate`) or ACCEPT emission (spec §4). When
            // verification is not wired we skip entirely (legacy behaviour). The
            // peer is `callerId`. `.abort` THROWS here → no ACCEPT is ever sent,
            // no session is derived. `.authenticated` commits the TOFU pin / v4
            // flag BEFORE completion and yields the offer_binding the ACCEPT must
            // carry (spec §3). `.proceedUnsignedWarn` logs and continues with an
            // EMPTY binding (legacy/unsigned-peer migration path).
            var verifiedOfferBinding = Data()  // empty == "no signed offer to bind"
            if verificationEnabled {
                let verdict = evaluateVerdict(bundle: bundle, peerId: callerId) { key in
                    Self.offerTranscript(from: bundle, callId: callId, signerKeyRaw: key)
                }
                switch verdict {
                case .abort(let code):
                    print("[QAudionCallIntegration] OFFER verify ABORT code=\(code) peer=\(callerId.prefix(8))… callId=\(callId.prefix(8))… — dropping, no ACCEPT emitted")
                    throw IntegrationError.handshakeAborted(code: code)
                case .authenticated(let tofuPinKey, let v4Capable):
                    applyAuthenticatedSideEffects(peerId: callerId, tofuPinKey: tofuPinKey, v4Capable: v4Capable)
                    // The signed OFFER's binding the ACCEPT will carry. Rebuilt
                    // under the trusted key (= the bundle's signerIdentityKey,
                    // which the verdict already confirmed == pinned/server key).
                    if let sikB64 = bundle.signerIdentityKey, let trustedKey = Data(base64Encoded: sikB64),
                       let offerT = Self.offerTranscript(from: bundle, callId: callId, signerKeyRaw: trustedKey) {
                        verifiedOfferBinding = HandshakeTranscript.offerBinding(offerT)
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
            var selectedFp: String? = nil
            var selectedPsk: Data? = nil
            if let advertised = bundle.pskFingerprints {
                if let first = advertised.first(where: { eligiblePsks[$0] != nil }) {
                    selectedFp = first
                    selectedPsk = eligiblePsks[first]
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
                var ownFpAdv: Data? = nil
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
                capabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true),
                selectedPskFingerprint: selectedFp
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
            if signingEnabled, let idKey = localSignerIdentityKey,
               let acceptT = Self.acceptTranscript(from: accept, callId: callId, signerKeyRaw: idKey, offerBinding: verifiedOfferBinding) {
                acceptToSend = signedCopy(of: accept, transcript: acceptT)
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
            // vkey-v1: JSON responder — `combined` is the post-PSK-mix
            // session key and the IKM for K_video.
            onVideoKeyEstablished?(combined)

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
            // paired with a forged OFFER (spec §3 / threat §7). `.abort` LOGS and
            // RETURNS WITHOUT initSession (no session is installed for an aborted
            // handshake). `.authenticated` commits the pin / v4 flag, then falls
            // through to the existing decapsulate + initSession.
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
                let verdict = evaluateVerdict(bundle: bundle, peerId: callerId) { key in
                    Self.acceptTranscript(from: bundle, callId: callId, signerKeyRaw: key, offerBinding: expectedBinding)
                }
                switch verdict {
                case .abort(let code):
                    print("[QAudionCallIntegration] ACCEPT verify ABORT code=\(code) peer=\(callerId.prefix(8))… callId=\(callId.prefix(8))… — NOT initialising session")
                    return
                case .authenticated(let tofuPinKey, let v4Capable):
                    applyAuthenticatedSideEffects(peerId: callerId, tofuPinKey: tofuPinKey, v4Capable: v4Capable)
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
                var ownFpAdv: Data? = nil
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
                let vault = SovereignKeyVault()
                let vaultPsk: Data? = {
                    guard let name = vault.listPskNames().first(where: {
                        vault.getFingerprint(name: $0) == selectedFpStr
                    }) else { return nil }
                    return (try? vault.loadPsk(name: name)) ?? nil
                }()
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
                combined = Self.deriveHybridSessionKey(
                    pqcSs: pqcSs,
                    x25519Ss: x25519Ss,
                    pqcCiphertext: pqcCt,
                    psk: nil
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
            // vkey-v1: JSON caller — `combined` is the IKM for K_video.
            onVideoKeyEstablished?(combined)
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
    ) -> (ratchetV3: Bool, sframeV1: Bool, vkeyV1: Bool) {
        return (
            ratchetV3: caps?.ratchetV3 ?? false,
            sframeV1: caps?.sframeV1 ?? false,
            vkeyV1: caps?.vkeyV1 ?? false
        )
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
            ratchetV: HandshakeSigningPolicy.ratchetV,
            suiteId: HandshakeSigningPolicy.suiteId,
            pskFingerprints: bundle.pskFingerprints
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
            ratchetV: HandshakeSigningPolicy.ratchetV,
            suiteId: HandshakeSigningPolicy.suiteId,
            selectedPskFingerprint: bundle.selectedPskFingerprint,
            offerBinding: offerBinding
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
        return resolvePinnedPeerKey != nil || resolveServerPeerKey != nil
    }

    /// Attach `signerIdentityKey` + `signature` to a bundle by signing `transcript`.
    /// Returns the ORIGINAL bundle unchanged on any failure (degrade to unsigned)
    /// so signing can never break a call. No-op (returns input) when signing is
    /// not wired.
    private func signedCopy(of bundle: AndroidHandshakeBundle, transcript: Data) -> AndroidHandshakeBundle {
        guard let idKey = localSignerIdentityKey, let sign = signTranscript,
              let sig = sign(transcript), sig.count == 64 else {
            return bundle
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
            signerIdentityKey: idKey.base64EncodedString(),
            signature: sig.base64EncodedString()
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
        transcriptFor: (Data) -> Data?
    ) -> HandshakeSigningPolicy.Verdict {
        let pinned = resolvePinnedPeerKey?(peerId)
        let server = resolveServerPeerKey?(peerId)
        // Pick the trusted key the same way the policy will, so the transcript
        // we hand the policy is built under that exact key (the policy verifies
        // against the trusted key, never the bundle key). On genuine first
        // contact (no pin, no server) the bundle's own key is the TOFU candidate.
        let trustedKey: Data
        if let p = pinned {
            trustedKey = p
        } else if let s = server {
            trustedKey = s
        } else if let sikB64 = bundle.signerIdentityKey, let bk = Data(base64Encoded: sikB64) {
            trustedKey = bk
        } else {
            // No signature/identity at all → policy will hit the ABSENT branch;
            // the transcript bytes are irrelevant there. Use empty so a
            // present-but-unparseable case still flows to `sig_malformed`.
            trustedKey = Data()
        }
        let transcript = transcriptFor(trustedKey) ?? Data()
        let advertisedV4 = (HandshakeSigningPolicy.ratchetV >= 0x04)
            && (HandshakeSigningPolicy.suiteId == 0x01)
        return HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: bundle.signerIdentityKey,
            signatureB64: bundle.signature,
            transcript: transcript,
            pinnedKey: pinned,
            serverFetchedKey: server,
            requireSigned: requireSigned(forPeer: peerId),
            advertisedV4: advertisedV4
        )
    }

    /// Commit the side effects of a `.authenticated` verdict (spec §2 / §4):
    /// first-contact TOFU pin, then v4-capable-pin — BOTH before the handshake
    /// completes. Pure side-effect; safe to call when closures are nil.
    private func applyAuthenticatedSideEffects(
        peerId: String,
        tofuPinKey: Data?,
        v4Capable: Bool
    ) {
        if let pinKey = tofuPinKey {
            commitTofuPin?(peerId, pinKey)
        }
        if v4Capable {
            setPeerV4Pinned?(peerId)
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
        voiceAnalysis.processFrame(pcmFrame)
        return try engine.processOutgoingAudio(pcmFrame: pcmFrame)
    }

    public func processIncomingAudio(serializedFrame: Data) throws -> Data {
        let pcm = try engine.processIncomingAudio(serializedFrame: serializedFrame)
        guardianMode.processFrame(pcm)
        return pcm
    }

    public func onCallEnded() {
        engine.destroySession()
        engine.release()
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
            do { try await sendOpaqueRaw(wire) }
            catch { print("[QAudionCallIntegration] FPSET send failed (\(callId.prefix(8))…): \(error)") }
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
}

public enum IntegrationError: Error {
    case invalidState(QAudionCallIntegration.CallState)
    /// Phase-10b fail-closed handshake abort (spec §4). `code` is one of
    /// `sig_invalid`, `identity_key_mismatch`, `sig_required_missing`,
    /// `sig_malformed`. Thrown BEFORE any session-key derivation / `initSession`,
    /// so an aborted handshake never installs a session.
    case handshakeAborted(code: String)
}
