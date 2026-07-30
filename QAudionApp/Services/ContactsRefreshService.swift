import Foundation
import QAudionEngine

@MainActor
final class ContactsRefreshService {

    enum Error: Swift.Error {
        case notAuthenticated
        case pepperFetchFailed
    }

    let appState: AppState
    let store: ContactsStore
    private let coordinator: PhonebookSyncCoordinator

    init(appState: AppState, store: ContactsStore = ContactsStore()) {
        self.appState = appState
        self.store = store
        self.coordinator = PhonebookSyncCoordinator(appState: appState, contactsStore: store)
    }

    /// Refresh by scanning the user's phonebook. Requires Contacts permission.
    /// Returns the resolved StoredContacts.
    func refreshFromPhonebook(
        onProgress: @escaping (PhonebookSyncCoordinator.ScanProgress) -> Void = { _ in }
    ) async throws -> [ContactsStore.StoredContact] {
        let granted = try await coordinator.requestPermission()
        guard granted else { throw PhonebookSyncCoordinator.Error.permissionDenied }
        _ = try await coordinator.scanAndDiscover(onProgress: onProgress)
        return store.load()
    }

    /// Low-level refresh for callers that already have a phone list.
    /// Caller supplies the list of E.164 phones (typically pre-enumerated).
    func refresh(phonesToCheck: [String]) async throws -> [ContactsStore.StoredContact] {
        guard let token = appState.authService.loadToken(), !token.isEmpty else {
            throw Error.notAuthenticated
        }
        guard let url = URL(string: appState.serverUrl) else {
            throw Error.pepperFetchFailed
        }
        let client = BCryptoContactsDiscoverV2Client(
            baseUrl: url,
            bearerTokenProvider: { token }
        )
        // W343 cross-platform parity: fetchPepper now returns
        // (pepperBytes, alg). Use the byte form so the SHA-256 input
        // matches Android byte-for-byte.
        let pepper = try await client.fetchPepper()
        let hashes = phonesToCheck.compactMap { phone -> (input: String, hash: String?) in
            (phone, try? PepperedPhoneHash.hash(phone: phone, pepperBytes: pepper.pepperBytes))
        }
        let validHashes = hashes.compactMap { $0.hash }
        let entries = try await client.discover(alg: pepper.alg, hashes: validHashes)
        // Map back to StoredContact (display name comes from local phonebook;
        // the discover-v2 response only confirms userId existence).
        // E2EE avatar transport (2026-07-30) — this is a full-row
        // upsert refresh; preserve any already-cached avatar pair so a
        // routine refresh doesn't wipe a peer's avatar back to nil,
        // forcing a needless re-download.
        let existingByUserId = Dictionary(
            uniqueKeysWithValues: store.load().map { ($0.userId, $0) }
        )
        let resolved: [ContactsStore.StoredContact] = entries.map { entry in
            let existing = existingByUserId[entry.userId]
            return ContactsStore.StoredContact(
                userId: entry.userId,
                displayName: "Contact \(entry.userId.suffix(6))",  // replaced by phonebook name in caller
                phoneHash: entry.phoneHash ?? "",
                avatarUrl: existing?.avatarUrl,
                lastSeen: nil,
                isVerified: false,
                avatarVersion: existing?.avatarVersion
            )
        }
        for c in resolved { store.upsert(c) }
        return store.load()
    }
}
