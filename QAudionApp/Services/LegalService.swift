import Foundation
import SwiftUI
import UniformTypeIdentifiers
import QAudionEngine

// MARK: - API of the app

/// The legal endpoints, reached with whatever the app has at the moment of the call: the session of the signed-in
/// account when there is one, the bare pinned server otherwise (the terms are public).
@MainActor
final class AppStateLegalApi: LegalApi {
    private weak var appState: AppState?

    init(appState: AppState) { self.appState = appState }

    private func restClient(authenticated: Bool) -> BCryptoRestClient? {
        guard let appState else { return nil }
        if authenticated {
            if let provider = appState.liveProvider { return provider.getRestClient() }
            guard let token = appState.authService.loadToken(), !token.isEmpty else { return nil }
            let config = BackendConfig.pinned(serverUrl: appState.serverUrl, accessToken: token)
            return BCryptoBackendProvider(config: config).getRestClient()
        }
        return BCryptoBackendProvider(config: BackendConfig.pinned(serverUrl: appState.serverUrl)).getRestClient()
    }

    private func authenticatedApi() throws -> BCryptoLegalApi {
        guard let rest = restClient(authenticated: true) else { throw BCryptoError.unauthorized }
        return BCryptoLegalApi(rest: rest)
    }

    func fetchTerms(lang: String) async throws -> LegalTermsFetch {
        guard let rest = restClient(authenticated: false) else { throw BCryptoError.invalidUrl }
        return try await BCryptoLegalApi(rest: rest).fetchTerms(lang: lang)
    }

    func status() async throws -> LegalStatus { try await authenticatedApi().status() }

    func accept(_ acceptance: TermsAcceptance) async throws { try await authenticatedApi().accept(acceptance) }

    func acceptanceCopy() async throws -> Data { try await authenticatedApi().acceptanceCopy() }

    func withdraw() async throws -> WithdrawalReceipt { try await authenticatedApi().withdraw() }
}

enum LegalService {
    /// `it` for an Italian app language, `en` for every other.
    static var documentLanguage: String {
        LegalLanguage.code(forAppLanguage: AppLanguageManager.effectiveLanguageCode)
    }

    /// The legal API for the registration screens: no account exists yet, only the public terms are read.
    @MainActor
    static func anonymousApi(serverUrl: String) -> LegalApi {
        let rest = BCryptoBackendProvider(config: BackendConfig.pinned(serverUrl: serverUrl)).getRestClient()
        return BCryptoLegalApi(rest: rest)
    }
}

// MARK: - Emergency notice

/// The emergency notice (art. 16.3 summary), shown once before the first outgoing call. `AppState.startCall` asks
/// `confirmBeforeFirstCall()` before it places a call from the phone; the logic (and its timings) is
/// `EmergencyNoticeCoordinator` in the engine. The root view shows `pendingText` in an alert.
typealias EmergencyNoticeCenter = EmergencyNoticeCoordinator

extension EmergencyNoticeCoordinator {
    static let shared = EmergencyNoticeCoordinator(
        isSceneActive: { UIApplication.shared.applicationState == .active })

    /// Reads the notice text with whatever the app has at the moment of the call.
    func configure(apiProvider: @escaping @MainActor () -> LegalApi?) {
        configure(textProvider: {
            guard let api = apiProvider() else { return nil }
            let lang = LegalService.documentLanguage
            return { try? await api.fetchTerms(lang: lang).document.emergencyNotice }
        })
    }
}

// MARK: - Withdrawal receipt

/// The receipt of a withdrawal, shown above the rest of the app until the person closes it. The account is gone from
/// the server and from the phone by then, so the receipt is also written to a file of the app container the moment it
/// arrives and read again at the next launch; the file goes away when the receipt is saved to Files or its screen is
/// closed.
@MainActor
final class WithdrawalReceiptStore: ObservableObject {
    static let shared = WithdrawalReceiptStore()

    @Published private(set) var receipt: WithdrawalReceipt?
    private let file: WithdrawalReceiptFile?

    init(file: WithdrawalReceiptFile? = WithdrawalReceiptFile.appContainer()) {
        self.file = file
        receipt = file?.load()
    }

    /// A receipt just arrived: kept on disk first, then shown.
    func present(_ newReceipt: WithdrawalReceipt) {
        try? file?.save(newReceipt)
        receipt = newReceipt
    }

    /// The person saved it to Files: the copy in the container is no longer needed.
    func savedToFiles() { file?.delete() }

    func close() {
        file?.delete()
        receipt = nil
    }
}

/// The receipt as a text file, for the share sheet and the export-to-Files dialog.
struct ReceiptTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

enum ReceiptFile {
    /// The file name of a receipt: letters, digits and dashes only, whatever the id looks like.
    static func fileName(receiptId: String) -> String {
        let id = String(receiptId.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(40))
        return "q-audion-receipt-\(id.isEmpty ? "withdrawal" : id).txt"
    }

    /// Writes the receipt to the temporary directory and returns the file, for `ShareLink`.
    static func writeTemporary(_ receipt: WithdrawalReceipt) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(receiptId: receipt.receiptId))
        do {
            try Data(receipt.receiptText.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Local wipe after the server deleted the account

extension AppState {
    /// The server has deleted the account (a recorded withdrawal runs the same deletion path as DELETE /account): this
    /// is the local half, the same steps `AccountSettingsContainer.deleteAccount()` takes once the server confirmed.
    func finishLocalSessionAfterServerSideDeletion() {
        LocalCryptoWipe.wipeAll()
        resetAccountScopedRuntimeState()
        authService.clearToken()
        capabilityGate.discard()
        isAuthenticated = false
    }
}
