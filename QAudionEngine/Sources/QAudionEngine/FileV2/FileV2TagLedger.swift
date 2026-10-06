import Foundation

/// The sender's anti-nonce-reuse ledger (section 12.8): `T[i]`, the GCM tag of every chunk already
/// encrypted at least once.
///
/// Encryption is deterministic: the same (`K`, `file_id`) always gives the same bytes for the same
/// plaintext chunk, so a chunk can be re-encrypted on every retry or resume instead of being kept on disk,
/// provided the content has not changed. The only way to reuse a nonce is to encrypt two DIFFERENT plaintexts
/// under the same (`K`, `file_id`, `i`). The rule that forbids it, on every path (retry, resume, parallel
/// workers, direct path and server path):
///
///  - whenever a chunk `i` already present in `T` is encrypted again, the new tag MUST equal `T[i]` before the
///    chunk leaves the process. If it differs the content changed: the chunk MUST NOT be transmitted and the
///    transfer is cancelled (`FileV2Error.contentChanged`, wire code `cancelled`; the sender sends
///    `qa_file_cancel`, with a new `K` and `file_id` for whatever comes next).
///
/// The ledger is OWNED by the `FileV2Encryptor` that seals with it: it is created inside the encryptor, loaded at
/// construction from the persisted tags of a resume (`FileV2Encryptor.resume`), and never handed out or injected, so
/// no caller can start a resume with an empty ledger, share one ledger between two encryptors or edit it behind the
/// encryptor's back. `FileV2Encryptor` consults it inside every seal, so a sealed chunk is only ever returned after the
/// check. It is thread safe: parallel workers, one index each, share the encryptor.
///
/// Persistence is the pipeline's job: `FileV2Encryptor.tagEntries` is what the local transfer state stores (at most
/// 80 KiB: 16 bytes for each of at most 5 120 chunks). The state is local to the device and never goes into a backup.
final class FileV2TagLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var tags: [Int: Data]

    /// An empty ledger: a new file, nothing encrypted yet.
    init() {
        tags = [:]
    }

    /// Restores a persisted ledger for a file of `chunkCount` chunks. Every index must be in `0..<chunkCount` and
    /// every tag exactly 16 bytes: a corrupted state is an error, never silently ignored (an ignored entry is an
    /// unchecked nonce).
    init(entries: [Int: Data], chunkCount: Int) throws {
        var restored: [Int: Data] = [:]
        for (index, tag) in entries {
            guard index >= 0, index < chunkCount, index < FileV2.maxChunks, tag.count == FileV2.tagSize else {
                throw FileV2Error.invalidArgument("invalid tag ledger entry")
            }
            restored[index] = Data([UInt8](tag))      // an own copy of the bytes
        }
        tags = restored
    }

    /// The tag of every chunk encrypted so far, by index.
    var entries: [Int: Data] {
        lock.lock(); defer { lock.unlock() }
        return tags
    }

    /// The number of chunks whose tag is recorded.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return tags.count
    }

    func tag(at index: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return tags[index]
    }

    /// Records the tag of chunk `index` the first time, and on every later encryption of the same chunk
    /// requires the same tag. Throws `contentChanged` (and records nothing) when it differs.
    func checkOrRecord(index: Int, tag: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if let recorded = tags[index] {
            guard recorded == tag else { throw FileV2Error.contentChanged }
        } else {
            tags[index] = tag
        }
    }
}
