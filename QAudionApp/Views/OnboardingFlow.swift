import SwiftUI
import QAudionEngine

@MainActor
final class OnboardingFlowContainer: ObservableObject {
    @Published var viewModel: OnboardingFlowViewModel = .mock

    func transition(to step: OnboardingFlowViewModel.Step) {
        viewModel = viewModel.advancing(to: step)
    }

    func skipRecovery() {
        viewModel = viewModel.markingSkipped(recovery: true).advancing(to: .voiceEnrollment)
    }

    func skipVoice() {
        viewModel = viewModel.markingSkipped(voice: true).advancing(to: .done)
    }
}

struct OnboardingFlow: View {
    @StateObject private var container = OnboardingFlowContainer()
    @EnvironmentObject var appState: AppState
    var onFinish: () -> Void

    var body: some View {
        NavigationStack {
            switch container.viewModel.step {
            case .welcome:
                welcomeView
            case .authChoice:
                authChoiceView
            case .register:
                RegisterView()
                    .toolbar { skipToolbar(to: .recoverySetup) }
            case .login:
                LoginView()
                    .toolbar { skipToolbar(to: .recoverySetup) }
            case .recoverySetup:
                recoverySetupView
            case .voiceEnrollment:
                voiceEnrollmentView
            case .done:
                doneView
            }
        }
        .interactiveDismissDisabled(true)
    }

    private var welcomeView: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 96))
                .foregroundStyle(.blue.gradient)
            VStack(spacing: 12) {
                Text("Q-Audion")
                    .font(.largeTitle.bold())
                Text("Post-quantum encrypted voice + chat")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 16) {
                feature(icon: "lock.shield", title: "Secure", desc: "ML-KEM-1024 + X25519 hybrid encryption — quantum-safe today.")
                feature(icon: "mic.badge.xmark", title: "Anti-Deepfake", desc: "ONNX-based voiceprint detection during every call.")
                feature(icon: "person.3.fill", title: "Cross-platform", desc: "Talk to friends on Android, Desktop, or iPhone.")
            }
            .padding(.horizontal)
            Spacer()
            Button("Get started") { container.transition(to: .authChoice) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
        }
        .padding(.vertical)
    }

    private var authChoiceView: some View {
        VStack(spacing: 32) {
            Spacer()
            Text("Welcome").font(.largeTitle.bold())
            Text("Create a new account or sign in to an existing one.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
            Spacer()
            VStack(spacing: 16) {
                Button {
                    container.transition(to: .register)
                } label: {
                    Label("Create new account", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    container.transition(to: .login)
                } label: {
                    Label("Sign in to existing account", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal)
            Spacer()
        }
        .navigationTitle("Get Started")
    }

    private var recoverySetupView: some View {
        // Wire to W9.B RecoverySeedContainerView. The host struct below owns
        // the RecoverySeedContainer as @StateObject so its state survives
        // OnboardingFlow's body re-runs (a plain inline init would create a
        // fresh container on every render and lose the user's mnemonic
        // setup progress). The container's onDismiss closure fires once
        // recoverySetup() returns success — at which point we advance the
        // onboarding flow to voice enrollment. Skip toolbar still bypasses
        // the whole step for users who decline.
        OnboardingRecoverySeedHost(
            appState: appState,
            onContinue: { container.transition(to: .voiceEnrollment) }
        )
        .toolbar {
            if container.viewModel.canSkipRecovery {
                ToolbarItem(placement: .primaryAction) {
                    Button("Skip", role: .destructive) { container.skipRecovery() }
                }
            }
        }
        .navigationTitle("Recovery Phrase")
    }

    private var voiceEnrollmentView: some View {
        // Wire to W11.D VoiceEnrollmentContainerView. The onComplete closure
        // fires when the 5-prompt enrollment finishes successfully, carrying
        // the enrollment id (currently unused by OnboardingFlow but available
        // for future backend round-trips). onCancel falls through to the Skip
        // toolbar path.
        VoiceEnrollmentContainerView(
            onComplete: { _ in container.transition(to: .done) },
            onCancel: { container.skipVoice() }
        )
        .toolbar {
            if container.viewModel.canSkipVoice {
                ToolbarItem(placement: .primaryAction) {
                    Button("Skip") { container.skipVoice() }
                }
            }
        }
        .navigationTitle("Voice Authentication")
    }

    private var doneView: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 96))
                .foregroundStyle(.green.gradient)
            Text("All set!")
                .font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 8) {
                if container.viewModel.skippedRecovery {
                    Label("Set up recovery phrase later in Settings → Security", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if container.viewModel.skippedVoice {
                    Label("Enable voice authentication later in Settings → Security", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .padding(.horizontal)
            Spacer()
            Button("Open Q-Audion") { onFinish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
        }
        .padding(.vertical)
    }

    @ToolbarContentBuilder
    private func skipToolbar(to step: OnboardingFlowViewModel.Step) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Continue") { container.transition(to: step) }
        }
    }

    private func feature(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.title2).foregroundStyle(.blue).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(desc).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Onboarding RecoverySeed host

/// Owns a `RecoverySeedContainer` as `@StateObject` so its mnemonic /
/// verification state survives the parent `OnboardingFlow`'s body re-runs.
/// Without this wrapper, instantiating `RecoverySeedContainer(...)` inline
/// inside `OnboardingFlow.recoverySetupView` would create a fresh container
/// every time the parent view re-rendered, throwing away the displayed
/// mnemonic and the in-progress confirmation entry.
private struct OnboardingRecoverySeedHost: View {
    @StateObject var container: RecoverySeedContainer

    init(appState: AppState, onContinue: @escaping () -> Void) {
        _container = StateObject(wrappedValue: RecoverySeedContainer(
            mode: .setup,
            appState: appState,
            onDismiss: onContinue
        ))
    }

    var body: some View {
        RecoverySeedContainerView(container: container)
    }
}

#Preview {
    OnboardingFlow(onFinish: { })
        .environmentObject(AppState())
}
