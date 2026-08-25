import XCTest
@testable import QAudionEngine

/// IOS-C4b / W-SRTPPTIME — the fixed Opus profile (CBR + in-band FEC +
/// 32 kbps cap, DTX stripped, 60 ms packetization) rewritten into every
/// produced/received SDP's audio fmtp. Pure-string transform, exercised
/// here against realistic libwebrtc-shaped SDP fragments — direct Swift
/// port of Android's `AudioSdpPolicyTest.kt`, same cases, same values.
final class AudioSdpPolicyTests: XCTestCase {

    private let typicalSdp: String = [
        "v=0",
        "o=- 4611731400430051336 2 IN IP4 127.0.0.1",
        "s=-",
        "t=0 0",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111 63 9 0 8 13 110 126",
        "c=IN IP4 0.0.0.0",
        "a=rtpmap:111 opus/48000/2",
        "a=rtcp-fb:111 transport-cc",
        "a=fmtp:111 minptime=10;useinbandfec=1",
        "a=rtpmap:63 red/48000/2",
        "a=fmtp:63 111/111",
        "m=video 9 UDP/TLS/RTP/SAVPF 96 97",
        "a=rtpmap:96 H265/90000",
        "a=fmtp:96 level-id=93",
    ].joined(separator: "\r\n") + "\r\n"

    private func audioFmtp111(_ sdp: String) -> String {
        sdp.components(separatedBy: "\r\n").first { $0.hasPrefix("a=fmtp:111 ") } ?? ""
    }

    func test_appliesCbrFecAndBitrateCapToTheOpusFmtp() {
        let out = AudioSdpPolicy.apply(typicalSdp)
        let fmtp = audioFmtp111(out)
        XCTAssertTrue(fmtp.contains("cbr=1"), "cbr=1 missing: \(fmtp)")
        XCTAssertTrue(fmtp.contains("useinbandfec=1"), "useinbandfec=1 missing: \(fmtp)")
        XCTAssertTrue(fmtp.contains("maxaveragebitrate=\(AudioSdpPolicy.maxAverageBitrateBps)"), "maxaveragebitrate missing: \(fmtp)")
        // W-SRTPPTIME — minptime is POLICY now, not a pass-through: the
        // libwebrtc default of 10 must be overwritten with the long profile.
        XCTAssertTrue(fmtp.contains("minptime=\(AudioSdpPolicy.ptimeMs)"), "minptime not forced to policy: \(fmtp)")
        XCTAssertFalse(fmtp.contains("minptime=10"), "stale minptime=10 survived: \(fmtp)")
    }

    func test_preExistingFmtpParamsThePolicyDoesNotOwnSurvive() {
        let withStereo = typicalSdp.replacingOccurrences(
            of: "a=fmtp:111 minptime=10;useinbandfec=1",
            with: "a=fmtp:111 minptime=10;useinbandfec=1;stereo=0")
        let out = AudioSdpPolicy.apply(withStereo)
        let fmtp = audioFmtp111(out)
        XCTAssertTrue(fmtp.contains("stereo=0"), "stereo=0 lost: \(fmtp)")
    }

    func test_stripsUsedtx() {
        let withDtx = typicalSdp.replacingOccurrences(
            of: "a=fmtp:111 minptime=10;useinbandfec=1",
            with: "a=fmtp:111 minptime=10;useinbandfec=1;usedtx=1")
        let out = AudioSdpPolicy.apply(withDtx)
        let fmtp = audioFmtp111(out)
        XCTAssertFalse(fmtp.contains("usedtx"), "usedtx must be stripped: \(fmtp)")
    }

    func test_doesNotTouchVideoFmtpOrTheRedFmtp() {
        let out = AudioSdpPolicy.apply(typicalSdp)
        let lines = out.components(separatedBy: "\r\n")
        XCTAssertTrue(lines.contains("a=fmtp:96 level-id=93"))
        XCTAssertTrue(lines.contains("a=fmtp:63 111/111"))
    }

    func test_sdpWithoutAnAudioSectionIsReturnedUnchanged() {
        let videoOnly = ["v=0", "m=video 9 UDP/TLS/RTP/SAVPF 96", "a=rtpmap:96 H265/90000"]
            .joined(separator: "\r\n") + "\r\n"
        XCTAssertEqual(videoOnly, AudioSdpPolicy.apply(videoOnly))
    }

    func test_idempotent_applyingTwiceEqualsApplyingOnce() {
        let once = AudioSdpPolicy.apply(typicalSdp)
        XCTAssertEqual(once, AudioSdpPolicy.apply(once))
    }

    func test_existingMaxAverageBitrateIsOverwrittenToThePolicyValue() {
        let withHighRate = typicalSdp.replacingOccurrences(
            of: "a=fmtp:111 minptime=10;useinbandfec=1",
            with: "a=fmtp:111 minptime=10;maxaveragebitrate=510000")
        let out = AudioSdpPolicy.apply(withHighRate)
        let fmtp = audioFmtp111(out)
        XCTAssertTrue(fmtp.contains("maxaveragebitrate=\(AudioSdpPolicy.maxAverageBitrateBps)"))
        XCTAssertFalse(fmtp.contains("510000"))
    }

