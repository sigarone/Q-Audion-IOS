import XCTest
@testable import QAudionEngine

/// W-NATIVEAUDIOQUALITY (this task, spec section D) — mono/fullband Opus
/// fmtp keys + NACK, additive on top of ``AudioSdpPolicy``, applied ONLY
/// when native SRTP is enabled for the call.
final class NativeAudioSdpPolicyTests: XCTestCase {

    private let typicalSdp: String = [
        "v=0",
        "o=- 4611731400430051336 2 IN IP4 127.0.0.1",
        "s=-",
        "t=0 0",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111 63 9 0 8 13 110 126",
        "c=IN IP4 0.0.0.0",
        "a=rtpmap:111 opus/48000/2",
        "a=rtcp-fb:111 transport-cc",
        "a=fmtp:111 cbr=1;useinbandfec=1;maxaveragebitrate=32000;minptime=60",
        "a=ptime:60",
        "a=maxptime:60",
        "a=rtpmap:63 red/48000/2",
        "a=fmtp:63 111/111",
        "m=video 9 UDP/TLS/RTP/SAVPF 96 97",
        "a=rtpmap:96 H265/90000",
        "a=fmtp:96 level-id=93",
    ].joined(separator: "\r\n") + "\r\n"

    private func audioFmtp111(_ sdp: String) -> String {
        sdp.components(separatedBy: "\r\n").first { $0.hasPrefix("a=fmtp:111 ") } ?? ""
    }

