import XCTest
@testable import QAudionEngine

/// N7 (network-resilience-max) — pure interval-delta computation for the
/// native-audio-srtp heartbeat. No WebRTC types involved: this seam is the
/// arithmetic only, exactly the part the task calls out for unit tests.
final class NativeAudioHeartbeatDeltasTests: XCTestCase {

    private typealias Counters = NativeAudioHeartbeatDeltas.IntervalCounters

    // MARK: - First sample: nothing to diff against

    func test_noPrevious_everythingIsMinusOne() {
        let current = Counters(jitterBufferDelaySec: 1.0, jitterBufferTargetDelaySec: 0.8,
                               jitterBufferEmittedCount: 100, concealedSamples: 5,
                               fecPacketsReceived: 2, fecPacketsDiscarded: 0,
                               nackCount: 1, retransmittedPacketsSent: 1)
        let d = NativeAudioHeartbeatDeltas.compute(previous: nil, current: current)
        XCTAssertEqual(d.jitterBufferDelayMsAvg, -1)
        XCTAssertEqual(d.jitterBufferTargetDelayMsAvg, -1)
        XCTAssertEqual(d.concealedSamplesDelta, -1)
        XCTAssertEqual(d.fecPacketsReceivedDelta, -1)
        XCTAssertEqual(d.fecPacketsDiscardedDelta, -1)
        XCTAssertEqual(d.nackCountDelta, -1)
        XCTAssertEqual(d.retransmittedPacketsSentDelta, -1)
    }

    // MARK: - Plain counter deltas

    func test_plainCounters_deltaIsCurrentMinusPrevious() {
        let previous = Counters(concealedSamples: 10, fecPacketsReceived: 4,
                                fecPacketsDiscarded: 1, nackCount: 3,
                                retransmittedPacketsSent: 2)
        let current = Counters(concealedSamples: 34, fecPacketsReceived: 9,
                               fecPacketsDiscarded: 1, nackCount: 3,
                               retransmittedPacketsSent: 5)
        let d = NativeAudioHeartbeatDeltas.compute(previous: previous, current: current)
        XCTAssertEqual(d.concealedSamplesDelta, 24)
        XCTAssertEqual(d.fecPacketsReceivedDelta, 5)
        XCTAssertEqual(d.fecPacketsDiscardedDelta, 0)
        XCTAssertEqual(d.nackCountDelta, 0)
        XCTAssertEqual(d.retransmittedPacketsSentDelta, 3)
    }

    /// A counter going DOWN means the underlying stats object was replaced
    /// (e.g. an ICE restart rebuilding the RTP stream stats from zero) — the
    /// two samples are not comparable, so this must read -1, never a
    /// fabricated negative delta.
    func test_counterWentDown_isMinusOneNotNegative() {
        let previous = Counters(concealedSamples: 500)
        let current = Counters(concealedSamples: 3)
        let d = NativeAudioHeartbeatDeltas.compute(previous: previous, current: current)
        XCTAssertEqual(d.concealedSamplesDelta, -1)
    }

    /// Either side absent (-1, "no such row this report") must not be
    /// treated as zero — that would silently manufacture a delta equal to
    /// the other side's raw value.
    func test_eitherSideAbsent_isMinusOne() {
        let previous = Counters(concealedSamples: -1)
        let current = Counters(concealedSamples: 40)
        XCTAssertEqual(NativeAudioHeartbeatDeltas.compute(previous: previous, current: current).concealedSamplesDelta, -1)

        let previous2 = Counters(concealedSamples: 40)
        let current2 = Counters(concealedSamples: -1)
        XCTAssertEqual(NativeAudioHeartbeatDeltas.compute(previous: previous2, current: current2).concealedSamplesDelta, -1)
    }

    // MARK: - Jitter buffer delay/target averaging

    /// 10 new samples emitted this interval, cumulative delay grew by 3.0s
    /// (delay) / 2.0s (target) -> 300ms / 200ms average per emitted sample.
    func test_jitterBufferAveraging_computesMsPerEmittedSample() {
        let previous = Counters(jitterBufferDelaySec: 10.0, jitterBufferTargetDelaySec: 8.0,
                                jitterBufferEmittedCount: 1000)
        let current = Counters(jitterBufferDelaySec: 13.0, jitterBufferTargetDelaySec: 10.0,
                               jitterBufferEmittedCount: 1010)
        let d = NativeAudioHeartbeatDeltas.compute(previous: previous, current: current)
        XCTAssertEqual(d.jitterBufferDelayMsAvg, 300)
        XCTAssertEqual(d.jitterBufferTargetDelayMsAvg, 200)
    }

