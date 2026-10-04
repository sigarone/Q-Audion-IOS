import XCTest
@testable import QAudionEngine

/// MEDIA-5 (W-INNERAUDIOAAD) — the inner sealed-audio replay window as a pure value type.
///
/// The old window was a bitmask that aged its bits toward LOWER indices on every advance of the
/// highest sequence number, so only the highest one stayed protected. The advance sizes below
/// (1, 63, 64, 65, 1000) straddle the word boundaries of that bitmask: any shift in the wrong
/// direction, or off by a word, fails at least one of them.
final class InnerAudioReplayWindowTests: XCTestCase {

    private let size = InnerAudioReplayWindow.windowSize

    /// Asserts `seq` is fresh and records it, so a mis-ordered setup fails loudly here instead of
    /// as a confusing assertion further down.
    private func accept(
        _ w: inout InnerAudioReplayWindow, _ seq: UInt64,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(w.check(seq), .fresh, "seq \(seq) should be fresh before commit", file: file, line: line)
        XCTAssertEqual(w.commit(seq), .fresh, "seq \(seq) should commit", file: file, line: line)
    }

    func test_windowSizeIs1024() {
        XCTAssertEqual(InnerAudioReplayWindow.windowSize, 1024)
    }

    func test_emptyWindowAcceptsAnySeq() {
        let w = InnerAudioReplayWindow()
        XCTAssertEqual(w.check(0), .fresh)
        XCTAssertEqual(w.check(7), .fresh)
        XCTAssertEqual(w.check(UInt64(UInt32.max)), .fresh)
    }

    func test_checkIsReadOnly() {
        var w = InnerAudioReplayWindow()
        // A far-ahead seq that is only CHECKED must not become the window's highest.
        XCTAssertEqual(w.check(1_000_000), .fresh)
        XCTAssertEqual(w.check(1_000_000), .fresh)
        accept(&w, 3)
        XCTAssertEqual(w.check(2), .fresh, "the earlier check of 1_000_000 must not have moved the window")
        XCTAssertEqual(w.check(3), .duplicate)
    }

    func test_seqZeroIsNotConfusedWithAnEmptySlot() {
        var w = InnerAudioReplayWindow()
        XCTAssertEqual(w.check(0), .fresh)
        accept(&w, 0)
        XCTAssertEqual(w.check(0), .duplicate)
        // A seq whose slot is empty but whose value is 0 mod 1024 is still fresh.
        XCTAssertEqual(w.check(1), .fresh)
    }

    func test_duplicateOfTheHighestIsRejected() {
        var w = InnerAudioReplayWindow()
        accept(&w, 41)
        XCTAssertEqual(w.check(41), .duplicate)
        XCTAssertEqual(w.commit(41), .duplicate)
    }

    // MARK: - The backwards-shift detectors

    /// A frame accepted INSIDE the window must stay a duplicate after the highest advanced by `d`.
    private func assertDuplicateSurvivesAdvance(by d: UInt64, file: StaticString = #filePath, line: UInt = #line) {
        var w = InnerAudioReplayWindow()
        let base: UInt64 = 5000
        accept(&w, base)
        accept(&w, base + d)
        XCTAssertEqual(w.check(base), .duplicate,
                       "seq \(base) was accepted; after the highest advanced by \(d) it must still be a duplicate",
                       file: file, line: line)
        XCTAssertEqual(w.check(base + d), .duplicate, file: file, line: line)
        if d > 1 {
            // Something in between that was never seen is NOT a duplicate.
            XCTAssertEqual(w.check(base + 1), .fresh, file: file, line: line)
        }
    }

    func test_inWindowDuplicateAfterHighestAdvancedBy1() { assertDuplicateSurvivesAdvance(by: 1) }
    func test_inWindowDuplicateAfterHighestAdvancedBy63() { assertDuplicateSurvivesAdvance(by: 63) }
    func test_inWindowDuplicateAfterHighestAdvancedBy64() { assertDuplicateSurvivesAdvance(by: 64) }
    func test_inWindowDuplicateAfterHighestAdvancedBy65() { assertDuplicateSurvivesAdvance(by: 65) }
    func test_inWindowDuplicateAfterHighestAdvancedBy1000() { assertDuplicateSurvivesAdvance(by: 1000) }

    /// Many accepted frames, then one advance: every one of them is still a duplicate.
    func test_everyAcceptedFrameStaysADuplicateAcrossLaterAdvances() {
        var w = InnerAudioReplayWindow()
        let accepted: [UInt64] = [100, 101, 103, 110, 150, 163, 164, 165, 400]
        for s in accepted { accept(&w, s) }
        for advance in [UInt64(1), 2, 63, 64, 65, 200] {
            let top = (accepted.max() ?? 0) + advance
            accept(&w, top)
            for s in accepted where top - s < size {
                XCTAssertEqual(w.check(s), .duplicate, "seq \(s) lost after highest moved to \(top)")
            }
        }
    }

    /// The reverse symptom of the same bug: a late seq that was NEVER seen was rejected because a
    /// recorded bit landed on its index. Highest 10 with {10, 5} accepted, then 12: 9 is still fresh.
    func test_noFalseRejectionOfANeverSeenSeqAfterAnAdvance() {
        var w = InnerAudioReplayWindow()
        accept(&w, 10)
        accept(&w, 5)
        accept(&w, 12)
        XCTAssertEqual(w.check(9), .fresh)
        XCTAssertEqual(w.check(11), .fresh)
        XCTAssertEqual(w.check(5), .duplicate)
        XCTAssertEqual(w.check(10), .duplicate)
    }

    // MARK: - Out of order