    func test_synthesizesAnFmtpWhenTheAudioSectionHasNoneForOpus() {
        let noFmtp = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=rtpmap:111 opus/48000/2",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "a=rtpmap:96 H265/90000",
        ].joined(separator: "\r\n") + "\r\n"
        let out = AudioSdpPolicy.apply(noFmtp)
        let lines = out.components(separatedBy: "\r\n")
        guard let rtpmapIdx = lines.firstIndex(of: "a=rtpmap:111 opus/48000/2") else {
            return XCTFail("rtpmap line missing")
        }
        XCTAssertEqual(
            lines[lines.index(after: rtpmapIdx)],
            "a=fmtp:111 cbr=1;useinbandfec=1;maxaveragebitrate=\(AudioSdpPolicy.maxAverageBitrateBps);minptime=\(AudioSdpPolicy.ptimeMs)")
    }

    // MARK: - W-SRTPPTIME — packetization-time policy

    /// Lines of the FIRST m=audio section (exclusive of the next m=).
    private func audioSection(_ sdp: String) -> [String] {
        let lines = sdp.components(separatedBy: "\r\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("m=audio") }) else { return [] }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.endIndex
        return Array(lines[start..<end])
    }

    func test_ptimeAndMaxptimeAreAddedWhenAbsent() {
        let out = AudioSdpPolicy.apply(typicalSdp)
        let audio = audioSection(out)
        XCTAssertEqual(audio.filter { $0 == "a=ptime:\(AudioSdpPolicy.ptimeMs)" }.count, 1)
        XCTAssertEqual(audio.filter { $0 == "a=maxptime:\(AudioSdpPolicy.ptimeMs)" }.count, 1)
    }

    func test_existingPtimeAndMaxptimeAreReplacedWithThePolicyValue() {
        let withPtime = typicalSdp.replacingOccurrences(
            of: "a=fmtp:111 minptime=10;useinbandfec=1",
            with: "a=fmtp:111 minptime=10;useinbandfec=1\r\na=ptime:20\r\na=maxptime:120")
        let out = AudioSdpPolicy.apply(withPtime)
        let audio = audioSection(out)
        XCTAssertEqual(audio.filter { $0 == "a=ptime:20" }.count, 0, "stale ptime survived")
        XCTAssertEqual(audio.filter { $0 == "a=maxptime:120" }.count, 0, "stale maxptime survived")
        XCTAssertEqual(audio.filter { $0 == "a=ptime:\(AudioSdpPolicy.ptimeMs)" }.count, 1)
        XCTAssertEqual(audio.filter { $0 == "a=maxptime:\(AudioSdpPolicy.ptimeMs)" }.count, 1)
    }

    func test_ptimeLinesLandInsideTheAudioSectionNeverInVideo() {
        let out = AudioSdpPolicy.apply(typicalSdp)
        let lines = out.components(separatedBy: "\r\n")
        guard let videoIdx = lines.firstIndex(where: { $0.hasPrefix("m=video") }) else {
            return XCTFail("no video section")
        }
        let videoLines = lines[videoIdx...]
        XCTAssertEqual(videoLines.filter { $0.hasPrefix("a=ptime:") }.count, 0, "ptime leaked into the video section")
        XCTAssertEqual(videoLines.filter { $0.hasPrefix("a=maxptime:") }.count, 0, "maxptime leaked into the video section")
        let beforeVideo = lines[0..<videoIdx]
        XCTAssertEqual(beforeVideo.filter { $0 == "a=ptime:\(AudioSdpPolicy.ptimeMs)" }.count, 1)
    }

    func test_anAudioSectionWithoutOpusGetsNoPtimeLines() {
        let mixed = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 minptime=10",
            "m=audio 9 UDP/TLS/RTP/SAVPF 0",
            "a=rtpmap:0 PCMU/8000",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "a=rtpmap:96 H265/90000",
        ].joined(separator: "\r\n") + "\r\n"
        let out = AudioSdpPolicy.apply(mixed)
        let lines = out.components(separatedBy: "\r\n")
        guard let secondAudio = lines.firstIndex(where: { $0 == "m=audio 9 UDP/TLS/RTP/SAVPF 0" }),
              let video = lines.firstIndex(where: { $0.hasPrefix("m=video") }) else {
            return XCTFail("expected sections missing")
        }
        XCTAssertTrue(secondAudio >= 1 && secondAudio < video)
        // Opus section (before the second m=audio) carries the pair…
        XCTAssertEqual(lines[0..<secondAudio].filter { $0 == "a=ptime:\(AudioSdpPolicy.ptimeMs)" }.count, 1)
        // …the PCMU-only section does not.
        XCTAssertEqual(lines[secondAudio..<video].filter { $0.hasPrefix("a=ptime:") }.count, 0)
        XCTAssertEqual(lines[secondAudio..<video].filter { $0.hasPrefix("a=maxptime:") }.count, 0)
    }

    func test_ptimeMungingIsIdempotent() {
        let once = AudioSdpPolicy.apply(typicalSdp)
        let twice = AudioSdpPolicy.apply(once)
        XCTAssertEqual(once, twice)
        // Belt-and-braces beyond byte equality: exactly one pair, ever.
        let audio = audioSection(twice)
        XCTAssertEqual(audio.filter { $0.hasPrefix("a=ptime:") }.count, 1)
        XCTAssertEqual(audio.filter { $0.hasPrefix("a=maxptime:") }.count, 1)
    }

    func test_loneLfInputStillGetsThePolicy() {
        let lf = typicalSdp.replacingOccurrences(of: "\r\n", with: "\n")
        let out = AudioSdpPolicy.apply(lf)
        let fmtp = audioFmtp111(out)
        XCTAssertTrue(fmtp.contains("cbr=1"))
    }
}
