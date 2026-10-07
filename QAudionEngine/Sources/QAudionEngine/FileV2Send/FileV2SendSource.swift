import Foundation

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
public struct FileV2FileSource: FileV2SendSource, CustomStringConvertible, CustomReflectable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var description: String { "FileV2FileSource" }

    public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

    public func currentIdentity() throws -> FileV2SourceIdentity {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) } catch {
            throw FileV2SendSourceError.unavailable
        }
        guard let size = (attributes[.size] as? NSNumber)?.uint64Value else { throw FileV2SendSourceError.unavailable }
        let seconds = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        guard seconds.isFinite, abs(seconds) < 1.0e12 else { throw FileV2SendSourceError.unavailable }
        return FileV2SourceIdentity(locator: url.path, size: size, modifiedMs: Int64((seconds * 1000.0).rounded(.down)))
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
