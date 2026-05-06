import SwiftUI

/// Full-bleed loading placeholder. 1:1 port di
/// `qaudion-android-new/core/core-ui/.../components/LoadingState.kt`.
///
/// Layout: spinner circular + label opzionale, centrato sullo screen.
/// Usato come stato transitorio quando una schermata è in attesa di
/// dati (load-from-server, decrypt backup, fetch contacts, ecc.).
///
/// API:
///   - `message`: stringa opzionale sotto lo spinner. Default `nil`
///     mostra solo lo spinner.
///   - `tint`:    colore dello spinner. Default `scheme.primary`.
struct QAudionLoadingState: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let message: String?
    let tint: Color?

    init(message: String? = nil, tint: Color? = nil) {
        self.message = message
        self.tint = tint
    }

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(tint ?? scheme.primary)
            if let message {
                Text(message)
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(scheme.background)
    }
}

#Preview {
    QAudionLoadingState(message: "Stabilisco un canale sicuro…")
        .qAudionTheme(dark: true)
}
