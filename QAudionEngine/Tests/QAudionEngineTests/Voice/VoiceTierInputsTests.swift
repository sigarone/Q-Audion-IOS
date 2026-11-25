import XCTest
import Foundation
@testable import QAudionEngine

/// The tier inputs of a call, built from the exact (peer, device) pin and the call, on top of the tier function (KAT stage 12).
/// The review cases: the second call of a brand-new ML-DSA device, a SAS-confirmed device, a legacy row, a re-pinned
/// key, and a call whose own device is missing. No clock and no timer: every time is a number.
final class VoiceTierInputsTests: XCTestCase {
    private let hour: Int64 = 3_600
    private let t0: Int64 = 1_800_000_000
    private let callId = "11111111-2222-3333-4444-555555555555"
    private let key = Data(repeating: 7, count: 32)
    private let device = "device-1"

    /// A call whose protection line says `auth=H` and `pin=ok`: the best a call can be.
    private func line(auth: String = "H", pin: String = "ok", call: String? = nil) -> CallPqProtection {
        CallPqProtection(levelToken: "PQ2", auth: auth, pin: pin, callId: call ?? callId)
    }

    private func trust(pinnedAt: Int64?, oob: Bool = false, pending: Bool = false, key: Data? = nil) -> VoiceTierTrust {
        VoiceTierTrust(pinnedKey: key ?? self.key, pinnedAtS: pinnedAt, pendingChange: pending, oobVerified: oob)
    }

    private func input(
        _ t: VoiceTierTrust?, device: String? = "device-1", start: Int64, auth: CallIdentityAuth? = nil,
        protection: CallPqProtection? = nil, kcmacOk: Bool = true
    ) -> VoiceTierInput? {
        VoiceTierInputs.build(
            callId: callId, peerDeviceId: device, trust: t, auth: auth ?? .authenticated(callId: callId, key: key),
            protection: protection ?? line(), kcmacOk: kcmacOk, callStartS: start)
    }

    private func tier(
        _ t: VoiceTierTrust?, device: String? = "device-1", start: Int64, auth: CallIdentityAuth? = nil,
        protection: CallPqProtection? = nil, kcmacOk: Bool = true
    ) throws -> Int {
        VoiceTier.tier(try XCTUnwrap(input(t, device: device, start: start, auth: auth, protection: protection, kcmacOk: kcmacOk)))
    }

    func testTheSecondCallOfABrandNewMlDsaDeviceWithin24HoursIsTierZeroHoweverStrongTheWordsAre() throws {
        // The first call pinned the device now; the PQ policy pinned its ML-DSA key too, so the second call reads auth=H pin=ok.
        let pinned = trust(pinnedAt: t0)
        XCTAssertEqual(try tier(pinned, start: t0), 0, "the first call itself")
        XCTAssertEqual(try tier(pinned, start: t0 + 23 * hour), 0, "the second call, 23 hours later")
        XCTAssertEqual(try tier(pinned, start: t0 + 25 * hour), 1, "control: the key older than 24 hours is tier 1")
    }

    func testASasConfirmedDeviceWithin24HoursIsTierZeroAndTheSasNeverMakesTheKeyOlderOrOutOfBand() throws {
        // The in-call SAS re-pins (the pinned-at time is now) and marks the contact verified with the method anti-replay.
        let sas = trust(pinnedAt: t0, oob: VoiceTierInputs.isOutOfBand(method: "anti-replay"))
        XCTAssertEqual(try tier(sas, start: t0 + hour), 0)
        XCTAssertEqual(try tier(sas, start: t0 + 25 * hour), 1, "a day later it is a plain tier 1 call: the in-call SAS is not out of band")
        XCTAssertFalse(VoiceTierInputs.isOutOfBand(method: "voice"))
    }

    func testOnlyInPersonQrAndNfcAreOutOfBandAndAMissingOrUnknownMethodIsNot() {
        for m in ["in-person", "qr", "nfc"] { XCTAssertTrue(VoiceTierInputs.isOutOfBand(method: m), m) }
        for m in ["anti-replay", "voice", "manual", "", "QR"] { XCTAssertFalse(VoiceTierInputs.isOutOfBand(method: m), m) }
        XCTAssertFalse(VoiceTierInputs.isOutOfBand(method: nil))
    }

    func testAnOutOfBandVerifiedKeyIsTierTwoOnlyOnceItIsOlderThan24Hours() throws {
        let r = trust(pinnedAt: t0, oob: true)
        XCTAssertEqual(try tier(r, start: t0 + hour), 0)
        XCTAssertEqual(try tier(r, start: t0 + 25 * hour), 2)
    }

