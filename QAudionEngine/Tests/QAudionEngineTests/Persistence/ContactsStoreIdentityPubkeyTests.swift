import XCTest
@testable import QAudionEngine

/// Covers `setIdentityPubkeyIfAbsent`, the write path that lets a call teach
/// the mesh radar who a device belongs to.
///
/// `pubkey` is the only field `MeshFeature.nodeId(forContactPubkey:)` can
/// identify a nearby device by, and its sole writer used to be the in-person QR
/// pairing flow — so a contact the user calls every day still rendered as
/// "Dispositivo non identificato". The call path already verifies the peer's
/// published key bundle (`verifyPeerBundleSelfSig`) before using it, so the key
/// it holds is authenticated; this store method is what remembers it.
///
/// The behaviour that most needs pinning is the refusal. A differing key is an
/// identity CHANGE, and silently overwriting would launder a rotation past
/// `verifiedFingerprintHex`, whose whole job is to notice the peer's key no
/// longer matches what the user verified.
final class ContactsStoreIdentityPubkeyTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: ContactsStore!

    private let keyA = Data(repeating: 0xA1, count: 32)
    private let keyB = Data(repeating: 0xB2, count: 32)
    private let userId = "550e8400-e29b-41d4-a716-446655440000"

    override func setUp() {
        super.setUp()
        // Same reason as ContactsStoreTests: a unit-test bundle has no usable
        // keychain, so inject a fixed key rather than asking for one.
        ContactsStore.testKeyOverride = Data(repeating: 0x2b, count: 32)
        let suite = "test.contactsstore.identity.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        // swiftlint:disable:next force_unwrapping
        defaults = UserDefaults(suiteName: suite)!
        store = ContactsStore(defaults: defaults)
    }

    override func tearDown() {
        ContactsStore.testKeyOverride = nil
        store = nil
        defaults = nil
        super.tearDown()
    }

    private func seedContact(pubkey: Data? = nil, verifiedFingerprint: String? = nil) {
        store.upsert(
            ContactsStore.StoredContact(
                userId: userId,
                displayName: "Marco Levi",
                phoneHash: "hash",
                avatarUrl: nil,
                lastSeen: nil,
                isVerified: verifiedFingerprint != nil,
                pubkey: pubkey,
                verifiedFingerprintHex: verifiedFingerprint,
                verifiedAtMs: verifiedFingerprint != nil ? 1_700_000_000_000 : nil,
                verificationMethod: verifiedFingerprint != nil ? "in-person" : nil
            )
        )
    }

    func test_fillsAnEmptyPubkey_soACalledContactBecomesRecognisable() {
        seedContact(pubkey: nil)
        XCTAssertEqual(store.setIdentityPubkeyIfAbsent(userId: userId, pubkey: keyA), .filled)
        XCTAssertEqual(store.findPubkey(userId: userId), keyA)
    }

    func test_repeatingTheSameKeyIsANoOp() {
        seedContact(pubkey: keyA)
        XCTAssertEqual(store.setIdentityPubkeyIfAbsent(userId: userId, pubkey: keyA), .alreadyPresent)
        XCTAssertEqual(store.findPubkey(userId: userId), keyA)
    }

    func test_aDifferentKeyIsRefused_andTheStoredOneIsUntouched() {
        seedContact(pubkey: keyA)
        XCTAssertEqual(store.setIdentityPubkeyIfAbsent(userId: userId, pubkey: keyB), .mismatch)
        XCTAssertEqual(
            store.findPubkey(userId: userId),
            keyA,
            "a rotation must go through the identity-change flow, not through placing a call"
        )
    }

    func test_refusingAMismatchLeavesTheVerificationPinIntact() {
        // The pin is what turns "this key changed" into a visible
        // .identityChanged downgrade. If a mismatch could quietly rewrite the
        // key, the pin would still hold the OLD fingerprint and the change
        // would never surface.
        seedContact(pubkey: keyA, verifiedFingerprint: "abc123")
        _ = store.setIdentityPubkeyIfAbsent(userId: userId, pubkey: keyB)
        let stored = store.load().first { $0.userId == userId }
        XCTAssertEqual(stored?.verifiedFingerprintHex, "abc123")
        XCTAssertEqual(stored?.verificationMethod, "in-person")
        XCTAssertEqual(stored?.pubkey, keyA)
    }

    func test_fillingPreservesEverythingElseOnTheRow() {
        seedContact(pubkey: nil, verifiedFingerprint: "abc123")
        XCTAssertEqual(store.setIdentityPubkeyIfAbsent(userId: userId, pubkey: keyA), .filled)
        let stored = store.load().first { $0.userId == userId }
        XCTAssertEqual(stored?.pubkey, keyA)
        XCTAssertEqual(stored?.displayName, "Marco Levi")
        XCTAssertEqual(stored?.verifiedFingerprintHex, "abc123")
        XCTAssertEqual(stored?.verifiedAtMs, 1_700_000_000_000)
        XCTAssertTrue(stored?.isVerified == true)
    }

    func test_unknownContactAndEmptyKeyAreRejected() {
        XCTAssertEqual(store.setIdentityPubkeyIfAbsent(userId: userId, pubkey: keyA), .unknownContact)
        seedContact(pubkey: nil)
        XCTAssertEqual(store.setIdentityPubkeyIfAbsent(userId: userId, pubkey: Data()), .mismatch)
        XCTAssertNil(store.findPubkey(userId: userId))
    }
}
