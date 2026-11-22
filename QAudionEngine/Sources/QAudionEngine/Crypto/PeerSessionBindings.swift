import Foundation

/// The fingerprints of the peer keys the live 1:1 CHAT and CONTROL sessions are bound to (`SessionBindingStore`), read for the contact
/// shield. Read-only: the records are written by `MessageRatchet` at every install, replace and drop.
///
///  - A contact whose newest ratchet version is 0 to 3 has no v4 or v5 session the binding covers: unknown (nil). So does a version that
///    cannot be read.
///  - An honest "cannot tell" is cached per peer until THAT peer's bindings change (`MessageRatchet.bindingVersion`) or the vault is
///    wiped; a failure to read is never cached.
///  - Reads touch the Keychain: callers keep them off the main thread.
public final class PeerSessionBindings: @unchecked Sendable {

    /// The production reader over the Keychain vault.
    public static let shared = PeerSessionBindings(ratchet: MessageRatchet(vault: KeychainRatchetVault()))

    /// A cached answer for a peer: `prints == nil` is the cached "unknown".
    public struct Answer: Equatable, Sendable {
        public let prints: Set<String>?
    }

    private struct Cached {
        let version: UInt64
        let generation: UInt64
        let prints: Set<String>?
    }

    private let ratchet: MessageRatchet
    private let ratchetVersionOf: (String) throws -> Int
    private let lock = NSLock()
    private var cache: [String: Cached] = [:]

    /// `ratchetVersionOf` defaults to the newest session version the device holds with the peer
    /// (`MessageRatchet.newestChannelRatchetVersion`); tests replace it.
    public init(ratchet: MessageRatchet, ratchetVersionOf: ((String) throws -> Int)? = nil) {
        self.ratchet = ratchet
        self.ratchetVersionOf = ratchetVersionOf ?? { peer in try ratchet.newestChannelRatchetVersion(peerId: peer) }
    }

    /// The prints the peer's live sessions are bound to, or nil when unknown. May read the Keychain.
    public func boundPeerPrints(peerUserId: String) -> Set<String>? {
        let version = MessageRatchet.bindingVersion(peerId: peerUserId)
        let generation = MessageRatchet.bindingGeneration()
        if let hit = cachedAnswer(peerUserId: peerUserId, version: version, generation: generation) { return hit.prints }
        // A version that cannot be read is a failure to tell, so it is unknown too (and not cached).
        guard let ratchetVersion = try? ratchetVersionOf(peerUserId) else { return nil }
        if (0...3).contains(ratchetVersion) { return nil } // a v3 (or older) contact: sessions the binding does not cover
        switch ratchet.boundPeerPrintsChecked(peerId: peerUserId) {
        case .known(let prints):
            store(peerUserId, Cached(version: version, generation: generation, prints: prints))
            return prints
        case .unknown:
            store(peerUserId, Cached(version: version, generation: generation, prints: nil))
            return nil
        case .failed:
            return nil // never cached
        }
    }

    /// The answer already cached for the peer and still valid, without touching the Keychain; nil when there is none.
    public func cachedAnswer(peerUserId: String) -> Answer? {
        cachedAnswer(peerUserId: peerUserId, version: MessageRatchet.bindingVersion(peerId: peerUserId),
                     generation: MessageRatchet.bindingGeneration())
    }

    private func cachedAnswer(peerUserId: String, version: UInt64, generation: UInt64) -> Answer? {
        lock.lock(); defer { lock.unlock() }
        guard let c = cache[peerUserId], c.version == version, c.generation == generation else { return nil }
        return Answer(prints: c.prints)
    }

    private func store(_ peer: String, _ c: Cached) {
        lock.lock(); cache[peer] = c; lock.unlock()
    }
}

/// The safety-number fingerprint of a peer key exactly as the trust rows record it (`SasPinVerification.fingerprintHex`); nil when an
/// input is missing or malformed. The session bindings and the contact shield compare these values, so both sides must come from here.
public enum PeerKeyPrint {
    public static func of(selfUserId: String?, selfIdentityKey: Data?, peerUserId: String?, peerKey: Data?) -> String? {
        guard let selfUserId, !selfUserId.isEmpty, let peerUserId, !peerUserId.isEmpty,
              let selfIdentityKey, selfIdentityKey.count == 32, let peerKey, peerKey.count == 32 else { return nil }
        return SasPinVerification.fingerprintHex(
            selfUserId: selfUserId, selfIdentityKey: selfIdentityKey, peerUserId: peerUserId, peerIdentityKey: peerKey)
    }
}
