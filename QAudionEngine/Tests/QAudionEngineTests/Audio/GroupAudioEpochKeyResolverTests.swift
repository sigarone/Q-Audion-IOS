import XCTest
@testable import QAudionEngine

/// W-GRPAUDIOKEY §7 (2026-08-27) — pins
/// `GroupAudioEpochKeyResolver.resolve` against
/// `GroupCallController.resolveFallbackRxAudioKey`'s real accept/reject
/// contract for the SFU-outage fallback-audio path: accept a frame claiming
/// the CURRENT epoch (if a key is cached for it), accept a frame claiming
/// the IMMEDIATELY-PREVIOUS epoch while still within its grace window,
/// reject everything else outright — closing the replay/downgrade risk an
/// external security review flagged for this feature. Same "no live
/// GroupCallController/GroupSession needed" pinning discipline as
/// `SfuDisconnectFallbackDecisionTests` for the SFU mid-call fallback.
final class GroupAudioEpochKeyResolverTests: XCTestCase {

    private let currentKey = Data(repeating: 0x11, count: 32)
    private let graceKey = Data(repeating: 0x22, count: 32)
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func test_wireMatchesCurrentEpoch_withCachedKey_accepts() {
        let resolved = GroupAudioEpochKeyResolver.resolve(
            wireEpochId: 5,
            currentEpochId: 5,
            current: .init(epochId: 5, audioKey: currentKey),
            grace: nil,
            graceExpiresAt: nil,
            now: now
        )
        XCTAssertEqual(resolved, currentKey)
    }

    func test_wireMatchesCurrentEpoch_butNoCachedKeyYet_rejects() {
        // Current epoch, but the caller never derived/cached a key for this
        // sender this epoch (e.g. their sender_key_init hasn't arrived) —
        // must reject, not silently fall through to some other key.
        let resolved = GroupAudioEpochKeyResolver.resolve(
            wireEpochId: 5,
            currentEpochId: 5,
            current: nil,
            grace: nil,
            graceExpiresAt: nil,
            now: now
        )
        XCTAssertNil(resolved)
    }

    func test_wireClaimsPreviousEpoch_withinGraceWindow_accepts() {
        let resolved = GroupAudioEpochKeyResolver.resolve(
            wireEpochId: 4,
            currentEpochId: 5,
            current: .init(epochId: 5, audioKey: currentKey),
            grace: .init(epochId: 4, audioKey: graceKey),
            graceExpiresAt: now.addingTimeInterval(2.0),
            now: now
        )
        XCTAssertEqual(resolved, graceKey, "must open under the GRACE key for the previous epoch, not the current one")
    }

    func test_wireClaimsPreviousEpoch_graceWindowExpired_rejects() {
        let resolved = GroupAudioEpochKeyResolver.resolve(
            wireEpochId: 4,
            currentEpochId: 5,
            current: .init(epochId: 5, audioKey: currentKey),
            grace: .init(epochId: 4, audioKey: graceKey),
            graceExpiresAt: now.addingTimeInterval(-0.001), // expired a moment ago
            now: now
        )
        XCTAssertNil(resolved)
    }

    func test_wireClaimsPreviousEpoch_rightAtExpiryBoundary_rejects() {
        // `now < expiresAt` is a strict inequality — exactly-at-expiry must
        // NOT be treated as still-valid (avoids an off-by-one grace window).
        let resolved = GroupAudioEpochKeyResolver.resolve(
            wireEpochId: 4,
            currentEpochId: 5,
            current: nil,
            grace: .init(epochId: 4, audioKey: graceKey),
            graceExpiresAt: now,
            now: now
        )
        XCTAssertNil(resolved)
    }

    func test_wireClaimsEpochOlderThanGrace_rejectsOutright() {
        // The security-review-flagged replay/downgrade case: an epoch TWO
        // (or more) bumps behind current, when only the immediately-previous
        // one is ever graced.
        let resolved = GroupAudioEpochKeyResolver.resolve(
            wireEpochId: 3,
            currentEpochId: 5,
            current: .init(epochId: 5, audioKey: currentKey),
            grace: .init(epochId: 4, audioKey: graceKey),
            graceExpiresAt: now.addingTimeInterval(2.0),
            now: now
        )
        XCTAssertNil(resolved)
    }

    func test_wireClaimsFutureEpoch_rejectsOutright() {
        // A wire claiming an epoch NEWER than ours should never happen for a
        // legitimate sender (epoch only advances via convergent departure
        // handling) — must not be accepted just because it doesn't match
        // any known-stale case.
        let resolved = GroupAudioEpochKeyResolver.resolve(
            wireEpochId: 6,
            currentEpochId: 5,
            current: .init(epochId: 5, audioKey: currentKey),
            grace: .init(epochId: 4, audioKey: graceKey),
            graceExpiresAt: now.addingTimeInterval(2.0),
            now: now
        )
        XCTAssertNil(resolved)
    }

    func test_noGraceEntryAtAll_previousEpochRejected() {
        // No local epoch bump has ever happened (or the grace slot was
        // never populated for this sender) — a previous-epoch claim has
        // nothing to be graced against.
        let resolved = GroupAudioEpochKeyResolver.resolve(
            wireEpochId: 4,
            currentEpochId: 5,
            current: .init(epochId: 5, audioKey: currentKey),
            grace: nil,
            graceExpiresAt: nil,
            now: now
        )
        XCTAssertNil(resolved)
    }

    func test_graceEntryForWrongEpoch_ignored() {
        // Defensive: a grace entry pinned to a DIFFERENT epoch than what the
        // wire claims (should not happen given how the controller populates
        // it, but the pure resolver must not accept it either way).
        let resolved = GroupAudioEpochKeyResolver.resolve(
            wireEpochId: 2,
            currentEpochId: 5,
            current: nil,
            grace: .init(epochId: 4, audioKey: graceKey),
            graceExpiresAt: now.addingTimeInterval(2.0),
            now: now
        )
        XCTAssertNil(resolved)
    }
}
