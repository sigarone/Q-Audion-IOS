import XCTest
@testable import QAudionEngine

/// WIRE_SPEC §8 (INT-5) — mid-call media-upgrade behavioral conformance.
///
/// Loads `tools/kat/upgrade-flow/upgrade-flow-kat.json` (mirrored across the
/// BCRYPTO repos) and asserts that iOS's pure upgrade-flow decision helpers
/// (`UpgradeFlowDecisions`) reproduce every scenario's `expect` outcome.
///
/// These are BEHAVIORAL vectors, not byte-KATs: each scenario is a sequence of
/// protocol events with expectations. iOS drives only the platform-independent
/// DECISIONS (media→consent, glare politeness given the original callRole,
/// aligned 30s timeouts, phantom-vs-relatch sink binding) — NOT a live
/// PeerConnection, which the KAT explicitly scopes out. The imperative side
/// effects (ship SDP, JSEP rollback, force IDR) are exercised on-device; here
/// we gate the choices the state machine makes.
///
/// Sister drivers (same JSON): Android `UpgradeFlowKatTest.kt`, Desktop
/// `upgradeFlow.kat.spec.ts`.
///
/// Failure modes caught: politeness keyed to the wrong role, unknown-media
/// NOT failing safe to camera-consent, timeout drift off 30s, or "last
/// receiver wins" phantom binding regressions (§8.6).
final class UpgradeFlowKatTests: XCTestCase {

    // MARK: - JSON model (mirrors upgrade-flow-kat.json)

    private struct Step: Decodable {
        /// JSON key `"do"` (a Swift statement keyword) → `action`.
        let action: String
        let media: String?
        let accepted: Bool?
        let sdp: String?
        let seconds: Int?
        let mid: String?
        let transceiverDirection: String?
        let senderTrack: Bool?
        let expect: [String: KatValue]?

        private enum CodingKeys: String, CodingKey {
            case action = "do"
            case media, accepted, sdp, seconds, mid
            case transceiverDirection, senderTrack, expect
        }
    }

    private struct Scenario: Decodable {
        let id: String
        let callRole: String
        let steps: [Step]
    }

    private struct KatFile: Decodable {
        let version: Int
        let scenarios: [Scenario]
    }

