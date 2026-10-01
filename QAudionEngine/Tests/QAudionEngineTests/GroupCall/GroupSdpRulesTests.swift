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

    /// Janus 1.4.2 keeps a sticky `disabled` flag per rid: a layer that is inactive in ONE offer
    /// (`~h`) is echoed as `~h` forever, and libwebrtc then switches it off again. The offer never
    /// marks a layer inactive.
    func testAPublisherOfferNeverMarksASimulcastLayerInactive() {
        let offer = [
            "v=0", "o=- 1 2 IN IP4 127.0.0.1", "s=-", "t=0 0",
            "m=video 9 UDP/TLS/RTP/SAVPF 96", "a=mid:1", "a=sendonly", "a=rtpmap:96 VP8/90000",
            "a=rid:l send", "a=rid:m send", "a=rid:h send", "a=simulcast:send l;m;~h",
        ].joined(separator: "\r\n") + "\r\n"
        let out = GroupSdpRules.mungeLocal(offer, role: .publisherOffer)
        XCTAssertTrue(out.contains("a=simulcast:send l;m;h\r\n"), out)
        XCTAssertFalse(out.contains("~"), "no rid is ever offered as inactive")
        XCTAssertTrue(out.contains("a=rid:h send"), "the rid lines themselves are untouched")
        XCTAssertEqual(GroupSdpRules.activateSimulcastLayers(out), out, "idempotent")
    }

    func testSubscriberAnswerAnswersPassive() {
        let out = GroupSdpRules.mungeLocal(sdp(), role: .subscriberAnswer)
        XCTAssertTrue(out.contains("a=setup:passive"))
        XCTAssertTrue(GroupSdpRules.disallowedExtensions(in: out).isEmpty)
    }

    func testMungeLocalIsIdempotentInSubstance() {
        // The 1:1 audio policies place `a=ptime` / `a=rtcp-fb` differently on a second
        // pass, so compare the SET of lines: applying the rules twice changes nothing.
        let once = GroupSdpRules.mungeLocal(sdp(), role: .subscriberAnswer)
        let twice = GroupSdpRules.mungeLocal(once, role: .subscriberAnswer)
        XCTAssertEqual(GroupSdpRules.lines(of: twice).sorted(), GroupSdpRules.lines(of: once).sorted())
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

    // MARK: remote descriptions (spec 12.4)

    /// What qjanus may send back: an answer that echoes the audio-level extension the
    /// offer never had, plus a few more extensions a node could switch on.
    private func janusAnswerWithExtensions() -> String {
        [
            "v=0",
            "o=- 4611731400430051336 2 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "a=group:BUNDLE 0 1",
            "a=extmap-allow-mixed",
            fingerprintLine("AB"),
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "c=IN IP4 0.0.0.0",
            "a=mid:0",
            "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level",
            "a=extmap:3 urn:ietf:params:rtp-hdrext:sdes:mid",
            "a=setup:active",
            "a=rtpmap:111 opus/48000/2",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "c=IN IP4 0.0.0.0",
            "a=mid:1",
            "a=extmap:2 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01",
            "a=extmap:5 urn:3gpp:video-orientation",
            "a=extmap:6 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time",
            "a=extmap:9 http://www.webrtc.org/experiments/rtp-hdrext/playout-delay",
            "a=rtpmap:96 VP8/90000",
            "",
        ].joined(separator: "\r\n")
    }

    func testARemoteAnswerCarryingSsrcAudioLevelIsStrippedOfItBeforeItIsApplied() {
        let answer = janusAnswerWithExtensions()
        XCTAssertTrue(answer.contains("urn:ietf:params:rtp-hdrext:ssrc-audio-level"), "the fixture really carries it")
        let applied = GroupSdpRules.mungeRemote(answer)
        XCTAssertFalse(applied.contains("ssrc-audio-level"))
        XCTAssertTrue(GroupSdpRules.disallowedExtensions(in: applied).isEmpty, "nothing but the allow-list is negotiated")
        for uri in GroupSdpRules.namedRemovedExtmapUris { XCTAssertFalse(applied.contains(uri), uri) }
        XCTAssertFalse(applied.contains("abs-send-time"))
        XCTAssertFalse(applied.contains("playout-delay"))
    }

    func testTheAllowListStaysInTheRemoteDescriptionAndThePinStillChecksTheRawOne() {
        let answer = janusAnswerWithExtensions()
        let applied = GroupSdpRules.mungeRemote(answer)
        XCTAssertTrue(applied.contains("a=extmap:3 urn:ietf:params:rtp-hdrext:sdes:mid"))
        XCTAssertTrue(applied.contains("transport-wide-cc-extensions-01"))
        XCTAssertTrue(applied.contains("a=extmap-allow-mixed"))
        XCTAssertEqual(GroupSdpRules.checkPin(sdp: applied, expected: pinned), .match)
        XCTAssertEqual(GroupSdpRules.checkPin(sdp: answer, expected: pinned), .match)
    }

    func testARemoteOfferGetsTheSameExtensionTreatmentAsALocalOne() {
        let janusOffer = janusAnswerWithExtensions().replacingOccurrences(of: "a=setup:active", with: "a=setup:actpass")
        let remote = GroupSdpRules.mungeRemote(janusOffer)
        let local = GroupSdpRules.mungeLocal(janusOffer, role: .subscriberAnswer)
        XCTAssertEqual(GroupSdpRules.disallowedExtensions(in: remote), [])
        XCTAssertEqual(GroupSdpRules.disallowedExtensions(in: local), [])
        let extmapsOf: (String) -> [String] = { text in GroupSdpRules.lines(of: text).filter { $0.hasPrefix("a=extmap:") }.sorted() }
        XCTAssertEqual(extmapsOf(remote), extmapsOf(local), "one allow-list for both directions")
    }

    // MARK: VP8 only (spec 12.8)

    /// A browser-style video offer: VP8, VP9, H.264, AV1 with their RTX, RED and ULPFEC, in
    /// two video sections with different payload type numbers, and a rejected third one
    /// (Janus spells that `m=video 0 ... 0`).
    private func multiCodecSdp() -> String {
        [
            "v=0",
            "o=- 4611731400430051336 2 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "a=group:BUNDLE 0 1 2 3",
            fingerprintLine("AB"),
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "c=IN IP4 0.0.0.0",
            "a=mid:0",
            "a=rtpmap:111 opus/48000/2",
            "m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99 100 101 102 103 104 105",
            "c=IN IP4 0.0.0.0",
            "a=mid:1",
            "a=extmap:3 urn:ietf:params:rtp-hdrext:sdes:mid",
            "a=rtcp-fb:* transport-cc",
            "a=rtpmap:96 VP8/90000",
            "a=rtcp-fb:96 nack",
            "a=rtcp-fb:96 nack pli",
            "a=rtpmap:97 rtx/90000",
            "a=fmtp:97 apt=96",
            "a=rtpmap:98 VP9/90000",
            "a=fmtp:98 profile-id=0",
            "a=rtcp-fb:98 nack",
            "a=rtpmap:99 rtx/90000",
            "a=fmtp:99 apt=98",
            "a=rtpmap:100 H264/90000",
            "a=fmtp:100 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
            "a=rtcp-fb:100 nack",
            "a=rtpmap:101 rtx/90000",
            "a=fmtp:101 apt=100",
            "a=rtpmap:102 AV1/90000",
            "a=fmtp:102 level-idx=5;profile=0;tier=0",
            "a=rtpmap:103 rtx/90000",
            "a=fmtp:103 apt=102",
            "a=rtpmap:104 red/90000",
            "a=rtpmap:105 ulpfec/90000",
            "m=video 9 UDP/TLS/RTP/SAVPF 120 121 122",
            "c=IN IP4 0.0.0.0",
            "a=mid:2",
            "a=rtpmap:120 vp8/90000",
            "a=rtpmap:121 rtx/90000",
            "a=fmtp:121 apt=120",
            "a=rtpmap:122 H265/90000",
            "a=rtcp-fb:122 nack",
            "m=video 0 UDP/TLS/RTP/SAVPF 0",
            "c=IN IP4 0.0.0.0",
            "a=mid:3",
            "a=inactive",
            "",
        ].joined(separator: "\r\n")
    }

    private func sections(of sdp: String) -> [[String]] {
        var out: [[String]] = []
        for line in GroupSdpRules.lines(of: sdp) {
            if line.hasPrefix("m=") { out.append([line]) } else if !out.isEmpty { out[out.count - 1].append(line) }
        }
        return out
    }

    func testOnlyVp8AndItsRtxSurviveInEveryVideoSection() {
        let out = GroupSdpRules.keepOnlyVp8Video(multiCodecSdp())
        let parts = sections(of: out)
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[1][0], "m=video 9 UDP/TLS/RTP/SAVPF 96 97")
        XCTAssertEqual(parts[2][0], "m=video 9 UDP/TLS/RTP/SAVPF 120 121", "payload types are scoped per section")
        for kept in ["a=rtpmap:96 VP8/90000", "a=rtcp-fb:96 nack", "a=rtcp-fb:96 nack pli", "a=rtpmap:97 rtx/90000", "a=fmtp:97 apt=96",
                     "a=rtcp-fb:* transport-cc", "a=extmap:3 urn:ietf:params:rtp-hdrext:sdes:mid"] {
            XCTAssertTrue(parts[1].contains(kept), kept)
        }
        for kept in ["a=rtpmap:120 vp8/90000", "a=rtpmap:121 rtx/90000", "a=fmtp:121 apt=120"] {
            XCTAssertTrue(parts[2].contains(kept), kept)
        }
    }

    func testNothingOfTheOtherVideoCodecsRemainsAnywhere() {
        let out = GroupSdpRules.keepOnlyVp8Video(multiCodecSdp())
        for gone in ["VP9", "H264", "AV1", "H265", "red/90000", "ulpfec", "apt=98", "apt=100", "apt=102",
                     "profile-id", "level-asymmetry", "level-idx", "rtcp-fb:98", "rtcp-fb:100", "rtcp-fb:122",
                     " 98", " 99", " 100", " 101", " 102", " 103", " 104", " 105", " 122"] {
            XCTAssertFalse(out.contains(gone), "\(gone) must be gone")
        }
    }

    func testARejectedVideoSectionWithoutVp8IsLeftAlone() {
        let out = GroupSdpRules.keepOnlyVp8Video(multiCodecSdp())
        let parts = sections(of: out)
        XCTAssertEqual(parts[3], ["m=video 0 UDP/TLS/RTP/SAVPF 0", "c=IN IP4 0.0.0.0", "a=mid:3", "a=inactive"],
                       "an m-line with no format at all would not parse")
    }

    func testAudioAndTheRestOfTheSdpAreUntouchedByTheVideoFilter() {
        let original = multiCodecSdp()
        let out = GroupSdpRules.keepOnlyVp8Video(original)
        XCTAssertEqual(sections(of: out)[0], sections(of: original)[0])
        XCTAssertEqual(GroupSdpRules.checkPin(sdp: out, expected: pinned), .match)
        XCTAssertTrue(out.contains("a=group:BUNDLE 0 1 2 3"))
    }

    func testTheVideoFilterIsIdempotentAndAVp8OnlySdpIsUnchanged() {
        let once = GroupSdpRules.keepOnlyVp8Video(multiCodecSdp())
        XCTAssertEqual(GroupSdpRules.keepOnlyVp8Video(once), once)
        let plain = sdp()
        XCTAssertEqual(GroupSdpRules.keepOnlyVp8Video(plain), plain)
    }

    func testAnRtxOfAnotherCodecIsDroppedEvenWhenItsAptLineIsMissing() {
        let text = [
            "v=0",
            "m=video 9 UDP/TLS/RTP/SAVPF 96 97 98",
            "a=mid:0",
            "a=rtpmap:96 VP8/90000",
            "a=rtpmap:97 rtx/90000",
            "a=rtpmap:98 H264/90000",
            "",
        ].joined(separator: "\r\n")
        let out = GroupSdpRules.keepOnlyVp8Video(text)
        XCTAssertEqual(sections(of: out)[0][0], "m=video 9 UDP/TLS/RTP/SAVPF 96", "an RTX that names no VP8 is not VP8's RTX")
    }

    func testAnActiveVideoSectionWithoutVp8IsReportedAndARejectedOneIsNot() {
        XCTAssertEqual(GroupSdpRules.activeVideoSectionsWithoutVp8(in: multiCodecSdp()), [],
                       "every active section has VP8, the port-0 one is rejected")
        let h264Only = [
            "v=0",
            "m=video 9 UDP/TLS/RTP/SAVPF 100 101",
            "a=mid:7",
            "a=rtpmap:100 H264/90000",
            "a=rtpmap:101 rtx/90000",
            "a=fmtp:101 apt=100",
            "m=video 0 UDP/TLS/RTP/SAVPF 0",
            "a=mid:8",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "a=mid:9",
            "a=rtpmap:96 VP8/90000",
            "m=video 9 UDP/TLS/RTP/SAVPF 102",
            "a=rtpmap:102 AV1/90000",
            "",
        ].joined(separator: "\r\n")
        XCTAssertEqual(GroupSdpRules.activeVideoSectionsWithoutVp8(in: h264Only), ["7", "?"])
        XCTAssertEqual(GroupSdpRules.activeVideoSectionsWithoutVp8(in: sdp()), [])
        XCTAssertEqual(GroupSdpRules.activeVideoSectionsWithoutVp8(in: "v=0\r\nm=audio 9 X 111\r\na=mid:0\r\n"), [])
    }

    func testBothDirectionsAreVp8Only() {
        let local = GroupSdpRules.mungeLocal(multiCodecSdp(), role: .publisherOffer)
        let remote = GroupSdpRules.mungeRemote(multiCodecSdp())
        for out in [local, remote] {
            XCTAssertEqual(sections(of: out)[1][0], "m=video 9 UDP/TLS/RTP/SAVPF 96 97")
            XCTAssertFalse(out.contains("H264"))
            XCTAssertFalse(out.contains("VP9"))
            XCTAssertTrue(out.contains("VP8/90000"))
        }
    }
}
