import Foundation
import CryptoKit

/// E2E-encrypted file transfer mirroring `qaudion-desktop/src/main/messaging/FileTransfer.ts`.
///
/// Wire protocol
/// ─────────────
///   Sender:
///     1. Pick PSK bound to recipient (fallback: first/primary PSK in vault).
///     2. Random 32-byte salt, 12-byte nonce, ts = now-ms.
///     3. fileKey = HKDF-SHA256(psk, salt, info="q-audion-file-key", L=32).
///     4. AAD = UTF-8("file:v2:{senderId}:{recipientId}:{ts}").
///     5. AES-256-GCM encrypt plaintext → ciphertext + 16B tag.
///     6. Upload ciphertext (without salt/nonce/tag) to /api/v1/files/upload.
///     7. Emit FileMarker JSON (hex-encoded binary fields) as chat body.
///   Recipient:
///     1. Parse `{"qfile":…}` marker from plaintext chat.
///     2. `marker.ts` is REQUIRED (v2 only — reject v1 legacy markers).
///     3. Rebuild AAD. Try PSK ordered: exact keyId match first, then all others.
///     4. AES-256-GCM decrypt → plaintext.
public final class FileTransfer: @unchecked Sendable {

    // MARK: - Wire constants (must match Desktop / Android)

    /// HKDF info string for per-file key derivation.
    private static let fileKeyInfo = CryptoConstants.HKDF_INFO_FILE_KEY
    /// AAD prefix for v2 file markers. v1 (no `ts`) is rejected on decrypt.
    private static let fileAadPrefix = "file:v2:"
    private static let saltSize = 32
    private static let nonceSize = 12
    private static let tagSize = 16

    // MARK: - Types

    /// JSON marker embedded in plaintext chat body.
    public struct FileMarker: Codable, Equatable {
        public struct QFile: Codable, Equatable {
            public let fileId: String
            public let name: String
            public let size: Int
            public let mime: String
            /// hex(32B) — HKDF salt.
            public let salt: String
            /// hex(12B) — AES-GCM nonce.
            public let nonce: String
            /// hex(16B) — AES-GCM tag.
            public let tag: String
            /// Vault key name (diagnostics + fast-path PSK selection).
            public let keyId: String
            /// Unix-ms timestamp embedded in AAD. v1 markers omit this and are rejected.
            public let ts: Int64
            /// W79 — recipient capability claim. When the sender owns the
            /// upload and the recipient is a different user, the sender
            /// mints this via `BCryptoDownloadTokenClient.issueToken`
            /// after upload and embeds it here. Recipients with a claim
            /// apply the 3 headers (`X-Download-Token` / `Expires-Ms` /
            /// `Max-Uses`) on `GET /api/v1/files/{id}`. Optional for
            /// backward compat with v2 markers (no claim) — those still
            /// decode and the receiver falls back to owner-direct fetch.
            public let downloadClaim: DownloadTokenClaim?
            /// W79 — voice-note duration in ms. Lets the chat UI render
            /// "🎤 Nota vocale (4.2s)" before downloading the audio.
            public let durationMs: Int64?

            public init(fileId: String, name: String, size: Int, mime: String,
                        salt: String, nonce: String, tag: String, keyId: String,
                        ts: Int64,
                        downloadClaim: DownloadTokenClaim? = nil,
                        durationMs: Int64? = nil) {
                self.fileId = fileId
                self.name = name
                self.size = size
                self.mime = mime
                self.salt = salt
                self.nonce = nonce
                self.tag = tag
                self.keyId = keyId
                self.ts = ts
                self.downloadClaim = downloadClaim
                self.durationMs = durationMs
            }

            private enum CodingKeys: String, CodingKey {
                case fileId, name, size, mime, salt, nonce, tag, keyId, ts
                case downloadClaim = "download_claim"
                case durationMs = "duration_ms"
            }
        }
        public let qfile: QFile

