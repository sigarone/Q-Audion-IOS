import Foundation

/// The second signature keys of peer devices whose cross-certificate verified on fetch, kept in process memory only.
/// Nothing reads them yet; calls start using them in a later step, together with a pin and the rules for a changed
/// key, which need a persisted record. A restart re-fetches and re-verifies. Bounded.
///
/// Keyed by (user uuid, device id, Ed25519 key): an entry can only be found by the exact identity it was certified
/// for, so a rotated Ed25519 key never reuses the old entry. A bundle of a (user, device) that has no valid
/// certificate removes what was stored for that (user, device). Cleared when the account leaves.
public enum PeerMldsaStore {

    struct Key: Hashable {
        let uuidRaw: Data
        let deviceId: String
        let edPub: Data
    }

    private static let maxEntries = 512
    private static let lock = NSLock()
    private static var entries: [Key: MldsaIdentityPublication.VerifiedPeer] = [:]

    /// Verifies the extra fields of a fetched bundle and records the result: a valid set is stored, anything else
    /// drops the stored entries of that (user, device). Returns the verified key, or nil. Call it only for a bundle
    /// whose own signature already verified. Never throws and never rejects the bundle.
    @discardableResult
    public static func ingest(_ bundle: BCryptoKmsClient.IdentityBundleV2) -> MldsaIdentityPublication.VerifiedPeer? {
        let verified = MldsaIdentityPublication.verifyPeer(
            pubB64: bundle.mldsaPubB64, createdMs: bundle.mldsaXcCreatedMs, edSigB64: bundle.mldsaXcEdSigB64,
            pqSigB64: bundle.mldsaXcPqSigB64, gen: bundle.mldsaGen, keyIdB64: bundle.mldsaKeyIdB64,
            uuidRaw: bundle.uuidRaw, deviceId: bundle.deviceId, edPub: bundle.ed25519Pub)
        record(uuidRaw: bundle.uuidRaw, deviceId: bundle.deviceId, edPub: bundle.ed25519Pub, verified: verified)
        return verified
    }

    /// Stores `verified`, replacing every other entry of the same (user, device); nil removes them all.
    static func record(uuidRaw: Data, deviceId: String?, edPub: Data, verified: MldsaIdentityPublication.VerifiedPeer?) {
        let device = deviceId ?? ""
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { !($0.key.uuidRaw == uuidRaw && $0.key.deviceId == device) }
        guard let verified else { return }
        if entries.count >= maxEntries { entries.removeAll() }
        entries[Key(uuidRaw: uuidRaw, deviceId: device, edPub: edPub)] = verified
    }

    /// The verified key for exactly that (user, device, Ed25519 key), or nil.
    public static func get(uuidRaw: Data, deviceId: String?, edPub: Data) -> MldsaIdentityPublication.VerifiedPeer? {
        lock.lock()
        defer { lock.unlock() }
        return entries[Key(uuidRaw: uuidRaw, deviceId: deviceId ?? "", edPub: edPub)]
    }

    public static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Logout, remote wipe, account deletion, and the tests.
    public static func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}
