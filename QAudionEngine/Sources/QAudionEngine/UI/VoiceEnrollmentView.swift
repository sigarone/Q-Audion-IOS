#if canImport(SwiftUI)
import SwiftUI

public struct VoiceEnrollmentView: View {

    public let viewModel: VoiceEnrollmentViewModel
    public var onStart: (() -> Void)?
    public var onPromptComplete: ((Int) -> Void)?
    public var onCancel: (() -> Void)?

    public init(viewModel: VoiceEnrollmentViewModel = .mock,
                onStart: (() -> Void)? = nil,
                onPromptComplete: ((Int) -> Void)? = nil,
                onCancel: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.onStart = onStart
        self.onPromptComplete = onPromptComplete
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 24) {
            ProgressView(value: viewModel.progressFraction)
                .tint(.blue)
                .padding(.horizontal)

            switch viewModel.step {
            case .introduction:
                introContent
            case .promptShowing(let prompt):
                promptContent(prompt: prompt, recording: false)
            case .recording(let prompt, let sec):
                promptContent(prompt: prompt, recording: true, seconds: sec)
            case .processing:
                processingContent
            case .complete:
                completeContent
            case .error(let msg):
                errorContent(msg)
            }
        }
        .padding()
        .navigationTitle("Voice Enrollment")
    }

    private var introContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
            Text("Set up Voice Authentication")
                .font(.title2.bold())
            Text("You'll read \(viewModel.totalPrompts) short sentences. This trains a voice model that helps detect deepfakes during calls.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Start", action: { onStart?() })
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private func promptContent(prompt: String, recording: Bool, seconds: Double = 0) -> some View {
        VStack(spacing: 24) {
            Text("Prompt \(viewModel.currentPromptIndex + 1) of \(viewModel.totalPrompts)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(prompt)
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

            if recording {
                VStack(spacing: 12) {
                    audioLevelMeter
                    Text(String(format: "%.1fs", seconds))
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }

            Button(recording ? "Stop & next" : "Read prompt now") {
                onPromptComplete?(viewModel.currentPromptIndex)
            }
            .buttonStyle(.borderedProminent)
            .tint(recording ? .red : .blue)
            .controlSize(.large)
        }
    }

    private var audioLevelMeter: some View {
        GeometryReader { geo in
            let clamped = max(0, min(1, viewModel.audioLevel))
            ZStack(alignment: .leading) {
                Capsule().fill(.gray.opacity(0.2))
                Capsule().fill(.red).frame(width: geo.size.width * clamped)
            }
        }
        .frame(height: 16)
        .padding(.horizontal)
    }

    private var processingContent: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.5)
            Text("Analyzing your voice…").font(.body)
        }
    }

    private var completeContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Voice enrolled").font(.title.bold())
            Text("Voice authentication is now active. We'll alert you if a call's voice doesn't match.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private func errorContent(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)
            Text("Enrollment error").font(.title.bold())
            Text(msg).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Cancel", action: { onCancel?() })
                .buttonStyle(.bordered)
        }
    }
}

#Preview {
    NavigationStack { VoiceEnrollmentView() }
}
#endif
