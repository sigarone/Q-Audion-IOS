import SwiftUI

/// Video call view matching Android BCryptoVideoCallActivity.
public struct VideoCallView: View {
    public let contactName: String
    public let isOutgoing: Bool
    @State private var isMuted = false
    @State private var isCameraOff = false
    @State private var isSpeakerOn = false
    @State private var callDuration: TimeInterval = 0
    @State private var callState: CallState = .connecting
    @State private var showGuardianMode = false
    @Environment(\.dismiss) private var dismiss

    public enum CallState: String {
        case connecting = "Connessione..."
        case ringing = "Squilla..."
        case active = ""
        case ended = "Chiamata terminata"
    }

    public init(contactName: String, isOutgoing: Bool = true) {
        self.contactName = contactName
        self.isOutgoing = isOutgoing
    }

    public var body: some View {
        ZStack {
            // Remote video placeholder
            QColors.deepSpace.ignoresSafeArea()

            // Local video preview (PiP)
            VStack {
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 12)
                        .fill(QColors.cardSurface)
                        .frame(width: 120, height: 160)
                        .overlay(
                            Image(systemName: isCameraOff ? "video.slash.fill" : "person.fill")
                                .font(.title)
                                .foregroundColor(QColors.textTertiary)
                        )
                        .padding()
                }
                Spacer()
            }

            // Overlay UI
            VStack {
                // Top bar: name + status + security badge
                VStack(spacing: 4) {
                    HStack {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(QColors.qGreen)
                        Text("E2E Encrypted")
                            .font(.caption)
                            .foregroundColor(QColors.qGreen)
                    }

                    Text(contactName)
                        .font(.title2.bold())
                        .foregroundColor(.white)

                    Text(callState == .active ? formatDuration(callDuration) : callState.rawValue)
                        .font(.subheadline)
                        .foregroundColor(QColors.textSecondary)
                }
                .padding(.top, 60)

                Spacer()

                // Guardian mode overlay
                if showGuardianMode {
                    GuardianModeOverlay()
                        .transition(.opacity)
                }

                Spacer()

                // Control buttons
                HStack(spacing: 32) {
                    controlButton("mic\(isMuted ? ".slash" : "").fill", isMuted ? "Attiva mic" : "Muto", isActive: isMuted) {
                        isMuted.toggle()
                    }

                    controlButton("video\(isCameraOff ? ".slash" : "").fill", isCameraOff ? "Camera on" : "Camera off", isActive: isCameraOff) {
                        isCameraOff.toggle()
                    }

                    controlButton("speaker.wave.2.fill", "Speaker", isActive: isSpeakerOn) {
                        isSpeakerOn.toggle()
                    }

                    controlButton("shield.fill", "Guardian", isActive: showGuardianMode) {
                        showGuardianMode.toggle()
                    }
                }
                .padding(.bottom, 16)

                // Hang up button
                Button(action: { dismiss() }, label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 64, height: 64)
                        .background(QColors.error)
                        .clipShape(Circle())
                })
                .padding(.bottom, 40)
            }
        }
        .statusBarHidden()
    }

    private func controlButton(_ icon: String, _ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 50, height: 50)
                    .background(isActive ? QColors.qGreen.opacity(0.3) : QColors.cardSurface)
                    .clipShape(Circle())
                Text(label)
                    .font(.caption2)
            }
            .foregroundColor(.white)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        return String(format: "%d:%02d", min, sec)
    }
}
