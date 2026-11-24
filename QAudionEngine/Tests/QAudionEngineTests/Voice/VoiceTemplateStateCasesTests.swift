import XCTest
import Foundation
@testable import QAudionEngine

/// Cases run directly on the machine with scripted sessions, next to the 88 cases of stage 9: 45 s gives Provisional, three calls
/// in one evening are one session, the share rule, Enrolled after 72 h with the centroids gone, conflict and its resolution,
/// eviction at nine sessions, purge, retention, reprompt. The numbers are the defaults of bundle v0, read from its constants.
final class VoiceTemplateStateCasesTests: XCTestCase {
    private var cfg: VoiceStateConstants!
    private let t0 = 1_790_000_000
    private let day = 86_400

    override func setUpWithError() throws {
        cfg = try VoiceKat.bundle().state
    }

    private func axis(_ i: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 512)
        v[i] = 1
        return v
    }

    private func session(_ speechMs: Int, axis a: Int = 0) -> StateSession {
        StateSession(speechMs: speechMs, centroid: axis(a), nWindows: 20, conflict: false, nb: 0)
    }

    private func call(_ start: Int, _ s: StateSession?, windows: [StateWindow]? = nil, dur: Int = 900) -> StateCall {
        StateCall(tStartS: start, tEndS: start + dur, utcOffsetS: 0, routeClass: 1, deviceTag: 7, consent: true, consentS: start,
                  tier: 1, learnBlocked: false, windows: windows, session: s)
    }

    private func run(_ rec: TemplateRecord?, _ c: StateCall) throws -> CallEnd {
        try VoiceTemplateState.endOfCall(rec, c, cfg)
    }

    private func windowsOver(_ chunks: Int, axis a: Int = 0) -> [StateWindow] {
        (0...((chunks - 128) / 64)).map { StateWindow(emb: axis(a), chunks: [(64 * $0)..<(64 * $0 + 128)], lC: 1.0, nb: false) }
    }

    func testOneSessionOf45sGivesProvisional() throws {
        let end = try run(nil, call(t0, session(45_000)))
        XCTAssertEqual(end.record?.state, TemplateState.provisional)
        XCTAssertEqual(end.result.recompute?.why, "speech")
        XCTAssertEqual(end.result.created, true)
        XCTAssertEqual(end.record?.consensusSpeechMs, 45_000)
    }

    func testUnder40sStaysLearningAndTheAnchorIsTheSession() throws {
        let end = try run(nil, call(t0, session(14_336)))
        XCTAssertEqual(end.record?.state, TemplateState.learning)
        XCTAssertEqual(end.result.recompute?.why, "prov_ms")
        XCTAssertEqual(end.record?.anchor, axis(0))
    }

    func testThreeCallsInOneEveningAreOneMergedSessionCappedAt60s() throws {
        var rec = try run(nil, call(t0, nil, windows: windowsOver(1216))).record
        rec = try run(rec, call(t0 + 1800, nil, windows: windowsOver(1216))).record
        let third = try run(rec, call(t0 + 3600, nil, windows: windowsOver(1216)))
        let r = try XCTUnwrap(third.record)
        XCTAssertEqual(r.sessions.count, 1)
        XCTAssertEqual(r.sessionsSeenTotal, 1)
        XCTAssertTrue(r.sessions[0].merged)
        XCTAssertLessThanOrEqual(r.sessions[0].speechMs, 60_000)
        XCTAssertEqual(third.result.session, "merged")
        XCTAssertEqual(third.result.contributed?.windows, 0) // the cap leaves 19 chunks free: no window fits
        XCTAssertEqual(r.sessions[0].endS, t0 + 3600 + 900)
    }

    func testSessionsOver3DaysStayProvisionalAnd4thAfter72hGivesEnrolledWithNoCentroids() throws {
        var rec: TemplateRecord?
        for (i, ms) in [60_000, 60_000, 40_000].enumerated() { rec = try run(rec, call(t0 + i * day, session(ms))).record }
        XCTAssertEqual(rec?.state, TemplateState.provisional)
        let fourth = try run(rec, call(t0 + 3 * day, session(40_000)))
        let r = try XCTUnwrap(fourth.record)
        XCTAssertEqual(r.state, TemplateState.enrolled)
        XCTAssertTrue(r.anchorFrozen)
        XCTAssertTrue(r.sessions.allSatisfy { $0.centroid == nil && $0.inConsensus })
        XCTAssertEqual(r.sessions.count, 4)
        XCTAssertEqual(r.anchor, r.adaptive)
        XCTAssertEqual(r.enrolledS, t0 + 3 * day + 900)
        // and a later call is processed as an Enrolled contact's call, never as a new session
        let outcome = StateOutcome(u: axis(0), lC: [4.0, 4.0, 4.0], gateWindows: 3, matched: true, finalMatches: true,
                                   differsCandidate: false, blocked: false, matchWindows: 3, scoredWindows: 3, eligWindows: 3,
                                   authenticityElevated: false, wasHim: false)
        let later = try run(r, StateCall(tStartS: t0 + 10 * day, tEndS: t0 + 10 * day + 600, utcOffsetS: 0, routeClass: 1,
                                         deviceTag: 7, consent: true, consentS: 0, tier: 1, learnBlocked: false, outcome: outcome))
        XCTAssertEqual(later.result.path, "enrolled")
        XCTAssertEqual(later.record?.sessions.count, 4)
    }

    func testSessionsOf60And40And20sFailTheShareRule() throws {
        var rec: TemplateRecord?
        for (i, ms) in [60_000, 40_000, 20_000].enumerated() { rec = try run(rec, call(t0 + i * 130_000, session(ms))).record }
        XCTAssertEqual(rec?.state, TemplateState.provisional)
        let last = try run(rec, call(t0 + 3 * 130_000, session(1_000))) // one more session changes the shares: 60 of 121
        XCTAssertEqual(last.result.recompute?.why, "share")
    }

    func testAConflictAndItsResolutionByTheNextSession() throws {
        var rec = try run(nil, call(t0, session(30_000, axis: 0))).record
        let two = try run(rec, call(t0 + day, session(30_000, axis: 1)))
        XCTAssertEqual(two.result.recompute?.why, "conflict")
        XCTAssertEqual(two.record?.conflict, true)
        XCTAssertEqual(two.record?.state, TemplateState.learning)
        XCTAssertNil(two.record?.anchor)
        rec = two.record
        let three = try run(rec, call(t0 + 2 * day, session(30_000, axis: 0)))
        XCTAssertEqual(three.result.recompute?.consensus, [0, 2])
        XCTAssertEqual(three.record?.conflict, false)
        XCTAssertEqual(three.record?.sessions.map { $0.inConsensus }, [true, false, true])
        // the session outside the consensus is purged 30 days after it ended
        let before = VoiceTemplateState.sweep(three.record, nowS: t0 + day + 900 + 30 * day - 1, cfg)
        XCTAssertEqual(before.purged, [])
        let after = VoiceTemplateState.sweep(three.record, nowS: t0 + day + 900 + 30 * day, cfg)
        XCTAssertEqual(after.purged, [1])
        XCTAssertEqual(after.record?.sessions.count, 2)
    }

    func testTheNinthSessionEvictsTheFirstThatIsNotInTheConsensusElseTheFirst() throws {
        var rec: TemplateRecord?
        for i in 0..<8 { rec = try run(rec, call(t0 + i * day, session(10_000))).record }
        XCTAssertEqual(rec?.sessions.count, 8)
        let ninth = try run(rec, call(t0 + 8 * day, session(10_000)))
        XCTAssertEqual(ninth.result.evicted, 0)
        XCTAssertEqual(ninth.record?.sessions.count, 8)
        XCTAssertEqual(ninth.record?.sessions[0].startS, t0 + day)
        XCTAssertEqual(ninth.record?.sessionsSeenTotal, 9)
    }

    func testRetentionDeletesTheRecord730DaysAfterTheLastVerifiedCallAndNotBefore() throws {
        let rec = try XCTUnwrap(try run(nil, call(t0, session(45_000))).record)
        let lastVerified = rec.lastVerifiedCallS
        XCTAssertNil(VoiceTemplateState.sweep(rec, nowS: lastVerified + 730 * day, cfg).record)
        XCTAssertEqual(VoiceTemplateState.sweep(rec, nowS: lastVerified + 730 * day, cfg).deleted, "retention")
        XCTAssertNotNil(VoiceTemplateState.sweep(rec, nowS: lastVerified + 730 * day - 1, cfg).record)
    }

    func testACallOfTier0OrWithoutConsentChangesNothing() throws {
        let rec = try XCTUnwrap(try run(nil, call(t0, session(45_000))).record)
        let tier0 = StateCall(tStartS: t0 + 5, tEndS: t0 + 900, utcOffsetS: 0, routeClass: 1, deviceTag: 7, consent: true,
                              consentS: 0, tier: 0, learnBlocked: false, session: session(20_000))
        let a = try run(rec, tier0)
        XCTAssertEqual(a.result.why, "tier")
        XCTAssertEqual(a.record?.updatedS, rec.updatedS)
        XCTAssertEqual(a.record?.sessions.count, 1)
        let noConsent = StateCall(tStartS: t0 + 5, tEndS: t0 + 900, utcOffsetS: 0, routeClass: 1, deviceTag: 7, consent: false,
                                  consentS: 0, tier: 1, learnBlocked: false, session: session(20_000))
        XCTAssertEqual(try run(rec, noConsent).result.why, "no_consent")
        XCTAssertNil(try run(nil, noConsent).record)
    }

    func testRepromptAfter30DaysInNeedsRefreshOnce() throws {
        let rec = TemplateRecord(state: TemplateState.needsRefresh, modelId: cfg.modelId, constantsVersion: 0, frontendVersion: 1)
        rec.refreshEnteredS = t0
        rec.anchor = axis(0)
        rec.adaptive = axis(0)
        XCTAssertFalse(VoiceTemplateState.reprompt(rec, nowS: t0 + 30 * day - 1, cfg).1)
        let (r, due) = VoiceTemplateState.reprompt(rec, nowS: t0 + 30 * day, cfg)
        XCTAssertTrue(due)
        XCTAssertEqual(r?.refreshReprompted, true)
        XCTAssertFalse(VoiceTemplateState.reprompt(r, nowS: t0 + 60 * day, cfg).1)
    }

    func testTheExactSumIsRoundedOnceAndKeepsTheOrderIndependentValue() {
        // a sum that plain left-to-right addition gets wrong
        XCTAssertEqual(StateVec.exactSum([1e100, 1.0, -1e100]), 1.0)
        XCTAssertEqual(StateVec.exactSum([0.1, 0.2, 0.3]), 0.6)
        XCTAssertEqual(StateVec.exactSum([]), 0.0)
        XCTAssertEqual(StateVec.exactSum([3.5]), 3.5)
        XCTAssertTrue(StateVec.exactSum([Double.nan, 1.0]).isNaN)
    }

    func testNoStateSourceLogsOrPrints() throws {
        var dir = URL(fileURLWithPath: "\(#filePath)")
        for _ in 0..<8 {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Sources/QAudionEngine/Voice").path) { break }
        }
        let base = dir.appendingPathComponent("Sources/QAudionEngine/Voice")
        for name in ["Fp16", "TemplateRecord", "VoiceStateConstants", "VoiceTemplateState", "VoiceTemplateStore", "VoiceKeyGuard", "VoiceKeychainAead"] {
            let text = try String(contentsOf: base.appendingPathComponent("\(name).swift"), encoding: .utf8)
            for token in ["print(", "NSLog", "os_log", "Logger(", "debugPrint", "dump("] {
                XCTAssertFalse(text.contains(token), "\(name).swift contains \(token)")
            }
        }
    }
}
