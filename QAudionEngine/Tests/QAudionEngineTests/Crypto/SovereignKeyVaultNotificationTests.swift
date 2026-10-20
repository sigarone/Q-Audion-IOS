import XCTest
@testable import QAudionEngine

/// W-VAULTREFRESH — pins the real root cause fix for the reported bug
/// "vault doesn't show a newly-paired NFC key immediately, has to
/// leave/re-enter the screen": the list of Key management
/// (`KeyManagementCoordinator.keys` in `QAudionApp/Services`) was
/// populated only once at `init()` plus after its OWN calls -- a PSK
/// written by a path that
/// doesn't hold a reference to that coordinator (`NfcExchangeView
/// .persistPsk`, called after a real NFC tap) never triggered a refresh.
///
/// Fix: `SovereignKeyVault.storePsk`/`deletePsk` now post
/// `.sovereignVaultDidChange` (mirroring `ContactsStore`'s own
/// `.contactsDidChange` convention, already relied on elsewhere in this
/// codebase for the identical class of problem) so ANY vault-mutating code
/// path notifies listeners, not just the call sites the coordinator
/// itself happens to know about. The device-internal entries (`__` prefix)
/// stay quiet.
///
/// This pins the MECHANISM half (does the vault actually notify) in a
/// module (`QAudionEngine`) covered by CI (`engine-tests.yml`
/// `ios-simulator-tests`). The CONSUMER half (`KeyManagementCoordinator`
/// subscribing and calling `loadKeys()`) lives in `QAudionApp`: the
/// observer is registered without a queue, so the poster never waits for
/// the main queue, and hops to the main actor with
/// `Task { @MainActor [weak self] in ... }`.
///
/// **Not run in CI.** This test performs real Keychain I/O
/// (`SovereignKeyVault.storePsk`/`deletePsk`), which fails on the CI
/// simulator with `errSecMissingEntitlement` (-34018) — a corrected claim:
/// an earlier version of this comment cited `CrossPlatformTestVectors
/// .testSovereignIdentityKeychainPersistence()` as a working precedent for
/// live Keychain I/O in this environment, but that test is ITSELF
/// `-skip-testing`'d in `engine-tests.yml` for the same reason, so it never
/// actually proved anything. `engine-tests.yml` skips this whole suite too,
/// matching that established convention rather than fighting the CI
/// environment. The notification-posting production code
/// (`SovereignKeyVault.swift`'s two `NotificationCenter.default.post(name:
/// .sovereignVaultDidChange, ...)` call sites) is a two-line, easily
/// code-reviewed change; this file remains as a real, locally-runnable
/// regression test for anyone with a properly keychain-provisioned device
/// or simulator.
final class SovereignKeyVaultNotificationTests: XCTestCase {

    private let testName = "test-vault-notify-\(UUID().uuidString)"
    private let internalTestName = "__test-vault-notify-\(UUID().uuidString)"

    override func tearDownWithError() throws {
        let vault = SovereignKeyVault()
        try? vault.deletePsk(name: testName)
        try? vault.deletePsk(name: internalTestName)
        try super.tearDownWithError()
    }

    func testStorePsk_postsSovereignVaultDidChange() throws {
        try KeychainAvailability.requireKeychain()
        let vault = SovereignKeyVault()
        let posted = expectation(description: "sovereignVaultDidChange posted on storePsk")
        let observer = NotificationCenter.default.addObserver(
            forName: .sovereignVaultDidChange, object: nil, queue: nil
        ) { _ in posted.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        try vault.storePsk(name: testName, key: Data(repeating: 0x01, count: 32), fingerprint: "deadbeef")

        wait(for: [posted], timeout: 2.0)
    }

    func testDeletePsk_postsSovereignVaultDidChange() throws {
        try KeychainAvailability.requireKeychain()
        let vault = SovereignKeyVault()
        try vault.storePsk(name: testName, key: Data(repeating: 0x02, count: 32), fingerprint: "cafebabe")

        let posted = expectation(description: "sovereignVaultDidChange posted on deletePsk")
        let observer = NotificationCenter.default.addObserver(
            forName: .sovereignVaultDidChange, object: nil, queue: nil
        ) { _ in posted.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        try vault.deletePsk(name: testName)

        wait(for: [posted], timeout: 2.0)
    }

    /// Regression guard: an UPDATE (re-storing an existing account name,
    /// the `errSecDuplicateItem` branch of `storeInternal`) must ALSO
    /// notify -- this is the exact path `SovereignKeyVault.migratePskProtection`
    /// aside, `storePsk` re-called for the SAME name (e.g. re-tapping the
    /// same NFC peer) takes.
    func testStorePsk_updateExistingEntry_alsoPostsNotification() throws {
        try KeychainAvailability.requireKeychain()
        let vault = SovereignKeyVault()
        try vault.storePsk(name: testName, key: Data(repeating: 0x03, count: 32), fingerprint: "fp1")

        let posted = expectation(description: "sovereignVaultDidChange posted on update")
        let observer = NotificationCenter.default.addObserver(
            forName: .sovereignVaultDidChange, object: nil, queue: nil
        ) { _ in posted.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Re-store under the SAME name -> hits the update (errSecDuplicateItem) branch.
        try vault.storePsk(name: testName, key: Data(repeating: 0x04, count: 32), fingerprint: "fp2")

        wait(for: [posted], timeout: 2.0)
    }

    /// A device-internal entry (`__` prefix: the order of the call keys is one) is written and deleted without a
    /// notification: `CallKeyPriorityStore` writes it inside its lock, where no observer may run.
    func testDeviceInternalEntry_writeAndDeletePostNothing() throws {
        try KeychainAvailability.requireKeychain()
        let vault = SovereignKeyVault()
        let silent = expectation(description: "no sovereignVaultDidChange for a device-internal entry")
        silent.isInverted = true
        let observer = NotificationCenter.default.addObserver(
            forName: .sovereignVaultDidChange, object: nil, queue: nil
        ) { _ in silent.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        try vault.storePsk(name: internalTestName, key: Data(repeating: 0x05, count: 32), fingerprint: "fp3")
        try vault.storePsk(name: internalTestName, key: Data(repeating: 0x06, count: 32), fingerprint: "fp4")
        try vault.deletePsk(name: internalTestName)

        wait(for: [silent], timeout: 0.5)
    }
}
