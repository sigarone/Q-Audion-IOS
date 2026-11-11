import Foundation
import CryptoKit
import CLiboqs
#if canImport(Security)
import Security
#endif

/// ML-DSA-87 (FIPS 204) helpers and the hybrid Ed25519 + ML-DSA-87 signature encodings, mirroring the server's
/// `internal/pqsig` and the Android `Pqsig` object. Library only: no call site, no wire change, no storage.
///
/// Fixed here:
///  - ML-DSA-87 only, pure mode with a FIPS 204 context string, never the pre-hash variant.
///  - One implementation on every iOS version: the vendored mldsa-native tree in CLiboqs (see PROVENANCE.md there).
///  - Production signing is hedged: every signature draws 32 fresh bytes from `SecRandomCopyBytes`. There is no
///    deterministic signing entry point in this file; the tests call the C layer with a zero `rnd` directly.
///  - Nothing here throws to a caller: producers return nil, verifiers return false, on any malformed input.
///
/// Ed25519 uses CryptoKit with the RFC 8032 32-byte seed (`rawRepresentation`). CryptoKit signs
/// non-deterministically, so Ed25519 signatures are only ever compared by verification.
public enum Pqsig {

    // MARK: - Constants

    /// Longest deviceId (bytes) `encodeXC` accepts.
    public static let maxDeviceIdLen = 255

    /// FIPS 204 contexts, exactly those of the shared vectors.
    public static let ctxHandshake = "qaudion-handshake-sig-v7"
    public static let ctxXCert = "qaudion-identity-xcert-v1"

    public static let seedSize = 32
    public static let publicKeySize = 2592
    public static let signatureSize = 4627
    public static let keyIdSize = 32
    public static let edSeedSize = 32
    public static let edPublicSize = 32
    public static let edSignatureSize = 64
    public static let hybridSigSize = edSignatureSize + signatureSize // 4691
    public static let dtlsFpSize = 33
    public static let extxSize = 32
    public static let uuidSize = 16

    public static let kindOffer: UInt8 = 0x01
    public static let kindAccept: UInt8 = 0x02

    private static let secretKeySize = Int(QA_MLDSA87_SECRET_KEY_BYTES)
    private static let rndSize = Int(QA_MLDSA87_RND_BYTES)

    private static let xcPrefix = Array("qaudion-mldsa-xcert-v1".utf8) // 22 B
    private static let htPrefix = Array("qaudion-hs-hybrid-v1".utf8) // 20 B
    private static let hybridEdPrefix = Array("qaudion-hs-hybrid-ed25519-v1".utf8)
    private static let seedSalt = Array("qaudion-mldsa87-seed-v1".utf8)
    private static let seedInfoPrefix = Array("qaudion-identity-mldsa87".utf8)

    // MARK: - Keys

    /// ML-DSA-87 public key (2592 bytes).
    public struct MlDsaPublicKey: Sendable {
        fileprivate let raw: [UInt8]

        /// The 2592-byte encoding.
        public func bytes() -> Data { Data(raw) }

        /// SHA-256(mldsaPub), the 32-byte key identifier.
        public func keyId() -> Data { Data(Pqsig.sha256Bytes(raw)) }

        /// Pure-mode verification of `sig` over `msg` under `ctx`. Any malformed input gives false.
        public func verify(_ msg: Data, _ sig: Data, ctx: String) -> Bool {
            guard sig.count == Pqsig.signatureSize, let c = Pqsig.ctxBytes(ctx) else { return false }
            let m = [UInt8](msg)
            let s = [UInt8](sig)
            let rc = raw.withUnsafeBufferPointer { pk in
                s.withUnsafeBufferPointer { sp in
                    m.withUnsafeBufferPointer { mp in
                        c.withUnsafeBufferPointer { cp in
                            qa_mldsa87_verify_pure(sp.baseAddress, mp.baseAddress, mp.count,
                                                   cp.baseAddress, cp.count, pk.baseAddress)
                        }
                    }
                }
            }
            return rc == 0
        }
    }

    /// ML-DSA-87 private key, built from the 32-byte seed. The 4896-byte secret key lives in a locked buffer that
    /// is zeroed when the key is released.
    public final class MlDsaPrivateKey: @unchecked Sendable {
        private let secret: SecureBytes
        public let publicKey: MlDsaPublicKey

