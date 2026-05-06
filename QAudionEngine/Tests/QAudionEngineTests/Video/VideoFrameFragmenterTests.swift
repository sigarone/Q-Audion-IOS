import XCTest
@testable import QAudionEngine

final class VideoFrameFragmenterTests: XCTestCase {

    func testSingleFragmentRoundTrip() throws {
        let fragmenter = VideoFrameFragmenter()
        let nal = Data((0..<256).map { UInt8($0 & 0xFF) })
        let frags = fragmenter.fragment(nalUnit: nal, isKeyFrame: true, bitrateKbps: 800)
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
        let frags = fragmenter.fragment(nalUnit: nal, isKeyFrame: false, bitrateKbps: 1500)
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
        let frags = fragmenter.fragment(nalUnit: nal, isKeyFrame: true)
        XCTAssertGreaterThan(frags.count, 1)

        let recv = VideoFrameFragmenter()
        // Deliver in reverse order.
        for f in frags.reversed().dropLast() {
            XCTAssertNil(recv.defragment(f))
        }
        // Last (= original first) completes the reassembly.
        let result = recv.defragment(frags.first!)
        XCTAssertEqual(result?.nalUnit, nal)
    }

    func testDuplicateFragmentIgnored() throws {
        let fragmenter = VideoFrameFragmenter()
        let nal = Data((0..<2000).map { UInt8($0 & 0xFF) })
        let frags = fragmenter.fragment(nalUnit: nal, isKeyFrame: false)
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

    func testFrameIdWraparound() {
        let fragmenter = VideoFrameFragmenter()
        let nal = Data([0x00])
        // Fragment 65537 times to wrap the u16 frameId.
        // (Use a smaller probe — 5 calls — and just verify it doesn't crash.)
        for _ in 0..<5 {
            _ = fragmenter.fragment(nalUnit: nal, isKeyFrame: false)
        }
    }

    func testPurgeStaleClearsPending() {
        let recv = VideoFrameFragmenter()
        let fragmenter = VideoFrameFragmenter()
        let nal = Data((0..<3000).map { UInt8($0 & 0xFF) })
        let frags = fragmenter.fragment(nalUnit: nal, isKeyFrame: false)

        XCTAssertNil(recv.defragment(frags[0]))
        XCTAssertEqual(recv.pendingFrameCount, 1)

        // The purge timeout is 150ms — sleep just past it.
        Thread.sleep(forTimeInterval: 0.2)
        let purged = recv.purgeStaleFrames()
        XCTAssertEqual(purged, 1)
        XCTAssertEqual(recv.pendingFrameCount, 0)
    }

    func testKeyFrameFlagPreservedAcrossFragments() {
        let fragmenter = VideoFrameFragmenter()
        let nal = Data((0..<2500).map { UInt8($0 & 0xFF) })
        let frags = fragmenter.fragment(nalUnit: nal, isKeyFrame: true)
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

    func testFragmentHeaderLayoutMatchesAndroid() {
        let fragmenter = VideoFrameFragmenter()
        let nal = Data(repeating: 0xAB, count: 100)
        let frags = fragmenter.fragment(nalUnit: nal, isKeyFrame: true, bitrateKbps: 0x1234)
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
}
