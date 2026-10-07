import XCTest
@testable import QAudionEngine

/// What leaves the device when a picture is sent: the metadata (GPS position, device identifiers, time, thumbnail, maker note,
/// XMP, IPTC, comments) is not in it, the pixels are the same bytes, and the one tag the picture needs to be shown upright
/// (Orientation) is kept. The files here are built byte by byte, with every field a camera writes, and the OUTPUT is searched for
/// the secrets: a test that only looked at a parser's answers would not notice a field that was copied by mistake.
///
/// The same files, with the same expectations, are the ones the Android app's `ImageMetadataStripperTest` builds.
final class ImageMetadataStripperTests: XCTestCase {

    // MARK: Byte helpers

    private func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

    private func cat(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }

    private func bytes(_ values: Int...) -> [UInt8] { values.map { UInt8(truncatingIfNeeded: $0) } }

    private func zeros(_ count: Int) -> [UInt8] { [UInt8](repeating: 0, count: count) }

    private func be16(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    private func be32(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    private func le16(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }

    private func le32(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
         UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)]
    }

    private func indexOf(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            var matches = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matches = false
                break
            }
            if matches { return start }
        }
        return nil
    }

    private func strip(_ input: [UInt8]) throws -> [UInt8] {
        let stripped = try ImageMetadataStripper.strip(Data(input))
        return [UInt8](stripped.data)
    }

    private func stripFormat(_ input: [UInt8]) throws -> PictureFormat {
        try ImageMetadataStripper.strip(Data(input)).format
    }

    private func assertNoSecrets(_ output: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        for secret in secrets {
            XCTAssertNil(indexOf(output, ascii(secret)), "a secret survived: \(secret)", file: file, line: line)
        }
    }

    /// The input is a handled format that is broken: the error says so (it is not "an unknown format").
    private func assertMalformed(_ input: [UInt8], _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try strip(input)
            XCTFail("expected a malformed error: \(why)", file: file, line: line)
        } catch let error as ImageMetadataError {
            if case .malformed = error { return }
            XCTFail("\(why): a handled format that is broken, not an unknown one", file: file, line: line)
        } catch {
            XCTFail("\(why): not an ImageMetadataError", file: file, line: line)
        }
    }

    private func assertRefused(_ input: [UInt8], _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try strip(input), why, file: file, line: line)
    }

    private var secrets: [String] {
        [
            "CanonXYZ-Make", "EOS-Model-9000", "PhotoSoft-7.1", "2026:10:07 12:34:56", "MKNOTE-SECRET-BYTES", "SN-4711-BODY",
            "LENS-ZZ-50mm", "THUMBNAIL-JPEG-SECRET", "GPS-PROC-METHOD-SECRET", "GPS-AREA-SECRET-RM", "XMP-SECRET", "ns.adobe.com",
            "Photoshop", "IPTC-CAPTION-SECRET", "COMMENT-SECRET", "MPF-SECRET", "TRAILER-MOTION-VIDEO-SECRET", "PLAINTEXT-SECRET",
            "private-secret", "GPS 45N", "GPSLatitude"
        ]
    }

    private var trailer: [UInt8] { ascii("TRAILER-MOTION-VIDEO-SECRET") }

    // MARK: TIFF (the body of an Exif block)

    private struct Entry {
        let tag: Int
        let type: Int
        let count: Int
        let data: [UInt8]
    }

    /// A TIFF with IFD0 (Make, Model, Orientation, Software, DateTime), an Exif IFD (MakerNote, serial numbers) and a GPS IFD, and a
    /// thumbnail after them.
    private func tiff(littleEndian: Bool, orientation: Int?) -> [UInt8] {
        func u16(_ value: Int) -> [UInt8] { littleEndian ? le16(value) : be16(value) }
        func u32(_ value: Int) -> [UInt8] { littleEndian ? le32(value) : be32(value) }
        func text(_ value: String) -> Entry {
            Entry(tag: 0, type: 2, count: value.utf8.count + 1, data: cat(ascii(value), bytes(0)))
        }
        func with(tag: Int, _ entry: Entry) -> Entry {
            Entry(tag: tag, type: entry.type, count: entry.count, data: entry.data)
        }
        func undefined(tag: Int, _ value: String) -> Entry {
            Entry(tag: tag, type: 7, count: value.utf8.count, data: ascii(value))
        }
        func ifdSize(_ entries: [Entry]) -> Int {
            var size = 2 + 12 * entries.count + 4
            for entry in entries where entry.data.count > 4 { size += (entry.data.count + 1) & ~1 }
            return size
        }
        func ifd(_ entries: [Entry], at start: Int) -> [UInt8] {
            var head: [UInt8] = u16(entries.count)
            var tail: [UInt8] = []
            var dataPosition = start + 2 + 12 * entries.count + 4
            for entry in entries {
                head.append(contentsOf: u16(entry.tag))
                head.append(contentsOf: u16(entry.type))
                head.append(contentsOf: u32(entry.count))
                if entry.data.count <= 4 {
                    head.append(contentsOf: entry.data)
                    head.append(contentsOf: zeros(4 - entry.data.count))
                } else {
                    head.append(contentsOf: u32(dataPosition))
                    tail.append(contentsOf: entry.data)
                    if entry.data.count % 2 == 1 { tail.append(0) }
                    dataPosition += (entry.data.count + 1) & ~1
                }
            }
            head.append(contentsOf: u32(0))
            head.append(contentsOf: tail)
            return head
        }
        let exifEntries: [Entry] = [
            with(tag: 0x9003, text("2026:10:07 12:34:56")),
            undefined(tag: 0x927C, "MKNOTE-SECRET-BYTES"),
            with(tag: 0xA431, text("SN-4711-BODY")),
            with(tag: 0xA434, text("LENS-ZZ-50mm"))
        ]
        let latitude: [UInt8] = cat(u32(45), u32(1), u32(30), u32(1), u32(1234), u32(100))
        let longitude: [UInt8] = cat(u32(12), u32(1), u32(29), u32(1), u32(5678), u32(100))
        let gpsEntries: [Entry] = [
            with(tag: 0x0001, text("N")),
            Entry(tag: 0x0002, type: 5, count: 3, data: latitude),
            with(tag: 0x0003, text("E")),
            Entry(tag: 0x0004, type: 5, count: 3, data: longitude),
            undefined(tag: 0x001B, "GPS-PROC-METHOD-SECRET"),
            undefined(tag: 0x001C, "GPS-AREA-SECRET-RM")
        ]
        func ifd0(exifAt: Int, gpsAt: Int) -> [Entry] {
            var entries: [Entry] = [
                with(tag: 0x010F, text("CanonXYZ-Make")),
                with(tag: 0x0110, text("EOS-Model-9000"))
            ]
            if let orientation {
                entries.append(Entry(tag: 0x0112, type: 3, count: 1, data: u16(orientation)))
            }
            entries.append(with(tag: 0x0131, text("PhotoSoft-7.1")))
            entries.append(with(tag: 0x0132, text("2026:10:07 12:34:56")))
            entries.append(Entry(tag: 0x8769, type: 4, count: 1, data: u32(exifAt)))
            entries.append(Entry(tag: 0x8825, type: 4, count: 1, data: u32(gpsAt)))
            return entries
        }
        let exifAt = 8 + ifdSize(ifd0(exifAt: 0, gpsAt: 0))
        let gpsAt = exifAt + ifdSize(exifEntries)
        let header: [UInt8] = cat(ascii(littleEndian ? "II" : "MM"), u16(42), u32(8))
        return cat(
            header,
            ifd(ifd0(exifAt: exifAt, gpsAt: gpsAt), at: 8),
            ifd(exifEntries, at: exifAt),
            ifd(gpsEntries, at: gpsAt),
            ascii("THUMBNAIL-JPEG-SECRET"))
    }

    /// The only Exif this code writes: one IFD0 entry, Orientation, big endian.
    private func minimalTiff(_ orientation: Int) -> [UInt8] {
        cat(ascii("MM"), be16(42), be32(8), be16(1), be16(0x0112), be16(3), be32(1), be16(orientation), be16(0), be32(0))
    }

    /// The Orientation in a TIFF block, read with code that is NOT the one under test.
    private func orientation(inTiff block: [UInt8]) -> Int? {
        guard block.count >= 8 else { return nil }
        let little = block[0] == 0x49
        func word(_ index: Int) -> Int {
            let first = Int(block[index])
            let second = Int(block[index + 1])
            return little ? (first + 256 * second) : (256 * first + second)
        }
        func long(_ index: Int) -> Int {
            let low = word(little ? index : index + 2)
            let high = word(little ? index + 2 : index)
            return low + 65536 * high
        }
        let ifd = long(4)
        guard ifd + 2 <= block.count else { return nil }
        for entry in 0..<word(ifd) {
            let at = ifd + 2 + 12 * entry
            guard at + 12 <= block.count else { return nil }
            if word(at) == 0x0112 { return word(at + 8) }
        }
        return nil
    }

    // MARK: JPEG

    private func seg(_ marker: Int, _ payload: [UInt8]) -> [UInt8] {
        cat(bytes(0xFF, marker), be16(payload.count + 2), payload)
    }

    private var soi: [UInt8] { bytes(0xFF, 0xD8) }
    private var eoi: [UInt8] { bytes(0xFF, 0xD9) }
    private var sof0: [UInt8] { seg(0xC0, bytes(8, 0, 16, 0, 16, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1)) }
    private var dqt: [UInt8] { seg(0xDB, cat(bytes(0), (0..<64).map { UInt8(truncatingIfNeeded: $0 + 1) })) }
    private var dht: [UInt8] { seg(0xC4, cat(bytes(0), (0..<16).map { UInt8(truncatingIfNeeded: $0 % 3) }, bytes(1, 2, 3, 4))) }
    private var dri: [UInt8] { seg(0xDD, bytes(0, 8)) }
    private var icc: [UInt8] { seg(0xE2, cat(ascii("ICC_PROFILE"), bytes(0), bytes(1, 1), ascii("ICC-BODY-KEPT"))) }
    private var adobe: [UInt8] { seg(0xEE, cat(ascii("Adobe"), bytes(0, 100, 0, 0, 0, 0, 1))) }
    private var sos: [UInt8] { seg(0xDA, bytes(3, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3F, 0)) }
    private var exifId: [UInt8] { cat(ascii("Exif"), bytes(0, 0)) }

    /// Entropy-coded data: stuffed 0xFF00, restart markers and fill bytes before the EOI, like a real scan. The bytes of the "picture"
    /// never hold 0xFF, so they cannot be taken for a marker.
    private func scan(_ size: Int = 150) -> [UInt8] {
        var state: UInt32 = 7
        var output: [UInt8] = []
        for index in 0..<3 {
            for _ in 0..<(size / 3) {
                state = state &* 1_664_525 &+ 1_013_904_223
                output.append(UInt8(truncatingIfNeeded: (state >> 16) % 255))
            }
            output.append(contentsOf: bytes(0xFF, 0x00))
            output.append(contentsOf: bytes(0xFF, 0xD0 + index))
        }
        output.append(contentsOf: bytes(0xFF, 0xFF)) // fill bytes before the marker
        return output
    }

    private func jfif(thumbnail: Bool) -> [UInt8] {
        let thumb: [UInt8] = thumbnail ? cat(bytes(2, 2), [UInt8](repeating: 9, count: 12)) : bytes(0, 0)
        return seg(0xE0, cat(ascii("JFIF"), bytes(0), bytes(1, 1, 1), be16(72), be16(72), thumb))
    }

    private var jfifClean: [UInt8] {
        seg(0xE0, cat(ascii("JFIF"), bytes(0), bytes(1, 1, 1), be16(72), be16(72), bytes(0, 0)))
    }

    private var xmpSegment: [UInt8] {
        let packet = "<x:xmpmeta><exif:GPSLatitude>45,30N</exif:GPSLatitude>XMP-SECRET</x:xmpmeta>"
        return seg(0xE1, cat(ascii("http://ns.adobe.com/xap/1.0/"), bytes(0), ascii(packet)))
    }

    private var photoshopSegment: [UInt8] {
        seg(0xED, cat(ascii("Photoshop 3.0"), bytes(0), ascii("8BIM"), ascii("IPTC-CAPTION-SECRET")))
    }

    private var commentSegment: [UInt8] { seg(0xFE, ascii("COMMENT-SECRET")) }

    private var multiPictureSegment: [UInt8] { seg(0xE2, cat(ascii("MPF"), bytes(0), ascii("MPF-SECRET"))) }

    private struct Jpeg {
        let input: [UInt8]
        let expected: [UInt8]
        let eoiEnd: Int
    }

    private func jpeg(littleEndian: Bool, orientation: Int?, thumbnail: Bool = false, scanSize: Int = 150) -> Jpeg {
        let exifSegment = seg(0xE1, cat(exifId, tiff(littleEndian: littleEndian, orientation: orientation)))
        let pixels = scan(scanSize)
        let input = cat(
            soi, jfif(thumbnail: thumbnail), exifSegment, xmpSegment, photoshopSegment, commentSegment, multiPictureSegment,
            icc, adobe, dqt, sof0, dht, dri, sos, pixels, eoi, trailer)
        var minimalExif: [UInt8] = []
        if let orientation, (2...8).contains(orientation) { minimalExif = seg(0xE1, cat(exifId, minimalTiff(orientation))) }
        let expected = cat(soi, jfifClean, minimalExif, icc, adobe, dqt, sof0, dht, dri, sos, pixels, eoi)
        return Jpeg(input: input, expected: expected, eoiEnd: input.count - trailer.count)
    }

    /// The Orientation a JPEG says it has, read from its first Exif segment (nil when it has none).
    private func orientation(ofJpeg file: [UInt8]) -> Int? {
        var at = 2
        while at + 4 <= file.count, file[at] == 0xFF, file[at + 1] != 0xDA {
            let length = Int(file[at + 2]) * 256 + Int(file[at + 3])
            if file[at + 1] == 0xE1, at + 2 + length <= file.count {
                let payload = Array(file[(at + 4)..<(at + 2 + length)])
                if payload.starts(with: exifId) { return orientation(inTiff: Array(payload.dropFirst(exifId.count))) }
            }
            at += 2 + length
        }
        return nil
    }

    func test_aJpegComesOutWithNoMetadata_theScanUnchanged_andOnlyTheOrientationKept_bigEndian() throws {
        let j = jpeg(littleEndian: false, orientation: 6)
        let out = try strip(j.input)
        XCTAssertEqual(out, j.expected, "exactly the kept segments, the Exif reduced to the orientation, nothing after the EOI")
        assertNoSecrets(out)
        XCTAssertEqual(try stripFormat(j.input), .jpeg)
    }

    func test_aLittleEndianExifWithOrientation8IsRewrittenWithThatOrientation() throws {
        let j = jpeg(littleEndian: true, orientation: 8)
        let out = try strip(j.input)
        XCTAssertEqual(out, j.expected)
        assertNoSecrets(out)
        XCTAssertEqual(orientation(ofJpeg: out), 8)
    }

    func test_everyOrientationFromOneToEightIsKept_inAJpeg() throws {
        for value in 1...8 {
            let j = jpeg(littleEndian: value % 2 == 0, orientation: value)
            let out = try strip(j.input)
            XCTAssertEqual(out, j.expected, "orientation \(value)")
            XCTAssertEqual(orientation(ofJpeg: out) ?? 1, value, "orientation \(value) is still there (1 is the default)")
            assertNoSecrets(out)
        }
        let upright = try strip(jpeg(littleEndian: false, orientation: 1).input)
        XCTAssertNil(indexOf(upright, ascii("Exif")), "no Exif block when the picture is upright")
        let none = jpeg(littleEndian: false, orientation: nil)
        XCTAssertEqual(try strip(none.input), none.expected)
    }

    func test_theMinimalExifIsExactly26BytesOfTiff() throws {
        let turned = try strip(jpeg(littleEndian: false, orientation: 6).input)
        let upright = try strip(jpeg(littleEndian: false, orientation: nil).input)
        // marker (2) + length (2) + "Exif" and two zero bytes (6) + the TIFF block
        XCTAssertEqual(turned.count - upright.count, 2 + 2 + 6 + ImageMetadataStripper.minimalTiffBytes)
        XCTAssertEqual(ImageMetadataStripper.minimalTiffBytes, 26)
        XCTAssertEqual(ImageMetadataStripper.minimalTiff(6).count, 26)
        XCTAssertEqual(ImageMetadataStripper.minimalTiff(6), minimalTiff(6))
    }

    func test_anOrientationOutsideOneToEight_isNotCopied() throws {
        for value in [0, 9, 255, 65_535] {
            let j = jpeg(littleEndian: false, orientation: value)
            let out = try strip(j.input)
            XCTAssertEqual(out, j.expected, "value \(value)")
            XCTAssertNil(indexOf(out, ascii("Exif")))
        }
    }

    func test_aJfifThumbnailIsDropped_andAFileWithoutMetadataComesOutByteForByte() throws {
        let withThumbnail = jpeg(littleEndian: false, orientation: nil, thumbnail: true)
        XCTAssertEqual(try strip(withThumbnail.input), withThumbnail.expected)
        let plain = cat(soi, jfifClean, dqt, sof0, dht, sos, scan(), eoi)
        XCTAssertEqual(try strip(plain), plain, "nothing to remove: nothing changes")
    }

    func test_aProgressiveJpegWithSeveralScansKeepsAllOfThem() throws {
        let progressive = seg(0xC2, bytes(8, 0, 16, 0, 16, 1, 1, 0x11, 0))
        let input = cat(soi, progressive, dht, sos, scan(60), dht, sos, scan(90), eoi)
        XCTAssertEqual(try strip(input), input)
    }

    func test_theScanBytesAreIdenticalToTheOriginal_markerForMarker() throws {
        let j = jpeg(littleEndian: false, orientation: 6, scanSize: 3000)
        let out = try strip(j.input)
        let scanBlock = cat(sos, scan(3000), eoi)
        let found = try XCTUnwrap(indexOf(j.input, scanBlock))
        XCTAssertEqual(found, j.input.count - trailer.count - scanBlock.count)
        XCTAssertEqual(Array(out.suffix(scanBlock.count)), scanBlock)
    }

    func test_aHostileExifIsSkippedNotTrusted() throws {
        let hostile: [[UInt8]] = [
            cat(ascii("MM"), be16(42), be32(0xFFFF_FFF0)), // IFD0 far outside the block
            cat(ascii("II"), le16(42), le32(8), le16(65_535)), // 65535 entries and none of them present
            cat(ascii("MM"), be16(42), be32(8), be16(1), be16(0x0112), be16(3), be32(1000), be16(6), be16(0), be32(0)), // count 1000
            cat(ascii("MM"), be16(42), be32(8), be16(1), be16(0x0112), be16(4), be32(1), be32(6), be32(0)), // LONG, not SHORT
            cat(ascii("XX"), be16(42), be32(8)), // no byte order
            []
        ]
        for (index, block) in hostile.enumerated() {
            let input = cat(soi, seg(0xE1, cat(exifId, block)), dqt, sof0, sos, scan(), eoi)
            XCTAssertEqual(try strip(input), cat(soi, dqt, sof0, sos, scan(), eoi), "hostile Exif #\(index)")
        }
    }

    func test_everyPrefixOfAJpegThatStopsBeforeItsEoiIsRefused_neverReturnedAsIs() throws {
        let j = jpeg(littleEndian: false, orientation: 6, scanSize: 90)
        for length in 0..<j.eoiEnd {
            assertRefused(Array(j.input.prefix(length)), "a JPEG cut at \(length) of \(j.eoiEnd) must not be accepted")
        }
        // cut after the EOI: the trailer was only junk
        XCTAssertEqual(try strip(Array(j.input.prefix(j.eoiEnd))), j.expected)
    }

    func test_hostileJpegSegmentLengthsAreRefused() {
        assertMalformed(cat(soi, bytes(0xFF, 0xE1, 0xFF, 0xFF), ascii("Exif"), bytes(0, 0), ascii("short")), "length past the end")
        assertMalformed(cat(soi, bytes(0xFF, 0xE1, 0, 0), ascii("Exif")), "length 0")
        assertMalformed(cat(soi, bytes(0xFF, 0xE1, 0, 1), ascii("Exif")), "length 1")
        assertMalformed(cat(soi, bytes(0xFF, 0xDB, 0, 1), dqt), "a kept segment with length 1")
        assertMalformed(cat(soi, bytes(0x00, 0x11, 0x22)), "bytes that are not a marker")
        assertMalformed(cat(soi, sof0, sos, bytes(0xFF, 0xE1, 0xFF, 0xFF)), "a marker with a length past the end after the scan")
        assertMalformed(soi, "nothing after the SOI")
        assertMalformed(cat(soi, soi, dqt), "a second SOI")
    }

    func test_aFloodOfKeptJpegSegmentsIsRefusedBeforeItEatsTheMemory() {
        let one = seg(0xE2, cat(ascii("ICC_PROFILE"), bytes(0), bytes(1, 200), zeros(65_000)))
        var input = soi
        for _ in 0..<140 { input.append(contentsOf: one) } // about 9 MB of profile, more than any picture needs
        input.append(contentsOf: cat(sof0, sos, scan(), eoi))
        assertMalformed(input, "profile flood")
    }

    // MARK: PNG

    /// CRC-32 of PNG (bitwise, so that it shares nothing with the table of the code under test).
    private func crc(_ parts: [UInt8]...) -> Int {
        var value: UInt32 = 0xFFFF_FFFF
        for part in parts {
            for byte in part {
                value ^= UInt32(byte)
                for _ in 0..<8 {
                    value = (value & 1) != 0 ? ((value >> 1) ^ 0xEDB8_8320) : (value >> 1)
                }
            }
        }
        return Int(value ^ 0xFFFF_FFFF)
    }

    private func pngChunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        cat(be32(data.count), ascii(type), data, be32(crc(ascii(type), data)))
    }

    private var pngSignature: [UInt8] { bytes(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) }
    private var ihdr: [UInt8] { pngChunk("IHDR", cat(be32(16), be32(16), bytes(8, 2, 0, 0, 0))) }
    private var phys: [UInt8] { pngChunk("pHYs", cat(be32(2835), be32(2835), bytes(1))) }
    private var iccp: [UInt8] { pngChunk("iCCP", cat(ascii("ICC-NAME"), bytes(0, 0), [UInt8](repeating: 5, count: 20))) }
    private var idat1: [UInt8] { pngChunk("IDAT", (0..<100).map { UInt8(truncatingIfNeeded: $0 * 7) }) }
    private var idat2: [UInt8] { pngChunk("IDAT", (0..<33).map { UInt8(truncatingIfNeeded: $0 * 3) }) }
    private var iend: [UInt8] { pngChunk("IEND", []) }

    private func png(orientation: Int?) -> (input: [UInt8], expected: [UInt8]) {
        let input = cat(
            pngSignature, ihdr,
            pngChunk("tEXt", cat(ascii("Author"), bytes(0), ascii("CanonXYZ-Make GPS 45N"))),
            pngChunk("zTXt", cat(ascii("Comment"), bytes(0, 0), ascii("COMMENT-SECRET"))),
            pngChunk("iTXt", cat(ascii("XML:com.adobe.xmp"), bytes(0, 0, 0, 0, 0), ascii("XMP-SECRET"))),
            pngChunk("tIME", bytes(7, 234, 10, 7, 12, 34, 56)),
            pngChunk("eXIf", tiff(littleEndian: false, orientation: orientation)), phys, iccp,
            pngChunk("prVt", ascii("private-secret")),
            idat1, idat2, iend, trailer)
        var exif: [UInt8] = []
        if let orientation, (2...8).contains(orientation) { exif = pngChunk("eXIf", minimalTiff(orientation)) }
        return (input, cat(pngSignature, ihdr, exif, phys, iccp, idat1, idat2, iend))
    }

    /// The Orientation a PNG says it has, from its eXIf chunk (nil when it has none).
    private func orientation(ofPng file: [UInt8]) -> Int? {
        var at = 8
        while at + 12 <= file.count {
            let length = Int(file[at]) * 16_777_216 + Int(file[at + 1]) * 65_536 + Int(file[at + 2]) * 256 + Int(file[at + 3])
            let type = String(decoding: file[(at + 4)..<(at + 8)], as: UTF8.self)
            if type == "eXIf", at + 8 + length <= file.count { return orientation(inTiff: Array(file[(at + 8)..<(at + 8 + length)])) }
            at += 12 + length
        }
        return nil
    }

    func test_aPngLosesItsTextTimeAndExifChunks_butKeepsTheOrientationTheProfileAndEveryIdat() throws {
        let (input, expected) = png(orientation: 6)
        let out = try strip(input)
        XCTAssertEqual(out, expected)
        assertNoSecrets(out)
        XCTAssertEqual(try stripFormat(input), .png)
        XCTAssertEqual(orientation(ofPng: out), 6)
    }

    func test_everyOrientationFromOneToEightIsKept_inAPng() throws {
        for value in 1...8 {
            let (input, expected) = png(orientation: value)
            let out = try strip(input)
            XCTAssertEqual(out, expected, "orientation \(value)")
            XCTAssertEqual(orientation(ofPng: out) ?? 1, value, "orientation \(value) is still there (1 is the default)")
            assertNoSecrets(out)
        }
    }

    func test_aPngWithoutAnOrientationGetsNoExifAtAll() throws {
        let (input, expected) = png(orientation: nil)
        let out = try strip(input)
        XCTAssertEqual(out, expected)
        XCTAssertNil(indexOf(out, ascii("eXIf")))
    }

    func test_everyPrefixOfAPngThatStopsBeforeItsIendIsRefused_andHostileChunkLengthsToo() {
        let (input, _) = png(orientation: 6)
        let end = input.count - trailer.count
        for length in 0..<end {
            assertRefused(Array(input.prefix(length)), "a PNG cut at \(length) must not be accepted")
        }
        assertMalformed(cat(pngSignature, bytes(0x7F, 0xFF, 0xFF, 0xFF), ascii("IDAT"), zeros(10)), "IDAT longer than the file, and not an IHDR first")
        assertMalformed(cat(pngSignature, ihdr, bytes(0xFF, 0xFF, 0xFF, 0xFF), ascii("IDAT"), zeros(10)), "a length above 2^31-1")
        assertMalformed(cat(pngSignature, ihdr, bytes(0x7F, 0xFF, 0xFF, 0xFF), ascii("eXIf"), zeros(10)), "an eXIf longer than the file")
        assertMalformed(cat(pngSignature, idat1, iend), "the first chunk is not IHDR")
        assertMalformed(cat(pngSignature, ihdr, bytes(0, 0, 0, 1), bytes(0x49, 0x44, 0x41, 0x31), zeros(5), iend), "a chunk type with a digit")
    }

    // MARK: WEBP

    private func riff(_ chunk: String, _ data: [UInt8]) -> [UInt8] {
        cat(ascii(chunk), le32(data.count), data, data.count % 2 == 1 ? bytes(0) : [])
    }

    private func webpFile(_ chunks: [UInt8]...) -> [UInt8] {
        let body = cat(ascii("WEBP"), chunks.flatMap { $0 })
        return cat(ascii("RIFF"), le32(body.count), body)
    }

    private func vp8x(_ flags: Int) -> [UInt8] { riff("VP8X", cat(bytes(flags, 0, 0, 0), bytes(15, 0, 0), bytes(15, 0, 0))) }
    private var iccpChunk: [UInt8] { riff("ICCP", ascii("ICC-BODY-KEPT")) }
    private var vp8: [UInt8] { riff("VP8 ", (0..<5).map { UInt8(truncatingIfNeeded: $0 + 40) }) } // odd size: carries a pad byte
    private var alph: [UInt8] { riff("ALPH", [UInt8](repeating: 3, count: 8)) }

    private func webp(orientation: Int?) -> (input: [UInt8], expected: [UInt8]) {
        let inputFile = webpFile(
            vp8x(0x3C), iccpChunk, alph, vp8,
            riff("EXIF", tiff(littleEndian: true, orientation: orientation)),
            riff("XMP ", ascii("<x:xmpmeta>XMP-SECRET</x:xmpmeta>")),
            riff("ZZZZ", ascii("COMMENT-SECRET")))
        let hasOrientation = orientation.map { (2...8).contains($0) } ?? false
        let flags = hasOrientation ? 0x38 : 0x30
        let exif: [UInt8] = hasOrientation ? riff("EXIF", minimalTiff(orientation ?? 1)) : []
        return (cat(inputFile, trailer), webpFile(vp8x(flags), iccpChunk, alph, vp8, exif))
    }

    /// The Orientation a WEBP says it has, from its EXIF chunk (nil when it has none).
    private func orientation(ofWebp file: [UInt8]) -> Int? {
        var at = 12
        while at + 8 <= file.count {
            let size = Int(file[at + 4]) + 256 * Int(file[at + 5]) + 65_536 * Int(file[at + 6]) + 16_777_216 * Int(file[at + 7])
            let name = String(decoding: file[at..<(at + 4)], as: UTF8.self)
            if name == "EXIF", at + 8 + size <= file.count { return orientation(inTiff: Array(file[(at + 8)..<(at + 8 + size)])) }
            at += 8 + size + (size % 2)
        }
        return nil
    }

    func test_aWebpLosesItsExifAndXmpChunks_itsFlagsAndRiffSizeFollow_theOrientationIsKept() throws {
        let (input, expected) = webp(orientation: 8)
        let out = try strip(input)
        XCTAssertEqual(out, expected)
        assertNoSecrets(out)
        let riffSize = Int(out[4]) + 256 * Int(out[5]) + 65_536 * Int(out[6]) + 16_777_216 * Int(out[7])
        XCTAssertEqual(riffSize, out.count - 8, "RIFF size is the file minus 8")
        XCTAssertEqual(try stripFormat(input), .webp)
        XCTAssertEqual(orientation(ofWebp: out), 8)
    }

    func test_everyOrientationFromOneToEightIsKept_inAWebp() throws {
        for value in 1...8 {
            let (input, expected) = webp(orientation: value)
            let out = try strip(input)
            XCTAssertEqual(out, expected, "orientation \(value)")
            XCTAssertEqual(orientation(ofWebp: out) ?? 1, value, "orientation \(value) is still there (1 is the default)")
            assertNoSecrets(out)
        }
    }

    func test_aWebpWithoutAnOrientationHasNoExifFlagAndNoExifChunk() throws {
        let (input, expected) = webp(orientation: nil)
        let out = try strip(input)
        XCTAssertEqual(out, expected)
        XCTAssertNil(indexOf(out, ascii("EXIF")))
        XCTAssertEqual(out[20] & 0x0C, 0, "the flags byte of the VP8X chunk says neither Exif nor XMP")
    }

    func test_aSimpleLossyWebpOnlyLosesWhatFollowsTheDeclaredEnd() throws {
        let plain = webpFile(vp8)
        XCTAssertEqual(try strip(cat(plain, trailer)), plain)
    }

    func test_everyPrefixOfAWebpThatStopsBeforeItsEndIsRefused_andHostileSizesToo() {
        let (input, _) = webp(orientation: 8)
        let end = input.count - trailer.count
        for length in 0..<end {
            assertRefused(Array(input.prefix(length)), "a WEBP cut at \(length) must not be accepted")
        }
        assertMalformed(cat(ascii("RIFF"), le32(3), ascii("WEBP")), "RIFF size below the header")
        assertMalformed(cat(ascii("RIFF"), le32(1000), ascii("WEBP"), ascii("VP8 "), le32(0xFFFF_FFFF), zeros(4)), "chunk size 4 GiB")
        assertMalformed(cat(ascii("RIFF"), le32(20), ascii("WEBP"), ascii("EXIF"), le32(500), zeros(4)), "EXIF longer than the file")
    }

    // MARK: GIF

    func test_aGifLosesItsCommentsTextAndXmp_butKeepsItsFramesAndItsLoopCount() throws {
        let head = cat(ascii("GIF89a"), le16(2), le16(2), bytes(0x80, 0, 0), bytes(0, 0, 0, 255, 255, 255))
        let netscape = cat(bytes(0x21, 0xFF, 0x0B), ascii("NETSCAPE2.0"), bytes(3, 1, 0, 0, 0))
        let xmpExtension = cat(bytes(0x21, 0xFF, 0x0B), ascii("XMP DataXMP"), bytes(10), ascii("XMP-SECRET"), bytes(0))
        let comment = cat(bytes(0x21, 0xFE, 14), ascii("COMMENT-SECRET"), bytes(0))
        let plainText = cat(bytes(0x21, 0x01, 12), zeros(12), bytes(16), ascii("PLAINTEXT-SECRET"), bytes(0))
        let control = bytes(0x21, 0xF9, 4, 0, 10, 0, 0, 0)
        let frame = cat(bytes(0x2C), le16(0), le16(0), le16(2), le16(2), bytes(0, 2, 2, 0x4C, 1, 0))
        let input = cat(head, netscape, xmpExtension, comment, plainText, control, frame, bytes(0x3B), trailer)
        let out = try strip(input)
        XCTAssertEqual(out, cat(head, netscape, control, frame, bytes(0x3B)))
        assertNoSecrets(out)
        XCTAssertEqual(try stripFormat(input), .gif)
        for length in 0..<(input.count - trailer.count) {
            assertRefused(Array(input.prefix(length)), "a GIF cut at \(length) must not be accepted")
        }
    }

    // MARK: What is not handled, and what every output looks like

    func test_aFormatThatIsNotHandledIsReportedAsUnsupported_neverCopied() {
        let inputs: [[UInt8]] = [
            cat(bytes(0, 0, 0, 0x18), ascii("ftypheic"), zeros(40)), // HEIC
            cat(bytes(0, 0, 0, 0x1C), ascii("ftypavif"), zeros(40)), // AVIF
            cat(ascii("II"), le16(42), le32(8), zeros(40)), // TIFF
            ascii("<svg xmlns='http://www.w3.org/2000/svg'/>"),
            ascii("plain text"),
            ascii("%PDF-1.7"),
            []
        ]
        for (index, input) in inputs.enumerated() {
            XCTAssertThrowsError(try strip(input), "input #\(index) must not be accepted") { error in
                XCTAssertEqual(error as? ImageMetadataError, .unsupportedFormat, "input #\(index)")
            }
        }
    }

    func test_theOutputStartsWithTheMagicOfItsFormat() throws {
        let jpegOut = try strip(jpeg(littleEndian: false, orientation: 6).input)
        XCTAssertEqual(Array(jpegOut.prefix(3)), bytes(0xFF, 0xD8, 0xFF))
        XCTAssertEqual(Array(jpegOut.suffix(2)), eoi)
        let pngOut = try strip(png(orientation: 6).input)
        XCTAssertEqual(Array(pngOut.prefix(8)), pngSignature)
        XCTAssertEqual(Array(pngOut.suffix(12)), iend)
        let webpOut = try strip(webp(orientation: 6).input)
        XCTAssertEqual(Array(webpOut.prefix(4)), ascii("RIFF"))
        XCTAssertEqual(Array(webpOut[8..<12]), ascii("WEBP"))
        let gifIn = cat(ascii("GIF87a"), le16(1), le16(1), bytes(0, 0, 0), bytes(0x2C), le16(0), le16(0), le16(1), le16(1),
                        bytes(0, 2, 2, 0x4C, 1, 0), bytes(0x3B))
        let gifOut = try strip(gifIn)
        XCTAssertEqual(Array(gifOut.prefix(6)), ascii("GIF87a"))
        XCTAssertEqual(gifOut, gifIn)
    }

    func test_strippingAStrippedPictureChangesNothing() throws {
        let inputs: [[UInt8]] = [
            jpeg(littleEndian: false, orientation: 6).input,
            png(orientation: 3).input,
            webp(orientation: 8).input
        ]
        for input in inputs {
            let once = try strip(input)
            XCTAssertEqual(try strip(once), once)
        }
    }

    func test_theFormatIsRecognisedFromTheFirstBytes_andAnImageThatIsNotHandledStillLooksLikeOne() {
        XCTAssertEqual(ImageMetadataStripper.sniff(Data(jpeg(littleEndian: false, orientation: nil).input)), .jpeg)
        XCTAssertEqual(ImageMetadataStripper.sniff(Data(png(orientation: nil).input)), .png)
        XCTAssertEqual(ImageMetadataStripper.sniff(Data(webp(orientation: nil).input)), .webp)
        XCTAssertEqual(ImageMetadataStripper.sniff(Data(ascii("GIF89a"))), .gif)
        XCTAssertNil(ImageMetadataStripper.sniff(Data(cat(bytes(0, 0, 0, 0x18), ascii("ftypheic")))))
        XCTAssertNil(ImageMetadataStripper.sniff(Data()))

        XCTAssertTrue(ImageMetadataStripper.looksLikePicture(Data(cat(bytes(0, 0, 0, 0x18), ascii("ftypheic"), zeros(8)))))
        XCTAssertTrue(ImageMetadataStripper.looksLikePicture(Data(cat(bytes(0, 0, 0, 0x1C), ascii("ftypavif"), zeros(8)))))
        XCTAssertTrue(ImageMetadataStripper.looksLikePicture(Data(cat(ascii("II"), le16(42), le32(8)))))
        XCTAssertTrue(ImageMetadataStripper.looksLikePicture(Data(cat(ascii("MM"), be16(42), be32(8)))))
        XCTAssertTrue(ImageMetadataStripper.looksLikePicture(Data(png(orientation: nil).input)))
        // a video, a document and a text are not pictures
        XCTAssertFalse(ImageMetadataStripper.looksLikePicture(Data(cat(bytes(0, 0, 0, 0x18), ascii("ftypisom"), zeros(8)))))
        XCTAssertFalse(ImageMetadataStripper.looksLikePicture(Data(ascii("%PDF-1.7 and more"))))
        XCTAssertFalse(ImageMetadataStripper.looksLikePicture(Data(ascii("plain text, not a picture"))))
        XCTAssertFalse(ImageMetadataStripper.looksLikePicture(Data()))
    }

    func test_aPictureThatCannotBeCleanedHasItsOwnFailureCode() {
        let failure = FileV2Failure(.imageNotCleanable)
        XCTAssertEqual(failure.code, "image_not_cleanable")
        XCTAssertEqual(failure, FileV2Failure(.imageNotCleanable))
        XCTAssertNotEqual(failure, FileV2Failure(.unreadable))
    }
}
