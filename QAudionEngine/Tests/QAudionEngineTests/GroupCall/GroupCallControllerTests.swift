import XCTest
@testable import QAudionEngine

// MARK: - Fakes

final class FakeMediaLink: GroupMediaLink, @unchecked Sendable {
    var onEvent: ((GroupMediaSession.Event) -> Void)?
    var onRemoteTrack: ((GroupRemoteTrack) -> Void)?
    var onLocalVideoTrack: ((AnyObject?) -> Void)?
    var publisherFilter: ((String) -> Bool)?

    private let lock = NSLock()
    private var log: [String] = []
    private var _tiles: [String] = []
    var startError: Error?
    var cameraResult: GroupCameraResult = .started
    /// Runs at the start of every `setMicrophoneEnabled`, before it is recorded: lets a
    /// test land another call in the middle of the wiring.
    var beforeMicrophone: ((Bool) -> Void)?

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    var tiles: [String] {
        lock.lock(); defer { lock.unlock() }
        return _tiles
    }

    private func record(_ entry: String) {
        lock.lock(); log.append(entry); lock.unlock()
    }

    func start(publishVideo: Bool) async throws {
        record("start video=\(publishVideo)")
        if let error = startError { throw error }
    }

    func setTile(pseudonym: String, tile: GroupLayerPolicy.TileClass, visible: Bool) {
        lock.lock(); _tiles.append("\(pseudonym.prefix(4)):\(tile.rawValue):\(visible)"); lock.unlock()
    }

    func setBackgrounded(_ value: Bool) { record("background=\(value)") }
    func refreshPublisherFilter() { record("refresh-filter") }
    func setPublishVideo(_ on: Bool) async { record("publish-video=\(on)") }
    func setMicrophoneEnabled(_ enabled: Bool) {
        beforeMicrophone?(enabled)
        record("mic=\(enabled)")
    }
    func setCameraEnabled(_ enabled: Bool) async -> GroupCameraResult {
        record("camera=\(enabled)")
        return enabled ? cameraResult : .stopped
    }
    func setActiveLayers(_ count: Int) { record("layers=\(count)") }
    func requestPublisherKeyFrame() async { record("keyframe") }
    func networkPathChanged(reason: String) async { record("path=\(reason)") }
    func updateSessionToken(_ token: String) { record("token=\(token)") }
    func updateIceServers(_ servers: [GroupCallWire.IceServer]) { record("ice=\(servers.first?.username ?? "")") }
    func close() { record("close") }

    /// Emits a session event as the real session would.
    func emit(_ event: GroupMediaSession.Event) { onEvent?(event) }
}

final class FakeMediaBackend: GroupMediaBackend, @unchecked Sendable {
    var onMissingKey: ((String) -> Void)?
    var onDecryptFailure: ((String) -> Void)?
    var onCryptorOk: ((String) -> Void)?

    private let lock = NSLock()
    private var _links: [FakeMediaLink] = []
    private var _keys: [(participant: String, index: Int32, key: Data)] = []
    private var _sendIndexes: [Int32] = []
    private var _begins = 0
    private var _ends = 0
    var startError: Error?
    /// Handed to every link made from now on (`FakeMediaLink.beforeMicrophone`).
    var microphoneHook: ((Bool) -> Void)?

    var links: [FakeMediaLink] { lock.lock(); defer { lock.unlock() }; return _links }
    var keys: [(participant: String, index: Int32, key: Data)] { lock.lock(); defer { lock.unlock() }; return _keys }
    var sendIndexes: [Int32] { lock.lock(); defer { lock.unlock() }; return _sendIndexes }
    var begins: Int { lock.lock(); defer { lock.unlock() }; return _begins }
    var ends: Int { lock.lock(); defer { lock.unlock() }; return _ends }

    func beginCall() { lock.lock(); _begins += 1; lock.unlock() }

    func installKey(_ key: Data, index: Int32, participantId: String) {
        lock.lock(); _keys.append((participantId, index, key)); lock.unlock()
    }

    func setSendKeyIndex(_ index: Int32) { lock.lock(); _sendIndexes.append(index); lock.unlock() }

    func makeLink(ready: GroupCallWire.MediaReady) async throws -> GroupMediaLink {
        let link = FakeMediaLink()
        link.startError = startError
        link.beforeMicrophone = microphoneHook
        lock.lock(); _links.append(link); lock.unlock()
        return link
    }

    func endCall() { lock.lock(); _ends += 1; lock.unlock() }
}

final class FakeAudioUnit: GroupAudioUnitControlling {
    var onNeedsSessionActivation: (() -> Void)?
    private let lock = NSLock()
    private var log: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return log }
    private func record(_ entry: String) { lock.lock(); log.append(entry); lock.unlock() }
    func begin() { record("begin") }
    func sessionActivated(source: AudioSessionActivationSource) { record("activated=\(source.rawValue)") }
    func sessionDeactivated() { record("deactivated") }
    func oneToOneEnded() { record("oneToOneEnded") }
    func end() { record("end") }
}

final class FakePathMonitor: GroupPathMonitoring {
    private(set) var started = 0
    private(set) var stopped = 0
    private var handler: ((String) -> Void)?
    func start(_ handler: @escaping (String) -> Void) { started += 1; self.handler = handler }
    func stop() { stopped += 1 }
    func fire(_ reason: String) { handler?(reason) }
}

// MARK: - Harness

/// A controller over a manager whose outbound messages are captured, a fake media
/// backend and fake audio / path monitors: every rule below is exercised without a
/// socket or a PeerConnection.
final class ControllerHarness: @unchecked Sendable {
    static let selfUser = "user-self"
    static let peerB = "user-b"
    static let peerC = "user-c"
    static let callId = "11111111-2222-3333-4444-555555555555"

    let manager: BCryptoGroupCallManager
    let backend = FakeMediaBackend()
    let audio = FakeAudioUnit()
    let paths = FakePathMonitor()
    let controller: GroupCallController
    private let lock = NSLock()
    private var _sent: [(type: String, data: [String: Any])] = []
    private var _control: [(peer: String, json: String)] = []
    private var _telemetry: [String] = []
    private var _errors: [GroupCallMediaError] = []
    private var _states: [GroupCallController.State] = []
    var controlSendResult = true

    init(iceRefreshRetrySeconds: Double = 60, mediaReadyTimeoutSeconds: Double = 10,
         tokenReplyTimeoutSeconds: Double = 8, tokenRetryBackoffSeconds: [Double] = [6, 12, 24, 48]) {
        let ws = BCryptoWebSocketClient(config: BackendConfig(serverUrl: "https://example.invalid"))
        manager = BCryptoGroupCallManager(ws: ws, selfUserId: Self.selfUser, nameResolver: { $0 })
        controller = GroupCallController(manager: manager, backend: backend, audio: audio, pathMonitor: paths,
                                         iceRefreshRetrySeconds: iceRefreshRetrySeconds,
                                         mediaReadyTimeoutSeconds: mediaReadyTimeoutSeconds,
                                         tokenReplyTimeoutSeconds: tokenReplyTimeoutSeconds,
                                         tokenRetryBackoffSeconds: tokenRetryBackoffSeconds)
        manager.sendOverride = { [weak self] type, data in
            self?.lock.lock(); self?._sent.append((type, data)); self?.lock.unlock()
        }
        controller.onSendControlEnvelope = { [weak self] peer, _, json in
            guard let self = self else { return false }
            self.lock.lock(); self._control.append((peer, json)); self.lock.unlock()
            return self.controlSendResult
        }
        controller.groupTelemetry = { [weak self] kind, _, _ in
            self?.lock.lock(); self?._telemetry.append(kind); self?.lock.unlock()
        }
        controller.onMediaError = { [weak self] error in
            self?.lock.lock(); self?._errors.append(error); self?.lock.unlock()
        }
        controller.onStateChange = { [weak self] state in
            self?.lock.lock(); self?._states.append(state); self?.lock.unlock()
        }
    }

