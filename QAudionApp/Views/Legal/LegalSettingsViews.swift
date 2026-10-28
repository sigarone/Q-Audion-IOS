import SwiftUI
import QAudionEngine

/// The emergency calls notice as it is on the server, always readable (Settings > Legal and About).
struct EmergencyNoticeCard: View {
    let appState: AppState
    @State private var text: String?
    @State private var failed = false

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text {
                Text(verbatim: text)
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if failed {
                Button {
                    Task { await load() }
                } label: {
                    Text(verbatim: LegalStrings.loadFailed + " " + LegalStrings.retry)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.primary)
                }
                .buttonStyle(.plain)
            } else {
                ProgressView()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(scheme.surfaceVariant.opacity(0.4)))
        .task { await load() }
    }

    private func load() async {
        failed = false
        do {
            let fetch = try await AppStateLegalApi(appState: appState).fetchTerms(lang: LegalService.documentLanguage)
            text = fetch.document.emergencyNotice
        } catch {
            failed = true
        }
    }
}

/// The Terms, read from the server.
struct LegalTermsReaderScreen: View {
    let appState: AppState
    @State private var fetch: LegalTermsFetch?
    @State private var failed = false

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let fetch {
                        if fetch.document.lang != "it" {
                            Text(verbatim: LegalStrings.italianPrevails)
                                .qaudionStyle(type.labelSmall)
                                .foregroundStyle(scheme.onSurfaceVariant)
                        }
                        Text(verbatim: LegalStrings.edition(fetch.document.version))
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                        TermsDocumentBody(markdown: fetch.document.bodyMarkdown)
                    } else if failed {
                        Button {
                            Task { await load() }
                        } label: {
                            Text(verbatim: LegalStrings.loadFailed + " " + LegalStrings.retry)
                                .qaudionStyle(type.labelSmall)
                                .foregroundStyle(scheme.primary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ProgressView()
                    }
                }
                .padding(16)
                .qaudionReadableWidth()
            }
        }
        .navigationTitle(Text(verbatim: LegalStrings.settingsTerms))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        failed = false
        do {
            fetch = try await AppStateLegalApi(appState: appState).fetchTerms(lang: LegalService.documentLanguage)
        } catch {
            failed = true
        }
    }
}

/// The copy of what the person accepted (`GET /legal/acceptance`), to read and to share as a text file.
struct LegalAcceptanceCopyScreen: View {
    let appState: AppState

    private enum LoadState: Equatable {
        case loading
        case loaded(String)
        case none
        case failed
    }

    @State private var state: LoadState = .loading
    @State private var shareURL: URL?

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch state {
                    case .loading:
                        ProgressView()
                    case .none:
                        Text(verbatim: LegalStrings.acceptanceNone)
                            .qaudionStyle(type.bodySmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                    case .failed:
                        Button {
                            Task { await load() }
                        } label: {
                            Text(verbatim: LegalStrings.acceptanceFailed + " " + LegalStrings.retry)
                                .qaudionStyle(type.labelSmall)
                                .foregroundStyle(scheme.primary)
                        }
                        .buttonStyle(.plain)
                    case .loaded(let text):
                        Text(verbatim: text)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(scheme.onSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        if let shareURL {
                            ShareLink(item: shareURL) {
                                Label {
                                    Text(verbatim: LegalStrings.receiptShare)
                                } icon: {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .qaudionReadableWidth()
            }
        }
        .navigationTitle(Text(verbatim: LegalStrings.settingsAcceptance))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear {
            if let shareURL { try? FileManager.default.removeItem(at: shareURL) }
        }
    }

    private func load() async {
        state = .loading
        do {
            let data = try await AppStateLegalApi(appState: appState).acceptanceCopy()
            let text = Self.readable(data)
            guard !text.isEmpty else { state = .none; return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("q-audion-acceptance.txt")
            try? Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            shareURL = url
            state = .loaded(text)
        } catch BCryptoError.notFound {
            state = .none
        } catch BCryptoError.httpError(404) {
            state = .none
        } catch {
            state = .failed
        }
    }

    /// The server's JSON, indented; anything else is shown as received.
    static func readable(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Settings > Legal.
struct LegalSettingsScreen: View {
    let appState: AppState

    @Environment(\.qaudionScheme) private var scheme

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 8) {
                    NavigationLink {
                        LazyView { LegalTermsReaderScreen(appState: appState) }
                    } label: {
                        SettingsRow(icon: "doc.text",
                                    iconColor: scheme.primary,
                                    title: LocalizedStringKey("legal.settings.terms"))
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        LazyView { LegalAcceptanceCopyScreen(appState: appState) }
                    } label: {
                        SettingsRow(icon: "checkmark.seal",
                                    iconColor: scheme.primary,
                                    title: LocalizedStringKey("legal.settings.acceptance"))
                    }
                    .buttonStyle(.plain)

                    SettingsSectionHeader(LocalizedStringKey("legal.settings.emergency"))
                    EmergencyNoticeCard(appState: appState)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .qaudionReadableWidth()
            }
        }
        .navigationTitle(Text(verbatim: LegalStrings.settingsTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}
