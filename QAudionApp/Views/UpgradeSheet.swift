import SwiftUI
import QAudionEngine

/// Sheet shown when the user taps a feature that the account does not have
/// enabled. It states that the feature is not available for the account and
/// offers a single "Chiudi" button; there is nothing to enter or buy here.
///
/// Presented with `.sheet(isPresented:)` / `.sheet(item:)`; the sheet applies
/// its own `.presentationDetents`, so call sites need no extra configuration.
/// `capability` identifies which locked feature was tapped; the text is the
/// same neutral line for every capability.
@MainActor
struct UpgradeSheet: View {
    let capability: Capability

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(scheme.outline.opacity(0.35))
                .frame(width: 36, height: 4)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 16) {
                header
                Divider().background(scheme.outline.opacity(0.3))
                Text("Funzione non disponibile per il tuo account.")
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                closeButton
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(scheme.surface.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 20))
                .foregroundStyle(scheme.primary)
                .frame(width: 36, height: 36)
                .background(scheme.primary.opacity(0.15))
                .clipShape(Circle())
            Text("Funzione non disponibile")
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.onSurface)
            Spacer()
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Text("Chiudi")
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.onPrimary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(scheme.primary)
                )
        }
    }
}
