import XCTest
@testable import QAudionEngine

/// W-VOIPSYNC (2026-10-08) — the PushKit callback reports to CallKit before it returns.
///
/// Incidents b0d7ba30 and eb2a6367 (2026-10-07): PushKit killed the app ("Killing app because it never posted an
/// incoming call to the system after receiving a PushKit VoIP push") 0.8 s after the push, with not one line from the
/// push path in the crash ring. The report used to sit behind a Task, the delegate's WEAK owner and a main-actor hop.
///
/// The pure pieces (classification, the placeholder, the diagnostic lines) are tested directly. The delegate itself
/// cannot be driven here (`PKPushPayload` has no public initializer, the registry needs a real PushKit), so its shape
/// is pinned by SOURCE INVARIANTS, the same choice `CallerBusyWiringTests` makes: no await / Task / main-actor hop and
/// no weak owner before the report, `completion()` only inside CallKit's completion, a strongly held reporter, one
/// registry per process, and AppState's PushKit handlers without a report of their own. Comments are stripped and
/// whitespace collapsed before matching, so only code counts. What none of this proves: that iOS now keeps the app
/// alive on a real phone — only a device test (VoIP push to a suspended app) shows that.
final class VoipPushSyncReportTests: XCTestCase {

    // MARK: - classification (same precedence the delegate always used)

    private let callId = UUID(uuidString: "B0D7BA30-655B-420D-A4ED-8848EFC51C98")!

    private var incomingDict: [String: Any] {
        ["type": "incoming_call", "call_id": callId.uuidString, "caller_id": "u1", "caller_name": "A", "call_type": "video"]
    }

    func testAnIncomingCallPushIsClassifiedAsIncoming() {
        guard case .incoming(let p) = PushKitProvider.classify(incomingDict) else {
            return XCTFail("expected .incoming")
        }
        XCTAssertEqual(p.callId, callId)
        XCTAssertTrue(p.hasVideo)
        XCTAssertEqual(PushKitProvider.classify(incomingDict).kindCode, 1)
    }

    func testGroupOpaqueAndCancelPushesAreClassifiedInOrder() {
        let group: [String: Any] = ["type": "incoming_group_call", "call_id": "1bc455b8-0000-0000-0000-000000000000",
                                    "creator_id": "c1"]
        let opaque: [String: Any] = ["type": "opaque_wakeup", "kind": "call", "shash": "ab", "ts": "1"]
        let cancel: [String: Any] = ["type": "call_cancelled", "call_id": callId.uuidString]
        XCTAssertEqual(PushKitProvider.classify(group).kindCode, 2)
        XCTAssertEqual(PushKitProvider.classify(opaque).kindCode, 3)
        XCTAssertEqual(PushKitProvider.classify(cancel).kindCode, 4)
    }

    func testAnythingElseIsUnparsed() {
        let dicts: [[String: Any]] = [
            [:],
            ["type": "incoming_call", "call_id": "not-a-uuid", "caller_id": "u", "caller_name": "n"],
            ["type": "opaque_wakeup", "kind": "message"],
            ["type": "call_cancelled"],
            ["type": "something_new", "call_id": UUID().uuidString],
        ]
        for dict in dicts {
            let event = PushKitProvider.classify(dict)
            XCTAssertTrue(event.isUnparsed, "\(dict)")
            XCTAssertEqual(event.kindCode, 0)
            XCTAssertNil(event.id8)
        }
    }

    func testTheEventCarriesTheCallIdPrefixOnlyWhenThereIsOne() {
        XCTAssertEqual(PushKitProvider.classify(incomingDict).id8, "b0d7ba30")
        let cancel: [String: Any] = ["type": "call_cancelled", "call_id": callId.uuidString]
        XCTAssertEqual(PushKitProvider.classify(cancel).id8, "b0d7ba30")
        let opaque: [String: Any] = ["type": "opaque_wakeup", "kind": "call"]
        XCTAssertNil(PushKitProvider.classify(opaque).id8)
        let oddGroup: [String: Any] = ["type": "incoming_group_call", "call_id": "room-name", "creator_id": "c1"]
        XCTAssertNil(PushKitProvider.classify(oddGroup).id8, "a non-hex room id never reaches the line")
    }

