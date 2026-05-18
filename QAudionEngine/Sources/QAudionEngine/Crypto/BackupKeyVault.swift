import Foundation

/// SECURITY L-5 — backup keys are stored in the Keychain WITHOUT a
/// biometric / device-passcode `kSecAccessControl` gate. This is an
/// accepted (LOW) risk: the `.qabk` backup blob these keys protect is
/// itself wrapped with scrypt(N=2^17) + AES-256-GCM under a
/// user-chosen password (see BackupCipher / BackupContainer), so a
/// stolen Keychain item alone does not yield plaintext. Keeping the
/// default path non-interactive preserves silent restore on app
/// relaunch (a Face ID prompt mid-restore would break the UX and the
/// engine has no UI). `loadKeyWithUserPresence(...)` below is an
/// OPTIONAL hardened accessor a future Settings "require Face ID for
/// backup keys" toggle can call; it is not wired into the default
/// flow so existing restore behaviour is unchanged.
public final class BackupKeyVault {
    private let keyStore = QAudionKeyStore()

    public init() {}

    public func backupKey(name: String, key: Data) throws {
        try keyStore.storeKey(identifier: "backup_\(name)", keyData: key)
    }

    public func restoreKey(name: String) -> Data? {
        keyStore.loadKey(identifier: "backup_\(name)")
    }

    /// SECURITY L-5 — optional biometric-gated read. Triggers a
    /// Face ID / Touch ID / passcode prompt (`.userPresence`) before
    /// returning the key. NOT used by the default restore path.
    public func restoreKeyWithUserPresence(name: String, reason: String) -> Data? {
        keyStore.loadKeyWithUserPresence(identifier: "backup_\(name)", reason: reason)
    }

    public func deleteBackup(name: String) {
        keyStore.deleteKey(identifier: "backup_\(name)")
    }
}
