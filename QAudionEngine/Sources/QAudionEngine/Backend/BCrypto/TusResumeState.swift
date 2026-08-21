import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

/// W-TUSRESUME — persisted state for a previously-attempted-but-not-
/// completed TUS upload, keyed by the outbound message's `clientMsgId`.
///
/// **Why this exists.** `TusUploadClient.upload()` mints a fresh `fileId`
/// (server-side `POST /files/tus`) every time it's called; if the app is
/// killed mid-upload (not just backgrounded — see `BackgroundUploadTask`
/// for the in-process grace-period story), today's only retry path is a
/// brand-new upload from byte zero. The server already exposes a
/// TUS-standard `HEAD /files/tus/{id}` (owner-only, returns
/// `Upload-Offset`/`Upload-Length`, 404 if purged) that lets a client
/// resume from the confirmed offset instead. This type is the client-side
/// breadcrumb that makes that possible: "the last attempt for this
/// outbound message got as far as fileId X, for a source blob that looked
/// like Y — is X still resumable, and is Y still trustworthy?"
///
/// **Server-side retention.** `bcrypto-server`'s `storage.RetentionWorker`
/// purges abandoned/incomplete TUS uploads 24h after creation (wired into
/// `main()` — see `cmd/bcrypto-lite/main.go`). A resume attempt against a
/// purged `fileId` legitimately 404s; callers must treat that as "no
/// longer resumable, fall through to a fresh upload," never as a bug.
///
/// **What this record intentionally does NOT track.** The exact byte
/// offset is NOT persisted here — `HEAD` is always the authoritative
/// source for that (the local device could have crashed mid-PATCH with
/// the server having committed a different offset than the client's last
/// known write). This record's only job is "does a resumable upload
/// plausibly exist for this attachment, and is the source blob on disk
/// still the SAME bytes that were partially uploaded" — not exact
/// progress bookkeeping.
///
/// **Storage convention.** Mirrors `PendingGroupInviteStore`: a single
/// `Codable` blob under one `UserDefaults` key (here a dictionary keyed
/// by `clientMsgId` rather than an array, since lookups are always by a
/// specific message, not "list newest-first"). This is non-sensitive
/// metadata — a fileId UUID, a byte count, a hex SHA-256 of the plaintext
/// source blob, the AES-GCM salt/nonce/timestamp used for that upload's
/// encryption, and a timestamp — so `UserDefaults` (unencrypted plist) is
/// an appropriate store, same reasoning as the group-invite queue.
/// Contrast with `SasVerificationStore`, which moved to Keychain
/// specifically because a forged SAS fingerprint has a real MITM
/// consequence. The salt/nonce/tag persisted here already ride in
/// cleartext inside the wire `qfile` marker on every successful send (see
/// `FileMarker.QFile`) — persisting them locally pre-send discloses
/// nothing an eavesdropper wouldn't already see once the message actually
/// goes out. The plaintext SHA-256 doesn't reveal file *contents* either
/// (a one-way hash, and the attacker would need the exact bytes in hand
/// to confirm a match).
public struct TusResumeState: Codable, Equatable {
    /// Server-assigned fileId from the `create()` call this record
    /// describes. This is what gets HEAD'd/PATCHed on resume.
    public let fileId: String
    /// The outbound message this upload belongs to — the dictionary key
    /// in the backing store duplicates this, but keeping it inline too
    /// means a single `TusResumeState` value is self-describing (useful
    /// for logging/debugging without needing the dictionary key in hand).
    public let clientMsgId: String
    /// Total ciphertext length in bytes, as sent in `Upload-Length` at
    /// create time. Purely informational today (HEAD's `Upload-Length`
    /// is authoritative) — kept for parity/debugging.
    public let totalBytes: Int64
    /// Size in bytes of the SOURCE file (the plaintext blob on disk that
    /// gets re-encrypted and re-uploaded) at the moment this upload
    /// began. Part of the corruption check: if the file on disk today
    /// doesn't match this, the source has changed since the failed
    /// attempt and resuming would upload garbage against the old
    /// ciphertext's already-uploaded bytes.
    public let sourceSizeAtStart: Int64
    /// Hex SHA-256 of the SOURCE file's bytes at the moment this upload
    /// began. Together with `sourceSizeAtStart`, this is the corruption
    /// check: both must match the file on disk today before a resume is
    /// attempted. Note this hashes the PLAINTEXT source blob (the local
    /// cache file `sendVoiceNote`/`sendImage` persist).
    public let sourceSha256AtStart: String
    /// When this record was written — informational; the authoritative
    /// abandonment clock is server-side (24h retention window). Not used
    /// for any local expiry decision (a 404 from HEAD is the actual
    /// signal), but useful for diagnostics/logging.
    public let createdAt: Date

