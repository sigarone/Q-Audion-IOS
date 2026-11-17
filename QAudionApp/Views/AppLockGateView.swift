import LocalAuthentication
import SwiftUI

/// W441 — Full-screen lock overlay shown when AppLockService.isLocked = true.
/// Tapping "Sblocca" triggers biometric / passcode prompt: the lock opens only through the
/// system authentication (Face ID, Touch ID or the device passcode).
/// Mirrors Android's AppLockGate composable.
struct AppLockGateView: View {
    @ObservedObject var lockService: AppLockService

    /// Simbolo del pulsante di sblocco secondo la biometria disponibile:
    /// Face ID o Touch ID se il dispositivo li ha, altrimenti un lucchetto.
    private var unlockSymbol: String {
        let ctx = LAContext()
        // biometryType è valorizzato solo dopo canEvaluatePolicy.
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.open.fill"
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 32) {
                Image(systemName: "lock.fill")
                    .qaudionScaledFont(size: 64, weight: .light, family: .display)
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
                        Image(systemName: unlockSymbol)
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
            }
        }
        .onAppear {
            Task { await lockService.evaluatePolicy() }
        }
    }
}
