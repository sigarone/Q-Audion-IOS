import XCTest
@testable import QAudionEngine

/// Source-invariant guard for where the faster-switch flag is read and used. The decisions are
/// proven in `FastSwitchDecisionsTests`; the real call sites need WebRTC and a live socket. A
/// missing file or anchor FAILS (never skips).
final class FastSwitchWiringTests: XCTestCase {

    private func repoRoot(file: StaticString = #filePath, line: UInt = #line) -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("QAudionApp/AppState.swift").path) { return dir }
        }
        XCTFail("repo root not found from \(file)", line: line)
        return dir
    }

    private func read(_ relative: String, line: UInt = #line) -> String {
        guard let text = try? String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8),
              !text.isEmpty else {
            XCTFail("cannot read \(relative)", line: line)
            return ""
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testEveryCallSetupSiteReadsTheFlagOnceThroughASnapshot() {
        let app = read("QAudionApp/AppState.swift")
        XCTAssertEqual(count("\"calls.ice_fastswitch\"", in: app), 3)
        XCTAssertEqual(count("controller.iceFastSwitchProvider = CallFlagProviders.snapshot { FeatureFlags.bool(\"calls.ice_fastswitch\", false) }", in: app), 3)
        XCTAssertEqual(count("controller.dtlsAnswerPassiveKillSwitchProvider = CallFlagProviders.snapshot", in: app), 3,
                       "the flag is wired at the same sites as the other call flags")
    }

    func testTheFlagDefaultsToFalseAndIsDocumented() {
        XCTAssertTrue(read("QAudionApp/Services/FeatureFlags.swift").contains("`calls.ice_fastswitch` | Bool | `false`"))
        XCTAssertFalse(read("QAudionApp/AppState.swift").contains("\"calls.ice_fastswitch\", true"))
    }

    func testTheRestartSkipsTheReprobeOnlyThroughTheDecision() {
        let ctl = read("QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift")
        XCTAssertTrue(ctl.contains("FastSwitchDecisions.usesCachedServersForRestart(\n            flagOn: fastSwitchOn, reason: reason, forceProbe: forceProbe,\n            peerRequestBypass: peerAction == .bypassGates)"))
        XCTAssertTrue(ctl.contains("if !cachedServers, let liveConnection = peerConnection {"))
        XCTAssertEqual(count("await refreshIceServersForRestart(on:", in: ctl), 1, "a single probe call site remains")
    }

    /// One ICE-restart offer per trigger: the offering path of `restartIce` creates exactly one
    /// restart offer, the fast path adds no priming call before it, and the fallback is one
    /// guarded repeat that goes through `restartIce` itself (never a second createOffer).
    func testOnlyOneRestartOfferIsCreatedPerTrigger() {
        let ctl = read("QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift")
        guard let a = ctl.range(of: "public func restartIce(reason: String, forceProbe: Bool = false) async {"),
              let b = ctl.range(of: "/// D6 (2026-09-28, TURN-stuck-on-P2P fix, owner-requested) \u{2014} watches") ?? ctl.range(of: "private func startP2pProbeWatch") else {
            XCTFail("restartIce anchors not found")
            return
        }
        let body = String(ctl[a.lowerBound..<b.lowerBound])
        XCTAssertEqual(count("createOffer(audioOnly: true, iceRestart: true)", in: body), 1)
        XCTAssertEqual(count("sendIceRestartOffer(", in: body), 2,
                       "the same-offer resend for a peer request, and the main path; the park closure lives in makeFastParkDelivery")
        XCTAssertEqual(count("primeIceRestart()", in: body), 2,
                       "the responder request-first prime and the one before a request inside the gate, neither sends an offer")
        XCTAssertFalse(ctl.contains("primesRestartAtTrigger"))
        XCTAssertEqual(count("createOffer(audioOnly: true, iceRestart: true)", in: ctl), 1,
                       "no other site mints a restart offer")
        XCTAssertEqual(count("await self.restartIce(reason: FastSwitchDecisions.fallbackReason, forceProbe: true)", in: ctl), 1)
    }

    /// The parked resend of a fast restart re-sends the same offer: the park delivery closure is
    /// only built when `parkedResendMintsNewOffer` says so, and nil is what `sendIceRestartOffer`
    /// turns into "resend the same SDP".
    func testAParkedResendOnTheFastPathCreatesNoSecondOffer() {
        let ctl = read("QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift")
        XCTAssertTrue(ctl.contains("if FastSwitchDecisions.parkedResendMintsNewOffer(cachedServers: cachedServers) {\n            parkDelivery = {"))
        XCTAssertTrue(ctl.contains("onParkDelivery: parkDelivery"))
        let api = read("QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoCallingApiImpl.swift")
        XCTAssertTrue(api.contains("if let onParkDelivery {"), "the park hands delivery to the closure, which re-sends the same SDP")
    }

    /// A parked fast restart that is later delivered logs trig_sent_ms (from the original trigger,
    /// once) and arms the fallback at that moment, and still mints no new offer.
    func testAParkedFastRestartArmsTheFallbackWhenDelivered() {
        let ctl = read("QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift")
        guard let a = ctl.range(of: "private func makeFastParkDelivery("),
              let b = ctl.range(of: "public func restartIce(reason: String, forceProbe: Bool = false) async {"),
              let c = ctl.range(of: "// Fast path: on socket recovery re-send THIS offer"),
              let d = ctl.range(of: "let sent = await callingApi.sendIceRestartOffer(") else {
            XCTFail("anchors not found")
            return
        }
        let body = String(ctl[a.lowerBound..<b.lowerBound])
        XCTAssertTrue(body.contains("onParkDelivery: nil"), "the same SDP is re-sent")
        XCTAssertFalse(body.contains("createOffer"), "no second offer")
        XCTAssertTrue(body.contains("self.noteFastSwitchSent()"))
        XCTAssertTrue(body.contains("self.startFastSwitchProbeFallback()"))
        XCTAssertTrue(body.contains("== connection"))
        let site = String(ctl[c.lowerBound..<d.lowerBound])
        XCTAssertTrue(site.contains("parkDelivery = makeFastParkDelivery("))
        XCTAssertFalse(site.contains("createOffer"), "no second offer")
        // noteFastSwitchSent reads the trigger stamp kept from the original trigger and logs once.
        XCTAssertTrue(ctl.contains("fastSwitchSentLogged = true"))
    }

    /// A refused restart (debounce or gate) must leave the pending fallback armed: the trigger is
    /// only adopted inside `restartIce`, after the refusal check, and the path monitor merely stamps.
    func testOnlyAnAcceptedRestartReplacesThePendingFallback() {
        let ctl = read("QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift")
        guard let stamp = ctl.range(of: "private func noteFastSwitchTrigger() {"),
              let adopt = ctl.range(of: "private func adoptFastSwitchTrigger(fast: Bool, trigLabel: String? = nil) {"),
              let sent = ctl.range(of: "private func noteFastSwitchSent() {") else {
            XCTFail("anchors not found")
            return
        }
        let stampBody = String(ctl[stamp.lowerBound..<adopt.lowerBound])
        XCTAssertFalse(stampBody.contains("fastSwitchFallbackTask"), "the path trigger must not cancel the fallback")
        let adoptBody = String(ctl[adopt.lowerBound..<sent.lowerBound])
        XCTAssertTrue(adoptBody.contains("fastSwitchFallbackTask?.cancel()"))
        guard let refusal = ctl.range(of: "log?(\"restart_ice \\(refusal)=1 reason=\\(reason)\")"),
              let adoptCall = ctl.range(of: "adoptFastSwitchTrigger(fast: fastSwitchOn)") else {
            XCTFail("restartIce anchors not found")
            return
        }
        XCTAssertLessThan(refusal.lowerBound, adoptCall.lowerBound, "adopted only after the refusal check")
        XCTAssertTrue(adoptBody.contains("if fast { startFastSwitchRxWatch() }"), "no polling with the flag off")
    }

    /// The fallback re-checks inbound audio and a peer-initiated restart before it fires.
    func testTheFallbackRechecksAudioAndPeerRestartBeforeFiring() {
        let ctl = read("QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift")
        XCTAssertTrue(ctl.contains("peerRestartApplied: peerApplied"))
        XCTAssertTrue(ctl.contains("packetsNow: now"))
    }

    /// The probe pair kind is read and written under the lock, and an unresolved selection
    /// resets it to unknown instead of keeping an older "direct".
    func testTheLatestSelectedPairTierIsLockedAndResetOnAmbiguity() {
        let ctl = read("QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift")
        XCTAssertEqual(count("_latestSelectedPairTier", in: ctl), 3,
                       "declaration, locked getter and locked setter only")
        XCTAssertTrue(ctl.contains("restartIceDebounceLock.withLock { _latestSelectedPairTier }"))
        XCTAssertTrue(ctl.contains("restartIceDebounceLock.withLock { _latestSelectedPairTier = tier }"))
        XCTAssertTrue(ctl.contains("self.setLatestSelectedPairTier(.unknown)\n                return"))
    }

    func testTheSocketPassesTheInterfaceTypeChange() {
        let ws = read("QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoWebSocketClient.swift")
        XCTAssertTrue(ws.contains("interfaceTypeChanged: transportSwitched"))
    }

    func testTheSocketPathEdgeGoesThroughTheDecisionAndTheGate() {
        let ws = read("QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoWebSocketClient.swift")
        XCTAssertTrue(ws.contains("FastSwitchDecisions.pathEdgeAction("))
        XCTAssertTrue(ws.contains("CallFastSwitchGate.shared.isEnabled"))
        XCTAssertTrue(ws.contains("if action == .reconnectNow {"))
    }

    func testTheRouteTierFollowsTheSelectedPair() {
        let ctl = read("QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift")
        XCTAssertTrue(ctl.contains("SelectedPairResolver.select(selectedPairId: selectedPairId, pairs: pairSnapshots)"))
        XCTAssertFalse(ctl.contains("let succeededPair = report.statistics.values.first"),
                       "the first succeeded pair in dictionary order must not decide the tier")
        XCTAssertTrue(ctl.contains("P2pProbeDecisions.effectivePairKind("))
    }
}
