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

    @State private var isMuted = false
    @State private var isCameraOn = true
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
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .animation(.easeInOut(duration: 0.25), value: showSas)
        .animation(.easeInOut(duration: 0.2), value: showDiagnostics)
        .animation(.easeInOut(duration: 0.25), value: appState.peerScreenShareActive)
        .statusBarHidden(!showControls)
        .onAppear {
            ScreenshotLockService.lock()
            resolveDisplayName()
        }
        .onDisappear {
            ScreenshotLockService.unlock()
        }
        .onChange(of: appState.callContactId) { _ in
            resolveDisplayName()
        }
    }

    // MARK: - Remote video

    @ViewBuilder
    private var remoteVideoLayer: some View {
        if let pipeline = appState.videoPipeline {
            // W562 — fill the whole screen; the AVSampleBufferDisplayLayer's
            // own .resizeAspect already letterboxes the video keeping its
            // aspect ratio. The previous SwiftUI .aspectRatio(.fit) on a UIView
            // with NO intrinsic content size shrank the view, so the layer then
            // letterboxed inside an already-undersized box → a huge black
            // border ("enorme cornice nera"). A single aspect stage (the layer)
            // is correct now that the encoder emits the right portrait dims.
            RemoteVideoDisplay(pipeline: pipeline)
                .ignoresSafeArea()
        } else {
            #if canImport(WebRTC)
            if let track = appState.remoteWebRtcVideoTrack as? RTCVideoTrack {
                // RTCMTLVideoView already applies .scaleAspectFit internally —
                // same single-aspect-stage rule as above.
                WebRTCRemoteVideoView(track: track)
                    .ignoresSafeArea()
            } else {
                remoteVideoFallback
            }
            #else
            remoteVideoFallback
            #endif
        }
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

            CallSecurityBadge()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
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

    // MARK: - Bottom controls

    private var bottomControls: some View {
        HStack(spacing: 24) {
            videoButton(icon: "camera.rotate.fill", label: "Inverti") {
                appState.videoFlipCamera()
            }
            videoButton(
                icon: isCameraOn ? "video.fill" : "video.slash.fill",
                label: isCameraOn ? "Cam ON" : "Cam OFF",
                isActive: !isCameraOn
            ) {
                isCameraOn.toggle()
                appState.videoSetCameraEnabled(isCameraOn)
            }
            videoButton(
                icon: isMuted ? "mic.slash.fill" : "mic.fill",
                label: isMuted ? "Riattiva" : "Muto",
                isActive: isMuted
            ) {
                isMuted.toggle()
                appState.setMuted(isMuted)
            }
            videoButton(icon: "phone.down.fill", label: "Termina", isEndCall: true) {
                appState.endCall()
            }
            videoButton(
                icon: isSpeaker ? "speaker.wave.3.fill" : "speaker.fill",
                label: "Altoparlante",
                isActive: isSpeaker
            ) {
                isSpeaker.toggle()
                appState.setSpeaker(isSpeaker)
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
            }
            Divider().background(Color.white.opacity(0.2))
            videoDiagTransport
            videoDiagFrameCounters
            videoDiagSessionKey
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.35), lineWidth: 1))
    }

    @ViewBuilder
    private var videoDiagTransport: some View {
        let codec = appState.videoCodecLabel
        let path = codec + " · AES-256-GCM"
        videoDiagRow("CODEC / CIFRA", path)
        videoDiagRow("AUDIO TX",  appState.callService.framesEncryptedTx.description)
        videoDiagRow("AUDIO RX",  appState.callService.framesDecryptedRx.description)
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
        let fp = SasVerificationStore.fingerprint(forWords: words)
        return SasVerificationStore.shared.isVerified(peerUserId: peer, currentFingerprint: fp)
    }

    private func confirmSas() {
        let words = appState.callSasWords
        guard !words.isEmpty, let peer = appState.callContactId else { return }
        let fp = SasVerificationStore.fingerprint(forWords: words)
        SasVerificationStore.shared.recordVerified(peerUserId: peer, fingerprint: fp)
    }

    private func resolveDisplayName() {
        guard let id = appState.callContactId else { peerDisplayName = ""; return }
        let contacts = contactsStore.load()
        if let match = contacts.first(where: { $0.userId == id }) {
            peerDisplayName = match.displayName
        } else {
            // Priority: incomingCallerName (resolved to "Int. 112" by
            // call_incoming handler) → truncated UUID. Never show the full
            // 36-char UUID on the video call screen.
            let resolved = appState.incomingCallerName
            if !resolved.isEmpty {
                peerDisplayName = resolved
            } else if id.count > 12 {
                peerDisplayName = String(id.prefix(8)) + "…" + String(id.suffix(4))
            } else {
                peerDisplayName = id
            }
        }
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
