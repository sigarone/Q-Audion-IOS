import XCTest
import CryptoKit
@testable import QAudionApp
import QAudionEngine

/// Entitlements Task 4 (2026-08-17) — coverage for
/// `UpgradeSheetContainer.redeem`, the single most important behavioral
/// correctness point of this task: on a successful redemption it must call
/// `capabilityGate.adopt(response.token)`, NEVER `capabilityGate.refresh()`
/// — this is the exact regression Android's Task 5 review caught and had
/// to fix (whole-phase-review fix I-1: the redeem response carries a
/// freshly minted EGT inline specifically so the client never needs a
/// follow-up `GET /entitlements/token` round-trip, and on the idempotent-
/// replay path the server does not even fire the `entitlements_changed`
/// doorbell, so the inline token is the ONLY delivery mechanism for that
/// case). `testRedeemOnSuccessAdoptsTheInlineTokenAndNeverCallsRefresh`
/// below is written specifically so it would FAIL if this file were
/// "fixed" back to calling `refresh()` instead of `adopt()`.
///
/// Same real-signing approach `CapabilityGateTests.swift` (Task 3)
/// establishes rather than a mocking framework (none is used anywhere in
/// this codebase): `CapabilityGate`'s own `EgtVerifier` has no protocol
/// seam to fake (Task 1's deliberate design), so every case here builds a
/// REAL `CapabilityGate` pinned to a real throwaway Ed25519 keypair and
/// signs REAL compact EGTs with it, then asserts observable side effects
/// (`gate.has(...)`, `TokenVault.loadEntitlement()`) rather than mocking
/// `.adopt()`/`.refresh()` calls directly. What IS faked is
/// `EntitlementsApiClient` (Task 4 added `redeemActivationCode` to the
/// same protocol `CapabilityGate.refresh()` already used
/// `fetchEntitlementsToken` through) — ONE fake instance is shared as both
/// `CapabilityGate`'s own `api` (so its `refresh()` calls are observable)
/// AND `UpgradeSheetContainer.redeem`'s `api` parameter (so its
/// `redeemActivationCode` calls are observable), which is what lets
/// "adopt() succeeded, refresh() was never called" be asserted as a real
/// call-count fact instead of an inferred one.
///
/// NOTE (not yet wired into a build target): same gap `CapabilityGateTests
/// .swift`/`TokenVaultTests.swift` already document — no `QAudionAppTests`
/// XCTest target in `QAudionApp/project.yml` today, and no Xcode/Swift
/// toolchain available in this session (Windows, no macOS) to compile or
/// run this file. Written FIRST against the not-yet-existing
/// `UpgradeSheetContainer` (TDD discipline: verified by reading it would
/// fail to compile — `UpgradeSheetContainer`/`redeem(api:capabilityGate:)`
/// undefined — then `UpgradeSheet.swift` was implemented, then verified by
/// re-reading both files together that every call/assertion below matches
/// the real, final signatures) — UNVERIFIED BY COMPILATION, matching Task
/// 1/2/3's own honesty standard.
///
/// Isolation: exercises the real `TokenVault` Keychain (`CapabilityGate`
/// reads `TokenVault.loadUserId()`/`.loadEntitlement()` directly, no
/// injection point), so `setUp`/`tearDown` snapshot and restore the
/// `userId`/`entitlement` accounts exactly like `CapabilityGateTests` does.
@MainActor
final class UpgradeSheetContainerTests: XCTestCase {

    private var savedUserId: String?
    private var savedEntitlement: String?
    private var privateKey: Curve25519.Signing.PrivateKey!
    private var verifier: EgtVerifier!

    override func setUp() {
        super.setUp()
        savedUserId = TokenVault.loadUserId()
        savedEntitlement = TokenVault.loadEntitlement()
        TokenVault.clearEntitlement()
        TokenVault.saveUserId("user-a")
        privateKey = Curve25519.Signing.PrivateKey()
        verifier = EgtVerifier(pinnedPublicKeyRaw: privateKey.publicKey.rawRepresentation)
    }

    override func tearDown() {
        TokenVault.clearEntitlement()
        if let savedEntitlement { TokenVault.saveEntitlement(savedEntitlement) }
        if let savedUserId {
            TokenVault.saveUserId(savedUserId)
        }
        privateKey = nil
        verifier = nil
        super.tearDown()
    }

    // MARK: - Local checksum pre-check