    /// Lines of the FIRST m=audio section (exclusive of the next m=).
    private func audioSection(_ sdp: String) -> [String] {
        let lines = sdp.components(separatedBy: "\r\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("m=audio") }) else { return [] }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.endIndex
        return Array(lines[start..<end])
    }

    // MARK: - Off switch: byte-for-byte no-op when native SRTP is disabled

    func test_disabled_returnsSdpUnchanged() {
        XCTAssertEqual(NativeAudioSdpPolicy.apply(typicalSdp, nativeSrtpEnabled: false), typicalSdp)
    }

    func test_disabled_evenWithNoOpusSection_returnsUnchanged() {
        let videoOnly = ["v=0", "m=video 9 UDP/TLS/RTP/SAVPF 96", "a=rtpmap:96 H265/90000"]
            .joined(separator: "\r\n") + "\r\n"
        XCTAssertEqual(NativeAudioSdpPolicy.apply(videoOnly, nativeSrtpEnabled: false), videoOnly)
        XCTAssertEqual(NativeAudioSdpPolicy.apply(videoOnly, nativeSrtpEnabled: true), videoOnly)
    }

    // MARK: - Enabled: mono/fullband fmtp keys

    func test_enabled_addsMonoAndFullbandKeys() {
        let out = NativeAudioSdpPolicy.apply(typicalSdp, nativeSrtpEnabled: true)
        let fmtp = audioFmtp111(out)
        XCTAssertTrue(fmtp.contains("stereo=0"), "stereo=0 missing: \(fmtp)")
        XCTAssertTrue(fmtp.contains("sprop-stereo=0"), "sprop-stereo=0 missing: \(fmtp)")
        XCTAssertTrue(fmtp.contains("maxplaybackrate=48000"), "maxplaybackrate missing: \(fmtp)")
        XCTAssertTrue(fmtp.contains("sprop-maxcapturerate=48000"), "sprop-maxcapturerate missing: \(fmtp)")
    }

    func test_enabled_neverTouchesTheKeysAudioSdpPolicyOwns() {
        // Byte-for-byte preservation of AudioSdpPolicy's own keys AND the
        // bare ptime/maxptime lines — this file is additive only.
        let out = NativeAudioSdpPolicy.apply(typicalSdp, nativeSrtpEnabled: true)
        let fmtp = audioFmtp111(out)
        XCTAssertTrue(fmtp.contains("cbr=1"))
        XCTAssertTrue(fmtp.contains("useinbandfec=1"))
        XCTAssertTrue(fmtp.contains("maxaveragebitrate=32000"))
        XCTAssertTrue(fmtp.contains("minptime=60"))
        let audio = audioSection(out)
        XCTAssertEqual(audio.filter { $0 == "a=ptime:60" }.count, 1)
        XCTAssertEqual(audio.filter { $0 == "a=maxptime:60" }.count, 1)
    }

    func test_enabled_overwritesAPreExistingStereoValue() {
        let withStereo = typicalSdp.replacingOccurrences(
            of: "a=fmtp:111 cbr=1;useinbandfec=1;maxaveragebitrate=32000;minptime=60",
            with: "a=fmtp:111 cbr=1;useinbandfec=1;maxaveragebitrate=32000;minptime=60;stereo=1")
        let out = NativeAudioSdpPolicy.apply(withStereo, nativeSrtpEnabled: true)
        let fmtp = audioFmtp111(out)
        XCTAssertTrue(fmtp.contains("stereo=0"))
        XCTAssertFalse(fmtp.contains("stereo=1"))
    }

    func test_enabled_doesNotTouchVideoOrTheRedFmtp() {
        let out = NativeAudioSdpPolicy.apply(typicalSdp, nativeSrtpEnabled: true)
        let lines = out.components(separatedBy: "\r\n")
        XCTAssertTrue(lines.contains("a=fmtp:96 level-id=93"))
        XCTAssertTrue(lines.contains("a=fmtp:63 111/111"))
    }

    // MARK: - Enabled: NACK

    func test_enabled_addsNackForTheOpusPayloadType() {
        let out = NativeAudioSdpPolicy.apply(typicalSdp, nativeSrtpEnabled: true)
        let audio = audioSection(out)
        XCTAssertTrue(audio.contains("a=rtcp-fb:111 nack"), "nack missing: \(audio)")
    }

    func test_enabled_keepsExistingTransportCcAlongsideNack() {
        let out = NativeAudioSdpPolicy.apply(typicalSdp, nativeSrtpEnabled: true)
        let audio = audioSection(out)
        XCTAssertTrue(audio.contains("a=rtcp-fb:111 transport-cc"))
        XCTAssertTrue(audio.contains("a=rtcp-fb:111 nack"))
    }

    func test_enabled_doesNotDuplicateAnAlreadyPresentNack() {
        let withNack = typicalSdp.replacingOccurrences(
            of: "a=rtcp-fb:111 transport-cc",
            with: "a=rtcp-fb:111 transport-cc\r\na=rtcp-fb:111 nack")
        let out = NativeAudioSdpPolicy.apply(withNack, nativeSrtpEnabled: true)
        let audio = audioSection(out)
        XCTAssertEqual(audio.filter { $0 == "a=rtcp-fb:111 nack" }.count, 1)
    }

    func test_enabled_nackLandsInsideTheAudioSectionNeverInVideo() {
        let out = NativeAudioSdpPolicy.apply(typicalSdp, nativeSrtpEnabled: true)
        let lines = out.components(separatedBy: "\r\n")
        guard let videoIdx = lines.firstIndex(where: { $0.hasPrefix("m=video") }) else {
            return XCTFail("no video section")
        }
        XCTAssertEqual(lines[videoIdx...].filter { $0.contains("nack") }.count, 0)
    }

    // MARK: - Idempotency

    func test_enabled_idempotent_applyingTwiceEqualsApplyingOnce() {
        let once = NativeAudioSdpPolicy.apply(typicalSdp, nativeSrtpEnabled: true)
        let twice = NativeAudioSdpPolicy.apply(once, nativeSrtpEnabled: true)
        XCTAssertEqual(once, twice)
    }

    // MARK: - Multiple audio sections with DIFFERENT Opus payload types

    func test_twoAudioSectionsWithDifferentOpusPts_eachGetsOnlyItsOwnPt() {
        let twoSections = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 minptime=60",
            "m=audio 9 UDP/TLS/RTP/SAVPF 109",
            "a=rtpmap:109 opus/48000/2",
            "a=fmtp:109 minptime=60",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "a=rtpmap:96 H265/90000",
        ].joined(separator: "\r\n") + "\r\n"
        let out = NativeAudioSdpPolicy.apply(twoSections, nativeSrtpEnabled: true)
        let lines = out.components(separatedBy: "\r\n")
        // Section 0 (pt 111) must NOT gain a phantom line for pt 109, and
        // vice versa.
        guard let secondAudioIdx = lines.firstIndex(where: { $0 == "m=audio 9 UDP/TLS/RTP/SAVPF 109" }),
              let videoIdx = lines.firstIndex(where: { $0.hasPrefix("m=video") }) else {
            return XCTFail("expected sections missing: \(lines)")
        }
        let firstSection = lines[0..<secondAudioIdx]
        let secondSection = lines[secondAudioIdx..<videoIdx]
        XCTAssertEqual(firstSection.filter { $0.contains(":109") }.count, 0,
                       "pt 109 leaked into section 0: \(firstSection)")
        XCTAssertEqual(secondSection.filter { $0.contains(":111") }.count, 0,
                       "pt 111 leaked into section 1: \(secondSection)")
        XCTAssertTrue(firstSection.contains("a=rtcp-fb:111 nack"))
        XCTAssertTrue(secondSection.contains("a=rtcp-fb:109 nack"))
    }

    // MARK: - Synthesis when AudioSdpPolicy has not run first

    func test_enabled_synthesizesFmtpWhenNoneExists() {
        let noFmtp = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=rtpmap:111 opus/48000/2",
        ].joined(separator: "\r\n") + "\r\n"
        let out = NativeAudioSdpPolicy.apply(noFmtp, nativeSrtpEnabled: true)
        let fmtp = audioFmtp111(out)
        XCTAssertTrue(fmtp.contains("stereo=0"))
        XCTAssertTrue(fmtp.contains("maxplaybackrate=48000"))
    }

    func test_sdpWithoutOpusIsReturnedUnchangedEvenWhenEnabled() {
        let noOpus = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 0",
            "a=rtpmap:0 PCMU/8000",
        ].joined(separator: "\r\n") + "\r\n"
        XCTAssertEqual(NativeAudioSdpPolicy.apply(noOpus, nativeSrtpEnabled: true), noOpus)
    }

    func test_loneLfInputStillGetsThePolicyWhenEnabled() {
        let lf = typicalSdp.replacingOccurrences(of: "\r\n", with: "\n")
        let out = NativeAudioSdpPolicy.apply(lf, nativeSrtpEnabled: true)
        let fmtp = audioFmtp111(out)
        XCTAssertTrue(fmtp.contains("stereo=0"))
    }
}
