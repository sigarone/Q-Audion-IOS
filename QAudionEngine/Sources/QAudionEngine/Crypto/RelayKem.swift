import Foundation
import CryptoKit

// The key exchange of the outer relay layer: the offerer's ephemeral pair, the acceptor's encapsulation, the offerer's
// decapsulation, the shared secrets and the four keys of a round. Pure functions and two small secret holders; no logging, no
// access to the call state.
//
//     relaySS    = mlkemSS(32) || x25519SS(32)
//     RELAYX     = SHA-256("qaudion-relay-kem-v1" || LP(offer.mlkem) || LP(offer.x25519) || LP(accept.mlkem) || LP(accept.x25519))
//     PRK_rel    = HKDF-Extract(salt = "qaudion-relay-salt-v1", IKM = relaySS || sessionKey_E)
//     kOut[k][d] = HKDF-Expand(PRK_rel, "q-audion-relay-v1" || LP(callIdL) || LP(k) || LP(d) || acceptBinding_E || RELAYX, 32)
//
// `LP` is a 16-bit big-endian length followed by the bytes. The member values are the DECODED bytes. The X25519 operation sits in
// its own function: a throw and an all-zero output are the same outcome. Secrets live in `ChainKeyBuffer`s (wiped on every path).

/// The decoded `relayKem` member: the ML-KEM-1024 encapsulation key (offer) or ciphertext (accept) and the X25519 public key.
public struct RelayKemWire: Equatable, Sendable {
    public static let mlkemBytes = 1568
    public static let x25519Bytes = 32

    public let mlkem: Data
    public let x25519: Data

    public init(mlkem: Data, x25519: Data) {
        self.mlkem = mlkem
        self.x25519 = x25519
    }

    var hasExactLengths: Bool {
        mlkem.count == Self.mlkemBytes && x25519.count == Self.x25519Bytes
    }
}

/// The four keys of one round, one buffer each. Wiped when the slot that holds them is erased.
struct OuterRoundKeys: Sendable {
    let audioOffererToAcceptor: ChainKeyBuffer
    let audioAcceptorToOfferer: ChainKeyBuffer
    let videoOffererToAcceptor: ChainKeyBuffer
    let videoAcceptorToOfferer: ChainKeyBuffer

    func key(kind: InnerSealV2.Kind, direction: InnerSealV2.Direction) -> ChainKeyBuffer {
        switch (kind, direction) {
        case (.audio, .offererToAcceptor): return audioOffererToAcceptor
        case (.audio, .acceptorToOfferer): return audioAcceptorToOfferer
        case (.video, .offererToAcceptor): return videoOffererToAcceptor
        case (.video, .acceptorToOfferer): return videoAcceptorToOfferer
        }
    }

    func wipe() {
        audioOffererToAcceptor.wipe()
        audioAcceptorToOfferer.wipe()
        videoOffererToAcceptor.wipe()
        videoAcceptorToOfferer.wipe()
    }

    var allBuffers: [ChainKeyBuffer] {
        [audioOffererToAcceptor, audioAcceptorToOfferer, videoOffererToAcceptor, videoAcceptorToOfferer]
    }
}

/// `mlkemSS || x25519SS` and `RELAYX` of one exchange. Created by the step that holds the exchange and wiped by it.
final class RelaySecrets: @unchecked Sendable {
    let relaySS: ChainKeyBuffer
    let relayx: ChainKeyBuffer

    init(relaySS: Data, relayx: Data) {
        self.relaySS = ChainKeyBuffer(copying: relaySS)
        self.relayx = ChainKeyBuffer(copying: relayx)
    }

    func wipe() {
        relaySS.wipe()
        relayx.wipe()
    }

    var isWipedForTesting: Bool {
        relaySS.isWipedForTesting && relayx.isWipedForTesting
    }

    deinit {
        wipe()
    }
}

enum RelayDecapResult {
    case ok(RelaySecrets)
    /// The X25519 operation threw or returned all zeros.
    case x25519Zero
    /// Anything else, a second use and a wiped object included.
    case failed
}

enum RelayEncapResult {
    case ok(accept: RelayKemWire, secrets: RelaySecrets)
    /// A key of the wrong size or out of range: the ACCEPT carries no member.
    case badKey
    case x25519Zero
    case failed
}

/// The offerer's private keys of one round. One shot: `decapsulate` consumes and wipes them, whatever it returns. The wrapper that
/// drops the holder of this object may drop its last reference without calling anything: the deinit wipes.
final class RelayOfferKeys: @unchecked Sendable {
    let pub: RelayKemWire
    private let lock = NSLock()
    private var mlkemSecret: ChainKeyBuffer?
    private var x25519Scalar: ChainKeyBuffer?
    private var consumed = false

    init(pub: RelayKemWire, mlkemSecret: Data, x25519Scalar: Data) {
        self.pub = pub
        self.mlkemSecret = ChainKeyBuffer(copying: mlkemSecret)
        self.x25519Scalar = ChainKeyBuffer(copying: x25519Scalar)
    }

