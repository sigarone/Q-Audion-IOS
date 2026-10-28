import SwiftUI
import QAudionEngine

/// Age declaration shown on every screen that creates an account: a box stating that the person is at least
/// `AgeDeclaration.minimumAge`, with links to the Terms and to the Privacy Policy. The acceptance of the Terms is not
/// this box: it comes right after, on a screen of its own (`TermsAcceptanceLoaderView`). The screen keeps its submit
/// button off until the box is ticked, and sends the declaration to the server only when it is.
/// Nothing is verified here: the declaration is what the person states.
struct AgeDeclarationSection: View {
    @Binding var declared: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prima di creare l'account")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            Text("Q-Audion è riservato a chi ha almeno \(AgeDeclaration.minimumAge) anni. Non verifichiamo l'età: ci basiamo su quello che dichiari qui.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))

            Button {
                declared.toggle()
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: declared ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .accessibilityHidden(true)
                    Text("Dichiaro di avere almeno \(AgeDeclaration.minimumAge) anni.")
                        .font(.footnote)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(declared ? .isSelected : [])
            .accessibilityIdentifier("age-declaration-checkbox")

            VStack(alignment: .leading, spacing: 8) {
                Link(destination: LegalLinks.appTerms()) {
                    Text("Termini e Condizioni d'Uso")
                }
                Link(destination: LegalLinks.appPrivacy()) {
                    Text("Informativa sulla Privacy")
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.blue)
        }
    }
}