    func testTheAgeIsMeasuredToTheStartOfTheCallAndRoundsTowardZeroSeconds() throws {
        let i = try XCTUnwrap(input(trust(pinnedAt: t0), start: t0 + 23 * hour + 59 * 60))
        XCTAssertEqual(i.keyAgeS, 23 * 3_600 + 59 * 60)
        XCTAssertEqual(VoiceTier.tier(i), 0)
        let exactly = try XCTUnwrap(input(trust(pinnedAt: t0), start: t0 + 24 * hour))
        XCTAssertEqual(exactly.keyAgeS, 86_400)
        XCTAssertEqual(VoiceTier.tier(exactly), 1, "24 h is old enough")
        XCTAssertEqual(try tier(trust(pinnedAt: t0), start: t0 + 24 * hour - 1), 0)
    }

    func testALegacyRowOrAMissingDeviceIdIsTierZero() throws {
        let old = t0 - 400 * 24 * hour
        XCTAssertEqual(try tier(trust(pinnedAt: old), device: nil, start: t0), 0, "no device id")
        XCTAssertEqual(try tier(trust(pinnedAt: old), device: "", start: t0), 0, "an empty device id")
        XCTAssertEqual(try tier(trust(pinnedAt: old), device: "  ", start: t0), 0, "a blank device id")
        XCTAssertEqual(try tier(nil, start: t0), 0, "a device that has no pin of its own (only the legacy one exists)")
        XCTAssertTrue(try XCTUnwrap(input(nil, start: t0)).viaLegacyRow)
        XCTAssertTrue(try XCTUnwrap(input(trust(pinnedAt: old), device: nil, start: t0)).viaLegacyRow)
        XCTAssertFalse(try XCTUnwrap(input(trust(pinnedAt: old), start: t0)).viaLegacyRow)
        XCTAssertEqual(try XCTUnwrap(input(nil, start: t0)).pinState, .unpinned)
    }

    func testAKeyWhoseAgeIsUnknownIsTierZero() throws {
        let i = try XCTUnwrap(input(trust(pinnedAt: nil, oob: true), start: t0))
        XCTAssertEqual(i.keyAgeS, -1)
        XCTAssertEqual(VoiceTier.tier(i), 0)
    }

    func testAReplacedKeyStartsItsOwn24Hours() throws {
        // The key was pinned a year ago and replaced two hours before the call: the pin holds the time of the replacement.
        XCTAssertEqual(try tier(trust(pinnedAt: t0 - 2 * hour), start: t0), 0)
        XCTAssertEqual(try tier(trust(pinnedAt: t0 - 2 * hour), start: t0 + 23 * hour), 1)
    }

    func testAKeyPinnedAfterTheCallStartedIsTierZero() throws {
        XCTAssertEqual(try tier(trust(pinnedAt: t0 + 5 * hour), start: t0), 0)
    }

    func testAPendingChangeAHoldAnAnomalyAMissingMacOrNoAuthWordAreEachTierZero() throws {
        let aged = trust(pinnedAt: t0 - 100 * hour)
        XCTAssertEqual(try tier(aged, start: t0), 1, "control")
        let pending = trust(pinnedAt: t0 - 100 * hour, pending: true)
        XCTAssertEqual(try XCTUnwrap(input(pending, start: t0)).pinState, .identityChanged)
        XCTAssertEqual(try tier(pending, start: t0), 0)
        let held: CallIdentityAuth = .held(
            callId: callId, code: IdentityShieldRules.codeIdentityUnresolved, releasedAdopted: false, signerKey: key)
        let heldInput = try XCTUnwrap(input(aged, start: t0, auth: held))
        XCTAssertEqual(heldInput.pinState, .unresolved)
        XCTAssertTrue(heldInput.heldUnresolved)
        XCTAssertEqual(VoiceTier.tier(heldInput), 0)
        XCTAssertEqual(try tier(aged, start: t0, protection: line(pin: "anomaly")), 0)
        XCTAssertEqual(try tier(aged, start: t0, kcmacOk: false), 0)
        XCTAssertEqual(try tier(aged, start: t0, protection: line(auth: "-")), 0)
        XCTAssertEqual(try XCTUnwrap(input(aged, start: t0, protection: line(auth: "-"))).authWord, .noWord)
        XCTAssertEqual(try tier(aged, start: t0, protection: line(auth: "C")), 1, "a classical call learns: PQC is preferred, never required")
    }

