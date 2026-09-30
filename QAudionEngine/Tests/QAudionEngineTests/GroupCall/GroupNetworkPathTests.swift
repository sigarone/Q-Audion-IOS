import XCTest
@testable import QAudionEngine

/// Spec 4.7: only a genuine edge restarts ICE; `NWPathMonitor` repeats itself.
final class GroupNetworkPathTests: XCTestCase {

    private typealias Snapshot = GroupNetworkPathPolicy.Snapshot

    private let wifi = Snapshot(satisfied: true, interface: "wifi")
    private let cellular = Snapshot(satisfied: true, interface: "cellular")
    private let offline = Snapshot(satisfied: false, interface: "none")

    func testFirstSampleNeverRestarts() {
        XCTAssertNil(GroupNetworkPathPolicy.changeReason(previous: nil, current: wifi))
        XCTAssertNil(GroupNetworkPathPolicy.changeReason(previous: nil, current: offline))
    }

    func testRepeatedCallbackIsNotAChange() {
        XCTAssertNil(GroupNetworkPathPolicy.changeReason(previous: wifi, current: wifi))
        XCTAssertNil(GroupNetworkPathPolicy.changeReason(previous: offline, current: offline))
    }

    func testInterfaceSwitchRestartsIce() {
        XCTAssertEqual(GroupNetworkPathPolicy.changeReason(previous: wifi, current: cellular), "iface_changed")
        XCTAssertEqual(GroupNetworkPathPolicy.changeReason(previous: cellular, current: wifi), "iface_changed")
    }

    func testPathComingBackAfterAnOutageRestartsIce() {
        XCTAssertEqual(GroupNetworkPathPolicy.changeReason(previous: offline, current: cellular), "path_restored")
    }

    func testLosingTheNetworkDoesNotRestartIce() {
        // Nothing to restart onto: the restart happens when the path is back.
        XCTAssertNil(GroupNetworkPathPolicy.changeReason(previous: wifi, current: offline))
    }

    func testTheRealWatcherStartsAndStopsCleanly() {
        let watcher = GroupNetworkPathWatcher(debounceSeconds: 0.01)
        watcher.start { _ in }
        watcher.stop()
        watcher.stop()
    }
}
