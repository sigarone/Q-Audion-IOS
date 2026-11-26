import XCTest
import Foundation
@testable import QAudionEngine

/// The device of an outgoing call: the sender of the `call_answer`, used only when the sender of the accept message is the same one,
/// and the pin row of that device, used only for the key that the call's own handshake verified.
final class VoiceAnsweredDeviceTests: XCTestCase {
    private let hour: Int64 = 3_600
    private let t0: Int64 = 1_800_000_000
    private let callId = "11111111-2222-3333-4444-555555555555"
    private let key = Data(repeating: 7, count: 32)
    private let otherKey = Data(repeating: 9, count: 32)

    private func tier(_ trust: VoiceTierTrust?, device: String?, auth: CallIdentityAuth, start: Int64) throws -> Int {
        let line = CallPqProtection(levelToken: "PQ2", auth: "H", pin: "ok", callId: callId)
        let built = VoiceTierInputs.build(
            callId: callId, peerDeviceId: device, trust: trust, auth: auth, protection: line, kcmacOk: true, callStartS: start)
        return VoiceTier.tier(try XCTUnwrap(built))
    }

    private func row(key: Data, pinnedAt: Int64) -> VoiceTierTrust {
        VoiceTierTrust(pinnedKey: key, pinnedAtS: pinnedAt, pendingChange: false, oobVerified: false)
    }

    // MARK: the device

    func testTheAnswerDeviceEqualToTheAcceptSenderIsTheDeviceInEitherOrder() {
        let answerFirst = VoiceDeviceBinding()
        answerFirst.bind(callId: "c1", deviceId: nil)
        answerFirst.noteAnswerSender(callId: "C1", deviceId: "dev-a")
        XCTAssertNil(answerFirst.device(forCall: "c1"), "the accept has not arrived: unknown, no wait")
        answerFirst.noteAccept(callId: "c1", deviceId: "dev-a")
        XCTAssertEqual(answerFirst.device(forCall: "c1"), "dev-a")
        XCTAssertTrue(answerFirst.isFromAnswerSender(forCall: "c1"))

        let acceptFirst = VoiceDeviceBinding()
        acceptFirst.noteAccept(callId: "c1", deviceId: "dev-a")
        acceptFirst.noteAnswerSender(callId: "c1", deviceId: "dev-a")
        XCTAssertEqual(acceptFirst.device(forCall: "c1"), "dev-a", "a late call_answer binds when it agrees")
    }

    func testAnAnswerDeviceDifferentFromTheAcceptSenderLeavesTheDeviceUnknown() {
        let b = VoiceDeviceBinding()
        b.noteAnswerSender(callId: "c1", deviceId: "dev-a")
        b.noteAccept(callId: "c1", deviceId: "dev-b")
        XCTAssertNil(b.device(forCall: "c1"))
        XCTAssertFalse(b.isFromAnswerSender(forCall: "c1"))
    }

    func testAnAnswerWithoutTheFieldLeavesTheDeviceUnknown() {
        let b = VoiceDeviceBinding()
        b.noteAnswerSender(callId: "c1", deviceId: nil)
        b.noteAnswerSender(callId: "c1", deviceId: "")
        b.noteAccept(callId: "c1", deviceId: "dev-a")
        XCTAssertNil(b.device(forCall: "c1"))
    }

    func testAnAcceptWithoutADeviceLeavesTheDeviceUnknown() {
        let b = VoiceDeviceBinding()
        b.noteAnswerSender(callId: "c1", deviceId: "dev-a")
        b.noteAccept(callId: "c1", deviceId: nil)
        XCTAssertNil(b.device(forCall: "c1"))
    }

