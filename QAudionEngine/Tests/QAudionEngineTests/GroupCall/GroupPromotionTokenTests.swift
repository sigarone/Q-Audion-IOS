import CryptoKit
import XCTest
@testable import QAudionEngine

/// The signed promotion token of a 1:1 call that is promoted to a group call (GROUP_CALLS_V2 2.7, Promotion token),
/// against `promotion-token-kat.json`: the byte layout, the builder's refusals, the receiver steps R1 to
/// R14, freshness and replay, the auto-join decision table and the roster rule.
///
/// The JSON is a BYTE-FOR-BYTE copy of the file the server repository holds
/// (test/kat/group_promotion_token_v1/promotion-token-kat.json, generated there with
/// the Go standard library only, so its Ed25519 signatures are deterministic RFC 8032). The tests pin its
/// SHA-256 and its length, so a changed file is a failing test until it is copied again, never edited.
/// CryptoKit signs with hedging, so the signatures this port makes are verified, not compared byte for
/// byte; the KAT's own signatures are verified too. The file is a test resource and a missing file FAILS.
final class GroupPromotionTokenTests: XCTestCase {

    // MARK: - Loading

    private struct KatProblem: Error, CustomStringConvertible {
        let what: String
        var description: String { what }
    }

    /// SHA-256 and size of `promotion-token-kat.json`, as pinned with the server.
    private static let katSha256Hex = "935a814dc81d2494ca6b1c1506bdfbb027ae0ee281d3bc345e339bdcfc7dd81f"
    private static let katLength = 166_405

