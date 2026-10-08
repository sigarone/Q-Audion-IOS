import XCTest
@testable import QAudionEngine

/// The effect state machine: truth of the label, queue and budget, levels and policy, governor, lifecycle, durations.
final class EnigmaEffectTests: XCTestCase {

    private let ms: Int64 = 1_000_000

    private func makeEffect(
        env: EnigmaEnvironment = EnigmaEnvironment(),
        level: EnigmaLevel = .full,
        flagOn: Bool = true
    ) -> EnigmaEffect {
        let effect = EnigmaEffect(environment: { env }, seedSource: { 1 })
        effect.configure(flagOn: flagOn, userLevel: level)
        return effect
    }

    @discardableResult
    private func playOk(
        _ e: EnigmaEffect, _ id: String, _ dir: EnigmaDirection = .receive, plain: String = "ciao mondo"
    ) -> EnigmaAdmission {
        let bytes = Data((0..<(plain.count + 40)).map { UInt8(truncatingIfNeeded: $0) })
        let cipher = bytes.base64EncodedString()
        let from = (dir == .send) ? plain : cipher
        let to = (dir == .send) ? cipher : plain
        return e.play(id: id, direction: dir, from: from, to: to, result: .ok(packetBytes: plain.count + 40))
    }

    /// Runs frames at `dtMs` until the active scene (and the queue) ends or `maxFrames` pass.
    @discardableResult
    private func runToEnd(_ e: EnigmaEffect, start: Int64 = 0, dtMs: Double = 16.7, maxFrames: Int = 5000) -> Int64 {
        var now = start
        var n = 0
        while e.hasWork && n < maxFrames {
            e.onFrame(nowNanos: now)
            now += Int64(dtMs * Double(ms))
            n += 1
        }
        return now
    }

    // MARK: - result truth

    func test_aRejectedVerificationNeverProducesASceneOrAnyLabel() {
        let e = makeEffect()
        let admission = e.play(id: "m1", direction: .receive, from: "AAAA", to: "ciao", result: .rejected)
        XCTAssertEqual(admission, .immediate)
        XCTAssertNil(e.activeId)
        XCTAssertEqual(e.retainedScenes, 0)
        XCTAssertFalse(e.disabled)
        XCTAssertNil(EnigmaScene.build(direction: .receive, from: "AAAA", to: "ciao", result: .rejected))
    }

    func test_theVerifiedLabelExistsOnlyForAReceiveSceneBuiltFromAnOkResult() {
        let e = makeEffect()
        playOk(e, "recv", .receive)
        XCTAssertEqual(e.labelKind, .verified)
        XCTAssertEqual(e.packetBytes, 50)
        e.cancelAll()
        playOk(e, "send", .send)
        // sending verified nothing, so the label must not claim it
        XCTAssertEqual(e.labelKind, .sealed)
    }

    func test_theLabelsAreTrue() {
        let verified = EnigmaLabels.line(kind: .verified, packetBytes: 1234, percent: 50)
        let sealed = EnigmaLabels.line(kind: .sealed, packetBytes: 99, percent: 100)
        XCTAssertTrue(verified.contains("AES-256-GCM"))
        XCTAssertTrue(verified.contains("chiave 256 bit"))
        XCTAssertTrue(verified.contains("1234 byte"))
        XCTAssertTrue(verified.contains("integrità verificata"))
        XCTAssertTrue(verified.hasSuffix("50%"))
        XCTAssertTrue(sealed.contains("integrità protetta"))
        XCTAssertFalse(sealed.contains("verificata"), "a send has not been verified by anyone")
        // never the size of the tag (the GCM tag is 128 bit), never the word
        let all = [verified, sealed, EnigmaLabels.verifiedDefault, EnigmaLabels.sealedDefault, EnigmaLabels.fileDefault,
                   EnigmaLabels.rotorsCaptionDefault, EnigmaLabels.rejectedDefault, EnigmaLabels.degradedDefault]
        for text in all {
            XCTAssertFalse(text.lowercased().contains("tag"), text)
            XCTAssertFalse(text.contains("tag 256"), text)
        }
        // the failure caption never reads like the success one
        XCTAssertFalse(EnigmaLabels.rejectedDefault.contains("integrità verificata"))
        // out of range numbers do not trap
        XCTAssertTrue(EnigmaLabels.line(kind: .sealed, packetBytes: -5, percent: 900).contains("0 byte"))
        XCTAssertTrue(EnigmaLabels.line(kind: .sealed, packetBytes: 5, percent: 900).hasSuffix("100%"))
    }

    // MARK: - durations (about one second longer than the first Android version)

