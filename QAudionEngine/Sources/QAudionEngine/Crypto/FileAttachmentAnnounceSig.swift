import Foundation
import CryptoKit

/// ATT-1 (`docs/security/CRYPTO_PROTOCOL_AUDIT_2026-09-01.md`, backlog item 1,
/// Android reference finding — this is the iOS port) — Ed25519 signature over
/// the `qa_fa_announce:1` file-attachment / voice-note announce envelope.
///
/// # Why this exists
///
/// `FileAttachmentAnnounce` (this same directory) is an ANONYMOUS
/// ephemeral-X25519-to-static-recipient-identity-key exchange: any holder of
/// the recipient's PUBLISHED X25519 key — including a malicious or
/// compromised server, which can read that key off the same directory the
/// real sender fetches it from — can mint its own ephemeral keypair,
/// encapsulate against it, and push a forged `qa_fa_announce:1` envelope that
/// the client will attribute to whatever `sender_id` the transport frame
/// carries. Nothing today ties the envelope to the SENDER's own long-term
/// identity. This type closes that gap by having the sender co-sign the
/// envelope with its existing Ed25519 DEVICE-IDENTITY key — the SAME key
/// `HandshakeTranscript.sign`/`KmsHsBundleV1.sign` already use for the call
/// handshake and the KMS pre-bootstrap message-ratchet-seed envelope — and
/// having the receiver verify against the sender's PINNED identity before
/// ever installing the content key.
///
/// # Canonical signed bytes (FROZEN once shipped)
///
/// ```
/// canon = domain_tag                              # ASCII, NOT length-prefixed
///       || envelope_version(1B)                    # signed-canon format version
///       || file_id(16B)
///       || sender_uuid(16B)
///       || recipient_uuid(16B)                      # the addressed device's raw UUID —
///                                                    #   today == the single recipient
///                                                    #   device's id (MVP, one device/user);
///                                                    #   binds a signed envelope to the ONE
///                                                    #   recipient it was signed for, so it
///                                                    #   cannot be replayed to a different peer
///       || sender_ephemeral_pub(32B)
///       || n_wraps(1B) || (device_id(16B) || LP(wrapped_content_key))*
///       || LP(tus_file_id)
///       || total_chunks(4B BE)
///       || total_size_bytes(8B BE, two's-complement bit pattern)
///       || transport_sender_id(16B)                 # the WS/opaque_message frame's
///                                                    #   SERVER-STAMPED sender — binds the
///                                                    #   signature to the delivery channel,
///                                                    #   not just the envelope's own claimed
///                                                    #   `sender_uuid`; a signature that only
///                                                    #   covered the claimed field would still
///                                                    #   let a malicious server relabel whose
///                                                    #   transport frame it rides on
/// ```
///
/// `LP(x) = u16_BE(len(x)) || x` — same convention as `HandshakeTranscript.appendLP`.
///
/// # Crypto
///
/// RFC 8032 pure Ed25519 via CryptoKit `Curve25519.Signing`, byte-compatible
/// with Android BouncyCastle `Ed25519Signer` / Desktop `@noble/curves`, same
/// primitive `HandshakeTranscript`/`KmsHsBundleV1` already use. `verify`
/// never throws — malformed input or a bad signature both return `false`
/// (fail-closed), matching those two types' own contract exactly.
///
/// # Compatibility
///
/// The signature travels as a NEW OPTIONAL field on the already-extensible
/// `qa_fa_announce:1` envelope (`FileAttachmentAnnounceWireEnvelope.sigB64`).
/// A legacy peer that has not shipped this simply omits the field; the
/// receiver's contract (enforced at the call site, not here) is: present +
/// invalid => always fatal (drop, never install/save); absent => accept as
/// unsigned, exactly as today. This mirrors `HandshakeSigner`'s
/// optional-but-checked signature field on the call path.
public enum FileAttachmentAnnounceSig {

    /// Signed-canon format version. Independent of the `qa_fa_announce:1`
    /// wire-type string's own ":1" suffix — this only bumps if THIS byte
    /// layout changes, not on unrelated wire-envelope additions.
    public static let envelopeVersion: UInt8 = 1

    /// Domain separation tag. Deliberately distinct from every other signed
    /// transcript in this codebase (`HandshakeTranscript`'s
    /// `qaudion-handshake-sig-v1`/`-v2`, `KmsHsBundleV1`'s
    /// `qa-kms-hs-offer-v1`/`qa-kms-hs-accept-v1`) so a signature computed
    /// for one can never be replayed as valid input to another.
    private static let domain: Data = Data("qaudion-fa-announce-sig-v1".utf8)

