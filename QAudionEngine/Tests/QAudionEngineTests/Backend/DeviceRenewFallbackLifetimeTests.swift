import XCTest
@testable import QAudionEngine

/// 2026-10-03 — review of #164: `BCryptoBackendProvider.wireDeviceRenewFallback()` installed a
/// closure that captured a `BCryptoDeviceRenewClient`, which holds the REST client strongly (and,
/// through the key manager's KMS client, a second time), while the REST client stores the closure.
/// That loop kept `BCryptoRestClient.deinit` (the `NWPathMonitor.cancel()`) from ever running, so
/// every wired provider leaked its URLSession and path monitor, and since #164 the dial paths build
/// one wired provider per dial. `BCryptoDeviceRenewClient.makeFallback` breaks the loop; these
/// tests pin it.
final class DeviceRenewFallbackLifetimeTests: XCTestCase {

    private static func keyManager(_ rest: BCryptoRestClient) -> DeviceKeyManager {
        // The same shape as the app's wiring: a KMS client on the live REST client.
        DeviceKeyManager(vault: SovereignKeyVault(), kmsClient: BCryptoKmsClient(rest: rest))
    }

    private func install(on rest: BCryptoRestClient, deviceId: String? = "device-1") {
        rest.setDeviceRenewFallback(BCryptoDeviceRenewClient.makeFallback(
            for: rest,
            makeKeyManager: { Self.keyManager($0) },
            loadDeviceId: { deviceId }))
    }

    private func newClient() -> BCryptoRestClient {
        BCryptoRestClient(config: BackendConfig(serverUrl: "https://renew.test",
                                                accessToken: "A0", refreshToken: "R0"))
    }

    func test_aRestClientWithTheRenewFallbackInstalledDeallocates() {
        weak var weakRest: BCryptoRestClient?
        do {
            let rest = newClient()
            weakRest = rest
            install(on: rest)
            XCTAssertTrue(rest.hasDeviceRenewFallback)
        }
        XCTAssertNil(weakRest, "the installed fallback must not keep the REST client (and its path monitor) alive")
    }

    func test_aRestClientStillDeallocatesAfterTheFallbackRanOnce() async {
        weak var weakRest: BCryptoRestClient?
        let fallback: BCryptoRestClient.DeviceRenewFallback
        do {
            let rest = newClient()
            weakRest = rest
            fallback = BCryptoDeviceRenewClient.makeFallback(
                for: rest,
                makeKeyManager: { Self.keyManager($0) },
                loadDeviceId: { "device-1" })
            // Runs the whole closure body against the live client: the renew client and the key
            // manager are built, used (the device key is not provisioned in a test, or the
            // Keychain refuses) and dropped. Whatever the error, nothing may stay behind.
            do {
                _ = try await fallback()
                XCTFail("a device without a provisioned key cannot renew")
            } catch {}
        }
        XCTAssertNil(weakRest, "a renew attempt must not leave anything holding the REST client")
        // The closure is still around (the client stored it), now facing a dead client.
        do {
            _ = try await fallback()
            XCTFail("expected restClientGone")
        } catch let error as BCryptoDeviceRenewClient.Error {
            guard case .restClientGone = error else {
                return XCTFail("expected restClientGone, got \(error)")
            }
        } catch {
            XCTFail("expected restClientGone, got \(error)")
        }
    }

    func test_aReleasedRestClientFailsTheRenewSafelyAndTransiently() async {
        let fallback: BCryptoRestClient.DeviceRenewFallback
        do {
            let rest = newClient()
            fallback = BCryptoDeviceRenewClient.makeFallback(
                for: rest,
                makeKeyManager: { Self.keyManager($0) },
                loadDeviceId: { "device-1" })
        }
        do {
            _ = try await fallback()
            XCTFail("a renew on a released client cannot succeed")
        } catch {
            let failure = AuthFailureClassifier.classifyRenew(error)
            XCTAssertEqual(failure.reason, .renewOther)
            XCTAssertFalse(failure.isFinal, "a released client says nothing about the session")
            XCTAssertFalse(failure.provesCredentialLoss)
        }
    }

    func test_anEmptyDeviceIdIsStillReportedAsSuchWhileTheClientIsAlive() async {
        let rest = newClient()
        let renewer = BCryptoDeviceRenewClient.makeFallback(
            for: rest,
            makeKeyManager: { Self.keyManager($0) },
            loadDeviceId: { "" })
        do {
            _ = try await renewer()
            XCTFail("an empty device id cannot renew")
        } catch {
            XCTAssertEqual(error as? AuthRenewPreconditionError, .noDeviceId)
            XCTAssertEqual(AuthFailureClassifier.classifyRenew(error).reason, .renewNoDeviceId)
        }
    }
}
