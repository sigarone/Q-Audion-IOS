import XCTest
@testable import QAudionEngine

/// The engine of a call that negotiated the per-round inner seal: its first frame is an envelope, the mode is fixed for the call,
/// a frame that is not an envelope is dropped by name before any accounting, only an authentication failure counts as a decrypt
/// failure, and a call that did not negotiate the seal behaves as before.
final class InnerSealV2EngineTests: XCTestCase {

    private let callIdL = "call-s9-e"
    private let secret = Data(repeating: 0x42, count: 32)

    private var oneFrame: Data { Data(count: AudioProfile.defaultProfile.bytesPerFrame) }

    private struct Side {
        let engine: QAudionEngine
        let session: InnerSealV2Session
    }

    private func sealedSide(role: LiveCallCrypto.Role) throws -> Side {
        let session = InnerSealV2Session(callIdL: callIdL, role: role, nowMs: { 0 })
        XCTAssertTrue(session.stageRound0(sessionKey: secret))
        let engine = QAudionEngine(config: .development())
        try engine.initialize()
        try engine.initSession(
            sharedSecret: secret, adaptivePadding: true, innerSealV2: session, selfIsCaller: role == .offerer)
        return Side(engine: engine, session: session)
    }

    private func legacyEngine(caller: Bool) throws -> QAudionEngine {
        let engine = QAudionEngine(config: .development())
        try engine.initialize()
        try engine.initSession(sharedSecret: secret, adaptivePadding: true, selfIsCaller: caller)
        return engine
    }

    private func receiveError(_ engine: QAudionEngine, _ frame: Data) -> Error? {
        do {
            _ = try engine.processIncomingAudio(serializedFrame: frame)
            return nil
        } catch {
            return error
        }
    }

    private func droppedReason(_ error: Error?) -> InnerDrop? {
        if let engineError = error as? QAudionEngineError, case .innerDropped(let why) = engineError { return why }
        return nil
    }

    private func isOpenFailure(_ error: Error?) -> Bool {
        if let engineError = error as? QAudionEngineError, case .innerOpenFailed = engineError { return true }
        return false
    }

    // MARK: - Mode, seal and open

    func testAV2PairSealsEnvelopesAndOpensThemAndTheModeIsFixedForTheCall() throws {
        let caller = try sealedSide(role: .offerer)
        let callee = try sealedSide(role: .acceptor)

        let wire = try caller.engine.processOutgoingAudio(pcmFrame: oneFrame)
        XCTAssertEqual(wire.first, InnerSealV2.envelopeType)
        XCTAssertEqual(InnerSealV2.header(ofWire: wire)?.ctr, 1)
        XCTAssertNoThrow(try callee.engine.processIncomingAudio(serializedFrame: wire))
        let back = try callee.engine.processOutgoingAudio(pcmFrame: oneFrame)
        XCTAssertNoThrow(try caller.engine.processIncomingAudio(serializedFrame: back))

        // A later install without a port (a rekey round) leaves the engine sealed, and the counter goes on.
        try caller.engine.initSession(
            sharedSecret: Data(repeating: 0x99, count: 32), adaptivePadding: true, selfIsCaller: true)
        let next = try caller.engine.processOutgoingAudio(pcmFrame: oneFrame)
        XCTAssertEqual(next.first, InnerSealV2.envelopeType)
        XCTAssertEqual(InnerSealV2.header(ofWire: next)?.ctr, 2)
    }

    func testAnInstallThatThrowsStoresNoPortAndTheEndOfTheSessionDropsIt() throws {
        let session = InnerSealV2Session(callIdL: callIdL, role: .offerer, nowMs: { 0 })
        XCTAssertTrue(session.stageRound0(sessionKey: secret))
        let engine = QAudionEngine(config: .development())
        try engine.initialize()
        XCTAssertThrowsError(try engine.initSession(sharedSecret: Data(count: 5), adaptivePadding: true, innerSealV2: session))
        try engine.initSession(sharedSecret: secret, adaptivePadding: true, selfIsCaller: true)
        XCTAssertEqual(try engine.processOutgoingAudio(pcmFrame: oneFrame).first, 0x01, "no port was stored: the legacy container")

        let sealed = try sealedSide(role: .offerer)
        sealed.engine.destroySession()
        XCTAssertEqual(sealed.engine.getState(), .initialized)
        try sealed.engine.initSession(sharedSecret: secret, adaptivePadding: true, selfIsCaller: true)
        XCTAssertEqual(try sealed.engine.processOutgoingAudio(pcmFrame: oneFrame).first, 0x01, "the port went with the session")
    }

    // MARK: - Classification

