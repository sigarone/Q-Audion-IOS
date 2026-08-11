import XCTest
@testable import QAudionEngine

final class MeshDiscoveryCipherTests: XCTestCase {

    func testEncryptDecryptRoundTrip() {
        let announce = MeshAnnounce(nodeIdHex: "a13f0c8e77b20001", identityFingerprintHex: "a13f0c8e77b20001", neighborNodeIdsHex: ["1111111111111111"])
        let plaintext = announce.encode()
        let ciphertext = try! XCTUnwrap(MeshDiscoveryCipher.encrypt(plaintext))
        let decrypted = try! XCTUnwrap(MeshDiscoveryCipher.decrypt(ciphertext))
        XCTAssertEqual(decrypted, plaintext)
        XCTAssertEqual(MeshAnnounce.decode(decrypted), announce)
    }

    func testCiphertextIsNotThePlaintext() {
        let plaintext = Data("hello mesh".utf8)
        let ciphertext = try! XCTUnwrap(MeshDiscoveryCipher.encrypt(plaintext))
        XCTAssertNotEqual(ciphertext, plaintext)
    }

    /// AES-GCM's random-per-call nonce means two encryptions of the SAME
    /// plaintext must produce DIFFERENT ciphertext — the property that
    /// removes any ciphertext-level correlator for a passive observer who
    /// can't decrypt at all (see the type's own header comment).
    func testEncryptionIsNonDeterministic() {
        let plaintext = Data("hello mesh".utf8)
        let first = try! XCTUnwrap(MeshDiscoveryCipher.encrypt(plaintext))
        let second = try! XCTUnwrap(MeshDiscoveryCipher.encrypt(plaintext))
        XCTAssertNotEqual(first, second)
    }

    func testDecryptNeverThrowsOnGarbageBytes() {
        XCTAssertNil(MeshDiscoveryCipher.decrypt(Data([0x00, 0x01, 0x02])))
        XCTAssertNil(MeshDiscoveryCipher.decrypt(Data()))
    }

    func testDecryptRejectsTamperedCiphertext() {
        let plaintext = Data("hello mesh".utf8)
        var ciphertext = try! XCTUnwrap(MeshDiscoveryCipher.encrypt(plaintext))
        ciphertext[ciphertext.count - 1] ^= 0xFF // flip a tag byte
        XCTAssertNil(MeshDiscoveryCipher.decrypt(ciphertext))
    }
}
