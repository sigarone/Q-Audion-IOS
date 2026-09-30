import XCTest
@testable import QAudionEngine

// MARK: - Fake links

final class FakePublisherLink: GroupPublisherLink, @unchecked Sendable {
    var onCandidate: ((GroupIceCandidate?) -> Void)?
    var onState: ((GroupPcState) -> Void)?
    private let lock = NSLock()
    private var log: [String] = []
    var offerSdp = FakeJanusServer.sdp(setup: "a=setup:actpass")
    var observation: GroupTransportPolicy.Observed? = FakePublisherLink.goodTransport
    var failStart: Error?

    static let goodTransport = GroupTransportPolicy.Observed(
        tlsVersion: "FEFC", dtlsCipher: "TLS_AES_256_GCM_SHA384", srtpCipher: "AEAD_AES_256_GCM", candidateType: "host")

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    private func record(_ entry: String) {
        lock.lock(); log.append(entry); lock.unlock()
    }

    func start() async throws {
        record("start")
        if let error = failStart { throw error }
    }

    func createOffer(iceRestart: Bool) async throws -> String {
        record(iceRestart ? "offer-restart" : "offer")
        return offerSdp
    }

    func applyAnswer(_ sdp: String) async throws { record("answer") }
    func transportObservation() async -> GroupTransportPolicy.Observed? { observation }
    func addRemoteCandidate(_ candidate: GroupIceCandidate?) async { record("remote-candidate") }
    func close() { record("close") }
}

final class FakeSubscriberLink: GroupSubscriberLink, @unchecked Sendable {
    var onCandidate: ((GroupIceCandidate?) -> Void)?
    var onState: ((GroupPcState) -> Void)?
    private let lock = NSLock()
    private var log: [String] = []
    private var _offers: [[VideoRoomStream]] = []
    var observation: GroupTransportPolicy.Observed? = FakePublisherLink.goodTransport
    var stats: GroupSubscriberStats?
    var answerSdp = FakeJanusServer.sdp(setup: "a=setup:passive")

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    var acceptedStreams: [[VideoRoomStream]] {
        lock.lock(); defer { lock.unlock() }
        return _offers
    }

    private func record(_ entry: String) {
        lock.lock(); log.append(entry); lock.unlock()
    }

    func start() async throws { record("start") }

    func acceptOffer(_ sdp: String, streams: [VideoRoomStream]) async throws -> String {
        record("offer")
        lock.lock(); _offers.append(streams); lock.unlock()
        return answerSdp
    }

    func inboundStats() async -> GroupSubscriberStats? { stats }
    func transportObservation() async -> GroupTransportPolicy.Observed? { observation }
    func addRemoteCandidate(_ candidate: GroupIceCandidate?) async { record("remote-candidate") }
    func close() { record("close") }
}

// MARK: - Harness

final class SessionHarness: @unchecked Sendable {
    let server: FakeJanusServer
    let publisher: FakePublisherLink
    let subscriber: FakeSubscriberLink
    let session: GroupMediaSession
    let policy: GroupLayerPolicy
    private let lock = NSLock()
    private var _events: [GroupMediaSession.Event] = []

    init(publishersOnJoin: [[String: Any]] = [], config: GroupMediaSession.Config? = nil, timeout: Double = 0.4,
         fingerprintPair: String = FakeJanusServer.fingerprintPair) {
        let serverLocal = FakeJanusServer()
        let publisherLocal = FakePublisherLink()
        let subscriberLocal = FakeSubscriberLink()
        let policyLocal = GroupLayerPolicy()
        serverLocal.publishersOnJoin = publishersOnJoin
        var janusConfig = JanusClient.Config()
        janusConfig.requestTimeoutSeconds = timeout
        let janus = JanusClient(config: janusConfig, makeSocket: { serverLocal }, token: { "tok" })
        let room = VideoRoomClient(janus: janus, room: GroupCallFixtures.room, pseudonym: GroupCallFixtures.pseudoA,
                                   joinToken: GroupCallFixtures.joinToken)
        var sessionConfig = config ?? GroupMediaSession.Config()
        if config == nil {
            sessionConfig.reconnectBackoffSeconds = [0.05, 0.05]
            sessionConfig.restartWatchdogSeconds = 0.3
            sessionConfig.statsIntervalSeconds = 0.05
            sessionConfig.transportCheckAttempts = 3
            sessionConfig.transportCheckIntervalMs = 10
            sessionConfig.debounceMs = 10
        }
        server = serverLocal
        publisher = publisherLocal
        subscriber = subscriberLocal
        policy = policyLocal
        session = GroupMediaSession(
            janus: janus, room: room, publisher: publisherLocal,
            makeSubscriber: { subscriberLocal },
            dtlsFingerprint: GroupCallFixtures.fingerprint(fingerprintPair),
            layerPolicy: policyLocal, config: sessionConfig)
        session.onEvent = { [weak self] event in
            guard let self = self else { return }
            self.lock.lock(); self._events.append(event); self.lock.unlock()
        }
    }

