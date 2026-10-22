import XCTest
@testable import QAudionEngine

/// The rules of docs/mesh/MESH_LINK_SPEC.md that the shared vectors cannot express
/// because they involve time, state or a decision: reassembly expiry and eviction,
/// the malformed streak, the one-ATT-operation-at-a-time sender, the relay
/// conditions, the startup order, the modes and the outbox.
final class MeshLinkBehaviorTests: XCTestCase {

    private func node(_ n: Int) -> MeshNodeId {
        try! MeshNodeId(hex: String(format: "%016x", n))
    }

    private func packet(
        type: MeshPacketType = .data, from: Int = 1, to: Int = 2, ttl: Int? = 5, ts: Int64 = 100,
        payload: Data = Data([1, 2, 3])
    ) -> MeshPacket {
        try! MeshPacket(type: type, senderId: node(from), recipientId: node(to), ttl: ttl, timestampMs: ts, payload: payload)
    }

    private func frame(set: UInt16, index: Int, total: Int, chunk: [UInt8] = [0xAA]) -> Data {
        Data([UInt8(set >> 8), UInt8(set & 0xFF), UInt8(index), UInt8(total)] + chunk)
    }

    // MARK: - Framing at the limits

    func testSplitAtTheLargestLegalSizeAndOneByteMore() throws {
        // 255 frames of 16 bytes at L = 20.
        let largest = Data(repeating: 7, count: 255 * 16)
        let frames = try MeshLinkFraming.split(largest, valueLimit: 20, setId: 0xBEEF).get()
        XCTAssertEqual(frames.count, 255)
        XCTAssertTrue(frames.allSatisfy { $0.count == 20 })
        XCTAssertEqual(frames.last?[3], 255)
        XCTAssertEqual(frames.last?[2], 254)
        if case .failure(let error) = MeshLinkFraming.split(largest + Data([1]), valueLimit: 20, setId: 1) {
            XCTAssertEqual(error, .tooManyFrames)
        } else {
            XCTFail("256 frames must be refused")
        }
    }

    func testSplitRefusesALinkThatCannotCarryOneChunkByte() {
        for limit in [0, 1, 4] {
            if case .failure(let error) = MeshLinkFraming.split(Data([1]), valueLimit: limit, setId: 1) {
                XCTAssertEqual(error, .linkTooSmall)
            } else {
                XCTFail("limit \(limit)")
            }
        }
        // Five bytes is a usable single-frame link.
        XCTAssertEqual((try? MeshLinkFraming.split(Data([1]), valueLimit: 5, setId: 1).get())?.count, 1)
    }