    func testTheAnswerDeviceOfOneCallNeverReachesTheNextCallOfTheSamePeer() {
        let b = VoiceDeviceBinding()
        b.noteAnswerSender(callId: "c1", deviceId: "dev-a")
        b.noteAccept(callId: "c1", deviceId: "dev-a")
        XCTAssertEqual(b.device(forCall: "c1"), "dev-a")
        b.clear(callId: "c1")
        b.noteAccept(callId: "c2", deviceId: "dev-a")
        XCTAssertNil(b.device(forCall: "c2"), "the new call has no answer of its own")
        XCTAssertNil(b.device(forCall: "c1"))
        let stillThere = VoiceDeviceBinding()
        stillThere.noteAnswerSender(callId: "c1", deviceId: "dev-a")
        stillThere.noteAccept(callId: "c2", deviceId: "dev-a")
        XCTAssertNil(stillThere.device(forCall: "c2"), "keyed by call id, never by peer")
    }

    func testTheIdentityCheckDeviceOfAnIncomingCallIsUnchanged() {
        let b = VoiceDeviceBinding()
        b.bind(callId: "c1", deviceId: "dev-a")
        b.noteAnswerSender(callId: "c1", deviceId: "dev-b")
        XCTAssertEqual(b.device(forCall: "c1"), "dev-a")
        XCTAssertFalse(b.isFromAnswerSender(forCall: "c1"))
    }

    // MARK: the pin row

    func testADeviceLessRowOnlyIsTierZero() throws {
        let auth = CallIdentityAuth.authenticated(callId: callId, key: key)
        XCTAssertEqual(try tier(nil, device: "dev-a", auth: auth, start: t0 + 100 * hour), 0)
        XCTAssertEqual(try tier(nil, device: nil, auth: auth, start: t0 + 100 * hour), 0)
    }

    func testARowForThatDeviceWithTheVerifiedKeyAndOldEnoughGivesTheTierOfTheInputs() throws {
        let auth = CallIdentityAuth.authenticated(callId: callId, key: key)
        let kept = VoiceTierInputs.rowForAnsweredDevice(row(key: key, pinnedAt: t0), auth: auth, callId: callId.uppercased())
        XCTAssertNotNil(kept)
        XCTAssertGreaterThanOrEqual(try tier(kept, device: "dev-a", auth: auth, start: t0 + 25 * hour), 1)
        XCTAssertEqual(try tier(kept, device: "dev-a", auth: auth, start: t0 + hour), 0, "control: younger than 24 hours")
    }

    func testARowWithAnotherKeyIsTierZeroAndTheIdentityVerdictIsNotTouched() throws {
        let auth = CallIdentityAuth.authenticated(callId: callId, key: key)
        let before = auth
        let kept = VoiceTierInputs.rowForAnsweredDevice(row(key: otherKey, pinnedAt: t0), auth: auth, callId: callId)
        XCTAssertNil(kept)
        XCTAssertEqual(try tier(kept, device: "dev-a", auth: auth, start: t0 + 100 * hour), 0)
        XCTAssertEqual(auth, before)
    }

    func testARowCountsOnlyWhileThisCallHasAVerifiedKey() {
        let r = row(key: key, pinnedAt: t0)
        XCTAssertNil(VoiceTierInputs.rowForAnsweredDevice(r, auth: .pending, callId: callId))
        XCTAssertNil(VoiceTierInputs.rowForAnsweredDevice(r, auth: .noIdentity(callId: callId), callId: callId))
        XCTAssertNil(VoiceTierInputs.rowForAnsweredDevice(
            r, auth: .authenticated(callId: "99999999-2222-3333-4444-555555555555", key: key), callId: callId))
        XCTAssertNil(VoiceTierInputs.rowForAnsweredDevice(nil, auth: .authenticated(callId: callId, key: key), callId: callId))
    }

    // MARK: the app

    func testTheAppFeedsTheAnswerDeviceOnlyToTheVoiceBindingAndNeverToTheIdentityStash() throws {
        let app = try VoiceTierInputsTests.source("QAudionApp/AppState.swift")
        XCTAssertTrue(app.contains("self.voiceDeviceBinding.noteAnswerSender(callId: bound, deviceId: answerSenderDeviceId)"))
        XCTAssertFalse(app.contains("senderDeviceIdByCallId[bound] = "), "the identity check keeps reading only the call_incoming stash")
        XCTAssertTrue(app.contains("trust = VoiceTierInputs.rowForAnsweredDevice(trust, auth: auth, callId: call.callId)"))
    }
}
