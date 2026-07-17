import Foundation
import AVFoundation  // AVAudioSession for speaker override
import CryptoKit     // W574l — one-way key fingerprint for seal-key diagnostics
import QAudionEngine

// Swift 6 — CallService coordinates its OWN concurrency (it is not @MainActor):
// the TX audio pipeline is serialised on the private `txAudioQueue`, decoded-RX
// diagnostic counters are touched on the capture/decode threads, and every
// UI-facing callback hops to the main actor via `Task { @MainActor in … }`.
// That manual, queue-based serialisation is exactly the contract `@unchecked
// Sendable` documents, and it lets the TX @Sendable dispatch closures capture
// `self` without the compiler flagging a false data race. No behaviour change.
final class CallService: @unchecked Sendable {
    var callIntegration: QAudionCallIntegration?
    var onDeepfakeAlert: ((Bool) -> Void)?
    var onDeepfakeScore: ((ConfidenceIndex.Level, Float) -> Void)?
    var onTxWaveformUpdate: (([Float]) -> Void)?
    var onRxWaveformUpdate: (([Float]) -> Void)?
    var onCipherWaveformUpdate: (([Float]) -> Void)?
    /// Unified call UI — Guardian ribbon voice biometrics (pitch/stress/
    /// health/speech-rate/confidence). Wired 1:1 alongside onDeepfakeAlert/
    /// onDeepfakeScore below, on BOTH integration binding sites (`startCall`
    /// outgoing + `activateIncomingCallAudio` responder — the old
    /// outgoing-only asymmetry left gauges dead on every incoming call, fixed
    /// 2026-07-04). Gated on `EngineConfig.production().enableVoiceAnalysis`
    /// at the wiring call site (not here) — mirrors how `VoiceAnalysisEngine`
    /// itself gates processing via its own internal `enabled` flag.
    var onVoiceAnalysis: ((VoiceAnalysisResult) -> Void)?
    /// Unified call UI — REAL remote-voice spectrum: 40 log-spaced bands
    /// (0..1), ≤15 Hz (66 ms throttle at the source — see
    /// `QAudionCallIntegration.onVoiceSpectrum`). Wired alongside
    /// `onVoiceAnalysis` on BOTH the outgoing and incoming integration
    /// binding sites; AppState publishes it for the Guardian MiniSpectrum.
    var onVoiceSpectrum: (([Float]) -> Void)?

    /// W65+W66: Full audio capture + processing pipeline.
    ///
    /// W65 ha attivato `AVAudioSession.voiceChat` mode (HW AEC/NS/AGC
    /// system-wide). W66 chiude il loop client-side: AudioCapture
    /// instanziato con la pipeline così l'AVAudioEngine.inputNode è
    /// **attivamente** engaged con `setVoiceProcessingEnabled(true)`
    /// — il VP IO unit gira su DSP separato e processa ogni PCM frame
    /// PRIMA che arrivi al nostro tap.
    ///
    /// Flow per-frame:
    ///   1. mic → VP IO unit (HW AEC + NS + AGC) → tap callback
    ///   2. supplemental software spectral subtraction (pipeline)
    ///   3. processOutgoingAudio → integration encrypt → EncryptedFrame
    ///   4. (network send: scope ENGINE WT — `wsClient.sendAudioFrame`)
    ///
    /// AudioPlayback è anch'esso instanziato e pronto a receive PCM
    /// dall'incoming WS handler. Il binding network → playback è
    /// engine WT (richiede WS dispatch → processIncomingAudio →
    /// playback.playFrame).
    ///
    /// Conflitti potenziali con C-engine audio capture: il C-engine non
    /// risulta avere capture attivo iOS-side (CLAUDE.md "voice call
    /// quality cross-platform iOS↔Android, never tested"), quindi il
    /// path Swift è l'unico mic consumer attivo. Se future PR engine-side
    /// dovesse aggiungere C-level capture concorrente, va coordinato
    /// con un toggle qui per disable Swift capture.
    private var audioPipeline: AudioProcessingPipeline?
    private var audioCapture: AudioCapture?
    private var audioPlayback: AudioPlayback?

    // XP-crackle — `AudioCapture`'s input tap runs on a dedicated real-time
    // Core Audio thread; Apple's guidance (and every other platform's own
    // fix for the identical symptom — Android's CallAudioBridge txChannel,
    // Desktop's off-thread encode) is that ANY allocation, lock, or I/O on
    // that thread risks missed render deadlines, which is exactly what
    // audible crackling sounds like. `processAndSendEncryptedFrame` used to
    // run synchronously right there: Opus encode, TWO AEAD seals (engine +
    // relay), JSONSerialization, an NSLock, and a URLSessionWebSocketTask
    // hand-off — all on the tap thread. Hand off to this dedicated SERIAL
    // queue instead. Serial (not concurrent) matters: the ratchet chain
    // position is assigned in ENCRYPT-call order, so frames must still be
    // processed strictly one-at-a-time in the order they were captured —
    // GCD serial queues execute `.async` blocks in FIFO submission order,
    // and Core Audio only ever calls the tap callback from one thread at a
    // time, so submission order already equals capture order.
    private let txAudioQueue = DispatchQueue(
        label: "com.bcrypto.qaudion.call.tx-audio-encode", qos: .userInitiated)

    /// W66: contatori di frame per diagnosi (esposti via Settings →
    /// Diagnostica). framesEncrypted incrementa ogni volta che un PCM
    /// dal mic completa il roundtrip processOutgoingAudio. framesPlayed
    /// incrementa quando un PCM decrypted entra in AudioPlayback.
    public private(set) var framesEncryptedTx: Int64 = 0
    public private(set) var framesDecryptedRx: Int64 = 0

    // MARK: - W466 — audio-pipeline diagnostics
    //
    // The user reported "call connects but no voice/video" and asked for
    // instrumentation to tell whether the break is in CAPTURE, ENCRYPT,
    // NETWORK, DECRYPT or PLAYBACK. The frame loop runs ~50x/sec, so the
    // logging is rate-limited: a one-shot marker for the FIRST occurrence
    // of each milestone, plus a periodic heartbeat every 250 frames
    // (~5 s). The previously-silent encrypt catch is now surfaced too —
    // it used to hide every Opus/AEAD failure.
    private var framesReceivedRx: Int64 = 0   // audio_frame envelopes off the WS, pre-decrypt
    private var txEncryptErrorCount: Int64 = 0
    private var rxDecryptErrorCount: Int64 = 0
    // W-TXGATE (2026-07-12) — the mic starts capturing the instant the call UI
    // appears, but the PQC session key isn't derived until the handshake
    // completes (~0.8 s later). Every mic frame in that window used to hit
    // `processOutgoingAudio` and throw QAudionEngineError.error3 (no session),
    // inflating tx_enc_err with EXPECTED pre-handshake drops that are
    // indistinguishable from a real post-handshake crypto failure (the
    // tune-report card flagged 40 such "errors" on a healthy call). Gate the
    // encrypt on session-ready: pre-handshake frames are dropped cleanly into a
    // SEPARATE counter, so tx_enc_err counts ONLY real failures.
    private var txSessionReady = false
    private var txPreHandshakeDropped: Int64 = 0
    // AUDIO-DIAG (2026-07-12) — decoded RX audio level accumulators, mirror of
    // Android MediaPathDiag.recordRxLevel (rx_peak_pct/rx_rms_pct). Touched only
    // on the RX decode branch (same lock-free discipline as framesDecryptedRx),
    // read+reset in teardownAudioStack. peak = max |sample|, rms = sqrt(Σs²/n),
    // both reported as % of 16-bit full scale in the call.audio.diag summary.
    private var rxLevelPeak: Float = 0        // running max |sample|, normalized [0,1]
    private var rxLevelSumSq: Double = 0      // Σ(sample²) over the whole call
    private var rxLevelSampleCount: Int64 = 0 // n, for the RMS denominator
    // Bug B diagnostics — did the playback/capture AVAudioEngines actually
    // start (true only after startAudioIOIfReady ran with an active session),
    // and did the didActivate-fallback have to fire (CallKit skipped its own
    // didActivate). Emitted in the call.audio.counts summary on teardown.
    private var audioEnginesStarted = false
    private var didActivateFallbackFired = false
    // Frames dropped because their call_id didn't match the active session.
    // Batched relay delivery from a previous/overlapping session causes x250+
    // AEAD failures (CryptoKitError 3) without this filter.
    private var rxStaleDropCount: Int64 = 0
    private var loggedFirstTxCapture = false
    private var loggedFirstTxEncrypt = false
    private var loggedTxNoTransport = false
    private var loggedFirstRxReceive = false
    private var loggedRxNoIntegration = false
    private var loggedFirstRxDecrypt = false
    private var loggedRxNoPlayback = false
    private var loggedFirstStaleDrop = false

    // W481 — pre-bind RX frame buffer.
    // The PQC handshake and callIntegration binding are async; audio frames
    // from the peer can arrive in the 200-600 ms window before binding
    // completes. Silently dropping them advances the peer's TX ratchet
    // WITHOUT advancing our RX ratchet, causing a permanent off-by-one
    // that makes every subsequent decrypt fail (CryptoKitError error 3).
    // We buffer up to kRxPreBufferCap frames and drain them immediately
    // after callIntegration is set. Cap = 20 ≈ 400 ms at 20 ms/frame.
    private var rxPreBuffer: [Data] = []
    private static let rxPreBufferCap = 20

    // MARK: - W469 — cross-platform audio wire format
    //
    // The engine's `processOutgoingAudio` always serialises the
    // iOS-native `FrameEncoder` container. Android peers on the
    // BcryptoWsRelay can only decode the compact `WireRelayFrameCodec`
    // audio envelope — telemetry of an iPad↔A50 call showed the iPad
    // rejecting 2250+ Android frames at header parsing. The toggle
    // mirrors the video path's UserDefault (default ON → cross-platform).
    private var loggedFirstTxWire = false
    private lazy var androidAudioWireCompat: Bool =
        (UserDefaults.standard.object(
            forKey: "qaudion.video.android_wire_compat") as? Bool) ?? true