    /// W-TUSRESUME — encryption continuity fields, hex-encoded, mirroring
    /// `FileTransfer.FileMarker.QFile.salt/nonce/ts`. **Why these must be
    /// persisted:** `FileTransfer.upload()` mints a fresh random
    /// salt/nonce/timestamp on every call — re-encrypting identical
    /// plaintext with fresh randomness never reproduces the same
    /// ciphertext bytes. A tier-1 resume PATCHes a byte-range CONTINUATION
    /// into an upload the server already has partial ciphertext for; if
    /// the continuation bytes come from a differently-keyed re-encryption,
    /// the assembled file is corrupt (silently — AES-GCM's tag only
    /// covers the ORIGINAL sealing, not a Frankenstein mix of two
    /// encryptions at different offsets). Persisting salt/nonce/ts lets
    /// the resume path deterministically reproduce byte-identical
    /// ciphertext from the (corruption-checked, unchanged) plaintext +
    /// the same PSK, so the continuation is genuinely the same stream.
    /// Not sensitive: salt/nonce/tag already ride in cleartext inside the
    /// wire `qfile` marker on every successful send (see `FileMarker.QFile`)
    /// — persisting them locally pre-send discloses nothing an eavesdropper
    /// wouldn't already see once the message actually goes out.
    public let saltHex: String
    public let nonceHex: String
    public let ts: Int64
    /// Recipient user id — needed to rebuild the exact AAD
    /// (`file:v2:{sender}:{recipient}:{ts}`) the original seal used.
    public let recipientUserId: String
    /// Filename passed to the original `upload()` call — the resume path
    /// re-sends the identical `FileMarker.QFile` fields.
    public let filename: String
    public let mime: String
    public let durationMs: Int64?
    public let timerOverrideSeconds: Int?
    /// W-TUSRESUME (security-review follow-up, 2026-07-02) — SHA-256 hex
    /// of the PSK bytes used for the ORIGINAL seal. `checkCorruption`
    /// only re-hashes the PLAINTEXT source file — it has no way to detect
    /// that the contact's PSK was rotated/re-bound between the failed
    /// attempt and the retry (e.g. re-verification, device re-pairing).
    /// A rotated PSK still passes the plaintext corruption check but
    /// makes `resumeUpload`'s `deriveFileKey` produce a DIFFERENT file
    /// key than the original attempt, so the re-sealed continuation bytes
    /// silently diverge from what the server already buffered at that
    /// offset — AES-GCM's tag only covers the final complete seal, not
    /// consistency across a byte-range continuation assembled from two
    /// different keys. `ChatContainer`/`ChatVoiceNoteSender` re-derive
    /// today's PSK for `recipientUserId` and hash it the same way before
    /// attempting a resume; a mismatch here is treated exactly like a
    /// corrupted source file (fall through to tier 3) rather than
    /// PATCHing a continuation that would assemble into an undecryptable
    /// file for the recipient. Hashing (not storing the PSK itself) keeps
    /// this field non-sensitive on the same reasoning as salt/nonce
    /// above — a one-way digest of key material reveals nothing about the
    /// key, same category as the plaintext SHA-256 above.
    public let pskFingerprintHex: String

