import XCTest
@testable import QAudionEngine

/// W-NATIVESRTPDIAG — AudioSdpSummary is a pure string transform (no WebRTC
/// dependency), so it is exercised directly here against realistic
/// libwebrtc-shaped SDP fragments, mirroring AudioSdpPolicyTests' own style.
final class AudioSdpSummaryTests: XCTestCase {

    private let typicalSdp: String = [
        "v=0",
        "o=- 4611731400430051336 2 IN IP4 127.0.0.1",
        "s=-",
        "t=0 0",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111 63",
        "c=IN IP4 0.0.0.0",
        "a=ice-ufrag:SECRETUFRAG",
        "a=ice-pwd:SECRETPWDSECRETPWDSECRETPWD",
        "a=fingerprint:sha-256 AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99",
        "a=setup:actpass",
        "a=mid:0",
        "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level",
        "a=extmap:3/recvonly urn:ietf:params:rtp-hdrext:sdes:mid",
        "a=sendrecv",
        "a=rtcp-mux",
        "a=rtpmap:111 opus/48000/2",
        "a=rtcp-fb:111 transport-cc",
        "a=fmtp:111 cbr=1;useinbandfec=1;maxaveragebitrate=32000;minptime=60",
        "a=rtpmap:63 red/48000/2",
        "a=fmtp:63 111/111",
        "a=candidate:1 1 udp 2130706431 10.0.0.1 54321 typ host",
        "m=video 9 UDP/TLS/RTP/SAVPF 96",
        "a=rtpmap:96 H265/90000",
    ].joined(separator: "\r\n") + "\r\n"

    func test_summarizesCodecsFmtpExtmapSetupAndDirection() {
        let summary = AudioSdpSummary.summarize(typicalSdp)
        XCTAssertNotNil(summary)
        let line = summary ?? ""
        XCTAssertTrue(line.hasPrefix("audio "), line)
        // W-NATIVESRTPDIAG — flat, indexed key=value tokens (see this file's
        // own doc for why: every value here is a number or an
        // enum/lowerCamel word under a "type"/"role"/"dir"-suffixed key,
        // the only two shapes the remote log shipper's KV-precision
        // protection trusts).
        XCTAssertTrue(line.contains("c0_type=opus"), line)
        XCTAssertTrue(line.contains("c0_clk=48000"), line)
        XCTAssertTrue(line.contains("c0_ch=2"), line)
        XCTAssertTrue(line.contains("c0_cbr=1"), line)
        XCTAssertTrue(line.contains("c0_useinbandfec=1"), line)
        XCTAssertTrue(line.contains("c0_maxaveragebitrate=32000"), line)
        XCTAssertTrue(line.contains("c0_minptime=60"), line)
        XCTAssertTrue(line.contains("c1_type=red"), line)
        XCTAssertTrue(line.contains("c1_clk=48000"), line)
        XCTAssertTrue(line.contains("c1_ch=2"), line)
        // c1 (red)'s fmtp is "111/111" — not a key=value shape, so exactly
        // the three structural fields above are emitted for it, no fmtp
        // param field ("c1_111" or similar).
        XCTAssertEqual(line.components(separatedBy: "c1_").count - 1, 3, line)
        // The uri is shortened to its last ':'/'/'-separated segment, then
        // lowerCamelized ("ssrc-audio-level" -> "ssrcAudioLevel") to match
        // the shipper's lowerCamel value shape.
        XCTAssertTrue(line.contains("e0_type=ssrcAudioLevel"), line)
        XCTAssertTrue(line.contains("e1_type=mid"), line)
        XCTAssertFalse(line.contains("urn:ietf"), line)
        XCTAssertTrue(line.contains("role=actpass"), line)
        XCTAssertTrue(line.contains("dir=sendrecv"), line)
    }

    func test_neverContainsFingerprintIceCredentialsCandidatesOrIps() {
        let line = AudioSdpSummary.summarize(typicalSdp) ?? ""
        XCTAssertFalse(line.contains("SECRETUFRAG"), line)
        XCTAssertFalse(line.contains("SECRETPWD"), line)
        XCTAssertFalse(line.contains("AA:BB:CC:DD:EE:FF"), line)
        XCTAssertFalse(line.contains("candidate"), line)
        XCTAssertFalse(line.contains("10.0.0.1"), line)
        XCTAssertFalse(line.contains("127.0.0.1"), line)
    }

    func test_sdpWithoutAnAudioSection_returnsNil() {
        let videoOnly = ["v=0", "m=video 9 UDP/TLS/RTP/SAVPF 96", "a=rtpmap:96 H265/90000"]
            .joined(separator: "\r\n") + "\r\n"
        XCTAssertNil(AudioSdpSummary.summarize(videoOnly))
    }

    func test_audioSectionWithNoRecognizedAttributes_returnsNil() {
        let bare = ["v=0", "m=audio 9 UDP/TLS/RTP/SAVPF 111", "c=IN IP4 0.0.0.0"]
            .joined(separator: "\r\n") + "\r\n"
        XCTAssertNil(AudioSdpSummary.summarize(bare))
    }

    func test_onlyReadsTheFirstAudioSection() {
        let twoAudio = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=rtpmap:111 opus/48000/2",
            "a=recvonly",
            "m=audio 9 UDP/TLS/RTP/SAVPF 0",
            "a=rtpmap:0 PCMU/8000",
            "a=sendonly",
        ].joined(separator: "\r\n") + "\r\n"
        let line = AudioSdpSummary.summarize(twoAudio) ?? ""
        XCTAssertTrue(line.contains("c0_type=opus"), line)
        XCTAssertTrue(line.contains("c0_clk=48000"), line)
        XCTAssertTrue(line.contains("dir=recvonly"), line)
        XCTAssertFalse(line.contains("PCMU"), line)
        XCTAssertFalse(line.contains("dir=sendonly"), line)
    }

    func test_lineHasExactlyOneOccurrenceOfEachField() {
        let line = AudioSdpSummary.summarize(typicalSdp) ?? ""
        XCTAssertEqual(line.components(separatedBy: "role=").count - 1, 1, line)
        XCTAssertEqual(line.components(separatedBy: "dir=").count - 1, 1, line)
    }

    /// W-NATIVESRTPDIAG — a non-numeric fmtp value (an unusual/future param)
    /// is dropped rather than emitted in a shape the remote log shipper
    /// might not protect.
    func test_nonNumericFmtpValue_isDropped() {
        let withWordFmtp = typicalSdp.replacingOccurrences(
            of: "a=fmtp:111 cbr=1;useinbandfec=1;maxaveragebitrate=32000;minptime=60",
            with: "a=fmtp:111 cbr=1;stereo=freeform")
        let line = AudioSdpSummary.summarize(withWordFmtp) ?? ""
        XCTAssertTrue(line.contains("c0_cbr=1"), line)
        XCTAssertFalse(line.contains("stereo"), line)
        XCTAssertFalse(line.contains("freeform"), line)
    }
}
