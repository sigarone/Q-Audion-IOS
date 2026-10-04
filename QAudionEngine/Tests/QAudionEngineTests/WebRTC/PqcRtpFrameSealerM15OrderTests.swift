import XCTest
@testable import QAudionEngine

/// W-M15ORDER (2026-10-03) — the receive side of the M-15 relay seal must follow RFC 3711 order:
/// read-only replay check, AES-GCM authentication, and only then record the counter. Three live
/// calls (28/9, 28/9 and 3/10): the caller's first mic frame left before its send sealer was
/// installed, the callee's open() recorded the counter it read from that
/// unsealed frame's (random) inner-nonce bytes BEFORE the tag was checked, and every genuine sealed
/// frame after it was "too old" for the rest of the call (callee heard nothing, caller decoded
/// everything).
final class PqcRtpFrameSealerM15OrderTests: XCTestCase {

    private static let key = Data((1...32).map { UInt8($0) })
    private static let callId = "call-m15-order"

    /// A directional pair as the two real ends build it: `a` is role A, `b` is role B.
    private func pair() throws -> (a: (send: PqcRtpFrameSealer, recv: PqcRtpFrameSealer),
                                   b: (send: PqcRtpFrameSealer, recv: PqcRtpFrameSealer)) {
        let a = try PqcRtpFrameSealer.createDirectional(
            pqcSessionKey: Self.key, callId: Self.callId, selfIsRoleA: true)
        let b = try PqcRtpFrameSealer.createDirectional(
            pqcSessionKey: Self.key, callId: Self.callId, selfIsRoleA: false)
        return (a, b)
    }

    /// What an UNSEALED relay frame looks like to the sealer: a `0x01 | nonce(12) | seq(8) | ...`
    /// audio envelope whose bytes 4..11 are the inner AES-GCM nonce (random). `counterByte` fills
    /// them so the "counter" it implies is huge and known.
    private func unsealedFrame(counterByte: UInt8, length: Int = 295) -> Data {
        var d = Data(repeating: 0x5A, count: length)
        d[d.startIndex] = 0x01
        for i in 4..<12 { d[d.startIndex + i] = counterByte }
        return d
    }

    private func sealerError(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line)
        -> PqcRtpFrameSealer.SealerError? {
        do {
            try body()
            XCTFail("expected a SealerError, got success", file: file, line: line)
            return nil
        } catch {
            return error as? PqcRtpFrameSealer.SealerError
        }
    }

    // MARK: - the incident: an unsealed first frame, then sealed frames

    func testUnsealedFirstFrameThenSealedFramesAllDecode() throws {
        let (a, b) = try pair()
        // The callee's (B) receive sealer exists from ringing; the caller's (A) first frame goes out
        // unsealed (what the old sender did) and is followed by properly sealed frames.
        let unsealed = unsealedFrame(counterByte: 0x7F)
        XCTAssertThrowsError(try b.recv.open(unsealed), "an unsealed frame must be rejected")

        for i in 0..<20 {
            let pt = Data("voice frame \(i)".utf8)
            let wire = try a.send.seal(pt)
            XCTAssertEqual(try b.recv.open(wire), pt, "sealed frame \(i) must still decode after the bad one")
        }
    }

    func testGarbageFrameDoesNotAdvanceTheWindow() throws {
        let (a, b) = try pair()
        let f0 = try a.send.seal(Data("f0".utf8))
        let f1 = try a.send.seal(Data("f1".utf8))
        let f2 = try a.send.seal(Data("f2".utf8))
        XCTAssertNoThrow(try b.recv.open(f0))
        XCTAssertNoThrow(try b.recv.open(f2))
        // Garbage claiming a counter far ahead of the window.
        XCTAssertThrowsError(try b.recv.open(unsealedFrame(counterByte: 0xFF)))
        // f1 is still inside the window and was never seen: it must be accepted.
        XCTAssertEqual(try b.recv.open(f1), Data("f1".utf8),
                       "the bad frame moved the window: a late genuine frame was rejected as too old")
        // And the stream keeps going.
        XCTAssertEqual(try b.recv.open(try a.send.seal(Data("f3".utf8))), Data("f3".utf8))
    }

    func testGarbageFrameIsAnAuthenticationFailureNotAReplay() throws {
        let (_, b) = try pair()
        let err = sealerError { _ = try b.recv.open(self.unsealedFrame(counterByte: 0x11)) }
        XCTAssertEqual(err, .openFailed)
        XCTAssertEqual(err?.isReplayRejection, false)
    }

    func testTamperedFrameCostsOneFrameAndItsCounterStaysFree() throws {
        let (a, b) = try pair()
        let genuine = try a.send.seal(Data("voice".utf8))
        var tampered = genuine
        tampered[tampered.endIndex - 1] ^= 0xFF
        XCTAssertEqual(sealerError { _ = try b.recv.open(tampered) }, .openFailed)
        // The genuine frame with the SAME counter must still open: the failed attempt recorded nothing.
        XCTAssertEqual(try b.recv.open(genuine), Data("voice".utf8))
    }

    // MARK: - replay protection is intact

    func testReplayOfAValidFrameIsStillRejectedAndClassifiedAsReplay() throws {
        let (a, b) = try pair()
        let wire = try a.send.seal(Data("voice".utf8))
        XCTAssertNoThrow(try b.recv.open(wire))
        let err = sealerError { _ = try b.recv.open(wire) }
        XCTAssertEqual(err, .replayRejected)
        XCTAssertEqual(err?.isReplayRejection, true)
    }