    /// Fixed keys, for the known-answer test: the X25519 public key is computed from the scalar.
    convenience init?(mlkemPublic: Data, mlkemSecret: Data, x25519Scalar: Data) {
        guard let own = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: x25519Scalar) else { return nil }
        let wire = RelayKemWire(mlkem: mlkemPublic, x25519: own.publicKey.rawRepresentation)
        self.init(pub: wire, mlkemSecret: mlkemSecret, x25519Scalar: x25519Scalar)
    }

    func decapsulate(_ accept: RelayKemWire) -> RelayDecapResult {
        lock.lock()
        let wasConsumed = consumed
        consumed = true
        let secretBuffer = mlkemSecret
        let scalarBuffer = x25519Scalar
        mlkemSecret = nil
        x25519Scalar = nil
        lock.unlock()
        defer {
            secretBuffer?.wipe()
            scalarBuffer?.wipe()
        }
        if wasConsumed { return .failed }
        guard let skBuffer = secretBuffer, let xsBuffer = scalarBuffer else { return .failed }
        guard var skData = skBuffer.copyData() else { return .failed }
        defer { CryptoConstants.zeroize(&skData) }
        guard var xsData = xsBuffer.copyData() else { return .failed }
        defer { CryptoConstants.zeroize(&xsData) }
        guard accept.hasExactLengths else { return .failed }
        var mlkemSS: Data
        do {
            mlkemSS = try PqcKeyExchange().decapsulate(ciphertext: accept.mlkem, privateKey: skData)
        } catch {
            return .failed
        }
        guard var dh = RelayKem.x25519Shared(scalar: xsData, peerPublic: accept.x25519) else {
            CryptoConstants.zeroize(&mlkemSS)
            return .x25519Zero
        }
        var relaySS = mlkemSS
        relaySS.append(dh)
        let secrets = RelaySecrets(relaySS: relaySS, relayx: RelayKem.relayx(offer: pub, accept: accept))
        CryptoConstants.zeroize(&mlkemSS)
        CryptoConstants.zeroize(&dh)
        CryptoConstants.zeroize(&relaySS)
        return .ok(secrets)
    }

    /// Idempotent. Afterwards `decapsulate` is `.failed`.
    func wipe() {
        lock.lock()
        consumed = true
        let secretBuffer = mlkemSecret
        let scalarBuffer = x25519Scalar
        mlkemSecret = nil
        x25519Scalar = nil
        lock.unlock()
        secretBuffer?.wipe()
        scalarBuffer?.wipe()
    }

    var isWipedForTesting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mlkemSecret == nil && x25519Scalar == nil
    }

    deinit {
        wipe()
    }
}

enum RelayKem {

    // MARK: - Small checks

    /// Constant-time "every byte is zero".
    static func isAllZero(_ data: Data) -> Bool {
        var accumulator: UInt8 = 0
        for byte in data { accumulator |= byte }
        return accumulator == 0
    }

    /// The FIPS 203 modulus check of an ML-KEM-1024 encapsulation key: each of the 4 x 256 twelve-bit coefficients of the first
    /// 1536 bytes is below 3329 (the last 32 bytes are the seed). Done here so the result does not depend on the library.
    static func isCanonicalMlKemEncapsulationKey(_ key: Data) -> Bool {
        guard key.count == RelayKemWire.mlkemBytes else { return false }
        let bytes = [UInt8](key)
        var index = 0
        while index < 1536 {
            let b0 = Int(bytes[index])
            let b1 = Int(bytes[index + 1])
            let b2 = Int(bytes[index + 2])
            let c0 = b0 | ((b1 & 0x0F) << 8)
            let c1 = (b1 >> 4) | (b2 << 4)
            if c0 >= 3329 || c1 >= 3329 { return false }
            index += 3
        }
        return true
    }

