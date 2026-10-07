import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Why a source could not be read.
public enum FileV2SendSourceError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The source cannot be opened or read (it is gone, or it is not reachable now).
    case unavailable
    /// The source ended before the bytes that were asked for: it is shorter than it was.
    case shortRead

    public var description: String {
        switch self {
        case .unavailable: return "FileV2SendSourceError(unavailable)"
        case .shortRead: return "FileV2SendSourceError(short_read)"
        }
    }
}

/// Where the bytes of the file come from. The pipeline never asks for more than one chunk (1 MiB) at a time, so a source of
/// 5 GiB is streamed: nothing here needs the whole file in memory, and a test can use a generated source that never exists in full.
///
/// Access to a security-scoped URL (the document picker, the share sheet, the photo library) is the CALLER's concern: the source
/// the caller hands in is already reachable, and stays reachable while the transfer runs. The pipeline reads it through
/// `makeReader`, one reader for each part being sealed.
public protocol FileV2SendSource: Sendable {
    /// What the source looks like now: where to find it again, its size and its modification time. The pipeline compares it with
    /// what the transfer started with (WIRE_SPEC 12.8 rule 1) before every part and before it closes the object.
    func currentIdentity() throws -> FileV2SourceIdentity

    /// A reader of its own (readers are not shared between tasks).
    func makeReader() throws -> FileV2SourceReader
}

/// Reads bytes of a source. Not thread safe: one reader belongs to one task.
public protocol FileV2SourceReader: AnyObject {
    /// Exactly `length` bytes at `offset`. Throws `shortRead` when the source ends before them.
    func read(offset: UInt64, length: Int) throws -> Data

    /// Releases the reader. Idempotent.
    func close()
}

/// Finds a source again after a restart, from the identity the journal kept (`locator`). The size and the time of the identity it
/// returns are compared with the journal's by the pipeline, so a provider only has to locate the file.
public protocol FileV2SendSourceProvider: Sendable {
    func source(for identity: FileV2SourceIdentity) throws -> FileV2SendSource
}

/// A source that is a file: `FileHandle` with `seek` and `read`, a chunk at a time. Its description never shows the path.
///
/// Its identity is the hardened one of `FileV2SourceIdentity`: the file is opened once and everything is read from that descriptor
/// (`fstat`, then the first and the last 64 KiB with `pread`), so the numbers and the two digests describe the same file even if the
/// name is replaced while they are read.
public struct FileV2FileSource: FileV2SendSource, CustomStringConvertible, CustomReflectable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var description: String { "FileV2FileSource" }

    public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

    public func currentIdentity() throws -> FileV2SourceIdentity {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw FileV2SendSourceError.unavailable }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            throw FileV2SendSourceError.unavailable
        }
        let size = UInt64(info.st_size)
        let modified = FileV2FileSource.modification(of: info)
        guard let modifiedMs = FileV2FileSource.milliseconds(modified), let modifiedNs = FileV2FileSource.nanoseconds(modified) else {
            throw FileV2SendSourceError.unavailable
        }
        let sampleLength = min(size, UInt64(FileV2SourceIdentity.sampleLength))
        let head = try FileV2FileSource.digest(of: descriptor, offset: 0, length: Int(sampleLength))
        let tail = try FileV2FileSource.digest(of: descriptor, offset: size - sampleLength, length: Int(sampleLength))
        return FileV2SourceIdentity(locator: url.path, size: size, modifiedMs: modifiedMs, modifiedNs: modifiedNs,
                                    fileNumber: UInt64(info.st_ino), createdMs: FileV2FileSource.creation(of: info),
                                    headDigest: head, tailDigest: tail)
    }

    private static func modification(of info: stat) -> timespec {
        #if canImport(Darwin)
        return info.st_mtimespec
        #else
        return info.st_mtim
        #endif
    }

    /// Creation time in epoch milliseconds, where the platform keeps it (Apple platforms; Linux has no birth time in `stat`).
    private static func creation(of info: stat) -> Int64? {
        #if canImport(Darwin)
        return milliseconds(info.st_birthtimespec)
        #else
        return nil
        #endif
    }

    private static func milliseconds(_ time: timespec) -> Int64? {
        let seconds = Int64(time.tv_sec)
        guard abs(seconds) < 1_000_000_000_000 else { return nil }
        return seconds * 1000 + Int64(time.tv_nsec) / 1_000_000
    }

    private static func nanoseconds(_ time: timespec) -> Int64? {
        let (scaled, overflow) = Int64(time.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return nil }
        let (total, overflowed) = scaled.addingReportingOverflow(Int64(time.tv_nsec))
        return overflowed ? nil : total
    }

    /// SHA-256 of `length` bytes at `offset`, read with `pread` (a read that ends early means the file shrank under it).
    private static func digest(of descriptor: Int32, offset: UInt64, length: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        var done = 0
        while done < length {
            let count = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return pread(descriptor, base + done, length - done, off_t(offset) + off_t(done))
            }
            if count > 0 {
                done += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                throw FileV2SendSourceError.unavailable
            }
        }
        return Data(SHA256.hash(data: bytes))
    }

    public func makeReader() throws -> FileV2SourceReader {
        do { return FileV2FileReader(handle: try FileHandle(forReadingFrom: url)) } catch {
            throw FileV2SendSourceError.unavailable
        }
    }
}

/// The reader of a `FileV2FileSource`.
final class FileV2FileReader: FileV2SourceReader {
    private var handle: FileHandle?

    init(handle: FileHandle) {
        self.handle = handle
    }

    func read(offset: UInt64, length: Int) throws -> Data {
        guard let handle = handle else { throw FileV2SendSourceError.unavailable }
        guard length > 0 else { return Data() }
        var content = Data()
        content.reserveCapacity(length)
        do {
            try handle.seek(toOffset: offset)
            while content.count < length {
                guard let piece = try handle.read(upToCount: length - content.count), !piece.isEmpty else {
                    throw FileV2SendSourceError.shortRead
                }
                content.append(piece)
            }
        } catch let error as FileV2SendSourceError {
            throw error
        } catch { throw FileV2SendSourceError.unavailable }
        return content
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    deinit {
        try? handle?.close()
    }
}

/// Finds a file source again from the path in its identity. An iOS container path changes with an app update: a caller whose
/// sources live in the container keeps its own provider, which maps the locator to wherever the file is now.
public struct FileV2FileSourceProvider: FileV2SendSourceProvider {
    public init() {}

    public func source(for identity: FileV2SourceIdentity) throws -> FileV2SendSource {
        FileV2FileSource(url: URL(fileURLWithPath: identity.locator))
    }
}
