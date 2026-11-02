import XCTest
@testable import QAudionApp

/// The mapping from the live readings to the rows of the in-call diagnostics panel, and the formats of the stats band.
final class CallDiagnosticsModelTests: XCTestCase {

    private func connected(_ path: CallDiagnosticsInput.Path, video: Bool = false) -> CallDiagnosticsInput {
        var input = CallDiagnosticsInput()
        input.path = path
        input.videoOn = video
        input.audioCodecMime = "audio/opus"
        input.audioCodecKbps = 32
        input.videoCodecLabel = "HEVC (H.265)"
        input.srtpCipher = "AEAD_AES_256_GCM"
        input.iceState = "connected"
        input.localCandidateType = "host"
        input.localCandidateProtocol = "udp"
        input.remoteCandidateType = "host"
        input.remoteCandidateProtocol = "udp"
        input.rttMs = 42.34
        input.jitterBufferDelaySec = 96.0
        input.jitterBufferEmittedCount = 480_000
        input.availableOutgoingBps = 512_000
        input.availableIncomingBps = 2_048_000
        input.transportBytesSent = 1_536
        input.transportBytesReceived = 812
        input.packetsSent = 1000
        input.packetsReceived = 990
        input.packetsLost = 10
        input.jitterSec = 0.0123
        input.nackCount = 3
        input.videoPipelineState = "attiva"
        input.mlKemFingerprint = "7f3bd2a1…d2e9"
        return input
    }

    private func fields(_ model: CallDiagnosticsModel) -> [CallDiagnosticsModel.Field] { model.rows.map(\.field) }

    private func value(_ model: CallDiagnosticsModel, _ field: CallDiagnosticsModel.Field) -> String? {
        model.rows.first(where: { $0.field == field })?.value
    }

    // MARK: - Branches

