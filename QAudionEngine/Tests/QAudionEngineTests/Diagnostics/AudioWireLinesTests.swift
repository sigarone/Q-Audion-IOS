import XCTest
@testable import QAudionEngine

/// The shared `audiowire` lines of the native-SRTP audio path (window deltas every heartbeat, the send-side codec once
/// per negotiation) and the sender-parameter lines. The exact strings are also pinned, as shipped text, by
/// `scripts/test_ship_ios_audiowire_vocab.py`: change one side, change the other.
final class AudioWireLinesTests: XCTestCase {

    private func counters(txP: Int64, txB: Int64, hdr: Int64, retx: Int64, rxP: Int64, rxB: Int64) -> AudioWireLines.Counters {
        AudioWireLines.Counters(txPackets: txP, txBytes: txB, txHeaderBytes: hdr, txRetransmittedPackets: retx,
                                rxPackets: rxP, rxBytes: rxB)
    }

    // MARK: - Window line

    func test_windowLineIsTheDeltasOfTheSixCounters() {
        let a = counters(txP: 94, txB: 9_990, hdr: 1_128, retx: 1, rxP: 34, rxB: 9_000)
        let b = counters(txP: 177, txB: 32_400, hdr: 2_124, retx: 1, rxP: 118, rxB: 31_680)
        XCTAssertEqual(AudioWireLines.windowLine(winMs: 5_004, previous: a, current: b),
                       "audiowire win_ms=5004 tx_pkts=83 tx_bytes=22410 tx_hdr_bytes=996 tx_retx_pkts=0 rx_pkts=84 rx_bytes=22680")
    }

    func test_aCounterThatWentBackwardsOrIsMissingIsOmittedNotPrintedAsNegative() {
        let a = counters(txP: 500, txB: 100_000, hdr: -1, retx: 3, rxP: 200, rxB: 50_000)
        let b = counters(txP: 10, txB: 120_000, hdr: 900, retx: 3, rxP: 283, rxB: 72_000)
        let line = AudioWireLines.windowLine(winMs: 5_000, previous: a, current: b)
        XCTAssertEqual(line, "audiowire win_ms=5000 tx_bytes=20000 tx_retx_pkts=0 rx_pkts=83 rx_bytes=22000")
        XCTAssertFalse(line.contains("-"), line)
    }

    func test_theLineCarriesNothingButNumbersAndTheFixedWords() {
        let line = AudioWireLines.windowLine(winMs: 5_000,
                                             previous: counters(txP: 0, txB: 0, hdr: 0, retx: 0, rxP: 0, rxB: 0),
                                             current: counters(txP: 83, txB: 22_410, hdr: 996, retx: 0, rxP: 83, rxB: 22_410))
        let words = line.split(separator: " ").dropFirst()
        for token in words {
            let parts = token.split(separator: "=")
            XCTAssertEqual(parts.count, 2, "\(token)")
            XCTAssertNotNil(Int(parts[1]), "\(token)")
        }
    }

    // MARK: - Reporter

    func test_theFirstHeartbeatOnlyTakesTheBaseline() {
        var reporter = AudioWireLines.Reporter()
        XCTAssertEqual(reporter.lines(counters: counters(txP: 10, txB: 2_700, hdr: 120, retx: 0, rxP: 10, rxB: 2_700),
                                      capturedAtMs: 5_000, codec: nil), [])
    }

    func test_eachLaterReportIsOneWindowBoundedByTheCaptureStampsOfTwoReports() {
        var reporter = AudioWireLines.Reporter()
        _ = reporter.lines(counters: counters(txP: 10, txB: 2_700, hdr: 120, retx: 0, rxP: 10, rxB: 2_700),
                           capturedAtMs: 5_000, codec: nil)
        let second = reporter.lines(counters: counters(txP: 93, txB: 25_110, hdr: 1_116, retx: 0, rxP: 94, rxB: 25_380),
                                    capturedAtMs: 10_012, codec: nil)
        XCTAssertEqual(second, ["audiowire win_ms=5012 tx_pkts=83 tx_bytes=22410 tx_hdr_bytes=996 tx_retx_pkts=0 rx_pkts=84 rx_bytes=22680"])
    }

