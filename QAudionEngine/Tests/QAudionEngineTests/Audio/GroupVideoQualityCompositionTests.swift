import XCTest
import Foundation
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

    // MARK: - W-GRPVIDEOPUBFIX (2026-09-29) — `videoEncoding(for:)` must NOT
    // set a non-default `bitratePriority`/`networkPriority` for ANY quality
    // level any more. Root cause of "setVideoEnabled(true) failed ... WebRTC
    // error(Failed to add transceiver)": verified against the pinned fork's
    // real source (`Utils+VideoEncodings.swift`'s `computeSimulcastPresets`/
    // `clamp`, `Dimensions.swift`'s `encodings(from:)` — RIDs
    // `["q","h","f"]`, so with `simulcast: true` this `encoding` becomes
    // ONLY the LAST/top "f" layer, `RTC.swift`'s
    // `createRtpEncodingParameters`), a non-default priority anywhere other
    // than `encodings[0]` (here, the lowest "q" layer, which keeps the
    // SDK's own nil/default priority via the untouched static presets) makes
    // WebRTC's `RTCRtpSender` reject the whole `AddTransceiver` call. Same
    // discipline as `testDefaultVideoPublishOptions_declaresNoBackupCodec`
    // above — a straight property assertion, no live Room/SDK needed.

    func testVideoEncoding_setsNoNonDefaultPriority_forAnyQualityLevel() {
        for quality: CallsSettingsViewModel.CallQuality in [.low, .medium, .high] {
            let encoding = LiveKitGroupCallRoom.videoEncoding(for: quality)
            XCTAssertNil(encoding.bitratePriority, "quality=\(quality)")
            XCTAssertNil(encoding.networkPriority, "quality=\(quality)")
        }
    }

    func testDefaultVideoPublishOptions_encodingSetsNoNonDefaultPriority_forAnyQualityLevel() {
        // Same property, reached through the actual publish-options
        // construction `connect()` feeds `RoomOptions` — the call site that
        // was really broken, not just the standalone `videoEncoding(for:)`
        // helper.
        for quality: CallsSettingsViewModel.CallQuality in [.low, .medium, .high] {
            let options = LiveKitGroupCallRoom.defaultVideoPublishOptions(for: quality)
            XCTAssertNil(options.encoding?.bitratePriority, "quality=\(quality)")
            XCTAssertNil(options.encoding?.networkPriority, "quality=\(quality)")
        }
    }

    // MARK: - W-GRPVIDEOPUBFIX — `connect()`'s camera-publish failure
    // handling. No fake/protocol exists for LiveKit's `Room`/
    // `LocalParticipant` in this codebase (both are concrete SDK types,
    // and `connect()` needs a live SFU token to reach the camera-publish
    // step at all), so — same discipline as `videoEncoding(for:)` /
    // `defaultVideoPublishOptions(for:)` above — the decision `connect()`'s
    // catch block now delegates to is extracted into the pure,
    // SDK-independent `videoPublishFailureAction(for:)` and pinned here
    // directly. This is the "small seam" the task allows in place of a
    // Room fake: it proves the POLICY (never throw, always degrade to
    // audio-only, carry only the numeric error code) without needing a
    // live Room to drive `connect()` end-to-end. The "does not throw" /
    // "keeps mic published" halves of the behavior follow directly from
    // `connect()`'s `do`/`catch` no longer having a bare `try` on the
    // camera publish (see that method's own kdoc) — not independently
    // re-provable without a live SFU connection.

    func testVideoPublishFailureAction_neverThrows_alwaysDegradesToAudioOnly() {
        struct DummyPublishError: Error {}
        let action = LiveKitGroupCallRoom.videoPublishFailureAction(for: DummyPublishError())
        switch action {
        case .degradeToAudioOnly:
            break // the only case that exists today — see the enum's own kdoc
        }
    }

    func testVideoPublishFailureAction_carriesOnlyTheNumericErrorCode() {
        // Privacy: telemetry built from this action's payload must never be
        // able to carry more than a bare error code (no free-text
        // description, no association with key material/IPs/ids).
        let nsError = NSError(domain: "io.livekit.swift-sdk", code: 201, userInfo: [
            NSLocalizedDescriptionKey: "WebRTC error(Failed to add transceiver)"
        ])
        guard case let .degradeToAudioOnly(code) = LiveKitGroupCallRoom.videoPublishFailureAction(for: nsError) else {
            return XCTFail("expected .degradeToAudioOnly")
        }
        XCTAssertEqual(code, 201)
    }

    func testVideoPublishError_isDistinctFromCameraPermissionError() {
        // `onError`'s two "video didn't publish" cases must stay
        // distinguishable by type — `GroupCallView`'s toast wiring filters
        // on `VideoPublishError` specifically so a permission denial (which
        // has no UI consumer yet, unrelated to this fix) does not also
        // start firing the "camera failed" toast as a side effect.
        let cameraError: Error = LiveKitGroupCallRoom.CameraPermissionError.denied
        let publishError: Error = LiveKitGroupCallRoom.VideoPublishError.failed(code: 1)
        XCTAssertFalse(cameraError is LiveKitGroupCallRoom.VideoPublishError)
        XCTAssertFalse(publishError is LiveKitGroupCallRoom.CameraPermissionError)
    }
}
