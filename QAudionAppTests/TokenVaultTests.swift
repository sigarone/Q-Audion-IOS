import XCTest
@testable import QAudionApp

/// Entitlements Task 2 (2026-08-17) — coverage for `TokenVault`'s new
/// `saveEntitlement`/`loadEntitlement`/`clearEntitlement` Keychain API and
/// its wiring into the existing full-wipe `clear()` (the same function
/// `AuthService.clearToken()` calls on logout, so a stale EGT for a
/// previous user is never left behind after logout).
///
/// NOTE (not yet wired into a build target): same gap `DisplayNameTests
/// .swift`/`PeerTrustEvaluatorTests.swift`/`HeroPresenceLabelTests.swift`/
/// `NameResolutionServicePhoneNumberOfTests.swift`/`LocalCallerIdSettingsTests
/// .swift`/`GroupCreationMetadataTests.swift` already document: no
/// `QAudionAppTests` XCTest target is wired in `QAudionApp/project.yml`
/// today, and no Xcode/Swift toolchain is available in this session
/// (Windows, no macOS/Xcode) to compile or run this file. Written against
/// that gap rather than left unwritten — UNVERIFIED BY COMPILATION,
/// reviewed carefully by hand instead: the new Keychain query construction
/// (`entitlementAccount = "entitlement_blob"`, routed through the exact
/// same private `save`/`load`/`delete`/`baseQuery` primitives the existing
/// `accessAccount`/`refreshAccount`/`deviceIdAccount`/`userIdAccount`
/// already use) was diffed character-by-character against those four
/// working accounts in `TokenVault.swift`.
///
/// Isolation note: unlike `ContactsStore`/`PeerIdentityPinStore`
/// (`PeerTrustEvaluatorTests.swift`), which are scoped by a randomised,
/// collision-proof `userId` per test, `TokenVault`'s account keys are fixed
/// constants by design — there is exactly one logical session per device,
/// so there is no per-test namespace to allocate. `testSaveAndLoadEntitlementBlob`
/// / `testClearRemovesEntitlementBlob` / `testLoadReturnsNilWhenNothingSaved`
/// only ever touch the new `entitlementAccount` (via `saveEntitlement`/
/// `loadEntitlement`/`clearEntitlement`), so they cannot disturb the real
/// access/refresh/device/user-id items even if a genuine session happens to
/// be sitting in the Keychain when this runs. `testFullWipeClearsEntitlementBlobToo`
/// necessarily calls the real `TokenVault.clear()` to prove the entitlement
/// account was actually added to that shared wipe list (not just
/// independently clearable via `clearEntitlement()` alone) — `setUp`/
/// `tearDown` snapshot and restore whatever ALL FIVE accounts held
/// before/after each test runs, so a real device session is never
/// permanently lost by running this suite.
///
/// `entitlementAccount` was NOT snapshot-restored here originally (Task 2,
/// 2026-08-17) — harmless at the time since nothing yet wrote a real cached
/// EGT, but Task 3's `CapabilityGate` is exactly what starts doing that
/// (`loadCached()`/`refresh()`/`adopt()` all call `TokenVault.saveEntitlement`).
/// Made symmetric with the other four accounts below (Task 3 carry-forward)
/// so running this suite on a device holding a real cached EGT no longer
/// silently discards it.
final class TokenVaultTests: XCTestCase {

    private var savedAccessToken: String?
    private var savedRefreshToken: String?
    private var savedDeviceId: String?
    private var savedUserId: String?
    private var savedEntitlement: String?

    override func setUp() {
        super.setUp()
        savedAccessToken = TokenVault.loadAccessToken()
        savedRefreshToken = TokenVault.loadRefreshToken()
        savedDeviceId = TokenVault.loadDeviceId()
        savedUserId = TokenVault.loadUserId()
        savedEntitlement = TokenVault.loadEntitlement()
        TokenVault.clearEntitlement()
    }

    override func tearDown() {
        TokenVault.clearEntitlement()
        if let savedAccessToken { TokenVault.saveAccessToken(savedAccessToken) }
        if let savedRefreshToken { TokenVault.saveRefreshToken(savedRefreshToken) }
        if let savedDeviceId { TokenVault.saveDeviceId(savedDeviceId) }
        if let savedUserId { TokenVault.saveUserId(savedUserId) }
        if let savedEntitlement { TokenVault.saveEntitlement(savedEntitlement) }
        super.tearDown()
    }

    func testSaveAndLoadEntitlementBlob() {
        TokenVault.saveEntitlement("header.payload.sig")
        XCTAssertEqual(TokenVault.loadEntitlement(), "header.payload.sig")
    }

    func testClearRemovesEntitlementBlob() {
        TokenVault.saveEntitlement("header.payload.sig")
        TokenVault.clearEntitlement()
        XCTAssertNil(TokenVault.loadEntitlement())
    }

    func testLoadReturnsNilWhenNothingSaved() {
        // `setUp` already guarantees a clean `entitlementAccount` for every test.
        XCTAssertNil(TokenVault.loadEntitlement())
    }

    func testFullWipeClearsEntitlementBlobToo() {
        // Proves the entitlement account was actually wired into
        // `TokenVault.clear()`'s account list — the function
        // `AuthService.clearToken()` calls on logout — not just
        // independently clearable via `clearEntitlement()` alone.
        TokenVault.saveEntitlement("header.payload.sig")
        TokenVault.clear()
        XCTAssertNil(TokenVault.loadEntitlement())
    }
}
