import XCTest
@testable import QAudionEngine

final class GroupSdpRulesTests: XCTestCase {

    private let pinned = GroupCallFixtures.fingerprint("AB")

    private func fingerprintLine(_ pair: String) -> String {
        "a=fingerprint:sha-256 " + Array(repeating: pair, count: 32).joined(separator: ":")
    }

    private func sdp(fingerprint: String? = nil, setup: String = "a=setup:active") -> String {
        [
            "v=0",
            "o=- 4611731400430051336 2 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "a=group:BUNDLE 0 1",
            "a=extmap-allow-mixed",
            fingerprint ?? fingerprintLine("AB"),
            "m=audio 9 UDP/TLS/RTP/SAVPF 111 63 110",
            "c=IN IP4 0.0.0.0",
            "a=mid:0",
            "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level",
            "a=extmap:2 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01",
            "a=extmap:3 urn:ietf:params:rtp-hdrext:sdes:mid",
            setup,
            "a=rtpmap:111 opus/48000/2",
            "a=rtcp-fb:111 transport-cc",
            "a=fmtp:111 minptime=10;useinbandfec=1;usedtx=1",
            "a=rtpmap:63 red/48000/2",
            "a=fmtp:63 111/111",
            "a=rtpmap:110 telephone-event/48000",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "c=IN IP4 0.0.0.0",
            "a=mid:1",
            "a=extmap:4 http://www.webrtc.org/experiments/rtp-hdrext/abs-capture-time",
            "a=extmap:5 urn:3gpp:video-orientation",
            "a=extmap:6 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time",
            "a=extmap:7 urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id",
            "a=extmap:8 urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id",
            "a=rtpmap:96 VP8/90000",
            "",
        ].joined(separator: "\r\n")
    }

    // MARK: fingerprint

    func testNormalizeFingerprint() {
        let lower = "SHA-256 " + Array(repeating: "ab", count: 32).joined(separator: ":")
        XCTAssertEqual(GroupSdpRules.normalizeFingerprint(lower), pinned)
        XCTAssertEqual(GroupSdpRules.normalizeFingerprint("a=fingerprint:" + lower), pinned)
        XCTAssertNil(GroupSdpRules.normalizeFingerprint("sha-1 AB:CD"))
        XCTAssertNil(GroupSdpRules.normalizeFingerprint("sha-256 AB:CD"), "too short")
        XCTAssertNil(GroupSdpRules.normalizeFingerprint("sha-256 " + Array(repeating: "ZZ", count: 32).joined(separator: ":")))
        XCTAssertNil(GroupSdpRules.normalizeFingerprint("sha-256 " + Array(repeating: "A", count: 32).joined(separator: ":")))
    }

    func testPinMatchesSessionLevelFingerprint() {
        XCTAssertEqual(GroupSdpRules.checkPin(sdp: sdp(), expected: pinned), .match)
    }

    func testPinMismatch() {
        XCTAssertEqual(GroupSdpRules.checkPin(sdp: sdp(fingerprint: fingerprintLine("CD")), expected: pinned), .mismatch)
    }

    func testPinRequiresEveryFingerprintToMatch() {
        let extra = sdp() + fingerprintLine("CD") + "\r\n"
        XCTAssertEqual(GroupSdpRules.checkPin(sdp: extra, expected: pinned), .mismatch,
                       "a second, different fingerprint (e.g. per m-line) must not slip through")
    }

    func testPinMissingWhenTheSdpHasNoFingerprint() {
        let bare = sdp().replacingOccurrences(of: fingerprintLine("AB") + "\r\n", with: "")
        XCTAssertEqual(GroupSdpRules.checkPin(sdp: bare, expected: pinned), .missing)
    }

    func testPinAgainstAMalformedExpectedValueIsAMismatch() {
        XCTAssertEqual(GroupSdpRules.checkPin(sdp: sdp(), expected: "garbage"), .mismatch)
    }

    func testPinIgnoresCaseOfTheHexInTheSdp() {
        XCTAssertEqual(GroupSdpRules.checkPin(sdp: sdp(fingerprint: fingerprintLine("ab")), expected: pinned), .match)
    }

    // MARK: header extensions

    func testStripRemovesTheThreeNamedExtensionsAndEverythingNotAllowed() {
        let out = GroupSdpRules.stripHeaderExtensions(sdp())
        for uri in GroupSdpRules.namedRemovedExtmapUris { XCTAssertFalse(out.contains(uri), uri) }
        XCTAssertFalse(out.contains("abs-send-time"), "an extension nobody asked to keep is not negotiated either")
        XCTAssertTrue(GroupSdpRules.disallowedExtensions(in: out).isEmpty)
    }

