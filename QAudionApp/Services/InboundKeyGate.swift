import Foundation
import QAudionEngine

/// Raised by the PSK-based receive formats (v1/v2) when no pairwise key is bound to the sender.
/// It is an ordinary decrypt failure: the frame follows the same keep, retry, nack and placeholder
/// policy as any other frame that does not open.
enum InboundKeyError: Error {
    case noPairwiseKey
}

/// At most one key-exchange request per peer within `interval`.
struct KeyExchangeThrottle {
    let interval: TimeInterval
    private var lastRequest: [String: Date] = [:]

    init(interval: TimeInterval = 30) {
        self.interval = interval
    }

    /// True when `peerId` may be sent a request at `now`. Does not take the slot.
    func isAllowed(peerId: String, now: Date = Date()) -> Bool {
        guard let last = lastRequest[peerId] else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// Takes the slot for `peerId`. Call it only once the request has actually been handed over.
    mutating func record(peerId: String, now: Date = Date()) {
        lastRequest[peerId] = now
        if lastRequest.count > 256 {
            lastRequest = lastRequest.filter { now.timeIntervalSince($0.value) < interval }
        }
    }

    /// Returns true (and records the request) when `peerId` may be sent a request at `now`.
    mutating func allow(peerId: String, now: Date = Date()) -> Bool {
        guard isAllowed(peerId: peerId, now: now) else { return false }
        record(peerId: peerId, now: now)
        return true
    }
}

extension PairwiseChainKeyResolver {
    /// True when a key for `peerId` may exist but the vault cannot be read right now (device locked).
    /// Such a read is "try again later", never "no key".
    static func vaultUnreadable(peerId: String, vault: SovereignKeyVault) -> Bool {
        let prefix = peerId.count > 8 ? String(peerId.prefix(8)) : peerId
        for name in ["auto:\(prefix):\(peerId)", peerId, "msg-psk:\(peerId)"] {
            do {
                _ = try vault.loadPsk(name: name)
            } catch KeyVaultError.deviceLocked {
                return true
            } catch {
                continue
            }
        }
        return false
    }
}
