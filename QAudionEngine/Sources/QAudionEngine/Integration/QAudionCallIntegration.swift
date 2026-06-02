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

    // ─── Answer-gated responder commit ──────────────────────────────────────
    /// True once the LOCAL user pressed answer (green button / CallKit accept).
    /// The responder still pre-computes the ML-KEM hybrid secret on OFFER
    /// receipt (during ringing — keeps zero-ring-delay), but DEFERS the side
    /// effects that the peer observes — sending the ACCEPT (which makes the
    /// caller's SAS appear), opening the audio session, and firing the local
    /// SAS — until this flag flips. Set by [commitLocalAnswer].
    private var localAnswerAccepted = false
    /// Buffered responder ACCEPT, prepared on OFFER receipt but held until the
    /// user answers. (acceptWire = serialized ACCEPT envelope; combined = the
    /// post-PSK-mix hybrid session key already derived.)
    private var bufferedResponderAccept: (wire: String, combined: Data)?
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
            pskFingerprints: []  // iOS has no SovereignKeyVault yet (see WIRE_SPEC §5)
        )
        let jsonWire = AndroidHandshakeEnvelope.serialize(callId: callId, bundle: offerBundle)

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
        eligiblePsks: [String: Data] = [:],
        sendOpaqueRaw: @escaping (String) async throws -> Void
    ) async throws {

        switch bundle.kind {
        case .offer:
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

            // 5. Corrected single ct-bound derivation (schema :2). The
            // ML-KEM ciphertext (pqcResult.ciphertext) is bound via the
            // HKDF info; the negotiated PSK (if any) is the HKDF salt.
            // Byte-identical to Android / iOS / Desktop / firmware.
            let combined = Self.deriveHybridSessionKey(
                pqcSs: pqcResult.sharedSecret,
                x25519Ss: x25519Result.sharedSecret,
                pqcCiphertext: pqcResult.ciphertext,
                psk: selectedPsk
            )

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
            let wire = AndroidHandshakeEnvelope.serialize(callId: callId, bundle: accept)

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
                // ANSWER GATE: only replay the ACCEPT to the caller if we have
                // actually answered. A duplicate OFFER arriving while we are
                // still ringing must NOT leak the ACCEPT (which would surface
                // the SAS on the caller before we pressed answer) — the bundle
                // stays buffered and goes out via commitLocalAnswer().
                let answered = lock.withLock { localAnswerAccepted }
                if answered, let cached = lock.withLock({ lastSentAcceptWire }) {
                    print("[QAudionCallIntegration] OFFER duplicate for callId=\(callId.prefix(8))… (answered) — replaying cached ACCEPT")
                    try await sendOpaqueRaw(cached)
                } else {
                    print("[QAudionCallIntegration] OFFER duplicate for callId=\(callId.prefix(8))… — \(answered ? "session already initialised" : "still ringing, ACCEPT stays buffered")")
                }
                return
            }
            // ANSWER GATE — the ML-KEM hybrid secret (`combined`) and the
            // ACCEPT `wire` are now ready (the expensive crypto ran during
            // ringing, preserving zero-ring-delay). But we MUST NOT make the
            // call "happen" before the local user actually answers:
            //   • sending the ACCEPT is what completes the CALLER's handshake
            //     and makes their SAS appear → the caller would see the call
            //     "encrypted/answered" before we pressed the green button.
            //   • initSession opens the audio channel.
            //   • onPqcSessionKeyEstablished fires OUR SAS.
            // So if the user hasn't answered yet, buffer everything and return.
            // [commitLocalAnswer] flushes the buffer the instant they answer —
            // the send is then immediate because the crypto is already done.
            let answeredAlready = lock.withLock { localAnswerAccepted }
            if !answeredAlready {
                lock.withLock { bufferedResponderAccept = (wire, combined) }
                print("[QAudionCallIntegration] OFFER processed for callId=\(callId.prefix(8))… — ACCEPT buffered, awaiting local answer (caller will NOT see SAS until then)")
                return
            }
            try await commitResponderHandshake(wire: wire, combined: combined)

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

            // 3. Corrected single ct-bound derivation (schema :2) —
            //    byte-equal with the responder's deriveHybridSessionKey
            //    and Android / Desktop / firmware. The ML-KEM ciphertext
            //    we just decapsulated (pqcCt) is bound via the HKDF info.

            // 4. iOS originator can't materialise the local PSK material
            //    yet (no SovereignKeyVault on iOS — WIRE_SPEC §5 P1). When
            //    the vault lands, look up selectedPskFingerprint and pass
            //    it as `psk:` below (it becomes the HKDF salt). For now a
            //    non-nil selectedPskFingerprint is a diagnostic warning:
            //    the peer mixed a PSK we can't reproduce, so keys diverge.
            if let selected = bundle.selectedPskFingerprint, !selected.isEmpty {
                print("[QAudionCallIntegration] ACCEPT carried selectedPskFingerprint=\(selected.prefix(16))… but iOS originator has no PSK — deriving without it (will diverge from peer)")
            }
            let combined = Self.deriveHybridSessionKey(
                pqcSs: pqcSs,
                x25519Ss: x25519Ss,
                pqcCiphertext: pqcCt,
                psk: nil
            )

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
        guardianMode.processFrame(pcmFrame)
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
        // W529 / W531: clear handshake retry state so the next call
        // starts with a fresh stash.
        lastSentOfferWire = nil
        lastSentAcceptWire = nil
        handshakeStartedAt = nil
        retrySenderClosure = nil
        // Answer-gate: a reused integration must start the next call un-answered
        // with no stale buffered ACCEPT.
        localAnswerAccepted = false
        bufferedResponderAccept = nil
        lock.unlock()
        offerRetryTask?.cancel()
        offerRetryTask = nil
        onStateChanged?(.idle)
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

    /// Responder side — the LOCAL user pressed answer (green button / CallKit
    /// CXAnswerCallAction). This is the single gate that lets the buffered
    /// handshake "go live": it sends the ACCEPT (caller's SAS appears now),
    /// opens the audio channel, and fires our SAS. If the OFFER hasn't arrived
    /// yet, we just record the answer; the `.offer` case then commits
    /// immediately when it lands. Idempotent.
    public func commitLocalAnswer() async {
        let buffered: (wire: String, combined: Data)? = lock.withLock {
            localAnswerAccepted = true
            let b = bufferedResponderAccept
            bufferedResponderAccept = nil
            return b
        }
        guard let b = buffered else {
            // OFFER not processed yet (fast answer) — the `.offer` case will
            // see localAnswerAccepted == true and commit inline. Or this is a
            // caller-side / no-op call; harmless.
            return
        }
        print("[QAudionCallIntegration] local answer — flushing buffered ACCEPT (handshake + audio + SAS go live now)")
        do {
            try await commitResponderHandshake(wire: b.wire, combined: b.combined)
        } catch {
            print("[QAudionCallIntegration] commitLocalAnswer: commit failed: \(error)")
        }
    }

    /// Send the responder ACCEPT, open the audio session and fire the SAS /
    /// video-key hooks. Factored out of the `.offer` case so it can run either
    /// inline (user already answered) or deferred (via [commitLocalAnswer]).
    private func commitResponderHandshake(wire: String, combined: Data) async throws {
        try await sendOpaqueRaw(wire)
        try engine.initialize()
        // W479 — Android peer: AdaptivePaddingController-compatible audio
        // scheme (static session key, no AAD, 2-byte len + 120B padding).
        try engine.initSession(sharedSecret: combined, adaptivePadding: true)
        lock.withLock { state = .active }
        // W529: handshake reached active — kill the retry loop.
        offerRetryTask?.cancel()
        offerRetryTask = nil
        onStateChanged?(.active)
        onPqcSessionKeyEstablished?(combined)
        // vkey-v1: `combined` is the post-PSK-mix session key + IKM for K_video.
        onVideoKeyEstablished?(combined)
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
}

public enum IntegrationError: Error { case invalidState(QAudionCallIntegration.CallState) }
