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

// MARK: - The three steps

/// Deviations, then terms plus the professional question, then the six groups. Every box starts off, and the
/// continue button is on only when the boxes of the step are. The legal text is the server's; the labels are the app's.
struct TermsAcceptanceFlowView: View {
    let fetch: LegalTermsFetch
    @Binding var draft: TermsAcceptanceDraft
    let isBusy: Bool
    let errorText: String?
    /// Back from the first step (leave the flow); nil hides the button there.
    let onBackFromFirst: (() -> Void)?
    let onFinish: (TermsAcceptance) -> Void

    @State private var showingTerms = false
    @State private var expandedGroups: Set<String> = []

    private var document: LegalTermsDocument { fetch.document }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch draft.step {
                    case .deviations: deviationsStep
                    case .terms: termsStep
                    case .groups: groupsStep
                    }
                    if let errorText {
                        Text(verbatim: errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .qaudionReadableWidth()
                .id(draft.step)
            }
            footer
        }
        .sheet(isPresented: $showingTerms) {
            TermsDocumentSheet(document: document)
        }
    }

    // MARK: header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: LegalStrings.progress(draft.step.rawValue + 1, of: TermsAcceptanceDraft.Step.allCases.count))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            if document.lang != "it" {
                Text(verbatim: LegalStrings.italianPrevails)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if draft.step != .deviations || onBackFromFirst != nil {
                Button {
                    if !draft.back() { onBackFromFirst?() }
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
                if draft.isLastStep {
                    if let acceptance = draft.acceptance(for: fetch) { onFinish(acceptance) }
                } else {
                    draft.advance(document: document)
                }
            } label: {
                Text(verbatim: draft.isLastStep ? LegalStrings.acceptAndContinue : String(localized: "Continua"))
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(canContinue ? .black : .white.opacity(0.4))
                    .background(canContinue ? Color.white : Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!canContinue || isBusy)
            .accessibilityIdentifier("terms-continue")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var canContinue: Bool { draft.canContinue(document: document) }

    // MARK: step 1

    private var deviationsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: document.deviations.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            Text(verbatim: document.deviations.text)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
            LegalCheckboxRow(isOn: $draft.deviationsAccepted, text: LegalStrings.deviationsCheckbox,
                             identifier: "terms-deviations-checkbox")
        }
    }

    // MARK: step 2

    private var termsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: document.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            Button {
                showingTerms = true
            } label: {
                Label {
                    Text(verbatim: LegalStrings.readTerms)
                } icon: {
                    Image(systemName: "doc.text")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.blue)
            }
            .accessibilityIdentifier("terms-read")
            LegalCheckboxRow(isOn: $draft.termsAccepted, text: LegalStrings.termsCheckbox,
                             identifier: "terms-checkbox")
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: LegalStrings.professionalQuestion)
                    .font(.footnote)
                    .foregroundStyle(.white)
                Picker(selection: $draft.professional) {
                    Text(verbatim: LegalStrings.no).tag(false)
                    Text(verbatim: LegalStrings.yes).tag(true)
                } label: {
                    Text(verbatim: LegalStrings.professionalQuestion)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("terms-professional")
            }
        }
    }

    // MARK: step 3

    private var groupsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: LegalStrings.groupsHeading)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            Text(verbatim: LegalStrings.groupsIntro)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
            ForEach(document.groups) { group in
                groupCard(group)
            }
        }
    }

    private func groupCard(_ group: LegalGroup) -> some View {
        let expanded = expandedGroups.contains(group.id)
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: group.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            if !group.clauses.isEmpty {
                Text(verbatim: group.clauses)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Button {
                if expanded { expandedGroups.remove(group.id) } else { expandedGroups.insert(group.id) }
            } label: {
                Text(verbatim: expanded ? LegalStrings.hideText : LegalStrings.showText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
            }
            .accessibilityIdentifier("terms-group-expand-\(group.id)")
            if expanded {
                Text(verbatim: group.text)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
            }
            LegalCheckboxRow(
                isOn: Binding(
                    get: { draft.isGroupAccepted(group.id) },
                    set: { draft.setGroup(group.id, accepted: $0) }),
                text: LegalStrings.groupApprove,
                identifier: "terms-group-checkbox-\(group.id)")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
    }
}

// MARK: - Loader

/// Loads the document and runs the three steps in front of a registration. `onAccepted` gets the acceptance to put in
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

/// An existing account whose acceptance is missing or old. Same three steps, a delete-account action on the same
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
