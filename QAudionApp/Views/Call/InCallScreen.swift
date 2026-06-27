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
    /// Whether the active call has a video track — shows/hides the
    /// camera toggle button. Mirrors Android InCallScreen `hasVideo`.
    let hasVideo: Bool
    /// Camera on/off state — only meaningful when `hasVideo == true`.
    let cameraOn: Bool
    /// Numero interno PBX del peer (es. "103").
    /// Priorità assoluta nel cerchietto dell'avatar. Port di Android
    /// `AvatarImage.kt` `shortNumber` param.
    let peerShortNumber: String?
    /// Normalized RX PCM samples (-1…1) from the received audio stream.
    /// Drives the "VOCE RICEVUTA" waveform — oscilloscope of what the
    /// peer is saying, which is also the deepfake-detector's live input.
    let rxSamples: [Float]
    /// Normalized cipher-stream samples from the active decryption path.
    /// Drives the "CIFRATURA" waveform — visually represents the
    /// encryption/decryption process on received audio packets.
    let cipherSamples: [Float]
    let onToggleMute: () -> Void
    let onToggleSpeaker: () -> Void
    let onToggleVoiceEnhancement: () -> Void
    let onToggleCamera: () -> Void
    /// Upgrade an audio call to video mid-call. Shown only when `!hasVideo`.
    /// Mirrors Android/Desktop "upgrade to video" button. On tap, starts the
    /// local camera and transitions the call to video mode.
    let onUpgradeToVideo: () -> Void
    /// W533: true when ReplayKit screen capture is currently feeding
    /// the WebRTC video sender instead of the camera. Drives the
    /// share-screen button's filled state.
    let screenSharing: Bool
    /// W533 + media-consent v1: toggle screen-share on/off. Always shown
    /// during a call (screen share works from audio-only calls and never
    /// opens the camera)
    /// (in audio calls we'd need an upgrade-to-video first).
    let onToggleScreenShare: () -> Void
    /// W534: true when the REMOTE peer has announced they are sharing
    /// their screen (via the `<callId>|SCREEN_SHARE:start` opaque
    /// piggy-back from iOS/Desktop/Android). Drives the "Peer is
    /// sharing screen" badge over the remote video panel so the user
    /// understands they're seeing screen content, not camera.
    let peerScreenSharing: Bool
    /// D11 / W-NOBRICK — true when the active call's peer presented an
    /// UNAUTHENTICATED identity-key change (handshake signer key ∉ the
    /// server-published per-device set). Drives a NON-BLOCKING advisory banner
    /// only; it MUST NOT gate audio/video. SAS remains the terminal gate.
    let identityUnauthenticatedChange: Bool
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
         hasVideo: Bool = false,
         cameraOn: Bool = false,
         peerShortNumber: String? = nil,
         rxSamples: [Float] = [],
         cipherSamples: [Float] = [],
         onToggleMute: @escaping () -> Void = {},
         onToggleSpeaker: @escaping () -> Void = {},
         onToggleVoiceEnhancement: @escaping () -> Void = {},
         onToggleCamera: @escaping () -> Void = {},
         onUpgradeToVideo: @escaping () -> Void = {},
         screenSharing: Bool = false,
         onToggleScreenShare: @escaping () -> Void = {},
         peerScreenSharing: Bool = false,
         identityUnauthenticatedChange: Bool = false,
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
        self.hasVideo = hasVideo
        self.cameraOn = cameraOn
        self.peerShortNumber = peerShortNumber
        self.rxSamples = rxSamples
        self.cipherSamples = cipherSamples
        self.onToggleMute = onToggleMute
        self.onToggleSpeaker = onToggleSpeaker
        self.onToggleVoiceEnhancement = onToggleVoiceEnhancement
        self.onToggleCamera = onToggleCamera
        self.onUpgradeToVideo = onUpgradeToVideo
        self.screenSharing = screenSharing
        self.onToggleScreenShare = onToggleScreenShare
        self.peerScreenSharing = peerScreenSharing
        self.identityUnauthenticatedChange = identityUnauthenticatedChange
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
            // W534: top-center pill badge "Peer sta condividendo lo
            // schermo" surfaced when the remote side has announced a
            // SCREEN_SHARE:start. Wrapped in the outermost ZStack so
            // the position is fixed independent of scrollContent /
            // bottomActionRow layout.
            if peerScreenSharing {
                VStack {
                    peerScreenShareBadge
                        .padding(.top, 14)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: peerScreenSharing)
            }
        }
    }

    /// W534 — pill badge surfaced when `peerScreenSharing == true`.
    /// Visually distinct from the SAS-confirmation banner so the user
    /// understands "you are seeing remote screen" rather than any
    /// security-state UI. Tinted with the same `pqcAccent` colour the
    /// CIFRATURA waveform uses for crypto-stream visual continuity.
    private var peerScreenShareBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(extras.onSuccess)
            Text("\(peerDisplayName) sta condividendo lo schermo")
                .qaudionStyle(type.labelSmall)
                .tracking(0.4)
                .foregroundStyle(extras.onSuccess)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(extras.pqcAccent.opacity(0.92))
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
        )
    }

    // MARK: - D11 identity-change advisory banner (non-blocking)

    /// W-NOBRICK advisory: the peer's identity key changed and is NOT
    /// server-published — possible re-pair / account churn, or a MITM. Advisory
    /// ONLY (never gates media); the user confirms the SAS to be sure. Static
    /// foreground + no closures (SWIFT6_PATTERNS §1) so the type-checker stays
    /// fast and there is no isolation concern.
    private var identityChangeBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(extras.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("CHIAVE IDENTITÀ CAMBIATA")
                    .qaudionStyle(type.labelSmall)
                    .tracking(0.6)
                    .foregroundStyle(extras.warning)
                Text("La chiave del contatto è cambiata e non risulta pubblicata dal server. Confronta le parole SAS per verificare.")
                    .qaudionStyle(type.labelMedium)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(scheme.surfaceVariant)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(extras.warning.opacity(0.55), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Avviso di sicurezza: la chiave identità del contatto è cambiata e non è pubblicata dal server. Verifica le parole SAS.")
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

                Spacer().frame(height: 8)

                ZStack {
                    AvatarHalo(color: confidenceColor, diameter: 180)
                    QAudionAvatar(displayName: peerDisplayName,
                                  imageURL: avatarUrl,
                                  size: 120,
                                  shortNumber: peerShortNumber)
                }
                .frame(width: 200, height: 200)

                Spacer().frame(height: 8)

                Text(peerDisplayName)
                    .font(.system(size: 26, weight: .semibold))
                    .italic()
                    .foregroundStyle(scheme.onBackground)
                    .multilineTextAlignment(.center)

                presenceLine
                    .padding(.top, 2)

                Spacer().frame(height: 12)

                statsCard.padding(.horizontal, 20)

                // D11 / W-NOBRICK — non-blocking security advisory. Shown when the
                // peer's identity key changed and is NOT in the server-published
                // per-device set. Advisory ONLY: it never gates audio/video; the
                // SAS panel below is the terminal verification.
                if identityUnauthenticatedChange {
                    Spacer().frame(height: 10)
                    identityChangeBanner.padding(.horizontal, 20)
                }

                if sasWords.count == 6 {
                    Spacer().frame(height: 8)
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

                // Reserve room for the pinned 2-row bottom action row.
                // Old 1-row: 140pt. New 2-row: ~160pt (2×48+10gap+28padding+20bottom).
                Spacer().frame(height: 170)
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
            // W323: tiny "DATI DEMO" badge surfaced when key panel is
            // not present — heuristic for "engine not yet wired" so
            // testers know the numbers above are placeholder.
            if keyInfo == nil {
                stubBadge
            }
        }
    }

    /// W323: small italianized "DEMO" pill. Static foreground / no
    /// closures + no multi-segment interpolation (SWIFT6_PATTERNS §1).
    private var stubBadge: some View {
        Text(Self.stubBadgeText)
            .qaudionStyle(type.labelSmall)
            .tracking(1.0)
            .foregroundStyle(extras.warning)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().stroke(extras.warning.opacity(0.6), lineWidth: 1)
            )
            .accessibilityLabel("Dati demo, non ancora collegati al motore")
    }

    /// W323: static helper — String formatting kept out of @ViewBuilder
    /// per SWIFT6_PATTERNS §1 / §6.
    private static let stubBadgeText: String = "DEMO"

    // MARK: - Stats card (waveform panel)

    /// The card below the avatar. CONFIDENCE and RE-KEY have been removed
    /// — both are already visible in the `SessionStatusStrip` at the top.
    /// The freed space shows two live oscilloscopes:
    ///   • VOCE RICEVUTA — RX audio from the peer (deepfake detector input)
    ///   • CIFRATURA — decryption stream (visually represents the crypto work)
    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Duration — the only metric not shown elsewhere.
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DURATA")
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.2)
                        .foregroundStyle(scheme.onSurfaceVariant)
                    Text(formatMmSs(durationSeconds))
                        .qaudionStyle(type.titleSmall)
                        .foregroundStyle(extras.success)
                }
                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(scheme.outline.opacity(0.3))
                .frame(height: 1)

            // RX voice waveform — oscilloscope of received audio.
            // This is what the deepfake detector analyses in real time.
            // autoGain on so the line stays visibly dynamic even at
            // conversational levels (typical |sample| peaks at ~0.2-0.4).
            waveformStrip(
                label: "VOCE RICEVUTA",
                samples: rxSamples,
                color: extras.success,
                autoGain: true,
                lineWidth: 1.5,
                glow: false
            )

            Rectangle()
                .fill(scheme.outline.opacity(0.2))
                .frame(height: 1)

            // Cipher waveform — the encryption/decryption byte stream.
            // Visually shows that every received packet is being unwrapped
            // by the ML-KEM-1024 + SFrame pipeline in real time. Thicker
            // line + soft glow gives a more "scenographic" feel that
            // distinguishes the crypto layer from the voice trace.
            waveformStrip(
                label: "CIFRATURA",
                samples: cipherSamples,
                color: extras.pqcAccent,
                autoGain: false,
                lineWidth: 2.2,
                glow: true
            )
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

    /// Compact oscilloscope strip used inside `statsCard`.
    /// Label above, Canvas waveform (36 pt tall) below.
    /// Falls back to a silent flat line when `samples` is empty.
    ///
    /// - Parameters:
    ///   - autoGain: scale samples by `1 / peak` so even quiet voice
    ///     levels fill the canvas (peak floor 0.1 so total silence stays
    ///     near the centerline). Cipher samples are uniform-distributed
    ///     bytes and don't need it.
    ///   - lineWidth: stroke width (1.5 for voice, 2.2 for cipher).
    ///   - glow: draws a soft 4-pt blur underneath the main stroke to
    ///     give the cipher trace a more "scenographic" feel.
    private func waveformStrip(label: String,
                               samples: [Float],
                               color: Color,
                               autoGain: Bool,
                               lineWidth: CGFloat,
                               glow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .qaudionStyle(type.labelSmall)
                .tracking(1.2)
                .foregroundStyle(scheme.onSurfaceVariant)
            Canvas { ctx, size in
                let midY = size.height / 2
                // Center reference line (always drawn)
                var centerLine = Path()
                centerLine.move(to: CGPoint(x: 0, y: midY))
                centerLine.addLine(to: CGPoint(x: size.width, y: midY))
                ctx.stroke(centerLine,
                           with: .color(color.opacity(0.18)),
                           lineWidth: 0.5)
                guard samples.count > 1 else { return }

                // W523: peak-based auto-gain for the voice trace. Peak
                // floor 0.10 keeps silence near the centerline (no
                // amplification of noise floor). Without this the line
                // appeared "stuck" at conversational levels because
                // typical mic Int16 peaks are well under 32768 → after
                // /32768 normalisation the |y| was 0.15-0.30, eating
                // only 25 % of the canvas.
                let gain: CGFloat
                if autoGain {
                    var peak: Float = 0.10
                    for s in samples {
                        let a = abs(s)
                        if a > peak { peak = a }
                    }
                    gain = CGFloat(min(1.0, 0.92 / peak))
                } else {
                    gain = 1.0
                }

                let count = samples.count - 1
                let stepX = size.width / CGFloat(count)
                var wave = Path()
                for (i, sample) in samples.enumerated() {
                    let x = CGFloat(i) * stepX
                    let scaled = max(-1.0, min(1.0, CGFloat(sample) * gain))
                    let y = midY - scaled * midY * 0.85
                    if i == 0 { wave.move(to: CGPoint(x: x, y: y)) }
                    else       { wave.addLine(to: CGPoint(x: x, y: y)) }
                }

                if glow {
                    // Soft glow underlay — gives the cipher trace depth
                    // without sacrificing legibility of the main stroke.
                    var glowContext = ctx
                    glowContext.addFilter(.blur(radius: 4))
                    glowContext.stroke(wave,
                                       with: .color(color.opacity(0.55)),
                                       lineWidth: lineWidth + 2.0)
                }
                ctx.stroke(wave, with: .color(color), lineWidth: lineWidth)
            }
            .frame(height: 36)
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
        // RE-KEY removed here — already shown in SessionStatusStrip at top.
        HStack(spacing: 8) {
            MetaPill("LIVENESS OK",   accent: extras.success, filled: true)
            MetaPill("PSK ROTATION",  accent: extras.success)
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

    // MARK: - Bottom action row (W557: 2-row adaptive layout for iPhone)
    //
    // Previous design: single HStack with 7 buttons.
    // Problem: 7×48pt + 1×60pt + 6×12pt spacing ≈ 420pt — overflows any
    // iPhone screen (narrowest = iPhone SE 375pt safe area ≈ 343pt).
    // The row was clipped / invisible on every iPhone in portrait mode.
    //
    // New design: two rows inside a rounded-rectangle card.
    //   Row 1 (secondary): camera/upgrade · screenshare · voice-enhance · add
    //   Row 2 (primary):   mute · speaker ·  [ HANGUP (centred, 60pt) ]
    // Each row fits comfortably on a 375pt screen.

    private var bottomActionRow: some View {
        VStack(spacing: 10) {
            secondaryControlsRow
            primaryControlsRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(scheme.surface.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(scheme.outline.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    /// Row 1: secondary / contextual controls.
    /// camera/upgrade-video | screen-share | voice-enhance | add-participant
    private var secondaryControlsRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if hasVideo {
                CircularAction(
                    icon: cameraOn ? "video.fill" : "video.slash.fill",
                    action: onToggleCamera,
                    diameter: 48,
                    background: cameraOn ? extras.success : scheme.surfaceVariant,
                    iconColor: cameraOn ? extras.onSuccess : scheme.onSurface
                )
            } else {
                CircularAction(
                    icon: "video.badge.plus",
                    action: onUpgradeToVideo,
                    diameter: 48,
                    background: scheme.surfaceVariant,
                    iconColor: scheme.onSurface
                )
            }
            Spacer(minLength: 0)
            // W538: screen-share (hidden on Mac Catalyst).
            if screenShareAvailable {
                CircularAction(
                    icon: screenSharing ? "square.on.square.fill" : "square.on.square",
                    action: onToggleScreenShare,
                    diameter: 48,
                    background: screenSharing ? extras.success : scheme.surfaceVariant,
                    iconColor: screenSharing ? extras.onSuccess : scheme.onSurface
                )
                Spacer(minLength: 0)
            }
            CircularAction(
                icon: "line.3.horizontal",
                action: onToggleVoiceEnhancement,
                diameter: 48,
                background: voiceEnhancement ? extras.success : scheme.surfaceVariant,
                iconColor: voiceEnhancement ? extras.onSuccess : scheme.onSurface
            )
            Spacer(minLength: 0)
            CircularAction(
                icon: "person.badge.plus",
                action: onAddParticipant,
                diameter: 48,
                background: scheme.surfaceVariant,
                iconColor: scheme.onSurface
            )
            Spacer(minLength: 0)
        }
    }

    /// Row 2: primary controls — mute, speaker, hangup (centred).
    private var primaryControlsRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            CircularAction(
                icon: muted ? "mic.slash.fill" : "mic.fill",
                action: onToggleMute,
                diameter: 52,
                background: muted ? extras.warning : scheme.surfaceVariant,
                iconColor: muted ? extras.onWarning : scheme.onSurface
            )
            Spacer(minLength: 0)
            CircularAction(
                icon: speakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                action: onToggleSpeaker,
                diameter: 52,
                background: speakerOn ? extras.success : scheme.surfaceVariant,
                iconColor: speakerOn ? extras.onSuccess : scheme.onSurface
            )
            Spacer(minLength: 0)
            // Hangup — prominent, centred, larger than secondary buttons.
            CircularAction(
                icon: "phone.down.fill",
                action: onHangup,
                diameter: 64,
                background: extras.riskHigh,
                iconColor: scheme.onPrimary
            )
            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    /// W538: screen-share is supported on iOS / iPadOS (ReplayKit's
    /// in-app `RPScreenRecorder` path). It is NOT supported on Mac
    /// Catalyst — `RPScreenRecorder.isAvailable` is false there and
    /// users would tap an inert button. Hide it on Catalyst entirely.
    private var screenShareAvailable: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return true
        #endif
    }

    private var confidenceColor: Color {
        switch ConfidenceThresholds.category(of: confidence) {
        case 0:  return extras.success
        case 1:  return extras.warning
        default: return extras.riskHigh
        }
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
