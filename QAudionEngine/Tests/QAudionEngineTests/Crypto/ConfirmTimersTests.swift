import XCTest
@testable import QAudionEngine

/// The v6 timer round, "no legitimate call may end 5 s after the answer" (WIRE_SPEC §3.7.1 R-CONFIRM-TIMEOUT,
/// R-KCMAC-NOGATE, R-KCMAC-RESEND, R-ANSWER-FIRST, R-CONFIRM-TELEMETRY; orchestrator decisions T1 to T5).
///
/// The pure rules are driven directly. The wiring that needs CallKit, a live provider or a PeerConnection
/// (AppState, the integration, the DTLS check) is pinned on the source text, like the other wiring invariants of
/// this module. Every test here fails on the code before the round: the old 5 s / 10 s / 15 s values, the REVEAL
/// re-send inside `replayPendingHandshake` that took one unit per message and never re-sent a KCMAC, no expiry
/// event, a pre-answer mode selected by `calls.ring_signaling_only`.
final class ConfirmTimersTests: XCTestCase {

    private let callId = "11111111-2222-3333-4444-555555555555"
    private let nonce = Data((0..<32).map { UInt8($0 &+ 1) })
    private let ownHash = Data(repeating: 0xA5, count: 32)

    private func commit() -> Data { SasCommit.commit(callId: callId, nonce: nonce)! }
    private func reveal() -> String { SasReveal.serialize(callId: callId, acceptBinding: ownHash, nonce: nonce)! }

    // MARK: - Source helpers

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

    /// Whole-line `//` comments dropped and every run of whitespace collapsed: a pin written against this text
    /// survives re-wrapping and comment edits, but not a change of the code.
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

    private let integrationPath = "QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift"
    private let appPath = "QAudionApp/AppState.swift"

    // MARK: - T3: one confirmation constant, no old value on these paths

    func testThereIsOneConfirmationConstantOfFifteenSeconds() {
        XCTAssertEqual(ConfirmTimeout.confirmTimeoutMs, 15_000)
        XCTAssertEqual(KcMacWindow.baseMs, ConfirmTimeout.confirmTimeoutMs, "every round's KCMAC window")
        XCTAssertEqual(KcMacWindow.calleeRound1AfterRevealVerifiedMs, ConfirmTimeout.confirmTimeoutMs,
                       "the callee's wait after its own REVEAL verified")
        XCTAssertEqual(ConfirmTimeout.callerRound1KcMacWaitMs, 2 * ConfirmTimeout.confirmTimeoutMs, "caller round 1: 30 s")
        XCTAssertEqual(KcMacWindow.callerRound1AfterRevealMs, 30_000)
        XCTAssertEqual(ConfirmTimeout.earlyKcMacHoldMs, 30_000, "early-MAC hold: 30 s")
        XCTAssertEqual(KcMacRoundRules.earlyHoldSeconds, 30)
        XCTAssertEqual(ConfirmTimeout.dtlsStatsRetryMs, 250)
        XCTAssertEqual(ConfirmTimeout.maxResendEvents, 4)
    }

    /// The callee's REVEAL timer: a REVEAL that arrives 14.9 s after the ACCEPT was sent still counts, 15.1 s is too late.
    func testTheRevealTimerSurvivesAt14p9SecondsAndExpiresAt15p1() {
        var survives = SasCommitCallee(callId: callId, storedCommit: commit())
        survives.setAcceptHash(ownHash)
        XCTAssertTrue(survives.acceptSent(nowMs: 1_000))
        XCTAssertEqual(survives.tick(nowMs: 1_000 + 14_900), .none, "14.9 s: the call survives")
        XCTAssertEqual(survives.receiveReveal(data: reveal(), nowMs: 1_000 + 14_900), .sasReady)

        var expires = SasCommitCallee(callId: callId, storedCommit: commit())
        expires.setAcceptHash(ownHash)
        XCTAssertTrue(expires.acceptSent(nowMs: 1_000))
        XCTAssertEqual(expires.tick(nowMs: 1_000 + 15_100), .end(reason: "sas_reveal_timeout"), "15.1 s: times out")

        let book = SasCommitBook()
        XCTAssertTrue(book.beginCallee(callId: callId, commit: commit()))
        book.calleeSetAccept(callId: callId, acceptHash: ownHash)
        XCTAssertTrue(book.calleeAcceptSent(callId: callId, nowMs: 0))
        XCTAssertEqual(book.calleeTick(callId: callId, nowMs: 14_900), .none)
        XCTAssertEqual(book.calleeTick(callId: callId, nowMs: 15_100), .end(reason: "sas_reveal_timeout"))
    }

