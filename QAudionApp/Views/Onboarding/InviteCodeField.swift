import SwiftUI
import QAudionEngine

/// "Codice invito" input shared by the registration screens
/// (`PhoneEntryScreen` in register mode and `ExtensionOnlyRegisterScreen`):
/// label, text field with live code formatting (uppercase, dashes, length cap
/// via `InviteCodeInput.format`) and the help line below it. Validity and the
/// value sent to the server live in `InviteCodeInput`, not here.
struct InviteCodeField: View {
    @Binding var code: String
    /// Red outline: the code is complete but its checksum does not match.
    var isInvalid: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Codice invito")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
            TextField("Codice invito", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityIdentifier("register-invite-code-field")
                .onChange(of: code) { newValue in
                    let formatted = InviteCodeInput.format(newValue)
                    if formatted != code { code = formatted }
                }
                .foregroundStyle(.white)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isInvalid ? Color.red : .white.opacity(0.3), lineWidth: 1.2)
                )
            Text("Il codice invito ti viene dato da chi gestisce Q-Audion o dalla tua organizzazione.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}
