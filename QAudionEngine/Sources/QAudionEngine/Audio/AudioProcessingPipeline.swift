import Foundation
#if canImport(UIKit)
import UIKit   // W574f — UIDevice.userInterfaceIdiom for the iPad VP-IO gate
#endif
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
            // W556 — default flipped to `false`.
            // When CallsGate.anyVoiceProcessingEnabled is used as
            // voiceProcessingOverride (the production path in CallService),
            // this value is ignored — the override wins. This default
            // matters only for standalone AudioProcessingPipeline usage
            // (SelfTestService, unit tests, simulator). Flipping it to
            // `false` means no VP-IO in those paths either, matching the
            // production default and avoiding NS artefacts in test audio.
            //
            // See CallsGate.aecEnabled for the full rationale behind
            // defaulting all VP-IO flags to false (W556).
            echoCancellationEnabled: Bool = false,
            // W555 — was `true` by default. This flag gates BOTH Apple's
            // Voice-Processing noise-suppression AND the per-sample
            // "soft-gating" inside `applyNoiseReduction()` (which is
            // commented as spectral subtraction but is actually a
            // sample-domain noise gate). The sample-domain gate
            // attenuates samples below ~2× noise-floor, producing
            // envelope pumping + transient distortion BEFORE Opus
            // sees the signal. Android has NO equivalent pre-Opus
            // step — that's the audio-quality gap iPhone→S24
            // reported on the 2026-05-27 test call.
            //
            // Apple's hardware VP-IO already handles noise suppression
            // much better than our naive software gate. Keeping the
            // flag for explicit user control but flipping default to
            // `false` so the pre-Opus pipeline matches Android's
            // (= identity passthrough). Receiver still gets HW NS via
            // the VP-IO chain — just no double-attenuation.
            noiseCancellationEnabled: Bool = false,
            automaticGainControl: Bool = false,   // W556: was true, VP-IO off by default
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
        //
        // W556 — removed `.allowBluetoothA2DP` from VoIP options.
        // A2DP is a high-quality STEREO OUTPUT profile (no mic input).
        // In `.voiceChat` mode iOS must use HFP for Bluetooth devices
        // (HFP = 16 kHz mono, bidirectional). Having `.allowBluetoothA2DP`
        // alongside `.allowBluetoothHFP` caused iOS to route PLAYBACK
        // through A2DP (high-quality) while the CAPTURE path fell back
        // to HFP — but the routing decision is made per-session start
        // and can flip mid-call when the user's headset state changes,
        // producing an audible glitch. More critically, when the device
        // was in A2DP output mode, `setVoiceProcessingEnabled(true)` on
        // the inputNode attached VP-IO to a capture node that was wired
        // to the HFP SCO codec (8/16 kHz) rather than the built-in mic's
        // 48 kHz path — the NS/AEC saw a 16 kHz signal and applied a
        // filter designed for that bandwidth to a resampled 48 kHz
        // stream, producing exactly the metallic coloring reported by
        // the user on the 2026-05-27 call. Removing A2DP from VoIP
        // forces iOS to use HFP for BOTH directions (or the built-in
        // mic/speaker), keeping the VP-IO attachment consistent.
        // W557 — removed `.defaultToSpeaker`.
        //
        // `.defaultToSpeaker` routed audio to the EXTERNAL loudspeaker
        // instead of the earpiece. On iPhone this means the speaker
        // output physically bleeds back into the microphone (room echo).
        // With VP-IO disabled (W556), there is no software AEC to cancel
        // that loop → the S24 receiver hears the iPhone's own speaker
        // echo mixed with the mic signal → metallic / washy artefact.
        //
        // The correct VoIP default is the EARPIECE, which is physically
        // isolated from the mic (no echo path). The user can switch to
        // speaker via the speaker button in InCallScreen, which calls
        // `AVAudioSession.overrideOutputAudioPort(.speaker)`.
        //
        // When the user switches to speaker mode AND is in a noisy
        // environment, they can enable AEC in Settings → Chiamate →
        // Echo Cancellation to re-activate VP-IO. For the common
        // earpiece case, no AEC is needed.
        #if os(iOS) && !targetEnvironment(simulator)
        let audioOpts: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .interruptSpokenAudioAndMixWithOthers]
        #else
        let audioOpts: AVAudioSession.CategoryOptions = [.interruptSpokenAudioAndMixWithOthers]
        #endif
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: audioOpts)

        // Low-latency I/O buffer for real-time VoIP
        try session.setPreferredIOBufferDuration(config.preferredBufferDuration)

        // Match engine sample rate
        try session.setPreferredSampleRate(config.preferredSampleRate)

        // W574c — pin the built-in mic as preferred input. On iPad the
        // voice-processing path expects the bottom (voice-chat) mic; when
        // the system picks a different array mic, enabling VP-IO with the
        // builtInSpeaker route can silently stop input callbacks (no tap
        // buffers → dead TX). Best-effort: external mics (headset/BT HFP)
        // still win automatically when their route is active, because
        // preferredInput only applies to the built-in route selection.
        if let builtInMic = session.availableInputs?.first(
            where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtInMic)
        }

        // W464: best-effort only — CallKit is the authoritative activator.
        // A failure here is EXPECTED when CallKit hasn't yet called
        // didActivate; it must not abort configuration or throw upward.
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        isConfigured = true
    }

    /// W556 — emit `call.media.session_config` telemetry right after the
    /// session is configured (but before VP-IO enable). This records the
    /// ACTUAL sample rate and buffer duration iOS granted vs the preferred
    /// values, the current Bluetooth route, and the VP-IO state. Used to
    /// diagnose metallic/choppy artefacts on the dashboard without a device.
    ///
    /// Must be called AFTER `configureForVoIP()` and `enableVoiceProcessing()`.
    public func emitSessionDiagnostics(vpioEnabled: Bool) {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let outputPorts = route.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let inputPorts  = route.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let actualSR    = session.sampleRate
        let actualBuf   = session.ioBufferDuration
        let preferredSR = config.preferredSampleRate
        let preferredBuf = config.preferredBufferDuration

        // Build the log line inside a single let — avoids Swift 6
        // type-checker timeout in nested closures (CLAUDE.md lesson 13).
        let line: String = "[AudioProcessingPipeline] W556 session: "
            + "sr=" + String(describing: actualSR)
            + " (pref=" + String(describing: preferredSR) + ")"
            + " buf=" + String(describing: actualBuf)
            + " (pref=" + String(describing: preferredBuf) + ")"
            + " vpio=" + String(describing: vpioEnabled)
            + " in=" + inputPorts
            + " out=" + outputPorts
        print(line)
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

    /// W574c — speaker-route AEC policy ("regola vivavoce"): when the
    /// CURRENT output route includes the built-in loudspeaker, Apple's
    /// VP-IO echo cancellation is force-enabled REGARDLESS of the user
    /// AEC toggle. Rationale: on the external speaker the output
    /// physically feeds back into the mic — without AEC the far end
    /// hears severe echo (iPad has no earpiece, so EVERY iPad call is
    /// a speaker call; iPhone hits this when the user taps speaker).
    /// On earpiece/headset routes the user toggle (override/config)
    /// stays authoritative, preserving the W556 no-VP-IO default that
    /// avoids NS artefacts. Set to `false` to restore pre-W574c
    /// behaviour (toggle-only).
    public var enableAecOnSpeakerRoute: Bool = true

    /// True when the active AVAudioSession output route includes the
    /// built-in loudspeaker (`.builtInSpeaker`). The earpiece reports
    /// `.builtInReceiver`, so this cleanly separates speakerphone from
    /// the normal handset route.
    public static func currentRouteHasBuiltInSpeaker() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { $0.portType == .builtInSpeaker }
    }

    /// W574f — VP-IO single-engine TX-capture is broken on iPad: enabling
    /// `setVoiceProcessingEnabled(true)` on the iPad's built-in-speaker
    /// route leaves the input tap callback silent (no buffers ever arrive
    /// → tx_enc=0; confirmed call 8bfdbad1, iPad callee). The Float32 tap
    /// fallback (W574) cannot help because the callback never fires at all
    /// — this is the documented iPad VP-IO + builtInSpeaker failure mode,
    /// NOT a format mismatch. The W556 history proves iPad TX works with
    /// VP-IO OFF. So the speaker-route AEC force (W574c) must NOT apply on
    /// iPad: working audio beats echo cancellation. iPad keeps no-VP-IO on
    /// speaker (echo remains — tracked as a follow-up needing a capture
    /// path that survives VP-IO, e.g. a dedicated VP-IO engine or software
    /// AEC). iPhone is unaffected (its tap works under VP-IO).
    private static var isPad: Bool {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    /// L-15 — cached voice-processing state. Updated by
    /// enable/disableVoiceProcessing so `getStats()` no longer has to
    /// allocate a throwaway `AVAudioEngine()` on every call just to
    /// read `inputNode.isVoiceProcessingEnabled`.
    private var voiceProcessingActive = false

    public func enableVoiceProcessing(on engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode

        // W574c — evaluated at engine-(re)start time. AudioCapture restarts
        // the engine on route changes (including the speaker override), so
        // toggling the in-call speaker button re-runs this decision.
        // W574f — EXCLUDE iPad: VP-IO kills the iPad tap (tx_enc=0). iPad
        // keeps no-VP-IO on speaker (echo, but working TX). iPhone only.
        let speakerRoute = enableAecOnSpeakerRoute
            && !Self.isPad
            && Self.currentRouteHasBuiltInSpeaker()

        let shouldEnable: Bool
        if speakerRoute {
            shouldEnable = true
        } else if let override = voiceProcessingOverride {
            shouldEnable = override
        } else {
            shouldEnable = config.echoCancellationEnabled || config.noiseCancellationEnabled
        }

        if shouldEnable {
            // iOS 13+: setVoiceProcessingEnabled enables Apple's full VoIP DSP
            if #available(iOS 13.0, *) {
                try inputNode.setVoiceProcessingEnabled(true)
                // W537: disable the Voice-Processing AGC component.
                // User-reported "qualità scarsa nella codifica da iPad
                // ad Android" was traced to Apple's AGC compressing/
                // expanding the speech envelope inside the VP I/O unit
                // BEFORE Opus saw it. Opus's own rate-distortion and
                // SILK pitch tracking work BEST with a clean, un-AGC-
                // mangled signal — and Android's reference build sets
                // `OpusConfig(agcEnabled = false)` (no system AGC, no
                // pre-Opus AGC). Matching that wire-shape on iOS removes
                // the dynamic-range pumping artefact the receiver hears.
                // AEC + NS are preserved (they're separate VP knobs).
                //
                // The setter is a non-throwing property (per Apple's
                // AVAudioInputNode docs); writing it before voice
                // processing has finalised setup is silently ignored
                // by AVAudioEngine on some iOS versions. We wrap the
                // assignment in a try? on its KVC form to absorb
                // that case without crashing.
                // W574c — AGC follows the route. On SPEAKERPHONE the mic
                // is far from the mouth and the captured level is low
                // ("audio molto basso" report from the iPad side): Apple's
                // VP AGC is exactly the right tool there. On earpiece /
                // headset routes keep W537 behaviour (AGC off — Opus gets
                // the raw mic, no envelope pumping).
                inputNode.isVoiceProcessingAGCEnabled = speakerRoute
                let agcState: String = speakerRoute ? "ENABLED (speaker route)" : "disabled (W537)"
                print("[AudioProcessingPipeline] voice-processing AGC " + agcState)
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

        // W556 — emit session diagnostics so the maintainer can see
        // the ACTUAL sample rate / buffer / routing on every call from
        // the telemetry dashboard, without needing a device.
        emitSessionDiagnostics(vpioEnabled: voiceProcessingActive)
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

    /// Bug B robustness — best-effort (re)activate the shared session.
    /// Used by the CallService didActivate-fallback: when CallKit SKIPS its
    /// `provider(_:didActivate:)` (the session was already active from
    /// `configureForVoIP`'s setActive or a prior call), the engines must still
    /// start under a definitely-active session. Idempotent / harmless if the
    /// session is already active.
    public func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
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
