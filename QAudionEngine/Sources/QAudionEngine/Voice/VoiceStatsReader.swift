import Foundation
#if canImport(WebRTC)
import WebRTC
#endif

/// One row of a statistics report, as plain values.
struct VoiceStatRow {
    var type: String
    var id: String
    var values: [String: Any]

    func int(_ key: String) -> Int64? {
        (values[key] as? NSNumber)?.int64Value
    }

    func double(_ key: String) -> Double? {
        (values[key] as? NSNumber)?.doubleValue
    }

    func string(_ key: String) -> String? {
        values[key] as? String
    }
}

/// Why a poll cannot be used. The engine reports Cannot verify (audio) for all of them.
enum VoiceStatsFault: Error, Equatable {
    /// The receiver report has no audio inbound-rtp row.
    case noAudioRow
    /// It has more than one: the counters could belong to any of them.
    case severalAudioRows
    /// The receive codec is not Opus (or the codec row is missing): the rate that the interval rule assumes would be wrong.
    case notOpus
}

/// The inbound counters of one receiver report (an absent counter is nil, never a made-up number).
struct VoiceInboundCounters: Equatable {
    var rxSsrc: Int64?
    var concealed: Int64?
    var silentConcealed: Int64?
    var concealmentEvents: Int64?
    var totalSamples: Int64?
    var insertedDecel: Int64?
    var removedAccel: Int64?
    var jbDelayS: Double?
    var jbEmitted: Int64?
}

/// What the sender report adds: the media-source energy of what is sent and the two round trips.
struct VoiceSenderCounters: Equatable {
    var txEnergy: Double?
    var txDurationS: Double?
    var rttRemoteS: Double?
    var rttPairS: Double?
}

/// Reads the two selector reports of a poll. Pure: the rules of the stats rule about which rows count.
enum VoiceStatsReader {
    /// The receiver report: exactly one audio inbound-rtp row, and Opus.
    static func readReceiver(_ rows: [VoiceStatRow]) -> Result<VoiceInboundCounters, VoiceStatsFault> {
        let audio = rows.filter { $0.type == "inbound-rtp" && isAudio($0) }
        guard !audio.isEmpty else { return .failure(.noAudioRow) }
        guard audio.count == 1, let row = audio.first else { return .failure(.severalAudioRows) }
        guard let codecId = row.string("codecId"),
              let codec = rows.first(where: { $0.type == "codec" && $0.id == codecId }),
              let mime = codec.string("mimeType")?.lowercased(), mime == "audio/opus" else {
            return .failure(.notOpus)
        }
        return .success(VoiceInboundCounters(
            rxSsrc: row.int("ssrc"),
            concealed: row.int("concealedSamples"),
            silentConcealed: row.int("silentConcealedSamples"),
            concealmentEvents: row.int("concealmentEvents"),
            totalSamples: row.int("totalSamplesReceived"),
            insertedDecel: row.int("insertedSamplesForDeceleration"),
            removedAccel: row.int("removedSamplesForAcceleration"),
            jbDelayS: row.double("jitterBufferDelay"),
            jbEmitted: row.int("jitterBufferEmittedCount")))
    }

    /// The sender report: the audio media-source, the remote-inbound row of the audio stream and the selected candidate pair.
    static func readSender(_ rows: [VoiceStatRow]) -> VoiceSenderCounters {
        let source = rows.first { $0.type == "media-source" && isAudio($0) }
        let remote = rows.first { $0.type == "remote-inbound-rtp" && isAudio($0) }
        let pair = rows.first { $0.type == "candidate-pair" && $0.string("state") == "succeeded" && isNominated($0) }
        return VoiceSenderCounters(
            txEnergy: source?.double("totalAudioEnergy"),
            txDurationS: source?.double("totalSamplesDuration"),
            rttRemoteS: remote?.double("roundTripTime"),
            rttPairS: pair?.double("currentRoundTripTime"))
    }

    /// One snapshot of the two reports with the stamps of the poll.
    static func snapshot(stamp: PeerConnectionStatsGate.Stamp, reportNs: Int64, inbound: VoiceInboundCounters,
                         sender: VoiceSenderCounters) -> VoiceStatsSnapshot {
        VoiceStatsSnapshot(
            reqNs: stamp.reqNs, arriveNs: stamp.arriveNs, oldestNs: stamp.oldestNs, reportNs: reportNs,
            rxSsrc: inbound.rxSsrc, concealed: inbound.concealed, silentConcealed: inbound.silentConcealed,
            concealmentEvents: inbound.concealmentEvents, totalSamples: inbound.totalSamples,
            insertedDecel: inbound.insertedDecel, removedAccel: inbound.removedAccel, jbDelayS: inbound.jbDelayS,
            jbEmitted: inbound.jbEmitted, txEnergy: sender.txEnergy, txDurationS: sender.txDurationS,
            rttRemoteS: sender.rttRemoteS, rttPairS: sender.rttPairS)
    }

    private static func isAudio(_ row: VoiceStatRow) -> Bool {
        (row.string("kind") ?? row.string("mediaType")) == "audio"
    }

    private static func isNominated(_ row: VoiceStatRow) -> Bool {
        if let n = row.values["nominated"] as? NSNumber { return n.boolValue }
        return false
    }

    #if canImport(WebRTC)
    /// The rows of a native report.
    static func rows(of report: RTCStatisticsReport) -> [VoiceStatRow] {
        report.statistics.values.map { VoiceStatRow(type: $0.type, id: $0.id, values: $0.values) }
    }

    /// The report's own timestamp in ns (kept only to drop a delivery that repeats the previous one).
    static func reportNs(of report: RTCStatisticsReport) -> Int64 {
        let us = report.timestamp_us
        return us.isFinite ? Int64(us * 1000.0) : 0
    }
    #endif
}
