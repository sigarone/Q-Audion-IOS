import SwiftUI
import QAudionEngine

/// Italian + design-token reskin of the engine's `VoiceEnrollmentView`.
/// 1:1 visual + copy port of Android
/// `qaudion-android-new/feature/feature-auth/.../VoiceEnrollmentScreen.kt`.
///
/// Drives the same `VoiceEnrollmentContainer` (the App-layer wrapper
/// around the engine's audio capture pipeline) — only the presentation
/// layer is new. Engine's own `VoiceEnrollmentView` remains in place
/// for any caller that hasn't migrated yet (currently
/// `VoiceEnrollmentContainerView`).
///
/// Layout (top → bottom):
///   1. Top bar — back chevron + "Voice-as-Key" title.
///   2. Linear progress bar (`completedPromptsCount / totalPrompts`).
///   3. State badge — Italian copy per step:
///        idle/intro          → "Tocca Registra per iniziare."
///        promptShowing(p)    → centered prompt text
///        recording(p,s)      → spinner + "Campione X/N — parla adesso."
///        processing          → "Elaborazione del prototipo vocale…"
///        complete            → "Voice-as-Key attivo (id=…)."
///        error(msg)          → riskHigh banner + msg
///   4. Audio meter — bar that pulses to `viewModel.audioLevel` while
///      recording (otherwise hidden).
///   5. CTA primary — "Registra" / "…" / "Fatto" (varies by step).
///   6. CTA secondary — "Salta" (always available; honors `onSkip`).
struct VoiceEnrollmentScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss

    @StateObject private var container: VoiceEnrollmentContainer

    let onComplete: (String) -> Void
    let onSkip: () -> Void

    init(initial: VoiceEnrollmentViewModel = .mock,
         onComplete: @escaping (String) -> Void = { _ in },
         onSkip: @escaping () -> Void = {}) {
        _container = StateObject(wrappedValue: VoiceEnrollmentContainer(initial: initial))
        self.onComplete = onComplete
        self.onSkip = onSkip
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                topBar
                progressBar
                Spacer().frame(height: 8)
                stateBadge
                if isRecording {
                    audioMeter
                }
                Spacer()
                primaryCta
                skipButton
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: container.viewModel.step) { newStep in
            if case .complete(let id) = newStep {
                onComplete(id)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(scheme.onSurface)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Indietro")

            Text("Voice-as-Key")
                .qaudionStyle(type.titleLarge)
                .foregroundStyle(scheme.onSurface)
            Spacer(minLength: 8)
        }
        .frame(height: 56)
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: container.viewModel.progressFraction)
                .tint(scheme.primary)
            Text("\(container.viewModel.completedPromptsCount) di \(container.viewModel.totalPrompts) campioni")
                .qaudionStyle(type.labelSmall)
                .tracking(0.8)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
    }

    // MARK: - State badge

    @ViewBuilder
    private var stateBadge: some View {
        switch container.viewModel.step {
        case .introduction:
            heroBadge(
                icon: "waveform.badge.mic",
                title: "Registra la tua voce",
                description: "Leggi 3 brevi frasi (3 secondi ciascuna). Q-Audion userà il prototipo per riconoscerti durante le chiamate e bloccare i deepfake.",
                tint: extras.pqcAccent
            )
        case .promptShowing(let prompt):
            promptCard(prompt: prompt, recording: false)
        case .recording(let prompt, let secs):
            promptCard(prompt: prompt, recording: true, seconds: secs)
        case .processing:
            heroBadge(
                icon: "waveform",
                title: "Elaborazione del prototipo vocale…",
                description: "Stiamo creando il tuo voiceprint. Tieni il dispositivo fermo per qualche secondo.",
                tint: scheme.primary,
                showsSpinner: true
            )
        case .complete(let id):
            heroBadge(
                icon: "checkmark.seal.fill",
                title: "Voice-as-Key attivo",
                description: "Il tuo voiceprint è registrato (id=\(id.suffix(8))). Da ora le chiamate saranno verificate per voce.",
                tint: extras.success
            )
        case .error(let msg):
            errorBanner(msg)
        }
    }

    private func heroBadge(icon: String,
                           title: String,
                           description: String,
                           tint: Color,
                           showsSpinner: Bool = false) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Image(systemName: icon)
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(tint)
                if showsSpinner {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(tint)
                        .scaleEffect(1.1)
                        .padding(.top, 8)
                }
            }
            Text(title)
                .qaudionStyle(type.titleMedium)
                .foregroundStyle(scheme.onSurface)
                .multilineTextAlignment(.center)
            Text(description)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func promptCard(prompt: String, recording: Bool, seconds: Double = 0) -> some View {
        VStack(spacing: 14) {
            Text("Campione \(container.viewModel.currentPromptIndex + 1) / \(container.viewModel.totalPrompts)")
                .qaudionStyle(type.labelSmall)
                .tracking(1.2)
                .foregroundStyle(scheme.onSurfaceVariant)
            Text(prompt)
                .qaudionStyle(type.titleMedium)
                .foregroundStyle(scheme.onSurface)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if recording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(extras.riskHigh)
                        .frame(width: 8, height: 8)
                    Text(String(format: "REC · %.1f s", seconds))
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.2)
                        .foregroundStyle(extras.riskHigh)
                }
            } else {
                Text("Tocca Registra e leggi a voce normale.")
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(recording ? extras.riskHigh.opacity(0.6) : scheme.outline.opacity(0.3),
                        lineWidth: 1)
        )
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(extras.riskHigh)
            VStack(alignment: .leading, spacing: 4) {
                Text("Errore")
                    .qaudionStyle(type.titleSmall)
                    .foregroundStyle(extras.riskHigh)
                Text(msg)
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurface)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(extras.riskHigh.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(extras.riskHigh.opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: - Audio meter (recording only)

    private var audioMeter: some View {
        let level = max(0, min(1, container.viewModel.audioLevel))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(scheme.surfaceVariant.opacity(0.5))
                Capsule()
                    .fill(LinearGradient(
                        colors: [extras.success, extras.warning, extras.riskHigh],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, geo.size.width * level))
            }
        }
        .frame(height: 8)
    }

    // MARK: - CTAs

    @ViewBuilder
    private var primaryCta: some View {
        switch container.viewModel.step {
        case .introduction:
            primaryButton(label: "Inizia") { container.start() }
        case .promptShowing:
            primaryButton(label: "Registra") { container.startRecordingPrompt() }
        case .recording:
            primaryButton(label: "Stop") { container.stopAndAdvance() }
        case .processing:
            primaryButton(label: "Attendi…", disabled: true) {}
        case .complete:
            primaryButton(label: "Fatto") { dismiss() }
        case .error:
            primaryButton(label: "Riprova") { container.start() }
        }
    }

    private func primaryButton(label: String,
                               disabled: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .qaudionStyle(type.labelLarge)
                .tracking(0.8)
                .foregroundStyle(scheme.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(disabled ? scheme.surfaceVariant : scheme.primary)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var skipButton: some View {
        Button {
            container.cancel()
            onSkip()
            dismiss()
        } label: {
            Text("Salta per ora")
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var isRecording: Bool {
        if case .recording = container.viewModel.step { return true }
        return false
    }
}

#Preview {
    NavigationStack {
        VoiceEnrollmentScreen()
    }
    .qAudionTheme(dark: true)
}
