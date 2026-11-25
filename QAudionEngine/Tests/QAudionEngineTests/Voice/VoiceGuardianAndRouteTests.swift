import XCTest
import Foundation
@testable import QAudionEngine

/// The parts of the trust inputs that are not the key age: voice leaves the Guardian (the index, the re-key timing and the confidence
/// announcement take no voice input, the wire format is unchanged), the maximum-assurance badge stays crypto-only, the route class of
/// the engine is the peer's announced one, and the route groups of the daily counters are those of `constants.json`.
final class VoiceGuardianAndRouteTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        try VoiceTierInputsTests.source(relative)
    }

    /// The text of a function or closure region: from `start` to the first `end` after it.
    private func slice(_ text: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(text.range(of: start), start)
        let b = try XCTUnwrap(text.range(of: end, range: a.upperBound..<text.endIndex), end)
        return String(text[a.lowerBound..<b.lowerBound])
    }

    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    // MARK: the Guardian index

    func testTheIndexIsTheVoiceFreeCombineOfTheTwoCalibratedSignals() {
        func cal(_ raw: Float) -> Float { raw >= 0.20 ? 0.95 + (raw - 0.20) / 0.80 * 0.05 : raw }
        let grid: [Float] = [0, 0.1, 0.2, 0.5, 0.9, 1]
        for df in grid {
            for lv in grid {
                let want = min(1, max(0, (0.4 * cal(df) + 0.3 * cal(lv)) / 0.7))
                XCTAssertEqual(ContactVoiceVerifier.guardianIndex(deepfake: df, liveness: lv), want, accuracy: 1e-6, "df=\(df) lv=\(lv)")
            }
        }
        XCTAssertEqual(ContactVoiceVerifier.guardianIndex(deepfake: 1, liveness: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(ContactVoiceVerifier.guardianIndex(deepfake: 0, liveness: 0), 0, accuracy: 1e-6)
    }

    /// The re-key period is a function of the index alone: whatever the contact-voice check shows, the same index gives the same
    /// period, so no rekey decision depends on a voice state.
    func testTheRekeyPeriodIsAFunctionOfTheIndexAloneForEveryStateOfTheVoiceCard() {
        let states: [VoiceCheckDisplay] = [
            .matches, .checking, .checkingDifferentSetup, .differs, .differsNewDevice, .off, .cannotVerify, .learning, .changed
        ]
        var periods: Set<Int64> = []
        for _ in states {
            let scheduler = ReKeyScheduler()
            scheduler.observeConfidence(ContactVoiceVerifier.guardianIndex(deepfake: 0.3, liveness: 0.6))
            periods.insert(scheduler.currentStatus.periodMs)
        }
        XCTAssertEqual(periods.count, 1)
        let c = ContactVoiceVerifier.guardianIndex(deepfake: 0.3, liveness: 0.6)
        XCTAssertEqual(periods.first, Int64(Float(ReKeyScheduler.basePeriodMs) * max(ReKeyScheduler.cMin, min(ReKeyScheduler.cMax, c))))
    }

    func testNoVoiceStateEntersTheIndexTheTickOrTheTwoConsumersOfTheScore() throws {
        let verifier = try source("QAudionEngine/Sources/QAudionEngine/Deepfake/ContactVoiceVerifier.swift")
        let src = code(verifier)
        XCTAssertFalse(src.contains("wVoiceprint"))
        XCTAssertFalse(src.contains("calibrate(vp)"))
        XCTAssertTrue(src.contains("static func guardianIndex(deepfake: Float, liveness: Float) -> Float {"))
        let index = try slice(src, from: "static func guardianIndex(", to: "private static func calibrate")
        XCTAssertFalse(index.lowercased().contains("voiceprint"))
        XCTAssertFalse(index.contains("vp"))
        // The tick: the voiceprint pass feeds the change monitor only; the gate and the combine take no voiceprint.
        let tick = try slice(src, from: "let windowRms = Self.rms(window)", to: "private static func calibrate")
        XCTAssertFalse(tick.contains("vp"), "the gate and the combine do not read the voiceprint")
        XCTAssertTrue(tick.contains("Self.guardianIndex(deepfake: genuineProb, liveness: liveness)"))
        XCTAssertTrue(tick.contains("self.onScoreBreakdown?(genuineProb, liveness, combined)"))

        // The re-key feed and the announcement of the confidence read the one score and nothing of the voice check.
        let app = code(try source("QAudionApp/AppState.swift"))
        let feed = try slice(app, from: "callService.onContactVoiceScoreUpdated = {", to: "callService.onContactVoiceScoreBreakdown = {")
        XCTAssertTrue(feed.contains("self.reKeyScheduler.observeConfidence(score)"))
        XCTAssertTrue(feed.contains("sendVoiceConfidenceAnnounce(seq: seq, confidence: score"))
        for word in ["VoiceCheckDisplay", "VoiceProcess", "VoiceCallWiring", "voiceCheck", "VoiceTier", "SpeakerVerifier"] {
            XCTAssertFalse(feed.contains(word), "the score of the re-key feed is voice-free: \(word)")
        }
    }

    // MARK: the maximum-assurance badge

    func testTheBadgeDependsOnlyOnTheIdentityShieldAndThePostQuantumProtection() throws {
        func protection(_ level: String, _ auth: String, _ pin: String = "ok") -> CallPqProtection {
            CallPqProtection(levelToken: level, auth: auth, pin: pin, callId: "c")
        }
        XCTAssertTrue(IdentityShieldRules.massimaSicurezza(shield: .verified, protection: protection("PQ2", "H")))
        XCTAssertFalse(IdentityShieldRules.massimaSicurezza(shield: .toVerify, protection: protection("PQ2", "H")))
        XCTAssertFalse(IdentityShieldRules.massimaSicurezza(shield: .verified, protection: protection("PQ2", "C")))
        XCTAssertFalse(IdentityShieldRules.massimaSicurezza(shield: .verified, protection: protection("PQ2", "H", "anomaly")))
        XCTAssertFalse(IdentityShieldRules.massimaSicurezza(shield: .verified, protection: nil))

        let rules = code(try source("QAudionEngine/Sources/QAudionEngine/Crypto/IdentityShield.swift"))
        let badge = try slice(
            rules, from: "public static func massimaSicurezza(shield: IdentityShield, protection: CallPqProtection?) -> Bool {",
            to: "public static func pqLogWord")
        XCTAssertFalse(badge.lowercased().contains("voice"))
        XCTAssertFalse(badge.contains("confidence"))
        XCTAssertFalse(badge.contains("Guardian"))
        let screen = code(try source("QAudionApp/Views/Call/InCallScreen.swift"))
        let shown = try slice(screen, from: "private var maxAssuranceShown: Bool {", to: "private func toneColor")
        XCTAssertTrue(shown.contains("IdentityShieldRules.massimaSicurezza(shield: identityShield, protection: pqProtection)"))
        XCTAssertFalse(shown.lowercased().contains("voice"))
    }

    // MARK: the route class

    func testTheRouteClassOfTheEngineIsOnlyTheOneThePeerAnnounced() throws {
        let session = code(try source("QAudionEngine/Sources/QAudionEngine/Voice/VoiceCallSession.swift"))
        XCTAssertEqual(session.components(separatedBy: ".route(atNs:").count - 1, 1, "one way in: the peer's announced class")
        let announced = try slice(session, from: "func peerRouteAnnounced(_ routeClass: Int) {", to: "func requestPostCancel()")
        XCTAssertTrue(announced.contains(".route(atNs: stamped(now), routeClass: routeClass)"))
        for name in ["VoiceEngine.swift", "VoiceCallSession.swift", "VoiceProcess.swift", "VoiceCallWiring.swift", "VoiceDailyCounters.swift"] {
            let text = code(try source("QAudionEngine/Sources/QAudionEngine/Voice/" + name))
            for word in ["AVAudioSession", "currentRoute", "availableInputs", "portType", "AudioRoute"] {
                XCTAssertFalse(text.contains(word), "\(name) must not read the local audio route: \(word)")
            }
        }
    }

    func testTheDailyCountersGroupTheRouteClassesLikeTheBundle() throws {
        let cfg = VoiceEngineConfig(bundle: try VoiceKat.bundle(), cohort: try VoiceScoringKat.cohort())
        let conditions = cfg.state.conditions
        XCTAssertFalse(conditions.routeClassNames.isEmpty)
        for (code, name) in conditions.routeClassNames {
            let group = conditions.routeGroup(code)
            let counter = VoiceDailyCounters.routeGroup(ofClass: code)
            switch group {
            case 0: XCTAssertEqual(counter, .unknown, name)
            case 1: XCTAssertEqual(counter, .handset, name)
            case 2: XCTAssertEqual(counter, .loudspeaker, name)
            case 3: XCTAssertEqual(counter, .handsFree, name)
            default: XCTFail("a group the counters do not have: \(name)")
            }
        }
        // The names of the bundle: ear and wired are handset, speaker is loudspeaker, bt and car are hands-free.
        XCTAssertEqual(VoiceDailyCounters.routeGroup(ofClass: conditions.routeClassNames.first { $0.value == "ear" }!.key), .handset)
        XCTAssertEqual(VoiceDailyCounters.routeGroup(ofClass: conditions.routeClassNames.first { $0.value == "wired" }!.key), .handset)
        XCTAssertEqual(VoiceDailyCounters.routeGroup(ofClass: conditions.routeClassNames.first { $0.value == "speaker" }!.key), .loudspeaker)
        XCTAssertEqual(VoiceDailyCounters.routeGroup(ofClass: conditions.routeClassNames.first { $0.value == "bt" }!.key), .handsFree)
        XCTAssertEqual(VoiceDailyCounters.routeGroup(ofClass: conditions.routeClassNames.first { $0.value == "car" }!.key), .handsFree)
        XCTAssertEqual(VoiceDailyCounters.routeGroup(ofClass: 0), .unknown)
        XCTAssertEqual(VoiceDailyCounters.routeGroup(ofClass: 99), .unknown, "a code that the table does not have")
    }
}
