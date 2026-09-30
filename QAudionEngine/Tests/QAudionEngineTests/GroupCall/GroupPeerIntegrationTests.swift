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
        // VP8 is offered for the video.
        XCTAssertTrue(lines.contains { $0.lowercased().hasPrefix("a=rtpmap:") && $0.contains("VP8/90000") }, text)
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
