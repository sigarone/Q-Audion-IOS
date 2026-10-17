import SwiftUI

/// Age declaration and Terms acceptance box shown on the registration
/// screens. It is a self-declaration: the app does not verify age.
struct AgeDeclarationSection: View {
    @Binding var declared: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prima di creare l'account")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)

            Text("Q-Audion è riservato a chi ha almeno 18 anni. Non verifichiamo l'età: ci basiamo su quello che dichiari qui.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

            Button {
                declared.toggle()
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: declared ? "checkmark.square.fill" : "square")
                    Text("Dichiaro di avere almeno 18 anni e accetto i Termini e condizioni d'uso.")
                        .font(.caption)
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(declared ? .isSelected : [])

            HStack(spacing: 16) {
                Button("Termini e condizioni d'uso") {
                    LegalLinks.open(LegalLinks.appTerms())
                }
                Button("Informativa privacy") {
                    LegalLinks.open(LegalLinks.appPrivacy())
                }
            }
            .font(.caption.weight(.semibold))
        }
    }
}