    /// The KCMAC windows of T3 at the instants the owner's bug needs: a callee KCMAC 14 s after the REVEAL, the caller
    /// getting the callee's KCMAC at 29 s, a rekey KCMAC at 14 s. The 5 s / 15 s windows of the round before ended
    /// all three calls.
    func testTheKcmacWindowsOfEveryRoundAtTheInstantsOfTheBug() {
        // callee, round 1: its REVEAL verified at 4.9 s after the key; the caller's MAC 14 s after the REVEAL
        XCTAssertGreaterThan(KcMacWindow.remainingMs(isRound1: true, isInitiator: false, armedAtMs: 0,
                                                     nowMs: 4_900 + 14_000, revealHandedAtMs: nil, revealVerifiedAtMs: 4_900), 0)
        XCTAssertEqual(KcMacWindow.remainingMs(isRound1: true, isInitiator: false, armedAtMs: 0,
                                               nowMs: 4_900 + 15_000, revealHandedAtMs: nil, revealVerifiedAtMs: 4_900), 0)
        // caller, round 1: the callee's MAC arrives 29 s after the REVEAL was handed to the transport
        XCTAssertGreaterThan(KcMacWindow.remainingMs(isRound1: true, isInitiator: true, armedAtMs: 100,
                                                     nowMs: 1_000 + 29_000, revealHandedAtMs: 1_000, revealVerifiedAtMs: nil), 0)
        XCTAssertEqual(KcMacWindow.remainingMs(isRound1: true, isInitiator: true, armedAtMs: 100,
                                               nowMs: 1_000 + 30_000, revealHandedAtMs: 1_000, revealVerifiedAtMs: nil), 0)
        // a rekey round, either role: 14 s after it was armed
        for isInitiator in [true, false] {
            XCTAssertGreaterThan(KcMacWindow.remainingMs(isRound1: false, isInitiator: isInitiator, armedAtMs: 0,
                                                         nowMs: 14_000, revealHandedAtMs: nil, revealVerifiedAtMs: nil), 0)
            XCTAssertEqual(KcMacWindow.remainingMs(isRound1: false, isInitiator: isInitiator, armedAtMs: 0,
                                                   nowMs: 15_000, revealHandedAtMs: nil, revealVerifiedAtMs: nil), 0)
        }
    }

    /// Check (b) of the DTLS binding: statistics that are still incomplete 12 s after `connected` are retried, not failed.
    func testTheDtlsStatsCheckWaitsFifteenSeconds() {
        XCTAssertFalse(ConfirmTimeout.dtlsStatsWaitExpired(elapsedMs: 0))
        XCTAssertFalse(ConfirmTimeout.dtlsStatsWaitExpired(elapsedMs: 5_000), "the old 5 s deadline")
        XCTAssertFalse(ConfirmTimeout.dtlsStatsWaitExpired(elapsedMs: 12_000), "12 s: still retrying")
        XCTAssertFalse(ConfirmTimeout.dtlsStatsWaitExpired(elapsedMs: 14_999))
        XCTAssertTrue(ConfirmTimeout.dtlsStatsWaitExpired(elapsedMs: 15_000), "no verdict in 15 s: stats_timeout")
    }

    /// The PeerConnection reads its deadline and retry period from the one constant, and no 5 s deadline is left.
    func testThePeerConnectionUsesTheOneConstantForTheStatsDeadline() throws {
        let pc = code(try sourceText("QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionPeerConnection.swift"))
        XCTAssertFalse(pc.contains("dtlsStatsDeadlineSeconds"), "the 5 s deadline constant is gone")
        XCTAssertTrue(pc.contains("ConfirmTimeout.dtlsStatsWaitExpired(elapsedMs:"))
        XCTAssertTrue(pc.contains("Double(ConfirmTimeout.dtlsStatsRetryMs) / 1000"))
        XCTAssertEqual(pc.components(separatedBy: "self.dtlsStatsDeadlineReached(since: startedAt)").count - 1, 1,
                       "the `.pending` branch uses the same deadline")
        XCTAssertTrue(pc.contains("let deadlineReached = dtlsStatsDeadlineReached(since: startedAt)"))
    }

