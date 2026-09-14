import XCTest
@testable import QAudionEngine

#if canImport(WebRTC)
final class PqcRtpFrameSealerTests: XCTestCase {

    func testRoundTripPlaintext() throws {
        let key = Data(repeating: 0x42, count: 32)
        let sealer = try PqcRtpFrameSealer(pqcSessionKey: key)
        // Receiver uses a fresh sealer (counter starts at 0 on the
        // RX side too — every incoming wire carries its own nonce).
        let receiver = try PqcRtpFrameSealer(pqcSessionKey: key)
        let pt = Data("hello pqc rtp".utf8)
        let wire = try sealer.seal(pt)
        XCTAssertEqual(wire.count, pt.count + 12 + 16)
        let opened = try receiver.open(wire)
        XCTAssertEqual(opened, pt)
    }

    func testRejectsWrongKeyLength() {
        XCTAssertThrowsError(try PqcRtpFrameSealer(pqcSessionKey: Data(repeating: 0x01, count: 16)))
    }

    func testTamperedTagFailsOpen() throws {
        let key = Data(repeating: 0x42, count: 32)
        let sealer = try PqcRtpFrameSealer(pqcSessionKey: key)
        let receiver = try PqcRtpFrameSealer(pqcSessionKey: key)
        var wire = try sealer.seal(Data("voice".utf8))
        // Flip a bit in the tag (last byte).
        let last = wire.endIndex - 1
        wire[last] ^= 0xFF
        XCTAssertThrowsError(try receiver.open(wire))
    }

    func testCounterAdvancesPerFrame() throws {
        let key = Data(repeating: 0x42, count: 32)
        let sealer = try PqcRtpFrameSealer(pqcSessionKey: key)
        let w1 = try sealer.seal(Data([0x01]))
        let w2 = try sealer.seal(Data([0x01]))
        // Same plaintext but different nonce → different ciphertext.
        XCTAssertNotEqual(w1, w2)
        // First 4 bytes of nonce always 0; last 8 bytes are the counter.
        let n1 = w1.prefix(12)
        let n2 = w2.prefix(12)
        XCTAssertNotEqual(n1, n2)
    }

    func testTwoSealersDifferentKeysDontInterop() throws {
        let s1 = try PqcRtpFrameSealer(pqcSessionKey: Data(repeating: 0x01, count: 32))
        let s2 = try PqcRtpFrameSealer(pqcSessionKey: Data(repeating: 0x02, count: 32))
        let wire = try s1.seal(Data("x".utf8))
        XCTAssertThrowsError(try s2.open(wire))
    }

    func testTruncatedFrameRejected() throws {
        let key = Data(repeating: 0x42, count: 32)
        let receiver = try PqcRtpFrameSealer(pqcSessionKey: key)
        XCTAssertThrowsError(try receiver.open(Data([0x01, 0x02, 0x03])))
    }

    // MARK: - M-15 callId binding

    /// Two sealers with the same key AND the same callId interop correctly.
    func testSameCallIdInterop() throws {
        let key = Data(repeating: 0x42, count: 32)
        let sealer   = try PqcRtpFrameSealer(pqcSessionKey: key, callId: "call-A")
        let receiver = try PqcRtpFrameSealer(pqcSessionKey: key, callId: "call-A")
        let pt = Data("pqc callid bound".utf8)
        XCTAssertEqual(try receiver.open(try sealer.seal(pt)), pt)
    }

    /// Two sealers with the same key but DIFFERENT callIds derive different
    /// master keys and cannot open each other's frames.
    func testDifferentCallIdsDontInterop() throws {
        let key = Data(repeating: 0x42, count: 32)
        let sealer   = try PqcRtpFrameSealer(pqcSessionKey: key, callId: "call-A")
        let receiver = try PqcRtpFrameSealer(pqcSessionKey: key, callId: "call-B")
        let wire = try sealer.seal(Data("x".utf8))
        XCTAssertThrowsError(try receiver.open(wire))
    }

    /// makeSibling inherits the callId so a send/recv pair on the same
    /// session can interop regardless of which direction installs the sealer.
    func testMakeSiblingSharesCallId() throws {
        let key = Data(repeating: 0x42, count: 32)
        let send = try PqcRtpFrameSealer(pqcSessionKey: key, callId: "call-C")
        let recv = send.makeSibling()
        let pt = Data("sibling callid".utf8)
        XCTAssertEqual(try recv.open(try send.seal(pt)), pt)
    }

