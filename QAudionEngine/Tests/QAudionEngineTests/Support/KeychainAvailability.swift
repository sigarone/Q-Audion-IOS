import Foundation
import Security
import XCTest

/// Probes whether THIS test host can actually use the Keychain.
///
/// A unit-test bundle running in the simulator has no keychain-access-group
/// entitlement, so every `SecItemAdd` comes back `-34018`
/// (`errSecMissingEntitlement`). Anything that stores a real key — the
/// sovereign PSK vault, the sovereign identity — therefore cannot be
/// exercised there, however correct it is.
///
/// That was the actual reason `SovereignKeyVaultNotificationTests` and
/// `CrossPlatformTestVectors/testSovereignIdentityKeychainPersistence` were
/// switched off at the CI level on 2026-06-19, though nobody wrote it down.
/// A CI-level `-skip-testing` is the wrong tool for it: the test disappears
/// silently, on every platform, forever, and the suite gives no hint that
/// coverage is missing. `XCTSkipUnless` reports the skip with its reason in
/// the test output, and the case still runs — and must still pass — anywhere
/// the Keychain works, which includes a real device.
///
/// The probe writes and removes a throwaway item rather than inferring from
/// the environment, so it reports what this host can do rather than what it
/// is assumed to do.
enum KeychainAvailability {

    private static let probeService = "com.bcrypto.qaudion.tests.keychain-probe"

    static let isUsable: Bool = {
        let account = "probe-\(UUID().uuidString)"
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data([0x01]),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { return false }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        return true
    }()

    /// Call at the top of a test that genuinely needs the real Keychain.
    static func requireKeychain(file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(
            isUsable,
            "Keychain unusable in this test host (SecItemAdd -34018, no keychain-access-group entitlement in a simulator test bundle). This case is not disabled — it runs and must pass wherever the Keychain works, including on device.",
            file: file, line: line
        )
    }
}
