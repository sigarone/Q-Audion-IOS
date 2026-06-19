import XCTest
@testable import QAudionEngine

final class KmsPollerPeriodicTests: XCTestCase {
    /// The periodic driver must fire the supplied async closure once per
    /// interval and stop firing after `stop()`.
    func testPeriodicFiresThenStops() async throws {
        let driver = KmsPeriodicPoller(intervalSeconds: 0.05)
        let counter = TickCounter()
        await driver.start { await counter.bump() }
        try await Task.sleep(nanoseconds: 180_000_000) // ~3 intervals
        await driver.stop()
        let afterStop = await counter.value
        try await Task.sleep(nanoseconds: 120_000_000)
        let later = await counter.value
        XCTAssertGreaterThanOrEqual(afterStop, 2, "expected >=2 ticks in 180ms @50ms")
        XCTAssertEqual(afterStop, later, "no ticks may fire after stop()")
    }

    actor TickCounter { private(set) var value = 0; func bump() { value += 1 } }
}
