import XCTest
@testable import QAudionEngine

final class SessionManagerTests: XCTestCase {
    func testInitSession() throws {
        let sm = SessionManager()
        let state = try sm.initSession(sharedSecret: Data(repeating: 0x42, count: 32))
        XCTAssertEqual(state.sessionId.count, 32)
        XCTAssertEqual(state.rootKey.count, 32)
        XCTAssertEqual(state.chainKey.count, 32)
        XCTAssertEqual(state.frameCounter, 0)
    }
    func testInitSessionWithPsk() throws {
        let sm1 = SessionManager()
        let s1 = try sm1.initSession(sharedSecret: Data(repeating: 0x42, count: 32), psk: Data(repeating: 0xAA, count: 32))
        let sm2 = SessionManager()
        let s2 = try sm2.initSession(sharedSecret: Data(repeating: 0x42, count: 32))
        XCTAssertNotEqual(s1.rootKey, s2.rootKey)
        XCTAssertNotEqual(s1.chainKey, s2.chainKey)
    }
    func testRatchetProducesUniqueKeys() throws {
        let sm = SessionManager()
        _ = try sm.initSession(sharedSecret: Data(repeating: 0x42, count: 32))
        let k1 = try sm.ratchet(); let k2 = try sm.ratchet(); let k3 = try sm.ratchet()
        XCTAssertEqual(k1.count, 32)
        XCTAssertNotEqual(k1, k2); XCTAssertNotEqual(k2, k3); XCTAssertNotEqual(k1, k3)
    }
    func testFrameCounterIncrements() throws {
        let sm = SessionManager()
        _ = try sm.initSession(sharedSecret: Data(repeating: 0x42, count: 32))
        XCTAssertEqual(sm.frameCounter, 0)
        _ = try sm.ratchet(); XCTAssertEqual(sm.frameCounter, 1)
        _ = try sm.ratchet(); XCTAssertEqual(sm.frameCounter, 2)
    }
    func testRatchetWithoutSessionThrows() {
        XCTAssertThrowsError(try SessionManager().ratchet())
    }
    func testDestroySession() throws {
        let sm = SessionManager()
        _ = try sm.initSession(sharedSecret: Data(repeating: 0x42, count: 32))
        sm.destroySession()
        XCTAssertNil(sm.sessionState)
        XCTAssertThrowsError(try sm.ratchet())
    }
    func testInvalidSecretSize() {
        XCTAssertThrowsError(try SessionManager().initSession(sharedSecret: Data(repeating: 0x42, count: 16)))
    }
    func testDeterministicKeyDerivation() throws {
        let sm1 = SessionManager(); let s1 = try sm1.initSession(sharedSecret: Data(repeating: 0xBE, count: 32)); let k1 = try sm1.ratchet()
        let sm2 = SessionManager(); let s2 = try sm2.initSession(sharedSecret: Data(repeating: 0xBE, count: 32)); let k2 = try sm2.ratchet()
        XCTAssertEqual(s1.rootKey, s2.rootKey)
        XCTAssertEqual(s1.chainKey, s2.chainKey)
        XCTAssertEqual(k1, k2)
    }
    func testUpdateConfidence() throws {
        let sm = SessionManager()
        _ = try sm.initSession(sharedSecret: Data(repeating: 0x42, count: 32))
        sm.updateConfidence(0.0); XCTAssertEqual(sm.adaptiveRatchetInterval, SessionManager.ratchetMinFrames)
        sm.updateConfidence(1.0); XCTAssertEqual(sm.adaptiveRatchetInterval, SessionManager.ratchetMaxFrames)
    }
}
