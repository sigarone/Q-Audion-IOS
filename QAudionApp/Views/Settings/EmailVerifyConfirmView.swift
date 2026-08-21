import SwiftUI
import QAudionEngine

/// Reached from the emailed `verify-landing` link's Universal Link
/// (`AppState.handleIncomingUniversalLink`, `QAudion.entitlements`'
/// `associated-domains`). Mirrors Android's `EmailVerifyConfirmScreen` —
/// email verification always redeems against the ALREADY-authenticated
/// session, so this simply confirms the token on appear and shows the
/// result.
enum EmailVerifyConfirmState {
    case confirming
    case success
    case failed(String)
}

struct EmailVerifyConfirmView: View {
    let token: String
    let onDone: () -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(\.qaudionScheme) private var scheme
    @State private var state: EmailVerifyConfirmState = .confirming

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                switch state {
                case .confirming:
                    ProgressView()
                    Text("Verifica dell'email in corso…")
                        .font(.body)
                        .foregroundStyle(scheme.onSurfaceVariant)
                case .success:
                    Text("Email verificata")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(scheme.primary)
                    doneButton(label: "Continua")
                case .failed(let message):
                    Text("Verifica non riuscita")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                    doneButton(label: "Chiudi")
                }
            }
            .padding(24)
        }
        .task { await confirm() }
    }

    private func doneButton(label: String) -> some View {
        Button(action: onDone) {
            Text(label)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(scheme.primary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    private func confirm() async {
        guard token.isEmpty == false else {
            state = .failed("Link non valido.")
            return
        }
        guard let provider = appState.liveProvider else {
            state = .failed("Accedi all'app con l'account che ha richiesto la verifica, poi riapri il link.")
            return
        }
        do {
            let result = try await provider.accountApi.confirmEmailVerification(token: token)
            state = result.verified ? .success : .failed("Verifica non riuscita.")
        } catch {
            state = .failed("Link scaduto o già usato.")
        }
    }
}
