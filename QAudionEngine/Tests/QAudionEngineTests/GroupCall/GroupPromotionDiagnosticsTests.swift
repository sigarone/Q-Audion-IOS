import XCTest
@testable import QAudionEngine

/// The wire fields of the 1:1 promotion (spec 28, 31) and the numeric phone-log lines of the
/// ring, the lone call, the admission question and the audio unit driver. Every `grp ...` line
/// pinned here is also read by `scripts/test_ship_ios_grppromo_vocab.py`, which checks that the
/// phone-log shipper keeps each one unchanged: change a format here and there together.
final class GroupPromotionDiagnosticsTests: XCTestCase {

    // MARK: wire: group_call_update.ringing (spec 31)

    private func updateData(_ extra: [String: Any] = [:]) -> [String: Any] {
        var data: [String: Any] = [
            "call_id": "c1", "participants": ["user-a", "user-b"], "sender_key_epoch": NSNumber(value: 3),
        ]
        for (key, value) in extra { data[key] = value }
        return data
    }

    func testSpec31_theRingingListIsParsed() throws {
        let update = try XCTUnwrap(GroupCallWire.Update.parse(updateData(["ringing": ["user-c", "user-d"]])))
        XCTAssertEqual(update.ringing, ["user-c", "user-d"])
        XCTAssertEqual(update.epoch, 3)
    }

    func testSpec31_anUpdateWithoutTheFieldHasNoRingingList() throws {
        XCTAssertNil(try XCTUnwrap(GroupCallWire.Update.parse(updateData())).ringing, "an older server")
        XCTAssertNil(try XCTUnwrap(GroupCallWire.Update.parse(updateData(["ringing": "user-c"]))).ringing,
                     "a field of the wrong type is no list")
        XCTAssertEqual(try XCTUnwrap(GroupCallWire.Update.parse(updateData(["ringing": [String]()]))).ringing, [],
                       "an empty list is a list: nobody rings")
    }

    func testSpec31_theRingingListIsDeduplicatedAndBounded() throws {
        let many = (0..<100).map { "user-\($0)" }
        let update = try XCTUnwrap(GroupCallWire.Update.parse(updateData(["ringing": ["user-x", "", "user-x"] + many])))
        XCTAssertEqual(update.ringing?.first, "user-x")
        XCTAssertEqual(update.ringing?.filter { $0 == "user-x" }.count, 1)
        XCTAssertFalse(update.ringing?.contains("") ?? true)
        XCTAssertEqual(update.ringing?.count, GroupCallWire.Update.maxRinging)
    }

    // MARK: wire: group_call_invite attestation (spec 28)

    private func makeManager() -> BCryptoGroupCallManager {
        let ws = BCryptoWebSocketClient(config: BackendConfig(serverUrl: "https://example.invalid"))
        return BCryptoGroupCallManager(ws: ws, selfUserId: "user-self", nameResolver: { $0 })
    }

    func testSpec28_anAttestedInviteCarriesBothFields() throws {
        let invite = try XCTUnwrap(makeManager().parseInvite(data: [
            "call_id": "g1", "creator_id": "user-b", "call_type": "audio",
            "promoted": true, "promoted_from_call_id": "one-to-one",
        ]))
        XCTAssertTrue(invite.promoted)
        XCTAssertEqual(invite.promotedFromCallId, "one-to-one")
        XCTAssertEqual(invite.creatorId, "user-b")
    }

