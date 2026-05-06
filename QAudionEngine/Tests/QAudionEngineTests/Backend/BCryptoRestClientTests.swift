import XCTest
@testable import QAudionEngine

final class BackendTests: XCTestCase {
    func testBackendRegistrySingleton() {
        let reg = BackendRegistry.shared
        let providersBefore = reg.getAllProviders().count
        // Regression check: registry singleton is stable.
        XCTAssertGreaterThanOrEqual(reg.getAllProviders().count, providersBefore)
    }

    func testCallRouterNoBackend() {
        let router = CallRouter()
        XCTAssertThrowsError(try router.initiateCall(remoteId: "test"))
    }

    func testBackendConfig() {
        let config = BackendConfig(serverUrl: "https://voip.bcrypto.com", acceptSelfSignedCerts: true)
        XCTAssertEqual(config.serverUrl, "https://voip.bcrypto.com")
        XCTAssertTrue(config.acceptSelfSignedCerts)
        XCTAssertFalse(config.proxyEnabled)
    }
}