    /// No other number lives on the confirmation paths: the REVEAL timer sleeps `confirmTimeoutMs`, the KCMAC window
    /// reads `KcMacWindow`, the early hold reads `ConfirmTimeout`.
    func testNoOldValueIsLeftOnTheConfirmationPaths() throws {
        let sas = code(try sourceText("QAudionEngine/Sources/QAudionEngine/Crypto/SasCommit.swift"))
        XCTAssertFalse(sas.contains("revealTimeoutMs"))
        XCTAssertFalse(sas.contains("maxRevealResends"))
        for stale in ["= 5_000", "= 10_000", "= 15_000"] {
            XCTAssertFalse(sas.contains(stale), "SasCommit.swift must not define \(stale)")
        }
        let integration = code(try sourceText(integrationPath))
        XCTAssertTrue(integration.contains("Task.sleep(nanoseconds: UInt64(ConfirmTimeout.confirmTimeoutMs) * 1_000_000)"))
        XCTAssertFalse(integration.contains("revealTimeoutMs"))
        let rules = code(try sourceText("QAudionEngine/Sources/QAudionEngine/Crypto/KcMacRoundRules.swift"))
        XCTAssertTrue(rules.contains("TimeInterval(ConfirmTimeout.earlyKcMacHoldMs) / 1000"))
        let app = code(try sourceText(appPath))
        XCTAssertTrue(app.contains("return self.kcWaitRemainingMs(callId: event.callId, state: cur)"),
                      "the KCMAC wait is `KcMacWindow`'s, not a fixed sleep")
    }

    // MARK: - T4: KCMAC re-send on re-auth, one shared budget of 4

    func testWhatAReauthResendsFollowsTheOwnStateOfTheDevice() {
        // callee, round 1, its own MAC was sent and the caller's MAC is not verified: the lost MAC goes again
        XCTAssertEqual(ConfirmResend.due(isCaller: false, revealBound: false, isRound1: true,
                                         ownKcMacSent: true, peerKcMacVerified: false),
                       ConfirmResend.Due(reveal: false, ownKcMac: true))
        // callee still holding its round-1 MAC (its REVEAL has not verified): nothing, and it does not start now
        let held = ConfirmResend.due(isCaller: false, revealBound: false, isRound1: true,
                                     ownKcMacSent: false, peerKcMacVerified: false)
        XCTAssertFalse(held.any, "R-COMMIT-KCMAC-HOLD: a MAC that was never sent is never re-sent")
        // caller, round 1, bound: REVEAL and own MAC, in that order of need
        XCTAssertEqual(ConfirmResend.due(isCaller: true, revealBound: true, isRound1: true,
                                         ownKcMacSent: true, peerKcMacVerified: false),
                       ConfirmResend.Due(reveal: true, ownKcMac: true))
        // caller before binding: no REVEAL exists
        XCTAssertFalse(ConfirmResend.due(isCaller: true, revealBound: false, isRound1: true,
                                         ownKcMacSent: false, peerKcMacVerified: false).any)
        // a rekey round re-sends the MAC only, never the (round-1) REVEAL
        XCTAssertEqual(ConfirmResend.due(isCaller: true, revealBound: true, isRound1: false,
                                         ownKcMacSent: true, peerKcMacVerified: false),
                       ConfirmResend.Due(reveal: false, ownKcMac: true))
        // the peer's MAC of the live round verified: it proves REVEAL and MAC arrived, nothing is due
        XCTAssertFalse(ConfirmResend.due(isCaller: true, revealBound: true, isRound1: true,
                                         ownKcMacSent: true, peerKcMacVerified: true).any)
    }

