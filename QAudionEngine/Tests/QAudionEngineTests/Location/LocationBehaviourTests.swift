import XCTest
@testable import QAudionEngine

/// Behaviour that the vector file cannot show: concurrency of the sealer, a failing store, the clear and delete-for-me rules, the builder
/// against the receiver on arbitrary fixes, hostile bytes, and the reply to a location. Pure logic, no network, no platform.
final class LocationBehaviourTests: XCTestCase {

    private let selfId = "a353aefc-1716-4516-9ffc-3f8d69ffe0b8"
    private let peerId = "b9d7540f-ece4-4b58-b03b-e0001e522085"
    private let sid = Data((0..<16).map { UInt8($0) })
    private let key = Data((32..<64).map { UInt8($0) })

    // MARK: The one sealer of a share

    /// Two threads hammer one sealer: every counter 1...N is used exactly once, and the next counter is N + 1 (section 14.6.1 rule 9).
    func testOneSealerNeverSealsACounterTwiceUnderConcurrency() throws {
        let sealer = try XCTUnwrap(LocationFrameSealer(sid: sid, shareKey: key, senderId: peerId, recipientId: selfId))
        let perThread = 400
        let collected = CounterBox()
        let group = DispatchGroup()
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                var mine: [UInt32] = []
                for _ in 0..<perThread {
                    if let sealed = sealer.seal(.position(latE7: 1, lonE7: 2, accuracy: 3, age: 4, approximate: false, interval: 30)) {
                        mine.append(sealed.counter)
                    }
                }
                collected.add(mine)
                group.leave()
            }
        }
        group.wait()
        let counters = collected.values
        XCTAssertEqual(counters.count, 4 * perThread)
        XCTAssertEqual(Set(counters).count, counters.count, "a counter was sealed twice")
        XCTAssertEqual(counters.min(), 1)
        XCTAssertEqual(counters.max(), UInt32(4 * perThread))
        XCTAssertEqual(sealer.nextCounter, UInt32(4 * perThread + 1))
    }

    func testAWipedSealerSealsNothingAndHoldsNoKey() throws {
        let sealer = try XCTUnwrap(LocationFrameSealer(sid: sid, shareKey: key, senderId: peerId, recipientId: selfId))
        XCTAssertTrue(sealer.holdsKey)
        XCTAssertNotNil(sealer.seal(.finalFrame))
        sealer.wipe()
        XCTAssertFalse(sealer.holdsKey)
        XCTAssertNil(sealer.nextCounter)
        XCTAssertNil(sealer.seal(.finalFrame))
    }

    func testTheKeyScheduleNeedsExactLengths() {
        XCTAssertNil(LocationFrameKeys(sid: Data(count: 15), shareKey: key))
        XCTAssertNil(LocationFrameKeys(sid: sid, shareKey: Data(count: 31)))
        XCTAssertNil(LocationFrameSealer(sid: sid, shareKey: Data(count: 33), senderId: peerId, recipientId: selfId))
    }

    /// An id longer than 255 bytes cannot be written with a one-byte length: no frame is sealed for it.
    func testAnOverlongIdSealsNothing() throws {
        let sealer = try XCTUnwrap(LocationFrameSealer(sid: sid, shareKey: key, senderId: String(repeating: "x", count: 256),
                                                       recipientId: selfId))
        XCTAssertNil(sealer.seal(.finalFrame))
    }

    // MARK: Sender: the end by time

    func testASenderThatReachesItsEndTimeSendsTheStopAndTheFinalFrameAtOnce() throws {
        let sid = LocationShareSecrets.generate().sid
        let stops = StopLog()
        let effects = LocationShareSenderEffects(sendStop: { id, _ in stops.add(id) }, withdrawStart: { _ in })
        let fix = LocationSenderFix(latE7: 1, lonE7: 2, accuracy: 3, approximate: false, capturedAt: 100)
        let sender = try XCTUnwrap(LocationShareSender(startClientMsgId: "s1", selfId: peerId, peerId: selfId, sid: sid, shareKey: key,
                                                       startedAt: 100, duration: 60, fix: fix, effects: effects,
                                                       journal: InMemoryLocationShareJournal()))
        _ = sender.startLeftDevice()
        _ = sender.startAcknowledged(now: 101)
        let first = sender.tick(now: 130, write: { _ in })
        XCTAssertEqual(first.frame?.counter, 1)
        XCTAssertEqual(first.frame?.kind, "position")
        var written: [LocationFrameCodec.Sealed] = []
        let last = sender.tick(now: 160, write: { written.append($0) })
        XCTAssertEqual(last.frame?.counter, 2)
        XCTAssertEqual(last.frame?.kind, "final")
        XCTAssertEqual(last.stop, .sent)
        XCTAssertFalse(last.keyHeld)
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(stops.ids, ["s1"])
        XCTAssertEqual(sender.tick(now: 190, write: { _ in }).refusal, .ended)
    }

    func testTheTickFollowsTheLowPowerInterval() throws {
        let sid = LocationShareSecrets.generate().sid
        let fix = LocationSenderFix(latE7: 1, lonE7: 2, accuracy: 3, approximate: true, capturedAt: 100)
        let effects = LocationShareSenderEffects(sendStop: { _, _ in }, withdrawStart: { _ in })
        let sender = try XCTUnwrap(LocationShareSender(startClientMsgId: "s1", selfId: peerId, peerId: selfId, sid: sid, shareKey: key,
                                                       startedAt: 100, duration: 3_600, fix: fix, effects: effects,
                                                       journal: InMemoryLocationShareJournal()))
        _ = sender.startAcknowledged(now: 100)
        var frames: [LocationFrameCodec.Sealed] = []
        _ = sender.tick(now: 130, write: { frames.append($0) })
        sender.setLowPower(true)
        _ = sender.tick(now: 190, write: { frames.append($0) })
        let keys = try XCTUnwrap(LocationFrameKeys(sid: sid, shareKey: key))
        func iv(_ frame: LocationFrameCodec.Sealed) throws -> UInt16 {
            guard case .success(let opened) = LocationFrameCodec.openAndJudge(frame.bytes, keys: keys, senderId: peerId, recipientId: selfId) else {
                XCTFail("the frame does not open")
                return 0
            }
            return opened.plaintext.iv
        }
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(try iv(frames[0]), 30)
        XCTAssertEqual(try iv(frames[1]), 60)
        // The age grows while no newer fix arrives, and the approximate flag is carried.
        guard case .success(let second) = LocationFrameCodec.openAndJudge(frames[1].bytes, keys: keys, senderId: peerId, recipientId: selfId) else {
            return XCTFail("the second frame does not open")
        }
        XCTAssertEqual(second.plaintext.age, 90)
        XCTAssertTrue(second.plaintext.isApproximate)
    }

    /// One sealer per share inside the process (section 14.6.1 rule 9): a second sender for a share id that already has one is refused,
    /// whatever the second one holds (the start body read back from the outbox, a second scene's copy, a retry).
    func testASecondSenderForTheSameShareIsRefused() throws {
        let secrets = LocationShareSecrets.generate()
        let fix = LocationSenderFix(latE7: 1, lonE7: 2, accuracy: 3, approximate: false, capturedAt: 100)
        let effects = LocationShareSenderEffects(sendStop: { _, _ in }, withdrawStart: { _ in })
        let first = LocationShareSender(startClientMsgId: "s1", selfId: peerId, peerId: selfId, sid: secrets.sid, shareKey: secrets.key,
                                        startedAt: 100, duration: 3_600, fix: fix, effects: effects, journal: InMemoryLocationShareJournal())
        XCTAssertNotNil(first)
        let second = LocationShareSender(startClientMsgId: "s1-copy", selfId: peerId, peerId: selfId, sid: secrets.sid,
                                         shareKey: secrets.key, startedAt: 100, duration: 3_600, fix: fix, effects: effects,
                                         journal: InMemoryLocationShareJournal())
        XCTAssertNil(second, "a second sealer for one share would seal the same counters again")
        // A different share is a different sender.
        let other = LocationShareSecrets.generate()
        XCTAssertNotNil(LocationShareSender(startClientMsgId: "s2", selfId: peerId, peerId: selfId, sid: other.sid, shareKey: other.key,
                                            startedAt: 100, duration: 3_600, fix: fix, effects: effects,
                                            journal: InMemoryLocationShareJournal()))
    }

    private final class CounterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [UInt32] = []
        func add(_ more: [UInt32]) { lock.lock(); stored.append(contentsOf: more); lock.unlock() }
        var values: [UInt32] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private final class StopLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var ids: [String] = []
        func add(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
    }

    // MARK: Receiver: the store

    private func liveStart(sid: Data? = nil, startedAt: Int64 = 1_000, duration: Int64 = 3_600) -> (LocationLiveStart, LocationPosition) {
        (LocationLiveStart(sid: sid ?? self.sid, key: key, startedAt: startedAt, duration: duration),
         LocationPosition(latE7: 454_642_110, lonE7: 91_899_820, accuracy: 12, age: 3, approximate: false))
    }

    private func sealedFrame(counter: UInt32, plaintext: LocationFramePlaintext) throws -> String {
        let keys = try XCTUnwrap(LocationFrameKeys(sid: sid, shareKey: key))
        return try XCTUnwrap(LocationFrameCodec.seal(plaintext, counter: counter, keys: keys, senderId: peerId, recipientId: selfId)).base64
    }

    /// A failed durable write ends the share (`state_lost`) and the frame is NOT applied: nothing is shown that was not stored.
    func testAFailedWriteEndsTheShareAndAppliesNothing() throws {
        let store = InMemoryLocationShareStore()
        let receiver = try LocationShareReceiver(selfId: selfId, peerId: peerId, store: store, now: 1_000)
        let (live, position) = liveStart()
        XCTAssertEqual(receiver.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_000), .applied)
        let frame = try sealedFrame(counter: 1, plaintext: .position(latE7: 5, lonE7: 6, accuracy: 7, age: 0, approximate: false, interval: 30))
        store.failWrites = true
        XCTAssertEqual(receiver.receiveFrame(payload: frame, now: 1_030), .storeFailed)
        store.failWrites = false
        let share = try XCTUnwrap(receiver.share(id: "c1", now: 1_030))
        XCTAssertEqual(share.state, .ended)
        XCTAssertEqual(share.reason, .stateLost)
        XCTAssertNil(share.position)
        XCTAssertNil(store.shareKey(forShare: "c1"), "the key goes with the share")
    }

    /// The receiver keeps only the position that the store holds: a position is never shown from memory alone.
    func testThePositionComesFromTheDurableState() throws {
        let store = InMemoryLocationShareStore()
        let receiver = try LocationShareReceiver(selfId: selfId, peerId: peerId, store: store, now: 1_000)
        let (live, position) = liveStart()
        _ = receiver.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_000)
        let frame = try sealedFrame(counter: 5, plaintext: .position(latE7: 5, lonE7: 6, accuracy: 7, age: 1, approximate: true, interval: 60))
        XCTAssertEqual(receiver.receiveFrame(payload: frame, now: 1_040), .applied)
        let stored = try store.load().records.first
        XCTAssertEqual(stored?.live?.lastCounter, 5)
        XCTAssertEqual(stored?.live?.lastFrameAt, 1_040)
        XCTAssertEqual(stored?.live?.interval, 60)
        XCTAssertEqual(stored?.live?.position, LiveSharePosition(latE7: 5, lonE7: 6, accuracy: 7, approximate: true, fixAt: 1_039))
    }

    /// A clear, a logout or a delete for me ends the share and keeps the two ids: the start redelivered afterwards is a duplicate.
    func testClearAndDeleteForMeKeepTheIdsForTheDuplicateTest() throws {
        for action in ["clear", "deleteForMe"] {
            let store = InMemoryLocationShareStore()
            let receiver = try LocationShareReceiver(selfId: selfId, peerId: peerId, store: store, now: 1_000)
            let (live, position) = liveStart()
            _ = receiver.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_000)
            if action == "clear" { receiver.endAllForLocalClear(now: 1_010) } else { receiver.deleteForMe(id: "c1", now: 1_010) }
            let share = try XCTUnwrap(receiver.share(id: "c1", now: 1_010), action)
            XCTAssertEqual(share.state, .ended, action)
            XCTAssertTrue(share.noCard, action)
            XCTAssertNil(share.position, action)
            XCTAssertNil(store.shareKey(forShare: "c1"), action)
            // The same client message id, and the same sid under a new id, are duplicates; nothing is created.
            XCTAssertEqual(receiver.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_020), .dropped(.startDuplicate), action)
            XCTAssertEqual(receiver.receiveStart(clientMsgId: "c2", live: live, position: position, now: 1_020), .dropped(.startDuplicate), action)
            XCTAssertEqual(receiver.shares(now: 1_020).count, 1, action)
        }
    }

    /// Equal ordering times are ordered by arrival (section 14.6.2 step 4): the later arrival is the newer share and supersedes the
    /// earlier one; it is not born superseded.
    func testEqualOrderingTimesFavourTheLaterArrival() throws {
        let receiver = try LocationShareReceiver(selfId: selfId, peerId: peerId, store: InMemoryLocationShareStore(), now: 1_000)
        let (first, position) = liveStart(startedAt: 1_000)
        let second = LocationLiveStart(sid: Data((100..<116).map { UInt8($0) }), key: key, startedAt: 1_000, duration: 3_600)
        XCTAssertEqual(receiver.receiveStart(clientMsgId: "c1", live: first, position: position, now: 1_000), .applied)
        XCTAssertEqual(receiver.receiveStart(clientMsgId: "c2", live: second, position: position, now: 1_000), .applied)
        XCTAssertEqual(receiver.share(id: "c1", now: 1_000)?.reason, .superseded)
        XCTAssertEqual(receiver.share(id: "c2", now: 1_000)?.state, .active)
    }

    func testABlockedPeerIsIgnoredUntilUnblocked() throws {
        let receiver = try LocationShareReceiver(selfId: selfId, peerId: peerId, store: InMemoryLocationShareStore(), now: 1_000)
        receiver.blockPeer(now: 1_000)
        let (live, position) = liveStart()
        XCTAssertEqual(receiver.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_001), .ignored)
        XCTAssertEqual(receiver.receiveStop(from: .peer, target: "c9", now: 1_002), .ignored)
        XCTAssertTrue(receiver.rememberedTombstones(now: 1_002).isEmpty, "a stop from a blocked sender is not remembered")
        receiver.unblockPeer()
        XCTAssertEqual(receiver.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_003), .applied)
    }

    func testAPayloadThatIsNotCanonicalBase64Is_frame_format() throws {
        let receiver = try LocationShareReceiver(selfId: selfId, peerId: peerId, store: InMemoryLocationShareStore(), now: 1_000)
        for payload in ["", "AQ", "not base64!", String(repeating: "A", count: 400), "AQAAAAGj\n"] {
            XCTAssertEqual(receiver.receiveFrame(payload: payload, now: 1_000), .dropped(.frameFormat), payload)
        }
    }

    // MARK: Builder against receiver, hostile bytes

    func testWhateverTheBuilderWritesTheReceiverAccepts() {
        var generator = SeededGenerator(seed: 0x51A7)
        for _ in 0..<500 {
            let fix = LocationFix(latitude: Double.random(in: -90...90, using: &generator),
                                  longitude: Double.random(in: -180...180, using: &generator),
                                  horizontalAccuracy: Double.random(in: 0...70_000, using: &generator),
                                  elapsedMs: Int64.random(in: -10_000...120_999, using: &generator),
                                  approximate: Bool.random(using: &generator))
            switch LocationCodec.buildPin(fix: fix) {
            case .failure(let refusal):
                XCTFail("a valid fix was refused: \(refusal)")
            case .success(let text):
                XCTAssertLessThan(text.utf8.count, 200)
                guard case .location(.pin(let position)) = LocationCodec.recognize(text, channel: .group) else {
                    return XCTFail("the receiver does not accept the builder's pin")
                }
                XCTAssertEqual(.success(position.latE7), LocationConversion.e7(degrees: fix.latitude, axis: .latitude))
            }
            let secrets = LocationShareSecrets.generate()
            let duration = LocationWire.duPresets[Int.random(in: 0..<LocationWire.duPresets.count, using: &generator)]
            if case .success(let text) = LocationCodec.buildLiveStart(fix: fix, sid: secrets.sid, key: secrets.key, startedAt: 1_792_756_800,
                                                                       duration: duration) {
                guard case .location(.live(let live, _)) = LocationCodec.recognize(text, channel: .chat) else {
                    return XCTFail("the receiver does not accept the builder's live start")
                }
                XCTAssertEqual(live.sid, secrets.sid)
                XCTAssertEqual(live.key, secrets.key)
                XCTAssertEqual(live.duration, duration)
            } else {
                XCTFail("a valid live start was refused")
            }
        }
    }

    func testTwoSharesNeverShareASecret() {
        let a = LocationShareSecrets.generate()
        let b = LocationShareSecrets.generate()
        XCTAssertEqual(a.sid.count, 16)
        XCTAssertEqual(a.key.count, 32)
        XCTAssertNotEqual(a.sid, b.sid)
        XCTAssertNotEqual(a.key, b.key)
    }

    /// Random bytes behind the prefix never crash the recogniser and never produce a location unless they are one.
    func testHostileBytesAreRejectedWithoutCrashing() {
        var generator = SeededGenerator(seed: 0xB0D1E5)
        for _ in 0..<2_000 {
            var bytes = LocationWire.prefix
            for _ in 0..<Int.random(in: 0...120, using: &generator) { bytes.append(UInt8.random(in: 0...255, using: &generator)) }
            if case .location = LocationCodec.recognize(utf8: Data(bytes), channel: .chat) {
                XCTFail("random bytes were accepted as a location")
            }
            _ = LocationStopControl.parse(utf8: Data(bytes))
        }
        // A body of 8191 bytes is judged, 8192 is not (the profile's bound), and a huge version is only a version.
        let pad = String(repeating: "a", count: 8_191 - #"{"qa_loc":1,"m":"pin","x":""}"#.utf8.count)
        XCTAssertEqual(LocationCodec.recognize(#"{"qa_loc":1,"m":"pin","x":"\#(pad)"}"#, channel: .chat), .rejected(.badLocation))
        XCTAssertEqual(LocationCodec.recognize(#"{"qa_loc":2,"m":"pin","x":"\#(pad)aaaa"}"#, channel: .chat), .rejected(.unsupportedVersion))
    }

    func testThePlaceholderForARejection() {
        XCTAssertEqual(LocationBodyPlaceholder.forRejection(.badLocation, body: Data()), .unavailable)
        XCTAssertEqual(LocationBodyPlaceholder.forRejection(.unsupportedContext, body: Data()), .unavailable)
        XCTAssertEqual(LocationBodyPlaceholder.forRejection(.unsupportedVersion, body: Data(#"{"qa_loc":2}"#.utf8)), .unsupportedVersion)
        // A plain version of 0 or below is not "update the app".
        XCTAssertEqual(LocationBodyPlaceholder.forRejection(.unsupportedVersion, body: Data(#"{"qa_loc":0}"#.utf8)), .unavailable)
        XCTAssertEqual(LocationBodyPlaceholder.forRejection(.unsupportedVersion, body: Data(#"{"qa_loc":-1}"#.utf8)), .unavailable)
        XCTAssertFalse(LocationBodyPlaceholder.text(.unavailable).contains("{"))
        XCTAssertFalse(LocationBodyPlaceholder.text(.unsupportedVersion).contains("{"))
    }

    // MARK: Replies to a location (WIRE_SPEC 13 and 14.3.7)

    func testAReplyToALocationQuotesNothing() throws {
        let to = "02492d4c-5000-4bb5-b3e1-bc2251047168"
        let built = MessageReplyCodec.build(to: to, kind: "location", quoteSource: "45.4642110,9.1899820", quotedIsEphemeral: false, body: "Arrivo")
        XCTAssertEqual(built, .success(#"{"qa_reply":1,"to":"\#(to)","k":"location","q":"","b":"Arrivo"}"#))
        // A body that is a location message is refused as a reply text (the fifth prefix).
        XCTAssertEqual(MessageReplyCodec.build(to: to, kind: "text", quoteSource: nil, quotedIsEphemeral: false, body: #"{"qa_loc":1}"#),
                       .failure(.bodyPrefix))
        guard case .reply(let reply) = MessageReplyCodec.recognize(#"{"qa_reply":1,"to":"\#(to)","k":"location","q":"45.4642110,9.1899820","b":"Ok"}"#) else {
            return XCTFail("a reply to a location is a reply")
        }
        XCTAssertEqual(reply.displayedQuote, "", "q is never shown for a location, whatever it holds")
        let found = MessageReplyRow(id: to, sameConversation: true, kind: .location, text: "45.4642110,9.1899820", author: "peer",
                                    viewOnce: false, gone: false, live: true)
        let block = MessageReplyCodec.resolve(reply, rows: [found])
        XCTAssertEqual(block.excerpt, "")
        XCTAssertEqual(block.label, "location_live")
        XCTAssertEqual(MessageReplyCodec.resolve(reply, rows: []).label, "location")
    }

    func testTheFifthPrefixIsReserved() {
        XCTAssertTrue(MessageReplyCodec.hasReservedPrefix(#"{"qa_loc":1,"m":"pin"} grazie"#))
        XCTAssertTrue(MessageReplyCodec.hasReservedPrefix(#"{"qa_loc":"#))
        XCTAssertFalse(MessageReplyCodec.hasReservedPrefix(#" {"qa_loc":1}"#))
        XCTAssertFalse(MessageReplyCodec.hasReservedPrefix(#"{"qa_ctl":1,"t":"loc_stop"}"#))
        XCTAssertTrue(LocationCodec.hasLocationPrefix(#"{"qa_loc":1}"#))
        XCTAssertFalse(LocationCodec.hasLocationPrefix(#"{"qa_locx":1}"#))
    }
}

/// A small deterministic generator for the property tests: the same sequence on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        // splitmix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
