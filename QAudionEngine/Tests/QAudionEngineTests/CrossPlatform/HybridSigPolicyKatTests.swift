import XCTest
import CryptoKit
@testable import QAudionEngine

/// The sections `pinPolicy` and `bundle-max` of the shared known-answer file (a byte-for-byte copy, its SHA-256 is pinned in
/// `PqcHardeningV1KatTests`): every decision vector of the pin policy is run against `HybridSigPolicy`, and the maximal bundle is
/// measured with this app's own serializer.
///
/// This code was written on a machine that cannot compile Swift for iOS: the macOS CI job is what runs it.
final class HybridSigPolicyKatTests: XCTestCase {

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

    private func object(_ any: Any?) throws -> [String: Any] {
        try XCTUnwrap(any as? [String: Any])
    }

    private func list(_ any: Any?) throws -> [[String: Any]] {
        try XCTUnwrap(any as? [[String: Any]])
    }

    private func string(_ dict: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(dict[key] as? String, key)
    }

    private func flag(_ dict: [String: Any], _ key: String) throws -> Bool {
        try XCTUnwrap(dict[key] as? Bool, key)
    }

    /// A record of the vectors: null is no record; the key id and the state may be null inside one.
    private func record(_ any: Any?) -> CapsPinRecord? {
        guard let d = any as? [String: Any] else { return nil }
        return CapsPinRecord(caps: (d["caps"] as? [String]) ?? [], mldsaKeyId: d["mldsaKeyId"] as? String,
                             pqState: d["pqState"] as? String)
    }

    private func result(_ text: String, _ name: String) throws -> PqSigResult {
        try XCTUnwrap(PqSigResult(rawValue: text), name)
    }

    // MARK: - pinPolicy

    func testPinPolicyVectorsAreAllRunByteExact() throws {
        let policy = try object(try load()["pinPolicy"])
        let vectors = try list(policy["vectors"])
        XCTAssertEqual(vectors.count, 135)
        var round1 = 0
        var rekey = 0
        for vector in vectors {
            let name = try string(vector, "name")
            let input = try object(vector["input"])
            let expect = try object(vector["expect"])
            switch try string(vector, "kind") {
            case "round1":
                round1 += 1
                try runRound1(name: name, input: input, expect: expect)
            case "rekey":
                rekey += 1
                try runRekey(name: name, input: input, expect: expect)
            default:
                XCTFail("unknown vector kind in \(name)")
            }
        }
        XCTAssertEqual(round1, 108)
        XCTAssertEqual(rekey, 27)
    }

    private func runRound1(name: String, input: [String: Any], expect: [String: Any]) throws {
        let bundle = try object(input["bundle"])
        let policyInput = HybridSigPolicy.Round1Input(
            record: record(input["record"]),
            capsBindV1: try flag(bundle, "capsBindV1"),
            sigHybridV1: try flag(bundle, "sigHybridV1"),
            withdrawn: (bundle["withdrawn"] as? [String]) ?? [],
            ext: try flag(input, "ext"),
            sigHybrid: try result(try string(input, "sigHybrid"), name),
            sigKeyId: input["sigKeyId"] as? String,
            kcmacValid: try string(input, "kcmac") == "valid",
            armed: try flag(input, "armed"),
            sasConfirmed: try string(input, "sas") == "confirmed")
        let got = HybridSigPolicy.decideRound1(policyInput)
        XCTAssertEqual(got.action.rawValue, try string(expect, "action"), name)
        XCTAssertEqual(got.auth, try string(expect, "auth"), name)
        XCTAssertEqual(got.pin, try string(expect, "pin"), name)
        XCTAssertEqual(got.withdraw, try string(expect, "withdraw"), name)
        XCTAssertEqual(got.pqSig, try string(expect, "pqSig"), name)
        XCTAssertEqual(got.pqSig2, try string(expect, "pqSig2"), name)
        XCTAssertEqual(got.warn.map { $0.rawValue }, (expect["warn"] as? [String]) ?? [], name)
        XCTAssertEqual(got.hold, try flag(expect, "hold"), name)
        XCTAssertFalse(got.hold, "nothing is ever held: \(name)")
        XCTAssertEqual(got.record, record(expect["record"]), name)
        // the record invariants the vectors assert on every record
        if let stored = got.record {
            XCTAssertEqual(stored.caps.contains("sigHybridV1"), stored.pqState == "pinned", "sigHybridV1 iff pinned: \(name)")
            XCTAssertEqual(stored.caps, stored.caps.sorted(), "caps sorted: \(name)")
            XCTAssertFalse(stored.caps.isEmpty && stored.mldsaKeyId == nil && stored.pqState == nil, "empty record is null: \(name)")
        }
        // the armed flag changes nothing: the same input with the opposite value gives the same answer
        var flipped = policyInput
        flipped.armed.toggle()
        XCTAssertEqual(HybridSigPolicy.decideRound1(flipped), got, "armed is ignored: \(name)")
    }