    func test_durationsFollowTheLengthenedConstants() {
        XCTAssertEqual(EnigmaScene.morphMs(length: 0), 1300)
        XCTAssertEqual(EnigmaScene.morphMs(length: 10), 1300)       // 900 + 160 = 1060 -> clamped up
        XCTAssertEqual(EnigmaScene.morphMs(length: 50), 1700)       // 900 + 800
        XCTAssertEqual(EnigmaScene.morphMs(length: 240), 2600)      // clamped down
        XCTAssertEqual(EnigmaScene.morphMs(length: -4), 1300)
        XCTAssertEqual(EnigmaScene.backMorphMs(morph: 1300), 650)
        XCTAssertEqual(EnigmaScene.backMorphMs(morph: 2600), 1300)
        XCTAssertTrue((1000...1200).contains(EnigmaScene.holdSendMs))
        XCTAssertTrue((1000...1200).contains(EnigmaScene.holdReceiveMs))
        guard let send = EnigmaScene.build(direction: .send, from: String(repeating: "a", count: 50), to: "QUJD", result: .ok(packetBytes: 3)),
              let receive = EnigmaScene.build(direction: .receive, from: "QUJD", to: String(repeating: "a", count: 50), result: .ok(packetBytes: 3))
        else {
            XCTFail("scenes")
            return
        }
        XCTAssertEqual(send.totalMs, 1700 + EnigmaScene.holdSendMs + 850)
        XCTAssertEqual(receive.totalMs, EnigmaScene.holdReceiveMs + 1700)
    }

    // MARK: - queue

    func test_aBurstOf20MessagesGivesOneActiveThreeQueuedAndTheRestImmediate() {
        let e = makeEffect()
        let results = (1...20).map { playOk(e, "m\($0)") }
        XCTAssertEqual(results.filter { $0 == .active }.count, 1)
        XCTAssertEqual(results.filter { $0 == .queued }.count, 3)
        XCTAssertEqual(results.filter { $0 == .immediate }.count, 16)
        XCTAssertEqual(e.retainedScenes, 4)
        XCTAssertEqual(e.activeId, "m1")
    }

    func test_aBurstOfLongSendsDegradesByTimeToo() {
        let e = makeEffect()
        let long = String(repeating: "x", count: 100)
        let results = (1...6).map { playOk(e, "m\($0)", .send, plain: long) }
        XCTAssertEqual(results[0], .active)
        XCTAssertEqual(results[1], .queued)
        XCTAssertTrue(results.dropFirst(2).allSatisfy { $0 == .immediate })
        XCTAssertTrue(e.retainedScenes <= 1 + EnigmaEffect.maxQueue)
    }

    func test_oneEffectPlaysAtATimeAndQueuedScenesPlayInOrderThenTheQueueIsEmpty() {
        let e = makeEffect()
        (1...4).forEach { playOk(e, "m\($0)") }
        var order: [String] = []
        var now: Int64 = 0
        var guardCount = 0
        while e.hasWork && guardCount < 20_000 {
            if let id = e.activeId, order.last != id { order.append(id) }
            e.onFrame(nowNanos: now)
            now += Int64(16.7 * Double(ms))
            guardCount += 1
        }
        XCTAssertEqual(order, ["m1", "m2", "m3", "m4"])
        XCTAssertEqual(e.retainedScenes, 0)
        XCTAssertNil(e.activeId)
        XCTAssertEqual(e.frameText, "")
    }

    func test_aQueuedRowThatIsNoLongerVisibleIsSkippedWhenItsTurnComes() {
        let e = makeEffect()
        e.isVisible = { $0 != "m2" }
        (1...3).forEach { playOk(e, "m\($0)") }
        var seen: [String] = []
        var now: Int64 = 0
        var guardCount = 0
        while e.hasWork && guardCount < 20_000 {
            if let id = e.activeId, seen.last != id { seen.append(id) }
            e.onFrame(nowNanos: now)
            now += Int64(16.7 * Double(ms))
            guardCount += 1
        }
        XCTAssertEqual(seen, ["m1", "m3"])
    }

    func test_theSameRowTwiceIsNotQueuedTwice() {
        let e = makeEffect()
        XCTAssertEqual(playOk(e, "m1"), .active)
        XCTAssertEqual(playOk(e, "m1"), .immediate)
        XCTAssertEqual(e.retainedScenes, 1)
    }

