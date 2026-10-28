import SwiftUI
import QAudionEngine

// MARK: - Pieces

/// A box with its text: the whole row is the tap target. Off at the start, always.
struct LegalCheckboxRow: View {
    @Binding var isOn: Bool
    let text: String
    let identifier: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .accessibilityHidden(true)
                Text(verbatim: text)
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// The published text of the Terms, as headings and paragraphs.
struct TermsDocumentBody: View {
    let markdown: String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(LegalMarkdown.blocks(from: markdown).enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .heading(let level):
                    Text(verbatim: block.text)
                        .font(level <= 1 ? .title3.weight(.bold) : .subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.top, level <= 2 ? 8 : 2)
                case .paragraph:
                    Text(Self.inline(block.text))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Emphasis and links only; the words are never changed. A text that does not parse is shown as it is.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// The full Terms in a sheet.
struct TermsDocumentSheet: View {
    let document: LegalTermsDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if document.lang != "it" {
                            Text(verbatim: LegalStrings.italianPrevails)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        TermsDocumentBody(markdown: document.bodyMarkdown)
                    }
                    .padding(16)
                    .qaudionReadableWidth()
                }
            }
            .navigationTitle(Text(verbatim: document.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// The specific-approval text in a sheet, behind the "Mostra" link.
struct SpecificApprovalSheet: View {
    let approval: LegalSpecificApproval
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    Text(verbatim: approval.text)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .qaudionReadableWidth()
                }
            }
            .navigationTitle(Text(verbatim: approval.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - The acceptance screen

/// One screen: the Terms and Privacy box, the specific-approval box with its "Mostra" link, and the emergency
/// notice as one small line. Both boxes start off and the continue button is on only when both are. The legal
/// text is the server's; the labels are the app's.
struct TermsAcceptanceFlowView: View {
    let fetch: LegalTermsFetch
    @Binding var draft: TermsAcceptanceDraft
    let isBusy: Bool
    let errorText: String?
    /// Back (leave the screen); nil hides the button.
    let onBackFromFirst: (() -> Void)?
    let onFinish: (TermsAcceptance) -> Void

    @State private var showingTerms = false
    @State private var showingSpecific = false

    private var document: LegalTermsDocument { fetch.document }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: document.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    if document.lang != "it" {
                        Text(verbatim: LegalStrings.italianPrevails)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    termsBox
                    specificBox
                    Text(verbatim: document.emergencyNotice)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                        .accessibilityIdentifier("terms-emergency-notice")
                    if let errorText {
                        Text(verbatim: errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .qaudionReadableWidth()
            }
            footer
        }
        .sheet(isPresented: $showingTerms) {
            TermsDocumentSheet(document: document)
        }
        .sheet(isPresented: $showingSpecific) {
            SpecificApprovalSheet(approval: document.specificApproval)
        }
    }

    private var termsBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            LegalCheckboxRow(isOn: $draft.termsAccepted, text: LegalStrings.termsCheckbox,
                             identifier: "terms-checkbox")
            HStack(spacing: 16) {
                Button {
                    showingTerms = true
                } label: {
                    Text(verbatim: LegalStrings.readTerms)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                .accessibilityIdentifier("terms-read")
                Link(destination: LegalLinks.appPrivacy()) {
                    Text(verbatim: LegalStrings.readPrivacy)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                .accessibilityIdentifier("terms-read-privacy")
            }
            .padding(.leading, 32)
        }
    }

    private var specificBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            LegalCheckboxRow(isOn: $draft.specificAccepted, text: LegalStrings.specificCheckbox,
                             identifier: "terms-specific-checkbox")
            Button {
                showingSpecific = true
            } label: {
                Text(verbatim: LegalStrings.showSpecific)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.blue)
            }
            .padding(.leading, 32)
            .accessibilityIdentifier("terms-specific-show")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let onBackFromFirst {
                Button {
                    onBackFromFirst()
                } label: {
                    Text("Indietro")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(.white)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.4), lineWidth: 1.2))
                }
                .disabled(isBusy)
                .accessibilityIdentifier("terms-back")
            }
            Button {
                if let acceptance = draft.acceptance(for: fetch) { onFinish(acceptance) }
            } label: {
                Text("Continua")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(draft.canContinue ? .black : .white.opacity(0.4))
                    .background(draft.canContinue ? Color.white : Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!draft.canContinue || isBusy)
            .accessibilityIdentifier("terms-continue")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Loader

/// Loads the document and runs the acceptance screen in front of a registration. `onAccepted` gets the acceptance to put in
/// the registration request; `onCancel` leaves without one.
struct TermsAcceptanceLoaderView: View {
    let api: LegalApi
    let onAccepted: (TermsAcceptance) -> Void
    let onCancel: () -> Void

    private enum LoadState {
        case loading
        case loaded(LegalTermsFetch)
        case failed
    }

    @State private var state: LoadState = .loading
    @State private var draft = TermsAcceptanceDraft()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch state {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(verbatim: LegalStrings.loading)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
            case .failed:
                VStack(spacing: 16) {
                    Text(verbatim: LegalStrings.loadFailed)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.85))
                    HStack(spacing: 12) {
                        Button("Annulla", action: onCancel)
                            .foregroundStyle(.white)
                        Button {
                            Task { await load() }
                        } label: {
                            Text(verbatim: LegalStrings.retry).fontWeight(.semibold)
                        }
                        .foregroundStyle(.white)
                    }
                }
                .padding(24)
            case .loaded(let fetch):
                TermsAcceptanceFlowView(
                    fetch: fetch, draft: $draft, isBusy: false, errorText: nil,
                    onBackFromFirst: onCancel, onFinish: onAccepted)
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private func load() async {
        state = .loading
        do {
            let fetch = try await api.fetchTerms(lang: LegalService.documentLanguage)
            state = .loaded(fetch)
        } catch {
            state = .failed
        }
    }
}

// MARK: - Blocking screen for an existing account

/// An existing account whose acceptance is missing or old. Same screen, a delete-account action on the same
/// screen, and the model takes the screen down by itself while a call is active or ringing.
struct TermsGateScreen: View {
    @ObservedObject var model: TermsGateModel
    @StateObject private var account: AccountSettingsContainer
    @State private var confirmDelete = false