    private func runRekey(name: String, input: [String: Any], expect: [String: Any]) throws {
        let role = try string(input, "role")
        XCTAssertTrue(role == "offerer" || role == "acceptor", name)
        let policyInput = HybridSigPolicy.RekeyInput(
            auth1: try string(input, "auth1"), anchorKeyId: input["anchorKeyId"] as? String, isOfferer: role == "offerer",
            round: try XCTUnwrap(input["round"] as? Int, name), sigHybrid: try result(try string(input, "sigHybrid"), name),
            sigKeyId: input["sigKeyId"] as? String, armed: try flag(input, "armed"))
        let got = HybridSigPolicy.decideRekey(policyInput)
        XCTAssertEqual(got.action.rawValue, try string(expect, "action"), name)
        XCTAssertEqual(got.auth, try string(expect, "auth"), name)
        XCTAssertEqual(got.warn, try flag(expect, "warn"), name)
        XCTAssertEqual(got.effect, try string(expect, "effect"), name)
        XCTAssertEqual(got.sendStaysOnCurrentRound, try flag(expect, "sendStaysOnCurrentRound"), name)
        XCTAssertEqual(got.eraseSlot, try flag(expect, "eraseSlot"), name)
        XCTAssertEqual(got.log, try string(expect, "log"), name)
        XCTAssertFalse(got.hold, name)
        // a rekey round never reads or changes the pin record
        XCTAssertEqual(record(expect["record"]), record(input["record"]), name)
    }

    // MARK: - bundle-max

    /// The maximal OFFER and ACCEPT of the file, measured as this app writes them: its bundle encoder escapes every slash of the
    /// text it produces, and the socket serializer escapes the quotes, the backslashes and the slashes of the string that carries it.
    /// The frame of the file lacks the envelope `id` member this app writes, which is 44 bytes.
    func testTheMaximalBundleFitsTheFrameRuleWithThisAppsOwnEscaping() throws {
        let vectors = try list(try object(try load()["bundle-max"])["vectors"])
        XCTAssertEqual(vectors.count, 1)
        let idMember = ",\"id\":\"\(OpaqueFrameRule.placeholderId)\"".utf8.count
        XCTAssertEqual(idMember, 44)
        for vector in vectors {
            for kind in ["offer", "accept"] {
                let entry = try object(vector[kind])
                let framed = try string(entry, "framed")
                XCTAssertEqual(Data(SHA256.hash(data: Data(framed.utf8))).map { String(format: "%02x", $0) }.joined(),
                               try string(entry, "sha256"), "\(kind): the file's text is the text hashed")
                XCTAssertEqual(framed.utf8.count, try XCTUnwrap(entry["dataBytes"] as? Int), kind)
                // what the bundle encoder writes: every slash of the JSON text escaped
                let pipe = try XCTUnwrap(framed.firstIndex(of: "|"))
                let escaped = String(framed[..<pipe]) + "|" + String(framed[framed.index(after: pipe)...]).replacingOccurrences(of: "/", with: "\\/")
                let client = try object(entry["client"])
                let worstCase = try XCTUnwrap(client["frameBytesWorstCase"] as? Int, kind)
                let measured = OpaqueFrameRule.frameBytes(payload: escaped)
                XCTAssertEqual(measured, worstCase + idMember, "\(kind): the app's frame is the file's worst case plus the id member")
                XCTAssertTrue(OpaqueFrameRule.fits(payload: escaped), kind)
                XCTAssertLessThanOrEqual(measured + OpaqueFrameRule.serverMarginBytes, OpaqueFrameRule.maxFrameBytes, kind)
                XCTAssertEqual(try XCTUnwrap(entry["limit"] as? Int), OpaqueFrameRule.maxFrameBytes, kind)
            }
        }
    }

    /// The frame a text carries is longer than the text: quotes and slashes grow, and the rule is on the frame.
    func testTheRuleIsMeasuredOnTheFrameAndNotOnTheText() {
        let plain = String(repeating: "a", count: 1000)
        let quoted = String(repeating: "\"", count: 1000)
        let slashed = String(repeating: "/", count: 1000)
        let base = OpaqueFrameRule.frameBytes(payload: plain)
        XCTAssertEqual(OpaqueFrameRule.frameBytes(payload: quoted), base + 1000)
        XCTAssertEqual(OpaqueFrameRule.frameBytes(payload: slashed), base + 1000)
        // the limit: frame + 128 <= 24576, at the byte
        let room = OpaqueFrameRule.maxFrameBytes - OpaqueFrameRule.serverMarginBytes - OpaqueFrameRule.frameBytes(payload: "")
        XCTAssertTrue(OpaqueFrameRule.fits(payload: String(repeating: "a", count: room)))
        XCTAssertFalse(OpaqueFrameRule.fits(payload: String(repeating: "a", count: room + 1)))
    }
}
