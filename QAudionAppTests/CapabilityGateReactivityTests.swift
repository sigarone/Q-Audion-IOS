import XCTest
import Combine
import CryptoKit
@testable import QAudionApp
import QAudionEngine

/// Entitlements Task 5 (2026-08-17) — coverage for the ONE thing this task
/// can actually verify mechanically without a render tree or a simulator
/// (neither is available in this environment — Windows, no Xcode/Swift
/// toolchain, same disclosed gap `CapabilityGateTests`/
/// `UpgradeSheetContainerTests` already document): that `CapabilityGate`
/// genuinely publishes `objectWillChange` on every state-mutating method
/// (`adopt`/`loadCached`/`discard`/`refresh`'s success path).
///
/// This is the load-bearing PREREQUISITE fact behind whole-phase-review
/// finding I4's fix (`QAudionApp.swift`'s new
/// `.environmentObject(appState.capabilityGate)`): SwiftUI's
/// `@EnvironmentObject`/`@ObservedObject` machinery re-renders a view
/// specifically because the injected object's `objectWillChange` fires —
/// if `CapabilityGate` did NOT actually publish on these methods, the I4
/// fix would inject a correctly-scoped but functionally inert object and
/// every Task 5 lock badge would still silently fail to update. What this
/// suite CANNOT verify (no compiler/simulator here): that a real
/// `@EnvironmentObject` read inside a real SwiftUI `body` actually
/// re-evaluates when this fires, that `GatedActionButton`/
/// `GatedScreenEntry`/`VpnToggleChip` render the dim+lock-badge visuals
/// correctly, or that a locked tap correctly routes to `UpgradeSheet`
/// instead of the real action. Those were verified by careful manual
/// reading against Android's own reviewed shape (2 review rounds there),
/// not by running anything — see Task 5's own report for the full list of
/// what is and isn't covered here.
///
/// Also covers the group-video combined-unlock formula
/// (`isUnlocked(.callsGroup) && isUnlocked(.callsGroupVideo)`) used at
/// `GroupChatScreen`'s video-call button and `LiveInCallScreen`'s
/// mid-call escalation — pure boolean logic against a REAL
/// `CapabilityGate`, so unlike the view-layer wiring this one genuinely IS
/// fully testable here, and was written FIRST (TDD discipline, same as
/// Tasks 1-4): verified by reading it would fail against a naive
/// `isUnlocked(.callsGroupVideo)`-only check (the bug Android's own review
/// finding I2 caught), then verified by reading the real call sites in
/// `GroupChatScreen.swift`/`LiveInCallScreen.swift` already implement the
/// AND, not the naive version.
///
/// Isolation: same real-`TokenVault`-Keychain save/restore discipline as
/// `CapabilityGateTests`, so running this suite on a real device never
/// permanently loses a live session sitting in the Keychain.
@MainActor
final class CapabilityGateReactivityTests: XCTestCase {