    func testEmptyPacketStillBecomesOneFrame() throws {
        let frames = try MeshLinkFraming.split(Data(), valueLimit: 20, setId: 9).get()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].count, 4)
    }

    func testFramesOfOnePacketAtDifferentLimitsReassembleToTheSamePacket() throws {
        let original = Data((0..<1500).map { UInt8($0 % 251) })
        for limit in [20, 23, 100, 182, 244, 509] {
            let frames = try MeshLinkFraming.split(original, valueLimit: limit, setId: 3).get()
            var reassembler = MeshLinkReassembler()
            var out: Data?
            for f in frames.shuffled() {
                if case .complete(let whole) = reassembler.offer(f, nowMs: 0).status { out = whole }
            }
            XCTAssertEqual(out, original, "limit \(limit)")
        }
    }

    // MARK: - Reassembly timing and caps

    func testSetExpiresTenSecondsAfterItsLastFrame() {
        var r2 = MeshLinkReassembler()
        _ = r2.offer(frame(set: 1, index: 0, total: 3), nowMs: 0)
        XCTAssertEqual(r2.offer(frame(set: 1, index: 1, total: 3), nowMs: 9_000).expiredSets, 0)
        // Last frame at 9 000: still alive at 19 000, gone at 19 001.
        XCTAssertEqual(r2.sweep(nowMs: 19_000), 0)
        XCTAssertEqual(r2.pendingSetCount, 1)
        XCTAssertEqual(r2.sweep(nowMs: 19_001), 1)
        XCTAssertEqual(r2.pendingSetCount, 0)
    }

    func testSetExpiresThirtySecondsAfterItsFirstFrameEvenIfFramesKeepComing() {
        var r = MeshLinkReassembler()
        var now: Int64 = 0
        _ = r.offer(frame(set: 5, index: 0, total: 200), nowMs: now)
        for i in 1..<4 {
            now += 8_000 // never idle for 10 s
            XCTAssertEqual(r.offer(frame(set: 5, index: i, total: 200), nowMs: now).expiredSets, 0)
        }
        // now = 24 000; the next frame at 30 001 finds the set past its absolute limit.
        let outcome = r.offer(frame(set: 5, index: 9, total: 200), nowMs: 30_001)
        XCTAssertEqual(outcome.expiredSets, 1)
        XCTAssertEqual(outcome.status, .pending) // a fresh set was started by this frame
        XCTAssertEqual(r.pendingSetCount, 1)
    }

    func testFifthIncompleteSetEvictsTheOneWithTheOldestMostRecentFrame() {
        var r = MeshLinkReassembler()
        _ = r.offer(frame(set: 1, index: 0, total: 3), nowMs: 0)
        _ = r.offer(frame(set: 2, index: 0, total: 3), nowMs: 10)
        _ = r.offer(frame(set: 3, index: 0, total: 3), nowMs: 20)
        _ = r.offer(frame(set: 4, index: 0, total: 3), nowMs: 30)
        // Set 1 gets a fresh frame, so set 2 now has the oldest most-recent frame.
        _ = r.offer(frame(set: 1, index: 1, total: 3), nowMs: 40)
        let outcome = r.offer(frame(set: 5, index: 0, total: 3), nowMs: 50)
        XCTAssertEqual(outcome.evictedSets, 1)
        XCTAssertEqual(r.pendingSetCount, 4)
        // Set 2 is gone: finishing it starts a new set instead of completing.
        XCTAssertEqual(r.offer(frame(set: 2, index: 1, total: 3), nowMs: 60).status, .pending)
        // Set 1 survived: it completes with its third frame.
        XCTAssertEqual(r.offer(frame(set: 1, index: 2, total: 3, chunk: [0xCC]), nowMs: 70).status,
                       .complete(Data([0xAA, 0xAA, 0xCC])))
    }

    func testSingleFrameSetsNeverTakeASlot() {
        var r = MeshLinkReassembler()
        for set in 1...4 { _ = r.offer(frame(set: UInt16(set), index: 0, total: 3), nowMs: 0) }
        for set in 100..<120 {
            XCTAssertEqual(r.offer(frame(set: UInt16(set), index: 0, total: 1, chunk: [9]), nowMs: 1).status, .complete(Data([9])))
        }
        XCTAssertEqual(r.pendingSetCount, 4)
    }

    func testSetBeyondTheLargestPacketIsDiscardedAndMalformed() {
        var r = MeshLinkReassembler()
        let big = [UInt8](repeating: 1, count: 4_000)
        var last: MeshLinkReassembler.Status = .pending
        for i in 0..<5 {
            last = r.offer(frame(set: 7, index: i, total: 20, chunk: big), nowMs: Int64(i)).status
        }
        XCTAssertEqual(last, .malformed(.setTooLarge)) // 5 x 4000 = 20000 > 18457
        XCTAssertEqual(r.pendingSetCount, 0)
    }

    func testMalformedFramesDoNotDisturbOtherSets() {
        var r = MeshLinkReassembler()
        _ = r.offer(frame(set: 1, index: 0, total: 2), nowMs: 0)
        XCTAssertEqual(r.offer(Data([0, 1, 2, 3]), nowMs: 1).status, .malformed(.shortFrame))
        XCTAssertEqual(r.offer(Data([0, 2, 5, 2, 1]), nowMs: 1).status, .malformed(.badHeader))
        XCTAssertEqual(r.offer(frame(set: 1, index: 1, total: 2), nowMs: 2).status, .complete(Data([0xAA, 0xAA])))
    }

    // MARK: - Malformed streak

    func testTenConsecutiveMalformedEventsBlockTheLinkForSixtySeconds() {
        var g = MeshMalformedGuard()
        for i in 1...9 {
            XCTAssertNil(g.registerMalformed("link", nowMs: Int64(i)))
            XCTAssertFalse(g.isBlocked("link", nowMs: Int64(i)))
        }
        XCTAssertEqual(g.registerMalformed("link", nowMs: 10), 10)
        XCTAssertTrue(g.isBlocked("link", nowMs: 59_999))
        XCTAssertFalse(g.isBlocked("other", nowMs: 59_999))
        XCTAssertFalse(g.isBlocked("link", nowMs: 60_010))
    }

    func testAWellFormedPacketResetsTheStreakAndABlockSurvivesTheLinkGoing() {
        var g = MeshMalformedGuard()
        for _ in 0..<9 { _ = g.registerMalformed("a", nowMs: 0) }
        g.registerWellFormed("a")
        XCTAssertEqual(g.streak("a"), 0)
        XCTAssertNil(g.registerMalformed("a", nowMs: 0))
        for _ in 0..<9 { _ = g.registerMalformed("b", nowMs: 0) }
        XCTAssertNotNil(g.registerMalformed("b", nowMs: 0))
        g.linkGone("b")
        XCTAssertTrue(g.isBlocked("b", nowMs: 1), "a block must survive the link going away and coming back")
    }

    // MARK: - One ATT operation at a time, sent only if every frame was accepted

    func testSetSenderSendsInOrderOneAtATimeAndFinishesOnlyWhenEveryFrameWasAccepted() {
        let frames = (0..<3).map { Data([UInt8($0)]) }
        var sender = MeshFrameSetSender(frames: frames)
        XCTAssertEqual(sender.advance(), .send(frames[0]))
        // Asking again while the first is unconfirmed does not release the second.
        XCTAssertEqual(sender.advance(), .send(frames[0]))
        XCTAssertEqual(sender.confirmed(success: true), .send(frames[1]))
        XCTAssertEqual(sender.confirmed(success: true), .send(frames[2]))
        XCTAssertFalse(sender.isTerminal)
        XCTAssertEqual(sender.confirmed(success: true), .finished)
        XCTAssertTrue(sender.isTerminal)
    }

    func testSetSenderAbandonsTheRestOnTheFirstFailure() {
        let frames = (0..<4).map { Data([UInt8($0)]) }
        var sender = MeshFrameSetSender(frames: frames)
        _ = sender.advance()
        _ = sender.confirmed(success: true)
        XCTAssertEqual(sender.confirmed(success: false), .failed(.rejected, frameIndex: 1))
        // Nothing further is released, whatever arrives later.
        XCTAssertEqual(sender.confirmed(success: true), .failed(.rejected, frameIndex: 1))
        XCTAssertEqual(sender.advance(), .failed(.rejected, frameIndex: 1))
    }

    func testSetSenderTimeoutAndLinkLoss() {
        var a = MeshFrameSetSender(frames: [Data([1]), Data([2])])
        _ = a.advance()
        XCTAssertEqual(a.timedOut(), .failed(.timeout, frameIndex: 0))
        var b = MeshFrameSetSender(frames: [Data([1]), Data([2])])
        _ = b.advance()
        _ = b.confirmed(success: true)
        XCTAssertEqual(b.timedOut(reason: .notReady), .failed(.notReady, frameIndex: 1))
        var c = MeshFrameSetSender(frames: [Data([1])])
        _ = c.advance()
        XCTAssertEqual(c.linkLost(), .failed(.linkLost, frameIndex: 0))
        XCTAssertEqual(MeshFrameSetSender.frameTimeoutMs, 2_000)
    }

    // MARK: - Relay conditions (section 9.2)

    private func decide(
        _ gate: inout MeshRelayGate, _ p: MeshPacket, link: String = "c1", mode: MeshAntennaMode = .fullMesh,
        nodes: Int = 2, now: Int64 = 0, sample: Double = 0, local: Int = 9
    ) -> MeshRelayGate.Decision {
        gate.decide(packet: p, payloadHash: MeshLog.payloadHash(p.payload), linkKey: link, localNodeId: node(local),
                    mode: mode, linkedNodes: nodes, nowMs: now, sample: { sample })
    }

    func testRelayForwardsWithTtlMinusOneAndTheAppliedProbability() {
        var gate = MeshRelayGate()
        XCTAssertEqual(decide(&gate, packet(ttl: 5)), .forward(nextTTL: 4, permille: 1000))
        var dense = MeshRelayGate()
        // 8 linked nodes, ttl 3: 0.8 as in the vectors.
        XCTAssertEqual(decide(&dense, packet(ttl: 3), nodes: 8), .forward(nextTTL: 2, permille: 800))
    }

    func testRelayOnlyInFullMode() {
        for mode in [MeshAntennaMode.direct, .visibleOnly] {
            var gate = MeshRelayGate()
            XCTAssertEqual(decide(&gate, packet(), mode: mode), .skip(.mode))
        }
    }

    func testRelayNeverForAnnounceAckFragmentOwnTrafficOrPacketsForUs() {
        var gate = MeshRelayGate()
        for type in [MeshPacketType.announce, .ack, .fragment] {
            XCTAssertEqual(decide(&gate, packet(type: type, to: 0xFFFF)), .skip(nil), "\(type)")
        }
        XCTAssertEqual(decide(&gate, packet(to: 9), local: 9), .skip(nil), "addressed to us")
        XCTAssertEqual(decide(&gate, packet(from: 9), local: 9), .skip(nil), "our own packet looping back")
    }

    func testRelayNeedsTtlGreaterThanZero() {
        var gate = MeshRelayGate()
        XCTAssertEqual(decide(&gate, packet(ttl: nil)), .skip(.ttl))
        XCTAssertEqual(decide(&gate, packet(ttl: 0)), .skip(.ttl))
    }

    func testARelayedPacketIsNotRelayedAgainEvenWithAnotherTtl() {
        var gate = MeshRelayGate()
        XCTAssertNotEqual(decide(&gate, packet(ttl: 5)), .skip(.dup))
        XCTAssertEqual(decide(&gate, packet(ttl: 3), link: "p2"), .skip(.dup))
        // A retransmission has a new timestamp: it is a new identity.
        XCTAssertEqual(decide(&gate, packet(ttl: 5, ts: 101)), .forward(nextTTL: 4, permille: 1000))
    }

    func testRemembersAtLeastTheLast256Identities() {
        var gate = MeshRelayGate()
        for i in 0..<300 {
            _ = decide(&gate, packet(ts: Int64(i)), link: "c\(i)")
        }
        XCTAssertEqual(gate.rememberedCount, 256)
        // The newest is still remembered, the oldest is not.
        XCTAssertEqual(decide(&gate, packet(ts: 299), link: "z"), .skip(.dup))
        XCTAssertEqual(decide(&gate, packet(ts: 0), link: "y"), .forward(nextTTL: 4, permille: 1000))
    }

    func testLinkMayRelayTwentyPacketsPerTenSecondWindow() {
        var gate = MeshRelayGate()
        for i in 0..<20 {
            XCTAssertEqual(decide(&gate, packet(ts: Int64(i)), now: Int64(i)), .forward(nextTTL: 4, permille: 1000), "\(i)")
        }
        XCTAssertEqual(decide(&gate, packet(ts: 20), now: 20), .skip(.rate))
        // Another link has its own window.
        XCTAssertEqual(decide(&gate, packet(ts: 21), link: "p1", now: 21), .forward(nextTTL: 4, permille: 1000))
        // A new window opens after 10 s.
        XCTAssertEqual(decide(&gate, packet(ts: 22), now: 10_001), .forward(nextTTL: 4, permille: 1000))
    }

    func testFailedProbabilityDrawIsReportedAndDoesNotMarkThePacketRelayed() {
        var gate = MeshRelayGate()
        // 100 nodes, ttl 0 impossible; ttl 1 gives 0.232 as in the vectors.
        let p = packet(ttl: 1)
        XCTAssertEqual(decide(&gate, p, nodes: 100, sample: 0.9), .dropped(permille: 232))
        XCTAssertEqual(gate.rememberedCount, 0)
        XCTAssertEqual(decide(&gate, p, link: "p3", nodes: 100, sample: 0.1), .forward(nextTTL: 0, permille: 232))
    }

    // MARK: - Startup order: identity first (section 1.2)

    private final class FakeTransport {
        let nodeId: MeshNodeId
        var stopped = false
        init(_ nodeId: MeshNodeId) { self.nodeId = nodeId }
    }

    private func key(_ seed: UInt8) -> Data { Data(repeating: seed, count: 32) }

    func testNoTransportExistsBeforeTheIdentityIsConfigured() {
        var built = 0
        let slot = MeshTransportSlot<FakeTransport>(factory: { built += 1; return FakeTransport($0) }, retire: { $0.stopped = true })
        XCTAssertNil(slot.nodeId)
        XCTAssertNil(slot.acquire(), "no transport without an identity: there is no random fallback id")
        XCTAssertEqual(built, 0)
        XCTAssertEqual(slot.configure(identityKeyRaw: nil), .unavailable)
        XCTAssertEqual(slot.configure(identityKeyRaw: Data(count: 31)), .unavailable)
        XCTAssertNil(slot.acquire())
        XCTAssertEqual(built, 0)
    }

    func testTransportIsBuiltWithTheDerivedNodeIdAndKeptWhileTheIdentityIsUnchanged() throws {
        var built: [FakeTransport] = []
        let slot = MeshTransportSlot<FakeTransport>(factory: { let t = FakeTransport($0); built.append(t); return t }, retire: { $0.stopped = true })
        let expected = try XCTUnwrap(MeshNodeId.from(identityKeyRaw: key(1)))
        XCTAssertEqual(slot.configure(identityKeyRaw: key(1)), .changed(expected, retired: false))
        XCTAssertEqual(slot.nodeId, expected)
        let t1 = try XCTUnwrap(slot.acquire())
        XCTAssertEqual(t1.nodeId, expected)
        XCTAssertTrue(slot.acquire() === t1)
        XCTAssertEqual(slot.configure(identityKeyRaw: key(1)), .unchanged(expected))
        XCTAssertTrue(slot.acquire() === t1)
        // An unreadable key later (storage locked) leaves the running identity alone.
        XCTAssertEqual(slot.configure(identityKeyRaw: nil), .unavailable)
        XCTAssertEqual(slot.nodeId, expected)
        XCTAssertFalse(t1.stopped)
        XCTAssertEqual(built.count, 1)
    }

    func testAChangedIdentityRetiresTheOldTransportAndBuildsANewOne() throws {
        let slot = MeshTransportSlot<FakeTransport>(factory: { FakeTransport($0) }, retire: { $0.stopped = true })
        slot.configure(identityKeyRaw: key(1))
        let old = try XCTUnwrap(slot.acquire())
        let newId = try XCTUnwrap(MeshNodeId.from(identityKeyRaw: key(2)))
        XCTAssertEqual(slot.configure(identityKeyRaw: key(2)), .changed(newId, retired: true))
        XCTAssertTrue(old.stopped)
        XCTAssertNil(slot.existingTransport)
        let fresh = try XCTUnwrap(slot.acquire())
        XCTAssertFalse(fresh === old)
        XCTAssertEqual(fresh.nodeId, newId)
        XCTAssertEqual(slot.nodeId, newId)
    }

    func testResetDropsTheIdentityAndTheTransport() throws {
        let slot = MeshTransportSlot<FakeTransport>(factory: { FakeTransport($0) }, retire: { $0.stopped = true })
        XCTAssertFalse(slot.reset(), "nothing to retire before anything was built")
        slot.configure(identityKeyRaw: key(1))
        let transport = try XCTUnwrap(slot.acquire())
        XCTAssertTrue(slot.reset())
        XCTAssertTrue(transport.stopped)
        XCTAssertNil(slot.nodeId)
        XCTAssertNil(slot.acquire(), "after the account left there is no transport until a new identity is configured")
        let again = try XCTUnwrap(MeshNodeId.from(identityKeyRaw: key(1)))
        XCTAssertEqual(slot.configure(identityKeyRaw: key(1)), .changed(again, retired: false))
    }

    // MARK: - Modes and consent

    func testRoles() {
        XCTAssertTrue(MeshAntennaMode.fullMesh.connectsOut)
        XCTAssertTrue(MeshAntennaMode.fullMesh.relays)
        XCTAssertTrue(MeshAntennaMode.direct.connectsOut)
        XCTAssertFalse(MeshAntennaMode.direct.relays)
        XCTAssertFalse(MeshAntennaMode.visibleOnly.connectsOut)
        XCTAssertFalse(MeshAntennaMode.visibleOnly.relays)
    }

    func testDeclinedRelayingGivesDirectNotOff() {
        XCTAssertEqual(MeshModePolicy.defaultMode(consent: .accepted), .fullMesh)
        XCTAssertEqual(MeshModePolicy.defaultMode(consent: .declined), .direct)
        XCTAssertNil(MeshModePolicy.defaultMode(consent: .undecided))
    }

    func testStartGateByConsentAndMode() {
        for mode in [MeshAntennaMode.fullMesh, .direct, .visibleOnly] {
            XCTAssertFalse(MeshModePolicy.mayStart(featureEnabled: true, consent: .undecided, mode: mode), "\(mode)")
            XCTAssertFalse(MeshModePolicy.mayStart(featureEnabled: false, consent: .accepted, mode: mode), "\(mode)")
            XCTAssertTrue(MeshModePolicy.mayStart(featureEnabled: true, consent: .accepted, mode: mode), "\(mode)")
        }
        XCTAssertFalse(MeshModePolicy.mayStart(featureEnabled: true, consent: .declined, mode: .fullMesh))
        XCTAssertTrue(MeshModePolicy.mayStart(featureEnabled: true, consent: .declined, mode: .direct))
        XCTAssertTrue(MeshModePolicy.mayStart(featureEnabled: true, consent: .declined, mode: .visibleOnly))
    }

    func testAUserWhoDeclinedRelayingNeverEndsUpRelaying() {
        XCTAssertEqual(MeshModePolicy.allowedMode(.fullMesh, consent: .declined), .direct)
        XCTAssertEqual(MeshModePolicy.allowedMode(.visibleOnly, consent: .declined), .visibleOnly)
        XCTAssertEqual(MeshModePolicy.allowedMode(.fullMesh, consent: .accepted), .fullMesh)
        XCTAssertNil(MeshModePolicy.allowedMode(.direct, consent: .undecided))
    }

    func testBackgroundReachabilityNeedsTheDeviceToConnectOut() {
        XCTAssertTrue(MeshModePolicy.reachableInBackground(mode: .fullMesh))
        XCTAssertTrue(MeshModePolicy.reachableInBackground(mode: .direct))
        XCTAssertFalse(MeshModePolicy.reachableInBackground(mode: .visibleOnly))
    }

    func testRefreshGateAllowsOneRunPerSixtySeconds() {
        var gate = MeshRefreshGate()
        XCTAssertTrue(gate.tryEnter(nowMs: 1_000))
        XCTAssertFalse(gate.tryEnter(nowMs: 30_000))
        XCTAssertFalse(gate.tryEnter(nowMs: 60_999))
        XCTAssertTrue(gate.tryEnter(nowMs: 61_000))
    }

    func testKeyedGateIsPerKey() {
        var gate = MeshKeyedGate(intervalMs: 10_000)
        XCTAssertTrue(gate.tryEnter(key: "a", nowMs: 0))
        XCTAssertFalse(gate.tryEnter(key: "a", nowMs: 9_999))
        XCTAssertTrue(gate.tryEnter(key: "b", nowMs: 5))
        XCTAssertTrue(gate.tryEnter(key: "a", nowMs: 10_000))
    }

    // MARK: - Banner for a stored mesh message

    func testBannerDecision() {
        func notify(_ enabled: Bool = true, muted: Bool = false, active: String? = nil) -> Bool {
            MeshMessageBanner.shouldNotify(bannersEnabled: enabled, muted: muted, activePeerUserId: active, senderUserId: "peer")
        }
        XCTAssertTrue(notify())
        XCTAssertTrue(notify(active: "someone-else"), "another chat is open: the banner is still wanted")
        XCTAssertFalse(notify(active: "peer"), "this conversation is open: it is on screen already")
        XCTAssertFalse(notify(muted: true))
        XCTAssertFalse(notify(false))
    }

    func testBannerBodyShowsNoMoreThanTheNormalPathDoes() {
        XCTAssertEqual(MeshMessageBanner.body(displayText: "ciao", hideContent: false, previewAllowed: true), "ciao")
        XCTAssertEqual(MeshMessageBanner.body(displayText: "ciao", hideContent: true, previewAllowed: true), "Nuovo messaggio")
        XCTAssertEqual(MeshMessageBanner.body(displayText: "ciao", hideContent: false, previewAllowed: false), "Nuovo messaggio")
        let long = String(repeating: "a", count: 130)
        XCTAssertEqual(MeshMessageBanner.body(displayText: long, hideContent: false, previewAllowed: true),
                       String(repeating: "a", count: 120) + "\u{2026}")
        XCTAssertEqual(MeshMessageBanner.body(displayText: String(repeating: "a", count: 120), hideContent: false, previewAllowed: true).count, 120)
    }

    // MARK: - Outbox

    private func entry(_ id: String, kind: MeshOutboxEntry.Kind = .message, target: String = "aa", created: Int64 = 0) -> MeshOutboxEntry {
        MeshOutboxEntry(id: id, kind: kind, messageId: id, conversationId: kind == .message ? "conv" : "", peerUserId: "peer",
                        targetNodeHex: target, payloadB64: "AA==", createdAtMs: created)
    }

    func testAMessageStaysInTheOutboxAfterTheFirstHopAcceptedIt() {
        var q = MeshOutboxQueue()
        q.enqueue(entry("m1"))
        XCTAssertEqual(q.due(nowMs: 0).map(\.id), ["m1"])
        XCTAssertEqual(q.recordAttempt(id: "m1", nowMs: 0, accepted: true), .firstAcceptance)
        XCTAssertTrue(q.contains(id: "m1"), "accepted by the first hop is not delivered")
        XCTAssertEqual(q.recordAttempt(id: "m1", nowMs: 20_000, accepted: true), .retained)
        XCTAssertEqual(q.entry(id: "m1")?.attempts, 2)
    }

    func testAMessageIsRetriedEveryTwentySecondsUntilAReceiptArrives() {
        var q = MeshOutboxQueue()
        q.enqueue(entry("m1"))
        _ = q.recordAttempt(id: "m1", nowMs: 1_000, accepted: true)
        XCTAssertTrue(q.due(nowMs: 20_999).isEmpty)
        XCTAssertEqual(q.due(nowMs: 21_000).map(\.id), ["m1"])
        XCTAssertNotNil(q.acknowledge(clientMsgId: "m1"), "the delivery receipt removes it")
        XCTAssertTrue(q.due(nowMs: 99_000).isEmpty)
        XCTAssertNil(q.acknowledge(clientMsgId: "m1"))
    }

    func testReachableTargetIsRetriedSoonerButNotFasterThanThreeSeconds() {
        var q = MeshOutboxQueue()
        q.enqueue(entry("m1", target: "aa"))
        q.enqueue(entry("m2", target: "bb"))
        _ = q.recordAttempt(id: "m1", nowMs: 10_000, accepted: false)
        _ = q.recordAttempt(id: "m2", nowMs: 10_000, accepted: false)
        XCTAssertTrue(q.due(nowMs: 11_000, reachableTargets: ["aa"]).isEmpty)
        XCTAssertEqual(q.due(nowMs: 13_000, reachableTargets: ["aa"]).map(\.id), ["m1"])
    }

    func testOutboxGivesUpAfterAnHour() {
        var q = MeshOutboxQueue()
        q.enqueue(entry("old", created: 0))
        q.enqueue(entry("young", created: 3_000_000))
        XCTAssertTrue(q.expired(nowMs: 3_600_000).isEmpty)
        XCTAssertEqual(q.expired(nowMs: 3_600_001).map(\.id), ["old"])
        XCTAssertEqual(q.due(nowMs: 3_600_001).map(\.id), ["young"], "an entry past the give-up age is no longer sent")
    }

    func testReceiptsAreQueuedReplacedAndLeaveOnceAccepted() {
        var q = MeshOutboxQueue()
        let key = MeshOutboxEntry.receiptKey(acknowledging: "m1", kind: MeshReceipt.kindDelivered)
        q.enqueue(entry(key, kind: .receipt, created: 1))
        q.enqueue(entry(key, kind: .receipt, created: 2)) // a newer receipt for the same message and kind
        XCTAssertEqual(q.entries.count, 1)
        XCTAssertEqual(q.entry(id: key)?.createdAtMs, 2)
        // The read receipt for the same message is a different entry.
        q.enqueue(entry(MeshOutboxEntry.receiptKey(acknowledging: "m1", kind: MeshReceipt.kindRead), kind: .receipt))
        XCTAssertEqual(q.entries.count, 2)
        XCTAssertEqual(q.recordAttempt(id: key, nowMs: 5, accepted: false), .retained)
        XCTAssertEqual(q.recordAttempt(id: key, nowMs: 6, accepted: true), .removed)
        XCTAssertFalse(q.contains(id: key))
        XCTAssertEqual(q.entries.count, 1)
        XCTAssertEqual(entry(key, kind: .receipt).packetType, .receipt)
        XCTAssertEqual(entry("m").packetType, .data)
    }

    func testAReceiptDoesNotAcknowledgeAReceiptEntry() {
        var q = MeshOutboxQueue()
        let key = MeshOutboxEntry.receiptKey(acknowledging: "m1", kind: "d")
        q.enqueue(entry(key, kind: .receipt))
        XCTAssertNil(q.acknowledge(clientMsgId: key))
        XCTAssertEqual(q.entries.count, 1)
    }

    func testOutboxSurvivesEncodingForStorage() throws {
        var q = MeshOutboxQueue()
        q.enqueue(entry("m1"))
        _ = q.recordAttempt(id: "m1", nowMs: 7, accepted: true)
        let decoded = try JSONDecoder().decode(MeshOutboxQueue.self, from: try JSONEncoder().encode(q))
        XCTAssertEqual(decoded, q)
        XCTAssertEqual(decoded.entry(id: "m1")?.firstHopAccepted, true)
    }

    // MARK: - Log lines

    func testLogLinesCarryOnlyShortIdentifiersAndTokens() {
        let nodeHex = "21fe31dfa154a261"
        XCTAssertEqual(MeshLog.nodeHash(nodeHex), "21fe31")
        XCTAssertEqual(MeshLog.payloadHash(Data("abc".utf8)), "ba7816bf") // SHA-256("abc") starts ba7816bf
        XCTAssertEqual(MeshLog.linkHandle(outgoing: true, ordinal: 3), "c3")
        XCTAssertEqual(MeshLog.linkHandle(outgoing: false, ordinal: 1), "p1")
        XCTAssertEqual(MeshLog.line(.linkUp, [("link", "c1"), ("role", "c"), ("n", "2")]), "link.up link=c1 role=c n=2")
        // A full node id, a long hash, a name or free text cannot get into a line.
        XCTAssertEqual(MeshLog.line(.annRx, [("nh", nodeHex)]), "ann.rx nh=x")
        XCTAssertEqual(MeshLog.line(.rx, [("ph", String(repeating: "a", count: 64))]), "rx ph=x")
        XCTAssertEqual(MeshLog.line(.rx, [("who", "Marco Rossi")]), "rx who=x")
        XCTAssertEqual(MeshLog.line(.rx, [("who", "AA:BB:CC:DD:EE:FF")]), "rx who=x")
        XCTAssertEqual(MeshLog.line(.rxDrop, [("reason", "short_frame"), ("streak", "3")]), "rx.drop reason=short_frame streak=3")
        XCTAssertEqual(MeshLog.line(.identity, [("ok", "1"), ("nh", "21fe31"), ("src", "key")]), "identity ok=1 nh=21fe31 src=key")
    }

    func testBluetoothCallPauseAndBackoffLinesUseTheSpecifiedFields() {
        // Section 13: radio.pause (reason), radio.resume (reason, pausedMs), connect.backoff (link, failures, waitMs).
        XCTAssertEqual(MeshLog.line(.radioPause, [("reason", MeshBtCallPause.pauseReason)]),
                       "radio.pause reason=bt_call_route")
        XCTAssertEqual(MeshLog.line(.radioResume, [("reason", MeshBtCallPause.ResumeReason.callEnded.rawValue), ("pausedMs", "44210")]),
                       "radio.resume reason=call_ended pausedMs=44210")
        XCTAssertEqual(MeshLog.line(.radioResume, [("reason", MeshBtCallPause.ResumeReason.routeChanged.rawValue), ("pausedMs", "900")]),
                       "radio.resume reason=route_changed pausedMs=900")
        XCTAssertEqual(MeshLog.line(.connectBackoff, [("link", "c31"), ("failures", "1"), ("waitMs", "14213")]),
                       "connect.backoff link=c31 failures=1 waitMs=14213")
        // INFO events, like the rest of the radio and link events.
        XCTAssertEqual(MeshLog.Event.radioPause.level, .info)
        XCTAssertEqual(MeshLog.Event.radioResume.level, .info)
        XCTAssertEqual(MeshLog.Event.connectBackoff.level, .info)
    }

    func testEventNamesAndLevelsFollowTheSpecification() {
        XCTAssertEqual(MeshLog.Event.allCases.map(\.rawValue), [
            "identity", "radio", "link.up", "link.ready", "link.down", "link.refused", "ann.tx", "ann.rx",
            "tx", "tx.frame.fail", "rx", "rx.drop", "guard.block", "relay", "app.tx", "app.rx", "outbox",
            "radio.pause", "radio.resume", "connect.backoff",
        ])
        let warn = Set(MeshLog.Event.allCases.filter { $0.level == .warn }.map(\.rawValue))
        XCTAssertEqual(warn, ["tx.frame.fail", "rx.drop", "guard.block"])
        XCTAssertEqual(MeshLog.tag, "mesh")
    }

    func testSinkReceivesLevelTagAndLine() {
        final class Box: @unchecked Sendable { var got: [(MeshLog.Level, String, String)] = [] }
        let box = Box()
        MeshLog.install(sink: { level, tag, message in box.got.append((level, tag, message)) })
        defer { MeshLog.install(sink: nil) }
        MeshLog.emit(.radio, [("state", "on"), ("mode", "direct"), ("reason", "start")])
        MeshLog.emit(.txFrameFail, [("link", "c1"), ("ph", "ba7816bf"), ("idx", "0"), ("total", "3"), ("reason", "timeout")])
        XCTAssertEqual(box.got.count, 2)
        XCTAssertEqual(box.got[0].2, "radio state=on mode=direct reason=start")
        XCTAssertEqual(box.got[0].1, "mesh")
        XCTAssertEqual(box.got[1].0, .warn)
    }

    // MARK: - Strict packet rules beyond the vectors

    func testSourceRouteBoundsAndCanonicalFlags() throws {
        let hops = (1...255).map { node($0) }
        let full = try MeshPacket(type: .data, senderId: node(1), recipientId: node(2), ttl: 5, sourceRoute: hops,
                                  timestampMs: 1, payload: Data(count: MeshPacket.maxPayloadBytes))
        XCTAssertEqual(full.encode().count, MeshPacket.maxEncodedBytes)
        XCTAssertEqual(MeshPacket.decode(full.encode()), full)
        // Canonical form: flags only ever carry bit0 and bit1.
        var withTtl = packet().encode()
        XCTAssertEqual(withTtl[18], 0x01)
        withTtl[18] = 0x03 // route flag with no route bytes: truncated or empty route, never accepted
        XCTAssertNil(MeshPacket.decode(withTtl))
    }
}
