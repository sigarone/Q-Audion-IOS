import XCTest
@testable import QAudionEngine

/// The ATT writes the iPhone sends to the earbud: KEY_IMPORT (c3) and PAIR_BEGIN (c5).
///
/// IOSEarbudGattProxy (CoreBluetooth, app target, QAUDION_EARBUD only) cannot run in a unit test, so what
/// it writes is decided by two pure functions of the engine, `EarbudKeyImportFragmenter.writeFrames` and
/// `EarbudPairGatt.pairBeginFrames`, and these tests replay their output through a Swift model of the
/// firmware's write handlers (qaudion_gatt.c, `key_import_write` 1612-1757 and `pair_begin_write`
/// 1822-1857). What they pin: c3 takes BIG-endian offsets (little-endian ones are refused from the second
/// fragment on) and needs the PoP-INPUTS frame BEFORE the package (written after it, no PoP is produced).
final class EarbudGattFramingTests: XCTestCase {

    // MARK: - Firmware models

    /// Model of `key_import_write` (qaudion_gatt.c:1612). Throws what the firmware answers with an ATT error.
    private struct KeyImportFirmware {
        enum Refusal: Error, Equatable { case invalidPdu, invalidAttributeLen, invalidOffset }

        private var buf = [UInt8](repeating: 0, count: 1668)
        private var received = 0
        private var popStaged = false
        /// The package the SE imported, and whether the PoP inputs had been staged when it ran.
        private(set) var imported: [UInt8]?
        private(set) var importedWithPop: Bool?

        mutating func write(_ frame: Data) throws {
            let p = [UInt8](frame)
            if p.count < 3 { throw Refusal.invalidPdu }                       // [off:2][>=1 data]
            let foff = (Int(p[0]) << 8) | Int(p[1])                            // BIG-endian
            let data = Array(p[2...])
            if foff == 0xFFFF {                                                // PoP inputs, staged
                if data.count != 80 { throw Refusal.invalidAttributeLen }
                popStaged = true
                return
            }
            if foff + data.count > 1668 { throw Refusal.invalidAttributeLen }
            if foff == 0 {
                buf = [UInt8](repeating: 0, count: 1668)                      // a new package
                received = 0
            } else if foff > received {
                throw Refusal.invalidOffset                                    // forward gap
            }
            buf.replaceSubrange(foff..<(foff + data.count), with: data)
            if foff + data.count > received { received = foff + data.count }
            if received == 1668 {
                imported = buf
                importedWithPop = popStaged
                popStaged = false                                              // wiped after an import attempt
                buf = [UInt8](repeating: 0, count: 1668)
                received = 0
            }
        }
    }

    /// Model of `pair_begin_write` (qaudion_gatt.c:1822): `[offset: u16 LE][data]`, the offset is NOT checked for contiguity.
    private struct PairBeginFirmware {
        enum Refusal: Error, Equatable { case invalidAttributeLen, invalidOffset }

        private var buf = [UInt8](repeating: 0, count: 1632)
        private var received = 0
        private(set) var accepted: [UInt8]?

        mutating func write(_ frame: Data) throws {
            let p = [UInt8](frame)
            if p.count < 3 { throw Refusal.invalidAttributeLen }
            let fragOff = Int(p[0]) | (Int(p[1]) << 8)                         // LITTLE-endian
            let dataLen = p.count - 2
            if fragOff + dataLen > 1632 { throw Refusal.invalidOffset }
            buf.replaceSubrange(fragOff..<(fragOff + dataLen), with: p[2...])
            if fragOff + dataLen > received { received = fragOff + dataLen }
            if received == 1632 {
                accepted = buf
                buf = [UInt8](repeating: 0, count: 1632)
                received = 0
            }
        }
    }

    // MARK: - Fixtures

    private let pkg = Data((0..<1668).map { UInt8(($0 * 7 + 3) & 0xFF) })
    /// 0xFFFF sentinel + 80 distinguishable bytes: the frame EarbudAckPopRelay builds, 82 B.
    private let popInputs = Data([0xFF, 0xFF] + (0..<80).map { UInt8(0xA0 + $0 % 64) })

    // MARK: - KEY_IMPORT (c3)

