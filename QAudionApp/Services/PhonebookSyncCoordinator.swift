import Foundation
import Contacts
import QAudionEngine

@MainActor
final class PhonebookSyncCoordinator {

    enum SyncError: Error, LocalizedError {
        case permissionDenied
        case noContactsFound
        case discoveryFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Contacts permission denied. Enable in Settings."
            case .noContactsFound: return "No contacts found in your phonebook."
            case .discoveryFailed(let m): return "Discovery failed: \(m)"
            }
        }
    }

    private let store = CNContactStore()
    private let client: BCryptoContactsDiscoverV2Client?

    init(client: BCryptoContactsDiscoverV2Client? = nil) {
        self.client = client
    }

    /// Request Contacts permission. Returns true if granted.
    func requestPermission() async -> Bool {
        do {
            return try await store.requestAccess(for: .contacts)
        } catch {
            return false
        }
    }

    /// Scan local phonebook for E.164 phone numbers, returns count.
    func scanLocalContacts() throws -> [(localName: String, phoneRaw: String)] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var collected: [(String, String)] = []

        try store.enumerateContacts(with: request) { contact, _ in
            let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
            for phone in contact.phoneNumbers {
                let raw = phone.value.stringValue
                collected.append((name.isEmpty ? raw : name, raw))
            }
        }
        return collected
    }

    /// Hash phones via PepperedPhoneHash + send to server discover-v2.
    /// Returns matched user_ids paired with the local name for display.
    func discover(localContacts: [(localName: String, phoneRaw: String)],
                  pepper: String) async throws -> (matched: [PhonebookImportViewModel.Match], unmatched: Int) {
        guard let client = client else {
            throw SyncError.discoveryFailed("No discover client wired")
        }

        // Build hash → localName map (skip invalid phones).
        var hashToName: [String: String] = [:]
        var hashes: [String] = []
        for (name, raw) in localContacts {
            if let hash = try? PepperedPhoneHash.hash(phone: raw, pepper: pepper) {
                hashToName[hash] = name
                hashes.append(hash)
            }
        }

        guard !hashes.isEmpty else { throw SyncError.noContactsFound }

        let entries = try await client.discover(hashes: hashes)
        var matches: [PhonebookImportViewModel.Match] = []
        for entry in entries {
            if let userId = entry.userId, let name = hashToName[entry.hash] {
                matches.append(PhonebookImportViewModel.Match(
                    userId: userId, localName: name, phoneHash: entry.hash
                ))
            }
        }
        let matchedHashes = Set(matches.map { $0.phoneHash })
        let unmatched = hashes.filter { !matchedHashes.contains($0) }.count
        return (matched: matches, unmatched: unmatched)
    }
}
