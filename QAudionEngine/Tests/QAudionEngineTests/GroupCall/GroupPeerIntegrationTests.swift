import XCTest
#if canImport(WebRTC)
import WebRTC
@testable import QAudionEngine

/// The two group PeerConnection wrappers on the REAL strict M150 build (iOS
/// Simulator slice): what the SDP really looks like after the group rules, and
/// that the frame cryptors attach to the real senders / receivers. No network:
/// nothing is ever connected, the offer of one wrapper stands in for Janus' offer.
final class GroupPeerIntegrationTests: XCTestCase {

    private func fixtureHub(_ factory: RTCPeerConnectionFactory) -> GroupFrameCryptorHub {
        let hub = GroupFrameCryptorHub()
        hub.bind(factory: factory)
        hub.installKey(GroupCallFixtures.keyBytes(7), index: 1, participantId: GroupCallFixtures.pseudoA)
        hub.setSendKeyIndex(1)
        return hub
    }

    func testPublisherOfferCarriesSimulcastVp8AndTheGroupAudioProfile() async throws {
        let factory = await QAudionPeerConnectionFactory.shared.factory()
        let peer = GroupPublisherPeer(factory: factory, iceServers: [], cryptors: fixtureHub(factory),
                                      selfPseudonym: GroupCallFixtures.pseudoA)
        try await peer.start()
        let offer = try await peer.createOffer(iceRestart: false)
        peer.close()
        let lines = GroupSdpRules.lines(of: offer)
        let text = lines.joined(separator: "\n")

        // Two m-lines: audio then video, both send-only.
        XCTAssertEqual(lines.filter { $0.hasPrefix("m=audio") }.count, 1, text)
        XCTAssertEqual(lines.filter { $0.hasPrefix("m=video") }.count, 1, text)
        XCTAssertGreaterThanOrEqual(lines.filter { $0 == "a=sendonly" }.count, 2, text)
        // Three simulcast encodings l / m / h.
        for rid in ["l", "m", "h"] {
            XCTAssertTrue(lines.contains("a=rid:\(rid) send"), "rid \(rid) missing\n" + text)
        }
        XCTAssertTrue(lines.contains { $0.hasPrefix("a=simulcast:send") }, text)
        // VP8 is offered for the video, and nothing else (spec 12.8).
        XCTAssertTrue(lines.contains { $0.lowercased().hasPrefix("a=rtpmap:") && $0.contains("VP8/90000") }, text)
        for other in ["vp9/90000", "h264/90000", "h265/90000", "av1/90000", "red/90000", "ulpfec/90000"] {
            XCTAssertFalse(lines.contains { $0.lowercased().hasPrefix("a=rtpmap:") && $0.lowercased().contains(other) },
                           "\(other) must not be offered\n" + text)
        }
        // Nothing but mid / rid / repaired-rid / transport-wide-cc travels as an extension.
        XCTAssertEqual(GroupSdpRules.disallowedExtensions(in: offer), [], text)
        // The 1:1 audio profile: Opus 60 ms / 32 kbps CBR, in-band FEC, no DTX.
        let fmtp = lines.first { $0.hasPrefix("a=fmtp:") && $0.contains("minptime") } ?? ""
        for expected in ["minptime=60", "useinbandfec=1", "usedtx=0", "cbr=1", "stereo=0", "maxaveragebitrate=32000"] {
            XCTAssertTrue(fmtp.contains(expected), "\(expected) missing in: \(fmtp)")
        }
        XCTAssertTrue(lines.contains("a=ptime:60"), text)
        // Janus is the DTLS client on the publisher PC: we offer actpass.
        XCTAssertTrue(lines.contains("a=setup:actpass"), text)
        // The mids the `publish` request describes.
        XCTAssertEqual(GroupSdpRules.videoMids(in: offer).count, 1, text)
    }

