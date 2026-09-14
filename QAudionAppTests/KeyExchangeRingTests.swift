import XCTest
@testable import QAudionApp

/// Pins `ringPhase(for:)` — the pure, free-function mapping from
/// `OutgoingCallScreen.State` (the 5-case call state machine) onto
/// `KeyExchangeRing.Phase` (the ring's 3-case animation phase). Extracted
/// specifically so this mapping is unit-testable without hosting a SwiftUI
/// view; see `KeyExchangeRing.swift`'s doc comment on `ringPhase(for:)` for
/// why `.dialing`/`.handshaking` collapse together and why `.rekeying`
/// (documented dead in production wiring today) still maps to `.settled`
/// instead of being left unhandled.
///
/// NOTE (not yet wired into a build target): same gap `HeroPresenceLabelTests
/// .swift`/`NoCallInFlightTests.swift`/`AbrControllerCpuBackpressureTests
/// .swift` already document — this repo has no `QAudionAppTests` XCTest
/// target in `QAudionApp/project.yml` today, only `QAudionEngine` ships a
/// runnable `swift test` / `xcodebuild test` harness. Written against that
/// gap (no macOS/Xcode/swift toolchain available in this session to
/// validate a project.yml change) so wiring it in later is a small,
/// mechanical addition rather than infrastructure added blind.
final class KeyExchangeRingTests: XCTestCase {
    func testDialingAndHandshakingBothMapToHandshaking() {
        XCTAssertEqual(ringPhase(for: .dialing), .handshaking)
        XCTAssertEqual(ringPhase(for: .handshaking), .handshaking)
    }

    func testConnectedMapsToCrystallizing() {
        XCTAssertEqual(ringPhase(for: .connected), .crystallizing)
    }

    func testRekeyingAndEndedBothMapToSettled() {
        XCTAssertEqual(ringPhase(for: .rekeying), .settled)
        XCTAssertEqual(ringPhase(for: .ended), .settled)
    }
}