    /// Minimal JSON-value box so `expect` (heterogeneous) decodes without a
    /// per-key struct. Only the shapes the vectors actually use are handled.
    private enum KatValue: Decodable, Equatable {
        case bool(Bool)
        case int(Int)
        case string(String)
        case stringArray([String])
        case other

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b); return }
            if let i = try? c.decode(Int.self) { self = .int(i); return }
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let a = try? c.decode([String].self) { self = .stringArray(a); return }
            self = .other
        }
    }

    // MARK: - Test

    func testUpgradeFlowDecisionsMatchVectors() throws {
        guard let kat = loadKatOrNil() else {
            // Isolated test checkouts without the monorepo `tools/` tree
            // no-op green (sister Android/Desktop drivers still gate). Same
            // policy as SasCrossPlatformKatTests.
            return
        }
        XCTAssertEqual(kat.version, 1, "upgrade-flow KAT schema version drift")
        XCTAssertGreaterThan(kat.scenarios.count, 0, "KAT must contain scenarios")

        var covered = Set<String>()
        for scenario in kat.scenarios {
            guard let role = callRole(scenario.callRole) else {
                XCTFail("[\(scenario.id)] unknown callRole '\(scenario.callRole)'")
                continue
            }
            for step in scenario.steps {
                assertStep(scenario: scenario, role: role, step: step, covered: &covered)
            }
        }

        // Guard: every scenario whose behavior maps to a pure decision MUST be
        // asserted (guards against a renamed/added scenario silently skipping).
        let mustCover: Set<String> = [
            "accept-remote-upgrade",
            "responder-auto-decline-30s",
            "timeout-equals-decline",
            "glare-polite-callee-rolls-back",
            "glare-impolite-caller-ignores",
            "screen-auto-accept",
            "unknown-media-treated-as-camera",
            "phantom-recvonly-ignored",
            "relatch-on-new-mid-after-stop",
        ]
        XCTAssertTrue(
            mustCover.isSubset(of: covered),
            "un-asserted decision scenarios: \(mustCover.subtracting(covered).sorted())"
        )
    }

    /// Assert the pure decision(s) implied by a single scenario step.
    private func assertStep(
        scenario: Scenario,
        role: UpgradeFlowDecisions.CallRole,
        step: Step,
        covered: inout Set<String>
    ) {
        let expect = step.expect ?? [:]

        // A `recv_upgrade_request` that FOLLOWS a `local_upgrade_request` in
        // the same scenario is a GLARE collision (asserted in the glare block
        // below, keyed to callRole), NOT a plain media→consent routing case.
        // The `sent:accepted` there is the polite-rollback accept, not screen
        // auto-accept — so the media-consent inference below MUST skip it.
        let isGlareStep = step.action == "recv_upgrade_request"
            && scenario.steps.contains { $0.action == "local_upgrade_request" }

        switch step.action {
        case "recv_upgrade_request" where !isGlareStep:
            // §8.1 — media → consent routing. `expect.consentDialogShown`
            // (when present) is exactly `resolveMediaConsent == .requireConsent`.
            if let media = step.media {
                let consent = UpgradeFlowDecisions.resolveMediaConsent(media: media)
                if case .bool(let shown)? = expect["consentDialogShown"] {
                    XCTAssertEqual(
                        consent == .requireConsent, shown,
                        "[\(scenario.id)] media=\(media) consent routing"
                    )
                    covered.insert(scenario.id)
                }
                // `call_upgrade_response:accepted` WITHOUT a consent dialog is
                // the screen auto-accept branch (§8.1). Only infer that when we
                // KNOW no dialog was shown (screen scenarios pin it false).
                if case .bool(false)? = expect["consentDialogShown"],
                   case .stringArray(let sent)? = expect["sent"],
                   sent.contains("call_upgrade_response:accepted") {
                    XCTAssertEqual(
                        consent, .autoAccept,
                        "[\(scenario.id)] auto-accept-without-dialog requires screen media"
                    )
                    covered.insert(scenario.id)
                }
            }

        case "local_upgrade_request":
            // Glare politeness is decided when the PEER request lands (below).
            // A lone local request just establishes the in-flight state.
            break

        case "advance_time_s":
            // §8.2 — aligned 30s timeouts (requester watchdog AND responder
            // auto-decline). The vector advances exactly the aligned window.
            if let seconds = step.seconds,
               case .string(let toState)? = expect["state"], toState == "AudioOnly" {
                let isResponderDecline =
                    (expect["sent"].map { v -> Bool in
                        if case .stringArray(let s) = v {
                            return s.contains("call_upgrade_response:declined")
                        }
                        return false
                    } ?? false)
                let aligned = isResponderDecline
                    ? UpgradeFlowDecisions.responderAutoDeclineSeconds
                    : UpgradeFlowDecisions.requesterWatchdogSeconds
                XCTAssertEqual(
                    seconds, aligned,
                    "[\(scenario.id)] timeout must equal the aligned §8.2 window"
                )
                covered.insert(scenario.id)
            }

        case "ontrack_video":
            // §8.6 — phantom-vs-relatch sink binding. Baseline mid is "2" per
            // the vectors' `video_active_baseline` step; the ontrack step
            // carries the new mid + transceiver shape.
            let established = "2"
            guard let incoming = step.mid else { break }
            let recvOnly = (step.transceiverDirection == "recvonly")
            // The KAT models a stop via a separate `transceiver_stopped` step
            // BEFORE ontrack in the relatch scenario; detect it structurally.
            let stopped = scenario.steps.contains {
                $0.action == "transceiver_stopped" && $0.mid == established
            }
            let binding = UpgradeFlowDecisions.resolveSinkBinding(
                establishedMid: established,
                incomingMid: incoming,
                transceiverIsRecvOnly: recvOnly,
                establishedTransceiverStopped: stopped
            )
            if case .bool(true)? = expect["phantomIgnored"] {
                XCTAssertEqual(
                    binding, .keepPhantomIgnored(mid: established),
                    "[\(scenario.id)] phantom recvonly must keep the established mid"
                )
                if case .string(let sinkMid)? = expect["sinkMid"] {
                    XCTAssertEqual(sinkMid, established, "[\(scenario.id)] sink stays on established mid")
                }
                covered.insert(scenario.id)
            } else if case .string(let sinkMid)? = expect["sinkMid"] {
                XCTAssertEqual(
                    binding, .relatch(mid: sinkMid),
                    "[\(scenario.id)] legitimate move must relatch to the new mid"
                )
                covered.insert(scenario.id)
            }

        default:
            break
        }

        // Glare (§8.3): a `recv_upgrade_request` following a
        // `local_upgrade_request` — politeness keyed to the ORIGINAL callRole.
        if isGlareStep {
            let resolution = UpgradeFlowDecisions.glareResolution(callRole: role)
            if case .bool(true)? = expect["politeRollback"] {
                XCTAssertEqual(
                    resolution, .politeAcceptPeer,
                    "[\(scenario.id)] polite glare requires original CALLEE role"
                )
                XCTAssertEqual(role, .callee, "[\(scenario.id)] politeRollback ⇒ callee")
                covered.insert(scenario.id)
            }
            if case .bool(true)? = expect["peerRequestIgnoredOrDeclinedClean"] {
                XCTAssertEqual(
                    resolution, .impoliteIgnorePeer,
                    "[\(scenario.id)] impolite glare requires original CALLER role"
                )
                XCTAssertEqual(role, .caller, "[\(scenario.id)] ignore ⇒ caller")
                covered.insert(scenario.id)
            }
        }
    }

    private func callRole(_ raw: String) -> UpgradeFlowDecisions.CallRole? {
        switch raw {
        case "caller": return .caller
        case "callee": return .callee
        default: return nil
        }
    }

    /// Walk up from the test's working dir to the bcrypto repo root + KAT
    /// JSON (same resolution as SasCrossPlatformKatTests).
    private func loadKatOrNil() -> KatFile? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("tools/kat/upgrade-flow/upgrade-flow-kat.json")
            if fm.fileExists(atPath: candidate.path),
               let data = try? Data(contentsOf: candidate),
               let kat = try? JSONDecoder().decode(KatFile.self, from: data) {
                return kat
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Direct unit assertions (independent of the JSON, always run)

    func testMediaConsentFailSafe() {
        XCTAssertEqual(UpgradeFlowDecisions.resolveMediaConsent(media: "screen"), .autoAccept)
        XCTAssertEqual(UpgradeFlowDecisions.resolveMediaConsent(media: "camera"), .requireConsent)
        // Unknown ⇒ camera (fail-safe consent, §8.1).
        XCTAssertEqual(UpgradeFlowDecisions.resolveMediaConsent(media: "hologram-v9"), .requireConsent)
        XCTAssertEqual(UpgradeFlowDecisions.resolveMediaConsent(media: ""), .requireConsent)
    }

    func testGlarePolitenessByOriginalRole() {
        XCTAssertEqual(UpgradeFlowDecisions.glareResolution(callRole: .callee), .politeAcceptPeer)
        XCTAssertEqual(UpgradeFlowDecisions.glareResolution(callRole: .caller), .impoliteIgnorePeer)
    }

    func testAlignedTimeouts() {
        XCTAssertEqual(UpgradeFlowDecisions.responderAutoDeclineSeconds, 30)
        XCTAssertEqual(UpgradeFlowDecisions.requesterWatchdogSeconds, 30)
        XCTAssertEqual(
            UpgradeFlowDecisions.responderAutoDeclineSeconds,
            UpgradeFlowDecisions.requesterWatchdogSeconds,
            "WIRE_SPEC §8.2 — timeouts MUST be aligned"
        )
    }

    func testPhantomAndRelatchBinding() {
        // Phantom recvonly, established still live → keep established (§8.6).
        XCTAssertEqual(
            UpgradeFlowDecisions.resolveSinkBinding(
                establishedMid: "2", incomingMid: "5",
                transceiverIsRecvOnly: true, establishedTransceiverStopped: false),
            .keepPhantomIgnored(mid: "2")
        )
        // Established stopped, real sendrecv track on new mid → relatch.
        XCTAssertEqual(
            UpgradeFlowDecisions.resolveSinkBinding(
                establishedMid: "2", incomingMid: "5",
                transceiverIsRecvOnly: false, establishedTransceiverStopped: true),
            .relatch(mid: "5")
        )
        // No established video yet → bind initial.
        XCTAssertEqual(
            UpgradeFlowDecisions.resolveSinkBinding(
                establishedMid: nil, incomingMid: "2",
                transceiverIsRecvOnly: false, establishedTransceiverStopped: false),
            .bindInitial(mid: "2")
        )
        // Same mid re-offer → no change.
        XCTAssertEqual(
            UpgradeFlowDecisions.resolveSinkBinding(
                establishedMid: "2", incomingMid: "2",
                transceiverIsRecvOnly: true, establishedTransceiverStopped: false),
            .keepPhantomIgnored(mid: "2")
        )
    }
}
