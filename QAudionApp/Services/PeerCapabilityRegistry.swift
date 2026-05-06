import Foundation
import QAudionEngine

/// W365 — per-peer wire-format capability tracker.
///
/// Replaces the global `UserDefaults["ChatRatchetV3.enabled"]` toggle
/// (W352) with an opt-in observation: when an inbound message from a
/// peer arrives in a v3 (0xE3) wire envelope, that peer is flagged as
/// v3-capable and every outbound message to them now also rides v3.
///
/// **Conservative bootstrap rules:**
/// - Default per-peer state = `unknown`. Sender path falls back to v1.
/// - First inbound v3 from peer → flag → v3 outbound from that point.
/// - First inbound v1 from peer (after a v3 was observed) → keep v3
///   (the peer might be a multi-device user with one device on the
///   new build and another still on v1; we don't want to ping-pong).
/// - Manual reset: `setCapability(peer, .unknown)` for QA / debug.
///
/// **Persistence:** flags live in UserDefaults under
/// `ChatRatchetV3.peerCaps` as a `[String: String]` map. Survives app
/// relaunch but NOT vault corruption / restore — by design, a vault
/// rebuild forces a fresh capability discovery.
public final class PeerCapabilityRegistry: @unchecked Sendable {

    public enum Capability: String, Equatable {
        case unknown
        case v1
        case v3
    }

    public static let shared = PeerCapabilityRegistry()

    private static let storageKey = "ChatRatchetV3.peerCaps"
    private let lock = NSLock()
    private var cache: [String: Capability]

    public init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        self.cache = raw.compactMapValues { Capability(rawValue: $0) }
    }

    /// Read the current capability flag for a peer. Falls back to
    /// `.unknown` for peers we've never observed.
    public func capability(for peerId: String) -> Capability {
        lock.lock(); defer { lock.unlock() }
        return cache[peerId] ?? .unknown
    }

    /// Promote a peer to v3-capable. Idempotent — calling repeatedly
    /// has no effect.
    public func observedV3(from peerId: String) {
        lock.lock()
        if cache[peerId] != .v3 {
            cache[peerId] = .v3
            persistLocked()
        }
        lock.unlock()
    }

    /// Demote a peer to v1-only. Used by QA / debug to force-roll
    /// back; production code rarely calls this.
    public func observedV1(from peerId: String) {
        lock.lock()
        // Only demote if we'd never seen v3 — see "conservative
        // bootstrap rules" in the type-doc.
        if cache[peerId] == nil {
            cache[peerId] = .v1
            persistLocked()
        }
        lock.unlock()
    }

    /// Force-set a peer's capability. Used by Settings UI to manually
    /// override. Persists.
    public func setCapability(_ cap: Capability, for peerId: String) {
        lock.lock()
        cache[peerId] = cap
        persistLocked()
        lock.unlock()
    }

    /// Clear every peer's capability flag. Useful for QA reset.
    public func reset() {
        lock.lock()
        cache.removeAll()
        persistLocked()
        lock.unlock()
    }

    /// W381: snapshot of the current per-peer state. Used by the
    /// Cross-Platform Beta settings screen to render the list of
    /// observed peers + their flag.
    public func allCapabilities() -> [(peerId: String, capability: Capability)] {
        lock.lock(); defer { lock.unlock() }
        return cache
            .map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
    }

    /// Whether to use v3 outbound for this peer. Combines the legacy
    /// global flag (`ChatRatchetV3.enabled`, off by default) with the
    /// per-peer observation. The global flag stays as a kill-switch
    /// for testers — v3 outbound only fires if EITHER the global
    /// flag is on OR the peer has been observed sending v3.
    public func shouldUseV3Outbound(for peerId: String) -> Bool {
        if UserDefaults.standard.bool(forKey: "ChatRatchetV3.enabled") {
            return true
        }
        return capability(for: peerId) == .v3
    }

    // MARK: - Internal

    /// Caller MUST hold `lock` before calling.
    private func persistLocked() {
        let raw = cache.mapValues { $0.rawValue }
        UserDefaults.standard.set(raw, forKey: Self.storageKey)
    }
}

// MARK: - Convenience wire-format probe

public extension PeerCapabilityRegistry {
    /// Inspect an inbound encrypted blob and update the per-peer
    /// capability flag based on the wire-format magic byte.
    /// Cheap (just looks at the first byte) — call from the chat
    /// receive dispatcher right after base64-decode.
    func probeInbound(_ wire: Data, from peerId: String) {
        let v = MessageWireFormat.detect(wire)
        switch v {
        case .v3:
            observedV3(from: peerId)
        case .v1, .v2:
            observedV1(from: peerId)
        }
    }
}
