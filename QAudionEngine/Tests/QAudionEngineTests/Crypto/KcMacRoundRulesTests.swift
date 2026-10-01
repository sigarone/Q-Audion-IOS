import XCTest
@testable import QAudionEngine

/// R-KCMAC bookkeeping (WIRE_SPEC §3.7.1): every key round has its own context and roles; a
/// retransmit of an already-decided round's MAC is recognised by content (and dropped by the app,
/// never judged wrong); a MAC for a round not armed yet is held (one at a time, small, for at most
/// 10 s).
final class KcMacRoundRulesTests: XCTestCase {

    /// A synthetic round: `K_kc` from a label, a distinct transcript, and this side's role.
    private func round(_ label: String, initiator: Bool) -> KcMacRound {
        KcMacRound(
            kcKey: KeyConfirmation.deriveKcKey(sessionKey: Data(label.utf8) + Data(repeating: 0x5A, count: 32)),
            transcript: Data("transcript-\(label)".utf8),
            isInitiator: initiator)
    }

    /// The `KCMAC:` payload the PEER of `r` sends for that round: `role || MAC`.
    private func peerPayload(of r: KcMacRound) -> String {
        let role: UInt8 = r.isInitiator ? 0x02 : 0x01
        let mac = r.isInitiator
            ? KeyConfirmation.macResp(kcKey: r.kcKey, transcript: r.transcript)
            : KeyConfirmation.macInit(kcKey: r.kcKey, transcript: r.transcript)
        return (Data([role]) + mac).base64EncodedString()
    }

    func testPeerMacOfTheSameRoundVerifies() {
        let r1 = round("a", initiator: true)
        XCTAssertTrue(KcMacRoundRules.isPeerMac(raw: peerPayload(of: r1), of: r1))
        let r2 = round("b", initiator: false)
        XCTAssertTrue(KcMacRoundRules.isPeerMac(raw: peerPayload(of: r2), of: r2))
    }

    /// Round roles are per round: the same peer MAC does not verify under the other round.
    func testAMacOfAnotherRoundDoesNotVerify() {
        let r1 = round("a", initiator: true)
        let r2 = round("b", initiator: true)
        XCTAssertFalse(KcMacRoundRules.isPeerMac(raw: peerPayload(of: r1), of: r2))
        // Same context but the opposite role in the round: the role byte / MAC direction differ.
        let flipped = KcMacRound(kcKey: r1.kcKey, transcript: r1.transcript, isInitiator: false)
        XCTAssertFalse(KcMacRoundRules.isPeerMac(raw: peerPayload(of: r1), of: flipped))
    }

    func testReflectedOwnMacAndMalformedPayloadsAreNotPeerMacs() {
        let r = round("a", initiator: true)
        let own = (Data([0x01]) + KeyConfirmation.macInit(kcKey: r.kcKey, transcript: r.transcript)).base64EncodedString()
        XCTAssertFalse(KcMacRoundRules.isPeerMac(raw: own, of: r), "a reflected MAC is not the peer's")
        XCTAssertFalse(KcMacRoundRules.isPeerMac(raw: "not base64!", of: r))
        XCTAssertFalse(KcMacRoundRules.isPeerMac(raw: Data(count: 32).base64EncodedString(), of: r))
        XCTAssertFalse(KcMacRoundRules.isPeerMac(raw: Data(count: 34).base64EncodedString(), of: r))
        XCTAssertNil(KcMacRoundRules.mac(inPayload: Data(count: 32).base64EncodedString()))
    }

