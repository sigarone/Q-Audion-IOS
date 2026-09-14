import XCTest
import Security
@testable import QAudionEngine

/// W-KCAFTERUNLOCK (2026-09-01) — real-Keychain half of the accessibility
/// change: fresh items land on `AfterFirstUnlockThisDeviceOnly`, and an item
/// still on the legacy `WhenUnlockedThisDeviceOnly` class is upgraded in place
/// by the first successful read WITHOUT its value changing.
///
/// Skipped via `KeychainAvailability.requireKeychain()` wherever the Keychain
/// is unusable (the CI simulator test bundle, -34018) — reported as a skip,
/// not silently absent — and runs, and must pass, on a device. The sovereign
/// identity is deliberately NOT exercised here: its Keychain item is the
/// device's one real identity (service/account are fixed) and a test must not
/// overwrite it; it shares `KeychainAccessibilityMigration` with the two
/// vaults below, which are covered under throwaway names.
final class KeychainAccessibilityMigrationTests: XCTestCase {

    /// `SovereignKeyVault.service` is private; the string is frozen storage
    /// format (every PSK on every device lives under it), so it is safe to pin.
    private let pskService = "com.bcrypto.qaudion.psk"
    private let pskName = "kcafu-\(UUID().uuidString)"
    private let ratchetEpoch = "kcafu-\(UUID().uuidString)"
    private let peer = "peer"

    override func tearDownWithError() throws {
        try? SovereignKeyVault().deletePsk(name: pskName)
        KeychainRatchetVault().deleteV4(epochId: ratchetEpoch, peerId: peer)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func accessibility(service: String, account: String) -> KeychainAccessibilityPolicy.AccessClass? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attrs = item as? [String: Any] else { return nil }
        return KeychainAccessibilityPolicy.accessClass(fromAttribute: attrs[kSecAttrAccessible as String])
    }

    /// Writes an item exactly the way every vault did before this change.
    private func seedLegacyItem(service: String, account: String, value: Data) {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess, "seeding the legacy item failed")
    }

    /// The ratchet vault's account format (`KeychainRatchetVault.account`,
    /// private) — "<epochId>|<peerId>", frozen storage format.
    private var ratchetAccount: String { "\(ratchetEpoch)|\(peer)" }

    // MARK: - SovereignKeyVault

    func testFreshPskIsWrittenAfterFirstUnlock() throws {
        try KeychainAvailability.requireKeychain()
        try XCTSkipUnless(
            !KeychainProtectionPolicy.shared.isEnabled,
            "biometric key protection ON: items carry a .userPresence access control, not a plain class")
        try SovereignKeyVault().storePsk(name: pskName, key: Data(repeating: 0x11, count: 32), fingerprint: "fp")
        XCTAssertEqual(accessibility(service: pskService, account: pskName), .afterFirstUnlockThisDeviceOnly)
    }

    // THE MIGRATION: legacy class → read → same value back → now on the new class → stable.
    func testLegacyPskIsUpgradedInPlaceOnReadWithoutLosingTheValue() throws {
        try KeychainAvailability.requireKeychain()
        try XCTSkipUnless(
            !KeychainProtectionPolicy.shared.isEnabled,
            "biometric key protection ON: loadPsk attaches an authentication context, not under test here")
        let value = Data(repeating: 0x22, count: 32)
        seedLegacyItem(service: pskService, account: pskName, value: value)
        XCTAssertEqual(accessibility(service: pskService, account: pskName), .whenUnlockedThisDeviceOnly)

        XCTAssertEqual(try SovereignKeyVault().loadPsk(name: pskName), value)
        XCTAssertEqual(accessibility(service: pskService, account: pskName), .afterFirstUnlockThisDeviceOnly)

        // Idempotent: a second read changes nothing and returns the same bytes.
        XCTAssertEqual(try SovereignKeyVault().loadPsk(name: pskName), value)
        XCTAssertEqual(accessibility(service: pskService, account: pskName), .afterFirstUnlockThisDeviceOnly)
    }

    func testAbsentPskStillReadsAsNilNotAsAnError() throws {
        try KeychainAvailability.requireKeychain()
        XCTAssertNil(try SovereignKeyVault().loadPsk(name: pskName))
    }

    // MARK: - KeychainRatchetVault

    func testFreshRatchetBlobIsWrittenAfterFirstUnlock() throws {
        try KeychainAvailability.requireKeychain()
        try KeychainRatchetVault().saveV4(epochId: ratchetEpoch, peerId: peer, blob: Data([0x01, 0x02]))
        XCTAssertEqual(
            accessibility(service: KeychainRatchetVault.serviceV4, account: ratchetAccount),
            .afterFirstUnlockThisDeviceOnly)
    }

    func testLegacyRatchetBlobIsUpgradedInPlaceOnReadWithoutLosingTheValue() throws {
        try KeychainAvailability.requireKeychain()
        let blob = Data([0xE5, 0x01, 0x02, 0x03])
        seedLegacyItem(service: KeychainRatchetVault.serviceV4, account: ratchetAccount, value: blob)
        XCTAssertEqual(
            accessibility(service: KeychainRatchetVault.serviceV4, account: ratchetAccount),
            .whenUnlockedThisDeviceOnly)

        XCTAssertEqual(KeychainRatchetVault().loadV4(epochId: ratchetEpoch, peerId: peer), blob)
        XCTAssertEqual(
            accessibility(service: KeychainRatchetVault.serviceV4, account: ratchetAccount),
            .afterFirstUnlockThisDeviceOnly)

        XCTAssertEqual(KeychainRatchetVault().loadV4(epochId: ratchetEpoch, peerId: peer), blob)
    }

    func testAbsentRatchetSnapshotStillReadsAsNilThroughLoadChecked() throws {
        try KeychainAvailability.requireKeychain()
        XCTAssertNil(try KeychainRatchetVault().loadChecked(epochId: ratchetEpoch, peerId: peer))
    }
}