    func testAKeyOtherThanThePinOrAnIdentityThatIsNotAuthenticatedIsTierZero() throws {
        let aged = trust(pinnedAt: t0 - 100 * hour)
        let other = Data(repeating: 9, count: 32)
        XCTAssertEqual(try tier(aged, start: t0, auth: .authenticated(callId: callId, key: other)), 0)
        XCTAssertEqual(try tier(aged, start: t0, auth: .lost(callId: callId)), 0)
        XCTAssertEqual(try tier(aged, start: t0, auth: .pending), 0)
        XCTAssertEqual(try tier(aged, start: t0, auth: .noIdentity(callId: callId)), 0)
        let otherCall: CallIdentityAuth = .authenticated(callId: "99999999-2222-3333-4444-555555555555", key: key)
        XCTAssertEqual(try tier(aged, start: t0, auth: otherCall), 0, "an identity verdict of another call is never read")
        let mismatch: CallIdentityAuth = .held(
            callId: callId, code: IdentityShieldRules.codeKeyMismatch, releasedAdopted: false, signerKey: other)
        XCTAssertEqual(try tier(aged, start: t0, auth: mismatch), 0)
        let adopted: CallIdentityAuth = .held(
            callId: callId, code: IdentityShieldRules.codeIdentityUnresolved, releasedAdopted: true, signerKey: key)
        XCTAssertEqual(try tier(aged, start: t0, auth: adopted), 0)
    }

    func testThereIsNoMomentUntilThisCallHasItsOwnProtectionLine() {
        XCTAssertNil(input(trust(pinnedAt: t0), start: t0, protection: line(call: "99999999-2222-3333-4444-555555555555")))
        XCTAssertNil(VoiceTierInputs.build(
            callId: callId, peerDeviceId: device, trust: trust(pinnedAt: t0), auth: .authenticated(callId: callId, key: key),
            protection: nil, kcmacOk: true, callStartS: t0))
    }

    func testAnOutgoingCallAnsweredWithoutADeviceIdAfterACallWithADeviceIsTierZero() throws {
        // Call 1 was incoming and stamped its device; call 2 is outgoing and nothing stamped it. The stash is keyed by call id.
        let stash = ["call-1": "device-1"]
        let old = trust(pinnedAt: t0 - 100 * hour) // the pin of the device of call 1, long old: tier 1 for call 1
        let first = VoiceTierInputs.peerDeviceId(forCall: "CALL-1", callScopedStash: stash)
        XCTAssertEqual(first, "device-1")
        XCTAssertEqual(try tier(old, device: first, start: t0), 1)
        let second = VoiceTierInputs.peerDeviceId(forCall: "call-2", callScopedStash: stash)
        XCTAssertNil(second, "nothing is borrowed from the call before")
        XCTAssertEqual(try tier(old, device: second, start: t0), 0)
        XCTAssertNil(VoiceTierInputs.peerDeviceId(forCall: "", callScopedStash: ["": "device-1"]))
        XCTAssertNil(VoiceTierInputs.peerDeviceId(forCall: "call-3", callScopedStash: ["call-3": " "]), "a blank id is no device")
    }

    func testTheBindingOfASessionIsFixedForItsCallAndTheNextSessionStartsFromItsOwn() {
        let first = VoiceCallBinding(callId: "c1", contactId: "p", peerDeviceId: "device-1", tStartS: 1, utcOffsetS: 0)
        let second = VoiceCallBinding(callId: "c2", contactId: "p", peerDeviceId: nil, tStartS: 2, utcOffsetS: 0)
        XCTAssertEqual(first.peerDeviceId, "device-1")
        XCTAssertNil(second.peerDeviceId)
    }

    func testTheAppReadsTheDeviceOfTheCallOnlyFromTheStashOfThatCall() throws {
        let app = try Self.source("QAudionApp/AppState.swift")
        let start = try XCTUnwrap(app.range(of: "private func startVoiceCheckForThisCall() {"))
        let end = try XCTUnwrap(app.range(of: "private struct VoiceTierCall {", range: start.upperBound..<app.endIndex))
        let body = String(app[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("VoiceTierInputs.peerDeviceId(forCall: callId, callScopedStash: senderDeviceIdByCallId)"))
        XCTAssertFalse(body.contains("callPinDeviceId"), "that reads the peer-keyed value when no call id is bound")
        XCTAssertFalse(body.contains("peerDeviceId(for:"), "never the peer-keyed value that an earlier call may have left")
    }

    static func source(_ relative: String, file: StaticString = #filePath) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return try String(contentsOf: candidate, encoding: .utf8) }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