    /// iPhone 1.0.1205: VP8 `InitEncode` failed with -15 because the three layers had different
    /// `maxFramerate`. The encodings the transceiver is created with carry ONE frame rate, and the
    /// ladder's bitrate / resolution steps are intact.
    func testTheVideoSendEncodingsShareOneFrameRate() {
        let encodings = GroupPublisherPeer.videoSendEncodings()
        XCTAssertEqual(encodings.map { $0.rid }, ["l", "m", "h"])
        XCTAssertEqual(Set(encodings.map { $0.maxFramerate?.intValue }), [GroupSimulcastLadder.fps])
        XCTAssertEqual(Set(encodings.map { $0.numTemporalLayers?.intValue }), [GroupSimulcastLadder.temporalLayers])
        XCTAssertEqual(encodings.map { $0.scaleResolutionDownBy?.doubleValue }, [4, 2, 1])
        XCTAssertEqual(encodings.map { $0.maxBitrateBps?.intValue }, [150_000, 450_000, 1_200_000])
        XCTAssertTrue(encodings.allSatisfy { $0.isActive })
    }

    func testSubscriberAnswersAJanusStyleOfferPassiveAndAttachesTheReceiverCryptors() async throws {
        let factory = await QAudionPeerConnectionFactory.shared.factory()
        // The publisher offer stands in for Janus' (send-only) offer.
        let source = GroupPublisherPeer(factory: factory, iceServers: [], cryptors: fixtureHub(factory),
                                        selfPseudonym: GroupCallFixtures.pseudoB)
        try await source.start()
        let publisherOffer = try await source.createOffer(iceRestart: false)
        source.close()
        // Janus' subscriber offer carries no simulcast rids (it switches layers server-side).
        let janusOffer = GroupSdpRules.lines(of: publisherOffer)
            .filter { !$0.hasPrefix("a=rid:") && !$0.hasPrefix("a=simulcast:") && !$0.contains("rtp-stream-id") }
            .joined(separator: "\r\n") + "\r\n"

        let hub = fixtureHub(factory)
        let subscriber = GroupSubscriberPeer(factory: factory, iceServers: [], cryptors: hub)
        let tracks = LockedBox<[String]>([])
        subscriber.onRemoteTrack = { remote in
            tracks.mutate { $0.append("\(remote.kind == .audio ? "audio" : "video"):\(remote.feedId.prefix(4)):\(remote.track != nil)") }
        }
        try await subscriber.start()
        let streams = [
            VideoRoomStream(type: "audio", mid: "0", feedId: GroupCallFixtures.pseudoB, feedMid: "0"),
            VideoRoomStream(type: "video", mid: "1", feedId: GroupCallFixtures.pseudoB, feedMid: "1"),
        ]
        let answer = try await subscriber.acceptOffer(janusOffer, streams: streams)
        let lines = GroupSdpRules.lines(of: answer)
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(lines.contains("a=setup:passive"), text)
        XCTAssertTrue(lines.contains("a=recvonly"), text)
        XCTAssertEqual(GroupSdpRules.disallowedExtensions(in: answer), [], text)
        // Both streams were reported with their track, keyed by the publisher pseudonym.
        XCTAssertEqual(Set(tracks.value), ["audio:b2b2:true", "video:b2b2:true"], text)
        // A mapped audio receiver is audible (only unmapped ones are muted, spec 12.1).
        let audioTransceiver = subscriber.currentPeerConnection?.transceivers.first { $0.mediaType == .audio }
        XCTAssertEqual(audioTransceiver?.receiver.track?.isEnabled, true)
        // The transport row does not exist before any connection: nothing to observe yet.
        let observed = await subscriber.transportObservation()
        XCTAssertTrue(observed == nil || GroupTransportPolicy.evaluate(observed!) != .ok)
        subscriber.close()
    }

    /// The Janus-style offer of a fresh publisher wrapper (audio mid 0, video mid 1).
    private func janusStyleOffer(_ factory: RTCPeerConnectionFactory) async throws -> String {
        let source = GroupPublisherPeer(factory: factory, iceServers: [], cryptors: fixtureHub(factory),
                                        selfPseudonym: GroupCallFixtures.pseudoB)
        try await source.start()
        let publisherOffer = try await source.createOffer(iceRestart: false)
        source.close()
        return GroupSdpRules.lines(of: publisherOffer)
            .filter { !$0.hasPrefix("a=rid:") && !$0.hasPrefix("a=simulcast:") && !$0.contains("rtp-stream-id") }
            .joined(separator: "\r\n") + "\r\n"
    }