    private func loadKat(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: "promotion-token-kat", withExtension: "json") else {
            XCTFail("promotion-token-kat.json is not in the test bundle: the promotion token vectors cannot run",
                    file: file, line: line)
            throw KatProblem(what: "KAT file not found in the test bundle")
        }
        let raw = try Data(contentsOf: url)
        XCTAssertEqual(raw.count, Self.katLength, "the KAT is the pinned file", file: file, line: line)
        XCTAssertEqual(sha256Hex(raw), Self.katSha256Hex, "the KAT is the pinned file", file: file, line: line)
        XCTAssertFalse(raw.contains(0x0D), "line endings were rewritten in the KAT", file: file, line: line)
        guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw KatProblem(what: "the KAT is not an object")
        }
        XCTAssertEqual(root["format"] as? String, "qaudion-group-promotion-token-kat", file: file, line: line)
        XCTAssertEqual((root["version"] as? NSNumber)?.intValue, 1, file: file, line: line)
        return root
    }

    private func object(_ value: Any?, _ what: String) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw KatProblem(what: "not an object: \(what)") }
        return result
    }

    private func objects(_ value: Any?, _ what: String) throws -> [[String: Any]] {
        guard let result = value as? [[String: Any]] else { throw KatProblem(what: "not a list of objects: \(what)") }
        return result
    }

    private func text(_ container: [String: Any], _ key: String) throws -> String {
        guard let result = container[key] as? String else { throw KatProblem(what: "missing text: \(key)") }
        return result
    }

    private func number(_ container: [String: Any], _ key: String) throws -> Int {
        guard let result = (container[key] as? NSNumber)?.intValue else { throw KatProblem(what: "missing number: \(key)") }
        return result
    }

    private func flag(_ container: [String: Any], _ key: String, default fallback: Bool) -> Bool {
        guard let number = container[key] as? NSNumber else { return fallback }
        return number.boolValue
    }

    private func texts(_ container: [String: Any], _ key: String) throws -> [String] {
        guard let result = container[key] as? [String] else { throw KatProblem(what: "missing list of texts: \(key)") }
        return result
    }

    private func hex(_ value: String) -> Data {
        let characters = Array(value.utf8)
        var out = Data()
        var index = 0
        while index + 1 < characters.count {
            let pair = String(decoding: characters[index..<(index + 2)], as: UTF8.self)
            out.append(UInt8(pair, radix: 16) ?? 0)
            index += 2
        }
        return out
    }

    private func toHex(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Hex(_ data: Data) -> String {
        return toHex(Data(SHA256.hash(data: data)))
    }

    // MARK: - The fixed inputs

    private struct Fixed {
        let creatorKey: Curve25519.Signing.PrivateKey
        let creatorPublic: Data
        let creator: String
        let peer: String
        let extra: String
        let stranger: String
        let group: String
        let live: String
        let binding: Data
        let issuedAtMs: Int
        let nowMs: Int
        let otherPublic: Data

        func sign(_ data: Data) -> Data? { try? creatorKey.signature(for: data) }
    }

    private func loadFixed(_ kat: [String: Any]) throws -> Fixed {
        let fixed = try object(kat["fixed_inputs"], "fixed_inputs")
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: hex(try text(fixed, "creator_seed_hex")))
        let publicKey = hex(try text(fixed, "creator_public_key_hex"))
        XCTAssertEqual(key.publicKey.rawRepresentation, publicKey, "the seed of the KAT gives the key of the KAT")
        return Fixed(
            creatorKey: key, creatorPublic: publicKey, creator: try text(fixed, "creator_user_id_C"),
            peer: try text(fixed, "peer_user_id_P"), extra: try text(fixed, "extra_invitee_X"),
            stranger: try text(fixed, "stranger_Y"), group: try text(fixed, "group_call_id_G"),
            live: try text(fixed, "live_call_id_L"), binding: hex(try text(fixed, "accept_binding1_hex")),
            issuedAtMs: try number(fixed, "issued_at_ms"), nowMs: try number(fixed, "verifier_now_ms"),
            otherPublic: hex(try text(fixed, "attacker_public_key_hex")))
    }

    /// The verifier state of one vector: the live 1:1 call, or none, with the anchor the vector describes.
    private func makeContext(_ state: [String: Any], _ f: Fixed) throws -> PromotionCallContext? {
        guard flag(state, "live_call", default: true) else { return nil }
        let anchor = try object(state["anchor"], "anchor")
        var context = PromotionCallContext(callId: try text(state, "live_call_id"), peerUserId: try text(state, "peer_user_id"))
        context.anchor.noteRoundOne(
            sigOk: flag(anchor, "defined", default: true), signerKey: hex(try text(anchor, "signer_key_hex")),
            acceptBinding: hex(try text(anchor, "accept_binding1_hex")), ownSignerKey: f.otherPublic, bound: true)
        if flag(anchor, "poisoned", default: false) { context.anchor.noteLaterRound(sigOk: false, signerKey: nil) }
        if flag(anchor, "kcmac_verified", default: true) { context.anchor.noteKcMacVerified(round: 1) }
        return context
    }

    /// The state of the first vector of `verify`: a live 1:1 call with the creator, an anchor defined with
    /// the creator's key, the peer's round-1 KCMAC verified.
    private func baseContext(_ kat: [String: Any], _ f: Fixed) throws -> PromotionCallContext {
        let first = try XCTUnwrap(try objects(kat["verify"], "verify").first)
        return try XCTUnwrap(try makeContext(try object(first["state"], "state"), f))
    }

    private func katRow(_ rows: [[String: Any]], _ number: String) throws -> [String: Any] {
        return try XCTUnwrap(rows.first { ($0["row"] as? String) == number }, "row \(number) of the KAT")
    }

    private func receive(_ data: String, state: [String: Any], context: inout PromotionCallContext?,
                         monoMs: Int64 = 1000) throws -> GroupPromotionReceiver.Outcome {
        return GroupPromotionReceiver.receive(
            data: data, senderId: try text(state, "sender_id"), selfUserId: try text(state, "self_user_id"),
            context: &context, nowWallMs: Int64(try number(state, "now_ms")), nowMonoMs: monoMs)
    }

    // MARK: - Encode and the builder's refusals

    private func build(_ input: [String: Any]) throws -> GroupPromotionToken.Built {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: hex(try text(input, "signer_seed_hex")))
        return try GroupPromotionToken.build(
            groupCallId: try text(input, "group_call_id"), fromCallId: try text(input, "from_call_id"),
            acceptBinding1: hex(try text(input, "accept_binding1_hex")), creatorUserId: try text(input, "creator_user_id"),
            signerKey: hex(try text(input, "signer_ik_hex")), peerUserId: try text(input, "peer_user_id"),
            invitees: try texts(input, "invitees"), issuedAtMs: UInt64(try number(input, "issued_at_ms")),
            lifetimeMs: UInt32(clamping: try number(input, "lifetime_ms")),
            callType: UInt8(clamping: try number(input, "call_type")), sign: { try? key.signature(for: $0) })
    }

    func testEncodeVectorsReproduceEveryByte() throws {
        let kat = try loadKat()
        let vectors = try objects(kat["encode"], "encode")
        XCTAssertEqual(vectors.count, 4)
        for vector in vectors {
            let name = try text(vector, "name")
            let input = try object(vector["input"], "input")
            let expected = try object(vector["expected"], "expected")
            let signerKey = hex(try text(input, "signer_ik_hex"))
            let seedKey = try Curve25519.Signing.PrivateKey(rawRepresentation: hex(try text(input, "signer_seed_hex")))
            XCTAssertEqual(seedKey.publicKey.rawRepresentation, signerKey, "[\(name)] seed and key")

            let built = try build(input)
            XCTAssertEqual(toHex(built.tbs), try text(expected, "tbs_hex"), "[\(name)] PROMO_TBS")
            XCTAssertEqual(sha256Hex(built.tbs), try text(expected, "tbs_sha256_hex"), "[\(name)] SHA-256(TBS)")
            XCTAssertEqual(built.tbs.count, try number(expected, "tbs_len"), "[\(name)] len(TBS)")
            XCTAssertEqual(built.token.count, try number(expected, "token_len"), "[\(name)] len(TOKEN)")
            XCTAssertEqual(built.encoded.count, try number(expected, "b64_len"), "[\(name)] len(B)")
            let wireCallId = try text(input, "wire_call_id")
            XCTAssertEqual(built.wireData(callId: wireCallId).utf8.count, try number(expected, "data_len"), "[\(name)] len(data)")

            // The signature of this port is hedged: it verifies, it is not compared.
            let own = try XCTUnwrap(try? GroupPromotionToken.parse(encoded: built.encoded).get(), "[\(name)] parses back")
            XCTAssertTrue(GroupPromotionToken.verifySignature(own, signerKey: signerKey), "[\(name)] own signature")
            XCTAssertEqual(own.fields.invitees, built.fields.invitees)

            // The deterministic signature of the KAT verifies over the same bytes and gives the KAT's wire.
            let katSignature = hex(try text(expected, "sig_hex"))
            XCTAssertTrue(HandshakeTranscript.verify(transcript: built.tbs, signature: katSignature,
                                                     signerIdentityKey: signerKey), "[\(name)] KAT signature")
            let katToken = built.tbs + katSignature
            XCTAssertEqual(katToken.count, try number(expected, "token_len"), "[\(name)] KAT token length")
            XCTAssertEqual(katToken.base64EncodedString(), try text(expected, "b64"), "[\(name)] base64")
            XCTAssertEqual(GroupPromotionToken.wireData(callId: wireCallId, encoded: try text(expected, "b64")),
                           try text(expected, "data"), "[\(name)] wire")
            // ... and the KAT's own token is accepted by the parser and verifies under the key it names.
            let katParsed = try XCTUnwrap(try? GroupPromotionToken.parse(encoded: try text(expected, "b64")).get(),
                                          "[\(name)] the KAT token parses")
            XCTAssertTrue(GroupPromotionToken.verifySignature(katParsed, signerKey: signerKey), "[\(name)] KAT token verifies")
            XCTAssertEqual(katParsed.fields.invitees, built.fields.invitees, "[\(name)] invitees, sorted")
        }
    }

    func testTheBuilderRefusesEveryInputOfTheRejectList() throws {
        let kat = try loadKat()
        let vectors = try objects(kat["encode_reject"], "encode_reject")
        XCTAssertEqual(vectors.count, 15)
        let byReason: [String: GroupPromotionToken.BuildError] = [
            "no_invitees": .invalidInvitees, "too_many_invitees": .invalidInvitees, "creator_invited": .invalidInvitees,
            "duplicate_invitee": .invalidInvitees, "peer_missing": .invalidInvitees, "bad_id": .invalidId,
            "bad_lifetime": .invalidLifetime, "bad_call_type": .invalidCallType,
            "bad_binding_len": .invalidBinding, "bad_signer_len": .invalidSignerKey,
        ]
        for vector in vectors {
            let name = try text(vector, "name")
            XCTAssertEqual(try text(vector, "expect"), "refuse", "[\(name)]")
            let reason = try text(vector, "reason")
            let expectedError = try XCTUnwrap(byReason[reason], "[\(name)] unknown reason \(reason)")
            XCTAssertThrowsError(try build(try object(vector["input"], "input")), "[\(name)] must not build") { error in
                XCTAssertEqual(error as? GroupPromotionToken.BuildError, expectedError, "[\(name)] \(reason)")
            }
        }
    }

    func testABuilderThatCannotSignBuildsNothing() throws {
        let kat = try loadKat()
        let f = try loadFixed(kat)
        let input = try object(try XCTUnwrap(try objects(kat["encode"], "encode").first)["input"], "input")
        XCTAssertThrowsError(try GroupPromotionToken.build(
            groupCallId: try text(input, "group_call_id"), fromCallId: try text(input, "from_call_id"),
            acceptBinding1: f.binding, creatorUserId: try text(input, "creator_user_id"), signerKey: f.creatorPublic,
            peerUserId: try text(input, "peer_user_id"), invitees: try texts(input, "invitees"),
            issuedAtMs: UInt64(f.issuedAtMs), sign: { _ in nil })) { error in
            XCTAssertEqual(error as? GroupPromotionToken.BuildError, .signFailed)
        }
        XCTAssertThrowsError(try GroupPromotionToken.build(
            groupCallId: try text(input, "group_call_id"), fromCallId: try text(input, "from_call_id"),
            acceptBinding1: f.binding, creatorUserId: try text(input, "creator_user_id"), signerKey: f.creatorPublic,
            peerUserId: try text(input, "peer_user_id"), invitees: try texts(input, "invitees"),
            issuedAtMs: UInt64(f.issuedAtMs), sign: { _ in Data(count: 63) })) { error in
            XCTAssertEqual(error as? GroupPromotionToken.BuildError, .signFailed, "a short signature is no signature")
        }
    }

    // MARK: - Receipt

    private func receiptName(_ outcome: GroupPromotionReceiver.Outcome) -> String {
        switch outcome {
        case .stored, .storedEvicting: return "ok"
        case .identicalCopy: return "unchanged"
        case .dropped(let drop): return drop.name
        }
    }

    func testEveryReceiptVectorGivesTheExpectedCode() throws {
        let kat = try loadKat()
        let f = try loadFixed(kat)
        let vectors = try objects(kat["verify"], "verify")
        XCTAssertEqual(vectors.count, 39)
        var codes = Set<String>()
        for vector in vectors {
            let label = "[\(try text(vector, "row")) \(try text(vector, "name"))]"
            let state = try object(vector["state"], "state")
            var context = try makeContext(state, f)
            let outcome = try receive(try text(vector, "data"), state: state, context: &context)
            XCTAssertEqual(receiptName(outcome), try text(vector, "expect"), label)
            codes.insert(try text(vector, "expect"))
        }
        // Every drop code of the spec is reached by at least one vector, apart from the ones the freshness
        // and replay tables hold.
        let dropCodes = try texts(try object(kat["constants"], "constants"), "DROP_CODES")
        for code in dropCodes where !["future", "stale", "dup_group"].contains(code) {
            XCTAssertTrue(codes.contains(code), "no receipt vector gives \(code)")
        }
    }

    func testAStoredTokenIsKeptForTheLiveCallOnlyAndADropChangesNothing() throws {
        let kat = try loadKat()
        let f = try loadFixed(kat)
        let vectors = try objects(kat["verify"], "verify")
        let good = try katRow(vectors, "1")
        let bad = try katRow(vectors, "28")
        let state = try object(good["state"], "state")
        var context: PromotionCallContext? = try makeContext(state, f)
        let before = context
        _ = try receive(try text(bad, "data"), state: state, context: &context)
        XCTAssertEqual(context, before, "a dropped token leaves no trace")
        _ = try receive(try text(good, "data"), state: state, context: &context)
        XCTAssertEqual(context?.book.entries.count, 1)
        XCTAssertEqual(context?.book.entries.first?.groupCallId, f.group)
        XCTAssertEqual(context?.book.entries.first?.invitees, [f.peer, f.extra])
    }

    func testASiblingDeviceWithoutTheCallCreatesNoState() throws {
        let kat = try loadKat()
        let good = try XCTUnwrap(try objects(kat["verify"], "verify").first)
        var none: PromotionCallContext?
        let outcome = try receive(try text(good, "data"), state: try object(good["state"], "state"), context: &none)
        XCTAssertEqual(outcome, .dropped(.noCall))
        XCTAssertNil(none)
    }

    // MARK: - Freshness and replay

    func testTheWallClockWindowIsInclusiveOnBothSides() throws {
        let kat = try loadKat()
        let f = try loadFixed(kat)
        let rows = try objects(kat["freshness"], "freshness").filter { ($0["kind"] as? String) == "receipt" }
        XCTAssertEqual(rows.count, 4)
        for vector in rows {
            let state = try object(vector["state"], "state")
            XCTAssertEqual(try number(vector, "now_ms"), try number(state, "now_ms"), "the clock of the row")
            var context = try makeContext(state, f)
            let outcome = try receive(try text(vector, "data"), state: state, context: &context)
            let name = try text(vector, "name")
            XCTAssertEqual(receiptName(outcome), try text(vector, "expect"), "[\(name)]")
        }
    }

    func testAHeldTokenIsAlsoLimitedByTheMonotonicClock() throws {
        let kat = try loadKat()
        let f = try loadFixed(kat)
        let rows = try objects(kat["freshness"], "freshness").filter { ($0["kind"] as? String) == "decision" }
        XCTAssertEqual(rows.count, 3)
        for vector in rows {
            var book = PromotionTokenBook()
            book.append(PromotionTokenBook.Entry(
                groupCallId: f.group, creatorUserId: f.creator, invitees: [f.peer, f.extra],
                issuedAtMs: UInt64(try number(vector, "issued_at_ms")), lifetimeMs: UInt32(try number(vector, "lifetime_ms")),
                receiptMonoMs: Int64(try number(vector, "stored_mono_ms")), token: Data()))
            let state = book.state(forGroupCallId: f.group, nowWallMs: Int64(try number(vector, "now_ms")),
                                   nowMonoMs: Int64(try number(vector, "decision_mono_ms")))
            let expected = try text(vector, "expect")
            let name = try text(vector, "name")
            XCTAssertEqual(state == .fresh ? "fresh" : "not_fresh", expected, "[\(name)]")
            if expected == "not_fresh" { XCTAssertEqual(state, .stale, "[\(name)]") }
        }
    }

    func testReplayRules() throws {
        let kat = try loadKat()
        let f = try loadFixed(kat)
        let sequences = try objects(kat["replay"], "replay")
        XCTAssertEqual(sequences.count, 3)
        for sequence in sequences {
            let name = try text(sequence, "name")
            let state = try object(sequence["state"], "state")
            var context = try makeContext(state, f)
            for step in try objects(sequence["steps"], "steps") {
                let outcome = try receive(try text(step, "data"), state: state, context: &context,
                                          monoMs: Int64(try number(step, "mono_ms")))
                let label: String
                switch outcome {
                case .stored: label = "stored"
                case .storedEvicting: label = "evicted"
                case .identicalCopy: label = "unchanged"
                case .dropped(let drop): label = drop.name
                }
                XCTAssertEqual(label, try text(step, "expect"), "[\(name)]")
            }
            let book = try XCTUnwrap(context?.book)
            XCTAssertEqual(book.entries.map { $0.groupCallId }, try texts(sequence, "expect_held"), "[\(name)] held tokens")
            XCTAssertEqual(book.usedGroupIds, Set(try texts(sequence, "expect_used")), "[\(name)] used group ids")
            XCTAssertLessThanOrEqual(book.entries.count, GroupPromotionToken.maxHeld)
        }
    }

    func testATokenIsConsumedOnceAndANewInviteWithTheSameIdRings() throws {
        let kat = try loadKat()
        let f = try loadFixed(kat)
        let good = try XCTUnwrap(try objects(kat["verify"], "verify").first)
        var context: PromotionCallContext? = try baseContext(kat, f)
        _ = try receive(try text(good, "data"), state: try object(good["state"], "state"), context: &context)
        var book = try XCTUnwrap(context?.book)
        XCTAssertEqual(book.state(forGroupCallId: f.group.uppercased(), nowWallMs: Int64(f.nowMs), nowMonoMs: 2000), .fresh)
        XCTAssertNotNil(book.consume(groupCallId: f.group))
        XCTAssertNil(book.consume(groupCallId: f.group), "one use")
        XCTAssertEqual(book.state(forGroupCallId: f.group, nowWallMs: Int64(f.nowMs), nowMonoMs: 2000), .consumed)
        XCTAssertEqual(book.state(forGroupCallId: f.stranger, nowWallMs: Int64(f.nowMs), nowMonoMs: 2000), .absent)
    }

    // MARK: - The auto-join decision

    private func decisionInput(_ step: [String: Any], _ f: Fixed) throws -> GroupPromotionDecision.Input {
        let inputs = try object(step["input"], "input")
        let invite = try object(inputs["invite"], "invite")
        let live = inputs["live_call"] as? [String: Any]
        let anchor = try object(inputs["anchor"], "anchor")
        let inviteCall = (invite["call_id"] as? String) ?? ""
        // The tokens held: one entry per token of the row, in the state the row asks for. A token is stale
        // when it was received long enough ago on the monotonic clock of the decision (1000 ms).
        var book = PromotionTokenBook()
        for token in (inputs["tokens"] as? [[String: Any]]) ?? [] {
            book.append(PromotionTokenBook.Entry(
                groupCallId: GroupCallIds.lower(try text(token, "group_call_id")), creatorUserId: try text(token, "creator_user_id"),
                invitees: [f.peer], issuedAtMs: UInt64(f.issuedAtMs), lifetimeMs: GroupPromotionToken.senderLifetimeMs,
                receiptMonoMs: flag(token, "fresh", default: true) ? 0 : -100_000, token: Data(),
                consumed: flag(token, "consumed", default: false)))
        }
        let freshness = book.state(forGroupCallId: inviteCall, nowWallMs: Int64(f.nowMs), nowMonoMs: 1000)
        return GroupPromotionDecision.Input(
            promoted: GroupCallWire.isJsonTrue(invite["promoted"]),
            promotedFromCallId: (invite["promoted_from_call_id"] as? String) ?? "",
            creatorId: (invite["creator_id"] as? String) ?? "",
            liveCallId: live.flatMap { $0["call_id"] as? String }, livePeerId: live.flatMap { $0["peer_user_id"] as? String },
            anchorDefined: flag(anchor, "defined", default: false), anchorPoisoned: flag(anchor, "poisoned", default: false),
            kcmacVerified: flag(anchor, "kcmac_verified", default: false), token: freshness,
            groupLive: flag(inputs, "group_live", default: false), micGranted: flag(inputs, "mic_granted", default: true),
            msSinceInvite: Int64(try number(inputs, "ms_since_invite")), ringUp: flag(inputs, "ring_up", default: false),
            userActed: flag(inputs, "user_acted", default: false))
    }

    /// The outcome, the `why` and the audio-only flag of a decision, spelled as the KAT spells them.
    private func decisionSpelling(_ outcome: GroupPromotionDecision.Outcome, _ input: GroupPromotionDecision.Input)
        -> (outcome: String, why: String, audioOnly: Bool) {
        switch outcome {
        case .autoJoin: return ("AUTO_JOIN", GroupPromotionDecision.Why.token.name, true)
        case .convert: return ("CONVERT", GroupPromotionDecision.Why.token.name, true)
        case .hold: return ("HOLD", GroupPromotionDecision.waitWhy(input.token).name, false)
        case .ring(let why): return ("RING", why.name, false)
        case .fallback: return ("FALLBACK", GroupPromotionDecision.Why.notCandidate.name, false)
        case .noConversion: return ("NO_CONVERSION", "user_acted", false)
        }
    }

    func testEveryRowOfTheDecisionTable() throws {
        let kat = try loadKat()
        let f = try loadFixed(kat)
        let rows = try objects(kat["predicate"], "predicate")
        XCTAssertEqual(rows.count, 27)
        var spellings = Set<String>()
        for entry in rows {
            for (index, step) in try objects(entry["steps"], "steps").enumerated() {
                let label = "[row \(try text(entry, "row")) \(try text(entry, "name")) step \(index)]"
                let input = try decisionInput(step, f)
                let expected = try object(step["expect"], "expect")
                let spelling = decisionSpelling(GroupPromotionDecision.decide(input), input)
                XCTAssertEqual(spelling.outcome, try text(expected, "outcome"), label)
                XCTAssertEqual(spelling.why, try text(expected, "why"), label)
                XCTAssertEqual(spelling.audioOnly, flag(expected, "join_audio_only", default: false),
                               "\(label) the automatic join is audio only")
                spellings.insert(spelling.outcome)
            }
        }
        XCTAssertEqual(spellings, ["AUTO_JOIN", "CONVERT", "HOLD", "RING", "FALLBACK", "NO_CONVERSION"])
    }

    func testOnlyAJsonBooleanTrueIsAnAttestation() throws {
        let kat = try loadKat()
        let rows = try objects(kat["predicate"], "predicate")
        // The shapes of the table (the string true, the number 1, null, false, absent), decoded the way the socket does.
        for number in ["2", "3", "4a", "4b", "4c"] {
            let entry = try katRow(rows, number)
            let step = try XCTUnwrap(try objects(entry["steps"], "steps").first)
            let invite = try object(try object(step["input"], "input")["invite"], "invite")
            XCTAssertFalse(GroupCallWire.isJsonTrue(invite["promoted"]), "row \(number)")
        }
        let decoded = try object(JSONSerialization.jsonObject(
            with: Data(#"{"a": true, "b": 1, "c": "true", "d": null, "e": false, "f": 2, "g": 1.0}"#.utf8)), "decoded")
        XCTAssertTrue(GroupCallWire.isJsonTrue(decoded["a"]))
        for key in ["b", "c", "d", "e", "f", "g", "missing"] {
            XCTAssertFalse(GroupCallWire.isJsonTrue(decoded[key]), key)
        }
        XCTAssertTrue(GroupCallWire.isJsonTrue(true))
        XCTAssertFalse(GroupCallWire.isJsonTrue(1))
        XCTAssertFalse(GroupCallWire.isJsonTrue(nil))
    }

    // MARK: - The roster rule

    func testEveryRowOfTheRosterRule() throws {
        let kat = try loadKat()
        let rows = try objects(kat["roster"], "roster")
        XCTAssertEqual(rows.count, 8)
        for row in rows {
            let name = try text(row, "name")
            let guardRule = GroupAutoJoinGuard(creatorUserId: try text(row, "creator"), invitees: try texts(row, "token_invitees"),
                                               selfUserId: try text(row, "self"))
            let updates = try objects(row["updates"], "updates")
            let expectations = try objects(row["expect"], "expect")
            XCTAssertEqual(updates.count, expectations.count, "[\(name)]")
            for (index, update) in updates.enumerated() {
                let verdict = guardRule.check(participants: try texts(update, "participants"),
                                              ringing: update["ringing"] as? [String])
                let action: String
                let mic: String
                switch verdict {
                case .pass(let release): (action, mic) = ("pass", release ? "released" : "held")
                case .refuse: (action, mic) = ("LEAVE", "off")
                }
                XCTAssertEqual(action, try text(expectations[index], "action"), "[\(name) update \(index)]")
                XCTAssertEqual(mic, try text(expectations[index], "mic"), "[\(name) update \(index)]")
            }
        }
    }

    func testTheConstantsAreTheOnesOfTheKat() throws {
        let kat = try loadKat()
        let constants = try object(kat["constants"], "constants")
        XCTAssertEqual(String(decoding: GroupPromotionToken.domain, as: UTF8.self), try text(constants, "PROMO_DOMAIN"))
        XCTAssertEqual(GroupPromotionToken.domain.count, try number(constants, "PROMO_DOMAIN_LEN"))
        XCTAssertEqual(Int(GroupPromotionToken.version), try number(constants, "PROMO_VERSION"))
        XCTAssertEqual(Int(GroupPromotionToken.callTypeAudio), try number(constants, "PROMO_CALL_AUDIO"))
        XCTAssertEqual(Int(GroupPromotionToken.senderLifetimeMs), try number(constants, "PROMO_LIFETIME_MS"))
        XCTAssertEqual(Int(GroupPromotionToken.maxLifetimeMs), try number(constants, "PROMO_LIFETIME_MS"))
        XCTAssertEqual(Int(GroupPromotionToken.minLifetimeMs), try number(constants, "PROMO_MIN_LIFETIME_MS"))
        XCTAssertEqual(Int(GroupPromotionToken.skewMs), try number(constants, "PROMO_SKEW_MS"))
        XCTAssertEqual(Int(GroupPromotionToken.inviteWaitMs), try number(constants, "PROMO_INVITE_WAIT_MS"))
        XCTAssertEqual(GroupPromotionToken.maxInvitees, try number(constants, "PROMO_MAX_INVITEES"))
        XCTAssertEqual(GroupPromotionToken.maxDataLength, try number(constants, "PROMO_MAX_DATA"))
        XCTAssertEqual(GroupPromotionToken.maxHeld, try number(constants, "PROMO_MAX_HELD"))
        XCTAssertEqual(GroupPromotionToken.tag, try text(constants, "PROMO_TAG"))
    }

    func testTheMicrophoneIsReleasedOnceAndARefusalCountsTheStrangers() {
        let rule = GroupAutoJoinGuard(creatorUserId: "c", invitees: ["p", "x"], selfUserId: "p")
        XCTAssertEqual(rule.check(participants: ["c"], ringing: ["p", "x"]), .pass(releaseMicrophone: false))
        XCTAssertEqual(rule.check(participants: ["c", "p"], ringing: ["x"]), .pass(releaseMicrophone: true))
        XCTAssertEqual(rule.check(participants: ["c", "p", "x"], ringing: []), .pass(releaseMicrophone: false),
                       "released once")
        XCTAssertEqual(rule.check(participants: ["c", "p", "y", "z"], ringing: ["y", "w"]), .refuse(extra: 3))
    }

    // MARK: - Pieces

    func testOnlyACanonicalGroupOrderScalarPasses() throws {
        let kat = try loadKat()
        let good = try object(try XCTUnwrap(try objects(kat["encode"], "encode").first)["input"], "input")
        let built = try build(good)
        let parsed = try GroupPromotionToken.parse(encoded: built.encoded).get()
        XCTAssertTrue(GroupPromotionToken.scalarIsCanonical(parsed.signature))
        var order = [UInt8](repeating: 0, count: 32)
        let bytes: [UInt8] = [0xED, 0xD3, 0xF5, 0x5C, 0x1A, 0x63, 0x12, 0x58, 0xD6, 0x9C, 0xF7, 0xA2, 0xDE, 0xF9, 0xDE, 0x14]
        for (index, byte) in bytes.enumerated() { order[index] = byte }
        order[31] = 0x10
        XCTAssertFalse(GroupPromotionToken.scalarIsCanonical(Data(count: 32) + Data(order)), "S = l")
        var below = order
        below[0] = 0xEC
        XCTAssertTrue(GroupPromotionToken.scalarIsCanonical(Data(count: 32) + Data(below)), "S = l - 1")
        XCTAssertFalse(GroupPromotionToken.scalarIsCanonical(Data(count: 63)))
    }

    func testTheDropCodesHaveTheNamesOfTheSpec() throws {
        let names = try texts(try object(try loadKat()["constants"], "constants"), "DROP_CODES")
        XCTAssertEqual(names.count, 15)
        for (index, name) in names.enumerated() {
            XCTAssertEqual(GroupPromotionToken.Drop(name: name)?.rawValue, index + 1, name)
            XCTAssertEqual(GroupPromotionToken.Drop(rawValue: index + 1)?.name, name)
        }
        XCTAssertNil(GroupPromotionToken.Drop(name: "evicted"))
    }

    func testTheWireIsSplitAtTheFirstPipeAndTheTagIsCaseSensitive() {
        XCTAssertEqual(GroupPromotionToken.splitWire("abc|GRPPROMO:AAAA")?.callId, "abc")
        XCTAssertEqual(GroupPromotionToken.splitWire("abc|GRPPROMO:AAAA")?.encoded, "AAAA")
        XCTAssertNil(GroupPromotionToken.splitWire("abc|grppromo:AAAA"))
        XCTAssertNil(GroupPromotionToken.splitWire("abc|KCMAC:AAAA"))
        XCTAssertNil(GroupPromotionToken.splitWire("GRPPROMO:AAAA"))
    }

    func testAGrppromoPayloadNeverReachesTheBundleParserWhateverItHolds() {
        for payload in ["", "AAAA", "{\"kind\":\"OFFER\"}", "not base64 at all", String(repeating: "A", count: 5000)] {
            let parsed = CallPiggyBack.parse("6b86b273-ff34-4ce1-9b49-85d6e7f8a9b0|GRPPROMO:" + payload)
            XCTAssertEqual(parsed, .groupPromotion(callId: "6b86b273-ff34-4ce1-9b49-85d6e7f8a9b0", raw: payload),
                           "payload of \(payload.count) characters")
        }
        // The JSON bundle path is still left alone.
        XCTAssertNil(CallPiggyBack.parse("c|{\"kind\":\"OFFER\"}"))
    }

    func testCanonicalIdsAndTheirComparison() {
        let id = "8a1f3c52-6d0e-4b7a-9c21-5e4d3b2a1f00"
        XCTAssertTrue(GroupCallIds.isCanonical(id))
        XCTAssertFalse(GroupCallIds.isCanonical(id.uppercased()))
        XCTAssertEqual(GroupCallIds.canonical(id.uppercased()), id)
        XCTAssertNil(GroupCallIds.canonical("abc"))
        XCTAssertNil(GroupCallIds.canonical(id + "0"))
        XCTAssertNil(GroupCallIds.canonical("8a1f3c52-6d0e-4b7a-9c21-5e4d3b2a1fgg"))
        XCTAssertTrue(GroupCallIds.ieq(id, id.uppercased()))
        XCTAssertFalse(GroupCallIds.ieq(id, "x" + id))
        XCTAssertFalse(GroupCallIds.ieq(id, nil as String?))
        XCTAssertTrue(GroupCallIds.contains([id.uppercased()], id))
        XCTAssertEqual(GroupCallIds.short(id), "8a1f3c52")
    }

    // MARK: - The anchor (GROUP_CALLS_V2 2.7, Consent)

    func testRoundOneDefinesTheAnchorOnlyWhenBoundAndAuthenticated() {
        let key = Data(repeating: 1, count: 32)
        let binding = Data(repeating: 2, count: 32)
        let own = Data(repeating: 3, count: 32)
        var caller = OneToOneAnchor()
        caller.noteRoundOne(sigOk: true, signerKey: key, acceptBinding: binding, ownSignerKey: own, bound: true)
        XCTAssertTrue(caller.isDefined)
        XCTAssertFalse(caller.kcmacVerified)
        caller.noteKcMacVerified(round: 2)
        XCTAssertFalse(caller.kcmacVerified, "only round 1 counts")
        caller.noteKcMacVerified(round: 1)
        XCTAssertTrue(caller.kcmacVerified)

        var callee = OneToOneAnchor()
        callee.noteRoundOne(sigOk: true, signerKey: key, acceptBinding: binding, ownSignerKey: own, bound: false)
        XCTAssertFalse(callee.isDefined, "the REVEAL has not verified")
        XCTAssertTrue(callee.authenticated)
        callee.noteBound()
        XCTAssertTrue(callee.isDefined)
    }

    func testAnAbortVerdictOfRoundOneLeavesTheAnchorUndefinedForTheWholeCall() {
        let key = Data(repeating: 1, count: 32)
        let binding = Data(repeating: 2, count: 32)
        let own = Data(repeating: 3, count: 32)
        var anchor = OneToOneAnchor()
        anchor.noteRoundOne(sigOk: false, signerKey: nil, acceptBinding: binding, ownSignerKey: own, bound: true)
        XCTAssertFalse(anchor.isDefined)
        // A later round that verifies (a call-scoped pin after a SAS confirmation) never defines it.
        anchor.noteRoundOne(sigOk: true, signerKey: key, acceptBinding: binding, ownSignerKey: own, bound: true)
        XCTAssertFalse(anchor.isDefined, "round 1 is noted once")
        XCTAssertTrue(anchor.canSign, "what this device needs to SIGN does not depend on the peer's verdict")
    }

    func testALaterRoundThatIsNotAuthenticatedOrIsSignedByAnotherKeyPoisonsForGood() {
        let key = Data(repeating: 1, count: 32)
        let binding = Data(repeating: 2, count: 32)
        let own = Data(repeating: 3, count: 32)
        func defined() -> OneToOneAnchor {
            var anchor = OneToOneAnchor()
            anchor.noteRoundOne(sigOk: true, signerKey: key, acceptBinding: binding, ownSignerKey: own, bound: true)
            return anchor
        }
        var same = defined()
        same.noteLaterRound(sigOk: true, signerKey: key)
        XCTAssertFalse(same.poisoned)
        var unverified = defined()
        unverified.noteLaterRound(sigOk: false, signerKey: nil)
        XCTAssertTrue(unverified.poisoned)
        unverified.noteLaterRound(sigOk: true, signerKey: key)
        XCTAssertTrue(unverified.poisoned, "sticky")
        var other = defined()
        other.noteLaterRound(sigOk: true, signerKey: Data(repeating: 9, count: 32))
        XCTAssertTrue(other.poisoned)
    }

    // MARK: - What the creator sends (GROUP_CALLS_V2 2.7, Promotion token)

    func testThePlanValidatesTheRecipientsAndSignsTheTokenForExactlyThose() throws {
        let kat = try loadKat()
        let f = try loadFixed(kat)
        var anchor = OneToOneAnchor()
        anchor.noteRoundOne(sigOk: true, signerKey: f.otherPublic, acceptBinding: f.binding,
                            ownSignerKey: f.creatorPublic, bound: true)
        let plan = GroupPromotionPlan.plan(
            peerUserId: f.peer, others: [f.extra.uppercased(), f.peer.uppercased(), "", f.creator, f.extra],
            selfUserId: f.creator, oneToOneCallId: f.live.uppercased(), anchor: anchor,
            liveSigningPublicKey: f.creatorPublic, nowMs: UInt64(f.issuedAtMs), groupCallId: f.group,
            sign: { f.sign($0) })
        let token = try XCTUnwrap(plan.token, "the preconditions hold")
        XCTAssertEqual(plan.recipients, [f.peer, f.extra], "sorted, de-duplicated, without the creator")
        XCTAssertEqual(plan.recipients, token.fields.invitees, "the create carries exactly the token's invitees")
        XCTAssertEqual(plan.groupCallId, f.group)
        XCTAssertEqual(token.fields.fromCallId, f.live, "the 1:1 call id enters the token in canonical form")
        XCTAssertEqual(token.fields.creatorUserId, f.creator)
        XCTAssertEqual(token.fields.callType, GroupPromotionToken.callTypeAudio)
        XCTAssertTrue(token.wireData(callId: f.live.uppercased()).hasPrefix(f.live.uppercased() + "|GRPPROMO:"),
                      "the wire names the 1:1 call as that call's transcript spells it")
    }

    func testWithoutAPreconditionNoTokenIsSentAndTheGroupIsCreatedAsBefore() throws {
        let kat = try loadKat()
        let f = try loadFixed(kat)
        func plan(_ anchor: OneToOneAnchor, key: Data?, peer: String? = nil, others: [String] = []) -> GroupPromotionPlan.Plan {
            GroupPromotionPlan.plan(
                peerUserId: peer ?? f.peer, others: others, selfUserId: f.creator, oneToOneCallId: f.live, anchor: anchor,
                liveSigningPublicKey: key, nowMs: UInt64(f.issuedAtMs), groupCallId: f.group, sign: { f.sign($0) })
        }
        var bound = OneToOneAnchor()
        bound.noteRoundOne(sigOk: false, signerKey: nil, acceptBinding: f.binding, ownSignerKey: f.creatorPublic, bound: true)
        XCTAssertNotNil(plan(bound, key: f.creatorPublic).token, "the peer's verdict plays no part in what is needed to sign")
        XCTAssertEqual(plan(OneToOneAnchor(), key: f.creatorPublic).withoutTokenWhy, "no_binding")
        var callee = OneToOneAnchor()
        callee.noteRoundOne(sigOk: true, signerKey: f.otherPublic, acceptBinding: f.binding,
                            ownSignerKey: f.creatorPublic, bound: false)
        XCTAssertNil(plan(callee, key: f.creatorPublic).token, "round 1 is not bound on this device yet")
        XCTAssertEqual(plan(bound, key: f.otherPublic).withoutTokenWhy, "key_changed")
        XCTAssertEqual(plan(bound, key: nil).withoutTokenWhy, "key_changed")
        let noUuid = plan(bound, key: f.creatorPublic, peer: "1042", others: ["abc"])
        XCTAssertNil(noUuid.token)
        XCTAssertEqual(noUuid.recipients, ["1042", "abc"], "the recipients go out as they were")
        XCTAssertEqual(noUuid.groupCallId, f.group)
        func pad(_ value: Int, _ width: Int) -> String {
            let digits = String(value, radix: 16)
            return String(repeating: "0", count: max(width - digits.count, 0)) + digits
        }
        let tooMany = plan(bound, key: f.creatorPublic, others: (1...63).map { pad($0, 8) + "-0000-4000-8000-" + pad($0, 12) })
        XCTAssertNil(tooMany.token, "64 invitees do not fit one token")
        XCTAssertEqual(tooMany.recipients.count, 64)
    }
}
