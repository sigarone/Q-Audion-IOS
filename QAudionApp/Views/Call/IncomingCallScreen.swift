import SwiftUI

/// Incoming-call ringing screen. 1:1 visual port of Android
/// `qaudion-android-new/feature/feature-call/.../IncomingCallScreen.kt`.
///
/// Layout:
///   - "CHIAMATA IN ARRIVO" header (success, 2.0sp). It says only that a call
///     is ringing: this screen reads no key-exchange state, so it does not
///     call the channel secure.
///   - 240pt `KeyExchangeRing` (always static and unconfirmed: nothing has
///     been exchanged yet) + 160pt avatar
///   - Caller display name (displaySmall, italic, semibold)
///   - Subtitle "Chiamata audio" / "Videochiamata": the kind of call and
///     nothing about its security (a ringing call has no channel yet), or the
///     caller's own line for a group call
///   - No status pills and no PQC / cipher footer line: the "VOICE VERIFIED",
///     "LOW RISK · C=0.NN" and PQC pills of the original port are gone, because
///     a ringing call has no voice reading and this screen has no key-exchange
///     state to show.
///   - Bottom action row (3 buttons, SpaceEvenly):
///       • Reject  — `CircularAction(72, riskHigh, "phone.down.fill")`
///       • Reply   — `CircularAction(56, surfaceVariant, "message.fill")`
///       • Accept  — `CircularAction(72, success,  "phone.fill")`
///   - No footer with an answer deadline. The old fixed "answer within 30s"
///     line matched no timer in the app: a group invite rings for 45 s
///     (`AppState.armGroupCallRingTimeout`) and a 1:1 ring has no client timer
///     at all, it ends when the caller hangs up or the server stops the ring.
struct IncomingCallScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    enum CallType: Equatable { case audio; case video }

    let peerDisplayName: String
    let avatarUrl: URL?
    let callType: CallType
    /// Numero interno PBX del chiamante (es. "103").
    /// Priorità assoluta nel cerchietto dell'avatar.
    let peerShortNumber: String?
    /// W-GRPRING — override della riga sotto il nome ("Chiamata audio" /
    /// "Videochiamata"), es. "Chiamata di gruppo · Mario Rossi" per una group
    /// call. nil = default. Una stringa gia' pronta: non viene localizzata qui.
    let subtitle: String?
    /// W-GRPRING — nasconde il bottone centrale "Rispondi" (quick reply) su
    /// superfici dove non esiste una chat 1:1 a cui rispondere (group call).
    let showReplyAction: Bool
    let onAccept: (_ acceptWithoutVideo: Bool) -> Void
    let onReject: () -> Void
    let onReplyWithMessage: () -> Void

    /// W-VIDPRIVACY — "answer without video" toggle. Only consulted when
    /// `callType == .video`; not persisted (no "always audio-only" setting
    /// — design non-goal).
    ///
    /// W-VIDEODEFAULTOFF (2026-09-08) — starts pre-set to true (audio-only)
    /// for a video call, set from `init` below. Confirmed live on the
    /// Android port of this same screen: tapping the main Accept action
    /// with zero other interaction is the most common real path, and with
    /// this toggle defaulting to false (wants video) that reflexive tap
    /// silently opened the camera — defeating the entire point of the
    /// feature. Getting video now requires actively turning this off.
    @State private var acceptWithoutVideo: Bool

    init(peerDisplayName: String,
         avatarUrl: URL? = nil,
         callType: CallType = .audio,
         peerShortNumber: String? = nil,
         subtitle: String? = nil,
         showReplyAction: Bool = true,
         onAccept: @escaping (Bool) -> Void,
         onReject: @escaping () -> Void,
         onReplyWithMessage: @escaping () -> Void = {}) {
        self.peerDisplayName = peerDisplayName
        self.avatarUrl = avatarUrl
        self.callType = callType
        self.peerShortNumber = peerShortNumber
        self.subtitle = subtitle
        self.showReplyAction = showReplyAction
        self.onAccept = onAccept
        self.onReject = onReject
        self.onReplyWithMessage = onReplyWithMessage
        _acceptWithoutVideo = State(initialValue: callType == .video)
    }

    /// The line under the name: the kind of call and nothing about its security,
    /// because a ringing call has no channel yet. A group call passes its own line.
    private var subtitleLine: String {
        if let subtitle = subtitle { return subtitle }
        if callType == .video {
            return String(localized: "Videochiamata",
                          comment: "Call screens (incoming and outgoing) — line under the name: the kind of call, a video call")
        }
        return String(localized: "Chiamata audio",
                      comment: "Call screens (incoming and outgoing) — line under the name: the kind of call, an audio call")
    }

    var body: some View {
        ZStack {
            CallMeshBackground()

            VStack(spacing: 0) {
                Spacer().frame(height: 16)
                Text("CHIAMATA IN ARRIVO")
                    .qaudionStyle(type.labelSmall)
                    .tracking(2.0)
                    .foregroundStyle(extras.success)
                    .padding(.bottom, 40)

                ZStack {
                    // Always .settled/unconfirmed — this screen is torn
                    // down before Accept even finishes processing
                    // (appState.incomingCallRingVisible clears BEFORE
                    // callState leaves .ringing) and there is no
                    // client-side timeout on a 1:1 incoming ring, so an
                    // animating ring here would have no real progress to
                    // show and no bound on how long it could run. See the
                    // design doc's "What is NOT real on iOS" section.
                    KeyExchangeRing(phase: .settled, confirmed: false, ringSize: 240)
                    QAudionAvatar(displayName: peerDisplayName,
                                  imageURL: avatarUrl,
                                  size: 160,
                                  shortNumber: peerShortNumber)
                }
                .frame(width: 240, height: 240)
                .padding(.bottom, 28)

                Text(peerDisplayName)
                    .font(.system(size: 36, weight: .semibold))
                    .italic()
                    .foregroundStyle(scheme.onBackground)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 4)

                if callType == .video {
                    HStack(spacing: 6) {
                        Image(systemName: "video.fill").font(.system(size: 13, weight: .semibold))
                        Text(subtitleLine).qaudionStyle(type.titleMedium)
                    }
                    .foregroundStyle(extras.trustEnterprise)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(extras.trustEnterprise.opacity(0.18)))
                    .overlay(Capsule().stroke(extras.trustEnterprise.opacity(0.55), lineWidth: 1))
                    .padding(.bottom, 10)

                    Button { acceptWithoutVideo.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: acceptWithoutVideo ? "checkmark.square.fill" : "square")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Rispondi senza video").qaudionStyle(type.labelSmall)
                        }
                        .foregroundStyle(acceptWithoutVideo ? extras.trustEnterprise : scheme.onSurfaceVariant)
                        // HIG minimum tap target is 44x44pt; the label's own
                        // bounding box (~16-18pt tall) is far under that.
                        // minHeight only grows the invisible hit area — the
                        // icon/text keep their natural size, centered inside
                        // it — and contentShape extends hit-testing to the
                        // full frame instead of just the drawn glyphs.
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rispondi senza video")
                    .accessibilityValue(acceptWithoutVideo ? "Attivo" : "Non attivo")
                    .padding(.bottom, 24)
                } else {
                    Text(subtitleLine)
                        .qaudionStyle(type.titleMedium)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.bottom, 24)
                }

                // No status pills and no cipher/PQC claim on a ringing call: this
                // screen has no voice reading and no key-exchange state to show.
                Spacer()

                HStack(spacing: 36) {
                    CircularAction(
                        icon: "phone.down.fill",
                        action: onReject,
                        diameter: 72,
                        background: extras.riskHigh,
                        iconColor: scheme.onPrimary,
                        caption: "Rifiuta",
                        captionColor: extras.riskHigh
                    )
                    if showReplyAction {
                        CircularAction(
                            icon: "message.fill",
                            action: onReplyWithMessage,
                            diameter: 56,
                            background: scheme.surfaceVariant,
                            iconColor: scheme.onSurface,
                            caption: "Rispondi",
                            captionColor: scheme.onSurfaceVariant
                        )
                    }
                    CircularAction(
                        icon: "phone.fill",
                        action: { onAccept(callType == .video && acceptWithoutVideo) },
                        diameter: 72,
                        background: extras.success,
                        iconColor: extras.onSuccess,
                        caption: (callType == .video && acceptWithoutVideo) ? "Senza video" : "Accetta",
                        captionColor: extras.success
                    )
                }
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
        }
    }
}

#Preview("Audio") {
    IncomingCallScreen(peerDisplayName: "Mario Rossi",
                       callType: .audio,
                       onAccept: { _ in }, onReject: {})
        .qAudionTheme(dark: true)
}

#Preview("Video") {
    IncomingCallScreen(peerDisplayName: "Anna Bianchi",
                       callType: .video,
                       onAccept: { _ in }, onReject: {})
        .qAudionTheme(dark: true)
}
