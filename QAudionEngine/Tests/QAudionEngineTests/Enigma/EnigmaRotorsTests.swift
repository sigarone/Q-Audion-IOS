import XCTest
@testable import QAudionEngine

/// The historical stepping of the three decorative drums (Enigma I, rotors I-II-III): a pure function of the advance index,
/// nothing else. Notches: rotor III V->W (right), rotor II E->F (middle, with the double step), rotor I Q->R (left, drives nothing).
final class EnigmaRotorsTests: XCTestCase {

    private func l(_ p: Int) -> Int { EnigmaRotors.left(p) }
    private func m(_ p: Int) -> Int { EnigmaRotors.middle(p) }
    private func r(_ p: Int) -> Int { EnigmaRotors.right(p) }
    private func at(_ start: Int, _ k: Int) -> Int { EnigmaRotors.stepFrom(start, k) }
    private let aaa = EnigmaRotors.pack(left: 0, middle: 0, right: 0)

    /// Independent, literal model of the Enigma I mechanism: one key press per iteration.
    private func reference(_ start: Int, _ k: Int) -> Int {
        var left = start / 676
        var mid = (start / 26) % 26
        var right = start % 26
        for _ in 0..<k {
            let leftStep = (mid == 4)               // rotor II notch E: it pushes the left drum along (double step)
            let midStep = (right == 21 || mid == 4) // rotor III notch V carries; E on the middle drum double-steps
            right = (right + 1) % 26
            if midStep { mid = (mid + 1) % 26 }
            if leftStep { left = (left + 1) % 26 }
        }
        return EnigmaRotors.pack(left: left, middle: mid, right: right)
    }

    func test_packingRoundTripsAndTheNotchesAreTheHistoricalOnes() {
        for a in 0..<26 {
            for b in 0..<26 {
                for c in 0..<26 {
                    let p = EnigmaRotors.pack(left: a, middle: b, right: c)
                    XCTAssertEqual(l(p), a)
                    XCTAssertEqual(m(p), b)
                    XCTAssertEqual(r(p), c)
                }
            }
        }
        XCTAssertEqual(EnigmaRotors.notchRight, 21)  // V: rotor III, V -> W
        XCTAssertEqual(EnigmaRotors.notchMiddle, 4)  // E: rotor II, E -> F
        XCTAssertEqual(EnigmaRotors.notchLeft, 16)   // Q: rotor I, Q -> R (moves nothing)
        XCTAssertEqual(EnigmaRotors.period, 26 * 25 * 26)
    }

    func test_stepIsDeterministicAndStartsAtTheFixedOffset() {
        let first = (0...600).map { EnigmaRotors.step($0) }
        let second = (0...600).map { EnigmaRotors.step($0) }
        XCTAssertEqual(first, second)
        XCTAssertEqual(EnigmaRotors.step(0), EnigmaRotors.start)
        XCTAssertEqual(EnigmaRotors.step(-5), EnigmaRotors.start, "never negative: clamped to the start")
    }

    func test_positionsNeverLeaveZeroToTwentyFive() {
        for k in 0...40_000 {
            let p = EnigmaRotors.step(k)
            XCTAssertTrue((0...25).contains(l(p)) && (0...25).contains(m(p)) && (0...25).contains(r(p)), "k=\(k)")
        }
    }

    func test_theRightDrumAdvancesByOneAtEveryResolvedCharacter() {
        for k in 0...300 {
            XCTAssertEqual((r(EnigmaRotors.start) + k) % 26, r(EnigmaRotors.step(k)))
        }
    }

    func test_aCarryMovesTheMiddleDrumOnlyWhenTheRightOneLeavesV() {
        // From AAA: after 21 presses the right drum shows V; the 22nd press takes it to W and carries.
        XCTAssertEqual(r(at(aaa, 21)), 21)
        XCTAssertEqual(m(at(aaa, 21)), 0)
        XCTAssertEqual(r(at(aaa, 22)), 22)
        XCTAssertEqual(m(at(aaa, 22)), 1)
        XCTAssertEqual(l(at(aaa, 22)), 0)
    }

    func test_the26PressesOfTheRightDrumAdvanceTheMiddleExactlyOnceAwayFromItsNotch() {
        for mid in 0..<26 where mid != 3 && mid != 4 {  // D and E take part in the double step, covered below
            for right in 0..<26 {
                let start = EnigmaRotors.pack(left: 5, middle: mid, right: right)
                let end = at(start, 26)
                XCTAssertEqual(m(end), (mid + 1) % 26, "m=\(mid) r=\(right)")
                XCTAssertEqual(l(end), 5)
                XCTAssertEqual(r(end), right)
            }
        }
    }