        fileprivate init(secret: SecureBytes, publicKey: MlDsaPublicKey) {
            self.secret = secret
            self.publicKey = publicKey
        }

        /// Pure-mode, hedged ML-DSA-87 signature of `msg` under `ctx` (4627 bytes), or nil on any failure.
        /// Two calls give two different valid signatures.
        public func sign(_ msg: Data, ctx: String) -> Data? {
            guard let c = Pqsig.ctxBytes(ctx), var rnd = Pqsig.randomBytes(Pqsig.rndSize) else { return nil }
            defer { Pqsig.wipe(&rnd) }
            let m = [UInt8](msg)
            var sig = [UInt8](repeating: 0, count: Pqsig.signatureSize)
            let rc: Int32 = secret.withUnsafeBytes { skBuf in
                let sk = skBuf.bindMemory(to: UInt8.self)
                return sig.withUnsafeMutableBufferPointer { sp in
                    m.withUnsafeBufferPointer { mp in
                        c.withUnsafeBufferPointer { cp in
                            rnd.withUnsafeBufferPointer { rp in
                                qa_mldsa87_sign_pure(sp.baseAddress, mp.baseAddress, mp.count,
                                                     cp.baseAddress, cp.count, rp.baseAddress, sk.baseAddress)
                            }
                        }
                    }
                }
            }
            return rc == 0 ? Data(sig) : nil
        }
    }

    /// Derives the ML-DSA-87 key seed from the device Ed25519 identity:
    /// `xi = HKDF-SHA256(IKM = edSeed, salt = "qaudion-mldsa87-seed-v1",
    ///                   info = "qaudion-identity-mldsa87" || edPub || BE16(gen), L = 32)`.
    ///
    /// `edSeed` must be the RFC 8032 32-byte seed and `edPub` the matching public key (recomputed from the seed
    /// and compared in constant time): another identity's key or a stored expanded scalar gives nil.
    /// `gen` is 0 in v1, valid range 0...65535. Prefer `keyFromIdentity`, which does not hand `xi` to the caller.
    public static func deriveSeed(edSeed: Data, edPub: Data, gen: Int) -> Data? {
        guard var xi = deriveSeedBytes(edSeed: edSeed, edPub: edPub, gen: gen) else { return nil }
        defer { wipe(&xi) }
        return Data(xi)
    }

    /// `deriveSeed` followed by `keyFromSeed`; the intermediate seed is wiped.
    public static func keyFromIdentity(edSeed: Data, edPub: Data, gen: Int) -> MlDsaPrivateKey? {
        guard var xi = deriveSeedBytes(edSeed: edSeed, edPub: edPub, gen: gen) else { return nil }
        defer { wipe(&xi) }
        return keyFromSeedBytes(xi)
    }

    /// FIPS 204 `KeyGen_internal(xi)` for ML-DSA-87 from a 32-byte `seed`; nil if the seed is malformed.
    public static func keyFromSeed(_ seed: Data) -> MlDsaPrivateKey? {
        guard seed.count == seedSize else { return nil }
        var s = [UInt8](seed)
        defer { wipe(&s) }
        return keyFromSeedBytes(s)
    }

    /// Decodes a 2592-byte ML-DSA-87 public key; nil if malformed.
    public static func parsePublicKey(_ b: Data) -> MlDsaPublicKey? {
        b.count == publicKeySize ? MlDsaPublicKey(raw: [UInt8](b)) : nil
    }

    /// Hedged pure ML-DSA-87 signature (see `MlDsaPrivateKey.sign`).
    public static func sign(_ key: MlDsaPrivateKey, _ msg: Data, ctx: String) -> Data? {
        key.sign(msg, ctx: ctx)
    }

    /// Pure ML-DSA-87 verification (see `MlDsaPublicKey.verify`).
    public static func verify(_ key: MlDsaPublicKey?, _ msg: Data, _ sig: Data, ctx: String) -> Bool {
        key?.verify(msg, sig, ctx: ctx) ?? false
    }

    // MARK: - Cross-certificate

    /// Fields of the cross-certificate statement XC. `deviceId` is the exact UTF-8 byte string as registered
    /// (non-empty, at most `maxDeviceIdLen`, valid UTF-8, never normalized); `uuid` is `uuid_raw`, 16 bytes in
    /// RFC 4122 network order; `createdMs` is `mldsa_xc_created_ms` (BE64).
    public struct XcFields: Sendable {
        public var uuid: Data
        public var deviceId: Data
        public var edPub: Data
        public var mldsaPub: Data
        public var gen: Int
        public var createdMs: UInt64

