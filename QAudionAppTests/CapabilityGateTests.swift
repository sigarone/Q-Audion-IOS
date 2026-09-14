import XCTest
import CryptoKit
@testable import QAudionApp
import QAudionEngine

/// Entitlements Task 3 (2026-08-17) — coverage for `CapabilityGate`'s two
/// load-bearing failure-safety properties (design doc §3.2 / §7.1), ported
/// from Android's approved `CapabilityGateTest.kt` and adapted to real
/// signed tokens instead of a fake `EgtVerifier`: `EgtVerifier` is a
/// `final class` with no protocol seam (Task 1's design — see its own doc:
/// the only test-only injection point, `verifySignatureOverride`, is an
/// `internal` initializer reachable only from `QAudionEngineTests` via
/// `@testable import`, not from this different test target), so every case
/// here signs a REAL compact EGT with a fresh throwaway Ed25519 keypair
/// (`Curve25519.Signing.PrivateKey()`) and constructs a REAL `EgtVerifier`
/// pinned to that keypair's public half — the same pattern
/// `EgtVerifierTests.signedToken(payload:)` already establishes, reused
/// here rather than inventing a fake-verifier abstraction with no other
/// caller.
///
/// NOTE (not yet wired into a build target): same gap `TokenVaultTests
/// .swift`/`PeerTrustEvaluatorTests.swift`/etc. already document — no
/// `QAudionAppTests` XCTest target in `QAudionApp/project.yml` today, and
/// no Xcode/Swift toolchain available in this session (Windows, no macOS)
/// to compile or run this file. Written against that gap rather than left
/// unwritten (TDD discipline: written FIRST, verified by reading they would
/// fail against the pre-`CapabilityGate.swift` tree, then implemented,
/// then verified by reading they would now pass) — UNVERIFIED BY
/// COMPILATION, matching Task 1/2's own honesty standard.
///
/// Isolation: exercises the real `TokenVault` Keychain (`CapabilityGate`
/// reads `TokenVault.loadUserId()`/`.loadEntitlement()` directly, with no
/// injection point — same pre-existing constraint `PeerTrustEvaluatorTests`
/// documents for `ContactsStore`/`PeerIdentityPinStore`), so `setUp`/
/// `tearDown` snapshot and restore the `userId`/`entitlement` accounts
/// exactly like `TokenVaultTests` does for its four accounts, so a real
/// device session sitting in the Keychain is never permanently lost by
/// running this suite.
@MainActor
final class CapabilityGateTests: XCTestCase {

    private var savedUserId: String?
    private var savedEntitlement: String?
    private var privateKey: Curve25519.Signing.PrivateKey!
    private var verifier: EgtVerifier!

    override func setUp() {
        super.setUp()
        savedUserId = TokenVault.loadUserId()
        savedEntitlement = TokenVault.loadEntitlement()
        TokenVault.clearEntitlement()
        privateKey = Curve25519.Signing.PrivateKey()
        verifier = EgtVerifier(pinnedPublicKeyRaw: privateKey.publicKey.rawRepresentation)
    }

    override func tearDown() {
        TokenVault.clearEntitlement()
        if let savedEntitlement { TokenVault.saveEntitlement(savedEntitlement) }
        if let savedUserId { TokenVault.saveUserId(savedUserId) }
        privateKey = nil
        verifier = nil
        super.tearDown()
    }

    // MARK: - has() / isUnlocked() before any token is loaded

    func testHasReturnsFalseBeforeAnyTokenLoaded() {
        let gate = makeGate()
        XCTAssertFalse(gate.has(.files))
    }

    func testIsUnlockedReturnsTrueBeforeAnyTokenLoaded() {
        // "Nothing verified yet" must never render as locked (Android's
        // Task 4 review C1/C2 — see CapabilityGate.swift's isUnlocked doc).
        let gate = makeGate()
        XCTAssertTrue(gate.isUnlocked(.files))
    }

    // MARK: - loadCached()

    func testLoadCachedDiscardsATokenForADifferentUser() throws {
        // design doc §7.1: discarded the instant blob.sub != current user.
        TokenVault.saveUserId("user-a")
        let staleToken = try signedToken(sub: "user-b", fea: ["feat.files": 0])
        TokenVault.saveEntitlement(staleToken)
        let gate = makeGate()

        gate.loadCached()

        XCTAssertFalse(gate.has(.files))
        XCTAssertNil(TokenVault.loadEntitlement(), "a cross-user grant must be wiped from the Keychain too, not just ignored in memory")
    }

    func testLoadCachedAcceptsATokenMatchingTheCurrentUser() throws {
        TokenVault.saveUserId("user-a")
        let token = try signedToken(sub: "user-a", fea: ["feat.files": 0])
        TokenVault.saveEntitlement(token)
        let gate = makeGate()

        gate.loadCached()

        XCTAssertTrue(gate.has(.files))
    }

