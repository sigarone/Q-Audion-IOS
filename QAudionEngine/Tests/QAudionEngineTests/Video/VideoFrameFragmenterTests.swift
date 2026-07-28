import XCTest
@testable import QAudionEngine

final class VideoFrameFragmenterTests: XCTestCase {

    func testSingleFragmentRoundTrip() throws {
        let fragmenter = VideoFrameFragmenter()
        let nal = Data((0..<256).map { UInt8($0 & 0xFF) })
        let frags = try fragmenter.fragment(nalUnit: nal, isKeyFrame: true, bitrateKbps: 800)
        XCTAssertEqual(frags.count, 1)

        let recv = VideoFrameFragmenter()
        let result = recv.defragment(frags[0])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.nalUnit, nal)
        XCTAssertEqual(result?.isKeyFrame, true)
        XCTAssertEqual(result?.bitrateHintKbps, 800)
    }

    func testMultiFragmentReassembly() throws {
        let fragmenter = VideoFrameFragmenter()
        // 3500 bytes -> ceil(3500 / 1193) = 3 fragments (1200-7=1193 max data per fragment)
        let nal = Data((0..<3500).map { UInt8($0 & 0xFF) })
        let frags = try fragmenter.fragment(nalUnit: nal, isKeyFrame: false, bitrateKbps: 1500)
        XCTAssertEqual(frags.count, 3)

        let recv = VideoFrameFragmenter()
        XCTAssertNil(recv.defragment(frags[0]))
        XCTAssertNil(recv.defragment(frags[1]))
        let final = recv.defragment(frags[2])
        XCTAssertNotNil(final)
        XCTAssertEqual(final?.nalUnit, nal)
        XCTAssertEqual(final?.isKeyFrame, false)
        XCTAssertEqual(final?.bitrateHintKbps, 1500)
    }

    func testOutOfOrderReassembly() throws {
        let fragmenter = VideoFrameFragmenter()
        let nal = Data((0..<3000).map { UInt8($0 & 0xFF) })
        let frags = try fragmenter.fragment(nalUnit: nal, isKeyFrame: true)
        XCTAssertGreaterThan(frags.count, 1)

        let recv = VideoFrameFragmenter()
        // Deliver in reverse order.
        for f in frags.reversed().dropLast() {
            XCTAssertNil(recv.defragment(f))
        }
        // Last (= original first) completes the reassembly.
        // Safe: XCTAssertGreaterThan(frags.count, 1) above guarantees frags is non-empty.
        // swiftlint:disable:next force_unwrapping
        let result = recv.defragment(frags.first!)
        XCTAssertEqual(result?.nalUnit, nal)
    }

    func testDuplicateFragmentIgnored() throws {
        let fragmenter = VideoFrameFragmenter()
        let nal = Data((0..<2000).map { UInt8($0 & 0xFF) })
        let frags = try fragmenter.fragment(nalUnit: nal, isKeyFrame: false)
        XCTAssertGreaterThan(frags.count, 1)

        let recv = VideoFrameFragmenter()
        // Deliver fragment 0 twice — receivedCount must NOT exceed totalFrags.
        XCTAssertNil(recv.defragment(frags[0]))
        XCTAssertNil(recv.defragment(frags[0])) // duplicate
        // Deliver remaining fragments.
        for i in 1..<frags.count {
            let r = recv.defragment(frags[i])
            if i == frags.count - 1 {
                XCTAssertEqual(r?.nalUnit, nal)
            } else {
                XCTAssertNil(r)
            }
        }
    }

    func testTooSmallFragmentReturnsNil() {
        let recv = VideoFrameFragmenter()
        XCTAssertNil(recv.defragment(Data([0x01, 0x02, 0x03])))
    }

    func testFrameIdWraparound() throws {
        let fragmenter = VideoFrameFragmenter()
        let nal = Data([0x00])
        // Fragment 65537 times to wrap the u16 frameId.
        // (Use a smaller probe — 5 calls — and just verify it doesn't crash.)
        for _ in 0..<5 {
            _ = try fragmenter.fragment(nalUnit: nal, isKeyFrame: false)
        }
    }

    func testPurgeStaleClearsPending() throws {
        let recv = VideoFrameFragmenter()
        let fragmenter = VideoFrameFragmenter()
        let nal = Data((0..<3000).map { UInt8($0 & 0xFF) })
        let frags = try fragmenter.fragment(nalUnit: nal, isKeyFrame: false)

        XCTAssertNil(recv.defragment(frags[0]))
        XCTAssertEqual(recv.pendingFrameCount, 1)

        // The purge timeout is 150ms — sleep just past it.
        Thread.sleep(forTimeInterval: 0.2)
        let purged = recv.purgeStaleFrames()
        XCTAssertEqual(purged, 1)
        XCTAssertEqual(recv.pendingFrameCount, 0)
    }

    /// Task 11 holistic-review fix — single-frame-in-flight: a new
    /// frameId must UNCONDITIONALLY discard whatever partial frame was
    /// previously buffered, matching Android's VideoFrameReassembler.kt /
    /// Desktop's VideoFrameReassembler.ts (a dictionary keyed by frameId
    /// was the previous — now-fixed — divergence from both). No timeout
    /// wait needed: the abandoned frame's fragments must never complete
    /// once a newer frame's fragment has arrived, even immediately.
    func testNewFrameIdDiscardsPriorIncompleteFrame() throws {
        let fragmenter = VideoFrameFragmenter()
        let nal1 = Data((0..<3000).map { UInt8($0 & 0xFF) })
        let frags1 = try fragmenter.fragment(nalUnit: nal1, isKeyFrame: false)
        XCTAssertGreaterThan(frags1.count, 1)
        let nal2 = Data((0..<256).map { UInt8($0 & 0xFF) })
        let frags2 = try fragmenter.fragment(nalUnit: nal2, isKeyFrame: true)
        XCTAssertEqual(frags2.count, 1)

        let recv = VideoFrameFragmenter()
        // Start frame 1 but never complete it.
        XCTAssertNil(recv.defragment(frags1[0]))
        XCTAssertEqual(recv.pendingFrameCount, 1)

        // Frame 2 (a different frameId, fully self-contained in 1
        // fragment) arrives next — it must complete on its own, proving
        // the pending slot was replaced rather than merged/blocked.
        let result = recv.defragment(frags2[0])
        XCTAssertEqual(result?.nalUnit, nal2)
        XCTAssertEqual(result?.isKeyFrame, true)
        XCTAssertEqual(recv.pendingFrameCount, 0)

        // Frame 1's remaining fragments must NOT complete it — its slot
        // was discarded when frame 2 arrived, not merged alongside it.
        for f in frags1.dropFirst() {
            XCTAssertNil(recv.defragment(f))
        }
        XCTAssertEqual(recv.pendingFrameCount, 1) // the last dropFirst fragment re-opens a (new, doomed) slot for frameId1
    }

    func testKeyFrameFlagPreservedAcrossFragments() throws {
        let fragmenter = VideoFrameFragmenter()
        let nal = Data((0..<2500).map { UInt8($0 & 0xFF) })
        let frags = try fragmenter.fragment(nalUnit: nal, isKeyFrame: true)
        // Every fragment must have the FRAG_FLAG_KEY_FRAME bit set.
        for f in frags {
            XCTAssertEqual(f[f.startIndex] & VideoConstants.fragFlagKeyFrame,
                           VideoConstants.fragFlagKeyFrame)
        }
        // Only the last fragment has FRAG_FLAG_LAST_FRAGMENT.
        for (i, f) in frags.enumerated() {
            let isLast = i == frags.count - 1
            let hasLast = (f[f.startIndex] & VideoConstants.fragFlagLastFragment) != 0
            XCTAssertEqual(hasLast, isLast)
        }
    }

    func testFragmentHeaderLayoutMatchesAndroid() throws {
        let fragmenter = VideoFrameFragmenter()
        let nal = Data(repeating: 0xAB, count: 100)
        let frags = try fragmenter.fragment(nalUnit: nal, isKeyFrame: true, bitrateKbps: 0x1234)
        XCTAssertEqual(frags.count, 1)
        let f = frags[0]
        // Header bytes:
        // [0] fragFlags = KEY|LAST = 0x03
        XCTAssertEqual(f[0], VideoConstants.fragFlagKeyFrame | VideoConstants.fragFlagLastFragment)
        // [1-2] frameId = 0 BE
        XCTAssertEqual(f[1], 0x00); XCTAssertEqual(f[2], 0x00)
        // [3] fragIdx = 0
        XCTAssertEqual(f[3], 0x00)
        // [4] totalFrags = 1
        XCTAssertEqual(f[4], 0x01)
        // [5-6] bitrateHint = 0x1234 BE
        XCTAssertEqual(f[5], 0x12); XCTAssertEqual(f[6], 0x34)
    }

    /// Task 10 holistic-review fix — a NAL needing more than
    /// `VideoConstants.maxFragmentsPerFrame` fragments must be REJECTED
    /// (thrown), not silently truncated. Mirrors Android's
    /// `VideoFrameFragmenter.kt` `require(totalFrags <= MAX_FRAGMENTS_PER_FRAME)`.
    func testOversizedFrameThrowsInsteadOfTruncating() {
        let fragmenter = VideoFrameFragmenter()
        let maxDataPerFragment = VideoConstants.maxFragmentPayload - VideoConstants.videoFragmentHeaderSize
        // One byte more than fits in maxFragmentsPerFrame fragments.
        let oversizedSize = maxDataPerFragment * VideoConstants.maxFragmentsPerFrame + 1
        let nal = Data(repeating: 0xCD, count: oversizedSize)
        XCTAssertThrowsError(try fragmenter.fragment(nalUnit: nal, isKeyFrame: true)) { error in
            guard case VideoFrameFragmenter.FragmenterError.frameTooLarge(let nalSize, let needed, let maxFrags) = error else {
                XCTFail("expected .frameTooLarge, got \(error)")
                return
            }
            XCTAssertEqual(nalSize, oversizedSize)
            XCTAssertEqual(needed, VideoConstants.maxFragmentsPerFrame + 1)
            XCTAssertEqual(maxFrags, VideoConstants.maxFragmentsPerFrame)
        }
    }

    /// A NAL that needs EXACTLY `maxFragmentsPerFrame` fragments must still
    /// succeed (the bound is inclusive, matching Android's `<=` check).
    func testFrameAtExactlyMaxFragmentsSucceeds() throws {
        let fragmenter = VideoFrameFragmenter()
        let maxDataPerFragment = VideoConstants.maxFragmentPayload - VideoConstants.videoFragmentHeaderSize
        let nal = Data(repeating: 0xCD, count: maxDataPerFragment * VideoConstants.maxFragmentsPerFrame)
        let frags = try fragmenter.fragment(nalUnit: nal, isKeyFrame: true)
        XCTAssertEqual(frags.count, VideoConstants.maxFragmentsPerFrame)
    }
}