        public init(uuid: Data, deviceId: Data, edPub: Data, mldsaPub: Data, gen: Int, createdMs: UInt64) {
            self.uuid = uuid
            self.deviceId = deviceId
            self.edPub = edPub
            self.mldsaPub = mldsaPub
            self.gen = gen
            self.createdMs = createdMs
        }

        /// The UTF-8 bytes of a string exactly as stored (no normalization).
        public static func deviceIdBytes(_ s: String) -> Data { Data(s.utf8) }
    }

    /// Both signatures over XC: `ed` 64 B pure Ed25519, `pq` 4627 B ML-DSA-87 under `ctxXCert`.
    public struct XcSignatures: Sendable {
        public var ed: Data
        public var pq: Data

        public init(ed: Data, pq: Data) {
            self.ed = ed
            self.pq = pq
        }
    }

    /// XC = "qaudion-mldsa-xcert-v1" || uuid_raw[16] || BE16(len(deviceId)) || deviceId || edPub[32] ||
    /// SHA-256(mldsaPub)[32] || BE16(gen) || BE64(createdMs). Nil on any malformed field.
    public static func encodeXC(_ f: XcFields) -> Data? {
        guard f.uuid.count == uuidSize, f.edPub.count == edPublicSize, f.mldsaPub.count == publicKeySize,
              !f.deviceId.isEmpty, f.deviceId.count <= maxDeviceIdLen, isStrictUTF8([UInt8](f.deviceId)),
              (0...0xFFFF).contains(f.gen)
        else { return nil }
        var out = xcPrefix
        out += [UInt8](f.uuid)
        out += be16(f.deviceId.count)
        out += [UInt8](f.deviceId)
        out += [UInt8](f.edPub)
        out += sha256Bytes([UInt8](f.mldsaPub))
        out += be16(f.gen)
        out += be64(f.createdMs)
        return Data(out)
    }

    /// Signs XC with both keys (`edSeed` is the RFC 8032 seed of the identity key). Nil on any failure.
    public static func signXC(_ f: XcFields, edSeed: Data, pq: MlDsaPrivateKey) -> XcSignatures? {
        guard let xc = encodeXC(f), let edSig = edSign(edSeed, xc), let pqSig = pq.sign(xc, ctx: ctxXCert)
        else { return nil }
        return XcSignatures(ed: edSig, pq: pqSig)
    }

    /// Verifies both cross-certificate signatures: the Ed25519 key endorses the ML-DSA key and the ML-DSA key
    /// (`f.mldsaPub`) endorses the Ed25519 key. Both must verify.
    public static func verifyXC(_ f: XcFields, _ sigs: XcSignatures) -> Bool {
        guard let xc = encodeXC(f), let pk = parsePublicKey(f.mldsaPub) else { return false }
        let edOk = edVerify(f.edPub, xc, sigs.ed)
        let pqOk = pk.verify(xc, sigs.pq, ctx: ctxXCert)
        return edOk && pqOk
    }

    // MARK: - Hybrid handshake signature

    /// Inputs of the signed handshake message HT. `kind` is `kindOffer` or `kindAccept`; `dtlsFpPeer` must be
    /// empty for OFFER and 33 bytes for ACCEPT; `capsx` at most 65535 bytes.
    public struct HtFields: Sendable {
        public var kind: UInt8
        public var bundleHash: Data
        public var edPub: Data
        public var mldsaKeyId: Data
        public var dtlsFpSelf: Data
        public var dtlsFpPeer: Data
        public var capsx: Data
        public var extx: Data

        public init(kind: UInt8, bundleHash: Data, edPub: Data, mldsaKeyId: Data, dtlsFpSelf: Data,
                    dtlsFpPeer: Data, capsx: Data, extx: Data) {
            self.kind = kind
            self.bundleHash = bundleHash
            self.edPub = edPub
            self.mldsaKeyId = mldsaKeyId
            self.dtlsFpSelf = dtlsFpSelf
            self.dtlsFpPeer = dtlsFpPeer
            self.capsx = capsx
            self.extx = extx
        }
    }