    /// The budget is ONE counter of EVENTS per call, shared by duplicate-ACCEPT re-sends and re-authentications: two
    /// duplicates and two re-auths spend it, the fifth event of either kind re-sends nothing; first sends are free.
    func testDuplicateAcceptsAndReauthsShareOneBudgetOfFourEvents() {
        let book = SasCommitBook()
        _ = book.beginCaller(callId: callId, nonce: nonce)
        XCTAssertEqual(book.callerOnAccept(callId: callId, acceptHash: ownHash).0, .bindAndReveal)
        XCTAssertEqual(book.resendEventsUsed(callId: callId), 0)
        XCTAssertEqual(book.callerOnAccept(callId: callId, acceptHash: ownHash).0, .resendReveal)   // event 1
        XCTAssertTrue(book.takeResendEvent(callId: callId))                                         // event 2 (re-auth)
        XCTAssertEqual(book.callerOnAccept(callId: callId, acceptHash: ownHash).0, .resendReveal)   // event 3
        XCTAssertTrue(book.takeResendEvent(callId: callId))                                         // event 4 (re-auth)
        XCTAssertEqual(book.resendEventsUsed(callId: callId), 4)
        XCTAssertFalse(book.takeResendEvent(callId: callId), "a fifth re-auth re-sends nothing")
        XCTAssertEqual(book.callerOnAccept(callId: callId, acceptHash: ownHash).0, .drop, "a fifth duplicate re-sends nothing")
        // an event re-sends everything due in ONE unit, not one unit per message
        let other = SasCommitBook()
        _ = other.beginCaller(callId: callId, nonce: nonce)
        _ = other.callerOnAccept(callId: callId, acceptHash: ownHash)
        XCTAssertTrue(other.takeResendEvent(callId: callId))
        XCTAssertEqual(other.callerRevealForResend(callId: callId), reveal())
        XCTAssertEqual(other.resendEventsUsed(callId: callId), 1, "the REVEAL and the KCMAC of one re-auth cost one unit")
        // the budget belongs to the call and goes with it
        other.clear(callId: callId)
        XCTAssertEqual(other.resendEventsUsed(callId: callId), 0)
    }

    /// The lost-KCMAC story end to end: the callee sent its round-1 MAC into a socket that died; the socket
    /// re-authenticates; the device's own state says "re-send it", one unit is taken, and the very same bytes go again.
    func testALostKcmacIsResentAfterTheReauthWithTheSameBytes() {
        let sentOnce = "\(callId)|KCMAC:AgECAwQ="   // opaque stand-in for the bytes of the first send
        var resent: [String] = []
        let budget = SasCommitBook()
        _ = budget.beginCaller(callId: callId, nonce: nonce)   // the book that counts this device's events
        let due = ConfirmResend.due(isCaller: false, revealBound: false, isRound1: true,
                                    ownKcMacSent: true, peerKcMacVerified: false)
        XCTAssertTrue(due.any)
        if due.any, budget.takeResendEvent(callId: callId), due.ownKcMac { resent.append(sentOnce) }
        XCTAssertEqual(resent, [sentOnce], "byte-identical")
        XCTAssertEqual(budget.resendEventsUsed(callId: callId), 1)
    }

    /// The app asks the budget only when something is due (nothing due consumes none), re-sends the REVEAL before the
    /// KCMAC in one ordered task, and the integration's replay no longer re-sends the REVEAL by itself.
    func testTheAppWiresTheReauthResend() throws {
        let app = try sourceText(appPath)
        let handler = code(try slice(app, from: "private func handleSocketReauthForConfirmation() {",
                                     to: "/// W-KCMAC — verify an inbound `KCMAC:` piggy-back"))
        let dueAt = try XCTUnwrap(handler.range(of: "guard due.any else { return }"))
        let takeAt = try XCTUnwrap(handler.range(of: "integration.takeResendEvent(callId: cid)"))
        XCTAssertLessThan(dueAt.lowerBound, takeAt.lowerBound, "nothing due: no budget is consumed")
        let revealAt = try XCTUnwrap(handler.range(of: "await integration.resendRevealAfterReauth(callId: cid)"))
        let macAt = try XCTUnwrap(handler.range(of: "sendOpaqueMessageString(recipientId: peerId, payload: ownWire)"))
        XCTAssertLessThan(revealAt.lowerBound, macAt.lowerBound, "the REVEAL leaves before the KCMAC")
        XCTAssertTrue(handler.contains("ownKcMacSent: state.ownMacWire != nil && state.ownMacSent"),
                      "a MAC that was never sent is never re-sent")
        XCTAssertTrue(code(app).contains("self?.handleSocketReauthForConfirmation()"), "called on every re-authentication")
        XCTAssertTrue(code(app).contains("kcCallStates[key]?.ownMacSent = true"), "the held MAC counts once it was released")
        XCTAssertTrue(code(app).contains("state.ownMacSent = !holdOwnMac"))

        let integration = code(try sourceText(integrationPath))
        XCTAssertFalse(integration.contains("callerResendReveal("), "no REVEAL re-send outside the shared budget")
        XCTAssertTrue(integration.contains("sasCommit.callerRevealForDuplicateAccept(callId: callId)"),
                      "a duplicate ACCEPT is one event of the same budget")
    }