    func test_aReportWhoseStampDidNotAdvanceWritesNoWindowAndKeepsTheBaseline() {
        var reporter = AudioWireLines.Reporter()
        let first = counters(txP: 10, txB: 2_700, hdr: 120, retx: 0, rxP: 10, rxB: 2_700)
        _ = reporter.lines(counters: first, capturedAtMs: 5_000, codec: nil)
        // The stats poll delivered nothing new: the heartbeat reads the very same report (same stamp, same counters).
        XCTAssertEqual(reporter.lines(counters: first, capturedAtMs: 5_000, codec: nil), [], "no window of zeros")
        // A stamp that went backwards is not a report either.
        XCTAssertEqual(reporter.lines(counters: first, capturedAtMs: 4_000, codec: nil), [])
        // The next real report spans the whole time since the baseline.
        let later = reporter.lines(counters: counters(txP: 176, txB: 47_520, hdr: 2_112, retx: 0, rxP: 177, rxB: 47_790),
                                   capturedAtMs: 15_020, codec: nil)
        XCTAssertEqual(later, ["audiowire win_ms=10020 tx_pkts=166 tx_bytes=44820 tx_hdr_bytes=1992 tx_retx_pkts=0 rx_pkts=167 rx_bytes=45090"])
    }

    func test_noReportYetTakesNoBaselineAndWritesNoWindow() {
        var reporter = AudioWireLines.Reporter()
        let empty = counters(txP: -1, txB: -1, hdr: -1, retx: -1, rxP: -1, rxB: -1)
        XCTAssertEqual(reporter.lines(counters: empty, capturedAtMs: -1, codec: nil), [])
        XCTAssertEqual(reporter.lines(counters: empty, capturedAtMs: -1, codec: nil), [])
        // The first real report is the baseline, not a window against the empty one.
        XCTAssertEqual(reporter.lines(counters: counters(txP: 10, txB: 2_700, hdr: 120, retx: 0, rxP: 10, rxB: 2_700),
                                      capturedAtMs: 7_000, codec: nil), [])
    }

    func test_theCodecLineComesOncePerNegotiationAndAgainWhenItChanges() throws {
        let sdp = AudioWireLines.SdpFacts(ptime: 60, maxptime: 60, audioLevel: 0, transportCc: 0)
        let codec = try XCTUnwrap(AudioWireLines.codec(
            sendFmtp: "minptime=60;useinbandfec=1;cbr=1;maxaveragebitrate=32000;stereo=0", sdp: sdp))
        var reporter = AudioWireLines.Reporter()
        let c = counters(txP: 0, txB: 0, hdr: 0, retx: 0, rxP: 0, rxB: 0)
        let first = reporter.lines(counters: c, capturedAtMs: 5_000, codec: codec)
        XCTAssertEqual(first, ["audiowire codec ptime=60 minptime=60 maxptime=60 cbr=1 fec=1 dtx=0 maxavg=32000 stereo=0 alevel=0 tcc=0"])
        XCTAssertEqual(reporter.lines(counters: c, capturedAtMs: 10_000, codec: codec).count, 1, "only the window line")
        let renegotiated = AudioWireLines.codec(sendFmtp: "minptime=60;useinbandfec=1;cbr=1;maxaveragebitrate=32000;stereo=0",
                                                sdp: AudioWireLines.SdpFacts(ptime: 60, maxptime: 60, audioLevel: 1, transportCc: 1))
        let again = reporter.lines(counters: c, capturedAtMs: 15_000, codec: renegotiated)
        XCTAssertEqual(again.count, 2)
        XCTAssertTrue(again[0].hasSuffix("alevel=1 tcc=1"), again[0])
    }

    func test_resetStartsAFreshBaselineAndReportsTheCodecAgain() throws {
        let sdp = AudioWireLines.SdpFacts(ptime: 60, maxptime: 60, audioLevel: 0, transportCc: 0)
        let codec = try XCTUnwrap(AudioWireLines.codec(sendFmtp: "minptime=60;useinbandfec=1;cbr=1", sdp: sdp))
        var reporter = AudioWireLines.Reporter()
        let c = counters(txP: 0, txB: 0, hdr: 0, retx: 0, rxP: 0, rxB: 0)
        _ = reporter.lines(counters: c, capturedAtMs: 5_000, codec: codec)
        reporter.reset()
        let lines = reporter.lines(counters: c, capturedAtMs: 6_000, codec: codec)
        XCTAssertEqual(lines.count, 1, "codec line again, no window yet")
        XCTAssertTrue(lines[0].hasPrefix("audiowire codec"))
    }

    // MARK: - Codec

    func test_fmtpParsingReadsTheSendSideOpusParameters() {
        let f = AudioWireLines.parseFmtp("a=fmtp:111 minptime=60;useinbandfec=1;usedtx=1;cbr=1;maxaveragebitrate=32000;stereo=1")
        XCTAssertEqual(f, AudioWireLines.Fmtp(minptime: 60, cbr: 1, fec: 1, dtx: 1, maxAverageBitrate: 32_000, stereo: 1))
    }