    func test_theDoubleStepMovesTheMiddleAndTheLeftDrumTogether() {
        // Middle on D, right on U: V (no carry yet), then W with the carry (middle -> E), then the press after that
        // moves the middle again (E -> F) AND the left drum, while the right drum keeps stepping.
        let start = EnigmaRotors.pack(left: 15, middle: 3, right: 20)
        XCTAssertEqual(reference(start, 1), EnigmaRotors.pack(left: 15, middle: 3, right: 21))
        XCTAssertEqual(reference(start, 2), EnigmaRotors.pack(left: 15, middle: 4, right: 22))
        XCTAssertEqual(reference(start, 3), EnigmaRotors.pack(left: 16, middle: 5, right: 23))
        XCTAssertEqual(at(start, 1), EnigmaRotors.pack(left: 15, middle: 3, right: 21))
        XCTAssertEqual(at(start, 2), EnigmaRotors.pack(left: 15, middle: 4, right: 22))
        XCTAssertEqual(at(start, 3), EnigmaRotors.pack(left: 16, middle: 5, right: 23))
        XCTAssertEqual(at(start, 4), EnigmaRotors.pack(left: 16, middle: 5, right: 24))
    }

    func test_theLeftDrumMovesOnlyOnAPressMadeWithTheMiddleDrumOnE() {
        var prev = EnigmaRotors.step(0)
        for k in 1...5_000 {
            let cur = EnigmaRotors.step(k)
            let leftMoved = l(cur) != l(prev)
            XCTAssertEqual(m(prev) == EnigmaRotors.notchMiddle, leftMoved, "k=\(k)")
            prev = cur
        }
    }

    func test_stepAgreesWithTheLiteralMechanismFromAnyStartAndAnyIndex() {
        var generator = SystemRandomNumberGenerator()
        var starts: [Int] = [
            aaa, EnigmaRotors.start,
            EnigmaRotors.pack(left: 16, middle: 4, right: 21),
            EnigmaRotors.pack(left: 25, middle: 25, right: 25),
        ]
        for _ in 0..<40 {
            starts.append(EnigmaRotors.pack(
                left: Int.random(in: 0..<26, using: &generator),
                middle: Int.random(in: 0..<26, using: &generator),
                right: Int.random(in: 0..<26, using: &generator)))
        }
        let ks: [Int] = Array(0...80) + [500, 16_899, 16_900, 16_901, 33_799, 33_800, 33_801, 50_000]
        for s in starts {
            for k in ks {
                XCTAssertEqual(at(s, k), reference(s, k), "start=\(s) k=\(k)")
            }
        }
    }

    func test_theWholeMechanismRepeatsAfter16900PressesAndNotBefore() {
        var seen = Set<Int>()
        for k in 0..<EnigmaRotors.period {
            XCTAssertTrue(seen.insert(EnigmaRotors.step(k)).inserted, "repeat at \(k)")
        }
        XCTAssertEqual(EnigmaRotors.step(0), EnigmaRotors.step(EnigmaRotors.period))
        XCTAssertEqual(EnigmaRotors.step(777), EnigmaRotors.step(777 + 3 * EnigmaRotors.period))
    }

    func test_snapIsAClickThatStartsAtRestEndsAtRestAndReboundsSlightly() {
        XCTAssertEqual(EnigmaRotors.snap(0), 0, accuracy: 1e-9)
        XCTAssertEqual(EnigmaRotors.snap(1), 1, accuracy: 1e-9)
        var peak = 0.0
        var f = 0.0
        while f <= 1.0 {
            peak = max(peak, EnigmaRotors.snap(f))
            f += 0.01
        }
        XCTAssertTrue(peak > 1.01 && peak < 1.2, "rebound \(peak)")
        XCTAssertEqual(EnigmaRotors.snap(-3), 0, accuracy: 1e-9)
        XCTAssertEqual(EnigmaRotors.snap(7), 1, accuracy: 1e-9)
        XCTAssertEqual(EnigmaRotors.snap(Double.nan), 0, accuracy: 1e-9)
    }

