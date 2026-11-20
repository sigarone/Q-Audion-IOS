import XCTest
@testable import QAudionEngine

/// In-memory storage of the learning record (the Keychain item in production).
final class MemoryOwnerVoiceProgress: OwnerVoiceProgressBacking {
    var data: Data?
    var failReads = false
    var failWrites = false

    func read() -> OwnerVoiceProgressRead {
        if failReads { return .unreadable }
        return data.map { .present($0) } ?? .absent
    }
    func write(_ data: Data) -> Bool {
        if failWrites { return false }
        self.data = data
        return true
    }
    func delete() -> Bool {
        if failWrites { return false }
        data = nil
        return true
    }
    var record: OwnerVoiceRecord? { data.flatMap(OwnerVoiceRecordCodec.decode) }
}

/// The rules of the learning (MIN, REFINED, the trim, the retention) and the learner that keeps the template and the
/// record between calls: windows are plain vectors, nothing here touches a model or the Keychain.
final class OwnerVoiceLearningTests: XCTestCase {

    private let dim = 16
    private let day: Int64 = 24 * 60 * 60 * 1000
    private let t0: Int64 = 1_700_000_000_000

    /// A window near the unit vector `axis` (a little different from every other one), so that the windows of one
    /// voice agree closely and those of another axis are orthogonal to them.
    private func window(_ call: String, _ i: Int, axis: Int = 0, day d: Int64 = 0, speechMs: Int = 4_000) -> OwnerVoiceLearning.Window {
        var v = [Float](repeating: 0, count: dim)
        v[axis] = 1
        v[(axis + 1 + i % 5) % dim] += 0.05 * Float(i % 3 + 1)
        return OwnerVoiceLearning.Window(embedding: v, callId: call, capturedAtEpochMs: t0 + d * day + Int64(i) * 4_000,
                                         netSpeechMs: speechMs)
    }

    private func windows(_ call: String, count: Int, axis: Int = 0, day d: Int64 = 0, speechMs: Int = 4_000) -> [OwnerVoiceLearning.Window] {
        (0..<count).map { window(call, $0, axis: axis, day: d, speechMs: speechMs) }
    }

    private struct Rig {
        let learner: OwnerVoiceLearner
        let templates: VoiceprintStore
        let progress: MemoryOwnerVoiceProgress
        let templateBacking: InMemoryVoiceprintBacking
    }

    private func makeRig() -> Rig {
        let backing = InMemoryVoiceprintBacking()
        let store = VoiceprintStore(backing: backing)
        let progress = MemoryOwnerVoiceProgress()
        return Rig(learner: OwnerVoiceLearner(templates: store, progress: progress), templates: store,
                   progress: progress, templateBacking: backing)
    }

    private var ownerId: String { VoiceprintStore.deviceOwnerId }

    // MARK: - MIN

    func testMinIsTenWindowsFortySecondsTwoCalls() {
        let ten = windows("a", count: 5) + windows("b", count: 5)
        let status = OwnerVoiceLearning.gateStatus(ten)
        XCTAssertEqual(status.windows, 10)
        XCTAssertEqual(status.distinctCalls, 2)
        XCTAssertEqual(status.netSpeechMs, 40_000)
        XCTAssertTrue(status.met)
        XCTAssertEqual(OwnerVoiceLearning.stage(status), .min)

        XCTAssertFalse(OwnerVoiceLearning.gateStatus(Array(ten.dropLast())).met, "9 windows are not MIN")
        XCTAssertFalse(OwnerVoiceLearning.gateStatus(windows("a", count: 10)).met, "one call is not MIN")
        let short = windows("a", count: 5, speechMs: 3_900) + windows("b", count: 5, speechMs: 3_900)
        XCTAssertFalse(OwnerVoiceLearning.gateStatus(short).met, "39 s are not MIN")
        XCTAssertEqual(OwnerVoiceLearning.stage(OwnerVoiceLearning.gateStatus(short)), .learning)
    }

    // MARK: - REFINED

    private func refinedSet() -> [OwnerVoiceLearning.Window] {
        // 30 windows, 6 calls, 3 days, 120 s.
        (0..<6).flatMap { windows("c\($0)", count: 5, day: Int64($0 / 2)) }
    }

