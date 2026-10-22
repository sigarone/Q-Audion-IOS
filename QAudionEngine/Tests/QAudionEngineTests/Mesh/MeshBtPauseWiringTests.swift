import XCTest
@testable import QAudionEngine

/// The WIRING of the Bluetooth call pause in the app target (docs/mesh/MESH_LINK_SPEC.md section 2.1). The decisions
/// are pinned by `MeshBtCallPauseTests`, `MeshCallDefinitionTests` and `MeshConnectBackoffTests`; what they cannot see
/// is whether the transport still asks them where it must: CoreBluetooth cannot be driven here. SOURCE INVARIANTS, the
/// same choice `NoticePushWiringTests` makes: comments are stripped and whitespace collapsed before matching, and a
/// missing file or marker FAILS, it never skips.
final class MeshBtPauseWiringTests: XCTestCase {

    private struct SourceProblem: Error, CustomStringConvertible {
        let what: String
        var description: String { what }
    }

    private func code(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try String(contentsOf: candidate, encoding: .utf8)
                let withoutComments = raw
                    .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
                    .map { line -> Substring in
                        if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                        return line
                    }
                    .joined(separator: "\n")
                return withoutComments.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
        }
        XCTFail("\(relativePath) not found from \(file): the wiring invariants cannot run", file: file, line: line)
        throw SourceProblem(what: "source file not found: \(relativePath)")
    }

    private func transport() throws -> String { try code("QAudionApp/Services/BleMeshTransport.swift") }
    private func runtime() throws -> String { try code("QAudionApp/Services/MeshRuntime.swift") }

    /// The text from the first `start` to the next `end` after it. Both must exist.
    private func slice(
        _ code: String, from start: String, to end: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let s = try XCTUnwrap(code.range(of: start), "marker not found: \(start)", file: file, line: line)
        let e = try XCTUnwrap(
            code.range(of: end, range: s.upperBound..<code.endIndex),
            "end marker not found after \(start): \(end)", file: file, line: line)
        return String(code[s.lowerBound..<e.lowerBound])
    }

    /// `first` occurs in `text` before `second`; both must occur.
    private func assertOrder(
        _ text: String, _ first: String, before second: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let a = try XCTUnwrap(text.range(of: first), "marker not found: \(first)", file: file, line: line)
        let b = try XCTUnwrap(text.range(of: second), "marker not found: \(second)", file: file, line: line)
        XCTAssertTrue(a.lowerBound < b.lowerBound, "\(first) must come before \(second)", file: file, line: line)
    }

    /// For every occurrence of `call`: the text of the function it is in, from its `func` keyword up to the call.
    private func enclosingPrefixes(
        of call: String, in code: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String] {
        var prefixes: [String] = []
        var searchFrom = code.startIndex
        while let hit = code.range(of: call, range: searchFrom..<code.endIndex) {
            let funcStart = try XCTUnwrap(
                code.range(of: "func ", options: .backwards, range: code.startIndex..<hit.lowerBound),
                "no function before \(call)", file: file, line: line)
            prefixes.append(String(code[funcStart.lowerBound..<hit.lowerBound]))
            searchFrom = hit.upperBound
        }
        return prefixes
    }

    // MARK: - Every discovery call site is behind the pause flag

    func testEveryScanStartIsBehindThePauseFlag() throws {
        let prefixes = try enclosingPrefixes(of: "scanForPeripherals(", in: try transport())
        XCTAssertEqual(prefixes.count, 1, "one place starts a scan")
        for prefix in prefixes {
            XCTAssertTrue(prefix.contains("guard active, !discoveryPaused,"), prefix)
        }
    }

    func testEveryAdvertisingStartIsBehindThePauseFlag() throws {
        let prefixes = try enclosingPrefixes(of: "startAdvertising(", in: try transport())
        XCTAssertEqual(prefixes.count, 1, "one place starts advertising")
        for prefix in prefixes {
            XCTAssertTrue(prefix.contains("guard !discoveryPaused else { return }"), prefix)
        }
    }

    func testEveryNewOutgoingConnectionIsBehindThePauseFlagAndTheBackoff() throws {
        let prefixes = try enclosingPrefixes(of: "central.connect(", in: try transport())
        XCTAssertEqual(prefixes.count, 1, "one place opens an outgoing link")
        for prefix in prefixes {
            XCTAssertTrue(prefix.contains("guard !discoveryPaused else { return }"), prefix)
            XCTAssertTrue(prefix.contains("guard !connectBackoff.isBackedOff(identifier.uuidString, nowMs: uptimeMs()) else { return }"), prefix)
        }
    }

    func testTheSystemIsNotAskedToKeepAConnectionPendingDuringAPause() throws {
        // State restoration hands back connections the system kept pending: a new outgoing link too.
        let restore = try slice(try transport(), from: "willRestoreState dict:", to: "private func setUpRestoredLinks()")
        XCTAssertTrue(restore.contains("let pendingWhilePaused = discoveryPaused && peripheral.state != .connected"))
        XCTAssertTrue(restore.contains("!pendingWhilePaused"))
        XCTAssertTrue(restore.contains("central.cancelPeripheralConnection(peripheral)"))
    }

    func testTheRestartsOfTheScanAreBehindThePauseFlagToo() throws {
        let text = try transport()
        let restart = try slice(text, from: "private func restartScan() {", to: "private func maybeStartAdvertisingAndServer()")
        XCTAssertTrue(restart.contains("guard active, !discoveryPaused,"))
        let soon = try slice(text, from: "private func restartScanSoon() {", to: "private func armSetupTimer")
        XCTAssertTrue(soon.contains("guard active, !discoveryPaused,"))
    }

    // MARK: - stop() clears the pause and the backoff

    func testStopClearsThePauseTheRecheckAndTheBackoff() throws {
        let stop = try slice(try transport(), from: "private func stopLocked() {", to: "func updateSchedule(")
        XCTAssertTrue(stop.contains("pauseRecheck?.cancel()"))
        XCTAssertTrue(stop.contains("pauseRecheck = nil"))
        XCTAssertTrue(stop.contains("callPause.reset()"))
        XCTAssertTrue(stop.contains("connectBackoff.removeAll()"))
    }

    func testThePauseIsEvaluatedOnlyWhileTheAntennaIsOn() throws {
        let evaluate = try slice(try transport(), from: "private func evaluateCallPause() {", to: "private func applyPause() {")
        XCTAssertTrue(evaluate.contains("guard active else { return }"))
    }

    // MARK: - When the pause is evaluated

    func testThePauseIsEvaluatedWhenFactsArriveAtStartInTheBackgroundAndWhenBluetoothPowersOn() throws {
        let text = try transport()
        let facts = try slice(text, from: "func setCallFacts(callActive: Bool, btRoute: Bool) {", to: "func setCallFactsRequest(")
        XCTAssertTrue(facts.contains("self.callActive = callActive"))
        XCTAssertTrue(facts.contains("self.btRoute = btRoute"))
        XCTAssertTrue(facts.contains("self.evaluateCallPause()"))

        let start = try slice(text, from: "private func startLocked(mode: MeshAntennaMode) {", to: "func stop() {")
        XCTAssertTrue(start.contains("evaluateCallPause()"))
        try assertOrder(start, "evaluateCallPause()", before: "maybeStartScanning()")

        let background = try slice(text, from: "private func setBackground(_ value: Bool) {", to: "private func modeToken()")
        XCTAssertTrue(background.contains("requestCallFacts()"))
        XCTAssertTrue(background.contains("evaluateCallPause()"))
        try assertOrder(background, "evaluateCallPause()", before: "restartScan()")

        let poweredOn = try slice(text, from: "case .poweredOn: requestCallFacts()", to: "case .poweredOff, .unauthorized")
        XCTAssertTrue(poweredOn.contains("evaluateCallPause()"))
        try assertOrder(poweredOn, "evaluateCallPause()", before: "maybeStartScanning()")
    }

    // MARK: - The route is never read on the Bluetooth queue

    func testTheTransportNeverReadsTheAudioRouteNorWaitsForTheMainThread() throws {
        let text = try transport()
        for forbidden in ["AVAudioSession", "AVFoundation", "currentRoute", "MeshAudioRoute", "CXCallObserver",
                          "main.sync", "assumeIsolated"] {
            XCTAssertFalse(text.contains(forbidden), "BleMeshTransport must not use \(forbidden): bleQueue never waits for the audio system or the main thread")
        }
        // The one synchronous hop is stop(), from the main thread into bleQueue; it is safe only because of the above.
        XCTAssertEqual(text.components(separatedBy: "bleQueue.sync").count - 1, 1)
    }

    func testTheRuntimeReadsTheRouteAndTheCallsOnTheMainThreadAndHandsThemOverTogether() throws {
        let text = try runtime()
        XCTAssertTrue(text.contains("@MainActor final class MeshRuntime"))

        let set = try slice(text, from: "func setCallActive(_ connected: Bool) {", to: "func refreshCallFacts() {")
        XCTAssertTrue(set.contains("ownCallConnected = connected"))
        XCTAssertTrue(set.contains("refreshCallFacts()"))

        let refresh = try slice(text, from: "func refreshCallFacts() {", to: "private let readSystemCalls")
        XCTAssertTrue(refresh.contains("slot.existingTransport?.setCallFacts(callActive: facts.callActive, btRoute: facts.btRoute)"))
        XCTAssertTrue(refresh.contains("MeshCallDefinition.callActive(ownCallConnected: ownCallConnected, systemCalls: readSystemCalls())"))
        XCTAssertTrue(refresh.contains("btRoute = readBluetoothRoute()"))

        // The route is read through one reader only.
        XCTAssertEqual(text.components(separatedBy: "MeshAudioRoute.currentRouteUsesBluetooth()").count - 1, 1)
    }

    func testARadioThatStartsGetsTheFactsBeforeItStarts() throws {
        let setAntenna = try slice(try runtime(), from: "transport.delegate = self", to: "MeshOutboxDrain.shared.start()")
        try assertOrder(setAntenna, "startObservingCallFacts()", before: "let facts = readCallFacts()")
        try assertOrder(setAntenna, "let facts = readCallFacts()", before: "transport.setCallFacts(callActive: facts.callActive, btRoute: facts.btRoute)")
        try assertOrder(setAntenna, "transport.setCallFactsRequest {", before: "transport.start(schedule:")
        try assertOrder(setAntenna, "transport.setCallFacts(callActive: facts.callActive, btRoute: facts.btRoute)", before: "transport.start(schedule:")
    }

    func testTheDeviceIsObservedOnlyWhileTheAntennaIsOn() throws {
        let text = try runtime()
        let off = try slice(text, from: "guard let mode else {", to: "guard startAllowed")
        XCTAssertTrue(off.contains("stopObservingCallFacts()"))
        let stop = try slice(text, from: "private func stopObservingCallFacts() {", to: "var startAllowed: Bool {")
        XCTAssertTrue(stop.contains("systemCalls?.stop()"))
        XCTAssertTrue(stop.contains("NotificationCenter.default.removeObserver(routeObserver)"))
        // Nothing starts an observer at launch: only the antenna does.
        XCTAssertEqual(text.components(separatedBy: "calls.start()").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: "startObservingCallFacts()").count - 1, 2, "its definition and the one call")
        let system = try code("QAudionApp/Services/MeshSystemCalls.swift")
        XCTAssertTrue(system.contains("let calls = observer?.calls ?? []"), "nothing is listed while it does not observe")
    }

    func testTheRuntimeNeverStartsTheRadioForACallFact() throws {
        let text = try runtime()
        let calls = try slice(text, from: "private(set) var ownCallConnected = false", to: "private let readSystemCalls")
        XCTAssertFalse(calls.contains("setAntenna("))
        XCTAssertFalse(calls.contains(".start("))
    }

    // MARK: - The backoff

    func testAFailedAttemptIsCountedByThePositiveListAndOnlyWhenTheCauseIsTheAdvertiser() throws {
        let text = try transport()
        let tearDown = try slice(text, from: "private func tearDown(", to: "private func disconnect(")
        XCTAssertTrue(tearDown.contains(
            "if countsAsFailure, MeshConnectBackoff.isFailedAttempt(outgoing: link.isOutgoing, announceReceived: link.announceReceived, reason: finalReason) {"))
        XCTAssertTrue(tearDown.contains("connectBackoff.recordFailure(link.identifier.uuidString, nowMs: uptimeMs())"))
        // Bluetooth switched off is no fault of the advertiser.
        XCTAssertTrue(text.contains("tearDown(link, reason: \"remote\", cancelConnection: false, countsAsFailure: false)"))
        // The pause gives up an attempt with the reason `stop`, which the list does not contain.
        let pause = try slice(text, from: "private func applyPause() {", to: "private func applyResume(")
        XCTAssertTrue(pause.contains("disconnect(link, reason: \"stop\")"))
    }

    func testAnAnnounceClearsTheBackoffOfItsLink() throws {
        let announce = try slice(try transport(), from: "link.announceReceived = true", to: "var bound = false")
        XCTAssertTrue(announce.contains("connectBackoff.clear(link.identifier.uuidString)"))
    }

    // MARK: - The app's own call

    func testTheOwnCallIsConnectedOnlyWhenItIsActiveNotWhenItRings() throws {
        let appState = try code("QAudionApp/AppState.swift")
        let own = try slice(appState, from: "private func updateMeshCallState() {", to: "func routeGroupCallAudioToSpeaker() {")
        XCTAssertTrue(own.contains("let oneToOneConnected = callState == .active || callState == .encrypted"))
        XCTAssertTrue(own.contains("if case .active = groupCallControllerState { return true }"))
        XCTAssertTrue(own.contains("MeshRuntime.shared.setCallActive(oneToOneConnected || groupConnected)"))

        // The auto-lock hold (which counts a ringing call) is not the mesh's signal.
        let idle = try slice(appState, from: "private func updateIdleTimer() {", to: "private func updateMeshCallState() {")
        XCTAssertFalse(idle.contains("MeshRuntime"))

        let callState = try slice(appState, from: "@Published var callState: CallState = .idle {", to: "@Published var callContactId")
        XCTAssertTrue(callState.contains("updateMeshCallState()"))
        let group = try slice(appState, from: "@Published var groupCallControllerState: GroupCallController.State = .idle {", to: "groupDiag(GroupDiagnostics.stateLine")
        XCTAssertTrue(group.contains("updateMeshCallState()"))
    }

    func testTheCallsOfTheDeviceComeFromTheSystemObserverWithoutAnyEntitlementOrOwnState() throws {
        let calls = try code("QAudionApp/Services/MeshSystemCalls.swift")
        XCTAssertTrue(calls.contains("CXCallObserver()"))
        XCTAssertTrue(calls.contains("MeshCallDefinition.SystemCall(hasConnected: $0.hasConnected, hasEnded: $0.hasEnded)"))
        XCTAssertTrue(calls.contains("created.setDelegate(self, queue: .main)"))
        // The definition itself lives in the engine and is tested there.
        let definition = try code("QAudionEngine/Sources/QAudionEngine/Mesh/MeshCallDefinition.swift")
        XCTAssertTrue(definition.contains("call.hasConnected && !call.hasEnded"))
    }
}
