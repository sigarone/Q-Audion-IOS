import XCTest
@testable import QAudionEngine

/// Replays `sender_sequences` of `location-kat.json` (WIRE_SPEC section 14.6.1 rules 2, 3, 5, 8, 9 and 10) against `LocationShareSender`.
///
/// A step that builds a frame (`tick`, or a `stop` that builds the final frame at once) may carry `"write":"fails"`: the harness makes
/// the transport fail the write of that very frame during that step, and then compares the WHOLE result of the step, `next_ctr`
/// included. A sender that advances its counter only after a successful write, or gives it back on failure, answers `next_ctr` one
/// too low there. A harness whose transport succeeds on a step marked `fails` does not run the vector: this one asserts that the write
/// was attempted.
final class LocationSenderKatTests: XCTestCase {

    private struct WriteFailure: Error {}

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        var stops: [(String, Int64)] = []
        var withdrawn: [String] = []

        func stop(_ id: String, _ ts: Int64) { lock.lock(); stops.append((id, ts)); lock.unlock() }
        func withdraw(_ id: String) { lock.lock(); withdrawn.append(id); lock.unlock() }
    }

    private static let selfId = "b9d7540f-ece4-4b58-b03b-e0001e522085"
    private static let peerId = "a353aefc-1716-4516-9ffc-3f8d69ffe0b8"

    private func result(_ outcome: LocationSenderOutcome) -> [String: Any] {
        var out: [String: Any] = ["k_held": outcome.keyHeld]
        if let frame = outcome.frame { out["frame"] = ["ctr": Int(frame.counter), "kind": frame.kind] as [String: Any] }
        if let next = outcome.nextCounter { out["next_ctr"] = Int(next) }
        if let refusal = outcome.refusal { out["refused"] = refusal.rawValue }
        if let stop = outcome.stop { out["loc_stop"] = stop.rawValue }
        if outcome.outboxWithdrawn { out["outbox"] = "withdrawn" }
        return out
    }

    func testEverySenderSequence() throws {
        let sequences = LocationKat.section(try LocationKat.load(), "sender_sequences")
        XCTAssertEqual(sequences.count, 15)
        var failedWrites = 0
        for sequence in sequences {
            let name = sequence["name"] as? String ?? "?"
            let recorder = Recorder()
            let journal = InMemoryLocationShareJournal()
            let effects = LocationShareSenderEffects(sendStop: { recorder.stop($0, $1) }, withdrawStart: { recorder.withdraw($0) })
            var sender: LocationShareSender?
            var shareNumber = 0
            var currentStartId = ""
            let steps = try XCTUnwrap(sequence["steps"] as? [[String: Any]], name)
            for (index, step) in steps.enumerated() {
                let event = try XCTUnwrap(step["event"] as? [String: Any], name)
                let type = try XCTUnwrap(event["t"] as? String, name)
                let at = try XCTUnwrap(LocationKat.int(event, "at"), name)
                let label = "\(name) step \(index) (\(type)): \(event["note"] as? String ?? "")"
                let fails = event["write"] as? String == "fails"
                var writeAttempts = 0
                let write: (LocationFrameCodec.Sealed) throws -> Void = { frame in
                    writeAttempts += 1
                    XCTAssertEqual(frame.bytes.count, LocationWire.frameLength, label)
                    if fails { throw WriteFailure() }
                }
                var outcome = LocationSenderOutcome()
                switch type {
                case "start":
                    shareNumber += 1
                    currentStartId = "start-\(shareNumber)"
                    // A fresh sid and key for every share (counters belong to a share, and a process builds one sender per sid).
                    let secrets = LocationShareSecrets.generate()
                    let key = secrets.key
                    let fix = LocationSenderFix(latE7: 454_642_110, lonE7: 91_899_820, accuracy: 12, approximate: false, capturedAt: at - 3)
                    let created = try XCTUnwrap(LocationShareSender(startClientMsgId: currentStartId, selfId: Self.selfId, peerId: Self.peerId,
                                                                    sid: secrets.sid, shareKey: key, startedAt: at, duration: 3_600, fix: fix,
                                                                    effects: effects, journal: journal), label)
                    sender = created
                    outcome.keyHeld = created.keyHeld
                    outcome.nextCounter = created.nextCounter
                case "sent":
                    outcome = try XCTUnwrap(sender, label).startLeftDevice()
                case "echo":
                    outcome = try XCTUnwrap(sender, label).startAcknowledged(now: at)
                case "tick":
                    outcome = try XCTUnwrap(sender, label).tick(now: at, write: write)
                case "stop":
                    let mode = LocationFinalFrameMode(rawValue: event["final"] as? String ?? "") ?? .onTick
                    outcome = try XCTUnwrap(sender, label).stop(now: at, final: mode, write: write)
                case "socket_down":
                    outcome = try XCTUnwrap(sender, label).socketWentDown()
                case "socket_up":
                    outcome = try XCTUnwrap(sender, label).socketCameUp()
                case "restart":
                    // The process died: only the durable note survives it. The new process builds no frame for the share.
                    let entry = try XCTUnwrap(journal.entries().first { $0.startClientMsgId == currentStartId }, label)
                    let recovered = LocationShareSender.recoverAfterRestart(entry: entry, now: at, effects: effects, journal: journal)
                    sender = recovered.sender
                    outcome = recovered.outcome
                default:
                    XCTFail("\(label): unknown event")
                }
                if fails {
                    failedWrites += 1
                    XCTAssertEqual(writeAttempts, 1, "\(label): the write of the frame must have been attempted (and failed)")
                } else {
                    XCTAssertLessThanOrEqual(writeAttempts, 1, label)
                }
                let expected = try XCTUnwrap(step["result"] as? [String: Any], label)
                XCTAssertEqual(LocationKat.canonical(result(outcome)), LocationKat.canonical(expected), label)
                // A frame appears in the result exactly when the transport was asked to write one.
                XCTAssertEqual(outcome.frame != nil, writeAttempts == 1, label)
            }
        }
        XCTAssertEqual(failedWrites, 3, "the vectors mark three steps whose write fails")
    }
}
