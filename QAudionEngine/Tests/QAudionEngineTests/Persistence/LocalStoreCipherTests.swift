import XCTest
@testable import QAudionEngine

/// Coverage for the at-rest sealing of message content (2026-08-02).
///
/// The properties asserted here are the ones the feature exists to
/// guarantee, not implementation details: a body round-trips, a stored
/// value never contains the plaintext verbatim, a pre-encryption row still
/// reads, and a tampered row fails closed instead of decoding to something
/// an attacker chose.
final class LocalStoreCipherTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // See ContactsStoreTests.setUp — no usable keychain in a simulator
        // test bundle, so the key is injected. The AEAD path under test is
        // unchanged; only where the key comes from differs.
        LocalStoreCipher.testKeyOverride = Data(repeating: 0x7f, count: 32)
    }

    override func tearDown() {
        LocalStoreCipher.testKeyOverride = nil
        super.tearDown()
    }

    func test_sealThenOpen_roundTrips() throws {
        let body = "Ci vediamo alle 19, porto io il vino."
        let sealed = try XCTUnwrap(try LocalStoreCipher.seal(body))
        XCTAssertEqual(LocalStoreCipher.open(sealed), body)
    }

    /// The whole point: what lands on disk must not be the message.
    func test_sealedValue_doesNotContainPlaintext() throws {
        let body = "codice-bonifico-8842"
        let sealed = try XCTUnwrap(try LocalStoreCipher.seal(body))
        XCTAssertFalse(sealed.contains(body))
        XCTAssertTrue(LocalStoreCipher.isSealed(sealed))
    }

    /// Two seals of the same body must differ — a deterministic ciphertext
    /// would leak "these two messages are identical" to anyone reading the
    /// database file.
    func test_sealing_twice_producesDifferentCiphertext() throws {
        let body = "ok"
        let a = try XCTUnwrap(try LocalStoreCipher.seal(body))
        let b = try XCTUnwrap(try LocalStoreCipher.seal(body))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(LocalStoreCipher.open(a), body)
        XCTAssertEqual(LocalStoreCipher.open(b), body)
    }

    /// Rows written before this format existed carry no marker and must
    /// keep displaying — an upgrade that blanked the history would be worse
    /// than the gap it closes.
    func test_legacyPlaintext_readsUnchanged() {
        let legacy = "messaggio salvato prima della cifratura locale"
        XCTAssertFalse(LocalStoreCipher.isSealed(legacy))
        XCTAssertEqual(LocalStoreCipher.open(legacy), legacy)
    }

    func test_nilAndEmpty_passThrough() throws {
        XCTAssertNil(try LocalStoreCipher.seal(nil))
        XCTAssertNil(LocalStoreCipher.open(nil))
        XCTAssertEqual(try LocalStoreCipher.seal(""), "")
    }

    /// Re-sealing an already-sealed value must not double-wrap it: the
    /// migration in ConversationStore re-saves every row, including rows it
    /// already converted on a previous launch.
    func test_sealingAnAlreadySealedValue_isANoOp() throws {
        let sealed = try XCTUnwrap(try LocalStoreCipher.seal("x"))
        XCTAssertEqual(try LocalStoreCipher.seal(sealed), sealed)
    }

    /// AES-GCM is authenticated: a flipped byte must fail to open rather
    /// than yield attacker-influenced text.
    func test_tamperedCiphertext_failsClosed() throws {
        let sealed = try XCTUnwrap(try LocalStoreCipher.seal("bonifico approvato"))
        let marker = "QM1:"
        let b64 = String(sealed.dropFirst(marker.count))
        var blob = try XCTUnwrap(Data(base64Encoded: b64))
        blob[blob.count - 1] ^= 0x01
        let tampered = marker + blob.base64EncodedString()
        XCTAssertNil(LocalStoreCipher.open(tampered))
    }

    /// A row sealed under a different key (restored onto another device)
    /// must not silently read as empty — the mapper turns nil into a
    /// visible marker, and that only works if open() reports failure.
    func test_wrongKey_failsToOpen() throws {
        let sealed = try XCTUnwrap(try LocalStoreCipher.seal("segreto"))
        LocalStoreCipher.testKeyOverride = Data(repeating: 0x11, count: 32)
        XCTAssertNil(LocalStoreCipher.open(sealed))
    }
}
