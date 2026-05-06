import SwiftUI

/// Severità semantica della snackbar. 1:1 port di
/// `qaudion-android-new/core/core-ui/.../components/Snackbars.kt`
/// (`QAudionSnackbarSeverity` enum).
public enum QAudionSnackbarSeverity {
    case info
    case warning
    case error
}

/// Modello del messaggio: ciò che l'host renderizza.
///
/// Note su `Equatable`: la closure `onAction` non è equatable. Per
/// matchare la promessa di `Identifiable`+`Equatable` confrontiamo solo
/// gli `id` (le UUID sono uniche). Due messaggi con stesso testo ma
/// `id` diversa restano distinti.
public struct QAudionSnackbarMessage: Identifiable {
    public let id: UUID
    public let text: String
    public let severity: QAudionSnackbarSeverity
    public let actionLabel: String?
    /// Callback opzionale eseguito quando l'utente preme `actionLabel`.
    /// Se `actionLabel == nil` viene ignorato. La snackbar si dismissa
    /// automaticamente dopo aver invocato l'azione.
    public let onAction: (() -> Void)?
    /// Durata in secondi prima dell'auto-dismiss. nil = permanente
    /// (richiede tap esplicito o azione caller).
    public let durationSeconds: Double?

    public init(text: String,
                severity: QAudionSnackbarSeverity = .info,
                actionLabel: String? = nil,
                onAction: (() -> Void)? = nil,
                durationSeconds: Double? = 4.0) {
        self.id = UUID()
        self.text = text
        self.severity = severity
        self.actionLabel = actionLabel
        self.onAction = onAction
        self.durationSeconds = durationSeconds
    }
}

extension QAudionSnackbarMessage: Equatable {
    public static func == (lhs: QAudionSnackbarMessage,
                           rhs: QAudionSnackbarMessage) -> Bool {
        lhs.id == rhs.id
    }
}

/// Coda + dispatcher per snackbar. Esposto come `@StateObject` o
/// passato giù via environment. Le viste consumer chiamano `show(...)`
/// e l'host (`QAudionSnackbarHost`) renderizza il messaggio in cima.
@MainActor
public final class QAudionSnackbarHostState: ObservableObject {
    @Published public private(set) var current: QAudionSnackbarMessage?
    public init() {}

    public func show(_ message: QAudionSnackbarMessage) {
        current = message
        if let dur = message.durationSeconds {
            let id = message.id
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(dur * 1_000_000_000))
                await MainActor.run {
                    // Solo dismiss se il messaggio attuale è ancora questo
                    // (evita di chiudere un messaggio nuovo arrivato nel
                    // frattempo).
                    guard let self else { return }
                    if self.current?.id == id { self.current = nil }
                }
            }
        }
    }

    public func dismiss() {
        current = nil
    }
}

/// Host overlay che renderizza la snackbar attuale dell'host state.
/// Da posizionare in cima alla gerarchia (es. ContentView ZStack), con
/// `.allowsHitTesting(true)` solo sull'area pill.
///
/// Visual: capsule 12pt corner, padding 14×10, surface gradient con
/// border 1pt accent @ 0.55α, label tinted al `accent`. Scivola dall'alto
/// con `.transition(.move(edge: .top).combined(with: .opacity))`.
public struct QAudionSnackbarHost: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    @ObservedObject var state: QAudionSnackbarHostState

    public init(state: QAudionSnackbarHostState) {
        self.state = state
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if let msg = state.current {
                pill(msg)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.current?.id)
        .allowsHitTesting(state.current != nil)
    }

    @ViewBuilder
    private func pill(_ msg: QAudionSnackbarMessage) -> some View {
        let accent = color(for: msg.severity)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon(for: msg.severity))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
            Text(msg.text)
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurface)
                .lineLimit(3)

            Spacer(minLength: 8)

            if let label = msg.actionLabel {
                Button(label) {
                    msg.onAction?()
                    state.dismiss()
                }
                .qaudionStyle(type.labelLarge)
                .foregroundStyle(accent)
                .buttonStyle(.plain)
            } else {
                Button {
                    state.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Chiudi")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surface.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.30), radius: 12, y: 4)
    }

    private func color(for severity: QAudionSnackbarSeverity) -> Color {
        switch severity {
        case .info:    return scheme.primary
        case .warning: return extras.warning
        case .error:   return extras.riskHigh
        }
    }

    private func icon(for severity: QAudionSnackbarSeverity) -> String {
        switch severity {
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }
}

// MARK: - Environment plumbing

private struct QAudionSnackbarHostKey: EnvironmentKey {
    static let defaultValue: QAudionSnackbarHostState? = nil
}

public extension EnvironmentValues {
    /// Snackbar host state — disponibile via `@Environment(\.qaudionSnackbar)`
    /// dentro qualsiasi view sotto `ContentView`. Caller chiamano
    /// `state?.show(...)` per pushare un messaggio.
    var qaudionSnackbar: QAudionSnackbarHostState? {
        get { self[QAudionSnackbarHostKey.self] }
        set { self[QAudionSnackbarHostKey.self] = newValue }
    }
}

#Preview {
    struct Demo: View {
        @StateObject var host = QAudionSnackbarHostState()
        var body: some View {
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                VStack(spacing: 12) {
                    Spacer()
                    Button("Info") {
                        host.show(.init(text: "Backup completato.",
                                        severity: .info))
                    }
                    Button("Warning") {
                        host.show(.init(text: "Voiceprint debole, riprova.",
                                        severity: .warning))
                    }
                    Button("Error") {
                        host.show(.init(text: "Connessione persa al server.",
                                        severity: .error,
                                        actionLabel: "Riprova"))
                    }
                    Spacer()
                }
                .foregroundStyle(.white)

                QAudionSnackbarHost(state: host)
            }
            .qAudionTheme(dark: true)
        }
    }
    return Demo()
}
