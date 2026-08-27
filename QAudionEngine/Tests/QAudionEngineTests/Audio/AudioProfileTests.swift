import XCTest
@testable import QAudionEngine

/// W-LONGAUDIO (2026-08-10) — the profile arithmetic, pinned.
///
/// Every number below is computed independently in Kotlin, Swift and TypeScript
/// from the same formulas. If the three ever disagree, two endpoints disagree
/// about what fits in a block on a live call, and the symptom is silence rather
/// than an error. So the expected values are written as LITERALS here, not as
/// re-derivations of the code under test — a test that recomputes the
/// implementation cannot catch the implementation being wrong.
final class AudioProfileTests: XCTestCase {

    // MARK: - The two profiles

    func test_standardProfile_isTodaysWire() {
        let p = AudioProfile.standard
        XCTAssertEqual(p.frameDurationMs, 20)
        XCTAssertEqual(p.blockBytes, 120)
        XCTAssertEqual(p.samplesPerFrame, 960)
        XCTAssertEqual(p.bytesPerFrame, 1920)
        // W-OPUSHEADROOM (2026-08-27): opusBitrate raised 32000->40000 for this
        // profile (real headroom under the 41,600 ceiling below, zero
        // wire-size change - see AudioConstants.opusBitrate's own kdoc). 100
        // bytes at 40 kbps / 20 ms, was 80 at 32 kbps.
        XCTAssertEqual(p.opusBytes(), 100)
        XCTAssertEqual(p.maxBitrateBps, 41600)
    }

    func test_longProfile_isSixtyMsInA256ByteBlock() {
        let p = AudioProfile.long60x256
        XCTAssertEqual(p.frameDurationMs, 60)
        XCTAssertEqual(p.blockBytes, 256)
        XCTAssertEqual(p.samplesPerFrame, 2880)
        XCTAssertEqual(p.bytesPerFrame, 5760)
        // W-OPUSHEADROOM (2026-08-27): this profile has ZERO headroom (its own
        // maxBitrateBps below is already 32,000) and stays clamped there in
        // real usage — unlike the standard profile above, opusBytes() must be
        // called with the CLAMPED rate explicitly, not the raised global
        // default (which would compute an over-block 300 bytes and was
        // exactly the overflow-to-silence hazard this file exists to catch).
        XCTAssertEqual(p.opusBytes(bitrateBps: 32000), 240)
        XCTAssertEqual(p.maxBitrateBps, 32000)
    }

    /// The block is exactly `2 + opus + filler`, and the filler is what is left.
    /// 18 spare bytes at 120/20 (40 kbps, W-OPUSHEADROOM); 14 at 256/60 (still
    /// 32 kbps, zero headroom) — and those 14 are `blockSafetyBytes`, i.e. NOT
    /// budget.
    func test_blockAccounting_addsUp() {
        XCTAssertEqual(AudioConstants.lengthHeaderBytes + AudioProfile.standard.opusBytes() + 18,
                       AudioProfile.standard.blockBytes)
        XCTAssertEqual(AudioConstants.lengthHeaderBytes + AudioProfile.long60x256.opusBytes(bitrateBps: 32000) + 14,
                       AudioProfile.long60x256.blockBytes)
        XCTAssertEqual(AudioConstants.blockSafetyBytes, 14)
    }

    /// THE hazard, stated as a test: the long profile's ceiling is LOWER than
    /// the standard one's, and it has zero headroom.
    ///
    /// This is the direction everyone gets wrong — a bigger block reads like
    /// more room, and it is not, because the frame grew three times over while
    /// the block only doubled.
    func test_longProfileCeiling_isLowerThanStandardAndHasNoHeadroom() {
        XCTAssertLessThan(AudioProfile.long60x256.maxBitrateBps,
                          AudioProfile.standard.maxBitrateBps)
        // Zero headroom: the frame at the ceiling exactly fills the budget.
        let budget = AudioProfile.long60x256.blockBytes - AudioConstants.lengthHeaderBytes
            - AudioConstants.blockSafetyBytes
        XCTAssertEqual(AudioProfile.long60x256.opusBytes(bitrateBps: 32000), budget)
        XCTAssertEqual(budget, 240)
    }

    // MARK: - The clamp (contract §2.4, the R2 blocker)

