import SwiftUI

/// Outgoing-call (ringing) screen. 1:1 visual port of Android
/// `qaudion-android-new/feature/feature-call/.../OutgoingCallScreen.kt`.
///
/// Shown while we are dialing a peer and the PQC handshake is happening
/// in the background. Layout (top → bottom):
///
///   - "CHIAMANDO · SECURE CHANNEL ACTIVE" header (success, 2.0sp tracking)
///   - 240pt `AvatarHalo` (pqcAccent) + 160pt avatar circle
///   - peer display name (displaySmall, italic, semibold)
///   - "Chiamata audio sicura" subtitle
///   - 3 `MetaPill`s (PQC NEGOTIATING / VOICE TRUST · ENROLLED / LOW LATENCY)
///   - **Handshake log** — 3 rows that tick from circle → check as the
///     state machine advances:
///        1. "KEM encap generated"           (≥ handshaking)
///        2. "PSK matched from vault"        (≥ handshaking)
///        3. "HKDF session key derived"      (≥ connected)
///   - hangup `CircularAction` (riskHigh, 80) + "Ring MM:SS" label
///
/// `state` drives the handshake checklist. `errorMessage` non-nil shows
/// the riskHigh banner instead of the third action.
struct OutgoingCallScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    enum State: Equatable {
        case dialing
        case handshaking
        case connected
        case rekeying
        case ended
    }

    let peerDisplayName: String
    let avatarUrl: URL?
    let state: State
    let elapsedSeconds: Int
    let errorMessage: String?
    let onHangup: () -> Void

    init(peerDisplayName: String,
         avatarUrl: URL? = nil,
         state: State = .dialing,
         elapsedSeconds: Int = 0,
         errorMessage: String? = nil,
         onHangup: @escaping () -> Void) {
        self.peerDisplayName = peerDisplayName
        self.avatarUrl = avatarUrl
        self.state = state
        self.elapsedSeconds = elapsedSeconds
        self.errorMessage = errorMessage
        self.onHangup = onHangup
    }

    var body: some View {
        ZStack {
            CallMeshBackground()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 32)

                    Text("CHIAMANDO · SECURE CHANNEL ACTIVE")
                        .qaudionStyle(type.labelSmall)
                        .tracking(2.0)
                        .foregroundStyle(extras.success)
                        .padding(.bottom, 36)

                    ZStack {
                        AvatarHalo(color: extras.pqcAccent, diameter: 240)
                        QAudionAvatar(displayName: peerDisplayName,
                                      imageURL: avatarUrl,
                                      size: 160)
                    }
                    .frame(width: 240, height: 240)
                    .padding(.bottom, 24)

                    Text(peerDisplayName)
                        .font(.system(size: 36, weight: .semibold, design: .default))
                        .italic()
                        .foregroundStyle(scheme.onBackground)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 4)

                    Text("Chiamata audio sicura")
                        .qaudionStyle(type.bodyLarge)
                        .italic()
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.bottom, 20)

                    HStack(spacing: 8) {
                        MetaPill("PQC NEGOTIATING", accent: extras.pqcAccent)
                        MetaPill("VOICE TRUST · ENROLLED", accent: extras.success, filled: true)
                        MetaPill("LOW LATENCY · 48ms", accent: extras.warning)
                    }
                    .padding(.bottom, 22)

                    handshakeLog
                        .padding(.horizontal, 4)

                    if let err = errorMessage {
                        errorBanner(err).padding(.top, 12)
                    }

                    Spacer().frame(height: 160) // space for pinned bottom action
                }
                .padding(.horizontal, 24)
            }

            VStack(spacing: 8) {
                Spacer()
                CircularAction(
                    icon: "phone.down.fill",
                    action: onHangup,
                    diameter: 80,
                    background: extras.riskHigh,
                    iconColor: scheme.onPrimary
                )
                Text(String(format: "Ring %d:%02d", elapsedSeconds / 60, elapsedSeconds % 60))
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(extras.success)
                Spacer().frame(height: 24)
            }
        }
    }

    // MARK: - Handshake log

    private var handshakeLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            handshakeRow("KEM encap generated",
                         done: state == .handshaking || state == .connected || state == .rekeying)
            handshakeRow("PSK matched from vault",
                         done: state == .handshaking || state == .connected || state == .rekeying)
            handshakeRow("HKDF session key derived",
                         done: state == .connected || state == .rekeying)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(scheme.surface.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(extras.pqcAccent.opacity(0.5), lineWidth: 1)
        )
    }

    private func handshakeRow(_ text: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(extras.success)
            } else {
                Circle()
                    .stroke(extras.pqcAccent.opacity(0.6), lineWidth: 1.2)
                    .frame(width: 12, height: 12)
            }
            Text(text)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
            Spacer(minLength: 0)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(extras.riskHigh)
                .padding(.top, 2)
            Text(message)
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurface)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 6).fill(extras.riskHigh.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(extras.riskHigh.opacity(0.6), lineWidth: 1))
    }
}

#Preview("Dialing") {
    OutgoingCallScreen(peerDisplayName: "Mario Rossi",
                       state: .dialing,
                       elapsedSeconds: 3,
                       onHangup: {})
        .qAudionTheme(dark: true)
}

#Preview("Handshaking") {
    OutgoingCallScreen(peerDisplayName: "Anna Bianchi",
                       state: .handshaking,
                       elapsedSeconds: 8,
                       onHangup: {})
        .qAudionTheme(dark: true)
}

#Preview("Error") {
    OutgoingCallScreen(peerDisplayName: "Luigi Verdi",
                       state: .ended,
                       elapsedSeconds: 27,
                       errorMessage: "Negoziazione PQC fallita: timeout dopo 25s.",
                       onHangup: {})
        .qAudionTheme(dark: true)
}
