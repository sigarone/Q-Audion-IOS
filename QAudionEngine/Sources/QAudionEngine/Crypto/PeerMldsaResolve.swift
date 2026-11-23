import Foundation

/// The second public key a call handshake checks a peer's second signature against (design section 5.5, step 2).
///
/// The key comes only from `PeerMldsaStore`, which keeps a key only if its certificate verified against the Ed25519 key, the uuid
/// and the device id of the SAME fetched bundle, and the lookup is under (peer uuid, sending device id, the Ed25519 key that
/// verified the round's `sigV6`): the second key belongs to the same Ed25519 key, uuid and device as the signature it endorses.
/// A bundle with another Ed25519 key for that device is another entry, never a hit. When the store has nothing for the device the
/// caller's `fetchDevice` runs once (it fills the store) and the store is read again. When the stored entry names another key id
/// than the one the bundle claims, `refetchDevice` runs instead: it returns the verified key of a fresh fetch WITHOUT recording it,
/// so a refetch can never erase or replace a stored or pinned key. The key must also be the one the bundle names. No device id (an envelope without one) means no key: the certificate binds a device id.
public enum PeerMldsaResolve {

    public static func resolve(
        peerUserId: String, deviceId: String?, signerEdPub: Data, keyId: Data,
        fetchDevice: (_ peerUserId: String, _ deviceId: String) async -> Void,
        refetchDevice: ((_ peerUserId: String, _ deviceId: String, _ signerEdPub: Data) async
                        -> MldsaIdentityPublication.VerifiedPeer?)? = nil
    ) async -> Pqsig.MlDsaPublicKey? {
        guard let deviceId, !deviceId.isEmpty, let uuid = UUID(uuidString: peerUserId) else { return nil }
        let uuidRaw = withUnsafeBytes(of: uuid.uuid) { Data($0) }
        var entry = PeerMldsaStore.get(uuidRaw: uuidRaw, deviceId: deviceId, edPub: signerEdPub)
        if entry == nil {
            await fetchDevice(peerUserId, deviceId)
            entry = PeerMldsaStore.get(uuidRaw: uuidRaw, deviceId: deviceId, edPub: signerEdPub)
        } else if let stale = entry, stale.keyId != keyId {
            // the stored entry names another key: look again, keep what is stored
            guard let refetchDevice, let fresh = await refetchDevice(peerUserId, deviceId, signerEdPub), fresh.keyId == keyId else {
                return nil
            }
            return Pqsig.parsePublicKey(fresh.pub)
        }
        guard let found = entry, found.keyId == keyId else { return nil }
        return Pqsig.parsePublicKey(found.pub)
    }
}

/// Runs an operation with an upper bound on the wait and measures it. The operation is not cancelled (a network call cannot be
/// stopped from here): after the bound its answer is simply not used.
enum BoundedWait {

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?

        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

        func resume(_ value: T?) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    /// The value, or nil when the operation answered nil or did not answer within `seconds`; and the elapsed milliseconds.
    static func run<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async -> T?) async -> (value: T?, elapsedMs: Int) {
        let started = DispatchTime.now().uptimeNanoseconds
        let value: T? = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once<T>(continuation)
            Task.detached { once.resume(await operation()) }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.resume(nil)
            }
        }
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        return (value, elapsed)
    }
}
