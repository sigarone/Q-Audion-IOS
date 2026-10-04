import XCTest
@testable import QAudionEngine

/// The app wiring of R-KCMAC-ROUNDS (K-round, 2026-10-03). The pure rules are in `KcMacRoundBookTests`; what needs a live
/// provider and CallKit (AppState) is pinned on the source text, like the other wiring invariants of this module.
final class KcMacRoundWiringTests: XCTestCase {

    private let appPath = "QAudionApp/AppState.swift"
    private let integrationPath = "QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift"

    private func sourceText(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw XCTSkip("\(relativePath) not found")
    }

    /// Whole-line `//` comments dropped and every run of whitespace collapsed.
    private func code(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func slice(_ text: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(text.range(of: start), "start marker: \(start)")
        let tail = text[a.upperBound...]
        let b = try XCTUnwrap(tail.range(of: end), "end marker: \(end)")
        return String(tail[..<b.lowerBound])
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// Arming a round never cancels another pending round's window: the only cancellation in the arming path is of the
    /// SAME round's earlier state. The round is inserted into the book before our MAC is sent and before the held MACs
    /// are offered again, and every round runs its own deadline task.
    func testArmingARoundNeverCancelsAnotherPendingRound() throws {
        let app = try sourceText(appPath)
        let arming = code(try slice(
            app, from: "private func handleKcMacReady(_ event: QAudionCallIntegration.KcMacReadyEvent) {",
            to: "/// R-KCMAC-RESEND: a decided round that is no longer the live one"))
        XCTAssertEqual(occurrences(of: "deadlineTask?.cancel()", in: arming), 1,
                       "only the same round's earlier state is cancelled")
        XCTAssertTrue(arming.contains("call.states[state.round]?.deadlineTask?.cancel()"))
        XCTAssertFalse(arming.contains("kcCallStates"))
        let armAt = try XCTUnwrap(arming.range(of: "call.book.arm("))
        let sendAt = try XCTUnwrap(arming.range(of: "sendOpaqueMessageString("))
        let verdictsAt = try XCTUnwrap(arming.range(of: "armed.verdicts"))
        XCTAssertLessThan(armAt.lowerBound, sendAt.lowerBound, "the round is inserted before anything else happens")
        XCTAssertLessThan(sendAt.lowerBound, verdictsAt.lowerBound, "the held MACs are judged after the round is armed")
        XCTAssertTrue(arming.contains("if armed.overflow {"), "a 17th pending round ends the call")
        XCTAssertTrue(arming.contains("guard let self, let cur = self.kcCalls[key]?.states[round], cur === state, !cur.resultRecorded else { return nil }"),
                      "each round runs its own timer")
        XCTAssertTrue(arming.contains("self.failKeyConfirmation(callId: event.callId, state: cur, expired: true)"),
                      "a round whose window ends while pending fails, superseded or not")
    }

    /// An inbound MAC is attributed by the book and never judged on arrival against some round: the handler has no
    /// failure path of its own, only the verdict of the book.
    func testAnInboundMacIsAttributedByContentAndNeverFailsTheCallOnArrival() throws {
        let app = try sourceText(appPath)
        let handler = code(try slice(
            app, from: "private func handleInboundKcMac(callId: String, raw: String, senderId: String, senderDeviceId: String? = nil) {",
            to: "/// W-KCMAC/W-ASSURANCE/W-FLOOR/W-NFCBADGE"))
        XCTAssertTrue(handler.contains("call.book.receive(payload: raw, nowMs: SasCommit.monotonicNowMs())"))
        XCTAssertFalse(handler.contains("failKeyConfirmation("), "arrival alone never ends the call")
        XCTAssertFalse(handler.contains("KeyConfirmation.verify("), "no judgment against a single round")
        XCTAssertTrue(handler.contains("case .decided(let verdict): applyKcVerdict(verdict, callId: callId)"))
        let verdicts = code(try slice(
            app, from: "private func applyKcVerdict(_ verdict: KcMacRoundBook.Verdict, callId: String) {",
            to: "/// A2: drop what the app queued for a round-1 OFFER"))
        XCTAssertTrue(verdicts.contains("case .mismatch(let round):"))
        XCTAssertTrue(verdicts.contains("failKeyConfirmation(callId: callId, state: state)"), "only a role-byte mismatch fails here")
        XCTAssertFalse(app.contains("kcEarlyInbound"), "the single early slot is the book's held set now")
        XCTAssertFalse(app.contains("kcDecidedPeerMacs"))
    }

    /// The re-authentication re-send covers every pending round, not only the live one, and the log says so.
    func testTheReauthResendCoversEveryPendingRoundAndLogsTheOlderCount() throws {
        let app = try sourceText(appPath)
        let handler = code(try slice(
            app, from: "private func handleSocketReauthForConfirmation() {",
            to: "/// W-KCMAC — verify an inbound `KCMAC:` piggy-back"))
        XCTAssertTrue(handler.contains("for (round, other) in call.states.sorted(by: { $0.key < $1.key }) where round != call.liveRound {"))
        XCTAssertTrue(handler.contains("older=\\(olderWires.count)"), "a re-send of older MACs only is no longer logged as kcmac=0")
    }

    /// A round superseded by a later one is dropped with the call and with the superseded OFFER, never earlier.
    func testTheBookAndTheRoundStatesAreDroppedWithTheCall() throws {
        let app = try sourceText(appPath)
        let clear = code(try slice(
            app, from: "private func clearKeyConfirmationState(callId: String?) {",
            to: "/// W-ASSURANCE/W-FLOOR (ship steps 6/8)"))
        XCTAssertTrue(clear.contains("kcCalls.removeValue(forKey: key)"))
        XCTAssertTrue(clear.contains("state.deadlineTask?.cancel()"))
        let discard = code(try slice(
            app, from: "private func discardUnansweredRound1AppState(callId: String) {",
            to: "/// Milliseconds left on this round's KCMAC wait"))
        XCTAssertTrue(discard.contains("kcCalls.removeValue(forKey: cid)"))
    }

    /// K3: the rekey offerer waits 2 x CONFIRM_TIMEOUT for the ACCEPT, so an acceptor that already armed its
    /// (now 30 s) window is not left without the offerer's MAC.
    func testTheRekeyOffererWaitsThirtySecondsForTheAccept() throws {
        let integration = code(try sourceText(integrationPath))
        XCTAssertTrue(integration.contains("timeoutSec: Double = Double(ConfirmTimeout.rekeyAcceptWaitMs) / 1000,"))
        XCTAssertFalse(integration.contains("timeoutSec: Double = 8.0"))
        XCTAssertEqual(ConfirmTimeout.rekeyAcceptWaitMs, 2 * ConfirmTimeout.confirmTimeoutMs)
        XCTAssertGreaterThanOrEqual(ConfirmTimeout.rekeyAcceptWaitMs, ConfirmTimeout.rekeyAcceptorKcMacWaitMs,
                                    "the acceptor's window never ends before the offerer gave up waiting")
    }
}
