import Foundation

// Removes the metadata of a picture (GPS position, device identifiers, time, thumbnail, maker note, XMP, IPTC, comments) from the
// BYTES of the file, without decoding the picture. A pure function of the input: no I/O, no UIKit, no ImageIO, no clock, no
// randomness, and nothing is ever logged. The app calls it before an image is sealed and uploaded (WIRE_SPEC section 12), so that
// the file the receiver gets is a cleaned COPY and the original never leaves the device. It is the Swift port of the
// `ImageMetadataStripper` the Android app ships; both apps keep the same lists of what stays, so a picture leaves a phone the same
// way whichever phone it is.

/// The container formats `ImageMetadataStripper` copies without decoding the pixels.
public enum PictureFormat: String, Equatable, Sendable {
    case jpeg
    case png
    case webp
    case gif
}

/// Why `ImageMetadataStripper.strip` gave no picture. The caller must NOT send the original in either case. The text of
/// `malformed` is one of a fixed set of phrases and never holds a byte of the file.
public enum ImageMetadataError: Error, Equatable, Sendable {
    /// Not one of the four formats (HEIC, AVIF, TIFF, BMP, SVG, text...): the platform image codec has to re-encode it.
    case unsupportedFormat
    /// One of the four formats, but not well formed (truncated, a length that does not fit, a chunk where none can be).
    case malformed(String)
}

/// A picture without its metadata, and the format it is in.
public struct StrippedImage: Equatable, Sendable {
    public let format: PictureFormat
    public let data: Data

    public init(format: PictureFormat, data: Data) {
        self.format = format
        self.data = data
    }
}

/// Writes a copy of a picture without the metadata of the camera and of the editors, WITHOUT decoding the picture: the compressed
/// data (the scans of a JPEG, the IDAT chunks of a PNG, the bitstream of a WEBP, the frames of a GIF) is copied byte for byte, so
/// there is no loss and no change of colours.
///
/// Removed: GPS position, device identifiers (make, model, serial numbers, lens), software, dates, the thumbnail inside Exif, the
/// maker note, XMP (also the extended one), IPTC / Photoshop resources, comments, the JFIF thumbnail, the multi-picture block, and
/// everything stored AFTER the end of the picture (the video of a motion photo). Kept: what is needed to decode and show the
/// picture: the colour profile (ICC), the Adobe marker (colour transform of CMYK), the density, the PNG transparency and animation
/// chunks, the GIF loop count and, of every Exif, only the Orientation, written again as the one entry of a new, minimal Exif
/// (`minimalTiffBytes` bytes): a picture that is turned by its Orientation must still be shown the right way up, and rotating the
/// pixels would mean decoding and encoding them again. An upright picture (Orientation 1, or none) gets no Exif at all.
///
/// Handled: JPEG, PNG, WEBP, GIF. Everything else is `ImageMetadataError.unsupportedFormat`.
///
/// The lengths of the file are read as hostile: each one is checked against what is left, a kept segment is read in memory only up
/// to 64 KiB (a JPEG segment cannot be more) and the sum of what is kept before the first scan is capped; the data of the picture
/// is copied in blocks. The input and the output are both held in memory (the caller limits the size of what it hands over).
public enum ImageMetadataStripper {

    /// The Exif written for a picture that has an Orientation to keep: TIFF header, IFD0 with one entry, no next IFD.
    public static let minimalTiffBytes = 26

    /// Most bytes a JPEG may have kept before its first scan (the colour profile and the tables are all that is kept there).
    static let maxKeptBeforeScan = 8 * 1024 * 1024
    /// Largest Exif / eXIf / EXIF block that is read to look for its Orientation.
    static let maxExifRead = 1 << 20

    // MARK: What the file is

    /// The format named by the first bytes of `data`, or `nil` when it is none of the four.
    public static func sniff(_ data: Data) -> PictureFormat? {
        sniff(Array(data.prefix(12)))
    }

    static func sniff(_ head: [UInt8]) -> PictureFormat? {
        if head.count >= 2, head[0] == 0xFF, head[1] == 0xD8 { return .jpeg }
        if head.starts(with: pngSignature) { return .png }
        if head.count >= 12, head.starts(with: riffTag), Array(head[8..<12]) == webpTag { return .webp }
        if head.starts(with: gif87Tag) || head.starts(with: gif89Tag) { return .gif }
        return nil
    }