    func test_outOfOrderFreshSeqsInsideTheWindowAreAcceptedExactlyOnce() {
        var w = InnerAudioReplayWindow()
        accept(&w, 500)
        for s: UInt64 in [499, 300, 450, 101, 498, 64, 65, 63] {
            accept(&w, s)
        }
        for s: UInt64 in [500, 499, 300, 450, 101, 498, 64, 65, 63] {
            XCTAssertEqual(w.check(s), .duplicate, "seq \(s)")
            XCTAssertEqual(w.commit(s), .duplicate, "seq \(s) must not commit twice")
        }
        XCTAssertEqual(w.check(497), .fresh)
    }

    func test_ascendingFromZeroThenDescendingInOrderRejectsNothingFresh() {
        var w = InnerAudioReplayWindow()
        // 3, 1, 2, 0: all inside the window of the first accepted seq.
        for s: UInt64 in [3, 1, 2, 0] { accept(&w, s) }
        for s: UInt64 in [0, 1, 2, 3] { XCTAssertEqual(w.check(s), .duplicate) }
    }

    // MARK: - Window edges

    func test_boundaryHighestMinus1023IsAcceptedAndHighestMinus1024IsTooOld() {
        var w = InnerAudioReplayWindow()
        let highest: UInt64 = 5000
        accept(&w, highest)
        accept(&w, highest - (size - 1))
        XCTAssertEqual(w.check(highest - size), .tooOld)
        XCTAssertEqual(w.commit(highest - size), .tooOld, "a too-old seq must not be recorded")
        // The rejected commit left the window as it was.
        XCTAssertEqual(w.check(highest - (size - 1)), .duplicate)
        XCTAssertEqual(w.check(highest + 1), .fresh)
    }

    func test_aSeqFallsOutOfTheWindowExactlyWhenTheHighestPassesIt() {
        var w = InnerAudioReplayWindow()
        accept(&w, size - 1)          // 1023
        XCTAssertEqual(w.check(0), .fresh, "1023 - 0 < 1024: still inside")
        accept(&w, size)              // 1024: seq 0 is now exactly 1024 behind
        XCTAssertEqual(w.check(0), .tooOld)
        XCTAssertEqual(w.check(1), .fresh)
    }

    func test_farAheadSeqMovesTheWindowAndOldEntriesBecomeTooOld() {
        var w = InnerAudioReplayWindow()
        accept(&w, 10)
        accept(&w, 10 + 5000)
        XCTAssertEqual(w.check(10), .tooOld)
        XCTAssertEqual(w.check(5010), .duplicate)
        XCTAssertEqual(w.check(5010 - size), .tooOld)
        XCTAssertEqual(w.check(5010 - (size - 1)), .fresh)
        // 4106 = 4 * 1024 + 10 shares slot 10 with the stale 10; the stale entry must not read
        // as a duplicate of 4106.
        XCTAssertEqual(w.check(4106), .fresh)
        accept(&w, 4106)
        XCTAssertEqual(w.check(4106), .duplicate)
    }

    func test_highestSeqAtTheUInt32Edge() {
        var w = InnerAudioReplayWindow()
        let top = UInt64(UInt32.max)
        accept(&w, top)
        XCTAssertEqual(w.check(top), .duplicate)
        accept(&w, top - (size - 1))
        XCTAssertEqual(w.check(top - size), .tooOld)
    }

    // MARK: - Reset

    func test_resetForgetsEverythingIncludingTheHighest() {
        var w = InnerAudioReplayWindow()
        accept(&w, 0)
        accept(&w, 1)
        accept(&w, 9000)
        w.reset()
        XCTAssertEqual(w.check(0), .fresh, "a restarted counter reuses 0")
        XCTAssertEqual(w.check(9000), .fresh)
        accept(&w, 5)
        // highest is 5 again, not 9000: 0 is neither a duplicate nor too old.
        XCTAssertEqual(w.check(0), .fresh)
        XCTAssertEqual(w.check(5), .duplicate)
    }

    // MARK: - Model check

    /// Deterministic SplitMix64, so the sequence is the same on every run.
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Plain-spec reference: highest + a set of accepted seqs. Thousands of operations, mostly near
    /// the highest (reordering, replays, boundary), some big jumps; every verdict must match.
    func test_verdictsMatchASetBasedModel() {
        var rng = SplitMix64(state: 0xC0FFEE)
        var w = InnerAudioReplayWindow()
        var model = Set<UInt64>()
        var highest: UInt64?

        func expected(_ seq: UInt64) -> InnerAudioReplayWindow.Verdict {
            guard let h = highest else { return .fresh }
            if seq > h { return .fresh }
            if h - seq >= InnerAudioReplayWindow.windowSize { return .tooOld }
            return model.contains(seq) ? .duplicate : .fresh
        }

        for step in 0..<6000 {
            let seq: UInt64
            let r = rng.next() % 100
            if let h = highest {
                if r < 4 {
                    seq = h + 1 + rng.next() % 3000          // big jump
                } else if r < 12 {
                    seq = h &+ rng.next() % 70               // small advance
                } else {
                    let back = rng.next() % 1300             // reorder / replay / too old
                    seq = h >= back ? h - back : 0
                }
            } else {
                seq = rng.next() % 50
            }
            let want = expected(seq)
            XCTAssertEqual(w.check(seq), want, "check step \(step) seq \(seq)")
            let committed = w.commit(seq)
            XCTAssertEqual(committed, want, "commit step \(step) seq \(seq)")
            if want == .fresh {
                model.insert(seq)
                if highest.map({ seq > $0 }) ?? true { highest = seq }
            }
        }
    }
}
