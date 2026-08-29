import SwiftUI
import CryptoKit
import QAudionEngine
#if canImport(WebRTC)
import WebRTC
#endif

// MARK: - Video Call View

/// Full-screen video call UI. Remote feed fills the screen; local
/// camera is a PiP in the bottom-right corner. SAS verification panel
/// overlays the bottom-left so the user can confirm words without
/// leaving the call. Mirrors Android InCallScreen (videoActive mode):
/// transparent mesh background replaced by real video, info minimized.
struct VideoCallView: View {
    @EnvironmentObject var appState: AppState

    /// W-MUTEBTNSRC (2026-07-24) — read LIVE from the published mirror. This was
    /// an `@State` seeded once in `onAppear`, so a mute arriving from CallKit
    /// (system call UI, lock screen, headset button) left the button reading
    /// "live" while the mic was muted, and the next tap unmuted-then-muted.
    private var isMuted: Bool { appState.callMuted }
    /// W-CAMBTNSRC (2026-07-24) — read LIVE from the ONE authoritative signal.
    /// This was an `@State` defaulting to `true` and re-synced on remount from
    /// `!appState.localVideoPaused`, whose default `false` is ambiguous between
    /// "not paused" and "never started" — the same ambiguity WIRE_SPEC §8.9
    /// calls out for the `paused` wire field. `localCameraSending` also requires
    /// `isVideoCall`, so it cannot claim the camera is live outside a video call,
    /// and being derived it needs no remount re-sync at all.
    private var isCameraOn: Bool { appState.localCameraSending }
    @State private var isSpeaker = true
    @State private var showControls = true
    @State private var showSas = false
    /// W502: toggle for the diagnostics overlay.
    @State private var showDiagnostics = false

    // Resolved display name (same lookup pattern as LiveInCallScreen).
    @State private var peerDisplayName: String = ""
    private let contactsStore = ContactsStore()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            remoteVideoLayer

