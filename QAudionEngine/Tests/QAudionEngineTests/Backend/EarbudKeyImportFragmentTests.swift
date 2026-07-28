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

    /// §3.4 PoP-INPUTS frame — pins the EXACT 82 bytes against the firmware
    /// (qaudion_gatt.c KEYIMPORT_POP_SENTINEL=0xFFFF, KEYIMPORT_POP_INPUTS_LEN=80,
    /// staged layout txn_id(16)||key_id(16)||server_id(32)||server_nonce(16)
    /// consumed by sovkey_import.c at offsets +0/+16/+32/+64).
    func testPopInputsFrameExactBytes() {
        // Distinct, recognizable byte fills so a wrong field order is caught.
        let txn = UUID(uuid: (0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7,
                              0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF))   // txn_id
        let key = UUID(uuid: (0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
                              0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF))   // key_id
        let serverId = Data((0..<32).map { UInt8(0x40 + $0) })           // server_id 0x40..0x5f
        let serverNonce = Data((0..<16).map { UInt8(0xE0 + $0) })        // 0xe0..0xef

        let frame = EarbudKeyImportFragmenter.popInputsFrame(
            txnId: txn, keyId: key, serverId: serverId, serverNonce: serverNonce)

        // Total length 2 (sentinel) + 80 (body) = 82.
        XCTAssertEqual(frame.count, 82)
        let b = [UInt8](frame)
        // Sentinel 0xFFFF, u16 BE.
        XCTAssertEqual(b[0], 0xFF)
        XCTAssertEqual(b[1], 0xFF)
        // txn_id(16) @ +2.
        XCTAssertEqual(Array(b[2..<18]), (0xD0...0xDF).map { UInt8($0) })
        // key_id(16) @ +18.
        XCTAssertEqual(Array(b[18..<34]), (0xA0...0xAF).map { UInt8($0) })
        // server_id(32) @ +34.
        XCTAssertEqual(Array(b[34..<66]), (0..<32).map { UInt8(0x40 + $0) })
        // server_nonce(16) @ +66.
        XCTAssertEqual(Array(b[66..<82]), (0xE0...0xEF).map { UInt8($0) })

        // Body (drop the 2-byte sentinel) is exactly KEYIMPORT_POP_INPUTS_LEN.
        XCTAssertEqual(frame.count - 2, EarbudKeyImportFragmenter.popInputsBodyLen)
        XCTAssertEqual(EarbudKeyImportFragmenter.popSentinel, 0xFFFF)
    }

    /// The PoP-INPUTS sentinel can never collide with a real package
    /// fragment offset: 0xFFFF > KEYIMPORT_PKG_LEN (1668), so the firmware
    /// dispatches it to the PoP-inputs path, not the reassembler.
    func testSentinelNeverCollidesWithFragmentOffset() {
        let pkg = Data((0..<1668).map { UInt8($0 & 0xFF) })
        let frames = EarbudKeyImportFragmenter.fragment(pkg, mtuPayload: 180)
        for f in frames {
            let off = (UInt16(f[f.startIndex]) << 8) | UInt16(f[f.startIndex + 1])
            XCTAssertNotEqual(off, EarbudKeyImportFragmenter.popSentinel)
            XCTAssertLessThanOrEqual(Int(off), 1668)
        }
    }
}