    func test_visualPositionEqualsTheRealPositionOnWholeIndexesAndIsContinuousInBetween() {
        func near(_ a: Double, _ b: Int) -> Bool {
            let d = (a - Double(b) + 13.0 + 26.0).truncatingRemainder(dividingBy: 26.0) - 13.0
            return abs(d) < 0.01
        }
        for k in 0...120 {
            let p = EnigmaRotors.step(k)
            let v = EnigmaRotors.visual(Double(k))
            XCTAssertEqual(v.left, Double(l(p)), accuracy: 1e-6)
            XCTAssertEqual(v.middle, Double(m(p)), accuracy: 1e-6)
            XCTAssertEqual(v.right, Double(r(p)), accuracy: 1e-6)
            // just before the next whole index the drums are (nearly) at the next position
            let q = EnigmaRotors.step(k + 1)
            let w = EnigmaRotors.visual(Double(k) + 0.9999)
            XCTAssertTrue(near(w.left, l(q)), "k=\(k) l")
            XCTAssertTrue(near(w.middle, m(q)), "k=\(k) m")
            XCTAssertTrue(near(w.right, r(q)), "k=\(k) r")
        }
    }

    func test_visualPositionsStayInsideZeroTo26IncludingTheWrapAndNaNOrNegativeInput() {
        var kf = 0.0
        while kf < 80.0 {
            let v = EnigmaRotors.visual(kf)
            for value in [v.left, v.middle, v.right] {
                XCTAssertTrue(value >= 0.0 && value < 26.0, "kf=\(kf) v=\(value)")
            }
            kf += 0.037
        }
        XCTAssertEqual(EnigmaRotors.visual(Double.nan).left, Double(l(EnigmaRotors.start)), accuracy: 1e-6)
        XCTAssertEqual(EnigmaRotors.visual(-4).right, Double(r(EnigmaRotors.start)), accuracy: 1e-6)
        XCTAssertEqual(EnigmaRotors.visual(Double.infinity).right >= 0.0, true)
    }

    func test_theDrumsDependOnTheIndexAloneNotOnTheTextTheCipherOrTheSeed() {
        // two different scenes of the same shape: same lengths, different text, different seeds
        guard let a = EnigmaScene.build(direction: .send, from: "ciao mondo", to: "AAAAAAAAAAAAAAAAAAAAAAAA", result: .ok(packetBytes: 18)),
              let b = EnigmaScene.build(direction: .send, from: "zzzzzzzzzz", to: "q+q+q+q+q+q+q+q+q+q+q+q+", result: .ok(packetBytes: 18))
        else {
            XCTFail("scenes")
            return
        }
        var ia = EnigmaFrameInfo()
        var ib = EnigmaFrameInfo()
        var sa = ""
        var sb = ""
        var last = -1.0
        var t: Int64 = 0
        while t <= a.totalMs {
            a.render(elapsedMs: t, full: true, seed: 1, frameIndex: 3, out: &sa, info: &ia)
            b.render(elapsedMs: t, full: true, seed: 999, frameIndex: 77, out: &sb, info: &ib)
            XCTAssertEqual(ia.rotorIndex, ib.rotorIndex, accuracy: 0, "t=\(t)")
            XCTAssertGreaterThanOrEqual(ia.rotorIndex, last, "never goes back at t=\(t)")
            last = ia.rotorIndex
            t += 17
        }
        // the drums have turned for both morphs of a send: 24 cipher units, then 10 plain units
        a.render(elapsedMs: a.totalMs, full: true, seed: 1, frameIndex: 3, out: &sa, info: &ia)
        XCTAssertEqual(ia.rotorIndex, 34.0, accuracy: 1e-3)
    }

    func test_holdsDoNotTurnTheDrumsAndAReceiveCountsOnlyThePlainCharacters() {
        guard let s = EnigmaScene.build(direction: .receive, from: "AAAAAAAAAAAAAAAAAAAAAAAA", to: "ciao", result: .ok(packetBytes: 18)) else {
            XCTFail("scene")
            return
        }
        var info = EnigmaFrameInfo()
        var out = ""
        s.render(elapsedMs: 0, full: true, seed: 1, frameIndex: 0, out: &out, info: &info)
        XCTAssertEqual(info.rotorIndex, 0, accuracy: 0)
        s.render(elapsedMs: EnigmaScene.holdReceiveMs - 1, full: true, seed: 1, frameIndex: 0, out: &out, info: &info)
        XCTAssertEqual(info.rotorIndex, 0, accuracy: 0)
        s.render(elapsedMs: s.totalMs, full: true, seed: 1, frameIndex: 0, out: &out, info: &info)
        XCTAssertEqual(info.rotorIndex, 4.0, accuracy: 1e-3)
    }

    func test_theCostOfOneDrumPositionIsSmall() {
        measure {
            var kf = 0.0
            for _ in 0..<5_000 {
                _ = EnigmaRotors.visual(kf)
                kf += 0.5
            }
        }
    }
}
