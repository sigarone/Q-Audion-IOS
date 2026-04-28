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

    init(appState: AppState, store: ContactsStore = ContactsStore()) {
        self.appState = appState
        self.store = store
    }

    /// Refresh contacts: fetches global pepper, hashes the user's phonebook,
    /// submits to discover-v2, persists the resolved contacts.
    /// Caller supplies the list of E.164 phones (typically from Contacts framework).
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
        let pepper = try await client.fetchPepper()
        let hashes = phonesToCheck.compactMap { phone -> (input: String, hash: String?) in
            (phone, try? PepperedPhoneHash.hash(phone: phone, pepper: pepper))
        }
        let validHashes = hashes.compactMap { $0.hash }
        let entries = try await client.discover(hashes: validHashes)
        // Map back to StoredContact (display name comes from local phonebook;
        // the discover-v2 response only confirms userId existence).
        let resolved: [ContactsStore.StoredContact] = entries.compactMap { entry in
            guard let uid = entry.userId else { return nil }
            return ContactsStore.StoredContact(
                userId: uid,
                displayName: "Contact \(uid.suffix(6))",  // replaced by phonebook name in caller
                phoneHash: entry.hash,
                avatarUrl: nil,
                lastSeen: nil,
                isVerified: false
            )
        }
        for c in resolved { store.upsert(c) }
        return store.load()
    }
}
