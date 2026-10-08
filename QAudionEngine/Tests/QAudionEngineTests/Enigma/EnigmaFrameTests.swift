import XCTest
@testable import QAudionEngine

/// The frame function: pure, deterministic, and always ends on exactly the expected text. Also the splitting into units
/// (Swift Characters): emoji, flags, combining marks, right-to-left text and CR LF are never cut.
final class EnigmaFrameTests: XCTestCase {

    private let samples: [String] = [
        "",
        "a",
        "ciao mondo",
        String(repeating: "x", count: 5000),
        "ciao 👋🏽 mondo 🇮🇹 👨‍👩‍👧‍👦 fine",
        "مرحبا بالعالم",
        "שלום עולם",
        "e\u{0301}a\u{0308}o\u{0323}\u{0302}",
        "riga1\r\nriga2\nriga3",
        "\u{05D0}\u{05B0}\u{05D1} abc \u{0627}\u{064E}",
        String(repeating: "👨‍👩‍👧‍👦", count: 300),
    ]

    private func scalars(_ s: String) -> [UInt32] {
        s.unicodeScalars.map { $0.value }
    }

    private func finalFrame(from: String, to: String, full: Bool, seed: UInt64) -> String {
        let f = EnigmaUnits(text: from)
        let t = EnigmaUnits(text: to)
        return EnigmaFrame.frame(from: f, to: t, p: 1.0, full: full, seed: seed, frameIndex: 7, suffix: t.rest)
    }

    // MARK: - the final text is always the expected one

    func test_theFinalFrameIsExactlyTheTargetForEveryInputLevelAndSeed() {
        let cipher = String(repeating: "Qk9PQkFSQkFa", count: 40)
        let seeds: [UInt64] = [0, 1, 0xDEADBEEF, UInt64.max]
        for plain in samples {
            for full in [false, true] {
                for seed in seeds {
                    // receive: cipher -> plain
                    XCTAssertEqual(scalars(finalFrame(from: cipher, to: plain, full: full, seed: seed)), scalars(plain))
                    // send, way back: cipher -> plain as well; send, way out: plain -> cipher
                    XCTAssertEqual(scalars(finalFrame(from: plain, to: cipher, full: full, seed: seed)), scalars(cipher))
                }
            }
        }
    }

    func test_outOfRangeAndNaNProgressNeverTrapsAndClampsToTheEnds() {
        let f = EnigmaUnits(text: "abcdef")
        let t = EnigmaUnits(text: "UVWXYZ")
        let atZero = EnigmaFrame.frame(from: f, to: t, p: 0.0, full: false, seed: 5, frameIndex: 0, suffix: "")
        XCTAssertEqual(EnigmaFrame.frame(from: f, to: t, p: Double.nan, full: false, seed: 5, frameIndex: 0, suffix: ""), atZero)
        XCTAssertEqual(EnigmaFrame.frame(from: f, to: t, p: -3.0, full: false, seed: 5, frameIndex: 0, suffix: ""), atZero)
        XCTAssertEqual(EnigmaFrame.frame(from: f, to: t, p: 9.0, full: true, seed: 5, frameIndex: 0, suffix: ""), "UVWXYZ")
        XCTAssertEqual(EnigmaFrame.frame(from: f, to: t, p: Double.infinity, full: true, seed: 5, frameIndex: 0, suffix: ""), "UVWXYZ")
    }

    // MARK: - determinism

    func test_sameInputsGiveTheSameFrameAndADifferentSeedGivesADifferentOne() {
        let f = EnigmaUnits(text: String(repeating: "a", count: 120))
        let t = EnigmaUnits(text: String(repeating: "b", count: 120))
        let a = EnigmaFrame.frame(from: f, to: t, p: 0.5, full: true, seed: 1, frameIndex: 3, suffix: "")
        let b = EnigmaFrame.frame(from: f, to: t, p: 0.5, full: true, seed: 1, frameIndex: 3, suffix: "")
        let c = EnigmaFrame.frame(from: f, to: t, p: 0.5, full: true, seed: 2, frameIndex: 3, suffix: "")
        let d = EnigmaFrame.frame(from: f, to: t, p: 0.5, full: true, seed: 1, frameIndex: 4, suffix: "")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
    }

