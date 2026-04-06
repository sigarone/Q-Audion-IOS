#if canImport(SwiftUI)
import SwiftUI

public struct VoiceEnrollmentView: View {
    @State private var isRecording = false
    @State private var progress: Float = 0
    @State private var statusText = "Tap to start enrollment"
    @State private var enrollmentComplete = false
    private let requiredSeconds: Float = 3.0

    public init() {}

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 8)
                    .frame(width: 160, height: 160)
                Circle()
                    .trim(from: 0, to: CGFloat(progress / requiredSeconds))
                    .stroke(isRecording ? Color.red : Color.green, lineWidth: 8)
                    .frame(width: 160, height: 160)
                    .rotationEffect(.degrees(-90))
                Image(systemName: isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 48))
                    .foregroundColor(isRecording ? .red : .primary)
            }
            .onTapGesture { toggleRecording() }

            Text(statusText)
                .font(.headline)

            if enrollmentComplete {
                Label("Enrollment Complete", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
            }

            Spacer()

            Text("Speak naturally for 3 seconds to create your voiceprint.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .navigationTitle("Voice Enrollment")
        .padding()
    }

    private func toggleRecording() {
        isRecording.toggle()
        if isRecording {
            statusText = "Recording... speak naturally"
            progress = 0
        } else {
            statusText = progress >= requiredSeconds ? "Enrollment saved" : "Enrollment cancelled"
            enrollmentComplete = progress >= requiredSeconds
        }
    }
}
#endif
