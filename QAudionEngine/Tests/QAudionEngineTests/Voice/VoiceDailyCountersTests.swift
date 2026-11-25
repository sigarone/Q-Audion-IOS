import XCTest
import Foundation
@testable import QAudionEngine

/// The id-free daily counters: what a call adds, the lines of a day, the moment at which they go out, and that nothing of a
/// contact reaches a line.
final class VoiceDailyCountersTests: XCTestCase {
    private final class Memory: VoiceDailyStorage {
        var data: Data?
        func load() -> Data? { data }
        func save(_ newData: Data) { data = newData }
        func clear() { data = nil }
    }

    private func summary(res: String = "match", verify: Bool = true, shadow: Bool = false, speechS: Int64 = 60, margin: Int = 0,
                         route: Int = 1, newDevice: Bool = false) -> VoiceCallSummary {
        VoiceCallSummary(res: res, verifyMode: verify, shadow: shadow, speechS: speechS, margin: margin, routeClass: route,
                         newDevice: newDevice)
    }

    private func call(_ s: VoiceCallSummary, contact: String = "c1", endS: Int = 1_790_000_000) -> VoiceDailyCall {
        VoiceDailyCall(summary: s, contactId: contact, endS: endS, utcOffsetS: 0)
    }

    private let day = VoiceDailyCounters.dayIndex(1_790_000_000, utcOffsetS: 0)

    func testARecordOfAnEarlierWipeEpochIsRefusedInsideTheLock() {
        let storage = Memory()
        let counters = VoiceDailyCounters(storage: storage, random: { 0 })
        let before = counters.epoch
        counters.wipe()
        XCTAssertNotEqual(counters.epoch, before)
        counters.record(call(summary()), ifEpoch: before)
        XCTAssertNil(storage.data, "nothing is persisted for a call of before the wipe")
        XCTAssertTrue(counters.dueLines(nowS: 1_790_000_000 + 5 * 86_400, utcOffsetS: 0).isEmpty)
        counters.record(call(summary()), ifEpoch: counters.epoch)
        XCTAssertNotNil(storage.data)
    }

    func testACallOfAnEnrolledContactAddsToItsStateItsRouteAndItsStratum() {
        let counters = VoiceDailyCounters(storage: Memory(), random: { 100 })
        counters.record(call(summary(res: "match", speechS: 60, margin: 2, route: 2)))
        counters.record(call(summary(res: "diff", shadow: true, speechS: 25 * 60, margin: 4, route: 3, newDevice: true), contact: "c2"))
        let lines = counters.dueLines(nowS: 1_790_000_000 + 3 * 86_400, utcOffsetS: 0)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(
            lines[0],
            "QA-VOICE v=1 ev=day calls=2 off=0 match=1 chk=0 nover=0 diff=1 sdiff=1 chg=0 schg=0 hs=0 spk=1 hf=1 unk=0 newdev=1 "
                + "enr=2 enrtot=2 lrn=0 mk=0")
        XCTAssertEqual(lines[1], "QA-VOICE v=1 ev=dstr st=1 calls=1 sdiff=0 m1=1 m2=1 m3=0 m4=0")
        XCTAssertEqual(lines[2], "QA-VOICE v=1 ev=dstr st=2 calls=0 sdiff=0 m1=0 m2=0 m3=0 m4=0")
        XCTAssertEqual(lines[3], "QA-VOICE v=1 ev=dstr st=3 calls=1 sdiff=1 m1=1 m2=1 m3=1 m4=1")
        XCTAssertEqual(lines[4], "QA-VOICE v=1 ev=dstr st=4 calls=0 sdiff=0 m1=0 m2=0 m3=0 m4=0")
    }

    func testEarAndWiredAreHandsetSpeakerIsLoudspeakerBluetoothAndCarAreHandsFreeAndUnknownIsItsOwnGroup() {
        let counters = VoiceDailyCounters(storage: Memory(), random: { 0 })
        // The codes of `route_class_codes`: unknown 0, ear 1, speaker 2, bt 3, wired 4, car 5; a code that is not in the table.
        for (i, route) in [0, 1, 2, 3, 4, 5, 99].enumerated() {
            counters.record(call(summary(route: route), contact: "c\(i)"))
        }
        let line = counters.dueLines(nowS: 1_790_000_000 + 3 * 86_400, utcOffsetS: 0)[0]
        XCTAssertTrue(line.contains(" hs=2 spk=1 hf=2 unk=2 "), line)
    }

    func testTheStrataSplitAtTwoTenAndThirtyMinutesOfSpeech() {
        XCTAssertEqual(VoiceDailyCounters.stratum(speechS: 120), 0)
        XCTAssertEqual(VoiceDailyCounters.stratum(speechS: 121), 1)
        XCTAssertEqual(VoiceDailyCounters.stratum(speechS: 600), 1)
        XCTAssertEqual(VoiceDailyCounters.stratum(speechS: 601), 2)
        XCTAssertEqual(VoiceDailyCounters.stratum(speechS: 1800), 2)
        XCTAssertEqual(VoiceDailyCounters.stratum(speechS: 1801), 3)
    }

