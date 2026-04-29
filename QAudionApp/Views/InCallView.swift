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
    // AppState is read by CallSecurityBadge and WaveformPanel via @EnvironmentObject,
    // so no explicit property needed here.

    private var vm: InCallViewModel { container.viewModel }

    var body: some View {
        ZStack {
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
        }
        // (7) SAS verification — placeholder sheet (full wiring deferred to follow-on task).
        .sheet(isPresented: .constant(vm.shouldShowSasPrompt)) {
            Text("Verifica SAS")
                .font(.headline)
                .padding()
                .presentationDetents([.medium])
        }
        // (6) Video PiP — hidden in audio-only A.4 scope; vm.showVideoPip drives this.
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
        HStack(spacing: 44) {
            InCallControlButton(
                systemName: vm.controls.isMuted ? "mic.slash.fill" : "mic.fill",
                label: vm.controls.isMuted ? "Unmute" : "Mute",
                isActive: vm.controls.isMuted,
                action: container.tapMute
            )

            InCallControlButton(
                systemName: vm.controls.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                label: "Speaker",
                isActive: vm.controls.isSpeakerOn,
                action: container.tapSpeaker
            )

            InCallControlButton(
                systemName: "pause.fill",
                label: vm.controls.isOnHold ? "Resume" : "Hold",
                isActive: vm.controls.isOnHold,
                action: container.tapHold
            )

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
        }
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