    func testSpec28_anInviteFromAnOlderServerIsNotAttested() throws {
        let manager = makeManager()
        let plain = try XCTUnwrap(manager.parseInvite(data: ["call_id": "g1", "creator_id": "user-b"]))
        XCTAssertFalse(plain.promoted)
        XCTAssertEqual(plain.promotedFromCallId, "")
        XCTAssertEqual(plain.callType, "audio")
        // The informational field alone (what the creator's client relays) is no attestation.
        let relayed = try XCTUnwrap(manager.parseInvite(data: [
            "call_id": "g1", "creator_id": "user-b", "promoted_from_call_id": "one-to-one",
        ]))
        XCTAssertFalse(relayed.promoted)
        // Only a boolean true counts, never a string.
        for bogus in ["true", "yes"] {
            let invite = try XCTUnwrap(manager.parseInvite(data: ["call_id": "g1", "creator_id": "user-b", "promoted": bogus]))
            XCTAssertFalse(invite.promoted)
        }
        let explicitFalse = try XCTUnwrap(manager.parseInvite(data: ["call_id": "g1", "creator_id": "user-b", "promoted": false]))
        XCTAssertFalse(explicitFalse.promoted)
        // Nor a number (a number 1 bridges to a true Bool), nor null, nor a list.
        let notBooleans: [Any] = [1, 0, 2, 1.5, NSNumber(value: 1), NSNull(), ["true"]]
        for bogus in notBooleans {
            let invite = try XCTUnwrap(manager.parseInvite(data: ["call_id": "g1", "creator_id": "user-b", "promoted": bogus]))
            XCTAssertFalse(invite.promoted, "\(bogus)")
        }
    }

