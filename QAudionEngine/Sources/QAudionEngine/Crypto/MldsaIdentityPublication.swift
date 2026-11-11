import Foundation
import CryptoKit

/// Second signature key of a device identity, published with the identity bundle (design notes
/// sections 5.1 to 5.3): the pure construction of what a publish carries, and the check of what a fetch returns.
/// Mirrors the Android `MldsaIdentityPublication` object. No I/O, no storage, no logging: the callers own those.
/// Nothing here throws; every failure is nil.
///
/// Publish: `build` derives the ML-DSA-87 key (generation 0) from the RFC 8032 Ed25519 identity seed and signs the
/// cross-certificate with both keys. Fetch: `verifyPeer` accepts a peer's fields only when all of them are present
/// and the certificate verifies against the Ed25519 key, uuid and device id of the same bundle.
///
/// Signing needs a large stack (about 108 KB): call `build` from a Task or a dispatch queue, never from a small
/// custom thread.
public enum MldsaIdentityPublication {

    /// The server fields of one publish, base64 (standard alphabet, padded). `mldsa_gen` is not sent: 0 is the
    /// server default and the only value it accepts.
    public struct Fields: Sendable, Equatable {
        public let pubB64: String
        public let createdMs: Int64
        public let edSigB64: String
        public let pqSigB64: String
        public let keyIdB64: String

        public init(pubB64: String, createdMs: Int64, edSigB64: String, pqSigB64: String, keyIdB64: String) {
            self.pubB64 = pubB64
            self.createdMs = createdMs
            self.edSigB64 = edSigB64
            self.pqSigB64 = pqSigB64
            self.keyIdB64 = keyIdB64
        }
    }

    /// A peer device key whose certificate verified against that peer's Ed25519 key.
    public struct VerifiedPeer: Sendable, Equatable {
        public let pub: Data
        public let keyId: Data
        public let createdMs: Int64
        public let gen: Int
    }

    private static let genV1 = 0
    private static let createdRecordDomain = "qaudion-mldsa-xc-created-v1"

    // MARK: - Device id

    /// Whether `deviceId` may be signed and sent with the fields: non-empty, at most 255 UTF-8 bytes, valid UTF-8
    /// (a Swift String always is), and no surrounding whitespace in the sense of Go's `unicode.IsSpace` (the server
    /// refuses that spelling instead of trimming it). The exact bytes are signed, never normalized.
    public static func isPublishableDeviceId(_ deviceId: String?) -> Bool {
        guard let deviceId, !deviceId.isEmpty else { return false }
        let bytes = Pqsig.XcFields.deviceIdBytes(deviceId)
        guard !bytes.isEmpty, bytes.count <= Pqsig.maxDeviceIdLen else { return false }
        guard let first = deviceId.unicodeScalars.first, let last = deviceId.unicodeScalars.last else { return false }
        return !isGoSpace(first.value) && !isGoSpace(last.value)
    }

