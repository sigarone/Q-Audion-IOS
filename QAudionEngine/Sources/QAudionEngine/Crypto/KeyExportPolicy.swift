import Foundation

/// W-NFCBIND — where a vault entry came from, and therefore whether its raw
/// material may ever leave this device.
///
/// Android has carried a `KeyCreationMethod` on every vault entry since the
/// vault existed; iOS never did. Provenance here was inferred at *display* time
/// from the shape of the Keychain account name (`AppState.resolvePskDisplayMeta`),
/// which is why an NFC-derived key showed up in the in-call security sheet as
/// the generic bucket "PSK" and never as "NFC". That is the same information
/// this policy needs, so it is promoted from a display-time guess to a stored
/// property.
///
/// The reason it matters is not confidentiality — the Keychain already handles
/// that, and `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` already keeps these
/// items out of iCloud Keychain and out of encrypted device-to-device
/// migration. It is that an NFC secret is supposed to be evidence about the
/// world: it is built jointly by two phones held against each other, neither
/// side picks it, and no third device can reproduce it because it needs both
/// radios in contact. Possession therefore means the holder was physically at
/// the tap, which is the only honest basis for ever showing a contact as
/// authenticated by presence. One copy onto a second phone converts that into a
/// badge that is true about the cryptography and false about the world.
///
/// iOS has no export surface for PSK material today — no QR emitter, and
/// `BackupCoordinator` does not touch this vault (both checked). So unlike
/// Android, where this closed a live path, here the lock is being fitted before
/// the door is built. That is deliberate: the Android hole existed because
/// export was written first and provenance never entered into it.
public enum PskOrigin: String {
    /// Derived from an NFC tap with another device. Never leaves.
    case nfc = "nfc"
    /// Scanned from a QR code shown by another device.
    case qr = "qr"
    /// Typed or pasted by the user.
    case manual = "manual"
    /// Delivered by the server's KMS and unwrapped locally.
    case kms = "kms"
    /// HKDF output of a past call's session key, scoped to one peer's chat and
    /// files. Nothing legitimate reads it off the device.
    case callDerived = "call_derived"
    /// Not a shared secret at all: this device's own long-term private keys and
    /// the bookkeeping sidecars, which live in the same Keychain service.
    /// `DeviceKeyManager` stores the X25519, ML-KEM and Ed25519 private keys
    /// here under `__device.*`, so "may this leave the device" has exactly one
    /// correct answer.
    case deviceInternal = "device_internal"

    /// An X25519 IDENTITY public key — this device's own rotated identity
    /// (`KeyRotationCoordinator.rotate()`, `"rotated_ephemeral.<ts>"`) or a
    /// peer's imported identity (`KeyRotationCoordinator.importPeerIdentity`,
    /// `"peer.<userId>"`). Not a shared secret with anyone: it is asymmetric,
    /// public by design, and carries none of the "both radios were in
    /// contact" evidence a real PSK does. Both call sites share this
    /// vault's storage (a pre-existing design choice this policy doesn't
    /// change) but must never be eligible as call-PSK material — an
    /// identity pubkey accidentally advertised/matched as a PSK fingerprint
    /// would mix public, non-secret bytes into the session key's HKDF salt.
    case identityKey = "identity_key"

    /// Whether the raw bytes behind this entry may cross the device boundary.
    ///
    /// Matched exhaustively with no `default`, so adding an origin forces a
    /// decision here rather than inheriting "exportable" by silence.
    public var isExportable: Bool {
        switch self {
        case .nfc, .callDerived, .deviceInternal, .identityKey:
            return false
        case .qr, .manual, .kms:
            // Transferable by design: a QR or manual key was carried in from
            // somewhere else to begin with, and a KMS key is already held by
            // the server that issued it, so refusing to move it protects
            // nothing while removing the user's ability to provision a second
            // device.
            return true
        }
    }

    /// Legacy fallback for entries written before the origin was persisted —
    /// which is every entry currently on a real device.
    ///
    /// Only the account-name conventions this codebase itself writes are
    /// recognised, and the mapping only ever *removes* privilege: a name it
    /// does not recognise falls through to `.manual`, never the reverse. So a
    /// key this returns `.nfc` for is genuinely one `NfcExchangeView.persistPsk`
    /// created, and a key it cannot place keeps behaving exactly as it does
    /// today.
    ///
    /// Once `SovereignKeyVault` records the origin at write time this is dead
    /// weight for new entries; it exists so the NFC keys already sitting in
    /// vaults become non-exportable the moment this ships, with no migration to
    /// run and none to forget.
    public static func inferred(fromAccountName name: String) -> PskOrigin {
        // `NfcExchangeView.persistPsk` names its entries "nfc-<peerIdPub[0..16]>".
        if name.hasPrefix("nfc-") { return .nfc }
        // `DeviceKeyManager` (`__device.*`) plus the KMS bookkeeping sidecars
        // (`__kmsname.*`, `__kms.active_epoch.*`). Nothing under this prefix is
        // a shared secret and nothing under it should ever be handed out.
        if name.hasPrefix("__") { return .deviceInternal }
        // Android's convention, mirrored by the message-PSK naming.
        if name.hasPrefix("call-") || name.hasPrefix("msg-psk") { return .callDerived }
        // `AppState.installKmsPreBootstrapPsk` names the group-control-channel
        // ratchet seed (RK_0) "auto:<peerPrefix8>:<peerId>" — byte-identical on
        // both sender and receiver, installed via the 3-arg `storePsk` (no
        // persisted origin), so THIS inference is what actually classifies it.
        // It is call/control-channel-derived key material in the same sense as
        // Android's `KeyCreationMethod.CALL_DERIVED` rows and Android's own
        // `"call-"`-prefixed names: reusing it as a 1:1-call audio PSK would
        // couple two independent crypto domains (a forward-secret ratchet seed
        // vs. a statically-mixed call PSK) that were never meant to share
        // material. `.callDerived` is already excluded from advertisement
        // below, so this closes that path without a new origin case.
        if name.hasPrefix("auto:") { return .callDerived }
        // `KeyRotationCoordinator.importPeerIdentity`/`rotate()` name their
        // entries "peer.<userId>" / "rotated_ephemeral.<ts>" — X25519 IDENTITY
        // public keys sharing this vault's storage, not PSKs. Without this
        // branch they fell through to `.manual`, which `fingerprintsForAdvertisement`/
        // `isEligibleMatchCandidate` never exclude — reachable, in principle,
        // as call-PSK candidates. (Never actually selected in practice because
        // their cached Keychain label is `Fingerprint.format(pubkey:)`'s dotted
        // display form, which can never string-equal a peer's 64-hex canonical
        // fingerprint — but that was an accident of formatting, not a rule.)
        if name.hasPrefix("peer.") || name.hasPrefix("rotated_ephemeral.") { return .identityKey }
        // A bare UUID account name is a KMS key id (`KmsPollerService` stores
        // `entry.keyId`), same test `resolvePskDisplayMeta` already uses.
        if UUID(uuidString: name) != nil { return .kms }
        return .manual
    }
}