    /// Zero new samples emitted this interval (a call idle at the RTP layer,
    /// or two polls landing inside the same underlying sample) — nothing to
    /// average, must read -1, never a divide-by-zero crash or a bogus 0.
    func test_jitterBufferAveraging_zeroEmittedDelta_isMinusOne() {
        let previous = Counters(jitterBufferDelaySec: 10.0, jitterBufferEmittedCount: 1000)
        let current = Counters(jitterBufferDelaySec: 10.0, jitterBufferEmittedCount: 1000)
        XCTAssertEqual(NativeAudioHeartbeatDeltas.compute(previous: previous, current: current).jitterBufferDelayMsAvg, -1)
    }

    func test_jitterBufferAveraging_emittedCountAbsent_isMinusOne() {
        let previous = Counters(jitterBufferDelaySec: 10.0, jitterBufferEmittedCount: -1)
        let current = Counters(jitterBufferDelaySec: 13.0, jitterBufferEmittedCount: -1)
        XCTAssertEqual(NativeAudioHeartbeatDeltas.compute(previous: previous, current: current).jitterBufferDelayMsAvg, -1)
    }

    /// The two averaged fields (delay vs target) must be computed
    /// independently: a reset on ONE must not poison the other.
    func test_jitterBufferAveraging_delayAndTargetAreIndependent() {
        let previous = Counters(jitterBufferDelaySec: 10.0, jitterBufferTargetDelaySec: 500.0,
                                jitterBufferEmittedCount: 1000)
        let current = Counters(jitterBufferDelaySec: 13.0, jitterBufferTargetDelaySec: 2.0,
                               jitterBufferEmittedCount: 1010)
        let d = NativeAudioHeartbeatDeltas.compute(previous: previous, current: current)
        XCTAssertEqual(d.jitterBufferDelayMsAvg, 300, "delay must still compute despite target having gone down")
        XCTAssertEqual(d.jitterBufferTargetDelayMsAvg, -1, "target went down (reset) -> -1")
    }

    // MARK: - relayProtocolCode / networkTypeCode

    func test_relayProtocolCode_knownValues() {
        XCTAssertEqual(NativeAudioHeartbeatDeltas.relayProtocolCode("udp"), 1)
        XCTAssertEqual(NativeAudioHeartbeatDeltas.relayProtocolCode("tcp"), 2)
        XCTAssertEqual(NativeAudioHeartbeatDeltas.relayProtocolCode("tls"), 3)
        XCTAssertEqual(NativeAudioHeartbeatDeltas.relayProtocolCode("UDP"), 1, "case-insensitive")
    }

    func test_relayProtocolCode_nilOrUnknown_isZero() {
        XCTAssertEqual(NativeAudioHeartbeatDeltas.relayProtocolCode(nil), 0)
        XCTAssertEqual(NativeAudioHeartbeatDeltas.relayProtocolCode("quic"), 0)
    }

    func test_networkTypeCode_knownValues() {
        XCTAssertEqual(NativeAudioHeartbeatDeltas.networkTypeCode("wifi"), 1)
        XCTAssertEqual(NativeAudioHeartbeatDeltas.networkTypeCode("ethernet"), 2)
        XCTAssertEqual(NativeAudioHeartbeatDeltas.networkTypeCode("cellular"), 3)
        XCTAssertEqual(NativeAudioHeartbeatDeltas.networkTypeCode("vpn"), 4)
        XCTAssertEqual(NativeAudioHeartbeatDeltas.networkTypeCode("loopback"), 5)
        XCTAssertEqual(NativeAudioHeartbeatDeltas.networkTypeCode("unknown"), 6)
    }

    func test_networkTypeCode_nilOrUnrecognized_isZero() {
        XCTAssertEqual(NativeAudioHeartbeatDeltas.networkTypeCode(nil), 0)
        XCTAssertEqual(NativeAudioHeartbeatDeltas.networkTypeCode("satellite"), 0)
    }
}
