import Foundation
import CryptoKit
import QAudionEngine

/// SEC-WIREUNIFY (2026-08-03) — iOS receive pipeline for the cross-platform
/// `qa_fa_announce:1` file-attachment scheme. Companion to
/// ``ChatFileAttachmentSender``; mirrors Android
/// `FileAttachmentReceiver.kt` + `InboundFileAttachmentDispatcher.kt`.
///
/// **Pipeline**:
///   1. Locate the wrap addressed to this device (single-device MVP —
///      `deviceId` = own userId's raw UUID bytes, same convention Android's
///      `PeerFileAttachmentRecipientResolver` uses on the sender side).
///   2. `FileAttachmentAnnounce.open` (X25519 ECDH + HKDF + AES-GCM) with
///      this device's long-term X25519 identity private key
///      (`DeviceKeyManager.currentKeys().x25519Priv`).
///   3. Download the FULL ciphertext blob in one GET (via the recipient
///      capability token when present, else owner-direct — the latter is
///      expected to fail for a genuine cross-user receive, matching
///      Android's tolerant-but-honest behavior). Unlike Android's
///      streamed ranged-GET receiver, iOS has no ranged-download
///      transport yet, so this reads the whole blob into memory before
///      parsing — acceptable for the realistic content sizes this pipeline
///      serves today (photos, voice notes, general files) and consistent
///      with every other iOS attachment receiver, all of which already
///      single-shot download. A true streaming receiver is a follow-up if
///      multi-GB "generic file" sends turn out to need it.
///   4. Parse sequential `ChunkRecord`s (8 B header: u32BE chunkIdx +
///      u32BE ciphertextLen, then ciphertext), verify the chunk index
///      matches the expected sequence (anti-reorder), and
///      `FileAttachmentCipher.openChunk` each — AEAD failure on any chunk
///      fails the whole receive (no partial file ever surfaces).
///   5. Write the recovered plaintext to a per-app cache file and return
///      its URL + the envelope's `mime`/`filename` for the chat bubble.
@MainActor
final class ChatFileAttachmentReceiver {