    /// HT = "qaudion-hs-hybrid-v1" || u8(kind) || SHA-256(T) || edPub || mldsaKeyId || DTLSFP_self[33] ||
    /// (ACCEPT only) DTLSFP_peer[33] || BE16(len(CAPSX)) || CAPSX || EXTX[32]. Nil on any malformed field.
    public static func encodeHT(_ f: HtFields) -> Data? {
        let peerOk: Bool
        switch f.kind {
        case kindOffer: peerOk = f.dtlsFpPeer.isEmpty
        case kindAccept: peerOk = f.dtlsFpPeer.count == dtlsFpSize
        default: peerOk = false
        }
        guard peerOk, f.bundleHash.count == 32, f.edPub.count == edPublicSize, f.mldsaKeyId.count == keyIdSize,
              f.dtlsFpSelf.count == dtlsFpSize, f.extx.count == extxSize, f.capsx.count <= 0xFFFF
        else { return nil }
        var out = htPrefix
        out.append(f.kind)
        out += [UInt8](f.bundleHash)
        out += [UInt8](f.edPub)
        out += [UInt8](f.mldsaKeyId)
        out += [UInt8](f.dtlsFpSelf)
        out += [UInt8](f.dtlsFpPeer)
        out += be16(f.capsx.count)
        out += [UInt8](f.capsx)
        out += [UInt8](f.extx)
        return Data(out)
    }

    /// Returns sigEd[64] || sigPq[4627] (4691 B) over `ht`: sigEd = Ed25519(edSk, "qaudion-hs-hybrid-ed25519-v1" ||
    /// HT), sigPq = hedged ML-DSA-87 under `ctxHandshake`. Nil on any failure.
    public static func signHybrid(_ ht: Data, edSeed: Data, pq: MlDsaPrivateKey) -> Data? {
        guard let pqSig = pq.sign(ht, ctx: ctxHandshake), let edSig = edSign(edSeed, hybridEdMessage(ht))
        else { return nil }
        return edSig + pqSig
    }

    /// Verifies a 4691-byte hybrid signature over `ht`: both halves must verify.
    public static func verifyHybrid(_ ht: Data, _ sig: Data, edPub: Data, pq: MlDsaPublicKey?) -> Bool {
        guard sig.count == hybridSigSize, edPub.count == edPublicSize, let pq = pq else { return false }
        let bytes = [UInt8](sig)
        let edOk = edVerify(edPub, hybridEdMessage(ht), Data(bytes[0..<edSignatureSize]))
        let pqOk = pq.verify(ht, Data(bytes[edSignatureSize...]), ctx: ctxHandshake)
        return edOk && pqOk
    }

    // MARK: - Helpers

