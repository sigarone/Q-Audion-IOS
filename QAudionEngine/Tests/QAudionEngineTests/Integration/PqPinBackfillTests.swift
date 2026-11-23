import XCTest
@testable import QAudionEngine

/// The backfill of the kept second public key for pins made before keys were kept: the key id is derived from the fetched key
/// (SHA-256 of its bytes) and compared with the one the record names; nothing kept is ever replaced.
final class PqPinBackfillTests: XCTestCase {

    private let user = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private let signer = Data(repeating: 0x31, count: 32)

    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func fire() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private var log = LogBox()

    override func setUp() {
        super.setUp()
        let box = LogBox()
        log = box
        CapsBindLog.setSink { box.add($0) }
    }

    override func tearDown() {
        CapsBindLog.setSink(nil)
        super.tearDown()
    }

    private func key(_ byte: UInt8) throws -> Pqsig.MlDsaPublicKey {
        try XCTUnwrap(Pqsig.keyFromSeed(Data(repeating: byte, count: 32))).publicKey
    }

    private func hex(_ data: Data) -> String { HybridBundleVerifier.hex(data) }

    private func verified(_ key: Pqsig.MlDsaPublicKey, claiming id: Data? = nil) -> MldsaIdentityPublication.VerifiedPeer {
        MldsaIdentityPublication.VerifiedPeer(pub: key.bytes(), keyId: id ?? key.keyId(), createdMs: 1, gen: 0)
    }

    private func bookNaming(_ key: Pqsig.MlDsaPublicKey) -> CapsPinBook {
        let book = CapsPinBook(persistence: MemoryCapsPinPersistence())
        book.putRecord(peerUserId: user, signerKey: signer,
                       record: CapsPinRecord(caps: ["capsBindV1", "sigHybridV1"], mldsaKeyId: hex(key.keyId()), pqState: "pinned"))
        return book
    }

    func testAKeyWhoseDerivedIdIsThePinnedOneIsStored() async throws {
        let a = try key(0x41)
        let book = bookNaming(a)
        XCTAssertEqual(book.pinsWithoutKeptKey().count, 1)
        XCTAssertEqual(book.pinsWithoutKeptKey().first?.peerUserId, user)
        XCTAssertEqual(book.pinsWithoutKeptKey().first?.signerKey, signer)
        await PqPinBackfill.run(book: book, spacing: 0, callActive: { false }, fetch: { _, _ in [self.verified(a)] })
        XCTAssertEqual(book.pinnedKey(peerUserId: user, signerKey: signer), a.bytes())
        XCTAssertEqual(log.lines, ["PQ-BACKFILL result=stored"])
        XCTAssertTrue(book.pinsWithoutKeptKey().isEmpty)
    }

    func testADifferentKeyIsNotStoredEvenWhenItClaimsThePinnedId() async throws {
        let a = try key(0x41)
        let b = try key(0x42)
        let book = bookNaming(a)
        // the fetched record CLAIMS A's id but carries B's bytes: the id is derived from the bytes
        await PqPinBackfill.run(book: book, spacing: 0, callActive: { false }, fetch: { _, _ in [self.verified(b, claiming: a.keyId())] })
        XCTAssertNil(book.pinnedKey(peerUserId: user, signerKey: signer))
        XCTAssertEqual(log.lines, ["PQ-BACKFILL result=mismatch"])
        // the record itself is untouched
        XCTAssertEqual(book.record(peerUserId: user, signerKey: signer)?.mldsaKeyId, hex(a.keyId()))
    }

    func testAFailedFetchIsLoggedAndStoresNothing() async throws {
        let a = try key(0x41)
        let book = bookNaming(a)
        await PqPinBackfill.run(book: book, spacing: 0, callActive: { false }, fetch: { _, _ in [] })
        XCTAssertNil(book.pinnedKey(peerUserId: user, signerKey: signer))
        XCTAssertEqual(log.lines, ["PQ-BACKFILL result=failed"])
    }

    func testAKeptKeyIsNeverReplacedOrErased() async throws {
        let a = try key(0x41)
        let b = try key(0x42)
        let book = bookNaming(a)
        book.setPinnedKey(peerUserId: user, signerKey: signer, key: a.bytes())
        XCTAssertTrue(book.pinsWithoutKeptKey().isEmpty)
        // no record is looked at, nothing is fetched
        let fetches = Counter()
        await PqPinBackfill.run(book: book, spacing: 0, callActive: { false }, fetch: { _, _ in fetches.fire(); return [self.verified(b)] })
        XCTAssertEqual(fetches.count, 0)
        // the direct call refuses too, for the same key and for another one
        XCTAssertEqual(book.backfillPinnedKey(peerUserId: user, signerKey: signer, key: b.bytes()), .alreadyKept)
        XCTAssertEqual(book.backfillPinnedKey(peerUserId: user, signerKey: signer, key: a.bytes()), .alreadyKept)
        XCTAssertEqual(book.pinnedKey(peerUserId: user, signerKey: signer), a.bytes())
        XCTAssertTrue(log.lines.isEmpty)
        // a record that is gone takes nothing
        XCTAssertEqual(book.backfillPinnedKey(peerUserId: "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee", signerKey: signer, key: a.bytes()),
                       .noRecord)
    }

    func testNothingRunsDuringACall() async throws {
        let a = try key(0x41)
        let book = bookNaming(a)
        let fetches = Counter()
        await PqPinBackfill.run(book: book, spacing: 0, callActive: { true }, fetch: { _, _ in fetches.fire(); return [self.verified(a)] })
        XCTAssertEqual(fetches.count, 0)
        XCTAssertNil(book.pinnedKey(peerUserId: user, signerKey: signer))
    }

    /// A contact with several devices: the candidate whose derived id is the record's is stored, the others are ignored; with none
    /// matching nothing is stored.
    func testOnlyTheDeviceKeyWhoseDerivedIdMatchesIsStored() async throws {
        let a = try key(0x41)
        let b = try key(0x42)
        let c = try key(0x43)
        let book = bookNaming(b)
        await PqPinBackfill.run(book: book, spacing: 0, callActive: { false },
                                fetch: { _, _ in [self.verified(a), self.verified(b), self.verified(c)] })
        XCTAssertEqual(book.pinnedKey(peerUserId: user, signerKey: signer), b.bytes())
        XCTAssertEqual(log.lines, ["PQ-BACKFILL result=stored"])

        let other = bookNaming(try key(0x44))
        await PqPinBackfill.run(book: other, spacing: 0, callActive: { false }, fetch: { _, _ in [self.verified(a), self.verified(c)] })
        XCTAssertNil(other.pinnedKey(peerUserId: user, signerKey: signer))
        XCTAssertEqual(log.lines.last, "PQ-BACKFILL result=mismatch")
    }
}
