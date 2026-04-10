import SwiftUI
import QAudionEngine

// MARK: - Call Security Badge

struct CallSecurityBadge: View {
    @EnvironmentObject var appState: AppState
    @State private var isExpanded = false
    @State private var redPulse = false

    var body: some View {
        VStack(spacing: 0) {
            compactBadge
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }

            if isExpanded {
                expandedDetails
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Compact Badge

    /// Compact pill: [lock] [traffic-light dot] [backend label] [PSK badge] [chevron]
    private var compactBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 14))
                .foregroundColor(.white)

            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .shadow(
                    color: appState.confidenceLevel == "red" ? .red.opacity(redPulse ? 0.9 : 0.3) : .clear,
                    radius: redPulse ? 8 : 3
                )
                .onAppear { startRedPulseIfNeeded() }
                .onChange(of: appState.confidenceLevel) { _ in startRedPulseIfNeeded() }

            Text(appState.backendType)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(backendColor)

            if appState.pskActive {
                Text("PSK")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.yellow)
                    .cornerRadius(4)
            }

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
    }

    // MARK: - Expanded Details Panel

    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(statusLabel)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(dotColor)
                Spacer()
                Text("\(Int(appState.confidenceScore * 100))%")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(dotColor)
            }

            Divider().background(Color.white.opacity(0.1))

            if appState.pskActive {
                detailRow(
                    label: "PSK",
                    value: "\(appState.pskName)  \u{2022}  \(appState.pskFingerprint)"
                )
            }

            detailRow(label: "Re-key", value: "\(appState.rekeyCount) rotations")
            detailRow(label: "Encryption", value: appState.encryptionAlgo)
            detailRow(label: "Transport", value: appState.transportType)
            detailRow(label: "Latency", value: "\(appState.latencyMs) ms", valueColor: latencyColor)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - Detail Row Helper

    private func detailRow(label: String, value: String, valueColor: Color = .white) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.gray)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
        }
    }

    // MARK: - Computed Colors

    private var dotColor: Color {
        switch appState.confidenceLevel {
        case "yellow": return .yellow
        case "red": return .red
        default: return .green
        }
    }

    private var backendColor: Color {
        switch appState.backendType {
        case "PQC": return .green
        case "BCR": return .blue
        default: return .gray
        }
    }

    private var latencyColor: Color {
        if appState.latencyMs < 80 { return .green }
        if appState.latencyMs < 200 { return .yellow }
        return .red
    }

    private var statusLabel: String {
        switch appState.confidenceLevel {
        case "yellow": return "Caution"
        case "red": return "Alert"
        default: return "Secure"
        }
    }

    // MARK: - Red Glow Pulse Animation

    private func startRedPulseIfNeeded() {
        if appState.confidenceLevel == "red" {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                redPulse = true
            }
        } else {
            redPulse = false
        }
    }
}