    func test_emptyOrInvisibleInputsAreImmediate() {
        let e = makeEffect()
        XCTAssertEqual(e.play(id: "a", direction: .receive, from: "", to: "x", result: .ok(packetBytes: 1)), .immediate)
        XCTAssertEqual(e.play(id: "a", direction: .receive, from: "x", to: "", result: .ok(packetBytes: 1)), .immediate)
        XCTAssertEqual(e.play(id: "a", direction: .receive, from: "AAAA", to: "ciao", result: .ok(packetBytes: 3), visible: false), .immediate)
        XCTAssertEqual(e.retainedScenes, 0)
    }

    // MARK: - levels and policy

    func test_offOrFlagOffOrReduceMotionMeansImmediateResultAndNoState() {
        XCTAssertEqual(playOk(makeEffect(level: .off), "a"), .immediate)
        XCTAssertEqual(playOk(makeEffect(flagOn: false), "a"), .immediate)
        let reduced = makeEffect(env: EnigmaEnvironment(reduceMotion: true))
        XCTAssertEqual(playOk(reduced, "a"), .immediate)
        XCTAssertEqual(reduced.retainedScenes, 0)
        XCTAssertFalse(reduced.hasWork)
        XCTAssertFalse(reduced.wouldAnimate())
    }

    func test_lowPowerAndThermalSeriousCapAtLiteNeverAbove() {
        let full = EnigmaLevel.full
        let lite = EnigmaLevel.lite
        XCTAssertEqual(EnigmaPolicy.effective(flagOn: true, user: full, governorCap: full, env: EnigmaEnvironment(lowPowerMode: true)), lite)
        XCTAssertEqual(EnigmaPolicy.effective(flagOn: true, user: full, governorCap: full, env: EnigmaEnvironment(thermalLevel: 2)), lite)
        XCTAssertEqual(EnigmaPolicy.effective(flagOn: true, user: full, governorCap: full, env: EnigmaEnvironment(thermalLevel: 3)), lite)
        XCTAssertEqual(EnigmaPolicy.effective(flagOn: true, user: full, governorCap: full, env: EnigmaEnvironment(thermalLevel: 1)), full)
        XCTAssertEqual(EnigmaPolicy.effective(flagOn: true, user: full, governorCap: full, env: EnigmaEnvironment(thermalLevel: nil)), full)
        XCTAssertEqual(EnigmaPolicy.effective(flagOn: true, user: lite, governorCap: full, env: EnigmaEnvironment(reduceMotion: true)), .off)
        XCTAssertEqual(EnigmaPolicy.effective(flagOn: false, user: full, governorCap: full, env: EnigmaEnvironment()), .off)
        XCTAssertEqual(EnigmaPolicy.effective(flagOn: true, user: lite, governorCap: full, env: EnigmaEnvironment()), lite)
        XCTAssertEqual(EnigmaPolicy.effective(flagOn: true, user: full, governorCap: lite, env: EnigmaEnvironment()), lite)
        XCTAssertEqual(EnigmaPolicy.effective(flagOn: true, user: full, governorCap: .off, env: EnigmaEnvironment()), .off)
        XCTAssertEqual(EnigmaPolicy.effective(flagOn: true, user: lite, governorCap: full, env: EnigmaEnvironment(lowPowerMode: true)), lite)
    }

    func test_storedValuesMapToLevelsAndUnknownReadsAsOff() {
        XCTAssertEqual(EnigmaLevel.fromStored(0), .off)
        XCTAssertEqual(EnigmaLevel.fromStored(1), .lite)
        XCTAssertEqual(EnigmaLevel.fromStored(2), .full)
        XCTAssertEqual(EnigmaLevel.fromStored(7), .off)
        XCTAssertEqual(EnigmaLevel.fromStored(-1), .off)
        XCTAssertEqual(EnigmaLevel.full.lowered(), .lite)
        XCTAssertEqual(EnigmaLevel.lite.lowered(), .off)
        XCTAssertEqual(EnigmaLevel.off.lowered(), .off)
    }

    func test_liteDrawsAt15FpsAndFullAt30Fps() {
        func renders(_ level: EnigmaLevel) -> Int {
            let e = makeEffect(level: level)
            playOk(e, "m", plain: String(repeating: "x", count: 100))
            var now: Int64 = 0
            var count = 0
            // one second of display link at 60 Hz
            for _ in 0..<60 {
                if e.onFrame(nowNanos: now) { count += 1 }
                now += Int64(16.667 * Double(ms))
            }
            return count
        }
        let full = renders(.full)
        let lite = renders(.lite)
        XCTAssertTrue((28...32).contains(full), "full ~30 got \(full)")
        XCTAssertTrue((14...17).contains(lite), "lite ~15 got \(lite)")
    }

    // MARK: - governor