    /// Every settings-slider value, against the long profile. None may produce a
    /// frame that overflows the block.
    ///
    /// The failure this prevents is not an error: an overflowing frame is
    /// replaced by a constant-size SILENT frame, so the call connects, holds a
    /// perfect 16.67 fps, and transmits nothing at all.
    func test_everySliderValue_clampsBelowTheLongProfileBudget() {
        let budget = 240
        for kbps in 8...44 {
            let clamped = AudioProfile.long60x256.clamp(kbps: kbps)
            XCTAssertLessThanOrEqual(clamped, 32, "\(kbps) kbps clamped to \(clamped)")
            let bytes = AudioConstants.opusCbrBytes(bitrateBps: clamped * 1000, frameDurationMs: 60)
            XCTAssertLessThanOrEqual(bytes, budget,
                                     "\(kbps) kbps → \(clamped) kbps → \(bytes) B against a \(budget) B budget")
        }
    }

    /// The two overflow cases from the contract, reproduced exactly. Both are
    /// values a user can actually select today.
    func test_theUnclampedOverflows_areRealNumbers() {
        // 40 kbps passes the STANDARD clamp untouched (ceiling 41)...
        XCTAssertEqual(AudioProfile.standard.clamp(kbps: 40), 40)
        // ...and then encodes 300 bytes into a 240-byte budget.
        XCTAssertEqual(AudioConstants.opusCbrBytes(bitrateBps: 40000, frameDurationMs: 60), 300)
        // 44 kbps clamps to 41 on standard...
        XCTAssertEqual(AudioProfile.standard.clamp(kbps: 44), 41)
        // ...which is 308 bytes at 60 ms.
        XCTAssertEqual(AudioConstants.opusCbrBytes(bitrateBps: 41000, frameDurationMs: 60), 308)
        // The correct clamp gives an exact fit and no overflow.
        XCTAssertEqual(AudioProfile.long60x256.clamp(kbps: 40), 32)
        XCTAssertEqual(AudioConstants.opusCbrBytes(bitrateBps: 32000, frameDurationMs: 60), 240)
    }

    /// The standard clamp is unchanged by any of this.
    func test_standardClamp_isUnchanged() {
        XCTAssertEqual(AudioProfile.standard.clamp(kbps: 32), 32)
        XCTAssertEqual(AudioProfile.standard.clamp(kbps: 41), 41)
        XCTAssertEqual(AudioProfile.standard.clamp(kbps: 100), 41)
        XCTAssertEqual(AudioProfile.standard.clamp(kbps: 0), 1)
        // ...and matches the free function's defaults, which must stay STANDARD.
        XCTAssertEqual(AudioConstants.clampToBlock(40), 40)
        XCTAssertEqual(AudioConstants.clampToBlock(44), 41)
    }

    // MARK: - Packet arithmetic (the whole point of the feature)

    /// Sealed frame sizes and the resulting byte rates. The saving is entirely
    /// in the packet RATE — the codec and the audio quality are identical.
    func test_sealedFrameSizes_andTheSaving() {
        let fixedOverhead = 16 + 23 + 28  // GCM tag + envelope + outer PQC seal
        XCTAssertEqual(fixedOverhead, 67)
        XCTAssertEqual(AudioProfile.standard.blockBytes + fixedOverhead, 187)
        XCTAssertEqual(AudioProfile.long60x256.blockBytes + fixedOverhead, 323)

        // 50 fps vs 16.667 fps.
        let stdRate = Double(187) * 50.0
        let longRate = Double(323) * (1000.0 / 60.0)
        XCTAssertEqual(stdRate, 9350, accuracy: 0.5)
        XCTAssertEqual(longRate, 5383, accuracy: 1.0)
        XCTAssertEqual((1 - longRate / stdRate) * 100, 42.4, accuracy: 0.2)
    }

    // MARK: - framesForMs

    /// At 20 ms every constant in the codebase is an exact multiple, so
    /// rounding is provably a no-op and today's numbers are untouched.
    func test_framesForMs_isANoOpAt20ms() {
        XCTAssertEqual(AudioConstants.framesForMs(80, frameDurationMs: 20), 4)
        XCTAssertEqual(AudioConstants.framesForMs(140, frameDurationMs: 20), 7)
        XCTAssertEqual(AudioConstants.framesForMs(160, frameDurationMs: 20), 8)
        XCTAssertEqual(AudioConstants.framesForMs(300, frameDurationMs: 20), 15)
        XCTAssertEqual(AudioConstants.framesForMs(600, frameDurationMs: 20), 30)
        XCTAssertEqual(AudioConstants.framesForMs(40, frameDurationMs: 20), 2)
        XCTAssertEqual(AudioConstants.framesForMs(60, frameDurationMs: 20), 3)
    }