    /// The retransmit of round 1's MAC arrives while round 2 is armed: it is a duplicate of a
    /// decided round (dropped), whereas it does NOT verify against round 2 (it would have been
    /// judged `wrong` and ended a healthy call).
    func testRetransmitOfADecidedRoundIsADuplicateAndWouldFailTheCurrentRound() throws {
        let r1 = round("a", initiator: true)
        let r2 = round("b", initiator: false)   // the callee started round 2: roles flipped
        let decided = [try XCTUnwrap(KcMacRoundRules.mac(inPayload: peerPayload(of: r1)))]
        let retransmit = peerPayload(of: r1)
        XCTAssertTrue(KcMacRoundRules.isDuplicate(raw: retransmit, decidedPeerMacs: decided))
        XCTAssertFalse(KcMacRoundRules.isPeerMac(raw: retransmit, of: r2))
        // Round 2's own MAC is not a duplicate of anything decided.
        XCTAssertFalse(KcMacRoundRules.isDuplicate(raw: peerPayload(of: r2), decidedPeerMacs: decided))
        // And a forged MAC is not a duplicate either: it is judged (and fails) normally.
        let forged = (Data([0x01]) + Data(repeating: 0x42, count: 32)).base64EncodedString()
        XCTAssertFalse(KcMacRoundRules.isDuplicate(raw: forged, decidedPeerMacs: decided))
        XCTAssertFalse(KcMacRoundRules.isDuplicate(raw: "junk", decidedPeerMacs: decided))
    }

    /// Every decided round of the call stays recognisable (not only the previous one).
    func testEveryDecidedRoundIsRecognisedForTheWholeCall() throws {
        let rounds = (0..<9).map { round("r\($0)", initiator: $0 % 2 == 0) }
        let decided = try rounds.map { try XCTUnwrap(KcMacRoundRules.mac(inPayload: peerPayload(of: $0))) }
        for r in rounds {
            XCTAssertTrue(KcMacRoundRules.isDuplicate(raw: peerPayload(of: r), decidedPeerMacs: decided))
        }
    }

    /// Decided peer MACs are kept for the rest of the call, bounded at 256 (the oldest drops first).
    func testDecidedPeerMacsAreKeptAndBoundedAt256() {
        XCTAssertEqual(KcMacRoundRules.maxDecidedPeerMacs, 256)
        var decided: [Data] = []
        for i in 0..<300 {
            KcMacRoundRules.recordDecided(Data([UInt8(i & 0xFF), UInt8(i >> 8)]), in: &decided)
        }
        XCTAssertEqual(decided.count, 256)
        XCTAssertEqual(decided.first, Data([UInt8(44), UInt8(0)]), "the 44 oldest were dropped")
        XCTAssertEqual(decided.last, Data([UInt8(299 & 0xFF), UInt8(299 >> 8)]))
    }

    func testEarlyMacIsHeldForAtMostTenSeconds() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(KcMacRoundRules.earlyHoldSeconds, 10)
        XCTAssertTrue(KcMacRoundRules.isEarlyHoldFresh(heldAt: t0, now: t0))
        XCTAssertTrue(KcMacRoundRules.isEarlyHoldFresh(heldAt: t0, now: t0.addingTimeInterval(9.9)))
        XCTAssertTrue(KcMacRoundRules.isEarlyHoldFresh(heldAt: t0, now: t0.addingTimeInterval(10)))
        XCTAssertFalse(KcMacRoundRules.isEarlyHoldFresh(heldAt: t0, now: t0.addingTimeInterval(10.1)))
    }

    /// One early MAC at a time (a further one is dropped while a fresh one is held), at most 512
    /// characters, and a stale held one no longer blocks a new one.
    func testOnlyOneSmallEarlyMacIsHeldAtATime() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let small = Data(count: 33).base64EncodedString()
        XCTAssertTrue(KcMacRoundRules.mayHoldEarly(raw: small, heldAt: nil, now: now))
        XCTAssertFalse(KcMacRoundRules.mayHoldEarly(raw: small, heldAt: now.addingTimeInterval(-3), now: now),
                       "a fresh held MAC is kept; the further one is dropped")
        XCTAssertTrue(KcMacRoundRules.mayHoldEarly(raw: small, heldAt: now.addingTimeInterval(-11), now: now),
                      "a stale held MAC no longer blocks")
        let huge = String(repeating: "A", count: KcMacRoundRules.maxHeldPayloadCharacters + 1)
        XCTAssertFalse(KcMacRoundRules.mayHoldEarly(raw: huge, heldAt: nil, now: now))
        let atLimit = String(repeating: "A", count: KcMacRoundRules.maxHeldPayloadCharacters)
        XCTAssertTrue(KcMacRoundRules.mayHoldEarly(raw: atLimit, heldAt: nil, now: now))
    }
}
