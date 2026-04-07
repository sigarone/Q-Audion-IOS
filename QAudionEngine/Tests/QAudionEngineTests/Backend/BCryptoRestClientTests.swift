import XCTest
@testable import QAudionEngine

final class BackendTests: XCTestCase {
    func testBackendRegistrySingleton() {
        let reg = BackendRegistry.shared
        let upstream = UpstreamBackendProvider()
        reg.register(upstream)
        XCTAssertNotNil(reg.getUpstreamProvider())
        XCTAssertEqual(reg.getAllProviders().count, 1)
        reg.unregister("upstream")
        XCTAssertNil(reg.getUpstreamProvider())
    }

    func testBackendSelectionPolicy() {
        let policy = BackendSelectionPolicy()
        policy.setPolicy(.upstreamOnly)
        XCTAssertEqual(policy.getPolicy(), .upstreamOnly)
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
