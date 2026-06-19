import XCTest
import CryptoKit
@testable import QAudionEngine

/// Cross-platform KAT verifier for the Q-Audion SFrame video codec.
///
/// Loads `sframe-video-kat.json` from the test bundle and asserts byte-equal
/// `expected_wire_hex` for every vector. The JSON is the immutable
/// cross-platform contract — DO NOT modify it. Any divergence here means
/// either this Swift port or the Kotlin reference (which generated the JSON)
/// disagrees on the wire layout, and the divergence must be reconciled
/// before merging.
///
/// See `docs/SFRAME_VIDEO_WIRE_SPEC.md` (in the Android repo) for the spec.
final class SFrameCodecKatTest: XCTestCase {

    func testVectorsMatchCrossPlatformContract() throws {
        guard let url = Bundle.module.url(forResource: "sframe-video-kat", withExtension: "json") else {
            XCTFail("sframe-video-kat.json not found in Bundle.module")
            return
        }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("KAT JSON top-level is not an object")
            return
        }
        guard let vectors = json["vectors"] as? [[String: Any]] else {
            XCTFail("KAT JSON missing 'vectors' array")
            return
        }
        XCTAssertFalse(vectors.isEmpty, "KAT JSON contains no vectors")

        for v in vectors {
            try runVector(v)
        }
    }

    // MARK: - Per-vector

    private func runVector(_ v: [String: Any]) throws {
        guard let name = v["name"] as? String else { XCTFail("vector missing name"); return }
        guard let masterInputHex = v["master_input_hex"] as? String,
              let masterInput = Self.fromHex(masterInputHex) else {
            XCTFail("[\(name)] invalid master_input_hex"); return
        }
        guard let mode = v["mode"] as? String else { XCTFail("[\(name)] missing mode"); return }

        let master: Data
        let kid: Data
        switch mode {
        case "1to1":
            master = try SFrameCodec.deriveMaster1to1(masterInput)
            kid = Data()
        case "1to1-dir":
            // WS-6 directional master: senderId binds direction, callId binds
            // per-call freshness. Same seal/round-trip path as plain "1to1"
            // (empty KID — 1:1 calls carry no KID).
            guard let senderId = v["sender_id"] as? String,
                  let callId = v["call_id"] as? String else {
                XCTFail("[\(name)] missing sender_id/call_id for 1to1-dir"); return
            }
            master = try SFrameCodec.deriveMaster1to1Directional(masterInput, senderId: senderId, callId: callId)
            kid = Data()
        case "group":
            guard let groupIdHex = v["group_id_hex"] as? String,
                  let senderId = v["sender_id"] as? String,
                  let kidHex = v["kid_hex"] as? String,
                  let kidBytes = Self.fromHex(kidHex) else {
                XCTFail("[\(name)] missing/invalid group fields"); return
            }
            master = try SFrameCodec.deriveMasterGroup(chainKey: masterInput, groupIdHex: groupIdHex, senderId: senderId)
            kid = kidBytes
        default:
            XCTFail("[\(name)] unknown mode '\(mode)'"); return
        }

        guard let layerStr = v["layer"] as? String, let layer = Self.layerFromString(layerStr) else {
            XCTFail("[\(name)] invalid layer"); return
        }
        guard let ctrNum = v["ctr"] as? NSNumber else { XCTFail("[\(name)] missing ctr"); return }
        let ctr = ctrNum.uint64Value
        guard let padded = v["padded"] as? Bool else { XCTFail("[\(name)] missing padded"); return }
        guard let isKey = v["is_key"] as? Bool else { XCTFail("[\(name)] missing is_key"); return }
        guard let plaintextHex = v["plaintext_hex"] as? String,
              let plaintext = Self.fromHex(plaintextHex) else {
            XCTFail("[\(name)] invalid plaintext_hex"); return
        }
        guard let expectedHex = v["expected_wire_hex"] as? String else {
            XCTFail("[\(name)] missing expected_wire_hex"); return
        }
        let expected = expectedHex.lowercased()

        let wire = try SFrameCodec.seal(
            master: master,
            ctr: ctr,
            plaintext: plaintext,
            kid: kid,
            layer: layer,
            padded: padded,
            keyFrame: isKey
        )
        let actual = Self.toHex(wire)

        if actual != expected {
            // Surface the first divergent byte to make cross-platform debugging easy.
            let prefix = Self.commonPrefixLength(actual, expected)
            XCTFail(
                """
                KAT '\(name)' mismatch — Swift output diverges from JSON contract.
                  expected_wire_hex (first 64): \(String(expected.prefix(64)))
                  actual                       : \(String(actual.prefix(64)))
                  diverges at hex char index   : \(prefix) (byte index \(prefix / 2))
                """
            )
        }

        // Bonus: round-trip the produced wire and confirm the plaintext recovers.
        let roundTripped = try SFrameCodec.open(master: master, wire: wire)
        XCTAssertEqual(roundTripped, plaintext, "[\(name)] round-trip plaintext mismatch")
    }

    // MARK: - Helpers

    private static func layerFromString(_ s: String) -> SFrameCodec.Layer? {
        switch s {
        case "L": return .L
        case "M": return .M
        case "H": return .H
        default: return nil
        }
    }

    private static func fromHex(_ hex: String) -> Data? {
        let h = hex.replacingOccurrences(of: " ", with: "").lowercased()
        guard h.count % 2 == 0 else { return nil }
        var out = Data(capacity: h.count / 2)
        var idx = h.startIndex
        while idx < h.endIndex {
            let next = h.index(idx, offsetBy: 2)
            guard let b = UInt8(h[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }

    private static func toHex(_ data: Data) -> String {
        var s = ""
        s.reserveCapacity(data.count * 2)
        for b in data {
            s += String(format: "%02x", b)
        }
        return s
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = min(aChars.count, bChars.count)
        var i = 0
        while i < n && aChars[i] == bChars[i] { i += 1 }
        return i
    }
}
