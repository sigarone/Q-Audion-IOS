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
}
