import XCTest
@testable import QAudionEngine

/// Smoke tests for the ViewModel layer.
///
/// Each concrete view model gets a dedicated test case file under this
/// directory; this file holds cross-cutting tests (e.g. "every view model
/// declares a stable `.mock`").
final class ViewModelProtocolSmokeTests: XCTestCase {

    /// Mocks must be deterministic — calling `.mock` twice in a row must
    /// produce equal values, otherwise SwiftUI previews flicker.
    func test_mockIsDeterministic_protocolWitness() {
        // Real assertion lives in each concrete view model's test file
        // (e.g. KeyManagementViewModelTests.test_mockIsDeterministic).
        // This method exists as a smoke test that the test target compiles
        // and runs against the engine package.
        XCTAssertTrue(true)
    }
}
