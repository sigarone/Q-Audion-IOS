import SwiftUI
import CryptoKit
import QAudionEngine
#if canImport(WebRTC)
import WebRTC
#endif

// MARK: - Video Call View

/// Full-screen video call UI. Remote feed fills the screen; local
/// camera is a draggable PiP that rests in the top-right corner and snaps
/// to the nearest corner when released. SAS verification panel
/// overlays the bottom-left so the user can confirm words without
/// leaving the call. Mirrors Android InCallScreen (videoActive mode):
/// transparent mesh background replaced by real video, info minimized.
struct VideoCallView: View {
    @EnvironmentObject var appState: AppState
    /// Entitlements Task 5 parity — same environment object
    /// `LiveInCallScreen` reads for its own upgrade-to-video gating.
    /// `capabilityGate` is injected on `ContentView()` (QAudionApp.swift),
    /// and `VideoCallView` is a plain descendant of it via
    /// `ContentView.inCallStack` (not a `.sheet`/`.fullScreenCover`
    /// presented above that injection point), so it's available here too.
    @EnvironmentObject private var capabilityGate: CapabilityGate
    /// W-VIDPARITY — drives `.sheet(item:)` for `UpgradeSheet` when the
    /// user taps "Attiva video" on `PeerVideoInviteBanner` without the
    /// `feat.calls.video` entitlement. Mirrors `LiveInCallScreen`'s
    /// `upgradeSheetCapability`.
    @State private var upgradeSheetCapability: Capability? = nil
    /// The chat with the peer, opened over the call (the "Chat" button of the controls). The cover, the unread dot and the action are
    /// shared with the audio call screen and live in `InCallChatHost` (see `InCallChatCover`), which sits above both and so keeps
    /// the chat open if `ContentView` swaps this screen for `LiveInCallScreen`; nil = no host or no peer, no button. Showing the
    /// cover tears nothing down here: this view, its renderers and the capture session behind them stay mounted underneath.
    @Environment(\.inCallChat) private var inCallChat

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
    /// The "+" of the dock: the same contact picker sheet the audio call screen uses (promotes the call to a group call).
    @State private var showAddParticipant = false
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @State private var showSas = false
    /// Local preview (PiP): the corner it rests in, the live drag offset, and the frames the layout reports (see CallPipLayout).
    @State private var pipCorner = CallPipLayout.defaultCorner
    @GestureState private var pipDrag: CGSize = .zero
    @State private var pipInsets = CallPipInsets()
    private static let pipSpace = "videoCallPipSpace"
    /// W502: toggle for the diagnostics overlay.
    @State private var showDiagnostics = false
    /// The voice technical-data block of the diagnostics panel is collapsed by default.
    @State private var showVoiceTechnicalData = false
    /// As on Android, the stats band is collapsed behind the info toggle during a video call, so nothing covers the
    /// picture until the user asks for it.
    @State private var showInfo = false
    /// The session security sheet ("Sicurezza sessione"), opened by the shield next to the info toggle.
    @State private var showSecuritySheet = false

    // Resolved display name (same lookup pattern as LiveInCallScreen).
    @State private var peerDisplayName: String = ""
    private let contactsStore = ContactsStore()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            remoteVideoLayer

            VStack(spacing: 0) {
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
                        // here (CallDiagnosticsPanel) rather than a second overlay,
                        // to avoid stacking two bottom sheets on the video
                        // surface.
                        trustBar
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        if showInfo {
                            CallStatsBand()
                                .padding(.horizontal, 16)
                                .padding(.top, 6)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }

                    // Narrowband Bluetooth notice: a row of the column, between the top bars and the picture area.
                    NarrowbandBluetoothBanner()
                }
                // The bottom edge of the header: the local preview stays under it.
                .background(pipFrameReader { CallPipInsets(headerMaxY: $0.maxY) })

                Spacer()

                HStack(alignment: .bottom) {
                    // SAS panel anchored bottom-left (shown only when
                    // SAS words are available + user tapped the lock icon).
                    if showSas && appState.callSasWords.count == 6 {
                        sasMiniPanel
                            .transition(.move(edge: .leading).combined(with: .opacity))
                            .padding(.leading, 12)
                            .background(pipFrameReader { CallPipInsets(sasMinY: $0.minY) })
                    }

                    Spacer()
                }

