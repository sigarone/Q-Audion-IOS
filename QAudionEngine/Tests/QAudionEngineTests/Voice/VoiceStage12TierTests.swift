import XCTest
import Foundation
@testable import QAudionEngine

/// Stage 12: the tier of one input and the sticky lowest tier of a call (the engine keeps the minimum over every moment at
/// which the inputs were evaluated). All 39 cases and 7 sequences, exact.
final class VoiceStage12TierTests: XCTestCase {
    static func tierInput(_ o: KatJSON) -> VoiceTierInput {
        VoiceTierInput(
            pinState: TierPinState(rawValue: o["pin_state"].string) ?? .unresolved,
            keyAgeS: o["key_age_s"].int,
            viaLegacyRow: o["via_legacy_row"].flag,
            oobVerified: o["oob_verified"].flag,
            pinAnomaly: o["pin_anomaly"].flag,
            kcmacOk: o["kcmac_ok"].flag,
            heldUnresolved: o["held_unresolved"].flag,
            authWord: TierAuthWord(rawValue: o["auth_word"].string) ?? .noWord)
    }

    func testTheKeyAgeLimitIsACodeConstant() throws {
        let s12 = try VoiceKat.json("stage12_tier/stage12.json")
        XCTAssertEqual(s12["min_key_age_s"].int, VoiceTier.minKeyAgeSeconds)
        XCTAssertEqual(VoiceTier.minKeyAgeSeconds, 86_400)
    }

    func testEveryNameOfTheVectorsIsKnown() throws {
        let s12 = try VoiceKat.json("stage12_tier/stage12.json")
        for c in s12["cases"].array {
            XCTAssertNotNil(TierPinState(rawValue: c["input"]["pin_state"].string), c["name"].string)
            XCTAssertNotNil(TierAuthWord(rawValue: c["input"]["auth_word"].string), c["name"].string)
        }
    }

    func testEveryCaseAndEverySequenceGivesTheStoredTier() throws {
        let s12 = try VoiceKat.json("stage12_tier/stage12.json")
        let cases = s12["cases"].array
        XCTAssertEqual(cases.count, 39)
        for c in cases {
            let name = c["name"].string
            let want = c["expected"]
            let t = VoiceTier.tier(Self.tierInput(c["input"]))
            XCTAssertEqual(t, want["tier"].int, "\(name): tier")
            XCTAssertEqual(t >= 1, want["learning_allowed"].bool, "\(name): learning allowed")
            XCTAssertEqual(t >= 1, want["matches_allowed"].bool, "\(name): matches allowed")
        }
        let sequences = s12["sequences"].array
        XCTAssertEqual(sequences.count, 7)
        for s in sequences {
            let name = s["name"].string
            let want = s["expected"]
            let tiers = s["inputs"].array.map { VoiceTier.tier(Self.tierInput($0)) }
            XCTAssertEqual(tiers, want["tiers"].ints, "\(name): tiers")
            let t = tiers.min() ?? 0
            XCTAssertEqual(t, want["tier"].int, "\(name): tier")
            XCTAssertEqual(t >= 1, want["learning_allowed"].bool, "\(name): learning allowed")
        }
    }
}
