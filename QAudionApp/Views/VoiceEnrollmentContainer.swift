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
    private var maxDurationSeconds: TimeInterval = 8.0
    private var recordingStartedAt: Date?

    init(initial: VoiceEnrollmentViewModel = .mock) {
        self.viewModel = initial
    }

    func start() {
        Task {
            do {
                try await requestMicrophonePermission()
                if let firstPrompt = viewModel.prompts.first {
                    await MainActor.run {
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
            // Simulate processing — in production this would call a voiceprint
            // generator (engine layer) + persist embedding.
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    self.viewModel.transition(to: .complete(speakerEmbeddingId: "embed-\(UUID().uuidString.prefix(8))"))
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
