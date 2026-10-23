import XCTest
@testable import QAudionEngine

/// Replays `receiver_sequences` of `location-kat.json` (WIRE_SPEC sections 14.6.2 to 14.7) against `LocationShareReceiver`, a start
/// followed by timed events (frames by counter, out of order, duplicates, a final frame, a `loc_stop`, a delete, a second start, time
/// steps, a block, a reload of the stored state with or without the counter or the key). After EVERY step the state of every share
/// at the time of the event, the tombstones and the dropped label are compared with the vector.
final class LocationReceiverKatTests: XCTestCase {

    private func position(_ view: LiveShareView) -> [String: Any]? {
        guard let position = view.position else { return nil }
        return ["lat": Int(position.latE7), "lon": Int(position.lonE7), "acc": position.accuracy, "ap": position.approximate ? 1 : 0,
                "fix_at": Int(position.fixAt)]
    }

    private func describe(_ view: LiveShareView) -> [String: Any] {
        var out: [String: Any] = ["id": view.id, "state": view.state.rawValue, "end_at": Int(view.endAt)]
        if let reason = view.reason { out["reason"] = reason.rawValue }
        if let counter = view.lastCounter { out["last_ctr"] = Int(counter) }
        if let last = view.lastFrameAt { out["last_frame_at"] = Int(last) }
        if let pos = position(view) { out["pos"] = pos }
        if view.noCard { out["no_card"] = true }
        return out
    }

    func testEveryReceiverSequence() throws {
        let sequences = LocationKat.section(try LocationKat.load(), "receiver_sequences")
        XCTAssertEqual(sequences.count, 36)
        var steps = 0
        var dropped = 0
        for sequence in sequences {
            let name = sequence["name"] as? String ?? "?"
            let selfId = try XCTUnwrap(sequence["self_id"] as? String, name)
            let peerId = try XCTUnwrap(sequence["peer_id"] as? String, name)
            let store = InMemoryLocationShareStore()
            let all = try XCTUnwrap(sequence["steps"] as? [[String: Any]], name)
            let firstAt = try XCTUnwrap(LocationKat.int(try XCTUnwrap(all.first?["event"] as? [String: Any]), "at"))
            var receiver = try LocationShareReceiver(selfId: selfId, peerId: peerId, store: store, now: firstAt)
            for (index, step) in all.enumerated() {
                let event = try XCTUnwrap(step["event"] as? [String: Any], name)
                let type = try XCTUnwrap(event["t"] as? String, name)
                let at = try XCTUnwrap(LocationKat.int(event, "at"), name)
                let label = "\(name) step \(index) (\(type)): \(event["note"] as? String ?? "")"
                var outcome: LocationReceiveOutcome = .ignored
                switch type {
                case "start":
                    let id = try XCTUnwrap(event["id"] as? String, label)
                    let body = Data(try XCTUnwrap(event["body"] as? String, label).utf8)
                    guard case .location(.live(let live, let position)) = LocationCodec.recognize(utf8: body, channel: .chat) else {
                        XCTFail("\(label): the start body is not a valid live start")
                        continue
                    }
                    outcome = receiver.receiveStart(clientMsgId: id, live: live, position: position, now: at)
                case "frame":
                    outcome = receiver.receiveFrame(payload: try XCTUnwrap(event["frame_b64"] as? String, label), now: at)
                case "tick":
                    receiver.advance(now: at)
                case "stop", "delete":
                    let origin: LocationShareReceiver.Origin = event["from"] as? String == "peer" ? .peer : .selfAccount
                    let target = try XCTUnwrap(event["target"] as? String, label)
                    outcome = type == "stop" ? receiver.receiveStop(from: origin, target: target, now: at)
                                             : receiver.receiveDeleteForEveryone(from: origin, target: target, now: at)
                case "block":
                    receiver.blockPeer(now: at)
                case "reload":
                    // The process restarts: a new receiver reads the store back. A record that cannot be read, or a key that cannot
                    // be loaded, ends its share as `state_lost`.
                    for id in (event["lose"] as? [String]) ?? [] { store.loseCounter(forShare: id) }
                    for id in (event["lose_key"] as? [String]) ?? [] { store.loseKey(forShare: id) }
                    receiver = try LocationShareReceiver(selfId: selfId, peerId: peerId, store: store, now: at)
                default:
                    XCTFail("\(label): unknown event")
                }
                steps += 1

                // The dropped label, when there is one.
                var label8: String?
                if case .dropped(let drop) = outcome { label8 = drop.rawValue; dropped += 1 }
                XCTAssertEqual(label8, step["dropped"] as? String, label)
                XCTAssertNotEqual(outcome, .storeFailed, label)

                // Every share, at the time of the event.
                let expectedShares = try XCTUnwrap(step["shares"] as? [[String: Any]], label)
                let actual = receiver.shares(now: at)
                XCTAssertEqual(actual.count, expectedShares.count, label)
                for expected in expectedShares {
                    let id = try XCTUnwrap(expected["id"] as? String, label)
                    guard let view = actual.first(where: { $0.id == id }) else {
                        XCTFail("\(label): no share \(id)")
                        continue
                    }
                    XCTAssertEqual(LocationKat.canonical(describe(view)), LocationKat.canonical(expected), label)
                }

                // The tombstones, in order of arrival; none is an empty list.
                let expectedTombstones = (step["tombstones"] as? [[String: Any]]) ?? []
                let tombstones = receiver.rememberedTombstones(now: at).map {
                    ["target": $0.target, "reason": $0.reason.rawValue, "until": Int($0.until)] as [String: Any]
                }
                XCTAssertEqual(LocationKat.canonical(tombstones), LocationKat.canonical(expectedTombstones), label)
            }
        }
        XCTAssertEqual(steps, 231)
        XCTAssertEqual(dropped, 51)
    }
}
