import SwiftUI
import CryptoKit
import QAudionEngine

/// Bridge between the live `AppState` + `CallService` and the new
/// `InCallScreen` design-system view.
///
/// W29 production wiring step. Allows the new InCallScreen to render
/// real call data (peer name, duration, confidence, mute state,
/// recent samples) WITHOUT touching the legacy CallView / InCallView /
/// InCallContainer plumbing — those still own the CallKit + AVAudioSession
/// + video-track mechanics.
///
/// Available live fields (mapped from AppState):
///   - `peerDisplayName`     ← `appState.callContactId` (best-effort lookup
///                              from ContactsStore; falls back to userId)
///   - `durationSeconds`     ← `appState.callService.callDurationSeconds`
///                              (refreshed once per second via TimelineView)
///   - `confidence`          ← `appState.confidenceScore` (@Published, live
///                              feed from deepfake detector)
///   - `muted`               ← `appState.callMuted` (@Published mirror of
///                              CallService.isMuted; no local copy — W-MUTEBTNSRC)
///   - `transportMode`       ← maps live `backendType` ("p2p"/"turn"/"relay")
///                              to the corresponding TransportMode case
///                              (see `liveTransportMode`) — FIXED: this used
///                              to compare `backendType == "PQC"`, a literal
///                              backendType never holds, so the chip always
///                              fell through to `.disconnected`.
///   - `keyInfo`             ← built from `appState.callPqcSessionKey` +
///                              `appState.pskActive`/`pskName`/`pskFingerprint`
///                              when ML-KEM session key is available (W502)
///   - `voiceBiometrics`     ← built from `appState.voiceAnalysis` (Guardian
///                              ribbon + security-sheet biometrics; unified
///                              call UI pass — see `liveVoiceBiometrics`)
///
/// Stub fields (kept until engine exposes them — see W29 spec from
/// the parallel agent):
///   - `rekeyInSeconds` / `rekeyTotalSeconds` — fixed 252/300
///   - `voiceEnhancement` — local @State only
///   - `speakerOn` — local @State only (real AVAudioSession routing
///                   stays inside legacy InCallView for now)
@MainActor
struct LiveInCallScreen: View {
    @EnvironmentObject var appState: AppState
    // ContactsStore is a plain final class (not ObservableObject) — used
    // as a one-shot lookup helper, not as reactive state.
    private let contactsStore = ContactsStore()

    @State private var speakerOn: Bool = false
    @State private var voiceEnhancement: Bool = false
    /// Camera on/off state for video calls. Starts ON when the call
    /// is a video call; user can mute/unmute the camera mid-call.
    /// W-CAMBTNSRC (2026-07-24) — read LIVE from the ONE authoritative signal,
    /// never a local copy. This used to be an `@State` seeded once from
    /// `appState.isVideoCall`, which is "does this call have video AT ALL": while
    /// only the PEER was sending, the local camera button rendered as ON in what
    /// was, for this user, a voice call (confirmed on call fec3decc). Being a
    /// seeded copy it also drifted from truth for the rest of the call, since
    /// this surface is remounted mid-call and only local taps updated it.
    private var cameraOn: Bool { appState.localCameraSending }

    /// W502: whether the network diagnostics overlay is visible.
    @State private var showDiagnostics: Bool = false

    /// Cached peer display name. Resolved once on appear / on
    /// callContactId change so the contacts-store lookup doesn't run
    /// on every TimelineView tick (OpenRouter review on v1.0.75 flagged
    /// the disk I/O on the main thread). Fallback to "Sconosciuto"
    /// when no peer is bound (e.g. between calls).
    @State private var cachedPeerDisplayName: String = "Sconosciuto"
    /// Numero interno PBX del peer risolto dalla stessa lookup di
    /// ContactsStore. nil quando il contatto è sconosciuto o non ha
    /// ancora un'estensione registrata — l'avatar ricade su initials().
    @State private var cachedPeerShortNumber: String? = nil
    /// E2EE avatar transport (2026-07-30) — local `file://` path to the
    /// peer's decrypted avatar, if `AvatarAnnounceReceiver` has cached
    /// one. Resolved alongside `cachedPeerDisplayName`/
    /// `cachedPeerShortNumber` in `resolvePeerDisplayName()` for the
    /// same reason (avoid a ContactsStore disk read on every
    /// TimelineView tick).
    @State private var cachedPeerAvatarUrl: URL? = nil

