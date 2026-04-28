import SwiftUI
import QAudionEngine

@MainActor
final class ThreatReportContainer: ObservableObject {

    @Published private(set) var viewModel: ThreatReportViewModel
    @Published private(set) var isSubmitting: Bool = false
    @Published var errorMessage: String?
    @Published var didSubmitSuccessfully: Bool = false

    private let appState: AppState

    init(appState: AppState, initial: ThreatReportViewModel = .mock) {
        self.appState = appState
        self.viewModel = initial
    }

    // MARK: - Submit

    /// Called by ThreatReportView's onSubmit closure with the fully-populated
    /// view-model (including the user's free-form note from the form).
    /// Maps to SecurityApi.reportThreat(category:details:severity:) per §3.14 /
    /// W12.A Android-shape signature.
    func submit(_ submitted: ThreatReportViewModel) {
        guard let provider = makeProvider() else {
            errorMessage = "Not signed in"
            return
        }
        Task {
            await MainActor.run {
                self.isSubmitting = true
                self.errorMessage = nil
            }
            do {
                // Build the three string fields required by the server endpoint.
                // category  — snake_case raw value from ThreatKind enum (e.g. "deepfake_detected")
                // details   — auto-collected detail + user-typed note (newline-separated when both present)
                // severity  — lowercase raw value from Severity enum (e.g. "high")
                let category = submitted.threatKind.rawValue
                let details: String = {
                    if submitted.userTypedDetail.isEmpty {
                        return submitted.detail
                    } else {
                        return submitted.detail + "\n\n" + submitted.userTypedDetail
                    }
                }()
                let severity = submitted.severity.rawValue

                try await provider.securityApi.reportThreat(
                    category: category,
                    details: details,
                    severity: severity
                )
                await MainActor.run {
                    self.didSubmitSuccessfully = true
                    self.isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isSubmitting = false
                }
            }
        }
    }

    // MARK: - Provider

    private func makeProvider() -> BCryptoBackendProvider? {
        guard let token = appState.authService.loadToken() else { return nil }
        let config = BackendConfig(serverUrl: appState.serverUrl, accessToken: token)
        return BCryptoBackendProvider(config: config)
    }
}

// MARK: - ContainerView

struct ThreatReportContainerView: View {
    @ObservedObject var container: ThreatReportContainer
    var onDismiss: (() -> Void)?

    var body: some View {
        ZStack {
            ThreatReportView(
                viewModel: container.viewModel,
                onSubmit: { submitted in
                    container.submit(submitted)
                },
                onDismiss: { onDismiss?() }
            )

            if container.isSubmitting {
                Color.black.opacity(0.3).ignoresSafeArea()
                ProgressView("Submitting…")
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
            }

            if let err = container.errorMessage {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(err).font(.caption)
                    }
                    .padding()
                    .background(Color.red.opacity(0.85))
                    .foregroundStyle(.white)
                    .cornerRadius(8)
                    .padding(.bottom, 32)
                }
            }
        }
        .onChange(of: container.didSubmitSuccessfully) { _, success in
            if success {
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    onDismiss?()
                }
            }
        }
    }
}
