import Foundation

/// Proximity pairing v1 — identity policy and persistence (spec §12,
/// docs/security/PROXIMITY_PAIRING_QR_BLE_SPEC.md).
///
/// - The identity policy is pure (`identityDecision`) plus one Keychain read
///   (`defaultIdentityPolicy` looks up the contact's pin).
/// - Nothing here WRITES identity pins: `PeerIdentityPinStore` belongs to the
///   call handshake. A pin written from here would also silence the spec §2 A5
///   warning for the very next mismatch.
/// - `persist` validates everything it is handed and fails closed before it
///   touches the Keychain; it never falls back to a different name, origin or
///   fingerprint.
public enum ProximityPairingStore {

    // MARK: - Constants

    /// Vault account-name prefix. `PskOrigin.inferred(fromAccountName:)` keys
    /// off the same prefix for entries whose blob carries no origin.
    private static let vaultEntryPrefix: String = "prox-"
    /// "first 16 lowercase hex chars of the peer's Ed25519 key" (spec §12).
    private static let vaultEntryHexCharacters: Int = 16
    private static let hexDigits: [Character] = Array("0123456789abcdef")

    private static let selfPairingMessage: String = "Non puoi associare il telefono con se stesso."
    private static let pinMismatchWarning: String =
        "Attenzione: la chiave di identità di questo contatto è diversa da quella verificata in precedenza. "
        + "Conferma solo se sei sicuro che la persona davanti a te sia davvero questo contatto."

    // MARK: - Vault naming

    /// `"prox-"` followed by the first 16 lowercase hex characters (8 bytes) of
    /// `peerSigningPublicKey`. Accepts `Data` slices. A key shorter than 8
    /// bytes yields fewer hex characters; `persist` refuses such keys before
    /// ever naming an entry.
    public static func vaultEntryName(peerSigningPublicKey: Data) -> String {
        let key: Data = Data(peerSigningPublicKey)
        let byteCount: Int = min(key.count, vaultEntryHexCharacters / 2)
        var characters: [Character] = []
        characters.reserveCapacity(byteCount * 2)
        var index: Int = 0
        while index < byteCount {
            let byte: UInt8 = key[index]
            let high: Int = Int(byte >> 4)
            let low: Int = Int(byte & 0x0F)
            characters.append(hexDigits[high])
            characters.append(hexDigits[low])
            index += 1
        }
        let suffix: String = String(characters)
        let name: String = vaultEntryPrefix + suffix
        return name
    }

    // MARK: - Identity policy (spec §12)

    /// Pure decision, evaluated before the SAS is shown:
    /// - same Ed25519 key OR same userId as the local identity → `.reject`;
    /// - a pin exists and differs from the presented Ed25519 key →
    ///   `.acceptWithWarning` (the user decides in person);
    /// - otherwise → `.accept`.
    ///
    /// Keys are public, so plain comparison is fine here. A malformed pin
    /// (wrong length, empty) counts as "differs": it can only ever add a
    /// warning, never remove one.
    public static func identityDecision(peer: ProximityPeerIdentity,
                                        local: ProximityLocalIdentity,
                                        pinnedSigningKey: Data?) -> ProximityIdentityDecision {
        let pinned: [Data] = pinnedSigningKey.map { (key: Data) -> [Data] in [key] } ?? []
        return decide(peer: peer,
                      localUserId: local.userId,
                      localSigningKey: local.signingPublicKey,
                      pinnedSigningKeys: pinned)
    }

    /// Same decision against every key the contact has pinned (legacy and
    /// per-device, `PeerIdentityPinStore.allPinnedKeys`): no pins → `.accept`;
    /// the presented key equals ANY of them → `.accept` (one of the peer's
    /// known devices); otherwise → `.acceptWithWarning`.
    public static func identityDecision(peer: ProximityPeerIdentity,
                                        local: ProximityLocalIdentity,
                                        pinnedSigningKeys: [Data]) -> ProximityIdentityDecision {
        return decide(peer: peer,
                      localUserId: local.userId,
                      localSigningKey: local.signingPublicKey,
                      pinnedSigningKeys: pinnedSigningKeys)
    }

    /// The production policy handed to the sessions: `identityDecision` with
    /// every pin read from `PeerIdentityPinStore().allPinnedKeys(contactId: peer.userId)`
    /// (the legacy pin AND the per-device ones — D11 keeps most pins per device).
    ///
    /// The returned closure captures only the local userId and Ed25519 PUBLIC
    /// key, never the private seed, and checks for self-pairing before it
    /// touches the Keychain.
    public static func defaultIdentityPolicy(local: ProximityLocalIdentity) -> (ProximityPeerIdentity) -> ProximityIdentityDecision {
        let localUserId: String = local.userId
        let localSigningKey: Data = Data(local.signingPublicKey)
        let policy: (ProximityPeerIdentity) -> ProximityIdentityDecision = { (peer: ProximityPeerIdentity) -> ProximityIdentityDecision in
            let selfPairing: Bool = ProximityPairingStore.isSelf(peer: peer,
                                                                 localUserId: localUserId,
                                                                 localSigningKey: localSigningKey)
            if selfPairing {
                return ProximityIdentityDecision.reject(ProximityPairingStore.selfPairingMessage)
            }
            let pinned: [Data] = PeerIdentityPinStore().allPinnedKeys(contactId: peer.userId)
            return ProximityPairingStore.decide(peer: peer,
                                                localUserId: localUserId,
                                                localSigningKey: localSigningKey,
                                                pinnedSigningKeys: pinned)
        }
        return policy
    }