        public init(qfile: QFile) { self.qfile = qfile }
    }

    // MARK: - Dependencies

    public struct StorageApi {
        public let uploadFile: (_ data: Data, _ filename: String) async throws -> String
        public let downloadFile: (_ fileId: String) async throws -> Data
        /// W446 — optional progress-reporting variant. When supplied, the
        /// caller-provided closure is preferred over `uploadFile` so
        /// ``upload(recipientId:bytes:filename:mime:onProgress:)`` can
        /// report bytes-uploaded/total to the UI as chunks complete.
        /// `nil` by default — local-only UI plumbing, never touches the
        /// wire schema.
        public let uploadFileWithProgress: (
            (_ data: Data, _ filename: String,
             _ onProgress: ((Int64, Int64) -> Void)?) async throws -> String
        )?

        public init(
            uploadFile: @escaping (_ data: Data, _ filename: String) async throws -> String,
            downloadFile: @escaping (_ fileId: String) async throws -> Data,
            uploadFileWithProgress: (
                (_ data: Data, _ filename: String,
                 _ onProgress: ((Int64, Int64) -> Void)?) async throws -> String
            )? = nil
        ) {
            self.uploadFile = uploadFile
            self.downloadFile = downloadFile
            self.uploadFileWithProgress = uploadFileWithProgress
        }
    }

    public struct VaultEntry {
        public let keyId: String
        public let material: Data
        public init(keyId: String, material: Data) {
            self.keyId = keyId
            self.material = material
        }
    }

    public struct VaultAdapter {
        /// Return PSK bound to `contactId`, or nil.
        public let forContact: (_ contactId: String) -> VaultEntry?
        /// Return the primary/default PSK if no bound one is found.
        public let primary: () -> VaultEntry?
        /// Return all vault entries in priority order (bound first).
        public let allByPriority: () -> [VaultEntry]

        public init(
            forContact: @escaping (_ contactId: String) -> VaultEntry?,
            primary: @escaping () -> VaultEntry?,
            allByPriority: @escaping () -> [VaultEntry]
        ) {
            self.forContact = forContact
            self.primary = primary
            self.allByPriority = allByPriority
        }
    }

    private let storage: StorageApi
    private let vault: VaultAdapter
    private let selfUserId: String

    public init(storage: StorageApi, vault: VaultAdapter, selfUserId: String) {
        self.storage = storage
        self.vault = vault
        self.selfUserId = selfUserId
    }

    // MARK: - Upload

    /// Encrypt `bytes`, upload ciphertext, return a marker ready for the chat body.
    ///
    /// - Parameter onProgress: optional local-UI callback,
    ///   `(bytesUploaded, totalBytes)`, forwarded to the storage layer's
    ///   `uploadFileWithProgress` when the caller wired one (see
    ///   ``StorageApi``). Ignored (never called) when the caller only
    ///   supplied the plain `uploadFile` closure. `nil` by default so
    ///   existing call sites keep compiling unchanged.
    public func upload(
        recipientId: String,
        bytes: Data,
        filename: String,
        mime: String,
        onProgress: ((Int64, Int64) -> Void)? = nil
    ) async throws -> FileMarker {
        guard let psk = vault.forContact(recipientId) ?? vault.primary() else {
            throw FileTransferError.noPskAvailable
        }

        let salt = Self.randomBytes(Self.saltSize)
        let nonceBytes = Self.randomBytes(Self.nonceSize)
        let ts = Int64(Date().timeIntervalSince1970 * 1000)

        let fileKey = Self.deriveFileKey(psk: psk.material, salt: salt)
        let aad = Self.buildFileAad(senderId: selfUserId, recipientId: recipientId, ts: ts)

        // AES-256-GCM seal.
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let sealed = try AES.GCM.seal(bytes, using: fileKey, nonce: nonce, authenticating: aad)
        let ciphertext = sealed.ciphertext
        let tag = sealed.tag

        // Upload ONLY the ciphertext — salt/nonce/tag ride in the chat marker.
        let fileId: String
        if let withProgress = storage.uploadFileWithProgress {
            fileId = try await withProgress(ciphertext, filename, onProgress)
        } else {
            fileId = try await storage.uploadFile(ciphertext, filename)
        }

        return FileMarker(qfile: .init(
            fileId: fileId,
            name: filename,
            size: bytes.count,
            mime: mime,
            salt: Self.hex(salt),
            nonce: Self.hex(nonceBytes),
            tag: Self.hex(tag),
            keyId: psk.keyId,
            ts: ts
        ))
    }

