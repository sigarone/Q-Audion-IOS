import XCTest
@testable import QAudionEngine

final class EngineStateTests: XCTestCase {
    func testValidTransitions() {
        XCTAssertTrue(EngineState.uninitialized.canTransitionTo(.initialized))
        XCTAssertTrue(EngineState.initialized.canTransitionTo(.sessionActive))
        XCTAssertTrue(EngineState.sessionActive.canTransitionTo(.processing))
        XCTAssertTrue(EngineState.processing.canTransitionTo(.sessionActive))
    }
    func testInvalidTransitions() {
        XCTAssertFalse(EngineState.uninitialized.canTransitionTo(.processing))
        XCTAssertFalse(EngineState.destroyed.canTransitionTo(.initialized))
    }
    func testTerminal() {
        XCTAssertTrue(EngineState.destroyed.isTerminal)
        XCTAssertFalse(EngineState.initialized.isTerminal)
    }
    func testErrorState() {
        XCTAssertTrue(EngineState.error.isError)
        XCTAssertTrue(EngineState.error.canTransitionTo(.destroyed))
        XCTAssertTrue(EngineState.error.canTransitionTo(.initialized))
    }
}
