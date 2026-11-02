import Foundation

/// What the in-call diagnostics panel shows, as plain values.
///
/// ONE panel for audio and video calls, the same rows in the same order as the Android panel. The mapping from the
/// measurements to the rows is pure on purpose (no AppState, no WebRTC types): `CallDiagnosticsInput` carries the raw
/// readings, `CallDiagnosticsModel.make` decides which rows exist and how each value reads. A reading that was not
/// measured is the dash, never a placeholder that looks real.
struct CallDiagnosticsInput: Equatable {

    /// Which branch of the panel the call is on.
    enum Path: Equatable {
        case p2p
        case turn
        case wsRelay
        case disconnected
    }

    var path: Path = .disconnected
    /// The call carries video: adds the video codec and the video pipeline rows.
    var videoOn: Bool = false

    // Codecs and cipher.
    /// Mime type of the audio codec the PeerConnection reports ("audio/opus"), nil when it has no audio row.
    var audioCodecMime: String?
    /// Opus bitrate applied to this call in kbps, 0 = not known yet.
    var audioCodecKbps: Int = 0
    var videoCodecLabel: String?
    /// SRTP cipher of the transport as the stats name it ("AEAD_AES_256_GCM").
    var srtpCipher: String?

    // The selected ICE pair.
    var iceState: String?
    var localCandidateType: String?
    var localCandidateProtocol: String?
    var localCandidateRelayProtocol: String?
    var remoteCandidateType: String?
    var remoteCandidateProtocol: String?
    var rttMs: Double?
    /// Cumulative playout-buffer delay in seconds and the samples it was emitted over; -1 = no row.
    var jitterBufferDelaySec: Double = -1
    var jitterBufferEmittedCount: Int64 = -1
    /// ICE server URL of the relay candidate in use, nil when the local candidate is not a relay one.
    var relayNodeUrl: String?
    var availableOutgoingBps: Double = -1
    var availableIncomingBps: Double = -1
    var transportBytesSent: Int64 = -1
    var transportBytesReceived: Int64 = -1

    // Audio RTP counters; -1 = no such row in the report.
    var packetsSent: Int64 = -1
    var packetsReceived: Int64 = -1
    var packetsLost: Int64 = -1
    var jitterSec: Double = -1
    var nackCount: Int64 = -1

    /// Video pipeline state, already worded for the user; nil = no value (never when video is on).
    var videoPipelineState: String?
    /// Short fingerprint of the ML-KEM session key, nil while the key exchange is still running.
    var mlKemFingerprint: String?

    // WS relay (audio sealed over the signalling socket).
    var wsFramesSent: Int64 = -1
    var wsFramesReceived: Int64 = -1
    var wsBytesSent: Int64 = -1
    var wsBytesReceived: Int64 = -1
}

struct CallDiagnosticsModel: Equatable {

    /// One row of the panel. The label is looked up by the view from `field`, so the model stays language-free.
    enum Field: String, Equatable {
        // Connected over P2P or TURN.
        case audioCodec, videoCodec, cipher, iceState, pair, localCandidate, remoteCandidate, rtt, jitterBufferAverage
        case relayNode, bandwidth, bytes, loss, jitter, packets, nack, videoPipeline, mlKemSession
        // WS relay.
        case path, format, frames, lastSend, lastReceive, discardedRefused
    }

    struct Row: Equatable {
        let field: Field
        let value: String
    }

    enum Subtitle: Equatable {
        case p2p
        case turn
        case wsRelay
        case waiting
    }

    let subtitle: Subtitle
    let rows: [Row]

    /// The dash used for every unmeasured value.
    static let noValue = "—"

    /// Value of the ML-KEM row while the key exchange is still running.
    static var handshakeInProgress: String {
        String(localized: "video.diag.handshake_in_progress",
               defaultValue: "handshake in corso…",
               comment: "Value in the call diagnostics panel while the key exchange of the call is still running.")
    }

    // MARK: - Build

