import Foundation
import Security

/// TOFU pin for the Reality front's public key (REALITY_PIN fix).
///
/// None of the 3 platforms ever compared a freshly-fetched Reality
/// `publicKey` (from `/calling/relays`, Cloudflare-fronted) against any
/// previously-seen value — a compromised/coerced CDN edge could swap the
/// pinned key with zero client-side signal, defeating exactly the
/// TLS-camouflage property Reality exists to provide.
///
/// Keyed by Reality FRONT HOSTNAME (`reality.hostname`), not `serverName`
/// (the disguise SNI is an operator choice that can legitimately change
/// independent of the key material).
///
/// Behaviour on mismatch (signal-not-kill, per project policy): NON-BLOCKING
/// — log loud + re-pin to the new value + still connect. Refusing to connect
/// would break the user's only censorship-bypass path, which this project's
/// policy explicitly forbids doing in response to a security finding.
///
/// Storage mirrors `SasVerificationStore`'s Keychain trio (same accessibility,
/// same update-then-add-then-reset write pattern, same constant-time
/// comparison) — a distinct service string so this namespace never collides
/// with SAS verification records.
public enum RealityPinStore {

    public enum Verdict: Equatable {
        /// No prior pin for this hostname — the key is now pinned.
        case firstUse
        /// The fetched key matches the pinned value.
        case match
        /// The fetched key DIFFERS from the pinned value — re-pinned to the
        /// new value (additive, non-blocking; caller decides what to surface).
        case changed
    }

    private static let keychainService = "com.qaudion.reality.pin"

    /// Check `publicKey` against the pin stored for `hostname`, pinning it
    /// (first-use or re-pin-on-change) as a side effect. Never blocks: always
    /// returns a verdict, never throws.
    public static func checkAndPin(hostname: String, publicKey: String) -> Verdict {
        guard !hostname.isEmpty, !publicKey.isEmpty else { return .firstUse }
        guard let stored = keychainGet(account: hostname) else {
            keychainSet(account: hostname, value: publicKey)
            return .firstUse
        }
        if constantTimeEquals(stored, publicKey) {
            return .match
        }
        keychainSet(account: hostname, value: publicKey)
        return .changed
    }

    // MARK: - Constant-time comparison

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

    // MARK: - Keychain helpers (mirrors SasVerificationStore)

    /// Atomic write: update-first, add-when-absent, delete+add only as a last
    /// resort — never leaves a partial write that would downgrade the
    /// `AfterFirstUnlockThisDeviceOnly` accessibility flag.
    private static func keychainSet(account: String, value: String) {
        let data = Data(value.utf8)
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var add = base
            for (k, v) in attributes { add[k] = v }
            SecItemAdd(add as CFDictionary, nil)
            return
        }
        SecItemDelete(base as CFDictionary)
        var add = base
        for (k, v) in attributes { add[k] = v }
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func keychainGet(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
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
}
