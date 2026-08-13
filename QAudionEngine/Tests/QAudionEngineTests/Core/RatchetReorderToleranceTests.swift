import XCTest
@testable import QAudionEngine

/// W-RXREORDER (2026-08-13) — the iOS-native (ratchet) audio path must survive
/// frames arriving out of order.
///
/// Why this test exists, in one paragraph: audio on this path rides the sealed
/// `qaudion-audio` DataChannel, which is created UNORDERED and unreliable
/// (`QAudionPeerConnection.createAudioDataChannel`: `isOrdered = false`,
/// `maxRetransmits = 0`), and the sender additionally alternates per frame
/// between that channel and the WS relay (`CallService`
/// `sendAudioOverDataChannel` → `ws.sendAudioFrame` fallback). Two transports
/// with different latencies feeding one forward-only chain reorder frames as a
/// matter of course — guaranteed at the instant a call switches from the relay
/// to a freshly-opened P2P channel. The old RX code answered every such frame
/// with `malformedFrame("stale/duplicate")`, and because an early frame ALSO
/// fast-forwarded the chain, one reordering event discarded every frame still
/// in flight behind it, not one.
///
/// That is an iOS↔iOS-only failure: the adaptive-padding branch taken for an
/// Android peer has a static session key and no sequence dependency, so
/// reordering there costs nothing. These cases pin the difference.
final class RatchetReorderToleranceTests: XCTestCase {

    /// Two engines keyed from the same secret, as `initSession` does for a real
    /// iOS↔iOS call (`adaptivePadding: false` — the ratchet path).
    private func makePair() throws -> (tx: QAudionEngine, rx: QAudionEngine) {
        let secret = Data(repeating: 0x5A, count: 32)
        let tx = QAudionEngine()
        let rx = QAudionEngine()
        try tx.initialize()
        try rx.initialize()
        try tx.initSession(sharedSecret: secret)
        try rx.initSession(sharedSecret: secret)
        return (tx, rx)
    }

    private func pcm(_ seed: UInt8) -> Data {
        Data(repeating: seed, count: AudioConstants.bytesPerFrame)
    }

    /// The exact shape the transport produces: frame N+1 overtakes N.
    /// Before the fix the second delivery threw; now both decode.
    func testSwappedAdjacentPairBothDecode() throws {
        let (tx, rx) = try makePair()
        let first = try tx.processOutgoingAudio(pcmFrame: pcm(1))
        let second = try tx.processOutgoingAudio(pcmFrame: pcm(2))

        // Deliver out of order.
        XCTAssertNoThrow(try rx.processIncomingAudio(serializedFrame: second))
        XCTAssertNoThrow(try rx.processIncomingAudio(serializedFrame: first),
                         "a frame that merely arrived late must still open")
        XCTAssertEqual(rx.getStats().framesRxReordered, 1)
    }

    /// The collateral damage that made this audible: ONE early frame used to
    /// invalidate the whole burst queued behind it. All of them must survive.
    func testBurstBehindAnEarlyFrameIsNotLost() throws {
        let (tx, rx) = try makePair()
        var frames: [Data] = []
        for i in 0..<8 { frames.append(try tx.processOutgoingAudio(pcmFrame: pcm(UInt8(i)))) }

        // The last frame overtakes the seven before it, then they land.
        XCTAssertNoThrow(try rx.processIncomingAudio(serializedFrame: frames[7]))
        for i in 0..<7 {
            XCTAssertNoThrow(try rx.processIncomingAudio(serializedFrame: frames[i]),
                             "frame \(i) was queued behind an early one, not lost")
        }
        XCTAssertEqual(rx.getStats().framesRx, 8)
        XCTAssertEqual(rx.getStats().framesRxReordered, 7)
    }

    /// Replay protection is the property the old branch really provided, and it
    /// must survive the fix: a retained key is consumed on first use.
    func testDuplicateIsStillRejected() throws {
        let (tx, rx) = try makePair()
        let a = try tx.processOutgoingAudio(pcmFrame: pcm(1))
        let b = try tx.processOutgoingAudio(pcmFrame: pcm(2))

        XCTAssertNoThrow(try rx.processIncomingAudio(serializedFrame: b))
        XCTAssertNoThrow(try rx.processIncomingAudio(serializedFrame: a))
        // Second copy of the same wire position: the key is gone.
        XCTAssertThrowsError(try rx.processIncomingAudio(serializedFrame: a),
                             "a replayed frame must not decode twice")
        XCTAssertThrowsError(try rx.processIncomingAudio(serializedFrame: b))
    }

    /// A genuinely lost frame stays lost — the window retains keys, it does not
    /// resurrect audio that never arrived, and it must not stall the chain.
    func testGenuineLossStillAdvancesTheChain() throws {
        let (tx, rx) = try makePair()
        let a = try tx.processOutgoingAudio(pcmFrame: pcm(1))
        _ = try tx.processOutgoingAudio(pcmFrame: pcm(2))   // dropped on the wire
        let c = try tx.processOutgoingAudio(pcmFrame: pcm(3))

        XCTAssertNoThrow(try rx.processIncomingAudio(serializedFrame: a))
        XCTAssertNoThrow(try rx.processIncomingAudio(serializedFrame: c))
        XCTAssertEqual(rx.getStats().framesRx, 2)
        XCTAssertEqual(rx.getStats().framesRxReordered, 0,
                       "nothing was reordered here — one frame simply never came")
    }

    /// The retention window is bounded, and the bound is a forward-secrecy
    /// knob: a frame older than the window is undecryptable again, by design.
    func testFrameOlderThanTheWindowIsRejected() throws {
        let (tx, rx) = try makePair()
        let ancient = try tx.processOutgoingAudio(pcmFrame: pcm(1))
        var latest = ancient
        // Push well past the retention window so `ancient`'s key is evicted.
        for i in 0..<200 { latest = try tx.processOutgoingAudio(pcmFrame: pcm(UInt8(i % 251))) }

        XCTAssertNoThrow(try rx.processIncomingAudio(serializedFrame: latest))
        XCTAssertThrowsError(try rx.processIncomingAudio(serializedFrame: ancient),
                             "beyond the window the key is gone, and that is the point")
    }

    /// Keys must never cross a session boundary.
    func testRetainedKeysDoNotSurviveANewSession() throws {
        let (tx, rx) = try makePair()
        let a = try tx.processOutgoingAudio(pcmFrame: pcm(1))
        let b = try tx.processOutgoingAudio(pcmFrame: pcm(2))
        XCTAssertNoThrow(try rx.processIncomingAudio(serializedFrame: b))

        // Re-key, as a mid-call handshake re-fire does.
        try rx.initSession(sharedSecret: Data(repeating: 0x11, count: 32))
        XCTAssertThrowsError(try rx.processIncomingAudio(serializedFrame: a),
                             "a key retained against the old chain must be gone")
    }
}
