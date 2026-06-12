import Foundation
import CryptoKit

/// SW-counterparty earbud-handshake state machine — direct port of
/// Android `EarbudHandshakeResponder.kt` (ADP-A redesign).
///
/// iOS is ALWAYS the counterparty on `earbud-relay-v1` calls (there is
/// no iOS earbud transport): it talks to the EARBUD FIRMWARE through the
/// peer phone, which acts as a zero-knowledge BLE↔WS relay.
///
/// Strictly-ordered, ONE-SHOT:
///   INIT -> SENT_HSINIT -> DONE | FAIL
/// Any out-of-order / duplicate / post-terminal / crypto-fail input ⇒
/// terminal `.fail`; the 32-byte session key is exposed ONLY inside
/// `.done` (never on any fail / partial path).
///
/// NOT a cryptographic change (CRUX KAT): the crypto seam reuses the
/// existing frozen primitives — ML-KEM-1024 encapsulate
/// (`PqcKeyExchange`), X25519 (CryptoKit, same as the engine hybrid
/// path) and the cross-platform-pinned schema-:2 ct-binding KDF
/// (`QAudionCallIntegration.deriveHybridSessionKey`, pinned by
/// tools/kat/hybrid-combine/hybrid-combine-kat.json — the same vectors
/// `EarbudHandshakeCounterpartyKatTest` pins on Android).
public final class EarbudHandshakeResponder {

    public struct X25519KeyPair {
        public let pub: Data
        public let opaquePriv: Data
        public init(pub: Data, opaquePriv: Data) {
            self.pub = pub
            self.opaquePriv = opaquePriv
        }
    }

    public struct MlkemEncaps {
        public let ciphertext: Data
        public let sharedSecret: Data
        public init(ciphertext: Data, sharedSecret: Data) {
            self.ciphertext = ciphertext
            self.sharedSecret = sharedSecret
        }
    }

    /// Narrow seam over the existing crypto — mirrors Android
    /// `EarbudHandshakeResponder.HybridCrypto` so the state machine stays
    /// key-material-free and unit-testable with a fake.
    public protocol HybridCrypto {
        func generateX25519() throws -> X25519KeyPair
        func mlkemEncapsulate(earbudMlkemPk: Data) throws -> MlkemEncaps
        func x25519Ecdh(ownPriv: Data, earbudX25519Pub: Data) throws -> Data
        /// Derive the 32-byte session key (schema :2 ct-binding KDF; the
        /// implementation injects any sovereign PSK as the frozen HKDF
        /// salt — the state machine itself carries no PSK argument).
        func deriveSessionKey(mlkemSs: Data, x25519Ss: Data, mlkemCt: Data) throws -> Data
    }

    public enum Step: Equatable {
        case send(pdus: [Data])
        case done(send: [Data], sessionKey: Data)
        case needMore
        case fail(reason: String)
    }

    private enum S { case initial, sentHsinit, done, failed }
    private var state: S = .initial
    private var ownPriv: Data?
    private let hsresp = EarbudFwPduCodec.HsrespReassembler()
    private let crypto: HybridCrypto
    private let counter: Int

    public init(crypto: HybridCrypto, counter: Int = 1) {
        self.crypto = crypto
        self.counter = counter
    }

    public func start() -> Step {
        guard state == .initial else { return fail("start() in state \(state)") }
        guard let kp = try? crypto.generateX25519() else { return fail("X25519 keygen failed") }
        guard kp.pub.count == EarbudFwPduCodec.x25519PubLen else { return fail("bad X25519 pub size") }
        ownPriv = kp.opaquePriv
        state = .sentHsinit
        guard let hsinit = EarbudFwPduCodec.buildHsinit(counter: counter, x25519Pub: kp.pub) else {
            return fail("HSINIT build failed (counter out of range?)")
        }
        return .send(pdus: [hsinit])
    }

    public func onInbound(_ pdu: Data) -> Step {
        if state == .failed || state == .done { return fail("input in terminal state \(state)") }
        guard state == .sentHsinit else { return fail("input before start()") }
        switch hsresp.offer(pdu) {
        case .needMore:
            return .needMore
        case .abort(let reason):
            return fail("HSRESP: \(reason)")
        case .ok(let mlkemEk, let earbudX25519):
            return complete(earbudEk: mlkemEk, earbudX: earbudX25519)
        }
    }

