import Foundation
import CryptoKit
import Security
import CLiboqs

// Proximity pairing v1 — cryptographic core.
//
// Normative reference: docs/security/PROXIMITY_PAIRING_QR_BLE_SPEC.md §3, §6,
// §8 and §10. Every label comes from `ProximityPairing.Label`; every size from
// `ProximityPairing`. Byte-for-byte cross-checked against the independent
// Python implementation by ProximityPairingKatTests.
//
// Key schedule (SIGMA-I, spec §10): stage 1 derives, from the hybrid shared
// secret and TH1 (a transcript WITHOUT identities), the keys that seal and MAC
// the two identity blocks; stage 2 re-extracts PRK1 under TH_D (a transcript
// that chains both identity blocks) into the confirmation keys, SAS and PSK.
//
// Failure policy (fail closed, never fall back):
// - Throwing functions throw `ProximityPairingError` on any wrong input length
//   or library failure. They never return random, zero or partial bytes.
//   `aeadOpen` throws `.authenticationFailed` for anything wrong with the
//   sealed bytes (tag, length) and `.cryptoFailure` for a wrong local key or
//   associated-data length.
// - Non-throwing derivations (frameKey, helloTag, commitment, transcriptHash,
//   identityTranscriptHash, transcriptMac, confirmationMac, signaturePayload)
//   return EMPTY `Data` when an input has the wrong length. Every consumer
//   rejects empty values: `constantTimeEquals` is false whenever either side
//   is empty, `sign` refuses an empty payload, `deriveHandshakeKeys` /
//   `deriveSessionKeys` / `aeadSeal` / `aeadOpen` throw on a wrong-length
//   transcript hash and `ProximityQrPayload.init` throws on a wrong-length
//   frame key / commitment. A caller bug therefore aborts the pairing; it can
//   never make a check pass or produce a usable key.

/// Big-endian helpers shared by the proximity-pairing files (spec §3 encodings).
enum ProximityBytes {