    func testAReceiverThatIsNotAKnownEnabledStreamGetsACryptorBoundToNobody() async throws {
        let factory = await QAudionPeerConnectionFactory.shared.factory()
        let janusOffer = try await janusStyleOffer(factory)
        let hub = fixtureHub(factory)
        let subscriber = GroupSubscriberPeer(factory: factory, iceServers: [], cryptors: hub)
        let tracks = LockedBox<[String]>([])
        subscriber.onRemoteTrack = { remote in
            tracks.mutate { $0.append("\(remote.kind == .audio ? "audio" : "video"):\(remote.track != nil)") }
        }
        try await subscriber.start()
        // The audio stream is a known publisher stream; the video m-line is a
        // stream Janus flags as removed (a node could just as well inject an
        // unmapped one): it must not render or play unprotected.
        let streams = [
            VideoRoomStream(type: "audio", mid: "0", feedId: GroupCallFixtures.pseudoB, feedMid: "0"),
            VideoRoomStream(type: "video", mid: "1", feedId: GroupCallFixtures.pseudoB, feedMid: "1", disabled: true),
        ]
        _ = try await subscriber.acceptOffer(janusOffer, streams: streams)
        XCTAssertEqual(Set(hub.attachedReceiverParticipants), [GroupCallFixtures.pseudoB, GroupFrameCryptorHub.unboundParticipantId])
        XCTAssertEqual(tracks.value, ["audio:true"], "the removed video stream must not be reported")
        subscriber.close()
        XCTAssertEqual(hub.attachedReceiverParticipants, [])
    }

    func testAnUnmappedAudioReceiverIsMutedAndItsCryptorHoldsNoKey() async throws {
        let factory = await QAudionPeerConnectionFactory.shared.factory()
        let janusOffer = try await janusStyleOffer(factory)
        let hub = fixtureHub(factory)
        let subscriber = GroupSubscriberPeer(factory: factory, iceServers: [], cryptors: hub)
        try await subscriber.start()
        // Only the video stream is a known publisher stream: the audio m-line is unmapped.
        let streams = [VideoRoomStream(type: "video", mid: "1", feedId: GroupCallFixtures.pseudoB, feedMid: "1")]
        _ = try await subscriber.acceptOffer(janusOffer, streams: streams)
        XCTAssertEqual(hub.attachedReceiverParticipants, [GroupCallFixtures.pseudoB, GroupFrameCryptorHub.unboundParticipantId].sorted())
        XCTAssertTrue(hub.attachedReceiverCryptors.allSatisfy { $0.enabled }, "every receiver keeps an ENABLED cryptor (spec 12.1)")
        let audio = try XCTUnwrap(subscriber.currentPeerConnection?.transceivers.first { $0.mediaType == .audio })
        XCTAssertEqual(audio.receiver.track?.isEnabled, false, "second guard: nothing unmapped is played")
        subscriber.close()
    }