    // MARK: - T5: one event per confirmation expiry

    func testTheExpiryEventCarriesOnlyNumbersTheTimerNameAndEightCharacters() {
        let full = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let event = ConfirmTimeoutEvent(timer: .kcmacR1Callee, elapsedMs: 15_007, round: 1, reauths: 2, callId: full)
        XCTAssertEqual(event.callId8, "aaaaaaaa")
        XCTAssertEqual(event.logLine, "confirm_timeout timer=kcmac_r1_callee ms=15007 round=1 reauths=2 id=aaaaaaaa")
        XCTAssertFalse(event.logLine.contains(full))
        XCTAssertFalse(event.logLine.contains("bbbb"), "the call id is cut to 8 characters")
        // negative inputs are clamped, never printed as such
        let clamped = ConfirmTimeoutEvent(timer: .reveal, elapsedMs: -5, round: 1, reauths: -1, callId: "x")
        XCTAssertEqual(clamped.elapsedMs, 0)
        XCTAssertEqual(clamped.reauths, 0)
        XCTAssertEqual(clamped.callId8, "x")
    }

    func testTheFiveTimerNamesAreTheOnesOfTheSpec() {
        XCTAssertEqual(ConfirmTimerName.reveal.rawValue, "reveal")
        XCTAssertEqual(ConfirmTimerName.kcmacR1Caller.rawValue, "kcmac_r1_caller")
        XCTAssertEqual(ConfirmTimerName.kcmacR1Callee.rawValue, "kcmac_r1_callee")
        XCTAssertEqual(ConfirmTimerName.kcmacRound.rawValue, "kcmac_round")
        XCTAssertEqual(ConfirmTimerName.dtlsfpStats.rawValue, "dtlsfp_stats")
        XCTAssertEqual(ConfirmTimerName.kcMac(isRound1: true, isInitiator: true), .kcmacR1Caller)
        XCTAssertEqual(ConfirmTimerName.kcMac(isRound1: true, isInitiator: false), .kcmacR1Callee)
        XCTAssertEqual(ConfirmTimerName.kcMac(isRound1: false, isInitiator: true), .kcmacRound)
        XCTAssertEqual(ConfirmTimerName.kcMac(isRound1: false, isInitiator: false), .kcmacRound)
    }

    func testReauthsAreCountedPerCallInsideTheWaitThatExpired() {
        var log = ReauthLog()
        log.note(nowMs: 1_000)
        log.note(nowMs: 5_000)
        log.note(nowMs: 9_000)
        XCTAssertEqual(log.count(sinceMs: 0), 3)
        XCTAssertEqual(log.count(sinceMs: 5_000), 2, "only re-auths during the wait")
        XCTAssertEqual(log.count(sinceMs: 9_001), 0)
        for i in 0..<200 { log.note(nowMs: 10_000 + i) }
        XCTAssertEqual(log.times.count, ReauthLog.maxEntries, "bounded")

        let book = SasCommitBook()
        book.noteReauth(callId: callId, nowMs: 100)      // not a call of this book: ignored
        XCTAssertEqual(book.reauths(callId: callId, sinceMs: 0), 0)
        _ = book.beginCaller(callId: callId, nonce: nonce)
        book.noteReauth(callId: callId.uppercased(), nowMs: 200)
        book.noteReauth(callId: callId, nowMs: 300)
        XCTAssertEqual(book.reauths(callId: callId, sinceMs: 250), 1)
        XCTAssertEqual(book.reauths(callId: callId, sinceMs: 0), 2)
        book.clear(callId: callId)
        XCTAssertEqual(book.reauths(callId: callId, sinceMs: 0), 0)
    }

