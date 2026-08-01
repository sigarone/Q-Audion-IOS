import SwiftUI
import AVFoundation
import QAudionEngine

@MainActor
final class VoiceEnrollmentContainer: ObservableObject {

    enum Error: Swift.Error, LocalizedError {
        case microphonePermissionDenied
        case audioEngineFailedToStart(String)
        case noPromptAvailable

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied: return "Microphone permission denied. Enable in Settings → Q-Audion → Microphone."
            case .audioEngineFailedToStart(let m): return "Audio engine failed: \(m)"
            case .noPromptAvailable: return "No prompts to read"
            }
        }
    }

    @Published private(set) var viewModel: VoiceEnrollmentViewModel
    @Published private(set) var isRecording: Bool = false
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var recordedSamples: [Float] = []
    // 2026-07-30: was 8.0 — way over what's actually needed (the accumulator
    // only needs ~150 total 20ms frames == 3s of speech across ALL 3
    // prompts combined, ~1s each on average) and read as "stuck"/"takes
    // forever" since nothing here auto-advances early. 3.0 matches
    // Android's per-prompt SAMPLE_DURATION exactly.
    private var maxDurationSeconds: TimeInterval = 3.0
    private var recordingStartedAt: Date?

    /// Feature A ("Voice-as-Key") real pipeline — the CAM++ neural speaker
    /// matcher that consumes the audio captured below. Accumulates
    /// frames across ALL prompts in this session (one call to
    /// `startEnrollment()` per full `start()`, NOT per prompt); the multi-
    /// prompt flow builds ONE device-owner template.
    private let speakerVerifier = SpeakerVerifier(embedder: CamPlusSpeakerEmbedder.shared)
    /// Keychain-backed (`VoiceprintStore`) — persists the finished template
    /// under `VoiceprintStore.deviceOwnerId` so it survives an app restart
    /// and can be loaded later by `VoiceUnlockController`/`VoiceAuthGate`.
    private let voiceprintStore = VoiceprintStore()

    init(initial: VoiceEnrollmentViewModel = .mock) {
        self.viewModel = initial
    }

    func start() {
        Task {
            do {
                try await requestMicrophonePermission()
                if let firstPrompt = viewModel.prompts.first {
                    await MainActor.run {
                        // Fresh enrollment session — clears any partial
                        // frames from a previous attempt (retry after
                        // .error, or a second full pass).
                        self.speakerVerifier.startEnrollment()
                        self.viewModel.transition(to: .promptShowing(prompt: firstPrompt))
                    }
                } else {
                    throw Error.noPromptAvailable
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.viewModel.transition(to: .error(message: error.localizedDescription))
                }
            }
        }
    }

    func startRecordingPrompt() {
        guard case .promptShowing(let prompt) = viewModel.step else { return }

        do {
            try setupAudioSession()
            try beginAudioCapture()
            recordingStartedAt = Date()
            recordedSamples = []
            viewModel.transition(to: .recording(prompt: prompt, secondsElapsed: 0))
            isRecording = true
        } catch {
            errorMessage = "Recording failed: \(error.localizedDescription)"
            viewModel.transition(to: .error(message: errorMessage ?? ""))
        }
    }

    func stopAndAdvance() {
        guard isRecording else { return }
        endAudioCapture()
        isRecording = false
        recordingStartedAt = nil

        // Real pipeline (replaces the former fake sleep+UUID placeholder):
        // feed THIS prompt's captured audio into the enrollment accumulator
        // now, before the samples/prompt index move on. `SpeakerVerifier`
        // accumulates frames across every prompt in the session; nothing
        // is computed/persisted until the LAST prompt below.
        feedRecordedSamplesToVerifier()

        // Move to next prompt or processing.
        let nextIndex = viewModel.currentPromptIndex + 1
        let completedCount = viewModel.completedPromptsCount + 1

        if nextIndex >= viewModel.totalPrompts {
            viewModel = VoiceEnrollmentViewModel(
                prompts: viewModel.prompts,
                currentPromptIndex: nextIndex,
                step: .processing,
                audioLevel: 0,
                completedPromptsCount: completedCount
            )
            // Real voiceprint generation (LFCC mean-embedding) + Keychain
            // persistence — see `finishEnrollmentAndPersist()`. Synchronous
            // (plain array/vDSP math, no I/O beyond a Keychain write), but
            // kept in a Task to match this method's existing async-completion
            // shape and keep the UI transition off the audio-tap call stack.
            Task {
                let embeddingId = await finishEnrollmentAndPersist()
                await MainActor.run {
                    if let embeddingId {
                        self.viewModel.transition(to: .complete(speakerEmbeddingId: embeddingId))
                    } else {
                        let message = "Elaborazione del voiceprint non riuscita. Riprova la registrazione."
                        self.errorMessage = message
                        self.viewModel.transition(to: .error(message: message))
                    }
                }
            }
        } else {
            let nextPrompt = viewModel.prompts[nextIndex]
            viewModel = VoiceEnrollmentViewModel(
                prompts: viewModel.prompts,
                currentPromptIndex: nextIndex,
                step: .promptShowing(prompt: nextPrompt),
                audioLevel: 0,
                completedPromptsCount: completedCount
            )
        }
    }

    // MARK: - Real speaker-verification pipeline (Feature A)

    /// Chunk `recordedSamples` (Float32, AVAudioEngine tap format) into
    /// 20 ms Int16 PCM frames — the format `SpeakerVerifier`/`LfccExtractor`
    /// expect (matches the call pipeline's own RX frame layout, see
    /// `AudioConstants`) — and feed each into the enrollment accumulator.
    /// No-op if nothing was captured (e.g. a near-silent tap).
    private func feedRecordedSamplesToVerifier() {
        guard !recordedSamples.isEmpty else { return }
        for frame in Self.pcm16Frames(from: recordedSamples) {
            speakerVerifier.processEnrollmentFrame(frame)
        }
    }

    /// Finish enrollment (requires the accumulated frames across all
    /// prompts to reach `SpeakerVerifier.enrollmentMinFrames`, ~3 s) and
    /// persist the resulting template to the Keychain-backed
    /// `VoiceprintStore` under the reserved device-owner id. Returns a
    /// display id on success, `nil` on failure (too little audio captured,
    /// or the template could not be exported) — the caller surfaces `nil`
    /// as a real `.error` state rather than fabricating success.
    private func finishEnrollmentAndPersist() async -> String? {
        guard speakerVerifier.finishEnrollment(),
              let template = speakerVerifier.exportTemplate() else {
            return nil
        }
        voiceprintStore.save(contactId: VoiceprintStore.deviceOwnerId, template: template)
        return "embed-\(UUID().uuidString.prefix(8))"
    }

    /// Float32 (-1...1) → little-endian Int16 PCM, chunked into
    /// `AudioConstants.samplesPerFrame`-sized frames (20 ms @ 48 kHz — same
    /// frame shape the call pipeline's RX path already feeds into
    /// `SpeakerVerifier`/`GuardianMode`). A short remainder shorter than one
    /// full frame is dropped rather than zero-padded, matching
    /// `LfccExtractor.extract`'s own "too short to feature-ize" behavior.
    private static func pcm16Frames(from samples: [Float]) -> [Data] {
        let frameSize = AudioConstants.samplesPerFrame
        guard frameSize > 0 else { return [] }
        var frames: [Data] = []
        var index = 0
        while index + frameSize <= samples.count {
            var frameData = Data(capacity: frameSize * MemoryLayout<Int16>.size)
            for i in 0..<frameSize {
                let clamped = max(-1.0, min(1.0, samples[index + i]))
                let intSample = Int16(clamped * 32767.0)
                withUnsafeBytes(of: intSample.littleEndian) { frameData.append(contentsOf: $0) }
            }
            frames.append(frameData)
            index += frameSize
        }
        return frames
    }

    func cancel() {
        if isRecording { endAudioCapture(); isRecording = false }
        viewModel = VoiceEnrollmentViewModel(
            prompts: viewModel.prompts,
            currentPromptIndex: 0,
            step: .introduction,
            audioLevel: 0,
            completedPromptsCount: 0
        )
        recordedSamples = []
        recordingStartedAt = nil
    }

    // MARK: - AVAudioEngine setup

    private func requestMicrophonePermission() async throws {
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 17.0, *) {
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted { throw Error.microphonePermissionDenied }
        } else {
            let granted: Bool = await withCheckedContinuation { cont in
                session.requestRecordPermission { allowed in cont.resume(returning: allowed) }
            }
            if !granted { throw Error.microphonePermissionDenied }
        }
    }

    private func setupAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        // `LfccExtractor`/`AudioConstants` assume 48 kHz (the same rate the
        // call's RX audio path already runs at) for their filterbank
        // frequency mapping. Best-effort — iOS may still hand back a
        // different native rate on some hardware; enrollment and later
        // verification both go through the same capture path, so a
        // consistent (if occasionally non-48kHz) rate is still internally
        // coherent for this single-device biometric comparison.
        try? session.setPreferredSampleRate(Double(AudioConstants.sampleRate))
        try session.setActive(true)
    }

    private func beginAudioCapture() throws {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            let level = Self.computeRms(buffer: buffer)
            // Append samples for later processing.
            if let chData = buffer.floatChannelData?[0] {
                let count = Int(buffer.frameLength)
                let frame = Array(UnsafeBufferPointer(start: chData, count: count))
                Task { @MainActor in
                    self.recordedSamples.append(contentsOf: frame)
                    self.updateRecordingState(audioLevel: level)
                }
            } else {
                Task { @MainActor in self.updateRecordingState(audioLevel: level) }
            }
        }

        do {
            try audioEngine.start()
        } catch {
            throw Error.audioEngineFailedToStart(error.localizedDescription)
        }
    }

    private func endAudioCapture() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    @MainActor
    private func updateRecordingState(audioLevel: Float) {
        guard isRecording, case .recording(let prompt, _) = viewModel.step else { return }
        let elapsed = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let normalizedLevel = max(0, min(1, Double(audioLevel)))

        // Update view model (we have to reconstruct since audioLevel is `let`).
        viewModel = VoiceEnrollmentViewModel(
            prompts: viewModel.prompts,
            currentPromptIndex: viewModel.currentPromptIndex,
            step: .recording(prompt: prompt, secondsElapsed: elapsed),
            audioLevel: normalizedLevel,
            completedPromptsCount: viewModel.completedPromptsCount
        )

        // Auto-stop after maxDuration.
        if elapsed >= maxDurationSeconds {
            stopAndAdvance()
        }
    }

    private static func computeRms(buffer: AVAudioPCMBuffer) -> Float {
        guard let chData = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sumSquared: Float = 0
        for i in 0..<count {
            let s = chData[i]
            sumSquared += s * s
        }
        let rms = sqrt(sumSquared / Float(count))
        // RMS for typical voice ~0.01-0.1; amplify so the meter is visible.
        let amplified = min(1.0, rms * 8.0)
        return amplified
    }
}

struct VoiceEnrollmentContainerView: View {
    @StateObject private var container: VoiceEnrollmentContainer
    var onComplete: ((String) -> Void)?
    var onCancel: (() -> Void)?

    init(initial: VoiceEnrollmentViewModel = .mock,
         onComplete: ((String) -> Void)? = nil,
         onCancel: (() -> Void)? = nil) {
        _container = StateObject(wrappedValue: VoiceEnrollmentContainer(initial: initial))
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    var body: some View {
        VoiceEnrollmentView(
            viewModel: container.viewModel,
            onStart: { container.start() },
            onPromptComplete: { _ in
                if container.isRecording {
                    container.stopAndAdvance()
                } else {
                    container.startRecordingPrompt()
                }
            },
            onCancel: {
                container.cancel()
                onCancel?()
            }
        )
        .onChange(of: container.viewModel.step) { newStep in
            // Single-param form for iOS 16 compat.
            if case .complete(let id) = newStep {
                onComplete?(id)
            }
        }
    }
}
