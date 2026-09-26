import XCTest
@testable import QAudionEngine

/// W-NATIVESRTPSNAPSHOT (2026-09-26) — one native-SRTP decision per call:
/// the advertisement, the local side of the intersection and
/// `isNativeSrtpEnabledLocally` all read the snapshot while a call is in
/// progress, so a mid-call flip of the debug override cannot desync them.
///
/// W-NATIVESRTPSNAPSHOT-ID — the snapshot is keyed by call id, so one left by
/// a call that never reached `CallService.endCall()` cannot decide the next.
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
        XCTAssertTrue(CallCapabilities.beginNativeSrtpCallSnapshot(callId: "call-a").value)
        CallCapabilities.audioSrtpDebugOverride = false
        XCTAssertTrue(CallCapabilities.isNativeSrtpEnabledLocally)
        XCTAssertTrue(CallCapabilities.localCaps().contains(CallCapabilities.audioSrtpV1))
        XCTAssertTrue(CallCapabilities.negotiationLocal().contains(CallCapabilities.audioSrtpV1))
    }

    func test_snapshotOff_survivesOverrideFlipMidCall() {
        CallCapabilities.audioSrtpDebugOverride = false
        XCTAssertFalse(CallCapabilities.beginNativeSrtpCallSnapshot(callId: "call-a").value)
        CallCapabilities.audioSrtpDebugOverride = true
        XCTAssertFalse(CallCapabilities.isNativeSrtpEnabledLocally)
        XCTAssertFalse(CallCapabilities.localCaps().contains(CallCapabilities.audioSrtpV1))
        XCTAssertFalse(CallCapabilities.negotiationLocal().contains(CallCapabilities.audioSrtpV1))
    }

    /// The earbud gate still wins over the snapshot, exactly like the override.
    func test_snapshotOn_doesNotResurrectAudioSrtpV1_onAnEarbudCall() {
        CallCapabilities.audioSrtpDebugOverride = true
        CallCapabilities.beginNativeSrtpCallSnapshot(callId: "call-a")
        let caps = CallCapabilities.localCaps(earbudActive: true, earbudPaired: true)
        XCTAssertFalse(caps.contains(CallCapabilities.audioSrtpV1))
    }

    // MARK: - W-NATIVESRTPSNAPSHOT-ID

    /// The same call (duplicate rescue OFFER, call_incoming → OFFER handoff)
    /// keeps its snapshot, case-insensitively.
    func test_sameCallId_keepsTheSnapshot_caseInsensitive() {
        CallCapabilities.audioSrtpDebugOverride = true
        let first = CallCapabilities.latchNativeSrtpCallSnapshot(callId: "AbC-1")
        XCTAssertTrue(first.fresh)
        XCTAssertFalse(first.stale)
        CallCapabilities.audioSrtpDebugOverride = false
        let again = CallCapabilities.latchNativeSrtpCallSnapshot(callId: "abc-1")
        XCTAssertTrue(again.value)
        XCTAssertFalse(again.fresh)
        XCTAssertFalse(again.stale)
        XCTAssertEqual(CallCapabilities.nativeSrtpSnapshotCallId, "abc-1")
    }

    /// THE bug this closes: an outgoing attempt aborted before
    /// `CallService.endCall()` leaves its snapshot; the toggle is switched
    /// off; the NEXT incoming call must NOT run native.
    func test_differentCallId_replacesAStaleSnapshot() {
        CallCapabilities.audioSrtpDebugOverride = true
        CallCapabilities.beginNativeSrtpCallSnapshot(callId: "aborted-outgoing")
        CallCapabilities.audioSrtpDebugOverride = false
        let incoming = CallCapabilities.latchNativeSrtpCallSnapshot(callId: "next-incoming")
        XCTAssertFalse(incoming.value)
        XCTAssertTrue(incoming.fresh)
        XCTAssertTrue(incoming.stale)
        XCTAssertFalse(CallCapabilities.isNativeSrtpEnabledLocally)
        XCTAssertEqual(CallCapabilities.nativeSrtpSnapshotCallId, "next-incoming")
    }

    /// begin follows the same keyed rule (a fresh outgoing id always replaces).
    func test_begin_withANewId_replacesAndReportsStale() {
        CallCapabilities.audioSrtpDebugOverride = false
        CallCapabilities.beginNativeSrtpCallSnapshot(callId: "old")
        CallCapabilities.audioSrtpDebugOverride = true
        let begun = CallCapabilities.beginNativeSrtpCallSnapshot(callId: "new")
        XCTAssertTrue(begun.value)
        XCTAssertTrue(begun.stale)
    }

    /// A snapshot taken without an id (a site that could not know it) is not
    /// proof it belongs to the call that now has one: replaced, stale.
    func test_unidentifiedSnapshot_isReplacedByAKeyedLatch() {
        CallCapabilities.audioSrtpDebugOverride = true
        CallCapabilities.latchNativeSrtpCallSnapshot(callId: nil)
        CallCapabilities.audioSrtpDebugOverride = false
        let keyed = CallCapabilities.latchNativeSrtpCallSnapshot(callId: "call-b")
        XCTAssertFalse(keyed.value)
        XCTAssertTrue(keyed.stale)
    }

    /// The PeerConnection site has no call id: it keeps whatever the current
    /// call took (every call-start path latches the keyed snapshot first) and
    /// only takes an unidentified one when there is none.
    func test_latchWithoutId_keepsTheCurrentCallsSnapshot() {
        CallCapabilities.audioSrtpDebugOverride = true
        CallCapabilities.latchNativeSrtpCallSnapshot(callId: "call-c")
        CallCapabilities.audioSrtpDebugOverride = false
        let pc = CallCapabilities.latchNativeSrtpCallSnapshot(callId: nil)
        XCTAssertTrue(pc.value)
        XCTAssertFalse(pc.fresh)
        XCTAssertFalse(pc.stale)
        XCTAssertEqual(CallCapabilities.nativeSrtpSnapshotCallId, "call-c")
    }

    func test_latchWithoutIdAndNoSnapshot_takesAnUnidentifiedOne() {
        CallCapabilities.audioSrtpDebugOverride = true
        let pc = CallCapabilities.latchNativeSrtpCallSnapshot(callId: nil)
        XCTAssertTrue(pc.value)
        XCTAssertTrue(pc.fresh)
        XCTAssertFalse(pc.stale)
        XCTAssertNil(CallCapabilities.nativeSrtpSnapshotCallId)
    }

    /// An empty id is treated as unknown, never as a key.
    func test_emptyCallId_isTreatedAsUnknown() {
        CallCapabilities.audioSrtpDebugOverride = true
        CallCapabilities.latchNativeSrtpCallSnapshot(callId: "call-d")
        let empty = CallCapabilities.latchNativeSrtpCallSnapshot(callId: "")
        XCTAssertFalse(empty.fresh)
        XCTAssertFalse(empty.stale)
        XCTAssertEqual(CallCapabilities.nativeSrtpSnapshotCallId, "call-d")
    }

    /// Keyed end clears only its own call's snapshot.
    func test_keyedEnd_clearsOnlyOnMatch() {
        CallCapabilities.audioSrtpDebugOverride = true
        CallCapabilities.beginNativeSrtpCallSnapshot(callId: "Call-E")
        XCTAssertFalse(CallCapabilities.endNativeSrtpCallSnapshot(callId: "other"))
        XCTAssertFalse(CallCapabilities.endNativeSrtpCallSnapshot(callId: nil))
        XCTAssertNotNil(CallCapabilities.nativeSrtpCallSnapshot)
        XCTAssertTrue(CallCapabilities.endNativeSrtpCallSnapshot(callId: "call-e"))
        XCTAssertNil(CallCapabilities.nativeSrtpCallSnapshot)
        XCTAssertNil(CallCapabilities.nativeSrtpSnapshotCallId)
    }

    // MARK: - W-NATIVESRTPSNAPSHOT-ENDOWNER (CallService.endCall)

    func test_callEnd_ownCallId_endsAndMatches_caseInsensitive() {
        CallCapabilities.audioSrtpDebugOverride = true
        CallCapabilities.beginNativeSrtpCallSnapshot(callId: "Call-H")
        let end = CallCapabilities.endNativeSrtpCallSnapshotAtCallEnd(callId: "call-h")
        XCTAssertEqual(end, CallCapabilities.NativeSrtpSnapshotEnd(value: true, matched: true, ended: true))
        XCTAssertNil(CallCapabilities.nativeSrtpCallSnapshot)
        XCTAssertNil(CallCapabilities.nativeSrtpSnapshotCallId)
    }

    /// THE bug this closes: a stale teardown carrying the OLD call's id must
    /// not delete the snapshot the NEWER call already took.
    func test_callEnd_staleTeardownWithAnotherKnownId_keepsTheNewerCallsSnapshot() {
        CallCapabilities.audioSrtpDebugOverride = true
        CallCapabilities.latchNativeSrtpCallSnapshot(callId: "newer-call")
        CallCapabilities.audioSrtpDebugOverride = false
        let end = CallCapabilities.endNativeSrtpCallSnapshotAtCallEnd(callId: "older-call")
        XCTAssertEqual(end, CallCapabilities.NativeSrtpSnapshotEnd(value: true, matched: false, ended: false))
        XCTAssertEqual(CallCapabilities.nativeSrtpCallSnapshot, true)
        XCTAssertEqual(CallCapabilities.nativeSrtpSnapshotCallId, "newer-call")
        XCTAssertTrue(CallCapabilities.isNativeSrtpEnabledLocally)
    }

    /// Safety net kept: an unidentified snapshot (nobody else provably owns
    /// it) is dropped even when the ending id does not match.
    func test_callEnd_unidentifiedSnapshot_isDroppedBySafetyNet() {
        CallCapabilities.audioSrtpDebugOverride = true
        CallCapabilities.latchNativeSrtpCallSnapshot(callId: nil)
        let end = CallCapabilities.endNativeSrtpCallSnapshotAtCallEnd(callId: "call-i")
        XCTAssertEqual(end, CallCapabilities.NativeSrtpSnapshotEnd(value: true, matched: false, ended: true))
        XCTAssertNil(CallCapabilities.nativeSrtpCallSnapshot)
    }

    /// Safety net kept: no ending id (unknown, or empty) drops whatever is there.
    func test_callEnd_unknownEndingId_isDroppedBySafetyNet() {
        CallCapabilities.audioSrtpDebugOverride = false
        CallCapabilities.beginNativeSrtpCallSnapshot(callId: "call-j")
        let end = CallCapabilities.endNativeSrtpCallSnapshotAtCallEnd(callId: nil)
        XCTAssertEqual(end, CallCapabilities.NativeSrtpSnapshotEnd(value: false, matched: false, ended: true))
        XCTAssertNil(CallCapabilities.nativeSrtpCallSnapshot)
        CallCapabilities.beginNativeSrtpCallSnapshot(callId: "call-k")
        XCTAssertTrue(CallCapabilities.endNativeSrtpCallSnapshotAtCallEnd(callId: "").ended)
        XCTAssertNil(CallCapabilities.nativeSrtpCallSnapshot)
    }

    func test_callEnd_noSnapshot_reportsNothing() {
        let end = CallCapabilities.endNativeSrtpCallSnapshotAtCallEnd(callId: "call-l")
        XCTAssertEqual(end, CallCapabilities.NativeSrtpSnapshotEnd(value: nil, matched: false, ended: false))
    }

    /// The unconditional end clears whatever is there.
    func test_unconditionalEnd_returnsToTheLiveValue() {
        CallCapabilities.audioSrtpDebugOverride = true
        CallCapabilities.beginNativeSrtpCallSnapshot(callId: "call-f")
        CallCapabilities.endNativeSrtpCallSnapshot()
        XCTAssertNil(CallCapabilities.nativeSrtpCallSnapshot)
        XCTAssertNil(CallCapabilities.nativeSrtpSnapshotCallId)
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
        CallCapabilities.beginNativeSrtpCallSnapshot(callId: "call-g")
        let n = CallCapabilities.negotiate(local: CallCapabilities.negotiationLocal(),
                                           peer: [CallCapabilities.audioSrtpV1, CallCapabilities.sframeV1])
        XCTAssertTrue(n.useAudioSrtp)
    }
}
