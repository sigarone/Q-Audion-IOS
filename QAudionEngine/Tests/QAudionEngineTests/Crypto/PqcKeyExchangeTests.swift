import XCTest
@testable import QAudionEngine

final class PqcKeyExchangeTests: XCTestCase {
    func testGenerateKeyPair() throws {
        let pqc = PqcKeyExchange()
        let kp = try pqc.generateKeyPair()
        XCTAssertEqual(kp.publicKey.count, 1568)
        XCTAssertEqual(kp.privateKey.count, 3168)
    }

    func testEncapsulateDecapsulate() throws {
        let pqc = PqcKeyExchange()
        let kp = try pqc.generateKeyPair()
        let result = try pqc.encapsulate(remotePublicKey: kp.publicKey)
        XCTAssertEqual(result.sharedSecret.count, 32)
        XCTAssertFalse(result.ciphertext.isEmpty)

        let recovered = try pqc.decapsulate(ciphertext: result.ciphertext, privateKey: kp.privateKey)
        XCTAssertEqual(recovered.count, 32)
        // With stub C library, encaps and decaps produce the same deterministic output
        XCTAssertEqual(result.sharedSecret, recovered)
    }

    func testEmptyPublicKeyThrows() {
        let pqc = PqcKeyExchange()
        XCTAssertThrowsError(try pqc.encapsulate(remotePublicKey: Data()))
    }

    func testEmptyCiphertextThrows() {
        let pqc = PqcKeyExchange()
        XCTAssertThrowsError(try pqc.decapsulate(ciphertext: Data(), privateKey: Data(repeating: 0, count: 32)))
    }
}