    func testRedeemWithAnInvalidChecksumNeverCallsTheApiOrTheGate() async {
        let fake = FakeEntitlementsApiClient()
        let gate = CapabilityGate(verifier: verifier, api: fake)
        let container = UpgradeSheetContainer()
        container.onCodeChanged("QA1-00000-00000-00000-XX") // checksum does not match its own payload

        await container.redeem(api: fake, capabilityGate: gate)

        XCTAssertEqual(fake.redeemActivationCodeCallCount, 0)
        XCTAssertEqual(fake.fetchEntitlementsTokenCallCount, 0)
        XCTAssertNotNil(container.error)
        XCTAssertFalse(container.submitting)
        XCTAssertFalse(container.success)
    }

    // MARK: - Success path: adopt(), never refresh() — THE regression-proof test

    func testRedeemOnSuccessAdoptsTheInlineTokenAndNeverCallsRefresh() async throws {
        let freshToken = try signedToken(sub: "user-a", fea: ["feat.files": 0])
        let fake = FakeEntitlementsApiClient()
        fake.redeemResult = .success(RedeemActivationCodeResponse(alreadyRedeemed: false, token: freshToken, kid: "ent-v1"))
        let gate = CapabilityGate(verifier: verifier, api: fake)
        let container = UpgradeSheetContainer()
        container.onCodeChanged(Self.validCode)

        await container.redeem(api: fake, capabilityGate: gate)

        XCTAssertEqual(fake.redeemActivationCodeCallCount, 1)
        // The load-bearing assertion: refresh() (fetchEntitlementsToken)
        // must NEVER be called on this path — only adopt() consumes the
        // inline token. This is exactly the call-count fact that would
        // flip to 1 if this file were "fixed" back to the buggy
        // `await capabilityGate.refresh()` shape.
        XCTAssertEqual(fake.fetchEntitlementsTokenCallCount, 0)
        XCTAssertTrue(gate.has(.files), "adopt() must have verified and cached the inline token")
        XCTAssertEqual(TokenVault.loadEntitlement(), freshToken)
        XCTAssertTrue(container.success)
        XCTAssertFalse(container.alreadyRedeemed)
        XCTAssertFalse(container.submitting)
        XCTAssertNil(container.error)
    }

    func testRedeemOnAnIdempotentReplayStillAdoptsAndNeverCallsRefresh() async throws {
        // entitlements_redemption.go deliberately does NOT fire the
        // entitlements_changed doorbell on the AlreadyRedeemed==true path,
        // so the inline token here is the ONLY delivery mechanism for this
        // case — not a hypothetical.
        let freshToken = try signedToken(sub: "user-a", fea: ["feat.files": 0])
        let fake = FakeEntitlementsApiClient()
        fake.redeemResult = .success(RedeemActivationCodeResponse(alreadyRedeemed: true, token: freshToken, kid: "ent-v1"))
        let gate = CapabilityGate(verifier: verifier, api: fake)
        let container = UpgradeSheetContainer()
        container.onCodeChanged(Self.validCode)

        await container.redeem(api: fake, capabilityGate: gate)

        XCTAssertEqual(fake.fetchEntitlementsTokenCallCount, 0)
        XCTAssertTrue(gate.has(.files))
        XCTAssertTrue(container.success)
        XCTAssertTrue(container.alreadyRedeemed)
    }

    // MARK: - adopt() rejects locally -> falls back to refresh()

    func testRedeemFallsBackToRefreshWhenTheInlineTokenIsRejectedLocally() async throws {
        // adopt() can legitimately reject the token it was just handed —
        // sign it with a DIFFERENT keypair than `verifier` is pinned to,
        // so EgtVerifier.verify genuinely fails, the same way a stale
        // pinned pubkey would in production.
        let otherKey = Curve25519.Signing.PrivateKey()
        let rejectedToken = try signedToken(sub: "user-a", fea: ["feat.files": 0], signingKey: otherKey)
        let refreshToken = try signedToken(sub: "user-a", fea: ["feat.files": 0, "feat.vpn": 0])
        let fake = FakeEntitlementsApiClient()
        fake.redeemResult = .success(RedeemActivationCodeResponse(alreadyRedeemed: false, token: rejectedToken, kid: "ent-v1"))
        fake.refreshResult = .success(EntitlementsTokenResponse(token: refreshToken, kid: "ent-v1"))
        let gate = CapabilityGate(verifier: verifier, api: fake)
        let container = UpgradeSheetContainer()
        container.onCodeChanged(Self.validCode)

        await container.redeem(api: fake, capabilityGate: gate)

        XCTAssertEqual(fake.redeemActivationCodeCallCount, 1)
        XCTAssertEqual(fake.fetchEntitlementsTokenCallCount, 1, "adopt() must have rejected the mis-signed token, triggering the refresh() fallback")
        XCTAssertTrue(gate.has(.files), "the fallback refresh() succeeded, so the capability must end up unlocked anyway")
        XCTAssertTrue(gate.has(.vpn))
        XCTAssertTrue(container.success, "redeem() itself succeeded server-side even though the inline token needed the fallback")
    }

