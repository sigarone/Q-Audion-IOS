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
        /// readiness-8.7 — virtual-clock advance (advance_time_ms).
        let ms: Int?
        /// readiness-8.7 — arm_video_tx_hold inputs.
        let midCallUpgrade: Bool?
        let alreadySendingVideo: Bool?
        let expect: [String: KatValue]?

        private enum CodingKeys: String, CodingKey {
            case action = "do"
            case media, accepted, sdp, seconds, mid
            case transceiverDirection, senderTrack, expect
            case ms, midCallUpgrade, alreadySendingVideo
        }
    }

    private struct Scenario: Decodable {
        let id: String
        let callRole: String
        /// "readiness-8.7" scenarios are replayed by the dedicated
        /// readiness driver below; nil = legacy decision scenario.
        let group: String?
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
        /// readiness-8.7 — nested `sentCount` maps ({"call_media_ready": 1}).
        case intDict([String: Int])
        case other

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b); return }
            if let i = try? c.decode(Int.self) { self = .int(i); return }
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let a = try? c.decode([String].self) { self = .stringArray(a); return }
            if let d = try? c.decode([String: Int].self) { self = .intDict(d); return }
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
            // readiness-8.7 scenarios are replayed by the dedicated driver
            // (testReadinessSelfHealVectorsMatch) — not decision vectors.
            if scenario.group == "readiness-8.7" { continue }
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

    // MARK: - readiness-8.7 replay driver (WIRE_SPEC §8.7 self-heal)

    /// Replays every `group == "readiness-8.7"` scenario against a pure
    /// model that delegates the escalation ladder + failsafe/stall rules
    /// to the PRODUCTION `VideoStallSelfHeal` / `VideoStallEscalationEngine`
    /// (the exact objects AppState's VIDEODIAG watchdog drives). The
    /// TX-hold / dedup / 1-per-second limiter rules mirror the production
    /// call sites 1:1 (`>=` boundary semantics everywhere). Fails on any
    /// unmodeled verb or expect key so a vector extension can never
    /// silently no-op on iOS. Sister drivers: Android
    /// `UpgradeFlowKatTest.kt`, Desktop `upgradeFlow.kat.spec.ts`.
    func testReadinessSelfHealVectorsMatch() throws {
        guard let kat = loadKatOrNil() else { return }  // same isolated-checkout policy
        let group = kat.scenarios.filter { $0.group == "readiness-8.7" }
        let mustCover: Set<String> = [
            "readiness-media-ready-once-per-mid",
            "readiness-tx-hold-released-by-peer-ready",
            "readiness-tx-hold-timeout-failsafe",
            "readiness-tx-hold-skip-on-reupgrade-peer-ready-seen",
            "readiness-keyframe-request-outbound-rate-limit",
            "readiness-peer-ready-forces-exactly-one-idr",
            "readiness-receiver-failsafe-lift-2s",
            "readiness-rekey-bidirectional-resync",
            "readiness-watchdog-escalation-ladder",
            "readiness-watchdog-recovery-resets-backoff",
        ]
        let found = Set(group.map { $0.id })
        XCTAssertTrue(
            mustCover.isSubset(of: found),
            "missing readiness-8.7 scenarios: \(mustCover.subtracting(found).sorted())"
        )
        for scenario in group {
            let model = ReadinessModel()
            for (idx, step) in scenario.steps.enumerated() {
                let ctx = "[\(scenario.id)] step \(idx) (\(step.action))"
                replayReadinessStep(step, model: model, ctx: ctx)
                assertReadinessExpect(step.expect, model: model, ctx: ctx)
            }
        }
    }

    /// Apply one readiness-8.7 verb to the model. Unknown verbs FAIL —
    /// the driver must be extended alongside any vector extension.
    private func replayReadinessStep(_ step: Step, model: ReadinessModel, ctx: String) {
        model.perStepSent.removeAll()
        switch step.action {
        case "video_active_baseline":
            if let mid = step.mid { model.boundMid = mid }
        case "receiver_cryptor_keyed_and_bound":
            guard let mid = step.mid else {
                XCTFail("\(ctx): missing mid"); return
            }
            model.boundMid = mid
            if model.receiverGated {
                model.receiverGated = false
                model.receiverGateLiftedBy = "ready"
            }
            model.announceMediaReady(mid: mid, bypassDedup: false)
        case "arm_video_tx_hold":
            let midCall = step.midCallUpgrade ?? false
            let already = step.alreadySendingVideo ?? false
            // §8.7 arm rule — Android shouldHoldVideoTx / Desktop parity:
            // hold ONLY on a mid-call upgrade, not already sending, and the
            // peer's readiness not yet proven this call.
            let shouldHold = midCall && !already && !model.peerMediaReadySeen
            model.txHoldArmedLastAttempt = shouldHold
            if shouldHold {
                model.txHolding = true
                model.txHoldArmAtMs = model.now
                model.txHoldTimeoutPending = true
                model.localVideoTxEnabled = false
            }
        case "recv_call_media_ready":
            model.peerMediaReadySeen = true
            // Release is NOT subject to the honor limiter check itself but
            // its IDR rides the SHARED 1/s limiter (flag-collapse parity).
            model.releaseTxHold(by: "media_ready")
            model.attemptForceIdr()  // honor path (shared limiter)
        case "recv_video_keyframe_request":
            model.attemptForceIdr()  // honor path (shared limiter)
        case "request_peer_keyframe":
            model.attemptSendKeyframeRequest()
        case "receiver_video_gate_armed":
            if let mid = step.mid { model.boundMid = mid }
            model.receiverGated = true
            model.receiverGateArmAtMs = model.now
        case "rekey":
            // §8.7 bidirectional resync: local IDR (new-epoch frames for
            // the peer) + video_keyframe_request (peer refreshes ours),
            // each on its OWN 1/s limiter.
            model.attemptForceIdr()
            model.attemptSendKeyframeRequest()
        case "watchdog_video_stalled":
            model.ladder.noteStalled(nowMs: model.now)
        case "watchdog_video_recovered":
            model.ladder.noteRecovered()
        case "advance_time_ms":
            guard let ms = step.ms else {
                XCTFail("\(ctx): advance_time_ms without ms"); return
            }
            model.advance(ms: Int64(ms))
        default:
            XCTFail("\(ctx): unmodeled readiness-8.7 verb '\(step.action)'")
        }
    }

    /// Assert every expect key of a readiness-8.7 step. Unknown keys FAIL.
    private func assertReadinessExpect(
        _ expect: [String: KatValue]?, model: ReadinessModel, ctx: String
    ) {
        guard let expect = expect else { return }
        for (key, value) in expect {
            switch (key, value) {
            case ("note", _):
                break  // documentation only
            case ("sent", .stringArray(let entries)):
                for e in entries {
                    XCTAssertTrue(
                        model.perStepSent.contains(e),
                        "\(ctx): expected '\(e)' sent this step; got \(model.perStepSent)")
                }
            case ("sentCount", .intDict(let counts)):
                for (wire, n) in counts {
                    XCTAssertEqual(
                        model.sentCount[wire, default: 0], n,
                        "\(ctx): sentCount[\(wire)]")
                }
            case ("forcedIdrCount", .int(let n)):
                XCTAssertEqual(model.forcedIdrCount, n, "\(ctx): forcedIdrCount")
            case ("txHoldArmed", .bool(let b)):
                XCTAssertEqual(model.txHoldArmedLastAttempt, b, "\(ctx): txHoldArmed")
            case ("txHolding", .bool(let b)):
                XCTAssertEqual(model.txHolding, b, "\(ctx): txHolding")
            case ("txHoldReleasedBy", .string(let s)):
                XCTAssertEqual(model.txHoldReleasedBy, s, "\(ctx): txHoldReleasedBy")
            case ("localVideoTxEnabled", .bool(let b)):
                XCTAssertEqual(model.localVideoTxEnabled, b, "\(ctx): localVideoTxEnabled")
            case ("peerMediaReadySeen", .bool(let b)):
                XCTAssertEqual(model.peerMediaReadySeen, b, "\(ctx): peerMediaReadySeen")
            case ("receiverGated", .bool(let b)):
                XCTAssertEqual(model.receiverGated, b, "\(ctx): receiverGated")
            case ("receiverGateLiftedBy", .string(let s)):
                XCTAssertEqual(model.receiverGateLiftedBy, s, "\(ctx): receiverGateLiftedBy")
            case ("watchdogStage", .int(let n)):
                XCTAssertEqual(model.ladder.stage, n, "\(ctx): watchdogStage")
            case ("sinkReattachCount", .int(let n)):
                XCTAssertEqual(model.sinkReattachCount, n, "\(ctx): sinkReattachCount")
            case ("callDropped", .bool(let b)):
                // SIGNAL-NOT-KILL — no vector may ever expect a teardown,
                // and the model can never drop a call.
                XCTAssertFalse(b, "\(ctx): a readiness vector may NEVER expect callDropped=true")
                XCTAssertEqual(model.callDropped, b, "\(ctx): callDropped")
            default:
                XCTFail("\(ctx): unhandled expect key '\(key)' = \(value)")
            }
        }
    }

    /// Pure replay model for the readiness-8.7 group. The escalation
    /// ladder is the PRODUCTION `VideoStallEscalationEngine`; the receiver
    /// failsafe window is the PRODUCTION `VideoStallSelfHeal` constant.
    /// Timer-fire order on `advance` is pinned by the KAT notes:
    /// TX-hold timeout → receiver failsafe → ladder rungs.
    private final class ReadinessModel {
        /// Virtual monotonic clock (ms).
        var now: Int64 = 0
        /// Wire records sent during the CURRENT step (reset per step).
        var perStepSent: [String] = []
        /// Cumulative per-message-type send counts.
        var sentCount: [String: Int] = [:]
        /// once-per-(callId, mid) dedup for the NORMAL readiness path.
        var mediaReadyDedup: Set<String> = []
        /// The established inbound video mid (rung-3 re-announce target).
        var boundMid: String = ""
        /// Outbound video_keyframe_request 1/s limiter (-1 = never sent).
        var kfrLastSentMs: Int64 = -1
        /// Shared local-IDR 1/s honor limiter (-1 = never forced).
        var idrLastForcedMs: Int64 = -1
        var forcedIdrCount: Int = 0
        // §8.7 sender TX-hold.
        var txHoldArmedLastAttempt = false
        var txHolding = false
        var txHoldArmAtMs: Int64 = -1
        var txHoldTimeoutPending = false
        var txHoldReleasedBy: String?
        var localVideoTxEnabled = true
        var peerMediaReadySeen = false
        // §8.7 receiver render gate.
        var receiverGated = false
        var receiverGateArmAtMs: Int64 = -1
        var receiverGateLiftedBy: String?
        // §8.7 self-heal ladder — PRODUCTION engine under test.
        let ladder = VideoStallEscalationEngine()
        var sinkReattachCount: Int = 0
        /// SIGNAL-NOT-KILL: the model has no teardown path at all.
        let callDropped = false

        static let txHoldTimeoutMs: Int64 = 2000
        static let limiterWindowMs: Int64 = 1000

        func record(_ wire: String) {
            perStepSent.append(wire)
            let key = wire.hasPrefix("call_media_ready") ? "call_media_ready" : wire
            sentCount[key, default: 0] += 1
        }

        func attemptForceIdr() {
            if idrLastForcedMs < 0 || now - idrLastForcedMs >= Self.limiterWindowMs {
                idrLastForcedMs = now
                forcedIdrCount += 1
            }
        }

        func attemptSendKeyframeRequest() {
            if kfrLastSentMs < 0 || now - kfrLastSentMs >= Self.limiterWindowMs {
                kfrLastSentMs = now
                record("video_keyframe_request")
            }
        }

        func announceMediaReady(mid: String, bypassDedup: Bool) {
            if !bypassDedup {
                guard !mediaReadyDedup.contains(mid) else { return }
                mediaReadyDedup.insert(mid)
            }
            record("call_media_ready:mid=" + mid)
        }

        func releaseTxHold(by reason: String) {
            guard txHolding else { return }
            txHolding = false
            txHoldTimeoutPending = false
            txHoldReleasedBy = reason
            localVideoTxEnabled = true
            attemptForceIdr()  // release forces one IDR (shared limiter)
        }

        /// Advance the virtual clock, then fire every DUE timer in the
        /// KAT-pinned order: sender TX-hold timeout → receiver render-gate
        /// failsafe → stall-escalation rungs (in ladder order even across
        /// a large jump — the production engine guarantees that).
        func advance(ms: Int64) {
            now += ms
            if txHoldTimeoutPending, txHolding, now - txHoldArmAtMs >= Self.txHoldTimeoutMs {
                releaseTxHold(by: "timeout")
            }
            if receiverGated, now - receiverGateArmAtMs >= VideoStallSelfHeal.receiverGateFailsafeMs {
                receiverGated = false
                receiverGateLiftedBy = "failsafe"
                // Blind lift ⇒ the decoder joined mid-stream: nudge the
                // sender (media_ready NOT sent — the cryptor is not ready).
                attemptSendKeyframeRequest()
            }
            for action in ladder.dueActions(nowMs: now) {
                switch action {
                case .keyframeRequest:
                    attemptSendKeyframeRequest()
                case .sinkReattach:
                    sinkReattachCount += 1
                case .mediaReadyReannounce:
                    // Deliberate dedup BYPASS (last-rung self-heal); the
                    // normal path's once-per-mid dedup stays untouched.
                    announceMediaReady(mid: boundMid, bypassDedup: true)
                }
            }
        }
    }

    // MARK: - Direct unit assertions (independent of the JSON, always run)

    /// §8.7 ladder engine — constants + rung ordering + recovery reset
    /// (always runs, even on isolated checkouts without the KAT tree).
    func testStallEscalationEngine() {
        XCTAssertEqual(VideoStallSelfHeal.receiverGateFailsafeMs, 2000)
        XCTAssertEqual(VideoStallSelfHeal.stallEscalationBackoffMs, [3000, 6000, 12000])
        XCTAssertEqual(
            VideoStallSelfHeal.escalationLadder,
            [.keyframeRequest, .sinkReattach, .mediaReadyReannounce],
            "rung order is pinned: cheapest wire nudge → local re-attach → dedup-bypass re-announce"
        )
        let engine = VideoStallEscalationEngine()
        XCTAssertFalse(engine.isStalled)
        XCTAssertEqual(engine.dueActions(nowMs: 99_999), [])
        engine.noteStalled(nowMs: 1000)
        engine.noteStalled(nowMs: 2500)  // idempotent — first detection bases the clock
        XCTAssertEqual(engine.stallStartMs, 1000)
        XCTAssertEqual(engine.dueActions(nowMs: 3999), [])
        XCTAssertEqual(engine.dueActions(nowMs: 4000), [.keyframeRequest])  // >= boundary
        XCTAssertEqual(engine.stage, 1)
        XCTAssertEqual(engine.dueActions(nowMs: 6999), [])
        XCTAssertEqual(engine.dueActions(nowMs: 7000), [.sinkReattach])
        XCTAssertEqual(engine.dueActions(nowMs: 13_000), [.mediaReadyReannounce])
        XCTAssertEqual(engine.stage, 3)
        // Exhausted ladder: keeps ticking, takes no further action, NEVER
        // tears anything down (SIGNAL-NOT-KILL).
        XCTAssertEqual(engine.dueActions(nowMs: 999_999), [])
        // Recovery resets stage AND backoff base.
        engine.noteRecovered()
        XCTAssertEqual(engine.stage, 0)
        engine.noteStalled(nowMs: 50_000)
        XCTAssertEqual(engine.dueActions(nowMs: 52_999), [])
        XCTAssertEqual(engine.dueActions(nowMs: 53_000), [.keyframeRequest])
        // Large clock jump fires the remaining rungs IN ORDER.
        let jump = VideoStallEscalationEngine()
        jump.noteStalled(nowMs: 0)
        XCTAssertEqual(
            jump.dueActions(nowMs: 12_000),
            [.keyframeRequest, .sinkReattach, .mediaReadyReannounce]
        )
    }

    /// §8.7 BLACK-VIDEO STALL rule + TX storm rule (pure predicates).
    func testStallAndStormRules() {
        // Arrivals recent + nothing rendered for >=3s = stall.
        XCTAssertTrue(VideoStallSelfHeal.isBlackVideoStall(
            msSinceLastArrivedIncrease: 500, msSinceLastRenderedIncrease: 3000))
        // Rendering recently = healthy.
        XCTAssertFalse(VideoStallSelfHeal.isBlackVideoStall(
            msSinceLastArrivedIncrease: 500, msSinceLastRenderedIncrease: 2999))
        // No arrivals at all = idle, NOT a stall (nothing to recover).
        XCTAssertFalse(VideoStallSelfHeal.isBlackVideoStall(
            msSinceLastArrivedIncrease: 3000, msSinceLastRenderedIncrease: 10_000))
        // 3 peer keyframe requests inside 5s = storm (force IDR now).
        XCTAssertTrue(VideoStallSelfHeal.isPeerKeyframeStorm(
            requestTimesMs: [0, 2000, 4000], nowMs: 5000))
        XCTAssertFalse(VideoStallSelfHeal.isPeerKeyframeStorm(
            requestTimesMs: [0, 2000, 4000], nowMs: 5001))
        XCTAssertFalse(VideoStallSelfHeal.isPeerKeyframeStorm(
            requestTimesMs: [4000, 4500], nowMs: 5000))
    }

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