    // MARK: - Persistence (spec §12)

    /// Stores the PSK of a COMPLETED pairing:
    /// - name `vaultEntryName(peerSigningPublicKey:)`;
    /// - fingerprint label `lowercase_hex(SHA-256(psk))`, recomputed here and
    ///   required to equal `result.pskFingerprint`;
    /// - origin `.proximity` (non-exportable);
    /// - the peer's full Ed25519 key in the blob's presence-identity field
    ///   (`nfcpid`), so call-time binding can compare it with the verified caller.
    ///
    /// Throws `ProximityPairingError.cryptoFailure` on any malformed input
    /// (checked before the Keychain is touched) and rethrows the vault's
    /// `KeyVaultError` on a failed write. Never writes identity pins.
    public static func persist(_ result: ProximityPairingResult, vault: SovereignKeyVault) throws {
        let peerKey: Data = Data(result.peer.signingPublicKey)
        guard peerKey.count == ProximityPairing.ed25519PublicKeyBytes else {
            throw ProximityPairingError.cryptoFailure("peer identity key length")
        }

        var psk: Data = Data(result.psk)
        defer { CryptoConstants.zeroize(&psk) }
        guard psk.count == ProximityPairing.pskBytes else {
            throw ProximityPairingError.cryptoFailure("psk length")
        }
        guard !isAllZero(psk) else {
            throw ProximityPairingError.cryptoFailure("psk all zero")
        }

        let fingerprint: String = PskAdvertising.canonicalFingerprint(forPsk: psk)
        let computedFingerprint: Data = Data(fingerprint.utf8)
        let claimedFingerprint: Data = Data(result.pskFingerprint.utf8)
        guard ProximityPairingCrypto.constantTimeEquals(computedFingerprint, claimedFingerprint) else {
            throw ProximityPairingError.cryptoFailure("psk fingerprint")
        }

        let name: String = vaultEntryName(peerSigningPublicKey: peerKey)
        try vault.storePsk(name: name,
                           key: psk,
                           fingerprint: fingerprint,
                           keyClass: nil,
                           origin: .proximity,
                           nfcPeerIdentityKey: peerKey)
    }

    // MARK: - Local identity

    /// This device's identity for a pairing: the sovereign Ed25519 seed and
    /// X25519 identity public key from `SovereignIdentityManager`, bound to the
    /// server account id `userId`.
    ///
    /// `nil` when `userId` is empty, no identity is stored (or the Keychain is
    /// locked / unreadable), any field is malformed, or the stored Ed25519
    /// public key does not match the one derived from the stored seed: call
    /// handshakes advertise the STORED public key, so a mismatch would pair
    /// under a key the peer would never see again.
    public static func loadLocalIdentity(userId: String) -> ProximityLocalIdentity? {
        guard !userId.isEmpty else { return nil }
        guard let stored = SovereignIdentityManager().loadIdentity() else { return nil }

        var seed: Data = Data(stored.signingPrivate)
        defer { CryptoConstants.zeroize(&seed) }
        let encryptionPublicKey: Data = Data(stored.encryptionPublic)
        let storedSigningPublicKey: Data = Data(stored.signingPublic)

        let local: ProximityLocalIdentity
        do {
            local = try ProximityLocalIdentity(userId: userId,
                                               signingPrivateKey: seed,
                                               encryptionPublicKey: encryptionPublicKey)
        } catch {
            return nil
        }
        guard local.signingPublicKey == storedSigningPublicKey else { return nil }
        return local
    }

    // MARK: - Private helpers

    private static func isSelf(peer: ProximityPeerIdentity, localUserId: String, localSigningKey: Data) -> Bool {
        let peerKey: Data = Data(peer.signingPublicKey)
        let ownKey: Data = Data(localSigningKey)
        if peerKey == ownKey { return true }
        return peer.userId == localUserId
    }

    private static func decide(peer: ProximityPeerIdentity,
                               localUserId: String,
                               localSigningKey: Data,
                               pinnedSigningKeys: [Data]) -> ProximityIdentityDecision {
        if isSelf(peer: peer, localUserId: localUserId, localSigningKey: localSigningKey) {
            return .reject(selfPairingMessage)
        }
        if pinnedSigningKeys.isEmpty { return .accept }
        let presentedKey: Data = Data(peer.signingPublicKey)
        for pinned in pinnedSigningKeys {
            let pinnedKey: Data = Data(pinned)
            if pinnedKey == presentedKey { return .accept }
        }
        return .acceptWithWarning(pinMismatchWarning)
    }

    private static func isAllZero(_ data: Data) -> Bool {
        let accumulated: UInt8 = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> UInt8 in
            var value: UInt8 = 0
            var index: Int = 0
            let count: Int = buffer.count
            while index < count {
                value |= buffer[index]
                index += 1
            }
            return value
        }
        return accumulated == 0
    }
}
