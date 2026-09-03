import SwiftUI

/// Incoming-call ringing screen. 1:1 visual port of Android
/// `qaudion-android-new/feature/feature-call/.../IncomingCallScreen.kt`.
///
/// Layout:
///   - "CHIAMATA IN ARRIVO · SECURE CHANNEL" header (success, 2.0sp)
///   - Stacked dual halo (240pt success + 200pt pqcAccent) + 160pt avatar
///   - Caller display name (displaySmall, italic, semibold)
///   - Subtitle "Chiamata audio sicura" / "Videochiamata sicura"
///   - 3 `MetaPill`s (PQC ACTIVE / VOICE VERIFIED / LOW RISK · C=0.NN)
///   - "Hybrid ML-KEM-1024 + PSK hardware · E2E" footer line
///   - Bottom action row (3 buttons, SpaceEvenly):
///       • Reject  — `CircularAction(72, riskHigh, "phone.down.fill")`
///       • Reply   — `CircularAction(56, surfaceVariant, "message.fill")`
///       • Accept  — `CircularAction(72, success,  "phone.fill")`
///   - Footer "dovrai rispondere entro 30s"
struct IncomingCallScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    enum CallType: Equatable { case audio; case video }

    let peerDisplayName: String
    let avatarUrl: URL?
    let callType: CallType
    let confidence: Double
    /// Numero interno PBX del chiamante (es. "103").
    /// Priorità assoluta nel cerchietto dell'avatar.
    let peerShortNumber: String?
    /// W-GRPRING — override della riga "Chiamata audio sicura" (es.
    /// "Chiamata di gruppo · Mario Rossi" per una group call). nil = default.
    let subtitle: String?
    /// W-GRPRING — nasconde il bottone centrale "Rispondi" (quick reply) su
    /// superfici dove non esiste una chat 1:1 a cui rispondere (group call).
    let showReplyAction: Bool
    let onAccept: () -> Void
    let onReject: () -> Void
    let onReplyWithMessage: () -> Void

    init(peerDisplayName: String,
         avatarUrl: URL? = nil,
         callType: CallType = .audio,
         confidence: Double = 0.94,
         peerShortNumber: String? = nil,
         subtitle: String? = nil,
         showReplyAction: Bool = true,
         onAccept: @escaping () -> Void,
         onReject: @escaping () -> Void,
         onReplyWithMessage: @escaping () -> Void = {}) {
        self.peerDisplayName = peerDisplayName
        self.avatarUrl = avatarUrl
        self.callType = callType
        self.confidence = confidence
        self.peerShortNumber = peerShortNumber
        self.subtitle = subtitle
        self.showReplyAction = showReplyAction
        self.onAccept = onAccept
        self.onReject = onReject
        self.onReplyWithMessage = onReplyWithMessage
    }

    var body: some View {
        ZStack {
            CallMeshBackground()

            VStack(spacing: 0) {
                Spacer().frame(height: 16)
                Text("CHIAMATA IN ARRIVO · SECURE CHANNEL")
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

                Text(subtitle ?? (callType == .video ? "Videochiamata sicura" : "Chiamata audio sicura"))
                    .qaudionStyle(type.titleMedium)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .padding(.bottom, 24)

                HStack(spacing: 8) {
                    MetaPill("PQC ACTIVE", accent: extras.pqcAccent)
                    MetaPill("VOICE VERIFIED", accent: extras.success, filled: true)
                    MetaPill(String(format: "LOW RISK · C=%.2f", confidence),
                             accent: extras.success, filled: true)
                }
                .padding(.bottom, 12)

                Text("Hybrid ML-KEM-1024 + PSK hardware · E2E")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)

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
                        action: onAccept,
                        diameter: 72,
                        background: extras.success,
                        iconColor: extras.onSuccess,
                        caption: "Accetta",
                        captionColor: extras.success
                    )
                }
                .padding(.bottom, 12)

                Text("dovrai rispondere entro 30s")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 24)
        }
    }
}

#Preview("Audio") {
    IncomingCallScreen(peerDisplayName: "Mario Rossi",
                       callType: .audio,
                       onAccept: {}, onReject: {})
        .qAudionTheme(dark: true)
}

#Preview("Video") {
    IncomingCallScreen(peerDisplayName: "Anna Bianchi",
                       callType: .video,
                       confidence: 0.81,
                       onAccept: {}, onReject: {})
        .qAudionTheme(dark: true)
}
