import XCTest
import CryptoKit
@testable import QAudionEngine

/// A source that is generated, never stored: byte `j` of chunk `c` is a function of `c`, `j` and a per-chunk salt, produced a chunk at
/// a time. It is how the tests move 5 GiB without a 5 GiB file, and how they change the content of a source WITHOUT changing its size
/// or its modification time (the one change that rule 1 of WIRE_SPEC 12.8 cannot see and rule 2 must).
///
/// By default its identity is only a size and a time (like a provider that has no more to give), so a change in the middle of it is
/// invisible to rule 1 and reaches the ledger. With `fingerprint` it gives the hardened identity of a file: the time to the nanosecond,
/// a file number, a creation time and the SHA-256 of its first and last 64 KiB, so the tests can show what the hardening catches.
final class GeneratedSource: FileV2SendSource, @unchecked Sendable {
    private static let chunk = FileV2.chunkSize

    /// 1 MiB of pseudo-random bytes (xorshift), made once.
    private static let base: Data = {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bytes = [UInt8](repeating: 0, count: GeneratedSource.chunk)
        var index = 0
        while index < bytes.count {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            var word = state
            for _ in 0..<8 where index < bytes.count {
                bytes[index] = UInt8(truncatingIfNeeded: word)
                word >>= 8
                index += 1
            }
        }
        return Data(bytes)
    }()

    let size: UInt64
    let locator: String
    /// The identity carries the hardened members (see above).
    let fingerprint: Bool
    private let lock = NSLock()
    private var modifiedMs: Int64
    private var extraNanoseconds: Int64 = 0
    private var fileNumber: UInt64 = 7_000_001
    private var salts: [Int: UInt8] = [:]
    private var flippedBytes: [UInt64: UInt8] = [:]
    private var reads = 0

    init(size: UInt64, locator: String = "generated-\(UUID().uuidString.lowercased())", modifiedMs: Int64 = 1_700_000_000_000,
         fingerprint: Bool = false) {
        self.size = size
        self.locator = locator
        self.modifiedMs = modifiedMs
        self.fingerprint = fingerprint
    }

    func currentIdentity() throws -> FileV2SourceIdentity {
        lock.lock()
        let milliseconds = modifiedMs
        let nanoseconds = extraNanoseconds
        let number = fileNumber
        lock.unlock()
        guard fingerprint else { return FileV2SourceIdentity(locator: locator, size: size, modifiedMs: milliseconds) }
        let sample = Int(min(size, UInt64(FileV2SourceIdentity.sampleLength)))
        let head = bytes(offset: 0, length: sample) ?? Data()
        let tail = bytes(offset: size - UInt64(sample), length: sample) ?? Data()
        return FileV2SourceIdentity(locator: locator, size: size, modifiedMs: milliseconds, modifiedNs: milliseconds * 1_000_000 + nanoseconds,
                                    fileNumber: number, createdMs: 1_600_000_000_000, headDigest: Data(SHA256.hash(data: head)),
                                    tailDigest: Data(SHA256.hash(data: tail)))
    }

    func makeReader() throws -> FileV2SourceReader { GeneratedReader(owner: self) }

    /// The content of chunk `index` changes; the size and the modification time do not.
    func mutate(chunk index: Int) {
        lock.lock()
        salts[index] = (salts[index] ?? 0) &+ 1
        lock.unlock()
    }

    /// One byte of the file, anywhere in it, changes; the size and the modification time do not.
    func flipByte(at offset: UInt64) {
        lock.lock()
        flippedBytes[offset] = (flippedBytes[offset] ?? 0) ^ 0xFF
        lock.unlock()
    }

    /// The modification time moves (the file was saved again).
    func touch() {
        lock.lock()
        modifiedMs += 1
        lock.unlock()
    }

    /// The modification time moves by a nanosecond: the same millisecond, another time (visible only to a fingerprint).
    func touchByANanosecond() {
        lock.lock()
        extraNanoseconds += 1
        lock.unlock()
    }

