import Foundation
import CryptoKit
import Security

/// W368 — persistence for the in-call SAS ceremony.
///
/// Once a user taps "CONFERMA COINCIDONO" in the InCallScreen, the
/// (peer, sasFingerprint) tuple is stored so the next call between
/// the same two peers automatically renders the panel as VERIFIED
/// (no need to re-do the ceremony for every call).
///
/// **Cross-platform parity:** mirrors Android's
/// `SasVerificationTracker.kt` — both store a hash of the peerUserId
/// + the SAS-words bundle so a tampered chain key (which would change
/// the SAS) auto-invalidates the verification.
///
/// **SECURITY M-7 — format + storage change (invalidates old data):**
/// - Fingerprint is now SHA-256 truncated to 16 bytes (32 hex chars)
///   instead of a 64-bit FNV-1a (16 hex chars). FNV is non-cryptographic
///   and trivially collidable, so an attacker who could write the store
///   could forge a fingerprint that matches a tampered SAS. Switching to
///   SHA-256 closes that and removes the FNV collision surface.
///   *Existing stored fingerprints are FNV-format and no longer match —
///   affected users simply re-verify the SAS once.*
/// - Comparison is constant-time (byte-wise, no early return) to remove
///   the timing side-channel on the previous `==` String compare.
/// - Storage moved from UserDefaults to the iOS Keychain
///   (`kSecClassGenericPassword`, service `com.qaudion.sas`,
///   accessibility `AfterFirstUnlockThisDeviceOnly`) so the
///   verification record is not world-readable in a plist backup.
///
/// Method names (`isVerified`, `recordVerified`, `fingerprint`,
/// `storedFingerprint`, `clear`) are unchanged so callers
/// (LiveInCallScreen etc.) compile without modification.
public final class SasVerificationStore {

    public static let shared = SasVerificationStore()

    /// Keychain service (M-7). Account is `prefix + peerUserId`.
    private static let keychainService = "com.qaudion.sas"
    private let prefix = "qaudion.sas.verified."

    public init() {}

    // MARK: - Public API (stable)

    /// Persist that `peerUserId` confirmed SAS coincidence under
    /// `fingerprint`. Replaces any previous fingerprint for the
    /// same peer (e.g. after a key rotation that produces a new SAS).
    public func recordVerified(peerUserId: String, fingerprint: String) {
        Self.keychainSet(account: prefix + peerUserId,
                         value: fingerprint)
    }

    /// Returns the previously-stored fingerprint, or nil if the user
    /// has never confirmed an SAS for this peer (or the store was
    /// reset). SECURITY M-7: reads from Keychain; falls back to a
    /// one-time UserDefaults migration of any legacy value.
    public func storedFingerprint(peerUserId: String) -> String? {
        let account = prefix + peerUserId
        if let v = Self.keychainGet(account: account) {
            return v
        }
        // One-time migration: a legacy FNV fingerprint may still sit in
        // UserDefaults. Note it is FNV-format and will NOT match the new
        // SHA-256 fingerprint() output, so it forces a benign re-verify.
        let defaults = UserDefaults.standard
        if let legacy = defaults.string(forKey: account) {
            Self.keychainSet(account: account, value: legacy)
            defaults.removeObject(forKey: account)
            return legacy
        }
        return nil
    }

    /// Convenience: returns true if `currentFingerprint` matches the
    /// last verified fingerprint for the peer. Used to render the
    /// "SAS VERIFICATO" badge on InCallScreen at call start without
    /// requiring the user to re-confirm.
    public func isVerified(peerUserId: String, currentFingerprint: String) -> Bool {
        guard let stored = storedFingerprint(peerUserId: peerUserId) else {
            return false
        }
        // SECURITY M-7: constant-time comparison (no early exit).
        return Self.constantTimeEquals(stored, currentFingerprint)
    }

    /// Forget the verification for a peer — used when the user
    /// explicitly resets a contact, or when key material rotates
    /// in a way that invalidates the historical fingerprint.
    public func clear(peerUserId: String) {
        let account = prefix + peerUserId
        Self.keychainDelete(account: account)
        // Also clear any not-yet-migrated legacy value.
        UserDefaults.standard.removeObject(forKey: account)
    }

    /// Compute the canonical fingerprint for a SAS-words bundle.
    /// SECURITY M-7: SHA-256 truncated to 16 bytes (32 hex chars),
    /// replacing the previous 64-bit FNV-1a. The fingerprint is what
    /// gets persisted — derived from the SAS rather than the raw
    /// session key so a manual reset doesn't expose secret material.
    public static func fingerprint(forWords words: [String]) -> String {
        let joined: String = words.map { $0.uppercased() }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(joined.utf8))
        let truncated = Array(digest.prefix(16))
        return truncated.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Constant-time comparison

    /// Byte-wise comparison with no data-dependent early return.
    /// Length mismatch still short-circuits (lengths are not secret —
    /// both inputs are hex of a fixed-size hash).
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        if ab.count != bb.count { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count {
            diff |= ab[i] ^ bb[i]
        }
        return diff == 0
    }

    // MARK: - Keychain helpers (M-7)

    /// SECURITY F-2: atomic write. The previous `SecItemDelete` then
    /// `SecItemAdd` (ignoring status) could silently lose the
    /// `AfterFirstUnlockThisDeviceOnly` accessibility flag if the add
    /// failed (e.g. `errSecInteractionNotAllowed` while the device is
    /// locked) — leaving the verification record absent (= benign,
    /// forces re-verify) but, worse, a partial write could downgrade
    /// protection. Mirrors `TokenVault.save`: update-first, add when
    /// absent, delete+add only as a last resort, and the terminal
    /// OSStatus is checked + logged instead of swallowed.
    private static func keychainSet(account: String, value: String) {
        let data = Data(value.utf8)
        let base: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(base as CFDictionary,
                                         attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var add = base
            for (k, v) in attributes { add[k] = v }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            logIfFailed("add", account: account, status: addStatus)
            return
        }
        // Any other status (e.g. duplicate after a race): hard-reset
        // the item so the value is never left stale.
        SecItemDelete(base as CFDictionary)
        var add = base
        for (k, v) in attributes { add[k] = v }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        logIfFailed("reset", account: account, status: addStatus)
    }

    /// SECURITY F-2: do not silently swallow a failed keychain write.
    /// The log string is built into a single `let line: String`
    /// outside any closure (CLAUDE.md Swift-6 type-checker trap).
    private static func logIfFailed(_ op: String,
                                    account: String,
                                    status: OSStatus) {
        if status == errSecSuccess { return }
        let statusText: String = String(describing: status)
        let line: String = "SasVerificationStore keychain "
            + op + " failed status=" + statusText
        RTLog.error("security", line)
    }

    private static func keychainGet(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    private static func keychainDelete(account: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
