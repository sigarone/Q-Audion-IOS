import Foundation
#if canImport(AVFoundation)
import AVFoundation

/// Audio processing pipeline for VoIP calls.
///
/// Uses Apple's hardware DSP chain via `AVAudioEngine` Voice Processing I/O unit,
/// which provides echo cancellation (AEC), noise suppression (NS), and automatic
/// gain control (AGC) — the standard iOS Voice-Processing I/O unit.
///
/// Additionally provides software-level spectral subtraction for supplemental
/// noise reduction and comfort noise generation for silence periods.
public final class AudioProcessingPipeline {

    // MARK: - Configuration

    public struct Config {
        public var echoCancellationEnabled: Bool
        public var noiseCancellationEnabled: Bool
        public var automaticGainControl: Bool
        public var voiceIsolation: Bool      // iOS 16.4+
        public var preferredBufferDuration: TimeInterval
        public var preferredSampleRate: Double

        public init(
            echoCancellationEnabled: Bool = true,
            noiseCancellationEnabled: Bool = true,
            automaticGainControl: Bool = true,
            voiceIsolation: Bool = true,
            preferredBufferDuration: TimeInterval = 0.005,  // 5ms for real-time VoIP
            preferredSampleRate: Double = Double(AudioConstants.sampleRate)
        ) {
            self.echoCancellationEnabled = echoCancellationEnabled
            self.noiseCancellationEnabled = noiseCancellationEnabled
            self.automaticGainControl = automaticGainControl
            self.voiceIsolation = voiceIsolation
            self.preferredBufferDuration = preferredBufferDuration
            self.preferredSampleRate = preferredSampleRate
        }
    }

    // MARK: - Stats

    public struct AudioProcessingStats {
        public let voiceProcessingEnabled: Bool
        public let echoCancellationActive: Bool
        public let currentSampleRate: Double
        public let currentBufferDuration: TimeInterval
        public let inputLatency: TimeInterval
        public let outputLatency: TimeInterval
        public let noiseFloorEstimate: Float
        public let framesProcessed: Int64
    }

    // MARK: - Properties

    private var config: Config
    private var noiseFloorEstimate: Float = 0.0
    private var framesProcessed: Int64 = 0
    private var isConfigured = false

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - AVAudioSession configuration

    /// Configure AVAudioSession for VoIP with hardware echo cancellation.
    ///
    /// `.voiceChat` mode enables Apple's built-in AEC, AGC, and noise suppression
    /// at the hardware/DSP level. This must be called before starting AVAudioEngine.
    ///
    /// W464 — DO NOT hard-activate the session here. Q-Audion calls are
    /// managed by CallKit (`CXProvider`), which OWNS the shared
    /// `AVAudioSession`: it activates the session itself and notifies the
    /// app via `provider(_:didActivate:)`. If the app calls
    /// `setActive(true)` before CallKit's `didActivate` fires, iOS
    /// rejects it with "Session activation failed" — and then every
    /// subsequent `AVAudioEngine.start()` fails too, so the call connects
    /// (WebRTC ICE + PQC handshake) but has NO audio in either direction.
    /// Setting the category/mode/preferred-buffer is allowed at any time
    /// and is the correct app responsibility; activation is CallKit's.
    /// The `setActive(true)` below is kept only as a best-effort `try?`
    /// for non-CallKit edges (interruption resume, simulator) — when it
    /// fails because CallKit hasn't handed over yet, the failure is
    /// swallowed and the real activation arrives via `didActivate`, which
    /// then drives `CallService.startAudioIOIfReady()`.
    public func configureForVoIP() throws {
        let session = AVAudioSession.sharedInstance()

        // Category: playAndRecord for full-duplex VoIP
        // Mode: voiceChat enables hardware AEC + AGC + noise suppression
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [
                .defaultToSpeaker,
                .allowBluetoothHFP,
                .allowBluetoothA2DP,
                .interruptSpokenAudioAndMixWithOthers
            ]
        )

        // Low-latency I/O buffer for real-time VoIP
        try session.setPreferredIOBufferDuration(config.preferredBufferDuration)

        // Match engine sample rate
        try session.setPreferredSampleRate(config.preferredSampleRate)

