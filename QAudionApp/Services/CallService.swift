import Foundation
import QAudionEngine

final class CallService {
    var callIntegration: QAudionCallIntegration?
    var onDeepfakeAlert: ((Bool) -> Void)?
    var onDeepfakeScore: ((ConfidenceIndex.Level, Float) -> Void)?
    var onTxWaveformUpdate: (([Float]) -> Void)?
    var onRxWaveformUpdate: (([Float]) -> Void)?
    var onCipherWaveformUpdate: (([Float]) -> Void)?

    /// W65: Audio processing pipeline che attiva HW AEC + AGC + NS via
    /// Apple Voice Processing I/O unit. Configurato all'inizio di ogni
    /// chiamata, deactivato all'`endCall()`. Pre-W65 le chiamate VoIP
    /// suonavano "eco-y, rumorose, volumi inconsistenti" perché
    /// AVAudioSession era in mode default (`.solo`) — ora `.voiceChat`
    /// trigger l'intero stack DSP hardware.
    ///
    /// NOTA: `AudioProcessingPipeline` espone anche `AudioCapture` /
    /// `AudioPlayback` con installTap/playerNode wiring completo, ma
    /// quelli rimangono dormienti perché il network transport
    /// (sendAudioFrame WS → processIncomingAudio loop) non è ancora
    /// wired a livello CallService — è ENGINE WT
    /// (`QAudionCallIntegration.processOutgoingAudio` returns encrypted
    /// bytes che vanno consegnati al `BCryptoWebSocketClient
    /// .sendAudioFrame(recipientId:frame:)`, scope engine team).
    ///
    /// Anche solo il `configureForVoIP()` (che NON cattura il mic ma
    /// sets system-wide AVAudioSession) garantisce HW AEC/NS/AGC su
    /// QUALSIASI altro path che catturi il mic durante la chiamata —
    /// inclusi C-level capture nel core engine.
    private var audioPipeline: AudioProcessingPipeline?

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
        // W65: defensive cleanup se startCall è chiamato 2x senza endCall
        // (caso che NON dovrebbe succedere ma proteggiamo da leak della
        // session). NVIDIA review punto #2.
        if let oldPipeline = audioPipeline {
            oldPipeline.deactivateSession()
            audioPipeline = nil
        }

        // W65: PRIMA cosa — configura AVAudioSession in `.voiceChat` mode
        // per attivare lo stack HW DSP di Apple (Voice Processing I/O):
        //   - Echo cancellation (AEC)         — cancella il feedback dello speaker
        //   - Noise suppression (NS)          — riduce rumore ambientale
        //   - Automatic gain control (AGC)    — normalizza volume voce
        //   - Voice Isolation (iOS 17+)       — isolamento neural-net del parlato
        //   - Bluetooth A2DP/HFP routing      — auricolari wireless supportati
        //   - 5ms IO buffer                   — bassa latenza real-time
        //
        // Best-effort: se la pipeline fallisce (sim / permission denied) la
        // chiamata continua comunque — meglio audio sub-ottimale che chiamata
        // bloccata. Errore silenziato in console per diagnosi.
        let pipeline = AudioProcessingPipeline()
        do {
            try pipeline.configureForVoIP()
            self.audioPipeline = pipeline
        } catch {
            print("[CallService] AVAudioSession.voiceChat config failed: \(error.localizedDescription) — fallback a session default")
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

        try integration.onCallSetupStarted { data in
            // Transport layer sends opaque message to remote peer.
            // Actual network transport is handled by the signaling layer.
        }

        self.callIntegration = integration
        startDurationTimer()
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

        // W65: rilascia la AVAudioSession voiceChat mode così il sistema
        // può tornare a una session generica (es. media playback in
        // background) senza tenere il VP IO unit attivo inutilmente.
        // `notifyOthersOnDeactivation` riattiva eventuali altre app
        // che erano state interrotte da `interruptSpokenAudioAndMixWithOthers`.
        audioPipeline?.deactivateSession()
        audioPipeline = nil
    }

    func processOutgoingAudio(pcmFrame: Data) throws -> Data {
        guard let integration = callIntegration else {
            throw CallServiceError.noActiveCall
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
            throw CallServiceError.noActiveCall
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

enum CallServiceError: Error, LocalizedError {
    case noActiveCall
    case setupFailed

    var errorDescription: String? {
        switch self {
        case .noActiveCall: return "No active call session"
        case .setupFailed: return "Call setup failed"
        }
    }
}
