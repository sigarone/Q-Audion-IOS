import XCTest
@testable import QAudionEngine

/// The verdict of the speaker-change monitor comes from the local detector
/// alone.
final class RemoteSpeakerChangeMonitorTests: XCTestCase {

    /// A monitor that has settled on a steady voice: the first scores build the
    /// reference (the detector needs six), the next ones are equal to it.
    private func steadyMonitor() -> RemoteSpeakerChangeMonitor {
        let monitor = RemoteSpeakerChangeMonitor()
        for _ in 0..<10 { monitor.feed(0.8) }
        return monitor
    }

    private func level(_ monitor: RemoteSpeakerChangeMonitor) -> RemoteSpeakerChangeMonitor.Level {
        monitor.verdict.level
    }

    func testStartsUnknown() {
        XCTAssertEqual(level(RemoteSpeakerChangeMonitor()), .unknown)
    }

    func testTheLocalDetectorSetsTheLevel() {
        let monitor = steadyMonitor()
        XCTAssertEqual(level(monitor), .steady)
        monitor.feed(0.2)
        XCTAssertEqual(level(monitor), .suspect)
        monitor.feed(0.2)
        monitor.feed(0.2)
        XCTAssertEqual(level(monitor), .changed)
    }

    // MARK: - Re-anchoring

    /// After a re-anchor the detector builds a new reference: the next score is
    /// read as the start of one, so the verdict goes back to unknown.
    func testReanchorStartsTheReferenceOver() {
        let monitor = steadyMonitor()
        XCTAssertEqual(level(monitor), .steady)
        monitor.reanchor()
        monitor.feed(0.5)
        XCTAssertEqual(level(monitor), .unknown)
    }

    // MARK: - Display switch and level-change log

    func testTheVerdictIsNotShownToTheUser() {
        XCTAssertFalse(RemoteSpeakerChangeMonitor.verdictShownToUser)
    }

    private final class Lines {
        var all: [String] = []
    }

    private func loggedMonitor(_ lines: Lines) -> RemoteSpeakerChangeMonitor {
        RemoteSpeakerChangeMonitor(detector: SpeakerChangeDetector(), log: { lines.all.append($0) })
    }

    /// One line per change of level, none per score.
    func testEachChangeOfLevelIsLoggedOnceAndNoScoreIsLoggedByItself() {
        let lines = Lines()
        let monitor = loggedMonitor(lines)
        for _ in 0..<6 { monitor.feed(0.8) }
        monitor.feed(nil)
        XCTAssertEqual(lines.all, [], "warm-up: the level stays unknown")

        monitor.feed(0.8)
        XCTAssertEqual(lines.all, ["[Voice] change lv=1 n=7 base=0.80 sd=0.03 cur=0.80"])
        for _ in 0..<3 { monitor.feed(0.8) }
        XCTAssertEqual(lines.all.count, 1, "scores that keep the level are not logged")

        monitor.feed(0.2)
        monitor.feed(0.2)
        XCTAssertEqual(lines.all.count, 2, "a second score at the same level is not logged")
        XCTAssertEqual(lines.all[1], "[Voice] change lv=2 n=11 base=0.80 sd=0.03 cur=0.20")

        monitor.feed(0.2)
        XCTAssertEqual(lines.all[2], "[Voice] change lv=3 n=13 base=0.80 sd=0.03 cur=0.20")
        XCTAssertEqual(level(monitor), .changed)

        monitor.reset()
        monitor.reset()
        XCTAssertEqual(lines.all.count, 4)
        XCTAssertEqual(lines.all[3], "[Voice] change lv=0 n=0")
    }

    /// A re-anchor that puts the verdict back to unknown is a change of level: logged without a reference.
    func testAReanchorThatReturnsToUnknownIsLoggedWithoutAReference() {
        let lines = Lines()
        let monitor = loggedMonitor(lines)
        for _ in 0..<7 { monitor.feed(0.8) }
        monitor.reanchor()
        monitor.feed(0.5)
        XCTAssertEqual(lines.all.last, "[Voice] change lv=0 n=8 cur=0.50")
    }

    func testTheLineShape() {
        XCTAssertEqual(RemoteSpeakerChangeMonitor.transitionLine(level: .steady, scores: 7, reference: 0.63,
                                                                 deviation: 0.05, last: 0.58),
                       "[Voice] change lv=1 n=7 base=0.63 sd=0.05 cur=0.58")
        XCTAssertEqual(RemoteSpeakerChangeMonitor.transitionLine(level: .suspect, scores: 40, reference: -0.12,
                                                                 deviation: 0.3, last: -0.55),
                       "[Voice] change lv=2 n=40 base=-0.12 sd=0.30 cur=-0.55")
        XCTAssertEqual(RemoteSpeakerChangeMonitor.transitionLine(level: .unknown, scores: 0, reference: nil,
                                                                 deviation: nil, last: nil),
                       "[Voice] change lv=0 n=0")
    }
}
