import Foundation

/// Group calls v2 (spec §12.11) — a 32-byte media key that lives in memory the
/// owner can zero on demand.
///
/// `Data` is a value type: every copy of a key that was ever handed around in
/// one is another heap block nobody can scrub. The coordinator's long-lived key
/// stores (`ownKeys`, `installed`, `pending`) hold `GroupKeyBuffer`s instead: ONE
/// allocation per key, zeroed with `memset_s` when the key is retired, replaced,
/// dropped with its member or when the call ends (and, as a backstop, when the
/// buffer is released). `data` hands out a transient copy for the two consumers
/// that need `Data` (the native key provider, the wire envelope); those copies
/// are as short-lived as the call that uses them.
///
/// Not thread-safe: the owner serialises every call (the coordinator's queue).
public final class GroupKeyBuffer: @unchecked Sendable {

    public let count: Int
    private let storage: UnsafeMutableRawPointer
    private var zeroed = false

    /// nil unless `bytes` is exactly one media key (`GroupE2ee.keyLength`).
    public init?(_ bytes: Data) {
        guard bytes.count == GroupE2ee.keyLength else { return nil }
        count = bytes.count
        storage = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
        bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress { storage.copyMemory(from: base, byteCount: raw.count) }
        }
    }

    deinit {
        Self.zero(storage, count: count)
        storage.deallocate()
    }

    /// True once `wipe()` ran (test seam and guard: a wiped buffer is all zeros).
    public var isWiped: Bool { zeroed }

    /// A fresh copy of the key bytes (all zeros after `wipe()`).
    public var data: Data { Data(bytes: storage, count: count) }

    /// Zeroes the key in place. Idempotent.
    public func wipe() {
        Self.zero(storage, count: count)
        zeroed = true
    }

    /// Constant-time comparison with another key.
    public func matches(_ other: GroupKeyBuffer) -> Bool {
        guard other.count == count else { return false }
        var difference: UInt8 = 0
        let mine = storage.assumingMemoryBound(to: UInt8.self)
        let theirs = other.storage.assumingMemoryBound(to: UInt8.self)
        for index in 0..<count { difference |= mine[index] ^ theirs[index] }
        return difference == 0
    }

    /// Zeroes `count` bytes at `pointer` in a way the optimiser may not drop
    /// (same primitive as `CryptoConstants.zeroize`).
    static func zero(_ pointer: UnsafeMutableRawPointer, count: Int) {
        guard count > 0 else { return }
        #if canImport(Darwin)
        memset_s(pointer, count, 0, count)
        #else
        let volatileMemset: @convention(c) (UnsafeMutableRawPointer?, Int32, Int) -> UnsafeMutableRawPointer? = memset
        _ = volatileMemset(pointer, 0, count)
        #endif
    }
}