    func testRefinedIsThirtyWindowsOneTwentySecondsSixCallsThreeDays() {
        let all = refinedSet()
        let status = OwnerVoiceLearning.gateStatus(all)
        XCTAssertEqual([status.windows, status.distinctCalls, status.distinctDays, status.netSpeechMs],
                       [30, 6, 3, 120_000])
        XCTAssertFalse(OwnerVoiceLearning.shouldRefine(status))
        XCTAssertEqual(OwnerVoiceLearning.stage(status), .refined)

        // Each axis on its own keeps the template in MIN.
        let fewerWindows = Array(all.prefix(29))
        XCTAssertTrue(OwnerVoiceLearning.shouldRefine(OwnerVoiceLearning.gateStatus(fewerWindows)))
        let fewerCalls = (0..<5).flatMap { windows("c\($0 % 5)", count: 6, day: Int64($0 / 2)) }
        XCTAssertEqual(OwnerVoiceLearning.gateStatus(fewerCalls).distinctCalls, 5)
        XCTAssertTrue(OwnerVoiceLearning.shouldRefine(OwnerVoiceLearning.gateStatus(fewerCalls)))
        let fewerDays = (0..<6).flatMap { windows("c\($0)", count: 5, day: Int64($0 / 3)) }
        XCTAssertEqual(OwnerVoiceLearning.gateStatus(fewerDays).distinctDays, 2)
        XCTAssertTrue(OwnerVoiceLearning.shouldRefine(OwnerVoiceLearning.gateStatus(fewerDays)))
        let lessSpeech = (0..<6).flatMap { windows("c\($0)", count: 5, day: Int64($0 / 2), speechMs: 3_900) }
        XCTAssertTrue(OwnerVoiceLearning.shouldRefine(OwnerVoiceLearning.gateStatus(lessSpeech)))
        XCTAssertEqual(OwnerVoiceLearning.stage(OwnerVoiceLearning.gateStatus(lessSpeech)), .min)
    }

    // MARK: - Fusion

    func testFusionTrimsAMinorityOfOtherVoicesAndNeedsMin() throws {
        let genuine = windows("a", count: 6) + windows("b", count: 6)
        let strangers = windows("c", count: 3, axis: 8)
        let fusion = try XCTUnwrap(OwnerVoiceLearning.fuse(genuine + strangers))
        XCTAssertEqual(fusion.survivorCount, 10)
        XCTAssertEqual(fusion.trimmedCount, 5)
        XCTAssertGreaterThan(OwnerVoiceLearning.cosine(fusion.centroid, window("x", 0).embedding), 0.95)
        XCTAssertLessThan(OwnerVoiceLearning.cosine(fusion.centroid, window("x", 0, axis: 8).embedding), 0.2)

        XCTAssertNil(OwnerVoiceLearning.fuse(Array(genuine.prefix(9))), "below MIN nothing is fused")
    }

    func testFusionRefusesWindowsThatDoNotAgree() {
        let scattered = (0..<12).map { i -> OwnerVoiceLearning.Window in
            var v = [Float](repeating: 0, count: dim)
            v[i] = 1
            return OwnerVoiceLearning.Window(embedding: v, callId: i < 6 ? "a" : "b", capturedAtEpochMs: t0, netSpeechMs: 4_000)
        }
        XCTAssertTrue(OwnerVoiceLearning.gateStatus(scattered).met)
        XCTAssertNil(OwnerVoiceLearning.fuse(scattered))
    }

    // MARK: - Retention

    func testRetentionDropsOldWindowsAndKeepsAWindowOfEveryDay() {
        let old = OwnerVoiceLearning.Window(embedding: [1], callId: "old", capturedAtEpochMs: t0 - OwnerVoiceLearning.progressMaxAgeMs - 1,
                                            netSpeechMs: 4_000)
        let fresh = window("new", 0, day: 0)
        XCTAssertEqual(OwnerVoiceLearning.retained([old, fresh], now: t0).map(\.callId), ["new"])

        let busy = (0..<100).map { window("d0-\($0)", $0, day: 0) }
        let lone = window("d1", 0, day: 1)
        let kept = OwnerVoiceLearning.retained(busy + [lone], now: t0 + day)
        XCTAssertEqual(kept.count, OwnerVoiceLearning.maxRetainedWindows)
        XCTAssertTrue(kept.contains { $0.callId == "d1" }, "the only window of a day is never the one to go")
        XCTAssertEqual(Set(kept.map { $0.capturedAtEpochMs / day }).count, 2)
    }

