import Foundation
import os.log
#if canImport(Darwin)
import Darwin
#endif

/// A container for sensitive byte data (session keys, private keys,
/// voiceprint templates) that is:
///
/// - **Zeroed on deallocation** via `memset_s` to defeat compiler dead-store
///   elimination.
/// - **Memory-locked** so the OS never pages these bytes to disk / swap.
/// - **Automatically scrubbed** in `deinit` regardless of how the object
///   is released.
///
/// Usage:
/// ```swift
/// let key = SecureBytes(data: sessionKeyData)
/// key.withUnsafeBytes { ptr in
///     // use the key material
/// }
/// // key is auto-zeroed when it leaves scope
/// ```
public final class SecureBytes: @unchecked Sendable {

    private let pointer: UnsafeMutableRawPointer
    private let byteCount: Int
    private var locked: Bool = false

    /// The number of bytes stored.
    public var count: Int { byteCount }

    /// Create a secure buffer by copying `data` into a locked, private region.
    public init(data: Data) {
        byteCount = data.count
        pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 1)
        // `src.baseAddress` is nil for an empty buffer — guard rather than
        // force-unwrap so a zero-length `data` (this is a public API; a
        // future caller isn't guaranteed to pass fixed-length key material)
        // degrades to a zero-byte SecureBytes instead of crashing.
        if let base = data.withUnsafeBytes({ $0.baseAddress }) {
            pointer.copyMemory(from: base, byteCount: byteCount)
        }
        lockMemory()
    }

    /// Create a secure buffer filled with `count` cryptographically random bytes.
    public init(randomCount count: Int) {
        byteCount = count
        pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 1)
        #if canImport(Security)
        _ = SecRandomCopyBytes(kSecRandomDefault, count,
                               pointer.assumingMemoryBound(to: UInt8.self))
        #else
        let fd = open("/dev/urandom", O_RDONLY)
        if fd >= 0 { _ = read(fd, pointer, count); close(fd) }
        #endif
        lockMemory()
    }

    deinit {
        zeroize()
        unlockMemory()
        pointer.deallocate()
    }

    // MARK: - Access

    /// Execute `body` with a read-only pointer to the key material.
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: pointer, count: byteCount))
    }

    /// Copy the contents into an ephemeral `Data` value.
    /// Prefer `withUnsafeBytes` to avoid an extra copy.
    public func copyData() -> Data {
        Data(bytes: pointer, count: byteCount)
    }

    // MARK: - Zeroization

    /// Overwrite the buffer with zeroes using a call the compiler cannot
    /// optimise away.
    public func zeroize() {
        #if canImport(Darwin)
        // memset_s is guaranteed not to be optimised out (C11 Annex K / Darwin).
        memset_s(pointer, byteCount, 0, byteCount)
        #else
        // Fallback: volatile-style store through a function pointer the
        // compiler cannot reason about at link time.
        let volatile_memset: @convention(c) (UnsafeMutableRawPointer?, Int32, Int) -> UnsafeMutableRawPointer? = memset
        _ = volatile_memset(pointer, 0, byteCount)
        #endif
    }

    // MARK: - Memory locking

    /// Pin the allocation so the OS does not swap it to disk.
    ///
    /// SECURITY M-35: a failed `mlock` previously failed silently, so
    /// key material could be paged to disk/swap with no signal. We now
    /// log a warning (and leave `locked = false` so `deinit` does not
    /// call `munlock` on an unpinned region). We deliberately do NOT
    /// crash in Release — `mlock` can legitimately fail under RLIMIT_
    /// MEMLOCK pressure and a hard abort would be a worse outcome than a
    /// degraded-but-functional secure buffer.
    private func lockMemory() {
        #if canImport(Darwin)
        if Darwin.mlock(pointer, byteCount) == 0 {
            locked = true
        } else {
            locked = false
            let err = errno
            os_log("SecureBytes.mlock failed (errno=%{public}d) — %{public}d bytes may be swappable",
                   log: OSLog(subsystem: "com.qaudion.app", category: "SecureMemory"),
                   type: .error, err, byteCount)
            assertionFailure("SecureBytes: mlock failed (errno=\(err))")
        }
        #endif
    }

    /// Unlock (unpin) the memory region before deallocation.
    private func unlockMemory() {
        #if canImport(Darwin)
        if locked {
            Darwin.munlock(pointer, byteCount)
            locked = false
        }
        #endif
    }
}