    func testStripKeepsMidRidRepairedRidAndTransportWideCc() {
        let out = GroupSdpRules.stripHeaderExtensions(sdp())
        XCTAssertTrue(out.contains("a=extmap:3 urn:ietf:params:rtp-hdrext:sdes:mid"))
        XCTAssertTrue(out.contains("urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id"))
        XCTAssertTrue(out.contains("urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id"))
        XCTAssertTrue(out.contains("draft-holmer-rmcat-transport-wide-cc-extensions-01"))
        XCTAssertTrue(out.contains("a=extmap-allow-mixed"), "not an extmap line, must stay")
    }

    func testStripHandlesDirectionSuffixedExtmapAndIsIdempotent() {
        let input = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=extmap:1/sendonly urn:ietf:params:rtp-hdrext:ssrc-audio-level\r\na=extmap:2/recvonly urn:ietf:params:rtp-hdrext:sdes:mid\r\n"
        let once = GroupSdpRules.stripHeaderExtensions(input)
        XCTAssertFalse(once.contains("ssrc-audio-level"))
        XCTAssertTrue(once.contains("sdes:mid"))
        XCTAssertEqual(GroupSdpRules.stripHeaderExtensions(once), once)
    }

    // MARK: audio profile

    func testAudioProfileIsTheOneToOneProfilePlusExplicitDtxAndStereoOff() throws {
        let out = GroupSdpRules.applyAudioProfile(sdp())
        let fmtp = try XCTUnwrap(out.components(separatedBy: "\r\n").first { $0.hasPrefix("a=fmtp:111 ") })
        let params = Set(fmtp.dropFirst("a=fmtp:111 ".count).split(separator: ";").map(String.init))
        XCTAssertTrue(params.contains("usedtx=0"), fmtp)
        XCTAssertTrue(params.contains("stereo=0"), fmtp)
        XCTAssertTrue(params.contains("cbr=1"), fmtp)
        XCTAssertTrue(params.contains("useinbandfec=1"), fmtp)
        XCTAssertTrue(params.contains("maxaveragebitrate=32000"), fmtp)
        XCTAssertTrue(params.contains("minptime=60"), fmtp)
        XCTAssertFalse(params.contains("usedtx=1"), fmtp)
        XCTAssertTrue(out.contains("a=ptime:60"))
    }

    func testAudioProfileDropsRedAndOtherNonOpusAudioPayloads() {
        let out = GroupSdpRules.applyAudioProfile(sdp())
        XCTAssertFalse(out.contains("red/48000"))
        XCTAssertFalse(out.contains("telephone-event"))
        XCTAssertTrue(out.contains("opus/48000/2"))
    }

    func testAudioProfileWithoutAudioIsUnchangedInSubstance() {
        let videoOnly = "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 VP8/90000\r\na=mid:0\r\n"
        XCTAssertEqual(GroupSdpRules.applyAudioProfile(videoOnly), videoOnly)
    }

    // MARK: DTLS role

    func testForcePassiveSetupOnlyRewritesActive() {
        let out = GroupSdpRules.forcePassiveSetup(inAnswer: sdp())
        XCTAssertTrue(out.contains("a=setup:passive"))
        XCTAssertFalse(out.contains("a=setup:active"))
        let untouched = GroupSdpRules.forcePassiveSetup(inAnswer: sdp(setup: "a=setup:actpass"))
        XCTAssertTrue(untouched.contains("a=setup:actpass"))
    }

    // MARK: composition

    func testPublisherOfferIsStrippedAndProfiledButKeepsItsDtlsRole() {
        let out = GroupSdpRules.mungeLocal(sdp(setup: "a=setup:actpass"), role: .publisherOffer)
        XCTAssertTrue(out.contains("a=setup:actpass"))
        XCTAssertTrue(GroupSdpRules.disallowedExtensions(in: out).isEmpty)
        XCTAssertTrue(out.contains("usedtx=0"))
    }

    func testSubscriberAnswerAnswersPassive() {
        let out = GroupSdpRules.mungeLocal(sdp(), role: .subscriberAnswer)
        XCTAssertTrue(out.contains("a=setup:passive"))
        XCTAssertTrue(GroupSdpRules.disallowedExtensions(in: out).isEmpty)
    }

    func testMungeLocalIsIdempotent() {
        let once = GroupSdpRules.mungeLocal(sdp(), role: .subscriberAnswer)
        XCTAssertEqual(GroupSdpRules.mungeLocal(once, role: .subscriberAnswer), once)
    }

    func testMungeRemoteKeepsTheFingerprintUntouched() {
        XCTAssertEqual(GroupSdpRules.checkPin(sdp: GroupSdpRules.mungeRemote(sdp()), expected: pinned), .match)
    }

    func testVideoMidsInOrder() {
        XCTAssertEqual(GroupSdpRules.videoMids(in: sdp()), ["1"])
        let two = sdp() + "m=video 9 UDP/TLS/RTP/SAVPF 96\r\na=mid:2\r\n"
        XCTAssertEqual(GroupSdpRules.videoMids(in: two), ["1", "2"])
        XCTAssertEqual(GroupSdpRules.videoMids(in: "v=0\r\nm=audio 9 X 111\r\na=mid:0\r\n"), [])
    }
}