    /// Whether the first bytes of a file say it is a picture: one of the four formats, or HEIF / AVIF (an `ftyp` box with an image
    /// brand) or TIFF. For a file whose name does not say what it is. The app re-encodes the ones this class does not handle.
    public static func looksLikePicture(_ head: Data) -> Bool {
        let bytes = Array(head.prefix(12))
        if sniff(bytes) != nil { return true }
        if bytes.count >= 12, Array(bytes[4..<8]) == ftypTag, imageBrands.contains(Array(bytes[8..<12])) { return true }
        if bytes.starts(with: tiffLittleEndian) || bytes.starts(with: tiffBigEndian) { return true }
        return false
    }

    // MARK: The cleaning

    /// A copy of `input` without metadata. On any failure the error says why and nothing of the input is returned.
    public static func strip(_ input: Data) throws -> StrippedImage {
        guard let format = sniff(input) else { throw ImageMetadataError.unsupportedFormat }
        let output: [UInt8] = try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [UInt8] in
            var cursor = ImageCursor(raw)
            switch format {
            case .jpeg: try stripJpeg(&cursor)
            case .png: try stripPng(&cursor)
            case .webp: try stripWebp(&cursor)
            case .gif: try stripGif(&cursor)
            }
            return cursor.out
        }
        return StrippedImage(format: format, data: Data(output))
    }

    // MARK: The Orientation

    /// The Orientation (1...8) in the TIFF structure at `b[offset ..< offset + length]`, or 0 when there is none or the structure is
    /// not trustworthy. Only IFD0 is read; every offset and count is checked against `length` before it is used.
    static func orientationOfTiff(_ b: [UInt8], offset off: Int, length len: Int) -> Int {
        guard off >= 0, len >= 8, off + len <= b.count else { return 0 }
        let littleEndian: Bool
        if b[off] == 0x49 && b[off + 1] == 0x49 {
            littleEndian = true
        } else if b[off] == 0x4D && b[off + 1] == 0x4D {
            littleEndian = false
        } else {
            return 0
        }
        func u16(_ p: Int) -> Int {
            let x = Int(b[off + p])
            let y = Int(b[off + p + 1])
            return littleEndian ? (x | (y << 8)) : ((x << 8) | y)
        }
        func u32(_ p: Int) -> Int {
            var v = 0
            for k in 0..<4 {
                let byte = Int(b[off + p + k])
                v = littleEndian ? (v | (byte << (8 * k))) : ((v << 8) | byte)
            }
            return v
        }
        if u16(2) != 42 { return 0 }
        let ifd = u32(4)
        if ifd < 8 || ifd + 2 > len { return 0 }
        let count = u16(ifd)
        var p = ifd + 2
        var index = 0
        while index < count {
            if p + 12 > len { return 0 }
            if u16(p) == 0x0112 {
                if u16(p + 2) != 3 || u32(p + 4) != 1 { return 0 }
                let value = u16(p + 8)
                return (1...8).contains(value) ? value : 0
            }
            p += 12
            index += 1
        }
        return 0
    }

    /// The minimal TIFF: big endian, one entry, Orientation as a SHORT.
    static func minimalTiff(_ orientation: Int) -> [UInt8] {
        let tiff: [UInt8] = [
            0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08,
            0x00, 0x01,
            0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, UInt8(truncatingIfNeeded: orientation), 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00
        ]
        return tiff
    }
}

// MARK: - Constants

private func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

