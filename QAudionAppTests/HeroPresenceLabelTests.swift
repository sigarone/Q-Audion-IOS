import XCTest
@testable import QAudionApp

/// I3 (W445 presence audit): pins that `ContactDetailScreen`'s hero label
/// never lets `.unknown` (no `presence_update` received yet for this peer)
/// collapse into the same string as a genuinely-confirmed `.offline` peer.
///
/// NOTE (not yet wired into a build target): this repo has no
/// `QAudionAppTests` XCTest target in `QAudionApp/project.yml` today — only
/// `QAudionEngine` ships a runnable `swift test` / `xcodebuild test` harness.
/// This file is written against that gap so wiring it in later is a small,
/// mechanical project.yml addition (a `bundle.unit-test` target depending on
/// `QAudionApp`) rather than blind infrastructure added without any way to
/// verify it compiles — this session has no macOS/Xcode/swift toolchain
/// available to validate an XcodeGen change. See the task report for the
/// full reasoning.
final class HeroPresenceLabelTests: XCTestCase {

    /// The exact regression this whole ticket is about: before the fix,
    /// BOTH `.unknown` and `.offline` rendered the literal string "offline"
    /// — a contact we simply haven't heard from yet was indistinguishable
    /// from one the server told us for a fact is offline. This assertion
    /// FAILS against the pre-fix code (both branches returned "offline").
    func test_unknownAndOffline_produceDifferentText() {
        let unknown = HeroPresenceLabel.select(presence: .unknown, isVerified: false)
        let offline = HeroPresenceLabel.select(presence: .offline, isVerified: false)
        XCTAssertNotEqual(unknown.text, offline.text)
    }

    func test_unknown_mapsToDistinctCase() {
        let label = HeroPresenceLabel.select(presence: .unknown, isVerified: true)
        XCTAssertEqual(label, .unknown)
    }

    /// `.invisible` intentionally still reads as "offline" — the peer chose
    /// to appear offline, so surfacing it as "unknown" would be misleading
    /// in the other direction. Only `.unknown` (no data at all) is special.
    func test_offlineAndInvisible_shareTheSameText() {
        let offline = HeroPresenceLabel.select(presence: .offline, isVerified: false)
        let invisible = HeroPresenceLabel.select(presence: .invisible, isVerified: false)
        XCTAssertEqual(offline.text, invisible.text)
    }

    func test_online_verified_mentionsVerifiedVoice() {
        let label = HeroPresenceLabel.select(presence: .online, isVerified: true)
        XCTAssertTrue(label.text.contains("verified voice"))
    }

    func test_online_unverified_mentionsNonVerificata() {
        let label = HeroPresenceLabel.select(presence: .online, isVerified: false)
        XCTAssertTrue(label.text.contains("non verificata"))
    }

    func test_inCall_and_doNotDisturb_useExtendedPresenceLabels() {
        XCTAssertEqual(
            HeroPresenceLabel.select(presence: .inCall, isVerified: false).text,
            ExtendedPresence.inCall.label
        )
        XCTAssertEqual(
            HeroPresenceLabel.select(presence: .doNotDisturb, isVerified: false).text,
            ExtendedPresence.doNotDisturb.label
        )
    }
}