    /// One `{deviceId, wrappedContentKey}` pair from the envelope's `w` array,
    /// in RAW (already base64-decoded) form, for canon construction. Every
    /// wrap the envelope carries is bound — not just the one addressed to the
    /// verifying device — so a relay cannot drop or substitute another
    /// recipient device's wrap without invalidating the signature.
    public struct DeviceWrap: Equatable {
        public let deviceId: Data
        public let wrappedContentKey: Data

        public init(deviceId: Data, wrappedContentKey: Data) {
            self.deviceId = deviceId
            self.wrappedContentKey = wrappedContentKey
        }
    }

    /// `LP(x) = u16_BE(len(x)) || x`. Same convention as
    /// `HandshakeTranscript.appendLP` — kept as a private duplicate rather
    /// than a shared helper so this type has no compile-time coupling to
    /// `HandshakeTranscript`'s (unrelated) domain and transcript shape.
    private static func appendLP(_ out: inout Data, _ bytes: Data) -> Bool {
        guard bytes.count <= 0xFFFF else { return false }
        out.append(UInt8((bytes.count >> 8) & 0xFF))
        out.append(UInt8(bytes.count & 0xFF))
        out.append(bytes)
        return true
    }

    /// Build the canonical signed bytes. Returns `nil` only for pathological
    /// input that cannot be encoded at all (a non-16-byte id, a wrap count
    /// above 255, a wrap or tus-file-id field longer than 65535 bytes) —
    /// never throws/traps on adversarial peer input, mirroring
    /// `HandshakeTranscript.advEnc`'s and `KmsHsBundleV1`'s own
    /// never-crash-on-untrusted-bytes discipline. A `nil` canon means the
    /// caller cannot verify and must treat the signature as invalid (drop),
    /// exactly like a signature that verifies to `false`.
    public static func canon(
        fileId: Data,
        senderUuid: Data,
        recipientUuid: Data,
        senderEphemeralPub: Data,
        wraps: [DeviceWrap],
        tusFileId: String,
        totalChunks: Int,
        totalSizeBytes: Int64,
        transportSenderId: Data
    ) -> Data? {
        guard fileId.count == 16, senderUuid.count == 16, recipientUuid.count == 16,
              senderEphemeralPub.count == 32, transportSenderId.count == 16,
              wraps.count <= 0xFF else { return nil }

        var out = Data()
        out.append(domain)
        out.append(envelopeVersion)
        out.append(fileId)
        out.append(senderUuid)
        out.append(recipientUuid)
        out.append(senderEphemeralPub)
        out.append(UInt8(wraps.count))
        for wrap in wraps {
            guard wrap.deviceId.count == 16 else { return nil }
            out.append(wrap.deviceId)
            guard appendLP(&out, wrap.wrappedContentKey) else { return nil }
        }
        guard appendLP(&out, Data(tusFileId.utf8)) else { return nil }
        var chunksBe = UInt32(truncatingIfNeeded: totalChunks).bigEndian
        out.append(withUnsafeBytes(of: &chunksBe) { Data($0) })
        var sizeBe = UInt64(bitPattern: totalSizeBytes).bigEndian
        out.append(withUnsafeBytes(of: &sizeBe) { Data($0) })
        out.append(transportSenderId)
        return out
    }

    /// Sign `canon` with the sender's 32-byte raw Ed25519 identity seed
    /// (`SovereignIdentityManager.SovereignIdentity.signingPrivate` — the
    /// SAME long-term device-identity key `HandshakeTranscript.sign` /
    /// `KmsHsBundleV1.sign` already use). Returns the 64-byte detached
    /// signature. Throws only on a malformed seed.
    public static func sign(canon: Data, signingPrivateKeyRaw: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKeyRaw)
        return try key.signature(for: canon)
    }

    /// Verify a 64-byte detached Ed25519 signature over `canon` under the
    /// signer's 32-byte raw Ed25519 public identity key. Fail-closed: any
    /// malformed input or a bad signature returns `false` — never throws.
    public static func verify(canon: Data, signature: Data, signerIdentityKey: Data) -> Bool {
        guard signature.count == 64, signerIdentityKey.count == 32 else { return false }
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: signerIdentityKey) else {
            return false
        }
        return pub.isValidSignature(signature, for: canon)
    }
}
