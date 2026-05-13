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

    /// W67: WebSocket transport binding. Quando setato via
    /// `wireTransport(wsClient:peerUserId:)`, il loop chiude:
    ///   TX: capture.onFrame → encrypt → wsClient.sendAudioFrame
    ///   RX: wsClient handler "audio_frame" → handleIncomingEncryptedFrame
    /// Quando nil, le encrypted bytes restano locali (counter only).
    private var wsClient: BCryptoWebSocketClient?
    private var peerUserId: String?
    /// Token usato per de-registrare il handler "audio_frame" su endCall
    /// — assumiamo che `registerHandler` sostituisca il precedente per
    /// type, quindi de-register è no-op (ma resettiamo wsClient così
    /// future incoming frames non triggherano playback senza session).

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

        do {
            try playback.start()
            self.audioPlayback = playback
        } catch {
            print("[CallService] AudioPlayback start failed: \(error.localizedDescription)")
        }

        do {
            try capture.start()
            self.audioCapture = capture
        } catch {
            print("[CallService] AudioCapture start failed: \(error.localizedDescription) — chiamata continua senza HW VP")
        }

        let integration = QAudionCallIntegration()

        integration.onStateChanged = { [weak self] state in
            guard let self else { return }
            switch state {
            case .active:
                break
            case .error, .fallback:
                self.endCall()
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
        callerDisplay: String? = nil
    ) async throws {
        // Snapshot to local strong ref — prevents use-after-free if
        // another Task tears down callIntegration mid-await.
        guard let integration = self.callIntegration else {
            throw CallServiceError.noIntegration
        }

        // 1) call_offer (vestigial empty SDP — WIRE_SPEC §3 SDP-less
        //    PQC path uses opaque_message OFFER for the actual crypto).
        //    `callerDisplay` (when non-nil) is shipped as the
        //    `caller_display` JSON field — the callee's CallKit prefers
        //    it over the server-resolved extension.
        let vestigialSdp = ""
        try await callingApi.sendCallOfferWithId(
            callId: callId,
            recipientId: recipientId,
            sdp: vestigialSdp,
            capabilities: CallCapabilities.local,
            callerDisplay: callerDisplay
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
            guard let self = self,
                  let integration = self.callIntegration else { return }
            do {
                let pcm = try integration.processIncomingAudio(serializedFrame: serializedFrame)
                self.framesDecryptedRx &+= 1
                self.audioPlayback?.playFrame(pcm)
                let rxSamples = self.updateWaveformSamples(from: pcm)
                self.onRxWaveformUpdate?(rxSamples)
            } catch {
                print("[CallService] processIncomingAudio failed: \(error.localizedDescription)")
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
        // W67: reset transport binding. Nota: NON disconnect-iamo il
        // wsClient (può restare connesso per signaling / chat / contacts).
        // Solo facciamo nil-out i riferimenti così future audio frames
        // non triggherano send/playback.
        wsClient = nil
        peerUserId = nil
    }

    /// W69 helper: encrypt + waveform-update + network-send routine
    /// extracted from `capture.onFrame` per essere call-able sia dal
    /// fast path (NetworkSim Off) che dal task-isolated delay path
    /// (NetworkSim HighLatency/Satellite).
    private func processAndSendEncryptedFrame(pcmFrame: Data,
                                               integration: QAudionCallIntegration) {
        do {
            let encrypted = try integration.processOutgoingAudio(pcmFrame: pcmFrame)
            framesEncryptedTx &+= 1
            let txSamples = updateWaveformSamples(from: pcmFrame)
            let cipherSamples = updateCipherSamples(from: encrypted)
            Task { @MainActor [weak self] in
                self?.onTxWaveformUpdate?(txSamples)
                self?.onCipherWaveformUpdate?(cipherSamples)
            }
            if let ws = wsClient, let peer = peerUserId {
                ws.sendAudioFrame(recipientId: peer, frame: encrypted)
            }
        } catch {
            // Silent: pre-session-active errors sono attesi durante handshake.
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
