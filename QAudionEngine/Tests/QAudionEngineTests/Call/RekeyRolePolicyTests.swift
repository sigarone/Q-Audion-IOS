import XCTest
@testable import QAudionEngine

/// R-REKEY-INIT (only the caller initiates a rekey; a rekey OFFER that reaches the caller is
/// answered) and R-E-STRICT (the key round epoch comes from the signed round, or the call ends).
final class RekeyRolePolicyTests: XCTestCase {

    private let callId = "11111111-2222-3333-4444-555555555555"

    // MARK: R-REKEY-INIT

    func testOnlyTheCallerInitiatesARekey() {
        XCTAssertTrue(RekeyRolePolicy.mayInitiateRekey(isCaller: true, isActive: true, hasPendingAttempt: false))
        XCTAssertFalse(
            RekeyRolePolicy.mayInitiateRekey(isCaller: false, isActive: true, hasPendingAttempt: false),
            "the callee only responds")
        XCTAssertFalse(RekeyRolePolicy.mayInitiateRekey(isCaller: true, isActive: false, hasPendingAttempt: false))
        XCTAssertFalse(
            RekeyRolePolicy.mayInitiateRekey(isCaller: true, isActive: true, hasPendingAttempt: true),
            "one own round in flight at a time")
    }

    func testACalleeIntegrationNeverStartsARound() async {
        let integ = QAudionCallIntegration()   // never sent an offer: not the caller
        let started = await integ.performPqcReKey(callId: callId, peerId: "peer-1")
        XCTAssertFalse(started)
    }

    /// A rekey OFFER that reaches the CALLER goes through the responder path (verification, ACCEPT):
    /// it is never left in the buffer the caller's own round reads its ACCEPT from. An OFFER without
    /// a signature must reach the verification and end the call as malformed.
    func testACallerAnswersAnOfferTheCalleeSends() async {
        let integ = QAudionCallIntegration()
        integ.didSendOutgoingCallOffer(callId: callId)   // this side is the caller
        var fatals: [(String, String)] = []
        integ.onHandshakeFatal = { id, reason in fatals.append((id, reason)) }
        let offer = AndroidHandshakeBundle(
            kind: .offer, callId: callId,
            pqcPublicKey: Data(repeating: 0xA1, count: 1568).base64EncodedString(),
            x25519PublicKey: Data(repeating: 0xA2, count: 32).base64EncodedString(),
            rekeyNonce: V6TestFixtures.rekeyNonce.base64EncodedString(), rekeyRound: 2)
        var threw = false
        do {
            try await integ.onAndroidBundleReceived(
                bundle: offer, callId: callId, callerId: "peer-1", sendOpaqueRaw: { _ in })
        } catch {
            threw = true
        }
        XCTAssertTrue(threw, "the OFFER reached the verification")
        XCTAssertEqual(fatals.map { $0.1 }, ["handshake_malformed"])
    }

    // MARK: R-E-STRICT

    func testTheEpochIsTheSignedRoundMinusOne() {
        XCTAssertEqual(RekeyRolePolicy.resolveKeyEpoch(signedRound: 1), .epoch(0))
        XCTAssertEqual(RekeyRolePolicy.resolveKeyEpoch(signedRound: 3), .epoch(2), "a gap is kept, never renumbered")
    }

    /// No local-counter fallback: a key whose signed round is unknown (never derived here) or
    /// invalid ends the call.
    func testAnUnresolvableRoundEndsTheCallWithHandshakeMalformed() {
        XCTAssertEqual(RekeyRolePolicy.resolveKeyEpoch(signedRound: nil), .endCall(reason: "handshake_malformed"))
        XCTAssertEqual(RekeyRolePolicy.resolveKeyEpoch(signedRound: 0), .endCall(reason: "handshake_malformed"))
        XCTAssertEqual(
            RekeyRolePolicy.resolveKeyEpoch(signedRound: UInt32.max), .endCall(reason: "handshake_malformed"))
    }

    func testAKeyTheIntegrationNeverDerivedHasNoRound() {
        let integ = QAudionCallIntegration()
        let key = Data(repeating: 7, count: 32)
        XCTAssertNil(integ.keyRound(forSessionKey: key, callId: callId))
        XCTAssertEqual(
            RekeyRolePolicy.resolveKeyEpoch(signedRound: integ.keyRound(forSessionKey: key, callId: callId)),
            .endCall(reason: "handshake_malformed"))
    }

    // AppState cannot be driven here (CallKit, live provider, WebSocket): the handler is pinned on
    // the source text, like the other wiring invariants.
    func testTheAppHasNoLocalCounterFallbackForTheEpoch() throws {
        var dir = URL(fileURLWithPath: #filePath)
        var text: String?
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("QAudionApp/AppState.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                text = try String(contentsOf: candidate, encoding: .utf8)
                break
            }
        }
        guard let app = text else { throw XCTSkip("QAudionApp/AppState.swift not found") }
        XCTAssertFalse(app.contains("callPqcRekeyEpoch += 1"), "E must never come from a local counter")
        XCTAssertFalse(app.contains("keyepoch src=2"))
        XCTAssertTrue(app.contains("RekeyRolePolicy.resolveKeyEpoch(signedRound: round)"))
        XCTAssertTrue(
            app.contains("handleHandshakeFatal(callId: activeId, reason: reason)"),
            "an unresolvable round ends the call")
    }
}