    func testPopInputsFixtureIsTheFirmwareSize() {
        XCTAssertEqual(popInputs.count, EarbudGattConstants.KEYIMPORT_POP_FRAME_LEN)
        XCTAssertEqual(pkg.count, EarbudGattConstants.KEYIMPORT_PKG_LEN)
    }

    func testKeyImportPlanWritesPopInputsFirstThenBigEndianFragments() throws {
        // ATT MTU 185 -> 182 bytes per write, 180 of package in each fragment.
        let frames = try XCTUnwrap(
            EarbudKeyImportFragmenter.writeFrames(pkg: pkg, popInputs: popInputs, maxWriteLength: 182))

        XCTAssertEqual(frames[0], popInputs, "the PoP-INPUTS frame goes out first, unchanged")
        XCTAssertEqual(Array(frames.dropFirst()), EarbudKeyImportFragmenter.fragment(pkg, mtuPayload: 180),
                       "the package follows as the engine's big-endian contiguous fragments")
        XCTAssertEqual(frames.count, 1 + 10, "1668 B in fragments of 180 B is 10 frames")
        // The second fragment starts at byte 180 = 0x00B4: big-endian is 00 B4 (little-endian would be
        // B4 00), the third at 360 = 0x0168 is 01 68.
        XCTAssertEqual(Array(frames[2].prefix(2)), [0x00, 0xB4])
        XCTAssertEqual(Array(frames[3].prefix(2)), [0x01, 0x68])
        for f in frames {
            XCTAssertLessThanOrEqual(f.count, 182, "no frame may need a long write (the firmware refuses ATT offset != 0)")
        }
    }

    func testKeyImportPlanIsAcceptedByTheFirmwareAndImportsWithThePop() throws {
        for budget in [182, 244, 514] {
            let frames = try XCTUnwrap(
                EarbudKeyImportFragmenter.writeFrames(pkg: pkg, popInputs: popInputs, maxWriteLength: budget))
            var fw = KeyImportFirmware()
            for f in frames { try fw.write(f) }
            XCTAssertEqual(fw.imported, [UInt8](pkg), "budget \(budget): the SE imports the package byte for byte")
            XCTAssertEqual(fw.importedWithPop, true, "budget \(budget): the PoP inputs were staged before the import ran")
        }
    }

    func testKeyImportPlanWithoutPopInputsHasNoSentinelFrame() throws {
        let frames = try XCTUnwrap(
            EarbudKeyImportFragmenter.writeFrames(pkg: pkg, popInputs: nil, maxWriteLength: 22))
        XCTAssertEqual(frames, EarbudKeyImportFragmenter.fragment(pkg, mtuPayload: 20))
        var fw = KeyImportFirmware()
        for f in frames { try fw.write(f) }
        XCTAssertEqual(fw.importedWithPop, false, "a legacy import: no PoP inputs staged")
    }

    func testKeyImportPlanRefusesABudgetThatCannotCarryThePopInputsFrame() {
        // The default ATT MTU (23) is 20 bytes: the 82 B frame cannot be split (the firmware stages it
        // from ONE write of exactly 82 bytes), so there is no plan. 82 is the smallest budget that works.
        XCTAssertNil(EarbudKeyImportFragmenter.writeFrames(pkg: pkg, popInputs: popInputs, maxWriteLength: 20))
        XCTAssertNil(EarbudKeyImportFragmenter.writeFrames(pkg: pkg, popInputs: popInputs, maxWriteLength: 81))
        let frames = EarbudKeyImportFragmenter.writeFrames(pkg: pkg, popInputs: popInputs, maxWriteLength: 82)
        XCTAssertNotNil(frames)
        XCTAssertEqual(frames?.count, 1 + 21, "fragments of 80 B: 1668 / 80 = 21 frames")
    }

    func testKeyImportPlanRefusesABudgetBelowTheMinimumFrame() {
        XCTAssertNil(EarbudKeyImportFragmenter.writeFrames(pkg: pkg, popInputs: nil, maxWriteLength: 2))
        XCTAssertNil(EarbudKeyImportFragmenter.writeFrames(pkg: pkg, popInputs: nil, maxWriteLength: 0))
        XCTAssertNotNil(EarbudKeyImportFragmenter.writeFrames(pkg: pkg, popInputs: nil, maxWriteLength: 3))
    }