    // MARK: - The learner: MIN, the cap per call, REFINED

    func testTemplateAppearsAtMinAndCallsCountOnceWithAtMostSixWindows() throws {
        let rig = makeRig()
        XCTAssertEqual(rig.learner.prepare(userId: "u1"), .ready(template: nil, collect: true))

        // Nine windows offered, six count.
        XCTAssertEqual(rig.learner.record(windows: windows("a", count: 9), userId: "u1"), .learning)
        XCTAssertEqual(rig.progress.record?.windows.count, 6)
        XCTAssertNil(rig.templates.load(contactId: ownerId), "6 windows of one call are not MIN")

        // The same call again adds nothing.
        XCTAssertNil(rig.learner.record(windows: windows("a", count: 6), userId: "u1"))
        XCTAssertEqual(rig.progress.record?.windows.count, 6)

        XCTAssertEqual(rig.learner.record(windows: windows("b", count: 6), userId: "u1"), .min)
        let template = try XCTUnwrap(rig.templates.load(contactId: ownerId))
        XCTAssertGreaterThan(OwnerVoiceLearning.cosine(template, window("x", 0).embedding), 0.95)
        XCTAssertEqual(rig.progress.record?.windows.count, 12, "the windows are kept while the template can still improve")
        XCTAssertEqual(rig.learner.prepare(userId: "u1"), .ready(template: template, collect: true))
    }

    func testRefinedStopsTheCollectionAndNothingRestartsIt() throws {
        let rig = makeRig()
        _ = rig.learner.prepare(userId: "u1")
        var last: OwnerVoiceLearning.Stage?
        for call in 0..<6 {
            last = rig.learner.record(windows: windows("c\(call)", count: 5, day: Int64(call / 2)), userId: "u1")
            if call == 0 { XCTAssertEqual(last, .learning) }
            if (1..<5).contains(call) { XCTAssertEqual(last, .min, "call \(call)") }
        }
        XCTAssertEqual(last, .refined)
        let record = try XCTUnwrap(rig.progress.record)
        XCTAssertTrue(record.refined)
        XCTAssertTrue(record.windows.isEmpty, "the template is final: the windows are dropped")
        let template = try XCTUnwrap(rig.templates.load(contactId: ownerId))

        // Later calls do not collect, and what they offer changes nothing.
        XCTAssertEqual(rig.learner.prepare(userId: "u1"), .ready(template: template, collect: false))
        XCTAssertEqual(rig.learner.record(windows: windows("late", count: 6, axis: 8, day: 9), userId: "u1"), .refined)
        XCTAssertEqual(rig.templates.load(contactId: ownerId), template)
        XCTAssertTrue(try XCTUnwrap(rig.progress.record).windows.isEmpty)
    }

    func testAResetTemplateStartsTheLearningAgain() throws {
        let rig = makeRig()
        _ = rig.learner.prepare(userId: "u1")
        for call in 0..<6 { rig.learner.record(windows: windows("c\(call)", count: 5, day: Int64(call / 2)), userId: "u1") }
        XCTAssertTrue(try XCTUnwrap(rig.progress.record).refined)

        XCTAssertTrue(rig.learner.reset())
        XCTAssertNil(rig.templates.load(contactId: ownerId))
        XCTAssertNil(rig.progress.data)
        XCTAssertEqual(rig.learner.prepare(userId: "u1"), .ready(template: nil, collect: true))
    }

    // MARK: - A fused template far from the current one

    func testAFusedTemplateFarFromTheCurrentOneDoesNotReplaceIt() throws {
        let rig = makeRig()
        var far = [Float](repeating: 0, count: dim)
        far[8] = 1
        XCTAssertTrue(rig.templates.save(contactId: ownerId, template: far))
        _ = rig.learner.prepare(userId: "alice")
        rig.learner.record(windows: windows("a", count: 6), userId: "alice")
        XCTAssertNil(rig.learner.record(windows: windows("b", count: 6), userId: "alice"), "no stage is reported when the fused template is refused")
        XCTAssertEqual(rig.templates.load(contactId: ownerId), far, "the template in use is kept")
        XCTAssertEqual(rig.progress.record?.windows.count, 12, "the windows are kept")
    }