    /// Every expiry reports once: the KCMAC wait (only when it RAN OUT, not when a MAC failed), the REVEAL timer and the
    /// DTLS stats wait (only `stats_timeout`, not a real mismatch).
    func testEveryExpiryEmitsOneEvent() throws {
        let app = try sourceText(appPath)
        let appCode = code(app)
        XCTAssertTrue(appCode.contains("self.failKeyConfirmation(callId: event.callId, state: cur, expired: true)"),
                      "the deadline task reports an expiry")
        XCTAssertEqual(appCode.components(separatedBy: "expired: true").count - 1, 1, "only the deadline path is an expiry")
        let fail = code(try slice(app, from: "private func failKeyConfirmation(callId: String, state: KeyConfirmationCallState, expired: Bool = false) {",
                                  to: "/// T5 (R-CONFIRM-TELEMETRY): a confirmation timer ended the call."))
        let eventAt = try XCTUnwrap(fail.range(of: "reportConfirmTimeout(ConfirmTimeoutEvent("))
        let fatalAt = try XCTUnwrap(fail.range(of: "handleHandshakeFatal(callId: callId, reason: \"kcmac_mismatch\")"))
        XCTAssertLessThan(eventAt.lowerBound, fatalAt.lowerBound, "the event is emitted before the call ends")
        XCTAssertTrue(fail.contains("if expired {"))
        XCTAssertTrue(fail.contains("timer: ConfirmTimerName.kcMac(isRound1: state.isRound1, isInitiator: state.isInitiator)"))
        XCTAssertTrue(fail.contains("elapsedMs: nowMs - state.armedAtMs, round: state.round,"))
        XCTAssertTrue(fail.contains("sasCommit.reauths(callId: callId, sinceMs: state.armedAtMs)"))

        // the sink: one local line and one telemetry event, kind `confirm_timeout`
        XCTAssertTrue(appCode.contains("RTLog.warn(\"call\", event.logLine)"))
        XCTAssertTrue(appCode.contains("kind: \"confirm_timeout\""))
        for key in ["\"timer\"", "\"elapsedMs\"", "\"round\"", "\"reauths\"", "\"callId8\""] {
            XCTAssertTrue(appCode.contains(key), "telemetry attribute \(key)")
        }

        // the REVEAL timer is the integration's: the event goes out before the fatal
        let integration = try sourceText(integrationPath)
        let fired = code(try slice(integration, from: "private func sasRevealTimerFired(callId: String, armedAtMs: Int) {",
                                   to: "/// T5 (R-CONFIRM-TELEMETRY): a confirmation timer owned by this integration"))
        let revealEventAt = try XCTUnwrap(fired.range(of: "onConfirmTimeout?(ConfirmTimeoutEvent( timer: .reveal"))
        let revealFatalAt = try XCTUnwrap(fired.range(of: "reportHandshakeFatal(callId: callId, reason: reason)"))
        XCTAssertLessThan(revealEventAt.lowerBound, revealFatalAt.lowerBound)
        XCTAssertTrue(code(app).contains("integration.onConfirmTimeout = { [weak self] event in"), "wired where both integrations are set up")

        // the DTLS stats wait: only the `stats_timeout` stage, never a verified mismatch
        XCTAssertTrue(appCode.contains("DtlsFingerprint.isStatsTimeout(stage: stage) ? controller?.dtlsStatsElapsedMs : nil"))
        XCTAssertTrue(appCode.contains("timer: .dtlsfpStats, elapsedMs: statsWaitMs, round: 1,"))
        XCTAssertTrue(DtlsFingerprint.isStatsTimeout(stage: "stats_timeout"))
        XCTAssertFalse(DtlsFingerprint.isStatsTimeout(stage: "stats"), "a real certificate mismatch is not an expiry")
        XCTAssertFalse(DtlsFingerprint.isStatsTimeout(stage: "pin_timeout"))
    }