    var sent: [(type: String, data: [String: Any])] { lock.lock(); defer { lock.unlock() }; return _sent }
    var sentTypes: [String] { sent.map { $0.type } }
    var control: [(peer: String, json: String)] { lock.lock(); defer { lock.unlock() }; return _control }
    var telemetry: [String] { lock.lock(); defer { lock.unlock() }; return _telemetry }
    var errors: [GroupCallMediaError] { lock.lock(); defer { lock.unlock() }; return _errors }
    var states: [GroupCallController.State] { lock.lock(); defer { lock.unlock() }; return _states }

    static let pseudoSelf = GroupCallFixtures.pseudoA
    static let pseudoB = GroupCallFixtures.pseudoB
    static let pseudoC = GroupCallFixtures.pseudoC

    func update(epoch: UInt32, members: [String]? = nil, withMedia: Bool = true,
                callId: String = ControllerHarness.callId) -> GroupCallWire.Update {
        let roster = members ?? [Self.selfUser, Self.peerB]
        var map: [String: String] = [:]
        if withMedia {
            map[Self.selfUser] = Self.pseudoSelf
            map[Self.peerB] = Self.pseudoB
            map[Self.peerC] = Self.pseudoC
            map = map.filter { roster.contains($0.key) }
        }
        return GroupCallWire.Update(callId: callId, participants: roster, epoch: epoch,
                                    nodeId: withMedia ? "node-a" : nil, pseudonyms: map)
    }

    func ready(callId: String = ControllerHarness.callId) -> GroupCallWire.MediaReady {
        var dictionary = GroupCallFixtures.readyDictionary()
        dictionary["call_id"] = callId
        return GroupCallWire.MediaReady.parse(dictionary)!
    }

    func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// join -> update (no media yet, or with the pseudonym map) -> media_ready -> link started.
    func joinAndConnect(video: Bool = false, epoch: UInt32 = 1, members: [String]? = nil,
                        mediaInUpdate: Bool = false, startMuted: Bool = false) async -> FakeMediaLink? {
        controller.join(callId: Self.callId, video: video, startMuted: startMuted)
        manager.onGroupUpdate?(update(epoch: epoch, members: members, withMedia: mediaInUpdate))
        manager.onMediaReady?(ready())
        _ = await waitUntil { !self.backend.links.isEmpty && self.backend.links[0].calls.contains { $0.hasPrefix("start") } }
        return backend.links.first
    }

    /// createCall (the creating side of a 1:1 -> group promotion) -> media_ready -> link started.
    /// The call id is the one the manager minted. The server sends the creator NO
    /// `group_call_update` until somebody joins, so none is injected here: the creator asks for
    /// its media by itself, right after the create.
    func createAndConnect(startMuted: Bool) async -> FakeMediaLink? {
        guard let id = controller.createCall(invitees: [Self.peerB], promotedFromCallId: "one-to-one-call",
                                             startMuted: startMuted) else { return nil }
        manager.onMediaReady?(ready(callId: id))
        _ = await waitUntil { !self.backend.links.isEmpty && self.backend.links[0].calls.contains { $0.hasPrefix("start") } }
        return backend.links.first
    }
}

// MARK: - Tests

final class GroupCallControllerTests: XCTestCase {

    /// A `media_key` as `peerB` sends it (its own pseudonym in `p`), unless told otherwise.
    private func keyEnvelope(epoch: UInt32, from fill: UInt8, callId: String = ControllerHarness.callId,
                             pseudonym: String = ControllerHarness.pseudoB) -> String {
        GroupKeyEnvelope.mediaKey(callId: callId, epoch: epoch, index: GroupE2ee.keyIndex(forEpoch: epoch),
                                  key: GroupCallFixtures.keyBytes(fill), pseudonym: pseudonym).encode()!
    }

    // MARK: media join / ready