    func testNotConnectedHasTheWaitingSubtitleAndNoRows() {
        let model = CallDiagnosticsModel.make(CallDiagnosticsInput())
        XCTAssertEqual(model.subtitle, .waiting)
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testP2pAndTurnShareTheRowsAndNameTheirBranch() {
        XCTAssertEqual(CallDiagnosticsModel.make(connected(.p2p)).subtitle, .p2p)
        XCTAssertEqual(CallDiagnosticsModel.make(connected(.turn)).subtitle, .turn)
        XCTAssertEqual(fields(CallDiagnosticsModel.make(connected(.p2p))),
                       fields(CallDiagnosticsModel.make(connected(.turn))))
    }

    func testAudioCallRowsAreInTheSpecifiedOrderWithoutTheVideoRows() {
        let model = CallDiagnosticsModel.make(connected(.p2p))
        XCTAssertEqual(fields(model), [
            .audioCodec, .cipher, .iceState, .pair, .localCandidate, .remoteCandidate, .rtt,
            .jitterBufferAverage, .relayNode, .bandwidth, .bytes, .loss, .jitter, .packets, .nack, .mlKemSession,
        ])
    }

    func testVideoCallAddsTheVideoCodecAndThePipelineRows() {
        let model = CallDiagnosticsModel.make(connected(.p2p, video: true))
        XCTAssertEqual(fields(model), [
            .audioCodec, .videoCodec, .cipher, .iceState, .pair, .localCandidate, .remoteCandidate, .rtt,
            .jitterBufferAverage, .relayNode, .bandwidth, .bytes, .loss, .jitter, .packets, .nack, .videoPipeline,
            .mlKemSession,
        ])
        XCTAssertEqual(value(model, .videoCodec), "HEVC (H.265)")
        XCTAssertEqual(value(model, .videoPipeline), "attiva")
    }

    func testWsRelayRowsAndOrder() {
        var input = CallDiagnosticsInput()
        input.path = .wsRelay
        input.wsFramesSent = 120
        input.wsFramesReceived = 118
        input.wsBytesSent = 2_048
        input.wsBytesReceived = 900
        let model = CallDiagnosticsModel.make(input)
        XCTAssertEqual(model.subtitle, .wsRelay)
        XCTAssertEqual(fields(model), [
            .path, .format, .frames, .bytes, .lastSend, .lastReceive, .discardedRefused, .mlKemSession,
        ])
        XCTAssertEqual(value(model, .frames), "120 / 118")
        XCTAssertEqual(value(model, .bytes), "2.0 KiB / 900 B")
    }

    func testWsRelayRowsTheAppDoesNotMeasureAreDashes() {
        var input = CallDiagnosticsInput()
        input.path = .wsRelay
        let model = CallDiagnosticsModel.make(input)
        for field in [CallDiagnosticsModel.Field.format, .lastSend, .lastReceive, .discardedRefused] {
            XCTAssertEqual(value(model, field), CallDiagnosticsModel.noValue)
        }
    }

    // MARK: - Values

    func testValuesOfAConnectedCall() {
        let model = CallDiagnosticsModel.make(connected(.p2p))
        XCTAssertEqual(value(model, .audioCodec), "opus · 32 kbps")
        XCTAssertEqual(value(model, .cipher), "AES-256-GCM")
        XCTAssertEqual(value(model, .iceState), "connected")
        XCTAssertEqual(value(model, .pair), "host/host udp")
        XCTAssertEqual(value(model, .localCandidate), "host (udp)")
        XCTAssertEqual(value(model, .remoteCandidate), "host (udp)")
        XCTAssertEqual(value(model, .rtt), "42.3 ms")
        XCTAssertEqual(value(model, .jitterBufferAverage), "0.2 ms")
        XCTAssertEqual(value(model, .bandwidth), "512 / 2048 kbps")
        XCTAssertEqual(value(model, .bytes), "1.5 KiB / 812 B")
        XCTAssertEqual(value(model, .loss), "1.00%")
        XCTAssertEqual(value(model, .jitter), "12 ms")
        XCTAssertEqual(value(model, .packets), "1000 / 990")
        XCTAssertEqual(value(model, .nack), "3")
        XCTAssertEqual(value(model, .mlKemSession), "7f3bd2a1…d2e9")
    }

    func testARelayedCallNamesItsNodeAndTheRelayProtocol() {
        var input = connected(.turn)
        input.localCandidateType = "relay"
        input.localCandidateRelayProtocol = "tls"
        input.relayNodeUrl = "turns:turn.example.net:443"
        let model = CallDiagnosticsModel.make(input)
        XCTAssertEqual(value(model, .localCandidate), "relay (udp/tls)")
        XCTAssertEqual(value(model, .relayNode), "turns:turn.example.net:443")
        XCTAssertEqual(value(model, .pair), "relay/host udp")
    }

    func testNothingMeasuredIsADashNeverAPlaceholder() {
        var input = CallDiagnosticsInput()
        input.path = .p2p
        input.videoOn = true
        let model = CallDiagnosticsModel.make(input)
        let dash = CallDiagnosticsModel.noValue
        for field in [CallDiagnosticsModel.Field.audioCodec, .videoCodec, .cipher, .iceState, .pair, .localCandidate,
                      .remoteCandidate, .rtt, .jitterBufferAverage, .relayNode, .bandwidth, .bytes, .loss, .jitter,
                      .packets, .nack, .videoPipeline] {
            XCTAssertEqual(value(model, field), dash, "\(field)")
        }
        XCTAssertEqual(value(model, .mlKemSession), CallDiagnosticsModel.handshakeInProgress)
    }

    func testLossNeedsPacketsToBeCounted() {
        XCTAssertEqual(CallDiagnosticsModel.loss(lost: 0, received: 0), CallDiagnosticsModel.noValue)
        XCTAssertEqual(CallDiagnosticsModel.loss(lost: -1, received: 500), CallDiagnosticsModel.noValue)
        XCTAssertEqual(CallDiagnosticsModel.loss(lost: 0, received: 500), "0.00%")
        XCTAssertEqual(CallDiagnosticsModel.loss(lost: 5, received: 95), "5.00%")
    }

    func testAudioCodecNeverShowsARateWithoutAnEncoder() {
        XCTAssertEqual(CallDiagnosticsModel.audioCodec(mime: nil, kbps: 0), CallDiagnosticsModel.noValue)
        XCTAssertEqual(CallDiagnosticsModel.audioCodec(mime: "audio/opus", kbps: 0), "opus")
        XCTAssertEqual(CallDiagnosticsModel.audioCodec(mime: nil, kbps: 24), "opus · 24 kbps")
    }

    func testAnUnknownCipherIsShownAsReported() {
        XCTAssertEqual(CallDiagnosticsModel.cipher("AES_CM_128_HMAC_SHA1_80"), "AES_CM_128_HMAC_SHA1_80")
        XCTAssertEqual(CallDiagnosticsModel.cipher("AEAD_AES_128_GCM"), "AES-128-GCM")
        XCTAssertEqual(CallDiagnosticsModel.cipher(nil), CallDiagnosticsModel.noValue)
    }

    func testBytesUnits() {
        XCTAssertEqual(CallDiagnosticsModel.bytes(0), "0 B")
        XCTAssertEqual(CallDiagnosticsModel.bytes(1023), "1023 B")
        XCTAssertEqual(CallDiagnosticsModel.bytes(1024), "1.0 KiB")
        XCTAssertEqual(CallDiagnosticsModel.bytes(5 * 1024 * 1024), "5.00 MiB")
    }

    func testOneSideOfAPairMayBeADash() {
        XCTAssertEqual(CallDiagnosticsModel.pairOfKbps(out: 64_000, in: -1), "64 / — kbps")
        XCTAssertEqual(CallDiagnosticsModel.pairOfKbps(out: -1, in: -1), CallDiagnosticsModel.noValue)
        XCTAssertEqual(CallDiagnosticsModel.pairOfCounts(-1, 7), "— / 7")
        XCTAssertEqual(CallDiagnosticsModel.pair(local: nil, remote: nil, proto: "udp"), CallDiagnosticsModel.noValue)
    }

    // MARK: - Stats band formats

    func testStatsBandFormats() {
        XCTAssertEqual(CallStatsFormat.duration(187), "3:07")
        XCTAssertEqual(CallStatsFormat.duration(-5), "0:00")
        XCTAssertEqual(CallStatsFormat.codec(kbps: 32), "32 kbps")
        XCTAssertEqual(CallStatsFormat.codec(kbps: 0), CallStatsFormat.dash)
        XCTAssertEqual(CallStatsFormat.flow(tx: 45.2, rx: 42.6), "45/43")
        XCTAssertEqual(CallStatsFormat.flow(tx: nil, rx: 10), "—/10")
        XCTAssertEqual(CallStatsFormat.flow(tx: nil, rx: nil), CallStatsFormat.dash)
        XCTAssertEqual(CallStatsFormat.delay(rttMs: 128, bufMs: nil), "128ms")
        XCTAssertEqual(CallStatsFormat.delay(rttMs: 128, bufMs: 9), "128ms")
        XCTAssertEqual(CallStatsFormat.delay(rttMs: 128, bufMs: 40), "128+40ms")
        XCTAssertEqual(CallStatsFormat.delay(rttMs: nil, bufMs: 40), CallStatsFormat.dash)
    }

    func testVideoFlowIsADashWhileNoVideoIsOn() {
        XCTAssertEqual(CallStatsFormat.videoFlow(videoOn: false, tx: 500, rx: 500), CallStatsFormat.dash)
        XCTAssertEqual(CallStatsFormat.videoFlow(videoOn: true, tx: 500, rx: nil), "500/—")
    }
}
