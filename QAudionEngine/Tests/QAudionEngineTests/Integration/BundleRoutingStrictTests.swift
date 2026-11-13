import XCTest
@testable import QAudionEngine

/// The grammar of a handshake bundle (RFC 8259) and the routing of an inbound opaque string (WIRE_SPEC 3.1): the first byte
/// after the separator decides, the strict grammar judges the rest. The vectors are the `chainBaseDecisions` of the shared KAT
/// file, run through the pure grammar check (the call-level outcome of each one is a later change).
final class BundleRoutingStrictTests: XCTestCase {

    // MARK: - KAT loading

    private func katVectors() throws -> [(name: String, json: String)] {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "kat"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "Resources/kat")
        ]
        let url = try XCTUnwrap(candidates.compactMap { $0 }.first)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        let chain = try XCTUnwrap(root["rekeyChain"] as? [String: Any])
        let section = try XCTUnwrap(chain["chainBaseDecisions"] as? [String: Any])
        let list = try XCTUnwrap(section["vectors"] as? [[String: Any]])
        return try list.map { entry in
            (name: try XCTUnwrap(entry["name"] as? String), json: try XCTUnwrap(entry["offerJson"] as? String))
        }
    }

    private func isValid(_ text: String) -> Bool {
        if case .valid = StrictBundleJSON.validate(text) { return true }
        return false
    }

    private func bundleJson(round: String, extra: String = "") -> String {
        "{\"kind\":\"OFFER\",\"callId\":\"abc-123\",\"pqcPublicKey\":\"AA==\",\"x25519PublicKey\":\"AA==\",\"rekeyRound\":\(round)\(extra)}"
    }

    // MARK: - V1: the shared vectors

    func testTheSharedVectorsAreValidOrInvalidAsTheGrammarSays() throws {
        let vectors = try katVectors()
        XCTAssertEqual(vectors.count, 32)
        let invalid = Set(vectors.filter { !isValid($0.json) }.map { $0.name })
        XCTAssertEqual(invalid, [
            "malformed-plus-one", "malformed-leading-zero", "malformed-nbsp-before-value",
            "malformed-u2028-after-value", "malformed-trailing-garbage-after-object"
        ])
    }

    func testTheSharedVectorsKeepEveryTopLevelMemberInOrder() throws {
        let vectors = try katVectors()
        let dup = try XCTUnwrap(vectors.first { $0.name == "duplicate-member-same-value" })
        guard case .valid(let members) = StrictBundleJSON.validate(dup.json) else { return XCTFail("valid") }
        XCTAssertEqual(members.map { $0.name }, ["callId", "kind", "rekeyRound", "chainBase", "chainBase"])
        let escaped = try XCTUnwrap(vectors.first { $0.name == "duplicate-member-by-escape" })
        guard case .valid(let escMembers) = StrictBundleJSON.validate(escaped.json) else { return XCTFail("valid") }
        XCTAssertEqual(escMembers.filter { $0.name == "chainBase" }.count, 2, "an escaped name equals the plain one")
        let spaced = try XCTUnwrap(vectors.first { $0.name == "accept-json-whitespace-around-token" })
        guard case .valid(let spacedMembers) = StrictBundleJSON.validate(spaced.json) else { return XCTFail("valid") }
        let token = try XCTUnwrap(spacedMembers.first { $0.name == "chainBase" })
        XCTAssertEqual(String(decoding: token.valueBytes, as: UTF8.self), "0", "no whitespace inside the token bytes")
    }

    // MARK: - V2: grammar table

    func testGrammarTable() {
        let valid = [
            "{}", " \t\r\n{ }\n", "{\"a\":1}", "{\"a\":-0}", "{\"a\":0.5e+3}", "{\"a\":[1,2,{\"b\":null}]}",
            "{\"a\":true,\"b\":false,\"c\":null}", "{\"a\":\"\\u00e9\\n\\/\\\"\"}", "{\"a\":\"\u{0301}\"}",
            "{\"a\":\"\\ud800\"}", "{ \"a\" : 1 , \"b\" : 2 }"
        ]
        for text in valid { XCTAssertTrue(isValid(text), text) }
        let invalid = [
            "", "[]", "1", "{", "{\"a\":1", "{\"a\":1,}", "{,}", "{\"a\":}", "{\"a\" 1}", "{a:1}",
            "{\"a\":+1}", "{\"a\":01}", "{\"a\":1.}", "{\"a\":.5}", "{\"a\":1e}", "{\"a\":-}", "{\"a\":--1}",
            "{\"a\":tru}", "{\"a\":nul}", "{\"a\":\"x}", "{\"a\":\"\\x\"}", "{\"a\":\"\\u12G4\"}", "{\"a\":\"\\u12\"}",
            "{\"a\":\"line\nbreak\"}", "{\"a\":\"tab\there\"}", "{\"a\":1}x", "{\"a\":1}{}", "{\"a\":1}\u{00A0}",
            "\u{FEFF}{}", "\u{00A0}{}", "{\"a\":1}\u{2028}", "{\u{00A0}\"a\":1}", "{\"a\":[1,]}", "{\"a\":[}",
            "{\"a\":1,\"b\"}", "{\"a\":'x'}"
        ]
        for text in invalid { XCTAssertFalse(isValid(text), text) }
    }

    func testNestingCapAndNoStackOverflow() {
        func nested(_ depth: Int) -> String {
            // depth counts the root object: `{"a":[[...]]}` has the root plus `depth - 1` arrays.
            "{\"a\":" + String(repeating: "[", count: depth - 1) + String(repeating: "]", count: depth - 1) + "}"
        }
        XCTAssertTrue(isValid(nested(64)))
        XCTAssertFalse(isValid(nested(65)))
        let huge = "{\"a\":" + String(repeating: "[", count: 200_000)
        XCTAssertFalse(isValid(huge))
    }

    func testALoneSurrogateEscapeIsGrammarValidAndMarksTheName() {
        guard case .valid(let members) = StrictBundleJSON.validate("{\"\\ud800\":1,\"b\":2}") else { return XCTFail("valid") }
        XCTAssertTrue(members[0].badName)
        XCTAssertFalse(members[1].badName)
        guard case .valid(let pairs) = StrictBundleJSON.validate("{\"\\ud83d\\ude00\":1}") else { return XCTFail("valid") }
        XCTAssertFalse(pairs[0].badName)
        guard case .valid(let escaped) = StrictBundleJSON.validate("{\"chain\\u0042ase\":1}") else { return XCTFail("valid") }
        XCTAssertEqual(escaped[0].name, "chainBase")
    }

    // MARK: - V3: routing truth table

    func testRoutingTruthTable() {
        let ok = bundleJson(round: "1")
        func isBundle(_ raw: String) -> Bool { if case .bundle = AndroidHandshakeEnvelope.route(raw) { return true }; return false }
        func isNotRouted(_ raw: String) -> Bool { if case .notRouted = AndroidHandshakeEnvelope.route(raw) { return true }; return false }
        func isMalformed(_ raw: String) -> Bool { if case .malformed = AndroidHandshakeEnvelope.route(raw) { return true }; return false }
        XCTAssertTrue(isBundle("abc-123|" + ok))
        // `{` followed by a combining mark is still routed (a byte test, never a Character test).
        XCTAssertTrue(isMalformed("abc-123|{\u{0301}\"kind\":\"OFFER\"}"))
        // Nothing before the brace is trimmed away: a BOM, a no-break space or a space means the string is not routed.
        XCTAssertTrue(isNotRouted("abc-123|\u{FEFF}" + ok))
        XCTAssertTrue(isNotRouted("abc-123|\u{00A0}" + ok))
        XCTAssertTrue(isNotRouted("abc-123| " + ok))
        XCTAssertTrue(isNotRouted("abc-123|[" + ok + "]"))
        // Spaces inside the object are plain grammar.
        let spaced = "abc-123|{\"kind\" : \"OFFER\", \"callId\" : \"abc-123\", \"pqcPublicKey\" : \"AA==\", \"x25519PublicKey\" : \"AA==\" }"
        XCTAssertTrue(isBundle(spaced))
        // No separator, an empty id.
        XCTAssertTrue(isNotRouted("no-separator"))
        XCTAssertTrue(isNotRouted("|" + ok))
        XCTAssertTrue(isNotRouted(""))
        // The first `|` is the separator even when a combining mark follows the second one.
        XCTAssertTrue(isNotRouted("id|\u{0301}|{\"kind\":\"OFFER\"}"))
        // A separator directly followed by a combining mark: the payload starts with that mark, so it is not routed.
        XCTAssertTrue(isNotRouted("id|\u{0301}{\"kind\":\"OFFER\"}"))
        // Text after the object.
        XCTAssertTrue(isMalformed("abc-123|" + ok + "x"))
        XCTAssertTrue(isMalformed("abc-123|" + ok + "\u{2028}"))
        // The call id is returned as sent.
        if case .malformed(let id, _) = AndroidHandshakeEnvelope.route("AbC-123|{") { XCTAssertEqual(id, "AbC-123") } else { XCTFail("malformed") }
    }

    func testTheGrammarIsCheckedBeforeAnyKnowledgeOfTheKeys() {
        // A leading zero in a member the typed decoder never reads is still malformed.
        let wire = "abc-123|" + bundleJson(round: "1", extra: ",\"chainBase\":01")
        XCTAssertNil(AndroidHandshakeEnvelope.parse(wire))
        XCTAssertEqual(AndroidHandshakeEnvelope.malformedBundleCallId(wire), "abc-123")
        // Duplicate top-level members are never an error by themselves.
        let dup = "abc-123|" + bundleJson(round: "1", extra: ",\"chainBase\":0,\"chainBase\":0")
        XCTAssertNotNil(AndroidHandshakeEnvelope.parse(dup))
        XCTAssertNil(AndroidHandshakeEnvelope.malformedBundleCallId(dup))
    }

    // MARK: - V4: outcomes

    func testRoutedPayloadsThatAreNotBundlesEndTheCallEvenWhenTheyNameAnotherKind() {
        for text in ["{\"kind\":\"SOMETHING\"}", "{\"qa_grpcall_ctrl\":1,\"kind\":\"OFFER\"}", "{\"qa_kms\":1,\"env_b64\":\"AA==\"}", "{}"] {
            XCTAssertEqual(AndroidHandshakeEnvelope.malformedBundleCallId("abc-123|" + text), "abc-123", text)
        }
    }

    func testStringsWithNoPrefixAreNeverRouted() {
        // The group control envelopes travel as a whole JSON string with no `<callId>|` prefix.
        for text in ["{\"qa_grpcall_ctrl\":1,\"kind\":\"OFFER\"}", "{\"qa_kms\":1,\"env_b64\":\"AA==\"}"] {
            XCTAssertNil(AndroidHandshakeEnvelope.malformedBundleCallId(text), text)
            XCTAssertNil(AndroidHandshakeEnvelope.parse(text), text)
        }
    }

    // MARK: - V5: the round range

    func testRekeyRoundRange() {
        func outcome(_ round: String, kind: String = "OFFER") -> String {
            let body: String
            if kind == "OFFER" {
                body = bundleJson(round: round)
            } else {
                body = "{\"kind\":\"ACCEPT\",\"callId\":\"abc-123\",\"ciphertext\":{\"pqc\":\"AA==\",\"x25519\":\"AA==\"},\"rekeyRound\":\(round)}"
            }
            switch AndroidHandshakeEnvelope.route("abc-123|" + body) {
            case .bundle: return "bundle"
            case .malformed(_, let code): return code
            case .notRouted: return "notRouted"
            }
        }
        for kind in ["OFFER", "ACCEPT"] {
            XCTAssertEqual(outcome("1", kind: kind), "bundle")
            XCTAssertEqual(outcome("2147483647", kind: kind), "bundle")
            XCTAssertEqual(outcome("2147483648", kind: kind), "round_range")
            XCTAssertEqual(outcome("4294967295", kind: kind), "round_range")
            XCTAssertEqual(outcome("-1", kind: kind), "round_range")
        }
        // Round 0 and a missing round keep their existing path: the transcript refuses them later.
        XCTAssertEqual(outcome("0"), "bundle")
        let missing = "abc-123|{\"kind\":\"OFFER\",\"callId\":\"abc-123\",\"pqcPublicKey\":\"AA==\",\"x25519PublicKey\":\"AA==\"}"
        if case .bundle = AndroidHandshakeEnvelope.route(missing) {} else { XCTFail("a missing round is not a routing failure") }
    }

    func testTheSharedRoundVectorEndsTheCallThroughTheRoute() throws {
        let vector = try XCTUnwrap(try katVectors().first { $0.name == "rekeyRound-2-pow-31-malformed" })
        XCTAssertTrue(isValid(vector.json), "the grammar accepts it: the failure is the range")
        let wire = "abc-123|" + bundleJson(round: "2147483648", extra: ",\"chainBase\":0")
        XCTAssertEqual(AndroidHandshakeEnvelope.malformedBundleCallId(wire), "abc-123")
    }

    func testTheSharedGrammarVectorsEndTheCallThroughTheRoute() throws {
        // The vectors carry no keys, so each token is placed into a full bundle: the call ends exactly for the five grammar ones.
        let tokens: [(String, String)] = [
            ("malformed-plus-one", "+1"), ("malformed-leading-zero", "01"), ("malformed-nbsp-before-value", "\u{00A0}0"),
            ("malformed-u2028-after-value", "0\u{2028}")
        ]
        for (name, token) in tokens {
            let wire = "abc-123|" + bundleJson(round: "4", extra: ",\"chainBase\":\(token)")
            XCTAssertEqual(AndroidHandshakeEnvelope.malformedBundleCallId(wire), "abc-123", name)
        }
        let trailing = "abc-123|" + bundleJson(round: "4", extra: ",\"chainBase\":0") + "xyz"
        XCTAssertEqual(AndroidHandshakeEnvelope.malformedBundleCallId(trailing), "abc-123")
        let okToken = "abc-123|" + bundleJson(round: "4", extra: ",\"chainBase\": \t\r\n0 \t")
        XCTAssertNotNil(AndroidHandshakeEnvelope.parse(okToken))
        // A malformed token also ends the call in a ROUND-1 OFFER (the strict check runs first).
        let roundOne = "abc-123|" + bundleJson(round: "1", extra: ",\"chainBase\":+1")
        XCTAssertEqual(AndroidHandshakeEnvelope.malformedBundleCallId(roundOne), "abc-123")
    }

    // MARK: - V8: the piggy-back parser and the bundle routing agree

    func testPiggyBackAndBundleRoutingNeverClaimTheSameString() {
        let strings = [
            "abc-123|" + bundleJson(round: "1"), "abc-123|{\u{0301}", "abc-123|\u{FEFF}{}", "abc-123| {}",
            "abc-123|HANGUP:x", "abc-123|SCREEN_SHARE:start", "id|\u{0301}|{\"kind\":\"OFFER\"}", "abc-123|{", "no-separator"
        ]
        for raw in strings {
            var bundleClaims = false
            switch AndroidHandshakeEnvelope.route(raw) {
            case .notRouted: bundleClaims = false
            default: bundleClaims = true
            }
            let piggyClaims = CallPiggyBack.parse(raw) != nil
            XCTAssertFalse(bundleClaims && piggyClaims, raw)
        }
        // A string routed as a bundle is never a piggy-back, even when it ends like one.
        XCTAssertNil(CallPiggyBack.parse("abc-123|{\"x\":\"SCREEN_SHARE:start\"}"))
        XCTAssertNotNil(CallPiggyBack.parse("abc-123|SCREEN_SHARE:start"))
    }
}