    public init(
        fileId: String,
        clientMsgId: String,
        totalBytes: Int64,
        sourceSizeAtStart: Int64,
        sourceSha256AtStart: String,
        saltHex: String,
        nonceHex: String,
        ts: Int64,
        recipientUserId: String,
        filename: String,
        mime: String,
        pskFingerprintHex: String,
        durationMs: Int64? = nil,
        timerOverrideSeconds: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.fileId = fileId
        self.clientMsgId = clientMsgId
        self.totalBytes = totalBytes
        self.sourceSizeAtStart = sourceSizeAtStart
        self.sourceSha256AtStart = sourceSha256AtStart
        self.saltHex = saltHex
        self.nonceHex = nonceHex
        self.ts = ts
        self.recipientUserId = recipientUserId
        self.filename = filename
        self.mime = mime
        self.durationMs = durationMs
        self.timerOverrideSeconds = timerOverrideSeconds
        self.pskFingerprintHex = pskFingerprintHex
        self.createdAt = createdAt
    }
}

/// Keychain-backed store for `[clientMsgId: TusResumeState]`. Single
/// key (not one-key-per-upload) — mirrors `PendingGroupInviteStore`'s
/// rationale: avoids key-sprawl and makes "is there anything in flight"
/// trivial to answer without enumerating.
///
/// Moved off UserDefaults (2026-08-21, security review) — the map holds
/// `recipientUserId` (peer identity) and `pskFingerprintHex` (a one-way
/// SHA-256 of the PSK, not the key itself) per pending upload, both of
/// which are readable from an unencrypted UserDefaults plist via jailbreak
/// or local backup extraction. `kSecUseDataProtectionKeychain` is set on
/// every query: without it, SecItemAdd/SecItemUpdate/SecItemCopyMatching
/// silently fail with errSecMissingEntitlement in a bare SPM test host
/// (no app-level keychain-access-group entitlement) — Apple's documented
/// fix, and unconditionally correct for the real signed app target too.
public enum TusResumeStateStore {

    private static let keychainService = "com.bcrypto.qaudion.tusresume"
    private static let keychainAccount = "resume_state_v1"
    private static let legacyUserDefaultsKey = "qaudion.tus.resumeState.v1"