    // MARK: - T1: the caller sends its round-1 KCMAC right after the REVEAL, never gated on call_accepted

    func testTheCallerSendsItsRoundOneKcmacRightAfterTheRevealWithoutWaitingForCallAccepted() throws {
        let src = try sourceText(integrationPath)
        let callerLeg = try slice(src, from: "// R-COMMIT-REVEAL: the REVEAL leaves right after the round-1 session is installed",
                                  to: "// W529: caller's ACCEPT decapsulation succeeded")
        let c = code(callerLeg)
        let revealAt = try XCTUnwrap(c.range(of: "await sendSasReveal(wire, callId: callId, resend: false)"))
        let kcmacAt = try XCTUnwrap(c.range(of: "onKcMacReady?(KcMacReadyEvent( peerId: callerId, callId: callId, isInitiator: true,"))
        XCTAssertLessThan(revealAt.lowerBound, kcmacAt.lowerBound, "the MAC event follows the REVEAL")
        for gate in ["call_accepted", "callAccepted", "isAccepted", "awaitAccepted", "onConnected", "Task.sleep"] {
            XCTAssertFalse(c.contains(gate), "nothing between the REVEAL and the MAC waits for \(gate)")
        }

        // the app sends the caller's MAC at once: only a CALLEE is ever held (R-COMMIT-KCMAC-HOLD)
        let app = try sourceText(appPath)
        let handler = code(try slice(app, from: "private func handleKcMacReady(_ event: QAudionCallIntegration.KcMacReadyEvent) {",
                                     to: "// The wait for the peer's MAC (`KcMacWindow`)"))
        XCTAssertTrue(handler.contains("guard !event.isInitiator, let integration = self.responderCallIntegration,"),
                      "the hold applies to the callee only")
        for gate in ["call_accepted", "callAccepted", "acceptedCallId", "onConnected", "answeredCallKitId"] {
            XCTAssertFalse(handler.contains(gate), "the MAC is never held for \(gate)")
        }
        // and the caller's leg of the callback chain has no deferral behind the human answer
        XCTAssertTrue(code(app).contains("integration.onKcMacReady = { [weak self] event in Task { @MainActor [weak self] in self?.handleKcMacReady(event) } }"),
                      "caller leg: handled at once, no runOrDeferUntilAccepted")
    }

    // MARK: - T2: one callee path, answer first

    /// The flag is not read anywhere in code, there is no mode on the plan, and nothing is built or sent before the
    /// answer, whatever flags.json says or fails to say.
    func testThereIsNoPreAnswerModeAndNoFlagIsRead() throws {
        let app = code(try sourceText(appPath))
        XCTAssertFalse(app.contains("FeatureFlags.bool(\"calls.ring_signaling_only\""), "the flag is never read")
        XCTAssertFalse(app.contains("defaultMode"))
        XCTAssertFalse(app.contains("plan.mode"))
        XCTAssertFalse(app.contains(".mode == 1"))
        XCTAssertFalse(app.contains("signalingOnly"))
        let registry = code(try sourceText("QAudionEngine/Sources/QAudionEngine/Call/RingSignalingRegistry.swift"))
        XCTAssertFalse(registry.contains("public var mode"))
        XCTAssertFalse(registry.contains("_defaultMode"))
        XCTAssertFalse(registry.contains("mode: Int"))
        let flags = try sourceText("QAudionApp/Services/FeatureFlags.swift")
        XCTAssertFalse(code(flags).contains("ring_signaling_only"), "no code path names the flag")
    }

