import Foundation
import Security

/// R-RING (WIRE_SPEC §3.7.2) — which slots of a 1:1 FrameCryptor key ring stay live.
///
/// A 1:1 receiver keeps exactly two key rounds live: the CURRENT one and the one installed BEFORE
/// it (so frames still in flight under the previous round decrypt during the sender-switch grace
/// window). Every other slot the ring ever held is retired when a new round is installed, by
/// overwriting it with RANDOM bytes: never zeros, because the native cryptor accepts 32 zero bytes
/// as a valid key, and an empty or zeroed slot would let anyone who can inject SRTP seal frames
/// under a key derived from a public value.
///
/// The "previous" round is the previously INSTALLED slot, not `E - 1`: key rounds can have gaps (a
/// round that did not complete), so computing it would randomise a live slot (and leave an old
/// one resident). Slots are `E mod 16`.
///
/// The tracker is pure bookkeeping (no WebRTC types): the cryptor that owns the ring calls
/// ``install(slot:senderSlot:)`` after it has set the new round's keys and overwrites each returned
/// slot with ``randomRetiredKey()`` for both participants.
public struct OneToOneKeyRingTracker: Equatable {

    /// The slot of the round installed last, `nil` before the first install.
    public private(set) var current: Int32?
    /// The slot of the round installed before `current`, `nil` until a second round is installed.
    public private(set) var previous: Int32?
    /// Every slot that currently holds a REAL key (installed and not yet retired).
    public private(set) var holdingRealKey: Set<Int32> = []

    public init() {}

    /// Record that the keys of a round were just set at `slot` and return the slots that must now
    /// be overwritten with random bytes (ascending).
    ///
    /// - Installing the slot that is already current is a re-publish of the same round (the
    ///   install sites are idempotent): nothing changes and nothing is retired.
    /// - `senderSlot` is the slot this device's OWN sender is still announcing: it is the key that
    ///   seals our outbound frames, so it is never retired from under the sender; it is retired by
    ///   a later install, once the sender has moved on.
    @discardableResult
    public mutating func install(slot: Int32, senderSlot: Int32? = nil) -> [Int32] {
        if current == slot { return [] }
        previous = current
        current = slot
        holdingRealKey.insert(slot)
        var live: Set<Int32> = [slot]
        if let previous { live.insert(previous) }
        if let senderSlot { live.insert(senderSlot) }
        let retired = holdingRealKey.subtracting(live)
        holdingRealKey.subtract(retired)
        return retired.sorted()
    }

    /// 32 random bytes from the system CSPRNG, never all zero. Used to overwrite a retired slot.
    public static func randomRetiredKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        for _ in 0..<4 {
            let status = bytes.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return SecRandomCopyBytes(kSecRandomDefault, raw.count, base)
            }
            if status != errSecSuccess {
                var rng = SystemRandomNumberGenerator()
                for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
            }
            if bytes.contains(where: { $0 != 0 }) { break }
        }
        if !bytes.contains(where: { $0 != 0 }) { bytes[0] = 1 }  // unreachable in practice
        return Data(bytes)
    }
}
