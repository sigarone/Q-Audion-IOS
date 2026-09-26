import XCTest
@testable import QAudionEngine

/// W-NATIVESRTPSNAPSHOT (2026-09-26) — one native-SRTP decision per call:
/// the advertisement, the local side of the intersection and
/// `isNativeSrtpEnabledLocally` all read the snapshot while a call is in
/// progress, so a mid-call flip of the debug override cannot desync them.
final class CallCapabilitiesNativeSrtpSnapshotTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CallCapabilities.endNativeSrtpCallSnapshot()
        CallCapabilities.audioSrtpDebugOverride = nil
    }

    /// Shared static state: leave both at their defaults for every other test.
    override func tearDown() {
        CallCapabilities.endNativeSrtpCallSnapshot()
        CallCapabilities.audioSrtpDebugOverride = nil
        super.tearDown()
    }

    func test_noSnapshot_isNativeSrtpEnabledLocally_isTheLiveValue() {
        XCTAssertNil(CallCapabilities.nativeSrtpCallSnapshot)
        CallCapabilities.audioSrtpDebugOverride = true
        XCTAssertTrue(CallCapabilities.isNativeSrtpEnabledLocally)
        CallCapabilities.audioSrtpDebugOverride = false
        XCTAssertFalse(CallCapabilities.isNativeSrtpEnabledLocally)
    }

    /// THE property: the override flipping mid-call changes nothing for the
    /// call in progress — neither the local predicate nor what is advertised.
    func test_snapshotOn_survivesOverrideFlipMidCall() {
        CallCapabilities.audioSrtpDebugOverride = true
        XCTAssertTrue(CallCapabilities.beginNativeSrtpCallSnapshot())
        CallCapabilities.audioSrtpDebugOverride = false
        XCTAssertTrue(CallCapabilities.isNativeSrtpEnabledLocally)
        XCTAssertTrue(CallCapabilities.localCaps().contains(CallCapabilities.audioSrtpV1))
        XCTAssertTrue(CallCapabilities.negotiationLocal().contains(CallCapabilities.audioSrtpV1))
    }

    func test_snapshotOff_survivesOverrideFlipMidCall() {
        CallCapabilities.audioSrtpDebugOverride = false
        XCTAssertFalse(CallCapabilities.beginNativeSrtpCallSnapshot())
        CallCapabilities.audioSrtpDebugOverride = true
        XCTAssertFalse(CallCapabilities.isNativeSrtpEnabledLocally)
        XCTAssertFalse(CallCapabilities.localCaps().contains(CallCapabilities.audioSrtpV1))
        XCTAssertFalse(CallCapabilities.negotiationLocal().contains(CallCapabilities.audioSrtpV1))
    }

    /// The earbud gate still wins over the snapshot, exactly like the override.
    func test_snapshotOn_doesNotResurrectAudioSrtpV1_onAnEarbudCall() {
        CallCapabilities.audioSrtpDebugOverride = true
        CallCapabilities.beginNativeSrtpCallSnapshot()
        let caps = CallCapabilities.localCaps(earbudActive: true, earbudPaired: true)
        XCTAssertFalse(caps.contains(CallCapabilities.audioSrtpV1))
    }

    /// begin always re-snapshots (a stale snapshot must not leak into a new
    /// outgoing call); latch keeps an existing one (duplicate OFFER, replaced
    /// PeerConnection of the same call).
    func test_beginOverwrites_latchKeeps() {
        CallCapabilities.audioSrtpDebugOverride = true
        CallCapabilities.beginNativeSrtpCallSnapshot()
        CallCapabilities.audioSrtpDebugOverride = false
        let latched = CallCapabilities.latchNativeSrtpCallSnapshot()
        XCTAssertTrue(latched.value)
        XCTAssertFalse(latched.fresh)
        XCTAssertFalse(CallCapabilities.beginNativeSrtpCallSnapshot())
        XCTAssertEqual(CallCapabilities.nativeSrtpCallSnapshot, false)
    }

    func test_latchWithoutSnapshot_takesTheLiveValue() {
        CallCapabilities.audioSrtpDebugOverride = true
        let latched = CallCapabilities.latchNativeSrtpCallSnapshot()
        XCTAssertTrue(latched.value)
        XCTAssertTrue(latched.fresh)
        XCTAssertEqual(CallCapabilities.nativeSrtpCallSnapshot, true)
    }

    func test_end_returnsToTheLiveValue() {
        CallCapabilities.audioSrtpDebugOverride = true
        CallCapabilities.beginNativeSrtpCallSnapshot()
        CallCapabilities.endNativeSrtpCallSnapshot()
        XCTAssertNil(CallCapabilities.nativeSrtpCallSnapshot)
        CallCapabilities.audioSrtpDebugOverride = false
        XCTAssertFalse(CallCapabilities.isNativeSrtpEnabledLocally)
    }

    /// With native SRTP off, the local side of the intersection is the
    /// compiled base list byte-for-byte — legacy calls negotiate exactly as
    /// before.
    func test_negotiationLocal_nativeOff_isTheBaseList() {
        CallCapabilities.audioSrtpDebugOverride = false
        XCTAssertEqual(
            Set(CallCapabilities.negotiationLocal()),
            Set(CallCapabilities.local.filter { $0 != CallCapabilities.audioSrtpV1 }))
        if !CallCapabilities.audioSrtpSendEnabled {
            XCTAssertEqual(CallCapabilities.negotiationLocal(), CallCapabilities.local)
        }
    }

    /// The asymmetry this closes: override on, compiled switch off — the tag
    /// was advertised but this side never agreed on it.
    func test_negotiationLocal_nativeOn_agreesWithAPeerThatAdvertisesTheTag() {
        CallCapabilities.audioSrtpDebugOverride = true
        CallCapabilities.beginNativeSrtpCallSnapshot()
        let n = CallCapabilities.negotiate(local: CallCapabilities.negotiationLocal(),
                                           peer: [CallCapabilities.audioSrtpV1, CallCapabilities.sframeV1])
        XCTAssertTrue(n.useAudioSrtp)
    }
}