    private func complete(earbudEk: Data, earbudX: Data) -> Step {
        guard let priv = ownPriv else { return fail("no own X25519 priv") }
        guard let enc = try? crypto.mlkemEncapsulate(earbudMlkemPk: earbudEk) else {
            return fail("ML-KEM encaps failed")
        }
        guard enc.ciphertext.count == EarbudFwPduCodec.mlkem1024CtLen else { return fail("bad ct size") }
        // FW-H6 parity (firmware qaudion_gatt.c:818-846): reject low-order /
        // small-subgroup X25519 results. CryptoKit throws on the RFC 7748
        // §6.1 all-zero-output check; the explicit loop is belt-and-braces
        // (mirrors the firmware's own all-zero loop).
        guard let xSs = try? crypto.x25519Ecdh(ownPriv: priv, earbudX25519Pub: earbudX) else {
            return fail("X25519 ECDH failed")
        }
        var z: UInt8 = 0
        for b in xSs { z |= b }
        guard xSs.count == 32, z != 0 else { return fail("X25519 SS all-zero (FW-H6)") }
        guard let key = try? crypto.deriveSessionKey(
            mlkemSs: enc.sharedSecret, x25519Ss: xSs, mlkemCt: enc.ciphertext
        ) else { return fail("deriveSessionKey failed") }
        guard key.count == 32 else { return fail("bad session-key size") }
        // FW-H7: HSINIT consumed `counter`; HSFIN[0] must use counter+1,
        // [1] counter+2, … (strictly-increasing per GATT write).
        guard let hsfin = EarbudFwPduCodec.buildHsfin(
            startCounter: counter + 1, mlkemCiphertext: enc.ciphertext
        ) else { return fail("HSFIN build failed (counter window exhausted)") }
        state = .done
        return .done(send: hsfin, sessionKey: key)
    }

    private func fail(_ why: String) -> Step {
        state = .failed
        ownPriv = nil
        return .fail(reason: why)
    }
}

/// Production binding of `EarbudHandshakeResponder.HybridCrypto` onto the
/// EXISTING engine primitives — mirrors Android `EarbudHandshakeCrypto.kt`.
/// Introduces NO new cryptographic construction:
///
///  - X25519 keygen / ECDH → CryptoKit `Curve25519.KeyAgreement`, the same
///    curve implementation the engine hybrid path uses.
///  - ML-KEM-1024 encapsulate → `PqcKeyExchange.encapsulate` (liboqs),
///    the production KEM.
///  - deriveSessionKey → `QAudionCallIntegration.deriveHybridSessionKey`
///    (schema :2 ct-binding, KAT-pinned cross-platform; the optional
///    sovereign `psk` becomes the frozen HKDF salt; nil ⇒ byte-identical
///    to the firmware counterparty derivation).
public final class EarbudHandshakeCrypto: EarbudHandshakeResponder.HybridCrypto {

    public enum CryptoError: Error { case malformedKey }

    private let psk: Data?
    private let pqc = PqcKeyExchange()

    public init(psk: Data? = nil) {
        self.psk = psk
    }

    public func generateX25519() throws -> EarbudHandshakeResponder.X25519KeyPair {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        return EarbudHandshakeResponder.X25519KeyPair(
            pub: priv.publicKey.rawRepresentation,
            opaquePriv: priv.rawRepresentation
        )
    }

    public func mlkemEncapsulate(earbudMlkemPk: Data) throws -> EarbudHandshakeResponder.MlkemEncaps {
        let r = try pqc.encapsulate(remotePublicKey: earbudMlkemPk)
        return EarbudHandshakeResponder.MlkemEncaps(
            ciphertext: r.ciphertext,
            sharedSecret: r.sharedSecret
        )
    }

    public func x25519Ecdh(ownPriv: Data, earbudX25519Pub: Data) throws -> Data {
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ownPriv)
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: earbudX25519Pub)
        // CryptoKit enforces the RFC 7748 §6.1 all-zero check internally
        // (throws on low-order input) — FW-H6 parity with BouncyCastle.
        let ss = try priv.sharedSecretFromKeyAgreement(with: pub)
        return ss.withUnsafeBytes { Data($0) }
    }

    public func deriveSessionKey(mlkemSs: Data, x25519Ss: Data, mlkemCt: Data) throws -> Data {
        // Frozen schema-:2 ct-binding KDF — same production function the
        // hybrid-combine-kat:2 cross-platform vectors pin (psk, when
        // present, is the HKDF Extract salt).
        return QAudionCallIntegration.deriveHybridSessionKey(
            pqcSs: mlkemSs,
            x25519Ss: x25519Ss,
            pqcCiphertext: mlkemCt,
            psk: psk
        )
    }
}

/// FW-H7 — strictly-monotonic HSINIT counter allocator, per peer phone.
///
/// The firmware's anti-replay counter is per-`bt_conn` and survives the
/// call boundary (the earbud-side phone keeps the BLE ACL alive between
/// calls), so consecutive calls from the SAME counterparty must use
/// strictly increasing HSINIT counters. Mirrors Android
/// `EarbudHsinitCounterAllocator`: start at 1, advance by 10 per call
/// (HSINIT consumes 1 value + 8 HSFIN fragments ⇒ ≤ 9 used per call),
/// exhausted past 245 (returns nil ⇒ caller surfaces "re-pair earbud").
/// Persisted in UserDefaults keyed by peer userId.
public enum EarbudHsinitCounterAllocator {

    private static let keyPrefix = "qaudion.earbud.hsinit_counter."
    private static let step = 10
    private static let maxStart = 245   // start + 8 HSFIN frags ≤ 253 < 255

    public static func allocate(peerId: String, defaults: UserDefaults = .standard) -> Int? {
        let key = keyPrefix + peerId
        let current = defaults.object(forKey: key) as? Int ?? 1
        guard current <= maxStart else { return nil }
        defaults.set(current + step, forKey: key)
        return current
    }

    /// Reset after a re-pair (firmware counter resets on ACL teardown +
    /// re-bond). Exposed for the future pairing-flow hook + tests.
    public static func reset(peerId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: keyPrefix + peerId)
    }
}
