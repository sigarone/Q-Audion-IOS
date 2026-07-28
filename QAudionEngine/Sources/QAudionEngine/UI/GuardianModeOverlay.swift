#if canImport(SwiftUI)
import SwiftUI

public struct GuardianModeOverlay: View {
    @State private var confidenceLevel: ConfidenceIndex.Level = .green
    @State private var confidenceScore: Float = 0.9
    @State private var isAlertVisible = false

    public init() {}

    public var body: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    Circle()
                        .fill(colorForLevel(confidenceLevel))
                        .frame(width: 12, height: 12)
                    Text(labelForLevel(confidenceLevel))
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("\(Int(confidenceScore * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                .padding(.trailing, 16)
                .padding(.top, 8)
            }
            Spacer()

            if isAlertVisible {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text("Possible voice manipulation detected")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                .padding()
                .background(Color.red.opacity(0.15))
                .cornerRadius(12)
                .padding(.horizontal)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    public func updateConfidence(level: ConfidenceIndex.Level, score: Float) {
        withAnimation { confidenceLevel = level; confidenceScore = score }
        if level == .red { withAnimation { isAlertVisible = true } } else { withAnimation { isAlertVisible = false } }
    }

    private func colorForLevel(_ level: ConfidenceIndex.Level) -> Color {
        switch level {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        }
    }

    private func labelForLevel(_ level: ConfidenceIndex.Level) -> String {
        switch level {
        case .green: return "Secure"
        case .yellow: return "Caution"
        case .red: return "Alert"
        }
    }
}
#endif