    // MARK: - W574x directional per-direction keys (nonce-reuse fix)

    private static let katKey = Data((1...32).map { UInt8($0) })

    func testDirectionalFullDuplexInterop() throws {
        let key = Self.katKey
        let (aSend, aRecv) = try PqcRtpFrameSealer.createDirectional(pqcSessionKey: key, callId: "call-Z", selfIsRoleA: true)
        let (bSend, bRecv) = try PqcRtpFrameSealer.createDirectional(pqcSessionKey: key, callId: "call-Z", selfIsRoleA: false)
        let a2b = Data("A says hi".utf8)
        let b2a = Data("B replies".utf8)
        XCTAssertEqual(try bRecv.open(try aSend.seal(a2b)), a2b)
        XCTAssertEqual(try aRecv.open(try bSend.seal(b2a)), b2a)
    }

    func testDirectionalEliminatesCrossDirectionReuse() throws {
        let key = Self.katKey
        let (aSend, _) = try PqcRtpFrameSealer.createDirectional(pqcSessionKey: key, callId: "call-Z", selfIsRoleA: true)
        let (bSend, _) = try PqcRtpFrameSealer.createDirectional(pqcSessionKey: key, callId: "call-Z", selfIsRoleA: false)
        let pt = Data(repeating: 0x5A, count: 64)
        let wa = try aSend.seal(pt)   // A→B frame#0, nonce all-zero
        let wb = try bSend.seal(pt)   // B→A frame#0, nonce all-zero (same nonce)
        XCTAssertEqual(wa.prefix(12), wb.prefix(12))             // same nonce
        XCTAssertNotEqual(Data(wa.dropFirst(12)), Data(wb.dropFirst(12)))  // different keystream
        // Regression guard: legacy single-key path reuses (identical = the bug).
        let la = try PqcRtpFrameSealer(pqcSessionKey: key, callId: "call-Z")
        let lb = try PqcRtpFrameSealer(pqcSessionKey: key, callId: "call-Z")
        XCTAssertEqual(try la.seal(pt), try lb.seal(pt))
    }

    func testRoleAssignmentDeterministicAndOpposite() {
        let u1 = "00000000-0000-0000-0000-000000000001"
        let u2 = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        XCTAssertTrue(PqcRtpFrameSealer.selfIsRoleA(u1, u2))
        XCTAssertFalse(PqcRtpFrameSealer.selfIsRoleA(u2, u1))
        XCTAssertTrue(PqcRtpFrameSealer.selfIsRoleA("ABC", "abd"))
    }

    /// Cross-platform KAT — MUST be byte-identical with Android + Desktop.
    /// key=01..20, callId="kat-call-0001", pt="Q-Audion KAT", counter 0.
    func testDirectionalKatVectorsMatchAndroidDesktop() throws {
        let key = Self.katKey
        let pt = Data("Q-Audion KAT".utf8)
        let (aSend, _) = try PqcRtpFrameSealer.createDirectional(pqcSessionKey: key, callId: "kat-call-0001", selfIsRoleA: true)
        let (bSend, _) = try PqcRtpFrameSealer.createDirectional(pqcSessionKey: key, callId: "kat-call-0001", selfIsRoleA: false)
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        let a2b = "00000000000000000000000030d6c7633758e2cff105afa141bcb8d24c7d93aee95bcf0a59ecce03"
        let b2a = "000000000000000000000000a7f59b5828fd5432b3ddc906024884b1edf0a9c5b3558eed8f223602"
        XCTAssertEqual(hex(try aSend.seal(pt)), a2b, "A2B KAT must match Android/Desktop")
        XCTAssertEqual(hex(try bSend.seal(pt)), b2a, "B2A KAT must match Android/Desktop")
    }

    // MARK: - M-14 anti-replay window (W-VNACK-REPLAY, 2026-08-24)
    //
    // Previously untested on iOS. These pin the CURRENT replayWindowSize
    // (1024) behaviourally rather than by literal value, so a future width
    // change doesn't silently break these — they only assume "wide enough to
    // hold 900 frames, narrow enough that 1100 exceeds it", which holds for
    // both the pre-fix 512 and the current 1024.

