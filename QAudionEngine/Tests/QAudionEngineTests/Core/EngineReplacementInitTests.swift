import XCTest
@testable import QAudionEngine

/// A2: a replacement round-1 OFFER makes the engine ready with `initializeUnlessAlreadyInitialized()`. It used to be
/// `try? engine.initialize()`, which swallowed EVERY refusal, including a destroyed engine.
final class EngineReplacementInitTests: XCTestCase {

    private let secret = Data(repeating: 0x42, count: 32)

    func testAnUninitializedEngineIsInitialized() throws {
        let engine = QAudionEngine()
        try engine.initializeUnlessAlreadyInitialized()
        XCTAssertEqual(engine.getState(), .initialized)
    }

    /// The expected refusal of `initialize()` (nothing was installed since the first one) is not an error here.
    func testAnAlreadyInitializedEngineIsLeftAsItIs() throws {
        let engine = QAudionEngine()
        try engine.initialize()
        XCTAssertThrowsError(try engine.initialize(), "the ordinary initialize() still refuses a second call")
        XCTAssertNoThrow(try engine.initializeUnlessAlreadyInitialized())
        XCTAssertEqual(engine.getState(), .initialized)
        try engine.initSession(sharedSecret: secret)
        XCTAssertEqual(engine.getState(), .sessionActive, "and it can still take its session")
    }

    /// The replaced round already installed a session: the replacement re-initialises the engine, as before.
    func testAnEngineWithAnActiveSessionIsReinitialized() throws {
        let engine = QAudionEngine()
        try engine.initialize()
        try engine.initSession(sharedSecret: secret)
        XCTAssertEqual(engine.getState(), .sessionActive)
        try engine.initializeUnlessAlreadyInitialized()
        XCTAssertEqual(engine.getState(), .initialized)
        try engine.initSession(sharedSecret: Data(repeating: 0x43, count: 32))
        XCTAssertEqual(engine.getState(), .sessionActive)
    }

    /// Any other refusal is a real failure and reaches the caller instead of being swallowed.
    func testADestroyedEngineThrows() throws {
        let engine = QAudionEngine()
        try engine.initialize()
        engine.release()
        XCTAssertEqual(engine.getState(), .destroyed)
        XCTAssertThrowsError(try engine.initializeUnlessAlreadyInitialized()) { error in
            guard case QAudionEngineError.invalidStateTransition(let from, let to) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(from, .destroyed)
            XCTAssertEqual(to, .initialized)
        }
        XCTAssertEqual(engine.getState(), .destroyed, "a refused call changes nothing")
    }
}