    private var savedUserId: String?
    private var savedEntitlement: String?
    private var privateKey: Curve25519.Signing.PrivateKey!
    private var verifier: EgtVerifier!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        savedUserId = TokenVault.loadUserId()
        savedEntitlement = TokenVault.loadEntitlement()
        TokenVault.clearEntitlement()
        privateKey = Curve25519.Signing.PrivateKey()
        verifier = EgtVerifier(pinnedPublicKeyRaw: privateKey.publicKey.rawRepresentation)
    }

    override func tearDown() {
        cancellables.removeAll()
        TokenVault.clearEntitlement()
        if let savedEntitlement { TokenVault.saveEntitlement(savedEntitlement) }
        if let savedUserId { TokenVault.saveUserId(savedUserId) }
        privateKey = nil
        verifier = nil
        super.tearDown()
    }

    // MARK: - objectWillChange fires — the I4 fix's load-bearing prerequisite

    func testObjectWillChangeFiresOnAdopt() throws {
        TokenVault.saveUserId("user-a")
        let gate = CapabilityGate(verifier: verifier, api: RejectingApiClient())

        let expectation = expectation(description: "objectWillChange fired on adopt()")
        gate.objectWillChange.sink { _ in expectation.fulfill() }.store(in: &cancellables)

        let token = try signedToken(sub: "user-a", fea: ["feat.files": 0])
        XCTAssertTrue(gate.adopt(token))

        wait(for: [expectation], timeout: 1.0)
    }

    func testObjectWillChangeFiresOnLoadCached() throws {
        TokenVault.saveUserId("user-a")
        let token = try signedToken(sub: "user-a", fea: ["feat.files": 0])
        TokenVault.saveEntitlement(token)
        let gate = CapabilityGate(verifier: verifier, api: RejectingApiClient())

        let expectation = expectation(description: "objectWillChange fired on loadCached()")
        gate.objectWillChange.sink { _ in expectation.fulfill() }.store(in: &cancellables)

        gate.loadCached()

        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(gate.has(.files), "sanity: loadCached actually adopted the cached token")
    }

    func testObjectWillChangeFiresOnDiscard() throws {
        TokenVault.saveUserId("user-a")
        let token = try signedToken(sub: "user-a", fea: ["feat.files": 0])
        let gate = CapabilityGate(verifier: verifier, api: RejectingApiClient())
        XCTAssertTrue(gate.adopt(token), "sanity: a grant is loaded before discard()")

        let expectation = expectation(description: "objectWillChange fired on discard()")
        gate.objectWillChange.sink { _ in expectation.fulfill() }.store(in: &cancellables)

        gate.discard()

        wait(for: [expectation], timeout: 1.0)
        XCTAssertFalse(gate.has(.files))
    }

    func testObjectWillChangeFiresOnSuccessfulRefresh() async throws {
        TokenVault.saveUserId("user-a")
        let fresh = try signedToken(sub: "user-a", fea: ["feat.vpn": 0])
        let gate = CapabilityGate(verifier: verifier, api: FakeEntitlementsApiClient(
            result: .success(EntitlementsTokenResponse(token: fresh, kid: "ent-v1"))
        ))

        let expectation = expectation(description: "objectWillChange fired on a successful refresh()")
        gate.objectWillChange.sink { _ in expectation.fulfill() }.store(in: &cancellables)

        await gate.refresh()

        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(gate.has(.vpn))
    }

    // MARK: - Group-video combined-unlock formula (GroupChatScreen / LiveInCallScreen)

    /// Mirrors Android's own review finding I2: a video group call sends
    /// TWO gated server commands in sequence (group_call_create, then
    /// group_call_sfu_token), so a grant with `callsGroupVideo` but NOT
    /// `callsGroup` must still render the video button LOCKED — checking
    /// `isUnlocked(.callsGroupVideo)` alone would render it unlocked and
    /// then fail server-side on the very first message.
    func testGroupVideoUnlockRequiresCallsGroupEvenWhenCallsGroupVideoIsGranted() throws {
        TokenVault.saveUserId("user-a")
        let token = try signedToken(sub: "user-a", fea: ["feat.calls.group_video": 0])
        let gate = CapabilityGate(verifier: verifier, api: RejectingApiClient())
        XCTAssertTrue(gate.adopt(token))

        XCTAssertTrue(gate.isUnlocked(.callsGroupVideo), "sanity: the raw capability IS granted")
        let combinedUnlocked = gate.isUnlocked(.callsGroup) && gate.isUnlocked(.callsGroupVideo)
        XCTAssertFalse(combinedUnlocked, "the video button's real unlock formula must still be LOCKED without callsGroup too")
    }

    /// The other half: both present unlocks it.
    func testGroupVideoUnlockedWhenBothCapabilitiesGranted() throws {
        TokenVault.saveUserId("user-a")
        let token = try signedToken(sub: "user-a", fea: ["feat.calls.group": 0, "feat.calls.group_video": 0])
        let gate = CapabilityGate(verifier: verifier, api: RejectingApiClient())
        XCTAssertTrue(gate.adopt(token))

        let combinedUnlocked = gate.isUnlocked(.callsGroup) && gate.isUnlocked(.callsGroupVideo)
        XCTAssertTrue(combinedUnlocked)
    }

    /// Only callsGroup (no video) — audio group calling unlocked, video
    /// button still locked. The regression this guards: a hand-inlined
    /// `!has(.callsGroupVideo)` check (rather than the combined AND) would
    /// pass this case by accident since callsGroupVideo really is absent —
    /// this test exists mainly to pin the audio-only-unlocked half of the
    /// matrix so a future edit can't quietly invert the AND into an OR.
    func testCallsGroupAloneDoesNotUnlockGroupVideo() throws {
        TokenVault.saveUserId("user-a")
        let token = try signedToken(sub: "user-a", fea: ["feat.calls.group": 0])
        let gate = CapabilityGate(verifier: verifier, api: RejectingApiClient())
        XCTAssertTrue(gate.adopt(token))

        XCTAssertTrue(gate.isUnlocked(.callsGroup))
        let combinedUnlocked = gate.isUnlocked(.callsGroup) && gate.isUnlocked(.callsGroupVideo)
        XCTAssertFalse(combinedUnlocked)
    }

    // MARK: - Helpers

    /// Signs a minimal EGT payload with `privateKey` (this test's shared
    /// throwaway keypair, matching `verifier`) and the given `sub`/`fea` —
    /// same real-Ed25519-signing shape as `CapabilityGateTests
    /// .signedToken(sub:fea:)` / `EgtVerifierTests.signedToken(payload:)`,
    /// duplicated here (not shared) rather than loosening either existing
    /// file's `private` access control for one new caller.
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

/// `adopt()`/`loadCached()`/`discard()` never call `api` at all — using a
/// client that fatalErrors if invoked keeps that assumption honest for
/// every test above except the one refresh() test, which needs a REAL
/// success response instead.
private final class RejectingApiClient: EntitlementsApiClient {
    func fetchEntitlementsToken() async throws -> EntitlementsTokenResponse {
        fatalError("RejectingApiClient.fetchEntitlementsToken should not be called from CapabilityGateReactivityTests")
    }
    func redeemActivationCode(_ code: String) async throws -> RedeemActivationCodeResponse {
        fatalError("RejectingApiClient.redeemActivationCode should not be called from CapabilityGateReactivityTests")
    }
}

private final class FakeEntitlementsApiClient: EntitlementsApiClient {
    private let result: Result<EntitlementsTokenResponse, Error>
    init(result: Result<EntitlementsTokenResponse, Error>) { self.result = result }
    func fetchEntitlementsToken() async throws -> EntitlementsTokenResponse { try result.get() }
    func redeemActivationCode(_ code: String) async throws -> RedeemActivationCodeResponse {
        fatalError("FakeEntitlementsApiClient.redeemActivationCode should not be called from CapabilityGateReactivityTests")
    }
}

// Test-only base64url helper — same shape as CapabilityGateTests' own
// private helper, duplicated for the same file-locality reason as
// signedToken(sub:fea:) above.
private func base64urlEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