                if showControls {
                    bottomControls
                        .background(pipFrameReader { CallPipInsets(dockMinY: $0.minY) })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 8)
                }
            }
        }
        .coordinateSpace(name: Self.pipSpace)
        .onPreferenceChange(CallPipInsetsKey.self) { pipInsets = $0 }
        // The local camera preview floats above the picture, in the free area between the header and the dock.
        .overlay { if isCameraOn { pipLayer } }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls.toggle()
            }
        }
        // W502: diagnostics overlay (bottom sheet, above controls).
        .overlay(alignment: .bottom) {
            if showDiagnostics {
                CallDiagnosticsPanel(onClose: { showDiagnostics = false }) { videoDiagExtra }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, CallDockLayout.overlayClearance)
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
        // W-VIDPARITY — "Richiesta video" banner: the peer is sending
        // video and we're not (RemoteOnly lane). Mutually exclusive with
        // both badges above by construction (`shouldShowPeerVideoInviteBanner`
        // requires `peerCameraSending`, i.e. NOT `remoteVideoPaused`, and
        // NOT `peerScreenShareActive`), so no stacking offset is needed —
        // pinned at the same top position as the other top overlays.
        .overlay(alignment: .top) {
            if appState.showPeerVideoInviteBanner {
                PeerVideoInviteBanner(
                    peerName: resolvedPeerDisplayName,
                    onAccept: { appState.acceptPeerVideoInvite() },
                    onDecline: { appState.declinePeerVideoInvite() },
                    onDismiss: { appState.dismissPeerVideoInvite() },
                    acceptLocked: !capabilityGate.isUnlocked(.callsVideo),
                    onAcceptLocked: { upgradeSheetCapability = .callsVideo }
                )
                .padding(.horizontal, 16)
                .padding(.top, 56)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .animation(.easeInOut(duration: 0.25), value: showSas)
        .animation(.easeInOut(duration: 0.2), value: showDiagnostics)
        .animation(.easeInOut(duration: 0.25), value: showInfo)
        .animation(.easeInOut(duration: 0.25), value: appState.peerScreenShareActive)
        .animation(.easeInOut(duration: 0.25), value: appState.remoteVideoPaused)
        .animation(.easeInOut(duration: 0.25), value: appState.showPeerVideoInviteBanner)
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
        // The speaker button follows the app's real choice when something other than this button changes it (the
        // Bluetooth banner's "use the phone" turns the loudspeaker off).
        .onChange(of: appState.callSpeakerOn) { value in
            isSpeaker = value
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
        // Entitlements Task 5 parity — same UpgradeSheet presentation
        // LiveInCallScreen uses for its own locked in-call controls.
        .sheet(item: $upgradeSheetCapability) { capability in
            UpgradeSheet(capability: capability)
                .environmentObject(appState)
        }
        // The "+" of the dock: the same contact picker the audio call screen opens, with the video toggle locked to this
        // call's own type.
        // The same session security sheet the audio call screen opens, built from the same live call data.
        .sheet(isPresented: $showSecuritySheet) {
            LiveInCallScreen().asSecuritySheetHost()
        }
        .sheet(isPresented: $showAddParticipant) {
            GroupCallContactPickerSheet(
                contacts: addParticipantCandidates,
                onStart: { selectedIds, _ in
                    showAddParticipant = false
                    appState.promoteToGroupCall(newPeerIds: selectedIds)
                },
                lockedVideo: appState.isVideoCall
            )
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

    /// W-VIDPARITY — same resolved-name-with-fallback the topBar title
    /// already computed inline; factored out so `PeerVideoInviteBanner`
    /// can reuse it instead of duplicating the fallback chain.
    private var resolvedPeerDisplayName: String {
        peerDisplayName.isEmpty ? (appState.callContactId ?? String(localized: "Videochiamata")) : peerDisplayName
    }

    // MARK: - Top bar

    private var topBar: some View {
        // The diagnostics button and the security badge float next to each other: one glass group.
        QAudionGlassGroup(spacing: 8) {
            topBarContent
        }
    }

    private var topBarContent: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(resolvedPeerDisplayName)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.green)

                    Text(String(localized: "Cifrato · ") + appState.videoCodecLabel)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
            }
            // The name side gives way first: the security badge keeps its natural width.
            .layoutPriority(-1)

            Spacer(minLength: 8)

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
                // W-L10N-BATCH1 — ternary-in-.accessibilityLabel(variable);
                // explicit lookup to avoid relying on overload-resolution
                // ambiguity between the LocalizedStringKey and String forms.
                .accessibilityLabel(sasVerified
                    ? String(localized: "sas.accessibility.verified", defaultValue: "Identità verificata (SAS)", comment: "Accessibility label — SAS identity verification completed")
                    : String(localized: "sas.accessibility.pending", defaultValue: "Verifica identità (SAS) in sospeso", comment: "Accessibility label — SAS identity verification still pending"))
            }

            // Report a problem or a call error: marks the moment in the call telemetry, then opens the report sheet.
            Button(action: reportProblem) {
                Image(systemName: "ladybug")
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .qaudionGlassSurface(in: Circle(), interactive: true, fallback: Color.white.opacity(0.12))
            }
            .padding(.trailing, 4)
            .accessibilityLabel(CallControlText.reportA11y)

            // W502: diagnostics toggle button.
            Button {
                showDiagnostics.toggle()
            } label: {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .qaudionGlassSurface(in: Circle(), interactive: true, fallback: Color.white.opacity(0.12))
            }
            .padding(.trailing, 4)
            .accessibilityLabel("Diagnostica")

            CallSecurityBadge()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func reportProblem() {
        if TelemetryService.isEnabled { CallMediaTelemetry.shared.recordDisturbanceMarker() }
        BugReporter.shared.requestReport(source: .inCall)
    }

    // MARK: - Trust bar (unified call UI)

    /// Compact security-chip row: SAS ✓ (only once actually verified),
    /// PQC (only once a real ML-KEM session key is live — same source as
    /// the ML-KEM row of the diagnostics panel, NOT the literal string "PQC" that
    /// `appState.backendType` never equals), and the media-transport
    /// label (`p2p`/`turn`/`relay` from AppState, mapped to the same
    /// wording InCallScreen's TransportMode.label uses so the two call
    /// surfaces read consistently). The shield at its start opens the session
    /// security sheet; the info toggle next to it shows the stats band.
    private var trustBar: some View {
        HStack(spacing: 6) {
            infoControls
            if sasVerified {
                trustChip(icon: "checkmark", label: "SAS ✓", color: .green, filled: true)
            }
            if realSessionKey != nil {
                trustChip(icon: "lock.shield.fill", label: "PQC", color: .purple, filled: false)
            }
            trustChip(icon: nil, label: transportChipLabel, color: .white.opacity(0.75), filled: false)
            Spacer()
        }
    }

    /// The info toggle (stats band) is always visible; the shield (session security sheet) shows only while the
    /// toggle is open, as on Android where the trust bar is hidden while the info is minimised.
    private var infoControls: some View {
        HStack(spacing: 8) {
            if showInfo {
                Button {
                    showSecuritySheet = true
                } label: {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .qaudionGlassSurface(in: Circle(), interactive: true, fallback: Color.white.opacity(0.12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "call.video.security_a11y", defaultValue: "Sicurezza della sessione",
                                           comment: "Accessibility label — the shield on the video call screen that opens the session security sheet"))
            }
            Button {
                showInfo.toggle()
            } label: {
                Image(systemName: showInfo ? "chevron.up" : "info.circle")
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .qaudionGlassSurface(in: Circle(), interactive: true, fallback: Color.white.opacity(0.12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showInfo
                ? String(localized: "call.video.info_hide", defaultValue: "Nascondi informazioni di sicurezza",
                         comment: "Accessibility label — hides the stats band on the video call screen")
                : String(localized: "call.video.info_show", defaultValue: "Mostra informazioni di sicurezza",
                         comment: "Accessibility label — shows the stats band on the video call screen"))
        }
        .padding(.trailing, 4)
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
                .lineLimit(1)
                .fixedSize()
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
                // W-L10N-SASCONSOLIDATE — shared keys with InCallScreen's SAS panel.
                Text(sasVerified
                     ? String(localized: "sas.header.verified", defaultValue: "SAS VERIFICATO", comment: "SAS verification panel header — words already confirmed")
                     : String(localized: "sas.header.compare_words", defaultValue: "CONFRONTA PAROLE", comment: "SAS verification panel header — prompts the user to compare the 6 SAS words with the other party"))
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
                    // W-L10N-SASCONSOLIDATE — was "CONFERMO", now shares
                    // InCallScreen's sas.confirm.button key/wording ("CONFERMA").
                    Text(String(localized: "sas.confirm.button", defaultValue: "CONFERMA", comment: "SAS verification panel — button to confirm the 6 SAS words match, ALL CAPS styling"))
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
        // Flip camera: a 48 pt button on the corner of our own picture (it shows only while our camera is sending).
        .overlay(alignment: .topTrailing) {
            Button {
                appState.videoFlipCamera()
            } label: {
                Image(systemName: "camera.rotate.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.black.opacity(0.5)))
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(CallControlText.flipA11y)
        }
    }

    /// The floating layer of the preview: rests in a corner of the free area between the header and the dock, follows a
    /// finger anywhere on the screen and snaps to the nearest corner on release.
    private var pipLayer: some View {
        // Coordinate spaces: this layer is an overlay of the same view that declares `pipSpace`, so its local space and
        // the named space share the same origin and size. The header/dock frames are measured in `pipSpace`, hence in
        // the same space as `.position` below. The ZStack respects the safe area (only the black backdrop and the
        // remote video ignore it), so `geo.safeAreaInsets` is 0 here and the measured frames already include the
        // system bars; the insets stay as a floor for when the header/dock are hidden.
        GeometryReader { geo in
            let top = max(pipInsets.headerMaxY, geo.safeAreaInsets.top)
            let bottom = max(pipInsets.dockMinY.map { geo.size.height - $0 } ?? 0, geo.safeAreaInsets.bottom)
            let area = CallPipLayout.freeArea(size: geo.size, topInset: top, bottomInset: bottom)
            let rest = CallPipLayout.origin(corner: pipCorner, area: area,
                                            leadingBottomLimit: pipInsets.sasMinY.map { $0 - CallPipLayout.gap })
            let screen = CGRect(x: 0, y: geo.safeAreaInsets.top, width: geo.size.width,
                                height: geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom)
            let size = CallPipLayout.size
            let origin = CallPipLayout.clamped(origin: CGPoint(x: rest.x + pipDrag.width, y: rest.y + pipDrag.height),
                                               within: screen)
            localPreview
                // Simultaneous, so a drag that starts on the flip button still moves the preview (the button drops
                // its tap once the finger travels), while a plain tap on the button still flips the camera.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.pipSpace))
                        // GestureState resets by itself when the system cancels the gesture.
                        .updating($pipDrag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            let end = CallPipLayout.clamped(origin: CGPoint(x: rest.x + value.translation.width,
                                                                            y: rest.y + value.translation.height),
                                                            within: screen)
                            let centre = CGPoint(x: end.x + size.width / 2, y: end.y + size.height / 2)
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                pipCorner = CallPipLayout.nearestCorner(point: centre, bounds: area)
                            }
                        }
                )
                .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        }
    }

    private func pipFrameReader(_ make: @escaping (CGRect) -> CallPipInsets) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: CallPipInsetsKey.self, value: make(proxy.frame(in: .named(Self.pipSpace))))
        }
    }

    // MARK: - Control dock
    //
    // The shared `CallControlDock`: 2 rows of 4 cells, the same as the audio call and Android. Row 1: Chat, Share, Add
    // (Buds: Android only). Row 2: Mute, Audio, Video, End. The flip camera is on the local preview, the report button
    // and the shield are in the top bar.

    private var dockRows: [[CallDockItem]] {
        let style = CallDockStyle(scheme: scheme, extras: extras)
        var items: [CallDockItem] = []
        items.append(CallDockItems.mute(style, muted: isMuted, action: toggleMute))
        items.append(CallDockItems.audio(style, speakerOn: isSpeaker, action: toggleSpeaker))
        // Entitlements Task 5 parity — Android gates this manual toggle too, not just the banner's "Attiva video".
        // Turning OFF is never gated.
        items.append(CallDockItems.video(style,
                                         callHasVideo: true,
                                         cameraOn: isCameraOn,
                                         isLocked: !isCameraOn && !capabilityGate.isUnlocked(.callsVideo),
                                         action: toggleCamera,
                                         onLocked: { upgradeSheetCapability = .callsVideo }))
        items.append(CallDockItems.end(style, action: endCall))
        if let chat = inCallChat {
            items.append(CallDockItems.chat(style, unreadDot: chat.hasUnread, action: { chat.open(resolvedPeerDisplayName) }))
        }
        // W538: screen-share (hidden on Mac Catalyst).
        if screenShareAvailable {
            items.append(CallDockItems.share(style, sharing: appState.isScreenSharing, action: toggleScreenShare))
        }
        // Entitlements Task 5 — feat.calls.group, same as the audio call screen.
        items.append(CallDockItems.add(style,
                                       isLocked: !capabilityGate.isUnlocked(.callsGroup),
                                       action: { showAddParticipant = true },
                                       onLocked: { upgradeSheetCapability = .callsGroup }))
        return CallDockItems.assemble(mode: .oneToOne, items: items)
    }

    private var bottomControls: some View {
        CallControlDock(rows: dockRows)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
    }

    private func toggleMute() {
        appState.setMuted(!isMuted)
    }

    private func toggleSpeaker() {
        isSpeaker.toggle()
        appState.setSpeaker(isSpeaker)
    }

    private func toggleCamera() {
        // W-VIDPARITY / BUG (C) — was `videoSetCameraEnabled`, which is a silent no-op on a `.receiveOnly` pipeline
        // (`.external` source, no AVCaptureSession). This routes to the right mechanism for however the call got here.
        appState.setLocalCameraEnabled(!isCameraOn)
    }

    private func toggleScreenShare() {
        if appState.isScreenSharing {
            Task { @MainActor in await appState.stopScreenShare() }
        } else {
            Task { @MainActor in await appState.startScreenShare() }
        }
    }

    private func endCall() {
        appState.endCall()
    }

    /// Screen-share is supported on iOS / iPadOS (ReplayKit's in-app `RPScreenRecorder` path), not on Mac Catalyst.
    private var screenShareAvailable: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return true
        #endif
    }

    /// Contacts selectable from the "+" sheet: every stored contact except ourselves and the peer already on this call.
    private var addParticipantCandidates: [ContactsListViewModel.Item] {
        contactsStore.load()
            .filter { $0.userId != appState.callContactId }
            .map { contact in
                ContactsListViewModel.Item(
                    userId: contact.userId,
                    displayName: contact.displayName,
                    phoneHash: contact.phoneHash,
                    avatarUrl: contact.avatarUrl,
                    isOnline: false,
                    unreadMessageCount: 0,
                    isVerified: contact.isVerified,
                    extension: contact.`extension`
                )
            }
    }

    // MARK: - Diagnostics panel (W502)

    /// What the shared diagnostics panel carries under its rows on this screen: the collapsed technical-data block
    /// of the voice measures, only once a result exists (never a fabricated "0.00" row).
    @ViewBuilder
    private var videoDiagExtra: some View {
        if appState.voiceAnalysis != nil {
            Divider().background(Color.white.opacity(0.2))
            videoDiagVoiceBiometrics
        }
    }

    /// Raw voice measures, as plain numbers and nothing else: no stress, breath
    /// or hoarseness reading, because none of them is validated for
    /// phone-quality speech. They sit in one block that is collapsed until the
    /// user opens it, titled and annotated as not validated (the same texts as
    /// the technical-data block of InCallScreen's security sheet).
    @ViewBuilder
    private var videoDiagVoiceBiometrics: some View {
        if appState.voiceAnalysis != nil {
            DisclosureGroup(isExpanded: $showVoiceTechnicalData) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(VoiceTechnicalCopy.note)
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    videoDiagRow("HNR", videoDiagHnrText)
                    videoDiagRow("PITCH f0", videoDiagPitchText)
                }
                .padding(.top, 6)
            } label: {
                Text(VoiceTechnicalCopy.title)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(.gray)
            }
            .tint(.green)
        }
    }

    // The two rows of the technical block, built outside the @ViewBuilder like the helpers below: they follow
    // the validity flag of their own measurement (a dash while it is not a reading), and a `.nan` ternary
    // inside a ViewBuilder is a type-check-time risk on Xcode 26.4. The mapping is the one of the security
    // sheet (`InCallScreen.VoiceBiometrics`), and the formats are those of the specification
    // (docs/voice-analysis-spec.md, section 12): f0 and HNR are whole numbers rounded half away from zero.
    private var videoDiagHnrText: String {
        guard let result = appState.voiceAnalysis else { return VoiceGauges.noValue }
        return VoiceBiometricsFormat.hnr(InCallScreen.VoiceBiometrics(result).hnr)
    }

    private var videoDiagPitchText: String {
        guard let result = appState.voiceAnalysis else { return VoiceGauges.noValue }
        return VoiceBiometricsFormat.pitch(hz: InCallScreen.VoiceBiometrics(result).pitchHz)
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

    // MARK: - Derived state

    /// The ML-KEM session key of this call, or nil while the call only holds the transitional key it starts with
    /// (`callSasKeySource` is not `.mlKem` yet). The "PQC" chip and the "SESSIONE ML-KEM" row name ML-KEM, so they
    /// read this and not `callPqcSessionKey` directly.
    private var realSessionKey: Data? {
        CallSessionKeyShown.realKey(appState.callPqcSessionKey, source: appState.callSasKeySource)
    }

    // D11 fix — same bug as LiveInCallScreen.sasIdentityTag: commitTofuPinForDevice
    // pins under the composite "<peer>|<deviceId>" account whenever the server
    // stamped one, so a lookup with no deviceId checks the wrong account and
    // silently misses a pin that genuinely exists. Both call sites below now
    // pass appState.peerDeviceId(for:) — see that accessor's kdoc.
    private var sasVerified: Bool {
        // Nothing here claims a verification before this call's assurance verdict is in.
        guard SasCardPlacement.showsVerified(sasVerified: true, verdictKnown: appState.callAssuranceState != nil) else { return false }
        let words = appState.callSasWords
        guard !words.isEmpty, let peer = appState.callContactId else { return false }
        guard let pinned = PeerIdentityPinStore().pinnedKey(
            contactId: peer, deviceId: appState.callPinDeviceId(for: peer)
        ) else { return false }
        let fp = SasVerificationStore.fingerprint(forWords: words)
        // The words alone are not enough: they must still belong to the identity key the ceremony was performed
        // against. Same decision as the audio screen: a contact confirmed before for the key pinned now counts too,
        // unless this call raised an identity notice or is held.
        let tag = SasVerificationStore.identityTag(forPinnedKey: pinned)
        let store = SasVerificationStore.shared
        return SasCardPlacement.isConfirmedForThisCall(
            wordsConfirmed: store.isVerified(peerUserId: peer, currentFingerprint: fp, currentIdentityTag: tag),
            bindingAppliesToPinnedKey: store.hasVerifiedBinding(peerUserId: peer, currentIdentityTag: tag),
            identityAuthenticated: appState.callIdentityAuthenticated,
            identityNotice: appState.callIdentityUnauthenticatedChange
                || appState.callHandshakeSignatureInvalid
                || appState.callIdentityRotationAwaitingSas,
            awaitingConfirmation: appState.awaitingIdentityConfirmation)
    }

    private func confirmSas() {
        let words = appState.callSasWords
        // C-3 — a confirmation with no pinned identity to bind it to is exactly the
        // record this finding was about, so refuse to write one.
        guard !words.isEmpty, let peer = appState.callContactId else { return }
        // 2026-09-19 — adopt a rotated key this call presented BEFORE binding the confirmation to a pin.
        appState.adoptPendingIdentityRotationIfEligible()
        // SAS-PIN — see LiveInCallScreen.handleConfirmSas: an `identity_unresolved` call gets its signer key
        // pinned by this explicit confirmation.
        let adoption = appState.adoptSasConfirmedSignerKeyIfUnresolved()
        // A round of this call was not signed by its unresolved signer key: record and release nothing.
        guard adoption != .refused else { return }
        let adoptedSignerKey = adoption.adoptedKey
        guard let pinned = PeerIdentityPinStore().pinnedKey(
            contactId: peer, deviceId: appState.peerDeviceId(for: peer)
        ) ?? adoptedSignerKey else { return }
        let fp = SasVerificationStore.fingerprint(forWords: words)
        SasVerificationStore.shared.recordVerified(
            peerUserId: peer, fingerprint: fp,
            identityTag: SasVerificationStore.identityTag(forPinnedKey: pinned))
        // Release the media held for an unverified handshake identity (no-op when never engaged).
        appState.confirmIdentityAndReleaseMedia()
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
            // W-VIDPARITY round 2 — VideoCallView now reads
            // `@EnvironmentObject private var capabilityGate: CapabilityGate`
            // (entitlement gating for the camera button / invite banner);
            // same fixture every other preview in this app injects.
            .environmentObject(CapabilityGate.previewInstance())
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