    func testSpec28_theAttestationIsReadFromTheJsonTheSocketDecodes() throws {
        let manager = makeManager()
        func invite(_ json: String) throws -> BCryptoGroupCallManager.IncomingGroupInvite {
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
            let data = try XCTUnwrap(object as? [String: Any])
            return try XCTUnwrap(manager.parseInvite(data: data))
        }
        XCTAssertTrue(try invite(#"{"call_id":"g","creator_id":"c","promoted":true}"#).promoted)
        XCTAssertFalse(try invite(#"{"call_id":"g","creator_id":"c","promoted":1}"#).promoted)
        XCTAssertFalse(try invite(#"{"call_id":"g","creator_id":"c","promoted":"true"}"#).promoted)
        XCTAssertFalse(try invite(#"{"call_id":"g","creator_id":"c","promoted":null}"#).promoted)
        XCTAssertFalse(try invite(#"{"call_id":"g","creator_id":"c"}"#).promoted)
    }

    func testSpec28_anInviteWithoutACallOrACreatorIsRefused() {
        let manager = makeManager()
        XCTAssertNil(manager.parseInvite(data: ["creator_id": "user-b"]))
        XCTAssertNil(manager.parseInvite(data: ["call_id": "g1"]))
    }

    func testSpec30_theAloneEndReasonEndsTheActiveCallAndIsNotARingOnlyReason() {
        XCTAssertFalse(BCryptoGroupCallManager.ringOnlyEndReasons.contains("alone"))
        let manager = makeManager()
        manager.sendOverride = { _, _ in }
        let id = manager.createGroupCall(recipients: ["user-b"])
        XCTAssertNotNil(id)
        var ended: [String] = []
        manager.onActiveCallEnded = { _, reason in ended.append(reason) }
        manager.handleGroupCallEnded(data: ["call_id": id ?? "", "reason": "alone"])
        XCTAssertEqual(ended, ["alone"])
        XCTAssertNil(manager.callId)
    }

    // MARK: phone-log lines

    func testRingLines() {
        XCTAssertEqual(GroupDiagnostics.ringLine(.shown), "grp ring phase=1 code=0")
        XCTAssertEqual(GroupDiagnostics.ringLine(.busyDrop, code: GroupDiagnostics.BusyCode.oneToOne.rawValue), "grp ring phase=2 code=1")
        XCTAssertEqual(GroupDiagnostics.ringLine(.busyDrop, code: GroupDiagnostics.BusyCode.groupCall.rawValue), "grp ring phase=2 code=3")
        XCTAssertEqual(GroupDiagnostics.ringLine(.timedOut), "grp ring phase=3 code=0")
        XCTAssertEqual(GroupDiagnostics.ringLine(.declined), "grp ring phase=4 code=0")
        XCTAssertEqual(GroupDiagnostics.ringLine(.endedByServer, code: GroupDiagnostics.endReasonCode("alone")), "grp ring phase=5 code=5")
        XCTAssertEqual(GroupDiagnostics.ringLine(.autoJoin), "grp ring phase=6 code=0")
        XCTAssertEqual(GroupDiagnostics.ringLine(.accepted), "grp ring phase=7 code=0")
    }

    func testEndReasonsAreNumbersNeverText() {
        XCTAssertEqual(GroupDiagnostics.endReasonCode("ring_timeout"), 1)
        XCTAssertEqual(GroupDiagnostics.endReasonCode("declined"), 2)
        XCTAssertEqual(GroupDiagnostics.endReasonCode("answered_elsewhere"), 3)
        XCTAssertEqual(GroupDiagnostics.endReasonCode("ended"), 4)
        XCTAssertEqual(GroupDiagnostics.endReasonCode("alone"), 5)
        XCTAssertEqual(GroupDiagnostics.endReasonCode("some new reason"), 9)
    }

    func testAloneLines() {
        XCTAssertEqual(GroupDiagnostics.aloneLine(.armed, ms: 50_000), "grp alone phase=1 ms=50000")
        XCTAssertEqual(GroupDiagnostics.aloneLine(.cancelled, ms: 50_000), "grp alone phase=2 ms=50000")
        XCTAssertEqual(GroupDiagnostics.aloneLine(.left, ms: 50_000), "grp alone phase=3 ms=50000")
        XCTAssertEqual(GroupDiagnostics.aloneLine(.ended, ms: 50_000), "grp alone phase=4 ms=50000")
    }

    func testRingingAdmissionAndExitLines() {
        XCTAssertEqual(GroupDiagnostics.ringingLine(count: 2, roster: 1), "grp ringing n=2 roster=1")
        XCTAssertEqual(GroupDiagnostics.ringingLine(count: 0, roster: 3), "grp ringing n=0 roster=3")
        XCTAssertEqual(GroupDiagnostics.admissionLine(.askedToDial, roster: 3), "grp busy why=1 roster=3")
        XCTAssertEqual(GroupDiagnostics.admissionLine(.askedToAnswer, roster: 2), "grp busy why=2 roster=2")
        XCTAssertEqual(GroupDiagnostics.admissionLine(.confirmed, roster: 2), "grp busy why=3 roster=2")
        XCTAssertEqual(GroupDiagnostics.admissionLine(.cancelled, roster: 1), "grp busy why=4 roster=1")
        XCTAssertEqual(GroupDiagnostics.admissionLine(.withdrawn, roster: 2), "grp busy why=5 roster=2")
        XCTAssertEqual(GroupDiagnostics.admissionLine(.refusedFromCar, roster: 2), "grp busy why=6 roster=2")
        XCTAssertEqual(GroupDiagnostics.exitLine(.alone, endsForAll: true), "grp end why=1 role=1")
        XCTAssertEqual(GroupDiagnostics.exitLine(.oneToOne, endsForAll: false), "grp end why=2 role=0")
        XCTAssertEqual(GroupDiagnostics.exitLine(.acceptOther, endsForAll: false), "grp end why=3 role=0")
        XCTAssertEqual(GroupDiagnostics.exitLine(.oneToOneEndedAlone, endsForAll: true), "grp end why=4 role=1")
        XCTAssertEqual(GroupDiagnostics.exitLine(.hangUp, endsForAll: true), "grp end why=5 role=1")
        XCTAssertEqual(GroupDiagnostics.exitLine(.promotionAborted, endsForAll: false), "grp end why=6 role=0")
        XCTAssertEqual(GroupDiagnostics.exitLine(.rosterMismatch, endsForAll: false), "grp end why=7 role=0")
        XCTAssertEqual(GroupDiagnostics.exitLine(.mediaNotUp, endsForAll: true), "grp end why=8 role=1")
    }

    func testThePromotionTokenLinesAreNumbersOnly() {
        XCTAssertEqual(GroupDiagnostics.promoNotSentLine(invitees: 2), "grp promo tx=0 n=2")
        XCTAssertEqual(GroupDiagnostics.promoSentLine(resend: false, invitees: 2), "grp promo tx=1 n=2")
        XCTAssertEqual(GroupDiagnostics.promoSentLine(resend: true, invitees: 63), "grp promo tx=2 n=63")
        XCTAssertEqual(GroupDiagnostics.promoReceivedLine(ok: true, code: 0), "grp promo rx=1 ok=1 code=0")
        XCTAssertEqual(GroupDiagnostics.promoReceivedLine(ok: false, code: GroupPromotionToken.Drop.badSig.rawValue),
                       "grp promo rx=1 ok=0 code=8")
        XCTAssertEqual(GroupDiagnostics.promoReceivedLine(ok: false, code: GroupPromotionToken.Drop.dupGroup.rawValue),
                       "grp promo rx=1 ok=0 code=15")
        XCTAssertEqual(GroupDiagnostics.promoReceivedLine(ok: true, code: GroupDiagnostics.promoStoredEvictingCode),
                       "grp promo rx=1 ok=1 code=16")
        XCTAssertEqual(GroupDiagnostics.promoDecisionLine(.auto, why: .token), "grp promo dec=1 why=1")
        XCTAssertEqual(GroupDiagnostics.promoDecisionLine(.hold, why: .noToken), "grp promo dec=2 why=2")
        XCTAssertEqual(GroupDiagnostics.promoDecisionLine(.hold, why: .kcPending), "grp promo dec=2 why=3")
        XCTAssertEqual(GroupDiagnostics.promoDecisionLine(.ring, why: .noMic), "grp promo dec=3 why=9")
        XCTAssertEqual(GroupDiagnostics.promoDecisionLine(.convert, why: .token), "grp promo dec=4 why=1")
        XCTAssertEqual(GroupDiagnostics.promoDecisionLine(.fallback, why: .notCandidate), "grp promo dec=5 why=10")
        XCTAssertEqual(GroupDiagnostics.promoRosterLine(extra: 1), "grp promo roster=0 n=1")
    }

    func testTheDecisionReasonsHaveTheNamesOfTheSpec() {
        let names: [GroupPromotionDecision.Why: String] = [
            .token: "token", .noToken: "no_token", .kcPending: "kc_pending", .noAnchor: "no_anchor",
            .poisoned: "poisoned", .consumed: "consumed", .stale: "stale", .groupLive: "group_live",
            .noMic: "no_mic", .notCandidate: "not_candidate",
        ]
        for (why, name) in names { XCTAssertEqual(why.name, name) }
    }

    func testAudioDriverLines() {
        XCTAssertEqual(GroupDiagnostics.audioDriverLine(.begun, shared: true), "grp audio phase=1 shared=1")
        XCTAssertEqual(GroupDiagnostics.audioDriverLine(.begun, shared: false), "grp audio phase=1 shared=0")
        XCTAssertEqual(GroupDiagnostics.audioDriverLine(.watchdog, shared: false), "grp audio phase=2 shared=0")
        XCTAssertEqual(GroupDiagnostics.audioDriverLine(.activatedShared, shared: true), "grp audio phase=3 shared=1")
        XCTAssertEqual(GroupDiagnostics.audioDriverLine(.rearmed, shared: false), "grp audio phase=4 shared=0")
    }

    func testTheNewHandOverPhases() {
        XCTAssertEqual(GroupDiagnostics.promotionLine(.autoJoined, ms: 120), "grp swap phase=6 ms=120")
        XCTAssertEqual(GroupDiagnostics.promotionLine(.peerInviteOver, ms: 2400), "grp swap phase=7 ms=2400")
        XCTAssertEqual(GroupDiagnostics.promotionLine(.oneToOneEnded, ms: 30000), "grp swap phase=10 ms=30000")
        XCTAssertEqual(GroupDiagnostics.promotionLine(.aborted, ms: 900), "grp swap phase=11 ms=900")
    }

    func testTheRefusedOneToOneAudioStartLine() {
        XCTAssertEqual(GroupDiagnostics.audioStartRefusedLine(native: true, unitEnabled: false), "audioIO skip=1 gate=1 nat=1 en=0")
        XCTAssertEqual(GroupDiagnostics.audioStartRefusedLine(native: false, unitEnabled: true), "audioIO skip=1 gate=1 nat=0 en=1")
    }
}