    /// An OFFER never builds a PeerConnection before the answer: the router only stashes the SDP (and starts the plane
    /// only for a call that was already answered); a call with no plan builds nothing.
    func testAnOfferNeverBuildsAPeerConnectionBeforeTheAnswer() throws {
        let app = try sourceText(appPath)
        let router = code(try slice(app, from: "func routeIncomingWebRtcOffer(\n        callerId: String,\n        sdp: String,\n        peerCapabilities: [String]? = nil,\n        hasVideo: Bool = false,\n        callId: String? = nil\n    ) {\n        let cid",
                                    to: "/// W347: handle inbound `call_offer` SDP via the WebRTC bridge."))
        XCTAssertFalse(router.contains("buildIncomingWebRtcMediaPlane("), "the router never builds")
        XCTAssertTrue(router.contains("guard !cid.isEmpty, let plan = RingSignalingRegistry.shared.entry(cid) else {"),
                      "no plan, no build")
        XCTAssertTrue(router.contains("if RingSignalingRegistry.shared.entry(cid)?.acceptedAtMs != nil { startIncomingMediaPlane(callId: cid, trigger: \"offer\") }"),
                      "only an already answered call builds")
        // the only builders are the accept-time start and the ring plan's own accept step
        let appCode = code(app)
        XCTAssertEqual(appCode.components(separatedBy: " buildIncomingWebRtcMediaPlane(").count - 1, 2,
                       "one definition and one call (startIncomingMediaPlane)")
        XCTAssertTrue(appCode.contains("guard !callId.isEmpty, RingSignalingRegistry.shared.entry(callId) != nil else { return } RingSignalingRegistry.shared.markAccepted(callId)"))
    }

    /// A call whose `call_incoming` has no id ends as `handshake_malformed` before anything rings; the integration
    /// refuses to put an ACCEPT of such a call on the wire.
    func testACallWithoutACallIdEndsAsHandshakeMalformedBeforeAnyAccept() throws {
        let app = try sourceText(appPath)
        let appCode = code(app)
        let guardAt = try XCTUnwrap(appCode.range(of: "if callIdStr.isEmpty { self.rejectIncomingCallWithoutCallId(senderId: senderId) return }"))
        let ageAt = try XCTUnwrap(appCode.range(of: "if let serverTs = (data[\"server_ts_ms\"] as? NSNumber)?.int64Value, serverTs > 0 {"))
        XCTAssertLessThan(guardAt.lowerBound, ageAt.lowerBound, "before the age gate, the ring and every provisioning step")
        XCTAssertTrue(appCode.contains("sendHangup(recipientId: senderId, reason: \"handshake_malformed\")"))
        let reject = code(try slice(app, from: "private func rejectIncomingCallWithoutCallId(senderId: String) {",
                                    to: "/// R-COMMIT-FIELD — a handshake bundle of the call peer that could not even be decoded"))
        XCTAssertFalse(reject.contains("latchIncomingNativeSrtpSnapshot"), "no ring plan")
        XCTAssertFalse(reject.contains("reportIncomingCall"), "no ring")

        let integration = try sourceText(integrationPath)
        let emit = code(try slice(integration, from: "private func emitJsonAccept(callId: String, wire: String, sendOpaqueRaw: @escaping (String) async throws -> Void, isRound1: Bool) async throws {",
                                  to: "/// Review fix — closes the check-then-store race of the two gates above"))
        let emptyAt = try XCTUnwrap(emit.range(of: "guard !cid.isEmpty else {"))
        let holdAt = try XCTUnwrap(emit.range(of: "if shouldHoldResponderAccept?(cid) == true {"))
        let sendAt = try XCTUnwrap(emit.range(of: "try await sendOpaqueRaw(wire)"))
        XCTAssertLessThan(emptyAt.lowerBound, holdAt.lowerBound)
        XCTAssertLessThan(holdAt.lowerBound, sendAt.lowerBound)
        XCTAssertTrue(emit.contains("reportHandshakeFatal(callId: callId, reason: \"handshake_malformed\") return }"))
    }

    /// The cold-start answer (the human answered before the `call_incoming` landed) takes the SAME path: the plan is
    /// latched and accepted in one step. It used to be the one case that fell back to the pre-answer mode.
    func testAColdStartAnswerTakesTheSamePathAsAnyOtherAnswer() throws {
        let app = code(try sourceText(appPath))
        XCTAssertTrue(app.contains("if latched, alreadyAnswered { self.beginAcceptedRingPlan(callId.lowercased(), trigger: \"coldanswer\") }"))
        XCTAssertTrue(app.contains("self.beginAcceptedRingPlan(ringPlanCallId, trigger: \"accept\")"))
        XCTAssertEqual(app.components(separatedBy: "RingSignalingRegistry.shared.markAccepted(").count - 1, 1,
                       "the accept-time step has one definition")
    }
}