    /// The only X25519 operation of this file: nil when it throws or the output is all zeros.
    static func x25519Shared(scalar: Data, peerPublic: Data) -> Data? {
        do {
            let own = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar)
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublic)
            let secret = try own.sharedSecretFromKeyAgreement(with: peer)
            var out = secret.withUnsafeBytes { Data($0) }
            if isAllZero(out) {
                CryptoConstants.zeroize(&out)
                return nil
            }
            return out
        } catch {
            return nil
        }
    }

    // MARK: - Digest and keys

    /// `RELAYX` over the decoded bytes of both members.
    static func relayx(offer: RelayKemWire, accept: RelayKemWire) -> Data {
        var preimage = HkdfLabels.relayBindLabelV1
        preimage.append(RekeyChain.lp16([UInt8](offer.mlkem)))
        preimage.append(RekeyChain.lp16([UInt8](offer.x25519)))
        preimage.append(RekeyChain.lp16([UInt8](accept.mlkem)))
        preimage.append(RekeyChain.lp16([UInt8](accept.x25519)))
        return Data(SHA256.hash(data: preimage))
    }

    /// The HKDF `info` of one outer key.
    static func keyInfo(callIdL: String, kind: InnerSealV2.Kind, direction: InnerSealV2.Direction, acceptBinding: Data, relayx: Data) -> Data? {
        let id = [UInt8](callIdL.utf8)
        guard id.count <= 0xFFFF else { return nil }
        var info = HkdfLabels.relayInfoPrefixV1
        info.append(RekeyChain.lp16(id))
        info.append(RekeyChain.lp16([UInt8](kind.word.utf8)))
        info.append(RekeyChain.lp16([UInt8](direction.word.utf8)))
        info.append(acceptBinding)
        info.append(relayx)
        return info
    }

    /// The four keys of one round, or nil when an input has the wrong size. Nothing derived is left behind on a failure.
    static func deriveOuterKeys(secrets: RelaySecrets, sessionKey: Data, acceptBinding: Data, callIdL: String) -> OuterRoundKeys? {
        guard sessionKey.count == 32, acceptBinding.count == 32 else { return nil }
        guard var shared = secrets.relaySS.copyData() else { return nil }
        defer { CryptoConstants.zeroize(&shared) }
        guard var binding = secrets.relayx.copyData() else { return nil }
        defer { CryptoConstants.zeroize(&binding) }
        guard shared.count == 64, binding.count == 32 else { return nil }
        var ikm = shared
        ikm.append(sessionKey)
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm), salt: HkdfLabels.relaySaltV1)
        CryptoConstants.zeroize(&ikm)
        let prkKey = SymmetricKey(data: prk)
        let order: [(InnerSealV2.Kind, InnerSealV2.Direction)] = [
            (.audio, .offererToAcceptor), (.audio, .acceptorToOfferer), (.video, .offererToAcceptor), (.video, .acceptorToOfferer)
        ]
        var built: [ChainKeyBuffer] = []
        for pair in order {
            guard let info = keyInfo(callIdL: callIdL, kind: pair.0, direction: pair.1, acceptBinding: acceptBinding, relayx: binding) else {
                for buffer in built { buffer.wipe() }
                return nil
            }
            let okm = HKDF<SHA256>.expand(pseudoRandomKey: prkKey, info: info, outputByteCount: 32)
            var bytes = okm.withUnsafeBytes { Data($0) }
            built.append(ChainKeyBuffer(copying: bytes))
            CryptoConstants.zeroize(&bytes)
        }
        return OuterRoundKeys(
            audioOffererToAcceptor: built[0], audioAcceptorToOfferer: built[1],
            videoOffererToAcceptor: built[2], videoAcceptorToOfferer: built[3])
    }

    // MARK: - The two sides

    /// The offerer's per-round pair, or nil when a key cannot be generated.
    static func generateOfferKeys() -> RelayOfferKeys? {
        guard let pair = try? PqcKeyExchange().generateKeyPair(), pair.publicKey.count == RelayKemWire.mlkemBytes else { return nil }
        let scalar = Curve25519.KeyAgreement.PrivateKey()
        var secret = pair.privateKey
        var raw = scalar.rawRepresentation
        let wire = RelayKemWire(mlkem: pair.publicKey, x25519: scalar.publicKey.rawRepresentation)
        let keys = RelayOfferKeys(pub: wire, mlkemSecret: secret, x25519Scalar: raw)
        CryptoConstants.zeroize(&secret)
        CryptoConstants.zeroize(&raw)
        return keys
    }

    /// The acceptor's step with the production primitives.
    static func encapsulate(offer: RelayKemWire) -> RelayEncapResult {
        encapsulate(offer: offer, mlkemEncaps: { key in
            guard let result = try? PqcKeyExchange().encapsulate(remotePublicKey: key) else { return nil }
            return (ct: result.ciphertext, ss: result.sharedSecret)
        }, x25519Scalar: nil)
    }

    /// The acceptor's step. `mlkemEncaps` and `x25519Scalar` are parameters so that a known-answer test can fix the randomness;
    /// production code never passes them.
    static func encapsulate(offer: RelayKemWire, mlkemEncaps: (Data) -> (ct: Data, ss: Data)?, x25519Scalar: Data?) -> RelayEncapResult {
        guard offer.hasExactLengths, isCanonicalMlKemEncapsulationKey(offer.mlkem) else { return .badKey }
        guard var encaps = mlkemEncaps(offer.mlkem), encaps.ct.count == RelayKemWire.mlkemBytes else { return .failed }
        defer { CryptoConstants.zeroize(&encaps.ss) }
        var scalar: Data
        if let fixed = x25519Scalar {
            scalar = fixed
        } else {
            scalar = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        }
        defer { CryptoConstants.zeroize(&scalar) }
        guard let ownPublic = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar).publicKey.rawRepresentation else {
            return .failed
        }
        guard var dh = x25519Shared(scalar: scalar, peerPublic: offer.x25519) else { return .x25519Zero }
        var relaySS = encaps.ss
        relaySS.append(dh)
        let accept = RelayKemWire(mlkem: encaps.ct, x25519: ownPublic)
        let secrets = RelaySecrets(relaySS: relaySS, relayx: relayx(offer: offer, accept: accept))
        CryptoConstants.zeroize(&dh)
        CryptoConstants.zeroize(&relaySS)
        return .ok(accept: accept, secrets: secrets)
    }
}
