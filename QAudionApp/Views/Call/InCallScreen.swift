import SwiftUI
import QAudionEngine

/// Active 1:1 call screen (audio, with optional video). Aligns with:
///   - Android `qaudion-android-new/feature/feature-call/.../InCallScreen.kt`
///   - Desktop `Q-Audion Desktop — Call Surface Variants` Stitch project
///   - Mobile Stitch mockup `Q-Audion Active Call` (project 15710203507549916868)
///
/// Cross-platform parity is the design contract. Component vocabulary
/// (MetaPill / CircularAction / AvatarHalo / SessionStatusStrip / QAudionAvatar)
/// and color tokens (`scheme.X`, `extras.Y`) are shared with Android and
/// Desktop — only the layout is mobile-tuned.
///
/// Layout (top → bottom):
///   1. **SessionStatusStrip** — slim 30pt strip with confidence dot,
///      "VOCE VERIFICATA" presence, C=0.NN, mini-spark, RE-KEY MM:SS.
///   2. **Hero avatar** — 220pt halo (success → connected, pqcAccent →
///      negotiating, warning → degraded) wrapping a 160pt avatar with
///      the per-name gradient.
///   3. **Peer name** + presence subtitle.
///   4. **Stats card** — 3 columns: DURATA, CONFIDENCE, RE-KEY progress.
///   5. **SAS verification panel** — visible only when `sasWords.count == 6`.
///   6. **Key info panel** — visible only when `keyInfo != nil`.
///   7. **Pills row** — RE-KEY / LIVENESS / PSK ROTATION badges.
///   8. **Transport row** — P2P-SRTP / TURN / RELAY / CONNECTING + an
///      optional analytics toggle (`onToggleDiagnostics`).
///   9. **Pinned bottom action row** — mute / audio-route /
///      voice-enhance / add-participant / hangup.
///
/// Stub fields (not yet wired through `AppState` / engine call state):
/// `confidence`, `recentSamples`, `rekeyInSeconds`, `sasWords`,
/// `sasVerified`, `keyInfo`, `transportMode`. Defaults render the screen
/// for design preview; the real wiring lands once
/// `AppState.callState`/`InCallContainer` exposes the equivalent fields.
struct InCallScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    // MARK: - Cross-platform model types (shared vocabulary)

    enum TransportMode: Equatable {
        case p2pSrtp
        case turn
        case bcryptoWsRelay
        case disconnected

        var label: String {
            switch self {
            case .p2pSrtp:        return "P2P SRTP"
            case .turn:           return "TURN"
            case .bcryptoWsRelay: return "RELAY"
            case .disconnected:   return "CONNECTING…"
            }
        }
    }

    struct KeyInfo: Equatable {
        let pqcAlgorithm: String           // "ML-KEM-1024 + X25519"
        let sessionFingerprint: String     // "7f3b…d2e9"
        let pskMethodLabel: String?        // "NFC" | "QR" | "Manuale" | …
        let pskName: String?               // "Yubi5"
        let pskFingerprint: String?        // "a83c-9f12"
    }

    // MARK: - Inputs

    let peerDisplayName: String
    let avatarUrl: URL?
    let durationSeconds: Int
    let confidence: Double
    let recentSamples: [Float]
    let rekeyInSeconds: Int
    let rekeyTotalSeconds: Int
    let pqcActive: Bool
    let sasWords: [String]
    let sasVerified: Bool
    let keyInfo: KeyInfo?
    let transportMode: TransportMode
    let muted: Bool
    let speakerOn: Bool
    let voiceEnhancement: Bool
    let onToggleMute: () -> Void
    let onToggleSpeaker: () -> Void
    let onToggleVoiceEnhancement: () -> Void
    let onAddParticipant: () -> Void
    let onHangup: () -> Void
    let onConfirmSas: () -> Void
    let onToggleDiagnostics: () -> Void

    init(peerDisplayName: String,
         avatarUrl: URL? = nil,
         durationSeconds: Int = 0,
         confidence: Double = 0.92,
         recentSamples: [Float] = [],
         rekeyInSeconds: Int = 252,
         rekeyTotalSeconds: Int = 300,
         pqcActive: Bool = true,
         sasWords: [String] = [],
         sasVerified: Bool = false,
         keyInfo: KeyInfo? = nil,
         transportMode: TransportMode = .p2pSrtp,
         muted: Bool = false,
         speakerOn: Bool = false,
         voiceEnhancement: Bool = false,
         onToggleMute: @escaping () -> Void = {},
         onToggleSpeaker: @escaping () -> Void = {},
         onToggleVoiceEnhancement: @escaping () -> Void = {},
         onAddParticipant: @escaping () -> Void = {},
         onHangup: @escaping () -> Void,
         onConfirmSas: @escaping () -> Void = {},
         onToggleDiagnostics: @escaping () -> Void = {}) {
        self.peerDisplayName = peerDisplayName
        self.avatarUrl = avatarUrl
        self.durationSeconds = durationSeconds
        self.confidence = confidence
        self.recentSamples = recentSamples
        self.rekeyInSeconds = rekeyInSeconds
        self.rekeyTotalSeconds = rekeyTotalSeconds
        self.pqcActive = pqcActive
        self.sasWords = sasWords
        self.sasVerified = sasVerified
        self.keyInfo = keyInfo
        self.transportMode = transportMode
        self.muted = muted
        self.speakerOn = speakerOn
        self.voiceEnhancement = voiceEnhancement
        self.onToggleMute = onToggleMute
        self.onToggleSpeaker = onToggleSpeaker
        self.onToggleVoiceEnhancement = onToggleVoiceEnhancement
        self.onAddParticipant = onAddParticipant
        self.onHangup = onHangup
        self.onConfirmSas = onConfirmSas
        self.onToggleDiagnostics = onToggleDiagnostics
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            CallMeshBackground()
            scrollContent
            bottomActionRow
        }
    }

    // MARK: - Scroll content (everything above the pinned action row)

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                SessionStatusStrip(
                    confidence: confidence,
                    presence: sasVerified ? "VOCE VERIFICATA" : "VERIFICA IN CORSO",
                    recentSamples: recentSamples,
                    rekeyInSeconds: rekeyInSeconds
                )

                Spacer().frame(height: 16)

                ZStack {
                    AvatarHalo(color: confidenceColor, diameter: 220)
                    QAudionAvatar(displayName: peerDisplayName,
                                  imageURL: avatarUrl,
                                  size: 160)
                }
                .frame(width: 240, height: 240)

                Spacer().frame(height: 12)

                Text(peerDisplayName)
                    .font(.system(size: 28, weight: .semibold))
                    .italic()
                    .foregroundStyle(scheme.onBackground)
                    .multilineTextAlignment(.center)

                presenceLine
                    .padding(.top, 2)

                Spacer().frame(height: 20)

                statsCard.padding(.horizontal, 20)

                if sasWords.count == 6 {
                    Spacer().frame(height: 12)
                    sasPanel.padding(.horizontal, 20)
                }

                if let keyInfo {
                    Spacer().frame(height: 12)
                    keyInfoPanel(keyInfo).padding(.horizontal, 20)
                }

                Spacer().frame(height: 12)
                pillsRow.padding(.horizontal, 20)

                Spacer().frame(height: 8)
                transportRow.padding(.horizontal, 20)

                // Reserve room for the pinned bottom action row.
                Spacer().frame(height: 140)
            }
        }
    }

    // MARK: - Presence line (matches Stitch / Android subtitle)

    private var presenceLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(extras.success)
                .frame(width: 6, height: 6)
            Text("online · verified voice")
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
    }

    // MARK: - Stats card

    private var statsCard: some View {
        HStack(alignment: .top, spacing: 0) {
            statColumn(label: "DURATA",
                       value: formatMmSs(durationSeconds),
                       valueColor: extras.success)
            Spacer()
            statColumn(label: "CONFIDENCE",
                       value: String(format: "C=%.2f", confidence),
                       valueColor: confidenceColor)
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text("RE-KEY")
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.2)
                    .foregroundStyle(scheme.onSurfaceVariant)
                Text("\(rekeyInSeconds)/\(rekeyTotalSeconds)")
                    .qaudionStyle(type.titleSmall)
                    .foregroundStyle(extras.pqcAccent)
                ProgressView(value: rekeyProgress)
                    .tint(extras.pqcAccent)
                    .frame(width: 72)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(scheme.surface.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(scheme.outline.opacity(0.5), lineWidth: 1)
        )
    }

    private func statColumn(label: String, value: String, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .qaudionStyle(type.labelSmall)
                .tracking(1.2)
                .foregroundStyle(scheme.onSurfaceVariant)
            Text(value)
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(valueColor)
        }
    }

    // MARK: - SAS panel

    private var sasPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: sasVerified ? "checkmark.seal.fill" : "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(sasVerified ? extras.success : scheme.primary)
                Text(sasVerified ? "SAS VERIFICATO" : "CONFRONTA QUESTE PAROLE")
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.2)
                    .foregroundStyle(sasVerified ? extras.success : scheme.primary)
            }

            VStack(spacing: 10) {
                HStack {
                    sasWordView(sasWords[0]); Spacer()
                    sasWordView(sasWords[1]); Spacer()
                    sasWordView(sasWords[2])
                }
                HStack {
                    sasWordView(sasWords[3]); Spacer()
                    sasWordView(sasWords[4]); Spacer()
                    sasWordView(sasWords[5])
                }
            }

            Button(action: onConfirmSas) {
                Text(sasVerified ? "VERIFICATO" : "CONFERMA COINCIDONO")
                    .qaudionStyle(type.labelLarge)
                    .tracking(1.2)
                    .foregroundStyle(sasVerified ? extras.success : scheme.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 999)
                            .fill(sasVerified
                                  ? scheme.surfaceVariant
                                  : scheme.primary.opacity(0.85))
                    )
            }
            .buttonStyle(.plain)
            .disabled(sasVerified)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(scheme.surface.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke((sasVerified ? extras.success : scheme.primary).opacity(0.6),
                        lineWidth: 1)
        )
    }

    private func sasWordView(_ word: String) -> some View {
        Text(word)
            .qaudionStyle(type.titleMedium)
            .foregroundStyle(scheme.onSurface)
    }

    // MARK: - Key info panel

    private func keyInfoPanel(_ info: KeyInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(extras.pqcAccent)
                Text("CHIAVE IN USO")
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.2)
                    .foregroundStyle(extras.pqcAccent)
            }
            keyInfoRow("PQC",      info.pqcAlgorithm)
            keyInfoRow("SESSIONE", info.sessionFingerprint)
            if let method = info.pskMethodLabel,
               let name = info.pskName {
                keyInfoRow("PSK", "\(method) · \(name)")
            }
            if let fp = info.pskFingerprint {
                keyInfoRow("FP", fp)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(scheme.surface.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(extras.pqcAccent.opacity(0.6), lineWidth: 1)
        )
    }

    private func keyInfoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .qaudionStyle(type.labelSmall)
                .tracking(1.0)
                .foregroundStyle(scheme.onSurfaceVariant)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurface)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Pills row

    private var pillsRow: some View {
        HStack(spacing: 8) {
            MetaPill("RE-KEY \(rekeyInSeconds)s", accent: extras.pqcAccent)
            MetaPill("LIVENESS OK",                accent: extras.success, filled: true)
            MetaPill("PSK ROTATION OK",            accent: extras.success)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Transport row

    private var transportRow: some View {
        HStack {
            MetaPill(transportMode.label,
                     accent: transportMode == .disconnected ? scheme.onSurfaceVariant : extras.success,
                     filled: transportMode == .p2pSrtp)
            Spacer()
            Button(action: onToggleDiagnostics) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(scheme.onSurface)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(scheme.surfaceVariant))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Diagnostica")
        }
    }

    // MARK: - Bottom action row (pinned)

    private var bottomActionRow: some View {
        HStack(spacing: 12) {
            CircularAction(
                icon: muted ? "mic.slash.fill" : "mic.fill",
                action: onToggleMute,
                diameter: 48,
                background: muted ? extras.warning : scheme.surfaceVariant,
                iconColor: muted ? extras.onWarning : scheme.onSurface
            )
            CircularAction(
                icon: speakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                action: onToggleSpeaker,
                diameter: 48,
                background: speakerOn ? extras.success : scheme.surfaceVariant,
                iconColor: speakerOn ? extras.onSuccess : scheme.onSurface
            )
            CircularAction(
                icon: "line.3.horizontal",
                action: onToggleVoiceEnhancement,
                diameter: 48,
                background: voiceEnhancement ? extras.success : scheme.surfaceVariant,
                iconColor: voiceEnhancement ? extras.onSuccess : scheme.onSurface
            )
            CircularAction(
                icon: "person.badge.plus",
                action: onAddParticipant,
                diameter: 48,
                background: scheme.surfaceVariant,
                iconColor: scheme.onSurface
            )
            CircularAction(
                icon: "phone.down.fill",
                action: onHangup,
                diameter: 60,
                background: extras.riskHigh,
                iconColor: scheme.onPrimary
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .background(
            Capsule().fill(scheme.surface.opacity(0.9))
        )
        .overlay(
            Capsule().stroke(scheme.outline.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Helpers

    private var confidenceColor: Color {
        switch ConfidenceThresholds.category(of: confidence) {
        case 0:  return extras.success
        case 1:  return extras.warning
        default: return extras.riskHigh
        }
    }

    private var rekeyProgress: Double {
        guard rekeyTotalSeconds > 0 else { return 0 }
        return max(0, min(1, Double(rekeyInSeconds) / Double(rekeyTotalSeconds)))
    }

    private func formatMmSs(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Preview

#Preview("Connected + SAS + KeyInfo") {
    InCallScreen(
        peerDisplayName: "Mario Rossi",
        durationSeconds: 754,
        confidence: 0.92,
        recentSamples: [0.84, 0.86, 0.89, 0.91, 0.92, 0.92, 0.93, 0.92],
        rekeyInSeconds: 252,
        rekeyTotalSeconds: 300,
        pqcActive: true,
        sasWords: ["OXYGEN", "ZEPHYR", "GLYPH", "RADIUS", "VESTIGE", "ECHO"],
        sasVerified: false,
        keyInfo: .init(pqcAlgorithm: "ML-KEM-1024 + X25519",
                       sessionFingerprint: "7f3b…d2e9",
                       pskMethodLabel: "NFC",
                       pskName: "Yubi5",
                       pskFingerprint: "a83c-9f12"),
        transportMode: .p2pSrtp,
        onHangup: {}
    )
    .qAudionTheme(dark: true)
}

#Preview("Connecting / no SAS") {
    InCallScreen(
        peerDisplayName: "Anna Bianchi",
        durationSeconds: 12,
        confidence: 0.55,
        rekeyInSeconds: 295,
        transportMode: .disconnected,
        onHangup: {}
    )
    .qAudionTheme(dark: true)
}
