import XCTest
@testable import QAudionEngine

final class SecurityDashboardViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(SecurityDashboardViewModel.mock, SecurityDashboardViewModel.mock)
    }

    func test_mockFingerprintIs4Groups() {
        let parts = SecurityDashboardViewModel.mock.identityFingerprint.split(separator: ".")
        XCTAssertEqual(parts.count, 4)
    }

    func test_mockPqcAlgorithmIsMlKem1024() {
        XCTAssertEqual(SecurityDashboardViewModel.mock.pqcAlgorithm, "ML-KEM-1024")
    }

    func test_mockKeyHealthIsHealthy() {
        XCTAssertEqual(SecurityDashboardViewModel.mock.keyHealth, .healthy)
    }
}