    func testLoadCachedWithNothingCachedYieldsNoCapabilitiesWithoutTouchingTheStore() {
        TokenVault.saveUserId("user-a")
        let gate = makeGate()

        gate.loadCached()

        XCTAssertFalse(gate.has(.files))
        XCTAssertNil(TokenVault.loadEntitlement())
    }

    func testVerificationFailureNeverGrantsACapability() {
        // A cached blob that isn't even a well-formed compact EGT must
        // fail closed, exactly like a tampered signature would.
        TokenVault.saveUserId("user-a")
        TokenVault.saveEntitlement("not.a.validtoken")
        let gate = makeGate()

        gate.loadCached()

        XCTAssertFalse(gate.has(.files))
    }

    // MARK: - discard() — whole-phase-review finding I1 (2026-08-17)

    func testDiscardClearsInMemoryClaimsAndKeychainWithoutAnyUserIdChange() throws {
        // The 4 session-ending sites that call this (hard credential
        // rejection, remote_wipe, account_locked, account deletion) clear
        // TokenVault via AuthService.clearToken() but do NOT change
        // currentUserId, so the didSet-driven loadCached() discard never
        // fires — discard() is the explicit substitute.
        TokenVault.saveUserId("user-a")
        let token = try signedToken(sub: "user-a", fea: ["feat.files": 0])
        TokenVault.saveEntitlement(token)
        let gate = makeGate()
        gate.loadCached()
        XCTAssertTrue(gate.has(.files), "sanity: cache valid before discard()")

        gate.discard()

        XCTAssertFalse(gate.has(.files))
        XCTAssertNil(TokenVault.loadEntitlement())
    }

    func testDiscardIsSafeToCallWithNothingCached() {
        TokenVault.saveUserId("user-a")
        let gate = makeGate()

        gate.discard()

        XCTAssertFalse(gate.has(.files))
        XCTAssertNil(TokenVault.loadEntitlement())
    }

    // MARK: - refresh() — design doc §3.2: exp is a refresh target, not a kill switch

    func testRefreshFailureLeavesExistingCacheIntact() async throws {
        TokenVault.saveUserId("user-a")
        let token = try signedToken(sub: "user-a", fea: ["feat.files": 0])
        TokenVault.saveEntitlement(token)
        let gate = makeGate(api: FakeEntitlementsApiClient(result: .failure(FakeApiError())))
        gate.loadCached()
        XCTAssertTrue(gate.has(.files), "sanity: the cache must be valid before refresh() runs")

        await gate.refresh()

        XCTAssertTrue(gate.has(.files), "a failed refresh must not clear an already-valid cache")
        XCTAssertEqual(TokenVault.loadEntitlement(), token, "the Keychain copy must also survive a failed refresh")
    }

    func testRefreshSuccessCachesAndUpdatesClaims() async throws {
        TokenVault.saveUserId("user-a")
        let fresh = try signedToken(sub: "user-a", fea: ["feat.files": 0, "feat.vpn": 0])
        let gate = makeGate(api: FakeEntitlementsApiClient(
            result: .success(EntitlementsTokenResponse(token: fresh, kid: "ent-v1"))
        ))
        XCTAssertFalse(gate.has(.files), "sanity: nothing loaded yet")

        await gate.refresh()

        XCTAssertTrue(gate.has(.files))
        XCTAssertTrue(gate.has(.vpn))
        XCTAssertEqual(TokenVault.loadEntitlement(), fresh)
    }

    func testRefreshRejectsATokenForTheWrongUserAndKeepsWhateverWasCached() async throws {
        // Same acceptance rule as loadCached(), applied to a FRESHLY
        // fetched token — a mint-endpoint bug or a stale server response
        // must never silently adopt the wrong user's grant.
        TokenVault.saveUserId("user-a")
        let existing = try signedToken(sub: "user-a", fea: ["feat.files": 0])
        TokenVault.saveEntitlement(existing)

        let wrongUser = try signedToken(sub: "user-b", fea: ["feat.vpn": 0])
        let gate = makeGate(api: FakeEntitlementsApiClient(
            result: .success(EntitlementsTokenResponse(token: wrongUser, kid: "ent-v1"))
        ))
        gate.loadCached()
        XCTAssertTrue(gate.has(.files), "sanity: existing cache valid before the bad refresh")

        await gate.refresh()

        XCTAssertTrue(gate.has(.files), "a wrong-sub refresh response must not overwrite the existing cache")
        XCTAssertFalse(gate.has(.vpn))
        XCTAssertEqual(TokenVault.loadEntitlement(), existing)
    }

    func testRefreshWithAVerificationFailureKeepsWhateverWasCached() async throws {
        TokenVault.saveUserId("user-a")
        let existing = try signedToken(sub: "user-a", fea: ["feat.files": 0])
        TokenVault.saveEntitlement(existing)
        let gate = makeGate(api: FakeEntitlementsApiClient(
            result: .success(EntitlementsTokenResponse(token: "garbage.not.atoken", kid: "ent-v1"))
        ))
        gate.loadCached()

        await gate.refresh()

        XCTAssertTrue(gate.has(.files), "an unverifiable fresh token must not clear the existing valid cache")
        XCTAssertEqual(TokenVault.loadEntitlement(), existing)
    }

