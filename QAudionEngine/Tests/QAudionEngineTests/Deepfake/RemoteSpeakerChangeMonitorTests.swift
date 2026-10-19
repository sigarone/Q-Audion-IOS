import XCTest
@testable import QAudionEngine

/// The verdict of the speaker-change monitor comes from the local detector
/// alone. What the far end reports about its own detector is about THIS
/// device's user, and is not authenticated as coming from that detector, so it
/// is recorded and nothing more.
final class RemoteSpeakerChangeMonitorTests: XCTestCase {

    private final class VerdictLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [RemoteSpeakerChangeMonitor.Verdict] = []
        func add(_ verdict: RemoteSpeakerChangeMonitor.Verdict) { lock.lock(); seen.append(verdict); lock.unlock() }
        var all: [RemoteSpeakerChangeMonitor.Verdict] { lock.lock(); defer { lock.unlock() }; return seen }
    }

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

    // MARK: - The peer's report does not move the verdict

    func testAPeerReportAloneLeavesAnUnknownVerdictUnknown() {
        let monitor = RemoteSpeakerChangeMonitor()
        let log = VerdictLog()
        monitor.onVerdictChanged = { log.add($0) }
        monitor.onPeerReportedChange(true)
        XCTAssertEqual(monitor.verdict, RemoteSpeakerChangeMonitor.Verdict(level: .unknown))
        XCTAssertTrue(log.all.isEmpty, "nothing changed, so nothing is announced")
    }

    func testAPeerReportAloneLeavesASteadyVerdictSteady() {
        let monitor = steadyMonitor()
        let log = VerdictLog()
        monitor.onVerdictChanged = { log.add($0) }
        monitor.onPeerReportedChange(true)
        XCTAssertEqual(level(monitor), .steady, "the report must not turn the card amber")
        monitor.onPeerReportedChange(false)
        XCTAssertEqual(level(monitor), .steady)
        XCTAssertTrue(log.all.isEmpty)
    }

    /// Agreeing with the local detector is not corroboration either: the two
    /// detectors do not listen to the same voice.
    func testAPeerReportAddsNothingToALocalSuspectOrChange() {
        let monitor = steadyMonitor()
        monitor.feed(0.2)
        let suspect = monitor.verdict
        XCTAssertEqual(suspect, RemoteSpeakerChangeMonitor.Verdict(level: .suspect))
        monitor.onPeerReportedChange(true)
        XCTAssertEqual(monitor.verdict, suspect)
        monitor.feed(0.2)
        monitor.feed(0.2)
        XCTAssertEqual(monitor.verdict, RemoteSpeakerChangeMonitor.Verdict(level: .changed))
        monitor.onPeerReportedChange(false)
        XCTAssertEqual(monitor.verdict, RemoteSpeakerChangeMonitor.Verdict(level: .changed))
    }

    /// The same scores give the same verdicts with or without the report.
    func testTheVerdictsAreTheSameWithAndWithoutAPeerReport() {
        let scores: [Float?] = [0.8, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8, nil, 0.8, 0.2, 0.2, 0.2, 0.8]
        let plain = RemoteSpeakerChangeMonitor()
        let reported = RemoteSpeakerChangeMonitor()
        reported.onPeerReportedChange(true)
        for score in scores {
            plain.feed(score)
            reported.feed(score)
            XCTAssertEqual(plain.verdict, reported.verdict)
        }
    }

    /// The claim is kept, for the day it is authenticated, and a new call
    /// forgets it.
    func testTheClaimIsRecordedAndForgottenOnReset() {
        let monitor = steadyMonitor()
        XCTAssertFalse(monitor.peerReportedChange)
        monitor.onPeerReportedChange(true)
        XCTAssertTrue(monitor.peerReportedChange)
        monitor.onPeerReportedChange(false)
        XCTAssertFalse(monitor.peerReportedChange)
        monitor.onPeerReportedChange(true)
        monitor.reset()
        XCTAssertFalse(monitor.peerReportedChange)
        XCTAssertEqual(level(monitor), .unknown)
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
