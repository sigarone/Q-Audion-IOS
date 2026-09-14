import XCTest
import QAudionEngine
@testable import QAudionApp

/// B9 (W-WSBANNER, 2026-09-02): pins the `ConnectionState` → banner mapping
/// `ChatListScreen`'s WS-health banner relies on — the healthy states
/// (`.connected`, `.authenticated`) must never produce a banner, and the two
/// unhealthy ones must always produce a DISTINCT one so "no server leg at
/// all" is never confused in the UI with "actively retrying".
///
/// NOTE (not yet wired into a build target): same gap `HeroPresenceLabelTests`
/// documents — this repo has no `QAudionAppTests` XCTest target in
/// `QAudionApp/project.yml` today, only `QAudionEngine` ships a runnable
/// `swift test` / `xcodebuild test` harness. Written against that gap
/// (no macOS/Xcode/swift toolchain available in this session to validate a
/// project.yml change) so wiring it in later is a small, mechanical addition.
final class ConnectionStatusBannerPolicyTests: XCTestCase {

    func test_disconnected_and_connecting_produceDifferentBanners() {
        let disconnected = ConnectionStatusBannerPolicy.select(.disconnected)
        let reconnecting = ConnectionStatusBannerPolicy.select(.connecting)
        XCTAssertEqual(disconnected, .disconnected)
        XCTAssertEqual(reconnecting, .reconnecting)
        XCTAssertNotEqual(disconnected, reconnecting)
    }

    /// The regression this exists to prevent: `.connected` is a transient
    /// pre-auth step (see the policy's own doc), NOT a healthy end state on
    /// its own — a naive `!= .authenticated` banner condition would flash on
    /// every ordinary login.
    func test_connected_and_authenticated_produceNoBanner() {
        XCTAssertNil(ConnectionStatusBannerPolicy.select(.connected))
        XCTAssertNil(ConnectionStatusBannerPolicy.select(.authenticated))
    }

    func test_disconnected_and_reconnecting_haveDistinctTitlesAndIcons() {
        let disconnected = ConnectionStatusBannerPolicy.disconnected
        let reconnecting = ConnectionStatusBannerPolicy.reconnecting
        XCTAssertNotEqual(disconnected.title, reconnecting.title)
        XCTAssertNotEqual(disconnected.systemImage, reconnecting.systemImage)
    }
}