    /// A sealed frame opened a second time (byte-identical replay) is rejected.
    func testReplayRejectsExactDuplicate() throws {
        let key = Data(repeating: 0x42, count: 32)
        let sealer = try PqcRtpFrameSealer(pqcSessionKey: key)
        let receiver = try PqcRtpFrameSealer(pqcSessionKey: key)
        let wire = try sealer.seal(Data("voice".utf8))
        XCTAssertNoThrow(try receiver.open(wire))
        XCTAssertThrowsError(try receiver.open(wire), "byte-identical replay must be rejected")
    }

    /// The direct regression guard for the bug this window widening fixes:
    /// a frame legitimately recovered by NACK long after it was originally
    /// sent (here, ~900 frames behind the highest counter already seen) must
    /// still be accepted, not false-positive-rejected as a replay.
    func testReplayAcceptsFrameRecoveredHundredsOfPositionsLate() throws {
        let key = Data(repeating: 0x42, count: 32)
        let sealer = try PqcRtpFrameSealer(pqcSessionKey: key)
        let receiver = try PqcRtpFrameSealer(pqcSessionKey: key)
        // Frame #0 is the one that will arrive "late" (simulating a NACK
        // round trip recovering it long after it was first sent).
        let lateFrame = try sealer.seal(Data("recovered-by-nack".utf8))
        // Advance the sender's counter to ~900 by sealing filler frames, then
        // open the newest one on the receiver first — this is what actually
        // advances replayHighest, exactly as an out-of-order/late-arriving
        // network would.
        var newest: Data = lateFrame
        for _ in 0..<900 { newest = try sealer.seal(Data("filler".utf8)) }
        XCTAssertNoThrow(try receiver.open(newest), "precondition: advancing receiver's replayHighest to ~900")
        XCTAssertNoThrow(
            try receiver.open(lateFrame),
            "a frame ~900 positions behind the highest counter seen must still be accepted — this is the exact scenario a NACK-recovered fragment hits, and the bug this window widening fixes"
        )
    }

    /// A frame old enough to exceed the window (not just old — genuinely too
    /// old) is still correctly rejected. The window widening must not have
    /// turned this into "accept everything".
    func testReplayRejectsFrameOlderThanWindow() throws {
        let key = Data(repeating: 0x42, count: 32)
        let sealer = try PqcRtpFrameSealer(pqcSessionKey: key)
        let receiver = try PqcRtpFrameSealer(pqcSessionKey: key)
        let tooOldFrame = try sealer.seal(Data("ancient".utf8))
        var newest: Data = tooOldFrame
        // 1100 exceeds every window size this fix has ever used (512 or
        // 1024) — the point is confirming REJECTION still happens somewhere,
        // not pinning the exact boundary.
        for _ in 0..<1100 { newest = try sealer.seal(Data("filler".utf8)) }
        XCTAssertNoThrow(try receiver.open(newest), "precondition: advance receiver's replayHighest")
        XCTAssertThrowsError(
            try receiver.open(tooOldFrame),
            "a frame far older than the window must still be rejected — widening the window must not disable the anti-replay check"
        )
    }

    /// Once the window has fully slid past a given counter (a fresh frame
    /// pushed it out), a REPLAY of that same counter must still be rejected
    /// as too old — not accepted just because it was legitimately seen once
    /// before. Confirms the shift-based design still closes correctly at the
    /// current window size.
    func testReplayOfNowExpiredCounterStillRejected() throws {
        let key = Data(repeating: 0x42, count: 32)
        let sealer = try PqcRtpFrameSealer(pqcSessionKey: key)
        let receiver = try PqcRtpFrameSealer(pqcSessionKey: key)
        let firstFrame = try sealer.seal(Data("first".utf8))
        XCTAssertNoThrow(try receiver.open(firstFrame))
        var newest: Data = firstFrame
        // 1100 pushes counter 0 out of even the widened 1024-slot window.
        for _ in 0..<1100 { newest = try sealer.seal(Data("filler".utf8)) }
        XCTAssertNoThrow(try receiver.open(newest))
        XCTAssertThrowsError(
            try receiver.open(firstFrame),
            "replaying a counter whose window slot has since expired must be rejected as too old, not accepted"
        )
    }
}
#endif
