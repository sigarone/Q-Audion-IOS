import SwiftUI

/// W441 — Full-screen lock overlay shown when AppLockService.isLocked = true.
/// Tapping "Sblocca" triggers biometric / passcode prompt.
/// Mirrors Android's AppLockGate composable.
///
/// Feature A ("Voice-as-Key") — ADDITIVE voice-unlock path. The "Sblocca"
/// (Face ID/passcode) button above is ALWAYS present, unchanged, and is
/// still the only path on a device with no enrolled voiceprint. The
/// "Sblocca con la voce" button below renders only when
/// `VoiceUnlockController.isAvailable` — i.e. Feature A enrollment has
/// actually completed at least once — and only ever unlocks via
/// `AppLockService.unlockViaVoice()` after a genuine `.passed` verdict.
struct AppLockGateView: View {
    @ObservedObject var lockService: AppLockService
    @StateObject private var voiceUnlock = VoiceUnlockController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 32) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))

                VStack(spacing: 8) {
                    Text("Q-Audion")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)
                    Text("App bloccata per sicurezza")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }

                Button {
                    Task { await lockService.evaluatePolicy() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "faceid")
                        Text("Sblocca")
                            .fontWeight(.semibold)
                    }
                    .font(.headline)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 14)
                    .background(Color.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                if voiceUnlock.isAvailable {
                    voiceUnlockControl
                }
            }
        }
        .onAppear {
            Task { await lockService.evaluatePolicy() }
        }
        .onDisappear {
            voiceUnlock.cancel()
        }
    }

    // MARK: - Feature A voice-unlock control

    @ViewBuilder
    private var voiceUnlockControl: some View {
        switch voiceUnlock.state {
        case .idle, .unavailable, .error:
            Button {
                voiceUnlock.start { lockService.unlockViaVoice() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                    Text("Sblocca con la voce")
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        case .listening(let progress):
            VStack(spacing: 8) {
                ProgressView(value: Double(progress))
                    .tint(.white)
                    .frame(width: 140)
                Text("In ascolto…")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .passed:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text("Voce riconosciuta")
            }
            .font(.subheadline)
            .foregroundStyle(.green)
        case .failed:
            VStack(spacing: 6) {
                Text("Voce non riconosciuta")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Button("Riprova") {
                    voiceUnlock.start { lockService.unlockViaVoice() }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
            }
        }
    }
}