    // MARK: - A new embedding format

    func testARecordOfAnOldEmbeddingFormatLosesItsWindowsAndLearnsAgain() throws {
        let rig = makeRig()
        let old = OwnerVoiceRecord(userId: "u1", embeddingVersion: VoiceprintCodec.formatVersion - 1, refined: true,
                                   windows: windows("a", count: 6) + windows("b", count: 6))
        rig.progress.data = OwnerVoiceRecordCodec.encode(old)

        XCTAssertEqual(rig.learner.prepare(userId: "u1"), .ready(template: nil, collect: true))
        let record = try XCTUnwrap(rig.progress.record)
        XCTAssertEqual(record.embeddingVersion, VoiceprintCodec.formatVersion)
        XCTAssertTrue(record.windows.isEmpty)
        XCTAssertFalse(record.refined)

        // The old windows are not mixed in: 6 windows of a new call are 6 windows, not 18.
        XCTAssertEqual(rig.learner.record(windows: windows("c", count: 6), userId: "u1"), .learning)
        XCTAssertEqual(rig.progress.record?.windows.count, 6)
    }

    func testATemplateOfAnOldFormatReadsAsNoTemplate() {
        // The same rule the learner relies on: only the current layout decodes.
        var header = VoiceprintCodec.encode([1, 0, 0])
        header.replaceSubrange(4..<8, with: withUnsafeBytes(of: (VoiceprintCodec.formatVersion - 1).littleEndian) { Data($0) })
        XCTAssertNil(VoiceprintCodec.decode(header))
    }

    // MARK: - Accounts

    func testADifferentAccountStartsFresh() throws {
        let rig = makeRig()
        _ = rig.learner.prepare(userId: "alice")
        rig.learner.record(windows: windows("a", count: 6), userId: "alice")
        rig.learner.record(windows: windows("b", count: 6), userId: "alice")
        XCTAssertNotNil(rig.templates.load(contactId: ownerId))

        // Another account on the same phone does not inherit the template or the windows.
        XCTAssertEqual(rig.learner.prepare(userId: "bob"), .ready(template: nil, collect: true))
        XCTAssertNil(rig.templates.load(contactId: ownerId))
        let record = try XCTUnwrap(rig.progress.record)
        XCTAssertEqual(record.userId, "bob")
        XCTAssertTrue(record.windows.isEmpty)

        // Alice's batch that arrives late is not added to Bob's learning.
        XCTAssertNil(rig.learner.record(windows: windows("late", count: 6), userId: "alice"))
        XCTAssertTrue(try XCTUnwrap(rig.progress.record).windows.isEmpty)
    }

    func testATemplateWithNoRecordIsAdoptedOnFirstRun() {
        let rig = makeRig()
        XCTAssertTrue(rig.templates.save(contactId: ownerId, template: [1, 0, 0, 0]))
        XCTAssertEqual(rig.learner.prepare(userId: "alice"), .ready(template: [1, 0, 0, 0], collect: true))
        XCTAssertEqual(rig.templates.load(contactId: ownerId), [1, 0, 0, 0])
        XCTAssertEqual(rig.progress.record?.userId, "alice")
        // Now bound: another account does not inherit it.
        XCTAssertEqual(rig.learner.prepare(userId: "bob"), .ready(template: nil, collect: true))
        XCTAssertNil(rig.templates.load(contactId: ownerId))
    }

    func testATemplateWithAnUndecodableRecordIsAdopted() {
        let rig = makeRig()
        XCTAssertTrue(rig.templates.save(contactId: ownerId, template: [1, 0, 0, 0]))
        rig.progress.data = Data([1, 2, 3])
        XCTAssertEqual(rig.learner.prepare(userId: "alice"), .ready(template: [1, 0, 0, 0], collect: true))
        XCTAssertEqual(rig.progress.record?.userId, "alice")
    }

    func testARecordOfAnotherAccountDropsTheTemplate() {
        let rig = makeRig()
        XCTAssertTrue(rig.templates.save(contactId: ownerId, template: [1, 0, 0, 0]))
        rig.progress.data = OwnerVoiceRecordCodec.encode(OwnerVoiceRecord(
            userId: "alice", embeddingVersion: VoiceprintCodec.formatVersion, refined: false, windows: []))
        XCTAssertEqual(rig.learner.prepare(userId: "bob"), .ready(template: nil, collect: true))
        XCTAssertNil(rig.templates.load(contactId: ownerId))
        XCTAssertEqual(rig.progress.record?.userId, "bob")
    }