    /// W67: WebSocket transport binding. Quando setato via
    /// `wireTransport(wsClient:peerUserId:)`, il loop chiude:
    ///   TX: capture.onFrame → encrypt → wsClient.sendAudioFrame
    ///   RX: wsClient handler "audio_frame" → handleIncomingEncryptedFrame
    /// Quando nil, le encrypted bytes restano locali (counter only).
    private var wsClient: BCryptoWebSocketClient?
    private var peerUserId: String?
    /// W476 — lazy fallback providers. Wired ONCE by AppState at login.
    /// `wireTransport(wsClient:peerUserId:)` is supposed to bind the two
    /// fields above at call setup, but both call sites in AppState gate
    /// the binding on `if let ws = liveProvider?.getWebSocketClient()` —
    /// when `liveProvider` is nil at that exact moment (or for a callee
    /// whose answer path never ran `startIncomingCallAudioOnAnswer`) the
    /// binding is silently SKIPPED, and every encrypted TX frame after
    /// that is dropped on the floor: capture+encrypt run normally
    /// (waveforms visibly move) but the server logs zero
    /// `audio relay from=<us>` and the peer hears nothing. These
    /// closures let `processAndSendEncryptedFrame` recover at TX time by
    /// fetching the live WS + current peer id directly. They follow the
    /// CLAUDE.md §16 pattern (no AppState param — closures capture only
    /// what they need, weakly).
    // Best-effort getters: read non-isolated because the TX path runs on
    // txAudioQueue (a dedicated background queue — XP-crackle moved it off
    // the AVFAudio tap thread, but it's still not main). AppState only sets
    // `liveProvider` and `callContactId` from main, but a stale read across
    // threads is acceptable for this fallback (worst case: drops the very
    // first frame and binds on the second). They MUST stay nullary `() -> ...`.
    public typealias WsClientProvider = () -> BCryptoWebSocketClient?
    public typealias PeerIdProvider = () -> String?
    /// Returns true iff the call is in an active/encrypted state — used
    /// by the W469 fallback timer to skip self-activation during outgoing
    /// ring (before the peer has answered). Wired by AppState at login.
    public typealias CallActiveProvider = () -> Bool
    /// W525 — Returns the wire-format call_id of the currently active
    /// call (lowercase UUID for outgoing, server-supplied callIdStr
    /// for incoming). Required on every `audio_frame` envelope so
    /// Android + Desktop peers accept the frame instead of dropping
    /// it for missing/mismatched call_id. Wired by AppState at login.
    public typealias CallIdProvider = () -> String?
    public var getWsClient: WsClientProvider?
    public var getPeerId: PeerIdProvider?
    public var isCallActive: CallActiveProvider?
    public var getCallId: CallIdProvider?
    /// W-GRPVPIO-CRASH-3 (2026-07-17) — returns true while a GROUP call owns
    /// the shared VoiceProcessingIO hardware unit (LiveKit's SFU room drives
    /// it directly). Injected by AppState (`{ groupCallKitId != nil }`).
    /// Every 1:1 audio-engine START path guards on this so NO caller — any
    /// WS message handler, CallKit callback, or stale redelivered signaling —
    /// can call `setVoiceProcessingEnabled(true)` on a SECOND engine while
    /// LiveKit already holds the unit: that throws an uncatchable ObjC
    /// NSException inside AVAudioEngineGraph::_Connect (EXC_CRASH/SIGABRT,
    /// crashPointId B4lMk7amGdH7pnGoa5qsYT — repro'd 5+ times today via the
    /// App Store Connect crash portal, always "crash after answering" a
    /// group call). The earlier fix gated ONLY the `call_answer` WS handler;
    /// the crash log's Last Exception Backtrace (still
    /// NSURLSessionWebSocketTask.receive → app → setVoiceProcessingEnabled)
    /// proved another WS message path reaches it. Guarding at the engine
    /// entry points here is defense-in-depth: it closes every path at once
    /// rather than playing whack-a-mole with individual message handlers.
    public var isGroupCallActive: (() -> Bool)?
    /// W-DCAUDIO — send a sealed audio frame over the WebRTC DataChannel if it is
    /// open; returns true if queued there, false to fall back to the WS relay.
    /// Wired by AppState to `QAudionWebRtcCallController.sendAudioFrameData`. The
    /// payload is the raw WireRelayFrameCodec envelope (same bytes as the WS path).
    public var sendAudioOverDataChannel: ((Data) -> Bool)?
    /// Token usato per de-registrare il handler "audio_frame" su endCall
    /// — assumiamo che `registerHandler` sostituisca il precedente per
    /// type, quindi de-register è no-op (ma resettiamo wsClient così
    /// future incoming frames non triggherano playback senza session).

    /// W464 — true once CallKit has activated the shared AVAudioSession.
    /// `AVAudioEngine.start()` (inside AudioCapture/AudioPlayback) REQUIRES
    /// an active session; starting it before CallKit's `didActivate`
    /// throws "Session activation failed" and the call ends up with NO
    /// audio in either direction even though WebRTC + the PQC handshake
    /// succeed. We therefore create the capture/playback objects in
    /// `startCall` / `activateIncomingCallAudio` but DEFER their
    /// `.start()` until `handleAudioSessionActivated()` fires.
    private var audioSessionActive = false

    /// W574b — true once the remote peer has formally answered
    /// (`call_answer` received, for outgoing calls) or once WE answered
    /// (incoming calls — set in `activateIncomingCallAudio`). Gates the
    /// mic start INDEPENDENTLY of `AppState.callState`: the outgoing flow
    /// sets `.active` right after the OFFER is sent (long before the peer
    /// answers), so the v1.0.618 `isCallActive?()` check never blocked
    /// anything — verified in the 655de1d9 device log (mic at +1.6s,
    /// call_answer at +5.9s).
    private var peerAnswered = false

    // MARK: - W574e — M-15 BcryptoWsRelay frame sealing (Android interop)

    /// PQC RTP frame sealers for the WS-relay audio path. Android's
    /// `BcryptoWsFrameRelayTransport` wraps EVERY relay audio frame in an
    /// AES-GCM seal (nonce12||ct||tag16, HKDF key from the PQC session key
    /// + callId, per-frame counter nonce, 64-frame anti-replay) ON TOP of
    /// the AdaptivePadding+WireRelayFrameCodec frame — UNCONDITIONALLY. iOS
    /// shipped the byte-identical `PqcRtpFrameSealer` (KAT-matched) but
    /// never wired it into this path (only into WebRTC SRTP), so every
    /// Android→iOS relay frame failed AEAD decode (100% rx_dec_err, calls
    /// 8bfdbad1/427e5027). These two sealers (independent counters via
    /// makeSibling — M-13) restore the layer. nil until the session key is
    /// known → pre-handshake frames pass through, matching Android's
    /// `pqcSend?.seal(payload) ?: payload`.
    private var relaySealerSend: PqcRtpFrameSealer?
    private var relaySealerRecv: PqcRtpFrameSealer?

    /// W574h — the (lowercased) callId the current relay sealers are bound to.
    /// The M-15 seal key is `HKDF(pqcSessionKey, info="…:<callId>")`, so the
    /// sealer is only valid for ONE call. Tracking the bound callId lets the
    /// installer re-key when the active call changes (call glare / retry leave
    /// more than one callId in flight) instead of staying locked to a dead
    /// call's key — the v1.0.624→632 "connected but silent both ways" bug.
    private var relaySealerCallId: String?

    /// W574l — fingerprint (8 hex of SHA-256) of the session key the current
    /// sealers were built from. The call handshake fires `onRelaySessionReady`
    /// from MULTIPLE sites with DIFFERENT key material (QUAD raw ML-KEM
    /// `sharedSecret` vs JSON dual-hybrid `combined`); the old per-callId
    /// idempotency locked the sealer to whichever fired FIRST, so if a
    /// contact-key-exchange `sharedSecret` install beat the real audio
    /// `combined` key, the seal was keyed wrong while the audio engine used
    /// `combined` → 100% M-15 unseal failure even on a clean same-callId call.
    /// Tracking the key fingerprint lets the installer re-key when the KEY
    /// changes for the same call (last-write-wins on key); logging it lets the
    /// two peers' seal keys be compared across devices.
    private var relaySealerKeyFp: String?

    /// W-SLOTLOCK (2026-07-12) — serialises the mutable reference-typed relay
    /// slots that are touched from MULTIPLE threads: the TX audio tap
    /// (txAudioQueue) reads `wsClient`/`peerUserId`/`relaySealerSend` per frame;
    /// the RX decode path reads `relaySealerRecv`; `installRelaySealers` (fires
    /// from several handshake sites), `wireTransport`, `answer()` and
    /// `teardownAudioStack()` write them from the call-lifecycle thread. Without
    /// a barrier the release-old/retain-new ARC write of a reference slot races
    /// a concurrent read → torn refcount → use-after-free that detonates later
    /// (EXC_CRASH/SIGTRAP) at an innocent site. CallService is @unchecked
    /// Sendable precisely so it can own this synchronisation. Contract: hold the
    /// lock ONLY to copy the reference in/out — never across seal/open/network or
    /// any call that might re-enter (NSLock is non-recursive).
    private let relaySlotLock = NSLock()

    /// One-way 8-hex fingerprint of a key — safe to log (does NOT reveal key
    /// bytes). Used only to compare seal keys across the two peers' logs.
    private static func sealKeyFingerprint(_ key: Data) -> String {
        let digest = SHA256.hash(data: key)
        var hex = ""
        for b in digest.prefix(4) {
            let s = String(b, radix: 16)
            hex += (s.count == 1 ? "0" + s : s)
        }
        return hex
    }

