import XCTest
@testable import QAudionEngine

final class QAudionEngineTests: XCTestCase {

    func testInitialize() throws {
        let engine = QAudionEngine()
        XCTAssertEqual(engine.getState(), .uninitialized)
        try engine.initialize()
        XCTAssertEqual(engine.getState(), .initialized)
    }

    func testInitSession() throws {
        let engine = QAudionEngine()
        try engine.initialize()
        try engine.initSession(sharedSecret: Data(repeating: 0x42, count: 32))
        XCTAssertEqual(engine.getState(), .sessionActive)
        XCTAssertNotNil(engine.getSessionInfo())
        XCTAssertTrue(engine.getSessionInfo()!.isActive)
    }

    func testProcessRoundTrip() throws {
        // Two engines with same shared secret can encrypt/decrypt
        let txEngine = QAudionEngine(config: .development())
        try txEngine.initialize()
        try txEngine.initSession(sharedSecret: Data(repeating: 0xBE, count: 32))

        let rxEngine = QAudionEngine(config: .development())
        try rxEngine.initialize()
        try rxEngine.initSession(sharedSecret: Data(repeating: 0xBE, count: 32))

        let pcm = Data(repeating: 0xAA, count: AudioConstants.bytesPerFrame)
        let encrypted = try txEngine.processOutgoingAudio(pcmFrame: pcm)
        let decrypted = try rxEngine.processIncomingAudio(serializedFrame: encrypted)

        XCTAssertFalse(decrypted.isEmpty)
        XCTAssertEqual(txEngine.getStats().framesTx, 1)
        XCTAssertEqual(rxEngine.getStats().framesRx, 1)
    }

    func testDestroySession() throws {
        let engine = QAudionEngine()
        try engine.initialize()
        try engine.initSession(sharedSecret: Data(repeating: 0x42, count: 32))
        engine.destroySession()
        XCTAssertEqual(engine.getState(), .initialized)
    }

    func testRelease() throws {
        let engine = QAudionEngine()
        try engine.initialize()
        engine.release()
        XCTAssertEqual(engine.getState(), .destroyed)
    }

    func testDoubleInitializeThrows() throws {
        let engine = QAudionEngine()
        try engine.initialize()
        XCTAssertThrowsError(try engine.initialize())
    }
}