    func testTheCallsLearnedAfterAnAdoptedTemplateReplaceIt() throws {
        let rig = makeRig()
        let seed = window("s", 1).embedding
        XCTAssertTrue(rig.templates.save(contactId: ownerId, template: seed))
        _ = rig.learner.prepare(userId: "alice")
        rig.learner.record(windows: windows("a", count: 6), userId: "alice")
        XCTAssertEqual(rig.templates.load(contactId: ownerId), seed, "below MIN the adopted template stays")
        XCTAssertEqual(rig.learner.record(windows: windows("b", count: 6), userId: "alice"), .min)
        let template = try XCTUnwrap(rig.templates.load(contactId: ownerId))
        XCTAssertGreaterThan(OwnerVoiceLearning.cosine(template, window("x", 0).embedding), 0.95)
    }

    // MARK: - When storage cannot be trusted

    func testWithoutAnAccountOrWithAnUnreadableKeychainNothingIsLearnedOrChanged() {
        let rig = makeRig()
        XCTAssertTrue(rig.templates.save(contactId: ownerId, template: [1, 0, 0, 0]))
        XCTAssertEqual(rig.learner.prepare(userId: ""), .unavailable)
        XCTAssertNil(rig.learner.record(windows: windows("a", count: 6), userId: ""))
        XCTAssertNil(rig.progress.data)

        rig.templateBacking.failReads = true
        XCTAssertEqual(rig.learner.prepare(userId: "alice"), .unavailable)
        rig.templateBacking.failReads = false
        rig.progress.failReads = true
        XCTAssertEqual(rig.learner.prepare(userId: "alice"), .unavailable)
        XCTAssertNil(rig.learner.record(windows: windows("a", count: 6), userId: "alice"))
        rig.progress.failReads = false

        XCTAssertEqual(rig.templates.load(contactId: ownerId), [1, 0, 0, 0], "an unreadable store removes nothing")
        XCTAssertNil(rig.progress.data)
    }

    func testAForeignTemplateIsRemovedEvenWhenTheRecordCannotBeWritten() {
        let rig = makeRig()
        _ = rig.learner.prepare(userId: "alice")
        rig.learner.record(windows: windows("a", count: 6), userId: "alice")
        rig.learner.record(windows: windows("b", count: 6), userId: "alice")
        rig.progress.failWrites = true
        // Nothing is learned, and the template that no record of this account vouches for is gone all the same: a
        // record that cannot be written must never end with another account adopting it.
        XCTAssertEqual(rig.learner.prepare(userId: "bob"), .unavailable)
        XCTAssertNil(rig.templates.load(contactId: ownerId))
        XCTAssertEqual(rig.progress.record?.userId, "alice")
    }

    // MARK: - Record format

    func testRecordCodecRoundTripAndRejectsAnythingElse() throws {
        let record = OwnerVoiceRecord(userId: "alice", embeddingVersion: VoiceprintCodec.formatVersion, refined: false,
                                      windows: windows("a", count: 3) + windows("b", count: 2, day: 1))
        let data = OwnerVoiceRecordCodec.encode(record)
        XCTAssertEqual(OwnerVoiceRecordCodec.decode(data), record)

        XCTAssertNil(OwnerVoiceRecordCodec.decode(data.dropLast()))
        XCTAssertNil(OwnerVoiceRecordCodec.decode(data + Data([0])))
        var badMagic = data
        badMagic[0] ^= 0xFF
        XCTAssertNil(OwnerVoiceRecordCodec.decode(badMagic))
        XCTAssertNil(OwnerVoiceRecordCodec.decode(Data()))

        let notFinite = OwnerVoiceRecord(
            userId: "alice", embeddingVersion: VoiceprintCodec.formatVersion, refined: false,
            windows: [OwnerVoiceLearning.Window(embedding: [Float.nan, 1], callId: "a", capturedAtEpochMs: t0, netSpeechMs: 4_000)])
        XCTAssertNil(OwnerVoiceRecordCodec.decode(OwnerVoiceRecordCodec.encode(notFinite)))
    }
}
