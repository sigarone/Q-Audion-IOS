import SwiftUI
import QAudionEngine

struct CallView: View {
    @EnvironmentObject var appState: AppState

    @State private var isMuted = false
    @State private var isSpeakerOn = false
    @State private var callStart = Date()

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: - Call State Label
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
                .padding(.top, 16)

                Spacer()

                // MARK: - Contact Info
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.gray)

                Text(appState.currentContactId ?? "Unknown")
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.top, 8)

                // MARK: - Duration Timer
                Text(callStart, style: .timer)
                    .font(.title3)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 4)

                Spacer()

                // MARK: - Deepfake Alert Banner
                if appState.deepfakeAlert {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.white)
                        Text("Potential deepfake detected")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
                    .cornerRadius(12)
                    .padding(.horizontal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // MARK: - Guardian Mode Overlay
                GuardianModeOverlay()
                    .frame(height: 60)
                    .padding(.bottom, 8)

                // MARK: - Call Controls
                HStack(spacing: 48) {
                    // Mute Button
                    CallControlButton(
                        systemName: isMuted ? "mic.slash.fill" : "mic.fill",
                        label: isMuted ? "Unmute" : "Mute",
                        tint: isMuted ? .white : .white.opacity(0.7),
                        background: isMuted ? Color.blue : Color.white.opacity(0.15)
                    ) {
                        isMuted.toggle()
                        appState.setMuted(isMuted)
                    }

                    // End Call Button
                    CallControlButton(
                        systemName: "phone.down.fill",
                        label: "End",
                        tint: .white,
                        background: .red
                    ) {
                        appState.endCall()
                    }

                    // Speaker Button
                    CallControlButton(
                        systemName: isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                        label: "Speaker",
                        tint: isSpeakerOn ? .white : .white.opacity(0.7),
                        background: isSpeakerOn ? Color.blue : Color.white.opacity(0.15)
                    ) {
                        isSpeakerOn.toggle()
                        appState.setSpeaker(isSpeakerOn)
                    }
                }
                .padding(.bottom, 48)
            }
        }
        .animation(.easeInOut, value: appState.deepfakeAlert)
        .onAppear { callStart = Date() }
    }

    // MARK: - Computed Properties

    private var callStateLabel: String {
        switch appState.callState {
        case .connecting: return "Connecting..."
        case .ringing: return "Ringing..."
        case .encrypted: return "Encrypted call"
        case .ended: return "Call ended"
        default: return "In call"
        }
    }

    private var callStateTint: Color {
        switch appState.callState {
        case .encrypted: return .green
        case .connecting, .ringing: return .yellow
        case .ended: return .red
        default: return .white.opacity(0.7)
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
                    .frame(width: 56, height: 56)
                    .background(background)
                    .clipShape(Circle())

                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}
