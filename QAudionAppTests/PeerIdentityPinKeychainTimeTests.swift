import XCTest
import CryptoKit
import Security
@testable import QAudionApp
import QAudionEngine

/// The pinned-at time of a peer key, against the real Keychain of the test host and an injected clock (no sleeps): every add and
/// every replacement stamps the time, seeing the same key again never moves it, an item written before the stamp existed reads its
/// Keychain modification date, and only the exact (peer, device) item answers.
final class PeerIdentityPinKeychainTimeTests: XCTestCase {
    private var ids: [String] = []
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private let service = "com.bcrypto.qaudion.peerpins"

    override func tearDown() {
        for id in ids { PeerIdentityPinStore().wipe(contactId: id) }
        ids = []
        super.tearDown()
    }

    private func store() -> PeerIdentityPinStore {
        PeerIdentityPinStore(clock: { [unowned self] in self.now })
    }

    private func newId() -> String {
        let id = "test-pintime-\(UUID().uuidString)"
        ids.append(id)
        return id
    }

    private func newKey() -> Data {
        Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    }

    private let hour: TimeInterval = 3_600

    func testTheFirstPinOfADeviceStampsTheTime() {
        let id = newId()
        let s = store()
        XCTAssertNil(s.pinnedAt(contactId: id, deviceId: "d1"))
        XCTAssertEqual(s.pinOrMatch(contactId: id, ed25519Pub: newKey(), deviceId: "d1"), .pinnedNew)
        XCTAssertEqual(s.pinnedAt(contactId: id, deviceId: "d1"), now)
    }

    func testSeeingTheSameKeyAgainNeverMovesTheTime() {
        let id = newId()
        let s = store()
        let key = newKey()
        let first = now
        XCTAssertEqual(s.pinOrMatch(contactId: id, ed25519Pub: key, deviceId: "d1"), .pinnedNew)
        now = first.addingTimeInterval(10 * hour)
        XCTAssertEqual(s.pinOrMatch(contactId: id, ed25519Pub: key, deviceId: "d1"), .match)
        XCTAssertEqual(s.repin(contactId: id, ed25519Pub: key, deviceId: "d1"), .unchanged)
        XCTAssertEqual(s.pinnedAt(contactId: id, deviceId: "d1"), first, "a write that is not a replacement does not reset the age")
    }

    func testAReplacementOfTheKeyResetsTheAgeAndSoDoesAnAddThroughRepin() {
        let id = newId()
        let s = store()
        let first = now
        // add through repin
        XCTAssertEqual(s.repin(contactId: id, ed25519Pub: newKey(), deviceId: "d1"), .added)
        XCTAssertEqual(s.pinnedAt(contactId: id, deviceId: "d1"), first)
        // replacement through repin (SAS-confirmed rotation, set-proven rotation after a number move or a reinstall)
        now = first.addingTimeInterval(30 * hour)
        let second = newKey()
        XCTAssertEqual(s.repin(contactId: id, ed25519Pub: second, deviceId: "d1"), .overwritten)
        XCTAssertEqual(s.exactPinnedKey(contactId: id, deviceId: "d1"), second)
        XCTAssertEqual(s.pinnedAt(contactId: id, deviceId: "d1"), now, "the replaced key starts its own 24 hours")
        // a mismatch writes nothing
        now = first.addingTimeInterval(60 * hour)
        XCTAssertEqual(s.pinOrMatch(contactId: id, ed25519Pub: newKey(), deviceId: "d1"), .mismatch)
        XCTAssertEqual(s.pinnedAt(contactId: id, deviceId: "d1"), first.addingTimeInterval(30 * hour))
    }

    func testASecondDeviceOfThePeerHasItsOwnTime() {
        let id = newId()
        let s = store()
        let first = now
        XCTAssertEqual(s.pinOrMatch(contactId: id, ed25519Pub: newKey(), deviceId: "d1"), .pinnedNew)
        now = first.addingTimeInterval(5 * hour)
        XCTAssertEqual(s.pinOrMatch(contactId: id, ed25519Pub: newKey(), deviceId: "d2"), .pinnedNew)
        XCTAssertEqual(s.pinnedAt(contactId: id, deviceId: "d1"), first)
        XCTAssertEqual(s.pinnedAt(contactId: id, deviceId: "d2"), now)
    }

    func testOnlyTheExactDeviceAnswersAndTheLegacyItemIsNeverBorrowed() {
        let id = newId()
        let s = store()
        let legacy = newKey()
        XCTAssertEqual(s.pinOrMatch(contactId: id, ed25519Pub: legacy), .pinnedNew)
        XCTAssertNil(s.pinnedAt(contactId: id, deviceId: nil))
        XCTAssertNil(s.pinnedAt(contactId: id, deviceId: ""))
        XCTAssertNil(s.pinnedAt(contactId: id, deviceId: "d1"), "no pin of its own: no time, however old the legacy item is")
        XCTAssertNil(s.exactPinnedKey(contactId: id, deviceId: "d1"))
        XCTAssertEqual(s.pinnedKey(contactId: id, deviceId: "d1"), legacy, "the old read still falls back; the new ones do not")
    }

    func testAnItemWrittenBeforeTheStampReadsItsModificationDateAndAReplacementStampsIt() {
        let id = newId()
        let account = id + "|d1"
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: newKey(),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let before = Date()
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        let after = Date()
        let s = store()
        let read = s.pinnedAt(contactId: id, deviceId: "d1")
        // The Keychain date is the time of the write: never earlier than the item, so the age is never overstated.
        XCTAssertNotNil(read)
        XCTAssertGreaterThanOrEqual(read?.timeIntervalSince1970 ?? 0, before.timeIntervalSince1970 - 2)
        XCTAssertLessThanOrEqual(read?.timeIntervalSince1970 ?? .infinity, after.timeIntervalSince1970 + 2)
        // The same key again writes nothing: the date stays.
        let existing = s.exactPinnedKey(contactId: id, deviceId: "d1")!
        XCTAssertEqual(s.repin(contactId: id, ed25519Pub: existing, deviceId: "d1"), .unchanged)
        XCTAssertEqual(s.pinnedAt(contactId: id, deviceId: "d1"), read)
        // A replacement stamps the injected time.
        XCTAssertEqual(s.repin(contactId: id, ed25519Pub: newKey(), deviceId: "d1"), .overwritten)
        XCTAssertEqual(s.pinnedAt(contactId: id, deviceId: "d1"), now)
    }
}
