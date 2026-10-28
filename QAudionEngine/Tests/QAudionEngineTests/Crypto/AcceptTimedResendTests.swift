import XCTest
@testable import QAudionEngine

/// The callee's round-1 ACCEPT goes again, byte-identical, on a timer until the caller's REVEAL verified.
final class AcceptTimedResendTests: XCTestCase {

    private let callId = "11111111-2222-3333-4444-555555555555"
    private let payloadHash = Data(repeating: 0xA1, count: 32)
    private let nonce = Data(repeating: 1, count: 32)

    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    /// An integration whose round-1 ACCEPT was just handed to the transport (first send); the schedule is shortened.
    private func armed(_ wire: Wire, delaysMs: [Int] = [20, 40]) async throws -> QAudionCallIntegration {
        let integ = QAudionCallIntegration()
        integ.acceptResendDelaysMs = delaysMs
        integ.setResponderSenderForTesting { wire.add($0) }
        let commit = try XCTUnwrap(SasCommit.commit(callId: callId, nonce: nonce))
        let token = try XCTUnwrap(integ.sasCommit.beginCalleeOwned(callId: callId, commit: commit, acceptHash: payloadHash))
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-1", sendOpaqueRaw: { wire.add($0) },
                                       isRound1: true, calleeToken: token, acceptRound: 1)
        return integ
    }

    private func settle(_ ms: Int = 250) async { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }

    func testTheAcceptGoesAgainOnTheScheduleWithIdenticalBytes() async throws {
        let wire = Wire()
        let integ = try await armed(wire)
        XCTAssertEqual(wire.all, ["ACCEPT-1"])
        await settle()
        XCTAssertEqual(wire.all, ["ACCEPT-1", "ACCEPT-1", "ACCEPT-1"], "first send + two identical copies, no more")
        XCTAssertEqual(integ.sasCommit.resendEventsUsed(callId: callId), 0, "the shared budget is untouched")
    }

    func testTheCopiesStopWhenTheRevealArrives() async throws {
        let wire = Wire()
        let integ = try await armed(wire, delaysMs: [60, 120])
        integ.sasCommit.recordRound1(callId: callId, sessionKey: Data(repeating: 7, count: 32), acceptHash: payloadHash)
        let reveal = try XCTUnwrap(SasReveal.serialize(callId: callId, acceptBinding: payloadHash, nonce: nonce))
        XCTAssertEqual(integ.handleSasReveal(callId: callId, data: reveal), .sasReady)
        await settle(400)
        XCTAssertEqual(wire.all, ["ACCEPT-1"], "no copy after the REVEAL verified")
        XCTAssertEqual(integ.sasCommit.resendEventsUsed(callId: callId), 0)
    }

    func testTheCopiesStopWhenTheCallEnds() async throws {
        let wire = Wire()
        let integ = try await armed(wire, delaysMs: [60, 120])
        integ.onCallEnded()
        await settle(400)
        XCTAssertEqual(wire.all, ["ACCEPT-1"], "no copy after the call ended")
    }

    func testTheTimerCopiesRunEvenWithTheSharedBudgetSpentAndLeaveItAlone() async throws {
        let wire = Wire()
        let integ = try await armed(wire)
        for _ in 0..<ConfirmTimeout.maxResendEvents { XCTAssertTrue(integ.takeResendEvent(callId: callId)) }
        await settle()
        XCTAssertEqual(wire.all, ["ACCEPT-1", "ACCEPT-1", "ACCEPT-1"], "own cap of two copies")
        XCTAssertEqual(integ.sasCommit.resendEventsUsed(callId: callId), ConfirmTimeout.maxResendEvents)
    }

    func testTheDefaultScheduleStaysInsideTheRevealWindow() {
        XCTAssertEqual(ConfirmTimeout.acceptResendDelaysMs, [4_000, 9_000])
        XCTAssertLessThan(ConfirmTimeout.acceptResendDelaysMs.max() ?? 0, ConfirmTimeout.confirmTimeoutMs)
    }
}
