import XCTest
@testable import QAudionEngine

/// W-MEDIAATACCEPT (option b) — `RingSignalingRegistry` is a process-wide
/// singleton (`.shared`), so every test resets it in `setUp`/`tearDown` to
/// avoid cross-test bleed, same discipline as `CrashBreadcrumbsTests`
/// resetting its ring.
final class RingSignalingRegistryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        RingSignalingRegistry.shared.resetForTesting()
    }

    override func tearDown() {
        RingSignalingRegistry.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Latch (I8: first write wins)

    func testFirstLatchWinsOverDuplicateCallIncoming() {
        let reg = RingSignalingRegistry.shared
        reg.latch("Call-1", native: true, kill: false)
        // A duplicate call_incoming for the same call must never change it.
        reg.latch("call-1", native: false, kill: true)

        let e = reg.entry("CALL-1")
        XCTAssertEqual(e?.native, true)
        XCTAssertEqual(e?.kill, false)
    }

    func testLatchIsCaseInsensitiveOnCallId() {
        let reg = RingSignalingRegistry.shared
        reg.latch("AbCd1234", native: true, kill: false)
        XCTAssertNotNil(reg.entry("abcd1234"))
        XCTAssertNotNil(reg.entry("ABCD1234"))
    }

    func testLatchIgnoresEmptyCallId() {
        let reg = RingSignalingRegistry.shared
        XCTAssertNil(reg.latch("", native: true, kill: false))
        XCTAssertNil(reg.entry(""))
    }

    func testLatchEvictsOldestBeyondFourEntries() {
        let reg = RingSignalingRegistry.shared
        for i in 0..<RingSignalingRegistry.maxEntries {
            reg.latch("call-\(i)", native: true, kill: false)
            // Ensure distinct latchedAtMs ordering on fast machines.
            Thread.sleep(forTimeInterval: 0.002)
        }
        XCTAssertNotNil(reg.entry("call-0"))
        reg.latch("call-overflow", native: true, kill: false)
        XCTAssertNil(reg.entry("call-0"), "the oldest entry must be evicted to make room")
        XCTAssertNotNil(reg.entry("call-overflow"))
    }

    // MARK: - Pre-accept counters stop after markAccepted

    func testPreAcceptCountersStopIncrementingAfterMarkAccepted() {
        let reg = RingSignalingRegistry.shared
        reg.latch("call-x", native: true, kill: false)
        reg.noteLocalIceSent("call-x")
        reg.noteLocalIceSent("call-x")
        XCTAssertEqual(reg.entry("call-x")?.preAcceptIce, 2)

        reg.markAccepted("call-x", nowMs: 1_000)
        reg.noteLocalIceSent("call-x")
        XCTAssertEqual(reg.entry("call-x")?.preAcceptIce, 2, "no further pre-accept ICE counting once accepted")
    }

    func testMarkAcceptedIsIdempotentKeepsFirstTimestamp() {
        let reg = RingSignalingRegistry.shared
        reg.latch("call-x", native: true, kill: false)
        reg.markAccepted("call-x", nowMs: 1_000)
        reg.markAccepted("call-x", nowMs: 5_000)
        XCTAssertEqual(reg.entry("call-x")?.acceptedAtMs, 1_000)
    }

    // MARK: - onAnswerSent fires exactly once

    func testOnAnswerSentFiresOnlyOnceAfterAccept() {
        let reg = RingSignalingRegistry.shared
        reg.latch("call-x", native: true, kill: false)
        reg.markAccepted("call-x", nowMs: 1_000)

        var fireCount = 0
        reg.onAnswerSent = { _ in fireCount += 1 }
        reg.noteAnswerSent("call-x", sdpEmpty: false)
        reg.noteAnswerSent("call-x", sdpEmpty: false)
        reg.onAnswerSent = nil

        XCTAssertEqual(fireCount, 1)
    }

    func testOnAnswerSentDoesNotFireBeforeAccept() {
        let reg = RingSignalingRegistry.shared
        reg.latch("call-x", native: true, kill: false)

        var fireCount = 0
        reg.onAnswerSent = { _ in fireCount += 1 }
        reg.noteAnswerSent("call-x", sdpEmpty: false)
        reg.onAnswerSent = nil

        XCTAssertEqual(fireCount, 0)
        XCTAssertEqual(reg.entry("call-x")?.preAcceptAnswers, 1)
    }

    // MARK: - shouldHoldAccept / markReleased integration

    /// T2 (R-ANSWER-FIRST): there is ONE callee path. A call with no ring plan (an OFFER that overtook its
    /// `call_incoming`, a wiped call) holds its ACCEPT: nothing is ever sent for a call nobody answered. Before the
    /// timer round a "fleet default" (the `calls.ring_signaling_only` flag, false or absent) made such a call send
    /// its ACCEPT at ring time.
    func testAnUnknownCallHoldsItsAcceptWhateverAnyFlagSays() {
        let reg = RingSignalingRegistry.shared
        XCTAssertTrue(reg.shouldHoldAccept("never-latched"))
        XCTAssertTrue(reg.shouldHoldAccept("also-never-latched"))
    }

    func testAnEmptyCallIdNeverReleasesAnAccept() {
        XCTAssertTrue(RingSignalingRegistry.shared.shouldHoldAccept(""))
    }

    /// A ringing callee (latched, not answered) holds its ACCEPT, sends no answer and builds nothing: the
    /// registry reads no flag, so the outcome cannot depend on `flags.json`.
    func testARingingCalleeHoldsItsAcceptAndBuildsNothingBeforeTheAnswer() {
        let reg = RingSignalingRegistry.shared
        reg.latch("call-ring", native: true, kill: false)
        XCTAssertTrue(reg.shouldHoldAccept("call-ring"), "no ACCEPT while ringing")
        XCTAssertNil(reg.entry("call-ring")?.acceptedAtMs)
        XCTAssertEqual(reg.entry("call-ring")?.mediaPlane, RingSignalingRegistry.MediaPlaneState.none, "no PeerConnection while ringing")
        XCTAssertFalse(RingSignalingDecisions.shouldStartMediaPlane(
            accepted: reg.entry("call-ring")?.acceptedAtMs != nil, hasSdp: true, state: .none),
            "no media plane before the answer")
        // an OFFER (SDP) held while ringing starts nothing either
        _ = reg.updateOffer("call-ring", sdp: "v=0...", capabilities: nil, hasVideo: false)
        XCTAssertEqual(reg.entry("call-ring")?.mediaPlane, RingSignalingRegistry.MediaPlaneState.none)
        XCTAssertTrue(reg.shouldHoldAccept("call-ring"))
        // the answer opens the plane, and only then
        reg.markAccepted("call-ring", nowMs: 1_000)
        XCTAssertTrue(RingSignalingDecisions.shouldStartMediaPlane(
            accepted: reg.entry("call-ring")?.acceptedAtMs != nil, hasSdp: true, state: .none))
    }

    func testMarkReleasedStopsFurtherHolding() {
        let reg = RingSignalingRegistry.shared
        reg.latch("call-x", native: true, kill: false)
        XCTAssertTrue(reg.shouldHoldAccept("call-x"))
        reg.markReleased("call-x")
        XCTAssertFalse(reg.shouldHoldAccept("call-x"))
    }

    // MARK: - offer stash (W-DCSTUCK / W-BLANKRERINGSDP parity)

    func testUpdateOfferNoPlanWhenNeverLatched() {
        let reg = RingSignalingRegistry.shared
        XCTAssertEqual(
            reg.updateOffer("ghost", sdp: "v=0...", capabilities: nil, hasVideo: false),
            .noPlan
        )
    }

    func testUpdateOfferStashesThenIgnoresBlankReplay() {
        let reg = RingSignalingRegistry.shared
        reg.latch("call-x", native: true, kill: false)
        XCTAssertEqual(reg.updateOffer("call-x", sdp: "v=0...real...", capabilities: ["audio-srtp-v1"], hasVideo: false), .accepted(len: "v=0...real...".count))
        XCTAssertEqual(reg.updateOffer("call-x", sdp: "", capabilities: nil, hasVideo: false), .ignoredEmpty)
        XCTAssertEqual(reg.entry("call-x")?.offer?.sdp, "v=0...real...")
    }

    // MARK: - wipe (I13)

    func testWipeRemovesEntryEntirely() {
        let reg = RingSignalingRegistry.shared
        reg.latch("call-x", native: true, kill: false)
        reg.wipe("call-x", why: 1)
        XCTAssertNil(reg.entry("call-x"))
        // A later latch for the same id must succeed as a brand-new entry.
        reg.latch("call-x", native: false, kill: false)
        XCTAssertEqual(reg.entry("call-x")?.native, false)
    }

    // MARK: - sweep (90s TTL for never-accepted entries)

    func testSweepRemovesOnlyExpiredUnacceptedEntries() {
        let reg = RingSignalingRegistry.shared
        reg.latch("stale", native: true, kill: false)
        reg.latch("fresh", native: true, kill: false)
        reg.markAccepted("fresh", nowMs: 0)

        // `latch` stamps wall-clock time, so the sweep clock must be
        // relative to the entry's own stamp, not to 0.
        guard let latchedAtMs = reg.entry("stale")?.latchedAtMs else {
            return XCTFail("latch must create the entry")
        }
        let farFuture: Int64 = latchedAtMs + RingSignalingRegistry.ttlMs + 1_000
        reg.sweep(nowMs: farFuture)

        XCTAssertNil(reg.entry("stale"), "an unaccepted entry past its TTL must be swept")
        XCTAssertNotNil(reg.entry("fresh"), "an accepted call must never be TTL-swept")
    }

    func testSweepKeepsEntriesWithinTtl() {
        let reg = RingSignalingRegistry.shared
        reg.latch("recent", native: true, kill: false)
        guard let latchedAtMs = reg.entry("recent")?.latchedAtMs else {
            return XCTFail("latch must create the entry")
        }
        reg.sweep(nowMs: latchedAtMs + RingSignalingRegistry.ttlMs - 1)
        XCTAssertNotNil(reg.entry("recent"))
    }
}
