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
            // W-AUXPIN (2026-09-02) — pinned session, same as every other
            // bearer-token aux client (audit reference_ios_stability_audit_
            // 2026_09_01, P1 item 6 / B11). PinnedSessionPolicy
            // .auxiliaryClientsUsePinnedSession == false restores `.shared`.
            session: PinnedURLSession.auxiliary(for: appState.serverUrl),
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
        //
        // This is a FULL-ROW upsert, and every field it does not carry forward
        // is destroyed. discover-v2 knows two things about a contact — that the
        // userId exists and which phoneHash resolved to it — while the row also
        // holds a pile of facts this device learned locally and the directory
        // has no opinion about. Each of those has to be preserved explicitly.
        //
        // It was already found the hard way once: the avatar pair was added
        // here (2026-07-30, E2EE avatar transport) after a routine refresh kept
        // wiping cached avatars back to nil and forcing re-downloads. Nobody
        // generalised the lesson, so everything else stayed erasable, and the
        // bug resurfaced with worse consequences than a re-download:
        //
        //   • `pubkey` is the ONLY field the mesh radar can identify a device
        //     by (MeshFeature.nodeId(forContactPubkey:)). Erasing it turns a
        //     recognised contact back into "Dispositivo non identificato" on
        //     the next background refresh — R1, reported from the field.
        //   • `verifiedFingerprintHex` / `verifiedAtMs` / `verificationMethod`
        //     are the verification PIN. Dropping them does not merely dim a
        //     checkmark: ContactDetailScreen compares the freshly computed
        //     fingerprint against the pin to detect an identity change, and a
        //     nil pin cannot detect anything.
        //   • `presenceAuth` / `presenceFloor` are a historical in-person
        //     authentication record with its own sanctioned write path
        //     (applyAssuranceOutcome) and its own deliberate clearing points.
        //     A directory refresh is not one of them.
        //   • `phoneNumber` / `extension` are learned only from a genuine call
        //     or a user-picked import row, never bulk-synced — so once erased
        //     here they do not come back on the next refresh.
        //   • `voiceVerifiedAt` records a completed voice-learning session.
        //
        // `isVerified` stays as the directory found it ONLY when the row is
        // new; for an existing contact it is a local trust decision and is
        // carried forward like the rest.
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
                lastSeen: existing?.lastSeen,
                isVerified: existing?.isVerified ?? false,
                pubkey: existing?.pubkey,
                verifiedFingerprintHex: existing?.verifiedFingerprintHex,
                verifiedAtMs: existing?.verifiedAtMs,
                verificationMethod: existing?.verificationMethod,
                presenceAuth: existing?.presenceAuth,
                presenceFloor: existing?.presenceFloor,
                phoneNumber: existing?.phoneNumber,
                extension: existing?.`extension`,
                avatarVersion: existing?.avatarVersion,
                voiceVerifiedAt: existing?.voiceVerifiedAt
            )
        }
        for c in resolved { store.upsert(c) }
        return store.load()
    }
}
