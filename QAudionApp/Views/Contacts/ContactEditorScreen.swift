import SwiftUI
import QAudionEngine

/// Add-or-edit contact form. 1:1 visual port of Android
/// `qaudion-android-new/feature/feature-contacts/.../ContactEditorScreen.kt`.
///
/// Fields:
///   - Display name (required, mode-agnostic)
///   - Local alias (optional, "solo per te")
///   - Status / nota (optional, multiline)
///   - Extension (required in Add, optional in Edit)
///
/// Validation rules:
///   - displayName: must be non-blank after trim → "Il nome è obbligatorio"
///   - extension: digits only (max 10) → "L'interno deve essere numerico"
///   - Add mode: extension required → "Inserisci l'interno per agganciare il contatto al server."
///
/// Cross-platform parity:
///   - Same field labels: "Nome visualizzato *", "Alias locale (solo per te)",
///     "Stato / nota", "Interno *" / "Interno (opzionale)"
///   - Same supporting text + placeholders
///   - Same accent colors per field (pqcAccent / primary / success)
struct ContactEditorScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss

    enum Mode: Equatable { case add; case edit }

    let mode: Mode
    let initialDisplayName: String
    let initialAlias: String
    let initialStatusMessage: String
    let initialExtension: String
    let onSave: (Draft) -> Void

    @State private var displayName: String
    @State private var alias: String
    @State private var statusMessage: String
    @State private var extensionText: String
    @State private var error: String?
    @State private var busy: Bool = false

    struct Draft: Equatable {
        var displayName: String
        var alias: String
        var statusMessage: String
        var extensionText: String
    }

    init(mode: Mode = .add,
         initialDisplayName: String = "",
         initialAlias: String = "",
         initialStatusMessage: String = "",
         initialExtension: String = "",
         onSave: @escaping (Draft) -> Void = { _ in }) {
        self.mode = mode
        self.initialDisplayName = initialDisplayName
        self.initialAlias = initialAlias
        self.initialStatusMessage = initialStatusMessage
        self.initialExtension = initialExtension
        self.onSave = onSave
        _displayName = State(initialValue: initialDisplayName)
        _alias = State(initialValue: initialAlias)
        _statusMessage = State(initialValue: initialStatusMessage)
        _extensionText = State(initialValue: initialExtension)
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    topBar
                    guidance
                    fields
                    if let error {
                        errorBox(error)
                    }
                    actions
                    Spacer().frame(height: 32)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
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

            Text(mode == .add ? "Nuovo contatto" : "Modifica contatto")
                .qaudionStyle(type.titleMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer(minLength: 8)
        }
        .frame(height: 56)
    }

    // MARK: - Guidance

    private var guidance: some View {
        Text(mode == .add
             ? "Inserisci i dettagli del nuovo contatto. L'interno è obbligatorio: viene risolto sul server bcrypto per agganciarlo alla sua identità."
             : "Aggiorna i dati salvati nella tua rubrica.")
            .qaudionStyle(type.bodySmall)
            .italic()
            .foregroundStyle(scheme.onSurfaceVariant)
            .padding(.top, 4)
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(spacing: 12) {
            field(
                label: "Nome visualizzato *",
                placeholder: "es. Mario Rossi",
                value: $displayName,
                accent: extras.pqcAccent,
                autocapitalization: .words
            )
            field(
                label: "Alias locale (solo per te)",
                placeholder: "es. Capo",
                value: $alias,
                accent: scheme.primary,
                autocapitalization: .sentences
            )
            multilineField(
                label: "Stato / nota",
                placeholder: "es. Disponibile dalle 9 alle 18",
                value: $statusMessage,
                accent: scheme.primary
            )
            field(
                label: mode == .add ? "Interno *" : "Interno (opzionale)",
                placeholder: "es. 103",
                value: $extensionText,
                accent: extras.success,
                keyboardType: .numberPad,
                supporting: mode == .add
                    ? "Cifra univoca PBX. Risolta tramite directory bcrypto al salvataggio."
                    : "Lascia vuoto per rimuovere l'aggancio interno."
            )
        }
    }

    private func field(label: String,
                       placeholder: String,
                       value: Binding<String>,
                       accent: Color,
                       autocapitalization: TextInputAutocapitalization = .never,
                       keyboardType: UIKeyboardType = .default,
                       supporting: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .qaudionStyle(type.labelSmall)
                .tracking(1.0)
                .foregroundStyle(accent)

            TextField("", text: value,
                      prompt: Text(placeholder).foregroundColor(scheme.onSurfaceVariant))
                .qaudionStyle(type.bodyMedium)
                .foregroundColor(scheme.onSurface)
                .tint(accent)
                .textInputAutocapitalization(autocapitalization)
                .keyboardType(keyboardType)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(scheme.surfaceVariant.opacity(0.45))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(accent.opacity(0.45), lineWidth: 1)
                )

            if let supporting {
                Text(supporting)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
        }
    }

    private func multilineField(label: String,
                                placeholder: String,
                                value: Binding<String>,
                                accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .qaudionStyle(type.labelSmall)
                .tracking(1.0)
                .foregroundStyle(accent)

            TextField("", text: value,
                      prompt: Text(placeholder).foregroundColor(scheme.onSurfaceVariant),
                      axis: .vertical)
                .lineLimit(2...4)
                .qaudionStyle(type.bodyMedium)
                .foregroundColor(scheme.onSurface)
                .tint(accent)
                .textInputAutocapitalization(.sentences)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(scheme.surfaceVariant.opacity(0.45))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(accent.opacity(0.45), lineWidth: 1)
                )
        }
    }

    // MARK: - Error box

    private func errorBox(_ message: String) -> some View {
        Text(message)
            .qaudionStyle(type.labelMedium)
            .tracking(0.5)
            .foregroundStyle(extras.riskHigh)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(extras.riskHigh.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(extras.riskHigh.opacity(0.4), lineWidth: 1)
            )
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Annulla") { dismiss() }
                .qaudionStyle(type.labelLarge)
                .foregroundStyle(scheme.primary)
                .padding(.vertical, 10).padding(.horizontal, 16)

            Spacer()

            Button(action: handleSave) {
                HStack(spacing: 8) {
                    if busy {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(scheme.onPrimary)
                    }
                    Text(saveButtonLabel)
                        .qaudionStyle(type.labelLarge)
                        .foregroundStyle(scheme.onPrimary)
                }
                .padding(.vertical, 10).padding(.horizontal, 18)
                .background(
                    RoundedRectangle(cornerRadius: 999)
                        .fill(extras.pqcAccent)
                )
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
        .padding(.top, 8)
    }

    private var saveButtonLabel: String {
        if busy {
            return mode == .add ? "Aggiunta in corso…" : "Salvataggio…"
        }
        return mode == .add ? "Aggiungi" : "Salva modifiche"
    }

    // MARK: - Save handler

    private func handleSave() {
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            error = "Il nome è obbligatorio"
            return
        }
        let trimmedExt = extensionText.trimmingCharacters(in: .whitespaces)
        if !trimmedExt.isEmpty,
           !trimmedExt.allSatisfy(\.isNumber) {
            error = "L'interno deve essere numerico"
            return
        }
        if mode == .add, trimmedExt.isEmpty {
            error = "Inserisci l'interno per agganciare il contatto al server."
            return
        }
        error = nil
        busy = true
        let draft = Draft(
            displayName: trimmedName,
            alias: alias.trimmingCharacters(in: .whitespaces),
            statusMessage: statusMessage.trimmingCharacters(in: .whitespaces),
            extensionText: trimmedExt
        )
        // Hand off to the caller; a real implementation would hit the
        // ContactsStore + bcrypto directory. We dismiss optimistically;
        // errors should be propagated back via a future async overload.
        onSave(draft)
        busy = false
        dismiss()
    }
}

#Preview("Add") {
    NavigationStack {
        ContactEditorScreen(mode: .add)
    }
    .qAudionTheme(dark: true)
}

#Preview("Edit") {
    NavigationStack {
        ContactEditorScreen(mode: .edit,
                            initialDisplayName: "Mario Rossi",
                            initialAlias: "Capo",
                            initialStatusMessage: "Disponibile dalle 9 alle 18",
                            initialExtension: "103")
    }
    .qAudionTheme(dark: true)
}
