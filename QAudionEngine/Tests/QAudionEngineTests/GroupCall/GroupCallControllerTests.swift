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
    func setMicrophoneEnabled(_ enabled: Bool) { record("mic=\(enabled)") }
    func setCameraEnabled(_ enabled: Bool) async -> GroupCameraResult {
        record("camera=\(enabled)")
        return enabled ? cameraResult : .stopped
    }
    func setActiveLayers(_ count: Int) { record("layers=\(count)") }
    func requestPublisherKeyFrame() async { record("keyframe") }
    func networkPathChanged(reason: String) async { record("path=\(reason)") }
    func close() { record("close") }

    /// Emits a session event as the real session would.
    func emit(_ event: GroupMediaSession.Event) { onEvent?(event) }
}

final class FakeMediaBackend: GroupMediaBackend, @unchecked Sendable {
    var onMissingKey: ((String) -> Void)?
    var onDecryptFailure: ((String) -> Void)?

    private let lock = NSLock()
    private var _links: [FakeMediaLink] = []
    private var _keys: [(participant: String, index: Int32, key: Data)] = []
    private var _sendIndexes: [Int32] = []
    private var _begins = 0
    private var _ends = 0
    var startError: Error?

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

    init() {
        let ws = BCryptoWebSocketClient(config: BackendConfig(serverUrl: "https://example.invalid"))
        manager = BCryptoGroupCallManager(ws: ws, selfUserId: Self.selfUser, nameResolver: { $0 })
        controller = GroupCallController(manager: manager, backend: backend, audio: audio, pathMonitor: paths)
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

    func update(epoch: UInt32, members: [String]? = nil, withMedia: Bool = true) -> GroupCallWire.Update {
        let roster = members ?? [Self.selfUser, Self.peerB]
        var map: [String: String] = [:]
        if withMedia {
            map[Self.selfUser] = Self.pseudoSelf
            map[Self.peerB] = Self.pseudoB
            map[Self.peerC] = Self.pseudoC
            map = map.filter { roster.contains($0.key) }
        }
        return GroupCallWire.Update(callId: Self.callId, participants: roster, epoch: epoch,
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
                        mediaInUpdate: Bool = false) async -> FakeMediaLink? {
        controller.join(callId: Self.callId, video: video)
        manager.onGroupUpdate?(update(epoch: epoch, members: members, withMedia: mediaInUpdate))
        manager.onMediaReady?(ready())
        _ = await waitUntil { !self.backend.links.isEmpty && self.backend.links[0].calls.contains { $0.hasPrefix("start") } }
        return backend.links.first
    }
}

// MARK: - Tests

final class GroupCallControllerTests: XCTestCase {

    private func keyEnvelope(epoch: UInt32, from fill: UInt8, callId: String = ControllerHarness.callId) -> String {
        GroupKeyEnvelope.mediaKey(callId: callId, epoch: epoch, index: GroupE2ee.keyIndex(forEpoch: epoch),
                                  key: GroupCallFixtures.keyBytes(fill)).encode()!
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
            guard case .envelope(.mediaKey(_, let epoch, let index, let key)) = GroupKeyEnvelope.parse(json: entry.json) else {
                return XCTFail("not a media_key envelope")
            }
            XCTAssertEqual(epoch, 1)
            XCTAssertEqual(index, 1)
            XCTAssertEqual(key, own?.key)
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

    func testRetryableJanusErrorGetsOneAutomaticMediaJoinThenAnError() async {
        let h = ControllerHarness()
        let link = await h.joinAndConnect()
        link?.emit(.janusFailure(.plugin(code: 428, reason: "no such feed")))
        let joins = await h.waitUntil { h.sentTypes.filter { $0 == "group_call_media_join" }.count == 2 }
        XCTAssertTrue(joins)
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
