import XCTest
import CryptoKit
@testable import QAudionEngine

/// KMS-rotation-v2 Phase-1 — the live-call derive seam
/// (`QAudionCallIntegration.phase1DeriveSessionKey`): D4 abort + D6 v2/v3 KDF
/// selection, exercised through the production integration object.
///
/// Pure in-memory (no Keychain / network), so host-runnable under `swift test`.
final class Phase1DeriveSeamTests: XCTestCase {

    private let pqcSs  = Data(hexP1: "ac59c1fd9bc063f6fc59ad275aa5ebb6932b30e8a23ee3a751be614c8774dc7b")
    private let x25519 = Data(repeating: 0x42, count: 32)
    private let ct     = Data(repeating: 0xAB, count: 1568)
    private let pskK1  = Data(hexP1: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")

    /// Unwired integration → byte-identical to schema:2 deriveHybridSessionKey.
    func testUnwiredIsSchema2() {
        let integ = QAudionCallIntegration()  // localSupportsSessionKdfV3 == false, no resolvers
        guard case let .success(key) = integ.phase1DeriveSessionKey(
            peerId: "peer", pqcSs: pqcSs, x25519Ss: x25519, pqcCiphertext: ct,
            selectedFp: nil, selectedPsk: nil, peerSupportsV3: false) else {
            return XCTFail("expected success")
        }
        let v2 = QAudionCallIntegration.deriveHybridSessionKey(
            pqcSs: pqcSs, x25519Ss: x25519, pqcCiphertext: ct, psk: nil)
        XCTAssertEqual(key.hexP1(), v2.hexP1())
    }

    /// Both legs support v3 → schema:3 key (matches deriveHybridSessionKeyV3).
    func testBothV3SelectsSchema3() {
        let integ = QAudionCallIntegration()
        integ.localSupportsSessionKdfV3 = true
        guard case let .success(key) = integ.phase1DeriveSessionKey(
            peerId: "peer", pqcSs: pqcSs, x25519Ss: x25519, pqcCiphertext: ct,
            selectedFp: nil, selectedPsk: nil, peerSupportsV3: true) else {
            return XCTFail("expected success")
        }
        let v3 = QAudionCallIntegration.deriveHybridSessionKeyV3(
            pqcSs: pqcSs, x25519Ss: x25519, pqcCiphertext: ct, psk: nil)
        XCTAssertEqual(key.hexP1(), v3.hexP1())
    }

    /// Local supports v3 but peer does not → falls back to schema:2 (mixed fleet).
    func testPeerLacksV3FallsBackToSchema2() {
        let integ = QAudionCallIntegration()
        integ.localSupportsSessionKdfV3 = true
        guard case let .success(key) = integ.phase1DeriveSessionKey(
            peerId: "peer", pqcSs: pqcSs, x25519Ss: x25519, pqcCiphertext: ct,
            selectedFp: nil, selectedPsk: nil, peerSupportsV3: false) else {
            return XCTFail("expected success")
        }
        let v2 = QAudionCallIntegration.deriveHybridSessionKey(
            pqcSs: pqcSs, x25519Ss: x25519, pqcCiphertext: ct, psk: nil)
        XCTAssertEqual(key.hexP1(), v2.hexP1())
    }

    /// D4: a hw_only contact whose negotiation produced NO matching fp → abort.
    func testHwOnlyContactStrippedAborts() {
        let integ = QAudionCallIntegration()
        integ.resolveHwOnlyContact = { _ in (true, "hwonly-fp-expected") }
        guard case let .abort(reason) = integ.phase1DeriveSessionKey(
            peerId: "peer", pqcSs: pqcSs, x25519Ss: x25519, pqcCiphertext: ct,
            selectedFp: nil, selectedPsk: nil, peerSupportsV3: false) else {
            return XCTFail("expected abort")
        }
        XCTAssertEqual(reason, "hw_only_required")
    }

    /// D4: hw_only contact landing on the expected fp → success (v3 w/ the PSK).
    func testHwOnlyContactCorrectFpSucceeds() {
        let integ = QAudionCallIntegration()
        integ.localSupportsSessionKdfV3 = true
        let fp = SHA256.hash(data: pskK1).map { String(format: "%02x", $0) }.joined()
        integ.resolveHwOnlyContact = { _ in (true, fp) }
        guard case let .success(key) = integ.phase1DeriveSessionKey(
            peerId: "peer", pqcSs: pqcSs, x25519Ss: x25519, pqcCiphertext: ct,
            selectedFp: fp, selectedPsk: pskK1, peerSupportsV3: true) else {
            return XCTFail("expected success")
        }
        let v3 = QAudionCallIntegration.deriveHybridSessionKeyV3(
            pqcSs: pqcSs, x25519Ss: x25519, pqcCiphertext: ct, psk: pskK1)
        XCTAssertEqual(key.hexP1(), v3.hexP1())
    }

    /// SW-only contact (no hw_only key) with null negotiation → legitimate
    /// fallback, no abort.
    func testSwOnlyContactNullNegotiationSucceeds() {
        let integ = QAudionCallIntegration()
        integ.resolveHwOnlyContact = { _ in (false, nil) }
        guard case .success = integ.phase1DeriveSessionKey(
            peerId: "peer", pqcSs: pqcSs, x25519Ss: x25519, pqcCiphertext: ct,
            selectedFp: nil, selectedPsk: nil, peerSupportsV3: false) else {
            return XCTFail("expected success (legit SW-only fallback)")
        }
    }
}

private extension Data {
    init(hexP1 hex: String) {
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            data.append(UInt8(hex[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        self = data
    }
    func hexP1() -> String { map { String(format: "%02x", $0) }.joined() }
}