    // MARK: - Server error routing (status-code only — see redemptionErrorMessage's own doc)

    func testRedeemOnA400ResponseRoutesToTheInvalidCodeMessageAndNeverAdoptsOrRefreshes() async {
        let fake = FakeEntitlementsApiClient()
        fake.redeemResult = .failure(BCryptoError.httpError(400))
        let gate = CapabilityGate(verifier: verifier, api: fake)
        let container = UpgradeSheetContainer()
        container.onCodeChanged(Self.validCode)

        await container.redeem(api: fake, capabilityGate: gate)

        XCTAssertEqual(container.error, "Codice non valido.")
        XCTAssertEqual(fake.fetchEntitlementsTokenCallCount, 0)
        XCTAssertFalse(gate.has(.files))
        XCTAssertFalse(container.success)
        XCTAssertFalse(container.submitting)
    }

    func testRedeemOnA409ConflictRoutesToTheConflictMessage() async {
        let fake = FakeEntitlementsApiClient()
        fake.redeemResult = .failure(BCryptoError.httpError(409))
        let gate = CapabilityGate(verifier: verifier, api: fake)
        let container = UpgradeSheetContainer()
        container.onCodeChanged(Self.validCode)

        await container.redeem(api: fake, capabilityGate: gate)

        XCTAssertEqual(container.error, "Codice già utilizzato o non disponibile.")
        XCTAssertFalse(container.success)
    }

    func testRedeemOnA429RateLimitRoutesToTheRateLimitMessage() async {
        let fake = FakeEntitlementsApiClient()
        fake.redeemResult = .failure(BCryptoError.httpError(429))
        let gate = CapabilityGate(verifier: verifier, api: fake)
        let container = UpgradeSheetContainer()
        container.onCodeChanged(Self.validCode)

        await container.redeem(api: fake, capabilityGate: gate)

        XCTAssertEqual(container.error, "Troppi tentativi — riprova più tardi.")
    }

    func testRedeemOnAServiceUnavailableRoutesToTheServerErrorMessage() async {
        let fake = FakeEntitlementsApiClient()
        fake.redeemResult = .failure(BCryptoError.httpError(503))
        let gate = CapabilityGate(verifier: verifier, api: fake)
        let container = UpgradeSheetContainer()
        container.onCodeChanged(Self.validCode)

        await container.redeem(api: fake, capabilityGate: gate)

        XCTAssertEqual(container.error, "Errore del server — riprova più tardi.")
    }

    /// W-B10PAYREQ (2026-09-02) — arrives as the bare `.paymentRequired`
    /// case (NOT `.httpError(402)`) since `BCryptoRestClient` now maps 402
    /// before it ever reaches this layer; see that case's own doc for why
    /// redeem itself realistically never triggers this (defensive
    /// completeness, not a live gap on this specific endpoint).
    func testRedeemOnA402PaymentRequiredRoutesToTheDedicatedProAccountMessage() async {
        let fake = FakeEntitlementsApiClient()
        fake.redeemResult = .failure(BCryptoError.paymentRequired)
        let gate = CapabilityGate(verifier: verifier, api: fake)
        let container = UpgradeSheetContainer()
        container.onCodeChanged(Self.validCode)

        await container.redeem(api: fake, capabilityGate: gate)

        XCTAssertEqual(container.error, BCryptoError.paymentRequired.userFacingMessage)
        XCTAssertFalse(container.success)
    }

    func testRedeemOnANetworkFailureRoutesToTheNetworkMessageAndNeverAdoptsOrRefreshes() async {
        // Not a BCryptoError at all -- BCryptoRestClient.performRequest lets
        // a raw URLSession failure (offline/DNS/timeout) propagate
        // unwrapped, unlike a non-2xx HTTP response.
        let fake = FakeEntitlementsApiClient()
        fake.redeemResult = .failure(URLError(.notConnectedToInternet))
        let gate = CapabilityGate(verifier: verifier, api: fake)
        let container = UpgradeSheetContainer()
        container.onCodeChanged(Self.validCode)

        await container.redeem(api: fake, capabilityGate: gate)

        XCTAssertEqual(container.error, "Errore di rete — verifica la connessione e riprova.")
        XCTAssertEqual(fake.fetchEntitlementsTokenCallCount, 0)
        XCTAssertFalse(gate.has(.files))
    }