    enum ReceiveError: Error, LocalizedError {
        case notAuthenticated
        case noWrapForDevice
        case noIdentityKey
        case openFailed(String)
        case downloadFailed(String)
        case truncated(String)
        case decryptFailed(String)
        case writeFailed(String)
        /// ATT-1 — a `sg` signature is present but malformed (wrong length)
        /// or its canon could not be reconstructed. Always fatal — see the
        /// type doc on `receive(envelope:transportSenderId:)`.
        case signatureMalformed
        /// ATT-1 — a `sg` signature is present but does not verify under the
        /// sender's resolved identity key. Always fatal.
        case signatureInvalid
        /// ATT-1 — a `sg` signature is present but the sender's identity key
        /// could not be resolved at all (no pin, no server-published key).
        /// Treated the same as an invalid signature: there is nothing to
        /// verify against, so the envelope cannot be trusted.
        case signatureUnresolvable

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "Non autenticato"
            case .noWrapForDevice: return "Allegato non indirizzato a questo dispositivo"
            case .noIdentityKey: return "Chiave dispositivo mancante"
            case .openFailed(let m): return "Apertura chiave fallita: \(m)"
            case .downloadFailed(let m): return "Download fallito: \(m)"
            case .truncated(let m): return "File troncato: \(m)"
            case .decryptFailed(let m): return "Decrittazione fallita: \(m)"
            case .writeFailed(let m): return "Scrittura fallita: \(m)"
            case .signatureMalformed: return "Firma allegato malformata"
            case .signatureInvalid: return "Firma allegato non valida"
            case .signatureUnresolvable: return "Identità del mittente non verificabile"
            }
        }
    }

    struct Result {
        let localUrl: URL
        let mime: String
        let filename: String
        let byteLength: Int64
    }

    /// 5 GiB DoS guard — matches Android's `MAX_FILE_BYTES` check before
    /// any download IO.
    private static let maxFileBytes: Int64 = 5 * 1024 * 1024 * 1024

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    /// - Parameter transportSenderId: the WS `opaque_message` frame's
    ///   SERVER-STAMPED sender — NOT read from the envelope itself. ATT-1
    ///   (CRYPTO_PROTOCOL_AUDIT_2026-09-01.md backlog item 1) binds this into
    ///   the envelope's signature canon (see `FileAttachmentAnnounceSig`), so
    ///   a signature can never be re-attributed to a different transport
    ///   frame than the one it was actually signed for.
    ///
    ///   Verification contract: `envelope.sigB64` PRESENT and malformed,
    ///   unverifiable (sender identity cannot be resolved), or invalid is
    ///   always fatal — the envelope is dropped before the content key is
    ///   ever unwrapped, nothing is downloaded or written to disk.
    ///   `envelope.sigB64` ABSENT is accepted exactly as before (unsigned) —
    ///   no interop break for a peer that has not shipped signing yet.
    func receive(envelope: FileAttachmentAnnounceWireEnvelope, transportSenderId: String) async throws -> Result {
        guard let token = appState.authService.loadToken(), !token.isEmpty,
              let selfId = appState.currentUserId, !selfId.isEmpty else {
            throw ReceiveError.notAuthenticated
        }
        _ = token
        guard envelope.totalSizeBytes > 0, envelope.totalSizeBytes <= Self.maxFileBytes else {
            throw ReceiveError.truncated("declared size \(envelope.totalSizeBytes) out of bounds")
        }
        guard let myDeviceId = Self.uuidBytes(from: selfId),
              let fileId = Self.uuidBytes(from: envelope.fileId),
              let senderId = Self.uuidBytes(from: envelope.senderId),
              let senderEphPub = Data(base64Encoded: envelope.senderEphPubB64) else {
            throw ReceiveError.openFailed("malformed envelope identifiers")
        }

        guard let wrap = envelope.wraps.first(where: {
            guard let d = Data(base64Encoded: $0.deviceIdB64) else { return false }
            return d == myDeviceId
        }), let wrappedKey = Data(base64Encoded: wrap.wrappedContentKeyB64) else {
            throw ReceiveError.noWrapForDevice
        }

        let provider = appState.makeUploadProvider()

        // ATT-1 — verify BEFORE the content key is ever unwrapped (cheapest
        // check first, same "sig-verify-first" ordering `KmsPreBootstrap`
        // documents for its own receiver: protects against an attacker
        // forcing ECDH/AEAD work by spamming garbage envelopes). Only runs
        // when the sender actually signed; an absent `sg` is legacy-accepted
        // unchanged below.
        if let sigB64 = envelope.sigB64 {
            guard let sig = Data(base64Encoded: sigB64), sig.count == 64,
                  let transportSenderRaw = Self.uuidBytes(from: transportSenderId) else {
                throw ReceiveError.signatureMalformed
            }
            let sigWraps: [FileAttachmentAnnounceSig.DeviceWrap] = try envelope.wraps.map { w in
                guard let d = Data(base64Encoded: w.deviceIdB64),
                      let k = Data(base64Encoded: w.wrappedContentKeyB64) else {
                    throw ReceiveError.signatureMalformed
                }
                return FileAttachmentAnnounceSig.DeviceWrap(deviceId: d, wrappedContentKey: k)
            }
            guard let canon = FileAttachmentAnnounceSig.canon(
                fileId: fileId, senderUuid: senderId, recipientUuid: myDeviceId,
                senderEphemeralPub: senderEphPub, wraps: sigWraps, tusFileId: envelope.tusFileId,
                totalChunks: envelope.totalChunks, totalSizeBytes: envelope.totalSizeBytes,
                transportSenderId: transportSenderRaw
            ) else {
                throw ReceiveError.signatureMalformed
            }
            guard let resolution = await Self.resolveSignerIdentity(
                senderId: envelope.senderId, kmsClient: provider.kmsClient
            ) else {
                throw ReceiveError.signatureUnresolvable
            }
            guard FileAttachmentAnnounceSig.verify(
                canon: canon, signature: sig, signerIdentityKey: resolution.key
            ) else {
                throw ReceiveError.signatureInvalid
            }
            // Only commit the first-contact TOFU pin AFTER a successful
            // verify — never pin a server-supplied candidate key that never
            // actually produced a valid signature (mirrors
            // `QAudionCallIntegration.applyAuthenticatedSideEffects`, which
            // commits its own TOFU pin only from an `.authenticated`
            // verdict, never before).
            if resolution.isNewCandidate {
                _ = PeerIdentityPinStore().pinOrMatch(contactId: envelope.senderId, ed25519Pub: resolution.key)
            }
        }

        let vault = SovereignKeyVault()
        let deviceKeyManager = DeviceKeyManager(vault: vault, kmsClient: provider.kmsClient)
        guard let identityPriv = try? deviceKeyManager.currentKeys()?.x25519Priv, identityPriv.count == 32 else {
            throw ReceiveError.noIdentityKey
        }

        let contentKey: Data
        do {
            contentKey = try FileAttachmentAnnounce.open(
                myIdentityPriv: identityPriv, senderEphPub: senderEphPub, fileId: fileId,
                senderId: senderId, myDeviceId: myDeviceId, wrappedContentKey: wrappedKey)
        } catch {
            throw ReceiveError.openFailed(String(describing: error))
        }

        // Download the full ciphertext blob.
        let blob: Data
        do {
            if let hex = envelope.downloadTokenHex, let expMs = envelope.downloadTokenExpiresMs,
               let maxUses = envelope.downloadTokenMaxUses {
                let claim = DownloadTokenClaim(
                    fileId: envelope.tusFileId, expiresAtMs: expMs, maxUses: Int32(maxUses), tokenHex: hex)
                blob = try await provider.downloadTokenClient.downloadCiphertext(
                    fileId: envelope.tusFileId, claim: claim)
            } else {
                blob = try await provider.storageApi.downloadFile(fileId: envelope.tusFileId)
            }
        } catch {
            throw ReceiveError.downloadFailed(error.localizedDescription)
        }

        // Parse + decrypt sequential ChunkRecords.
        var plaintext = Data()
        plaintext.reserveCapacity(Int(envelope.totalSizeBytes))
        var offset = blob.startIndex
        for expectedIdx in 0..<envelope.totalChunks {
            guard blob.distance(from: offset, to: blob.endIndex) >= 8 else {
                throw ReceiveError.truncated("missing chunk-record header at chunk \(expectedIdx)")
            }
            let headerEnd = blob.index(offset, offsetBy: 8)
            let header = blob.subdata(in: offset..<headerEnd)
            let chunkIdx = Self.beUInt32(header, at: 0)
            let ctLen = Int(Self.beUInt32(header, at: 4))
            guard Int(chunkIdx) == expectedIdx else {
                throw ReceiveError.truncated("chunk_idx mismatch: expected \(expectedIdx), got \(chunkIdx)")
            }
            guard blob.distance(from: headerEnd, to: blob.endIndex) >= ctLen else {
                throw ReceiveError.truncated("missing ciphertext for chunk \(expectedIdx)")
            }
            let ctEnd = blob.index(headerEnd, offsetBy: ctLen)
            let ct = blob.subdata(in: headerEnd..<ctEnd)
            do {
                let opened = try FileAttachmentCipher.openChunk(
                    contentKey: contentKey, fileId: fileId, senderId: senderId,
                    chunkIdx: expectedIdx, totalChunks: envelope.totalChunks, ciphertext: ct)
                plaintext.append(opened)
            } catch {
                throw ReceiveError.decryptFailed("chunk \(expectedIdx): \(error)")
            }
            offset = ctEnd
        }
        guard Int64(plaintext.count) == envelope.totalSizeBytes else {
            throw ReceiveError.truncated("assembled \(plaintext.count) B, expected \(envelope.totalSizeBytes) B")
        }

        // Persist to the per-app caches folder, mirroring
        // ChatVoiceNoteReceiver's file_attachments convention.
        let outURL: URL
        do {
            let base = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = base.appendingPathComponent("file_attachments", isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let safeName = Self.sanitiseFilename(envelope.filename)
            outURL = dir.appendingPathComponent("\(envelope.fileId)__\(safeName)")
            try plaintext.write(to: outURL, options: [.atomic])
        } catch {
            throw ReceiveError.writeFailed(String(describing: error))
        }

        return Result(localUrl: outURL, mime: envelope.mime, filename: envelope.filename, byteLength: envelope.totalSizeBytes)
    }

    // MARK: - ATT-1 pinned-identity resolution

    /// Result of `resolveSignerIdentity`: which Ed25519 key to verify
    /// against, and whether it came from an existing Keychain pin
    /// (`isNewCandidate == false`) or is a first-contact server-published
    /// candidate that the caller should only pin AFTER a successful verify
    /// (`isNewCandidate == true`).
    private struct SignerResolution {
        let key: Data
        let isNewCandidate: Bool
    }

    /// ATT-1's pinned-identity resolver — the iOS counterpart of Android's
    /// `EnsurePeerTrustPinnedUseCase.resolvePeerIdentity`, reused the same
    /// way `KmsPreBootstrap`'s own receiver resolves the sender's identity
    /// before verifying its Ed25519 signature: Keychain TOFU pin FIRST
    /// (`PeerIdentityPinStore`, the same store `QAudionCallIntegration`'s
    /// handshake verifier and `AppState.wireHandshakeSigning` use); only
    /// when no pin exists yet does this fall back to the server-published
    /// key as a first-contact TOFU candidate — mirrored from
    /// `PeerTrustEvaluator.evaluate`'s and the call-handshake's own
    /// `resolveServerPeerKey` fallback shape.
    ///
    /// Returns `nil` ("Unresolved") only when NEITHER a pin nor a
    /// server-published key exists for `senderId` — the caller then drops
    /// the envelope rather than verifying a signature against nothing.
    /// Never trusts a key the WIRE envelope itself might claim to carry
    /// (this envelope carries none) — the whole point of pinned-identity
    /// resolution is that the verifier decides which key is authoritative,
    /// not the (potentially forged) message.
    private static func resolveSignerIdentity(
        senderId: String, kmsClient: BCryptoKmsClient
    ) async -> SignerResolution? {
        guard !senderId.isEmpty else { return nil }
        if let pinned = PeerIdentityPinStore().pinnedKey(contactId: senderId) {
            return SignerResolution(key: pinned, isNewCandidate: false)
        }
        guard let serverKey = await kmsClient.fetchUserIdentityKey(userId: senderId),
              serverKey.count == 32 else {
            return nil
        }
        return SignerResolution(key: serverKey, isNewCandidate: true)
    }

    // MARK: - Helpers

    private static func beUInt32(_ d: Data, at offset: Int) -> UInt32 {
        let base = d.startIndex
        return (UInt32(d[base + offset]) << 24) |
            (UInt32(d[base + offset + 1]) << 16) |
            (UInt32(d[base + offset + 2]) << 8) |
            UInt32(d[base + offset + 3])
    }

    private static func uuidBytes(from str: String) -> Data? {
        guard let u = UUID(uuidString: str) else { return nil }
        var tuple = u.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }

    /// Strip path separators + control chars from the peer-supplied
    /// filename before using it on disk — same defence Android's
    /// `InboundFileAttachmentDispatcher.sanitiseFilename` applies (the
    /// peer is untrusted; the `<fileId>__` prefix already blocks
    /// traversal but this stays defense-in-depth).
    private static func sanitiseFilename(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .unicodeScalars
            .filter { $0.value >= 0x20 && $0.value != 0x7F }
            .map(Character.init)
        let result = String(cleaned).trimmingCharacters(in: .whitespaces)
        if result.isEmpty || result == "." || result == ".." {
            return "attachment"
        }
        return String(result.prefix(255))
    }
}