private let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
private let riffTag = ascii("RIFF")
private let webpTag = ascii("WEBP")
private let exifTag = ascii("EXIF")
private let gif87Tag = ascii("GIF87a")
private let gif89Tag = ascii("GIF89a")
private let ftypTag = ascii("ftyp")
private let exifHeader: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00] // "Exif" and two zero bytes
private let jfifId: [UInt8] = [0x4A, 0x46, 0x49, 0x46, 0x00] // "JFIF" and a zero byte
private let iccId: [UInt8] = ascii("ICC_PROFILE") + [0x00]
private let adobeId = ascii("Adobe")
private let netscapeId = ascii("NETSCAPE2.0")
private let animextsId = ascii("ANIMEXTS1.0")
private let tiffLittleEndian: [UInt8] = [0x49, 0x49, 0x2A, 0x00]
private let tiffBigEndian: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A]
private let imageBrands: Set<[UInt8]> = Set(
    ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1", "avif", "avis"].map { ascii($0) })

/// The chunks of a PNG that stay (apart from the critical ones, which all stay): the transparency, the colour description, the
/// density, the palette-related ones and the animation chunks.
private let pngKept: Set<String> = [
    "tRNS", "gAMA", "cHRM", "sRGB", "iCCP", "sBIT", "bKGD", "hIST", "pHYs", "sPLT", "acTL", "fcTL", "fdAT", "cICP", "mDCV", "cLLI"
]

/// The chunks of a WEBP that stay (VP8X is handled apart): the colour profile, the animation and the bitstream.
private let webpKept: Set<String> = ["ICCP", "ANIM", "ANMF", "ALPH", "VP8 ", "VP8L"]

private func bad(_ what: String) -> ImageMetadataError { .malformed(what) }

// MARK: - Input with a cursor, output in memory

private struct ImageCursor {
    let bytes: UnsafeRawBufferPointer
    var pos = 0
    var out: [UInt8] = []

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
        out.reserveCapacity(bytes.count)
    }

    var remaining: Int { bytes.count - pos }

    // Reading

    mutating func u8() throws -> Int {
        guard pos < bytes.count else { throw bad("unexpected end") }
        let value = Int(bytes[pos])
        pos += 1
        return value
    }

    mutating func u16be() throws -> Int {
        let high = try u8()
        let low = try u8()
        return (high << 8) | low
    }

    mutating func u32be() throws -> Int {
        let high = try u16be()
        let low = try u16be()
        return (high << 16) | low
    }

    mutating func u32le() throws -> Int {
        let b0 = try u8()
        let b1 = try u8()
        let b2 = try u8()
        let b3 = try u8()
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw bad("unexpected end") }
        let result = Array(bytes[pos..<(pos + count)])
        pos += count
        return result
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw bad("unexpected end") }
        pos += count
    }

    // Copying input to output

    mutating func copy(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw bad("unexpected end") }
        out.append(contentsOf: bytes[pos..<(pos + count)])
        pos += count
    }

    /// Copies the bytes up to, not including, the next 0xFF; false when the input ends before one.
    mutating func copyUntilFF() -> Bool {
        let start = pos
        while pos < bytes.count && bytes[pos] != 0xFF { pos += 1 }
        if pos > start { out.append(contentsOf: bytes[start..<pos]) }
        return pos < bytes.count
    }

    // Writing

    mutating func put(_ byte: Int) {
        out.append(UInt8(truncatingIfNeeded: byte))
    }

    mutating func put(_ block: [UInt8]) {
        out.append(contentsOf: block)
    }

    mutating func put16be(_ value: Int) {
        put(value >> 8)
        put(value)
    }

    mutating func put32be(_ value: Int) {
        put(value >> 24)
        put(value >> 16)
        put(value >> 8)
        put(value)
    }

    mutating func put32le(_ value: Int) {
        put(value)
        put(value >> 8)
        put(value >> 16)
        put(value >> 24)
    }
}

// MARK: - JPEG

private func putJpegSegment(_ cursor: inout ImageCursor, marker: Int, payload: [UInt8]) {
    cursor.put(0xFF)
    cursor.put(marker)
    cursor.put16be(payload.count + 2)
    cursor.put(payload)
}

private func keepJpegSegment(_ header: inout [UInt8], marker: Int, payload: [UInt8]) throws {
    header.append(0xFF)
    header.append(UInt8(truncatingIfNeeded: marker))
    header.append(UInt8(truncatingIfNeeded: (payload.count + 2) >> 8))
    header.append(UInt8(truncatingIfNeeded: payload.count + 2))
    header.append(contentsOf: payload)
    if header.count > ImageMetadataStripper.maxKeptBeforeScan { throw bad("too much before the scan") }
}