    func test_aFlagThatIsNotInTheFmtpIsOffAndANumberThatIsNotThereIsMissing() {
        let f = AudioWireLines.parseFmtp("minptime=10;useinbandfec=0")
        XCTAssertEqual(f, AudioWireLines.Fmtp(minptime: 10, cbr: 0, fec: 0, dtx: 0, maxAverageBitrate: -1, stereo: 0))
        let line = AudioWireLines.codecLine(AudioWireLines.Codec(
            ptime: -1, minptime: 10, maxptime: -1, cbr: 0, fec: 0, dtx: 0, maxAverageBitrate: -1, stereo: 0, audioLevel: 0, transportCc: 0))
        XCTAssertEqual(line, "audiowire codec minptime=10 cbr=0 fec=0 dtx=0 stereo=0 alevel=0 tcc=0")
    }

    func test_noCodecUntilBothTheFmtpAndTheSdpAreKnown() {
        let sdp = AudioWireLines.SdpFacts(ptime: 60, maxptime: 60, audioLevel: 0, transportCc: 0)
        XCTAssertNil(AudioWireLines.codec(sendFmtp: nil, sdp: sdp))
        XCTAssertNil(AudioWireLines.codec(sendFmtp: "", sdp: sdp))
        XCTAssertNil(AudioWireLines.codec(sendFmtp: "cbr=1", sdp: nil))
    }

    // MARK: - SDP facts

