import XCTest
@testable import QAudionApp
import QAudionEngine

/// W-PAIRFB (in-person pairing feedback sweep) — pins
/// `ContactsListContainer.recordProximityPairing`'s three-way outcome
/// classification and the persistence it drives, closing the audit gap this
/// sweep fixes: a completed in-person (QR + Bluetooth) pairing used to leave
/// no trace beyond a transient toast, and `verificationMethod` on the
/// contact row stayed `nil` even though `TrustVerificationMethod.inPerson`
/// already existed for exactly this.
///
/// Same "not yet wired into a build target" gap `PeerTrustEvaluatorTests`
/// already documents (only `QAudionEngine` has a runnable `swift test`
/// harness today) — written against a `ContactsListContainer(store:)`
/// constructed with NO `AppState` (its default), which is enough: every
/// path `recordProximityPairing` touches (`ContactsStore`, `DisplayName`)
/// works without one, and the `appState`-gated key-exchange trigger inside
/// `addScannedContact` simply no-ops when it is nil, exactly as it does for
/// a signed-out preview.
@MainActor
final class ContactsListContainerProximityPairingTests: XCTestCase {

    private var testUserIds: [String] = []
    private var store: ContactsStore!
    private var container: ContactsListContainer!

    override func setUp() {
        super.setUp()
        store = ContactsStore()
        container = ContactsListContainer(store: store)
    }

    override func tearDown() {
        for id in testUserIds { store.remove(userId: id) }
        testUserIds = []
        store = nil
        container = nil
        super.tearDown()
    }

    private func makePeerUserId() -> String {
        let id = "test-pairfb-\(UUID().uuidString)"
        testUserIds.append(id)
        return id
    }

    private func makeSummary(peerUserId: String,
                             serverCheckOutcome: ProximityServerCheckOutcome,
                             elapsedMs: Int = 1_234) -> ProximityPairingSummary {
        let peer = try! ProximityPeerIdentity(
            userId: peerUserId,
            signingPublicKey: Data(repeating: 0x11, count: 32),
            encryptionPublicKey: Data(repeating: 0x22, count: 32)
        )
        let result = ProximityPairingResult(
            role: .scanner, peer: peer, psk: Data(repeating: 0x33, count: 32),
            pskFingerprint: "deadbeef", sas: "123456", identityWarning: nil
        )
        return ProximityPairingSummary(result, serverCheckOutcome: serverCheckOutcome, elapsedMs: elapsedMs)
    }

    // MARK: - New contact, server confirmed → "verified"

    func test_newContact_serverConfirmed_isReportedAndPersistedAsVerified() {
        let peerUserId = makePeerUserId()
        let summary = makeSummary(peerUserId: peerUserId, serverCheckOutcome: .confirmed)

        let outcome = container.recordProximityPairing(summary)

        XCTAssertEqual(outcome.kind, .newContactVerified)
        XCTAssertFalse(outcome.isError)

        let stored = store.load().first(where: { $0.userId == peerUserId })
        XCTAssertNotNil(stored, "a brand-new contact must be added")
        XCTAssertTrue(stored?.isVerified ?? false, "server-confirmed ⇒ the existing isVerified rule grants verified")
        XCTAssertNotNil(stored?.proximityPairedAtMs, "the pairing date must be persisted regardless of wording")
        XCTAssertEqual(stored?.proximityServerConfirmed, true)
    }

    // MARK: - New contact, server check unavailable → "saved", never "verified"

    /// The exact rule the audit called out by name: "if the SAS was
    /// confirmed but the server check could not run, show 'Chiave di
    /// persona salvata' rather than 'verificato'" — this must never upgrade
    /// trust beyond what the existing `isVerified` logic already grants.
    func test_newContact_serverUnavailable_isReportedAsSavedNotVerified() {
        let peerUserId = makePeerUserId()
        let summary = makeSummary(peerUserId: peerUserId, serverCheckOutcome: .unavailable)

        let outcome = container.recordProximityPairing(summary)

        XCTAssertEqual(outcome.kind, .savedUnverified)
        XCTAssertFalse(outcome.isError)
        // Locale-independent: compare against BOTH shipped translations
        // rather than substring-matching a word (English "verification" —
        // as in "the check could not run" — legitimately contains
        // "verificat", so a naive `contains("verificat")` check would be a
        // false positive there; the real contract is which of the two
        // known strings this is, not a banned substring).
        XCTAssertTrue(
            ["Chiave salvata, verifica server non disponibile", "Key saved, server verification unavailable"]
                .contains(outcome.title),
            "unexpected title wording: \(outcome.title)"
        )

        let stored = store.load().first(where: { $0.userId == peerUserId })
        XCTAssertNotNil(stored, "the contact is still added -- only the wording/isVerified differ")
        XCTAssertFalse(stored?.isVerified ?? true, "must NOT upgrade trust beyond what serverIdentityConfirmed grants")
        XCTAssertNotNil(stored?.proximityPairedAtMs, "the pairing still happened and must be recorded")
        XCTAssertEqual(stored?.proximityServerConfirmed, false)
    }

    /// A server-side key MISMATCH must be treated the same as "unavailable"
    /// for wording/trust purposes — it is still not a confirmation.
    func test_newContact_serverMismatch_isAlsoReportedAsSavedNotVerified() {
        let peerUserId = makePeerUserId()
        let summary = makeSummary(peerUserId: peerUserId, serverCheckOutcome: .mismatch)

        let outcome = container.recordProximityPairing(summary)

        XCTAssertEqual(outcome.kind, .savedUnverified)
        XCTAssertFalse(store.load().first(where: { $0.userId == peerUserId })?.isVerified ?? true)
    }

    // MARK: - Already-known contact → history only, key/verified badge untouched

    /// Spec §12: a KNOWN contact's key and verified badge are never rewritten
    /// from this call site. Only the in-person pairing HISTORY (date +
    /// server outcome) is recorded — a pure addition, not a trust change.
    func test_existingContact_recordsHistoryOnly_neverRewritesKeyOrVerifiedBadge() {
        let peerUserId = makePeerUserId()
        let originalPubkey = Data(repeating: 0x99, count: 32)
        store.upsert(ContactsStore.StoredContact(
            userId: peerUserId, displayName: "Already Known", phoneHash: "abc",
            avatarUrl: nil, lastSeen: nil, isVerified: false, pubkey: originalPubkey
        ))

        let summary = makeSummary(peerUserId: peerUserId, serverCheckOutcome: .confirmed)
        let outcome = container.recordProximityPairing(summary)

        XCTAssertEqual(outcome.kind, .existingContact)
        XCTAssertFalse(outcome.isError)

        let stored = store.load().first(where: { $0.userId == peerUserId })
        XCTAssertEqual(stored?.pubkey, originalPubkey, "spec §12 -- a known contact's key is never rewritten from here")
        XCTAssertFalse(stored?.isVerified ?? true, "spec §12 -- nor is its verified badge, even when the server confirms")
        XCTAssertEqual(stored?.displayName, "Already Known")
        XCTAssertNotNil(stored?.proximityPairedAtMs, "the exchange still happened and must be recorded as history")
        XCTAssertEqual(stored?.proximityServerConfirmed, true)
    }
}
