import XCTest
@testable import QAudionEngine

/// W-CONFBADGE1SRC (2026-10-07) — the in-call "C=" badge value against Android's display path.
///
/// Reference: Android `DeepfakeMonitor` (EMA alpha 0.15 of the 3-signal combine, seeded at 1.0 per call,
/// clamped) and the CONFIDENCE colour of Android's `InCallScreen` (>= 0.72 green, >= 0.40 amber, red
/// below). The vectors are the Tier 2 `combined` values iOS logged in two real calls of 2026-10-07
/// (`guardian3sig ... combined=0.99` on every tick), and the expected EMAs are written out by hand from
/// Android's formula (closed form for a constant combine c: c + (1 - c) * 0.85^n), not recomputed with
/// the code under test.
final class GuardianDisplayConfidenceTests: XCTestCase {

    private func run(_ combines: [Float], from seed: Float = GuardianDisplayConfidence.seed) -> [Float] {
        var ema = seed
        return combines.map { c in
            ema = GuardianDisplayConfidence.next(ema: ema, combined: c)
            return ema
        }
    }

    /// The constants are Android's, not iOS-local tuning.
    func testConstantsAreAndroidDeepfakeMonitorAndInCallScreen() {
        XCTAssertEqual(GuardianDisplayConfidence.emaAlpha, 0.15)
        XCTAssertEqual(GuardianDisplayConfidence.seed, 1.0)
        XCTAssertEqual(GuardianDisplayConfidence.greenFloor, 0.72)
        XCTAssertEqual(GuardianDisplayConfidence.amberFloor, 0.40)
    }

    /// A genuine caller, as logged on 2026-10-07 (a one-minute call, eleven Tier 2 ticks, all 0.99): the
    /// badge must read ~0.99 and be green from the first tick, as it does on Android. Before the fix
    /// the iOS badge showed 0.50 amber for that whole call.
    func testLoggedGenuineCallMatchesAndroidVectorAndIsGreen() {
        let emas = run(Array(repeating: 0.99, count: 11))
        // Android: 0.15 * 0.99 + 0.85 * 1.0 = 0.9985; then 0.15 * 0.99 + 0.85 * 0.9985 = 0.997225.
        XCTAssertEqual(emas[0], 0.9985, accuracy: 1e-5)
        XCTAssertEqual(emas[1], 0.997225, accuracy: 1e-5)
        // 0.99 + 0.01 * 0.85^11 = 0.99 + 0.01 * 0.1673432 = 0.9916734.
        XCTAssertEqual(emas[10], 0.9916734, accuracy: 1e-5)
        for e in emas {
            XCTAssertEqual(GuardianDisplayConfidence.level(of: e), "green")
        }
    }

    /// The number the owner saw: Tier 1's `ConfidenceIndex` before its first inference reads exactly its
    /// 0.5 seed, which is amber on both platforms' bands. It is not a reading of the caller, which is why
    /// it must never be the badge (see `ConfidenceBadgeWiringTests`).
    func testTier1SeedIsTheAmberHalfTheBadgeUsedToShow() {
        let tier1 = ConfidenceIndex()
        XCTAssertEqual(tier1.currentScore, 0.5)
        XCTAssertEqual(GuardianDisplayConfidence.level(of: tier1.currentScore), "yellow")
        // One genuine Tier 2 tick is already green.
        XCTAssertEqual(GuardianDisplayConfidence.level(of: run([0.99])[0]), "green")
    }

    /// Band edges are Android's `>=` comparisons.
    func testBandEdges() {
        XCTAssertEqual(GuardianDisplayConfidence.level(of: 1.0), "green")
        XCTAssertEqual(GuardianDisplayConfidence.level(of: 0.72), "green")
        XCTAssertEqual(GuardianDisplayConfidence.level(of: 0.7199), "yellow")
        XCTAssertEqual(GuardianDisplayConfidence.level(of: 0.40), "yellow")
        XCTAssertEqual(GuardianDisplayConfidence.level(of: 0.3999), "red")
        XCTAssertEqual(GuardianDisplayConfidence.level(of: 0.0), "red")
    }

    /// A sustained synthetic-looking combine still reaches red, at Android's pace:
    /// 0.2 + 0.8 * 0.85^n crosses 0.72 at n = 3 (0.6913) and 0.40 at n = 9 (0.3853).
    func testSustainedLowCombineFallsThroughTheBandsAtAndroidPace() {
        let emas = run(Array(repeating: 0.2, count: 20))
        XCTAssertEqual(emas[1], 0.778, accuracy: 1e-4)     // n = 2: 0.2 + 0.8 * 0.7225
        XCTAssertEqual(GuardianDisplayConfidence.level(of: emas[1]), "green")
        XCTAssertEqual(emas[2], 0.6913, accuracy: 1e-4)    // n = 3
        XCTAssertEqual(GuardianDisplayConfidence.level(of: emas[2]), "yellow")
        XCTAssertEqual(GuardianDisplayConfidence.level(of: emas[7]), "yellow")   // n = 8: 0.4180
        XCTAssertEqual(emas[8], 0.3853, accuracy: 1e-4)    // n = 9
        XCTAssertEqual(GuardianDisplayConfidence.level(of: emas[8]), "red")
        XCTAssertEqual(emas[19], 0.2310, accuracy: 1e-4)   // n = 20
    }

    /// Clamping as Android's `coerceIn(0f, 1f)`; a non-finite combine is ignored, not treated as 0.
    func testClampAndNonFiniteInput() {
        XCTAssertEqual(GuardianDisplayConfidence.next(ema: 1, combined: 2), 1)
        XCTAssertEqual(GuardianDisplayConfidence.next(ema: 0, combined: -1), 0)
        XCTAssertEqual(GuardianDisplayConfidence.next(ema: 0.9, combined: .nan), 0.9)
        XCTAssertEqual(GuardianDisplayConfidence.next(ema: 0.9, combined: .infinity), 0.9)
        XCTAssertEqual(GuardianDisplayConfidence.next(ema: .nan, combined: 0.5), GuardianDisplayConfidence.seed)
    }
}