    func testARebindOfAReceiverAttachesTheNewCryptorAndNeverDisablesTheOldOne() async throws {
        let factory = await QAudionPeerConnectionFactory.shared.factory()
        let janusOffer = try await janusStyleOffer(factory)
        let hub = fixtureHub(factory)
        let subscriber = GroupSubscriberPeer(factory: factory, iceServers: [], cryptors: hub)
        try await subscriber.start()
        let streams = [
            VideoRoomStream(type: "audio", mid: "0", feedId: GroupCallFixtures.pseudoB, feedMid: "0"),
            VideoRoomStream(type: "video", mid: "1", feedId: GroupCallFixtures.pseudoB, feedMid: "1"),
        ]
        _ = try await subscriber.acceptOffer(janusOffer, streams: streams)
        let before = hub.attachedReceiverCryptors
        XCTAssertEqual(before.count, 2)
        XCTAssertTrue(before.allSatisfy { $0.enabled })

        // The video mid now belongs to another publisher.
        let video = try XCTUnwrap(subscriber.currentPeerConnection?.transceivers.first { $0.mediaType == .video })
        XCTAssertTrue(hub.attachReceiver(video.receiver, participantId: GroupCallFixtures.pseudoC))
        XCTAssertEqual(hub.attachedReceiverParticipants, [GroupCallFixtures.pseudoB, GroupCallFixtures.pseudoC])
        XCTAssertEqual(hub.attachedReceiverCryptors.count, 2, "rebound, not added")
        XCTAssertTrue(before.allSatisfy { $0.enabled }, "the replaced cryptor was never switched off: a disabled one passes frames in the clear")
        XCTAssertTrue(hub.attachedReceiverCryptors.allSatisfy { $0.enabled })
        // The same binding again changes nothing; moving to the sentinel is a rebind too.
        let afterRebind = hub.attachedReceiverCryptors
        XCTAssertTrue(hub.attachReceiver(video.receiver, participantId: GroupCallFixtures.pseudoC))
        XCTAssertEqual(hub.attachedReceiverCryptors.count, 2)
        XCTAssertTrue(hub.attachReceiver(video.receiver, participantId: GroupFrameCryptorHub.unboundParticipantId))
        XCTAssertEqual(hub.attachedReceiverParticipants, [GroupCallFixtures.pseudoB, GroupFrameCryptorHub.unboundParticipantId].sorted())
        XCTAssertTrue(afterRebind.allSatisfy { $0.enabled })

        subscriber.close()
        XCTAssertEqual(hub.attachedReceiverParticipants, [])
        XCTAssertTrue(before.allSatisfy { $0.enabled }, "dropping a cryptor never disables it either")
    }

    func testClosingThePublisherDetachesTheTracksAndNeverDisablesASenderCryptor() async throws {
        let factory = await QAudionPeerConnectionFactory.shared.factory()
        let hub = fixtureHub(factory)
        let publisher = GroupPublisherPeer(factory: factory, iceServers: [], cryptors: hub,
                                           selfPseudonym: GroupCallFixtures.pseudoA)
        try await publisher.start()
        let cryptors = hub.attachedSenderCryptors
        XCTAssertEqual(cryptors.count, 2)
        XCTAssertTrue(cryptors.allSatisfy { $0.enabled })
        let senders = try XCTUnwrap(publisher.currentPeerConnection).senders
        XCTAssertEqual(senders.count, 2)
        XCTAssertTrue(senders.allSatisfy { $0.track != nil })

        publisher.close()
        XCTAssertEqual(hub.attachedSenderCount, 0, "dropped once the PeerConnection is closed")
        // Spec 12.1: a disabled cryptor passes the live microphone frames in the clear, so
        // none was switched off, and the tracks were taken off the senders before the close.
        XCTAssertTrue(cryptors.allSatisfy { $0.enabled })
        XCTAssertTrue(senders.allSatisfy { $0.track == nil })
        publisher.close()           // a second close is a no-op
        XCTAssertEqual(hub.attachedSenderCount, 0)
    }

    func testASecondPublisherClosingLateDoesNotForgetTheCryptorsOfTheNewOne() async throws {
        let factory = await QAudionPeerConnectionFactory.shared.factory()
        let hub = fixtureHub(factory)
        let first = GroupPublisherPeer(factory: factory, iceServers: [], cryptors: hub, selfPseudonym: GroupCallFixtures.pseudoA)
        try await first.start()
        first.close()
        let second = GroupPublisherPeer(factory: factory, iceServers: [], cryptors: hub, selfPseudonym: GroupCallFixtures.pseudoA)
        try await second.start()
        XCTAssertEqual(hub.attachedSenderCount, 2)
        first.close()               // the old wrapper is closed again (the session and the link both close)
        XCTAssertEqual(hub.attachedSenderCount, 2, "a wrapper tears down once")
        second.close()
        XCTAssertEqual(hub.attachedSenderCount, 0)
    }