    /// Reference timestamp (UNIX epoch seconds) used to derive a
    /// counting-down rekey clock until the engine surfaces a real
    /// rekey timer. We anchor it on `.onAppear` and decrement it as
    /// the TimelineView ticks; resets every `rekeyTotalSeconds`.
    private static let rekeyTotalSeconds = 300
    @State private var rekeyAnchorEpoch: TimeInterval = Date().timeIntervalSince1970

    var body: some View {
        // TimelineView refreshes the body once per second so the
        // duration label + sparkline tick without forcing CallService
        // to push @Published updates.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            inCallScreenView
        }
        // W502: network diagnostics overlay — slides up from the bottom
        // when the analytics button in the transport row is tapped.
        .overlay(alignment: .bottom) {
            if showDiagnostics {
                diagPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 160)    // clear the pinned action row
                    .padding(.horizontal, 16)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showDiagnostics)
        // W324: stub disclaimer next to the rekey countdown, shown only
        // while the engine rekey ETA is not yet surfaced (i.e. keyInfo==nil).
        .overlay(alignment: .topTrailing) {
            if liveKeyInfo == nil {
                stubRekeyDisclaimer
                    .padding(.top, 56)
                    .padding(.trailing, 12)
            }
        }
        .onAppear {
            // SECURITY F-3: the in-call screen renders the SAS words +
            // peer identity. Mirror ChatDetailScreen's secure-window
            // lifecycle so screenshots / screen recording / AirPlay
            // mirroring of that material are blocked while it is up.
            ScreenshotLockService.lock()
            resolvePeerDisplayName()
            rekeyAnchorEpoch = Date().timeIntervalSince1970
            // W-AUDIOUILIE (2026-07-24) — this surface is REMOUNTED mid-call
            // every time the pair transitions to/from both-paused, and both
            // toggles used to reopen at a hardcoded `false`. So a call muted
            // before a video round trip came back showing an un-muted mic, and
            // the next tap muted an already-muted call. Speaker still seeds from
            // live truth here; mute no longer needs to (W-MUTEBTNSRC — it reads
            // the published `callMuted` mirror directly).
            // (The camera has no seed any more — it is derived live from
            // appState.localCameraSending, W-CAMBTNSRC.)
            speakerOn = appState.callSpeakerOn
        }
        .onDisappear {
            // SECURITY F-3: release the secure window when the call
            // surface unmounts (same unconditional unlock pattern as
            // ChatDetailScreen.handleScreenDisappear).
            ScreenshotLockService.unlock()
        }
        .onChange(of: appState.callContactId) { _ in
            // Re-resolve when the call peer changes (e.g. switching
            // between successive calls on the same showcase entry).
            resolvePeerDisplayName()
        }
        // 2026-07-29 fix — pick up NameResolutionService's async enrichment
        // (device-contact match, or the `ensureResolved` profile fetch
        // kicked off by `resolvePeerDisplayName` above) once it lands the
        // real phone number/name into the rubrica after the fact; without
        // this the screen only shows it on the NEXT unrelated redraw.
        .onReceive(NotificationCenter.default.publisher(for: .contactsDidChange)) { _ in
            resolvePeerDisplayName()
        }
        // media-consent v1 — the peer asked to turn their camera on.
        // NOTHING (no camera, no answer) happens until the user decides
        // here; AppState auto-declines after 25s.
        .alert(
            "Videochiamata richiesta",
            isPresented: incomingUpgradeAlertBinding
        ) {
            Button("Attiva video") {
                appState.acceptIncomingUpgrade()
            }
            Button("Rifiuta", role: .cancel) {
                appState.declineIncomingUpgrade()
            }
        } message: {
            Text("\(cachedPeerDisplayName) vuole attivare il video. Se accetti, si attiva anche la tua fotocamera.")
        }
    }

    /// Bridge AppState.pendingIncomingUpgrade ↔ the SwiftUI alert. Setting
    /// false (swipe/dismiss) declines so the peer isn't left waiting.
    private var incomingUpgradeAlertBinding: Binding<Bool> {
        Binding(
            get: { appState.pendingIncomingUpgrade != nil },
            set: { shown in if !shown { appState.declineIncomingUpgrade() } }
        )
    }

    // MARK: - Sub-views (extracted to keep TimelineView body shallow,
    //                   per SWIFT6_PATTERNS §5/§6).

    /// W324: composing all the InCallScreen args inline used to be a
    /// 22-arg call inside a TimelineView closure — wrapping it in a
    /// computed property keeps the type-checker scope clean.
    @ViewBuilder
    private var inCallScreenView: some View {
        InCallScreen(
                peerDisplayName: cachedPeerDisplayName,
                avatarUrl: cachedPeerAvatarUrl,
                durationSeconds: Int(appState.callService.callDurationSeconds),
                confidence: Double(appState.confidenceScore),
                rekeyInSeconds: liveRekeyInSeconds,
                rekeyTotalSeconds: Self.rekeyTotalSeconds,
                // W-TRUSTBAR-FIX: backendType is one of "p2p"/"turn"/"relay"
                // (see AppState.swift ~line 267) — it is NEVER the literal
                // "PQC". The PQC handshake is a SEPARATE layer from the
                // media transport; "PQC active" should reflect whether the
                // ML-KEM session key has actually been established, i.e.
                // the same live source the trust-bar/key-info panel already
                // uses (liveKeyInfo != nil), not the transport string.
                pqcActive: liveKeyInfo != nil,
                // W339: real SAS from ComputeSasUseCase — derived from
                // appState.callPqcSessionKey when set by the call setup
                // path. While the key is nil (current state in most
                // builds) the array is empty and the panel hides.
                sasWords: appState.callSasWords,
                // W368: surface SAS verification persistence — if the
                // user already confirmed coincidence with this peer
                // for the current SAS-words fingerprint, render the
                // panel as VERIFIED and disable the confirm button.
                sasVerified: liveSasVerified,
                // W502: KeyInfo built from live session key when available.
                keyInfo: liveKeyInfo,
                transportMode: liveTransportMode,
                muted: liveMuted,
                speakerOn: speakerOn,
                voiceEnhancement: voiceEnhancement,
                hasVideo: appState.isVideoCall,
                cameraOn: cameraOn,
                peerShortNumber: cachedPeerShortNumber,
                // TrustChainCard phone-vs-earbud model: iOS has NO earbud
                // media-provider path yet (EarbudCounterpartyService only
                // handles the PQC handshake toward a PEER's earbud, never a
                // local earbud media route), so both flags are a constant
                // false — the software branch renders. When the earbud
                // provider lands, wire its "active + CRACEN verified" state
                // here (Android: SecureMediaProviderSelector).
                earbudActive: false,
                earbudHwVerified: false,
                // Unified call UI — Guardian ribbon + security-sheet
                // biometrics. nil while appState.voiceAnalysis is nil
                // (engine flag off, or no result has arrived yet) —
                // InCallScreen renders the graceful "not available"
                // state in that case. Wired on both call directions.
                voiceBiometrics: liveVoiceBiometrics,
                // Unified call UI — REAL RX spectrum (40 bands 0..1,
                // ≤15 Hz, SpectrumExtractor over the decoded remote
                // PCM). nil before the first decoded frame → the
                // MiniSpectrum bars decay to rest, never fabricated.
                voiceSpectrum: appState.voiceSpectrum,
                // No live rekey-count/epoch source exists yet (see
                // AppState.rekeyCount doc comment — it is declared but
                // never incremented by any current rotation hook), so we
                // pass nil rather than a fabricated epoch. If a future
                // pass wires a real rekey event, swap this for
                // `appState.rekeyCount`.
                keyEpoch: nil,
                // Unified call UI — live crypto-engine rate (real AES-256-GCM
                // frame ops/s). Sampled once/sec by AppState.startCryptoMeter()
                // from the CallService frame counters; 0 hides the pulsing
                // meter. Read inside the per-second TimelineView body so the
                // ribbon re-renders with a fresh value each tick.
                cryptoOpsPerSec: appState.cryptoOpsPerSec,
                onToggleMute: handleToggleMute,
                onToggleSpeaker: handleToggleSpeaker,
                onToggleVoiceEnhancement: handleToggleVoiceEnhancement,
                onToggleCamera: handleToggleCamera,
                onUpgradeToVideo: handleUpgradeToVideo,
                screenSharing: appState.isScreenSharing,
                onToggleScreenShare: handleToggleScreenShare,
                peerScreenSharing: appState.peerScreenShareActive,
                // D11 / W-NOBRICK — non-blocking identity-change advisory banner.
                identityUnauthenticatedChange: appState.callIdentityUnauthenticatedChange,
                // W-ASSURANCE (ship step 6) — mapped to display copy HERE
                // (not in AppState) specifically so `secretLabel` is the
                // already-resolved, UI-safe `cachedPeerDisplayName` — AppState
                // publishes only the raw verdict, never a name, so there is
                // no risk of a raw UUID leaking into this text (standing
                // project rule). nil verdict ⇒ nil presentation ⇒ no section.
                assurancePresentation: appState.callAssuranceState.map {
                    AssuranceStateUI.present(
                        state: $0,
                        expectedNfc: appState.callAssuranceExpectedNfc,
                        secretLabel: cachedPeerDisplayName
                    )
                },
                // W-NFCCOMMON — independent of assurancePresentation above (see
                // AppState.callMutualNfcInCommon's own doc).
                mutualNfcInCommon: appState.callMutualNfcInCommon,
                // W-NFCCOMMON follow-up (Pavel decision) — independent of
                // assurancePresentation too (see AppState.callPskMixedThisCall's doc).
                pskMixedThisCall: appState.callPskMixedThisCall,
                // "Voce come chiave" (item 2, 2026-07-31 InCallScreen
                // Android→iOS port) — the PEER's own device fact, announced
                // over the opaque_message VOICE_KEY piggy-back (see
                // AppState.callPeerVoiceKeyEnrolled's doc).
                peerVoiceKeyEnrolled: appState.callPeerVoiceKeyEnrolled,
                onAddParticipant: {},
                onHangup: handleHangup,
                onConfirmSas: handleConfirmSas,
                // W502: toggle the diagnostics overlay.
                onToggleDiagnostics: handleToggleDiagnostics,
                // Feature B ("voce verificata") — W-AUTOLEARN parity (item 5):
                // fed from AppState.voiceLearningState (itself fed from the
                // SAME decoded RX audio the Guardian ribbon above already
                // uses). nil between calls / before auto-enrollment kicks in
                // (see AppState.maybeAutoStartVoiceLearning) — no more manual
                // trigger to wire a button to.
                voiceLearningState: appState.voiceLearningState,
                onStartVoiceLearning: { appState.startVoiceLearning() },
                // Item 5 — live raw per-frame Guardian confidence wave,
                // replaces the old manual-CTA slot for the rest of the call.
                voiceConfidenceHistory: appState.voiceConfidenceHistory
            )
    }

    // MARK: - Action handlers (extracted per SWIFT6_PATTERNS §13 — named
    //         methods prevent type-checker timeout inside @ViewBuilder).

    private func handleToggleMute() {
        appState.setMuted(!appState.callMuted)
    }

    private func handleToggleSpeaker() {
        speakerOn.toggle()
        appState.setSpeaker(speakerOn)
    }

    private func handleToggleVoiceEnhancement() {
        voiceEnhancement.toggle()
    }

    private func handleToggleCamera() {
        let next = !cameraOn
        // W-CAMSILENT (2026-07-24) — was `appState.setCamera(...)`, which only
        // flips the LOCAL pipeline: it neither updates `localVideoPaused` nor
        // sends `call_video_state`. So turning the camera off on THIS surface
        // left the peer believing we were still transmitting for the rest of the
        // call, and left our own paused-state flag lying to every other reader.
        // `videoSetCameraEnabled` is the complete operation (pipeline + flag +
        // peer notification) and is what the other camera controls already use.
        appState.videoSetCameraEnabled(next)
    }

    private func handleUpgradeToVideo() {
        // `cameraOn` follows `appState.localCameraSending`; upgradeToVideo is
        // what actually turns the camera on, so there is nothing to pre-set.
        appState.upgradeToVideo()
    }

    /// W533: toggle screen-share. Tapping while not sharing requests
    /// the ReplayKit capture; tapping again stops it and restores
    /// the camera. Both branches dispatch into AppState which owns
    /// the WebRTC capturer + ScreenShareController.
    private func handleToggleScreenShare() {
        if appState.isScreenSharing {
            Task { @MainActor in await appState.stopScreenShare() }
        } else {
            Task { @MainActor in await appState.startScreenShare() }
        }
    }

    private func handleHangup() {
        appState.endCall()
    }

    private func handleConfirmSas() {
        let words = appState.callSasWords
        guard !words.isEmpty,
              let peer = appState.callContactId,
              let identityTag = sasIdentityTag(for: peer) else { return }
        let fp = SasVerificationStore.fingerprint(forWords: words)
        SasVerificationStore.shared.recordVerified(
            peerUserId: peer, fingerprint: fp, identityTag: identityTag)
    }

    /// C-3 — the identity binding for the SAS record, from the key currently
    /// pinned for the call's peer. `nil` when there is no pin, in which case
    /// nothing may be recorded or trusted: a confirmation with no identity to bind
    /// to is the state this finding was about.
    private func sasIdentityTag(for peerId: String) -> String? {
        guard let pinned = PeerIdentityPinStore().pinnedKey(contactId: peerId) else { return nil }
        return SasVerificationStore.identityTag(forPinnedKey: pinned)
    }


    private func handleToggleDiagnostics() {
        showDiagnostics.toggle()
    }

    // MARK: - Diagnostics panel (W502)

    /// Network + crypto pipeline diagnostics panel. Slides up from the
    /// bottom on tap of the analytics icon in the transport row.
    /// Mirrors Android InCallScreen's diagnostics panel with available
    /// engine counters. WebRTC RTT/bitrate/jitter will land when the
    /// engine surfaces RTCStatisticsReport via AppState.
    @ViewBuilder
    private var diagPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            diagPanelHeader
            Divider().background(Color.white.opacity(0.2))
            diagPanelTransport
            diagPanelFrameCounters
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.green.opacity(0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var diagPanelHeader: some View {
        HStack {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.green)
            Text("DIAGNOSTICA RETE")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(.green)
            Spacer()
            Button(action: handleToggleDiagnostics) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
        }
    }

    // Helper — pure function so @ViewBuilder never sees a switch that returns ().
    private func diagTransportPath(_ mode: InCallScreen.TransportMode) -> String {
        switch mode {
        case .p2pSrtp:        return "P2P SRTP · UDP"
        case .turn:           return "TURN · relay"
        case .bcryptoWsRelay: return "WSS sealed · bcrypto relay"
        case .disconnected:   return "—"
        }
    }

    @ViewBuilder
    private var diagPanelTransport: some View {
        let path = diagTransportPath(liveTransportMode)
        let label = liveTransportMode.label
        diagRow("PERCORSO", path)
        diagRow("MODO",     label)
    }

    // Helpers to avoid String(Int) overload-resolution timeout in @ViewBuilder
    // (CLAUDE.md §13 v1.0.255). All string building happens outside ViewBuilder.
    private static func latencyString(_ ms: Int) -> String {
        guard ms > 0 else { return "n/d" }
        return ms.description + " ms"
    }

    @ViewBuilder
    private var diagPanelFrameCounters: some View {
        let txVal = appState.callService.framesEncryptedTx.description
        let rxVal = appState.callService.framesDecryptedRx.description
        let rekeyVal = appState.rekeyCount.description
        let latencyVal = Self.latencyString(appState.latencyMs)
        diagRow("TX FRAME CIFRATI",   txVal)
        diagRow("RX FRAME DECIFRATI", rxVal)
        diagRow("REKEY",              rekeyVal)
        diagRow("LATENZA RELAY",      latencyVal)
    }

    private func diagRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(.gray)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: - W324: stub "REKEY DEMO" badge (hidden once keyInfo is live).

    @ViewBuilder
    private var stubRekeyDisclaimer: some View {
        Text(Self.stubRekeyText)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.0)
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().stroke(Color.orange.opacity(0.6), lineWidth: 1)
            )
            .accessibilityLabel("Rekey demo, contatore non collegato al motore")
    }

    private static let stubRekeyText: String = "REKEY DEMO"

    // MARK: - Derived state

    /// W-MUTEBTNSRC (2026-07-24) — reads the published mirror, so the value
    /// updates the moment it changes instead of on the next TimelineView tick,
    /// and no local `@State` copy has to be kept in step with it.
    private var liveMuted: Bool {
        appState.callMuted
    }

    /// W368: live SAS verification flag. Returns true iff the
    /// SasVerificationStore has the current SAS words' fingerprint
    /// stored under the call's peer id. Computed every TimelineView
    /// tick — cheap (one UserDefaults string read).
    private var liveSasVerified: Bool {
        let words = appState.callSasWords
        guard !words.isEmpty,
              let peer = appState.callContactId else { return false }
        guard let identityTag = sasIdentityTag(for: peer) else { return false }
        let fp = SasVerificationStore.fingerprint(forWords: words)
        return SasVerificationStore.shared.isVerified(
            peerUserId: peer, currentFingerprint: fp, currentIdentityTag: identityTag)
    }

    /// W502: build a `KeyInfo` panel from the live ML-KEM session key.
    /// Returns nil while the key is unavailable (panel stays hidden,
    /// "DEMO" badge remains visible). Mirrors Android's KeyInfoPanel
    /// which shows algo + session fingerprint + PSK block.
    private var liveKeyInfo: InCallScreen.KeyInfo? {
        guard let key = appState.callPqcSessionKey, !key.isEmpty else { return nil }
        let fp = Self.sessionFingerprintFromKey(key)
        // W-UNIFORMKEYINFO — canonical spec: method must always come from the
        // REAL negotiated label ("KMS"/"NFC"/"QR"/"HW"/"SW"/"PSK") resolved by
        // AppState.resolvePskDisplayMeta, never a hardcoded literal reuse of
        // this row's own "PSK" label — that produced the doubled "PSK: PSK ·
        // <hex>" string. When resolution genuinely finds no local vault entry
        // (a real anomaly, not just "no human name set"), the row is skipped
        // entirely rather than shown with a fabricated method.
        let pskMethod: String? = appState.pskMethod.isEmpty ? nil : appState.pskMethod
        let pskName: String?
        if appState.pskActive && !appState.pskName.isEmpty {
            pskName = appState.pskName
        } else {
            pskName = nil
        }
        let pskFp: String?
        if appState.pskActive && !appState.pskFingerprint.isEmpty {
            pskFp = String(appState.pskFingerprint.prefix(9))
        } else {
            pskFp = nil
        }
        return InCallScreen.KeyInfo(
            pqcAlgorithm: "ML-KEM-1024 + X25519",
            sessionFingerprint: fp,
            pskMethodLabel: pskMethod,
            pskName: pskName,
            pskFingerprint: pskFp
        )
    }

    /// Unified call UI — maps the live `AppState.voiceAnalysis` (raw
    /// engine result, see QAudionEngine.VoiceAnalysisResult) onto
    /// InCallScreen's small display-only `VoiceBiometrics` struct. Returns
    /// nil while no result has arrived (engine flag off, or genuinely no
    /// analysis yet — both call directions are wired as of 2026-07-04) —
    /// InCallScreen then omits the biometrics rows entirely rather than
    /// showing zeros.
    private var liveVoiceBiometrics: InCallScreen.VoiceBiometrics? {
        guard let result = appState.voiceAnalysis else { return nil }
        return InCallScreen.VoiceBiometrics(
            stressScore: result.stress.score,
            jitter: result.stress.jitter,
            shimmer: result.stress.shimmer,
            hnr: result.voiceHealth.hnr,
            breathiness: result.voiceHealth.breathiness,
            pitchHz: result.pitch.f0Hz,
            syllablesPerSec: result.speechRate.syllablesPerSec,
            confidence: result.confidence,
            // Unified call UI — formant/energy inputs for the animated
            // mini-spectrum. f1…f4 are the real vocal-resonance peaks; the
            // spectrum maps them onto a 0…3800 Hz display band. `speaking`
            // gates the cyan→green active tint (isSpeaking && voiced).
            f1: result.formants.f1,
            f2: result.formants.f2,
            f3: result.formants.f3,
            f4: result.formants.f4,
            speaking: result.speechRate.isSpeaking && result.pitch.voiced
        )
    }

    /// Compute a short display fingerprint from the ML-KEM session key.
    /// Format: first 8 hex chars + "…" + last 4 hex chars of SHA-256(key).
    /// E.g. "7f3bd2a1…d2e9" — matches Android KeyInfoPanel.
    private static func sessionFingerprintFromKey(_ key: Data) -> String {
        let digest = SHA256.hash(data: key)
        var hex = ""
        for byte in digest {
            hex += String(format: "%02x", byte)
        }
        let head = String(hex.prefix(8))
        let tail = String(hex.suffix(4))
        return head + "…" + tail
    }

    /// W-EXTPREFIX consolidation (2026-07-29): this used to be an
    /// independent copy of the resolution chain PLUS a separate ad-hoc
    /// token-scan parser for `cachedPeerShortNumber` (regex-shaped digit
    /// hunting through the ALREADY-resolved display string, truncated to 3
    /// chars) — fragile, and capable of silently diverging from
    /// `cachedPeerDisplayName` for a 4+-digit extension (a real bug: the
    /// name would show "1234" while the avatar glyph showed the wrong
    /// "123"). Now `cachedPeerDisplayName` is a single call into the
    /// canonical `DisplayName.forUser`, and `cachedPeerShortNumber` (the
    /// avatar-circle glyph only — see `QAudionAvatar`'s `shortNumber` param,
    /// rendered verbatim with no length cap of its own, same as
    /// `CallHistoryView`'s `entry.peerExtension.map(String.init)`) reads the
    /// peer's OWN structured extension field directly instead of
    /// re-deriving it by scanning text and truncating to 3 chars.
    private func resolvePeerDisplayName() {
        guard let id = appState.callContactId else {
            cachedPeerDisplayName = "Sconosciuto"
            cachedPeerShortNumber = nil
            cachedPeerAvatarUrl = nil
            return
        }
        let stored = contactsStore.load()
        let match = stored.first(where: { $0.userId == id })
        cachedPeerDisplayName = DisplayName.forUser(
            id,
            serverDisplay: appState.incomingCallerName.isEmpty ? nil : appState.incomingCallerName,
            contacts: stored
        )
        cachedPeerShortNumber = DisplayName.resolvedExtension(
            for: id, serverDisplay: appState.incomingCallerName.isEmpty ? nil : appState.incomingCallerName,
            knownExtension: match?.`extension`, contacts: stored)
        cachedPeerAvatarUrl = match?.avatarUrl
        // 2026-07-29 fix (same root cause as InCallContainer's — see its
        // doc comment): `DisplayName.forUser`'s async enrichment
        // (`NameResolutionService.ensureResolved` → `enrichFromCallProfile`,
        // the only path that persists the peer's real phone number) only
        // fires on a tier-6 miss, which `incomingCallerName` already
        // resolving the name at tier 2 usually prevents. Fire it
        // explicitly so phone/extension enrichment is attempted for every
        // real call regardless of which tier resolved the display name —
        // idempotent, internally deduped + cooldown-gated.
        NameResolutionService.shared.ensureResolved(userId: id)
    }

    /// Stub rekey countdown derived from a local anchor. Counts down
    /// 300→0 then loops back to 300 — purely visual until the engine
    /// exposes the real next-rekey timer (see W29 GAP analysis).
    private var liveRekeyInSeconds: Int {
        let elapsed = Int(Date().timeIntervalSince1970 - rekeyAnchorEpoch)
        let inWindow = ((elapsed % Self.rekeyTotalSeconds) + Self.rekeyTotalSeconds)
            % Self.rekeyTotalSeconds
        return Self.rekeyTotalSeconds - inWindow
    }

    // NOTE (2026-07-04 dedup): the old `liveSamples` / `liveRxSamples` /
    // `liveCipherSamples` bridges are GONE together with InCallScreen's
    // SessionStatusStrip call and the synthetic "VOCE RICEVUTA"/"CIFRATURA"
    // oscilloscopes they fed. The honest replacements are already wired
    // below: `appState.voiceSpectrum` (real RX FFT → Guardian MiniSpectrum)
    // and `appState.cryptoOpsPerSec` (real AES-GCM ops/s → CipherFlowTube).

    private var liveTransportMode: InCallScreen.TransportMode {
        switch appState.backendType {
        case "p2p":   return .p2pSrtp        // WebRTC ICE direct
        case "turn":  return .turn            // WebRTC via TURN relay
        case "relay": return .bcryptoWsRelay  // bcrypto server WS relay (fallback)
        default:      return .disconnected
        }
    }
}

#Preview {
    LiveInCallScreen()
        .environmentObject({
            let s = AppState()
            s.callContactId = "user-mario"
            s.confidenceScore = 0.92
            s.backendType = "p2p"
            s.isInCall = true
            return s
        }())
        .qAudionTheme(dark: true)
}