            VStack(spacing: 0) {
                if showControls {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                    // Unified call UI — compact trust bar (SAS ✓ / PQC /
                    // transport chips). Additive: topBar's existing lock
                    // icon + CallSecurityBadge are untouched; this is a
                    // second, small row directly under it, matching the
                    // "trust bar → Guardian ribbon" order from
                    // call-guardian-reference.html. The Guardian ribbon
                    // itself lives inside the existing diagnostics sheet
                    // here (videoDiagPanel) rather than a second overlay,
                    // to avoid stacking two bottom sheets on the video
                    // surface.
                    trustBar
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()

                HStack(alignment: .bottom) {
                    // SAS panel anchored bottom-left (shown only when
                    // SAS words are available + user tapped the lock icon).
                    if showSas && appState.callSasWords.count == 6 {
                        sasMiniPanel
                            .transition(.move(edge: .leading).combined(with: .opacity))
                            .padding(.leading, 12)
                    }

                    Spacer()

                    if isCameraOn {
                        localPreview
                    }
                }

                if showControls {
                    bottomControls
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 40)
                }
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls.toggle()
            }
        }
        // W502: diagnostics overlay (bottom sheet, above controls).
        .overlay(alignment: .bottom) {
            if showDiagnostics {
                videoDiagPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 120)
                    .padding(.horizontal, 16)
            }
        }
        // W534 — "peer is sharing their screen" badge. Shown whenever
        // the remote peer has announced a `SCREEN_SHARE:start` via the
        // OpaqueMessage piggy-back framing. Pinned top-center under
        // the safe area so it doesn't fight the topBar layout.
        // See apps/qaudion-desktop/docs/SCREEN_SHARE_PROTOCOL.md.
        .overlay(alignment: .top) {
            if appState.peerScreenShareActive {
                screenShareBadge
                    .padding(.top, 56)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // WIRE_SPEC §8.1 — "peer paused their video" badge. Only reached
        // while this screen is still mounted, i.e. the local camera is
        // still on (once both sides pause, ContentView.inCallStack has
        // already swapped to LiveInCallScreen). Mirrors Desktop's
        // equivalent badge for the same wire signal.
        .overlay(alignment: .top) {
            if appState.remoteVideoPaused && !appState.peerScreenShareActive {
                peerVideoPausedBadge
                    .padding(.top, 56)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .animation(.easeInOut(duration: 0.25), value: showSas)
        .animation(.easeInOut(duration: 0.2), value: showDiagnostics)
        .animation(.easeInOut(duration: 0.25), value: appState.peerScreenShareActive)
        .animation(.easeInOut(duration: 0.25), value: appState.remoteVideoPaused)
        .statusBarHidden(!showControls)
        .onAppear {
            ScreenshotLockService.lock()
            resolveDisplayName()
            // W-AUDIOUILIE (2026-07-24) — mute/speaker are still local @State and
            // so still need a remount re-sync (the camera no longer does: it is
            // derived from appState.localCameraSending — W-CAMBTNSRC). They
            // opened at hardcoded `false` / `true` on every remount, so after a
            // single video toggle round trip the mic button could read "live"
            // while the mic was muted, and the speaker button could read "on"
            // while audio was on the receiver. Worse than cosmetic — the next
            // tap toggles from the fabricated value and applies the inverse of
            // what the user intended. Seeded from the live truth
            // (`CallService.isMuted` / `AppState.callSpeakerOn`), same pattern.
            isSpeaker = appState.callSpeakerOn
        }
        .onDisappear {
            ScreenshotLockService.unlock()
        }
        .onChange(of: appState.callContactId) { _ in
            resolveDisplayName()
        }
        // 2026-07-30: `peerDisplayName` is a @State snapshot taken by
        // `resolveDisplayName()` — same stale-cache shape as the
        // ContactsListView bug (W-UUIDSWEEP class). Without this, a peer
        // reached via bare extension/UUID fallback at call-start stays on
        // that fallback for the ENTIRE call even after
        // `NameResolutionService` lands the real name mid-call.
        .onReceive(NotificationCenter.default.publisher(for: .contactsDidChange)) { _ in
            resolveDisplayName()
        }
    }

    // MARK: - Remote video

    @ViewBuilder
    private var remoteVideoLayer: some View {
        #if canImport(WebRTC)
        // SOURCE PRIORITY (device-verified 2026-06-26, iOS↔Android black screen):
        // an Android peer sends remote video over WebRTC RTP, NOT the WS
        // sealed-relay HEVC `videoPipeline`. `videoPipeline` is non-nil on every
        // video call (it owns the local camera capture), so the old
        // `if let pipeline` branch ALWAYS won and rendered the empty WS-HEVC
        // remote display → the peer's camera showed as a black screen even though
        // the remote WebRTC track was received and its FrameCryptor was keyed
        // (proof: the Android side decoded our frames fine). When a remote WebRTC
        // video track is present the peer is RTP-sending, so it MUST take
        // precedence. iOS↔iOS / iOS↔Desktop carry no remote WebRTC track and
        // fall through to the WS HEVC pipeline exactly as before.
        if let track = appState.remoteWebRtcVideoTrack as? RTCVideoTrack {
            // RTCMTLVideoView already applies .scaleAspectFit internally.
            // VIDEODIAG §8.7 — the view wraps its real renderer in a
            // counting forwarder fed by appState.videoDiag, so the
            // rendered-hop counter stops whenever this view detaches.
            WebRTCRemoteVideoView(track: track, diag: appState.videoDiag)
                .ignoresSafeArea()
        } else if let pipeline = appState.videoPipeline {
            // W562 — fill the whole screen; the AVSampleBufferDisplayLayer's own
            // .resizeAspect letterboxes keeping aspect ratio. A single aspect
            // stage (the layer) is correct now the encoder emits portrait dims.
            RemoteVideoDisplay(pipeline: pipeline)
                .ignoresSafeArea()
        } else {
            remoteVideoFallback
        }
        #else
        if let pipeline = appState.videoPipeline {
            RemoteVideoDisplay(pipeline: pipeline)
                .ignoresSafeArea()
        } else {
            remoteVideoFallback
        }
        #endif
    }

    private var remoteVideoFallback: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.fill")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.3))
            Text("Video cifrato")
                .font(.caption)
                .foregroundColor(.white.opacity(0.3))
            Text(appState.videoCodecLabel + " + AES-256-GCM")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.green.opacity(0.5))
        }
    }

    /// W534 — minimal "schermo condiviso" badge surfaced when the peer
    /// announces `SCREEN_SHARE:start`. The remote RTP frames mount on
    /// the existing `remoteVideoLayer` (pre-allocated transceiver), so
    /// this view only owns the textual affordance.
    private var screenShareBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 11, weight: .semibold))
            Text("Schermo condiviso")
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .accessibilityLabel(Text("Il peer sta condividendo lo schermo"))
    }

    /// WIRE_SPEC §8.1 — "peer paused their video" badge, shown while the
    /// remote peer has signalled `call_video_state(paused: true)` and we
    /// still have our own camera on (so this screen is still mounted).
    /// Same visual language as `screenShareBadge` above.
    private var peerVideoPausedBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("Il peer ha messo in pausa la videocamera")
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .accessibilityLabel(Text("Il peer ha messo in pausa la videocamera"))
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(peerDisplayName.isEmpty ? (appState.callContactId ?? "Videochiamata") : peerDisplayName)
                    .font(.headline)
                    .foregroundColor(.white)

                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.green)

                    Text("Cifrato · " + appState.videoCodecLabel)
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            // SAS lock button — tapping shows/hides the SAS mini panel.
            if appState.callSasWords.count == 6 {
                Button {
                    withAnimation { showSas.toggle() }
                } label: {
                    Image(systemName: sasVerified ? "checkmark.seal.fill" : "lock.shield")
                        .font(.system(size: 20))
                        .foregroundColor(sasVerified ? .green : .white)
                }
                .padding(.trailing, 8)
                .accessibilityLabel(sasVerified ? "Identità verificata (SAS)" : "Verifica identità (SAS) in sospeso")
            }

            // W502: diagnostics toggle button.
            Button {
                showDiagnostics.toggle()
            } label: {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .padding(.trailing, 4)
            .accessibilityLabel("Diagnostica")

            CallSecurityBadge()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Trust bar (unified call UI)

    /// Compact security-chip row: SAS ✓ (only once actually verified),
    /// PQC (only once a real ML-KEM session key is live — same source as
    /// `videoDiagSessionKey` below, NOT the literal string "PQC" that
    /// `appState.backendType` never equals), and the media-transport
    /// label (`p2p`/`turn`/`relay` from AppState, mapped to the same
    /// wording InCallScreen's TransportMode.label uses so the two call
    /// surfaces read consistently). Tapping the shield opens the existing
    /// diagnostics sheet, now extended with the Guardian mini-gauges
    /// (see videoDiagPanel) — reusing one sheet rather than stacking a
    /// second one on the video surface.
    private var trustBar: some View {
        HStack(spacing: 6) {
            if sasVerified {
                trustChip(icon: "checkmark", label: "SAS ✓", color: .green, filled: true)
            }
            if appState.callPqcSessionKey != nil && !(appState.callPqcSessionKey?.isEmpty ?? true) {
                trustChip(icon: "lock.shield.fill", label: "PQC", color: .purple, filled: false)
            }
            trustChip(icon: nil, label: transportChipLabel, color: .white.opacity(0.75), filled: false)
            Spacer()
        }
    }

    private func trustChip(icon: String?, label: String, color: Color, filled: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .bold))
            }
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.4)
        }
        .foregroundColor(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(filled ? color.opacity(0.16) : Color.clear)
        )
        .overlay(
            Capsule().stroke(color.opacity(0.5), lineWidth: 1)
        )
    }

    /// Maps the live `backendType` ("p2p"/"turn"/"relay") to the same
    /// wording InCallScreen.TransportMode.label uses, so the audio and
    /// video call surfaces read consistently. Falls back to "CONNECTING…"
    /// for any other/unrecognised value, matching TransportMode's default
    /// case.
    private var transportChipLabel: String {
        switch appState.backendType {
        case "p2p":   return "P2P SRTP"
        case "turn":  return "TURN"
        case "relay": return "RELAY"
        default:      return "CONNECTING…"
        }
    }

    // MARK: - SAS mini panel (bottom-left overlay)

    private var sasMiniPanel: some View {
        let words = appState.callSasWords
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: sasVerified ? "checkmark.seal.fill" : "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(sasVerified ? .green : .cyan)
                Text(sasVerified ? "SAS VERIFICATO" : "CONFRONTA PAROLE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(sasVerified ? .green : .cyan)
            }

            if words.count == 6 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        sasWord(words[0]); sasWord(words[1]); sasWord(words[2])
                    }
                    HStack(spacing: 8) {
                        sasWord(words[3]); sasWord(words[4]); sasWord(words[5])
                    }
                }
            }

            if !sasVerified {
                Button(action: confirmSas) {
                    Text("CONFERMO")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.0)
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.green))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke((sasVerified ? Color.green : Color.cyan).opacity(0.6), lineWidth: 1)
        )
    }

    private func sasWord(_ word: String) -> some View {
        Text(word)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
    }

    // MARK: - Local camera preview (PiP)

    @ViewBuilder
    private var localPreview: some View {
        ZStack {
            if let pipeline = appState.videoPipeline {
                LocalCameraPreview(pipeline: pipeline)
                    .frame(width: 120, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.15))
                    .frame(width: 120, height: 160)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.title)
                            .foregroundColor(.gray)
                    )
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
        .padding(.trailing, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Bottom controls (unified call UI — cosmetic regroup only)
    //
    // Same 5 buttons, same closures (videoFlipCamera / videoSetCameraEnabled
    // / setMuted / setSpeaker / endCall) — nothing added or removed. Order
    // changed to match the unified dock's primary-controls-together,
    // hangup-last convention from call-guardian-reference.html /
    // InCallScreen's regrouped dock: mute · speaker · video · invert ·
    // end (was: invert · video · mute · end · speaker, with hangup
    // stranded in the middle).

    private var bottomControls: some View {
        HStack(spacing: 24) {
            videoButton(
                icon: isMuted ? "mic.slash.fill" : "mic.fill",
                label: isMuted ? "Riattiva" : "Muto",
                isActive: isMuted
            ) {
                appState.setMuted(!isMuted)
            }
            videoButton(
                icon: isSpeaker ? "speaker.wave.3.fill" : "speaker.fill",
                label: "Altoparlante",
                isActive: isSpeaker
            ) {
                isSpeaker.toggle()
                appState.setSpeaker(isSpeaker)
            }
            videoButton(
                icon: isCameraOn ? "video.fill" : "video.slash.fill",
                label: isCameraOn ? "Video attivo" : "Video spento",
                isActive: !isCameraOn
            ) {
                appState.videoSetCameraEnabled(!isCameraOn)
            }
            videoButton(icon: "camera.rotate.fill", label: "Inverti") {
                appState.videoFlipCamera()
            }
            videoButton(icon: "phone.down.fill", label: "Termina", isEndCall: true) {
                appState.endCall()
            }
        }
    }

    // MARK: - Video control button helper

    private func videoButton(
        icon: String,
        label: String,
        isActive: Bool = false,
        isEndCall: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 50, height: 50)
                    .background(
                        isEndCall ? Color.red
                            : (isActive ? Color.blue : Color.white.opacity(0.15))
                    )
                    .clipShape(Circle())
                    .foregroundColor(.white)

                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
            }
        }
    }

    // MARK: - Diagnostics panel (W502)

    @ViewBuilder
    private var videoDiagPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.green)
                Text("DIAGNOSTICA VIDEO")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.green)
                Spacer()
                Button {
                    showDiagnostics = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Chiudi")
            }
            Divider().background(Color.white.opacity(0.2))
            videoDiagTransport
            videoDiagFrameCounters
            videoDiagSessionKey
            // Unified call UI — Guardian voice biometrics, interpreted
            // (value + plain-language meaning), reusing the existing
            // diagnostics sheet as the aggregation point for video calls
            // rather than a second sheet. Omitted entirely (not the
            // section header either) when no result is available, so the
            // sheet never shows a fabricated "0.00" row.
            if appState.voiceAnalysis != nil {
                Divider().background(Color.white.opacity(0.2))
                videoDiagVoiceBiometrics
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.35), lineWidth: 1))
    }

    /// Interpreted voice biometrics — same thresholds as InCallScreen's
    /// security sheet (StressDetector composite score bands, and the REAL
    /// VoiceHealthMonitor >20dB/<10dB HNR bands, since breathiness = 1 −
    /// hnr/20 is the engine's own formula, not a UI-invented threshold).
    @ViewBuilder
    private var videoDiagVoiceBiometrics: some View {
        if let bio = appState.voiceAnalysis {
            let stressPct = Int((bio.stress.score * 100).rounded())
            let stressWord = Self.videoStressWord(bio.stress.score * 100)
            let hnrWord = Self.videoHnrWord(bio.voiceHealth.hnr)
            videoDiagRow("STRESS", "\(stressPct)/100 · \(stressWord)")
            videoDiagRow("RESPIRO · HNR", "\(Int(bio.voiceHealth.hnr.rounded())) dB · \(hnrWord)")
            videoDiagRow("PITCH f0", "\(Int(bio.pitch.f0Hz.rounded())) Hz")
        }
    }

    /// UI-only interpretive band (the engine's composite stress score has
    /// no named bands of its own) — matches InCallScreen's
    /// stressStatusWord thresholds so the two surfaces never disagree.
    private static func videoStressWord(_ pct: Float) -> String {
        if pct < 35 { return "calmo" }
        if pct < 60 { return "elevato" }
        return "agitato"
    }

    /// REAL threshold: VoiceHealthMonitor.analyze computes
    /// `breathiness = max(0, 1 - hnr/20)`, so >20dB clear / <10dB hoarse
    /// is a direct reading of that formula.
    private static func videoHnrWord(_ hnr: Float) -> String {
        if hnr > 20 { return "chiara" }
        if hnr < 10 { return "rauca" }
        return "media"
    }

    @ViewBuilder
    private var videoDiagTransport: some View {
        let codec = appState.videoCodecLabel
        let path = codec + " · AES-256-GCM"
        videoDiagRow("CODEC / CIFRA", path)
        // W-SRTPCOUNTERS (2026-08-29) — effective counters: RTP packets on a
        // native-SRTP call, sealed frames on the DataChannel path. The raw
        // frame counters read 0 for the whole of an `audio-srtp-v1` call.
        videoDiagRow("AUDIO TX",  appState.callService.effectiveAudioTxCount.description)
        videoDiagRow("AUDIO RX",  appState.callService.effectiveAudioRxCount.description)
    }

    // Helpers — build strings outside @ViewBuilder to avoid String(Int)
    // overload timeout on Xcode 26.4 (CLAUDE.md §13 v1.0.255).
    private static func videoLatencyString(_ ms: Int) -> String {
        guard ms > 0 else { return "n/d" }
        return ms.description + " ms"
    }

    @ViewBuilder
    private var videoDiagFrameCounters: some View {
        let hasPipeline = appState.videoPipeline != nil
        let pipelineState = hasPipeline ? "attiva" : "inattiva"
        let rekeyVal = appState.rekeyCount.description
        let latencyVal = Self.videoLatencyString(appState.latencyMs)
        videoDiagRow("PIPELINE VIDEO", pipelineState)
        videoDiagRow("REKEY",          rekeyVal)
        videoDiagRow("LATENZA RELAY",  latencyVal)
    }

    @ViewBuilder
    private var videoDiagSessionKey: some View {
        if let key = appState.callPqcSessionKey, !key.isEmpty {
            let fp = Self.sessionFingerprintForDiag(key)
            videoDiagRow("SESSIONE ML-KEM", fp)
        } else {
            videoDiagRow("SESSIONE ML-KEM", "handshake in corso…")
        }
    }

    private func videoDiagRow(_ label: String, _ value: String) -> some View {
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

    private static func sessionFingerprintForDiag(_ key: Data) -> String {
        let digest = SHA256.hash(data: key)
        var hex = ""
        for byte in digest { hex += String(format: "%02x", byte) }
        let head = String(hex.prefix(8))
        let tail = String(hex.suffix(4))
        return head + "…" + tail
    }

    // MARK: - Derived state

    private var sasVerified: Bool {
        let words = appState.callSasWords
        guard !words.isEmpty, let peer = appState.callContactId else { return false }
        guard let pinned = PeerIdentityPinStore().pinnedKey(contactId: peer) else { return false }
        let fp = SasVerificationStore.fingerprint(forWords: words)
        // C-3 — the SAS words alone are not enough: they must still belong to the
        // identity key the ceremony was performed against.
        return SasVerificationStore.shared.isVerified(
            peerUserId: peer, currentFingerprint: fp,
            currentIdentityTag: SasVerificationStore.identityTag(forPinnedKey: pinned))
    }

    private func confirmSas() {
        let words = appState.callSasWords
        // C-3 — a confirmation with no pinned identity to bind it to is exactly the
        // record this finding was about, so refuse to write one.
        guard !words.isEmpty, let peer = appState.callContactId,
              let pinned = PeerIdentityPinStore().pinnedKey(contactId: peer) else { return }
        let fp = SasVerificationStore.fingerprint(forWords: words)
        SasVerificationStore.shared.recordVerified(
            peerUserId: peer, fingerprint: fp,
            identityTag: SasVerificationStore.identityTag(forPinnedKey: pinned))
    }

    /// W-EXTPREFIX consolidation (2026-07-29): this used to be ANOTHER
    /// independent copy of the resolution chain — `match.displayName`
    /// returned raw with no placeholder (or even UUID) guard at all, unlike
    /// every other consolidated call site. Now a single call into the
    /// canonical `DisplayName.forUser`.
    private func resolveDisplayName() {
        guard let id = appState.callContactId else { peerDisplayName = ""; return }
        let contacts = contactsStore.load()
        peerDisplayName = DisplayName.forUser(
            id,
            serverDisplay: appState.incomingCallerName.isEmpty ? nil : appState.incomingCallerName,
            contacts: contacts
        )
    }
}

// MARK: - Previews

#if DEBUG
struct VideoCallView_Previews: PreviewProvider {
    static var previews: some View {
        VideoCallView()
            .environmentObject(previewAppState())
    }

    static func previewAppState() -> AppState {
        let state = AppState()
        state.callContactId = "Alice"
        state.callState = .encrypted
        state.isVideoCall = true
        state.isInCall = true
        return state
    }
}
#endif
