import Foundation
import Contacts
import QAudionEngine

/// Reads the user's on-device address book, normalises phone numbers, hashes
/// them with SHA-256 (matching `bcrypto-server/internal/api/account.go:hashPhone`
/// and Android's contact discovery), and asks the server which contacts are
/// registered Q-Audion users.
///
/// The server never sees raw phone numbers — only the hex-encoded SHA-256
/// digests, so the discovery is privacy-preserving (server can confirm a hash
/// matches a registered user but cannot enumerate arbitrary phone numbers).
///
/// Intended usage:
/// ```
/// let service = ContactSyncService(provider: backendProvider)
/// let matches = try await service.syncDeviceContacts()
/// ```
/// Call sites should display the discovered list in `ConversationListView` so
/// the user can start calls or chats with any contact who also installed the
/// app.
@MainActor
public final class ContactSyncService {

    /// Maps an iOS `CNContact` to the server-side match, preserving the
    /// human-readable display name from the local address book so the UI
    /// isn't forced to show server-supplied display names for people the
    /// user already knows under a different name.
    public struct ContactMatch: Identifiable {
        public var id: String { discovered.userId }
        public let discovered: DiscoveredContact
        /// The local contact this match originated from (address book
        /// `familyName + givenName`, fallback to server-side display name).
        public let localDisplayName: String
        /// The normalised phone number (E.164-ish) as fed into the hash.
        public let normalisedPhone: String
    }

    public enum SyncError: Error, LocalizedError {
        case contactsPermissionDenied
        case backendUnavailable

        public var errorDescription: String? {
            switch self {
            case .contactsPermissionDenied:
                return "Permesso contatti negato. Attivalo da Impostazioni → Q-Audion."
            case .backendUnavailable:
                return "Backend non disponibile. Rieffettua il login."
            }
        }
    }

    private let provider: BCryptoBackendProvider
    private let contactStore = CNContactStore()

    public init(provider: BCryptoBackendProvider) {
        self.provider = provider
    }

    // MARK: - Permission

    /// Requests read access to the Contacts database. iOS shows the system
    /// permission prompt on first call; subsequent calls return immediately.
    public func requestAccess() async throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let granted = try await contactStore.requestAccess(for: .contacts)
            if !granted { throw SyncError.contactsPermissionDenied }
        case .denied, .restricted:
            throw SyncError.contactsPermissionDenied
        @unknown default:
            throw SyncError.contactsPermissionDenied
        }
    }

    // MARK: - Sync

    /// Enumerate local contacts, hash every phone number, ask the server
    /// which ones correspond to registered users, and return the matches.
    ///
    /// - Returns: one `ContactMatch` per local contact that the server
    ///   confirmed is a registered Q-Audion user. Contacts with no matching
    ///   phone hash are silently dropped.
    public func syncDeviceContacts() async throws -> [ContactMatch] {
        try await requestAccess()

        // 1. Pull phone numbers + display names from the local address book.
        let localPairs = try readLocalContacts()
        if localPairs.isEmpty { return [] }

        // 2. Build a phoneHash → (displayName, normalisedPhone) lookup so
        //    we can join the server's DiscoveredContact (keyed by phoneHash)
        //    with the address book entry that produced it.
        var hashToLocal: [String: (displayName: String, phone: String)] = [:]
        for pair in localPairs {
            let hash = BCryptoAccountApiImpl.hashPhone(pair.normalisedPhone)
            // First write wins for a given hash so duplicate numbers across
            // multiple CNContacts don't double-count.
            if hashToLocal[hash] == nil {
                hashToLocal[hash] = (pair.displayName, pair.normalisedPhone)
            }
        }

        // 3. Ask the server which hashes belong to registered users.
        let discovered = try await provider.contactsApi.discoverContacts(
            phoneHashes: Array(hashToLocal.keys)
        )

        // 4. Stitch together the server result with the local metadata.
        return discovered.compactMap { server -> ContactMatch? in
            guard let local = hashToLocal[server.phoneHash] else { return nil }
            return ContactMatch(
                discovered: server,
                localDisplayName: !local.displayName.isEmpty
                    ? local.displayName
                    : (server.displayName ?? "Unknown"),
                normalisedPhone: local.phone
            )
        }
    }

    // MARK: - Local enumeration

    private struct LocalPhone {
        let displayName: String
        let normalisedPhone: String
    }

    private func readLocalContacts() throws -> [LocalPhone] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault

        var results: [LocalPhone] = []
        try contactStore.enumerateContacts(with: request) { contact, _ in
            let displayName = Self.formatDisplayName(contact)
            for labeledValue in contact.phoneNumbers {
                let raw = labeledValue.value.stringValue
                let normalised = Self.normalisePhoneNumber(raw)
                guard !normalised.isEmpty else { continue }
                results.append(LocalPhone(
                    displayName: displayName,
                    normalisedPhone: normalised
                ))
            }
        }
        return results
    }

    // MARK: - Normalisation helpers

    /// Strip every character that isn't a digit, preserving a leading `+` if
    /// present. This is a deliberately low-sophistication normaliser — it
    /// matches what the Android client does in its own contact sync
    /// (SHA-256 of `+<digits>` or `<digits>`). A proper libphonenumber pass
    /// is out of scope for MVP and would require an extra 2 MB dependency;
    /// users whose address book stores local-format numbers won't get a
    /// cross-platform match until they save the contact in international
    /// form. That's acceptable for a beta used by a small tester pool.
    public static func normalisePhoneNumber(_ raw: String) -> String {
        var result = ""
        var sawPlus = false
        for scalar in raw.unicodeScalars {
            if scalar == "+" && result.isEmpty && !sawPlus {
                result.append("+")
                sawPlus = true
                continue
            }
            if CharacterSet.decimalDigits.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func formatDisplayName(_ contact: CNContact) -> String {
        let parts = [contact.givenName, contact.familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        let org = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return org.isEmpty ? "" : org
    }
}
