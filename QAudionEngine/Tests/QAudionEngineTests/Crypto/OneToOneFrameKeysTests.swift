import XCTest
import CryptoKit
@testable import QAudionEngine

/// Directional 1:1 frame keys (owner decision O1, WIRE_SPEC §3.7.2).
final class OneToOneFrameKeysTests: XCTestCase {

    private let sessionKey = Data((0..<32).map { UInt8($0) })
    private let callId = V6TestFixtures.callId

    private func hkdf(_ info: String) -> Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sessionKey),
            salt: Data("qaudion-frame-salt-v5".utf8),
            info: Data(info.utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
    }

    /// First-principles reconstruction of both keys from the WIRE_SPEC §3.7.2 formula.
    func testMatchesSpecFormula() throws {
        let keys = try XCTUnwrap(OneToOneFrameKeys.derive(sessionKey: sessionKey, callId: callId))
        XCTAssertEqual(keys.offererToAcceptor, hkdf("q-audion-frame-key-v5:" + callId + ":o2a"))
        XCTAssertEqual(keys.acceptorToOfferer, hkdf("q-audion-frame-key-v5:" + callId + ":a2o"))
        XCTAssertEqual(keys.offererToAcceptor.count, 32)
        XCTAssertEqual(keys.acceptorToOfferer.count, 32)
    }

    /// The two directions never share a key (a reflected frame cannot authenticate).
    func testDirectionsDiffer() throws {
        let keys = try XCTUnwrap(OneToOneFrameKeys.derive(sessionKey: sessionKey, callId: callId))
        XCTAssertNotEqual(keys.offererToAcceptor, keys.acceptorToOfferer)
        XCTAssertNotEqual(keys.offererToAcceptor, sessionKey)
        XCTAssertNotEqual(keys.acceptorToOfferer, sessionKey)
    }

    /// What one side sends is exactly what the other side receives, and vice versa.
    func testSendAndReceiveKeysAreComplementary() throws {
        let keys = try XCTUnwrap(OneToOneFrameKeys.derive(sessionKey: sessionKey, callId: callId))
        XCTAssertEqual(keys.sendKey(isOfferer: true), keys.receiveKey(isOfferer: false))
        XCTAssertEqual(keys.sendKey(isOfferer: false), keys.receiveKey(isOfferer: true))
        XCTAssertNotEqual(keys.sendKey(isOfferer: true), keys.receiveKey(isOfferer: true))
    }

    func testBoundToCallIdAndSessionKey() throws {
        let a = try XCTUnwrap(OneToOneFrameKeys.derive(sessionKey: sessionKey, callId: callId))
        let otherCall = try XCTUnwrap(OneToOneFrameKeys.derive(sessionKey: sessionKey, callId: callId + "x"))
        var key2 = sessionKey
        key2[0] ^= 0x01
        let otherKey = try XCTUnwrap(OneToOneFrameKeys.derive(sessionKey: key2, callId: callId))
        XCTAssertNotEqual(a, otherCall)
        XCTAssertNotEqual(a, otherKey)
        XCTAssertEqual(a, OneToOneFrameKeys.derive(sessionKey: sessionKey, callId: callId))
    }

    func testRejectsBadInputsWithoutTrapping() {
        XCTAssertNil(OneToOneFrameKeys.derive(sessionKey: Data(count: 31), callId: callId))
        XCTAssertNil(OneToOneFrameKeys.derive(sessionKey: Data(count: 33), callId: callId))
        XCTAssertNil(OneToOneFrameKeys.derive(sessionKey: sessionKey, callId: ""))
    }

    func testParticipantIdsAreLocalLabels() {
        XCTAssertEqual(OneToOneFrameParticipant.local, "local")
        XCTAssertEqual(OneToOneFrameParticipant.remote, "remote")
    }
}