    func test_highAverageIntervalsDegradeOneLevelAndTheSceneContinues() {
        let e = makeEffect()
        playOk(e, "m", plain: String(repeating: "x", count: 150))
        XCTAssertEqual(e.runLevel, .full)
        var now: Int64 = 0
        for _ in 0..<25 {
            e.onFrame(nowNanos: now)
            now += 40 * ms
        }
        XCTAssertEqual(e.governor.cap, .lite)
        XCTAssertEqual(e.runLevel, .lite)
        XCTAssertTrue(e.hasWork, "scene still running")
        XCTAssertTrue(e.takeDegradeNotice())
        XCTAssertFalse(e.takeDegradeNotice(), "the notice is shown once")
    }

    func test_aHealthy60HzRunNeverDegrades() {
        let e = makeEffect()
        playOk(e, "m", plain: String(repeating: "x", count: 150))
        runToEnd(e, dtMs: 16.7)
        XCTAssertEqual(e.governor.cap, .full)
        XCTAssertFalse(e.takeDegradeNotice())
    }

    func test_aDisplayThatRunsAt30HzByDesignIsNotPenalised() {
        // Low Power Mode caps the display link at 30 Hz: every interval is 33.3 ms, the display's own nominal interval.
        let e = makeEffect()
        playOk(e, "m", plain: String(repeating: "x", count: 150))
        var now: Int64 = 0
        for _ in 0..<80 {
            e.onFrame(nowNanos: now, nominalFrameMs: 33.333)
            now += Int64(33.333 * Double(ms))
        }
        XCTAssertEqual(e.governor.cap, .full)
        // the same intervals judged against a 60 Hz display are slow
        let slow = makeEffect()
        playOk(slow, "m", plain: String(repeating: "x", count: 150))
        now = 0
        for _ in 0..<30 {
            slow.onFrame(nowNanos: now, nominalFrameMs: 16.667)
            now += Int64(33.333 * Double(ms))
        }
        XCTAssertEqual(slow.governor.cap, .lite)
        XCTAssertEqual(EnigmaGovernor.normalizedInterval(dtMs: 33.3, nominalMs: 33.3), EnigmaGovernor.referenceFrameMs, accuracy: 0.01)
        XCTAssertEqual(EnigmaGovernor.normalizedInterval(dtMs: 8.3, nominalMs: 8.3), EnigmaGovernor.referenceFrameMs, accuracy: 0.01)
        XCTAssertEqual(EnigmaGovernor.normalizedInterval(dtMs: 100, nominalMs: 16.667), 100, accuracy: 0.01)
        XCTAssertEqual(EnigmaGovernor.normalizedInterval(dtMs: 5, nominalMs: 33), 0, accuracy: 0.01)
        XCTAssertEqual(EnigmaGovernor.normalizedInterval(dtMs: -1, nominalMs: 16), 0)
        XCTAssertEqual(EnigmaGovernor.normalizedInterval(dtMs: 20, nominalMs: 0), 20)
    }

    func test_aSingleIntervalAbove120msClosesTheJobAtOnceAndLowersTheLevel() {
        let e = makeEffect()
        playOk(e, "m1")
        playOk(e, "m2")
        e.onFrame(nowNanos: 0)
        e.onFrame(nowNanos: 17 * ms)
        e.onFrame(nowNanos: 17 * ms + 130 * ms)
        XCTAssertEqual(e.governor.cap, .lite)
        // m1 was closed; m2 starts, now at lite
        XCTAssertEqual(e.activeId, "m2")
        XCTAssertEqual(e.runLevel, .lite)
    }

    func test_degradingAllTheWayToOffEndsTheEffect() {
        let e = makeEffect()
        for i in 1...3 { playOk(e, "m\(i)") }
        var now: Int64 = 0
        e.onFrame(nowNanos: now)
        now += 200 * ms
        e.onFrame(nowNanos: now)
        XCTAssertEqual(e.governor.cap, .lite)
        e.onFrame(nowNanos: now + 16 * ms)
        now += 16 * ms
        now += 200 * ms
        e.onFrame(nowNanos: now)
        XCTAssertEqual(e.governor.cap, .off)
        XCTAssertEqual(playOk(e, "later"), .immediate)
        XCTAssertEqual(e.retainedScenes, 0)
    }

    func test_theCapIsRestoredWhenTheUserChangesTheSetting() {
        let e = makeEffect()
        playOk(e, "m")
        e.onFrame(nowNanos: 0)
        e.onFrame(nowNanos: 300 * ms)
        XCTAssertEqual(e.governor.cap, .lite)
        e.configure(flagOn: true, userLevel: .lite)
        XCTAssertEqual(e.governor.cap, .full)
        XCTAssertEqual(e.currentLevel(), .lite)
        // the notice may appear again after a reset
        playOk(e, "m2")
        e.onFrame(nowNanos: 1_000 * ms)
        e.onFrame(nowNanos: 1_300 * ms)
        XCTAssertTrue(e.takeDegradeNotice())
    }