/// The marker after a segment or a scan: 0xFF fill bytes are skipped.
private func nextJpegMarker(_ cursor: inout ImageCursor) throws -> Int {
    guard try cursor.u8() == 0xFF else { throw bad("not a marker") }
    var marker = try cursor.u8()
    while marker == 0xFF { marker = try cursor.u8() }
    if marker == 0 { throw bad("not a marker") }
    return marker
}

/// Copies the entropy-coded data that follows a start-of-scan header, up to the next real marker, which is returned (not written):
/// stuffed 0xFF00 and restart markers belong to the data, runs of 0xFF are fill.
private func copyJpegScan(_ cursor: inout ImageCursor) throws -> Int {
    while true {
        if !cursor.copyUntilFF() { throw bad("scan without end") }
        _ = try cursor.u8() // the 0xFF
        var next = try cursor.u8()
        while next == 0xFF {
            cursor.put(0xFF)
            next = try cursor.u8()
        }
        if next == 0x00 || (0xD0...0xD7).contains(next) {
            cursor.put(0xFF)
            cursor.put(next)
        } else {
            return next
        }
    }
}

private struct JpegHead {
    var header: [UInt8] = []
    var jfif: [UInt8]?
    var exifSeen = false
    var orientation = 0
    var scanStarted = false
}

/// Writes SOI, the JFIF header, the new Exif (if the picture is turned) and what was kept before the scan.
private func startJpegOutput(_ cursor: inout ImageCursor, _ head: inout JpegHead) {
    cursor.put(0xFF)
    cursor.put(0xD8)
    if let jfif = head.jfif { putJpegSegment(&cursor, marker: 0xE0, payload: jfif) }
    if (2...8).contains(head.orientation) {
        putJpegSegment(&cursor, marker: 0xE1, payload: exifHeader + ImageMetadataStripper.minimalTiff(head.orientation))
    }
    cursor.put(head.header)
    head.scanStarted = true
}

/// What an application segment contributes: only four kinds are looked at (they are small, at most 64 KiB, and read whole).
private func handleJpegApplicationSegment(_ marker: Int, _ payload: [UInt8], _ head: inout JpegHead) throws {
    switch marker {
    case 0xE0:
        if !head.scanStarted, head.jfif == nil, payload.count >= 14, payload.starts(with: jfifId) {
            // the JFIF header without its thumbnail (the thumbnail is a second, unmarked picture)
            var kept = Array(payload.prefix(14))
            kept[12] = 0
            kept[13] = 0
            head.jfif = kept
        }
    case 0xE1:
        if !head.exifSeen, payload.starts(with: exifHeader) {
            head.exifSeen = true
            head.orientation = ImageMetadataStripper.orientationOfTiff(
                payload, offset: exifHeader.count, length: payload.count - exifHeader.count)
        }
    case 0xE2:
        if !head.scanStarted, payload.starts(with: iccId) { try keepJpegSegment(&head.header, marker: marker, payload: payload) }
    case 0xEE:
        if !head.scanStarted, payload.starts(with: adobeId) { try keepJpegSegment(&head.header, marker: marker, payload: payload) }
    default:
        break
    }
}

private func stripJpeg(_ cursor: inout ImageCursor) throws {
    let first = try cursor.u8()
    let second = try cursor.u8()
    guard first == 0xFF, second == 0xD8 else { throw bad("no SOI") }
    var head = JpegHead()
    var marker = try nextJpegMarker(&cursor)
    while true {
        if marker == 0xD9 {
            if !head.scanStarted { startJpegOutput(&cursor, &head) }
            cursor.put(0xFF)
            cursor.put(0xD9)
            return
        }
        if marker == 0xD8 { throw bad("a second SOI") }
        if marker == 0x01 || (0xD0...0xD7).contains(marker) {
            marker = try nextJpegMarker(&cursor) // standalone, nothing to keep
            continue
        }
        let length = try cursor.u16be()
        if length < 2 { throw bad("segment length") }
        let count = length - 2
        if (0xE0...0xEF).contains(marker) || marker == 0xFE {
            if marker == 0xE0 || marker == 0xE1 || marker == 0xE2 || marker == 0xEE {
                let payload = try cursor.readBytes(count)
                try handleJpegApplicationSegment(marker, payload, &head)
            } else {
                try cursor.skip(count) // the other application segments and the comments: dropped
            }
            marker = try nextJpegMarker(&cursor)
            continue
        }
        if marker == 0xDA {
            let payload = try cursor.readBytes(count)
            if !head.scanStarted { startJpegOutput(&cursor, &head) }
            putJpegSegment(&cursor, marker: marker, payload: payload)
            marker = try copyJpegScan(&cursor)
            continue
        }
        if (0xC0...0xCF).contains(marker) || (0xDB...0xDF).contains(marker) {
            // frame header, tables, restart interval, line count: what the decoder needs
            let payload = try cursor.readBytes(count)
            if head.scanStarted {
                putJpegSegment(&cursor, marker: marker, payload: payload)
            } else {
                try keepJpegSegment(&head.header, marker: marker, payload: payload)
            }
        } else {
            try cursor.skip(count) // reserved and extension markers: not needed, not copied
        }
        marker = try nextJpegMarker(&cursor)
    }
}

