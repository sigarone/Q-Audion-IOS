import XCTest
import Foundation
@testable import QAudionEngine

/// The rows that count in the two reports of a poll: exactly one audio inbound row, Opus only, and the rest absent rather than
/// invented.
final class VoiceStatsReaderTests: XCTestCase {
    private func inbound(id: String = "IT1", kind: String = "audio", codec: String? = "COD1", extra: [String: Any] = [:]) -> VoiceStatRow {
        var v: [String: Any] = [
            "kind": kind, "ssrc": NSNumber(value: 2_882_343_476 as Int64), "concealedSamples": NSNumber(value: 480),
            "silentConcealedSamples": NSNumber(value: 96), "concealmentEvents": NSNumber(value: 3),
            "totalSamplesReceived": NSNumber(value: 192_000), "insertedSamplesForDeceleration": NSNumber(value: 10),
            "removedSamplesForAcceleration": NSNumber(value: 20), "jitterBufferDelay": NSNumber(value: 11.5),
            "jitterBufferEmittedCount": NSNumber(value: 190_000)
        ]
        if let codec { v["codecId"] = codec }
        for (k, x) in extra { v[k] = x }
        return VoiceStatRow(type: "inbound-rtp", id: id, values: v)
    }

    private func codec(id: String = "COD1", mime: String = "audio/opus") -> VoiceStatRow {
        VoiceStatRow(type: "codec", id: id, values: ["mimeType": mime])
    }

    func testOneAudioInboundRowAndOpusGiveTheCounters() throws {
        let result = VoiceStatsReader.readReceiver([inbound(), codec(), VoiceStatRow(type: "transport", id: "T", values: [:])])
        let c = try result.get()
        XCTAssertEqual(c.rxSsrc, 2_882_343_476)
        XCTAssertEqual(c.concealed, 480)
        XCTAssertEqual(c.silentConcealed, 96)
        XCTAssertEqual(c.concealmentEvents, 3)
        XCTAssertEqual(c.totalSamples, 192_000)
        XCTAssertEqual(c.insertedDecel, 10)
        XCTAssertEqual(c.removedAccel, 20)
        XCTAssertEqual(c.jbDelayS, 11.5)
        XCTAssertEqual(c.jbEmitted, 190_000)
    }

    func testAnAbsentCounterIsNilAndNotZero() throws {
        var row = inbound()
        row.values.removeValue(forKey: "concealmentEvents")
        row.values.removeValue(forKey: "jitterBufferDelay")
        let c = try VoiceStatsReader.readReceiver([row, codec()]).get()
        XCTAssertNil(c.concealmentEvents)
        XCTAssertNil(c.jbDelayS)
        XCTAssertEqual(c.concealed, 480)
    }

    func testNoAudioRowIsAFault() {
        XCTAssertEqual(VoiceStatsReader.readReceiver([codec()]), .failure(.noAudioRow))
        XCTAssertEqual(VoiceStatsReader.readReceiver([inbound(kind: "video"), codec()]), .failure(.noAudioRow))
    }

    func testMoreThanOneAudioRowIsAFault() {
        XCTAssertEqual(VoiceStatsReader.readReceiver([inbound(id: "A"), inbound(id: "B"), codec()]), .failure(.severalAudioRows))
    }

    func testAVideoRowBesideTheAudioRowIsNotCounted() throws {
        let c = try VoiceStatsReader.readReceiver([inbound(), inbound(id: "V", kind: "video"), codec()]).get()
        XCTAssertEqual(c.totalSamples, 192_000)
    }

    func testAnythingButOpusIsAFault() {
        XCTAssertEqual(VoiceStatsReader.readReceiver([inbound(), codec(mime: "audio/PCMU")]), .failure(.notOpus))
        XCTAssertEqual(VoiceStatsReader.readReceiver([inbound(codec: nil), codec()]), .failure(.notOpus))
        XCTAssertEqual(VoiceStatsReader.readReceiver([inbound(codec: "MISSING"), codec()]), .failure(.notOpus))
        XCTAssertNoThrow(try VoiceStatsReader.readReceiver([inbound(), codec(mime: "audio/OPUS")]).get())
    }

