import XCTest
@testable import QAudionEngine

/// §3.3 sovereign KEY_IMPORT fragmentation. The firmware reassembler
/// (firmware/nspe/src/transport/qaudion_gatt.c key_import_write) accepts
/// per-fragment Write-With-Response frames `[frag_offset:u16 BE][payload]`
/// at ATT offset 0, requires each frame to EXTEND a contiguous prefix
/// (forward gaps rejected), and completes when received == 1668. This
/// test pins the contiguous, big-endian-offset, payload>=1 framing.
final class EarbudKeyImportFragmentTests: XCTestCase {
    func testFragmentsAndReassembles() {
        let pkg = Data((0..<1668).map { UInt8($0 & 0xFF) })  // §3.3 fixed size
        let frames = EarbudKeyImportFragmenter.fragment(pkg, mtuPayload: 180)
        // Each frame: [offset:u16 BE][payload<=180], payload>=1.
        XCTAssertGreaterThan(frames.count, 1)
        for f in frames {
            XCTAssertGreaterThanOrEqual(f.count, 3, "firmware requires len>=3 ([off:2][>=1 data])")
        }
        // Reassemble by reading the offsets.
        var out = Data(count: pkg.count)
        for f in frames {
            let off = (Int(f[f.startIndex]) << 8) | Int(f[f.startIndex + 1])
            let payload = f.dropFirst(2)
            out.replaceSubrange(off..<(off + payload.count), with: payload)
        }
        XCTAssertEqual(out, pkg, "reassembled payload must equal input")
    }

    func testOffsetsAreBigEndianAndContiguous() {
        let pkg = Data(repeating: 0x7, count: 500)
        let frames = EarbudKeyImportFragmenter.fragment(pkg, mtuPayload: 100)
        XCTAssertEqual(frames.count, 5)
        var expected = 0
        for f in frames {
            let off = (Int(f[f.startIndex]) << 8) | Int(f[f.startIndex + 1])
            // Contiguous (no forward gap → firmware accepts each frame).
            XCTAssertEqual(off, expected)
            expected += f.count - 2
        }
        XCTAssertEqual(expected, 500)
    }

    func testFirstFrameOffsetIsZero() {
        let pkg = Data(repeating: 0xAB, count: 50)
        let frames = EarbudKeyImportFragmenter.fragment(pkg, mtuPayload: 180)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0][frames[0].startIndex], 0x00)
        XCTAssertEqual(frames[0][frames[0].startIndex + 1], 0x00)
    }
}