    /// Go `unicode.IsSpace`. Foundation's whitespace sets differ from it, and the server uses Go's.
    static func isGoSpace(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return (0x2000...0x200A).contains(cp)
        }
    }

    // MARK: - Publish

    /// Builds the publish fields for (uuid, device, Ed25519 identity). `edSeed` is the RFC 8032 seed of `edPub`
    /// (checked by `Pqsig.deriveSeed`); `createdMs` is the fixed `mldsa_xc_created_ms` of this binding (see
    /// `createdMsFor`). Nil if any input is malformed or the certificate does not verify.
    public static func build(edSeed: Data, edPub: Data, uuidRaw: Data, deviceId: String, createdMs: Int64) -> Fields? {
        guard createdMs > 0, isPublishableDeviceId(deviceId) else { return nil }
        guard let key = Pqsig.keyFromIdentity(edSeed: edSeed, edPub: edPub, gen: genV1) else { return nil }
        let pub = key.publicKey.bytes()
        let xc = Pqsig.XcFields(
            uuid: uuidRaw, deviceId: Pqsig.XcFields.deviceIdBytes(deviceId), edPub: edPub, mldsaPub: pub,
            gen: genV1, createdMs: UInt64(createdMs))
        // Own check before anything leaves the device: a certificate that does not verify would only be refused.
        guard let sigs = Pqsig.signXC(xc, edSeed: edSeed, pq: key), Pqsig.verifyXC(xc, sigs) else { return nil }
        return Fields(
            pubB64: pub.base64EncodedString(), createdMs: createdMs,
            edSigB64: sigs.ed.base64EncodedString(), pqSigB64: sigs.pq.base64EncodedString(),
            keyIdB64: key.publicKey.keyId().base64EncodedString())
    }

    /// `mldsa_xc_created_ms` is fixed per (uuid, Ed25519 key, device id): the server refuses a different key under
    /// the same Ed25519 key and a republish must carry the same fields. `stored` is the record this function
    /// returned last time (`<hash>:<ms>`), or nil. Returns the created_ms to use and the record to persist. A record
    /// of another binding, or a malformed one, gives `nowMs` (a fresh binding).
    public static func createdMsFor(
        stored: String?, uuidRaw: Data, edPub: Data, deviceId: String, nowMs: Int64
    ) -> (createdMs: Int64, record: String) {
        var input = Data(createdRecordDomain.utf8)
        input.append(uuidRaw)
        input.append(edPub)
        input.append(Data(deviceId.utf8))
        let hash = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        if let stored, let idx = stored.firstIndex(of: ":"), idx != stored.startIndex,
           String(stored[stored.startIndex..<idx]) == hash,
           let ms = Int64(stored[stored.index(after: idx)...]), ms > 0 {
            return (ms, stored)
        }
        return (nowMs, "\(hash):\(nowMs)")
    }

    // MARK: - Fetch

    /// Verifies the fields of a fetched bundle. Every field the publish requires must be present, `gen` must be 0
    /// (anything else is reserved) and `keyIdB64`, if present, must be SHA-256 of the key. The certificate is
    /// checked against `edPub`, `uuidRaw` and `deviceId` of the same bundle, and `edPub` must be an acceptable
    /// Ed25519 key. Nil for an absent, partial or invalid set.
    public static func verifyPeer(
        pubB64: String?, createdMs: Int64?, edSigB64: String?, pqSigB64: String?, gen: Int?, keyIdB64: String?,
        uuidRaw: Data, deviceId: String?, edPub: Data
    ) -> VerifiedPeer? {
        guard let pubB64, !pubB64.isEmpty, let edSigB64, !edSigB64.isEmpty, let pqSigB64, !pqSigB64.isEmpty,
              let createdMs, createdMs > 0 else { return nil }
        guard (gen ?? genV1) == genV1, let deviceId, isPublishableDeviceId(deviceId),
              Ed25519IdentityKeyPolicy.isAcceptable(edPub) else { return nil }
        guard let pub = Data(base64Encoded: pubB64), pub.count == Pqsig.publicKeySize,
              let edSig = Data(base64Encoded: edSigB64), edSig.count == Pqsig.edSignatureSize,
              let pqSig = Data(base64Encoded: pqSigB64), pqSig.count == Pqsig.signatureSize else { return nil }
        let keyId = Data(SHA256.hash(data: pub))
        if let keyIdB64, !keyIdB64.isEmpty {
            guard let claimed = Data(base64Encoded: keyIdB64), claimed == keyId else { return nil }
        }
        let xc = Pqsig.XcFields(
            uuid: uuidRaw, deviceId: Pqsig.XcFields.deviceIdBytes(deviceId), edPub: edPub, mldsaPub: pub,
            gen: genV1, createdMs: UInt64(createdMs))
        guard Pqsig.verifyXC(xc, Pqsig.XcSignatures(ed: edSig, pq: pqSig)) else { return nil }
        return VerifiedPeer(pub: pub, keyId: keyId, createdMs: createdMs, gen: genV1)
    }
}