    static func u16be(_ value: UInt16) -> Data {
        let bytes: [UInt8] = [
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
        return Data(bytes)
    }

    static func u32be(_ value: UInt32) -> Data {
        let bytes: [UInt8] = [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
        return Data(bytes)
    }

    /// Reads 2 bytes at the zero-based `offset` (relative to the data's own
    /// start, so slices with a non-zero `startIndex` work). `nil` when out of range.
    static func readU16be(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, data.count >= 2, offset <= data.count - 2 else { return nil }
        let base: Int = data.startIndex + offset
        let hi: UInt16 = UInt16(data[base])
        let lo: UInt16 = UInt16(data[base + 1])
        return (hi << 8) | lo
    }

    /// Reads 4 bytes at the zero-based `offset`. `nil` when out of range.
    static func readU32be(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, data.count >= 4, offset <= data.count - 4 else { return nil }
        let base: Int = data.startIndex + offset
        let b0: UInt32 = UInt32(data[base])
        let b1: UInt32 = UInt32(data[base + 1])
        let b2: UInt32 = UInt32(data[base + 2])
        let b3: UInt32 = UInt32(data[base + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    /// `lp32(x) = u32be(len(x)) ‖ x`. Protocol inputs are bounded by
    /// `ProximityPairing.maxMessageBytes`, so the length always fits.
    static func lp32(_ data: Data) -> Data {
        precondition(data.count <= Int(UInt32.max), "lp32 input too large")
        var out: Data = u32be(UInt32(data.count))
        out.append(data)
        return out
    }
}

public enum ProximityPairingCrypto {

    // MARK: - Randomness

    /// `count` bytes from `SecRandomCopyBytes`. Throws `.cryptoFailure` on a
    /// non-positive count or a CSPRNG failure; there is no fallback source.
    public static func randomBytes(_ count: Int) throws -> Data {
        guard count > 0 else {
            throw ProximityPairingError.cryptoFailure("random length")
        }
        var out = Data(count: count)
        let status: Int32 = out.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Int32 in
            guard let base = buf.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            CryptoConstants.zeroize(&out)
            throw ProximityPairingError.cryptoFailure("random source")
        }
        return out
    }

    // MARK: - ML-KEM-1024 (FIPS 203, liboqs algorithm-specific entry points)

    public struct KemKeyPair {
        /// Encapsulation key `ek`, exactly 1568 bytes.
        public let publicKey: Data
        /// Decapsulation key `dk`, exactly 3168 bytes. The owner zeroizes it after use.
        public let secretKey: Data
    }

    private static let kemKeypairSeedBytes: Int = 64   // OQS_KEM_ml_kem_1024_length_keypair_seed
    private static let kemEncapsSeedBytes: Int = 32    // OQS_KEM_ml_kem_1024_length_encaps_seed

    public static func kemGenerateKeyPair() throws -> KemKeyPair {
        var publicKey = Data(count: ProximityPairing.mlKemPublicKeyBytes)
        var secretKey = Data(count: ProximityPairing.mlKemSecretKeyBytes)
        let ok: Bool = publicKey.withUnsafeMutableBytes { (pkBuf: UnsafeMutableRawBufferPointer) -> Bool in
            return secretKey.withUnsafeMutableBytes { (skBuf: UnsafeMutableRawBufferPointer) -> Bool in
                guard let pkBase = pkBuf.baseAddress, let skBase = skBuf.baseAddress else { return false }
                let status: OQS_STATUS = OQS_KEM_ml_kem_1024_keypair(
                    pkBase.assumingMemoryBound(to: UInt8.self),
                    skBase.assumingMemoryBound(to: UInt8.self))
                return status == OQS_SUCCESS
            }
        }
        guard ok else {
            CryptoConstants.zeroize(&secretKey)
            throw ProximityPairingError.cryptoFailure("ML-KEM keypair")
        }
        return KemKeyPair(publicKey: publicKey, secretKey: secretKey)
    }

    /// Deterministic key generation (`OQS_KEM_ml_kem_1024_keypair_derand`),
    /// 64-byte seed `d ‖ z`. Tests only.
    static func kemGenerateKeyPair(seed: Data) throws -> KemKeyPair {
        guard seed.count == kemKeypairSeedBytes else {
            throw ProximityPairingError.cryptoFailure("ML-KEM keypair seed length")
        }
        var publicKey = Data(count: ProximityPairing.mlKemPublicKeyBytes)
        var secretKey = Data(count: ProximityPairing.mlKemSecretKeyBytes)
        let ok: Bool = publicKey.withUnsafeMutableBytes { (pkBuf: UnsafeMutableRawBufferPointer) -> Bool in
            return secretKey.withUnsafeMutableBytes { (skBuf: UnsafeMutableRawBufferPointer) -> Bool in
                return seed.withUnsafeBytes { (seedBuf: UnsafeRawBufferPointer) -> Bool in
                    guard let pkBase = pkBuf.baseAddress,
                          let skBase = skBuf.baseAddress,
                          let seedBase = seedBuf.baseAddress else { return false }
                    let status: OQS_STATUS = OQS_KEM_ml_kem_1024_keypair_derand(
                        pkBase.assumingMemoryBound(to: UInt8.self),
                        skBase.assumingMemoryBound(to: UInt8.self),
                        seedBase.assumingMemoryBound(to: UInt8.self))
                    return status == OQS_SUCCESS
                }
            }
        }
        guard ok else {
            CryptoConstants.zeroize(&secretKey)
            throw ProximityPairingError.cryptoFailure("ML-KEM keypair")
        }
        return KemKeyPair(publicKey: publicKey, secretKey: secretKey)
    }

    /// Encapsulates to `publicKey` (exactly 1568 bytes). liboqs / mlkem-native
    /// performs the FIPS 203 §7.2 modulus check, so a malformed key throws.
    public static func kemEncapsulate(publicKey: Data) throws -> (ciphertext: Data, sharedSecret: Data) {
        guard publicKey.count == ProximityPairing.mlKemPublicKeyBytes else {
            throw ProximityPairingError.cryptoFailure("ML-KEM public key length")
        }
        var ciphertext = Data(count: ProximityPairing.mlKemCiphertextBytes)
        var sharedSecret = Data(count: ProximityPairing.sharedSecretBytes)
        let ok: Bool = ciphertext.withUnsafeMutableBytes { (ctBuf: UnsafeMutableRawBufferPointer) -> Bool in
            return sharedSecret.withUnsafeMutableBytes { (ssBuf: UnsafeMutableRawBufferPointer) -> Bool in
                return publicKey.withUnsafeBytes { (pkBuf: UnsafeRawBufferPointer) -> Bool in
                    guard let ctBase = ctBuf.baseAddress,
                          let ssBase = ssBuf.baseAddress,
                          let pkBase = pkBuf.baseAddress else { return false }
                    let status: OQS_STATUS = OQS_KEM_ml_kem_1024_encaps(
                        ctBase.assumingMemoryBound(to: UInt8.self),
                        ssBase.assumingMemoryBound(to: UInt8.self),
                        pkBase.assumingMemoryBound(to: UInt8.self))
                    return status == OQS_SUCCESS
                }
            }
        }
        guard ok else {
            CryptoConstants.zeroize(&sharedSecret)
            throw ProximityPairingError.cryptoFailure("ML-KEM encapsulate")
        }
        return (ciphertext: ciphertext, sharedSecret: sharedSecret)
    }

    /// Deterministic encapsulation (`OQS_KEM_ml_kem_1024_encaps_derand`),
    /// 32-byte seed `m`. Tests only.
    static func kemEncapsulate(publicKey: Data, seed: Data) throws -> (ciphertext: Data, sharedSecret: Data) {
        guard publicKey.count == ProximityPairing.mlKemPublicKeyBytes else {
            throw ProximityPairingError.cryptoFailure("ML-KEM public key length")
        }
        guard seed.count == kemEncapsSeedBytes else {
            throw ProximityPairingError.cryptoFailure("ML-KEM encapsulation seed length")
        }
        var ciphertext = Data(count: ProximityPairing.mlKemCiphertextBytes)
        var sharedSecret = Data(count: ProximityPairing.sharedSecretBytes)
        let ok: Bool = ciphertext.withUnsafeMutableBytes { (ctBuf: UnsafeMutableRawBufferPointer) -> Bool in
            return sharedSecret.withUnsafeMutableBytes { (ssBuf: UnsafeMutableRawBufferPointer) -> Bool in
                return publicKey.withUnsafeBytes { (pkBuf: UnsafeRawBufferPointer) -> Bool in
                    return seed.withUnsafeBytes { (seedBuf: UnsafeRawBufferPointer) -> Bool in
                        guard let ctBase = ctBuf.baseAddress,
                              let ssBase = ssBuf.baseAddress,
                              let pkBase = pkBuf.baseAddress,
                              let seedBase = seedBuf.baseAddress else { return false }
                        let status: OQS_STATUS = OQS_KEM_ml_kem_1024_encaps_derand(
                            ctBase.assumingMemoryBound(to: UInt8.self),
                            ssBase.assumingMemoryBound(to: UInt8.self),
                            pkBase.assumingMemoryBound(to: UInt8.self),
                            seedBase.assumingMemoryBound(to: UInt8.self))
                        return status == OQS_SUCCESS
                    }
                }
            }
        }
        guard ok else {
            CryptoConstants.zeroize(&sharedSecret)
            throw ProximityPairingError.cryptoFailure("ML-KEM encapsulate")
        }
        return (ciphertext: ciphertext, sharedSecret: sharedSecret)
    }

    /// Decapsulates `ciphertext` (exactly 1568 bytes) with `secretKey`
    /// (exactly 3168 bytes). A tampered ciphertext does NOT throw: ML-KEM's
    /// implicit rejection returns an unrelated shared secret, whose stage-1
    /// keys then fail to open sealed_S. A secret key failing the FIPS 203 §7.3
    /// hash check throws.
    public static func kemDecapsulate(ciphertext: Data, secretKey: Data) throws -> Data {
        guard ciphertext.count == ProximityPairing.mlKemCiphertextBytes else {
            throw ProximityPairingError.cryptoFailure("ML-KEM ciphertext length")
        }
        guard secretKey.count == ProximityPairing.mlKemSecretKeyBytes else {
            throw ProximityPairingError.cryptoFailure("ML-KEM secret key length")
        }
        var sharedSecret = Data(count: ProximityPairing.sharedSecretBytes)
        let ok: Bool = sharedSecret.withUnsafeMutableBytes { (ssBuf: UnsafeMutableRawBufferPointer) -> Bool in
            return ciphertext.withUnsafeBytes { (ctBuf: UnsafeRawBufferPointer) -> Bool in
                return secretKey.withUnsafeBytes { (skBuf: UnsafeRawBufferPointer) -> Bool in
                    guard let ssBase = ssBuf.baseAddress,
                          let ctBase = ctBuf.baseAddress,
                          let skBase = skBuf.baseAddress else { return false }
                    let status: OQS_STATUS = OQS_KEM_ml_kem_1024_decaps(
                        ssBase.assumingMemoryBound(to: UInt8.self),
                        ctBase.assumingMemoryBound(to: UInt8.self),
                        skBase.assumingMemoryBound(to: UInt8.self))
                    return status == OQS_SUCCESS
                }
            }
        }
        guard ok else {
            CryptoConstants.zeroize(&sharedSecret)
            throw ProximityPairingError.cryptoFailure("ML-KEM decapsulate")
        }
        return sharedSecret
    }

    // MARK: - X25519

    /// X25519(privateKey, peerPublicKey). The peer key must be exactly 32
    /// bytes; any CryptoKit failure or an all-zero result (low-order peer
    /// point, RFC 7748 §6.1) throws `.authenticationFailed`.
    public static func x25519SharedSecret(privateKey: Curve25519.KeyAgreement.PrivateKey,
                                          peerPublicKey: Data) throws -> Data {
        guard peerPublicKey.count == ProximityPairing.x25519PublicKeyBytes else {
            throw ProximityPairingError.authenticationFailed("X25519 peer key length")
        }
        var out: Data
        do {
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(peerPublicKey))
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
            out = shared.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Data in
                return Data(buf)
            }
        } catch {
            throw ProximityPairingError.authenticationFailed("X25519 agreement")
        }
        guard out.count == ProximityPairing.sharedSecretBytes, !isAllZero(out) else {
            CryptoConstants.zeroize(&out)
            throw ProximityPairingError.authenticationFailed("X25519 low-order point")
        }
        return out
    }

    // MARK: - Ed25519 identity signatures

    /// Ed25519 signature (64 bytes) over `payload` with the raw 32-byte
    /// private key. CryptoKit signatures are randomized: verify, never compare.
    public static func sign(_ payload: Data, signingPrivateKey: Data) throws -> Data {
        guard signingPrivateKey.count == ProximityPairing.ed25519PrivateKeyBytes else {
            throw ProximityPairingError.cryptoFailure("signing key length")
        }
        guard !payload.isEmpty else {
            throw ProximityPairingError.cryptoFailure("empty signature payload")
        }
        let key: Curve25519.Signing.PrivateKey
        let signature: Data
        do {
            // No `Data(...)` copy: the init reads any ContiguousBytes (slices
            // included), so no extra, unzeroized copy of the key is made.
            key = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKey)
            signature = try key.signature(for: Data(payload))
        } catch {
            throw ProximityPairingError.cryptoFailure("Ed25519 sign")
        }
        guard signature.count == ProximityPairing.ed25519SignatureBytes else {
            throw ProximityPairingError.cryptoFailure("Ed25519 signature length")
        }
        return Data(signature)
    }

    /// False (never a crash) for wrong key / signature lengths, an empty
    /// payload, an invalid key encoding, a small-order or non-canonical key
    /// (`Ed25519IdentityKeyPolicy`: the peer supplies this key in the sealed
    /// identity box) or a bad signature.
    public static func verify(signature: Data, payload: Data, signingPublicKey: Data) -> Bool {
        guard signature.count == ProximityPairing.ed25519SignatureBytes,
              signingPublicKey.count == ProximityPairing.ed25519PublicKeyBytes,
              !payload.isEmpty,
              Ed25519IdentityKeyPolicy.isAcceptable(signingPublicKey) else {
            return false
        }
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(signingPublicKey))
        } catch {
            return false
        }
        return key.isValidSignature(Data(signature), for: Data(payload))
    }

    // MARK: - QR frame keys, HELLO tag, commitment (spec §6, §8)

    /// `HMAC-SHA256(sessionSecret, L_FRAME ‖ sessionId ‖ u32be(i))`. Empty on wrong input lengths.
    public static func frameKey(sessionSecret: Data, sessionId: Data, frameIndex: UInt32) -> Data {
        guard sessionSecret.count == ProximityPairing.sessionSecretBytes,
              sessionId.count == ProximityPairing.sessionIdBytes else {
            return Data()
        }
        var message = Data()
        message.append(ProximityPairing.Label.frame)
        message.append(sessionId)
        message.append(ProximityBytes.u32be(frameIndex))
        return hmacSha256(key: sessionSecret, message: message)
    }

    /// `HMAC-SHA256(frameKey_i, L_HELLO ‖ sessionId ‖ u32be(i) ‖ xpk_S ‖ nonce_S)`.
    /// Empty on wrong input lengths.
    public static func helloTag(frameKey: Data, sessionId: Data, frameIndex: UInt32,
                                scannerEphemeralX25519: Data, scannerNonce: Data) -> Data {
        guard frameKey.count == ProximityPairing.frameKeyBytes,
              sessionId.count == ProximityPairing.sessionIdBytes,
              scannerEphemeralX25519.count == ProximityPairing.x25519PublicKeyBytes,
              scannerNonce.count == ProximityPairing.nonceBytes else {
            return Data()
        }
        var message = Data()
        message.append(ProximityPairing.Label.hello)
        message.append(sessionId)
        message.append(ProximityBytes.u32be(frameIndex))
        message.append(scannerEphemeralX25519)
        message.append(scannerNonce)
        return hmacSha256(key: frameKey, message: message)
    }

    /// `SHA-256(L_COMMIT ‖ sessionId ‖ offerBody)` over the ephemeral-only
    /// OFFER body (spec §6). Empty unless sessionId is 16 bytes and offerBody
    /// exactly 1632.
    public static func commitment(sessionId: Data, offerBody: Data) -> Data {
        guard sessionId.count == ProximityPairing.sessionIdBytes,
              offerBody.count == ProximityPairing.offerBodyBytes else {
            return Data()
        }
        var message = Data()
        message.append(ProximityPairing.Label.commit)
        message.append(sessionId)
        message.append(offerBody)
        return sha256(message)
    }

    // MARK: - Transcript hashes (spec §10)

    /// TH1 = `SHA-256(L_TRANSCRIPT ‖ lp32(qrBytes) ‖ lp32(helloBody) ‖ lp32(offerBody) ‖ lp32(ct))`:
    /// the handshake transcript, before either identity is known. Empty unless
    /// qrBytes is 85 bytes, helloBody 100, offerBody 1632 and ct 1568.
    public static func transcriptHash(qrBytes: Data, helloBody: Data,
                                      offerBody: Data, mlKemCiphertext: Data) -> Data {
        guard qrBytes.count == ProximityPairing.qrPayloadBytes,
              helloBody.count == ProximityPairing.helloBodyBytes,
              offerBody.count == ProximityPairing.offerBodyBytes,
              mlKemCiphertext.count == ProximityPairing.mlKemCiphertextBytes else {
            return Data()
        }
        var message = Data()
        message.append(ProximityPairing.Label.transcript)
        message.append(ProximityBytes.lp32(qrBytes))
        message.append(ProximityBytes.lp32(helloBody))
        message.append(ProximityBytes.lp32(offerBody))
        message.append(ProximityBytes.lp32(mlKemCiphertext))
        return sha256(message)
    }

    /// SIGMA-I chained transcript over one identity block:
    /// - scanner:   TH_S = `SHA-256(L_TH_S ‖ TH1 ‖ lp32(idBlock_S))`, `previousHash` = TH1;
    /// - displayer: TH_D = `SHA-256(L_TH_D ‖ TH_S ‖ lp32(idBlock_D))`, `previousHash` = TH_S.
    /// Empty unless `previousHash` is 32 bytes and `idBlock` is 67...322 bytes
    /// (the only lengths a valid idBlock can have).
    public static func identityTranscriptHash(role: ProximityRole, previousHash: Data, idBlock: Data) -> Data {
        let minimum: Int = ProximityPairing.idBlockFixedBytes + 1
        let maximum: Int = ProximityPairing.idBlockFixedBytes + ProximityPairing.maxUserIdBytes
        guard previousHash.count == ProximityPairing.transcriptHashBytes,
              idBlock.count >= minimum, idBlock.count <= maximum else {
            return Data()
        }
        var message = Data()
        switch role {
        case .scanner:
            message.append(ProximityPairing.Label.transcriptScanner)
        case .displayer:
            message.append(ProximityPairing.Label.transcriptDisplayer)
        }
        message.append(previousHash)
        message.append(ProximityBytes.lp32(idBlock))
        return sha256(message)
    }

    // MARK: - Key schedule, stage 1 (spec §10)

    /// The stage-1 keys: they seal and MAC the identity blocks. Kept until
    /// stage 2 has consumed PRK1, then zeroized. After `zeroize()` every field
    /// is empty, so a stale use fails closed instead of running with an
    /// all-zero key.
    public struct HandshakeKeys {
        /// K_enc_S — seals `sealed_S` (ACCEPT).
        public private(set) var encKeyScanner: Data
        /// K_enc_D — seals `sealed_D` (FINISH).
        public private(set) var encKeyDisplayer: Data
        /// K_mac_S — `mac_S = HMAC(K_mac_S, TH_S)`.
        public private(set) var macKeyScanner: Data
        /// K_mac_D — `mac_D = HMAC(K_mac_D, TH_D)`.
        public private(set) var macKeyDisplayer: Data
        /// PRK1 — the stage-2 IKM. Internal: read by `deriveSessionKeys` and the KAT only.
        internal private(set) var prk: Data

        fileprivate init(encKeyScanner: Data, encKeyDisplayer: Data,
                         macKeyScanner: Data, macKeyDisplayer: Data, prk: Data) {
            self.encKeyScanner = encKeyScanner
            self.encKeyDisplayer = encKeyDisplayer
            self.macKeyScanner = macKeyScanner
            self.macKeyDisplayer = macKeyDisplayer
            self.prk = prk
        }

        public mutating func zeroize() {
            CryptoConstants.zeroize(&encKeyScanner)
            CryptoConstants.zeroize(&encKeyDisplayer)
            CryptoConstants.zeroize(&macKeyScanner)
            CryptoConstants.zeroize(&macKeyDisplayer)
            CryptoConstants.zeroize(&prk)
            encKeyScanner = Data()
            encKeyDisplayer = Data()
            macKeyScanner = Data()
            macKeyDisplayer = Data()
            prk = Data()
        }
    }

    /// `PRK1 = HKDF-Extract(salt = TH1, IKM = ss_kem ‖ ss_x ‖ nonce_S ‖ nonce_D)`
    /// and K_enc_S, K_enc_D, K_mac_S, K_mac_D (spec §10). Every input must be
    /// exactly 32 bytes, otherwise `.cryptoFailure`.
    public static func deriveHandshakeKeys(transcriptHash: Data, kemSharedSecret: Data,
                                           x25519SharedSecret: Data, scannerNonce: Data,
                                           displayerNonce: Data) throws -> HandshakeKeys {
        guard transcriptHash.count == ProximityPairing.transcriptHashBytes else {
            throw ProximityPairingError.cryptoFailure("transcript hash length")
        }
        guard kemSharedSecret.count == ProximityPairing.sharedSecretBytes else {
            throw ProximityPairingError.cryptoFailure("KEM shared secret length")
        }
        guard x25519SharedSecret.count == ProximityPairing.sharedSecretBytes else {
            throw ProximityPairingError.cryptoFailure("X25519 shared secret length")
        }
        guard scannerNonce.count == ProximityPairing.nonceBytes else {
            throw ProximityPairingError.cryptoFailure("scanner nonce length")
        }
        guard displayerNonce.count == ProximityPairing.nonceBytes else {
            throw ProximityPairingError.cryptoFailure("displayer nonce length")
        }

        var ikm = Data(capacity: 128)
        ikm.append(kemSharedSecret)
        ikm.append(x25519SharedSecret)
        ikm.append(scannerNonce)
        ikm.append(displayerNonce)
        defer { CryptoConstants.zeroize(&ikm) }

        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm),
                                       salt: Data(transcriptHash))
        let prkBytes: Data = prk.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Data in
            return Data(buf)
        }
        let encS: Data = expand(prk: prk, label: ProximityPairing.Label.encScanner, count: ProximityPairing.aeadKeyBytes)
        let encD: Data = expand(prk: prk, label: ProximityPairing.Label.encDisplayer, count: ProximityPairing.aeadKeyBytes)
        let macS: Data = expand(prk: prk, label: ProximityPairing.Label.macScanner, count: ProximityPairing.macBytes)
        let macD: Data = expand(prk: prk, label: ProximityPairing.Label.macDisplayer, count: ProximityPairing.macBytes)
        return HandshakeKeys(encKeyScanner: encS, encKeyDisplayer: encD,
                             macKeyScanner: macS, macKeyDisplayer: macD, prk: prkBytes)
    }

    // MARK: - Key schedule, stage 2 (spec §10)

    /// The final keys, bound to the whole transcript including both
    /// identities. Call `zeroize()` as soon as the session ends; after it
    /// every field is empty, so a stale use fails closed.
    public struct SessionKeys {
        public private(set) var confirmKeyScanner: Data
        public private(set) var confirmKeyDisplayer: Data
        /// 6-digit short authentication string shown to both users.
        public private(set) var sas: String
        /// 32-byte pre-shared key handed to the completion result.
        public private(set) var psk: Data
        /// PRK2 — exposed for the KAT only.
        internal private(set) var prk: Data
        /// Raw 8 SAS bytes — exposed for the KAT only.
        internal private(set) var sasBytes: Data

        fileprivate init(confirmKeyScanner: Data, confirmKeyDisplayer: Data,
                         sas: String, psk: Data, prk: Data, sasBytes: Data) {
            self.confirmKeyScanner = confirmKeyScanner
            self.confirmKeyDisplayer = confirmKeyDisplayer
            self.sas = sas
            self.psk = psk
            self.prk = prk
            self.sasBytes = sasBytes
        }

        public mutating func zeroize() {
            CryptoConstants.zeroize(&confirmKeyScanner)
            CryptoConstants.zeroize(&confirmKeyDisplayer)
            CryptoConstants.zeroize(&psk)
            CryptoConstants.zeroize(&prk)
            CryptoConstants.zeroize(&sasBytes)
            confirmKeyScanner = Data()
            confirmKeyDisplayer = Data()
            psk = Data()
            prk = Data()
            sasBytes = Data()
            sas = ""
        }
    }

    /// `PRK2 = HKDF-Extract(salt = TH_D, IKM = PRK1)` and the four HKDF-Expand
    /// outputs of spec §10 stage 2. Throws `.cryptoFailure` when TH_D is not
    /// 32 bytes or `handshakeKeys` was already zeroized. Does not zeroize
    /// `handshakeKeys`: the caller owns it and scrubs it right after this.
    public static func deriveSessionKeys(handshakeKeys: HandshakeKeys,
                                         displayerTranscriptHash: Data) throws -> SessionKeys {
        guard displayerTranscriptHash.count == ProximityPairing.transcriptHashBytes else {
            throw ProximityPairingError.cryptoFailure("displayer transcript hash length")
        }
        guard handshakeKeys.prk.count == ProximityPairing.sharedSecretBytes else {
            throw ProximityPairingError.cryptoFailure("stage-1 key")
        }
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: handshakeKeys.prk),
                                       salt: Data(displayerTranscriptHash))

        // SAS first: its core is the only step that can fail after the length
        // checks, and nothing else has been materialized yet at that point.
        var sasRaw: Data = expand(prk: prk, label: ProximityPairing.Label.sas, count: ProximityPairing.sasBytes)
        let code: String
        do {
            code = try sasCore(sasRaw)
        } catch {
            CryptoConstants.zeroize(&sasRaw)
            throw ProximityPairingError.cryptoFailure("SAS derivation")
        }

        let prkBytes: Data = prk.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Data in
            return Data(buf)
        }
        let confirmS: Data = expand(prk: prk, label: ProximityPairing.Label.confirmScanner, count: ProximityPairing.macBytes)
        let confirmD: Data = expand(prk: prk, label: ProximityPairing.Label.confirmDisplayer, count: ProximityPairing.macBytes)
        let pskBytes: Data = expand(prk: prk, label: ProximityPairing.Label.psk, count: ProximityPairing.pskBytes)

        return SessionKeys(confirmKeyScanner: confirmS, confirmKeyDisplayer: confirmD,
                           sas: code, psk: pskBytes, prk: prkBytes, sasBytes: sasRaw)
    }

    // MARK: - Identity sealing (spec §4, §8)

    /// `Seal(K, aad, p)`: AES-256-GCM with the all-zero 12-byte nonce, output
    /// `ciphertext ‖ tag[16]`. The fixed nonce is safe only because every
    /// K_enc_S / K_enc_D seals exactly one message. `key` must be 32 bytes and
    /// `transcriptHash` (the aad: TH1 for sealed_S, TH_S for sealed_D) 32
    /// bytes, otherwise `.cryptoFailure`.
    public static func aeadSeal(_ plaintext: Data, key: Data, transcriptHash: Data) throws -> Data {
        guard key.count == ProximityPairing.aeadKeyBytes else {
            throw ProximityPairingError.cryptoFailure("AEAD key length")
        }
        guard transcriptHash.count == ProximityPairing.transcriptHashBytes else {
            throw ProximityPairingError.cryptoFailure("AEAD associated data length")
        }
        guard !plaintext.isEmpty else {
            throw ProximityPairingError.cryptoFailure("empty AEAD plaintext")
        }
        let box: AES.GCM.SealedBox
        do {
            let nonce: AES.GCM.Nonce = try AES.GCM.Nonce(data: Data(count: ProximityPairing.aeadNonceBytes))
            box = try AES.GCM.seal(Data(plaintext), using: SymmetricKey(data: key), nonce: nonce,
                                   authenticating: Data(transcriptHash))
        } catch {
            throw ProximityPairingError.cryptoFailure("AES-GCM seal")
        }
        var out: Data = Data(box.ciphertext)
        let tag: Data = Data(box.tag)
        guard out.count == plaintext.count, tag.count == ProximityPairing.aeadTagBytes else {
            throw ProximityPairingError.cryptoFailure("AES-GCM output length")
        }
        out.append(tag)
        return out
    }

    /// Opens a `ciphertext ‖ tag[16]` box sealed by `aeadSeal` with the same
    /// key and aad. A wrong tag, a wrong aad, a wrong key or a box too short to
    /// hold a tag throws `.authenticationFailed`; a local key / aad of the
    /// wrong length throws `.cryptoFailure`.
    public static func aeadOpen(_ sealed: Data, key: Data, transcriptHash: Data) throws -> Data {
        guard key.count == ProximityPairing.aeadKeyBytes else {
            throw ProximityPairingError.cryptoFailure("AEAD key length")
        }
        guard transcriptHash.count == ProximityPairing.transcriptHashBytes else {
            throw ProximityPairingError.cryptoFailure("AEAD associated data length")
        }
        let box: Data = Data(sealed)
        guard box.count > ProximityPairing.aeadTagBytes else {
            throw ProximityPairingError.authenticationFailed("sealed length")
        }
        let split: Int = box.count - ProximityPairing.aeadTagBytes
        let ciphertext: Data = Data(box.prefix(split))
        let tag: Data = Data(box.suffix(ProximityPairing.aeadTagBytes))
        do {
            let nonce: AES.GCM.Nonce = try AES.GCM.Nonce(data: Data(count: ProximityPairing.aeadNonceBytes))
            let sealedBox: AES.GCM.SealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let plaintext: Data = try AES.GCM.open(sealedBox, using: SymmetricKey(data: key),
                                                   authenticating: Data(transcriptHash))
            return Data(plaintext)
        } catch {
            throw ProximityPairingError.authenticationFailed("AES-GCM open")
        }
    }

    // MARK: - Identity proofs and confirmation (spec §9, §10)

    /// `HMAC-SHA256(K_mac_role, TH_role)` — mac_S over TH_S, mac_D over TH_D.
    /// Empty unless key and transcript hash are 32 bytes.
    public static func transcriptMac(key: Data, transcriptHash: Data) -> Data {
        guard key.count == ProximityPairing.macBytes,
              transcriptHash.count == ProximityPairing.transcriptHashBytes else {
            return Data()
        }
        return hmacSha256(key: key, message: transcriptHash)
    }

    /// `HMAC-SHA256(K_confirm_role, L_CONFIRMED)`. Empty unless key is 32 bytes.
    public static func confirmationMac(key: Data) -> Data {
        guard key.count == ProximityPairing.macBytes else {
            return Data()
        }
        return hmacSha256(key: key, message: ProximityPairing.Label.userConfirmed)
    }

    /// `L_SIG_S ‖ TH_S` (scanner) or `L_SIG_D ‖ TH_D` (displayer): the payload
    /// the given role signs. Empty unless the transcript hash is 32 bytes.
    public static func signaturePayload(role: ProximityRole, transcriptHash: Data) -> Data {
        guard transcriptHash.count == ProximityPairing.transcriptHashBytes else {
            return Data()
        }
        var payload = Data()
        switch role {
        case .scanner:
            payload.append(ProximityPairing.Label.sigScanner)
        case .displayer:
            payload.append(ProximityPairing.Label.sigDisplayer)
        }
        payload.append(transcriptHash)
        return payload
    }

    /// `decimal(u64be(bytes) mod 1 000 000)`, zero-padded to 6 digits.
    ///
    /// Contract: `bytes` is exactly the 8 `sasBytes` produced by
    /// `deriveSessionKeys` (which itself uses the throwing core and so never
    /// yields a malformed SAS). For any other length this returns the empty
    /// string — never a plausible code — and UI must treat an empty SAS as a
    /// failed pairing.
    public static func sas(fromBytes bytes: Data) -> String {
        guard let code = try? sasCore(bytes) else { return "" }
        return code
    }

    /// Constant-time equality for MACs, tags and commitments. False when the
    /// lengths differ or either side is empty (no valid MAC is ever empty).
    /// Timing depends only on the (public) length.
    public static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        let diff: UInt8 = a.withUnsafeBytes { (pa: UnsafeRawBufferPointer) -> UInt8 in
            return b.withUnsafeBytes { (pb: UnsafeRawBufferPointer) -> UInt8 in
                var acc: UInt8 = 0
                var i: Int = 0
                let n: Int = pa.count
                while i < n {
                    acc |= pa[i] ^ pb[i]
                    i += 1
                }
                return acc
            }
        }
        return diff == 0
    }

    // MARK: - Private helpers

    private enum SasError: Error {
        case wrongLength
    }

    private static func sasCore(_ bytes: Data) throws -> String {
        guard bytes.count == ProximityPairing.sasBytes else { throw SasError.wrongLength }
        guard let value = ProximityBytes.readU32be(bytes, at: 0),
              let low = ProximityBytes.readU32be(bytes, at: 4) else {
            throw SasError.wrongLength
        }
        let full: UInt64 = (UInt64(value) << 32) | UInt64(low)
        let reduced: UInt64 = full % 1_000_000
        var digits: [Character] = []
        var remaining: UInt64 = reduced
        var position: Int = 0
        while position < ProximityPairing.sasDigits {
            let digit: UInt64 = remaining % 10
            remaining = remaining / 10
            let scalar: UInt8 = UInt8(truncatingIfNeeded: digit) + 48
            digits.append(Character(UnicodeScalar(scalar)))
            position += 1
        }
        return String(digits.reversed())
    }

    private static func isAllZero(_ data: Data) -> Bool {
        let acc: UInt8 = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> UInt8 in
            var value: UInt8 = 0
            var i: Int = 0
            let n: Int = buf.count
            while i < n {
                value |= buf[i]
                i += 1
            }
            return value
        }
        return acc == 0
    }

    private static func hmacSha256(key: Data, message: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey)
        return mac.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Data in
            return Data(buf)
        }
    }

    private static func sha256(_ message: Data) -> Data {
        let digest = SHA256.hash(data: message)
        return Data(digest)
    }

    private static func expand(prk: HashedAuthenticationCode<SHA256>, label: Data, count: Int) -> Data {
        let key: SymmetricKey = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: label, outputByteCount: count)
        return key.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Data in
            return Data(buf)
        }
    }
}
