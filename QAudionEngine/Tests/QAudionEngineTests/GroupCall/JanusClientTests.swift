import XCTest
@testable import QAudionEngine

final class JanusWireTests: XCTestCase {

    func testTransactionsAre128BitHexAndUnique() {
        let a = JanusWire.newTransaction()
        let b = JanusWire.newTransaction()
        XCTAssertEqual(a.count, 32)
        XCTAssertTrue(GroupCallWire.isHex128(a))
        XCTAssertNotEqual(a, b)
    }

    func testEveryRequestCarriesTheSessionToken() {
        XCTAssertEqual(JanusWire.create(token: "t")["token"] as? String, "t")
        XCTAssertEqual(JanusWire.claim(sessionId: 1, token: "t")["token"] as? String, "t")
        XCTAssertEqual(JanusWire.keepalive(sessionId: 1, token: "t")["token"] as? String, "t")
        XCTAssertEqual(JanusWire.attach(sessionId: 1, plugin: JanusWire.pluginVideoRoom, token: "t")["token"] as? String, "t")
        XCTAssertEqual(JanusWire.detach(sessionId: 1, handleId: 2, token: "t")["token"] as? String, "t")
        XCTAssertEqual(JanusWire.destroy(sessionId: 1, token: "t")["token"] as? String, "t")
        XCTAssertEqual(JanusWire.message(sessionId: 1, handleId: 2, body: [:], jsep: nil, token: "t")["token"] as? String, "t")
        XCTAssertEqual(JanusWire.trickle(sessionId: 1, handleId: 2, candidate: nil, token: "t")["token"] as? String, "t")
    }

    func testMessageWithAndWithoutJsep() {
        let jsep = JanusJsep(type: "offer", sdp: "v=0")
        XCTAssertEqual(jsep.dictionary.keys.sorted(), ["sdp", "type"], "no flag unless asked for")
        let flagged = JanusJsep(type: "offer", sdp: "v=0", e2ee: true, ridOrder: "lmh")
        XCTAssertEqual(flagged.dictionary["e2ee"] as? Bool, true)
        XCTAssertEqual(flagged.dictionary["rid_order"] as? String, "lmh")
        let with = JanusWire.message(sessionId: 1, handleId: 2, body: ["request": "publish"], jsep: jsep, token: "t")
        XCTAssertEqual((with["jsep"] as? [String: Any])?["type"] as? String, "offer")
        XCTAssertEqual((with["jsep"] as? [String: Any])?["sdp"] as? String, "v=0")
        let without = JanusWire.message(sessionId: 1, handleId: 2, body: [:], jsep: nil, token: "t")
        XCTAssertNil(without["jsep"])
    }

    func testTrickleCandidateAndEndOfCandidates() {
        let one = JanusWire.trickle(sessionId: 1, handleId: 2, candidate: (sdpMid: "0", sdpMLineIndex: 0, candidate: "candidate:1"), token: "t")
        let body = one["candidate"] as? [String: Any]
        XCTAssertEqual(body?["candidate"] as? String, "candidate:1")
        XCTAssertEqual(body?["sdpMid"] as? String, "0")
        XCTAssertEqual(body?["sdpMLineIndex"] as? Int, 0)
        let end = JanusWire.trickle(sessionId: 1, handleId: 2, candidate: nil, token: "t")
        XCTAssertEqual((end["candidate"] as? [String: Any])?["completed"] as? Bool, true)
    }