// MARK: - PNG

private let crcTable: [UInt32] = (0..<256).map { (n: Int) -> UInt32 in
    var c = UInt32(n)
    for _ in 0..<8 {
        c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
    }
    return c
}

private func pngCrc32(_ first: [UInt8], _ second: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in first {
        crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    for byte in second {
        crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
}

private func putPngChunk(_ cursor: inout ImageCursor, name: String, data: [UInt8]) {
    let type = ascii(name)
    cursor.put32be(data.count)
    cursor.put(type)
    cursor.put(data)
    cursor.put32be(Int(pngCrc32(type, data)))
}

private func stripPng(_ cursor: inout ImageCursor) throws {
    try cursor.skip(pngSignature.count)
    cursor.put(pngSignature)
    var first = true
    while true {
        let length = try cursor.u32be()
        if length > 0x7FFF_FFFF { throw bad("chunk length") }
        let type = try cursor.readBytes(4)
        for byte in type {
            let isLetter = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            if !isLetter { throw bad("chunk type") }
        }
        let name = String(decoding: type, as: UTF8.self)
        if first && name != "IHDR" { throw bad("IHDR first") }
        first = false
        let critical = type[0] >= 0x41 && type[0] <= 0x5A
        if critical || pngKept.contains(name) {
            cursor.put32be(length)
            cursor.put(type)
            try cursor.copy(length + 4) // data and CRC, as they are
        } else if name == "eXIf" {
            if length <= ImageMetadataStripper.maxExifRead {
                let data = try cursor.readBytes(length)
                try cursor.skip(4)
                let orientation = ImageMetadataStripper.orientationOfTiff(data, offset: 0, length: data.count)
                if (2...8).contains(orientation) {
                    putPngChunk(&cursor, name: "eXIf", data: ImageMetadataStripper.minimalTiff(orientation))
                }
            } else {
                try cursor.skip(length + 4)
            }
        } else {
            try cursor.skip(length + 4) // text, time, and every other ancillary chunk
        }
        if name == "IEND" { return }
    }
}

// MARK: - WEBP

private func stripWebp(_ cursor: inout ImageCursor) throws {
    try cursor.skip(4) // RIFF
    let riffSize = try cursor.u32le()
    try cursor.skip(4) // WEBP
    if riffSize < 4 + 8 { throw bad("RIFF size") }
    let end = riffSize - 4 // bytes of chunks
    cursor.put(riffTag)
    cursor.put32le(0) // the size is known only at the end
    cursor.put(webpTag)
    var consumed = 0
    var first = true
    var vp8xFlagsAt = -1
    var vp8xFlags = 0
    var exifWritten = false
    while consumed < end {
        if end - consumed < 8 { throw bad("chunk header") }
        let fourcc = try cursor.readBytes(4)
        let size = try cursor.u32le()
        let padded = size + (size & 1)
        if padded > end - consumed - 8 { throw bad("chunk size") }
        let name = String(decoding: fourcc, as: UTF8.self)
        if name == "VP8X" {
            if !first || size < 10 || size > ImageMetadataStripper.maxExifRead { throw bad("VP8X") }
            let data = try cursor.readBytes(size)
            if padded > size { try cursor.skip(1) }
            vp8xFlags = Int(data[0])
            vp8xFlagsAt = cursor.out.count + 8
            cursor.put(fourcc)
            cursor.put32le(size)
            cursor.put(data)
            if padded > size { cursor.put(0) }
        } else if webpKept.contains(name) {
            cursor.put(fourcc)
            cursor.put32le(size)
            try cursor.copy(padded)
        } else if name == "EXIF" {
            if size <= ImageMetadataStripper.maxExifRead {
                let data = try cursor.readBytes(size)
                if padded > size { try cursor.skip(1) }
                let shift = data.starts(with: exifHeader) ? exifHeader.count : 0
                let orientation = ImageMetadataStripper.orientationOfTiff(data, offset: shift, length: data.count - shift)
                if (2...8).contains(orientation), vp8xFlagsAt >= 0, !exifWritten {
                    cursor.put(exifTag)
                    cursor.put32le(ImageMetadataStripper.minimalTiffBytes)
                    cursor.put(ImageMetadataStripper.minimalTiff(orientation))
                    exifWritten = true
                }
            } else {
                try cursor.skip(padded)
            }
        } else {
            try cursor.skip(padded) // XMP and anything this code does not know
        }
        first = false
        consumed += 8 + padded
    }
    // The size and the flags are known only now.
    let total = cursor.out.count - 8
    cursor.out[4] = UInt8(truncatingIfNeeded: total)
    cursor.out[5] = UInt8(truncatingIfNeeded: total >> 8)
    cursor.out[6] = UInt8(truncatingIfNeeded: total >> 16)
    cursor.out[7] = UInt8(truncatingIfNeeded: total >> 24)
    if vp8xFlagsAt >= 0 {
        // bit 0x08 is "has Exif" and 0x04 is "has XMP": XMP is gone, Exif is there only when it was rewritten
        cursor.out[vp8xFlagsAt] = UInt8(truncatingIfNeeded: (vp8xFlags & ~0x0C) | (exifWritten ? 0x08 : 0))
    }
}

// MARK: - GIF

private func copyGifSubBlocks(_ cursor: inout ImageCursor) throws {
    while true {
        let size = try cursor.u8()
        cursor.put(size)
        if size == 0 { return }
        try cursor.copy(size)
    }
}

private func skipGifSubBlocks(_ cursor: inout ImageCursor) throws {
    while true {
        let size = try cursor.u8()
        if size == 0 { return }
        try cursor.skip(size)
    }
}

private func stripGif(_ cursor: inout ImageCursor) throws {
    try cursor.copy(6) // signature and version
    let screen = try cursor.readBytes(7)
    cursor.put(screen)
    let screenPacked = Int(screen[4])
    if screenPacked & 0x80 != 0 { try cursor.copy(3 << ((screenPacked & 7) + 1)) }
    while true {
        let block = try cursor.u8()
        if block == 0x3B {
            cursor.put(0x3B)
            return
        }
        if block == 0x21 {
            let label = try cursor.u8()
            if label == 0xF9 {
                cursor.put(0x21)
                cursor.put(label)
                try copyGifSubBlocks(&cursor)
            } else if label == 0xFF {
                let idSize = try cursor.u8()
                if idSize != 0 { // 0 is the terminator of an application block that has no identifier at all
                    let identifier = try cursor.readBytes(idSize)
                    if idSize == 11 && (identifier == netscapeId || identifier == animextsId) {
                        cursor.put(0x21)
                        cursor.put(label)
                        cursor.put(idSize)
                        cursor.put(identifier)
                        try copyGifSubBlocks(&cursor)
                    } else {
                        try skipGifSubBlocks(&cursor)
                    }
                }
            } else {
                try skipGifSubBlocks(&cursor) // comment, plain text, anything else
            }
        } else if block == 0x2C {
            cursor.put(0x2C)
            let descriptor = try cursor.readBytes(9)
            cursor.put(descriptor)
            let packed = Int(descriptor[8])
            if packed & 0x80 != 0 { try cursor.copy(3 << ((packed & 7) + 1)) }
            let minimumCodeSize = try cursor.u8() // LZW minimum code size
            cursor.put(minimumCodeSize)
            try copyGifSubBlocks(&cursor)
        } else {
            throw bad("block")
        }
    }
}