    func testFirstUpdateRequestsMediaJoinExactlyOnce() async {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId)
        XCTAssertEqual(h.controller.state, .connecting(callId: ControllerHarness.callId))
        XCTAssertEqual(h.sentTypes, ["group_call_join"])
        h.manager.onGroupUpdate?(h.update(epoch: 1, withMedia: false))
        h.manager.onGroupUpdate?(h.update(epoch: 2, withMedia: false))
        XCTAssertEqual(h.sentTypes.filter { $0 == "group_call_media_join" }.count, 1)
        h.controller.leave()
    }

    func testMediaReadyBuildsTheLinkAndPublishesWithTheCallType() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect(video: true)
        XCTAssertNotNil(link)
        XCTAssertEqual(link?.calls.first, "mic=true")
        XCTAssertTrue(link?.calls.contains("start video=true") ?? false)
        XCTAssertEqual(h.backend.begins, 1)
        XCTAssertTrue(h.controller.hasMediaLink)
        // group.media_join telemetry follows the start.
        let joined = await h.waitUntil { h.telemetry.contains("group.media_join") }
        XCTAssertTrue(joined)
        h.controller.leave()
    }

    func testMediaReadyForAnotherCallIsIgnored() async {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId)
        h.manager.onMediaReady?(h.ready(callId: "99999999-0000-0000-0000-000000000000"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(h.backend.links.isEmpty)
        h.controller.leave()
    }

    func testPublisherConnectedFiresMediaConnectedOnceAndTelemetry() async {
        let h = ControllerHarness()
        let connected = expectation(description: "media connected")
        connected.assertForOverFulfill = true
        h.controller.onMediaConnected = { connected.fulfill() }
        guard let link = await h.joinAndConnect() else { return XCTFail("no link") }
        link.emit(.pcState(.pub, .connected))
        link.emit(.pcState(.sub, .connected))
        link.emit(.pcState(.pub, .connected))
        await fulfillment(of: [connected], timeout: 2)
        XCTAssertTrue(h.controller.isMediaConnected)
        XCTAssertTrue(h.telemetry.contains("call.media.connected"))
        link.emit(.pcState(.pub, .disconnected))
        XCTAssertFalse(h.controller.isMediaConnected)
        h.controller.leave()
    }

    // MARK: E2EE v2

    func testUpdateWithPseudonymsInstallsOwnKeyAndSendsItToEveryOtherMember() async {
        let h = ControllerHarness()
        _ = await h.joinAndConnect(members: [ControllerHarness.selfUser, ControllerHarness.peerB, ControllerHarness.peerC],
                                   mediaInUpdate: true)
        let sent = await h.waitUntil { h.control.count >= 2 }
        XCTAssertTrue(sent)
        XCTAssertEqual(Set(h.control.map { $0.peer }), [ControllerHarness.peerB, ControllerHarness.peerC])
        // Own key: slot 1 for our own pseudonym, 32 bytes.
        let own = h.backend.keys.first { $0.participant == ControllerHarness.pseudoSelf }
        XCTAssertEqual(own?.index, 1)
        XCTAssertEqual(own?.key.count, 32)
        // The sent envelopes carry exactly that key.
        for entry in h.control {
            guard case .envelope(.mediaKey(_, let epoch, let index, let key, let pseudonym)) = GroupKeyEnvelope.parse(json: entry.json) else {
                return XCTFail("not a media_key envelope")
            }
            XCTAssertEqual(epoch, 1)
            XCTAssertEqual(index, 1)
            XCTAssertEqual(key, own?.key)
            XCTAssertEqual(pseudonym, ControllerHarness.pseudoSelf, "p is the sender's own pseudonym (spec 12.5)")
        }
        h.controller.leave()
    }

    func testSendIndexSwitchesOnceEveryMemberAcked() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect()
        h.manager.onGroupUpdate?(h.update(epoch: 3))
        _ = await h.waitUntil { !h.control.isEmpty }
        XCTAssertTrue(h.backend.sendIndexes.isEmpty, "not before the ack")
        h.controller.onGroupCallControlEnvelope(
            json: GroupKeyEnvelope.ack(callId: ControllerHarness.callId, epoch: 3).encode()!, fromUserId: ControllerHarness.peerB)
        let switched = await h.waitUntil { h.backend.sendIndexes == [3] }
        XCTAssertTrue(switched)
        // ... and a key frame is forced on the publisher afterwards.
        let keyframe = await h.waitUntil { link?.calls.contains("keyframe") ?? false }
        XCTAssertTrue(keyframe)
        h.controller.leave()
    }

    func testIncomingKeyIsInstalledForThePublisherPseudonymAndAcked() async {
        let h = ControllerHarness()
        _ = await h.joinAndConnect()
        h.manager.onGroupUpdate?(h.update(epoch: 1))
        h.controller.onGroupCallControlEnvelope(json: keyEnvelope(epoch: 1, from: 0x42), fromUserId: ControllerHarness.peerB)
        let installed = await h.waitUntil { h.backend.keys.contains { $0.participant == ControllerHarness.pseudoB } }
        XCTAssertTrue(installed)
        let key = h.backend.keys.first { $0.participant == ControllerHarness.pseudoB }
        XCTAssertEqual(key?.key, GroupCallFixtures.keyBytes(0x42))
        XCTAssertEqual(key?.index, 1)
        let acked = await h.waitUntil {
            h.control.contains { entry in
                if case .envelope(.ack) = GroupKeyEnvelope.parse(json: entry.json) { return entry.peer == ControllerHarness.peerB }
                return false
            }
        }
        XCTAssertTrue(acked)
        h.controller.leave()
    }

    func testAKeyThatArrivesBeforeTheJoinIsKeptAndInstalledOnceTheRosterIsKnown() async {
        let h = ControllerHarness()
        // The push-woken accept joins later than the peers' keys arrive.
        h.controller.onGroupCallControlEnvelope(json: keyEnvelope(epoch: 1, from: 0x51), fromUserId: ControllerHarness.peerB)
        // A key of ANOTHER call is never replayed into this one.
        h.controller.onGroupCallControlEnvelope(json: keyEnvelope(epoch: 1, from: 0x52, callId: "other-call"), fromUserId: ControllerHarness.peerB)
        _ = await h.joinAndConnect(mediaInUpdate: true)
        let installed = await h.waitUntil { h.backend.keys.contains { $0.participant == ControllerHarness.pseudoB } }
        XCTAssertTrue(installed)
        let keys = h.backend.keys.filter { $0.participant == ControllerHarness.pseudoB }
        XCTAssertEqual(keys.map { $0.key }, [GroupCallFixtures.keyBytes(0x51)])
        h.controller.leave()
    }

    func testV1EnvelopeAndAKeyFromAStrangerAreDropped() async {
        let h = ControllerHarness()
        _ = await h.joinAndConnect()
        h.manager.onGroupUpdate?(h.update(epoch: 1))
        // A removed v1 envelope.
        h.controller.onGroupCallControlEnvelope(
            json: "{\"qa_grp\":1,\"t\":\"sender_key_init\",\"g\":\"00\",\"e\":1,\"seed\":\"AA\",\"idx\":0}",
            fromUserId: ControllerHarness.peerB)
        // A well-formed key from somebody who is not a member: held as pending, never installed.
        h.controller.onGroupCallControlEnvelope(json: keyEnvelope(epoch: 1, from: 0x33), fromUserId: "user-stranger")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(h.backend.keys.contains { $0.key == GroupCallFixtures.keyBytes(0x33) })
        XCTAssertFalse(h.backend.keys.contains { $0.participant != ControllerHarness.pseudoSelf })
        h.controller.leave()
    }

    func testMissingKeyReportedByTheBackendSendsANack() async {
        let h = ControllerHarness()
        _ = await h.joinAndConnect()
        h.manager.onGroupUpdate?(h.update(epoch: 2))
        h.backend.onMissingKey?(ControllerHarness.pseudoB)
        let nacked = await h.waitUntil {
            h.control.contains { entry in
                if case .envelope(.nack) = GroupKeyEnvelope.parse(json: entry.json) { return entry.peer == ControllerHarness.peerB }
                return false
            }
        }
        XCTAssertTrue(nacked)
        h.controller.leave()
    }

    // MARK: tracks / tiles

    func testRemoteTracksAreMappedFromPseudonymToUser() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect()
        h.manager.onGroupUpdate?(h.update(epoch: 1))
        let seen = LockedBox<[String]>([])
        h.controller.onRemoteVideoTrack = { identity, track in seen.mutate { $0.append("video:\(identity):\(track != nil)") } }
        h.controller.onRemoteAudioTrack = { identity, track in seen.mutate { $0.append("audio:\(identity):\(track != nil)") } }
        h.controller.onRemoteScreenShareTrack = { identity, track in seen.mutate { $0.append("screen:\(identity):\(track != nil)") } }
        let marker = NSObject()
        link?.onRemoteTrack?(GroupRemoteTrack(feedId: ControllerHarness.pseudoB, mid: "1", kind: .video, isScreenShare: false, track: marker))
        link?.onRemoteTrack?(GroupRemoteTrack(feedId: ControllerHarness.pseudoB, mid: "2", kind: .audio, isScreenShare: false, track: marker))
        link?.onRemoteTrack?(GroupRemoteTrack(feedId: ControllerHarness.pseudoB, mid: "3", kind: .video, isScreenShare: true, track: nil))
        // A feed the roster does not know is never rendered.
        link?.onRemoteTrack?(GroupRemoteTrack(feedId: String(repeating: "ee", count: 16), mid: "4", kind: .video, isScreenShare: false, track: marker))
        XCTAssertEqual(seen.value, ["video:user-b:true", "audio:user-b:true", "screen:user-b:false"])
        h.controller.leave()
    }

    func testTileRequestsAreRememberedAndAppliedWhenThePublisherAppears() async {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId)
        h.controller.setRemoteVideoRenderPriority(identity: ControllerHarness.peerB, priority: .onScreenSpotlight)
        h.manager.onGroupUpdate?(h.update(epoch: 1, withMedia: false))
        h.manager.onMediaReady?(h.ready())
        _ = await h.waitUntil { h.backend.links.first?.calls.contains { $0.hasPrefix("start") } ?? false }
        guard let link = h.backend.links.first else { return XCTFail("no link") }
        h.manager.onGroupUpdate?(h.update(epoch: 1))
        link.emit(.remotePublishers([]))
        let applied = await h.waitUntil { link.tiles.contains("b2b2:2:true") }
        XCTAssertTrue(applied, "tiles: \(link.tiles)")
        h.controller.leave()
    }

    func testPublisherFilterAdmitsOnlyCurrentMembers() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect()
        h.manager.onGroupUpdate?(h.update(epoch: 1))
        XCTAssertEqual(link?.publisherFilter?(ControllerHarness.pseudoB), true)
        XCTAssertEqual(link?.publisherFilter?(ControllerHarness.pseudoC), false, "C is not in the roster")
        XCTAssertEqual(link?.publisherFilter?(ControllerHarness.pseudoSelf), false, "never subscribe to ourselves")
        XCTAssertEqual(link?.publisherFilter?(String(repeating: "ee", count: 16)), false)
        h.controller.leave()
    }

    func testAudioLevelsBecomeActiveSpeakersByUserId() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect()
        h.manager.onGroupUpdate?(h.update(epoch: 1))
        let speakers = LockedBox<[String]>([])
        h.controller.onActiveSpeakersChanged = { ids in speakers.mutate { $0 = ids } }
        link?.emit(.audioLevels([ControllerHarness.pseudoB: 0.4]))
        XCTAssertEqual(speakers.value, [ControllerHarness.peerB])
        h.controller.leave()
    }

    // MARK: recovery

    func testNeedsRejoinAsksTheServerAfterTheBackoffAndClosesTheOldLink() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect()
        link?.emit(.needsRejoin("pc_failed"))
        XCTAssertTrue(link?.calls.contains("close") ?? false)
        let asked = await h.waitUntil(2) { h.sentTypes.contains("group_call_media_rejoin") }
        XCTAssertTrue(asked)
        let rejoin = h.sent.first { $0.type == "group_call_media_rejoin" }
        XCTAssertEqual(rejoin?.data["reason"] as? String, "pc_failed")
        XCTAssertTrue(h.telemetry.contains("group.rejoin"))
        // A second media_ready builds a new link; the keys stay untouched (no beginCall again).
        h.manager.onMediaReady?(h.ready())
        let rebuilt = await h.waitUntil { h.backend.links.count == 2 }
        XCTAssertTrue(rebuilt)
        XCTAssertEqual(h.backend.begins, 1)
        h.controller.leave()
    }

    func testEventsOfAReplacedLinkAreIgnored() async {
        let h = ControllerHarness()
        let old = await h.joinAndConnect()
        h.manager.onMediaReady?(h.ready())
        _ = await h.waitUntil { h.backend.links.count == 2 }
        old?.emit(.needsRejoin("pc_failed"))
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(h.sentTypes.contains("group_call_media_rejoin"))
        h.controller.leave()
    }

    func testFullRoomIsAClearErrorAndTheCallEnds() async {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId)
        h.manager.onGroupUpdate?(h.update(epoch: 1, withMedia: false))
        h.manager.onMediaUnavailable?(ControllerHarness.callId, .full)
        XCTAssertEqual(h.errors, [.full])
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertTrue(h.sentTypes.contains("group_call_leave"))
        XCTAssertTrue(h.states.contains(.failed(reason: "media_error")))
        XCTAssertEqual(h.backend.ends, 1)
    }

    func testDtlsPinMismatchIsFatal() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect()
        link?.emit(.failed(.dtlsPinMismatch(pc: .pub)))
        XCTAssertEqual(h.errors, [.transportPolicy])
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertTrue(link?.calls.contains("close") ?? false)
    }

    func testRetryableJanusErrorGetsOneAutomaticRejoinThenAnError() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect()
        link?.emit(.janusFailure(.plugin(code: 428, reason: "no such feed")))
        let rejoins = await h.waitUntil { h.sentTypes.filter { $0 == "group_call_media_rejoin" }.count == 1 }
        XCTAssertTrue(rejoins)
        XCTAssertEqual(h.sent.first { $0.type == "group_call_media_rejoin" }?.data["reason"] as? String, "janus_428")
        XCTAssertEqual(h.sentTypes.filter { $0 == "group_call_media_join" }.count, 1, "no plain join for a session that was torn down")
        h.manager.onMediaReady?(h.ready())
        _ = await h.waitUntil { h.backend.links.count == 2 }
        h.backend.links[1].emit(.janusFailure(.plugin(code: 428, reason: "no such feed")))
        let failed = await h.waitUntil { !h.errors.isEmpty }
        XCTAssertTrue(failed)
        XCTAssertEqual(h.errors, [.mediaLost])
    }

    func testStartFailureWithAnUnauthorizedCodeIsAnError() async {
        let h = ControllerHarness()
        h.backend.startError = JanusClientError.plugin(code: 436, reason: "unauthorized")
        h.controller.join(callId: ControllerHarness.callId)
        h.manager.onGroupUpdate?(h.update(epoch: 1, withMedia: false))
        h.manager.onMediaReady?(h.ready())
        let failed = await h.waitUntil { !h.errors.isEmpty }
        XCTAssertTrue(failed)
        XCTAssertEqual(h.errors, [.other("janus_436")])
        XCTAssertEqual(h.controller.state, .idle)
    }

    func testARefreshRequestOfTheSessionIsSentToTheServer() async {
        let h = ControllerHarness()
        guard let link = await h.joinAndConnect() else { return XCTFail("no link") }
        link.emit(.tokenRefresh("periodic"))
        // A round that is already being retried covers the next trigger (single-flight).
        link.emit(.tokenRefresh("ws_reconnect"))
        XCTAssertEqual(h.sentTypes.filter { $0 == "group_call_media_refresh" }.count, 1)
        let refresh = h.sent.first { $0.type == "group_call_media_refresh" }
        XCTAssertEqual(refresh?.data["call_id"] as? String, ControllerHarness.callId)
        h.controller.leave()
    }

    // MARK: Janus token refresh: timeout + retry (LC-6)

    private func refreshCount(_ h: ControllerHarness) -> Int { h.sentTypes.filter { $0 == "group_call_media_refresh" }.count }

    /// The server drops an over-budget refresh without an answer and the app socket can lose a
    /// frame: the token lives 600 s, so one lost request must not wait for the next 300 s tick.
    func testAnUnansweredTokenRefreshIsAskedAgainAndGivesUpWithARejoinBeforeTheTokenExpires() async {
        let h = ControllerHarness(tokenReplyTimeoutSeconds: 0.05, tokenRetryBackoffSeconds: [0.05, 0.05])
        guard let link = await h.joinAndConnect() else { return XCTFail("no link") }
        link.emit(.tokenRefresh("periodic"))
        XCTAssertEqual(refreshCount(h), 1)
        let three = await h.waitUntil { self.refreshCount(h) == 3 }
        XCTAssertTrue(three, "an attempt, then two more after the pauses")
        // Nobody answered any of them: the media is rejoined while the old token is still good.
        let rejoined = await h.waitUntil { h.sent.contains { $0.type == "group_call_media_rejoin" } }
        XCTAssertTrue(rejoined)
        XCTAssertEqual(h.sent.first { $0.type == "group_call_media_rejoin" }?.data["reason"] as? String, "token_refresh")
        XCTAssertEqual(refreshCount(h), 3, "no attempt beyond the round")
        h.controller.leave()
    }

    func testAnAnsweredTokenRefreshStopsItsRetries() async {
        let h = ControllerHarness(tokenReplyTimeoutSeconds: 0.05, tokenRetryBackoffSeconds: [0.05, 0.05])
        guard let link = await h.joinAndConnect() else { return XCTFail("no link") }
        link.emit(.tokenRefresh("periodic"))
        h.manager.onMediaToken?(GroupCallWire.MediaToken(callId: ControllerHarness.callId, sessionToken: "fresh-1", ttlSeconds: 600))
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(refreshCount(h), 1)
        XCTAssertFalse(h.sentTypes.contains("group_call_media_rejoin"))
        XCTAssertTrue(link.calls.contains("token=fresh-1"))
        // The next periodic refresh starts a new round.
        link.emit(.tokenRefresh("periodic"))
        XCTAssertEqual(refreshCount(h), 2)
        h.controller.leave()
    }

    func testALateAnswerOfALaterAttemptEndsTheRound() async {
        let h = ControllerHarness(tokenReplyTimeoutSeconds: 0.4, tokenRetryBackoffSeconds: [0.05, 0.05])
        guard let link = await h.joinAndConnect() else { return XCTFail("no link") }
        link.emit(.tokenRefresh("periodic"))
        _ = await h.waitUntil { self.refreshCount(h) == 2 }
        h.manager.onMediaToken?(GroupCallWire.MediaToken(callId: ControllerHarness.callId, sessionToken: "fresh-2", ttlSeconds: 600))
        try? await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(refreshCount(h), 2, "answered: nothing more is asked")
        XCTAssertFalse(h.sentTypes.contains("group_call_media_rejoin"))
        h.controller.leave()
    }

    func testATokenRefreshOfALinkThatWasReplacedIsNeverRetried() async {
        let h = ControllerHarness(tokenReplyTimeoutSeconds: 0.05, tokenRetryBackoffSeconds: [0.05, 0.05])
        guard let link = await h.joinAndConnect() else { return XCTFail("no link") }
        link.emit(.tokenRefresh("periodic"))
        h.manager.onMediaReady?(h.ready())          // a fresh hand-out replaces the link (and carries its own token)
        _ = await h.waitUntil { h.backend.links.count == 2 }
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(refreshCount(h), 1, "the old link's round is over")
        XCTAssertFalse(h.sentTypes.contains("group_call_media_rejoin"))
        h.controller.leave()
    }

    // MARK: hourly TURN refresh (desktop parity)

    /// A hand-out of the running call (same room, node, pseudonym, certificate) with fresh credentials.
    private func refreshedReady(_ h: ControllerHarness, room: String? = nil) -> GroupCallWire.MediaReady {
        var dictionary = GroupCallFixtures.readyDictionary()
        dictionary["call_id"] = ControllerHarness.callId
        dictionary["session_token"] = "fresh-token"
        dictionary["ice_servers"] = [["urls": ["turn:turn2.example.invalid:3478"], "username": "fresh-user", "credential": "fresh-secret"]]
        if let room = room { dictionary["room"] = room }
        return GroupCallWire.MediaReady.parse(dictionary)!
    }

    func testTheHourlyRefreshAsksForAFreshHandOutWithAPlainMediaJoin() async {
        let h = ControllerHarness()
        guard let link = await h.joinAndConnect() else { return XCTFail("no link") }
        let before = h.sentTypes.filter { $0 == "group_call_media_join" }.count
        link.emit(.iceRefresh)
        XCTAssertEqual(h.sentTypes.filter { $0 == "group_call_media_join" }.count, before + 1)
        XCTAssertFalse(h.sentTypes.contains("group_call_media_rejoin"), "a plain join, not a rejoin")
        h.controller.leave()
    }

    func testTheFreshHandOutIsAppliedInPlaceAndTheMediaIsNotRebuilt() async {
        let h = ControllerHarness()
        guard let link = await h.joinAndConnect() else { return XCTFail("no link") }
        link.emit(.iceRefresh)
        h.manager.onMediaReady?(refreshedReady(h))
        XCTAssertEqual(h.backend.links.count, 1, "no new link")
        XCTAssertFalse(link.calls.contains("close"), "the running media is not touched")
        XCTAssertTrue(link.calls.contains("ice=fresh-user"))
        XCTAssertTrue(link.calls.contains("token=fresh-token"), "the hand-out carries a fresh session token too")
        XCTAssertEqual(link.calls.filter { $0.hasPrefix("start") }.count, 1)
        h.controller.leave()
    }

    func testAHandOutForAnotherRoomIsANewPathAndRebuildsTheLink() async {
        let h = ControllerHarness()
        guard let link = await h.joinAndConnect() else { return XCTFail("no link") }
        h.manager.onMediaReady?(refreshedReady(h, room: String(repeating: "1f", count: 16)))
        let rebuilt = await h.waitUntil { h.backend.links.count == 2 }
        XCTAssertTrue(rebuilt)
        XCTAssertTrue(link.calls.contains("close"), "the old path is closed")
        h.controller.leave()
    }

    func testAnyRefusalOfTheRefreshEndsTheMediaTheServerNeverAnswersAThrottledOne() async {
        let h = ControllerHarness()
        guard let link = await h.joinAndConnect() else { return XCTFail("no link") }
        link.emit(.iceRefresh)
        // The server drops an over-budget request without any answer: a reason it never sends
        // (this one) is an unknown reason, a visible error like every other refusal.
        h.manager.onMediaUnavailable?(ControllerHarness.callId, GroupCallWire.UnavailableReason(wire: "throttled"))
        let ended = await h.waitUntil { h.errors.contains(.other("throttled")) }
        XCTAssertTrue(ended, "a refusal means something: it is an error")
        XCTAssertTrue(link.calls.contains("close"))
    }

    func testAnUnansweredRefreshIsAskedAgainThreeTimesAtMostThenLeftToTheNextHour() async {
        let h = ControllerHarness(iceRefreshRetrySeconds: 0.05)
        guard let link = await h.joinAndConnect() else { return XCTFail("no link") }
        let before = h.sentTypes.filter { $0 == "group_call_media_join" }.count
        link.emit(.iceRefresh)
        let asked = await h.waitUntil { h.sentTypes.filter { $0 == "group_call_media_join" }.count == before + 3 }
        XCTAssertTrue(asked)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(h.sentTypes.filter { $0 == "group_call_media_join" }.count, before + 3, "three attempts a round")
        XCTAssertFalse(link.calls.contains("close"), "an unanswered refresh never costs the media")
        h.controller.leave()
    }

    func testAnAnsweredRefreshStopsItsRetryTimer() async {
        let h = ControllerHarness(iceRefreshRetrySeconds: 0.05)
        guard let link = await h.joinAndConnect() else { return XCTFail("no link") }
        let before = h.sentTypes.filter { $0 == "group_call_media_join" }.count
        link.emit(.iceRefresh)
        h.manager.onMediaReady?(refreshedReady(h))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(h.sentTypes.filter { $0 == "group_call_media_join" }.count, before + 1)
        h.controller.leave()
    }

    func testTheFreshTokenReachesTheLiveLinkOnlyForThisCall() async {
        let h = ControllerHarness()
        guard let link = await h.joinAndConnect() else { return XCTFail("no link") }
        h.manager.onMediaToken?(GroupCallWire.MediaToken(callId: ControllerHarness.callId, sessionToken: "fresh-1", ttlSeconds: 600))
        h.manager.onMediaToken?(GroupCallWire.MediaToken(callId: "another-call", sessionToken: "fresh-2", ttlSeconds: 600))
        XCTAssertEqual(link.calls.filter { $0.hasPrefix("token=") }, ["token=fresh-1"])
        h.controller.leave()
    }

    func testNotAMemberAnymoreAnswersTheRefreshWithAnErrorAndEndsTheMedia() async {
        let h = ControllerHarness()
        guard let link = await h.joinAndConnect() else { return XCTFail("no link") }
        link.emit(.tokenRefresh("periodic"))
        h.manager.onMediaUnavailable?(ControllerHarness.callId, .notMember)
        let ended = await h.waitUntil { h.errors.contains(.notMember) }
        XCTAssertTrue(ended, "the refusal ends the media like any other one")
        XCTAssertTrue(link.calls.contains("close"))
    }

    func testARejoinThatGetsNoAnswerIsAskedAgainAsARejoinNeverAsAPlainJoin() async {
        // The server answers nothing to a member over its request budget: the wait ends in
        // the SAME kind of request, after the timeout (never a tight loop).
        let h = ControllerHarness(mediaReadyTimeoutSeconds: 0.3)
        let link = await h.joinAndConnect()
        link?.emit(.needsRejoin("ws_lost"))
        let twice = await h.waitUntil(4) { h.sentTypes.filter { $0 == "group_call_media_rejoin" }.count == 2 }
        XCTAssertTrue(twice)
        let reasons = h.sent.filter { $0.type == "group_call_media_rejoin" }.map { $0.data["reason"] as? String }
        XCTAssertEqual(reasons, ["ws_lost", "ws_lost"])
        XCTAssertEqual(h.sentTypes.filter { $0 == "group_call_media_join" }.count, 1, "only the very first join of the call")
        h.controller.leave()
    }

    func testAFirstJoinThatGetsNoAnswerIsAskedAgainAsAJoin() async {
        let h = ControllerHarness(mediaReadyTimeoutSeconds: 0.3)
        h.controller.join(callId: ControllerHarness.callId)
        h.manager.onGroupUpdate?(h.update(epoch: 1, withMedia: false))
        let twice = await h.waitUntil(4) { h.sentTypes.filter { $0 == "group_call_media_join" }.count == 2 }
        XCTAssertTrue(twice)
        XCTAssertFalse(h.sentTypes.contains("group_call_media_rejoin"))
        h.controller.leave()
    }

    // MARK: creator media start (SIG-2 / LC-1)

    /// The server never sends the creator a `group_call_update` until somebody joins: the
    /// creator must ask for its media right after the create, like Android and desktop, instead
    /// of waiting for the first invitee to accept (a promotion from a 1:1 is abandoned after 30 s).
    func testTheCreatorAsksForItsMediaRightAfterTheCreateWithoutAnyUpdate() async {
        let h = ControllerHarness()
        let id = h.controller.createCall(invitees: [ControllerHarness.peerB], promotedFromCallId: "one-to-one-call")
        XCTAssertNotNil(id)
        XCTAssertEqual(h.sentTypes, ["group_call_create", "group_call_media_join"], "both frames, in order, no update needed")
        XCTAssertEqual(h.sent[1].data["call_id"] as? String, id)
        // The first update (an invitee joined) does not ask a second time.
        h.manager.onGroupUpdate?(h.update(epoch: 2, withMedia: false, callId: id ?? ""))
        XCTAssertEqual(h.sentTypes.filter { $0 == "group_call_media_join" }.count, 1)
        h.controller.leave()
    }

    func testTheCreatorsMediaComesUpWithoutAnyUpdate() async {
        let h = ControllerHarness()
        let link = await h.createAndConnect(startMuted: false)
        XCTAssertNotNil(link, "media_ready alone builds the link")
        XCTAssertTrue(h.controller.hasMediaLink)
        h.controller.leave()
    }

    // MARK: refused media (SIG-6 / LC-7)

    func testAnEntitlementDenialOfTheMediaEndsTheAttemptOnceAndIsNeverRetried() async {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId)
        h.manager.onGroupUpdate?(h.update(epoch: 1, withMedia: false))
        h.manager.onMediaUnavailable?(ControllerHarness.callId, .entitlement)
        XCTAssertEqual(h.errors, [.entitlementRequired])
        XCTAssertEqual(h.controller.state, .idle)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(h.sentTypes.contains("group_call_media_rejoin"), "asking again cannot change the answer")
        XCTAssertEqual(h.sentTypes.filter { $0 == "group_call_media_join" }.count, 1)
    }

    func testACorrelatedServerErrorWhileTheMediaIsBeingSetUpFailsFast() async {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId)
        h.manager.onGroupUpdate?(h.update(epoch: 1, withMedia: false))        // media_join sent, no answer yet
        h.manager.handleServerError(code: "entitlement_required", callId: ControllerHarness.callId)
        XCTAssertEqual(h.errors, [.entitlementRequired], "no 10-15 s wait for a media_ready that will not come")
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertTrue(h.sentTypes.contains("group_call_leave"))
    }

    func testAnUncorrelatedServerErrorRightAfterOurRequestFailsFastToo() async {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId)
        h.manager.handleServerError(code: "?", callId: nil)                    // the answer of the join we just sent
        XCTAssertEqual(h.errors, [.other("server_error")])
        XCTAssertEqual(h.controller.state, .idle)
    }

    func testAServerErrorOfAnotherCallOrWithALiveMediaPathChangesNothing() async {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId)
        h.manager.handleServerError(code: "x", callId: "another-call")
        XCTAssertTrue(h.errors.isEmpty, "another call's error is not ours")
        XCTAssertNotEqual(h.controller.state, .idle)
        h.manager.onGroupUpdate?(h.update(epoch: 1, withMedia: false))
        h.manager.onMediaReady?(h.ready())
        _ = await h.waitUntil { h.controller.hasMediaLink }
        h.manager.handleServerError(code: "x", callId: ControllerHarness.callId)
        h.manager.handleServerError(code: "x", callId: nil)
        XCTAssertTrue(h.errors.isEmpty, "with a running media path an error is about something else")
        XCTAssertTrue(h.controller.hasMediaLink)
        h.controller.leave()
    }

    func testAnUncorrelatedServerErrorLongAfterOurRequestIsNotTheAnswerOfIt() async {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId)
        try? await Task.sleep(nanoseconds: 3_300_000_000)
        h.manager.handleServerError(code: "?", callId: nil)
        XCTAssertTrue(h.errors.isEmpty)
        h.controller.leave()
    }

    // MARK: decrypt / key plumbing

    func testACryptorThatDecryptsAgainIsPassedToTheCoordinator() async {
        let h = ControllerHarness()
        _ = await h.joinAndConnect()
        h.manager.onGroupUpdate?(h.update(epoch: 2))
        h.backend.onDecryptFailure?(ControllerHarness.pseudoB)
        h.backend.onCryptorOk?(ControllerHarness.pseudoB)
        // The failing run is over before its first second: not one nack is ever sent for it.
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        let nacks = h.control.filter { entry in
            if case .envelope(.nack) = GroupKeyEnvelope.parse(json: entry.json) { return true }
            return false
        }
        XCTAssertTrue(nacks.isEmpty)
        h.controller.leave()
    }

    func testMediaMovedRequestsANewJoin() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect()
        h.manager.onMediaMoved?(ControllerHarness.callId, "node-b")
        XCTAssertTrue(link?.calls.contains("close") ?? false)
        let joins = await h.waitUntil { h.sentTypes.filter { $0 == "group_call_media_join" }.count == 2 }
        XCTAssertTrue(joins)
        h.controller.leave()
    }

    // MARK: network / background / publish policy

    func testGenuineNetworkChangeRestartsIceOnTheLiveLink() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect()
        XCTAssertEqual(h.paths.started, 1)
        h.paths.fire("iface_changed")
        let restarted = await h.waitUntil { link?.calls.contains("path=iface_changed") ?? false }
        XCTAssertTrue(restarted)
        h.controller.leave()
        XCTAssertEqual(h.paths.stopped, 1)
    }

    func testBackgroundingPausesLocalVideoAndUnsubscribesRemoteVideo() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect()
        let on = await h.controller.setVideoEnabled(true)
        XCTAssertTrue(on)
        h.controller.setAppBackgrounded(true)
        XCTAssertTrue(link?.calls.contains("background=true") ?? false)
        let paused = await h.waitUntil { link?.calls.last == "publish-video=false" }
        XCTAssertTrue(paused)
        h.controller.setAppBackgrounded(false)
        let resumed = await h.waitUntil { link?.calls.last == "publish-video=true" }
        XCTAssertTrue(resumed)
        h.controller.leave()
    }

    func testCameraDeniedIsANonFatalError() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect()
        link?.cameraResult = .permissionDenied
        let on = await h.controller.setVideoEnabled(true)
        XCTAssertFalse(on)
        XCTAssertEqual(h.errors, [.cameraPermissionDenied])
        XCTAssertNotEqual(h.controller.state, .idle, "a camera problem never ends the call")
        h.controller.leave()
    }

    func testUplinkCongestionStepsTheCameraDownThenStopsIt() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect()
        _ = await h.controller.setVideoEnabled(true)
        link?.emit(.uplinkCongested)
        let two = await h.waitUntil { link?.calls.contains("layers=2") ?? false }
        XCTAssertTrue(two)
        link?.emit(.uplinkCongested)
        link?.emit(.uplinkCongested)
        let stopped = await h.waitUntil { link?.calls.last == "publish-video=false" }
        XCTAssertTrue(stopped, "calls: \(link?.calls ?? [])")
        h.controller.leave()
    }

    func testMuteRequestMutesTheMicAndNotifies() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect()
        let requester = LockedBox<String?>(nil)
        h.controller.onMuteRequested = { id in requester.mutate { $0 = id } }
        h.manager.onGroupCallMuteRequestReceived?(ControllerHarness.callId, ControllerHarness.peerB)
        XCTAssertEqual(requester.value, ControllerHarness.peerB)
        XCTAssertTrue(h.controller.isMuted)
        XCTAssertEqual(link?.calls.last, "mic=false")
        h.controller.leave()
    }

    // MARK: mute state (1:1 -> group hand-over, CallKit mirror)

    /// Every mic call of the link that happened before its publisher started: the start
    /// is what creates the audio track, so these decide whether a frame can ever be live.
    private func micCallsBeforeStart(_ link: FakeMediaLink?) -> [String] {
        let calls = link?.calls ?? []
        guard let start = calls.firstIndex(where: { $0.hasPrefix("start") }) else { return [] }
        return calls[..<start].filter { $0.hasPrefix("mic=") }
    }

    func testAPromotedCallStartsMutedAndTheMicrophoneIsNeverLive() async {
        let h = ControllerHarness()
        let changes = LockedBox<[Bool]>([])
        h.controller.onMutedChanged = { muted in changes.mutate { $0.append(muted) } }
        let link = await h.createAndConnect(startMuted: true)
        XCTAssertNotNil(link)
        // The state is the controller's from the first instant, so the button / self tile show it.
        XCTAssertTrue(h.controller.isMuted)
        XCTAssertEqual(changes.value, [true])
        // The publisher was told to stay muted BEFORE it started (its audio track is created
        // by the start), and never once to be live.
        XCTAssertEqual(micCallsBeforeStart(link), ["mic=false"])
        XCTAssertFalse(link?.calls.contains("mic=true") ?? true, "calls: \(link?.calls ?? [])")
        h.controller.leave()
    }

    func testJoiningAPromotedCallStartsMutedToo() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect(startMuted: true)
        XCTAssertNotNil(link)
        XCTAssertTrue(h.controller.isMuted)
        XCTAssertEqual(micCallsBeforeStart(link), ["mic=false"])
        XCTAssertFalse(link?.calls.contains("mic=true") ?? true, "calls: \(link?.calls ?? [])")
        h.controller.leave()
    }

    func testAnUnmutedCallKeepsTheMicrophoneLiveAndReportsNoChange() async {
        let h = ControllerHarness()
        let changes = LockedBox<[Bool]>([])
        h.controller.onMutedChanged = { muted in changes.mutate { $0.append(muted) } }
        let link = await h.joinAndConnect()
        XCTAssertFalse(h.controller.isMuted)
        XCTAssertEqual(micCallsBeforeStart(link), ["mic=true"])
        XCTAssertEqual(changes.value, [])
        h.controller.leave()
        XCTAssertEqual(changes.value, [], "nothing to reset: the call never was muted")
    }

    func testTheStartMuteSurvivesARejoinOfTheMedia() async {
        let h = ControllerHarness()
        _ = await h.joinAndConnect(startMuted: true)
        // A fresh hand-out (rejoin, media moved, ...) replaces the link: its publisher is
        // wired muted as well, it never comes up live.
        h.manager.onMediaReady?(h.ready())
        let rebuilt = await h.waitUntil { h.backend.links.count == 2 && h.backend.links[1].calls.contains { $0.hasPrefix("start") } }
        XCTAssertTrue(rebuilt)
        let second = h.backend.links[1]
        XCTAssertEqual(micCallsBeforeStart(second), ["mic=false"])
        XCTAssertFalse(second.calls.contains("mic=true"), "calls: \(second.calls)")
        h.controller.leave()
    }

    func testUnmutingAPromotedCallOpensTheMicrophoneOnceAndIsReported() async {
        let h = ControllerHarness()
        let changes = LockedBox<[Bool]>([])
        h.controller.onMutedChanged = { muted in changes.mutate { $0.append(muted) } }
        let link = await h.createAndConnect(startMuted: true)
        h.controller.setMuted(false)
        XCTAssertFalse(h.controller.isMuted)
        XCTAssertEqual(link?.calls.last, "mic=true")
        XCTAssertEqual(changes.value, [true, false])
        h.controller.leave()
    }

    func testTheStartMuteEndsWithTheCallAndDoesNotLeakIntoTheNextOne() async {
        let h = ControllerHarness()
        let changes = LockedBox<[Bool]>([])
        h.controller.onMutedChanged = { muted in changes.mutate { $0.append(muted) } }
        _ = await h.createAndConnect(startMuted: true)
        h.controller.leave()
        // The reset is reported too: the long-lived view model must not carry the mute over.
        XCTAssertFalse(h.controller.isMuted)
        XCTAssertEqual(changes.value, [true, false])
        h.controller.join(callId: ControllerHarness.callId)
        XCTAssertFalse(h.controller.isMuted)
        h.manager.onGroupUpdate?(h.update(epoch: 1, withMedia: false))
        h.manager.onMediaReady?(h.ready())
        let second = await h.waitUntil { h.backend.links.count == 2 && h.backend.links[1].calls.contains { $0.hasPrefix("start") } }
        XCTAssertTrue(second)
        XCTAssertEqual(micCallsBeforeStart(h.backend.links[1]), ["mic=true"])
        XCTAssertEqual(changes.value, [true, false])
        h.controller.leave()
    }

    /// The CallKit mirror of the app layer hangs off this one callback: whatever moves the
    /// microphone (the button, the async switch, a peer's request, CallKit itself, which
    /// reaches the controller through the same `setMuted`) is reported once per change.
    func testEveryMuteSourceIsReportedOncePerChange() async {
        let h = ControllerHarness()
        let changes = LockedBox<[Bool]>([])
        h.controller.onMutedChanged = { muted in changes.mutate { $0.append(muted) } }
        let link = await h.joinAndConnect()
        h.controller.setMuted(true)
        h.controller.setMuted(true)
        XCTAssertEqual(changes.value, [true], "a repeat of the current state is not a change")
        XCTAssertEqual(link?.calls.last, "mic=false")
        h.controller.setMuted(false)
        XCTAssertEqual(changes.value, [true, false])
        XCTAssertEqual(link?.calls.last, "mic=true")
        let live = await h.controller.setMicrophoneEnabled(false)
        XCTAssertTrue(live)
        XCTAssertEqual(changes.value, [true, false, true])
        XCTAssertEqual(link?.calls.last, "mic=false")
        // A peer asks for a mute while already muted: the requester is still told, nothing changes.
        let requests = LockedBox(0)
        h.controller.onMuteRequested = { _ in requests.mutate { $0 += 1 } }
        h.manager.onGroupCallMuteRequestReceived?(ControllerHarness.callId, ControllerHarness.peerB)
        XCTAssertEqual(requests.value, 1)
        XCTAssertEqual(changes.value, [true, false, true])
        h.controller.setMuted(false)
        h.manager.onGroupCallMuteRequestReceived?(ControllerHarness.callId, ControllerHarness.peerB)
        XCTAssertEqual(changes.value, [true, false, true, false, true])
        XCTAssertEqual(link?.calls.last, "mic=false")
        h.controller.leave()
        XCTAssertEqual(changes.value, [true, false, true, false, true, false])
    }

    func testAMuteThatLandsWhileTheLinkIsBeingWiredStillWins() async {
        let h = ControllerHarness()
        let fired = LockedBox(false)
        // The mute arrives after the wiring read "live" and before its apply: the stale apply
        // would land AFTER the mute's own `setMicrophoneEnabled(false)` and reopen the microphone.
        h.backend.microphoneHook = { [weak h] enabled in
            guard enabled, !fired.value else { return }
            fired.mutate { $0 = true }
            h?.controller.setMuted(true)
        }
        let link = await h.joinAndConnect()
        XCTAssertTrue(fired.value)
        XCTAssertTrue(h.controller.isMuted)
        let mics = micCallsBeforeStart(link)
        XCTAssertEqual(mics.last, "mic=false", "calls: \(link?.calls ?? [])")
        h.controller.leave()
    }

    // MARK: audio unit / lifecycle

    func testAudioActivationBeforeTheJoinIsReplayed() {
        let h = ControllerHarness()
        h.controller.audioSessionActivated(source: .callKit)
        XCTAssertEqual(h.audio.events, [], "no call yet: nothing to drive")
        h.controller.join(callId: ControllerHarness.callId)
        XCTAssertEqual(h.audio.events, ["begin", "activated=1"])
        h.controller.audioSessionDeactivated()
        XCTAssertEqual(h.audio.events.last, "deactivated")
        h.controller.leave()
        XCTAssertEqual(h.audio.events.last, "end")
        // A leftover activation does not leak into the next call.
        h.controller.join(callId: ControllerHarness.callId)
        XCTAssertEqual(Array(h.audio.events.suffix(1)), ["begin"])
        h.controller.leave()
    }

    func testOneToOneEndedIsForwardedOnlyDuringACall() {
        let h = ControllerHarness()
        h.controller.oneToOneEnded()
        XCTAssertTrue(h.audio.events.isEmpty)
        h.controller.join(callId: ControllerHarness.callId)
        h.controller.oneToOneEnded()
        XCTAssertEqual(h.audio.events.last, "oneToOneEnded")
        h.controller.leave()
    }

    func testAudioUnitNeedingActivationIsRelayedToTheApp() {
        let h = ControllerHarness()
        let asked = LockedBox(0)
        h.controller.onNeedsAudioSessionActivation = { asked.mutate { $0 += 1 } }
        h.audio.onNeedsSessionActivation?()
        XCTAssertEqual(asked.value, 1)
    }

    func testLeaveTearsEverythingDown() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect()
        h.controller.leave()
        XCTAssertTrue(link?.calls.contains("close") ?? false)
        XCTAssertEqual(h.backend.ends, 1)
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertFalse(h.controller.hasMediaLink)
        XCTAssertTrue(h.sentTypes.contains("group_call_leave"))
        XCTAssertTrue(h.telemetry.contains("call.media.ended"))
    }

    func testCreateCallMarksTheCallAsCreatedLocally() {
        let h = ControllerHarness()
        let id = h.controller.createCall(invitees: [ControllerHarness.peerB], callType: "video")
        XCTAssertNotNil(id)
        XCTAssertTrue(h.controller.isCreatedLocally)
        XCTAssertTrue(h.controller.callWantsVideo)
        XCTAssertEqual(h.sentTypes.first, "group_call_create")
        h.controller.leave()
        XCTAssertFalse(h.controller.isCreatedLocally)
    }

    func testReactionsAndRaisedHandsFollowTheManagerCallbacks() {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId)
        h.manager.onGroupCallRaiseHandReceived?(ControllerHarness.callId, ControllerHarness.peerB, true)
        XCTAssertEqual(h.controller.raisedHands, [ControllerHarness.peerB])
        // Another call's signal is ignored.
        h.manager.onGroupCallRaiseHandReceived?("other", ControllerHarness.peerC, true)
        XCTAssertEqual(h.controller.raisedHands, [ControllerHarness.peerB])
        h.manager.onGroupCallReactionReceived?(ControllerHarness.callId, ControllerHarness.peerB, "x")
        XCTAssertEqual(h.controller.reactionEvents.map { $0.emoji }, ["x"])
        h.controller.leave()
        XCTAssertTrue(h.controller.raisedHands.isEmpty)
    }
}

/// Small thread-safe box for values written from callbacks.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate(_ change: (inout T) -> Void) { lock.lock(); change(&_value); lock.unlock() }
}