    func testALearningContactCountsAsLearningAndItsShadowChange() {
        let counters = VoiceDailyCounters(storage: Memory(), random: { 0 })
        counters.record(call(summary(res: "na", verify: false, shadow: true)))
        counters.record(call(summary(res: "chg", verify: false, shadow: true), contact: "c2"))
        let line = counters.dueLines(nowS: 1_790_000_000 + 3 * 86_400, utcOffsetS: 0)[0]
        XCTAssertTrue(line.contains(" calls=0 "), line)
        XCTAssertTrue(line.contains(" chg=1 schg=2 "), line)
        XCTAssertTrue(line.contains(" lrn=2 "), line)
    }

    func testTheSameContactIsOneDistinctContactAndTheTotalCountsEveryDay() {
        let counters = VoiceDailyCounters(storage: Memory(), random: { 0 })
        counters.record(call(summary(), contact: "Alice"))
        counters.record(call(summary(), contact: "alice"))
        counters.record(call(summary(), contact: "bob", endS: 1_790_000_000 + 86_400))
        let lines = counters.dueLines(nowS: 1_790_000_000 + 5 * 86_400, utcOffsetS: 0)
        XCTAssertEqual(lines.count, 10, "two days")
        XCTAssertTrue(lines[0].contains(" enr=1 enrtot=2 "), lines[0])
        XCTAssertTrue(lines[5].contains(" enr=1 enrtot=2 "), lines[5])
    }

    func testADayIsWrittenOnlyAfterItsRandomMomentOfTheNextDayAndOnlyOnce() {
        let counters = VoiceDailyCounters(storage: Memory(), random: { 3_600 })
        counters.record(call(summary()))
        let startOfNext = (day + 1) * 86_400
        XCTAssertTrue(counters.dueLines(nowS: startOfNext - 1, utcOffsetS: 0).isEmpty, "the day is not over")
        XCTAssertTrue(counters.dueLines(nowS: startOfNext + 3_599, utcOffsetS: 0).isEmpty, "before the random moment")
        XCTAssertEqual(counters.dueLines(nowS: startOfNext + 3_600, utcOffsetS: 0).count, 5)
        XCTAssertTrue(counters.dueLines(nowS: startOfNext + 90_000, utcOffsetS: 0).isEmpty, "once")
    }

    func testTheMomentIsKeptInsideTheNextDayWhateverTheRandomNumberIs() {
        let high = VoiceDailyCounters(storage: Memory(), random: { 10_000_000 })
        high.record(call(summary()))
        XCTAssertEqual(high.dueLines(nowS: (day + 2) * 86_400, utcOffsetS: 0).count, 5)
        let low = VoiceDailyCounters(storage: Memory(), random: { -50 })
        low.record(call(summary()))
        XCTAssertEqual(low.dueLines(nowS: (day + 1) * 86_400, utcOffsetS: 0).count, 5)
    }

    func testTheStateSurvivesARestart() {
        let storage = Memory()
        let first = VoiceDailyCounters(storage: storage, random: { 0 })
        first.record(call(summary(res: "match")))
        let second = VoiceDailyCounters(storage: storage, random: { 0 })
        let lines = second.dueLines(nowS: 1_790_000_000 + 3 * 86_400, utcOffsetS: 0)
        XCTAssertTrue(lines[0].contains(" calls=1 off=0 match=1 "), lines[0])
    }

    func testAWipeForgetsEverything() {
        let storage = Memory()
        let counters = VoiceDailyCounters(storage: storage, random: { 0 })
        counters.record(call(summary()))
        counters.wipe()
        XCTAssertNil(storage.data)
        XCTAssertTrue(counters.dueLines(nowS: 1_790_000_000 + 9 * 86_400, utcOffsetS: 0).isEmpty)
    }

    func testNoLineCarriesAContactOrACallAndEveryNumberIsCapped() {
        let counters = VoiceDailyCounters(storage: Memory(), random: { 0 })
        for i in 0..<1_200 {
            counters.record(call(summary(res: "match", shadow: true, speechS: 5_000_000, margin: 4), contact: "contact-\(i)"))
        }
        let lines = counters.dueLines(nowS: 1_790_000_000 + 3 * 86_400, utcOffsetS: 0)
        XCTAssertTrue(lines[0].contains(" enr=999 "), "distinct contacts are capped at 999: \(lines[0])")
        for line in lines {
            XCTAssertFalse(line.contains("contact"), line)
            XCTAssertFalse(line.contains("call="), "a daily line has no call number: \(line)")
        }
    }
}