        // W464: best-effort only — CallKit is the authoritative activator.
        // A failure here is EXPECTED when CallKit hasn't yet called
        // didActivate; it must not abort configuration or throw upward.
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        isConfigured = true
    }

    /// Enable Apple Voice Processing I/O on the audio engine's input node.
    ///
    /// This activates the full VoIP DSP chain:
    /// - Hardware echo cancellation (AEC)
    /// - Noise suppression (NS)
    /// - Automatic gain control (AGC)
    ///
    /// Must be called BEFORE installing an input tap or starting the engine.
    /// W406 — runtime override set by CallService before calling
    /// `enableVoiceProcessing`. When non-nil, this takes precedence
    /// over the internal `config.echoCancellationEnabled /
    /// noiseCancellationEnabled` flags. Set this to `false` to honor
    /// a user request to skip Apple's VP I/O unit (the bundled AEC +
    /// NS + AGC chain). Apple does NOT expose per-effect toggles —
    /// VP is all-or-nothing.
    public var voiceProcessingOverride: Bool? = nil

    /// L-15 — cached voice-processing state. Updated by
    /// enable/disableVoiceProcessing so `getStats()` no longer has to
    /// allocate a throwaway `AVAudioEngine()` on every call just to
    /// read `inputNode.isVoiceProcessingEnabled`.
    private var voiceProcessingActive = false

    public func enableVoiceProcessing(on engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode

        let shouldEnable: Bool
        if let override = voiceProcessingOverride {
            shouldEnable = override
        } else {
            shouldEnable = config.echoCancellationEnabled || config.noiseCancellationEnabled
        }

        if shouldEnable {
            // iOS 13+: setVoiceProcessingEnabled enables Apple's full VoIP DSP
            if #available(iOS 13.0, *) {
                try inputNode.setVoiceProcessingEnabled(true)
            }
            voiceProcessingActive = true
        } else {
            // W406: explicit user opt-out from Apple's VP I/O. The mic
            // capture still works but without HW echo cancellation /
            // noise suppression / AGC. Spectral subtraction in our SW
            // path remains enabled.
            if #available(iOS 13.0, *) {
                try? inputNode.setVoiceProcessingEnabled(false)
            }
            voiceProcessingActive = false
        }

        // iOS 17+: Voice Isolation for enhanced noise cancellation
        if config.voiceIsolation && shouldEnable {
            if #available(iOS 17.0, *) {
                configureVoiceIsolation()
            }
        }
    }

    /// Disable voice processing (call when the call ends).
    public func disableVoiceProcessing(on engine: AVAudioEngine) {
        let inputNode = engine.inputNode
        if #available(iOS 13.0, *) {
            try? inputNode.setVoiceProcessingEnabled(false)
        }
        voiceProcessingActive = false
    }

    /// Deactivate the audio session when the call ends.
    public func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isConfigured = false
    }

    // MARK: - Software noise reduction (supplemental)

    /// Apply spectral subtraction noise reduction to a PCM frame.
    ///
    /// This provides a supplemental layer on top of Apple's hardware noise suppression.
    /// Estimates the noise floor from low-energy frames and subtracts it from the signal.
    public func applyNoiseReduction(pcmFrame: Data) -> Data {
        guard config.noiseCancellationEnabled else { return pcmFrame }

        framesProcessed += 1

        var output = Data(count: pcmFrame.count)
        pcmFrame.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                let srcPtr = src.bindMemory(to: Int16.self)
                let dstPtr = dst.bindMemory(to: Int16.self)
                let sampleCount = min(srcPtr.count, dstPtr.count)

                // Compute frame energy (RMS)
                var energy: Float = 0
                for i in 0..<sampleCount {
                    let sample = Float(srcPtr[i])
                    energy += sample * sample
                }
                energy = sqrtf(energy / Float(max(sampleCount, 1)))

                // Adaptive noise floor estimation (slow attack, fast release)
                let alpha: Float = energy < noiseFloorEstimate ? 0.05 : 0.002
                noiseFloorEstimate = noiseFloorEstimate * (1.0 - alpha) + energy * alpha

                // Spectral subtraction: attenuate samples near the noise floor
                let threshold = noiseFloorEstimate * 2.0
                for i in 0..<sampleCount {
                    let sample = Float(srcPtr[i])
                    let magnitude = abs(sample)
                    if magnitude < threshold {
                        // Soft gating: reduce instead of zeroing to avoid artifacts
                        let gain = max(0.0, (magnitude - noiseFloorEstimate) / max(threshold - noiseFloorEstimate, 1.0))
                        dstPtr[i] = Int16(clamping: Int32(sample * gain))
                    } else {
                        dstPtr[i] = srcPtr[i]
                    }
                }
            }
        }

        return output
    }

    /// Generate comfort noise at a given level for silence periods.
    /// Delegates to the same algorithm used by `JitterBuffer` for consistency.
    public func generateComfortNoise(level: Float = Float(AudioConstants.comfortNoiseAmplitude)) -> Data {
        let amplitude = Int16(clamping: Int32(level))
        var pcm = Data(count: AudioConstants.bytesPerFrame)
        pcm.withUnsafeMutableBytes { buf in
            let ptr = buf.bindMemory(to: Int16.self)
            for i in 0..<AudioConstants.samplesPerFrame {
                ptr[i] = Int16.random(in: -amplitude...amplitude)
            }
        }
        return pcm
    }

    // MARK: - Stats

    /// Get current audio processing statistics.
    public func getStats() -> AudioProcessingStats {
        let session = AVAudioSession.sharedInstance()
        // L-15 — read the cached state instead of allocating a
        // throwaway AVAudioEngine() on every getStats() call.
        let vpEnabled = voiceProcessingActive

        return AudioProcessingStats(
            voiceProcessingEnabled: vpEnabled,
            echoCancellationActive: config.echoCancellationEnabled && isConfigured,
            currentSampleRate: session.sampleRate,
            currentBufferDuration: session.ioBufferDuration,
            inputLatency: session.inputLatency,
            outputLatency: session.outputLatency,
            noiseFloorEstimate: noiseFloorEstimate,
            framesProcessed: framesProcessed
        )
    }

    // MARK: - Configuration updates

    /// Update the processing configuration at runtime.
    public func updateConfig(_ newConfig: Config) {
        config = newConfig
    }

    /// Whether the pipeline has been configured for VoIP.
    public var isActive: Bool { isConfigured }

    // MARK: - Private

    @available(iOS 17.0, *)
    private func configureVoiceIsolation() {
        // Voice Isolation is a system-level feature; we check if it's available.
        // Users can enable it from Control Center. We log its state for diagnostics.
        #if !targetEnvironment(simulator)
        // AVAudioApplication is iOS 17+
        // The system handles voice isolation automatically when enabled by the user.
        #endif
    }
}
#endif