    private func sdp(extmaps: [String], ptime: Bool = true) -> String {
        var lines: [String] = ["v=0", "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=mid:0"]
        lines += extmaps
        lines += ["a=rtpmap:111 opus/48000/2", "a=fmtp:111 minptime=60;useinbandfec=1"]
        if ptime { lines += ["a=ptime:60", "a=maxptime:60"] }
        lines += ["m=video 9 UDP/TLS/RTP/SAVPF 96", "a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private let level = "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level"
    private let tcc = "a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"
    private let tcc02 = "a=extmap:5 http://www.webrtc.org/experiments/rtp-hdrext/transport-wide-cc-02"

    func test_theFactsOfTheAudioSectionOnlyNeverTheVideoSections() {
        let facts = AudioWireLines.sdpFacts(local: sdp(extmaps: []), remote: sdp(extmaps: []))
        XCTAssertEqual(facts, AudioWireLines.SdpFacts(ptime: 60, maxptime: 60, audioLevel: 0, transportCc: 0),
                       "the video section's transport-cc is not the audio section's")
    }

    func test_anExtensionIsNegotiatedOnlyWhenBothDescriptionsCarryIt() {
        let both = AudioWireLines.sdpFacts(local: sdp(extmaps: [level, tcc]), remote: sdp(extmaps: [level, tcc02]))
        XCTAssertEqual(both?.audioLevel, 1)
        XCTAssertEqual(both?.transportCc, 1, "either spelling counts")
        let offered = AudioWireLines.sdpFacts(local: sdp(extmaps: [level, tcc]), remote: sdp(extmaps: []))
        XCTAssertEqual(offered?.audioLevel, 0)
        XCTAssertEqual(offered?.transportCc, 0)
    }

    func test_alevelIsOneForEverySpeechLevelFormAndTccForEitherTransportWideCcUri() {
        let csrc = "a=extmap:2 urn:ietf:params:rtp-hdrext:csrc-audio-level"
        let wrapped = "a=extmap:1 urn:ietf:params:rtp-hdrext:encrypt urn:ietf:params:rtp-hdrext:ssrc-audio-level"
        for line in [level, csrc, wrapped, "a=extmap:1/sendrecv urn:ietf:params:rtp-hdrext:ssrc-audio-level"] {
            let facts = AudioWireLines.sdpFacts(local: sdp(extmaps: [line]), remote: sdp(extmaps: [line]))
            XCTAssertEqual(facts?.audioLevel, 1, line)
            XCTAssertEqual(facts?.transportCc, 0, line)
        }
        for line in [tcc, tcc02] {
            let facts = AudioWireLines.sdpFacts(local: sdp(extmaps: [line]), remote: sdp(extmaps: [line]))
            XCTAssertEqual(facts?.transportCc, 1, line)
            XCTAssertEqual(facts?.audioLevel, 0, line)
        }
        // Other header extensions are neither.
        let mid = "a=extmap:4 urn:ietf:params:rtp-hdrext:sdes:mid"
        let other = AudioWireLines.sdpFacts(local: sdp(extmaps: [mid]), remote: sdp(extmaps: [mid]))
        XCTAssertEqual(other?.audioLevel, 0)
        XCTAssertEqual(other?.transportCc, 0)
    }

    func test_afterThePolicyAPlainLevelAndTheTransportWideCcAreGoneAndOnlyAWrappedLevelRemains() {
        let extmaps = [level, tcc, tcc02, "a=extmap:6 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time"]
        let plain = AudioSdpPolicy.apply(sdp(extmaps: extmaps))
        let facts = AudioWireLines.sdpFacts(local: plain, remote: plain)
        XCTAssertEqual(facts?.audioLevel, 0)
        XCTAssertEqual(facts?.transportCc, 0, "the video section's transport-wide-cc is not the audio section's")

        let wrapped = AudioSdpPolicy.apply(sdp(extmaps: ["a=extmap:1 urn:ietf:params:rtp-hdrext:encrypt urn:ietf:params:rtp-hdrext:ssrc-audio-level", tcc]))
        let wrappedFacts = AudioWireLines.sdpFacts(local: wrapped, remote: wrapped)
        XCTAssertEqual(wrappedFacts?.audioLevel, 1, "a speech level in the wrapped form is still a speech level")
        XCTAssertEqual(wrappedFacts?.transportCc, 0)
    }

    func test_withOnlyOneDescriptionThatOneDecides() {
        XCTAssertEqual(AudioWireLines.sdpFacts(local: sdp(extmaps: [level]), remote: nil)?.audioLevel, 1)
        XCTAssertEqual(AudioWireLines.sdpFacts(local: nil, remote: sdp(extmaps: [tcc]))?.transportCc, 1)
        XCTAssertNil(AudioWireLines.sdpFacts(local: nil, remote: nil))
        XCTAssertNil(AudioWireLines.sdpFacts(local: "v=0\r\nm=video 9 X 96\r\n", remote: nil))
    }

    func test_thePacketTimesAreWhatTheRemoteAsksOfOurSender() {
        let local = sdp(extmaps: [], ptime: false)
        let remote = sdp(extmaps: [])
        XCTAssertEqual(AudioWireLines.sdpFacts(local: local, remote: remote)?.ptime, 60)
        XCTAssertEqual(AudioWireLines.sdpFacts(local: local, remote: nil)?.ptime, -1, "absent stays absent")
    }

    func test_anAudioSectionAfterTheVideoOneAndAnOpuslessOneAreHandled() {
        let late = ["v=0", "m=video 9 X 96", "a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01",
                    "m=audio 9 X 0", "a=rtpmap:0 PCMU/8000", level,
                    "m=audio 9 X 111", "a=rtpmap:111 opus/48000/2", "a=ptime:60"].joined(separator: "\r\n") + "\r\n"
        let facts = AudioWireLines.sdpFacts(local: late, remote: nil)
        XCTAssertEqual(facts?.ptime, 60)
        XCTAssertEqual(facts?.audioLevel, 0, "the level belongs to the PCMU section, not the Opus one")
    }

    // MARK: - Sender parameters

    func test_senderCapLineShape() {
        XCTAssertEqual(AudioWireLines.senderCapLine(encodings: 1, minBps: 32_000, maxBps: 32_000, adaptivePacketTime: 0,
                                                    priority: 4, ok: true, source: 1),
                       "audiosrtp cap n=1 min=32000 max=32000 apt=0 prio=4 ok=1 src=1")
        XCTAssertEqual(AudioWireLines.senderCapLine(encodings: 0, minBps: -1, maxBps: -1, adaptivePacketTime: -1,
                                                    priority: -1, ok: false, source: 2),
                       "audiosrtp cap n=0 ok=0 src=2")
    }

    // MARK: - Group line

    func test_groupAudioSenderLineShape() {
        XCTAssertEqual(GroupDiagnostics.audioSenderLine(encodings: 1, minBps: 32_000, maxBps: 32_000, adaptivePacketTime: 0, ok: true),
                       "grp audio cap n=1 min=32000 max=32000 apt=0 ok=1")
        XCTAssertEqual(GroupDiagnostics.audioSenderLine(encodings: 1, minBps: -1, maxBps: -1, adaptivePacketTime: -1, ok: false),
                       "grp audio cap n=1 min=0 max=0 apt=0 ok=0")
        // A sender that has no encoding yet still reports, with the same shape.
        XCTAssertEqual(GroupDiagnostics.audioSenderLine(encodings: 0, minBps: -1, maxBps: -1, adaptivePacketTime: -1, ok: false),
                       "grp audio cap n=0 min=0 max=0 apt=0 ok=0")
    }
}