    // MARK: - has() expiry semantics (design doc §3.1: 0 = perpetual)

    func testHasTreatsZeroExpiryAsPerpetual() throws {
        TokenVault.saveUserId("user-a")
        let token = try signedToken(sub: "user-a", fea: ["feat.files": 0])
        TokenVault.saveEntitlement(token)
        let gate = makeGate()
        gate.loadCached()

        XCTAssertTrue(gate.has(.files))
    }

    func testHasRejectsAnExpiredPerFeatureEntry() throws {
        TokenVault.saveUserId("user-a")
        let past = Int64(Date().timeIntervalSince1970) - 1000
        let token = try signedToken(sub: "user-a", fea: ["feat.files": past])
        TokenVault.saveEntitlement(token)
        let gate = makeGate()
        gate.loadCached()

        XCTAssertFalse(gate.has(.files), "an expired per-feature entry must not grant the capability")
    }

    func testIsUnlockedDistinguishesNoGrantFromAnExplicitDenial() throws {
        // Once a REAL grant is loaded, isUnlocked must behave like has() —
        // the "unknown" leniency in isUnlocked only applies before any
        // verified claims exist at all.
        TokenVault.saveUserId("user-a")
        let token = try signedToken(sub: "user-a", fea: ["feat.files": 0])
        TokenVault.saveEntitlement(token)
        let gate = makeGate()
        gate.loadCached()

        XCTAssertTrue(gate.isUnlocked(.files))
        XCTAssertFalse(gate.isUnlocked(.vpn), "a capability absent from a LOADED grant must read as locked, not unknown")
    }

    // MARK: - adopt() — Task 4's intended future caller (redemption flow)

    func testAdoptAcceptsAMatchingTokenAndRejectsAMismatchedOne() throws {
        TokenVault.saveUserId("user-a")
        let gate = makeGate()

        let wrongUser = try signedToken(sub: "user-b", fea: ["feat.files": 0])
        XCTAssertFalse(gate.adopt(wrongUser))
        XCTAssertFalse(gate.has(.files))

        let rightUser = try signedToken(sub: "user-a", fea: ["feat.files": 0])
        XCTAssertTrue(gate.adopt(rightUser))
        XCTAssertTrue(gate.has(.files))
        XCTAssertEqual(TokenVault.loadEntitlement(), rightUser)
    }

    // MARK: - Helpers

    private func makeGate(api: EntitlementsApiClient = FakeEntitlementsApiClient(result: .failure(FakeApiError()))) -> CapabilityGate {
        CapabilityGate(verifier: verifier, api: api)
    }

    /// Signs a minimal EGT payload with `privateKey` (this test's shared
    /// throwaway keypair, matching `verifier`) and the given `sub`/`fea`.
    /// Real Ed25519 signing + the real `EgtVerifier`, not a hand-rolled
    /// stand-in — same reasoning as `EgtVerifierTests.signedToken(payload:)`.
    private func signedToken(sub: String, fea: [String: Int64]) throws -> String {
        let feaJson = fea.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        let payload = #"{"v":1,"sub":""# + sub + #"","did":"test-device","dkt":"","pkg":["base","pro"],"fea":{"# + feaJson + #"},"lim":{},"pol":{"min_assurance":"none","on_violation":"warn"},"ee":1,"iat":0,"exp":9999999999}"#
        let header = #"{"alg":"EdDSA","kid":"ent-v1","typ":"BEGT"}"#
        let signedPart = "\(base64urlEncode(Data(header.utf8))).\(base64urlEncode(Data(payload.utf8)))"
        let sig = try privateKey.signature(for: Data(signedPart.utf8))
        return "\(signedPart).\(base64urlEncode(sig))"
    }
}

// MARK: - Test doubles

private final class FakeEntitlementsApiClient: EntitlementsApiClient {
    private let result: Result<EntitlementsTokenResponse, Error>
    init(result: Result<EntitlementsTokenResponse, Error>) { self.result = result }
    func fetchEntitlementsToken() async throws -> EntitlementsTokenResponse { try result.get() }

    // Task 4 (2026-08-17) added `redeemActivationCode` to the shared
    // `EntitlementsApiClient` protocol — no `CapabilityGateTests` case
    // exercises redemption (that is `UpgradeSheetContainerTests`'s job),
    // so this stub only exists to keep this fake conforming; it must never
    // be called from this file.
    func redeemActivationCode(_ code: String) async throws -> RedeemActivationCodeResponse {
        fatalError("FakeEntitlementsApiClient.redeemActivationCode should not be called from CapabilityGateTests")
    }
}

private struct FakeApiError: Error {}

// Test-only base64url helper (standard base64url-no-padding encoding),
// same shape as EgtVerifierTests' own private helper — kept file-local
// rather than shared across modules since EgtVerifier's own decode side
// is deliberately private to its own file.
private func base64urlEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