    static func make(_ input: CallDiagnosticsInput) -> CallDiagnosticsModel {
        switch input.path {
        case .disconnected:
            return CallDiagnosticsModel(subtitle: .waiting, rows: [])
        case .wsRelay:
            return CallDiagnosticsModel(subtitle: .wsRelay, rows: wsRelayRows(input))
        case .p2p:
            return CallDiagnosticsModel(subtitle: .p2p, rows: webrtcRows(input))
        case .turn:
            return CallDiagnosticsModel(subtitle: .turn, rows: webrtcRows(input))
        }
    }

    private static func webrtcRows(_ i: CallDiagnosticsInput) -> [Row] {
        var rows: [Row] = []
        rows.append(Row(field: .audioCodec, value: audioCodec(mime: i.audioCodecMime, kbps: i.audioCodecKbps)))
        if i.videoOn {
            rows.append(Row(field: .videoCodec, value: text(i.videoCodecLabel)))
        }
        rows.append(Row(field: .cipher, value: cipher(i.srtpCipher)))
        rows.append(Row(field: .iceState, value: text(i.iceState)))
        rows.append(Row(field: .pair, value: pair(local: i.localCandidateType, remote: i.remoteCandidateType,
                                                  proto: i.localCandidateProtocol)))
        rows.append(Row(field: .localCandidate, value: candidate(type: i.localCandidateType,
                                                                proto: i.localCandidateProtocol,
                                                                relayProto: i.localCandidateRelayProtocol)))
        rows.append(Row(field: .remoteCandidate, value: candidate(type: i.remoteCandidateType,
                                                                 proto: i.remoteCandidateProtocol,
                                                                 relayProto: nil)))
        rows.append(Row(field: .rtt, value: milliseconds(i.rttMs, decimals: 1)))
        rows.append(Row(field: .jitterBufferAverage, value: jitterBufferAverage(delaySec: i.jitterBufferDelaySec,
                                                                                emitted: i.jitterBufferEmittedCount)))
        rows.append(Row(field: .relayNode, value: text(i.relayNodeUrl)))
        rows.append(Row(field: .bandwidth, value: pairOfKbps(out: i.availableOutgoingBps, in: i.availableIncomingBps)))
        rows.append(Row(field: .bytes, value: pairOfBytes(i.transportBytesSent, i.transportBytesReceived)))
        rows.append(Row(field: .loss, value: loss(lost: i.packetsLost, received: i.packetsReceived)))
        rows.append(Row(field: .jitter, value: i.jitterSec >= 0 && i.jitterSec.isFinite
                        ? String(format: "%.0f ms", i.jitterSec * 1000.0) : noValue))
        rows.append(Row(field: .packets, value: pairOfCounts(i.packetsSent, i.packetsReceived)))
        rows.append(Row(field: .nack, value: i.nackCount >= 0 ? String(i.nackCount) : noValue))
        if i.videoOn {
            rows.append(Row(field: .videoPipeline, value: text(i.videoPipelineState)))
        }
        rows.append(Row(field: .mlKemSession, value: i.mlKemFingerprint ?? handshakeInProgress))
        return rows
    }

    private static func wsRelayRows(_ i: CallDiagnosticsInput) -> [Row] {
        [
            Row(field: .path, value: "wss (sealed)"),
            // The app keeps no record of the wire form of the relay, of when the last frame went out or came in,
            // or of what the socket dropped or refused: those three are not measured on this platform.
            Row(field: .format, value: noValue),
            Row(field: .frames, value: pairOfCounts(i.wsFramesSent, i.wsFramesReceived)),
            Row(field: .bytes, value: pairOfBytes(i.wsBytesSent, i.wsBytesReceived)),
            Row(field: .lastSend, value: noValue),
            Row(field: .lastReceive, value: noValue),
            Row(field: .discardedRefused, value: noValue),
            Row(field: .mlKemSession, value: i.mlKemFingerprint ?? handshakeInProgress),
        ]
    }

    // MARK: - Value formats

