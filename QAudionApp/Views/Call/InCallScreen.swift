import SwiftUI
import QAudionEngine

/// Active 1:1 call screen (audio, with optional video). Aligns with:
///   - Android `qaudion-android-new/feature/feature-call/.../InCallScreen.kt`
///   - Desktop `Q-Audion Desktop — Call Surface Variants` Stitch project
///   - Mobile Stitch mockup `Q-Audion Active Call` (project 15710203507549916868)
///
/// Cross-platform parity is the design contract. Component vocabulary
/// (MetaPill / CircularAction / AvatarHalo / QAudionAvatar)
/// and color tokens (`scheme.X`, `extras.Y`) are shared with Android and
/// Desktop — only the layout is mobile-tuned.
///
/// Layout (top → bottom) — mirrors the Android InCallScreen ceremony
/// column 1:1 (2026-07-04 dedup pass: the old SessionStatusStrip call and
/// the old synthetic "VOCE RICEVUTA"/"CIFRATURA" oscilloscopes were
/// DELETED — the Guardian ribbon's real-FFT MiniSpectrum + real-ops/s
/// CipherFlowTube are their one honest replacement):
///   1. **Hero avatar** — 180pt halo (success → connected, pqcAccent →
///      negotiating, warning → degraded) wrapping a 120pt avatar with
///      the per-name gradient.
///   2. **Peer name** + presence subtitle.
///   3. **Stats band** — 3 columns: DURATA, CONFIDENCE, RE-KEY progress
///      (Android's stats Row; absorbs what SessionStatusStrip showed).
///   4. **Trust bar** — SAS ✓ / PQC / transport chips + shield-to-expand.
///   5. **Guardian ribbon** — real-FFT MiniSpectrum + cipher-seal chip +
///      3 gauges (STRESS / BREATH·HNR / PITCH) + ENGINE CipherFlowTube.
///   6. **TrustChainCard** — Mic→Seal→Air custody visual, full
///      phone-vs-earbud model (iOS-only card, honest data).
///   7. **SAS verification panel** — visible only when `sasWords.count == 6`.
///   8. **Key info panel** — visible only when `keyInfo != nil`.
///   9. **Pills row** — LIVENESS / PSK ROTATION badges.
///  10. **Transport row** — P2P-SRTP / TURN / RELAY / CONNECTING + an
///      optional analytics toggle (`onToggleDiagnostics`).
///  11. **Pinned bottom action row** — 2-row dock: mute / speaker /
///      video / screen-share · enhance / add-participant / hangup.
///
/// Stub fields (not yet wired through `AppState` / engine call state):
/// `confidence`, `rekeyInSeconds`, `sasWords`, `sasVerified`, `keyInfo`,
/// `transportMode`. Defaults render the screen for design preview; the
/// real wiring lands once `AppState.callState`/`InCallContainer` exposes
/// the equivalent fields.
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

    /// W-SHIELDBADGES (item 1, 2026-07-31 InCallScreen Android→iOS parity)
    /// — which trust-bar shield's tap-to-explain popup is showing, if any.
    /// Local UI-only state, same posture as `showSecuritySheet` above.
    @State private var trustBadgeInfo: TrustBadgeInfo?

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

        /// W-SHIELDBADGES (item 1, 2026-07-31 InCallScreen Android→iOS
        /// parity) — short label for the trust-bar transport SHIELD, which
        /// has room for ~4-5 monospace characters (the same shape as
        /// Android's `incall_transport_p2p`/`_turn`/`_relay` string
        /// resources). `label` above is unchanged and keeps feeding the
        /// full-width transport row further down the screen.
        var shortLabel: String {
            switch self {
            case .p2pSrtp:        return "P2P"
            case .turn:           return "TURN"
            case .bcryptoWsRelay: return "RELAY"
            case .disconnected:   return "…"
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
        // Unified call UI — f1…f4 are the REAL vocal-resonance peak
        // frequencies (Hz) from VoiceAnalysisResult.Formants. As of the
        // real-FFT MiniSpectrum (2026-07-04) they NO LONGER drive the
        // spectrum bars — the bars are the actual `voiceSpectrum` bands —
        // but the fields are retained (call sites/previews already
        // populate them, and a future formant overlay may use them).
        // `speaking` still gates the MiniSpectrum's cyan→green "active"
        // tint (VoiceAnalysisResult.speechRate.isSpeaking && .pitch.voiced).
        // Defaulted so preview/test call sites keep compiling.
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
    /// TrustChainCard — true when the active media provider is the earbud
    /// secure element (mic + seal both live in earbud hardware, so the
    /// protection envelope reaches the microphone). Android parity:
    /// `GuardianRibbon.kt` `TrustChainCard(earbudActive:)`. iOS has NO
    /// earbud media-provider path yet, so live call sites wire a constant
    /// `false` — the view still implements BOTH states so the card is
    /// ready the day the provider lands (and for design previews).
    let earbudActive: Bool
    /// TrustChainCard — true when the earbud's CRACEN secure element was
    /// confirmed active (drives the "Secure element CRACEN ✓ / linking…"
    /// stat row). Only meaningful while `earbudActive == true`.
    let earbudHwVerified: Bool
    /// Unified call UI — live Guardian voice-biometrics snapshot for the
    /// security sheet + Guardian ribbon mini-gauges. nil while unavailable
    /// (engine flag off, or no result yet — both call directions wired) —
    /// every dependent row is omitted gracefully, never fabricated.
    let voiceBiometrics: VoiceBiometrics?
    /// Unified call UI — REAL remote-voice spectrum: 40 log-spaced bands
    /// (0..1) of ACTUAL RX-PCM FFT magnitude (`SpectrumExtractor`, ≤15 Hz).
    /// Drives the Guardian ribbon MiniSpectrum bars 1:1 — parity with
    /// Android's real-FFT MiniSpectrum, no synthetic shimmer, no formant
    /// fake. nil ⇒ no decoded frame yet / between calls ⇒ the bars decay
    /// to rest rather than animating fabricated motion.
    let voiceSpectrum: [Float]?
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
    /// P0-3 (2026-08-05, coordinated fix plan cluster 3) — true when the
    /// handshake identity verdict for THIS call was `.abort` (a signature was
    /// required and did not verify). Unlike `identityUnauthenticatedChange`
    /// above, this ONE actually gates media: `AppState` holds back the relay
    /// sealers / v4 ratchet bootstrap until the user taps "CONFERMA COINCIDONO"
    /// below, same blocking-SAS-gate policy already shipped on Android/Desktop.
    /// The banner exists so the user understands WHY audio hasn't started yet.
    let awaitingIdentityConfirmation: Bool
    /// W-ASSURANCE (ship step 6) — THIS call's LIVE `AssuranceState.decide()`
    /// verdict, mapped to display copy by `AssuranceStateUI.present(...)`.
    /// nil ⇒ no key-confirmation attempt has resolved yet (rendered as no
    /// section at all, never a fabricated placeholder verdict).
    ///
    /// **NEVER the same widget as a contact's historical badge**
    /// (`ContactDetailScreen`'s `PresenceAuth`-driven badge) — this is
    /// computed FRESH from THIS handshake every time and rendered in its own
    /// security-sheet section, never merged into `keyInfoPanel`/`trustChip`
    /// (the static handshake-parameter display) or into any contact-level
    /// widget. See this project's "two things that must never share a
    /// widget" rule.
    let assurancePresentation: AssuranceStateUI.Presentation?
    /// W-NFCCOMMON (2026-07-24, Pavel correction) — "this device and the peer
    /// both hold a matching NFC-tap secret", independent of
    /// [assurancePresentation] above (which reflects what THIS call's session
    /// key actually mixed). Drives the trust bar's own always-on "NFC ✓" chip,
    /// additive to — never gated by — whatever [assurancePresentation] shows.
    let mutualNfcInCommon: Bool
    /// W-NFCCOMMON follow-up (2026-07-24, Pavel DECISION) — "a pre-shared key of
    /// ANY origin (KMS/NFC/QR/manual) is mixed into this call's session key",
    /// independent of [assurancePresentation]. Deliberately shows in EVERY state
    /// a PSK was mixed, INCLUDING warning states — see the property's doc on
    /// `AppState.callPskMixedThisCall` for the full rationale.
    let pskMixedThisCall: Bool
    /// "Voce come chiave" cross-device attestation (item 2, 2026-07-31
    /// InCallScreen Android→iOS port) — `true` once the PEER has announced
    /// Voice-as-Key is enrolled on THEIR OWN device (self-declared, not a
    /// crypto proof — see the trust-bar voice-key shield's tap-to-explain
    /// copy). Drives that shield's visibility; `false`/unannounced ⇒ hidden,
    /// same "additive, never a gate" posture as `mutualNfcInCommon`/
    /// `pskMixedThisCall` above. Mirrors `AppState.callPeerVoiceKeyEnrolled`.
    let peerVoiceKeyEnrolled: Bool
    let onAddParticipant: () -> Void
    let onHangup: () -> Void
    let onConfirmSas: () -> Void
    let onToggleDiagnostics: () -> Void
    /// Feature B ("voce verificata") — state of the per-contact call-time
    /// voice-learning session, fed from the SAME decoded RX audio as
    /// `voiceBiometrics`/`voiceSpectrum` above. nil ⇒ no session has run
    /// this call. Item 5 (2026-07-31 port): auto-started silently by
    /// `AppState` on first-ever connect to a contact — this view never asks
    /// for a tap, it only SHOWS state (`voiceLearningControl`'s brief
    /// progress indicator while `.inProgress`).
    let voiceLearningState: VoiceLearningSession.State?
    /// Manual re-learn entry point — kept for API parity with
    /// `AppState.startVoiceLearning()` (mirrors Android's `CallController
    /// .startVoiceLearning()`, itself kept non-private "in case a future UI
    /// wants a manual re-learn affordance too"). No control in this view
    /// calls it any more since item 5 removed the manual CTA — see
    /// `voiceLearningControl`.
    let onStartVoiceLearning: () -> Void
    /// Item 5 (2026-07-31 InCallScreen Android→iOS port) — rolling window
    /// of RAW per-frame Guardian confidence samples driving
    /// `voiceConfidenceWave`, the permanent UI slot `voiceLearningControl`
    /// falls back to whenever no learning session is `.inProgress` (i.e.
    /// most of any call). Empty ⇒ the wave renders its neutral flat-line
    /// state. See `AppState.voiceConfidenceHistory`'s doc for the source.
    let voiceConfidenceHistory: [Float]
    /// "Voce storica" — the PEER's self-reported
    /// `AppState.peerOwnerContinuityLevel`: does THEIR live voice still
    /// match THEIR OWN historical Voice-as-Key enrollment, received over
    /// the `OWNER_CONT` opaque-message piggy-back (see
    /// `AppState.routeInboundCallPiggyBack`'s `.ownerContinuity` case).
    /// `.unknown` for the whole call unless the peer's device actually
    /// signals a transition — most calls never do, in which case this
    /// shield falls back to showing just the static `peerVoiceKeyEnrolled`
    /// fact (see the merged shield in `trustBar`). Matches Android's
    /// `GuardianRibbon.peerOwnerContinuityLevel` exactly — this is NOT this
    /// device's own local self-check (see `ContactVoiceVerifier`'s sibling
    /// engine class `OwnerContinuityMonitor`, which drives the OUTBOUND
    /// half of this signal from `AppState`, never a trust-bar shield of its
    /// own — Android doesn't show one either).
    let peerOwnerContinuityLevel: ContactVoiceContinuityGate.Level
    /// Tier 2 ("voce remota") — RX-side per-contact continuity level,
    /// published as `AppState.contactVoiceLevel`. `.unknown` until the
    /// first real score tick for the active contact — the shield stays
    /// hidden in that case too.
    let contactVoiceLevel: ContactVoiceContinuityGate.Level

    init(peerDisplayName: String,
         avatarUrl: URL? = nil,
         durationSeconds: Int = 0,
         confidence: Double = 0.92,
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
         earbudActive: Bool = false,
         earbudHwVerified: Bool = false,
         voiceBiometrics: VoiceBiometrics? = nil,
         voiceSpectrum: [Float]? = nil,
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
         awaitingIdentityConfirmation: Bool = false,
         assurancePresentation: AssuranceStateUI.Presentation? = nil,
         mutualNfcInCommon: Bool = false,
         pskMixedThisCall: Bool = false,
         peerVoiceKeyEnrolled: Bool = false,
         onAddParticipant: @escaping () -> Void = {},
         onHangup: @escaping () -> Void,
         onConfirmSas: @escaping () -> Void = {},
         onToggleDiagnostics: @escaping () -> Void = {},
         voiceLearningState: VoiceLearningSession.State? = nil,
         onStartVoiceLearning: @escaping () -> Void = {},
         voiceConfidenceHistory: [Float] = [],
         peerOwnerContinuityLevel: ContactVoiceContinuityGate.Level = .unknown,
         contactVoiceLevel: ContactVoiceContinuityGate.Level = .unknown) {
        self.peerDisplayName = peerDisplayName
        self.avatarUrl = avatarUrl
        self.durationSeconds = durationSeconds
        self.confidence = confidence
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
        self.earbudActive = earbudActive
        self.earbudHwVerified = earbudHwVerified
        self.voiceBiometrics = voiceBiometrics
        self.voiceSpectrum = voiceSpectrum
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
        self.awaitingIdentityConfirmation = awaitingIdentityConfirmation
        self.assurancePresentation = assurancePresentation
        self.mutualNfcInCommon = mutualNfcInCommon
        self.pskMixedThisCall = pskMixedThisCall
        self.peerVoiceKeyEnrolled = peerVoiceKeyEnrolled
        self.onAddParticipant = onAddParticipant
        self.onHangup = onHangup
        self.onConfirmSas = onConfirmSas
        self.onToggleDiagnostics = onToggleDiagnostics
        self.voiceLearningState = voiceLearningState
        self.onStartVoiceLearning = onStartVoiceLearning
        self.voiceConfidenceHistory = voiceConfidenceHistory
        self.peerOwnerContinuityLevel = peerOwnerContinuityLevel
        self.contactVoiceLevel = contactVoiceLevel
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
        // W-SHIELDBADGES (item 1) — tap-to-explain popup for whichever
        // trust-bar shield was tapped. A native `.alert`, not a second
        // sheet: this is a single short paragraph, not a place to drag
        // around — matches this project's convention of reserving `.sheet`
        // for genuinely scrollable/aggregating content.
        .alert(
            trustBadgeInfo?.title ?? "",
            isPresented: trustBadgeInfoPresented
        ) {
            Button("Ho capito") { trustBadgeInfo = nil }
        } message: {
            Text(trustBadgeInfo?.body ?? "")
        }
    }

    /// Bridge `trustBadgeInfo` ↔ the SwiftUI `.alert(isPresented:)` API,
    /// same computed-`Binding` pattern `LiveInCallScreen
    /// .incomingUpgradeAlertBinding` already uses for the same reason (the
    /// state driving the alert's CONTENT is richer than a plain `Bool`).
    private var trustBadgeInfoPresented: Binding<Bool> {
        Binding(
            get: { trustBadgeInfo != nil },
            set: { shown in if !shown { trustBadgeInfo = nil } }
        )
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

    // MARK: - P0-3 identity-hold banner (media IS gated — distinct from the
    //         advisory-only banner above)

    /// Shown while `awaitingIdentityConfirmation` is true: the handshake
    /// identity signature was required and did not verify, so `AppState` is
    /// holding back audio/video until the user confirms the SAS below.
    /// Deliberately a stronger visual (`riskHigh`) than `identityChangeBanner`
    /// (`warning`) — that one is advisory-only, this one reflects a real gate.
    private var identityHoldBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(extras.riskHigh)
            VStack(alignment: .leading, spacing: 2) {
                Text("AUDIO IN ATTESA DI CONFERMA")
                    .qaudionStyle(type.labelSmall)
                    .tracking(0.6)
                    .foregroundStyle(extras.riskHigh)
                Text("La firma dell'identità non è stata verificata. Confronta le parole SAS qui sotto per attivare audio e video.")
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
                        .stroke(extras.riskHigh.opacity(0.6), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Audio e video in attesa: verifica le parole SAS per continuare la chiamata in sicurezza.")
    }

    // MARK: - W-ASSURANCE (ship step 6) — live per-call verdict section body

    /// Renders `AssuranceStateUI.present(...)`'s output — the visual
    /// treatment (`.badge`/`.warning`/`.info`) is `AssuranceStateUI.Style`,
    /// decided entirely OUTSIDE this view. This function ONLY picks colours/
    /// iconography per style; it never re-derives trust logic from the raw
    /// `AssuranceState` case, so a future new state needs only a
    /// `AssuranceStateUI.present` mapping, not a new SwiftUI branch here.
    /// W-NFCBADGE: the one exception is `presentation.isPhysicalPresenceProof`
    /// (itself a `Presentation` field, not a raw enum switch — see that
    /// property's doc) which selects a visually-distinct, more prominent
    /// treatment for S2 specifically, vs every other `.badge`-style state
    /// (e.g. S8's ordinary PSK confirmation).
    ///
    /// W-NOBRICK: purely informational — no button here can drop the call;
    /// the existing SAS/hangup controls elsewhere on screen are untouched.
    @ViewBuilder
    private func assuranceSectionBody(_ presentation: AssuranceStateUI.Presentation) -> some View {
        if presentation.isPhysicalPresenceProof {
            physicalPresenceBadge(presentation)
        } else {
            let tint: Color = {
                switch presentation.style {
                case .badge: return extras.success
                case .warning: return extras.warning
                case .info: return scheme.onSurfaceVariant
                }
            }()
            let icon: String = {
                switch presentation.style {
                case .badge: return "checkmark.shield.fill"
                case .warning: return "exclamationmark.shield.fill"
                case .info: return "info.circle.fill"
                }
            }()
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                Text(presentation.message)
                    .qaudionStyle(type.labelMedium)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(scheme.surfaceVariant)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(tint.opacity(presentation.style == .info ? 0.25 : 0.55), lineWidth: 1)
                    )
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(presentation.message)
        }
    }

    /// W-NFCBADGE — S2's (`.nfcAuthenticated`) extra-prominent treatment:
    /// bigger/bolder icon, an ALL-CAPS eyebrow label (same convention as
    /// `identityChangeBanner`'s title above, and `sasPanel`'s own header
    /// below — this app's existing pattern for "this line matters more than
    /// body copy"), and a tinted fill instead of the flat `surfaceVariant`
    /// every other assurance state renders on. Still purely informational
    /// (W-NOBRICK) — no control here, same as the generic branch.
    private func physicalPresenceBadge(_ presentation: AssuranceStateUI.Presentation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(extras.success)
            VStack(alignment: .leading, spacing: 3) {
                Text("PRESENZA FISICA VERIFICATA")
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.0)
                    .foregroundStyle(extras.success)
                Text(presentation.message)
                    .qaudionStyle(type.labelMedium)
                    .foregroundStyle(scheme.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(extras.success.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(extras.success.opacity(0.8), lineWidth: 1.5)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Presenza fisica verificata. \(presentation.message)")
    }

    // MARK: - Scroll content (everything above the pinned action row)

    /// One coherent vertical flow, mirroring Android InCallScreen.kt's
    /// ceremony Column order exactly (avatar → name → stats band → trust
    /// bar → Guardian ribbon → trust chain → SAS → key info → pills →
    /// transport). The old SessionStatusStrip call and the old stats card
    /// (synthetic oscilloscopes) are GONE — their surviving data (duration,
    /// confidence, rekey countdown) lives in `statsBand`.
    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 16)

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

                statsBand.padding(.horizontal, 20)

                Spacer().frame(height: 12)

                trustBar.padding(.horizontal, 20)

                Spacer().frame(height: 8)

                guardianRibbon.padding(.horizontal, 20)

                Spacer().frame(height: 8)

                trustChainCard.padding(.horizontal, 20)

                // D11 / W-NOBRICK — non-blocking security advisory. Shown when the
                // peer's identity key changed and is NOT in the server-published
                // per-device set. Advisory ONLY: it never gates audio/video; the
                // SAS panel below is the terminal verification.
                if identityUnauthenticatedChange {
                    Spacer().frame(height: 10)
                    identityChangeBanner.padding(.horizontal, 20)
                }

                // P0-3 — this one actually gates media (see the field's doc).
                if awaitingIdentityConfirmation {
                    Spacer().frame(height: 10)
                    identityHoldBanner.padding(.horizontal, 20)
                }

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

    // MARK: - Stats band (DURATA / CONFIDENCE / RE-KEY)

    /// Unified stats band under the peer name — 1:1 port of Android
    /// InCallScreen.kt's stats Row (DURATION / CONFIDENCE / REKEY): three
    /// columns in one thin outlined card. This band absorbs everything the
    /// deleted SessionStatusStrip call and the deleted old stats card
    /// showed that was real (duration, confidence, rekey countdown). The
    /// old synthetic "VOCE RICEVUTA"/"CIFRATURA" oscilloscopes are gone —
    /// the Guardian ribbon below carries the one honest voice viz
    /// (real-FFT MiniSpectrum) and crypto viz (real-ops/s CipherFlowTube).
    private var statsBand: some View {
        HStack(alignment: .center, spacing: 0) {
            statColumn("DURATA", formatMmSs(durationSeconds), extras.success)
            Spacer(minLength: 8)
            statColumn("CONFIDENCE",
                       String(format: "C=%.2f", min(1.0, max(0.0, confidence))),
                       confidenceColor)
            Spacer(minLength: 8)
            VStack(spacing: 4) {
                Text("RE-KEY")
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.2)
                    .foregroundStyle(scheme.onSurfaceVariant)
                rekeyProgress
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(scheme.surface.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(scheme.outline.opacity(0.5), lineWidth: 1)
        )
    }

    /// One label+value column of the stats band — mirrors Android's
    /// `StatColumn(label, value, color)` (monospace label 8.5sp / value 14sp).
    private func statColumn(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .qaudionStyle(type.labelSmall)
                .tracking(1.2)
                .foregroundStyle(scheme.onSurfaceVariant)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    /// Compact circular rekey countdown — port of Android core-ui
    /// `ReKeyProgress`: a ring that fills with the ELAPSED fraction of the
    /// rekey window plus a "NNs" remaining readout in the middle. Redrawn
    /// once per second by the caller's TimelineView tick (LiveInCallScreen);
    /// the 0.6s tween between ticks is draw-phase only (never-block rules:
    /// no timers, no per-frame tasks).
    private var rekeyProgress: some View {
        let total = max(rekeyTotalSeconds, 1)
        let remaining = min(max(rekeyInSeconds, 0), total)
        let elapsedFraction = 1.0 - Double(remaining) / Double(total)
        return ZStack {
            Circle()
                .stroke(scheme.surfaceVariant, lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(elapsedFraction))
                .stroke(scheme.primary,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: remaining)
            Text(Self.rekeySecondsText(remaining))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(scheme.onSurface)
        }
        .frame(width: 38, height: 38)
        .accessibilityLabel("Prossimo re-key tra \(remaining) secondi")
    }

    /// Static readout builder kept out of @ViewBuilder (SWIFT6_PATTERNS
    /// §1/§6). Mirrors Android's `seconds(sec)`: "now" at 0, else "NNs".
    private static func rekeySecondsText(_ remaining: Int) -> String {
        return remaining <= 0 ? "now" : remaining.description + "s"
    }

    // MARK: - SAS panel

    /// W-NFCBADGE — when S2 (`.nfcAuthenticated`) is this call's live verdict,
    /// the SAS ceremony is redundant (physical NFC proximity already exceeds
    /// what a verbal compare proves — see `AssuranceStateUI.Presentation
    /// .sasRequired`'s own doc, `false` for exactly this state) but stays
    /// FULLY visible and functional: same words, same button, same
    /// `onConfirmSas`/persistence behavior, completely untouched. Only the
    /// visual WEIGHT changes (a de-emphasizing opacity + a small explanatory
    /// hint), never the availability.
    private var sasCeremonyRedundant: Bool {
        assurancePresentation?.isPhysicalPresenceProof == true
    }

    @ViewBuilder
    private var sasPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if sasCeremonyRedundant {
                Text("Non necessario: già autenticato via NFC")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant.opacity(0.85))
            }

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
                .stroke((sasVerified ? extras.success : scheme.primary).opacity(sasCeremonyRedundant ? 0.3 : 0.6),
                        lineWidth: 1)
        )
        // Reduced visual weight ONLY — every control above stays fully
        // interactive at this opacity (SwiftUI does not gate hit-testing on
        // `.opacity`), so tapping "CONFERMA COINCIDONO" still calls
        // `onConfirmSas` -> `handleConfirmSas` -> `SasVerificationStore
        // .recordVerified` exactly as it does when S2 is not active. This is
        // a pure presentation change.
        .opacity(sasCeremonyRedundant ? 0.6 : 1.0)
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
            // W-UNIFORMKEYINFO — canonical spec: the row shows whenever a
            // method resolved, even if no human name did (e.g. a KMS key the
            // server sent with no key_name) — "(unnamed key)" is the shared
            // honest placeholder every platform uses, never a fingerprint
            // fragment disguised as a name.
            if let method = info.pskMethodLabel {
                let name = info.pskName ?? "(unnamed key)"
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

    /// W-SHIELDBADGES (item 1, 2026-07-31 InCallScreen Android→iOS parity)
    /// — every trust-bar fact now renders as a colored SHIELD with a small
    /// icon or short text label centered inside, replacing the old
    /// text+checkmark `trustChip` pills. The shield's COLOR alone carries
    /// verified/pending/absent state (green = confirmed/good, `pqcAccent` =
    /// active-but-neutral/unverified, muted `onSurfaceVariant` = inactive)
    /// — no checkmark glyph anywhere on the badge itself any more. Tapping
    /// ANY shield opens a short `.alert` (`trustBadgeInfo`) explaining that
    /// one fact; the trailing lock button still opens the full aggregating
    /// security sheet. Mirrors Android's `TrustBar`/`ShieldBadge`
    /// (`GuardianRibbon.kt`) 1:1 — same six facts, same conditions.
    private var trustBar: some View {
        HStack(spacing: 7) {
            // "Voce come chiave" (item 2) — the PEER's own device,
            // self-declared. Independent of every other fact here; see
            // `peerVoiceKeyEnrolled`'s doc. Placed first, ahead of NFC, to
            // match Android's ordering.
            // 2026-08-01 3-tier voice-auth design: this shield is now a
            // SUPERSET of the old static-only version — it shows whenever
            // there's anything to say at all (the static `peerVoiceKeyEnrolled`
            // fact, OR a real live `peerOwnerContinuityLevel` tri-state once
            // the peer's device has ever signalled a transition — most calls
            // never do, in which case this renders exactly as before: a flat
            // green "enrolled" shield). Matches Android's `GuardianRibbon`
            // merged shield exactly (same single `TrustBadgeInfo.voiceKey`
            // popup for both facts) — do NOT split this into two shields,
            // that was this file's own first draft and diverged from the
            // validated Android UI before being corrected against real
            // Android source.
            if peerVoiceKeyEnrolled || peerOwnerContinuityLevel != .unknown {
                trustShield(
                    tint: peerOwnerContinuityLevel == .mismatch ? extras.riskHigh
                        : (peerOwnerContinuityLevel == .uncertain ? extras.pqcAccent : extras.success),
                    icon: "mic.fill",
                    info: .voiceKey,
                    accessibilityLabel: peerOwnerContinuityLevel == .mismatch
                        ? "Attenzione: la voce del contatto non corrisponde più al suo profilo vocale dichiarato"
                        : "Il contatto ha attivato la Voce-come-chiave sul proprio dispositivo"
                )
            }
            // Tier 2 ("voce remota") — RX-side per-contact continuity, LOCAL
            // and continuous (this device hears the audio directly, no wire
            // signal involved). Hidden until the first real score tick for
            // the active contact (`.unknown` — no template yet / window not
            // full) — matches Android's `contactVoiceContinuityLevel` shield.
            if contactVoiceLevel != .unknown {
                trustShield(
                    tint: contactVoiceLevel == .mismatch ? extras.riskHigh
                        : (contactVoiceLevel == .uncertain ? extras.pqcAccent : extras.success),
                    icon: "ear",
                    info: .contactVoice,
                    accessibilityLabel: contactVoiceLevel == .verified
                        ? "La voce del contatto corrisponde a quella già conosciuta"
                        : (contactVoiceLevel == .mismatch
                            ? "Attenzione: la voce del contatto non corrisponde a quella già conosciuta"
                            : "Verifica della voce del contatto in corso")
                )
            }
            // W-NFCVISIBLE / W-NFCCOMMON — Pavel: an NFC key held in common with
            // this peer must be visible on the always-on trust bar, not only
            // inside the tap-to-open security sheet. Same "wave.3.right.circle"
            // glyph `NfcExchangeView` already uses for NFC elsewhere in this app
            // — this platform's own established NFC icon. Independent fact
            // (`mutualNfcInCommon`, NOT `assurancePresentation?.isPhysicalPresenceProof`
            // anymore): true whenever the peer's OFFER/ACCEPT key-list exchange shows
            // a mutual NFC-tier fingerprint, regardless of which secret THIS call's
            // session key ends up mixing (could be KMS/QR/plain PSK). Never implies
            // nor requires the PSK shield below — both render independently.
            if mutualNfcInCommon {
                trustShield(
                    tint: extras.success,
                    icon: "wave.3.right.circle.fill",
                    info: .nfc,
                    accessibilityLabel: "NFC in comune con il contatto"
                )
            }
            // W-NFCVISIBLE / W-NFCCOMMON follow-up (2026-07-24, Pavel DECISION) — "a
            // pre-shared key of ANY origin (KMS/NFC/QR/manual) is mixed into this call's
            // session key", driven directly by `pskMixedThisCall` (n>=1) — no longer by
            // `assurancePresentation` at all. Pavel's explicit choice: this shield shows
            // in EVERY state a PSK was mixed, INCLUDING warning states (S1 active-attack,
            // S3-S7 NFC-specific problems) — it answers only "does a shared secret exist
            // for this call", never "is everything about it fine" (the warning banner's
            // job). WHICH tier was actually mixed (NFC/KMS/other) is what
            // `KeyInfoPanel`'s detail row is for, not this compact shield.
            if pskMixedThisCall {
                trustShield(
                    tint: extras.success,
                    label: "PSK",
                    info: .psk,
                    accessibilityLabel: "Chiave pre-condivisa mescolata in questa chiamata"
                )
            }
            // W-UNIFORMKEYINFO — canonical spec (2026-07-24, cross-platform audit):
            // the SAS shield must be visible as soon as the 6-word code EXISTS
            // (mirrors Android's `hasSas = sasWords.size == 6` gate and Desktop's
            // TrustBar.svelte, both of which always render it), with only the
            // COLOR toggling on verification (green once verified, pqcAccent while
            // pending) — showing it early is what invites the user to actually go
            // verify. Gating the whole shield on `sasVerified` (previous behavior)
            // hid it entirely pre-verification, a real cross-platform divergence.
            if sasWords.count == 6 {
                trustShield(
                    tint: sasVerified ? extras.success : extras.pqcAccent,
                    label: "SAS",
                    info: .sas,
                    accessibilityLabel: sasVerified ? "Identità verificata (SAS)" : "Verifica identità (SAS) in sospeso"
                )
            }
            // PQC — ALWAYS rendered now (the old `if pqcActive` gate + a
            // separate "PQC off" text variant are both gone): the shield's
            // color alone carries active-vs-inactive, matching every other
            // shield on this bar and Android's identical change.
            trustShield(
                tint: pqcActive ? extras.pqcAccent : scheme.onSurfaceVariant,
                label: "PQC",
                info: .pqc,
                accessibilityLabel: pqcActive ? "Scambio post-quantistico attivo" : "Scambio post-quantistico non attivo"
            )
            trustShield(
                tint: transportMode == .disconnected ? scheme.onSurfaceVariant : extras.success,
                label: transportMode.shortLabel,
                info: .transport,
                accessibilityLabel: "Percorso di rete: \(transportMode.label)"
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

    /// The real Google Material "shield" filled-icon outline (24x24 grid),
    /// as a `Shape` rather than the SF Symbol `shield.fill` — needed so the
    /// SAME outline can be filled with `tint` AND stroked with a second
    /// gold color at once (a `Shape` supports independent `.fill`/`.stroke`
    /// modifiers; an `Image(systemName:)` can only be tinted as one flat
    /// color). Same path data used on Android (`SHIELD_PATH_DATA` in
    /// `GuardianRibbon.kt`) for pixel-identical shape cross-platform.
    private struct TrustShieldOutline: Shape {
        func path(in rect: CGRect) -> Path {
            let s = rect.width / 24
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
            }
            var p = Path()
            p.move(to: pt(12, 1))
            p.addLine(to: pt(3, 5))
            p.addLine(to: pt(3, 11))
            p.addCurve(to: pt(12, 23), control1: pt(3, 16.55), control2: pt(6.84, 21.74))
            p.addCurve(to: pt(21, 11), control1: pt(17.16, 21.74), control2: pt(21, 16.55))
            p.addLine(to: pt(21, 5))
            p.addLine(to: pt(12, 1))
            p.closeSubpath()
            return p
        }
    }

    private static let trustShieldGold = LinearGradient(
        colors: [Color(red: 0.953, green: 0.824, blue: 0.478), Color(red: 0.831, green: 0.686, blue: 0.216), Color(red: 0.592, green: 0.443, blue: 0.106)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// One trust-bar fact: a colored shield with a small black icon or
    /// short black label centered on top, tappable to open `info`'s
    /// tap-to-explain `.alert`. Shape/color language shared by every badge
    /// on `trustBar` — only `tint`/`icon`/`label`/`info` differ per fact,
    /// and `tint` ALONE carries the verified/pending/absent state (no
    /// separate checkmark).
    ///
    /// W-SHIELDGOLD (2026-08-04, Pavel pick "C" from the gold proposal) —
    /// back to the plain Material shield silhouette (not the ornate Stitch
    /// artwork from the previous attempt, which read as "worse than the
    /// original"). Bigger than before (30pt → 36pt) and finished as a
    /// small medal: `tint` still fills the shield exactly like the old
    /// `shield.fill` SF Symbol did, plus a gold gradient stroke around the
    /// rim and two gold studs at the top shoulders. The inner icon/label
    /// is now BLACK instead of white — white on top of pale/desaturated
    /// tints was hard to read; black holds contrast against every tint in
    /// the palette.
    private func trustShield(
        tint: Color,
        icon: String? = nil,
        label: String? = nil,
        info: TrustBadgeInfo,
        accessibilityLabel: String
    ) -> some View {
        Button {
            trustBadgeInfo = info
        } label: {
            ZStack {
                TrustShieldOutline().fill(tint)
                TrustShieldOutline().stroke(Self.trustShieldGold, lineWidth: 1.6)
                Circle().fill(Self.trustShieldGold).frame(width: 3.4, height: 3.4).offset(x: -12.6, y: -10.2)
                Circle().fill(Self.trustShieldGold).frame(width: 3.4, height: 3.4).offset(x: 12.6, y: -10.2)
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black)
                } else if let label {
                    Text(label)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.2)
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    /// W-SHIELDBADGES (item 1) — which shield's tap-to-explain popup is
    /// showing. `title`/`body` are the exact meanings this task specifies,
    /// translated into Italian matching this screen's own established copy
    /// style (e.g. `identityChangeBanner`/the SAS panel above) rather than
    /// a verbatim copy of Android's strings.
    enum TrustBadgeInfo {
        case voiceKey, contactVoice, nfc, psk, sas, pqc, transport

        var title: String {
            switch self {
            case .voiceKey:         return "Voce come chiave"
            case .contactVoice:     return "Voce remota"
            case .nfc:              return "NFC in comune"
            case .psk:              return "Chiave pre-condivisa (PSK)"
            case .sas:              return "Verifica identità (SAS)"
            case .pqc:              return "Post-quantistico (PQC)"
            case .transport:        return "Percorso di rete"
            }
        }

        var body: String {
            switch self {
            case .voiceKey:
                return "Il contatto ha attivato lo sblocco vocale sul proprio dispositivo. Quando il suo telefono rileva una transizione live (per esempio uno scambio di persona a metà chiamata), il colore di questo scudo cambia per segnalarlo — altrimenti mostra semplicemente il fatto statico che l'ha attivato. Non è una prova crittografica: è un'informazione che il dispositivo del contatto dichiara di sé stesso."
            case .contactVoice:
                return "Verifica continua, durante la chiamata, che la voce che stai ASCOLTANDO corrisponda a quella già imparata per questo contatto nelle chiamate precedenti. Se il contatto parla per la prima volta, l'apprendimento avviene automaticamente in sottofondo nei primi secondi."
            case .nfc:
                return "Tu e il contatto avete in comune un segreto scambiato fisicamente avvicinando i telefoni (NFC). Indipendente da quale chiave stia effettivamente usando questa specifica chiamata."
            case .psk:
                return "In questa chiamata è stata mescolata una chiave pre-condivisa — di qualunque origine: NFC, QR, KMS o inserita a mano — nella chiave di sessione. Aggiunge protezione oltre al solo scambio post-quantistico."
            case .sas:
                return "La cerimonia di verifica dell'identità per questa chiamata: tu e il contatto confrontate a voce le stesse parole. Il colore indica se è già stata confermata da entrambi o è ancora in sospeso."
            case .pqc:
                return "Lo scambio di chiavi post-quantistico (ML-KEM) è attivo per questa chiamata: protegge anche se un computer quantistico del futuro intercettasse oggi il traffico cifrato e provasse a decifrarlo più avanti."
            case .transport:
                return "Come viaggia l'audio: direttamente tra i due telefoni (P2P), tramite un server di attraversamento NAT (TURN), oppure tramite il relay del server Q-Audion (RELAY) quando non c'è una via diretta. Il contenuto resta cifrato end-to-end su qualunque percorso."
            }
        }
    }

    // MARK: - Guardian ribbon (unified call UI)

    /// Compact Guardian strip: a small live remote-voice spectrum on the
    /// left, a cipher/seal visual on the right, 3 mini gauges below
    /// (stress / breath·HNR / pitch) with a one-word status per gauge, and —
    /// when the crypto engine is doing real work (ops/s > 0) — a thin
    /// cipher-flow tube at the bottom. Additive and small per spec — NOT
    /// the full decorative canvas spectrum-analyzer from the HTML reference.
    /// The mini-spectrum shows the REAL RX FFT bands (see `miniSpectrum`),
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

    /// Per-band displayed bar height with asymmetric attack/decay smoothing
    /// (instant rise to a louder band, gentle 0.78 fall) — the exact
    /// `display[]` logic of Android's `MiniSpectrum`. A plain
    /// (non-observable) final class kept in `@State` so the SAME buffer
    /// survives re-renders, while mutating it during the Canvas draw phase
    /// never invalidates/recomposes the view tree (2026-07-04 never-block
    /// rules: the draw is the only thing that runs per display frame).
    private final class SpectrumDisplayHolder {
        var levels = [Float](repeating: 0, count: 40)
    }
    @State private var spectrumDisplay = SpectrumDisplayHolder()

    /// Live remote-voice mini-spectrum — the REAL thing, parity with Android
    /// `MiniSpectrum` (feature-call/ui/GuardianRibbon.kt). Each bar is the
    /// actual FFT magnitude of the decoded remote PCM (40 log-spaced bands,
    /// 0..1, computed by `SpectrumExtractor` on the RX audio at ≤15 Hz), so
    /// the bars move with what is genuinely being said. No synthetic
    /// shimmer, no formant fake — the old gaussian-bump code path is gone.
    ///
    /// The only smoothing is a per-band fall decay held in
    /// `spectrumDisplay` (the bar can jump UP instantly to a new peak, then
    /// eases DOWN) so the display reads as a fluid analyser rather than a
    /// strobing histogram. When `voiceSpectrum` is nil (pre-first-frame /
    /// between calls) the bars decay to the idle floor and rest.
    ///
    /// Frame source: the existing `TimelineView(.animation(paused:
    /// reduceMotion))` — one Canvas redraw per display frame, zero
    /// recomposition. Under Reduce Motion the timeline pauses and the bars
    /// simply snap to each ≤15 Hz spectrum update without the decay tween.
    private var miniSpectrum: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas { ctx, size in
                // Explicitly read the timeline date so each tick is a real
                // dependency of this draw — the decay smoothing advances per
                // display frame even though the value itself is unused.
                _ = timeline.date
                drawMiniSpectrum(ctx: &ctx, size: size)
            }
        }
    }

    /// Pure Canvas draw for `miniSpectrum` — extracted so the TimelineView
    /// body stays shallow (SWIFT6_PATTERNS §5/§6); mirrors Android's
    /// `MiniSpectrum` Canvas block 1:1 (instant-rise / 0.78-decay smoothing
    /// INSIDE the draw, 40 bars, per-bar active/idle brush).
    private func drawMiniSpectrum(ctx: inout GraphicsContext, size: CGSize) {
        // Advance the per-band display levels (mutating the class holder —
        // never triggers a view update; see SpectrumDisplayHolder).
        let holder = spectrumDisplay
        if let bands = voiceSpectrum {
            let n = min(holder.levels.count, bands.count)
            for i in 0..<n {
                let target = bands[i]
                // Instant rise to a louder band, gentle fall — analyser feel.
                holder.levels[i] = target > holder.levels[i]
                    ? target
                    : holder.levels[i] * 0.78 + target * 0.22
            }
        } else {
            for i in holder.levels.indices { holder.levels[i] *= 0.85 }
        }

        let speaking = voiceBiometrics?.speaking ?? false
        let n = holder.levels.count
        guard n > 0 else { return }
        let gap = min(size.width * 0.20 / CGFloat(n), 2.2)
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
            let h = CGFloat(min(max(holder.levels[i], 0.02), 1.0))
            let barH = h * size.height
            let rect = CGRect(x: x, y: baseY - barH, width: max(bw, 1), height: barH)
            let barPath = Path(roundedRect: rect, cornerRadius: 1.2)
            ctx.fill(barPath,
                     with: (speaking || h > 0.08) ? activeGradient : idleShading)
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

    // MARK: - Trust-chain card (unified call UI — custody of your voice)
    //
    // Full native port of the approved "custody of your voice" mockup
    // (trust-chain.html, scratchpad design spec): two ambient particle-flow
    // lanes either side of a glowing pulsing seal core, a morphing bordered
    // "protection boundary" box with a floating label, a callout-box verdict,
    // a 5-cell stat ring row, and a collapsible earbud detail panel. This
    // REPLACES the previous plain 3-label chain + thin progress bar
    // (2026-07-04 unified-call-ui redesign) — no second component, no dead
    // code left behind (`trustNode`/`trustStat`/`trustArrow` plain helpers
    // removed with it).
    //
    // All animation follows the two conventions ALREADY established in this
    // same file rather than inventing new ones:
    //  - continuous per-frame drawing → `TimelineView(.animation(paused:
    //    reduceMotion))` + `Canvas`, deterministic golden-ratio index hashing
    //    for per-particle phase/speed/lane/wobble (see `drawCipherTube`/
    //    `drawMiniSpectrum` above) — cheap, stable across frames, paused
    //    under Reduce Motion exactly like the spectrum/cipher-tube visuals.
    //  - the boundary-box morph (position/width/color/label) is a plain
    //    `.animation(.linear(duration: 0.6), value: earbudActive)` layout
    //    tween — the SAME 0.6s duration the old progress-bar envelope used,
    //    preserved rather than inventing a different timing.
    //
    // All data is real, unchanged from the previous implementation:
    // `earbudActive`/`earbudHwVerified` from the call site (constant `false`
    // today pending the iOS earbud media-provider — see LiveInCallScreen),
    // plus `sasVerified`/`pqcActive`/`transportMode` already stored on this
    // view for the trust bar above. The mockup's manual toggle button is a
    // demo-only affordance and is intentionally NOT ported — production
    // state is always driven by these real flags.
    //
    // NOT ported: the mockup's bottom "how it reads inside the call" one-
    // line strip preview. This screen's `trustBar` (SAS ✓ / PQC / transport
    // chips, rendered just above the Guardian ribbon) already surfaces the
    // same "how it reads" summary in a slot that exists today — a second
    // strip directly under this card would duplicate it rather than adding
    // information, so it is intentionally omitted per the task's own
    // "don't force it" guidance.

    /// Protection-envelope start fraction for the SOFTWARE path: the seal
    /// happens on the phone, so the envelope covers Seal→Air and the MIC
    /// sits just OUTSIDE it on the left. Same 0.42 constant as Android's
    /// `TrustChainCard` software branch (and the mockup's `left:40%`). The
    /// earbud path starts at 0.0 (the envelope reaches the microphone).
    private static let trustEnvelopeStartSoftware: CGFloat = 0.42

    /// Trust-chain card — the honest "where is the voice sealed, and does
    /// the protection reach the microphone?" visual.
    ///
    ///  - SOFTWARE (`earbudActive == false`, today's only live iOS state):
    ///    the seal happens ON THE PHONE, so the protection envelope starts
    ///    at 42% and the MICROPHONE sits just outside it — raw audio exists
    ///    in the phone's audio pipeline for an instant before it is sealed.
    ///    The OS keystore/Keychain keeps the KEYS safe, but a compromised
    ///    OS could tap the mic upstream of encryption. Cyan accent,
    ///    "GRADE A".
    ///  - EARBUD (`earbudActive == true`, ready for when the earbud media
    ///    provider lands on iOS): mic AND seal both live inside the
    ///    earbud's secure chip, so the envelope extends to the microphone
    ///    and raw voice never reaches the phone. Gold accent, "GRADE A+ ·
    ///    SOVEREIGN", plus a live "Secure element CRACEN ✓ / linking…"
    ///    stat driven by `earbudHwVerified`. (Android also shows battery/
    ///    ANC from its BudsStatus; iOS has no equivalent source yet, so
    ///    those rows are omitted rather than fabricated — same discipline
    ///    as before this redesign.)
    private var trustChainCard: some View {
        let gold = extras.warning          // sovereign-hardware accent (amber/gold)
        let cyan = extras.pqcAccent
        let cipher = extras.pqcAccent      // mockup's --cipher lane tint (violet)
        let envColor = earbudActive ? gold : cyan
        let envelopeStart: CGFloat = earbudActive ? 0.0 : Self.trustEnvelopeStartSoftware
        return VStack(alignment: .leading, spacing: 0) {
            // header
            HStack {
                Circle()
                    .fill(extras.success)
                    .frame(width: 5, height: 5)
                Text("SESSION SECURITY · CUSTODY OF YOUR VOICE")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(scheme.onSurfaceVariant)
                Spacer(minLength: 0)
                Text(earbudActive ? "HARDWARE-SEALED · SOVEREIGN" : "SOFTWARE-SEALED")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(envColor)
            }
            .padding(.horizontal, 14)
            Spacer().frame(height: 16)

            // Mic ↔ seal ↔ peer chain, with the two particle-flow lanes and
            // the morphing protection-boundary box layered behind it.
            trustChainDiagram(envColor: envColor, cipher: cipher, envelopeStart: envelopeStart)
                .padding(.horizontal, 6)
                .frame(height: 118)
            Spacer().frame(height: 14)

            trustVerdictCallout(gold: gold)
                .padding(.horizontal, 14)
            Spacer().frame(height: 10)

            trustStatRing(gold: gold)
                .padding(.horizontal, 6)

            // live earbud stat when connected — CRACEN secure-element
            // confirmation only (no battery/ANC: iOS has no BudsStatus
            // source, and fabricating one would break the honest-data rule).
            if earbudActive {
                Divider().background(gold.opacity(0.25))
                    .padding(.horizontal, 14)
                trustEarbudPanel(gold: gold)
                    .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(scheme.surfaceVariant.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(earbudActive ? gold.opacity(0.5) : scheme.outline.opacity(0.5),
                        lineWidth: earbudActive ? 1.3 : 1)
        )
        .animation(.linear(duration: 0.6), value: earbudActive)
    }

    // MARK: Trust-chain diagram (particle lanes + seal core + boundary box)

    /// Mic → seal → peer row, with the two ambient particle canvases and the
    /// morphing protection-boundary box behind it in one `ZStack` so the
    /// boundary can span from an arbitrary fraction of the width (0.0 or
    /// 0.42) to the trailing edge exactly like the mockup's `.boundary`.
    private func trustChainDiagram(envColor: Color, cipher: Color, envelopeStart: CGFloat) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let laneY = h * 0.42
            let boundaryX = envelopeStart * w
            let boundaryWidth = max(w - boundaryX, 0)

            ZStack(alignment: .topLeading) {
                // Protection boundary — bordered glowing box, grows left to
                // swallow the mic node in earbud mode. Position/width/color
                // all animate on the shared 0.6s tween (see trustChainCard).
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [envColor.opacity(0.10), .clear],
                            center: .center, startRadius: 0, endRadius: w * 0.5
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(envColor.opacity(0.5), lineWidth: 1.3)
                    )
                    .frame(width: boundaryWidth, height: h - 20)
                    .overlay(alignment: .top) {
                        // Floating label pill on the boundary box's own top
                        // edge — `.overlay(alignment:)` centers it relative
                        // to the (not-yet-offset) rectangle's own bounds, so
                        // it rides along correctly once the whole composite
                        // is shifted by the trailing `.offset` below.
                        Text(earbudActive ? "protection reaches the mic" : "protected from here →")
                            .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(envColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule().fill(scheme.surfaceVariant)
                            )
                            .fixedSize()
                            .offset(y: -6)
                    }
                    .offset(x: boundaryX, y: 14)

                // Particle lanes — cheap ambient motion either side of the
                // seal, sharing ONE TimelineView tick (paused under Reduce
                // Motion, same convention as drawCipherTube/drawMiniSpectrum).
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    Canvas { ctx, _ in
                        drawVoiceParticleLane(ctx: &ctx, rect: CGRect(x: 0, y: laneY - 12, width: w * 0.40, height: 24),
                                              t: t, cipher: false, tint: envColor)
                        drawVoiceParticleLane(ctx: &ctx, rect: CGRect(x: w * 0.60, y: laneY - 12, width: w * 0.40, height: 24),
                                              t: t, cipher: true, tint: cipher)
                    }
                }
                .frame(width: w, height: h)
                .allowsHitTesting(false)

                // Mic → Seal → Peer row.
                HStack(spacing: 0) {
                    trustEndpointNode(
                        icon: "mic.fill",
                        title: "Microphone",
                        sub: earbudActive ? "protected" : "exposed",
                        accent: earbudActive ? envColor : extras.riskHigh
                    )
                    .frame(width: w * 0.30)

                    sealCore(envColor: envColor)
                        .frame(width: w * 0.40)

                    trustEndpointNode(
                        icon: "person.wave.2.fill",
                        title: peerDisplayName,
                        sub: "ciphertext · over the net",
                        accent: scheme.onSurfaceVariant
                    )
                    .frame(width: w * 0.30)
                }
                .frame(width: w, height: h)
            }
        }
    }

    /// One endpoint (mic or peer) — icon disc + title + monospace sub-caption.
    private func trustEndpointNode(icon: String, title: String, sub: String, accent: Color) -> some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(colors: [scheme.surfaceVariant, scheme.background],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(accent.opacity(0.55), lineWidth: 1)
                    )
                    .frame(width: 42, height: 42)
                    .shadow(color: accent.opacity(0.35), radius: 6)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(accent)
            }
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(scheme.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(sub)
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    /// The glowing seal core — radial-gradient box, colored border, a soft
    /// pulsing ring (opacity+scale breathing loop) around it, tagged with
    /// where the seal is currently happening. The pulse reuses the SAME
    /// TimelineView tick the particle lanes already subscribe to (no extra
    /// timer): a `sin` breathing curve derived from the shared time base.
    private func sealCore(envColor: Color) -> some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let breath = (sin(t * 1.35) + 1) / 2   // 0...1
            VStack(spacing: 7) {
                ZStack {
                    // pulsing ring
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(envColor, lineWidth: 1)
                        .frame(width: 64, height: 64)
                        .scaleEffect(1 + breath * 0.22)
                        .opacity(reduceMotion ? 0.35 : (1 - breath) * 0.5)
                    // core box
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [envColor.opacity(0.30), scheme.background.opacity(0.95)],
                                center: UnitPoint(x: 0.5, y: 0.34), startRadius: 0, endRadius: 46
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(envColor.opacity(0.6), lineWidth: 1)
                        )
                        .frame(width: 64, height: 64)
                        .shadow(color: envColor.opacity(0.45), radius: 10)
                    Image(systemName: earbudActive ? "waveform.badge.mic" : "lock.rectangle.stack.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(envColor)
                }
                Text(earbudActive ? "Sealed inside the earbud" : "Sealed on the phone")
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .foregroundStyle(envColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(envColor.opacity(0.14)))
                    .overlay(Capsule().stroke(envColor.opacity(0.4), lineWidth: 1))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Deterministic ambient particle lane — sparse warm dots drifting with
    /// a slow vertical sine bob (raw, unsealed voice) on the LEFT, denser
    /// cooler/more-randomised dots (already ciphertext) on the RIGHT.
    /// Same golden-ratio index-hashing technique as `drawCipherTube` (zero
    /// allocation, stable across frames, cheap — a few dozen points).
    private func drawVoiceParticleLane(ctx: inout GraphicsContext, rect: CGRect, t: Double, cipher: Bool, tint: Color) {
        guard rect.width > 0 else { return }
        let n = cipher ? 22 : 12
        for i in 0..<n {
            let ph = Self.fract(Double(i) * 0.61803399 + (cipher ? 0.5 : 0))
            let spd = cipher
                ? 0.09 + 0.10 * Self.fract(Double(i) * 0.75487767)
                : 0.045 + 0.05 * Self.fract(Double(i) * 0.75487767)
            let lane = Self.fract(Double(i) * 0.38196601)
            let x = rect.minX + CGFloat(Self.fract(ph + t * spd)) * rect.width
            let y: CGFloat
            let alpha: Double
            let radius: CGFloat
            if cipher {
                // denser, more randomised jitter — ciphertext already.
                let jitter = Self.fract(Double(i) * 0.91113 + t * 0.7)
                y = rect.minY + CGFloat(lane) * rect.height + CGFloat(jitter - 0.5) * rect.height * 0.6
                alpha = 0.35 + 0.45 * Self.fract(Double(i) * 0.27 + t * 0.3)
                radius = 1.1
            } else {
                // sparse, smooth vertical sine bob — raw voice.
                let wob = sin(t * 1.6 + Double(i) * 1.9)
                y = rect.minY + rect.height / 2 + CGFloat(wob) * rect.height * 0.32
                alpha = 0.55 + 0.35 * sin(t * 2 + Double(i))
                radius = 1.3
            }
            var dotCtx = ctx
            dotCtx.opacity = max(0, min(1, alpha))
            dotCtx.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .color(tint)
            )
        }
    }

    // MARK: Verdict callout

    /// Verdict callout box — bordered/tinted box with a leading icon,
    /// matching the mockup's `.verdict .v` treatment (the previous
    /// implementation had the same copy as a bare paragraph with no box).
    private func trustVerdictCallout(gold: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: earbudActive ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(earbudActive ? gold : extras.riskHigh)
                .padding(.top, 1)
            Text(earbudActive
                 ? "The mic and the seal both live inside the earbud's secure chip — your voice is sealed at the source and never reaches the phone."
                 : "Keys stay safe in the OS keystore, but the raw mic audio exists in the phone for an instant before the seal — an OS compromise could tap it upstream of encryption.")
                .font(.system(size: 11))
                .foregroundStyle(scheme.onSurface.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((earbudActive ? gold : extras.riskHigh).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke((earbudActive ? gold : extras.riskHigh).opacity(0.28), lineWidth: 1)
        )
    }

    // MARK: Stat ring row

    /// Row of 5 stat cells (icon + label + value), wired to REAL state
    /// already threaded to this view for the trust bar above — no new
    /// state invented. Only "Seal point" changes with `earbudActive`; the
    /// rest are informational badges of already-real values:
    ///  - Identity      → `sasVerified` (same flag the trust bar's "SAS ✓" chip uses)
    ///  - Post-quantum  → `pqcActive` (same flag the trust bar's "PQC" chip uses)
    ///  - Cipher        → static "AES-256" label (the one algorithm string this
    ///                     screen already commits to elsewhere — see
    ///                     `cipherKeySectionBody`'s doc comment on why no
    ///                     second, possibly-wrong cipher string is fabricated)
    ///  - Seal point    → `earbudActive` (Phone vs Earbud HW, cyan vs gold)
    ///  - Liveness      → static "Guardian" badge, same unconditional
    ///                     "LIVENESS OK" the pills row already shows today
    private func trustStatRing(gold: Color) -> some View {
        HStack(spacing: 0) {
            trustStatCell(icon: "checkmark.seal.fill", label: "Identity",
                          value: sasVerified ? "SAS ✓" : "unverified",
                          active: sasVerified, accent: extras.success)
            trustStatCell(icon: "shield.lefthalf.filled", label: "Post-quantum",
                          value: pqcActive ? "ML-KEM" : "off",
                          active: pqcActive, accent: extras.success)
            trustStatCell(icon: "lock.rectangle.stack.fill", label: "Cipher",
                          value: "AES-256", active: true, accent: extras.success)
            trustStatCell(icon: earbudActive ? "waveform.badge.mic" : "iphone",
                          label: "Seal point",
                          value: earbudActive ? "Earbud HW" : "Phone",
                          active: true, accent: earbudActive ? gold : extras.success)
            trustStatCell(icon: "shield.checkerboard", label: "Liveness",
                          value: "Guardian", active: true, accent: extras.success)
        }
    }

    private func trustStatCell(icon: String, label: String, value: String, active: Bool, accent: Color) -> some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(active ? accent.opacity(0.14) : scheme.surfaceVariant)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(active ? accent.opacity(0.4) : scheme.outline.opacity(0.4), lineWidth: 1)
                    )
                    .frame(width: 30, height: 30)
                    .shadow(color: active ? accent.opacity(0.3) : .clear, radius: 5)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(active ? accent : scheme.onSurfaceVariant)
            }
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(scheme.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(value)
                .font(.system(size: 7, design: .monospaced))
                .textCase(.uppercase)
                .foregroundStyle(active ? accent : scheme.onSurfaceVariant)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: Earbud detail panel

    /// Collapsible earbud detail panel — shown ONLY when `earbudActive`.
    /// iOS has NO real battery/ANC/seals-per-second/key-epoch data source
    /// (no `BudsStatus`-shaped provider exists here the way Android's does,
    /// and no live seal-rate or key-epoch counter exists elsewhere in this
    /// codebase either — `keyEpoch` is a call-level nil-by-default counter
    /// with no earbud-specific meaning; see its doc comment above). Rather
    /// than fabricate those cells, this panel keeps the SAME honest single
    /// row the previous implementation had: CRACEN secure-element
    /// confirmation, driven by the real `earbudHwVerified` flag.
    private func trustEarbudPanel(gold: Color) -> some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(gold.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(gold.opacity(0.35), lineWidth: 1)
                    )
                    .frame(width: 26, height: 26)
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(gold)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("SECURE ELEMENT")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(scheme.onSurfaceVariant)
                Text(earbudHwVerified ? "CRACEN ✓" : "linking…")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(earbudHwVerified ? gold : scheme.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
    }

    // MARK: - Crypto-engine meter (unified call UI)

    /// Cipher flow tube — parity with Android `CipherFlowTube`
    /// (feature-call/ui/GuardianRibbon.kt): the "myriad of chaotic dots"
    /// representation of the live encryption stream. A fixed-width rounded
    /// tube through which a swarm of dots flows left→right; every visual
    /// parameter is bound to REAL crypto-engine telemetry (no canned
    /// animation):
    ///
    ///  - dot COUNT   ∝ real AES-256-GCM frame ops/s (`cryptoOpsPerSec`):
    ///                  the swarm literally is ~1.4 s worth of sealed/opened
    ///                  frames in flight (clamped 24…220 for GPU sanity), so
    ///                  a busier engine shows a visibly denser stream;
    ///  - dot chaos     deterministic per-dot pseudo-random phase/speed/
    ///                  lane/wobble/radius via golden-ratio index hashing —
    ///                  zero allocation, stable across frames, chaotic to
    ///                  the eye: ciphertext-like;
    ///  - colour        cyan (pqcAccent, plaintext side) → success-green
    ///                  (sealed side) by x/w, with a mid-tube alpha bloom.
    ///
    /// Readout is "N/s" only. Android also prints "X kB/s", but iOS has no
    /// byte counter (only frame counts), so — per the honest-data rule — no
    /// byte rate is shown rather than fabricating one from an assumed frame
    /// size. The TimelineView is PAUSED under Reduce Motion or while the
    /// engine is idle (ops == 0): only the static tube walls render then.
    private var cryptoEngineMeterRow: some View {
        HStack(spacing: 8) {
            Text("ENGINE")
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundStyle(scheme.onSurfaceVariant)
            TimelineView(.animation(paused: reduceMotion || cryptoOpsPerSec == 0)) { timeline in
                Canvas { ctx, size in
                    // t == 0 ⇒ paused/idle ⇒ walls only (static tube).
                    let animate = !reduceMotion && cryptoOpsPerSec > 0
                    let t = animate ? timeline.date.timeIntervalSinceReferenceDate : 0
                    drawCipherTube(ctx: &ctx, size: size, t: t)
                }
                .frame(height: 14)
            }
            Text(Self.cryptoReadout(cryptoOpsPerSec))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(extras.pqcAccent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// Pure Canvas draw for the cipher tube — extracted so the TimelineView
    /// body stays shallow (SWIFT6_PATTERNS §5/§6). Ports Android
    /// `CipherFlowTube`'s draw block 1:1: golden-ratio index hashing for
    /// per-dot phase/speed/lane/radius, sin wobble, x from
    /// `fract(ph + t·spd)`, colour lerp cyan→green by x/w (realised as ONE
    /// horizontal gradient shading each dot samples at its x — same visual
    /// result as Android's per-dot RGB lerp without needing Color
    /// components), alpha `0.20 + 0.62·sin(π·x/w)`. `t == 0` ⇒ walls only.
    /// All per-dot math stays in Double: the reference-date time base
    /// (~8×10⁸ s) would lose sub-second precision in Float32.
    private func drawCipherTube(ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let w = size.width
        let h = size.height
        // Tube walls — always drawn, also when idle/paused.
        ctx.fill(
            Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                 cornerRadius: h / 2.0),
            with: .color(scheme.onSurfaceVariant.opacity(0.14))
        )
        guard t > 0 else { return }

        // Dot budget = ~1.4 s of real frame ops in flight (clamped for GPU sanity).
        let n = min(220, max(24, Int(Double(cryptoOpsPerSec) * 1.4)))
        // One cyan→green gradient across the tube — every dot filled with it
        // picks up exactly the lerp(cyan, green, x/w) colour at its position.
        let flowShading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [extras.pqcAccent, extras.success]),
            startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: w, y: 0)
        )
        for i in 0..<n {
            // Deterministic per-dot chaos via golden-ratio index hashing.
            let ph = Self.fract(Double(i) * 0.61803399)               // spawn phase along the tube
            let spd = 0.22 + 0.30 * Self.fract(Double(i) * 0.75487767) // per-dot speed (tube lengths/s)
            let fy = Self.fract(Double(i) * 0.38196601)               // lane inside the tube
            let x = CGFloat(Self.fract(ph + t * spd)) * w
            // chaotic vertical wobble, frequency varies per dot
            let wob = sin(t * (1.7 + fy * 3.1) + Double(i) * 1.618)
            let y = h / 2.0 + (CGFloat(fy) - 0.5) * (h * 0.58) + CGFloat(wob) * h * 0.14
            let frac = Double(x / w)
            // fade in at entry, out at exit; brighter mid-tube
            let alpha = 0.20 + 0.62 * sin(Double.pi * frac)
            let radius = CGFloat(0.8 + 1.2 * Self.fract(Double(i) * 0.91113))
            var dotCtx = ctx
            dotCtx.opacity = alpha
            dotCtx.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                       width: radius * 2, height: radius * 2)),
                with: flowShading
            )
        }
    }

    /// Fractional part — mirrors Android GuardianRibbon's `fract(v)`.
    private static func fract(_ v: Double) -> Double { v - v.rounded(.down) }

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
    /// W-GAUGEUNITS (2026-07-31 InCallScreen Android→iOS parity, item 3) —
    /// the compact `guardianGauge`'s bare `Int(...)` used to render with NO
    /// unit suffix (unlike this same value's use in
    /// `voiceBiometricsSectionBody`, which already appended "/100" at its
    /// own call site). Now the unit lives HERE, once, so the compact gauge
    /// and the security-sheet detail row can never disagree — the sheet's
    /// call site below no longer appends its own "/100".
    private var stressDisplayValue: String {
        guard let bio = voiceBiometrics else { return "—" }
        return "\(Int((bio.stressScore * 100).rounded()))/100"
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
    /// W-GAUGEUNITS (item 3) — same fix as `stressDisplayValue` above: the
    /// unit now lives in the shared helper instead of only at the
    /// security-sheet call site, so the compact gauge stops rendering a
    /// bare number.
    private var hnrDisplayValue: String {
        guard let bio = voiceBiometrics else { return "—" }
        return "\(Int(bio.hnr.rounded())) dB"
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

    /// W-GAUGEUNITS (item 3) — same fix as `stressDisplayValue`/
    /// `hnrDisplayValue` above.
    private var pitchDisplayValue: String {
        guard let bio = voiceBiometrics else { return "—" }
        return "\(Int(bio.pitchHz.rounded())) Hz"
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
        // RE-KEY removed here — already shown in the stats band's RE-KEY
        // progress column above (Android parity keeps its pill because its
        // band has no countdown text; ours does).
        HStack(spacing: 8) {
            MetaPill("LIVENESS OK",   accent: extras.success, filled: true)
            MetaPill("PSK ROTATION",  accent: extras.success)
            Spacer(minLength: 8)
            voiceLearningControl
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Feature B ("voce verificata") — call-time voice learning

    /// W-AUTOLEARN parity (item 5, 2026-07-31 InCallScreen Android→iOS
    /// port) — no more manual "Avvia apprendimento voce" tap. Enrollment is
    /// started silently by `AppState.maybeAutoStartVoiceLearning` the first
    /// time this call ever connects to a NEW contact (fed from the SAME
    /// decoded RX audio the Guardian ribbon above already uses — never
    /// local mic), so this slot only ever SHOWS state, never asks for one:
    ///  - `.inProgress` → the brief (~3s) auto-enrollment is running; a
    ///    determinate progress bar, no button.
    ///  - every other state (`.none`/`.idle`/`.completed`/`.failed`, or a
    ///    call where this contact already had a template so no session
    ///    ever ran) → the live `voiceConfidenceWave` for THIS call — the
    ///    permanent "is this still really them" signal, driven by real
    ///    per-frame Guardian data the whole time, not just during the rare
    ///    first-contact enrollment window.
    @ViewBuilder
    private var voiceLearningControl: some View {
        if case .inProgress(let progress) = voiceLearningState {
            HStack(spacing: 6) {
                ProgressView(value: Double(progress))
                    .frame(width: 44)
                    .tint(extras.pqcAccent)
                Text("APPRENDIMENTO VOCE…")
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.0)
                    .foregroundStyle(extras.pqcAccent)
            }
        } else {
            voiceConfidenceWave
        }
    }

    /// Item 5 (2026-07-31 InCallScreen Android→iOS port) — live moving wave
    /// of `voiceConfidenceHistory`, the RAW per-frame Guardian confidence
    /// score (never the smoothed number, which barely moves — see that
    /// property's doc). W-VOICEWAVE parity (Android 2026-07-31): plotting
    /// the value against its own absolute 0...1 scale reads as a dead flat
    /// line — a healthy call's raw score sits in a tight band. Instead this
    /// auto-scales to the CURRENT window's own deviation from its mean (a
    /// floor keeps a silent/rock-steady window from blowing tiny noise up
    /// into fake-looking movement) and draws it as a filled wave around a
    /// center baseline — same "real data, not decoration" discipline as
    /// `miniSpectrum`/`drawCipherTube` elsewhere on this screen: it only
    /// ever moves because a genuinely new sample arrived.
    private var voiceConfidenceWave: some View {
        Canvas { ctx, size in
            drawVoiceConfidenceWave(ctx: &ctx, size: size)
        }
        .frame(width: 90, height: 20)
        .accessibilityLabel("Curva di verifica vocale in tempo reale")
    }

    /// Floor on the auto-scale window spread — keeps a rock-steady call's
    /// real micro-noise from being amplified into misleadingly large
    /// swings. Matches Android's `CONFIDENCE_WAVE_MIN_SPREAD`.
    private static let voiceConfidenceWaveMinSpread: Float = 0.02

    /// Pure Canvas draw for `voiceConfidenceWave`, extracted per this
    /// file's own convention (`drawMiniSpectrum`/`drawCipherTube`).
    /// Mirrors Android's `ConfidenceCurve` algorithm exactly: center
    /// baseline, per-sample deviation from the window's mean divided by its
    /// (floored) spread, clipped to ±1, scaled to 85% of half-height.
    private func drawVoiceConfidenceWave(ctx: inout GraphicsContext, size: CGSize) {
        let history = voiceConfidenceHistory
        let midY = size.height / 2
        let color = extras.pqcAccent
        guard history.count >= 2 else {
            var flat = Path()
            flat.move(to: CGPoint(x: 0, y: midY))
            flat.addLine(to: CGPoint(x: size.width, y: midY))
            ctx.stroke(flat, with: .color(color.opacity(0.35)), lineWidth: 1.5)
            return
        }
        let mean = history.reduce(0, +) / Float(history.count)
        let spread = max(history.map { abs($0 - mean) }.max() ?? 0, Self.voiceConfidenceWaveMinSpread)
        let stepX = size.width / CGFloat(history.count - 1)
        var line = Path()
        var fill = Path()
        for (i, v) in history.enumerated() {
            let dev = max(-1, min(1, (v - mean) / spread))
            let x = CGFloat(i) * stepX
            let y = midY - CGFloat(dev) * midY * 0.85
            if i == 0 {
                line.move(to: CGPoint(x: x, y: y))
                fill.move(to: CGPoint(x: x, y: midY))
                fill.addLine(to: CGPoint(x: x, y: y))
            } else {
                line.addLine(to: CGPoint(x: x, y: y))
                fill.addLine(to: CGPoint(x: x, y: y))
            }
        }
        fill.addLine(to: CGPoint(x: size.width, y: midY))
        fill.closeSubpath()
        ctx.fill(fill, with: .color(color.opacity(0.16)))
        ctx.stroke(line, with: .color(color), lineWidth: 2)
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
                    // W-ASSURANCE (ship step 6) — the LIVE per-call verdict,
                    // rendered FIRST (most important live signal) and as its
                    // OWN section — never merged into the "Handshake ·
                    // post-quantum" section below, which shows the static
                    // handshake parameters (keyInfo), not a trust verdict.
                    if let assurancePresentation {
                        securitySection(title: "Verifica di questa chiamata") {
                            assuranceSectionBody(assurancePresentation)
                        }
                    }

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
                    // W-GAUGEUNITS (item 3) — stressDisplayValue now already
                    // includes "/100" (see its doc), no longer appended here.
                    value: "\(stressDisplayValue) · \(stressStatusWord)",
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
                    // W-GAUGEUNITS (item 3) — hnrDisplayValue now already
                    // includes "dB" (see its doc), no longer appended here.
                    value: "\(hnrDisplayValue) · \(String(format: "%.2f", bio.breathiness))",
                    valueColor: hnrStatusColor,
                    meaning: ">20 dB chiara · <10 dB rauca o link rumoroso (VoiceHealthMonitor: breathiness = 1 − hnr/20)."
                )
                biometricRow(
                    label: "Pitch f0 · rate",
                    // W-GAUGEUNITS (item 3) — pitchDisplayValue now already
                    // includes "Hz" (see its doc), no longer appended here.
                    value: "\(pitchDisplayValue) · \(String(format: "%.1f", bio.syllablesPerSec)) syl/s",
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

#Preview("Earbud sovereign (TrustChainCard A+)") {
    // Design preview of the TrustChainCard earbud branch (gold accent,
    // envelope reaching the mic, CRACEN stat). No live iOS call site can
    // produce this state yet — the earbud media provider lands later.
    InCallScreen(
        peerDisplayName: "Mario Rossi",
        durationSeconds: 340,
        confidence: 0.95,
        rekeyInSeconds: 120,
        rekeyTotalSeconds: 300,
        pqcActive: true,
        transportMode: .p2pSrtp,
        earbudActive: true,
        earbudHwVerified: true,
        cryptoOpsPerSec: 102,
        onHangup: {}
    )
    .qAudionTheme(dark: true)
}