    func testTheSenderReportGivesTheMediaSourceAndTheTwoRoundTrips() {
        let rows = [
            VoiceStatRow(type: "media-source", id: "S", values: [
                "kind": "audio", "totalAudioEnergy": NSNumber(value: 0.25), "totalSamplesDuration": NSNumber(value: 12.5)
            ]),
            VoiceStatRow(type: "remote-inbound-rtp", id: "R", values: ["kind": "audio", "roundTripTime": NSNumber(value: 0.08)]),
            VoiceStatRow(type: "candidate-pair", id: "P1", values: [
                "state": "waiting", "nominated": NSNumber(value: true), "currentRoundTripTime": NSNumber(value: 9.0)
            ]),
            VoiceStatRow(type: "candidate-pair", id: "P2", values: [
                "state": "succeeded", "nominated": NSNumber(value: true), "currentRoundTripTime": NSNumber(value: 0.05)
            ])
        ]
        let s = VoiceStatsReader.readSender(rows)
        XCTAssertEqual(s.txEnergy, 0.25)
        XCTAssertEqual(s.txDurationS, 12.5)
        XCTAssertEqual(s.rttRemoteS, 0.08)
        XCTAssertEqual(s.rttPairS, 0.05)
        XCTAssertEqual(VoiceStatsReader.readSender([]), VoiceSenderCounters(txEnergy: nil, txDurationS: nil, rttRemoteS: nil, rttPairS: nil))
    }

    func testTheSnapshotCarriesTheStampsAndBothReports() throws {
        let inboundCounters = try VoiceStatsReader.readReceiver([inbound(), codec()]).get()
        let sender = VoiceSenderCounters(txEnergy: 1.5, txDurationS: 3.0, rttRemoteS: nil, rttPairS: 0.04)
        let stamp = PeerConnectionStatsGate.Stamp(reqNs: 10, arriveNs: 30, oldestNs: 5)
        let s = VoiceStatsReader.snapshot(stamp: stamp, reportNs: 77, inbound: inboundCounters, sender: sender)
        XCTAssertEqual([s.reqNs, s.arriveNs, s.oldestNs, s.reportNs], [10, 30, 5, 77])
        XCTAssertEqual(s.rxSsrc, 2_882_343_476)
        XCTAssertEqual(s.txEnergy, 1.5)
        XCTAssertNil(s.rttRemoteS)
        XCTAssertEqual(s.rttPairS, 0.04)
    }

    func testThePollJoinDeliversOnceWhenBothReportsAreThere() {
        var results: [VoicePollResult] = []
        let join = VoicePollJoin { results.append($0) }
        let stampA = PeerConnectionStatsGate.Stamp(reqNs: 10, arriveNs: 20, oldestNs: 10)
        let stampB = PeerConnectionStatsGate.Stamp(reqNs: 12, arriveNs: 40, oldestNs: 8)
        join.senderArrived(([], stampB, 2))
        XCTAssertTrue(results.isEmpty)
        join.receiverArrived(([inbound(), codec()], stampA, 1))
        join.receiverArrived(([inbound(), codec()], stampA, 1))
        XCTAssertEqual(results.count, 1)
        guard case .snapshot(let s) = results[0] else { return XCTFail("a snapshot is expected") }
        XCTAssertEqual([s.reqNs, s.arriveNs, s.oldestNs], [10, 40, 8])
        XCTAssertEqual(s.reportNs, 1)
    }

    func testThePollJoinDeliversTheFaultOfTheReceiverReport() {
        var results: [VoicePollResult] = []
        let join = VoicePollJoin { results.append($0) }
        let stamp = PeerConnectionStatsGate.Stamp(reqNs: 1, arriveNs: 2, oldestNs: 1)
        join.receiverArrived(([codec()], stamp, 1))
        join.senderArrived(([], stamp, 1))
        guard case .fault(let fault) = results.first else { return XCTFail("a fault is expected") }
        XCTAssertEqual(fault, .noAudioRow)
    }
}
