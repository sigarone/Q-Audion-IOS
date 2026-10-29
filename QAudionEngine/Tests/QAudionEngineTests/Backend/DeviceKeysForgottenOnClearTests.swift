import XCTest
@testable import QAudionEngine

/// The device keys live in the same Keychain service as the shared secrets, so the vault-wide clear
/// that sign-out, remote wipe and account deletion run must take every one of them with it.
final class DeviceKeysForgottenOnClearTests: XCTestCase {

    override func setUpWithError() throws {
        try KeychainAvailability.requireKeychain()
        try SovereignKeyVault().clearAll()
    }

    override func tearDownWithError() throws {
        try? SovereignKeyVault().clearAll()
    }

    func test_clearAllRemovesEveryDeviceKeyAndTheAccessorsReturnNil() throws {
        let vault = SovereignKeyVault()
        let rest = BCryptoRestClient(config: BackendConfig(serverUrl: "https://keys.test",
                                                           accessToken: "A0", refreshToken: "R0"))
        let manager = DeviceKeyManager(vault: vault, kmsClient: BCryptoKmsClient(rest: rest))
        let sizes: [(String, Int)] = [
            ("__device.x25519.priv", 32), ("__device.x25519.pub", 32),
            ("__device.mlkem.priv", 3168), ("__device.mlkem.pub", 1568),
            ("__device.ed25519.priv", 32), ("__device.ed25519.pub", 32),
        ]
        for (name, size) in sizes {
            try vault.storePsk(name: name, key: Data(repeating: 7, count: size), fingerprint: "device-key")
        }
        XCTAssertNotNil(try manager.currentEd25519Priv())
        XCTAssertNotNil(try manager.currentEd25519Pub())
        XCTAssertNotNil(try manager.currentX25519Pub())
        XCTAssertNotNil(try manager.currentKeys())

        try vault.clearAll()

        XCTAssertNil(try manager.currentEd25519Priv())
        XCTAssertNil(try manager.currentEd25519Pub())
        XCTAssertNil(try manager.currentX25519Pub())
        XCTAssertNil(try manager.currentKeys())
        for (name, _) in sizes {
            XCTAssertNil(try vault.loadPsk(name: name), "\(name) survived the clear")
        }
    }
}