    func testAFrameThatIsNotAnEnvelopeIsDroppedByNameAndCountsNowhere() throws {
        let callee = try sealedSide(role: .acceptor)
        let container = try legacyEngine(caller: true).processOutgoingAudio(pcmFrame: oneFrame)
        XCTAssertEqual(container.first, 0x01)
        let received = callee.engine.getStats().framesRx
        let loss = callee.engine.rxLossSnapshot()

        let cases: [(Data, InnerDrop)] = [
            (container, .legacyFrame),
            (Data([0x02, 0x00, 0x01]), .legacyFrame),
            (Data([0x05] + Array(container.dropFirst())), .unknownType),
            (Data([0x82, 0x00, 0x00]), .unknownType),
            (Data([0x00]), .unknownType),
            (Data([0x03, 0x01]), .unknownType),
            (Data(), .malformed)
        ]
        for (frame, reason) in cases {
            let error = receiveError(callee.engine, frame)
            XCTAssertEqual(droppedReason(error), reason, "first byte \(frame.first.map { String($0) } ?? "none")")
            if let error { XCTAssertEqual(RxDecodeFailureKind.classify(error), .dropped) }
        }
        XCTAssertEqual(callee.engine.getStats().framesRx, received)
        XCTAssertEqual(callee.engine.rxLossSnapshot().expected, loss.expected)
        XCTAssertEqual(callee.engine.rxLossSnapshot().lost, loss.lost)
    }

    func testAReplayIsADropAndATamperedFrameIsADecryptFailureThatCommitsNothing() throws {
        let caller = try sealedSide(role: .offerer)
        let callee = try sealedSide(role: .acceptor)
        let first = try caller.engine.processOutgoingAudio(pcmFrame: oneFrame)
        XCTAssertNil(receiveError(callee.engine, first))

        let repeated = receiveError(callee.engine, first)
        XCTAssertEqual(droppedReason(repeated), .replay)
        if let repeated { XCTAssertEqual(RxDecodeFailureKind.classify(repeated), .dropped) }

        let second = try caller.engine.processOutgoingAudio(pcmFrame: oneFrame)
        var tampered = second
        tampered[tampered.count - 1] ^= 0x01
        let failure = receiveError(callee.engine, tampered)
        XCTAssertTrue(isOpenFailure(failure))
        if let failure { XCTAssertEqual(RxDecodeFailureKind.classify(failure), .decrypt) }
        XCTAssertNil(receiveError(callee.engine, second), "the genuine frame still opens: a failed open commits nothing")
    }

    func testAnAuthenticatedBlockWithABadHeaderIsADropAndItsCounterStaysRecorded() throws {
        let caller = try sealedSide(role: .offerer)
        let callee = try sealedSide(role: .acceptor)
        var bad = Data(count: 256)
        bad[0] = 0xFF
        bad[1] = 0xFF
        guard case .sealed(let wire, _, _) = caller.session.sealAudio(block: bad) else { return XCTFail("seal") }
        let first = receiveError(callee.engine, wire)
        XCTAssertEqual(droppedReason(first), .malformedBlock)
        if let first { XCTAssertEqual(RxDecodeFailureKind.classify(first), .dropped) }
        XCTAssertEqual(droppedReason(receiveError(callee.engine, wire)), .replay)
    }

    func testACallWithoutTheSealTreatsAnEnvelopeAsItAlwaysDid() throws {
        let caller = try sealedSide(role: .offerer)
        let envelope = try caller.engine.processOutgoingAudio(pcmFrame: oneFrame)
        let legacy = try legacyEngine(caller: false)
        let error = receiveError(legacy, envelope)
        XCTAssertNotNil(error, "an envelope is not a legacy frame")
        XCTAssertNil(droppedReason(error), "no drop classification outside a sealed call")
        if let error { XCTAssertEqual(RxDecodeFailureKind.classify(error), .decrypt) }
    }

    // MARK: - The key of the resend cache

    func testTheResendKeyIsReadFromTheEnvelopeHeaderOnlyOnASealedCall() throws {
        let caller = try sealedSide(role: .offerer)
        let envelope = try caller.engine.processOutgoingAudio(pcmFrame: oneFrame)
        let container = try legacyEngine(caller: true).processOutgoingAudio(pcmFrame: oneFrame)
        for compat in [true, false] {
            XCTAssertEqual(InnerSealV2.nackSeq(inner: envelope, innerV2: true, androidAudioWireCompat: compat), 1)
            XCTAssertNil(InnerSealV2.nackSeq(inner: container, innerV2: true, androidAudioWireCompat: compat), "a legacy frame has no key")
        }
        // A call without the seal reads what it always read, even from a well-formed envelope.
        XCTAssertEqual(
            InnerSealV2.nackSeq(inner: envelope, innerV2: false, androidAudioWireCompat: true),
            (try? WireRelayFrameCodec.decode(envelope)).map { Int64($0.frame.sequenceNumber) })
        XCTAssertEqual(
            InnerSealV2.nackSeq(inner: envelope, innerV2: false, androidAudioWireCompat: false),
            (try? FrameEncoder.deserialize(envelope)).map { Int64($0.sequenceNumber) })
        XCTAssertEqual(
            InnerSealV2.nackSeq(inner: container, innerV2: false, androidAudioWireCompat: false),
            (try? FrameEncoder.deserialize(container)).map { Int64($0.sequenceNumber) })
    }
}
