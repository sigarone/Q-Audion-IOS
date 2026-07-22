import XCTest
@testable import QAudionApp
import QAudionEngine

/// W-ASSURANCE/W-FLOOR (ship steps 6/8) — pins two related, easy-to-get-wrong
/// invariants at `PeerTrustEvaluator`'s REAL call sites (not just against
/// `ContactsStore` in isolation — see `ContactsStoreTests
/// .test_reconstructingStoredContactWithoutPresenceFields_clearsThemToNil`
/// for that mechanism-only pin):
///
///   1. `acceptNewFingerprint` (an ACTUAL identity-key rotation) clears
///      `presenceAuth`/`presenceFloor` as an EMERGENT side effect of the
///      SAME `StoredContact` reconstruction that already clears
///      `verifiedFingerprintHex`/`verifiedAtMs`/`verificationMethod` — per
///      the design brief's explicit instruction to rely on this rather than
///      duplicate the clearing logic.
///   2. `markVerified` (a manual SAS/QR/anti-replay confirm — NOT an
///      identity change) must PRESERVE `presenceAuth`/`presenceFloor`
///      unchanged. Getting this backwards (i.e. accidentally omitting the
///      two fields here too) would silently wipe a physically-established
///      NFC presence floor on every ordinary manual-verify action — a real
///      regression this test exists specifically to catch.
///
/// NOTE (not yet wired into a build target): same gap `HeroPresenceLabelTests
/// .swift` already documents — this repo has no `QAudionAppTests` XCTest
/// target in `QAudionApp/project.yml` today, only `QAudionEngine` ships a
/// runnable `swift test`/`xcodebuild test` harness. Written against that gap
/// (a small, mechanical `project.yml` addition later) rather than left
/// unwritten — this session has no macOS/Xcode/Swift toolchain available to
/// validate either the test or a project.yml change. See the task report for
/// the full reasoning and the manual verification performed instead.
///
/// Uses the REAL `UserDefaults.standard`-backed `ContactsStore()` (both
/// `PeerTrustEvaluator` functions under test construct their own
/// `ContactsStore()`/`PeerIdentityPinStore()` internally with no injection
/// point — a pre-existing constraint of that type, not something this test
/// works around) with a randomised, collision-proof `userId` per test and
/// explicit teardown cleanup, so this never touches real app data even once
/// a build target does exist to run it.
final class PeerTrustEvaluatorTests: XCTestCase {

    private var testUserIds: [String] = []

    override func tearDown() {
        let store = ContactsStore()
        for id in testUserIds {
            store.remove(userId: id)
            PeerIdentityPinStore().wipe(contactId: id)
        }
        testUserIds = []
        super.tearDown()
    }

    private func makeTestUserId() -> String {
        let id = "test-peertrust-\(UUID().uuidString)"
        testUserIds.append(id)
        return id
    }

    func test_acceptNewFingerprint_clearsPresenceAuthAndFloor() {
        let userId = makeTestUserId()
        let peerIdentityKey = Data(repeating: 0xAA, count: 32)
        let store = ContactsStore()
        let auth = ContactsStore.PresenceAuth(
            tier: .nfcPresent, keyFingerprint: String(repeating: "ab", count: 32),
            peerIdentityKey: peerIdentityKey, firstConfirmedCallId: "call-1",
            firstConfirmedAt: 1_700_000_000_000, confirmedCallCount: 2,
            witnessTier: "secure_element"
        )
        store.upsert(ContactsStore.StoredContact(
            userId: userId, displayName: "Test Peer", phoneHash: "abc",
            avatarUrl: nil, lastSeen: nil, isVerified: true,
            presenceAuth: auth, presenceFloor: true
        ))
        XCTAssertNotNil(store.load().first(where: { $0.userId == userId })?.presenceAuth, "precondition")

        let newKey = Data(repeating: 0xBB, count: 32)
        PeerTrustEvaluator.acceptNewFingerprint(peerUserId: userId, newPeerIkEdPub: newKey)

        let reloaded = store.load().first(where: { $0.userId == userId })
        XCTAssertNil(reloaded?.presenceAuth, "an ACTUAL identity rotation must clear the presence record")
        XCTAssertNil(reloaded?.presenceFloor)
    }

    func test_markVerified_preservesPresenceAuthAndFloor() {
        let userId = makeTestUserId()
        let peerIdentityKey = Data(repeating: 0xCC, count: 32)
        let store = ContactsStore()
        let auth = ContactsStore.PresenceAuth(
            tier: .nfcPresent, keyFingerprint: String(repeating: "cd", count: 32),
            peerIdentityKey: peerIdentityKey, firstConfirmedCallId: "call-1",
            firstConfirmedAt: 1_700_000_000_000, confirmedCallCount: 3,
            witnessTier: "secure_element"
        )
        store.upsert(ContactsStore.StoredContact(
            userId: userId, displayName: "Test Peer", phoneHash: "abc",
            avatarUrl: nil, lastSeen: nil, isVerified: false,
            presenceAuth: auth, presenceFloor: true
        ))

        PeerTrustEvaluator.markVerified(peerUserId: userId, method: .qr, fingerprintHex: "somefingerprint")

        let reloaded = store.load().first(where: { $0.userId == userId })
        XCTAssertTrue(reloaded?.isVerified ?? false, "sanity: the manual verify itself must still apply")
        XCTAssertEqual(reloaded?.presenceAuth, auth, "a manual SAS/QR verify is NOT an identity change -- presenceAuth must be untouched")
        XCTAssertEqual(reloaded?.presenceFloor, true)
    }
}
