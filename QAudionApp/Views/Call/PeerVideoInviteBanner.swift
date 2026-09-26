import SwiftUI

/// W-VIDPARITY — "Richiesta video" banner shown on `VideoCallView` while
/// the peer is sending video and we answered/stayed audio-only
/// (`AppState.showPeerVideoInviteBanner`, mirroring Android
/// `InCallScreen.kt`'s RemoteOnly card: title, body, an "X" close, a
/// plain-text "No, solo audio" and a filled "Attiva video"). No timer —
/// stays up until the user acts on it or the call ends.
///
/// `acceptLocked`/`onAcceptLocked` mirror the entitlement gating
/// `LiveInCallScreen`'s own upgrade-to-video control already uses
/// (`capabilityGate.isUnlocked(.callsVideo)` → `UpgradeSheet`): when the
/// capability is locked, tapping "Attiva video" must open the upgrade
/// sheet instead of touching the camera.
struct PeerVideoInviteBanner: View {
    let peerName: String
    let onAccept: () -> Void
    let onDecline: () -> Void
    let onDismiss: () -> Void
    var acceptLocked: Bool = false
    var onAcceptLocked: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "video.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.blue))

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "call.video_invite.title", defaultValue: "Richiesta video", comment: "Peer-video-invite banner — title shown while the peer is sending video and we are not"))
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(bodyText)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "call.video_invite.close_a11y", defaultValue: "Chiudi", comment: "Accessibility label — close button on the peer-video-invite banner"))
            }

            HStack(spacing: 16) {
                Spacer(minLength: 0)

                Button(action: onDecline) {
                    Text(String(localized: "call.video_invite.decline_button", defaultValue: "No, solo audio", comment: "Peer-video-invite banner — plain-text button that dismisses the banner and asks the peer to turn their camera off too"))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)

                Button(action: acceptLocked ? onAcceptLocked : onAccept) {
                    Text(String(localized: "call.video_invite.accept_button", defaultValue: "Attiva video", comment: "Peer-video-invite banner — filled button that turns on the local camera"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.blue))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var bodyText: String {
        String(localized: "call.video_invite.body", defaultValue: "\(peerName) sta trasmettendo video. Vuoi attivare la tua fotocamera?", comment: "Peer-video-invite banner — body text; %@ is the peer's display name")
    }
}

#if DEBUG
struct PeerVideoInviteBanner_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.gray.ignoresSafeArea()
            VStack {
                PeerVideoInviteBanner(
                    peerName: "Alice",
                    onAccept: {}, onDecline: {}, onDismiss: {})
                    .padding(.horizontal, 16)
                Spacer()
            }
            .padding(.top, 60)
        }
    }
}
#endif
