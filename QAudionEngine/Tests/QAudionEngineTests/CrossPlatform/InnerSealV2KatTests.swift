import XCTest
import CryptoKit
@testable import QAudionEngine

/// The sections `innerSealV2` and `nackResendV2.sendSwitchScript` of the shared known-answer file, run against the pure layer, the
/// session and the resend cache. Every vector is compared byte for byte.
final class InnerSealV2KatTests: XCTestCase {

    // MARK: - Loading

    private func load() throws -> [String: Any] {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "kat"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "Resources/kat")
        ]
        let url = try XCTUnwrap(candidates.compactMap { $0 }.first, "pqc-hardening-v1-kat.json is not in the test bundle")
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url), options: [])
        return try XCTUnwrap(object as? [String: Any])
    }

    private func hex(_ s: String) -> Data {
        var out = Data()
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            out.append(UInt8(s[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    private func section(_ root: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(root["innerSealV2"] as? [String: Any], "innerSealV2")
    }

    /// The vectors of a subsection: a plain array, or `{ ..., vectors: [...] }`.
    private func vectors(_ root: [String: Any], _ name: String) throws -> [[String: Any]] {
        let top = try section(root)
        if let plain = top[name] as? [[String: Any]] { return plain }
        let sub = try XCTUnwrap(top[name] as? [String: Any], name)
        return try XCTUnwrap(sub["vectors"] as? [[String: Any]], name)
    }

    private func str(_ d: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(d[key] as? String, key)
    }

    private func int(_ d: [String: Any], _ key: String) throws -> Int {
        try XCTUnwrap((d[key] as? NSNumber)?.intValue, key)
    }

    /// Counters are decimal strings in the file (they pass 2^53).
    private func counter(_ d: [String: Any], _ key: String) throws -> UInt64 {
        try XCTUnwrap(UInt64(try str(d, key)), key)
    }

    private func kind(_ word: String) -> InnerSealV2.Kind { word == "audio" ? .audio : .video }

    private func direction(_ word: String) -> InnerSealV2.Direction { word == "o2a" ? .offererToAcceptor : .acceptorToOfferer }

    // MARK: - Labels

    func testTheNewLabelsHaveTheirLengths() {
        XCTAssertEqual(HkdfLabels.innerSealSaltV2.count, 26)
        XCTAssertEqual(HkdfLabels.innerSealInfoPrefixV2.count, 22)
        XCTAssertEqual(HkdfLabels.innerSealAadPrefixV2.count, 11)
        XCTAssertTrue(HkdfLabels.verifyAllUtf8RoundTrip())
    }

    // MARK: - keys, nonceAad, frames

    func testKeysMatchTheSharedVectors() throws {
        let list = try vectors(try load(), "keys")
        XCTAssertEqual(list.count, 28)
        for v in list {
            let name = "\(try str(v, "set"))/E\(try int(v, "E"))/\(try str(v, "kind"))/\(try str(v, "dir"))"
            XCTAssertEqual(RekeyChain.asciiLower(try str(v, "channelCallId")), try str(v, "callIdL"), name)
            let key = InnerSealV2.deriveKey(
                sessionKey: hex(try str(v, "sessionKey")), callIdL: try str(v, "callIdL"), kind: kind(try str(v, "kind")),
                direction: direction(try str(v, "dir")))
            XCTAssertEqual(key, hex(try str(v, "key")), name)
            let info = InnerSealV2.keyInfo(
                callIdL: try str(v, "callIdL"), kind: kind(try str(v, "kind")), direction: direction(try str(v, "dir")))
            XCTAssertEqual(info, hex(try str(v, "info")), name)
        }
    }

    func testNonceAndAadMatchTheSharedVectors() throws {
        let list = try vectors(try load(), "nonceAad")
        XCTAssertEqual(list.count, 7)
        for v in list {
            let name = try str(v, "name")
            XCTAssertEqual(RekeyChain.asciiLower(try str(v, "channelCallId")), try str(v, "callIdL"), name)
            let ctr = try counter(v, "ctr")
            let k = kind(try str(v, "kind"))
            let d = direction(try str(v, "dir"))
            XCTAssertEqual(InnerSealV2.nonce(direction: d, kind: k, ctr: ctr), hex(try str(v, "nonce")), name)
            let epoch = Int32(try int(v, "E"))
            XCTAssertEqual(
                InnerSealV2.aad(callIdL: try str(v, "callIdL"), direction: d, kind: k, epoch: epoch, ctr: ctr),
                hex(try str(v, "aad")), name)
            XCTAssertEqual(UInt8(truncatingIfNeeded: epoch), UInt8(try int(v, "envelopeEpochByte")), name)
        }
    }

    func testSealReproducesTheSharedFramesAndOpenReturnsTheirPlaintext() throws {
        let root = try load()
        // The session key of a round is the one of the `lowercase` key set; a frame names its round and, for the mixed-case row,
        // its channel id.
        var sessionKeys: [Int: Data] = [:]
        for v in try vectors(root, "keys") {
            if (try str(v, "set")) == "lowercase" { sessionKeys[try int(v, "E")] = hex(try str(v, "sessionKey")) }
        }
        let list = try vectors(root, "frames")
        XCTAssertEqual(list.count, 7)
        for v in list {
            let name = try str(v, "name")
            let callIdL = RekeyChain.asciiLower((v["channelCallId"] as? String) ?? "kat-call-s9")
            let epoch = Int32(try int(v, "E"))
            let k = kind(try str(v, "kind"))
            let d = direction(try str(v, "dir"))
            let ctr = try counter(v, "ctr")
            let sessionKey = try XCTUnwrap(sessionKeys[Int(epoch)], name)
            let keyBytes = try XCTUnwrap(InnerSealV2.deriveKey(sessionKey: sessionKey, callIdL: callIdL, kind: k, direction: d), name)
            let key = SymmetricKey(data: keyBytes)
            let plaintext = hex(try str(v, "plaintext"))
            let envelope = InnerSealV2.seal(
                key: key, callIdL: callIdL, direction: d, kind: k, epoch: epoch, ctr: ctr, plaintext: plaintext)
            XCTAssertEqual(envelope, hex(try str(v, "envelope")), name)
            XCTAssertEqual(try int(v, "ctLen"), plaintext.count + InnerSealV2.tagBytes, name)
            guard case .envelope(let eByte, let parsedCtr, let ciphertext) = InnerSealV2.parse(hex(try str(v, "envelope"))) else {
                return XCTFail("parse \(name)")
            }
            XCTAssertEqual(eByte, UInt8(truncatingIfNeeded: epoch), name)
            XCTAssertEqual(parsedCtr, ctr, name)
            XCTAssertEqual(
                InnerSealV2.open(
                    key: key, callIdL: callIdL, direction: d, kind: k, epoch: epoch, ctr: ctr, ciphertextAndTag: ciphertext),
                plaintext, name)
        }
    }

    // MARK: - negatives and the window sequence

    private func makeSession(for receiver: [String: Any]) throws -> InnerSealV2Session {
        // The receiver names the direction it OPENS: it opens o2a as the acceptor, a2o as the offerer.
        let role: LiveCallCrypto.Role = (try str(receiver, "direction")) == "o2a" ? .acceptor : .offerer
        let session = InnerSealV2Session(callIdL: try str(receiver, "callIdL"), role: role, nowMs: { 0 })
        for slot in try XCTUnwrap(receiver["slots"] as? [[String: Any]]) {
            let epoch = Int32(try int(slot, "E"))
            let sessionKey = hex(try str(slot, "sessionKey"))
            if epoch == 0 {
                XCTAssertTrue(session.stageRound0(sessionKey: sessionKey))
            } else {
                let prepared = try XCTUnwrap(session.prepare(sessionKey: sessionKey))
                XCTAssertNil(session.install(epoch: epoch, prepared: prepared))
            }
        }
        if let committed = (receiver["windowHighestCommitted"] as? NSNumber)?.uint64Value, committed > 0 {
            session.commitReceivedCounterForTesting(committed)
        }
        return session
    }

    private func dropReason(_ reason: String) -> InnerDrop {
        switch reason {
        case "aead": return .aead
        case "no_slot": return .noSlot
        case "replay": return .replay
        case "too_old": return .tooOld
        case "malformed": return .malformed
        case "unknown_type": return .unknownType
        default:
            XCTFail("unknown reason \(reason)")
            return .closed
        }
    }

    func testNegativesAreDroppedForTheNamedReasonAndThePositiveControlsOpen() throws {
        let list = try vectors(try load(), "negatives")
        XCTAssertEqual(list.count, 13)
        for n in list {
            let name = try str(n, "name")
            let receiver = try XCTUnwrap(n["receiver"] as? [String: Any], name)
            let expect = try XCTUnwrap(n["expect"] as? [String: Any], name)
            let wire = hex(try str(n, "frame"))
            if (try str(receiver, "kind")) == "video" {
                // An audio-only session cannot open the video kind: the pure layer does, with the key of the round the byte names.
                guard case .envelope(let eByte, let ctr, let ciphertext) = InnerSealV2.parse(wire) else {
                    return XCTFail("parse \(name)")
                }
                let slots = try XCTUnwrap(receiver["slots"] as? [[String: Any]], name)
                let slot = try XCTUnwrap(slots.first { UInt8(truncatingIfNeeded: (try? int($0, "E")) ?? -1) == eByte }, name)
                let callIdL = try str(receiver, "callIdL")
                let d = direction(try str(receiver, "direction"))
                let keyBytes = try XCTUnwrap(
                    InnerSealV2.deriveKey(sessionKey: hex(try str(slot, "sessionKey")), callIdL: callIdL, kind: .video, direction: d), name)
                let opened = InnerSealV2.open(
                    key: SymmetricKey(data: keyBytes), callIdL: callIdL, direction: d, kind: .video,
                    epoch: Int32(try int(slot, "E")), ctr: ctr, ciphertextAndTag: ciphertext)
                XCTAssertNil(opened, name)
                XCTAssertEqual(try str(expect, "reason"), "aead", name)
                continue
            }
            let outcome = try makeSession(for: receiver).openAudio(wire: wire)
            if (try str(expect, "result")) == "open" {
                guard case .opened = outcome else { return XCTFail("\(name): \(outcome)") }
            } else {
                XCTAssertEqual(outcome, .dropped(dropReason(try str(expect, "reason"))), name)
            }
        }
    }

    func testTheWindowSequenceIsAcceptedOnceAndNeverCommittedByAFailedOpen() throws {
        let root = try load()
        let top = try section(root)
        let sequence = try XCTUnwrap(top["windowSequence"] as? [String: Any])
        let receiver = try XCTUnwrap(sequence["receiver"] as? [String: Any])
        XCTAssertEqual(try int(receiver, "windowSize"), Int(InnerAudioReplayWindow.windowSize))
        let session = try makeSession(for: receiver)
        let events = try XCTUnwrap(sequence["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 11)
        for event in events {
            let name = try str(event, "name")
            let outcome = session.openAudio(wire: hex(try str(event, "frame")))
            let expect = try str(event, "expect")
            if expect == "accept" {
                guard case .opened = outcome else { return XCTFail("\(name): \(outcome)") }
            } else {
                XCTAssertTrue(expect.hasPrefix("drop:"), name)
                XCTAssertEqual(outcome, .dropped(dropReason(String(expect.dropFirst(5)))), name)
            }
        }
    }

    // MARK: - dispatch and the video fragments

    func testDispatchKeepsTheFourHandledBytesAndDropsEveryOther() throws {
        let list = try vectors(try load(), "dispatch")
        XCTAssertEqual(list.count, 8)
        for v in list {
            let byte = try XCTUnwrap(hex(try str(v, "firstByte")).first)
            let handling = try str(v, "handling")
            let expected: InnerSealV2.Route
            switch handling {
            case "audio": expected = .audio
            case "video": expected = .video
            case "control": expected = .control
            case "envelope": expected = .envelope
            // 0x82 is a Desktop-only first byte: iOS defines none, so it is dropped like any other.
            default: expected = .drop
            }
            XCTAssertEqual(InnerSealV2.route(firstByte: byte), expected, handling)
        }
    }

    func testVideoFragmentsAreBuiltAndReadBackAndASliceReadsLikeAWholeValue() throws {
        let list = try vectors(try load(), "videoFragments")
        XCTAssertEqual(list.count, 2)
        for v in list {
            let name = try str(v, "name")
            let envelope = hex(try str(v, "envelope"))
            let wire = InnerSealV2.fragmentWire(
                fragIdx: UInt16(try int(v, "fragIdx")), totalFrags: UInt16(try int(v, "totalFrags")),
                isKey: (try int(v, "isKey")) == 1, envelope: envelope)
            XCTAssertEqual(wire, hex(try str(v, "binaryWireBytes")), name)
            guard case .envelope(let eByte, let ctr, _) = InnerSealV2.parse(envelope) else { return XCTFail("parse \(name)") }
            XCTAssertEqual(eByte, UInt8(truncatingIfNeeded: try int(v, "E")), name)
            XCTAssertEqual(ctr, try counter(v, "ctr"), name)
            // The same bytes as a slice that does not start at index 0.
            let slice = Data([0xAA] + envelope).dropFirst()
            XCTAssertEqual(InnerSealV2.parse(slice), InnerSealV2.parse(envelope), name)
            XCTAssertEqual(InnerSealV2.header(ofWire: slice)?.ctr, ctr, name)
            XCTAssertEqual(InnerSealV2.header(ofWire: slice)?.eByte, eByte, name)
            XCTAssertEqual(InnerSealV2.route(ofWire: slice), InnerSealV2.route(ofWire: envelope), name)
        }
    }

    // MARK: - nackResendV2.sendSwitchScript

    func testTheResendCacheFollowsTheSendSwitchScript() throws {
        let root = try load()
        let nack = try XCTUnwrap(root["nackResendV2"] as? [String: Any])
        let script = try XCTUnwrap(nack["sendSwitchScript"] as? [String: Any])
        let events = try XCTUnwrap(script["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 6)
        let ring = NackRetransmitRing()
        var seqs: [String: Int64] = [:]
        var wires: [String: Data] = [:]
        var sendByte: UInt8 = 0
        for event in events {
            switch try str(event, "ev") {
            case "seal":
                let frame = try str(event, "frame")
                let seq = Int64(seqs.count + 1)
                seqs[frame] = seq
                wires[frame] = hex(try str(event, "wire"))
                ring.record(
                    seq: seq, envelope: try XCTUnwrap(wires[frame]), epochByte: UInt8(truncatingIfNeeded: try int(event, "innerEpoch")))
            case "nackRequest":
                let frame = try str(event, "frame")
                let expect = try XCTUnwrap(event["expect"] as? [String: Any])
                let found = ring.lookup(seq: try XCTUnwrap(seqs[frame]), sendEpochByte: sendByte)
                if (expect["resend"] as? Bool) == true {
                    XCTAssertEqual(found, wires[frame], "a resend is the cached bytes")
                    XCTAssertEqual(found, hex(try str(expect, "wire")))
                } else {
                    XCTAssertNil(found, "the cache was dropped at the send switch")
                }
            case "sendSwitch":
                ring.clear()
                sendByte = UInt8(truncatingIfNeeded: try int(event, "toRound"))
            default:
                XCTFail("unknown event")
            }
            if let has = event["cacheHas"] as? [String] {
                for (frame, seq) in seqs {
                    // Present under the round it was sealed under, and under no other.
                    let present = [UInt8(0), UInt8(1)].contains { ring.lookup(seq: seq, sendEpochByte: $0) != nil }
                    XCTAssertEqual(present, has.contains(frame), "cacheHas \(frame)")
                }
            }
        }
    }
}