    var events: [GroupMediaSession.Event] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func lastPublishers() -> [VideoRoomPublisher]? {
        for event in events.reversed() { if case .remotePublishers(let list) = event { return list } }
        return nil
    }

    func telemetryKinds() -> [String] {
        events.compactMap { if case .telemetry(let item) = $0 { return item.kind } else { return nil } }
    }

    func rejoinReasons() -> [String] {
        events.compactMap { if case .needsRejoin(let reason) = $0 { return reason } else { return nil } }
    }

    func failures() -> [GroupMediaSession.Failure] {
        events.compactMap { if case .failed(let failure) = $0 { return failure } else { return nil } }
    }
}

// MARK: - Tests

final class GroupMediaSessionTests: XCTestCase {

    private let bob = GroupCallFixtures.pseudoB
    private let carol = GroupCallFixtures.pseudoC

    private func bobStreams() -> [(feed: String, feedMid: String, type: String, mid: String)] {
        [(feed: bob, feedMid: "0", type: "audio", mid: "0"), (feed: bob, feedMid: "1", type: "video", mid: "1")]
    }

    // MARK: bring-up

    func testStartRunsTheSpecSequenceCreateAttachJoinPublish() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        let janusKinds = h.server.requests.compactMap { $0["janus"] as? String }
        XCTAssertEqual(Array(janusKinds.prefix(4)), ["create", "attach", "message", "message"])
        XCTAssertEqual(h.server.pluginRequests, ["join", "publish"])
        XCTAssertEqual(h.publisher.calls, ["start", "offer", "answer"], "PC and cryptors exist BEFORE the offer is created")
        XCTAssertEqual(h.session.currentState, .active)
        h.session.close()
    }

    func testJoinAsPublisherCarriesRoomPseudonymAndJoinToken() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        let join = try XCTUnwrap(h.server.bodies(for: "join").first)
        XCTAssertEqual(join["ptype"] as? String, "publisher")
        XCTAssertEqual(join["room"] as? String, GroupCallFixtures.room)
        XCTAssertEqual(join["id"] as? String, GroupCallFixtures.pseudoA)
        XCTAssertEqual(join["display"] as? String, GroupCallFixtures.pseudoA)
        XCTAssertEqual(join["token"] as? String, GroupCallFixtures.joinToken)
        h.session.close()
    }

    func testPublishCarriesE2eeFlagCameraDescriptionAndTheOffer() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        let publish = try XCTUnwrap(h.server.bodies(for: "publish").first)
        XCTAssertEqual(publish["e2ee"] as? Bool, true)
        XCTAssertEqual(publish["audio"] as? Bool, true)
        XCTAssertEqual(publish["video"] as? Bool, true)
        let descriptions = try XCTUnwrap(publish["descriptions"] as? [[String: String]])
        XCTAssertEqual(descriptions, [["mid": "1", "description": "camera"]])
        let jsep = try XCTUnwrap(h.server.jsep(for: "publish").first)
        XCTAssertEqual(jsep["type"] as? String, "offer")
        XCTAssertEqual(jsep["sdp"] as? String, h.publisher.offerSdp)
        h.session.close()
    }

    func testPublishDeclaresTheAscendingRidOrderOfTheSimulcastLayers() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        XCTAssertEqual(h.server.bodies(for: "publish").first?["rid_order"] as? String, "lmh")
        h.session.close()
    }

    func testAnActiveFalseStreamIsADisabledStream() {
        let removed = VideoRoomStream.parse(["type": "video", "mid": "3", "feed_id": "x", "feed_mid": "1", "active": false])
        XCTAssertEqual(removed?.disabled, true)
        let live = VideoRoomStream.parse(["type": "video", "mid": "3", "feed_id": "x", "feed_mid": "1", "active": true])
        XCTAssertEqual(live?.disabled, false)
        XCTAssertEqual(VideoRoomStream.parse(["type": "audio", "mid": "0", "feed_id": "x", "feed_mid": "0"])?.disabled, false)
    }

    func testAudioOnlyCallPublishesWithVideoOff() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: false)
        XCTAssertEqual(h.server.bodies(for: "publish").first?["video"] as? Bool, false)
        h.session.close()
    }

    func testAPublishAnswerWithAnotherFingerprintIsRefusedAndEverythingClosed() async {
        let h = SessionHarness()
        h.server.publishAnswerSdp = FakeJanusServer.sdp(setup: "a=setup:active", fingerprintPair: "CD")
        do {
            try await h.session.start(publishVideo: true)
            XCTFail("must refuse")
        } catch {
            XCTAssertEqual(error as? GroupMediaSession.Failure, .dtlsPinMismatch(pc: .pub))
        }
        XCTAssertFalse(h.publisher.calls.contains("answer"), "the answer is never applied")
        XCTAssertTrue(h.publisher.calls.contains("close"))
        XCTAssertTrue(h.server.closedByClient)
        XCTAssertTrue(h.telemetryKinds().contains(GroupTelemetry.Kind.dtlsPinMismatch))
        XCTAssertEqual(h.session.currentState, .closed)
    }

    func testTheEndToEndTokenIsSentOnEveryRequest() async throws {
        let h = SessionHarness()
        h.server.requireToken = "tok"
        try await h.session.start(publishVideo: true)
        XCTAssertTrue(h.server.requests.allSatisfy { ($0["token"] as? String) == "tok" })
        h.session.close()
    }

    // MARK: subscriptions

    func testExistingPublishersAreSubscribedThroughOneMultistreamSubscriberHandle() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        try await h.session.start(publishVideo: true)
        let ok = await h.waitUntil { h.subscriber.acceptedStreams.count == 1 && h.server.pluginRequests.contains("start") }
        XCTAssertTrue(ok)
        let join = try XCTUnwrap(h.server.bodies(for: "join").last)
        XCTAssertEqual(join["ptype"] as? String, "subscriber")
        XCTAssertEqual((join["private_id"] as? NSNumber)?.int64Value, 4242)
        XCTAssertNil(join["token"], "the subscriber join needs only the private id")
        let streams = try XCTUnwrap(join["streams"] as? [[String: Any]])
        XCTAssertEqual(Set(streams.compactMap { $0["mid"] as? String }), ["0", "1"])
        XCTAssertTrue(streams.allSatisfy { ($0["feed"] as? String) == bob })
        let start = try XCTUnwrap(h.server.jsep(for: "start").first)
        XCTAssertEqual(start["type"] as? String, "answer")
        XCTAssertEqual(h.subscriber.acceptedStreams[0].map { $0.mid }.sorted(), ["0", "1"])
        XCTAssertEqual(h.subscriber.acceptedStreams[0].first?.feedId, bob)
        h.session.close()
    }

    func testANewPublisherEventTriggersASubscribeNotASecondJoin() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        try await h.session.start(publishVideo: true)
        _ = await h.waitUntil { h.server.pluginRequests.contains("start") }
        h.server.subscriberStreams += [(feed: carol, feedMid: "0", type: "audio", mid: "2"), (feed: carol, feedMid: "1", type: "video", mid: "3")]
        h.server.push(["janus": "event", "session_id": 1001, "sender": h.server.handle(forRole: "publisher") ?? 0,
                       "plugindata": ["plugin": "janus.plugin.videoroom",
                                      "data": ["videoroom": "event", "room": "r", "publishers": [FakeJanusServer.publisher(id: carol)]]]])
        let ok = await h.waitUntil { h.server.pluginRequests.filter { $0 == "subscribe" }.count == 1 }
        XCTAssertTrue(ok)
        XCTAssertEqual(h.server.bodies(for: "join").count, 2, "publisher join + ONE subscriber join")
        let subscribe = try XCTUnwrap(h.server.bodies(for: "subscribe").first)
        let streams = try XCTUnwrap(subscribe["streams"] as? [[String: Any]])
        XCTAssertTrue(streams.allSatisfy { ($0["feed"] as? String) == carol })
        XCTAssertEqual(h.subscriber.calls.filter { $0 == "start" }.count, 1, "one subscriber PeerConnection")
        h.session.close()
    }

    func testACallWithoutPublishersNeverCreatesTheSubscriberPeerConnection() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(h.subscriber.calls.isEmpty)
        XCTAssertEqual(h.server.pluginRequests, ["join", "publish"])
        h.session.close()
    }

    func testARemovedStreamComingBackAsActiveFalseIsForgottenBeforeTheNextAnswer() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        try await h.session.start(publishVideo: true)
        _ = await h.waitUntil { h.subscriber.acceptedStreams.count == 1 }
        // Bob leaves: Janus re-offers with his mids left in the SDP as active:false, no feed.
        h.server.push(["janus": "event", "session_id": 1001, "sender": h.server.handle(forRole: "subscriber") ?? 0,
                       "plugindata": ["plugin": "janus.plugin.videoroom",
                                      "data": ["videoroom": "updated", "room": "r", "streams": [
                                          ["type": "audio", "mindex": 0, "mid": "0", "active": false],
                                          ["type": "video", "mindex": 1, "mid": "1", "active": false],
                                      ]]],
                       "jsep": ["type": "offer", "sdp": FakeJanusServer.sdp(setup: "a=setup:actpass")]])
        let ok = await h.waitUntil { h.subscriber.acceptedStreams.count == 2 }
        XCTAssertTrue(ok)
        XCTAssertTrue(h.subscriber.acceptedStreams[1].isEmpty, "the answer is built without the departed publisher's streams")
        h.session.close()
    }

    func testAPublisherWhoLeavesIsRemovedWithoutAnUnsubscribeRequest() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        try await h.session.start(publishVideo: true)
        _ = await h.waitUntil { h.server.pluginRequests.contains("start") }
        h.server.push(["janus": "event", "session_id": 1001, "sender": h.server.handle(forRole: "publisher") ?? 0,
                       "plugindata": ["plugin": "janus.plugin.videoroom", "data": ["videoroom": "event", "leaving": bob]]])
        let ok = await h.waitUntil { h.lastPublishers()?.isEmpty == true }
        XCTAssertTrue(ok)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(h.server.pluginRequests.contains("unsubscribe"), "Janus drops the streams itself")
        h.session.close()
    }

    func testPublishersOutsideTheRosterAreNeverSubscribed() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob), FakeJanusServer.publisher(id: carol)])
        h.server.subscriberStreams = bobStreams()
        h.session.publisherFilter = { $0 == GroupCallFixtures.pseudoB }
        try await h.session.start(publishVideo: true)
        _ = await h.waitUntil { h.server.pluginRequests.contains("start") }
        let join = try XCTUnwrap(h.server.bodies(for: "join").last)
        let streams = try XCTUnwrap(join["streams"] as? [[String: Any]])
        XCTAssertTrue(streams.allSatisfy { ($0["feed"] as? String) == bob })
        XCTAssertEqual(h.lastPublishers()?.map { $0.id }, [bob])
        h.session.close()
    }

    func testAFilterRefreshLetsALateRosterEntryIn() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        var allowed = false
        h.session.publisherFilter = { _ in allowed }
        try await h.session.start(publishVideo: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(h.subscriber.calls.isEmpty)
        allowed = true
        h.session.refreshPublisherFilter()
        let ok = await h.waitUntil { h.server.pluginRequests.contains("start") }
        XCTAssertTrue(ok)
        h.session.close()
    }

    func testAnOfferFromTheNodeWithAnotherFingerprintClosesEverything() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        h.server.subscriberOfferSdp = FakeJanusServer.sdp(setup: "a=setup:actpass", fingerprintPair: "CD")
        try await h.session.start(publishVideo: true)
        let ok = await h.waitUntil { !h.failures().isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(h.failures().first, .dtlsPinMismatch(pc: .sub))
        XCTAssertTrue(h.subscriber.acceptedStreams.isEmpty, "the offer is never applied")
        XCTAssertTrue(h.publisher.calls.contains("close"))
        XCTAssertEqual(h.session.currentState, .closed)
    }

    // MARK: layers

    func testTileChangesBecomeSubstreamConfigureRequestsOnTheSubscriberMid() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        try await h.session.start(publishVideo: true)
        _ = await h.waitUntil { h.server.pluginRequests.contains("start") }
        h.session.setTile(pseudonym: bob, tile: .fullscreen, visible: true)
        let ok = await h.waitUntil {
            h.server.bodies(for: "configure").contains { ($0["streams"] as? [[String: Any]])?.first?["substream"] as? Int == 2 }
        }
        XCTAssertTrue(ok)
        let body = try XCTUnwrap(h.server.bodies(for: "configure").last { $0["streams"] != nil })
        let entry = try XCTUnwrap((body["streams"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["mid"] as? String, "1", "the subscriber-side mid of the video stream")
        XCTAssertEqual(entry["substream"] as? Int, 2)
        XCTAssertEqual(entry["temporal"] as? Int, 2)
        h.session.close()
    }

    func testHidingATileUnsubscribesItsVideoButKeepsItsAudio() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        try await h.session.start(publishVideo: true)
        _ = await h.waitUntil { h.server.pluginRequests.contains("start") }
        h.session.setTile(pseudonym: bob, tile: .grid, visible: false)
        let ok = await h.waitUntil { h.server.pluginRequests.contains("unsubscribe") }
        XCTAssertTrue(ok)
        let body = try XCTUnwrap(h.server.bodies(for: "unsubscribe").first)
        let streams = try XCTUnwrap(body["streams"] as? [[String: Any]])
        XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(streams[0]["feed"] as? String, bob)
        XCTAssertEqual(streams[0]["mid"] as? String, "1", "only the video stream (the publisher's mid)")
        h.session.close()
    }

    func testBackgroundingUnsubscribesEveryRemoteVideo() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        try await h.session.start(publishVideo: true)
        _ = await h.waitUntil { h.server.pluginRequests.contains("start") }
        h.session.setBackgrounded(true)
        let ok = await h.waitUntil { h.server.pluginRequests.contains("unsubscribe") }
        XCTAssertTrue(ok)
        h.session.close()
    }

    func testSlowlinkOnTheSubscriberStepsTheLayerDown() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        try await h.session.start(publishVideo: true)
        _ = await h.waitUntil { h.server.pluginRequests.contains("start") }
        h.session.setTile(pseudonym: bob, tile: .fullscreen, visible: true)
        _ = await h.waitUntil { h.server.bodies(for: "configure").contains { ($0["streams"] as? [[String: Any]])?.first?["substream"] as? Int == 2 } }
        let sub = h.server.handle(forRole: "subscriber") ?? 0
        h.server.push(["janus": "slowlink", "sender": sub, "uplink": false, "nacks": 20])
        let ok = await h.waitUntil { h.server.bodies(for: "configure").contains { ($0["streams"] as? [[String: Any]])?.first?["substream"] as? Int == 1 } }
        XCTAssertTrue(ok)
        XCTAssertTrue(h.telemetryKinds().contains(GroupTelemetry.Kind.layer))
        h.session.close()
    }

    func testSlowlinkOnThePublisherRaisesUplinkCongestion() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        h.server.push(["janus": "slowlink", "sender": h.server.handle(forRole: "publisher") ?? 0, "uplink": true, "nacks": 9])
        let ok = await h.waitUntil { h.events.contains { if case .uplinkCongested = $0 { return true } else { return false } } }
        XCTAssertTrue(ok)
        h.session.close()
    }

    func testReceiverSideAudioLevelsAreReportedPerPublisher() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        h.subscriber.stats = GroupSubscriberStats(videos: [], availableIncomingBps: nil, audioLevels: ["0": 0.3])
        try await h.session.start(publishVideo: true)
        let ok = await h.waitUntil {
            h.events.contains { if case .audioLevels(let levels) = $0 { return levels[self.bob] == 0.3 } else { return false } }
        }
        XCTAssertTrue(ok)
        h.session.close()
    }

    func testLossReportedByTheSubscriberStatsStepsTheLayerDown() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        h.subscriber.stats = GroupSubscriberStats(videos: [GroupInboundVideoStat(mid: "1", packetsLost: 0, packetsReceived: 100)], availableIncomingBps: nil)
        try await h.session.start(publishVideo: true)
        _ = await h.waitUntil { h.server.pluginRequests.contains("start") }
        h.session.setTile(pseudonym: bob, tile: .fullscreen, visible: true)
        _ = await h.waitUntil { h.server.bodies(for: "configure").contains { ($0["streams"] as? [[String: Any]])?.first?["substream"] as? Int == 2 } }
        try await Task.sleep(nanoseconds: 150_000_000)
        h.subscriber.stats = GroupSubscriberStats(videos: [GroupInboundVideoStat(mid: "1", packetsLost: 30, packetsReceived: 170)], availableIncomingBps: nil)
        let ok = await h.waitUntil { h.server.bodies(for: "configure").contains { ($0["streams"] as? [[String: Any]])?.first?["substream"] as? Int == 1 } }
        XCTAssertTrue(ok)
        h.session.close()
    }

    // MARK: transport self-check

    func testAConnectedPeerConnectionWithTheRequiredLevelEmitsTransportTelemetry() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        h.publisher.onState?(.connected)
        let ok = await h.waitUntil { h.telemetryKinds().contains(GroupTelemetry.Kind.transport) }
        XCTAssertTrue(ok)
        XCTAssertTrue(h.failures().isEmpty)
        XCTAssertEqual(h.session.currentState, .active)
        h.session.close()
    }

    func testADowngradedTransportClosesThePeerConnections() async throws {
        let h = SessionHarness()
        h.publisher.observation = GroupTransportPolicy.Observed(tlsVersion: "FEFD", dtlsCipher: "TLS_AES_256_GCM_SHA384", srtpCipher: "AEAD_AES_256_GCM")
        try await h.session.start(publishVideo: true)
        h.publisher.onState?(.connected)
        let ok = await h.waitUntil { !h.failures().isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(h.failures().first, .transportPolicy(pc: .pub, fields: ["tls"]))
        XCTAssertTrue(h.telemetryKinds().contains(GroupTelemetry.Kind.transportPolicyViolation))
        XCTAssertTrue(h.publisher.calls.contains("close"))
        XCTAssertEqual(h.session.currentState, .closed)
    }

    func testTransportStatsThatNeverFillInAreRefused() async throws {
        let h = SessionHarness()
        h.publisher.observation = nil
        try await h.session.start(publishVideo: true)
        h.publisher.onState?(.connected)
        let ok = await h.waitUntil { !h.failures().isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(h.failures().first, .transportPolicy(pc: .pub, fields: ["stats"]))
    }

    func testTheSubscriberPeerConnectionIsCheckedToo() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        h.subscriber.observation = GroupTransportPolicy.Observed(tlsVersion: "FEFC", dtlsCipher: "TLS_AES_128_GCM_SHA256", srtpCipher: "AEAD_AES_256_GCM")
        try await h.session.start(publishVideo: true)
        _ = await h.waitUntil { h.server.pluginRequests.contains("start") }
        h.subscriber.onState?(.connected)
        let ok = await h.waitUntil { !h.failures().isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(h.failures().first, .transportPolicy(pc: .sub, fields: ["cipher"]))
    }

    // MARK: failures and recovery

    func testAFailedPeerConnectionAsksForARejoin() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        h.publisher.onState?(.failed)
        let ok = await h.waitUntil { h.rejoinReasons().contains("pc_failed") }
        XCTAssertTrue(ok)
        h.session.close()
    }

    func testAPeerConnectionStuckDisconnectedAsksForARejoinAfterTheWatchdog() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        h.publisher.onState?(.disconnected)
        let ok = await h.waitUntil { h.rejoinReasons().contains("pc_disconnected") }
        XCTAssertTrue(ok)
        h.session.close()
    }

    func testAFirstConnectThatNeverCompletesAsksForARejoin() async throws {
        var config = GroupMediaSession.Config()
        config.startWatchdogSeconds = 0.2
        config.statsIntervalSeconds = 0.05
        config.debounceMs = 10
        let h = SessionHarness(config: config)
        try await h.session.start(publishVideo: true)
        // The publisher PC never reports `connected`.
        let ok = await h.waitUntil { h.rejoinReasons().contains("ice_restart_timeout") }
        XCTAssertTrue(ok)
        h.session.close()
    }

    func testAPublisherThatConnectsInTimeNeverTripsTheStartWatchdog() async throws {
        var config = GroupMediaSession.Config()
        config.startWatchdogSeconds = 0.2
        config.statsIntervalSeconds = 0.05
        config.transportCheckAttempts = 3
        config.transportCheckIntervalMs = 10
        config.debounceMs = 10
        let h = SessionHarness(config: config)
        try await h.session.start(publishVideo: true)
        h.publisher.onState?(.connected)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(h.rejoinReasons().contains("ice_restart_timeout"))
        h.session.close()
    }

    func testReconnectingInTimeCancelsTheDisconnectWatchdog() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        h.publisher.onState?(.disconnected)
        h.publisher.onState?(.connected)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(h.rejoinReasons().contains("pc_disconnected"))
        h.session.close()
    }

    func testAJanusHangupAsksForARejoin() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        h.server.push(["janus": "hangup", "sender": h.server.handle(forRole: "publisher") ?? 0, "reason": "DTLS alert"])
        let ok = await h.waitUntil { h.rejoinReasons().contains("janus_hangup") }
        XCTAssertTrue(ok)
        h.session.close()
    }

    func testBeingKickedIsReported() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        h.server.push(["janus": "event", "session_id": 1001, "sender": h.server.handle(forRole: "publisher") ?? 0,
                       "plugindata": ["plugin": "janus.plugin.videoroom", "data": ["videoroom": "event", "leaving": "ok", "reason": "kicked"]]])
        let ok = await h.waitUntil { h.events.contains { if case .kicked = $0 { return true } else { return false } } }
        XCTAssertTrue(ok)
        h.session.close()
    }

    func testAWebSocketDropIsReclaimedWhilstThePeerConnectionsStayUp() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        h.server.dropConnection()
        let reconnecting = await h.waitUntil { h.events.contains { if case .state(.reconnecting) = $0 { return true } else { return false } } }
        XCTAssertTrue(reconnecting)
        let recovered = await h.waitUntil { h.session.currentState == .active }
        XCTAssertTrue(recovered)
        XCTAssertFalse(h.publisher.calls.contains("close"), "the media path is untouched")
        XCTAssertTrue(h.server.requests.contains { ($0["janus"] as? String) == "claim" })
        XCTAssertTrue(h.rejoinReasons().isEmpty)
        h.session.close()
    }

    func testAGoneSessionSkipsStraightToARejoin() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        h.server.claimError = 458
        h.server.dropConnection()
        let ok = await h.waitUntil { h.rejoinReasons().contains("ws_lost") }
        XCTAssertTrue(ok)
        h.session.close()
    }

    // MARK: timeouts and Janus errors (spec §8)

    func testOneLostReplyIsRetriedOnce() async throws {
        let h = SessionHarness(timeout: 0.15)
        h.server.swallowOnce = ["publish"]
        try await h.session.start(publishVideo: true)
        XCTAssertEqual(h.server.pluginRequests.filter { $0 == "publish" }.count, 2)
        XCTAssertEqual(h.session.currentState, .active)
        h.session.close()
    }

    func testTwoLostRepliesFailTheStart() async {
        let h = SessionHarness(timeout: 0.1)
        h.server.swallow = ["publish"]
        do {
            try await h.session.start(publishVideo: true)
            XCTFail("must fail")
        } catch {
            XCTAssertEqual(error as? JanusClientError, .timeout)
        }
        XCTAssertEqual(h.server.pluginRequests.filter { $0 == "publish" }.count, 2, "one retry, no more")
    }

    func testAnUnauthorizedJoinFailsTheStartWith433() async {
        let h = SessionHarness()
        h.server.pluginErrors["join"] = 433
        do {
            try await h.session.start(publishVideo: true)
            XCTFail("must fail")
        } catch {
            XCTAssertEqual((error as? JanusClientError)?.code, 433)
        }
    }

    func testASubscribeErrorThatIsRetryableAsksForARejoin() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        try await h.session.start(publishVideo: true)
        _ = await h.waitUntil { h.server.pluginRequests.contains("start") }
        h.server.pluginErrors["subscribe"] = 433
        h.server.subscriberStreams += [(feed: carol, feedMid: "0", type: "audio", mid: "2")]
        h.server.push(["janus": "event", "session_id": 1001, "sender": h.server.handle(forRole: "publisher") ?? 0,
                       "plugindata": ["plugin": "janus.plugin.videoroom", "data": ["videoroom": "event", "publishers": [FakeJanusServer.publisher(id: carol)]]]])
        let ok = await h.waitUntil { h.rejoinReasons().contains("janus_433") }
        XCTAssertTrue(ok)
        h.session.close()
    }

    func testNoSuchFeedOnASubscribeWaitsForThePublishersEventInsteadOfRejoining() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        try await h.session.start(publishVideo: true)
        _ = await h.waitUntil { h.server.pluginRequests.contains("start") }
        // Carol was listed a moment before she stopped publishing: 428.
        h.server.pluginErrors["subscribe"] = 428
        h.server.subscriberStreams += [(feed: carol, feedMid: "0", type: "audio", mid: "2")]
        let announce: () -> Void = {
            h.server.push(["janus": "event", "session_id": 1001, "sender": h.server.handle(forRole: "publisher") ?? 0,
                           "plugindata": ["plugin": "janus.plugin.videoroom",
                                          "data": ["videoroom": "event", "publishers": [FakeJanusServer.publisher(id: self.carol)]]]])
        }
        announce()
        _ = await h.waitUntil { h.server.pluginRequests.filter { $0 == "subscribe" }.count == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(h.rejoinReasons().isEmpty, "a vanished feed is not a broken media path")
        XCTAssertEqual(h.server.pluginRequests.filter { $0 == "subscribe" }.count, 1, "not retried on its own")
        // She publishes again: the next publishers event subscribes her.
        announce()
        let ok = await h.waitUntil { h.server.pluginRequests.filter { $0 == "subscribe" }.count == 2 }
        XCTAssertTrue(ok)
        h.session.close()
    }

    func testNoSuchFeedOnTheFirstSubscriberJoinDropsThatPeerConnectionAndRetriesOnThePublishersEvent() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        h.server.subscriberJoinError = 428
        try await h.session.start(publishVideo: true)
        let dropped = await h.waitUntil { h.subscriber.calls.contains("close") }
        XCTAssertTrue(dropped, "the unusable subscriber (PC + handle) is torn down")
        XCTAssertTrue(h.rejoinReasons().isEmpty)
        // Bob (re)appears: a fresh subscriber handle joins and is answered.
        h.server.push(["janus": "event", "session_id": 1001, "sender": h.server.handle(forRole: "publisher") ?? 0,
                       "plugindata": ["plugin": "janus.plugin.videoroom",
                                      "data": ["videoroom": "event", "publishers": [FakeJanusServer.publisher(id: bob)]]]])
        let ok = await h.waitUntil { h.server.pluginRequests.contains("start") }
        XCTAssertTrue(ok)
        XCTAssertEqual(h.server.bodies(for: "join").filter { ($0["ptype"] as? String) == "subscriber" }.count, 2)
        h.session.close()
    }

    func testASubscribeErrorThatIsNotRetryableIsSurfaced() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        try await h.session.start(publishVideo: true)
        _ = await h.waitUntil { h.server.pluginRequests.contains("start") }
        h.server.pluginErrors["subscribe"] = 432
        h.server.push(["janus": "event", "session_id": 1001, "sender": h.server.handle(forRole: "publisher") ?? 0,
                       "plugindata": ["plugin": "janus.plugin.videoroom", "data": ["videoroom": "event", "publishers": [FakeJanusServer.publisher(id: carol)]]]])
        let ok = await h.waitUntil { h.events.contains { if case .janusFailure = $0 { return true } else { return false } } }
        XCTAssertTrue(ok)
        h.session.close()
    }

    // MARK: ICE restart (spec §4.7)

    func testANetworkChangeRestartsIceOnBothPeerConnections() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        try await h.session.start(publishVideo: true)
        _ = await h.waitUntil { h.server.pluginRequests.contains("start") }
        h.publisher.onState?(.connected)
        h.subscriber.onState?(.connected)
        await h.session.networkPathChanged(reason: "wifi_cell")
        XCTAssertTrue(h.publisher.calls.contains("offer-restart"))
        let restart = try XCTUnwrap(h.server.bodies(for: "configure").first { $0["restart"] as? Bool == true && h.server.jsep(for: "configure").count >= 1 })
        XCTAssertEqual(restart["restart"] as? Bool, true)
        let configureJsep = h.server.jsep(for: "configure")
        XCTAssertEqual(configureJsep.first?["type"] as? String, "offer", "publisher: configure restart + a new offer")
        XCTAssertEqual(restart["rid_order"] as? String, "lmh")
        XCTAssertEqual(h.publisher.calls.filter { $0 == "answer" }.count, 2, "the answer of the restart is applied")
        XCTAssertGreaterThanOrEqual(h.subscriber.acceptedStreams.count, 2, "subscriber: Janus' new offer is answered")
        XCTAssertTrue(h.telemetryKinds().contains(GroupTelemetry.Kind.iceRestart))
        h.session.close()
    }

    func testARestartThatDoesNotReconnectAsksForARejoin() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        h.publisher.onState?(.disconnected)      // never comes back
        await h.session.networkPathChanged(reason: "ip_change")
        let ok = await h.waitUntil { h.rejoinReasons().contains("ice_restart_timeout") || h.rejoinReasons().contains("pc_disconnected") }
        XCTAssertTrue(ok)
        h.session.close()
    }

    func testARestartThatKeepsTheStateConnectedIsNotAFailure() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        h.publisher.onState?(.connected)
        await h.session.networkPathChanged(reason: "wifi_cell")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(h.rejoinReasons().isEmpty)
        h.session.close()
    }

    func testARestartAnswerWithAnotherFingerprintIsRefused() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        h.server.publishAnswerSdp = FakeJanusServer.sdp(setup: "a=setup:active", fingerprintPair: "CD")
        await h.session.networkPathChanged(reason: "wifi_cell")
        let ok = await h.waitUntil { !h.failures().isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(h.failures().first, .dtlsPinMismatch(pc: .pub))
    }

    // MARK: publisher controls

    func testCameraToggleIsAConfigureNotARenegotiation() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: false)
        await h.session.setPublishVideo(true)
        let body = try XCTUnwrap(h.server.bodies(for: "configure").last)
        XCTAssertEqual(body["video"] as? Bool, true)
        XCTAssertNil(h.server.jsep(for: "configure").first, "no SDP for a camera toggle")
        XCTAssertEqual(h.publisher.calls.filter { $0.hasPrefix("offer") }.count, 1)
        h.session.close()
    }

    func testKeyFrameRequestGoesThroughJanusConfigure() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        await h.session.requestPublisherKeyFrame()
        let body = try XCTUnwrap(h.server.bodies(for: "configure").last)
        XCTAssertEqual(body["keyframe"] as? Bool, true)
        h.session.close()
    }

    // MARK: candidates and shutdown

    func testLocalCandidatesAreTrickledToTheirHandle() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        h.publisher.onCandidate?(GroupIceCandidate(sdpMid: "0", sdpMLineIndex: 0, candidate: "candidate:1 1 udp 1 192.0.2.1 9 typ host"))
        h.publisher.onCandidate?(nil)
        let ok = await h.waitUntil { h.server.requests.filter { ($0["janus"] as? String) == "trickle" }.count == 2 }
        XCTAssertTrue(ok)
        let trickles = h.server.requests.filter { ($0["janus"] as? String) == "trickle" }
        XCTAssertEqual((trickles[0]["handle_id"] as? NSNumber)?.int64Value, h.server.handle(forRole: "publisher"))
        XCTAssertEqual((trickles[1]["candidate"] as? [String: Any])?["completed"] as? Bool, true)
        h.session.close()
    }

    func testCloseDestroysTheSessionAndClosesBothPeerConnections() async throws {
        let h = SessionHarness(publishersOnJoin: [FakeJanusServer.publisher(id: bob)])
        h.server.subscriberStreams = bobStreams()
        try await h.session.start(publishVideo: true)
        _ = await h.waitUntil { h.server.pluginRequests.contains("start") }
        h.session.close()
        XCTAssertTrue(h.server.requests.contains { ($0["janus"] as? String) == "destroy" })
        XCTAssertTrue(h.publisher.calls.contains("close"))
        XCTAssertTrue(h.subscriber.calls.contains("close"))
        XCTAssertEqual(h.session.currentState, .closed)
        h.session.close()      // idempotent
    }

    func testNothingIsEmittedAfterClose() async throws {
        let h = SessionHarness()
        try await h.session.start(publishVideo: true)
        h.session.close()
        let before = h.events.count
        h.publisher.onState?(.failed)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(h.events.count, before)
    }
}
