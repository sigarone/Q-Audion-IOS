import Foundation
import QAudionEngine

final class CallService {
    var callIntegration: QAudionCallIntegration?
    var onDeepfakeAlert: ((Bool) -> Void)?
    var onDeepfakeScore: ((ConfidenceIndex.Level, Float) -> Void)?
    var onTxWaveformUpdate: (([Float]) -> Void)?
    var onRxWaveformUpdate: (([Float]) -> Void)?
    var onCipherWaveformUpdate: (([Float]) -> Void)?

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
    private var loggedFirstTxCapture = false
    private var loggedFirstTxEncrypt = false
    private var loggedTxNoTransport = false
    private var loggedFirstRxReceive = false
    private var loggedRxNoIntegration = false
    private var loggedFirstRxDecrypt = false
    private var loggedRxNoPlayback = false

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
    // the AVFAudio tap thread, not main. AppState only sets `liveProvider`
    // and `callContactId` from main, but a stale read across threads is
    // acceptable for this fallback (worst case: drops the very first
    // frame and binds on the second). They MUST stay nullary `() -> ...`.
    public typealias WsClientProvider = () -> BCryptoWebSocketClient?
    public typealias PeerIdProvider = () -> String?
    /// Returns true iff the call is in an active/encrypted state — used
    /// by the W469 fallback timer to skip self-activation during outgoing
    /// ring (before the peer has answered). Wired by AppState at login.
    public typealias CallActiveProvider = () -> Bool
    public var getWsClient: WsClientProvider?
    public var getPeerId: PeerIdProvider?
    public var isCallActive: CallActiveProvider?
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
                    self?.processAndSendEncryptedFrame(pcmFrame: pcmFrame, integration: integration)
                }
                return
            }
            self.processAndSendEncryptedFrame(pcmFrame: pcmFrame, integration: integration)
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
            case .error:
                self.endCall()
            case .fallback:
                // W461: PQC handshake timed out. WebRTC DTLS audio may still be
                // flowing — do NOT tear down the call here. The 30s fallback is
                // purely a "handshake slow" signal. Ending the call here caused
                // the exact 30s drop bug (iPad→A50 calls always dropped at :30).
                // The call will end normally when either side hangs up.
                print("[CallService] PQC handshake fallback — keeping call alive, audio continues via WebRTC DTLS. Diagnose: check Android ACCEPT routing and callId case match.")
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
            // Only self-activate when the call is actually connected (peer
            // answered). During outgoing ring this must not open the mic —
            // the peer hasn't answered yet and early audio activation leaks
            // the session and causes the waveform to animate before answer.
            guard self.isCallActive?() == true else {
                print("[CallService] W469 — skipped; call not active (peer has not answered)")
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
        // Defensive cleanup: stop any leftover capture from a previous call.
        teardownAudioStack()

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
                    self?.processAndSendEncryptedFrame(
                        pcmFrame: pcmFrame, integration: integration)
                }
                return
            }
            self.processAndSendEncryptedFrame(pcmFrame: pcmFrame, integration: integration)
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
        startAudioIOIfReady()

        // Bind the integration so handleIncomingEncryptedFrame can decrypt
        // inbound audio_frame packets.
        self.callIntegration = integration
        drainRxPreBuffer()  // W481 — replay any frames that arrived before binding
        startDurationTimer()
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
            capabilities: CallCapabilities.local,
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

    func endCall() {
        callIntegration?.onCallEnded()
        callIntegration = nil
        onDeepfakeAlert?(false)
        stopDurationTimer()
        callStartedAt = nil
        callDurationSeconds = 0
        isMuted = false
        isOnHold = false

        // W65+W66: stop capture/playback + rilascia AVAudioSession.
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
            do {
                let pcm = try integration.processIncomingAudio(serializedFrame: frame)
                framesDecryptedRx &+= 1
                audioPlayback?.playFrame(pcm)
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
    public func handleIncomingEncryptedFrame(_ serializedFrame: Data) {
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
            do {
                let pcm = try integration.processIncomingAudio(serializedFrame: serializedFrame)
                self.framesDecryptedRx &+= 1
                if !self.loggedFirstRxDecrypt {
                    self.loggedFirstRxDecrypt = true
                    print("[CallService] RX: first frame DECRYPTED ok — AEAD+Opus decode live")
                }
                if let pb = self.audioPlayback {
                    pb.playFrame(pcm)
                } else if !self.loggedRxNoPlayback {
                    self.loggedRxNoPlayback = true
                    print("[CallService] RX: decrypted frame but audioPlayback is nil — not audible")
                }
                if self.framesDecryptedRx % 250 == 0 {
                    let n: String = self.framesDecryptedRx.description
                    let line: String = "[CallService] RX heartbeat: " + n + " frames decrypted+played"
                    print(line)
                }
                let rxSamples = self.updateWaveformSamples(from: pcm)
                self.onRxWaveformUpdate?(rxSamples)
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
    private func teardownAudioStack() {
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
        loggedFirstTxCapture = false
        loggedFirstTxEncrypt = false
        loggedTxNoTransport = false
        loggedFirstRxReceive = false
        loggedRxNoIntegration = false
        loggedFirstRxDecrypt = false
        loggedRxNoPlayback = false
        rxPreBuffer.removeAll()  // W481
        // W464 — drop the session-active flag so the NEXT call starts
        // from a clean slate and waits for its own CallKit `didActivate`.
        audioSessionActive = false
        // W67: reset transport binding. Nota: NON disconnect-iamo il
        // wsClient (può restare connesso per signaling / chat / contacts).
        // Solo facciamo nil-out i riferimenti così future audio frames
        // non triggherano send/playback.
        wsClient = nil
        peerUserId = nil
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
        guard audioSessionActive else {
            print("[CallService] audio I/O deferred — waiting for CallKit didActivate")
            return
        }
        if let playback = audioPlayback {
            do {
                try playback.start()
            } catch {
                // CLAUDE.md §13 — build the String before the print call.
                let desc: String = error.localizedDescription
                let line: String = "[CallService] AudioPlayback start failed: " + desc
                print(line)
            }
        }
        if let capture = audioCapture {
            do {
                try capture.start()
            } catch {
                let desc: String = error.localizedDescription
                let line: String = "[CallService] AudioCapture start failed: " + desc + " — chiamata continua senza HW VP"
                print(line)
            }
        }
    }

    /// W464 — CallKit activated the shared `AVAudioSession`. This is the
    /// only safe moment to spin up the mic-capture / speaker-playback
    /// `AVAudioEngine`s. Wired from `AppState` to
    /// `CallKitProvider.onAudioSessionActivated`. Runs on the main thread.
    public func handleAudioSessionActivated() {
        audioSessionActive = true
        startAudioIOIfReady()
    }

    /// W464 — CallKit released the audio session (call ending or
    /// interrupted). Future audio-engine starts must wait for the next
    /// `didActivate`. Wired from `CallKitProvider.onAudioSessionDeactivated`.
    public func handleAudioSessionDeactivated() {
        audioSessionActive = false
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
    private func processAndSendEncryptedFrame(pcmFrame: Data,
                                               integration: QAudionCallIntegration) {
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
            // silence. Persist on first successful recovery so subsequent
            // frames in the call skip the closure call.
            let effectiveWs = wsClient ?? getWsClient?()
            let effectivePeer = peerUserId ?? getPeerId?()
            if let ws = effectiveWs, let peer = effectivePeer {
                // W522 — when the W476 lazy fallback rescues TX (wireTransport
                // was never called because liveProvider was nil at startCall),
                // we ALSO need to register the audio_frame RX handler. Without
                // this branch the iPad encrypts+sends correctly but never sees
                // any inbound audio_frame from the peer: the symptom is the
                // remote side hears us but we hear silence (confirmed in
                // session bbe9a2ff, 1.0.520 — TX heartbeat reaches 3000 frames
                // while RX heartbeat is never emitted).
                let needsRxRegistration: Bool = (wsClient == nil)
                if wsClient == nil { wsClient = ws }
                if peerUserId == nil { peerUserId = peer }
                if needsRxRegistration {
                    ws.registerHandler(type: "audio_frame") { [weak self] _, data in
                        guard let self,
                              let b64 = data["frame"] as? String,
                              let frameData = Data(base64Encoded: b64) else { return }
                        self.handleIncomingEncryptedFrame(frameData)
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
                ws.sendAudioFrame(recipientId: peer, frame: wireFrame)
                if !loggedFirstTxWire {
                    loggedFirstTxWire = true
                    let fmt: String = androidAudioWireCompat ? "WireRelayFrameCodec" : "FrameEncoder"
                    let a: String = encrypted.count.description
                    let b: String = wireFrame.count.description
                    let line: String = "[CallService] TX: wire format = " + fmt + " (" + a + "->" + b + " bytes)"
                    print(line)
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
            // W466 — previously a SILENT catch that hid every Opus/AEAD
            // failure. Pre-handshake errors ARE expected for the first
            // ~second (session key not derived yet); log the first one
            // and then every 250th so the telemetry shows whether they
            // stop (handshake completed) or continue (real crypto bug).
            txEncryptErrorCount &+= 1
            if txEncryptErrorCount == 1 || txEncryptErrorCount % 250 == 0 {
                let desc: String = error.localizedDescription
                let cnt: String = txEncryptErrorCount.description
                let line: String = "[CallService] TX encrypt FAILED (x" + cnt + "): " + desc
                print(line)
            }
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
        self.wsClient = wsClient
        self.peerUserId = peerUserId

        // Register handler. BCryptoWebSocketClient.registerHandler
        // sostituisce qualsiasi precedente handler per lo stesso type,
        // quindi non serve unregister esplicito su endCall.
        wsClient.registerHandler(type: "audio_frame") { [weak self] _, data in
            guard let self,
                  let b64 = data["frame"] as? String,
                  let frameData = Data(base64Encoded: b64) else { return }
            self.handleIncomingEncryptedFrame(frameData)
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
