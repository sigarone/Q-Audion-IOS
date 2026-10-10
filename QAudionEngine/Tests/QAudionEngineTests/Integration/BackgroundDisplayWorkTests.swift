import XCTest
@testable import QAudionEngine

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Display-only call work (voice ribbon analysis, spectrum, confidence wave) is
/// skipped while the app is in the background and resumes in the foreground.
final class BackgroundDisplayWorkTests: XCTestCase {

    // MARK: - AppBackgroundFlag

    func testFlagDefaultsToForegroundAndFollowsSet() {
        let flag = AppBackgroundFlag()
        XCTAssertFalse(flag.isInBackground)
        flag.set(isInBackground: true)
        XCTAssertTrue(flag.isInBackground)
        flag.set(isInBackground: false)
        XCTAssertFalse(flag.isInBackground)
    }

    func testFlagIsReadableFromOtherQueuesWhileItIsWritten() {
        let flag = AppBackgroundFlag()
        let done = expectation(description: "readers done")
        done.expectedFulfillmentCount = 4
        for _ in 0..<4 {
            DispatchQueue.global().async {
                for i in 0..<2000 {
                    _ = flag.isInBackground
                    if i % 100 == 0 { flag.set(isInBackground: i % 200 == 0) }
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
        flag.set(isInBackground: true)
        let seen = expectation(description: "seen on another queue")
        DispatchQueue.global().async {
            XCTAssertTrue(flag.isInBackground)
            seen.fulfill()
        }
        wait(for: [seen], timeout: 5)
    }

    // MARK: - DisplayWorkGate (fake clock)

    func testGateRunsAtItsNormalCadenceInTheForeground() {
        var gate = DisplayWorkGate(minIntervalNs: 66_000_000)
        var runs = 0
        // 20 ms steps for 1 s: one run every 4th step (80 ms >= 66 ms).
        for step in 1...50 {
            if gate.shouldRun(nowNs: UInt64(step) * 20_000_000, isInBackground: false) { runs += 1 }
        }
        XCTAssertEqual(runs, 12)
    }

    func testGateNeverRunsInTheBackgroundAndResumesImmediatelyOnReturn() {
        var gate = DisplayWorkGate(minIntervalNs: 66_000_000)
        XCTAssertTrue(gate.shouldRun(nowNs: 1_000_000_000, isInBackground: false))
        var runsInBackground = 0
        for step in 1...200 {
            if gate.shouldRun(nowNs: 1_000_000_000 + UInt64(step) * 20_000_000, isInBackground: true) {
                runsInBackground += 1
            }
        }
        XCTAssertEqual(runsInBackground, 0)
        // Back in the foreground: the very next call runs (the schedule was not advanced), then the cadence holds.
        let back: UInt64 = 1_000_000_000 + 201 * 20_000_000
        XCTAssertTrue(gate.shouldRun(nowNs: back, isInBackground: false))
        XCTAssertFalse(gate.shouldRun(nowNs: back + 20_000_000, isInBackground: false))
        XCTAssertTrue(gate.shouldRun(nowNs: back + 80_000_000, isInBackground: false))
    }

    // MARK: - QAudionCallIntegration.analyze (through the native-SRTP RX tap)

    /// 20 ms of a 300 Hz tone at 48 kHz, Int16 mono little-endian.
    private func toneFrame(phase: Int) -> Data {
        var out = Data(capacity: 960 * 2)
        for i in 0..<960 {
            let v = Int16(8000 * sin(2 * Double.pi * 300 * Double(phase + i) / 48_000))
            withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    private func feedFrames(_ integration: QAudionCallIntegration, frames: Int) {
        // The RX ring is bounded (drop-oldest): hand the frames over in small batches.
        for n in 0..<frames {
            integration.feedNativeAudioSrtpRxPcm(toneFrame(phase: n * 960))
            if n % 5 == 4 { integration.drainAnalysisForTesting() }
        }
        integration.drainAnalysisForTesting()
        // Spectrum bands are delivered on the main queue.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    func testRibbonAnalysisAndSpectrumRunInTheForeground() {
        let integration = QAudionCallIntegration()
        integration.backgroundFlag = AppBackgroundFlag()
        let analysis = Counter()
        let spectrum = Counter()
        integration.getVoiceAnalysis().onResult = { _ in analysis.bump() }
        integration.onVoiceSpectrum = { _ in spectrum.bump() }

        feedFrames(integration, frames: 100)   // 2 s of audio

        XCTAssertGreaterThan(analysis.value, 0, "voice analysis must run in the foreground")
        XCTAssertGreaterThan(spectrum.value, 0, "spectrum must run in the foreground")
    }

    func testRibbonAnalysisAndSpectrumStopInTheBackgroundAndResume() {
        let integration = QAudionCallIntegration()
        let flag = AppBackgroundFlag()
        integration.backgroundFlag = flag
        let analysis = Counter()
        let spectrum = Counter()
        integration.getVoiceAnalysis().onResult = { _ in analysis.bump() }
        integration.onVoiceSpectrum = { _ in spectrum.bump() }

        flag.set(isInBackground: true)
        feedFrames(integration, frames: 100)
        XCTAssertEqual(analysis.value, 0, "no voice analysis in the background")
        XCTAssertEqual(spectrum.value, 0, "no spectrum in the background")

        flag.set(isInBackground: false)
        feedFrames(integration, frames: 100)
        XCTAssertGreaterThan(analysis.value, 0, "voice analysis resumes in the foreground")
        XCTAssertGreaterThan(spectrum.value, 0, "spectrum resumes in the foreground")
    }

    // MARK: - App-layer wiring (source invariants: AppState needs a live app to run)

    private func repoSource(_ relative: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw XCTSkip("could not locate \(relative) from \(#filePath)")
    }

    func testTheAppLayerKeepsTheFlagCurrentFromBothLifecycleNotifications() throws {
        let src = try repoSource("QAudionApp/AppState.swift")
        let fg = src.components(separatedBy: "AppBackgroundFlag.shared.set(isInBackground: false)").count - 1
        let bg = src.components(separatedBy: "AppBackgroundFlag.shared.set(isInBackground: true)").count - 1
        XCTAssertEqual(fg, 1, "willEnterForeground must clear the flag")
        XCTAssertEqual(bg, 1, "didEnterBackground must set the flag")
        XCTAssertTrue(src.contains("UIApplication.shared.applicationState == .background"),
                      "the start-up value is read once, on the main thread")
    }

    func testTheConfidenceWaveSamplerSkipsItsTickInTheBackgroundBeforeHoppingToTheMainActor() throws {
        let src = try repoSource("QAudionApp/AppState.swift")
        guard let start = src.range(of: "private func startVoiceConfidenceWaveSampler()") else {
            return XCTFail("sampler not found")
        }
        let body = String(src[start.lowerBound...].prefix(1500))
        guard let guardRange = body.range(of: "if AppBackgroundFlag.shared.isInBackground { return }"),
              let taskRange = body.range(of: "Task { @MainActor") else {
            return XCTFail("background guard or Task hop not found")
        }
        XCTAssertLessThan(guardRange.lowerBound, taskRange.lowerBound,
                          "the guard must come before the per-tick Task is created")
    }
}