    func test_decorativeCharactersComeOnlyFromTheFixedAsciiAlphabet() {
        let empty = EnigmaUnits(text: "")
        let t = EnigmaUnits(text: String(repeating: "Z", count: 80))
        let frame = EnigmaFrame.frame(from: empty, to: t, p: 0.0, full: true, seed: 99, frameIndex: 1, suffix: "")
        XCTAssertEqual(frame.count, 80)
        for ch in frame {
            XCTAssertTrue(EnigmaFrame.charset.contains(ch), "unexpected \(ch)")
        }
    }

    func test_liteNeverScramblesAndKeepsTheOldTextInFront() {
        let f = EnigmaUnits(text: String(repeating: "a", count: 100))
        let t = EnigmaUnits(text: String(repeating: "b", count: 100))
        let frame = EnigmaFrame.frame(from: f, to: t, p: 0.0, full: false, seed: 3, frameIndex: 0, suffix: "")
        XCTAssertEqual(frame, String(repeating: "a", count: 100))
    }

    func test_theRevealedPrefixOnlyGrowsWithProgress() {
        let f = EnigmaUnits(text: String(repeating: "a", count: 90))
        let t = EnigmaUnits(text: String(repeating: "b", count: 90))
        var out = ""
        var last = -1
        var p = 0.0
        while p <= 1.0 {
            let reveal = EnigmaFrame.render(into: &out, from: f, to: t, p: p, full: true, seed: 4, frameIndex: 0, suffix: "")
            XCTAssertGreaterThanOrEqual(reveal, last, "p=\(p)")
            last = reveal
            p += 0.01
        }
        let atEnd = EnigmaFrame.render(into: &out, from: f, to: t, p: 1.0, full: true, seed: 4, frameIndex: 0, suffix: "")
        XCTAssertEqual(atEnd, 90)
    }

    func test_tailOfALongerOldTextShrinksToNothing() {
        let f = EnigmaUnits(text: String(repeating: "a", count: 100))
        let t = EnigmaUnits(text: String(repeating: "b", count: 10))
        let start = EnigmaFrame.frame(from: f, to: t, p: 0.0, full: false, seed: 1, frameIndex: 0, suffix: "")
        let end = EnigmaFrame.frame(from: f, to: t, p: 1.0, full: false, seed: 1, frameIndex: 0, suffix: "")
        XCTAssertEqual(start.count, 100)
        XCTAssertEqual(end, String(repeating: "b", count: 10))
    }

    // MARK: - units

    func test_aCompositeCharacterIsOneUnit() {
        let one: [String] = ["👨‍👩‍👧‍👦", "🇮🇹", "e\u{0301}", "\r\n", "👋🏽", "ا\u{064E}", "\u{05D0}\u{05B0}"]
        for text in one {
            let units = EnigmaUnits(text: text)
            XCTAssertEqual(units.count, 1, text)
            XCTAssertEqual(scalars(units.head), scalars(text))
            XCTAssertEqual(units.rest, "")
        }
    }

    func test_onlyTheFirst240UnitsAreAnimatedAndTheRestIsKeptUnchanged() {
        let text = String(repeating: "a", count: 300) + "👨‍👩‍👧‍👦"
        let units = EnigmaUnits(text: text)
        XCTAssertEqual(units.count, 240)
        XCTAssertEqual(units.rest.count, 61)
        XCTAssertEqual(scalars(units.head + units.rest), scalars(text))
        // the cut never lands inside a cluster: put an emoji exactly across the limit
        let across = String(repeating: "a", count: 239) + "👨‍👩‍👧‍👦" + "tail"
        let split = EnigmaUnits(text: across)
        XCTAssertEqual(split.count, 240)
        XCTAssertEqual(split.rest, "tail")
        XCTAssertEqual(scalars(split.head + split.rest), scalars(across))
    }

    func test_emptyTextHasNoUnits() {
        let units = EnigmaUnits(text: "")
        XCTAssertEqual(units.count, 0)
        XCTAssertEqual(units.rest, "")
        var out = "keep?"
        units.append(to: &out, index: 0)
        units.append(to: &out, index: -1)
        XCTAssertEqual(out, "keep?", "an index outside the head appends nothing")
    }

    // MARK: - cost

    func test_aFrameOfAFullLengthMessageIsCheap() {
        let f = EnigmaUnits(text: String(repeating: "a", count: 240))
        let t = EnigmaUnits(text: String(repeating: "b", count: 240))
        var out = ""
        measure {
            var p = 0.0
            while p < 1.0 {
                EnigmaFrame.render(into: &out, from: f, to: t, p: p, full: true, seed: 1, frameIndex: 1, suffix: "")
                p += 0.001
            }
        }
    }
}
