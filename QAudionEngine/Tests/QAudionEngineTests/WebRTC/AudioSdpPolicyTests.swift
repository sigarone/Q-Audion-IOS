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

    // MARK: - Audio header extensions (no speech indicator in the clear, no bandwidth probing on the audio stream)

    private static let levelUri = "urn:ietf:params:rtp-hdrext:ssrc-audio-level"
    private static let absSendTimeUri = "http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time"
    private static let tccUri = "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"
    private static let tcc02Uri = "http://www.webrtc.org/experiments/rtp-hdrext/transport-wide-cc-02"
    private static let midUri = "urn:ietf:params:rtp-hdrext:sdes:mid"
    private static let absCaptureTimeUri = "http://www.webrtc.org/experiments/rtp-hdrext/abs-capture-time"
    private static let fingerprintLine = "a=fingerprint:sha-256 " + Array(repeating: "AB", count: 32).joined(separator: ":")

    /// What libwebrtc writes for an audio + video call: one id per URI across the whole SDP, the audio section with
    /// the level, abs-send-time, transport-cc and mid, the video section with its own bandwidth extensions.
    private func libwebrtcSdp(audioExtras: [String] = [], sessionExtras: [String] = [], videoExtras: [String] = []) -> String {
        var lines: [String] = [
            "v=0",
            "o=- 4611731400430051336 2 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "a=group:BUNDLE 0 1",
            Self.fingerprintLine,
        ]
        lines += sessionExtras
        lines += [
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "c=IN IP4 0.0.0.0",
            "a=mid:0",
            "a=extmap:1 " + Self.levelUri,
            "a=extmap:2 " + Self.absSendTimeUri,
            "a=extmap:3 " + Self.tccUri,
            "a=extmap:4 " + Self.midUri,
            "a=sendrecv",
            "a=rtpmap:111 opus/48000/2",
            "a=rtcp-fb:111 transport-cc",
            "a=rtcp-fb:111 nack",
            "a=fmtp:111 minptime=10;useinbandfec=1",
        ]
        lines += audioExtras
        lines += [
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "c=IN IP4 0.0.0.0",
            "a=mid:1",
            "a=extmap:2 " + Self.absSendTimeUri,
            "a=extmap:3 " + Self.tccUri,
            "a=extmap:4 " + Self.midUri,
            "a=rtpmap:96 H265/90000",
            "a=rtcp-fb:96 transport-cc",
            "a=rtcp-fb:* transport-cc",
            "a=fmtp:96 level-id=93",
        ]
        lines += videoExtras
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private func videoSection(_ sdp: String) -> [String] {
        let lines = sdp.components(separatedBy: "\r\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("m=video") }) else { return [] }
        return Array(lines[start...])
    }

    func test_theAudioSectionLosesTheSpeechIndicatorAndEveryBandwidthExtension() {
        let audio = audioSection(AudioSdpPolicy.apply(libwebrtcSdp()))
        for gone in [Self.levelUri, Self.absSendTimeUri, Self.tccUri] {
            XCTAssertFalse(audio.contains { $0.contains(gone) }, "\(gone) must not be negotiated on audio: \(audio)")
        }
        XCTAssertTrue(audio.contains("a=extmap:4 " + Self.midUri), "mid is not touched")
        XCTAssertTrue(audio.contains("a=mid:0"))
        XCTAssertTrue(audio.contains("a=sendrecv"))
    }

    func test_bothTransportWideCcSpellingsAndToffsetAndCsrcLevelGoToo() {
        let extra = [
            "a=extmap:5 " + Self.tcc02Uri,
            "a=extmap:6 urn:ietf:params:rtp-hdrext:toffset",
            "a=extmap:7 urn:ietf:params:rtp-hdrext:csrc-audio-level",
            "a=extmap:8/sendrecv " + Self.tccUri,
        ]
        let audio = audioSection(AudioSdpPolicy.apply(libwebrtcSdp(audioExtras: extra)))
        XCTAssertEqual(audio.filter { $0.hasPrefix("a=extmap:") }, ["a=extmap:4 " + Self.midUri], "only mid is left: \(audio)")
    }

    func test_theTransportCcFeedbackOfTheOpusPayloadTypeGoesButNackStays() {
        let audio = audioSection(AudioSdpPolicy.apply(libwebrtcSdp()))
        XCTAssertFalse(audio.contains("a=rtcp-fb:111 transport-cc"))
        XCTAssertTrue(audio.contains("a=rtcp-fb:111 nack"), "only the bandwidth feedback is dropped")
    }

    func test_aWildcardTransportCcFeedbackInTheAudioSectionGoesToo() {
        let audio = audioSection(AudioSdpPolicy.apply(libwebrtcSdp(audioExtras: ["a=rtcp-fb:* transport-cc"])))
        XCTAssertFalse(audio.contains("a=rtcp-fb:* transport-cc"))
    }

    func test_theVideoSectionKeepsItsOwnBandwidthExtensionsAndFeedback() {
        let before = videoSection(libwebrtcSdp())
        let after = videoSection(AudioSdpPolicy.apply(libwebrtcSdp()))
        XCTAssertEqual(before, after, "a video upgrade still gets its bandwidth feedback")
        XCTAssertTrue(after.contains("a=extmap:3 " + Self.tccUri))
        XCTAssertTrue(after.contains("a=rtcp-fb:96 transport-cc"))
    }

    func test_anExtensionTheHeaderEncryptionCoversIsKept() {
        // RFC 6904: the extension is carried encrypted, so the level is not in the clear.
        let encryptedLine = "a=extmap:1 urn:ietf:params:rtp-hdrext:encrypt " + Self.levelUri
        let encrypted = libwebrtcSdp().replacingOccurrences(of: "a=extmap:1 " + Self.levelUri, with: encryptedLine)
        let audio = audioSection(AudioSdpPolicy.apply(encrypted))
        XCTAssertTrue(audio.contains(encryptedLine))
        XCTAssertFalse(audio.contains { $0.contains(Self.tccUri) }, "the bandwidth extension goes whatever the encryption")
    }

    func test_cryptexAtMediaOrSessionLevelDoesNotKeepThePlainLevel() {
        // A cryptex line in one description says nothing about what the stream carries: the plain speech level and
        // every bandwidth / capture-time extension go, whatever `a=cryptex` says, at media or session level.
        let extra = ["a=extmap:7 urn:ietf:params:rtp-hdrext:csrc-audio-level", "a=extmap:8 " + Self.absCaptureTimeUri]
        for sdp in [libwebrtcSdp(audioExtras: ["a=cryptex"] + extra), libwebrtcSdp(audioExtras: extra, sessionExtras: ["a=cryptex"])] {
            let audio = audioSection(AudioSdpPolicy.apply(sdp))
            XCTAssertEqual(audio.filter { $0.hasPrefix("a=extmap:") }, ["a=extmap:4 " + Self.midUri],
                           "only mid is left whatever cryptex says: \(audio)")
        }
    }

    func test_onlyTheWrappedFormOfTheSpeechLevelMayStayEvenWithCryptex() {
        let wrappedLine = "a=extmap:1 urn:ietf:params:rtp-hdrext:encrypt " + Self.levelUri
        let sdp = libwebrtcSdp(audioExtras: ["a=cryptex"]).replacingOccurrences(of: "a=extmap:1 " + Self.levelUri, with: wrappedLine)
        let audio = audioSection(AudioSdpPolicy.apply(sdp))
        XCTAssertTrue(audio.contains(wrappedLine))
        XCTAssertFalse(audio.contains { $0.contains(Self.tccUri) })
    }

    func test_absCaptureTimeGoesFromTheAudioSectionAndStaysOnTheVideoSection() {
        let wrapped = "a=extmap:9 urn:ietf:params:rtp-hdrext:encrypt " + Self.absCaptureTimeUri
        let sdp = libwebrtcSdp(audioExtras: ["a=extmap:8 " + Self.absCaptureTimeUri, wrapped],
                               videoExtras: ["a=extmap:8 " + Self.absCaptureTimeUri])
        let out = AudioSdpPolicy.apply(sdp)
        XCTAssertFalse(audioSection(out).contains { $0.contains(Self.absCaptureTimeUri) },
                       "it makes some audio packets larger, plain or wrapped")
        XCTAssertTrue(videoSection(out).contains("a=extmap:8 " + Self.absCaptureTimeUri), "video is untouched")
        XCTAssertEqual(videoSection(sdp).filter { $0.hasPrefix("a=extmap:") }, videoSection(out).filter { $0.hasPrefix("a=extmap:") })
    }

    func test_sessionLevelExtmapLinesAreDroppedOutright() {
        // What a non-libwebrtc remote may send: RFC 8285 would apply these to every section, the audio one included.
        let session = [
            "a=extmap:10 " + Self.tccUri,
            "a=extmap:11 " + Self.levelUri,
            "a=extmap:12 urn:ietf:params:rtp-hdrext:encrypt " + Self.levelUri,
            "a=extmap:13 " + Self.midUri,
            "a=extmap-allow-mixed",
        ]
        let sdp = libwebrtcSdp(sessionExtras: session)
        let out = AudioSdpPolicy.apply(sdp)
        let lines = out.components(separatedBy: "\r\n")
        let head = Array(lines[..<(lines.firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.endIndex)])
        XCTAssertEqual(head.filter { $0.hasPrefix("a=extmap:") }, [], "no session-level extmap survives: \(head)")
        XCTAssertTrue(head.contains("a=extmap-allow-mixed"), "only the extmap lines go")
        XCTAssertTrue(head.contains(Self.fingerprintLine))
        XCTAssertFalse(audioSection(out).contains { $0.contains(Self.tccUri) || $0.contains(Self.levelUri) })
        XCTAssertEqual(videoSection(out), videoSection(libwebrtcSdp()), "the video section is not touched")
    }

    func test_anSdpWithoutAnOpusAudioSectionKeepsItsSessionLevelExtmaps() {
        // No audio stream to protect: the policy does not run at all, as before.
        let videoOnly = ["v=0", "a=extmap:10 " + Self.tccUri, "m=video 9 UDP/TLS/RTP/SAVPF 96", "a=rtpmap:96 VP8/90000"]
            .joined(separator: "\r\n") + "\r\n"
        XCTAssertEqual(AudioSdpPolicy.apply(videoOnly), videoOnly)
    }

    func test_aDirectionSuffixedExtmapIsRecognised() {
        let suffixed = libwebrtcSdp().replacingOccurrences(of: "a=extmap:1 " + Self.levelUri,
                                                           with: "a=extmap:1/sendrecv " + Self.levelUri)
        XCTAssertFalse(audioSection(AudioSdpPolicy.apply(suffixed)).contains { $0.contains(Self.levelUri) })
    }

    func test_anAudioSectionWithoutOpusKeepsItsExtensions() {
        let pcmu = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 0",
            "a=extmap:1 " + Self.levelUri,
            "a=extmap:3 " + Self.tccUri,
            "a=rtpmap:0 PCMU/8000",
            "a=rtcp-fb:0 transport-cc",
        ].joined(separator: "\r\n") + "\r\n"
        XCTAssertEqual(AudioSdpPolicy.apply(pcmu), pcmu)
    }

    func test_theExtensionRulesAreIdempotentAndLeaveTheFingerprintAlone() {
        let once = AudioSdpPolicy.apply(libwebrtcSdp(audioExtras: ["a=extmap:8 " + Self.absCaptureTimeUri],
                                                     sessionExtras: ["a=extmap:10 " + Self.tccUri]))
        XCTAssertEqual(once, AudioSdpPolicy.apply(once))
        XCTAssertTrue(once.components(separatedBy: "\r\n").contains(Self.fingerprintLine),
                      "the signed DTLS fingerprint line is untouched")
    }

    func test_extmapTargetReadsPlainAndEncryptedForms() {
        XCTAssertEqual(AudioSdpPolicy.extmapTarget(of: "a=extmap:1 " + Self.levelUri)?.uri, Self.levelUri)
        XCTAssertEqual(AudioSdpPolicy.extmapTarget(of: "a=extmap:1/sendrecv " + Self.levelUri + " attr")?.uri, Self.levelUri)
        XCTAssertEqual(AudioSdpPolicy.extmapTarget(of: "a=extmap:1 urn:ietf:params:rtp-hdrext:encrypt " + Self.levelUri)?.encrypted, true)
        XCTAssertNil(AudioSdpPolicy.extmapTarget(of: "a=extmap-allow-mixed"))
        XCTAssertNil(AudioSdpPolicy.extmapTarget(of: "a=mid:0"))
    }
}
