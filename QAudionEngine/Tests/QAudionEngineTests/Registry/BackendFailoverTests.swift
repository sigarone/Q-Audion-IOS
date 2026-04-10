import XCTest
@testable import QAudionEngine

final class BackendFailoverTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        // Clean up any providers registered during tests
        for provider in BackendRegistry.shared.getAllProviders() {
            BackendRegistry.shared.unregister(provider.identifier)
        }
    }

    // MARK: - BackendRegistry

    func testRegistryStartsEmpty() {
        // After tearDown cleanup, registry should have no providers
        XCTAssertTrue(BackendRegistry.shared.getAllProviders().isEmpty)
    }

    func testGetProviderReturnsNilForUnknown() {
        XCTAssertNil(BackendRegistry.shared.getProvider("nonexistent"))
    }

    func testGetBCryptoProviderReturnsNilWhenNotRegistered() {
        XCTAssertNil(BackendRegistry.shared.getBCryptoProvider())
    }

    func testGetUpstreamProviderReturnsNilWhenNotRegistered() {
        XCTAssertNil(BackendRegistry.shared.getUpstreamProvider())
    }

    func testRegisterAndRetrieveUpstreamProvider() {
        let upstream = UpstreamBackendProvider()
        BackendRegistry.shared.register(upstream)

        XCTAssertNotNil(BackendRegistry.shared.getProvider("upstream"))
        XCTAssertNotNil(BackendRegistry.shared.getUpstreamProvider())
        XCTAssertEqual(BackendRegistry.shared.getUpstreamProvider()?.identifier, "upstream")
    }

    func testUnregisterRemovesProvider() {
        let upstream = UpstreamBackendProvider()
        BackendRegistry.shared.register(upstream)
        BackendRegistry.shared.unregister("upstream")

        XCTAssertNil(BackendRegistry.shared.getProvider("upstream"))
        XCTAssertNil(BackendRegistry.shared.getUpstreamProvider())
    }

    func testGetAllProvidersReturnsRegistered() {
        let upstream = UpstreamBackendProvider()
        BackendRegistry.shared.register(upstream)

        let all = BackendRegistry.shared.getAllProviders()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.identifier, "upstream")
    }

    // MARK: - BackendSelectionPolicy

    func testDefaultPolicyIsBcryptoPreferred() {
        let policy = BackendSelectionPolicy()
        if case .bcryptoPreferred = policy.getPolicy() {} else {
            XCTFail("Default policy should be .bcryptoPreferred")
        }
    }

    func testSetPolicy() {
        let policy = BackendSelectionPolicy()
        policy.setPolicy(.upstreamOnly)
        if case .upstreamOnly = policy.getPolicy() {} else {
            XCTFail("Expected .upstreamOnly after setPolicy")
        }
    }

    func testSelectBackendWithNoRegisteredBackendsReturnsNil() {
        let policy = BackendSelectionPolicy()
        // No backends registered
        let selected = policy.selectBackend(for: "anyContact")
        XCTAssertNil(selected, "Should return nil when no backends are registered")
    }

    func testSelectBackendBcryptoPreferredFallsBackToUpstream() {
        let policy = BackendSelectionPolicy()
        policy.setPolicy(.bcryptoPreferred)

        // Register only upstream (no bcrypto)
        let upstream = UpstreamBackendProvider()
        BackendRegistry.shared.register(upstream)

        let selected = policy.selectBackend(for: "contact1")
        XCTAssertNotNil(selected)
        XCTAssertEqual(selected?.identifier, "upstream",
                       "bcryptoPreferred should fall back to upstream when bcrypto is unavailable")
    }

    func testSelectBackendUpstreamOnlyReturnsUpstream() {
        let policy = BackendSelectionPolicy()
        policy.setPolicy(.upstreamOnly)

        let upstream = UpstreamBackendProvider()
        BackendRegistry.shared.register(upstream)

        let selected = policy.selectBackend(for: "contact1")
        XCTAssertNotNil(selected)
        XCTAssertEqual(selected?.identifier, "upstream")
    }

    func testSelectBackendUpstreamOnlyReturnsNilWithoutUpstream() {
        let policy = BackendSelectionPolicy()
        policy.setPolicy(.upstreamOnly)
        // No upstream registered
        let selected = policy.selectBackend(for: "contact1")
        XCTAssertNil(selected)
    }

    func testContactOverrideSelectsSpecificBackend() {
        let policy = BackendSelectionPolicy()
        let upstream = UpstreamBackendProvider()
        BackendRegistry.shared.register(upstream)

        policy.setContactBackend(contactId: "special", backendId: "upstream")
        let selected = policy.selectBackend(for: "special")
        XCTAssertNotNil(selected)
        XCTAssertEqual(selected?.identifier, "upstream")
    }

    func testContactOverrideWithInvalidBackendReturnsNil() {
        let policy = BackendSelectionPolicy()
        policy.setContactBackend(contactId: "special", backendId: "nonexistent")
        let selected = policy.selectBackend(for: "special")
        XCTAssertNil(selected, "Override to non-existent backend should return nil")
    }

    // MARK: - CallRouter

    func testCallRouterInitiateCallWithNoBackendThrows() {
        let router = CallRouter()
        XCTAssertThrowsError(try router.initiateCall(remoteId: "remote1")) { error in
            XCTAssertTrue(error is CallRouterError)
        }
    }

    func testCallRouterInitiateAndEndCall() {
        let upstream = UpstreamBackendProvider()
        BackendRegistry.shared.register(upstream)

        let router = CallRouter()
        router.getSelectionPolicy().setPolicy(.upstreamOnly)

        let session = try? router.initiateCall(remoteId: "remote1")
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.remoteId, "remote1")
        XCTAssertTrue(session?.isActive ?? false)

        if let callId = session?.callId {
            XCTAssertNotNil(router.getActiveSession(callId: callId))
            router.endCall(callId: callId)
            XCTAssertNil(router.getActiveSession(callId: callId))
        }
    }

    func testCallRouterEndCallNonexistentDoesNotCrash() {
        let router = CallRouter()
        router.endCall(callId: "fake-id")
        // Should not crash
    }

    func testCallRouterGetActiveSesssionReturnsNilForUnknown() {
        let router = CallRouter()
        XCTAssertNil(router.getActiveSession(callId: "unknown"))
    }

    func testCallRouterSelectionPolicyAccess() {
        let router = CallRouter()
        let policy = router.getSelectionPolicy()
        policy.setPolicy(.perContact)
        if case .perContact = policy.getPolicy() {} else {
            XCTFail("Expected .perContact policy")
        }
    }
}
