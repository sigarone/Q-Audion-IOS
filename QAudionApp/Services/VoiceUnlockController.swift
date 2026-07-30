import Foundation
import AVFoundation
import QAudionEngine

/// Feature A ("Voice-as-Key") re-authentication consumer — device-owner
/// voice unlock for the app-lock gate. Additive to `AppLockService`'s
/// PIN/biometric gate (`evaluatePolicy()`): this controller only ever calls
/// `AppLockService.unlockViaVoice()` after a `VoiceAuthGate` `.passed`
/// verdict, and `AppLockGateView` only shows the voice-unlock affordance
/// when `isAvailable` — a device with no enrolled voiceprint never sees it
/// and the existing "Sblocca" (Face ID/passcode) button is never touched.
///
/// Captures LIVE local mic audio (the device owner's own voice) via
/// `AVAudioEngine` — the same tap-and-convert shape as
/// `VoiceEnrollmentContainer` (which enrolls the template this controller
/// verifies against). Deliberately NOT the call's RX audio path — that is
/// `VoiceLearningSession`'s job (Feature B), a different tap point for a
/// different person's voice entirely.
///
/// SECURITY note on `VoiceAuthGate.verify(pcmFrame:)`: it "fails open"
/// (`.passed`) when the underlying `SpeakerVerifier` has no enrolled
/// template — a deliberate design in `VoiceAuthGate` itself (see that
/// type's doc: "No enrolled voiceprint — cannot verify, pass through"),
/// presumably so a caller that always runs the gate doesn't lock a user out
/// of a device-wide feature that assumes voice-auth. This controller relies
/// on `isAvailable` to prevent that path from ever being reachable here:
/// `start()` refuses to run at all unless `VoiceprintStore` already has a
/// `deviceOwnerId` template, so the gate it builds always starts from a
/// `.ready` (real template loaded) `SpeakerVerifier`, never an empty one.
@MainActor
final class VoiceUnlockController: ObservableObject {
    enum State: Equatable {
        case idle
        case listening(progress: Float)
        case passed
        case failed
        /// No device-owner voiceprint enrolled — `AppLockGateView` should
        /// not have called `start()` at all (see `isAvailable`), but this
        /// is the safe terminal state if it somehow did.
        case unavailable
        case error(String)
    }

    @Published private(set) var state: State = .idle

    private let audioEngine = AVAudioEngine()
    private let gate: VoiceAuthGate
    private var pendingSamples: [Float] = []

    init() {
        let verifier = SpeakerVerifier()
        if let template = VoiceprintStore().load(contactId: VoiceprintStore.deviceOwnerId) {
            verifier.importTemplate(template)
        }
        self.gate = VoiceAuthGate(verifier: verifier)
    }

    /// True only when a device-owner voiceprint has actually been enrolled
    /// (Feature A `VoiceEnrollmentContainer` completed at least once).
    /// `AppLockGateView` uses this to decide whether to render the
    /// voice-unlock affordance at all.
    var isAvailable: Bool {
        VoiceprintStore().hasTemplate(contactId: VoiceprintStore.deviceOwnerId)
    }

    /// Begin listening for the device owner's voice. `onPassed` is called
    /// exactly once, only after a genuine `.passed` verdict — the caller
    /// (`AppLockGateView`) is expected to call `AppLockService
    /// .unlockViaVoice()` from it.
    func start(onPassed: @escaping () -> Void) {
        guard isAvailable else { state = .unavailable; return }
        Task {
            do {
                try await requestMicrophonePermission()
                self.beginListening(onPassed: onPassed)
            } catch {
                self.state = .error(error.localizedDescription)
            }
        }
    }

    /// Stop listening without unlocking. Safe to call even if not
    /// currently listening.
    func cancel() {
        endAudioCapture()
        gate.cancel()
        pendingSamples.removeAll()
        state = .idle
    }

    // MARK: - Internals

    private func requestMicrophonePermission() async throws {
        if #available(iOS 17.0, *) {
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted {
                throw NSError(domain: "VoiceUnlockController", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Permesso microfono negato."])
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            let granted: Bool = await withCheckedContinuation { cont in
                session.requestRecordPermission { allowed in cont.resume(returning: allowed) }
            }
            if !granted {
                throw NSError(domain: "VoiceUnlockController", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Permesso microfono negato."])
            }
        }
    }

    private func beginListening(onPassed: @escaping () -> Void) {
        gate.startAuthentication(challenge: "device-owner")
        pendingSamples.removeAll()
        state = .listening(progress: 0)

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            // Best-effort — matches VoiceEnrollmentContainer's capture rate
            // so enrollment and verification stay on the same footing.
            try? session.setPreferredSampleRate(Double(AudioConstants.sampleRate))
            try session.setActive(true)
        } catch {
            state = .error(error.localizedDescription)
            return
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let chData = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            let frame = Array(UnsafeBufferPointer(start: chData, count: count))
            Task { @MainActor in self.consumeFloatFrame(frame, onPassed: onPassed) }
        }

        do {
            try audioEngine.start()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func consumeFloatFrame(_ frame: [Float], onPassed: @escaping () -> Void) {
        guard case .listening = state else { return }
        pendingSamples.append(contentsOf: frame)
        let frameSize = AudioConstants.samplesPerFrame
        guard frameSize > 0 else { return }

        while pendingSamples.count >= frameSize, case .listening = state {
            let chunk = Array(pendingSamples.prefix(frameSize))
            pendingSamples.removeFirst(frameSize)

            let result = gate.verify(pcmFrame: Self.pcm16Data(from: chunk))
            switch result {
            case .passed:
                endAudioCapture()
                state = .passed
                onPassed()
            case .failed:
                endAudioCapture()
                state = .failed
            case .pending:
                state = .listening(progress: gate.progress)
            }
        }
    }

    private func endAudioCapture() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Float32 (-1...1) → little-endian Int16 PCM. Same conversion shape as
    /// `VoiceEnrollmentContainer.pcm16Frames` (kept as a small local
    /// duplicate rather than a shared cross-file helper — both are ~10
    /// lines and the two call sites have different chunking needs).
    private static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let intSample = Int16(clamped * 32767.0)
            withUnsafeBytes(of: intSample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