    /// A client that frames c3 with LITTLE-endian offsets, replayed on the model, so the model proves it catches the error.
    func testTheShippedLittleEndianFramingWasRefusedFromTheSecondFragment() {
        var legacy: [Data] = []
        var offset = 0
        while offset < pkg.count {
            let len = min(180, pkg.count - offset)
            var f = Data([UInt8(offset & 0xFF), UInt8((offset >> 8) & 0xFF)])   // LITTLE-endian: wrong for c3
            f.append(pkg[offset..<(offset + len)])
            legacy.append(f)
            offset += len
        }
        var fw = KeyImportFirmware()
        XCTAssertNoThrow(try fw.write(legacy[0]), "the first fragment (offset 0) is the same in both byte orders")
        XCTAssertThrowsError(try fw.write(legacy[1]), "offset 180 read big-endian is 46080: refused")
    }

    func testThePopInputsFrameWrittenAfterThePackageNeverReachedTheSe() throws {
        var fw = KeyImportFirmware()
        for f in EarbudKeyImportFragmenter.fragment(pkg, mtuPayload: 180) { try fw.write(f) }
        try fw.write(popInputs)   // the wrong order: PoP-INPUTS last
        XCTAssertEqual(fw.imported, [UInt8](pkg))
        XCTAssertEqual(fw.importedWithPop, false, "the import ran before the inputs were staged: no PoP on c1")
    }

    // MARK: - PAIR_BEGIN (c5)

    func testPairBeginFramesAreLittleEndianContiguousAndFitTheWrite() throws {
        let payload = Data((0..<1632).map { UInt8(($0 * 13 + 5) & 0xFF) })
        let frames = try XCTUnwrap(EarbudPairGatt.pairBeginFrames(payload, maxWriteLength: 182))

        XCTAssertEqual(frames.count, 10, "1632 B in 180 B of data per frame")
        // Second frame starts at byte 180 = 0x00B4: little-endian B4 00 (c3 is the other way round).
        XCTAssertEqual(Array(frames[1].prefix(2)), [0xB4, 0x00])
        // Byte 1440 = 0x05A0 starts the ninth frame.
        XCTAssertEqual(Array(frames[8].prefix(2)), [0xA0, 0x05])
        for f in frames { XCTAssertLessThanOrEqual(f.count, 182) }

        var fw = PairBeginFirmware()
        for f in frames { try fw.write(f) }
        XCTAssertEqual(fw.accepted, [UInt8](payload), "the earbud reassembles the 1632 B PAIR_BEGIN")
    }

    func testPairBeginFramesAtTheDefaultMtu() throws {
        let payload = Data(repeating: 0x5C, count: 1632)
        let frames = try XCTUnwrap(EarbudPairGatt.pairBeginFrames(payload, maxWriteLength: 20))
        XCTAssertEqual(frames.count, 91, "18 B of data per frame: 1632 / 18 = 90.67")
        var fw = PairBeginFirmware()
        for f in frames { try fw.write(f) }
        XCTAssertEqual(fw.accepted, [UInt8](payload))
    }

    func testPairBeginFramesRefuseTooSmallABudgetOrAnEmptyPayload() {
        XCTAssertNil(EarbudPairGatt.pairBeginFrames(Data(repeating: 1, count: 1632), maxWriteLength: 2))
        XCTAssertNil(EarbudPairGatt.pairBeginFrames(Data(), maxWriteLength: 182))
    }

    func testBigEndianFramesWouldCorruptPairBegin() throws {
        // c3's framing on c5 is the mirror mistake: the firmware reads the offset little-endian.
        let payload = Data(repeating: 0x21, count: 1632)
        let wrongOrder = EarbudKeyImportFragmenter.fragment(payload, mtuPayload: 180)
        var fw = PairBeginFirmware()
        var refused = false
        for f in wrongOrder {
            do { try fw.write(f) } catch { refused = true; break }
        }
        XCTAssertTrue(refused, "offset 180 read little-endian is 46080: out of range")
    }
}