    /// The window must remember every accepted counter below the highest, not only the highest:
    /// advancing the highest counter used to shift the record of the frames just below it out of
    /// the window, so an already-accepted older frame could be replayed and opened again.
    func testReplayOfAnOlderAcceptedFrameInsideTheWindowIsRejected() throws {
        let (a, b) = try pair()
        let frames = try (0..<4).map { try a.send.seal(Data("f\($0)".utf8)) }
        for f in frames { XCTAssertNoThrow(try b.recv.open(f)) }
        for i in [0, 1, 2] {
            XCTAssertEqual(sealerError { _ = try b.recv.open(frames[i]) }, .replayRejected,
                           "frame \(i) was accepted once and must not open a second time")
        }
    }

    /// Same, across the 64-bit word boundaries of the multi-word window and across a jump of the
    /// highest counter; a frame that never arrived stays acceptable exactly once.
    func testReplayAcrossWordBoundariesAndJumpsIsRejected() throws {
        let (a, b) = try pair()
        let frames = try (0..<300).map { try a.send.seal(Data("f\($0)".utf8)) }
        for i in 0..<200 where i != 150 { XCTAssertNoThrow(try b.recv.open(frames[i])) }
        for i in [5, 62, 63, 64, 65, 127, 128, 129, 191, 192, 199] {
            XCTAssertEqual(sealerError { _ = try b.recv.open(frames[i]) }, .replayRejected,
                           "replay of frame \(i) must be rejected")
        }
        XCTAssertEqual(try b.recv.open(frames[150]), Data("f150".utf8), "a late, never-seen frame is accepted")
        XCTAssertEqual(sealerError { _ = try b.recv.open(frames[150]) }, .replayRejected)
        // Jump the highest counter by 99 (199 -> 298), then replay below it and fill a gap.
        XCTAssertNoThrow(try b.recv.open(frames[298]))
        for i in [10, 150, 197, 198, 199] {
            XCTAssertEqual(sealerError { _ = try b.recv.open(frames[i]) }, .replayRejected,
                           "replay of frame \(i) after the jump must be rejected")
        }
        XCTAssertEqual(try b.recv.open(frames[250]), Data("f250".utf8))
        XCTAssertEqual(sealerError { _ = try b.recv.open(frames[250]) }, .replayRejected)
        XCTAssertEqual(try b.recv.open(frames[299]), Data("f299".utf8))
        XCTAssertEqual(sealerError { _ = try b.recv.open(frames[298]) }, .replayRejected)
    }

    func testFrameOlderThanTheWindowIsAReplayRejection() throws {
        let (a, b) = try pair()
        let old = try a.send.seal(Data("old".utf8))
        var newest = old
        for _ in 0..<1100 { newest = try a.send.seal(Data("filler".utf8)) }
        XCTAssertNoThrow(try b.recv.open(newest))
        XCTAssertEqual(sealerError { _ = try b.recv.open(old) }, .replayRejected)
    }

    func testTruncatedFrameIsNotAReplay() throws {
        let (_, b) = try pair()
        let err = sealerError { _ = try b.recv.open(Data([0x01, 0x02, 0x03])) }
        XCTAssertEqual(err, .truncated)
        XCTAssertEqual(err?.isReplayRejection, false)
    }

    // MARK: - two copies of one frame

    /// Both copies pass the read-only pre-check; only one may pass the atomic record. The hook runs
    /// between the tag verification and the record, exactly where a second thread's copy of the
    /// same frame can win.
    func testSecondCopyThatWinsTheRaceMakesTheFirstCopyAReplay() throws {
        let (a, b) = try pair()
        let wire = try a.send.seal(Data("voice".utf8))
        var reentered = false
        let recv = b.recv
        recv.afterAuthenticateHook = {
            guard !reentered else { return }
            reentered = true
            do {
                _ = try recv.open(wire)
            } catch {
                XCTFail("the other copy must be accepted, got \(error)")
            }
        }
        let err = sealerError { _ = try recv.open(wire) }
        XCTAssertEqual(err, .replayRejected, "the same counter must be accepted exactly once")
    }

    func testConcurrentDuplicatesAreAcceptedExactlyOnce() throws {
        let (a, b) = try pair()
        let wire = try a.send.seal(Data("voice".utf8))
        let recv = b.recv
        let lock = NSLock()
        var accepted = 0
        var replays = 0
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do {
                _ = try recv.open(wire)
                lock.lock(); accepted += 1; lock.unlock()
            } catch let e as PqcRtpFrameSealer.SealerError where e == .replayRejected {
                lock.lock(); replays += 1; lock.unlock()
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(replays, 15)
    }

    // MARK: - out-of-order delivery is unchanged

    func testOutOfOrderGenuineFramesWithinTheWindowAreAccepted() throws {
        let (a, b) = try pair()
        let frames = try (0..<10).map { try a.send.seal(Data("f\($0)".utf8)) }
        for i in [3, 1, 0, 9, 5, 2, 8, 4, 7, 6] {
            XCTAssertEqual(try b.recv.open(frames[i]), Data("f\(i)".utf8))
        }
    }
}