    static func text(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return noValue }
        return value
    }

    /// "opus · 32 kbps", or just "opus" while the applied rate is not known. A rate is never shown without the codec it belongs to.
    static func audioCodec(mime: String?, kbps: Int) -> String {
        var name: String?
        if let mime, !mime.isEmpty {
            let lower = mime.lowercased()
            name = lower.hasPrefix("audio/") ? String(lower.dropFirst("audio/".count)) : lower
        }
        switch (name, kbps > 0) {
        case let (name?, true): return name + " · " + String(kbps) + " kbps"
        case let (name?, false): return name
        case (nil, true): return "opus · " + String(kbps) + " kbps"
        case (nil, false): return noValue
        }
    }

    /// The SRTP cipher in the usual spelling ("AEAD_AES_256_GCM" -> "AES-256-GCM"); a name it does not know is
    /// shown as the stats report it.
    static func cipher(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return noValue }
        switch raw {
        case "AEAD_AES_256_GCM": return "AES-256-GCM"
        case "AEAD_AES_128_GCM": return "AES-128-GCM"
        default: return raw
        }
    }

    /// "host/host udp": the candidate types of the pair and the protocol of the local one.
    static func pair(local: String?, remote: String?, proto: String?) -> String {
        guard local != nil || remote != nil else { return noValue }
        var out = text(local) + "/" + text(remote)
        if let proto, !proto.isEmpty { out += " " + proto }
        return out
    }

    /// "relay (udp/tls)", "host (udp)", or the bare type.
    static func candidate(type: String?, proto: String?, relayProto: String?) -> String {
        guard let type, !type.isEmpty else { return noValue }
        guard let proto, !proto.isEmpty else { return type }
        if let relayProto, !relayProto.isEmpty { return type + " (" + proto + "/" + relayProto + ")" }
        return type + " (" + proto + ")"
    }

    static func milliseconds(_ ms: Double?, decimals: Int) -> String {
        guard let ms, ms.isFinite, ms >= 0 else { return noValue }
        return String(format: "%.\(decimals)f ms", ms)
    }

    /// Lifetime average playout-buffer delay: the cumulative delay over the samples it was emitted for.
    static func jitterBufferAverage(delaySec: Double, emitted: Int64) -> String {
        guard emitted > 0, delaySec >= 0, delaySec.isFinite else { return noValue }
        return String(format: "%.1f ms", delaySec / Double(emitted) * 1000.0)
    }

    /// Share of the audio packets that never arrived, "0.42%". No packets counted yet is not 0% loss: a dash.
    static func loss(lost: Int64, received: Int64) -> String {
        guard lost >= 0, received > 0 else { return noValue }
        let ratio = Double(lost) / Double(received + lost)
        return String(format: "%.2f%%", ratio * 100.0)
    }

    /// "512 / 2048 kbps" from bits per second; either side may be a dash.
    static func pairOfKbps(out: Double, in incoming: Double) -> String {
        guard out >= 0 || incoming >= 0 else { return noValue }
        let outText = out >= 0 && out.isFinite ? String(format: "%.0f", out / 1000.0) : noValue
        let inText = incoming >= 0 && incoming.isFinite ? String(format: "%.0f", incoming / 1000.0) : noValue
        return outText + " / " + inText + " kbps"
    }

    static func pairOfCounts(_ sent: Int64, _ received: Int64) -> String {
        guard sent >= 0 || received >= 0 else { return noValue }
        return (sent >= 0 ? String(sent) : noValue) + " / " + (received >= 0 ? String(received) : noValue)
    }

    static func pairOfBytes(_ sent: Int64, _ received: Int64) -> String {
        guard sent >= 0 || received >= 0 else { return noValue }
        return (sent >= 0 ? bytes(sent) : noValue) + " / " + (received >= 0 ? bytes(received) : noValue)
    }

    /// "812 B", "4.3 KiB", "1.20 MiB".
    static func bytes(_ count: Int64) -> String {
        if count < 1024 { return String(count) + " B" }
        let kib = Double(count) / 1024.0
        if kib < 1024 { return String(format: "%.1f KiB", kib) }
        return String(format: "%.2f MiB", kib / 1024.0)
    }
}
