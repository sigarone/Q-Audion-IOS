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
        // getState() == .sessionActive was just asserted above, so getSessionInfo() is non-nil here too.
        // swiftlint:disable:next force_unwrapping
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

    /// XP-ratchet-loss — a single dropped frame must NOT permanently
    /// desync the RX ratchet from the TX ratchet. Simulates network loss
    /// by simply never feeding frame #2 to the rxEngine, then verifies
    /// frame #3 (and beyond) still decrypts correctly via ratchet
    /// catch-up, instead of failing GCM auth forever after the drop.
    func testProcessRoundTripSurvivesDroppedFrame() throws {
        let txEngine = QAudionEngine(config: .development())
        try txEngine.initialize()
        try txEngine.initSession(sharedSecret: Data(repeating: 0xBE, count: 32))

        let rxEngine = QAudionEngine(config: .development())
        try rxEngine.initialize()
        try rxEngine.initSession(sharedSecret: Data(repeating: 0xBE, count: 32))

        let pcm = Data(repeating: 0xAA, count: AudioConstants.bytesPerFrame)
        let frame1 = try txEngine.processOutgoingAudio(pcmFrame: pcm)
        _ = try txEngine.processOutgoingAudio(pcmFrame: pcm) // frame 2 — "lost in transit"
        let frame3 = try txEngine.processOutgoingAudio(pcmFrame: pcm)

        XCTAssertNoThrow(try rxEngine.processIncomingAudio(serializedFrame: frame1))
        // Frame 2 never arrives (simulated loss). Frame 3 must still
        // decrypt cleanly — the old behaviour would fail GCM auth here
        // and on every subsequent frame for the rest of the call.
        XCTAssertNoThrow(try rxEngine.processIncomingAudio(serializedFrame: frame3))

        // Chain keeps working normally after the catch-up.
        let frame4 = try txEngine.processOutgoingAudio(pcmFrame: pcm)
        XCTAssertNoThrow(try rxEngine.processIncomingAudio(serializedFrame: frame4))
    }

    /// XP-ratchet-loss — a stale/duplicate frame (already consumed ratchet
    /// position) must be rejected without corrupting the chain, so later
    /// in-order frames keep decrypting fine.
    func testProcessRoundTripRejectsStaleDuplicateFrame() throws {
        let txEngine = QAudionEngine(config: .development())
        try txEngine.initialize()
        try txEngine.initSession(sharedSecret: Data(repeating: 0xBE, count: 32))

        let rxEngine = QAudionEngine(config: .development())
        try rxEngine.initialize()
        try rxEngine.initSession(sharedSecret: Data(repeating: 0xBE, count: 32))

        let pcm = Data(repeating: 0xAA, count: AudioConstants.bytesPerFrame)
        let frame1 = try txEngine.processOutgoingAudio(pcmFrame: pcm)
        let frame2 = try txEngine.processOutgoingAudio(pcmFrame: pcm)

        XCTAssertNoThrow(try rxEngine.processIncomingAudio(serializedFrame: frame1))
        XCTAssertNoThrow(try rxEngine.processIncomingAudio(serializedFrame: frame2))
        // Replay frame1 (duplicate / very-late reorder) — must be
        // rejected, not silently re-derived.
        XCTAssertThrowsError(try rxEngine.processIncomingAudio(serializedFrame: frame1))

        // Chain must still be healthy for the next real frame.
        let frame3 = try txEngine.processOutgoingAudio(pcmFrame: pcm)
        XCTAssertNoThrow(try rxEngine.processIncomingAudio(serializedFrame: frame3))
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
