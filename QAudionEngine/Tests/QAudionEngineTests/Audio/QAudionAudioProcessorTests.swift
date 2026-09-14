import XCTest
@testable import QAudionEngine

final class QAudionAudioProcessorTests: XCTestCase {
    func testProcessOutgoing() {
        let proc = QAudionAudioProcessor()
        let pcm = Data(repeating: 0x10, count: AudioProfile.defaultProfile.bytesPerFrame)
        let encoded = proc.processOutgoing(pcmFrame: pcm)
        XCTAssertNotNil(encoded)
    }

    func testProcessIncoming() {
        let proc = QAudionAudioProcessor()
        let pcm = Data(repeating: 0x10, count: AudioProfile.defaultProfile.bytesPerFrame)
        // Safe: pcm is fixed-size (bytesPerFrame) and proc is unmuted, so
        // processOutgoing() always returns non-nil (delegates to encode()).
        // swiftlint:disable:next force_unwrapping
        let encoded = proc.processOutgoing(pcmFrame: pcm)!
        let decoded = proc.processIncoming(opusFrame: encoded)
        XCTAssertNotNil(decoded)
    }

    func testMute() {
        let proc = QAudionAudioProcessor()
        proc.setMuted(true)
        XCTAssertTrue(proc.muted)
        let pcm = Data(repeating: 0x10, count: AudioProfile.defaultProfile.bytesPerFrame)
        let encoded = proc.processOutgoing(pcmFrame: pcm)
        XCTAssertNotNil(encoded) // Should produce comfort noise
    }

    func testCallbacks() {
        let proc = QAudionAudioProcessor()
        var gotRawPcm = false
        var gotEncoded = false
        proc.onRawPcmFrame = { _ in gotRawPcm = true }
        proc.onEncodedFrame = { _ in gotEncoded = true }
        let pcm = Data(repeating: 0, count: AudioProfile.defaultProfile.bytesPerFrame)
        _ = proc.processOutgoing(pcmFrame: pcm)
        XCTAssertTrue(gotRawPcm)
        XCTAssertTrue(gotEncoded)
    }

    // MARK: - W-FECDECODE (2026-08-25) — the sequence-gap wiring

    private func fourSequentialPackets(_ proc: QAudionAudioProcessor) -> [Data]? {
        let pcm = Data(repeating: 0x22, count: AudioProfile.defaultProfile.bytesPerFrame)
        var packets: [Data] = []
        for _ in 0..<4 {
            guard let p = proc.codec.encode(pcm) else { return nil }
            packets.append(p)
        }
        return packets
    }

    /// The exact condition `decodeFEC`'s call-order contract requires: seq ==
    /// last+2, i.e. exactly one frame missing between the last frame this
    /// processor saw and the one that just arrived.
    func testFecRecoveryFiresExactlyOnASingleFrameGap() {
        let proc = QAudionAudioProcessor()
        var recovered = 0
        proc.onFecRecoveredPcm = { _ in recovered += 1 }
        guard let packets = fourSequentialPackets(proc) else { return XCTFail("encode failed") }

        // seq 1: first frame this processor has ever seen — nothing to gap
        // against yet.
        _ = proc.processIncoming(opusFrame: packets[0], sequenceNumber: 1)
        XCTAssertEqual(recovered, 0, "the very first frame must never trigger FEC")

        // seq 2 is LOST (never handed to processIncoming). seq 3 arrives:
        // 3 == 1 + 2, a genuine single-frame gap.
        _ = proc.processIncoming(opusFrame: packets[2], sequenceNumber: 3)
        XCTAssertEqual(recovered, 1, "a single-frame gap must trigger exactly one FEC recovery")

        // seq 4 is the very next frame in order — must not re-fire.
        _ = proc.processIncoming(opusFrame: packets[3], sequenceNumber: 4)
        XCTAssertEqual(recovered, 1, "an in-order frame must not trigger FEC again")
    }

    /// LBRR only ever covers the frame immediately before the one that
    /// carries it. A gap of two or more must NOT attempt a reconstruction —
    /// there is no data for it, and the older holes are the PLC scheduler's
    /// job, not FEC's.
    func testFecRecoveryDoesNotFireOnAMultiFrameGap() {
        let proc = QAudionAudioProcessor()
        var recovered = 0
        proc.onFecRecoveredPcm = { _ in recovered += 1 }
        guard let packets = fourSequentialPackets(proc) else { return XCTFail("encode failed") }

        _ = proc.processIncoming(opusFrame: packets[0], sequenceNumber: 1)
        // seq 2 and 3 both lost; seq 4 arrives — a 3-frame gap, not 1.
        _ = proc.processIncoming(opusFrame: packets[3], sequenceNumber: 4)
        XCTAssertEqual(recovered, 0, "a multi-frame gap must not attempt a single-frame FEC reconstruction")
    }

    /// A reordered/late frame must not be read as a fresh gap against a
    /// watermark that already advanced past it — see `lastRxSeq`'s doc.
    func testFecRecoveryIgnoresAReorderedLateFrame() {
        let proc = QAudionAudioProcessor()
        var recovered = 0
        proc.onFecRecoveredPcm = { _ in recovered += 1 }
        guard let packets = fourSequentialPackets(proc) else { return XCTFail("encode failed") }

        _ = proc.processIncoming(opusFrame: packets[0], sequenceNumber: 1)
        _ = proc.processIncoming(opusFrame: packets[2], sequenceNumber: 3)  // fires once
        XCTAssertEqual(recovered, 1)

        // seq 2 now arrives LATE, after seq 3 — the watermark is already at
        // 3, so this is not "3's predecessor" any more.
        _ = proc.processIncoming(opusFrame: packets[1], sequenceNumber: 2)
        XCTAssertEqual(recovered, 1, "a late-arriving frame must not trigger a second FEC pass")
    }

    /// `sequenceNumber: nil` (every caller before this feature, and every
    /// existing test above) must reproduce today's behaviour byte for byte —
    /// no gap tracking, no FEC callback, ever.
    func testNoSequenceNumberMeansNoFecTracking() {
        let proc = QAudionAudioProcessor()
        var recovered = 0
        proc.onFecRecoveredPcm = { _ in recovered += 1 }
        guard let packets = fourSequentialPackets(proc) else { return XCTFail("encode failed") }
        for p in packets { _ = proc.processIncoming(opusFrame: p) }
        XCTAssertEqual(recovered, 0)
    }
}
