import Foundation

/// Holds the one mesh transport of the process and enforces the startup order of
/// docs/mesh/MESH_LINK_SPEC.md section 1.2:
///
/// 1. the identity key is read (or created) by the caller,
/// 2. the node id is derived from it,
/// 3. the transport is created WITH that node id, which is immutable for the life
///    of the transport,
/// 4. only then may the radio start.
///
/// There is no random fallback id. Until ``configure(identityKeyRaw:)`` has
/// succeeded, ``acquire()`` returns nil, so nothing can put a packet on the air
/// (or accept one) under any other id. If the identity changes while the process
/// runs, the transport built for the old one is stopped and discarded; the next
/// ``acquire()`` builds a new one. Components that need the node id read
/// ``nodeId`` here and keep no copy of their own.
public final class MeshTransportSlot<Transport: AnyObject> {

    public enum Configured: Equatable {
        /// No usable identity key (nil, wrong length): nothing changed, the radio must not start.
        case unavailable
        /// The same node id as before.
        case unchanged(MeshNodeId)
        /// A first identity, or a different one. `retired` is true when a transport built for the
        /// previous id was discarded, so a running radio has to be restarted with ``acquire()``.
        case changed(MeshNodeId, retired: Bool)
    }

    /// Raw Ed25519 public key length.
    public static var identityKeyBytes: Int { 32 }

    private let factory: (MeshNodeId) -> Transport
    private let retire: (Transport) -> Void
    private let lock = NSLock()
    private var currentNodeId: MeshNodeId?
    private var currentTransport: Transport?

    public init(factory: @escaping (MeshNodeId) -> Transport, retire: @escaping (Transport) -> Void) {
        self.factory = factory
        self.retire = retire
    }

    /// The node id derived from the identity key, nil until one was configured.
    public var nodeId: MeshNodeId? {
        lock.lock()
        defer { lock.unlock() }
        return currentNodeId
    }

    /// The transport if one has been built, without building one.
    public var existingTransport: Transport? {
        lock.lock()
        defer { lock.unlock() }
        return currentTransport
    }

    /// Derives the node id from the raw 32-byte identity public key. A key that
    /// cannot be read (nil) or is not 32 bytes leaves everything as it was.
    @discardableResult
    public func configure(identityKeyRaw: Data?) -> Configured {
        guard let raw = identityKeyRaw, raw.count == Self.identityKeyBytes,
              let derived = MeshNodeId.from(identityKeyRaw: raw) else {
            return .unavailable
        }
        lock.lock()
        let previous = currentNodeId
        if previous == derived {
            lock.unlock()
            return .unchanged(derived)
        }
        let oldTransport = currentTransport
        currentNodeId = derived
        currentTransport = nil
        lock.unlock()
        if let oldTransport { retire(oldTransport) }
        return .changed(derived, retired: oldTransport != nil)
    }

    /// The account left (logout, remote wipe): the identity is gone, so is the transport built for it. Returns
    /// whether a transport was retired. Until ``configure(identityKeyRaw:)`` succeeds again there is no node id and
    /// no transport.
    @discardableResult
    public func reset() -> Bool {
        lock.lock()
        let oldTransport = currentTransport
        currentNodeId = nil
        currentTransport = nil
        lock.unlock()
        if let oldTransport { retire(oldTransport) }
        return oldTransport != nil
    }

    /// The transport for the current node id, built on first use. Nil while there
    /// is no identity.
    public func acquire() -> Transport? {
        lock.lock()
        defer { lock.unlock() }
        guard let nodeId = currentNodeId else { return nil }
        if let currentTransport { return currentTransport }
        let built = factory(nodeId)
        currentTransport = built
        return built
    }
}
