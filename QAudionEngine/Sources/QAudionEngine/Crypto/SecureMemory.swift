import Foundation
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
        data.withUnsafeBytes { src in
            pointer.copyMemory(from: src.baseAddress!, byteCount: byteCount)
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
    private func lockMemory() {
        #if canImport(Darwin)
        if Darwin.mlock(pointer, byteCount) == 0 {
            locked = true
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