    // MARK: - Download

    /// Download + decrypt the file referenced by `marker`.
    /// `senderId` is the OTHER side (uploader).
    public func download(marker: FileMarker, senderId: String) async throws -> Data {
        let f = marker.qfile

        // v1 markers (no ts) are rejected — matches Desktop/Android policy.
        guard f.ts > 0 else {
            throw FileTransferError.legacyV1MarkerRejected
        }

        let salt = try Self.unhex(f.salt, expected: Self.saltSize, field: "salt")
        let nonceBytes = try Self.unhex(f.nonce, expected: Self.nonceSize, field: "nonce")
        let tag = try Self.unhex(f.tag, expected: Self.tagSize, field: "tag")

        let ciphertext = try await storage.downloadFile(f.fileId)

        let aad = Self.buildFileAad(senderId: senderId, recipientId: selfUserId, ts: f.ts)
        let nonce = try AES.GCM.Nonce(data: nonceBytes)

        // Try exact keyId first (fast path), then every other PSK. Mirrors
        // Desktop behavior: sender may have rotated bindings since upload.
        let all = vault.allByPriority()
        guard !all.isEmpty else { throw FileTransferError.emptyVault }
        let ordered = all.filter { $0.keyId == f.keyId } + all.filter { $0.keyId != f.keyId }

        for entry in ordered {
            let fileKey = Self.deriveFileKey(psk: entry.material, salt: salt)
            do {
                let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
                return try AES.GCM.open(sealed, using: fileKey, authenticating: aad)
            } catch {
                continue
            }
        }
        throw FileTransferError.noPskDecrypted
    }

    // MARK: - Marker parsing

    /// Parse an incoming chat body for a `{"qfile":…}` marker.
    /// Returns nil on any mismatch (not JSON, not a qfile, missing field, …).
    public static func tryParseMarker(text: String) -> FileMarker? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FileMarker.self, from: data)
    }

    /// Serialize a marker as JSON text suitable for dropping into a chat body.
    public static func serializeMarker(_ marker: FileMarker) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(marker)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Internals

    private static func deriveFileKey(psk: Data, salt: Data) -> SymmetricKey {
        let ikm = SymmetricKey(data: psk)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: fileKeyInfo,
            outputByteCount: 32
        )
    }

    private static func buildFileAad(senderId: String, recipientId: String, ts: Int64) -> Data {
        return Data("\(fileAadPrefix)\(senderId):\(recipientId):\(ts)".utf8)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }

    private static func hex(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func unhex(_ string: String, expected: Int, field: String) throws -> Data {
        guard string.count == expected * 2 else {
            throw FileTransferError.badHexField(field, string.count)
        }
        var out = Data(capacity: expected)
        var idx = string.startIndex
        while idx < string.endIndex {
            let next = string.index(idx, offsetBy: 2)
            guard let byte = UInt8(string[idx..<next], radix: 16) else {
                throw FileTransferError.badHexField(field, string.count)
            }
            out.append(byte)
            idx = next
        }
        return out
    }
}

public enum FileTransferError: Error, Equatable {
    case noPskAvailable
    case emptyVault
    case noPskDecrypted
    case legacyV1MarkerRejected
    case badHexField(String, Int)
}