    init(appState: AppState, model: TermsGateModel) {
        self.model = model
        _account = StateObject(wrappedValue: AccountSettingsContainer(appState: appState))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: LegalStrings.gateTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                    Text(verbatim: LegalStrings.gateMessage)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 24)

                if let fetch = model.fetch {
                    TermsAcceptanceFlowView(
                        fetch: fetch, draft: $model.draft, isBusy: model.isSubmitting || account.isLoading,
                        errorText: problemText, onBackFromFirst: nil,
                        onFinish: { _ in Task { await model.submit() } })
                }

                Button {
                    confirmDelete = true
                } label: {
                    Text("Elimina account")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.vertical, 10)
                }
                .disabled(model.isSubmitting || account.isLoading)
                .accessibilityIdentifier("terms-gate-delete-account")
                if let message = account.errorMessage {
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                }
                Spacer().frame(height: 12)
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "Eliminare definitivamente l'account?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Elimina account", role: .destructive) {
                account.deleteAccount()
            }
            Button("Annulla", role: .cancel) { }
        } message: {
            Text("Il tuo account, i contatti, le chat e le chiavi crittografiche verranno cancellati in modo permanente sia dal server che da questo dispositivo. Questa azione non può essere annullata.")
        }
    }

    private var problemText: String? {
        switch model.problem {
        case .submitFailed: return LegalStrings.submitFailed
        case .editionChanged: return LegalStrings.editionChanged
        case nil: return nil
        }
    }
}
