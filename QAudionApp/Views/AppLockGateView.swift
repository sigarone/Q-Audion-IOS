import SwiftUI

/// W441 — Full-screen lock overlay shown when AppLockService.isLocked = true.
/// Tapping "Sblocca" triggers biometric / passcode prompt.
/// Mirrors Android's AppLockGate composable.
struct AppLockGateView: View {
    @ObservedObject var lockService: AppLockService

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
            }
        }
        .onAppear {
            Task { await lockService.evaluatePolicy() }
        }
    }
}
