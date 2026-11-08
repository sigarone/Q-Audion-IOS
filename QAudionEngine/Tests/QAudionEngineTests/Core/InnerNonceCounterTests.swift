import XCTest
@testable import QAudionEngine

/// The legacy (static key, no AAD) inner seal of the adaptive path: ONE send counter per call, never reset by an `initSession`
/// (rekey, revert to an earlier key), feeding the wire seq (its low 32 bits) and the GCM nonce
/// `dirTag || 0 0 0 || BE64(ctr)`. The inner nonce vectors of the shared known-answer file are run in PqcHardeningV1KatTests.
final class InnerNonceCounterTests: XCTestCase {

    private let secret1 = Data(repeating: 0x11, count: 32)
    private let secret2 = Data(repeating: 0x22, count: 32)

    private var oneFrame: Data { Data(count: AudioProfile.defaultProfile.bytesPerFrame) }

    private func engine(caller: Bool?, secret: Data? = nil) throws -> QAudionEngine {
        let e = QAudionEngine(config: .development())
        try e.initialize()
        try e.initSession(sharedSecret: secret ?? secret1, adaptivePadding: true, selfIsCaller: caller)
        return e
    }

    private func frame(_ wire: Data) throws -> EncryptedFrame {
        try FrameEncoder.deserialize(wire)
    }

    private func counterOfNonce(_ nonce: Data) -> UInt64 {
        var v: UInt64 = 0
        for i in 4..<12 { v = (v << 8) | UInt64(nonce[nonce.startIndex + i]) }
        return v
    }

    func testFirstFrameCarriesCounterOneAndTheRolePrefix() throws {
        for (caller, tag) in [(true, UInt8(0x01)), (false, UInt8(0x02))] {
            let e = try engine(caller: caller)
            let f = try frame(try e.processOutgoingAudio(pcmFrame: oneFrame))
            XCTAssertEqual(f.sequenceNumber, 1)
            XCTAssertEqual(f.nonce, QAudionEngine.innerNonce(dirTag: tag, ctr: 1))
            XCTAssertEqual(Array(f.nonce.prefix(4)), [tag, 0, 0, 0])
            XCTAssertEqual(counterOfNonce(f.nonce), 1)
        }
    }

    func testTheCounterSurvivesARekeyAndARevert() throws {
        let e = try engine(caller: true, secret: secret1)
        var seen = Set<Data>()
        var last: UInt64 = 0
        func seal(_ n: Int) throws {
            for _ in 0..<n {
                let f = try frame(try e.processOutgoingAudio(pcmFrame: oneFrame))
                let ctr = counterOfNonce(f.nonce)
                XCTAssertEqual(ctr, last + 1)
                XCTAssertEqual(f.sequenceNumber, UInt32(truncatingIfNeeded: ctr))
                XCTAssertTrue(seen.insert(f.nonce).inserted, "nonce repeated at \(ctr)")
                last = ctr
            }
        }
        try seal(3)
        // Rekey: a new key, the same call. The counter does not restart.
        try e.initSession(sharedSecret: secret2, adaptivePadding: true, selfIsCaller: true)
        try seal(2)
        // Revert to the earlier key: still no restart, so no nonce is repeated under it either.
        try e.initSession(sharedSecret: secret1, adaptivePadding: true, selfIsCaller: true)
        try seal(2)
        XCTAssertEqual(last, 7)
    }

    func testANewCallStartsAtOneAgain() throws {
        let e = try engine(caller: true)
        _ = try e.processOutgoingAudio(pcmFrame: oneFrame)
        _ = try e.processOutgoingAudio(pcmFrame: oneFrame)
        try e.initialize()
        try e.initSession(sharedSecret: secret1, adaptivePadding: true, selfIsCaller: true)
        let f = try frame(try e.processOutgoingAudio(pcmFrame: oneFrame))
        XCTAssertEqual(counterOfNonce(f.nonce), 1)
    }

    func testCallerAndCalleeUnderOneKeyNeverShareANonceAndStillInteroperate() throws {
        let caller = try engine(caller: true)
        let callee = try engine(caller: false)
        let a = try caller.processOutgoingAudio(pcmFrame: oneFrame)
        let b = try callee.processOutgoingAudio(pcmFrame: oneFrame)
        XCTAssertNotEqual(try frame(a).nonce, try frame(b).nonce)
        XCTAssertNoThrow(try callee.processIncomingAudio(serializedFrame: a))
        XCTAssertNoThrow(try caller.processIncomingAudio(serializedFrame: b))
    }

    func testAnUnknownRoleKeepsTheRandomNonceButTheSameCounter() throws {
        let e = try engine(caller: nil)
        let f1 = try frame(try e.processOutgoingAudio(pcmFrame: oneFrame))
        let f2 = try frame(try e.processOutgoingAudio(pcmFrame: oneFrame))
        XCTAssertEqual(f1.sequenceNumber, 1)
        XCTAssertEqual(f2.sequenceNumber, 2)
        XCTAssertNotEqual(f1.nonce, f2.nonce)
    }

    func testTheWireSeqIsTheLowHalfAndTheNonceCarriesTheWholeCounter() throws {
        let e = try engine(caller: true)
        e.txInnerCtr = UInt64(UInt32.max)   // the next frame is counter 2^32
        let f = try frame(try e.processOutgoingAudio(pcmFrame: oneFrame))
        XCTAssertEqual(f.sequenceNumber, 0)
        XCTAssertEqual(counterOfNonce(f.nonce), UInt64(1) << 32)
    }

    func testTheSenderStopsBeforeTheLimit() throws {
        let e = try engine(caller: true)
        // The last counter that may be used is 2^63 - 2.
        e.txInnerCtr = QAudionEngine.innerCtrLimit - 2
        XCTAssertNoThrow(try e.processOutgoingAudio(pcmFrame: oneFrame))
        XCTAssertThrowsError(try e.processOutgoingAudio(pcmFrame: oneFrame)) { error in
            guard case QAudionEngineError.txSequenceExhausted = error else { return XCTFail("\(error)") }
        }
    }

    func testAnExplicitNonceIsUsedAsGiven() throws {
        let key = Data(repeating: 0x33, count: 32)
        let nonce = Data([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9])
        let out = try AeadCipher().encrypt(plaintext: Data([1, 2, 3]), key: key, nonce: nonce, associatedData: nil)
        XCTAssertEqual(out.nonce, nonce)
        XCTAssertEqual(try AeadCipher().decrypt(cipherOutput: out, key: key), Data([1, 2, 3]))
        XCTAssertThrowsError(try AeadCipher().encrypt(plaintext: Data([1]), key: key, nonce: Data([1, 2, 3]), associatedData: nil))
    }
}
