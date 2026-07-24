import SwiftUI
import QAudionEngine

// MARK: - InCallView

/// Full-screen in-call UI (audio-only, A.4 scope). Renders the seven §6.1 elements:
/// 1. Security badge (reuses CallSecurityBadge via @EnvironmentObject)
/// 2. Peer name + §5.1 fingerprint
/// 3. Call timer (mm:ss, driven by InCallViewModel.callDuration)
/// 4. TX / RX / Cipher waveforms (reuses WaveformPanel via @EnvironmentObject)
/// 5. Mute / Speaker / Hold / End-call controls
/// 6. Video PiP placeholder (hidden in A.4 audio-only scope)
/// 7. SAS verification prompt (sheet — wired stub; full flow in A.4 follow-on)
struct InCallView: View {
    @ObservedObject var container: InCallContainer
    // AppState is read by CallSecurityBadge and WaveformPanel via @EnvironmentObject;
    // we also read it directly for video-camera toggle.
    @EnvironmentObject private var appState: AppState

    private var vm: InCallViewModel { container.viewModel }

    /// W439: local camera-on state that mirrors appState.isVideoCall on appear
    /// and lets the user toggle the camera mid-call without waiting for the full
    /// isVideoCall publish cycle (setCamera doesn't write isVideoCall back).
    @State private var cameraOn: Bool = false

    /// 2026-05-03 — local dismiss flag for the SAS verification banner.
    /// Per user requirement: "sas verification deve essere una cosa
    /// non bloccante ma opzionale quando ho già instaurato la chiamata".
    /// The InCallViewModel.shouldShowSasPrompt drives whether the
    /// banner CAN be shown; this @State lets the user hide it for the
    /// remainder of the call without affecting the underlying VM flag
    /// (which is owned by the call-setup pipeline).
    @State private var sasBannerDismissed: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 24)

                // (1) Security badge — reuses existing CallSecurityBadge which reads AppState.
                CallSecurityBadge()
                    .padding(.horizontal, 32)

                // (2) Peer info
                peerInfo
                    .padding(.top, 20)

                // (3) Call timer
                Text(timerText)
                    .font(.system(.title2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 8)

                Spacer()

                // (4) TX / RX / Cipher waveforms (reuses WaveformPanel, which reads AppState).
                WaveformPanel()
                    .padding(.top, 8)

                Spacer()

                // (5) Call controls
                callControls
                    .padding(.bottom, 48)
            }

            // (7) SAS verification — NON-BLOCKING inline banner.
            //
            // 2026-05-03 — was a `.sheet(isPresented: .constant(...))`
            // with a placeholder `Text("Verifica SAS")` body. The
            // `.constant()` binding meant the sheet could never be
            // dismissed (read-only binding); the placeholder body was
            // an empty-looking square. Net effect — when iOS answered
            // an incoming call, the user saw a stuck "Verifica SAS"
            // sheet with no content + the End-call button hidden
            // behind it (user report 2026-05-03: "mi vine fuori
            // scritta verifica sas con un quadrato vuoto e anche se
            // lo metto giù non fa nulla").
            //
            // The user explicitly clarified: "sas verification deve
            // essere una cosa non bloccante ma opzionale quando ho
            // già instaurato la chiamata". So this is now a small
            // inline banner with a Dismiss "X". The audio + Hangup
            // continue to work the moment the call is active.
            if vm.shouldShowSasPrompt && !sasBannerDismissed {
                sasBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // (6) Video PiP — hidden in audio-only A.4 scope; vm.showVideoPip drives this.
        .onAppear { cameraOn = appState.isVideoCall }
    }

    // MARK: - SAS banner (non-blocking)

    private var sasBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.white.opacity(0.85))
            VStack(alignment: .leading, spacing: 2) {
                Text("Verifica SAS disponibile")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Apri il dettaglio chiamata per confrontare le 6 parole con il peer")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button {
                sasBannerDismissed = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chiudi banner SAS")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
    }

    // MARK: - Peer info

    private var peerInfo: some View {
        VStack(spacing: 4) {
            Text(vm.peer.displayName)
                .font(.title)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text(vm.peer.fingerprint)
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: - Timer

    private var timerText: String {
        let total = max(0, Int(vm.callDuration))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Background gradient (§6.1 security-state tinting)

    private var backgroundGradient: LinearGradient {
        switch vm.security {
        case .secure:
            return LinearGradient(
                colors: [Color(white: 0.08), Color(red: 0.0, green: 0.10, blue: 0.04)],
                startPoint: .top, endPoint: .bottom
            )
        case .verifying:
            return LinearGradient(
                colors: [Color(white: 0.08), Color(red: 0.12, green: 0.09, blue: 0.0)],
                startPoint: .top, endPoint: .bottom
            )
        case .insecureFallback:
            return LinearGradient(
                colors: [Color(white: 0.08), Color(red: 0.18, green: 0.04, blue: 0.04)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    // MARK: - Call controls (5)

    private var callControls: some View {
        // Each button claims equal horizontal space so the row always fits
        // within the screen width regardless of device size (iPhone SE 375pt
        // up to Pro Max 430pt). Fixed spacing of 44pt per button caused a
        // 476pt total on a 390pt screen — the End-call button was clipped
        // and the user could only tap a sliver of it.
        HStack(spacing: 0) {
            InCallControlButton(
                systemName: vm.controls.isMuted ? "mic.slash.fill" : "mic.fill",
                label: vm.controls.isMuted ? "Unmute" : "Mute",
                isActive: vm.controls.isMuted,
                action: container.tapMute
            )
            .frame(maxWidth: .infinity)

            InCallControlButton(
                systemName: vm.controls.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                label: "Speaker",
                isActive: vm.controls.isSpeakerOn,
                action: container.tapSpeaker
            )
            .frame(maxWidth: .infinity)

            InCallControlButton(
                systemName: "pause.fill",
                label: vm.controls.isOnHold ? "Resume" : "Hold",
                isActive: vm.controls.isOnHold,
                action: container.tapHold
            )
            .frame(maxWidth: .infinity)

            // W439: video toggle — always visible so users can upgrade an
            // audio call to video. cameraOn mirrors appState.isVideoCall on
            // appear and tracks local toggles; setCamera wires the pipeline.
            InCallControlButton(
                systemName: cameraOn ? "video.fill" : "video.slash.fill",
                label: cameraOn ? "Video On" : "Video",
                isActive: cameraOn,
                action: {
                    cameraOn.toggle()
                    // W-CAMSILENT (2026-07-24) — same fix as LiveInCallScreen's
                    // handleToggleCamera: `setCamera` only flips the local pipeline,
                    // leaving `localVideoPaused` stale and never telling the peer,
                    // so the far end kept believing our camera was live.
                    appState.videoSetCameraEnabled(cameraOn)
                }
            )
            .frame(maxWidth: .infinity)

            // End-call button — always red per InCallViewModel.Controls.endCallStyle.
            Button(action: container.tapEnd) {
                VStack(spacing: 6) {
                    Image(systemName: "phone.down.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(.red)
                        .clipShape(Circle())
                    Text("Termina")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - InCallControlButton

private struct InCallControlButton: View {
    let systemName: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.title2)
                    .foregroundStyle(isActive ? .black : .white)
                    .frame(width: 60, height: 60)
                    .background(isActive ? Color.white : Color.white.opacity(0.15))
                    .clipShape(Circle())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}