    // MARK: - onCodeChanged clears a previous error

    func testOnCodeChangedClearsAPreviousError() async {
        let fake = FakeEntitlementsApiClient()
        let gate = CapabilityGate(verifier: verifier, api: fake)
        let container = UpgradeSheetContainer()
        container.onCodeChanged("not a valid code")
        await container.redeem(api: fake, capabilityGate: gate) // fails the local checksum gate, no network
        XCTAssertNotNil(container.error)

        container.onCodeChanged("something else")

        XCTAssertNil(container.error)
    }

    // MARK: - Helpers

    /// A real KAT vector (prefix "QA1" payload "7K3M9PXTVYR2HN5" checksum
    /// "ZZ" — same table as the Go server's `TestChecksumVectors_KAT` and
    /// `ActivationCodeTests`), so the "reaches the network" tests above are
    /// exercising `UpgradeSheetContainer.redeem`'s real local pre-check
    /// honestly rather than happening to pass because the code was invalid
    /// and never reached `api.redeemActivationCode` at all.
    private static let validCode = "QA1-7K3M9-PXTVY-R2HN5-ZZ"

    /// Signs a minimal EGT payload, matching `CapabilityGateTests
    /// .signedToken`'s own shape/wire-format exactly. `signingKey`
    /// defaults to this test's shared `privateKey` (which matches
    /// `verifier`'s pinned key) — pass a DIFFERENT key to build a token
    /// that will fail `EgtVerifier.verify` on purpose, as the
    /// adopt-rejects-falls-back-to-refresh test does.
    private func signedToken(sub: String, fea: [String: Int64], signingKey: Curve25519.Signing.PrivateKey? = nil) throws -> String {
        let key = signingKey ?? privateKey!
        let feaJson = fea.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        let payload = #"{"v":1,"sub":""# + sub + #"","did":"test-device","dkt":"","pkg":["base","pro"],"fea":{"# + feaJson + #"},"lim":{},"pol":{"min_assurance":"none","on_violation":"warn"},"ee":1,"iat":0,"exp":9999999999}"#
        let header = #"{"alg":"EdDSA","kid":"ent-v1","typ":"BEGT"}"#
        let signedPart = "\(base64urlEncode(Data(header.utf8))).\(base64urlEncode(Data(payload.utf8)))"
        let sig = try key.signature(for: Data(signedPart.utf8))
        return "\(signedPart).\(base64urlEncode(sig))"
    }
}

// MARK: - Test double

/// One fake conforms to the WHOLE `EntitlementsApiClient` protocol and is
/// shared as both `CapabilityGate`'s own `api` (its `refresh()` calls
/// route to `fetchEntitlementsToken` here) and
/// `UpgradeSheetContainer.redeem`'s `api` parameter (its calls route to
/// `redeemActivationCode` here) — sharing ONE instance across both
/// injection points is what makes "refresh() was never called" a real,
/// observable call-count fact rather than something inferred from state
/// alone.
private final class FakeEntitlementsApiClient: EntitlementsApiClient {
    var redeemResult: Result<RedeemActivationCodeResponse, Error> = .failure(FakeApiError())
    var refreshResult: Result<EntitlementsTokenResponse, Error> = .failure(FakeApiError())
    private(set) var redeemActivationCodeCallCount = 0
    private(set) var fetchEntitlementsTokenCallCount = 0

    func fetchEntitlementsToken() async throws -> EntitlementsTokenResponse {
        fetchEntitlementsTokenCallCount += 1
        return try refreshResult.get()
    }

    func redeemActivationCode(_ code: String) async throws -> RedeemActivationCodeResponse {
        redeemActivationCodeCallCount += 1
        return try redeemResult.get()
    }
}

private struct FakeApiError: Error {}

// Test-only base64url helper (standard base64url-no-padding encoding),
// same shape as CapabilityGateTests'/EgtVerifierTests' own private
// helpers -- kept file-local rather than shared across modules since
// EgtVerifier's own decode side is deliberately private to its own file.
private func base64urlEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