    /// Load the full map. Corrupted/missing data decodes to an empty
    /// map rather than throwing — this is best-effort local bookkeeping,
    /// never a hard dependency (see the corruption-check / graceful-
    /// degradation contract on the caller side in `TusUploadClient`).
    public static func loadAll() -> [String: TusResumeState] {
        #if canImport(Security)
        // One-time sweep of the pre-migration plaintext store so it
        // doesn't linger after the first Keychain-backed launch.
        UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKey)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return [:]
        }
        #else
        guard let data = UserDefaults.standard.data(forKey: legacyUserDefaultsKey) else { return [:] }
        #endif

        guard let decoded = try? JSONDecoder().decode([String: TusResumeState].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// Look up the resume state for a specific outbound message, if any.
    public static func load(clientMsgId: String) -> TusResumeState? {
        loadAll()[clientMsgId]
    }

    /// Persist (or overwrite) the resume state for `state.clientMsgId`.
    /// Called right after a successful `create()` in
    /// `TusUploadClient.upload()`, before the chunk loop starts.
    public static func save(_ state: TusResumeState) {
        var all = loadAll()
        all[state.clientMsgId] = state
        write(all)
    }

    /// Clear the resume state for a specific message. Called on: (a)
    /// successful upload completion (the whole send succeeded), (b) a
    /// resume attempt hitting `TusError.uploadNotFound` (stale — no
    /// longer resumable server-side), (c) corruption-check failure
    /// (source file changed/missing — the old record is meaningless).
    public static func clear(clientMsgId: String) {
        var all = loadAll()
        guard all.removeValue(forKey: clientMsgId) != nil else { return }
        write(all)
    }

    private static func write(_ all: [String: TusResumeState]) {
        guard let data = try? JSONEncoder().encode(all) else { return }

        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            for (k, v) in attributes { query[k] = v }
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("[TusResumeStateStore] SecItemAdd failed: \(addStatus)")
            }
            return
        }
        // Any other status: hard-reset.
        SecItemDelete(query as CFDictionary)
        for (k, v) in attributes { query[k] = v }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus != errSecSuccess {
            print("[TusResumeStateStore] SecItemAdd (after reset) failed: \(addStatus)")
        }
        #else
        UserDefaults.standard.set(data, forKey: legacyUserDefaultsKey)
        #endif
    }

    // MARK: - Corruption check

    /// Result of checking whether a resume attempt is safe to try.
    public enum CorruptionCheck: Equatable {
        /// Source file exists, size + hash match the persisted record —
        /// safe to attempt tier-1 resume.
        case resumable
        /// Source file is missing, changed size, or hashed differently
        /// since the upload began — resume must NOT be attempted; the
        /// caller should clear the stale record and go straight to a
        /// fresh upload (tier 3).
        case corrupted(reason: String)
    }

    /// Full re-hash of the file at `path` and comparison against `state`.
    /// The files this guards are attachment blobs already capped by the
    /// app's own size limits (10 MB images, voice notes far smaller), so
    /// a full SHA-256 pass is cheap relative to the upload it might save.
    ///
    /// - Parameter currentPskFingerprintHex: W-TUSRESUME (security-review
    ///   follow-up, 2026-07-02) — the SHA-256 fingerprint of TODAY's
    ///   resolved PSK for `state.recipientUserId`, computed the same way
    ///   `fingerprint(ofPsk:)` does. When supplied and it doesn't match
    ///   `state.pskFingerprintHex`, the resume is rejected exactly like a
    ///   changed source file: a rotated/re-bound PSK would make
    ///   `resumeUpload` re-derive a DIFFERENT file key than the original
    ///   attempt used, silently corrupting the byte-range continuation
    ///   (see `TusResumeState.pskFingerprintHex`'s doc for why the
    ///   plaintext-only check above can't catch this). `nil` by default —
    ///   a caller that hasn't resolved the PSK yet (or doesn't have
    ///   access to it at this call site) gets the pre-existing
    ///   plaintext-only check, same behavior as before this parameter
    ///   existed; callers that DO have the PSK in hand should always pass
    ///   it since it closes a real (if narrow) data-integrity gap.
    public static func checkCorruption(
        state: TusResumeState,
        sourcePath: String,
        currentPskFingerprintHex: String? = nil
    ) -> CorruptionCheck {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcePath) else {
            return .corrupted(reason: "source file missing at \(sourcePath)")
        }
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: sourcePath)
        } catch {
            return .corrupted(reason: "cannot stat source file: \(error.localizedDescription)")
        }
        let sizeOnDisk = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        guard sizeOnDisk == state.sourceSizeAtStart else {
            return .corrupted(reason: "size mismatch: on-disk=\(sizeOnDisk) recorded=\(state.sourceSizeAtStart)")
        }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        } catch {
            return .corrupted(reason: "cannot read source file: \(error.localizedDescription)")
        }
        let hashHex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard hashHex == state.sourceSha256AtStart else {
            return .corrupted(reason: "sha256 mismatch")
        }
        if let currentPskFingerprintHex = currentPskFingerprintHex,
           currentPskFingerprintHex != state.pskFingerprintHex {
            return .corrupted(reason: "psk fingerprint mismatch (rotated/re-bound since the original attempt)")
        }
        return .resumable
    }

    /// Convenience: hash + size for a freshly-read source blob, used at
    /// `create()` time to build the record that gets persisted.
    public static func fingerprint(of bytes: Data) -> (size: Int64, sha256Hex: String) {
        let hashHex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return (Int64(bytes.count), hashHex)
    }

    /// W-TUSRESUME (security-review follow-up) — SHA-256 fingerprint of
    /// PSK bytes, used both when persisting `TusResumeState.pskFingerprintHex`
    /// at upload time and when re-checking it at resume time. One-way
    /// digest — never reveals the key itself, same reasoning as
    /// `fingerprint(of:)` above for the plaintext source.
    public static func fingerprint(ofPsk psk: Data) -> String {
        SHA256.hash(data: psk).map { String(format: "%02x", $0) }.joined()
    }
}