    /// The file is replaced by another file (an editor that saves atomically): the content and the times are the same, the file number is not.
    func replaceFile() {
        lock.lock()
        fileNumber += 1
        lock.unlock()
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    fileprivate func noteRead() {
        lock.lock()
        reads += 1
        lock.unlock()
    }

    /// The 1 MiB of chunk `index` as it is NOW.
    func content(ofChunk index: Int) -> Data {
        lock.lock()
        let salt = salts[index] ?? 0
        let flips = flippedBytes.filter { $0.key / UInt64(GeneratedSource.chunk) == UInt64(index) }
        lock.unlock()
        var block = GeneratedSource.base
        var counter = UInt64(index)
        for position in 0..<8 {
            block[position] = UInt8(truncatingIfNeeded: counter)
            counter >>= 8
        }
        block[8] = salt
        for (offset, mask) in flips { block[Int(offset % UInt64(GeneratedSource.chunk))] ^= mask }
        return block
    }

    /// The real bytes of the file in `range` as they are NOW (`nil` past the end).
    func bytes(offset: UInt64, length: Int) -> Data? {
        guard offset + UInt64(length) <= size else { return nil }
        var out = Data()
        out.reserveCapacity(length)
        var position = offset
        var remaining = length
        while remaining > 0 {
            let chunkIndex = Int(position / UInt64(GeneratedSource.chunk))
            let inside = Int(position % UInt64(GeneratedSource.chunk))
            let take = min(remaining, GeneratedSource.chunk - inside)
            out.append(content(ofChunk: chunkIndex).subdata(in: inside..<(inside + take)))
            position += UInt64(take)
            remaining -= take
        }
        return out
    }

    /// Writes the whole content to a file, a chunk at a time: the same bytes a reader returns.
    func write(to url: URL) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var written: UInt64 = 0
        var index = 0
        while written < size {
            let take = Int(min(UInt64(GeneratedSource.chunk), size - written))
            try handle.write(contentsOf: content(ofChunk: index).prefix(take))
            written += UInt64(take)
            index += 1
        }
    }
}

private final class GeneratedReader: FileV2SourceReader {
    private let owner: GeneratedSource
    private var closed = false

    init(owner: GeneratedSource) {
        self.owner = owner
    }

    func read(offset: UInt64, length: Int) throws -> Data {
        guard !closed else { throw FileV2SendSourceError.unavailable }
        owner.noteRead()
        guard let bytes = owner.bytes(offset: offset, length: length) else { throw FileV2SendSourceError.shortRead }
        return bytes
    }

    func close() { closed = true }
}

/// Finds the sources of a test again by their locator (a restart builds a new pipeline, which asks for them), and falls back to a
/// file path.
final class TestSourceProvider: FileV2SendSourceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [String: FileV2SendSource] = [:]
    var failLookups = false

    func register(_ source: GeneratedSource) {
        lock.lock()
        sources[source.locator] = source
        lock.unlock()
    }

    func source(for identity: FileV2SourceIdentity) throws -> FileV2SendSource {
        lock.lock()
        defer { lock.unlock() }
        if failLookups { throw FileV2SendSourceError.unavailable }
        if let known = sources[identity.locator] { return known }
        return FileV2FileSource(url: URL(fileURLWithPath: identity.locator))
    }
}

enum SendTestSizes {
    /// Three parts: two full ones and a short last one. Padme adds a little: the stream of this size is a bit longer, still 3 parts.
    static let threeParts: UInt64 = 2 * UInt64(FileV2Wire.chunksPerPart) * UInt64(FileV2.chunkSize) + 123_457

    /// One byte over a part boundary: the second part holds a single short chunk.
    static let oneChunkOver: UInt64 = UInt64(FileV2Wire.chunksPerPart) * UInt64(FileV2.chunkSize) + 1

    static func parts(ofSize size: UInt64) -> Int {
        let stream = FileV2.padme(size)
        let chunks = FileV2.chunkCount(forStreamLength: stream)
        let blob = Int64(FileV2.headerLength) + Int64(stream) + Int64(chunks) * Int64(FileV2.tagSize)
        return FileV2Wire.partCount(blobLength: blob)
    }
}
