import XCTest
@testable import QAudionEngine

/// R-KCMAC payload helpers (WIRE_SPEC §3.7.1): every key round has its own context and roles, and a MAC verifies only
/// under the round it was made for. The attribution, duplicate and held-set rules are in `KcMacRoundBookTests`.
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
}