    // MARK: - what is reported

    func testAnUnparsedPushIsReportedAsAPlaceholderThatEndsAtOnce() {
        let given = PushKitProvider.ReportSpec(uuid: callId, callerName: "X", hasVideo: true, endReason: nil)
        let spec = PushKitProvider.resolveSpec(event: .unparsed, prepared: given)
        XCTAssertNotEqual(spec.uuid, callId, "an unparsed push never reports a uuid the app chose")
        XCTAssertEqual(spec.callerName, "Q-Audion")
        XCTAssertFalse(spec.hasVideo)
        XCTAssertEqual(spec.endReason, .failed("malformed-voip-push"))
    }

    func testNoOwnerOrNoHandlerStillReportsAPlaceholder() {
        let event = PushKitProvider.classify(incomingDict)
        let spec = PushKitProvider.resolveSpec(event: event, prepared: nil)
        XCTAssertEqual(spec.callerName, PushKitProvider.placeholderCallerName)
        XCTAssertEqual(spec.endReason, .failed("malformed-voip-push"))
    }

    func testTheAppsOwnSpecIsReportedUnchanged() {
        let event = PushKitProvider.classify(incomingDict)
        let given = PushKitProvider.ReportSpec(uuid: callId, callerName: "Marco", hasVideo: true, endReason: nil)
        let spec = PushKitProvider.resolveSpec(event: event, prepared: given)
        XCTAssertEqual(spec.uuid, callId)
        XCTAssertEqual(spec.callerName, "Marco")
        XCTAssertTrue(spec.hasVideo)
        XCTAssertNil(spec.endReason)
    }

    func testEveryPlaceholderHasAFreshUuid() {
        XCTAssertNotEqual(PushKitProvider.placeholderSpec().uuid, PushKitProvider.placeholderSpec().uuid)
    }

    // MARK: - the diagnostic lines (same text as scripts/test_ship_ios_voip_vocab.py checks against the shipper)

    func testTheDiagnosticLinesHaveTheirExactShape() {
        typealias D = VoipPushDiagnostics
        XCTAssertEqual(D.rxLine(kind: 1, owner: true, initCount: 1, appState: 2, id8: "b0d7ba30"),
                       "voip rx kind=1 owner=1 init=1 state=2 call8=b0d7ba30")
        XCTAssertEqual(D.rxLine(kind: 3, owner: false, initCount: 2, appState: 0, id8: nil),
                       "voip rx kind=3 owner=0 init=2 state=0")
        XCTAssertEqual(D.initLine(count: 1, site: D.siteRegistry), "voip init count=1 site=1")
        XCTAssertEqual(D.initLine(count: 2, site: D.siteAppInitialize), "voip init count=2 site=2")
        XCTAssertEqual(D.initSkippedLine(), "voip init skip=1 site=2")
        XCTAssertEqual(D.initNoReporterLine(), "voip init count=0 site=1")
        XCTAssertEqual(
            D.reportLine(kind: 4, outcome: .init(ok: true, code: 0, duplicate: false), ms: 61, id8: "eb2a6367"),
            "voip report kind=4 ok=1 code=0 dup=0 ms=61 call8=eb2a6367")
        XCTAssertEqual(
            D.reportLine(kind: 1, outcome: .init(ok: false, code: 3, duplicate: true), ms: 5, id8: nil),
            "voip report kind=1 ok=0 code=3 dup=1 ms=5")
        XCTAssertEqual(D.doneLine(kind: 1, ok: true, ms: 75), "voip done kind=1 ok=1 ms=75")
        XCTAssertEqual(D.lateLine(kind: 0, ms: D.lateAfterMs), "voip late kind=0 ms=2000")
    }