    private static func deriveSeedBytes(edSeed: Data, edPub: Data, gen: Int) -> [UInt8]? {
        guard edSeed.count == edSeedSize, edPub.count == edPublicSize, (0...0xFFFF).contains(gen),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: edSeed)
        else { return nil }
        let derived = [UInt8](key.publicKey.rawRepresentation)
        guard constantTimeEqual(derived, [UInt8](edPub)) else { return nil }
        let info = Data(seedInfoPrefix + [UInt8](edPub) + be16(gen))
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: edSeed), salt: Data(seedSalt), info: info,
            outputByteCount: seedSize)
        return okm.withUnsafeBytes { [UInt8]($0) }
    }

    private static func keyFromSeedBytes(_ seed: [UInt8]) -> MlDsaPrivateKey? {
        guard seed.count == seedSize else { return nil }
        var pk = [UInt8](repeating: 0, count: publicKeySize)
        var sk = [UInt8](repeating: 0, count: secretKeySize)
        defer { wipe(&sk) }
        let rc: Int32 = pk.withUnsafeMutableBufferPointer { pp in
            sk.withUnsafeMutableBufferPointer { sp in
                seed.withUnsafeBufferPointer { dp in
                    qa_mldsa87_keygen_from_seed(pp.baseAddress, sp.baseAddress, dp.baseAddress)
                }
            }
        }
        guard rc == 0 else { return nil }
        let secret: SecureBytes = sk.withUnsafeMutableBytes { buf in
            SecureBytes(data: Data(bytesNoCopy: buf.baseAddress!, count: buf.count, deallocator: .none))
        }
        return MlDsaPrivateKey(secret: secret, publicKey: MlDsaPublicKey(raw: pk))
    }

    private static func hybridEdMessage(_ ht: Data) -> Data { Data(hybridEdPrefix) + ht }

    private static func edSign(_ edSeed: Data, _ msg: Data) -> Data? {
        guard edSeed.count == edSeedSize,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: edSeed),
              let sig = try? key.signature(for: msg), sig.count == edSignatureSize
        else { return nil }
        return Data(sig)
    }

    /// Ed25519 verification under the rule shared by all platforms: the public key is a canonical encoding and not a
    /// small-order point (`Ed25519IdentityKeyPolicy`), R is a canonical encoding, S < L; the remaining checks are
    /// CryptoKit's. The shared vectors (section ed25519Strict) are run by Ed25519StrictKatTests.
    static func edVerify(_ edPub: Data, _ msg: Data, _ sig: Data) -> Bool {
        guard edPub.count == edPublicSize, sig.count == edSignatureSize,
              Ed25519IdentityKeyPolicy.isAcceptable(edPub), edSignatureIsReduced([UInt8](sig)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: edPub)
        else { return false }
        return key.isValidSignature(sig, for: msg)
    }

    /// The prime group order L = 2^252 + 27742317777372353535851937790883648493, little-endian.
    private static let edGroupOrderLE: [UInt8] = [
        0xED, 0xD3, 0xF5, 0x5C, 0x1A, 0x63, 0x12, 0x58, 0xD6, 0x9C, 0xF7, 0xA2, 0xDE, 0xF9, 0xDE, 0x14,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
    ]

    /// `sig` is R (32 bytes) || S (32 bytes, little-endian): R must be a canonical encoding and S must be below L.
    private static func edSignatureIsReduced(_ sig: [UInt8]) -> Bool {
        guard sig.count == edSignatureSize,
              !Ed25519IdentityKeyPolicy.isNonCanonicalEncoding(Data(sig[0..<32]))
        else { return false }
        var i = 31
        while i >= 0 {
            let s = sig[32 + i]
            let l = edGroupOrderLE[i]
            if s != l { return s < l }
            i -= 1
        }
        return false
    }

    fileprivate static func ctxBytes(_ ctx: String) -> [UInt8]? {
        let b = Array(ctx.utf8)
        return b.count <= 255 ? b : nil
    }

    fileprivate static func randomBytes(_ n: Int) -> [UInt8]? {
        var b = [UInt8](repeating: 0, count: n)
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return status == errSecSuccess ? b : nil
    }

    fileprivate static func sha256Bytes(_ b: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: b)) }

    fileprivate static func wipe(_ b: inout [UInt8]) {
        let n = b.count
        guard n > 0 else { return }
        b.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, n, 0, n) }
    }

    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    private static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    private static func be64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 0xFF) } }

    /// Strict UTF-8 (RFC 3629): no overlong forms, no surrogates, nothing above U+10FFFF.
    private static func isStrictUTF8(_ b: [UInt8]) -> Bool {
        var i = 0
        let n = b.count
        func cont(_ k: Int, _ lo: UInt8 = 0x80, _ hi: UInt8 = 0xBF) -> Bool {
            k < n && b[k] >= lo && b[k] <= hi
        }
        while i < n {
            let c = b[i]
            switch c {
            case 0x00...0x7F:
                i += 1
            case 0xC2...0xDF:
                guard cont(i + 1) else { return false }
                i += 2
            case 0xE0:
                guard cont(i + 1, 0xA0, 0xBF), cont(i + 2) else { return false }
                i += 3
            case 0xE1...0xEC, 0xEE...0xEF:
                guard cont(i + 1), cont(i + 2) else { return false }
                i += 3
            case 0xED:
                guard cont(i + 1, 0x80, 0x9F), cont(i + 2) else { return false }
                i += 3
            case 0xF0:
                guard cont(i + 1, 0x90, 0xBF), cont(i + 2), cont(i + 3) else { return false }
                i += 4
            case 0xF1...0xF3:
                guard cont(i + 1), cont(i + 2), cont(i + 3) else { return false }
                i += 4
            case 0xF4:
                guard cont(i + 1, 0x80, 0x8F), cont(i + 2), cont(i + 3) else { return false }
                i += 4
            default:
                return false
            }
        }
        return true
    }
}
