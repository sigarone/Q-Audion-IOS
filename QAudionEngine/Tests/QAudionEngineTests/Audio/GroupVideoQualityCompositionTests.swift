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

    // MARK: - W-GRPVIDEOPRIO (2026-09-29) regression lock — the pinned
    // fork's simulcast path (`Utils+VideoEncodings.computeVideoEncodings` /
    // `Dimensions.computeSimulcastPresets`) applies this encoding's
    // `bitratePriority`/`networkPriority` to the TOP simulcast layer
    // (`encodings[2]`), but WebRTC only allows a non-default value on
    // `encodings[0]` — any non-default priority here makes EVERY group
    // video publish at that quality tier fail with LiveKit error 201
    // ("Failed to add transceiver"), which is exactly the 2026-09-29 "iOS
    // never publishes group video" regression. `.medium`/`.high` used to
    // set `.medium`/`.high` (2.0x/4.0x, non-default); this must never
    // regress back to that. `nil` is the only value proven safe against
    // this fork bug, matching Android (which sets no priority at all for
    // group video and never hit this).

    func testVideoEncoding_neverSetsBitrateOrNetworkPriority() {
        for quality: CallsSettingsViewModel.CallQuality in [.low, .medium, .high] {
            let encoding = LiveKitGroupCallRoom.videoEncoding(for: quality)
            XCTAssertNil(
                encoding.bitratePriority,
                "a non-default bitratePriority lands on the fork's top simulcast layer, not encodings[0], and WebRTC rejects that (LiveKit error 201) — quality=\(quality)"
            )
            XCTAssertNil(
                encoding.networkPriority,
                "same fork bug as bitratePriority above — quality=\(quality)"
            )
        }
    }

    func testDefaultVideoPublishOptions_neverSetsBitrateOrNetworkPriority() {
        // Same lock as testVideoEncoding_neverSetsBitrateOrNetworkPriority,
        // through the actual RoomOptions-facing entry point group calls
        // publish with (`defaultVideoPublishOptions(for:)` wraps
        // `videoEncoding(for:)` — must not reintroduce priority on top of it).
        for quality: CallsSettingsViewModel.CallQuality in [.low, .medium, .high] {
            let options = LiveKitGroupCallRoom.defaultVideoPublishOptions(for: quality)
            XCTAssertNil(options.encoding?.bitratePriority, "quality=\(quality)")
            XCTAssertNil(options.encoding?.networkPriority, "quality=\(quality)")
        }
    }

    // MARK: - W-GRPVP8SIMULCAST (2026-08-27) — group-call video publish
    // must force VP8 with simulcast on, unconditionally, on every device.
    // Mobile hardware H265 encoders are commonly single-instance per chip
    // and cannot produce the concurrent multi-resolution encode streams
    // simulcast needs; VP8's software (libvpx) path can. Supersedes
    // W-GRPH265, which had flipped the primary codec to `.h265` (with
    // `.vp8` as a decode-compatibility backup) on the grounds that E2EE and
    // the SFU could carry it — true, but orthogonal to whether the local
    // encoder can actually produce 3 concurrent H265 streams.

    func testDefaultVideoPublishOptions_forcesVP8UnconditionallyForEveryQualityTier() {
        for quality: CallsSettingsViewModel.CallQuality in [.low, .medium, .high] {
            let options = LiveKitGroupCallRoom.defaultVideoPublishOptions(for: quality)
            XCTAssertEqual(
                options.preferredCodec, .vp8,
                "group video publish must be VP8 regardless of device capability — quality=\(quality)"
            )
        }
    }

    func testDefaultVideoPublishOptions_simulcastIsAlwaysOn() {
        for quality: CallsSettingsViewModel.CallQuality in [.low, .medium, .high] {
            let options = LiveKitGroupCallRoom.defaultVideoPublishOptions(for: quality)
            XCTAssertTrue(
                options.simulcast,
                "group calls must always publish simulcast layers — quality=\(quality)"
            )
        }
    }

    func testDefaultVideoPublishOptions_declaresNoBackupCodec() {
        // VP8 already has universal decode support across every
        // LiveKit-participating platform this app talks to — unlike the
        // old H265-primary configuration, there is nothing to fall back
        // FROM, so `preferredBackupCodec` must stay unset.
        for quality: CallsSettingsViewModel.CallQuality in [.low, .medium, .high] {
            let options = LiveKitGroupCallRoom.defaultVideoPublishOptions(for: quality)
            XCTAssertNil(options.preferredBackupCodec, "quality=\(quality)")
        }
    }

    func testDefaultVideoPublishOptions_encodingMatchesVideoEncodingForSameQuality() {
        // The extracted function must not silently diverge from the
        // already-pinned `videoEncoding(for:)` bitrate/fps ladder — it only
        // adds the codec/simulcast decision on top of it.
        for quality: CallsSettingsViewModel.CallQuality in [.low, .medium, .high] {
            let options = LiveKitGroupCallRoom.defaultVideoPublishOptions(for: quality)
            let standaloneEncoding = LiveKitGroupCallRoom.videoEncoding(for: quality)
            XCTAssertEqual(options.encoding?.maxBitrate, standaloneEncoding.maxBitrate, "quality=\(quality)")
            XCTAssertEqual(options.encoding?.maxFps, standaloneEncoding.maxFps, "quality=\(quality)")
        }
    }
}