    func testTheExtremeValuesKeepTheShape() {
        typealias D = VoipPushDiagnostics
        XCTAssertEqual(D.rxLine(kind: 1, owner: false, initCount: 99999, appState: 1, id8: "00000000"),
                       "voip rx kind=1 owner=0 init=99999 state=1 call8=00000000")
        XCTAssertEqual(
            D.reportLine(kind: 2, outcome: .init(ok: false, code: 99999, duplicate: true), ms: 9_999_999,
                         id8: "abcdef01"),
            "voip report kind=2 ok=0 code=99999 dup=1 ms=9999999 call8=abcdef01")
        XCTAssertEqual(D.doneLine(kind: 0, ok: true, ms: 9_999_999), "voip done kind=0 ok=1 ms=9999999")
    }

    func testTheIdPrefixIsHexOnlyAndLowerCase() {
        XCTAssertEqual(VoipPushDiagnostics.id8("B0D7BA30-655B-420D-A4ED-8848EFC51C98"), "b0d7ba30")
        XCTAssertEqual(VoipPushDiagnostics.id8("00000000"), "00000000")
        XCTAssertNil(VoipPushDiagnostics.id8("b0d7ba3"), "too short")
        XCTAssertNil(VoipPushDiagnostics.id8("room-1234"))
        XCTAssertNil(VoipPushDiagnostics.id8("Marco Rossi"))
    }

    // MARK: - reading the source

    private struct SourceNotFound: Error, CustomStringConvertible {
        let path: String
        var description: String { "source file not found: \(path)" }
    }