    func testASenderWithoutATrackOrWithoutABoundFactoryGetsNoCryptor() async throws {
        let factory = await QAudionPeerConnectionFactory.shared.factory()
        let configuration = QAudionPeerConnectionFactory.defaultConfiguration(iceServers: [], nativeSrtpEnabledLocally: true)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let pc = try XCTUnwrap(factory.peerConnection(with: configuration, constraints: constraints, delegate: nil))
        defer { pc.close() }
        // A transceiver that carries no track: the native init cannot create a cryptor for it.
        let bare = try XCTUnwrap(pc.addTransceiver(of: .audio, init: RTCRtpTransceiverInit()))
        XCTAssertNil(bare.sender.track)
        let hub = fixtureHub(factory)
        XCTAssertFalse(hub.attachSender(bare.sender, participantId: GroupCallFixtures.pseudoA), "fail closed (spec 12.9)")
        XCTAssertEqual(hub.attachedSenderCount, 0)
        // A hub that was never bound to a factory refuses too, even for a sender with a track.
        let track = factory.audioTrack(with: factory.audioSource(with: nil), trackId: "audio-x")
        let carrying = try XCTUnwrap(pc.addTransceiver(with: track, init: RTCRtpTransceiverInit()))
        XCTAssertFalse(GroupFrameCryptorHub().attachSender(carrying.sender, participantId: GroupCallFixtures.pseudoA))
        XCTAssertTrue(hub.attachSender(carrying.sender, participantId: GroupCallFixtures.pseudoA), "the bound hub does attach")
        XCTAssertEqual(hub.attachedSenderCount, 1)
    }

    func testDroppingTheSubscriberAloneKeepsThePublishersSenderCryptors() async throws {
        let factory = await QAudionPeerConnectionFactory.shared.factory()
        let hub = fixtureHub(factory)
        let publisher = GroupPublisherPeer(factory: factory, iceServers: [], cryptors: hub,
                                           selfPseudonym: GroupCallFixtures.pseudoA)
        try await publisher.start()
        XCTAssertEqual(hub.attachedSenderCount, 2, "audio + video sender cryptors")
        let subscriber = GroupSubscriberPeer(factory: factory, iceServers: [], cryptors: hub)
        try await subscriber.start()
        // A refused subscriber join drops just the subscriber: a disabled sender
        // cryptor would silently discard our own published media.
        subscriber.close()
        XCTAssertEqual(hub.attachedSenderCount, 2)
        publisher.close()
        XCTAssertEqual(hub.attachedSenderCount, 0)
    }

    func testRefreshedTurnCredentialsReplaceTheIceServersOfTheLivePeerConnection() async throws {
        let factory = await QAudionPeerConnectionFactory.shared.factory()
        let peer = GroupPublisherPeer(factory: factory, iceServers: [], cryptors: fixtureHub(factory),
                                      selfPseudonym: GroupCallFixtures.pseudoA)
        try await peer.start()
        let pc = try XCTUnwrap(peer.currentPeerConnection)
        XCTAssertTrue(pc.configuration.iceServers.isEmpty)
        peer.updateIceServers([GroupCallWire.IceServer(urls: ["turn:turn.example.invalid:3478"], username: "user-2", credential: "secret-2")])
        XCTAssertEqual(pc.configuration.iceServers.first?.urlStrings, ["turn:turn.example.invalid:3478"])
        XCTAssertEqual(pc.configuration.iceServers.first?.username, "user-2")
        // Nothing else of the group configuration is reset by the refresh.
        XCTAssertEqual(pc.configuration.bundlePolicy, .maxBundle)
        XCTAssertEqual(pc.configuration.rtcpMuxPolicy, .require)
        peer.close()
        peer.updateIceServers([])      // a closed wrapper ignores it
    }

    func testAWrapperClosedBeforeItStartedNeverBuildsAPeerConnection() async throws {
        let factory = await QAudionPeerConnectionFactory.shared.factory()
        let publisher = GroupPublisherPeer(factory: factory, iceServers: [], cryptors: fixtureHub(factory),
                                           selfPseudonym: GroupCallFixtures.pseudoA)
        publisher.close()
        do {
            try await publisher.start()
            XCTFail("a closed wrapper must refuse to start")
        } catch {
            XCTAssertEqual(error as? GroupPeerError, .notStarted)
        }
    }
}
#endif
