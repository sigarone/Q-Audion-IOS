import XCTest
@testable import QAudionEngine

/// W-ACCEPTDEVSTALE (2026-09-08) — pins `AcceptDeviceIdResolution` against
/// the exact device-id-confusion incident found by adversarial review of the
/// W-SASPIN/W-CAPTURELIVE-SIGNAL diff: a peer-keyed stash can leak a STALE
/// device id from an unrelated earlier call into the current call's ACCEPT
/// verdict. These tests exercise the call-scoped replacement directly, with
/// no `AppState` involved (that class cannot be unit-tested in isolation).
final class AcceptDeviceIdResolutionTests: XCTestCase {

    /// The regression itself, modeled directly: peer X called us from device
    /// A on an EARLIER call (some other call id). We now call X and X
    /// answers THIS call from device B. A peer-keyed stash would still
    /// return A; the call-scoped stash must return nil (never A) because
    /// THIS call id was never stamped.
    func testDoesNotLeakDeviceIdFromAnUnrelatedEarlierCall() {
        // Only the EARLIER call's id is in the call-scoped stash — exactly
        // what `call_incoming` for that earlier, different call would have
        // written. The current call's id is absent.
        let callScopedStash = ["earlier-call-id": "device-A"]
        let resolved = AcceptDeviceIdResolution.callerAcceptDeviceId(
            callId: "current-call-id", callScopedStash: callScopedStash)
        XCTAssertNil(resolved, "an unrelated call's stashed device id must never answer for this call")
    }

    /// The intended "always nil for an outgoing call's ACCEPT" behaviour:
    /// a caller's own call never receives an inbound `call_incoming`, so the
    /// call-scoped stash is empty for it — this must resolve to nil, not
    /// crash or fall back to some other source.
    func testEmptyStashResolvesToNil() {
        XCTAssertNil(AcceptDeviceIdResolution.callerAcceptDeviceId(
            callId: "any-call-id", callScopedStash: [:]))
    }

    /// If this exact call id genuinely was stamped (e.g. a future protocol
    /// change that does deliver call_incoming for both legs), the lookup
    /// must still succeed — this is a scoping fix, not a "never return a
    /// value" regression.
    func testReturnsDeviceIdWhenThisExactCallIdWasStamped() {
        let callScopedStash = ["abc12345-call": "device-B"]
        let resolved = AcceptDeviceIdResolution.callerAcceptDeviceId(
            callId: "abc12345-call", callScopedStash: callScopedStash)
        XCTAssertEqual(resolved, "device-B")
    }

    /// W461 — iOS emits uppercase UUIDs, Android echoes lowercase. The
    /// lookup must be case-insensitive on the call id in both directions.
    func testLookupIsCaseInsensitiveOnCallId() {
        let callScopedStash = ["8b392e49-aaaa-bbbb-cccc-111122223333": "device-B"]
        let resolved = AcceptDeviceIdResolution.callerAcceptDeviceId(
            callId: "8B392E49-AAAA-BBBB-CCCC-111122223333", callScopedStash: callScopedStash)
        XCTAssertEqual(resolved, "device-B")
    }
}