    func testParseSuccessWithDataId() throws {
        let message = try XCTUnwrap(JanusMessage.parse(#"{"janus":"success","transaction":"x","data":{"id":9007199254740991}}"#))
        XCTAssertEqual(message.kind, .success)
        XCTAssertEqual(message.transaction, "x")
        XCTAssertEqual(message.dataId, 9007199254740991)
    }

    func testParseEventWithPluginDataAndJsep() throws {
        let text = #"{"janus":"event","session_id":1,"sender":7,"transaction":"t","plugindata":{"plugin":"janus.plugin.videoroom","data":{"videoroom":"joined","id":"abc"}},"jsep":{"type":"answer","sdp":"v=0"}}"#
        let message = try XCTUnwrap(JanusMessage.parse(text))
        XCTAssertEqual(message.kind, .event)
        XCTAssertEqual(message.sender, 7)
        XCTAssertEqual(message.pluginData?["videoroom"] as? String, "joined")
        XCTAssertEqual(message.jsep, JanusJsep(type: "answer", sdp: "v=0"))
        XCTAssertEqual(message.jsep?.e2ee, false, "an incoming JSEP carries no flags of ours")
    }

    func testParseErrors() throws {
        let core = try XCTUnwrap(JanusMessage.parse(#"{"janus":"error","transaction":"t","error":{"code":458,"reason":"No such session"}}"#))
        XCTAssertEqual(core.kind, .error)
        XCTAssertEqual(core.errorCode, 458)
        XCTAssertEqual(core.errorReason, "No such session")
        let plugin = try XCTUnwrap(JanusMessage.parse(#"{"janus":"event","plugindata":{"data":{"videoroom":"event","error_code":433,"error":"Unauthorized"}}}"#))
        XCTAssertEqual(plugin.pluginErrorCode, 433)
        XCTAssertEqual(plugin.pluginErrorReason, "Unauthorized")
    }

    func testParseAsyncNotifications() throws {
        let slow = try XCTUnwrap(JanusMessage.parse(#"{"janus":"slowlink","sender":3,"uplink":true,"nacks":12}"#))
        XCTAssertEqual(slow.kind, .slowlink)
        XCTAssertEqual(slow.slowlinkUplink, true)
        XCTAssertEqual(slow.slowlinkNacks, 12)
        let hangup = try XCTUnwrap(JanusMessage.parse(#"{"janus":"hangup","sender":3,"reason":"DTLS alert"}"#))
        XCTAssertEqual(hangup.hangupReason, "DTLS alert")
        let media = try XCTUnwrap(JanusMessage.parse(#"{"janus":"media","type":"audio","receiving":false}"#))
        XCTAssertEqual(media.mediaType, "audio")
        XCTAssertEqual(media.mediaReceiving, false)
        XCTAssertEqual(try XCTUnwrap(JanusMessage.parse(#"{"janus":"webrtcup","sender":3}"#)).kind, .webrtcup)
        XCTAssertEqual(try XCTUnwrap(JanusMessage.parse(#"{"janus":"something_new"}"#)).kind, .other)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(JanusMessage.parse("not json"))
        XCTAssertNil(JanusMessage.parse(#"{"no":"janus field"}"#))
        XCTAssertNil(JanusMessage.parse("[1,2,3]"))
    }
}

final class VideoRoomModelTests: XCTestCase {

    func testPublisherListParsing() {
        let list = VideoRoomPublisher.parseList([FakeJanusServer.publisher(id: GroupCallFixtures.pseudoB, screen: false)])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, GroupCallFixtures.pseudoB)
        XCTAssertEqual(list[0].streams.map { $0.type }, ["audio", "video"])
        XCTAssertTrue(list[0].streams[1].simulcast)
        XCTAssertFalse(list[0].streams[1].isScreenShare)
    }

    func testScreenShareDescriptionIsRecognised() {
        let list = VideoRoomPublisher.parseList([FakeJanusServer.publisher(id: GroupCallFixtures.pseudoB, screen: true)])
        XCTAssertTrue(list[0].streams[1].isScreenShare)
    }

    func testMidMayBeANumber() {
        let stream = VideoRoomStream.parse(["type": "video", "mid": 3, "feed_id": "f", "feed_mid": 1])
        XCTAssertEqual(stream?.mid, "3")
        XCTAssertEqual(stream?.feedMid, "1")
        XCTAssertEqual(stream?.feedId, "f")
    }

    func testPublisherWithoutAnIdIsSkipped() {
        XCTAssertTrue(VideoRoomPublisher.parseList([["display": "x"]]).isEmpty)
        XCTAssertTrue(VideoRoomPublisher.parseList(nil).isEmpty)
    }

    func testEventParsing() {
        XCTAssertEqual(VideoRoomEvent.parse(["videoroom": "event", "publishers": [FakeJanusServer.publisher(id: "p")]]),
                       .publishers(VideoRoomPublisher.parseList([FakeJanusServer.publisher(id: "p")])))
        XCTAssertEqual(VideoRoomEvent.parse(["unpublished": "p"]), .unpublished("p"))
        XCTAssertEqual(VideoRoomEvent.parse(["leaving": "p"]), .leaving("p"))
        XCTAssertEqual(VideoRoomEvent.parse(["leaving": "ok", "reason": "kicked"]), .kicked)
        XCTAssertEqual(VideoRoomEvent.parse(["videoroom": "destroyed"]), .destroyed)
        XCTAssertEqual(VideoRoomEvent.parse(["videoroom": "event", "configured": "ok"]), .other("event"))
        if case .attached(let streams) = VideoRoomEvent.parse(["videoroom": "attached", "streams": [["type": "audio", "mid": "0", "feed_id": "p", "feed_mid": "0"]]]) {
            XCTAssertEqual(streams.count, 1)
        } else {
            XCTFail("attached")
        }
    }

    // MARK: error policy (spec §8)

    func testJanusErrorPolicy() {
        XCTAssertEqual(JanusErrorPolicy.action(for: .plugin(code: 428, reason: "")), .retryMediaJoin)
        XCTAssertEqual(JanusErrorPolicy.action(for: .plugin(code: 433, reason: "")), .retryMediaJoin)
        XCTAssertEqual(JanusErrorPolicy.action(for: .plugin(code: 426, reason: "")), .retryMediaJoin, "no such room: a fresh media_join re-creates it")
        XCTAssertEqual(JanusErrorPolicy.action(for: .plugin(code: 436, reason: "")), .fail)
        XCTAssertEqual(JanusErrorPolicy.action(for: .plugin(code: 432, reason: "")), .fail)
        XCTAssertEqual(JanusErrorPolicy.action(for: .janus(code: 458, reason: "")), .retryMediaJoin)
        XCTAssertEqual(JanusErrorPolicy.action(for: .janus(code: 403, reason: "")), .retryMediaJoin)
        XCTAssertEqual(JanusErrorPolicy.action(for: .janus(code: 500, reason: "")), .fail)
        XCTAssertEqual(JanusErrorPolicy.action(for: .timeout), .fail)
    }
}

final class JanusClientTests: XCTestCase {

    private func makeClient(_ server: FakeJanusServer, token: String = "tok", timeout: Double = 0.4, keepalive: Double = 25) -> JanusClient {
        var config = JanusClient.Config()
        config.requestTimeoutSeconds = timeout
        config.keepaliveIntervalSeconds = keepalive
        return JanusClient(config: config, makeSocket: { server }, token: { token })
    }

    func testConnectCreatesTheSessionWithTheTokenOnEveryRequest() async throws {
        let server = FakeJanusServer()
        server.requireToken = "tok"
        let client = makeClient(server)
        let session = try await client.connect()
        XCTAssertEqual(session, 1001)
        let handle = try await client.attach()
        XCTAssertGreaterThan(handle, 2000)
        XCTAssertEqual(server.requests.compactMap { $0["token"] as? String }, ["tok", "tok"])
        client.close()
    }

    func testTheNewestTokenIsUsedForEveryLaterRequestKeepaliveIncluded() async throws {
        let server = FakeJanusServer()
        let token = JanusSessionToken("first")
        var config = JanusClient.Config()
        config.requestTimeoutSeconds = 0.4
        config.keepaliveIntervalSeconds = 0.1
        let client = JanusClient(config: config, makeSocket: { server }, token: { token.value })
        _ = try await client.connect()
        let handle = try await client.attach()
        token.update("second")
        _ = try await client.send(handle: handle, body: ["request": "join", "ptype": "publisher", "room": "r", "id": "me"])
        client.trickle(handle: handle, candidate: nil)
        try await Task.sleep(nanoseconds: 450_000_000)
        let byKind = Dictionary(grouping: server.requests, by: { $0["janus"] as? String ?? "" })
        XCTAssertEqual(byKind["create"]?.compactMap { $0["token"] as? String }, ["first"])
        XCTAssertEqual(byKind["message"]?.compactMap { $0["token"] as? String }, ["second"])
        XCTAssertEqual(byKind["trickle"]?.compactMap { $0["token"] as? String }, ["second"])
        let keepalives = byKind["keepalive"]?.compactMap { $0["token"] as? String } ?? []
        XCTAssertGreaterThanOrEqual(keepalives.count, 2)
        XCTAssertEqual(keepalives.last, "second", "Janus re-validates the token on every request, keepalive included")
        client.close()
    }

    func testAWrongTokenIsRefusedByTheNode() async {
        let server = FakeJanusServer()
        server.requireToken = "right"
        let client = makeClient(server, token: "wrong")
        do {
            _ = try await client.connect()
            XCTFail("must fail")
        } catch {
            XCTAssertEqual(error as? JanusClientError, .janus(code: 403, reason: "Unauthorized request"))
        }
        client.close()
    }

    func testPluginMessageWaitsForTheFinalEventNotTheAck() async throws {
        let server = FakeJanusServer()
        server.publishersOnJoin = [FakeJanusServer.publisher(id: GroupCallFixtures.pseudoB)]
        let client = makeClient(server)
        _ = try await client.connect()
        let handle = try await client.attach()
        let reply = try await client.send(handle: handle, body: ["request": "join", "ptype": "publisher", "room": "r", "id": "me"])
        XCTAssertEqual(reply.kind, .event)
        XCTAssertEqual(reply.pluginData?["videoroom"] as? String, "joined")
        XCTAssertEqual((reply.pluginData?["private_id"] as? NSNumber)?.int64Value, 4242)
        client.close()
    }

    func testAPluginErrorInsideAnEventThrows() async throws {
        let server = FakeJanusServer()
        server.pluginErrors["join"] = 433
        let client = makeClient(server)
        _ = try await client.connect()
        let handle = try await client.attach()
        do {
            _ = try await client.send(handle: handle, body: ["request": "join"])
            XCTFail("must throw")
        } catch {
            XCTAssertEqual((error as? JanusClientError)?.code, 433)
        }
        client.close()
    }

    func testAMissingReplyTimesOut() async throws {
        let server = FakeJanusServer()
        server.swallow = ["publish"]
        let client = makeClient(server, timeout: 0.15)
        _ = try await client.connect()
        let handle = try await client.attach()
        let started = Date()
        do {
            _ = try await client.send(handle: handle, body: ["request": "publish"])
            XCTFail("must time out")
        } catch {
            XCTAssertEqual(error as? JanusClientError, .timeout)
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.12)
        client.close()
    }

    func testRepliesAreMatchedByTransactionWhenRequestsOverlap() async throws {
        let server = FakeJanusServer()
        let client = makeClient(server)
        _ = try await client.connect()
        let handle = try await client.attach()
        async let a = client.send(handle: handle, body: ["request": "start"])
        async let b = client.send(handle: handle, body: ["request": "leave"])
        let (ra, rb) = try await (a, b)
        XCTAssertEqual(ra.kind, .event)
        XCTAssertEqual(rb.kind, .event)
        XCTAssertNotEqual(ra.transaction, rb.transaction)
        client.close()
    }

    func testUnsolicitedEventsGoToTheHandler() async throws {
        let server = FakeJanusServer()
        let client = makeClient(server)
        let received = expectation(description: "event")
        let box = AsyncRecorder()
        client.onEvent = { message in
            box.add("\(message.kind.rawValue):\(message.sender ?? -1)")
            received.fulfill()
        }
        _ = try await client.connect()
        server.push(["janus": "slowlink", "sender": 2001, "uplink": false, "nacks": 3])
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(box.all, ["slowlink:2001"])
        client.close()
    }

    func testTrickleIsFireAndForget() async throws {
        let server = FakeJanusServer()
        let client = makeClient(server)
        _ = try await client.connect()
        let handle = try await client.attach()
        client.trickle(handle: handle, candidate: (sdpMid: "0", sdpMLineIndex: 0, candidate: "candidate:1"))
        client.trickle(handle: handle, candidate: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        let trickles = server.requests.filter { ($0["janus"] as? String) == "trickle" }
        XCTAssertEqual(trickles.count, 2)
        XCTAssertNotNil(trickles[0]["transaction"])
        client.close()
    }

    func testAnUnexpectedSocketCloseIsReportedAndCutsPendingRequests() async throws {
        let server = FakeJanusServer()
        server.swallow = ["publish"]
        let client = makeClient(server, timeout: 5)
        let closed = expectation(description: "closed")
        client.onTransportClosed = { _ in closed.fulfill() }
        _ = try await client.connect()
        let handle = try await client.attach()
        async let pending: JanusMessage = client.send(handle: handle, body: ["request": "publish"])
        try await Task.sleep(nanoseconds: 80_000_000)
        server.dropConnection()
        do {
            _ = try await pending
            XCTFail("must fail")
        } catch {
            XCTAssertEqual(error as? JanusClientError, .closed)
        }
        await fulfillment(of: [closed], timeout: 2)
        client.close()
    }

    func testReclaimReattachesTheSameSessionOnANewSocket() async throws {
        let first = FakeJanusServer()
        let second = FakeJanusServer()
        var sockets: [FakeJanusServer] = [first, second]
        var config = JanusClient.Config()
        config.requestTimeoutSeconds = 1
        let client = JanusClient(config: config, makeSocket: { sockets.removeFirst() }, token: { "tok" })
        let session = try await client.connect()
        first.dropConnection()
        try await Task.sleep(nanoseconds: 50_000_000)
        try await client.reclaim()
        XCTAssertEqual(client.sessionId, session)
        let claim = second.requests.first { ($0["janus"] as? String) == "claim" }
        XCTAssertEqual((claim?["session_id"] as? NSNumber)?.int64Value, session)
        client.close()
    }

    func testReclaimOfAGoneSessionFailsWith458() async throws {
        let first = FakeJanusServer()
        let second = FakeJanusServer()
        second.claimError = 458
        var sockets: [FakeJanusServer] = [first, second]
        var config = JanusClient.Config()
        config.requestTimeoutSeconds = 1
        let client = JanusClient(config: config, makeSocket: { sockets.removeFirst() }, token: { "tok" })
        _ = try await client.connect()
        first.dropConnection()
        try await Task.sleep(nanoseconds: 50_000_000)
        do {
            try await client.reclaim()
            XCTFail("must fail")
        } catch {
            XCTAssertEqual((error as? JanusClientError)?.code, 458)
        }
        client.close()
    }

    func testKeepaliveRunsOnItsInterval() async throws {
        let server = FakeJanusServer()
        let client = makeClient(server, keepalive: 0.1)
        _ = try await client.connect()
        try await Task.sleep(nanoseconds: 450_000_000)
        let keepalives = server.requests.filter { ($0["janus"] as? String) == "keepalive" }
        XCTAssertGreaterThanOrEqual(keepalives.count, 2)
        client.close()
    }

    func testRequestsAfterCloseFailFast() async throws {
        let server = FakeJanusServer()
        let client = makeClient(server)
        _ = try await client.connect()
        let handle = try await client.attach()
        client.close()
        do {
            _ = try await client.send(handle: handle, body: ["request": "join"])
            XCTFail("must fail")
        } catch {
            XCTAssertEqual(error as? JanusClientError, .notConnected)
        }
    }
}