    func test_theSameSettingAgainDoesNotResetTheCap() {
        let e = makeEffect()
        playOk(e, "m")
        e.onFrame(nowNanos: 0)
        e.onFrame(nowNanos: 300 * ms)
        e.configure(flagOn: true, userLevel: .full)
        XCTAssertEqual(e.governor.cap, .lite)
    }

    func test_governorWindowNeeds20SamplesAndALowAverageDoesNotDegrade() {
        let g = EnigmaGovernor()
        for _ in 0..<19 { XCTAssertEqual(g.onFrameInterval(60.0), .ok) }
        XCTAssertEqual(g.onFrameInterval(60.0), .degraded)
        let g2 = EnigmaGovernor()
        for _ in 0..<100 { XCTAssertEqual(g2.onFrameInterval(25.0), .ok) }
        XCTAssertEqual(g2.onFrameInterval(121.0), .abortAndDegrade)
        XCTAssertEqual(EnigmaGovernor().onFrameInterval(120.0), .ok)
        XCTAssertEqual(EnigmaGovernor().onFrameInterval(Double.nan), .ok)
    }

    // MARK: - lifecycle and fail-safe

    func test_cancelAllShowsEveryResultAndDropsEveryString() {
        let e = makeEffect()
        (1...4).forEach { playOk(e, "m\($0)") }
        e.cancelAll()
        XCTAssertNil(e.activeId)
        XCTAssertEqual(e.retainedScenes, 0)
        XCTAssertEqual(e.frameText, "")
        XCTAssertFalse(e.onFrame(nowNanos: 5 * ms))
    }

    func test_switchingTheSettingOffCancelsWhatIsRunning() {
        let e = makeEffect()
        playOk(e, "m")
        e.configure(flagOn: true, userLevel: .off)
        XCTAssertFalse(e.hasWork)
    }

    func test_twoStallsSwitchTheEffectOffForTheSession() {
        let e = makeEffect()
        e.noteStall()
        XCTAssertFalse(e.disabled)
        e.noteStall()
        XCTAssertTrue(e.disabled)
        XCTAssertEqual(playOk(e, "m"), .immediate)
        XCTAssertFalse(e.wouldAnimate())
    }

    func test_aReportedFailureDisablesTheEffectAndClearsEverything() {
        let e = makeEffect()
        (1...3).forEach { playOk(e, "m\($0)") }
        e.reportFailure()
        XCTAssertTrue(e.disabled)
        XCTAssertEqual(e.retainedScenes, 0)
        XCTAssertNil(e.activeId)
        XCTAssertEqual(playOk(e, "again"), .immediate)
        // configuring again does not bring it back
        e.configure(flagOn: true, userLevel: .full)
        XCTAssertEqual(playOk(e, "again2"), .immediate)
    }

    func test_after1000AnimationsNothingIsRetained() {
        let e = makeEffect()
        for i in 0..<1000 {
            playOk(e, "m\(i)", (i % 2 == 0) ? .send : .receive, plain: "messaggio numero \(i)")
            runToEnd(e, start: Int64(i) * 10_000 * ms)
        }
        XCTAssertEqual(e.retainedScenes, 0)
        XCTAssertNil(e.activeId)
        XCTAssertEqual(e.frameText, "")
        XCTAssertEqual(e.reveal, 0)
        XCTAssertEqual(e.rotorIndex, 0)
        XCTAssertEqual(e.queuedCount, 0)
        XCTAssertFalse(e.disabled)
    }

    func test_everySceneShowsAFrameWhileItRunsAndThenEnds() {
        let texts = ["a", "ciao mondo", "👋🏽 ciao 🇮🇹", "שלום עולם", String(repeating: "z", count: 700)]
        for plain in texts {
            for dir in [EnigmaDirection.send, EnigmaDirection.receive] {
                let e = makeEffect()
                playOk(e, "m", dir, plain: plain)
                // run to the last frame that still belongs to the scene
                var now: Int64 = 0
                var lastShown = e.frameText
                var guardCount = 0
                while e.hasWork && guardCount < 5000 {
                    e.onFrame(nowNanos: now)
                    if e.hasWork { lastShown = e.frameText }
                    now += Int64(16.7 * Double(ms))
                    guardCount += 1
                }
                XCTAssertFalse(e.hasWork)
                XCTAssertFalse(lastShown.isEmpty)
            }
        }
    }
}
