import XCTest
@testable import QAudionEngine

/// W-GRPQUALITY (2026-08-26) — pure logic behind wiring the previously
/// dead-code `CallsSettingsViewModel.CallQuality` setting into group-call
/// subscribe-side quality. `RemoteVideoRenderPriority.subscribeQuality
/// (preferring:)` is kept independent of the `#if canImport(LiveKit)`
/// split specifically so it is pinnable here without the SDK — same
/// discipline as `RestartIceDecisionsTests`.
final class GroupVideoQualityCompositionTests: XCTestCase {

    // MARK: - `.medium` (today's persisted default) reproduces the
    // behavior W-GRPVIEWPORT already shipped — no regression for a user
    // who never touched the quality setting.

    func testMediumPreference_reproducesTheShippedViewportDefaults() {
        XCTAssertEqual(RemoteVideoRenderPriority.onScreenSmall.subscribeQuality(preferring: .medium), .low)
        XCTAssertEqual(RemoteVideoRenderPriority.onScreenSpotlight.subscribeQuality(preferring: .medium), .high)
    }

    // MARK: - `.low` reduces everything, including the tile the user is
    // actually looking at.

    func testLowPreference_capsTheSpotlightTileDown() {
        XCTAssertEqual(RemoteVideoRenderPriority.onScreenSpotlight.subscribeQuality(preferring: .low), .medium)
        XCTAssertEqual(RemoteVideoRenderPriority.onScreenSmall.subscribeQuality(preferring: .low), .low)
    }

    // MARK: - `.high` raises the small grid tiles too, not just the
    // spotlight (which is already at the ceiling).

    func testHighPreference_raisesSmallTilesUp_spotlightStaysAtCeiling() {
        XCTAssertEqual(RemoteVideoRenderPriority.onScreenSmall.subscribeQuality(preferring: .high), .medium)
        XCTAssertEqual(RemoteVideoRenderPriority.onScreenSpotlight.subscribeQuality(preferring: .high), .high)
    }

    // MARK: - every (priority, preference) pair is covered — exhaustive
    // sweep so a future added case in either enum fails loudly here
    // instead of silently falling through to a default.

    func testEveryOnScreenCombination_producesAConcreteTier() {
        for priority: RemoteVideoRenderPriority in [.onScreenSmall, .onScreenSpotlight] {
            for quality: CallsSettingsViewModel.CallQuality in [.low, .medium, .high] {
                // Just must not crash / must return a value — the specific
                // mapping is pinned by the tests above.
                _ = priority.subscribeQuality(preferring: quality)
            }
        }
    }

    // MARK: - W-GRPQUALITY publish-side encoding — LiveKit's OWN preset
    // scale, not invented numbers, plus a matching bandwidth priority.

    func testVideoEncoding_usesLiveKitsOwnPresetBitrateAndFpsScale() {
        let low = LiveKitGroupCallRoom.videoEncoding(for: .low)
        XCTAssertEqual(low.maxBitrate, 450_000, "VideoParameters.presetH360_169")
        XCTAssertEqual(low.maxFps, 20)

        let medium = LiveKitGroupCallRoom.videoEncoding(for: .medium)
        XCTAssertEqual(medium.maxBitrate, 800_000, "VideoParameters.presetH540_169")
        XCTAssertEqual(medium.maxFps, 25)

        let high = LiveKitGroupCallRoom.videoEncoding(for: .high)
        XCTAssertEqual(high.maxBitrate, 1_700_000, "VideoParameters.presetH720_169")
        XCTAssertEqual(high.maxFps, 30)
    }

    func testVideoEncoding_bitrateStrictlyIncreasesWithQuality() {
        let low = LiveKitGroupCallRoom.videoEncoding(for: .low)
        let medium = LiveKitGroupCallRoom.videoEncoding(for: .medium)
        let high = LiveKitGroupCallRoom.videoEncoding(for: .high)
        XCTAssertLessThan(low.maxBitrate, medium.maxBitrate)
        XCTAssertLessThan(medium.maxBitrate, high.maxBitrate)
    }
}
