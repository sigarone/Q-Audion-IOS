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
    /// Unified call UI — respect the system Reduce Motion setting: when on,
    /// the animated mini-spectrum + crypto-engine comet freeze to a single
    /// representative frame instead of continuously redrawing.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Unified call UI — security sheet presentation state. Local to this
    /// view (not plumbed from AppState): purely a "is the aggregating
    /// sheet open" UI flag, nothing security-critical is gated by it.
    @State private var showSecuritySheet: Bool = false

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

    /// Unified call UI — Guardian ribbon voice-biometrics snapshot. Maps
    /// 1:1 onto `QAudionEngine.VoiceAnalysisResult` fields the security
    /// sheet needs; kept as a small local struct (rather than importing
    /// QAudionEngine's type directly into the view's public API) so
    /// InCallScreen's previews/tests don't need to construct the full
    /// engine result type. nil at the call site ⇒ every biometrics row
    /// in the security sheet is omitted gracefully (no fabricated data).
    struct VoiceBiometrics: Equatable {
        let stressScore: Float        // 0...1 (VoiceAnalysisResult.Stress.score)
        let jitter: Float             // 0...1 fraction (not yet ×100)
        let shimmer: Float            // 0...1 fraction
        let hnr: Float                // dB (VoiceAnalysisResult.VoiceHealth.hnr)
        let breathiness: Float        // 0...1
        let pitchHz: Float            // VoiceAnalysisResult.Pitch.f0Hz
        let syllablesPerSec: Float    // VoiceAnalysisResult.SpeechRate.syllablesPerSec
        let confidence: Float         // 0...1 (VoiceAnalysisResult.confidence)
        // Unified call UI — formant/energy fields driving the animated
        // mini-spectrum (Guardian ribbon). f1…f4 are the REAL vocal-resonance
        // peak frequencies (Hz) from VoiceAnalysisResult.Formants; a zero
        // formant simply contributes no gaussian bump. `speaking` gates the
        // cyan→green "active" tint (VoiceAnalysisResult.speechRate.isSpeaking
        // && .pitch.voiced). These are display-only inputs to the spectrum;
        // the security sheet ignores them. Defaulted so preview/test call
        // sites that don't care about the spectrum keep compiling.
        let f1: Float                 // VoiceAnalysisResult.Formants.f1 (Hz)
        let f2: Float                 // .f2 (Hz)
        let f3: Float                 // .f3 (Hz)
        let f4: Float                 // .f4 (Hz)
        let speaking: Bool            // .speechRate.isSpeaking && .pitch.voiced

        init(stressScore: Float, jitter: Float, shimmer: Float, hnr: Float,
             breathiness: Float, pitchHz: Float, syllablesPerSec: Float,
             confidence: Float,
             f1: Float = 0, f2: Float = 0, f3: Float = 0, f4: Float = 0,
             speaking: Bool = false) {
            self.stressScore = stressScore
            self.jitter = jitter
            self.shimmer = shimmer
            self.hnr = hnr
            self.breathiness = breathiness
            self.pitchHz = pitchHz
            self.syllablesPerSec = syllablesPerSec
            self.confidence = confidence
            self.f1 = f1; self.f2 = f2; self.f3 = f3; self.f4 = f4
            self.speaking = speaking
        }
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
    /// Unified call UI — live Guardian voice-biometrics snapshot for the
    /// security sheet + Guardian ribbon mini-gauges. nil while unavailable
    /// (engine flag off, incoming-call wiring gap, or no result yet) —
    /// every dependent row is omitted gracefully, never fabricated.
    let voiceBiometrics: VoiceBiometrics?
    /// Unified call UI — KMS key epoch counter (0-based count of rekeys
    /// this call has performed so far). nil when no live rekey-count
    /// source is available; the security sheet then shows the static
    /// "PQC session key" row without an epoch/countdown line rather than
    /// fabricating one. Currently sourced from `AppState.rekeyCount`,
    /// which increments only if a live rotation hook exists (see
    /// CallSessionKeyBroker / KeyRotationCoordinator — as of this pass
    /// neither exposes an in-call rekey EVENT, only the one-time initial
    /// key registration, so this is expected to render nil / omitted).
    let keyEpoch: Int?
    /// Unified call UI — live crypto-engine rate: real AES-256-GCM frame
    /// operations per second (seal(TX)+open(RX)), sampled once/sec by
    /// `AppState.startCryptoMeter()` from the ground-truth `CallService`
    /// frame counters. 0 when no frames are flowing → the pulsing meter is
    /// hidden. No kB/s counterpart is shown: iOS has no byte counter (only
    /// frame counts), so a byte rate would be fabricated — see
    /// `AppState.cryptoOpsPerSec` doc comment.
    let cryptoOpsPerSec: Int
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
         voiceBiometrics: VoiceBiometrics? = nil,
         keyEpoch: Int? = nil,
         cryptoOpsPerSec: Int = 0,
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
        self.voiceBiometrics = voiceBiometrics
        self.keyEpoch = keyEpoch
        self.cryptoOpsPerSec = cryptoOpsPerSec
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
        // Unified call UI — security sheet aggregates SAS + PQC handshake +
        // cipher/key/epoch + transport + interpreted voice biometrics.
        // Presented as a system sheet (not a custom overlay) so it gets
        // native drag-to-dismiss. Matches the existing sheet convention in
        // this codebase (e.g. ContactDetailScreen's SasVerifySheet): the
        // qaudionScheme/extras/type environment values propagate down from
        // ContentView's single root `.qAudionTheme(dark: true)` — no need
        // to reapply the modifier at each sheet call site.
        .sheet(isPresented: $showSecuritySheet) {
            securitySheet
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

                trustBar.padding(.horizontal, 20)

                Spacer().frame(height: 8)

                guardianRibbon.padding(.horizontal, 20)

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

    // MARK: - Trust bar (unified call UI)

    /// Compact row of security chips + an expand shield, matching the
    /// "Aegis Cipher" trust-bar from call-guardian-reference.html: SAS ✓
    /// (green, only once actually verified), PQC (accent, only once a
    /// real ML-KEM session key is live), and the transport chip (reusing
    /// the exact `transportMode.label` the transport row already shows).
    /// Tapping the shield opens the aggregating security sheet — the
    /// single place SAS words / handshake / cipher / transport / voice
    /// biometrics live together, instead of scattering them across the
    /// scroll content.
    private var trustBar: some View {
        HStack(spacing: 7) {
            if sasVerified {
                trustChip(
                    icon: "checkmark",
                    label: "SAS ✓",
                    color: extras.success,
                    filled: true
                )
            }
            if pqcActive {
                trustChip(
                    icon: "lock.shield.fill",
                    label: "PQC",
                    color: extras.pqcAccent,
                    filled: false
                )
            }
            trustChip(
                icon: nil,
                label: transportMode.label,
                color: scheme.onSurfaceVariant,
                filled: false
            )
            Spacer(minLength: 0)
            Button {
                showSecuritySheet = true
            } label: {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(extras.pqcAccent)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(scheme.surfaceVariant)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Apri sicurezza sessione")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(scheme.surfaceVariant.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(scheme.outline.opacity(0.5), lineWidth: 1)
        )
    }

    /// Small monospace chip used only inside `trustBar`. Distinct from
    /// `MetaPill` (rounded-rect not capsule, smaller, optional leading
    /// icon) to match the reference's `.chip` visual — kept private and
    /// local rather than promoted to a shared component since nothing
    /// else in the call UI needs this exact shape yet.
    private func trustChip(icon: String?, label: String, color: Color, filled: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(label)
                .qaudionStyle(type.labelSmall)
                .tracking(0.4)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(filled ? color.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Guardian ribbon (unified call UI)

    /// Compact Guardian strip: a small live remote-voice spectrum on the
    /// left, a cipher/seal visual on the right, 3 mini gauges below
    /// (stress / breath·HNR / pitch) with a one-word status per gauge, and —
    /// when the crypto engine is doing real work (ops/s > 0) — a thin pulsing
    /// crypto-engine meter at the bottom. Additive and small per spec — NOT
    /// the full decorative canvas spectrum-analyzer from the HTML reference.
    /// The mini-spectrum is formant-driven + animated (see `miniSpectrum`),
    /// for parity with Android's `MiniSpectrum`. When `voiceBiometrics == nil`
    /// (engine flag off, or no result yet) the gauges render an em-dash rather
    /// than fabricated numbers.
    private var guardianRibbon: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("REMOTE VOICE")
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.0)
                        .foregroundStyle(scheme.onSurfaceVariant)
                    miniSpectrum
                        .frame(height: 30)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                    .background(scheme.outline.opacity(0.4))
                    .frame(height: 40)
                    .padding(.horizontal, 10)

                cipherSeal
                    .frame(width: 40, height: 40)
            }
            .padding(10)

            Rectangle()
                .fill(scheme.outline.opacity(0.3))
                .frame(height: 1)

            HStack(spacing: 0) {
                guardianGauge(
                    label: "STRESS",
                    value: stressDisplayValue,
                    status: stressStatusWord,
                    statusColor: stressStatusColor
                )
                guardianGauge(
                    label: "BREATH·HNR",
                    value: hnrDisplayValue,
                    status: hnrStatusWord,
                    statusColor: hnrStatusColor
                )
                guardianGauge(
                    label: "PITCH",
                    value: pitchDisplayValue,
                    status: pitchStatusWord,
                    statusColor: scheme.onSurfaceVariant
                )
            }

            // Live crypto-engine meter — real AES-256-GCM frame ops/s
            // pulsing. Shown only while the engine is doing work (ops > 0),
            // i.e. once frames are actually flowing on an active call.
            if cryptoOpsPerSec > 0 {
                Rectangle()
                    .fill(scheme.outline.opacity(0.3))
                    .frame(height: 1)
                cryptoEngineMeterRow
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(scheme.surfaceVariant.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(scheme.outline.opacity(0.5), lineWidth: 1)
        )
    }

    /// Live remote-voice mini-spectrum — parity with Android `MiniSpectrum`
    /// (feature-call/ui/GuardianRibbon.kt). A small (≤30pt) 16-bar spectrum
    /// whose SHAPE is the real `VoiceAnalysisResult` formants (f1…f4 vocal-
    /// resonance peaks mapped onto a 0…3800 Hz display band as soft gaussian
    /// bumps), whose AMPLITUDE tracks live speaking energy (analysis
    /// confidence when voiced/speaking, decaying to a low idle floor
    /// otherwise), with ONE cheap continuous phase (a single `TimelineView
    /// (.animation)` redraw) adding a travelling shimmer so it stays alive
    /// between the ~10 Hz analysis updates. Cost: one Canvas redraw per
    /// display frame reading a time-derived phase — NOT a per-frame
    /// recomposition, NOT a real FFT.
    ///
    /// Colors: cyan (pqcAccent) → green (success) gradient when speaking, dim
    /// (onSurfaceVariant) when idle. When Reduce Motion is on the phase is
    /// frozen to a single representative frame (the animation stops), so the
    /// bars still show the formant shape + energy but don't shimmer.
    private var miniSpectrum: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas { ctx, size in
                // One continuous looping phase, period 1500 ms (matches
                // Android's spectrumPhase tween). Frozen to 0 under Reduce
                // Motion for a static representative frame.
                let phase: Double
                if reduceMotion {
                    phase = 0
                } else {
                    let period = 1.5
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    phase = (t.truncatingRemainder(dividingBy: period)) / period * 2.0 * .pi
                }
                drawMiniSpectrum(ctx: &ctx, size: size, phase: phase)
            }
        }
    }

    /// Pure Canvas draw for `miniSpectrum` — extracted so the TimelineView
    /// body stays shallow (SWIFT6_PATTERNS §5/§6) and the parameters mirror
    /// Android's `MiniSpectrum` Canvas block 1:1.
    private func drawMiniSpectrum(ctx: inout GraphicsContext, size: CGSize, phase: Double) {
        let bio = voiceBiometrics
        // Speaking gate (cyan→green tint) + energy driver. iOS `Pitch` has
        // no per-frame `confidence` field (only f0Hz/voiced/rms), so — unlike
        // Android which reads `pitch.confidence` — the energy uses the
        // top-level `VoiceAnalysisResult.confidence` (the overall analysis
        // confidence, the closest analog). isSpeaking && voiced already fold
        // into `bio.speaking` at the map site (liveVoiceBiometrics).
        let speaking = bio?.speaking ?? false
        let conf = CGFloat(max(0, min(1, bio?.confidence ?? 0)))
        let energy: CGFloat = speaking ? (0.45 + 0.55 * conf) : 0.12

        // Formant peaks (Hz) → normalised x in [0,1] over a 0…3800 Hz band.
        // A zero formant contributes no peak (filtered out).
        var peaks: [CGFloat] = []
        if let bio {
            for hz in [bio.f1, bio.f2, bio.f3, bio.f4] {
                let xn = CGFloat(max(0, min(1, hz / 3800.0)))
                if xn > 0.001 { peaks.append(xn) }
            }
        }

        let n = 16
        let gap = size.width * 0.28 / CGFloat(n)
        let bw = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
        let baseY = size.height
        let activeGradient = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [extras.pqcAccent, extras.success]),
            startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: 0, y: size.height)
        )
        let idleShading = GraphicsContext.Shading.color(scheme.onSurfaceVariant.opacity(0.30))

        for i in 0..<n {
            let x = CGFloat(i) * (bw + gap)
            let xn: CGFloat = n <= 1 ? 0 : CGFloat(i) / CGFloat(n - 1)
            // Formant-shaped envelope: a soft gaussian bump near each real peak.
            var env: CGFloat = 0.10
            for p in peaks {
                let d = xn - p
                env += 0.9 * CGFloat(exp(-(Double(d * d)) / 0.010))
            }
            // Spectral tilt (voice rolls off toward high freq).
            env *= (1.0 - 0.35 * xn)
            // Travelling shimmer keeps it alive between analysis updates.
            let shimmer = 0.5 + 0.5 * sin(phase + Double(i) * 0.55)
            var h = env * (0.55 + 0.45 * CGFloat(shimmer)) * energy
            h = max(0.04, min(1.0, h))
            let barH = h * size.height
            let rect = CGRect(x: x, y: baseY - barH, width: bw, height: barH)
            let barPath = Path(roundedRect: rect, cornerRadius: bw / 2.0)
            ctx.fill(barPath, with: speaking ? activeGradient : idleShading)
        }
    }

    /// Small cipher/seal glyph — a static lock badge (not an animated
    /// particle canvas like the HTML reference) tinted by whether a PQC
    /// session key is actually live, so the glyph itself carries meaning
    /// rather than being purely decorative.
    private var cipherSeal: some View {
        ZStack {
            Circle()
                .fill(scheme.background.opacity(0.6))
                .overlay(
                    Circle().stroke((pqcActive ? extras.pqcAccent : scheme.outline).opacity(0.5), lineWidth: 1)
                )
            Image(systemName: "lock.rectangle.stack.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(pqcActive ? extras.pqcAccent : scheme.onSurfaceVariant)
        }
    }

    private func guardianGauge(label: String, value: String, status: String, statusColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .qaudionStyle(type.labelSmall)
                .tracking(0.6)
                .foregroundStyle(scheme.onSurfaceVariant)
                .font(.system(size: 8))
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(scheme.onSurface)
            Text(status)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Crypto-engine meter (unified call UI)

    /// Thin pulsing crypto-engine meter — parity with Android
    /// `CryptoEngineMeterRow` (feature-call/ui/GuardianRibbon.kt). A bright
    /// COMET sweeps across a dim track; its sweep PERIOD shortens as
    /// `cryptoOpsPerSec` rises (~1700 ms idle → ~450 ms busy) and its
    /// height/brightness rise with intensity (`opsPerSec / 200` clamped).
    /// Real per-frame AES-256-GCM work — the rate is the live delta of the
    /// `CallService` seal(TX)+open(RX) frame counters, never fabricated.
    ///
    /// Readout is "N/s" only. Android also prints "X kB/s", but iOS has no
    /// byte counter (only frame counts), so — per the honest-data rule — no
    /// byte rate is shown rather than fabricating one from an assumed frame
    /// size. Under Reduce Motion the comet freezes to a representative frame.
    private var cryptoEngineMeterRow: some View {
        HStack(spacing: 8) {
            Text("ENGINE")
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundStyle(scheme.onSurfaceVariant)
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                Canvas { ctx, size in
                    // Sweep period shortens as ops/s rises: mirrors Android's
                    // (1_800_000 / (ops + 60)) clamped to [420, 1700] ms.
                    let periodMs = min(1700.0, max(420.0, 1_800_000.0 / (Double(cryptoOpsPerSec) + 60.0)))
                    let period = periodMs / 1000.0
                    let sweep: Double
                    if reduceMotion {
                        sweep = 0.5   // representative mid-sweep frame
                    } else {
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        sweep = (t.truncatingRemainder(dividingBy: period)) / period
                    }
                    drawCryptoComet(ctx: &ctx, size: size, sweep: sweep)
                }
                .frame(height: 8)
            }
            Text(Self.cryptoReadout(cryptoOpsPerSec))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(extras.pqcAccent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// Pure Canvas draw for the crypto comet — extracted so the TimelineView
    /// body stays shallow (SWIFT6_PATTERNS §5/§6). Mirrors Android's comet
    /// geometry: dim track + a travelling bright pulse whose height/alpha
    /// scale with intensity (`opsPerSec / 200` clamped to [0.15, 1]).
    private func drawCryptoComet(ctx: inout GraphicsContext, size: CGSize, sweep: Double) {
        let intensity = CGFloat(min(1.0, max(0.15, Double(cryptoOpsPerSec) / 200.0)))
        let trackH = size.height * 0.42
        let ty = (size.height - trackH) / 2.0
        // Dim track.
        let trackRect = CGRect(x: 0, y: ty, width: size.width, height: trackH)
        ctx.fill(
            Path(roundedRect: trackRect, cornerRadius: trackH / 2.0),
            with: .color(scheme.onSurfaceVariant.opacity(0.18))
        )
        // Travelling comet — position driven by `sweep`.
        let cometW = size.width * 0.28
        let cx = CGFloat(sweep) * (size.width + cometW) - cometW
        let cometRect = CGRect(
            x: cx,
            y: ty - trackH * intensity * 0.6,
            width: cometW,
            height: trackH * (1.0 + intensity * 1.2)
        )
        let cometShading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: extras.pqcAccent.opacity(0), location: 0),
                .init(color: extras.pqcAccent.opacity(0.9 * Double(intensity)), location: 0.5),
                .init(color: extras.success.opacity(0), location: 1),
            ]),
            startPoint: CGPoint(x: cx, y: 0),
            endPoint: CGPoint(x: cx + cometW, y: 0)
        )
        ctx.fill(Path(roundedRect: cometRect, cornerRadius: trackH / 2.0), with: cometShading)
    }

    /// Static readout builder kept out of @ViewBuilder (SWIFT6_PATTERNS §1/§6
    /// — avoids String(Int) overload-resolution in a view body). ops/s only;
    /// no kB/s (no iOS byte counter — see `cryptoEngineMeterRow` doc comment).
    private static func cryptoReadout(_ ops: Int) -> String {
        return ops.description + "/s"
    }

    // MARK: - Guardian ribbon — interpreted display values (shared with
    //         the security-sheet biometrics rows so the two never disagree)

    /// Real thresholds from `StressDetector`/`ConfidenceIndex`
    /// (QAudionEngine/Sources/QAudionEngine/Analysis + Deepfake):
    /// `stress.score` is already normalised to [0,1]
    /// (`min(1, (jitter*10 + shimmer*5)/2)`). Displayed ×100 as "/100"
    /// to match the reference's convention; bands below are a UI-only
    /// interpretive convention (the engine itself has no named bands for
    /// this composite score) loosely aligned to common voice-stress
    /// literature: <35 calm, 35-60 elevated, >60 agitated/possible duress.
    private var stressDisplayValue: String {
        guard let bio = voiceBiometrics else { return "—" }
        return "\(Int((bio.stressScore * 100).rounded()))"
    }
    private var stressStatusWord: String {
        guard let bio = voiceBiometrics else { return "n/d" }
        let pct = bio.stressScore * 100
        if pct < 35 { return "calm" }
        if pct < 60 { return "elevated" }
        return "agitated"
    }
    private var stressStatusColor: Color {
        guard let bio = voiceBiometrics else { return scheme.onSurfaceVariant }
        let pct = bio.stressScore * 100
        if pct < 35 { return extras.success }
        if pct < 60 { return extras.warning }
        return extras.riskHigh
    }

    /// HNR threshold is REAL and load-bearing: `VoiceHealthMonitor.analyze`
    /// computes `breathiness = max(0, 1 - hnr/20)`, i.e. the engine itself
    /// treats 20 dB as the "fully clear" reference point and 0 dB as
    /// maximally breathy — so >20 dB clear / <10 dB hoarse-or-noisy-link
    /// (breathiness ≥ 0.5) is a direct reading of that formula, not an
    /// invented band.
    private var hnrDisplayValue: String {
        guard let bio = voiceBiometrics else { return "—" }
        return "\(Int(bio.hnr.rounded()))"
    }
    private var hnrStatusWord: String {
        guard let bio = voiceBiometrics else { return "n/d" }
        if bio.hnr > 20 { return "clear" }
        if bio.hnr < 10 { return "hoarse" }
        return "fair"
    }
    private var hnrStatusColor: Color {
        guard let bio = voiceBiometrics else { return scheme.onSurfaceVariant }
        if bio.hnr > 20 { return extras.success }
        if bio.hnr < 10 { return extras.warning }
        return scheme.onSurfaceVariant
    }

    private var pitchDisplayValue: String {
        guard let bio = voiceBiometrics else { return "—" }
        return "\(Int(bio.pitchHz.rounded()))"
    }
    /// SpeechRateAnalyzer/PitchExtractor expose no explicit "steady vs
    /// shifting" band — this is a coarse UI-only heuristic (no baseline
    /// history is tracked here) so it always reads "steady" while voiced.
    /// It exists only so the gauge has a status word rather than a blank;
    /// a real "shifted from this peer's baseline" comparison would need
    /// a per-peer stored baseline, which is out of scope for this pass.
    private var pitchStatusWord: String {
        guard let bio = voiceBiometrics else { return "n/d" }
        return bio.pitchHz > 0 ? "steady" : "silent"
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

    // MARK: - Security sheet (unified call UI)
    //
    // Aggregates, in one place: SAS words + verify (reuses sasPanel's
    // sub-pieces), PQC handshake/key info (reuses keyInfoPanel's KeyInfo
    // model — same `keyInfo` input, no new data source), cipher + key +
    // epoch/rekey (epoch shown only when `keyEpoch != nil`; no live rekey
    // countdown hook exists as of this pass — see `keyEpoch` doc comment —
    // so it is omitted rather than fabricated), transport, and INTERPRETED
    // voice biometrics (reusing the same display/status helpers as
    // `guardianRibbon` so the two surfaces never disagree).

    private var securitySheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Sicurezza sessione")
                        .qaudionStyle(type.titleMedium)
                        .foregroundStyle(scheme.onSurface)
                    Spacer()
                    Button {
                        showSecuritySheet = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(scheme.surfaceVariant))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)

                Divider().background(scheme.outline.opacity(0.35))

                VStack(alignment: .leading, spacing: 0) {
                    if sasWords.count == 6 {
                        securitySection(title: "SAS · leggi ad alta voce per verificare \(peerDisplayName)") {
                            sasPanel
                        }
                    }

                    if let keyInfo {
                        securitySection(title: "Handshake · post-quantum") {
                            keyInfoPanel(keyInfo)
                        }
                    }

                    // Cipher + key + epoch/rekey. Epoch row shown ONLY when
                    // a live `keyEpoch` source exists (see its doc comment —
                    // no rotation-event hook exists as of this pass, so the
                    // call site passes nil and this row is simply absent
                    // rather than showing a fabricated "epoch 0" / countdown).
                    if keyInfo != nil || keyEpoch != nil {
                        securitySection(title: "Cifra e chiave") {
                            cipherKeySectionBody
                        }
                    }

                    securitySection(title: "Trasporto") {
                        transportSectionBody
                    }

                    securitySection(title: "Biometria vocale · \(peerDisplayName)", isLast: true) {
                        voiceBiometricsSectionBody
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
    }

    /// Shared section chrome for the security sheet — title row + content
    /// + bottom divider (omitted for the last section).
    @ViewBuilder
    private func securitySection<Content: View>(
        title: String,
        isLast: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .qaudionStyle(type.labelSmall)
                .tracking(1.2)
                .foregroundStyle(scheme.onSurfaceVariant)
            content()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        if !isLast {
            Divider().background(scheme.outline.opacity(0.25))
        }
    }

    /// Cipher + key + epoch/rekey section body.
    ///
    /// "CIFRA" intentionally reuses `keyInfo.pqcAlgorithm` (the SAME field
    /// keyInfoPanel already shows) rather than a hardcoded transport-cipher
    /// string: `CallCapabilities.sframeAes256V1` exists in the engine but
    /// is a VIDEO-only, Phase-2 kill-switch tag that defaults OFF
    /// (`v4SFrameAes256Enabled`) — labelling every call "sframe-aes256-v1"
    /// would be false for audio-only calls and for any call where that
    /// switch is off. Better to repeat the one algorithm string we KNOW is
    /// live than fabricate a second, possibly-wrong one.
    ///
    /// "EPOCA" is the one row gated on `keyEpoch`: shown only when a real
    /// counter is supplied, omitted entirely otherwise (see `keyEpoch` doc
    /// comment for why no live rekey countdown is offered).
    private var cipherKeySectionBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let keyInfo {
                keyInfoRow("CIFRA", keyInfo.pqcAlgorithm)
            }
            if let keyEpoch {
                keyInfoRow("EPOCA", "\(keyEpoch)")
            }
        }
    }

    /// Transport section body: media path + codec-ish info, reusing the
    /// exact same `transportMode` the trust-bar/transport-row already show
    /// — no second source of truth for "what transport is this call on".
    private var transportSectionBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            keyInfoRow("PERCORSO", transportMode.label)
            keyInfoRow("STATO", transportMode == .disconnected ? "in negoziazione…" : "attivo")
        }
    }

    /// INTERPRETED voice biometrics: value + plain-language meaning, using
    /// the SAME thresholds/status helpers as `guardianRibbon` (stress/HNR
    /// bands) plus jitter/shimmer and speech-rate rows that the compact
    /// ribbon has no room for. All rows omitted (not zero-filled) when
    /// `voiceBiometrics == nil`.
    @ViewBuilder
    private var voiceBiometricsSectionBody: some View {
        if let bio = voiceBiometrics {
            VStack(alignment: .leading, spacing: 10) {
                biometricRow(
                    label: "Autenticità",
                    value: "\(confidenceWord(bio.confidence)) · \(String(format: "%.2f", bio.confidence))",
                    valueColor: confidenceColorFor(bio.confidence),
                    meaning: ">0.70 genuina · 0.25–0.70 verifica con SAS · <0.25 possibile voce sintetica (soglie ConfidenceIndex/ConfidenceThresholds)."
                )
                biometricRow(
                    label: "Stress",
                    value: "\(stressDisplayValue)/100 · \(stressStatusWord)",
                    valueColor: stressStatusColor,
                    meaning: "<35 calmo · 35–60 elevato · >60 agitato — un picco sostenuto può indicare pressione/coercizione."
                )
                biometricRow(
                    label: "Jitter / Shimmer",
                    value: "\(String(format: "%.1f", bio.jitter * 100))% / \(String(format: "%.1f", bio.shimmer * 100))%",
                    valueColor: scheme.onSurface,
                    meaning: "Normale <1% / <3% (convenzione voice-science). Valori troppo perfetti (≈0) sono a loro volta sospetti — una voce umana non è mai così stabile."
                )
                biometricRow(
                    label: "Respiro · HNR",
                    value: "\(hnrDisplayValue) dB · \(String(format: "%.2f", bio.breathiness))",
                    valueColor: hnrStatusColor,
                    meaning: ">20 dB chiara · <10 dB rauca o link rumoroso (VoiceHealthMonitor: breathiness = 1 − hnr/20)."
                )
                biometricRow(
                    label: "Pitch f0 · rate",
                    value: "\(pitchDisplayValue) Hz · \(String(format: "%.1f", bio.syllablesPerSec)) syl/s",
                    valueColor: scheme.onSurface,
                    meaning: "Uno scarto improvviso dal basale di \(peerDisplayName) può segnalare una sostituzione/impersonificazione."
                )
            }
        } else {
            Text("Biometria vocale non disponibile per questa chiamata.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
    }

    private func biometricRow(label: String, value: String, valueColor: Color, meaning: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .qaudionStyle(type.labelMedium)
                    .foregroundStyle(scheme.onSurfaceVariant)
                Spacer()
                Text(value)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(valueColor)
            }
            Text(meaning)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    /// `ConfidenceIndex.greenThreshold`/`redThreshold` equivalents exposed
    /// via `ConfidenceThresholds` (0.70 / 0.25) — same values already used
    /// by `confidenceColor` below, reused here for the biometrics row so
    /// the "Autenticità" wording and its color never diverge from the
    /// avatar-halo tone.
    private func confidenceWord(_ value: Float) -> String {
        switch ConfidenceThresholds.category(of: Double(value)) {
        case 0:  return "genuina"
        case 1:  return "verifica con SAS"
        default: return "a rischio"
        }
    }
    private func confidenceColorFor(_ value: Float) -> Color {
        switch ConfidenceThresholds.category(of: Double(value)) {
        case 0:  return extras.success
        case 1:  return extras.warning
        default: return extras.riskHigh
        }
    }

    // MARK: - Bottom action row (pinned)

    // MARK: - Control dock (unified call UI — cosmetic regroup only)
    //
    // Every button below calls the EXACT SAME closure it did before this
    // pass (onToggleMute / onToggleSpeaker / onToggleCamera /
    // onUpgradeToVideo / onToggleScreenShare / onToggleVoiceEnhancement /
    // onAddParticipant / onHangup) — no new control was invented and no
    // existing one was removed. Only the grouping changed, to match the
    // unified dock layout from call-guardian-reference.html:
    //   Row 1 (primary):   Mute · Speaker · Video · Share screen
    //   Row 2 (secondary): Enhance · Add(disabled) · End
    // The reference's Row 2 also has "Chat" as its first button — chat-
    // over-call is explicitly wave-2 scope (deferred), so it is omitted
    // here rather than added as a non-functional placeholder button.
    //
    // W557 constraint carried over unchanged: two rows inside a rounded-
    // rectangle card so 4-5 buttons per row always fit on a 375pt screen
    // (the previous single-HStack-of-7 design overflowed iPhone SE).
    //
    // Add-participant: per spec, no API exists yet — CircularAction's
    // existing `isDisabled` (already supported, see Components/
    // CircularAction.swift) renders it visibly dimmed + non-interactive,
    // matching Android's current no-op state for this button. This is
    // NOT a new capability — onAddParticipant is still wired verbatim,
    // it simply never fires because CircularAction gates the tap.

    private var bottomActionRow: some View {
        VStack(spacing: 10) {
            primaryControlsRow
            secondaryControlsRow
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

    /// Row 1 (primary, top): mute · speaker · video/upgrade · screen-share.
    /// Same four controls as before the regroup, same closures — only the
    /// row they live in changed (previously mute/speaker/hangup shared a
    /// row; hangup now anchors the end of Row 2 instead, matching the
    /// reference's "End" position).
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
            if hasVideo {
                CircularAction(
                    icon: cameraOn ? "video.fill" : "video.slash.fill",
                    action: onToggleCamera,
                    diameter: 52,
                    background: cameraOn ? extras.success : scheme.surfaceVariant,
                    iconColor: cameraOn ? extras.onSuccess : scheme.onSurface
                )
            } else {
                CircularAction(
                    icon: "video.badge.plus",
                    action: onUpgradeToVideo,
                    diameter: 52,
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
                    diameter: 52,
                    background: screenSharing ? extras.success : scheme.surfaceVariant,
                    iconColor: screenSharing ? extras.onSuccess : scheme.onSurface
                )
                Spacer(minLength: 0)
            }
        }
    }

    /// Row 2 (secondary, bottom): voice-enhance · add-participant
    /// (visually present, disabled/no-op) · hangup (prominent, larger,
    /// anchors the end of the dock — matches the reference's "End"
    /// position instead of floating mid-row).
    private var secondaryControlsRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            CircularAction(
                icon: "line.3.horizontal",
                action: onToggleVoiceEnhancement,
                diameter: 48,
                background: voiceEnhancement ? extras.success : scheme.surfaceVariant,
                iconColor: voiceEnhancement ? extras.onSuccess : scheme.onSurface
            )
            Spacer(minLength: 0)
            // No add-participant API exists yet (spec: render present but
            // disabled/no-op, matching Android's current state — do not
            // build 1:1→group escalation now). CircularAction's isDisabled
            // dims the icon and blocks the tap at the button level.
            CircularAction(
                icon: "person.badge.plus",
                action: onAddParticipant,
                diameter: 48,
                background: scheme.surfaceVariant,
                iconColor: scheme.onSurface,
                isDisabled: true
            )
            Spacer(minLength: 0)
            // Hangup — prominent, larger than secondary buttons, anchors
            // the end of the dock (matches the reference's "End" slot).
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
        rxSamples: [0.1, 0.3, -0.2, 0.4, -0.3, 0.2, 0.1, -0.15],
        voiceBiometrics: .init(
            stressScore: 0.18, jitter: 0.006, shimmer: 0.021,
            hnr: 21, breathiness: 0.12, pitchHz: 142,
            syllablesPerSec: 4.1, confidence: 0.94,
            f1: 620, f2: 1200, f3: 2600, f4: 3400, speaking: true
        ),
        keyEpoch: nil,
        cryptoOpsPerSec: 96,
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