    /// Build the WS-relay sealers from the established PQC session key and
    /// the wire call_id. MUST use the lowercase wire call_id (same string
    /// Android feeds `PqcRtpFrameSealer.create`) or the HKDF info diverges
    /// and interop fails.
    ///
    /// W574h — the sealer MUST track the ACTIVE call. The M-15 seal key is
    /// `HKDF(pqcSessionKey, info="q-audion-srtp-master-v1:<callId>")`, so a
    /// sealer built for callId A can NEVER open/seal frames for callId B.
    /// Under call glare or retry there can be more than one callId in flight
    /// (e.g. a superseded outgoing call whose handshake completed first, then
    /// the call actually answered) — the old `guard relaySealerSend == nil`
    /// locked onto whichever fired first and silently skipped the live call,
    /// so the peer's frames failed 100% AEAD (M-15 unseal failed) in BOTH
    /// directions with NO fallback (W574d disabled SRTP audio). This installer
    /// now:
    ///   • IGNORES installs for a callId that isn't the active call
    ///     (`getActiveCallId()` is set by bindIncomingCallId /
    ///     sendCallOfferWithId BEFORE the handshake completes, so it is
    ///     authoritative here) — a dead call's late handshake can't clobber
    ///     the live sealer, and can't leave us keyed to a stale call;
    ///   • is IDEMPOTENT for the SAME call — re-firing must NOT rebuild,
    ///     because that would reset the AES-GCM send counter to 0 and risk
    ///     (key, nonce) reuse (catastrophic for confidentiality);
    ///   • RE-KEYS when the active call's id genuinely changes.
    /// Pure iOS-side logic — no wire-format / HKDF change, so Android, the
    /// firmware earbud counterparty, Desktop and the server are unaffected.
    public func installRelaySealers(sessionKey: Data, callId: String,
                                    srtpDirKeyV1: Bool = false, selfIsRoleA: Bool = false) {
        let cid = callId.lowercased()
        // Stale-call guard: only (re)key for the call media actually flows on.
        if let active = getCallId?()?.lowercased(), !active.isEmpty, active != cid {
            let a: String = String(cid.prefix(8))
            let b: String = String(active.prefix(8))
            let line: String = "[CallService] W574h: relay sealer install IGNORED for non-active callId=" + a + "… (active=" + b + "…)"
            print(line)
            return
        }
        // W574l — idempotent ONLY when the callId AND the key are both
        // unchanged (rebuilding with the same key would reset the AES-GCM
        // counter → (key,nonce) reuse). Re-key when the call's session key
        // changes: the handshake fires onRelaySessionReady from several sites
        // with different key material, and the seal MUST end up on the audio
        // session key the engine actually uses — last write wins. A new key
        // means a brand-new sealer with counter 0, which is safe (the key,
        // and therefore the whole nonce space, is new).
        let kfp: String = Self.sealKeyFingerprint(sessionKey)
        // W-SLOTLOCK — read the dedup slots under the lock (they are written from
        // the audio threads' lazy paths). Copy out; the crypto below runs unlocked.
        let (dedupSend, dedupCallId, dedupKeyFp): (PqcRtpFrameSealer?, String?, String?) =
            relaySlotLock.withLock { (relaySealerSend, relaySealerCallId, relaySealerKeyFp) }
        if dedupSend != nil, dedupCallId == cid, dedupKeyFp == kfp { return }
        let hadSealer: Bool = (dedupSend != nil)
        do {
            // W574x — directional per-direction keys when both peers negotiated
            // srtpDirKeyV1 (fixes bidirectional AES-GCM nonce reuse). Role A =
            // the lexicographically-smaller userId (computed by the caller, same
            // rule as Android/Desktop). Otherwise the legacy single-key sealer.
            let send: PqcRtpFrameSealer
            let recv: PqcRtpFrameSealer
            if srtpDirKeyV1 {
                let pair = try PqcRtpFrameSealer.createDirectional(
                    pqcSessionKey: sessionKey, callId: cid, selfIsRoleA: selfIsRoleA)
                send = pair.send
                recv = pair.recv
            } else {
                send = try PqcRtpFrameSealer(pqcSessionKey: sessionKey, callId: cid)
                recv = send.makeSibling()
            }
            relaySlotLock.withLock {
                relaySealerSend = send
                relaySealerRecv = recv
                relaySealerCallId = cid
                relaySealerKeyFp = kfp
            }
            let verb: String = hadSealer ? "re-keyed" : "installed"
            let p: String = String(cid.prefix(8))
            // W574x diag — mirror Android's "PQC_DIAG W574x ... dirKeys=.. roleA=.."
            // so an iOS↔Android call can be compared side-by-side: if iOS dirKeys
            // disagrees with the peer (one directional, one single) OR the role is
            // not opposite, the recv key can't open the peer's frames (M-15 unseal
            // failed/replay). keyfp is the MASTER sessionKey fp (pre-directional) —
            // if it differs across peers the handshake/callId diverged, not the role.
            let dirStr: String = srtpDirKeyV1 ? "true" : "false"
            let roleStr: String = selfIsRoleA ? "A" : "B"
            let line: String = "[CallService] PQC_DIAG W574x-iOS sealers " + verb + " callId=" + p + "… keyfp=" + kfp + " dirKeys=" + dirStr + " role=" + roleStr
            print(line)
        } catch {
            print("[CallService] W574e: relay sealer install failed: \(error) — relay runs unsealed (Android interop will fail)")
        }
    }

    // MARK: - Mute / Hold

    /// When true, processOutgoingAudio returns silent (zero-padded) ciphertext.
    /// Drives the user-facing mute toggle. CallKit's CXSetMutedCallAction
    /// flips this via AppState bridge.
    public private(set) var isMuted: Bool = false

    /// Set/cleared by the CallKit mute bridge. Must be called on the main thread.
    public func setMuted(_ muted: Bool) {
        self.isMuted = muted
    }

    /// When true, audio is paused. For now, hold == mute both directions plus
    /// pausing the duration timer (QAudionCallIntegration hold API is USER WT).
    public private(set) var isOnHold: Bool = false

    public func setOnHold(_ onHold: Bool) {
        self.isOnHold = onHold
        if onHold { stopDurationTimer() } else { startDurationTimer() }
    }

    // MARK: - Call duration tracking

    /// Wall-clock seconds since `startCall(...)` succeeded.
    public private(set) var callDurationSeconds: TimeInterval = 0
    public var onDurationTick: ((TimeInterval) -> Void)?

    private var durationTimer: Timer?
    private var callStartedAt: Date?

    private func startDurationTimer() {
        callStartedAt = callStartedAt ?? Date()
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let started = self.callStartedAt else { return }
            let dur = Date().timeIntervalSince(started)
            self.callDurationSeconds = dur
            self.onDurationTick?(dur)
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    func startCall(engine: QAudionEngine, contactId: String) throws {
        // W65: defensive cleanup se startCall è chiamato 2x senza endCall.
        teardownAudioStack()

        // W65: PRIMA cosa — configura AVAudioSession in `.voiceChat` mode
        // per attivare lo stack HW DSP di Apple (Voice Processing I/O).
        // Best-effort: se fallisce la chiamata continua comunque.
        // W406: read CallsGate so the user's AEC/NS/AGC choice
        // actually controls Apple's VP I/O unit. iOS bundles the three
        // effects into a single switch — when ALL three are off,
        // we explicitly disable VP I/O. Otherwise the previous
        // hardcoded `setVoiceProcessingEnabled(true)` behavior holds.
        let pipeline = AudioProcessingPipeline()
        pipeline.voiceProcessingOverride = CallsGate.anyVoiceProcessingEnabled
        do {
            try pipeline.configureForVoIP()
            self.audioPipeline = pipeline
        } catch {
            print("[CallService] AVAudioSession.voiceChat config failed: \(error.localizedDescription) — fallback a session default")
            // Even without successful session config, continue: pipeline can
            // still attempt VP enable on the engine inputNode below.
            self.audioPipeline = pipeline
        }

        // W66: instantiate audio capture + playback PRIMA dell'integration
        // così il VP IO unit è attivo sul mic capture loop.
        // Best-effort: errori catturati e loggati — la chiamata continua
        // anche se il capture / playback falliscono (es. simulator).
        let capture = AudioCapture(audioPipeline: pipeline)
        let playback = AudioPlayback()

        // Encrypt-on-mic-frame callback: ogni PCM dal mic passa attraverso
        // VP IO HW DSP, poi spectral subtraction, poi processOutgoingAudio
        // (Opus encode + AEAD encrypt). L'output `encrypted` è un
        // `EncryptedFrame` serializzato pronto per il transport WS — ma il
        // network sender (`BCryptoWebSocketClient.sendAudioFrame`) NON è
        // wirable da CallService senza injection del wsClient — è
        // ENGINE WT. Per ora i frame encryptati sono solo conteggiati
        // così l'utente vede via Diagnostica che il loop crypto sta girando.
        capture.onFrame = { [weak self] pcmFrame in
            guard let self = self,
                  let integration = self.callIntegration else { return }
            // W69: dev network simulator hook. In Off (default) il call
            // è branch-predicted off-path. In altri profili può
            // droppare o ritardare il frame.
            if !NetworkConditionSimulator.shared.isPassthrough() {
                if NetworkConditionSimulator.shared.shouldDropOutbound() {
                    return  // frame droppato — simula packet loss outbound
                }
                // Delay è async; isolated in a Task così non blocca il
                // tap callback. Per simulare HighLatency / Satellite il
                // peer riceve il frame con il delay configurato.
                Task { [weak self] in
                    await NetworkConditionSimulator.shared.delayOutbound()
                    self?.txAudioQueue.async {
                        self?.processAndSendEncryptedFrame(pcmFrame: pcmFrame, integration: integration)
                    }
                }
                return
            }
            // XP-crackle — off the real-time tap thread; see txAudioQueue kdoc.
            self.txAudioQueue.async { [weak self] in
                self?.processAndSendEncryptedFrame(pcmFrame: pcmFrame, integration: integration)
            }
        }

        // W464 — store the capture/playback refs UNCONDITIONALLY (before
        // any .start()) so the start can be (re)driven later.
        self.audioPlayback = playback
        self.audioCapture = capture
        // W464 — OUTGOING calls are now driven by CallKit's CXProvider
        // (AppState.startCall(contactId:) calls `callKit.startOutgoingCall`),
        // which triggers `provider(_:didActivate:)`. We defer starting the
        // audio engines until `handleAudioSessionActivated()` is fired by CallKit.

        let integration = QAudionCallIntegration()

        integration.onStateChanged = { [weak self] state in
            guard let self else { return }
            switch state {
            case .active:
                print("[CallService] PQC handshake complete — session active")
                // W-TXGATE — session key is live; open the TX encrypt gate. From
                // here processOutgoingAudio can succeed, so any failure past this
                // point is a REAL crypto error (counted in tx_enc_err).
                self.txSessionReady = true
                // Engine is now initialized — apply tuner-persisted codec params.
                self.callIntegration?.reconfigureAudioCodec(
                    bitrateKbps: AudioCodecPrefs.bitrateKbps,
                    plp:         AudioCodecPrefs.plp
                )
            case .error:
                self.endCall()
            case .fallback:
                // W461: PQC handshake slow/timed out. Do NOT tear down the
                // call here — the 30s fallback is purely a "handshake slow"
                // signal. Ending the call here caused the exact 30s drop bug
                // (iPad→A50 calls always dropped at :30). The call ends
                // normally when either side hangs up.
                //
                // CORRECTION (audit wf_b1d38abe): there is NO "audio continues
                // via WebRTC DTLS" invariant on iOS. The WebRTC SRTP audio
                // track is added DISABLED (QAudionPeerConnection.addLocalAudioTrack,
                // W574d) and the remote SRTP audio track is force-disabled on
                // arrival — voice rides ONLY the sealed WS relay (PqcRtpFrameSealer
                // M-15 seal over the engine's Opus+AEAD frames). While the relay
                // sealer is not yet installed (G2 unmet) NO mic frame is sent at
                // all (fail-closed, see startAudioIOIfReady / processAndSendEncryptedFrame).
                // So this state means "still negotiating the PQC seal", never
                // "falling back to plaintext/DTLS audio".
                print("[CallService] PQC handshake fallback — keeping call alive; voice stays on the sealed relay (no DTLS-audio fallback exists). Diagnose: check Android ACCEPT routing and callId case match.")
            default:
                break
            }
        }

        integration.onDeepfakeAlert = { [weak self] level, score in
            guard let self else { return }
            let isAlert: Bool
            switch level {
            case .red:
                isAlert = true
            case .yellow, .green:
                isAlert = false
            }
            self.onDeepfakeAlert?(isAlert)
            self.onDeepfakeScore?(level, score)
        }

        // Unified call UI — Guardian ribbon voice biometrics. Battery/perf
        // gate: only assign `onResult` (i.e. only ever receive callbacks)
        // when the engine config has voice analysis enabled. EngineConfig
        // .production() has enableVoiceAnalysis=true; .batteryOptimized()
        // (not currently selected anywhere) has it false — this check keeps
        // the wiring inert automatically if/when the app switches profiles,
        // without adding a second gate that could drift from the engine's
        // own config. VoiceAnalysisEngine.processFrame() ALSO internally
        // downsamples via analysisRate (default every 5th frame), so this
        // wiring does not run the full analysis pipeline unconditionally.
        if EngineConfig.production().enableVoiceAnalysis {
            integration.getVoiceAnalysis().onResult = { [weak self] result in
                self?.onVoiceAnalysis?(result)
            }
            // Unified call UI — REAL RX spectrum for the Guardian ribbon's
            // MiniSpectrum. Same battery gate as the gauges above; the
            // integration additionally skips the FFT while this stays nil.
            integration.onVoiceSpectrum = { [weak self] bands in
                self?.onVoiceSpectrum?(bands)
            }
        }

        // NOTE: do NOT call `integration.onCallSetupStarted` here.
        // That legacy entry point flipped the engine state machine into
        // .capabilitySent with an empty send-closure (bytes → /dev/null),
        // which then made `beginAndroidOutgoing` →
        // `onAndroidCallSetupStarted` fail with
        // `invalidState(.capabilitySent)` so no PQC OFFER ever reached
        // the peer and the call attached no media (silent audio).
        // The universal outgoing path is `beginAndroidOutgoing` for
        // ALL peer types (iOS / Android / Desktop) — it owns the
        // idle → capabilitySent transition itself and ships the real
        // JSON+QUAD OFFER pair.

        self.callIntegration = integration
        drainRxPreBuffer()  // W481 — replay any frames that arrived before binding
        startDurationTimer()

        // W469 — CallKit `didActivate` fallback for OUTGOING calls.
        // The W467 path defers the audio-engine start to
        // `provider(_:didActivate:)`. Telemetry of an iPad→A50 call
        // showed the iPad relaying ZERO TX frames: the mic never
        // started because CallKit's `didActivate` was not observed and
        // `audioSessionActive` stayed false forever, making
        // `startAudioIOIfReady()` a permanent no-op. If the session is
        // still not active after a short grace period, self-activate so
        // the call has working audio. `configureForVoIP()` already ran
        // above (best-effort `setActive(true)`); this only flips the
        // flag and starts the (idempotent) capture/playback engines. If
        // CallKit DOES fire `didActivate` first, this closure sees
        // `audioSessionActive == true` and does nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            guard !self.audioSessionActive, self.callIntegration != nil else { return }
            // Only self-activate when the peer has actually answered.
            // During outgoing ring this must not open the mic — the peer
            // hasn't answered yet and early audio activation leaks the
            // session and causes the waveform to animate before answer.
            // W574b: use peerAnswered (not isCallActive — AppState sets
            // .active right after the OFFER, before the answer).
            guard self.peerAnswered else {
                print("[CallService] W469 — skipped; peer has not answered yet")
                return
            }
            print("[CallService] W469 — CallKit didActivate not seen after 1.5s; self-activating audio session (fallback)")
            self.handleAudioSessionActivated()
        }
    }

