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
///   - `recentSamples`       ← `appState.txWaveformSamples` (last N tx samples)
///   - `muted`               ← local @State mirror, set + read by button tap
///   - `transportMode`       ← `.bcryptoWsRelay` if `backendType == "PQC"`
///                              else `.disconnected` (richer mapping when
///                              engine surfaces real transport feedback)
///   - `keyInfo`             ← built from `appState.callPqcSessionKey` +
///                              `appState.pskActive`/`pskName`/`pskFingerprint`
///                              when ML-KEM session key is available (W502)
///
/// Stub fields (kept until engine exposes them — see W29 spec from
/// the parallel agent):
///   - `recentSamples` if empty → fallback to confidenceScore-derived
///                                 5-point sparkline
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

    @State private var muted: Bool = false
    @State private var speakerOn: Bool = false
    @State private var voiceEnhancement: Bool = false
    /// Camera on/off state for video calls. Starts ON when the call
    /// is a video call; user can mute/unmute the camera mid-call.
    @State private var cameraOn: Bool = false

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
            // Seed camera state from the call type: video calls start
            // with camera ON; audio calls hide the button entirely.
            cameraOn = appState.isVideoCall
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
                avatarUrl: nil,
                durationSeconds: Int(appState.callService.callDurationSeconds),
                confidence: Double(appState.confidenceScore),
                recentSamples: liveSamples,
                rekeyInSeconds: liveRekeyInSeconds,
                rekeyTotalSeconds: Self.rekeyTotalSeconds,
                pqcActive: appState.backendType == "PQC",
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
                rxSamples: liveRxSamples,
                cipherSamples: liveCipherSamples,
                onToggleMute: handleToggleMute,
                onToggleSpeaker: handleToggleSpeaker,
                onToggleVoiceEnhancement: handleToggleVoiceEnhancement,
                onToggleCamera: handleToggleCamera,
                onUpgradeToVideo: handleUpgradeToVideo,
                screenSharing: appState.isScreenSharing,
                onToggleScreenShare: handleToggleScreenShare,
                peerScreenSharing: appState.peerScreenShareActive,
                onAddParticipant: {},
                onHangup: handleHangup,
                onConfirmSas: handleConfirmSas,
                // W502: toggle the diagnostics overlay.
                onToggleDiagnostics: handleToggleDiagnostics
            )
    }

    // MARK: - Action handlers (extracted per SWIFT6_PATTERNS §13 — named
    //         methods prevent type-checker timeout inside @ViewBuilder).

    private func handleToggleMute() {
        let next = !appState.callService.isMuted
        muted = next
        appState.setMuted(next)
    }

    private func handleToggleSpeaker() {
        speakerOn.toggle()
        appState.setSpeaker(speakerOn)
    }

    private func handleToggleVoiceEnhancement() {
        voiceEnhancement.toggle()
    }

    private func handleToggleCamera() {
        cameraOn.toggle()
        appState.setCamera(cameraOn)
    }

    private func handleUpgradeToVideo() {
        cameraOn = true
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
              let peer = appState.callContactId else { return }
        let fp = SasVerificationStore.fingerprint(forWords: words)
        SasVerificationStore.shared.recordVerified(peerUserId: peer, fingerprint: fp)
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

    /// Always re-reads `CallService.isMuted` so external mute changes
    /// (Bluetooth headset, programmatic) propagate to the UI on each
    /// TimelineView tick. The local `@State muted` mirror is still
    /// updated on tap to avoid a one-frame flicker.
    private var liveMuted: Bool {
        appState.callService.isMuted
    }

    /// W368: live SAS verification flag. Returns true iff the
    /// SasVerificationStore has the current SAS words' fingerprint
    /// stored under the call's peer id. Computed every TimelineView
    /// tick — cheap (one UserDefaults string read).
    private var liveSasVerified: Bool {
        let words = appState.callSasWords
        guard !words.isEmpty,
              let peer = appState.callContactId else { return false }
        let fp = SasVerificationStore.fingerprint(forWords: words)
        return SasVerificationStore.shared.isVerified(
            peerUserId: peer, currentFingerprint: fp)
    }

    /// W502: build a `KeyInfo` panel from the live ML-KEM session key.
    /// Returns nil while the key is unavailable (panel stays hidden,
    /// "DEMO" badge remains visible). Mirrors Android's KeyInfoPanel
    /// which shows algo + session fingerprint + PSK block.
    private var liveKeyInfo: InCallScreen.KeyInfo? {
        guard let key = appState.callPqcSessionKey, !key.isEmpty else { return nil }
        let fp = Self.sessionFingerprintFromKey(key)
        let pskMethod: String? = appState.pskActive ? "PSK" : nil
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

    private func resolvePeerDisplayName() {
        guard let id = appState.callContactId else {
            cachedPeerDisplayName = "Sconosciuto"
            cachedPeerShortNumber = nil
            return
        }
        let stored = contactsStore.load()
        // W569: sanitise the contact's displayName via StringSanitiser so that
        // UUID-format names (set by the server when a user registers without a
        // real display name) are treated as absent rather than displayed raw.
        // Fall through to the incomingCallerName path when the name is a UUID.
        let contactSanitised: String? = {
            guard let m = stored.first(where: { $0.userId == id }) else { return nil }
            let sanitised = StringSanitiser.displayName(m.displayName, fallback: "")
            return sanitised.isEmpty ? nil : sanitised
        }()
        if let displayName = contactSanitised {
            cachedPeerDisplayName = displayName
            // Estrai il numero interno dal displayName del contatto usando
            // la stessa logica di QAudionAvatar.initials() — cerca token
            // puramente numerici (es. "103" in "Interno 103").
            let tokens = displayName
                .trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            if let numTok = tokens.first(where: { $0.allSatisfy({ $0.isNumber }) }) {
                cachedPeerShortNumber = String(numTok.prefix(3))
            } else if let hashTok = tokens.first(where: { $0.hasPrefix("#") }) {
                cachedPeerShortNumber = String(hashTok.dropFirst().prefix(3))
            } else {
                cachedPeerShortNumber = nil
            }
        } else {
            // Peer not in contacts. Priority:
            // 1. incomingCallerName (already resolved from server caller_display
            //    → "Int. 112") — this is set by call_incoming handler and contains
            //    the PBX extension even when the peer is not in local contacts.
            // 2. UUID truncation as last resort (never show 36-char raw UUID).
            let resolvedFromSignaling = appState.incomingCallerName
            if !resolvedFromSignaling.isEmpty {
                cachedPeerDisplayName = resolvedFromSignaling
                // Extract short number from "Int. 112" → "112"
                let tokens = resolvedFromSignaling.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if let num = tokens.first(where: { $0.allSatisfy({ $0.isNumber }) }) {
                    cachedPeerShortNumber = String(num.prefix(3))
                } else {
                    cachedPeerShortNumber = nil
                }
            } else if id.hasPrefix("user-") {
                cachedPeerDisplayName = String(id.dropFirst(5)).capitalized
                cachedPeerShortNumber = nil
            } else if id.count > 12 {
                cachedPeerDisplayName = String(id.prefix(8)) + "…" + String(id.suffix(4))
                cachedPeerShortNumber = nil
            } else {
                cachedPeerDisplayName = id
                cachedPeerShortNumber = nil
            }
        }
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

    /// Live samples for the SessionStatusStrip mini-spark inside InCallScreen.
    /// Prefers the engine's `txWaveformSamples` feed when populated; falls back
    /// to a confidence-derived sparkline so the strip renders something
    /// meaningful even before any audio packet has arrived.
    ///
    /// NOTE: `appState.txWaveform` (128-element array) is intentionally NOT
    /// used here — it is initialised to `Array(repeating: 0, count: 128)` so
    /// it is never empty, causing the old code to always pass 128 zeros to
    /// MiniSpark → flat line drawn at y=0.  `txWaveformSamples` starts empty
    /// and only receives real samples once the audio engine delivers frames,
    /// so the empty-check correctly gates the fallback sparkline.
    private var liveSamples: [Float] {
        // W523 — user feedback v1.0.522: the SessionStatusStrip mini-spark
        // duplicates the main "VOCE RICEVUTA" oscilloscope below the avatar.
        // Pass an empty array so the strip hides the spark (SessionStatusStrip
        // guards `if !recentSamples.isEmpty`) and keeps the strip purely as
        // presence + confidence + rekey-countdown summary. The full waveform
        // moved to the stats card.
        return []
    }

    /// Live RX oscilloscope — received audio from the peer.
    /// This is the raw PCM that feeds the deepfake detector in real time.
    /// Normalized to -1…1; up to 64 samples for a smooth waveform.
    private var liveRxSamples: [Float] {
        guard appState.callState == .active || appState.callState == .encrypted else {
            return []
        }
        let rx = appState.rxWaveformSamples
        guard !rx.isEmpty else { return [] }
        return Array(rx.suffix(64))
    }

    /// Live cipher oscilloscope — byte amplitudes of the decrypted packet stream.
    /// Normalized to -1…1 (cipher bytes mapped through 0…1 → -1…1 around midpoint).
    /// Shows that the ML-KEM-1024 + SFrame pipeline is actively processing frames.
    private var liveCipherSamples: [Float] {
        guard appState.callState == .active || appState.callState == .encrypted else {
            return []
        }
        let cipher = appState.cipherWaveformSamples
        guard !cipher.isEmpty else { return [] }
        return Array(cipher.suffix(64))
    }

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
            s.backendType = "PQC"
            s.isInCall = true
            return s
        }())
        .qAudionTheme(dark: true)
}
