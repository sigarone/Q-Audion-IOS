import Foundation
import CryptoKit

/// Local at-rest encryption for message content stored in `qaudion.sqlite`.
///
/// Pavel, 2026-08-02: "sarebbe meglio che venissero decifrati e importati
/// nella chat dove sono cifrati con la password locale con cui si proteggono
/// anche i contatti."
///
/// He is right, and the gap was real. To answer the question behind it
/// first: an inbound message is decrypted from the wire EXACTLY ONCE, on
/// receipt — the wire ciphertext is not kept and nothing is ever
/// re-decrypted with the transport keys when a chat is opened. What the
/// chat screen reads is the local store. But until this file existed that
/// store held message bodies as plain rows in `qaudion.sqlite`, protected
/// only by the iOS Data Protection class on the file
/// (`completeUntilFirstUserAuthentication`) — so the single most sensitive
/// data in the app had strictly WEAKER at-rest protection than the contact
/// list, which `ContactsStore` has encrypted with an app-held AES-256-GCM
/// key since 2026-08-01. This closes that inversion: message bodies now get
/// the same treatment as contacts.
///
/// Design (checked against the `implementing-aes-encryption-for-data-at-rest`
/// skill, NIST FIPS 197 / SP 800-38D):
///   - AES-256-GCM through the same `AeadCipher` the rest of the codebase
///     uses. Authenticated, so a tampered row fails to open rather than
///     decoding to attacker-chosen text.
///   - A random 256-bit key generated on the device, held in the Keychain.
///     No password-derived key (no PBKDF2/Argon2 step): there is no user
///     password in this flow, and a full-entropy device key is stronger
///     than anything derivable from one.
///   - Fresh random nonce per record, from `AeadCipher`.
///   - Versioned textual header so a legacy plaintext row is recognisable
///     and readable forever, rather than turning into garbage on upgrade.
///
/// **Key accessibility — deliberate, and different from `ContactsStore`.**
/// This key is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not
/// `WhenUnlocked`. Messages arrive over the persistent WebSocket while the
/// phone is locked and in the user's pocket; a `WhenUnlocked` key would be
/// unreadable at exactly that moment, so every message received while
/// locked would fail to persist. That is not hypothetical — it is the
/// `ContactsStore` bug observed in CI and reachable on device
/// (`[ContactsStore] Keychain SecItemAdd failed status=-34018`, and
/// `-25308` for the locked-device case): a write the store cannot encrypt
/// is a write that is silently lost. `AfterFirstUnlock` is also exactly the
/// protection class the SQLite file itself already carries, so for messages
/// this is strictly additive — it adds an app-held key on top of the same
/// class, and takes nothing away.
public enum LocalStoreCipher {

    /// Dedicated Keychain service, distinct from `ContactsStore`'s and from
    /// the PSK vaults, so each store's key can be rotated or migrated on its
    /// own.
    private static let keyService = "com.bcrypto.qaudion.localstore.key.v1"
    private static let keyAccount = "masterKey"

    /// Textual marker for a sealed value. Chosen so the column stays a
    /// plain `TEXT` column and a legacy plaintext row — which cannot begin
    /// with this exact prefix unless a user typed it — is still readable.
    private static let prefix = "QM1:"

    private static let cipher = AeadCipher()

    // MARK: - Public API

    public enum CipherError: Error {
        /// The Keychain key could not be read or created. Callers MUST fail
        /// the write loudly rather than fall back to storing plaintext —
        /// silently degrading to plaintext is the failure mode this whole
        /// file exists to remove.
        case keyUnavailable
        case sealFailed
    }

    /// Encrypts `value` for storage. `nil` in → `nil` out (a NULL column
    /// stays NULL). Throws rather than returning the input unchanged: a
    /// caller that cannot encrypt must not write the plaintext.
    public static func seal(_ value: String?) throws -> String? {
        guard let value = value else { return nil }
        if value.isEmpty { return value }
        if value.hasPrefix(prefix) { return value }   // already sealed
        guard let key = loadOrCreateKey() else { throw CipherError.keyUnavailable }
        guard let sealed = try? cipher.encrypt(plaintext: Data(value.utf8), key: key) else {
            throw CipherError.sealFailed
        }
        var blob = Data()
        blob.append(sealed.nonce)
        blob.append(sealed.tag)
        blob.append(sealed.ciphertext)
        return prefix + blob.base64EncodedString()
    }

