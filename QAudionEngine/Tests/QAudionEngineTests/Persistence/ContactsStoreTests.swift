import XCTest
@testable import QAudionEngine

final class ContactsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: ContactsStore!

    override func setUp() {
        super.setUp()
        let suite = "test.contactsstore.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)!
        store = ContactsStore(defaults: defaults)
    }

    override func tearDown() {
        store = nil
        defaults = nil
        super.tearDown()
    }

    func test_load_emptyByDefault() {
        XCTAssertTrue(store.load().isEmpty)
    }

    func test_save_then_load() {
        let c = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice",
            phoneHash: String(repeating: "ab", count: 32),
            avatarUrl: nil, lastSeen: nil, isVerified: true
        )
        store.save([c])
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, c)
    }

    func test_upsert_addsNewContact() {
        let c = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: false
        )
        store.upsert(c)
        XCTAssertEqual(store.load().count, 1)
    }

    func test_upsert_updatesExisting() {
        let c1 = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: false
        )
        let c2 = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice (verified)",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: true
        )
        store.upsert(c1)
        store.upsert(c2)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.displayName, "Alice (verified)")
    }

    func test_remove_deletesContact() {
        let c = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: false
        )
        store.save([c])
        store.remove(userId: "u-1")
        XCTAssertTrue(store.load().isEmpty)
    }

    func test_wipeAll_clearsEverything() {
        let c = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: false
        )
        store.save([c])
        store.wipeAll()
        XCTAssertTrue(store.load().isEmpty)
    }

    // MARK: - W14.F pubkey persistence

    func test_pubkey_defaultsToNilWhenNotProvided() {
        let c = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: false
        )
        XCTAssertNil(c.pubkey, "Default-arg init should produce a nil pubkey")
    }

    func test_pubkey_roundTripsThroughCodable() {
        let pk = Data(repeating: 0xAB, count: 32)
        let c = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: true,
            pubkey: pk
        )
        store.save([c])
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.pubkey, pk)
    }

    func test_findPubkey_returnsValueForKnownUserId() {
        let pk = Data(repeating: 0x42, count: 32)
        let c = ContactsStore.StoredContact(
            userId: "u-known", displayName: "Bob",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: true,
            pubkey: pk
        )
        store.save([c])
        XCTAssertEqual(store.findPubkey(userId: "u-known"), pk)
    }

    func test_findPubkey_returnsNilForUnknownUserId() {
        XCTAssertNil(store.findPubkey(userId: "u-missing"))
    }

    func test_findPubkey_returnsNilForLegacyContactWithoutPubkey() {
        let c = ContactsStore.StoredContact(
            userId: "u-legacy", displayName: "Old Row",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: false
        )
        store.save([c])
        XCTAssertNil(store.findPubkey(userId: "u-legacy"),
                     "Legacy rows persisted without pubkey field must surface as nil")
    }

    /// Forward-compatibility: a row encoded by an old build (no pubkey field)
    /// should decode cleanly with pubkey=nil. Simulates that by hand-writing
    /// JSON that mirrors the pre-W14.F shape.
    func test_legacyJsonWithoutPubkey_decodesWithNilPubkey() throws {
        let legacyJson = Data("""
        [{"userId":"u-old","displayName":"Old","phoneHash":"abc","isVerified":false}]
        """.utf8)
        defaults.set(legacyJson, forKey: "qaudion.contacts.list")
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.userId, "u-old")
        XCTAssertNil(loaded.first?.pubkey)
    }

    // MARK: - W-ASSURANCE/W-FLOOR (ship steps 6/8) — presenceAuth/presenceFloor

    func test_presenceAuth_defaultsToNilWhenNotProvided() {
        let c = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice", phoneHash: "abc",
            avatarUrl: nil, lastSeen: nil, isVerified: false
        )
        XCTAssertNil(c.presenceAuth)
        XCTAssertNil(c.presenceFloor)
    }

    func test_presenceAuth_roundTripsThroughCodable() {
        let peerKey = Data(repeating: 0xCD, count: 32)
        let auth = ContactsStore.PresenceAuth(
            tier: .nfcPresent, keyFingerprint: String(repeating: "ab", count: 32),
            peerIdentityKey: peerKey, firstConfirmedCallId: "call-1",
            firstConfirmedAt: 1_700_000_000_000, confirmedCallCount: 1,
            witnessTier: "secure_element"
        )
        let c = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice", phoneHash: "abc",
            avatarUrl: nil, lastSeen: nil, isVerified: false,
            presenceAuth: auth, presenceFloor: true
        )
        store.save([c])
        let loaded = store.load()
        XCTAssertEqual(loaded.first?.presenceAuth, auth)
        XCTAssertEqual(loaded.first?.presenceFloor, true)
    }

    func test_legacyJsonWithoutPresenceAuth_decodesWithNilPresenceAuthAndFloor() {
        let legacyJson = Data("""
        [{"userId":"u-old","displayName":"Old","phoneHash":"abc","isVerified":false}]
        """.utf8)
        defaults.set(legacyJson, forKey: "qaudion.contacts.list")
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertNil(loaded.first?.presenceAuth)
        XCTAssertNil(loaded.first?.presenceFloor)
    }

    // MARK: - applyAssuranceOutcome — S2 (.nfcAuthenticated) write path

    private let peerKeyA = Data(repeating: 0xAA, count: 32)
    private let peerKeyB = Data(repeating: 0xBB, count: 32)

    private func seedContact(userId: String = "u-1", presenceAuth: ContactsStore.PresenceAuth? = nil, presenceFloor: Bool? = nil) {
        store.upsert(ContactsStore.StoredContact(
            userId: userId, displayName: "Alice", phoneHash: "abc",
            avatarUrl: nil, lastSeen: nil, isVerified: false,
            presenceAuth: presenceAuth, presenceFloor: presenceFloor
        ))
    }

    func test_applyAssuranceOutcome_noExistingContact_returnsNil() {
        let result = store.applyAssuranceOutcome(
            peerUserId: "u-unknown", peerIdentityKey: peerKeyA, keyFingerprint: "fp",
            callId: "call-1", state: .nfcAuthenticated, witnessOk: true, mediaDwellMs: 20_000
        )
        XCTAssertNil(result)
    }

    func test_applyAssuranceOutcome_s2FirstConfirmation_writesPresenceAuthAndFloor() {
        seedContact()
        let result = store.applyAssuranceOutcome(
            peerUserId: "u-1", peerIdentityKey: peerKeyA, keyFingerprint: "fp-1",
            callId: "call-first", state: .nfcAuthenticated, witnessOk: true, mediaDwellMs: 10_000
        )
        XCTAssertEqual(result?.presenceAuth?.tier, .nfcPresent)
        XCTAssertEqual(result?.presenceAuth?.firstConfirmedCallId, "call-first")
        XCTAssertEqual(result?.presenceAuth?.confirmedCallCount, 1)
        XCTAssertEqual(result?.presenceAuth?.peerIdentityKey, peerKeyA)
        XCTAssertEqual(result?.presenceAuth?.witnessTier, "secure_element")
        XCTAssertEqual(result?.presenceAuth?.status, .active)
        XCTAssertEqual(result?.presenceFloor, true)
        // Persisted, not just returned:
        XCTAssertEqual(store.load().first?.presenceAuth?.confirmedCallCount, 1)
    }

    func test_applyAssuranceOutcome_s2BelowDwellFloor_isNoOp() {
        seedContact()
        let result = store.applyAssuranceOutcome(
            peerUserId: "u-1", peerIdentityKey: peerKeyA, keyFingerprint: "fp-1",
            callId: "call-1", state: .nfcAuthenticated, witnessOk: true, mediaDwellMs: 9_999
        )
        XCTAssertNil(result?.presenceAuth)
        XCTAssertNil(result?.presenceFloor)
        XCTAssertNil(store.load().first?.presenceAuth)
    }

    func test_applyAssuranceOutcome_s2ContinuingSameIdentity_incrementsCountPreservesFirstConfirmed() {
        let prior = ContactsStore.PresenceAuth(
            tier: .nfcPresent, keyFingerprint: "fp-old", peerIdentityKey: peerKeyA,
            firstConfirmedCallId: "call-first", firstConfirmedAt: 1_000, confirmedCallCount: 3,
            witnessTier: "secure_element", status: .active
        )
        seedContact(presenceAuth: prior, presenceFloor: true)
        let result = store.applyAssuranceOutcome(
            peerUserId: "u-1", peerIdentityKey: peerKeyA, keyFingerprint: "fp-new",
            callId: "call-fourth", state: .nfcAuthenticated, witnessOk: false, mediaDwellMs: 15_000
        )
        XCTAssertEqual(result?.presenceAuth?.confirmedCallCount, 4, "must increment, not reset")
        XCTAssertEqual(result?.presenceAuth?.firstConfirmedCallId, "call-first", "must never overwrite the FIRST confirming call")
        XCTAssertEqual(result?.presenceAuth?.firstConfirmedAt, 1_000)
        XCTAssertEqual(result?.presenceAuth?.witnessTier, "backup_restore", "witnessTier reflects the LATEST confirming call")
        XCTAssertEqual(result?.presenceAuth?.status, .active, "a fresh S2 call revives an active record")
    }

    func test_applyAssuranceOutcome_s2DifferentIdentityKeyThanExistingRecord_startsFresh() {
        let prior = ContactsStore.PresenceAuth(
            tier: .nfcPresent, keyFingerprint: "fp-old", peerIdentityKey: peerKeyA,
            firstConfirmedCallId: "call-first", firstConfirmedAt: 1_000, confirmedCallCount: 5,
            witnessTier: "secure_element", status: .active
        )
        seedContact(presenceAuth: prior, presenceFloor: true)
        let result = store.applyAssuranceOutcome(
            peerUserId: "u-1", peerIdentityKey: peerKeyB, keyFingerprint: "fp-new",
            callId: "call-new-identity", state: .nfcAuthenticated, witnessOk: true, mediaDwellMs: 12_000
        )
        XCTAssertEqual(result?.presenceAuth?.confirmedCallCount, 1, "a record for a DIFFERENT identity key must start fresh, not increment the stale one")
        XCTAssertEqual(result?.presenceAuth?.firstConfirmedCallId, "call-new-identity")
        XCTAssertEqual(result?.presenceAuth?.peerIdentityKey, peerKeyB)
    }

    // MARK: - applyAssuranceOutcome — S3 (.nfcIdentityMismatch) revokes

    func test_applyAssuranceOutcome_s3_revokesPresenceAuthAndFloorEntirely() {
        let prior = ContactsStore.PresenceAuth(
            tier: .nfcPresent, keyFingerprint: "fp-old", peerIdentityKey: peerKeyA,
            firstConfirmedCallId: "call-first", firstConfirmedAt: 1_000, confirmedCallCount: 2,
            witnessTier: "secure_element", status: .active
        )
        seedContact(presenceAuth: prior, presenceFloor: true)
        let result = store.applyAssuranceOutcome(
            peerUserId: "u-1", peerIdentityKey: peerKeyB, keyFingerprint: "fp-mismatch",
            callId: "call-mismatch", state: .nfcIdentityMismatch, witnessOk: true, mediaDwellMs: 30_000
        )
        XCTAssertNil(result?.presenceAuth, "S3 REVOKES the whole record, unlike S1/S7's suspend")
        XCTAssertEqual(result?.presenceFloor, false)
    }

    func test_applyAssuranceOutcome_s3_noExistingRecord_isNoOp() {
        seedContact() // no presenceAuth to begin with
        let result = store.applyAssuranceOutcome(
            peerUserId: "u-1", peerIdentityKey: peerKeyA, keyFingerprint: "fp",
            callId: "call-1", state: .nfcIdentityMismatch, witnessOk: true, mediaDwellMs: 30_000
        )
        XCTAssertNil(result?.presenceAuth)
        XCTAssertNil(result?.presenceFloor)
    }

    // MARK: - applyAssuranceOutcome — S1/S7 suspend (never downgrade further)

    func test_applyAssuranceOutcome_s1KcFailed_suspendsExistingRecord_preservesEverythingElse() {
        let prior = ContactsStore.PresenceAuth(
            tier: .nfcPresent, keyFingerprint: "fp-old", peerIdentityKey: peerKeyA,
            firstConfirmedCallId: "call-first", firstConfirmedAt: 1_000, confirmedCallCount: 3,
            witnessTier: "secure_element", status: .active
        )
        seedContact(presenceAuth: prior, presenceFloor: true)
        let result = store.applyAssuranceOutcome(
            peerUserId: "u-1", peerIdentityKey: peerKeyA, keyFingerprint: "fp",
            callId: "call-failed-kc", state: .kcFailed, witnessOk: false, mediaDwellMs: 0
        )
        XCTAssertEqual(result?.presenceAuth?.status, .suspended)
        XCTAssertEqual(result?.presenceAuth?.confirmedCallCount, 3, "S1/S7 must NEVER downgrade confirmedCallCount")
        XCTAssertEqual(result?.presenceAuth?.firstConfirmedCallId, "call-first")
        XCTAssertEqual(result?.presenceFloor, true, "the floor itself is untouched by a suspend")
    }

    func test_applyAssuranceOutcome_s7ExpectedNfcStripped_suspendsExistingRecord() {
        let prior = ContactsStore.PresenceAuth(
            tier: .nfcPresent, keyFingerprint: "fp-old", peerIdentityKey: peerKeyA,
            firstConfirmedCallId: "call-first", firstConfirmedAt: 1_000, confirmedCallCount: 2,
            witnessTier: "secure_element", status: .active
        )
        seedContact(presenceAuth: prior, presenceFloor: true)
        let result = store.applyAssuranceOutcome(
            peerUserId: "u-1", peerIdentityKey: peerKeyA, keyFingerprint: "fp",
            callId: "call-stripped", state: .expectedNfcStripped, witnessOk: false, mediaDwellMs: 0
        )
        XCTAssertEqual(result?.presenceAuth?.status, .suspended)
        XCTAssertEqual(result?.presenceAuth?.confirmedCallCount, 2)
    }

    func test_applyAssuranceOutcome_s1_noExistingRecord_isNoOp() {
        seedContact() // nothing to suspend
        let result = store.applyAssuranceOutcome(
            peerUserId: "u-1", peerIdentityKey: peerKeyA, keyFingerprint: "fp",
            callId: "call-1", state: .kcFailed, witnessOk: false, mediaDwellMs: 0
        )
        XCTAssertNil(result?.presenceAuth)
    }

    func test_applyAssuranceOutcome_s1_alreadySuspended_isIdempotentNoOp() {
        let prior = ContactsStore.PresenceAuth(
            tier: .nfcPresent, keyFingerprint: "fp-old", peerIdentityKey: peerKeyA,
            firstConfirmedCallId: "call-first", firstConfirmedAt: 1_000, confirmedCallCount: 3,
            witnessTier: "secure_element", status: .suspended
        )
        seedContact(presenceAuth: prior, presenceFloor: true)
        let result = store.applyAssuranceOutcome(
            peerUserId: "u-1", peerIdentityKey: peerKeyA, keyFingerprint: "fp",
            callId: "call-2", state: .kcFailed, witnessOk: false, mediaDwellMs: 0
        )
        XCTAssertEqual(result?.presenceAuth, prior, "already-suspended must not churn the record again")
    }

    // MARK: - applyAssuranceOutcome — every other state is a no-op

    func test_applyAssuranceOutcome_everyOtherState_leavesRecordUntouched() {
        let prior = ContactsStore.PresenceAuth(
            tier: .nfcPresent, keyFingerprint: "fp-old", peerIdentityKey: peerKeyA,
            firstConfirmedCallId: "call-first", firstConfirmedAt: 1_000, confirmedCallCount: 1,
            witnessTier: "secure_element", status: .active
        )
        let untouchedStates: [AssuranceState] = [
            .peerLegacy, .nfcUnattestable, .identityUnverified, .nfcPresentUnconfirmed,
            .pskConfirmed, .pskUnconfirmed, .pqcOnly,
        ]
        for state in untouchedStates {
            seedContact(presenceAuth: prior, presenceFloor: true)
            let result = store.applyAssuranceOutcome(
                peerUserId: "u-1", peerIdentityKey: peerKeyA, keyFingerprint: "fp",
                callId: "call-x", state: state, witnessOk: true, mediaDwellMs: 99_999
            )
            XCTAssertEqual(result?.presenceAuth, prior, "\(state) must not touch presenceAuth")
            XCTAssertEqual(result?.presenceFloor, true, "\(state) must not touch presenceFloor")
        }
    }

    // MARK: - PeerTrustEvaluator emergent-clear-on-identity-change contract
    // (design brief: "rely on it, don't duplicate the logic" — see
    // PeerTrustEvaluator.acceptNewFingerprint's own doc comment). This pins
    // the MECHANISM (ContactsStore/StoredContact honour omitted-field-means-
    // nil), independent of QAudionApp (which has no wired XCTest target —
    // see QAudionAppTests/PeerTrustEvaluatorTests.swift for the real
    // call-path pin and why it can't run in this repo today).

    func test_reconstructingStoredContactWithoutPresenceFields_clearsThemToNil() {
        let auth = ContactsStore.PresenceAuth(
            tier: .nfcPresent, keyFingerprint: "fp", peerIdentityKey: peerKeyA,
            firstConfirmedCallId: "call-1", firstConfirmedAt: 1_000, confirmedCallCount: 1,
            witnessTier: "secure_element"
        )
        seedContact(presenceAuth: auth, presenceFloor: true)
        // Mirrors PeerTrustEvaluator.acceptNewFingerprint's own reconstruction
        // EXACTLY: every field threaded through from `existing` EXCEPT
        // presenceAuth/presenceFloor, which are simply omitted.
        let existing = store.load().first(where: { $0.userId == "u-1" })!
        store.upsert(ContactsStore.StoredContact(
            userId: existing.userId, displayName: existing.displayName, phoneHash: existing.phoneHash,
            avatarUrl: existing.avatarUrl, lastSeen: existing.lastSeen, isVerified: false,
            pubkey: existing.pubkey, verifiedFingerprintHex: nil, verifiedAtMs: nil, verificationMethod: nil
        ))
        let reloaded = store.load().first(where: { $0.userId == "u-1" })
        XCTAssertNil(reloaded?.presenceAuth, "identity-change reconstruction must clear presenceAuth as an emergent side effect of omission")
        XCTAssertNil(reloaded?.presenceFloor)
    }
}
