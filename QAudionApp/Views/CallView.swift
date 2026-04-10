import SwiftUI
import QAudionEngine

struct CallView: View {
    @EnvironmentObject var appState: AppState

    @State private var isMuted = false
    @State private var isSpeakerOn = false
    @State private var callStart = Date()
    @State private var alertPulse = false

    var body: some View {
        ZStack {
            // MARK: - Dark Gradient Background
            LinearGradient(
                colors: [Color(white: 0.08), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: - Top: Shield + Contact + Status
                topSection
                    .padding(.top, 24)

                Spacer()

                // MARK: - Center: Security Badge
                CallSecurityBadge()

                Spacer()

                // MARK: - Deepfake Alert Banner
                if appState.deepfakeAlert {
                    deepfakeAlertBanner
                }

                // MARK: - Bottom: Call Controls
                callControls
                    .padding(.bottom, 48)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.deepfakeAlert)
        .onAppear { callStart = Date() }
    }

    // MARK: - Top Section

    private var topSection: some View {
        VStack(spacing: 8) {
            // Call state label with lock icon
            HStack(spacing: 6) {
                if appState.callState == .encrypted {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                }
                Text(callStateLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .foregroundStyle(callStateTint)

            // Shield icon
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 100, height: 100)

                Image(systemName: "shield.checkered")
                    .font(.system(size: 44))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .padding(.top, 12)

            // Contact name
            Text(appState.callContactId ?? "Unknown")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)

            // Duration timer (only shown when call is active/encrypted)
            if appState.callState == .active || appState.callState == .encrypted {
                Text(callStart, style: .timer)
                    .font(.title3)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    // MARK: - Deepfake Alert Banner

    private var deepfakeAlertBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .scaleEffect(alertPulse ? 1.15 : 1.0)

            VStack(alignment: .leading, spacing: 2) {
                Text("Deepfake Alert")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Text("Potential voice manipulation detected")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.red.opacity(0.85))
                .shadow(color: .red.opacity(alertPulse ? 0.5 : 0.2), radius: alertPulse ? 12 : 4)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                alertPulse = true
            }
        }
    }

    // MARK: - Call Controls

    private var callControls: some View {
        HStack(spacing: 48) {
            CallControlButton(
                systemName: isMuted ? "mic.slash.fill" : "mic.fill",
                label: isMuted ? "Unmute" : "Mute",
                tint: isMuted ? .white : .white.opacity(0.7),
                background: isMuted ? .blue : .white.opacity(0.12)
            ) {
                isMuted.toggle()
                appState.setMuted(isMuted)
            }

            CallControlButton(
                systemName: "phone.down.fill",
                label: "End",
                tint: .white,
                background: .red
            ) {
                appState.endCall()
            }

            CallControlButton(
                systemName: isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                label: "Speaker",
                tint: isSpeakerOn ? .white : .white.opacity(0.7),
                background: isSpeakerOn ? .blue : .white.opacity(0.12)
            ) {
                isSpeakerOn.toggle()
                appState.setSpeaker(isSpeakerOn)
            }
        }
    }

    // MARK: - Computed Properties

    private var callStateLabel: String {
        switch appState.callState {
        case .connecting: return "Connecting..."
        case .ringing:    return "Ringing..."
        case .encrypted:  return "Encrypted call"
        case .active:     return "In call"
        case .ended:      return "Call ended"
        default:          return ""
        }
    }

    private var callStateTint: Color {
        switch appState.callState {
        case .encrypted:             return .green
        case .connecting, .ringing:  return .yellow
        case .ended:                 return .red
        default:                     return .white.opacity(0.7)
        }
    }
}

// MARK: - Call Control Button

private struct CallControlButton: View {
    let systemName: String
    let label: String
    let tint: Color
    let background: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 60, height: 60)
                    .background(background)
                    .clipShape(Circle())

                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}