    /// `relativePath` (from the repository root), line comments stripped and every run of whitespace collapsed to one
    /// space. A missing file is `XCTFail` and a thrown error, never `XCTSkip`.
    private func code(
        _ relativePath: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try String(contentsOf: candidate, encoding: .utf8)
                let withoutComments = raw
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line -> Substring in
                        if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                        return line
                    }
                    .joined(separator: "\n")
                return withoutComments.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
        }
        XCTFail("\(relativePath) not found from \(file): the wiring invariants cannot run", file: file, line: line)
        throw SourceNotFound(path: relativePath)
    }

    private func pushKitCode() throws -> String {
        try code("QAudionEngine/Sources/QAudionEngine/Integration/PushKitProvider.swift")
    }

    private func callKitCode() throws -> String {
        try code("QAudionEngine/Sources/QAudionEngine/Integration/CallKitProvider.swift")
    }

    private func appCode() throws -> String { try code("QAudionApp/AppState.swift") }

    /// The text from the first `start` to the next `end` after it. Both markers must exist.
    private func slice(
        _ code: String, from start: String, to end: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let s = try XCTUnwrap(code.range(of: start), "marker not found: \(start)", file: file, line: line)
        let e = try XCTUnwrap(
            code.range(of: end, range: s.upperBound..<code.endIndex),
            "end marker not found after \(start): \(end)", file: file, line: line)
        return String(code[s.lowerBound..<e.lowerBound])
    }

    private func assertOrder(
        _ body: String, _ first: String, before second: String, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let a = body.range(of: first) else { return XCTFail("missing: \(first)", file: file, line: line) }
        guard let b = body.range(of: second) else { return XCTFail("missing: \(second)", file: file, line: line) }
        XCTAssertLessThan(a.lowerBound, b.lowerBound, message, file: file, line: line)
    }

    private func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private let callbackStart = "didReceiveIncomingPushWith payload: PKPushPayload,"
    private let reportCall = "reporter.reportIncomingCallNow("
    private let callbackEnd = "fileprivate static func onMain("

    // MARK: - the PushKit callback

    /// Between the callback's entry and the hand-off to CallKit: nothing that suspends, defers or hops.
    func testNothingSuspendsOrHopsBeforeTheReport() throws {
        let beforeReport = try slice(try pushKitCode(), from: callbackStart, to: reportCall)
        for forbidden in ["await ", "Task {", "Task.detached", "MainActor.run", "DispatchQueue.main.async {",
                          "self.owner?."] {
            XCTAssertFalse(beforeReport.contains(forbidden), "before the report: \(forbidden)")
        }
        XCTAssertTrue(beforeReport.contains("MainActor.assumeIsolated"),
                      "the main-actor prepare runs inline (the registry's queue is .main)")
    }

    func testTheFirstLineIsLoggedBeforeThePrepareAndTheReport() throws {
        let beforeReport = try slice(try pushKitCode(), from: callbackStart, to: reportCall)
        assertOrder(beforeReport, "VoipPushDiagnostics.rxLine(", before: "owner.prepare(event)",
                    "`voip rx` is the first line, before anything that could kill or block")
        assertOrder(beforeReport, "log?(rxLine)", before: "owner.prepare(event)", "the rx line is logged first")
    }

    /// PushKit raises as soon as completion() runs without a report, so it must only run inside CallKit's answer —
    /// after the end of a report-and-end spec and after the app's follow-up. The one exception is the non-VoIP guard.
    func testCompletionRunsOnlyInsideCallKitsCompletion() throws {
        let callback = try slice(try pushKitCode(), from: callbackStart, to: callbackEnd)
        XCTAssertEqual(count("completion()", in: callback), 2, "the non-VoIP guard and the CallKit completion")
        let afterGuard = try slice(callback, from: "guard type == .voIP else { completion(); return }", to: reportCall)
        XCTAssertEqual(count("completion()", in: afterGuard), 1, "only the guard's own, before the report")
        let afterReport = try slice(callback, from: reportCall, to: "completion() }")
        assertOrder(afterReport, "reporter.reportCallEndedNow(uuid: spec.uuid, reason: reason)",
                    before: "log?(VoipPushDiagnostics.doneLine(", "a cancel / placeholder is ended before completion")
        assertOrder(afterReport, "owner.afterReport(event, spec, outcome)",
                    before: "log?(VoipPushDiagnostics.doneLine(", "the app's follow-up runs before completion")
        XCTAssertTrue(afterReport.contains("log?(VoipPushDiagnostics.reportLine("))
    }

    func testEveryPushIsReportedEvenWithoutOwnerOrHandler() throws {
        let callback = try slice(try pushKitCode(), from: callbackStart, to: callbackEnd)
        XCTAssertTrue(callback.contains(
            "let spec: ReportSpec = PushKitProvider.resolveSpec(event: event, prepared: prepared)"))
        XCTAssertEqual(count(reportCall, in: callback), 1, "one report per push, unconditional")
        XCTAssertFalse(callback.contains("guard let reporter"), "the report never depends on an optional")
    }

    func testTheReporterIsHeldStrongly() throws {
        let src = try pushKitCode()
        XCTAssertTrue(src.contains("private let reporter: VoipCallReporter"))
        XCTAssertTrue(src.contains("weak var owner: PushKitProvider? var reporter: VoipCallReporter var log:"),
                      "the delegate keeps its own strong reference next to the weak owner")
        XCTAssertTrue(src.contains("init(reporter: VoipCallReporter) { self.reporter = reporter }"))
        XCTAssertFalse(src.contains("weak var reporter"))
        XCTAssertFalse(src.contains("unowned"))
        XCTAssertTrue(src.contains("let reporter: VoipCallReporter = self.reporter"))
    }

    func testThereIsOneRegistryPerProcess() throws {
        let src = try pushKitCode()
        XCTAssertEqual(count("PKPushRegistry(queue: .main)", in: src), 1)
        let initBody = try slice(src, from: "public init(reporter: VoipCallReporter,", to: "#endif")
        assertOrder(initBody, "if let registry = PushKitProvider.sharedRegistry", before: "PKPushRegistry(queue: .main)",
                    "an existing registry is reused, never replaced")
        assertOrder(initBody, "registry.delegate = delegate registry.desiredPushTypes = [.voIP]",
                    before: "VoipPushDiagnostics.initLine(", "delegate first, push types second")
    }

    // MARK: - CallKitProvider: one implementation, one ledger

    func testTheAsyncReportIsAWrapperOfTheSynchronousOne() throws {
        let body = try slice(
            try callKitCode(), from: "public func reportIncomingCall(uuid: UUID, callerName: String, hasVideo: Bool) async {",
            to: "public func reportIncomingCallNow(")
        XCTAssertTrue(body.contains("reportIncomingCallNow(uuid: uuid, callerName: callerName, hasVideo: hasVideo)"))
        XCTAssertFalse(body.contains("provider.reportNewIncomingCall"), "only one place talks to CallKit")
    }

    func testTheSynchronousReportUsesTheLedgerClaim() throws {
        let body = try slice(
            try callKitCode(), from: "public func reportIncomingCallNow(", to: "private func finishIncomingReport(")
        assertOrder(body, "let claimed: Bool = ledger.beginReport(uuid)",
                    before: "provider.reportNewIncomingCall(with: uuid, update: update)", "claim before the report")
        assertOrder(body, "self.finishIncomingReport(", before: "if claimed { self.ledger.finishReport(uuid) }",
                    "ledger updated before the claim is released, as the old defer did")
        assertOrder(body, "if claimed { self.ledger.finishReport(uuid) }", before: "completion(outcome)",
                    "the caller hears back last")
        let finish = try slice(
            try callKitCode(), from: "private func finishIncomingReport(",
            to: "public func reportCallEnded(uuid: UUID, reason: CallEndReason) async {")
        XCTAssertTrue(finish.contains("ledger.recordNativeReport(uuid)"))
        XCTAssertTrue(finish.contains("CallKitReportFailurePolicy.shouldArmManualAnswer( alreadyReported: alreadyUp, errorCode: nsErr.code)"))
        XCTAssertTrue(finish.contains("ledger.recordRejected(uuid)"))
    }

    func testTheAsyncEndIsTheSynchronousOne() throws {
        let body = try slice(
            try callKitCode(), from: "public func reportCallEnded(uuid: UUID, reason: CallEndReason) async {",
            to: "public func reportCallEndedNow(")
        XCTAssertTrue(body.contains("reportCallEndedNow(uuid: uuid, reason: reason)"))
    }

    // MARK: - AppState

    func testInitializeRegistersPushKitOncePerProcess() throws {
        let src = try appCode()
        let block = try slice(
            src, from: "W-NOCALLKIT callKitFreeMode ON — PushKit/VoIP NOT registered; using APNs alert path",
            to: "#endif if let token = authService.loadToken()")
        assertOrder(block, "} else if self.pushKit != nil {", before: "self.pushKit = PushKitProvider(",
                    "a second initialize() keeps the registration it has")
        XCTAssertTrue(block.contains("RTLog.warn(\"call\", VoipPushDiagnostics.initSkippedLine())"))
        XCTAssertTrue(block.contains("reporter: voipReporter,"))
        XCTAssertTrue(src.contains(
            "AppState.initializeCount += 1 RTLog.info(\"call\", VoipPushDiagnostics.initLine( count: AppState.initializeCount, site: VoipPushDiagnostics.siteAppInitialize))"))
    }

    /// The handlers no longer report: the provider did, inside the callback. A report here would be a second one.
    func testThePushHandlersHaveNoReportOfTheirOwn() throws {
        let src = try appCode()
        let block = try slice(src, from: "self.pushKit = PushKitProvider(", to: "#endif if let token = authService.loadToken()")
        XCTAssertFalse(block.contains("reportIncomingCall("))
        XCTAssertFalse(block.contains("reportCallEnded("))
        let prepare = try slice(src, from: "func prepareVoipPushReport(", to: "func finishVoipPushReport(")
        for forbidden in ["await ", "Task {", "MainActor.run", "reportIncomingCall(", "reportCallEnded("] {
            XCTAssertFalse(prepare.contains(forbidden), "prepare runs inside the PushKit callback: \(forbidden)")
        }
        XCTAssertTrue(prepare.contains("prepareIncomingPushCall("), "activeCallKitId is still set before the report")
        let finish = try slice(src, from: "func finishVoipPushReport(", to: "private func planIncomingCancelReport(")
        XCTAssertFalse(finish.contains("reportIncomingCall("))
        XCTAssertFalse(finish.contains("reportCallEnded("))
        XCTAssertTrue(finish.contains("await self?.reviveSignalingSocket()"))
        XCTAssertTrue(finish.contains("await self?.reconcileOpaqueCallWakeup(placeholderCallKitId: placeholder)"))
        assertOrder(finish, "self.recordMissedOnCancelPush(callId: payload.callId)",
                    before: "self.incomingCallRingVisible = false", "the missed call is recorded while the ring is up")
    }
}