    /// THE reason it rounds instead of truncating: 140 and 160 are two distinct
    /// watermarks, and truncation collapses both to 2 frames at 60 ms — a tier
    /// boundary that silently stops existing.
    func test_framesForMs_roundsSoAdjacentWatermarksStayDistinct() {
        XCTAssertEqual(AudioConstants.framesForMs(140, frameDurationMs: 60), 2)
        XCTAssertEqual(AudioConstants.framesForMs(160, frameDurationMs: 60), 3)
        XCTAssertNotEqual(AudioConstants.framesForMs(140, frameDurationMs: 60),
                          AudioConstants.framesForMs(160, frameDurationMs: 60))
        // Truncation is what it is NOT doing:
        XCTAssertEqual(140 / 60, 2)
        XCTAssertEqual(160 / 60, 2)
    }

    /// Never zero. A watermark of 0 frames is a tier that fires on an empty
    /// queue.
    func test_framesForMs_neverReturnsZero() {
        XCTAssertEqual(AudioConstants.framesForMs(10, frameDurationMs: 60), 1)
        XCTAssertEqual(AudioConstants.framesForMs(0, frameDurationMs: 60), 1)
        XCTAssertEqual(AudioConstants.framesForMs(40, frameDurationMs: 60), 1)
    }

    /// The derived frame counts still equal the numbers that shipped.
    func test_derivedJitterDepths_matchTheShippedFrameCounts() {
        XCTAssertEqual(AudioConstants.jitterBufferFramesP2P, 3)
        XCTAssertEqual(AudioConstants.jitterBufferFramesWsRelay, 8)
        XCTAssertEqual(AudioConstants.jitterBufferFramesSignalRelay, 150)
        XCTAssertEqual(AudioConstants.playbackRingBufferFrames, 10)
    }

    /// The tuning constants this (W-LONGAUDIO) change must NOT redefine.
    /// `opusBitrate` is deliberately NOT asserted here any more — it moved
    /// 32000 -> 40000 under W-OPUSHEADROOM (2026-08-27), a later, unrelated
    /// change; see `AudioConstantsTests.testOpusBitrate` for its current
    /// value and the tests below for why raising it is safe.
    func test_defaultConstants_keepTheirValues() {
        XCTAssertEqual(AudioConstants.frameDurationMs, 20)
        XCTAssertEqual(AudioConstants.samplesPerFrame, 960)
        XCTAssertEqual(AudioConstants.bytesPerFrame, 1920)
        XCTAssertEqual(AudioConstants.blockBytesStandard, 120)
        XCTAssertEqual(AudioConstants.blockBytesLong, 256)
        XCTAssertEqual(AudioConstants.maxFrameDurationMs, 60)
        XCTAssertEqual(AudioConstants.maxSamplesPerFrame, 2880)
        XCTAssertEqual(AudioConstants.maxBytesPerFrame, 5760)
    }

    // MARK: - W-OPUSHEADROOM (2026-08-27): the shared 40 kbps preferred base

    /// The base preferred bitrate must never itself exceed the LOOSEST
    /// ceiling any profile offers — the standard profile's, since the long
    /// profile's is tighter and is covered by its own clamp regardless.
    /// This is the ceiling computation from first principles, independent of
    /// the `AudioProfile.standard.maxBitrateBps` convenience property, so a
    /// bug in one cannot hide behind the other.
    func test_opusBitrate_neverExceedsTheStandardProfileCeiling() {
        let ceiling = AudioConstants.maxBitrateForBlock(blockBytes: 120, frameDurationMs: 20)
        XCTAssertEqual(ceiling, 41600)
        XCTAssertLessThanOrEqual(AudioConstants.opusBitrate, ceiling)
    }

    /// The construction path every real call uses (`OpusCodec.Config(profile:)`,
    /// via `QAudionEngine.initialize()`/`latchAudioProfile()`) takes the new
    /// 40 kbps base and clamps it to EXACTLY 32 kbps for a call latched to the
    /// fleet-default long profile — zero headroom, unchanged from before this
    /// constant moved. This is the single fact that makes raising the base
    /// safe: the clamp already existed and already used the ACTIVE profile.
    func test_defaultBitrate_clampsToExactly32kbpsOnTheLongProfile() {
        let cfg = OpusCodec.Config(profile: .long60x256)
        XCTAssertEqual(cfg.bitrate, 32000)
    }

    /// The same base bitrate reaches the standard profile UNCLAMPED — the
    /// 8 kbps of headroom `blockSafetyBytes` was reserved for.
    func test_defaultBitrate_reachesTheStandardProfileUnclamped() {
        let cfg = OpusCodec.Config(profile: .standard)
        XCTAssertEqual(cfg.bitrate, AudioConstants.opusBitrate)
        XCTAssertEqual(cfg.bitrate, 40000)
    }
}