    /// Decrypts a stored value. A value without the marker is returned
    /// unchanged — that is a row written before this format existed, and
    /// it must keep displaying normally. A marked value that fails to open
    /// (missing key, tampered row) returns `nil` rather than garbage.
    public static func open(_ stored: String?) -> String? {
        guard let stored = stored else { return nil }
        guard stored.hasPrefix(prefix) else { return stored }
        let b64 = String(stored.dropFirst(prefix.count))
        guard let blob = Data(base64Encoded: b64) else { return nil }
        let headerLen = CryptoConstants.nonceSize + CryptoConstants.tagSize
        guard blob.count > headerLen else { return nil }
        let nonce = blob.prefix(CryptoConstants.nonceSize)
        let tag = blob.dropFirst(CryptoConstants.nonceSize).prefix(CryptoConstants.tagSize)
        let ciphertext = blob.dropFirst(headerLen)
        guard let key = loadOrCreateKey() else { return nil }
        let output = AeadCipher.CipherOutput(
            nonce: Data(nonce), ciphertext: Data(ciphertext), tag: Data(tag))
        guard let plaintext = try? cipher.decrypt(cipherOutput: output, key: key) else { return nil }
        return String(data: plaintext, encoding: .utf8)
    }

    /// True when `stored` is in this format — used by the lazy migration in
    /// `ConversationStore` to tell an already-converted row from a legacy one.
    public static func isSealed(_ stored: String?) -> Bool {
        stored?.hasPrefix(prefix) ?? false
    }

    /// Shown in place of a sealed row that cannot be opened (key gone after
    /// a restore-to-new-device, or a tampered row). Deliberately NOT the
    /// empty string: a blank bubble is indistinguishable from a message that
    /// was never there, and worded differently from the wire-decrypt
    /// placeholder ("[messaggio cifrato non leggibile]") so a log or a
    /// screenshot says which of the two layers failed.
    public static let unreadableMarker = "[messaggio non leggibile su questo dispositivo]"

    // MARK: - Key management

    /// Test seam. `internal`, so it exists only for `@testable import` and
    /// is invisible to the app target — production code can never set it.
    ///
    /// Without this the encrypted stores are literally untestable in CI: a
    /// unit-test bundle in the simulator has no usable keychain, every
    /// `SecItemAdd` returns `-34018 errSecMissingEntitlement`, and the store
    /// fails closed. That is not a hypothetical — it is why every single
    /// `ContactsStoreTests` case has been red since at-rest encryption
    /// landed on 2026-08-01, which in turn means a real regression in this
    /// code would be invisible behind an already-red suite.
    internal static var testKeyOverride: Data?

    private static func loadOrCreateKey() -> Data? {
        if let override = testKeyOverride { return override }
        if let existing = readKey() { return existing }
        let fresh = SymmetricKey(size: .bits256)
        let freshData = fresh.withUnsafeBytes { Data($0) }
        let addAttrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: keyAccount,
            kSecValueData as String: freshData,
            // Never leaves the device, never syncs to iCloud. See the type
            // doc for why this is AfterFirstUnlock and not WhenUnlocked.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
        if addStatus == errSecSuccess { return freshData }
        // A concurrent caller won the race and created the item between our
        // read and this add — re-read instead of treating it as a failure.
        // `ContactsStore` had exactly this bug (W-CONTACTKEYRACE): the loser
        // of the race got `errSecDuplicateItem`, returned nil, and every
        // subsequent load on that instance came back empty.
        if addStatus == errSecDuplicateItem { return readKey() }
        return nil
    }

    private static func readKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: keyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, data.count == 32 else { return nil }
        return data
    }
}
