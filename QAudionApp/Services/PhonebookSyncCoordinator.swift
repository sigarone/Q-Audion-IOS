import Foundation
import Contacts
import QAudionEngine

/// Coordinates the full phonebook-to-discover-v2 pipeline.
///
/// Responsibilities:
///  1. Request Contacts framework permission via CNContactStore.
///  2. Enumerate all CNContacts that have phone numbers.
///  3. Normalize each raw phone string to E.164 via PhoneHash.normalizeE164.
///  4. Hash each normalized number with a server-issued pepper via PepperedPhoneHash.
///  5. Submit hashes to /contacts/discover-v2 via BCryptoContactsDiscoverV2Client.
///  6. Persist resolved contacts to ContactsStore with the display name from CNContact.
///
/// Must be created and used on the MainActor (matches PhonebookImportContainer).
@MainActor
final class PhonebookSyncCoordinator {

    // MARK: - Error

    enum Error: Swift.Error, LocalizedError {
        case permissionDenied
        case notAuthenticated
        case fetchFailed(String)
        case normalizationFailedAll

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Contacts permission denied. Enable in Settings → Q-Audion → Contacts."
            case .notAuthenticated:
                return "Not signed in"
            case .fetchFailed(let m):
                return "Phonebook fetch failed: \(m)"
            case .normalizationFailedAll:
                return "No valid phone numbers found in your phonebook"
            }
        }
    }

    // MARK: - Supporting types

    struct ScanProgress {
        let totalContacts: Int
        let processedContacts: Int
        let validE164Count: Int
        let resolvedUserCount: Int
    }

    struct ResolvedMatch {
        let userId: String
        let displayName: String
        let phoneHash: String
        let originalPhone: String
    }

    // MARK: - Dependencies

    private let appState: AppState
    private let contactsStore: ContactsStore
    private let cnStore: CNContactStore

    // MARK: - Init

    init(appState: AppState,
         contactsStore: ContactsStore = ContactsStore(),
         cnStore: CNContactStore = CNContactStore()) {
        self.appState = appState
        self.contactsStore = contactsStore
        self.cnStore = cnStore
    }

    // MARK: - Permission

    /// Returns the current CNAuthorizationStatus without requesting.
    var permissionStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    /// Request Contacts permission.
    /// - Returns: `true` if the user has granted (or already had) access.
    /// - Throws: Any system error surfaced by CNContactStore.requestAccess.
    func requestPermission() async throws -> Bool {
        let status = permissionStatus
        switch status {
        case .authorized, .limited:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return try await withCheckedThrowingContinuation { cont in
                cnStore.requestAccess(for: .contacts) { granted, err in
                    if let e = err { cont.resume(throwing: e); return }
                    cont.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    // MARK: - Main pipeline

    /// Scan local phonebook, normalize numbers, hash, submit to discover-v2,
    /// persist results to ContactsStore, and return resolved matches.
    ///
    /// - Parameter onProgress: Called at start (after enumeration) and end (after
    ///   discovery) with a ScanProgress snapshot. Safe to mutate UI from here —
    ///   the coordinator is @MainActor and the closure is called inline.
    /// - Returns: Array of ResolvedMatch (one per Q-Audion user found in phonebook).
    func scanAndDiscover(
        onProgress: @escaping (ScanProgress) -> Void = { _ in }
    ) async throws -> [ResolvedMatch] {

        // Require auth token before touching the network.
        guard let token = appState.authService.loadToken(), !token.isEmpty else {
            throw Error.notAuthenticated
        }
        guard let url = URL(string: appState.serverUrl) else {
            throw Error.fetchFailed("Invalid server URL: \(appState.serverUrl)")
        }

        // Step 1 — enumerate CNContacts (only those with phone numbers).
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var allContacts: [CNContact] = []
        do {
            try cnStore.enumerateContacts(with: request) { contact, _ in
                if !contact.phoneNumbers.isEmpty { allContacts.append(contact) }
            }
        } catch {
            throw Error.fetchFailed(error.localizedDescription)
        }

        // Step 2 — normalize each number to E.164 and pair with display name.
        var normalized: [(phone: String, name: String)] = []
        for contact in allContacts {
            let name = displayName(for: contact)
            for labeled in contact.phoneNumbers {
                let raw = labeled.value.stringValue
                if let e164 = try? PhoneHash.normalizeE164(raw) {
                    normalized.append((phone: e164, name: name))
                }
            }
        }

        guard !normalized.isEmpty else {
            throw Error.normalizationFailedAll
        }

        onProgress(ScanProgress(
            totalContacts: allContacts.count,
            processedContacts: allContacts.count,
            validE164Count: normalized.count,
            resolvedUserCount: 0
        ))

        // Step 3 — fetch pepper, build hash → info map.
        let client = BCryptoContactsDiscoverV2Client(
            baseUrl: url,
            bearerTokenProvider: { token }
        )
        let pepper: String
        do {
            pepper = try await client.fetchPepper()
        } catch {
            throw Error.fetchFailed("Pepper fetch failed: \(error.localizedDescription)")
        }

        // Build hash → (phone, name) map; first occurrence wins for duplicate numbers.
        var hashToInfo: [String: (phone: String, name: String)] = [:]
        var allHashes: [String] = []
        for entry in normalized {
            if let hash = try? PepperedPhoneHash.hash(phone: entry.phone, pepper: pepper) {
                if hashToInfo[hash] == nil {
                    hashToInfo[hash] = entry
                    allHashes.append(hash)
                }
            }
        }

        // Step 4 — discover-v2.
        let discovered: [BCryptoContactsDiscoverV2Client.DiscoveredEntry]
        do {
            discovered = try await client.discover(hashes: allHashes)
        } catch {
            throw Error.fetchFailed("Discover-v2 failed: \(error.localizedDescription)")
        }

        // Step 5 — persist resolved contacts and build results list.
        var results: [ResolvedMatch] = []
        for entry in discovered {
            guard let uid = entry.userId, let info = hashToInfo[entry.hash] else { continue }
            let stored = ContactsStore.StoredContact(
                userId: uid,
                displayName: info.name,
                phoneHash: entry.hash,
                avatarUrl: nil,
                lastSeen: nil,
                isVerified: false
            )
            contactsStore.upsert(stored)
            results.append(ResolvedMatch(
                userId: uid,
                displayName: info.name,
                phoneHash: entry.hash,
                originalPhone: info.phone
            ))
        }

        onProgress(ScanProgress(
            totalContacts: allContacts.count,
            processedContacts: allContacts.count,
            validE164Count: normalized.count,
            resolvedUserCount: results.count
        ))

        return results
    }

    // MARK: - Helpers

    /// Build a human-readable display name from a CNContact.
    /// Prefers "GivenName FamilyName", falls back to OrganizationName,
    /// then to the empty string (caller can substitute "Unknown").
    private func displayName(for contact: CNContact) -> String {
        let parts = [contact.givenName, contact.familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        let org = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return org.isEmpty ? "Unknown" : org
    }
}