    /// W450: incoming-call counterpart of `startCall(engine:contactId:)`.
    ///
    /// For incoming calls `startCall(engine:contactId:)` is never invoked
    /// because `AppState.isInCall` is already true (set by the
    /// `call_incoming` WS handler). This method fills that gap: it sets up
    /// the same AudioCapture + AudioPlayback stack and wires them to an
    /// EXISTING integration created by `AppState.ensureResponderIntegration`.
    ///
    /// Unlike `startCall`, it does NOT create a new QAudionCallIntegration —
    /// the PQC handshake has already started on the provided integration and
    /// we must not discard that state.
    ///
    /// - Parameters:
    ///   - engine: The shared QAudionEngine instance (unused directly here;
    ///     kept symmetric with `startCall` for future use).
    ///   - integration: The responder integration built during ringing.
    func activateIncomingCallAudio(engine: QAudionEngine,
                                   integration: QAudionCallIntegration) throws {
        // W-GRPVPIO-CRASH-3 — refuse to build a 1:1 audio engine while a
        // group call owns the VP-IO unit (see `isGroupCallActive` kdoc). A
        // stray/redelivered 1:1 accept-path message during a group call
        // otherwise reaches setVoiceProcessingEnabled here and aborts the
        // whole process.
        if isGroupCallActive?() == true {
            print("[CallService] activateIncomingCallAudio SKIPPED — group call active (VP-IO owned by LiveKit)")
            return
        }
        // W574i — preserve the M-15 relay sealers across the defensive
        // teardown. On the CALLEE the PQC handshake completes DURING ringing,
        // so onRelaySessionReady -> installRelaySealers has ALREADY run by the
        // time the user answers and this method fires. teardownAudioStack()
        // nils relaySealer{Send,Recv,CallId} — and the handshake will NOT fire
        // again (it's done), so without this the callee runs with NIL sealers:
        // it sends UNSEALED relay frames (159 B) and cannot unseal the caller's
        // SEALED frames (187 B) -> 100% RX failure, no audio in either
        // direction (the v1.0.624->633 callee-side "connected but silent" bug).
        // The CALLER never hit this because it installs its sealers AFTER its
        // own startCall() teardown. Save the sealers, run the teardown, then
        // restore them iff they still belong to the call being answered.
        // W-SLOTLOCK — snapshot the sealers atomically before teardown nils them.
        let (_savedSealerSend, _savedSealerRecv, _savedSealerCallId, _savedSealerKeyFp):
            (PqcRtpFrameSealer?, PqcRtpFrameSealer?, String?, String?) =
            relaySlotLock.withLock {
                (relaySealerSend, relaySealerRecv, relaySealerCallId, relaySealerKeyFp)
            }
        // Defensive cleanup: stop any leftover capture from a previous call.
        teardownAudioStack()
        if let cid = _savedSealerCallId, _savedSealerSend != nil {
            let active: String = getCallId?()?.lowercased() ?? ""
            // Restore when the sealer matches the active call, or when the
            // active id is unknown (the sealer was installed by W574h only for
            // the active call, so it cannot belong to a superseded one here).
            if active.isEmpty || active == cid {
                relaySlotLock.withLock {
                    relaySealerSend = _savedSealerSend
                    relaySealerRecv = _savedSealerRecv
                    relaySealerCallId = cid
                    relaySealerKeyFp = _savedSealerKeyFp
                }
                let p: String = String(cid.prefix(8))
                let line: String = "[CallService] W574i: preserved M-15 relay sealers across answer teardown (callId=" + p + "…)"
                print(line)
            }
        }

        let pipeline = AudioProcessingPipeline()
        pipeline.voiceProcessingOverride = CallsGate.anyVoiceProcessingEnabled
        do {
            try pipeline.configureForVoIP()
        } catch {
            print("[CallService] activateIncomingCallAudio: AVAudioSession config failed: \(error.localizedDescription)")
        }
        self.audioPipeline = pipeline

        let capture = AudioCapture(audioPipeline: pipeline)
        let playback = AudioPlayback()

        // TX path: mic → VP DSP → encrypt → WS send (same as outgoing).
        capture.onFrame = { [weak self] pcmFrame in
            guard let self else { return }
            if !NetworkConditionSimulator.shared.isPassthrough() {
                if NetworkConditionSimulator.shared.shouldDropOutbound() { return }
                Task { [weak self] in
                    await NetworkConditionSimulator.shared.delayOutbound()
                    self?.txAudioQueue.async {
                        self?.processAndSendEncryptedFrame(
                            pcmFrame: pcmFrame, integration: integration)
                    }
                }
                return
            }
            // XP-crackle — off the real-time tap thread; see txAudioQueue kdoc.
            self.txAudioQueue.async { [weak self] in
                self?.processAndSendEncryptedFrame(pcmFrame: pcmFrame, integration: integration)
            }
        }

        // W464 — INCOMING calls ARE driven by CallKit's CXProvider
        // (reportIncomingCall + CXAnswerCallAction). CallKit OWNS the
        // AVAudioSession and activates it itself, then calls
        // `provider(_:didActivate:)`. `activateIncomingCallAudio` runs
        // from the answer handler BEFORE that callback, so the session is
        // NOT yet active here: store the refs and DEFER the engine start.
        // `audioSessionActive` stays false (teardownAudioStack reset it)
        // and `handleAudioSessionActivated()` — wired to
        // `CallKitProvider.onAudioSessionActivated` — performs the real
        // start once CallKit hands the session over. Calling
        // `startAudioIOIfReady()` now is a deliberate no-op that also
        // covers the race where `didActivate` somehow already fired.
        self.audioPlayback = playback
        self.audioCapture = capture
        // W574b — WE are the answering side: this method only runs from the
        // answer handler, so the call is answered by definition. Unblock the
        // pre-answer mic gate before the (possibly deferred) engine start.
        peerAnswered = true
        startAudioIOIfReady()

        // Bind the integration so handleIncomingEncryptedFrame can decrypt
        // inbound audio_frame packets.
        self.callIntegration = integration
        // Unified call UI — responder-side Guardian wiring (2026-07-04 gap
        // fix): the incoming path never wired `getVoiceAnalysis().onResult`,
        // so the ribbon gauges + spectrum stayed dead on EVERY incoming call
        // (the old asymmetry noted on `AppState.voiceAnalysis`). Mirror
        // startCall's block 1:1 so both call directions feed the same sinks.
        // Placed BEFORE drainRxPreBuffer so even replayed pre-bind frames
        // already reach the spectrum tap.
        if EngineConfig.production().enableVoiceAnalysis {
            integration.getVoiceAnalysis().onResult = { [weak self] result in
                self?.onVoiceAnalysis?(result)
            }
            integration.onVoiceSpectrum = { [weak self] bands in
                self?.onVoiceSpectrum?(bands)
            }
        }
        // For incoming calls the PQC handshake started before answer, so
        // engine.initialize() has already run — apply tuner prefs now.
        integration.reconfigureAudioCodec(
            bitrateKbps: AudioCodecPrefs.bitrateKbps,
            plp:         AudioCodecPrefs.plp
        )
        drainRxPreBuffer()  // W481 — replay any frames that arrived before binding
        startDurationTimer()

        // Bug B — `didActivate` fallback. CallKit emits
        // provider(_:didActivate:) ONLY on an inactive→active AVAudioSession
        // transition. `configureForVoIP()` above best-effort `setActive(true)`,
        // and a PRIOR call can leave the session active, so on the SECOND
        // incoming call CallKit frequently SKIPS didActivate →
        // handleAudioSessionActivated() never runs → `audioSessionActive`
        // stays false → startAudioIOIfReady() no-ops → handshake completes but
        // there is TOTAL SILENCE (the exact "second call: data exchange OK but
        // no audio" symptom). If didActivate hasn't fired shortly after we set
        // up the stack, drive the start ourselves. The session is already
        // active (that's WHY CallKit skipped didActivate), so flipping the
        // flag + startAudioIOIfReady() starts capture+playback under it.
        // Idempotent: guarded on !audioSessionActive, and the engines guard on
        // their own isRunning flag, so a real didActivate that fires first wins.
        // Fallback: ensure audio engines start even if CallKit's didActivate
        // never fires (W520 suppressed call, or CallKit skipping didActivate
        // because the session was already active). The guard on
        // !audioSessionActive was WRONG — in rapid call sequences the flag
        // could be stale from a previous call, silently skipping the fallback
        // and leaving tx_enc=0 (the "iPhone non codificava" bug).
        // startAudioIOIfReady() is already idempotent (guards on isRunning),
        // so calling it unconditionally is safe — worst case it's a no-op.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self = self,
                  (self.audioCapture != nil || self.audioPlayback != nil) else { return }
            if !self.audioSessionActive {
                print("[CallService] Bug B fallback — CallKit didActivate never fired; forcing session active + starting audio")
                self.didActivateFallbackFired = true
                self.audioPipeline?.activateSession()
                self.handleAudioSessionActivated()
            } else {
                // Session is already active but engines may not have started
                // (e.g. rapid call sequence where the flag was stale). Poke
                // startAudioIOIfReady to ensure they're running.
                self.startAudioIOIfReady()
            }
        }
    }

    /// Originator-side wire driver for the iOS-as-caller PQC handshake.
    /// Closes the WIRE_SPEC §5 P0 gap that had `onCallSetupStarted` get
    /// passed an empty closure (no OFFER bytes ever reached the wire).
    ///
    /// Sequence (per OpenRouter glm-5.1 review 2026-05-06):
    ///   1. Snapshot integration to a strong local — guards against
    ///      mid-method teardown from another concurrency domain.
    ///   2. Send `call_offer` with the supplied callId — wakes the
    ///      Android peer's WsCallSignaller which buffers the
    ///      CallIncoming event per-callId for the user-accept path.
    ///   3. Drive `integration.onAndroidCallSetupStarted` with the
    ///      same callId. The engine generates dual-hybrid keypair,
    ///      stashes the privs INSIDE the method body BEFORE invoking
    ///      either send closure, then ships the JSON OFFER (literal
    ///      string, no base64 wrap) followed by the legacy QUAD
    ///      binary OFFER for backwards compat.
    ///   4. On any failure mid-stream: fire `sendCallHangupForId` so
    ///      the peer's UI doesn't sit on a phantom incoming call.
    ///
    /// CallId is supplied by the caller (AppState) so the WS-level
    /// callId, the engine stash key, the PQC bundle's `callId` field,
    /// and the eventual ACCEPT routing all converge on the same UUID.
    func beginAndroidOutgoing(
        callId: String,
        recipientId: String,
        callingApi: CallingApi,
        callerDisplay: String? = nil,
        hasVideo: Bool = false
    ) async throws {
        // Snapshot to local strong ref — prevents use-after-free if
        // another Task tears down callIntegration mid-await.
        guard let integration = self.callIntegration else {
            throw CallServiceError.noIntegration
        }

        // 1) call_offer (vestigial empty SDP — WIRE_SPEC §3 SDP-less
        //    PQC path uses opaque_message OFFER for the actual crypto).
        //    `callerDisplay` and `hasVideo` must match the parallel
        //    WebRTC offer so Android's WsCallSignaller sets up the right
        //    media pipeline regardless of which offer it processes first.
        let vestigialSdp = ""
        try await callingApi.sendCallOfferWithId(
            callId: callId,
            recipientId: recipientId,
            sdp: vestigialSdp,
            // R-4 (vkey-v1): strip `vkey-v1` when sovereign-only is on so
            // we never advertise phone-level video E2EE to the peer.
            capabilities: CallsGate.filterAdvertisedCapabilities(CallCapabilities.local),
            callerDisplay: callerDisplay,
            hasVideo: hasVideo
        )

        // 2) PQC handshake OFFER pair (JSON + QUAD). Best-effort
        //    cleanup on failure: tell the peer to dismiss the
        //    phantom incoming call.
        do {
            try await integration.onAndroidCallSetupStarted(
                callId: callId,
                sendOpaqueRaw: { wireString in
                    try await callingApi.sendOpaqueMessageString(
                        recipientId: recipientId, payload: wireString)
                },
                sendOpaqueBinary: { data in
                    try await callingApi.sendOpaqueMessage(
                        recipientId: recipientId, data: data)
                }
            )
        } catch is CancellationError {
            // User cancelled the call after call_offer landed but
            // before the OFFER bundles went out. Best-effort hangup
            // and re-raise so AppState can transition the UI to .idle.
            try? await callingApi.sendCallHangupForId(
                callId: callId, recipientId: recipientId)
            throw CancellationError()
        } catch {
            print("[CallService] Android originator OFFER pipeline failed for callId=\(callId.prefix(8))…: \(error)")
            try? await callingApi.sendCallHangupForId(
                callId: callId, recipientId: recipientId)
            throw error
        }
    }

    enum CallServiceError: Error {
        case noIntegration
    }

    /// W574e — strip the M-15 relay seal from an inbound frame, mirroring
    /// Android `BcryptoWsFrameRelayTransport.parseRawFrame`.
    ///
    /// Returns the inner `0x01|…` WireRelayFrameCodec frame, or nil if the
    /// frame must be DROPPED. Once the recv sealer is installed (key
    /// established) ALL frames are expected sealed — an open failure is a
    /// replay/forgery/garbage frame and is dropped (matching Android, which
    /// drops on SecurityException). Before install (sealer nil) the frame
    /// passes through unchanged — the pre-handshake window where neither
    /// side seals yet.
    private func unsealRelayFrame(_ data: Data) -> Data? {
        // W-SLOTLOCK — copy the recv sealer under the lock (installRelaySealers /
        // teardown write it from other threads); open() runs unlocked.
        guard let sealer = relaySlotLock.withLock({ relaySealerRecv }) else { return data }
        do {
            return try sealer.open(data)
        } catch {
            return nil
        }
    }

    func endCall() {
        onDeepfakeAlert?(false)
        stopDurationTimer()
        callStartedAt = nil
        callDurationSeconds = 0
        isMuted = false
        isOnHold = false

        // W65+W66: stop capture/playback + rilascia AVAudioSession.
        // teardownAudioStack also handles callIntegration cleanup.
        teardownAudioStack()
    }

    /// W481 — drain frames buffered before callIntegration was bound.
    /// Call immediately after `self.callIntegration = integration` on the
    /// main thread. Processes each frame through processIncomingAudio so
    /// the RX ratchet advances in step with the peer's TX ratchet.
    private func drainRxPreBuffer() {
        guard !rxPreBuffer.isEmpty, let integration = callIntegration else { return }
        let frames = rxPreBuffer
        rxPreBuffer.removeAll()
        let n: String = frames.count.description
        print("[CallService] RX W481: draining " + n + " pre-buffered frame(s)")
        for frame in frames {
            // W574e — these buffered frames arrived pre-bind (pre-handshake),
            // so they are normally unsealed pass-through; unsealRelayFrame
            // returns them unchanged when the sealer isn't installed yet, or
            // strips the seal / drops if it is.
            guard let inner = unsealRelayFrame(frame) else {
                rxDecryptErrorCount &+= 1
                continue
            }
            do {
                let pcm = try integration.processIncomingAudio(serializedFrame: inner)
                framesDecryptedRx &+= 1
                audioCapture?.playFrame(pcm)  // single-engine: playback lives on the capture engine
            } catch {
                rxDecryptErrorCount &+= 1
            }
        }
    }

    /// W66+W67: ingresso per il RX path. Chiamato dal handler "audio_frame"
    /// del `BCryptoWebSocketClient` quando il server inoltra un frame
    /// del peer. Esegue decrypt + playback + UI updates.
    ///
    /// Thread safety: il WS handler è invocato su una background queue
    /// di URLSession. AVAudioPCMBuffer scheduleBuffer è thread-safe per
    /// Apple docs, ma per safety con i `@Published` AppState e i counter
    /// non-atomic, dispatchiamo l'intera elaborazione su main.
    /// `callId` is the `call_id` field from the `audio_frame` WS envelope.
    /// When present and mismatched against the active call, the frame is
    /// dropped immediately — this prevents x250+ CryptoKitError 3 storms
    /// caused by stale relay delivery from a previous/overlapping session.
    /// W-DCAUDIO — inbound sealed audio frame received over the WebRTC
    /// DataChannel. The bytes are the raw WireRelayFrameCodec envelope (identical
    /// to what the WS "audio_frame" handler delivers after base64 decode), so we
    /// route them through the same decrypt + playback path. The DataChannel is
    /// per-call (one PC per call), so the active call_id applies. Wired by AppState
    /// to `QAudionWebRtcCallController.onAudioDataChannelFrame`.
    public func handleIncomingDataChannelAudio(_ data: Data) {
        handleIncomingEncryptedFrame(data, callId: getCallId?())
    }

    public func handleIncomingEncryptedFrame(_ serializedFrame: Data,
                                             callId: String? = nil) {
        // W69: dev network simulator hook RX. Stessa semantica del TX —
        // simula packet loss inbound. Branch-predicted off-path in Off.
        if !NetworkConditionSimulator.shared.isPassthrough() {
            if NetworkConditionSimulator.shared.shouldDropInbound() {
                return  // frame inbound droppato
            }
        }
        // Dispatch to main per coerenza con TX path (Task { @MainActor })
        // e per evitare race su framesDecryptedRx counter.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Stale-session filter: drop frames whose call_id doesn't match
            // the active call. Without this, the relay delivers all buffered
            // frames from a previous session to the new session's decrypt
            // path, causing x250+ AEAD authentication failures (CryptoKitError 3).
            // Only filter when both sides are known — if either is nil (old
            // client with no call_id, or call not yet fully set up), allow through.
            if let incomingId = callId,
               let activeId = self.getCallId?(),
               incomingId.caseInsensitiveCompare(activeId) != .orderedSame {
                self.rxStaleDropCount &+= 1
                if !self.loggedFirstStaleDrop {
                    self.loggedFirstStaleDrop = true
                    let inc: String = String(incomingId.prefix(8))
                    let act: String = String(activeId.prefix(8))
                    let line: String = "[CallService] RX stale drop: frame callId=" + inc + "… != active=" + act + "… (suppressing further per-frame logs)"
                    print(line)
                }
                return
            }
            // W466 — count EVERY audio_frame off the WS, before decrypt,
            // so the telemetry distinguishes "peer never sent" from
            // "received but decrypt failed".
            self.framesReceivedRx &+= 1
            if !self.loggedFirstRxReceive {
                self.loggedFirstRxReceive = true
                let bytes: String = serializedFrame.count.description
                let line: String = "[CallService] RX: first audio_frame received from peer (" + bytes + " bytes)"
                print(line)
            }
            guard let integration = self.callIntegration else {
                // W481 — buffer instead of drop. Dropping silently advances
                // the peer's TX ratchet without advancing our RX ratchet,
                // causing a permanent off-by-one (CryptoKitError on EVERY
                // subsequent frame). Buffer up to rxPreBufferCap frames;
                // drainRxPreBuffer() replays them once callIntegration binds.
                if self.rxPreBuffer.count < Self.rxPreBufferCap {
                    self.rxPreBuffer.append(serializedFrame)
                }
                if !self.loggedRxNoIntegration {
                    self.loggedRxNoIntegration = true
                    print("[CallService] RX W481: callIntegration nil — buffering frame (will drain on bind)")
                }
                return
            }
            // W574e — strip the M-15 relay seal before the AdaptivePadding
            // decode. Android wraps every relay frame in this seal; once our
            // recv sealer is installed an open failure means replay/forgery →
            // drop (counts as a decrypt error). Pre-install → pass through.
            guard let inner = self.unsealRelayFrame(serializedFrame) else {
                self.rxDecryptErrorCount &+= 1
                if self.rxDecryptErrorCount == 1 || self.rxDecryptErrorCount % 250 == 0 {
                    print("[CallService] RX: M-15 unseal failed/replay (x\(self.rxDecryptErrorCount)) — dropped")
                }
                return
            }
            do {
                let pcm = try integration.processIncomingAudio(serializedFrame: inner)
                self.framesDecryptedRx &+= 1
                if !self.loggedFirstRxDecrypt {
                    self.loggedFirstRxDecrypt = true
                    print("[CallService] RX: first frame DECRYPTED ok — AEAD+Opus decode live")
                }
                if let cap = self.audioCapture {
                    // single-engine: playback runs on the capture engine's player node
                    cap.playFrame(pcm)
                } else if !self.loggedRxNoPlayback {
                    self.loggedRxNoPlayback = true
                    print("[CallService] RX: decrypted frame but audioCapture is nil — not audible")
                }
                if self.framesDecryptedRx % 250 == 0 {
                    let n: String = self.framesDecryptedRx.description
                    let line: String = "[CallService] RX heartbeat: " + n + " frames decrypted+played"
                    print(line)
                }
                let rxSamples = self.updateWaveformSamples(from: pcm)
                self.onRxWaveformUpdate?(rxSamples)
                // AUDIO-DIAG (2026-07-12) — accumulate decoded RX level from the
                // samples already in hand (no extra decode). rxSamples are the
                // Int16 PCM normalized to [-1,1]; peak/rms roll up into
                // call.audio.diag as rx_peak_pct/rx_rms_pct (mirror of Android).
                for s in rxSamples {
                    let a = abs(s)
                    if a > self.rxLevelPeak { self.rxLevelPeak = a }
                    self.rxLevelSumSq += Double(s) * Double(s)
                }
                self.rxLevelSampleCount &+= Int64(rxSamples.count)
            } catch {
                self.rxDecryptErrorCount &+= 1
                if self.rxDecryptErrorCount == 1 || self.rxDecryptErrorCount % 250 == 0 {
                    let desc: String = error.localizedDescription
                    let cnt: String = self.rxDecryptErrorCount.description
                    let line: String = "[CallService] RX decrypt FAILED (x" + cnt + "): " + desc
                    print(line)
                }
            }
        }
    }

    /// W66: stop ordinato di capture + playback + session deactivation.
    /// Chiamato sia in `endCall()` che come defensive cleanup all'inizio
    /// di `startCall()` (re-entry guard).
    /// Also owns callIntegration lifecycle: fires onCallEnded and nils it
    /// so stale frames arriving after teardown can't be decrypted with
    /// an old session key (they hit the W481 pre-buffer instead).
    private func teardownAudioStack() {
        // Diagnostic: emit the REAL audio frame counters BEFORE they reset.
        // call.media.summary's `suspect_silent` is a timer-only heuristic and
        // says nothing about audio — these counters are the ground truth that
        // distinguishes the failure modes the user reported ("connected but no
        // audio / no SAS"):
        //   rx_recv>0 & rx_dec≈rx_recv & engines_started → audio DECRYPTS; a
        //       silent call then means PLAYBACK/route (Bug B / speaker).
        //   rx_recv>0 & rx_dec≈0 & rx_dec_err high       → KEY MISMATCH (the
        //       two sides derived different session keys → SAS won't match).
        //   rx_recv≈0                                     → audio never arrived
        //       (peer not capturing / transport / wrong call_id).
        //   engines_started=false                         → engines never ran.
        // Only emit when the call actually had an audio stack (skip the
        // defensive pre-call cleanups that would log all-zeros).
        if audioEnginesStarted || framesReceivedRx > 0 || framesEncryptedTx > 0 {
            let _callId = getCallId?()
            let _attrs: [String: Any] = [
                "tx_enc":          framesEncryptedTx,
                "rx_recv":         framesReceivedRx,
                "rx_dec":          framesDecryptedRx,
                "rx_dec_err":      rxDecryptErrorCount,
                "tx_enc_err":      txEncryptErrorCount,
                // W-TXGATE — expected mic frames dropped before the session key
                // existed (~0.8 s handshake window); NOT a fault. Kept separate
                // so tx_enc_err stays a clean real-failure signal.
                "tx_pre_hs":       txPreHandshakeDropped,
                "engines_started": audioEnginesStarted,
                "fallback_fired":  didActivateFallbackFired,
                "session_active":  audioSessionActive
            ]
            Task { @MainActor in
                TelemetryService.shared.emit(kind: "call.audio.counts", callId: _callId, attrs: _attrs)
            }
            // Post-call Opus tuning — must run BEFORE counters reset below.
            // W574c: callId attached so the tune decision (or skip reason)
            // shows up on the server's per-call telemetry timeline.
            AudioAutoTuner.shared.tunePostCall(
                framesReceived:  framesReceivedRx,
                framesDecrypted: framesDecryptedRx,
                rxDecryptErrors: rxDecryptErrorCount,
                callId:          getCallId?()
            )
            // AUDIO-DIAG (2026-07-10) — real per-call evidence for two open
            // reports, replacing guesswork:
            //   * "scoppiettii" on EARPIECE: defaults leave VP-IO fully OFF
            //     (aec/ns/agc all false), so the raw mic hits Opus with no
            //     AEC/NS/AGC and no limiter — unlike Android, which ships HW
            //     AEC+NS on. `clip_samples > 0` with `peak_pct ~100` and
            //     `vpio_ever_active=false` confirms hard clipping.
            //   * AirPods "voce storpiata": `bt_route_ever=true` plus a
            //     `granted_sr` far below `preferred_sr` (48k) confirms the
            //     A2DP→HFP narrow-band drop rather than a double-AEC theory.
            // MUST read before audioCapture/audioPipeline are nil'd + stopped
            // below. peak_pct is peak/32767 rounded to 1dp.
            if let capture = audioCapture, let pipeline = audioPipeline {
                let level = capture.consumeLevelStats()
                let diag = pipeline.consumeAudioDiagStats()
                let peakPct = Double(level.peak) / Double(Int16.max) * 100
                // TX mic RMS (% of full scale) alongside the existing TX peak.
                let txRmsPct = Double(level.rms) / Double(Int16.max) * 100
                // Decoded RX level (% of full scale) — peak/rms mirror of Android.
                let rxPeakPct = Double(rxLevelPeak) * 100
                let rxRmsPct = rxLevelSampleCount > 0
                    ? (rxLevelSumSq / Double(rxLevelSampleCount)).squareRoot() * 100
                    : 0
                let diagAttrs: [String: Any] = [
                    "peak_pct":           (peakPct * 10).rounded() / 10,
                    "rms_pct":            (txRmsPct * 10).rounded() / 10,
                    // W-MICAGC — max software make-up gain the mic AGC reached this
                    // call (1.0 = never engaged / VP-IO on; higher = raw mic was
                    // quiet and got lifted). Hitting the 6.0 cap ⇒ target unreachable.
                    "agc_gain":           (Double(level.agcGain) * 100).rounded() / 100,
                    "rx_peak_pct":        (rxPeakPct * 10).rounded() / 10,
                    "rx_rms_pct":         (rxRmsPct * 10).rounded() / 10,
                    "clip_samples":       level.clipSamples,
                    "vpio_ever_active":   diag.vpioEverActive,
                    "agc_ever_active":    diag.agcEverActive,
                    "speaker_route_ever": diag.speakerRouteEver,
                    "bt_route_ever":      diag.bluetoothRouteEver,
                    "input_route":        diag.inputRoute,
                    "output_route":       diag.outputRoute,
                    "granted_sr":         diag.grantedSampleRate,
                    "preferred_sr":       diag.preferredSampleRate,
                    // W-CANONICAL — proof instruments for the VP-IO migration:
                    // tap_sr/tap_ch = real post-enable tap format (≠48000 was
                    // the W556 warp class, now converted); engine_restarts =
                    // mid-call route bounces; vpio_bypassed_ever = the starve
                    // watchdog forced the raw-mic fallback this call.
                    "tap_sr":             diag.tapSampleRate,
                    "tap_ch":             diag.tapChannels,
                    "engine_restarts":    diag.engineRestarts,
                    "vpio_bypassed_ever": diag.vpioBypassedEver
                ]
                Task { @MainActor in
                    TelemetryService.shared.emit(kind: "call.audio.diag", callId: _callId, attrs: diagAttrs)
                }
            }
        }
        audioEnginesStarted = false
        didActivateFallbackFired = false
        callIntegration?.onCallEnded()
        callIntegration = nil
        audioCapture?.stop()
        audioCapture = nil
        audioPlayback?.stop()
        audioPlayback = nil
        audioPipeline?.deactivateSession()
        audioPipeline = nil
        framesEncryptedTx = 0
        framesDecryptedRx = 0
        // W466 — reset the per-call diagnostic counters/markers so the
        // next call's telemetry starts from a clean slate.
        framesReceivedRx = 0
        txEncryptErrorCount = 0
        rxDecryptErrorCount = 0
        txSessionReady = false            // W-TXGATE — re-arm for the next call
        txPreHandshakeDropped = 0
        rxLevelPeak = 0        // AUDIO-DIAG (2026-07-12) — reset RX level accumulators
        rxLevelSumSq = 0
        rxLevelSampleCount = 0
        loggedFirstTxCapture = false
        loggedFirstTxEncrypt = false
        loggedTxNoTransport = false
        loggedFirstRxReceive = false
        loggedRxNoIntegration = false
        loggedFirstRxDecrypt = false
        loggedRxNoPlayback = false
        loggedFirstStaleDrop = false
        rxStaleDropCount = 0
        rxPreBuffer.removeAll()  // W481
        // W464 — drop the session-active flag so the NEXT call starts
        // from a clean slate and waits for its own CallKit `didActivate`.
        audioSessionActive = false
        peerAnswered = false  // W574b — re-arm the pre-answer mic gate for the next call
        // W-SLOTLOCK — nil the cross-thread reference slots under the lock so an
        // in-flight tap (TX) or decode (RX) frame can't race the release-old ARC
        // write of these reference-typed slots (torn refcount → use-after-free).
        relaySlotLock.withLock {
            relaySealerSend = nil  // W574e — fresh M-15 sealers per call (new key)
            relaySealerRecv = nil
            relaySealerCallId = nil  // W574h — unbind so the next call re-keys cleanly
            relaySealerKeyFp = nil   // W574l
            // W67: reset transport binding. Nota: NON disconnect-iamo il
            // wsClient (può restare connesso per signaling / chat / contacts).
            // Solo facciamo nil-out i riferimenti così future audio frames
            // non triggherano send/playback.
            wsClient = nil
            peerUserId = nil
        }
    }

    // MARK: - W464 — CallKit audio-session lifecycle

    /// W464 — start the capture + playback `AVAudioEngine`s, but ONLY once
    /// CallKit has activated the shared `AVAudioSession`.
    ///
    /// `AudioCapture.start()` / `AudioPlayback.start()` both guard on an
    /// internal `isRunning` flag, so this is idempotent: it is safe to
    /// call from `startCall` / `activateIncomingCallAudio` (where the
    /// session is usually NOT yet active → no-op) AND from
    /// `handleAudioSessionActivated()` (where it actually starts the
    /// engines). Whichever runs last with `audioSessionActive == true`
    /// performs the real start.
    private func startAudioIOIfReady() {
        // W-GRPVPIO-CRASH-3 — the single chokepoint every 1:1 audio start
        // funnels through (activateIncomingCallAudio, handleAudioSessionActivated,
        // handleCallAnswered, and CallKit didActivate all reach here). Refusing
        // it while a group call owns VP-IO closes EVERY path to the crashing
        // setVoiceProcessingEnabled at once (see `isGroupCallActive` kdoc).
        if isGroupCallActive?() == true {
            print("[CallService] startAudioIOIfReady SKIPPED — group call active (VP-IO owned by LiveKit)")
            return
        }
        guard audioSessionActive else {
            print("[CallService] audio I/O deferred — waiting for CallKit didActivate")
            return
        }
        // W574b pre-answer gate: for outgoing calls CallKit fires didActivate
        // as soon as the call UI appears — BEFORE the peer answers. Block the
        // mic until call_answer arrives (handleCallAnswered flips the flag).
        // Incoming calls set the flag in activateIncomingCallAudio (we ARE
        // the answerer), so this is a no-op on the answering side.
        // Do NOT use AppState.callState here — the outgoing flow sets
        // `.active` immediately after the OFFER is sent, which defeated
        // the v1.0.618 isCallActive?() version of this gate.
        guard peerAnswered else {
            print("[CallService] audio I/O deferred — peer has not answered yet")
            return
        }
        // SINGLE-ENGINE FIX — start ONE AVAudioEngine only. AudioCapture now
        // owns both the mic tap AND the playback player node, so there is no
        // separate AudioPlayback engine to start (a second engine on the same
        // AVAudioSession muted the output route → total silence). audioPlayback
        // is left intentionally unused/nil.
        if let capture = audioCapture {
            do {
                try capture.start()
            } catch {
                let desc: String = error.localizedDescription
                let line: String = "[CallService] AudioCapture start failed: " + desc + " — chiamata continua senza HW VP"
                print(line)
            }
        }
        // Diagnostics: mark audio I/O live once the single engine has started.
        if audioCapture != nil {
            audioEnginesStarted = true
        }
    }

    /// W464 — CallKit activated the shared `AVAudioSession`. This is the
    /// only safe moment to spin up the mic-capture / speaker-playback
    /// `AVAudioEngine`s. Wired from `AppState` to
    /// `CallKitProvider.onAudioSessionActivated`. Runs on the main thread.
    public func handleAudioSessionActivated() {
        audioSessionActive = true
        startAudioIOIfReady()
        // EARPIECE is the default route for an encrypted phone call (user
        // requirement: "gestire il volume della capsula telefonica; lo speaker
        // esterno va bene solo se lo imposto dall'interfaccia per fare vivavoce").
        // Do NOT force .speaker here — the .voiceChat session already routes to
        // the receiver. The user switches to speaker via the in-call button
        // (overrideOutputAudioPort(.speaker)). The .none reset in endCall keeps
        // the next call starting on the earpiece.
    }

    /// W464 — CallKit released the audio session (call ending or
    /// interrupted). Future audio-engine starts must wait for the next
    /// `didActivate`. Wired from `CallKitProvider.onAudioSessionDeactivated`.
    public func handleAudioSessionDeactivated() {
        audioSessionActive = false
    }

    /// W574 — called by AppState when `call_answer` is received (callee has
    /// formally accepted). Kicks off audio I/O if CallKit already fired
    /// `didActivate` (audioSessionActive == true). If `didActivate` has not
    /// yet arrived, the deferred call to `startAudioIOIfReady()` from
    /// `handleAudioSessionActivated()` will complete the start once it fires.
    public func handleCallAnswered() {
        peerAnswered = true
        startAudioIOIfReady()
        // W574b — post-answer W469 fallback. The 1.5s timer in startCall
        // now (correctly) skips while the peer hasn't answered, so it no
        // longer covers the "CallKit didActivate never fires" case for
        // outgoing calls. Re-arm here: if the session is still inactive
        // shortly after the answer, self-activate so the call gets audio.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            guard !self.audioSessionActive,
                  self.callIntegration != nil,
                  self.peerAnswered else { return }
            print("[CallService] W574b — didActivate not seen 1s after answer; self-activating audio session (fallback)")
            self.handleAudioSessionActivated()
        }
    }

    /// W469 — convert the engine's `FrameEncoder` output to the wire
    /// format the peer can decode. With the Android-wire toggle ON
    /// (default) this re-wraps the frame as a `WireRelayFrameCodec`
    /// audio envelope, which Android relay peers decode and iOS peers
    /// auto-detect. The audio AEAD carries no AAD, so re-containerising
    /// changes only header bytes — never the ciphertext/tag. On a parse
    /// failure it returns the original bytes unchanged (fail-safe).
    private func encodeAudioForWire(_ frameEncoderBytes: Data) -> Data {
        guard androidAudioWireCompat else { return frameEncoderBytes }
        guard let fe = try? FrameEncoder.deserialize(frameEncoderBytes) else {
            return frameEncoderBytes
        }
        return WireRelayFrameCodec.encodeAudio(fe)
    }

    /// W69 helper: encrypt + waveform-update + network-send routine
    /// extracted from `capture.onFrame` per essere call-able sia dal
    /// fast path (NetworkSim Off) che dal task-isolated delay path
    /// (NetworkSim HighLatency/Satellite).
    ///
    /// W-STALEPIPE (2026-07-13) — same class of bug fixed for video
    /// (onOutboundFragment identity guard): `capture.onFrame` snapshots
    /// `integration` once and hands it to `txAudioQueue.async` (or, on the
    /// NetworkSim delay path, to a Task that can sleep arbitrarily long
    /// first). CallService itself is a process-wide singleton
    /// (`AppState.callService = CallService()`), so a queued/delayed frame
    /// that outlives `endCall()` (which sets `self.callIntegration = nil`
    /// and stops audioCapture) still finds `self` alive and — for the
    /// incoming-call capture.onFrame — has NO freshness check at all before
    /// this call, encrypting and sending audio for a call that already
    /// ended. Mirrors the fleet-wide "video relay rejected: not an
    /// established call party" finding (~6662/week) at smaller volume
    /// (~705/week server-side "audio relay rejected"). Fixed at this single
    /// shared chokepoint (both capture.onFrame sites funnel through here)
    /// rather than duplicating the guard at each closure.
    private func processAndSendEncryptedFrame(pcmFrame: Data,
                                               integration: QAudionCallIntegration) {
        guard callIntegration === integration else {
            RTLog.error("call", "W-STALEPIPE processAndSendEncryptedFrame called with an integration that is no longer self.callIntegration — dropping frame (would have been rejected server-side anyway)")
            return
        }
        // W517 — honour mute / hold flags.
        // Hold: suppress TX entirely so the peer hears silence without
        // the ratchet advancing out-of-step.
        guard !isOnHold else { return }
        // Mute: replace mic PCM with silence so the crypto state advances
        // in step with the peer (ratchet stays aligned) but the peer
        // hears nothing. Mirrors the gate in the legacy processOutgoingAudio().
        let frameToProcess = isMuted ? Data(repeating: 0, count: pcmFrame.count) : pcmFrame

        // W466 — TX-path instrumentation: prove whether the mic produces
        // frames, whether encryption succeeds, and whether frames hit the
        // wire. Rate-limited (first occurrence + 250-frame heartbeat).
        if !loggedFirstTxCapture {
            loggedFirstTxCapture = true
            let bytes: String = frameToProcess.count.description
            let line: String = "[CallService] TX: first mic frame reached encrypt stage (" + bytes + " bytes PCM)"
            print(line)
        }
        do {
            let encrypted = try integration.processOutgoingAudio(pcmFrame: frameToProcess)
            framesEncryptedTx &+= 1
            if !loggedFirstTxEncrypt {
                loggedFirstTxEncrypt = true
                let bytes: String = encrypted.count.description
                let line: String = "[CallService] TX: first frame ENCRYPTED ok (" + bytes + " bytes) — Opus+AEAD pipeline live"
                print(line)
            }
            let txSamples = updateWaveformSamples(from: frameToProcess)
            let cipherSamples = updateCipherSamples(from: encrypted)
            Task { @MainActor [weak self] in
                self?.onTxWaveformUpdate?(txSamples)
                self?.onCipherWaveformUpdate?(cipherSamples)
            }
            // W476 — fall back to the lazy providers (set once by AppState
            // at login) when `wireTransport` never bound these eagerly.
            // Without this every encrypted TX frame was silently dropped
            // for any call where `liveProvider` was nil at startCall
            // /answer time — the local waveforms moved but the server
            // logged zero `audio relay from=<us>` and the peer heard
            // silence.
            //
            // W574c — priority INVERTED: prefer the LIVE provider's client
            // over the cached `wsClient`. The cache binds whatever instance
            // was current at call setup; when that instance is superseded
            // mid-call (multi-provider reconnect, see fix/ws-reconnect-storm)
            // its webSocketTask goes nil and `send(audio_frame)` drops every
            // frame with no recovery — call 382c46bb: client tx_enc=2245,
            // server relayed=1, while RX kept flowing on the NEW instance.
            // `getWsClient` always resolves the current live instance; the
            // cache remains as fallback for transient liveProvider==nil.
            // W-SLOTLOCK — snapshot the cached transport refs under the lock; the
            // getWsClient/getPeerId provider closures run OUTSIDE the lock.
            let (cachedWs, cachedPeer): (BCryptoWebSocketClient?, String?) =
                relaySlotLock.withLock { (wsClient, peerUserId) }
            let effectiveWs = getWsClient?() ?? cachedWs
            let effectivePeer = cachedPeer ?? getPeerId?()
            if let ws = effectiveWs, let peer = effectivePeer {
                // W522 — when the W476 lazy fallback rescues TX (wireTransport
                // was never called because liveProvider was nil at startCall),
                // we ALSO need to register the audio_frame RX handler. Without
                // this branch the iPad encrypts+sends correctly but never sees
                // any inbound audio_frame from the peer: the symptom is the
                // remote side hears us but we hear silence (confirmed in
                // session bbe9a2ff, 1.0.520 — TX heartbeat reaches 3000 frames
                // while RX heartbeat is never emitted).
                let needsRxRegistration: Bool = (cachedWs == nil)
                if cachedWs == nil {
                    // W-SLOTLOCK — lazy-populate the transport cache under the lock.
                    relaySlotLock.withLock {
                        if wsClient == nil { wsClient = ws }
                        if peerUserId == nil { peerUserId = peer }
                    }
                }
                if needsRxRegistration {
                    ws.registerHandler(type: "audio_frame") { [weak self] _, data in
                        guard let self,
                              let b64 = data["frame"] as? String,
                              let frameData = Data(base64Encoded: b64) else { return }
                        let incomingCallId = data["call_id"] as? String
                        self.handleIncomingEncryptedFrame(frameData, callId: incomingCallId)
                    }
                    print("[CallService] W522: lazy audio_frame RX handler registered (fallback path)")
                }
                // W469 — emit the cross-platform wire format. The engine's
                // `processOutgoingAudio` always serialises the iOS-native
                // `FrameEncoder` container; Android peers on the relay can
                // only decode the compact `WireRelayFrameCodec` audio
                // envelope. `encodeAudioForWire` re-containerises it (the
                // receiving iOS side auto-detects either format, so this is
                // also correct for iOS↔iOS).
                let wireFrame = encodeAudioForWire(encrypted)
                // W574e — apply the M-15 seal so the on-wire bytes match
                // Android's BcryptoWsFrameRelayTransport.sendRaw exactly:
                // seal( 0x01|nonce|seq|ctLen|ct ). Pass-through until the
                // sealer is installed (key-established), mirroring Android's
                // `pqcSend?.seal(payload) ?: payload`. iOS↔iOS (both new)
                // seal↔open; iOS↔Android now interops.
                let sealedFrame: Data
                // W-SLOTLOCK — copy the send sealer under the lock; seal() runs unlocked.
                if let sealer = relaySlotLock.withLock({ relaySealerSend }) {
                    sealedFrame = (try? sealer.seal(wireFrame)) ?? wireFrame
                } else {
                    sealedFrame = wireFrame
                }
                // W525: include the call_id so Android/Desktop accept
                // the frame. Their filter drops envelopes whose
                // call_id doesn't match the active call.
                let cid = getCallId?()
                // W-DCAUDIO — prefer the P2P sealed-audio DataChannel when it is
                // open; fall back to the WS relay otherwise. Identical bytes on
                // either path (the raw WireRelayFrameCodec envelope), so the peer
                // decodes both the same way. The DataChannel is lower-latency and
                // keeps media off the server; the WS relay guarantees delivery when
                // ICE/DTLS cannot form a P2P link.
                let sentOnDc: Bool = sendAudioOverDataChannel?(sealedFrame) ?? false
                if !sentOnDc {
                    ws.sendAudioFrame(recipientId: peer, frame: sealedFrame, callId: cid)
                }
                if !loggedFirstTxWire {
                    loggedFirstTxWire = true
                    let fmt: String = androidAudioWireCompat ? "WireRelayFrameCodec" : "FrameEncoder"
                    let a: String = encrypted.count.description
                    let b: String = wireFrame.count.description
                    let line: String = "[CallService] TX: wire format = " + fmt + " (" + a + "->" + b + " bytes)"
                    print(line)
                    // W526 diagnostic: confirm whether the call_id is
                    // actually flowing through. If `cid == nil` here the
                    // peer (Android/Desktop) silently drops every frame.
                    let cidStr: String = cid ?? "<NIL>"
                    let cidShortPrefix: String = String(cidStr.prefix(8))
                    let cidShort: String = cidStr.count > 8 ? (cidShortPrefix + "…") : cidStr
                    let peerShort: String = String(peer.prefix(8))
                    let cidLine: String = "[CallService] TX call_id=" + cidShort + " (peer=" + peerShort + "…)"
                    print(cidLine)
                }
                if framesEncryptedTx % 250 == 0 {
                    let n: String = framesEncryptedTx.description
                    let line: String = "[CallService] TX heartbeat: " + n + " frames encrypted+sent"
                    print(line)
                }
            } else if !loggedTxNoTransport {
                loggedTxNoTransport = true
                print("[CallService] TX: encrypted frames NOT sent — WS transport not bound (wsClient/peerUserId nil)")
            }
        } catch {
            // W-TXGATE — separate the EXPECTED pre-handshake window from a REAL
            // crypto failure. Before the session key exists (txSessionReady
            // still false), processOutgoingAudio necessarily throws
            // QAudionEngineError.error3 on every mic frame — ~40 frames over the
            // ~0.8 s handshake. Counting those in tx_enc_err made a healthy call
            // look like it had 40 crypto errors (surfaced by tune-report). Route
            // them to txPreHandshakeDropped instead; tx_enc_err now counts ONLY
            // failures AFTER the session went active — a genuine bug signal.
            if !txSessionReady {
                txPreHandshakeDropped &+= 1
                return
            }
            // W466 — a real post-handshake encrypt failure. Log the first one and
            // every 250th so the telemetry shows whether they persist.
            txEncryptErrorCount &+= 1
            if txEncryptErrorCount == 1 || txEncryptErrorCount % 250 == 0 {
                let desc: String = error.localizedDescription
                let cnt: String = txEncryptErrorCount.description
                let line: String = "[CallService] TX encrypt FAILED (x" + cnt + "): " + desc
                print(line)
            }
        }
    }

    /// W530 — register ONLY the inbound `audio_frame` handler on the
    /// given WS, without touching the eager outbound fields
    /// (`wsClient` / `peerUserId`). AppState calls this once at login
    /// AND on every WS reconnect, so the dispatcher's
    /// `messageHandlers["audio_frame"]` slot is always populated
    /// before any frame can arrive — eliminating the ~5 s RX gap that
    /// was caused by `wireTransport(wsClient:peerUserId:)` only
    /// running at startCall/answer time when `liveProvider` happened
    /// to be non-nil.
    ///
    /// Idempotent: BCryptoWebSocketClient.registerHandler replaces any
    /// previous handler for the same type, so calling this on every
    /// reconnect simply re-attaches the closure on the (possibly
    /// fresh) WS instance.
    ///
    /// The handler dispatches to `handleIncomingEncryptedFrame` which
    /// no-ops via the rxPreBuffer when no call integration is bound
    /// yet (W481) — so registering early is harmless.
    public func attachIncomingAudioHandler(wsClient: BCryptoWebSocketClient) {
        wsClient.registerHandler(type: "audio_frame") { [weak self] _, data in
            guard let self,
                  let b64 = data["frame"] as? String,
                  let frameData = Data(base64Encoded: b64) else { return }
            let incomingCallId = data["call_id"] as? String
            self.handleIncomingEncryptedFrame(frameData, callId: incomingCallId)
        }
    }

    /// W67: wire del WebSocket transport per chiudere il loop audio.
    /// Chiamato da `AppState.startCall()` PRIMA di `startCall(engine:contactId:)`
    /// così la prima frame catturata può immediatamente essere instradata.
    ///
    /// Registra il handler "audio_frame" che il `BCryptoWebSocketClient`
    /// emette quando il server inoltra un audio frame del peer:
    ///   1. extract `frame` field (base64) dal payload JSON
    ///   2. decode base64 → serialized EncryptedFrame
    ///   3. handleIncomingEncryptedFrame → decrypt → AudioPlayback
    public func wireTransport(wsClient: BCryptoWebSocketClient,
                              peerUserId: String) {
        // W-SLOTLOCK — write the transport refs under the lock (the TX tap on
        // txAudioQueue reads them per frame).
        relaySlotLock.withLock {
            self.wsClient = wsClient
            self.peerUserId = peerUserId
        }

        // Register handler. BCryptoWebSocketClient.registerHandler
        // sostituisce qualsiasi precedente handler per lo stesso type,
        // quindi non serve unregister esplicito su endCall.
        wsClient.registerHandler(type: "audio_frame") { [weak self] _, data in
            guard let self,
                  let b64 = data["frame"] as? String,
                  let frameData = Data(base64Encoded: b64) else { return }
            let incomingCallId = data["call_id"] as? String
            self.handleIncomingEncryptedFrame(frameData, callId: incomingCallId)
        }
    }

    func processOutgoingAudio(pcmFrame: Data) throws -> Data {
        guard let integration = callIntegration else {
            throw CallServiceError.noIntegration
        }
        // When muted, replace PCM plaintext with silence before encryption.
        // The AEAD ciphertext still flows to the remote peer; the plaintext is zeroed.
        let frameToEncrypt = isMuted ? Data(repeating: 0, count: pcmFrame.count) : pcmFrame
        let encrypted = try integration.processOutgoingAudio(pcmFrame: frameToEncrypt)

        // Update TX waveform from raw PCM
        let txSamples = updateWaveformSamples(from: pcmFrame)
        onTxWaveformUpdate?(txSamples)

        // Update cipher waveform from encrypted output
        let cipherSamples = updateCipherSamples(from: encrypted)
        onCipherWaveformUpdate?(cipherSamples)

        return encrypted
    }

    func processIncomingAudio(frame: Data) throws -> Data {
        guard let integration = callIntegration else {
            throw CallServiceError.noIntegration
        }
        let pcm = try integration.processIncomingAudio(serializedFrame: frame)

        // Update RX waveform from decoded PCM
        let rxSamples = updateWaveformSamples(from: pcm)
        onRxWaveformUpdate?(rxSamples)

        return pcm
    }

    // MARK: - Waveform Helpers

    /// Converts PCM Int16 data to a normalized Float array suitable for waveform display.
    /// Each sample is divided by 32768.0 to produce values in the range [-1.0, 1.0].
    func updateWaveformSamples(from pcmData: Data) -> [Float] {
        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }
        var samples = [Float](repeating: 0, count: sampleCount)
        pcmData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                samples[i] = Float(int16Buffer[i]) / 32768.0
            }
        }
        return samples
    }

    /// Takes encrypted frame bytes and normalizes them as Float values for the cipher waveform.
    /// Each byte is mapped from [0, 255] to [-1.0, 1.0] to visualize the encrypted stream.
    func updateCipherSamples(from encryptedData: Data) -> [Float] {
        guard !encryptedData.isEmpty else { return [] }
        var samples = [Float](repeating: 0, count: encryptedData.count)
        encryptedData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for i in 0..<encryptedData.count {
                samples[i] = (Float(bytes[i]) / 127.5) - 1.0
            }
        }
        return samples
    }
}
