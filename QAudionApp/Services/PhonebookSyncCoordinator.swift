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
    /// Also registers the user's own peppered phone hashes via
    /// `POST /api/v1/contacts/phones` before running discovery, so peers who
    /// have our number in their address book can find us. Mirrors Android
    /// `DiscoverContactsUseCase.runPeppered` (fire-and-forget for own phones:
    /// a transient failure here does not abort the discovery pass).
    ///
    /// - Parameters:
    ///   - onProgress: Called at start (after enumeration) and end (after
    ///     discovery) with a ScanProgress snapshot. Safe to mutate UI from here —
    ///     the coordinator is @MainActor and the closure is called inline.
    ///   - ownE164Phones: The user's own E.164 phone numbers to register on the
    ///     server for reverse-discovery. When nil, the coordinator reads from
    ///     UserDefaults (key `com.qaudion.profile.myPhones`). Pass [] to skip
    ///     registration explicitly.
    /// - Returns: Array of ResolvedMatch (one per Q-Audion user found in phonebook).
    func scanAndDiscover(
        onProgress: @escaping (ScanProgress) -> Void = { _ in },
        ownE164Phones: [String]? = nil
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
        // W343: fetchPepper now returns (bytes, alg). The byte form is
        // the canonical hash input — feeding the base64 string into
        // SHA-256 silently broke server-side matching.
        let pepper: BCryptoContactsDiscoverV2Client.PepperBundle
        do {
            pepper = try await client.fetchPepper()
        } catch {
            throw Error.fetchFailed("Pepper fetch failed: \(error.localizedDescription)")
        }

        // Build hash → (phone, name) map; first occurrence wins for duplicate numbers.
        var hashToInfo: [String: (phone: String, name: String)] = [:]
        var allHashes: [String] = []
        for entry in normalized {
            if let hash = try? PepperedPhoneHash.hash(phone: entry.phone, pepperBytes: pepper.pepperBytes) {
                if hashToInfo[hash] == nil {
                    hashToInfo[hash] = entry
                    allHashes.append(hash)
                }
            }
        }

        // Step 4 — register our own peppered phone hashes so peers who hold
        // our number can discover us (Android parity: DiscoverContactsUseCase
        // calls registerPepperedPhones before the discover batch). Fire-and-
        // forget: a failure here must not abort the discovery pass.
        let resolvedOwnPhones: [String] = ownE164Phones
            ?? (UserDefaults.standard.array(forKey: "com.qaudion.profile.myPhones") as? [String] ?? [])
        if !resolvedOwnPhones.isEmpty {
            let ownHashes = resolvedOwnPhones.compactMap { phone -> String? in
                try? PepperedPhoneHash.hash(phone: phone, pepperBytes: pepper.pepperBytes)
            }
            if !ownHashes.isEmpty {
                do {
                    try await client.registerPepperedPhones(alg: pepper.alg, hashes: ownHashes)
                } catch {
                    // Best-effort: log but continue. Reverse-discovery for our number
                    // may be stale until the next successful sync.
                    print("[PhonebookSyncCoordinator] registerPepperedPhones failed (non-fatal): \(error.localizedDescription)")
                }
            }
        }

        // Step 5 — discover-v2.
        let discovered: [BCryptoContactsDiscoverV2Client.DiscoveredEntry]
        do {
            discovered = try await client.discover(alg: pepper.alg, hashes: allHashes)
        } catch {
            throw Error.fetchFailed("Discover-v2 failed: \(error.localizedDescription)")
        }

        // Step 6 — persist resolved contacts and build results list.
        //
        // 2026-07-30: the server never echoes back which REQUEST hash
        // matched a given discovered account (a genuine, pre-existing gap
        // shared with Android's DiscoverContactsUseCase, not introduced by
        // this fix — see that file's identical two-step fallback). Mirrors
        // it exactly: (a) try the discovered account's own phone_hash as a
        // hashToInfo key — essentially never true in practice, since that's
        // the account's regular auth hash, a different hash space than the
        // discovery pepper, kept only for parity/future-proofing — then (b)
        // fall back to a direct plaintext match against the account's
        // opt-in public phone_number when the server sends one. An entry
        // that matches neither is skipped, same as Android — "can't tell
        // which local contact this is", not an error.
        var results: [ResolvedMatch] = []
        for entry in discovered {
            let info = hashToInfo[entry.phoneHash ?? ""]
                ?? entry.phoneNumber.flatMap { pn in normalized.first(where: { $0.phone == pn }) }
            guard let info else { continue }
            let uid = entry.userId
            let stored = ContactsStore.StoredContact(
                userId: uid,
                displayName: info.name,
                phoneHash: entry.phoneHash ?? "",
                avatarUrl: nil,
                lastSeen: nil,
                isVerified: false
            )
            contactsStore.upsert(stored)
            results.append(ResolvedMatch(
                userId: uid,
                displayName: info.name,
                phoneHash: entry.phoneHash ?? "",
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
