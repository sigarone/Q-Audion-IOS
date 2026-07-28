import Foundation
import CryptoKit

/// KMS pre-bootstrap engine — gap A2 / ADR-014a.
///
/// Implements the `qa_kms_prebootstrap:1` envelope defined in ADR-014a
/// §2.3-§2.5 (see `qaudion-desktop/docs/adr/ADR-014a-kms-prebootstrap.md`).
/// Wraps a single `sender_key_init`/`sender_key_rotate` payload inside a
/// hybrid (ML-KEM-1024 + X25519, or PQ-only when the receiver is on a v1
/// bundle) authenticated envelope, lets the receiver derive a fresh
/// `RK_0`, and returns that `RK_0` to the caller so it can seed a
/// Phase-1 (v1) ratchet exactly as if the bytes had arrived from a
/// PQXDH voice handshake.
///
/// Direct byte-for-byte port of Android
/// `qaudion-android-new/qaudion-engine/.../crypto/KmsPreBootstrap.kt`
/// (that file is the authoritative algorithm spec — read it before
/// touching this one). Cross-platform contract, verified against the
/// shared KAT fixture `kms-prebootstrap-kat.json` (structural / ad_bytes
/// fidelity — see `KmsPreBootstrapKatTests.swift`; the KAT vectors use
/// random per-run key material so they do NOT pin exact ciphertext bytes,
/// only the CBOR envelope shape + independently-rebuilt `ad_bytes`).
///
/// **Receiver verification order** (cheap -> expensive) per ADR §2.5:
///  1. length checks
///  2. ts skew check
///  3. replay cache probe
///  4. Ed25519 sig verify against pinned `IK_ed`
///  5. one-time prekey lookup if id present
///  6. ML-KEM-1024 decap
///  7. X25519 (skipped on v1-fallback)
///  8. ChaCha20-Poly1305 decrypt with AAD
///
/// Steps 6-8 are expensive; sig-verify-first protects against an
/// attacker who can force decap by spamming garbage envelopes.
public enum KmsPreBootstrap {

    // MARK: - ADR-014a §2.4 constants

    /// Domain tag for the HKDF salt AND the signature transcript (same 28
    /// ASCII bytes incl. trailing 0x00) — matches Android's `SALT_DOMAIN`
    /// / `SIG_DOMAIN` (both point at the same constant there too).
    static let domainTag: Data = Data("qaudion-kms-prebootstrap-v1".utf8) + Data([0x00])

    /// HKDF-Expand info string for the AEAD payload key.
    static let infoPayloadKey: Data = Data("kms-payload-key".utf8)

    static let envelopeVersion = 1
    static let nonceBytes = 16
    static let kemCtBytes = 1568
    static let ephXPubBytes = 32
    static let mlkemPubBytes = 1568
    static let mlkemPrivBytes = 3168
    static let maxPayloadBytes = 4096
    static let maxTsSkewMs: Int64 = 5 * 60 * 1000

    /// ChaCha20-Poly1305 nonce size — 12 bytes per RFC 8439 §2.3.
    static let chachaNonceBytes = 12

    // MARK: - Public types

    /// Result of `encode`: the on-the-wire envelope bytes plus the
    /// 32-byte `RK_0` derived during encap. The caller MUST install its
    /// own outgoing 1:1 ratchet seeded by `rk0` BEFORE the receiver's
    /// first reply lands — otherwise the symmetric ratchet is asymmetric
    /// (only the receiver has it) and the peer's first response is
    /// undecryptable. Mirrors Android's `KmsPreBootstrap.EncodeResult`.
    public struct EncodeResult {
        public let envelopeBytes: Data
        public let rk0: Data
    }

    /// In-memory view of a Q-Audion identity tuple, mirroring Android's
    /// `com.bcrypto.qaudion.identity.IdentityKeys`. Sender side (encode)
    /// only reads `uuidRaw` + `ikEdPriv`; receiver side (decode) needs
    /// the long-term private halves to decapsulate, plus its own
    /// `ikEdPub` (hashed into the transcript it must match what the
    /// sender fetched as our published bundle).
    public struct IdentityKeys {
        public let uuidRaw: Data          // 16B
        public let ikEdPub: Data          // 32B
        public let ikEdPriv: Data?        // 32B raw seed, sender-side only
        public let ikPqPub: Data          // 1568B ML-KEM-1024, receiver-side only (may be empty on sender)
        public let ikPqPriv: Data?        // 3168B, receiver-side only
        public let ikX25519Pub: Data?     // 32B, nil => v1 (no X25519 leg)
        public let ikX25519Priv: Data?    // 32B, receiver-side only

        public init(
            uuidRaw: Data, ikEdPub: Data, ikEdPriv: Data?,
            ikPqPub: Data, ikPqPriv: Data?,
            ikX25519Pub: Data?, ikX25519Priv: Data?
        ) {
            self.uuidRaw = uuidRaw
            self.ikEdPub = ikEdPub
            self.ikEdPriv = ikEdPriv
            self.ikPqPub = ikPqPub
            self.ikPqPriv = ikPqPriv
            self.ikX25519Pub = ikX25519Pub
            self.ikX25519Priv = ikX25519Priv
        }
    }

    /// Receiver-view of a bundle as fetched from the directory
    /// (`BCryptoKmsClient.IdentityBundleV2`). `ikX25519Pub == nil`
    /// implies a v1 (PQ-only) bundle.
    public struct ReceiverBundleView {
        public let uuidRaw: Data          // 16B
        public let ikEdPub: Data          // 32B
        public let ikPqPub: Data          // 1568B
        public let ikX25519Pub: Data?     // 32B or nil

        public init(uuidRaw: Data, ikEdPub: Data, ikPqPub: Data, ikX25519Pub: Data?) {
            self.uuidRaw = uuidRaw
            self.ikEdPub = ikEdPub
            self.ikPqPub = ikPqPub
            self.ikX25519Pub = ikX25519Pub
        }
    }

    /// Public-only one-time prekey tuple as returned by `/prekey/next`.
    public struct ReceiverOneTimePrekeyView {
        public let prekeyId: UInt32
        public let pqPub: Data            // 1568B
        public let x25519Pub: Data        // 32B

        public init(prekeyId: UInt32, pqPub: Data, x25519Pub: Data) {
            self.prekeyId = prekeyId
            self.pqPub = pqPub
            self.x25519Pub = x25519Pub
        }
    }

    /// Local one-time prekey tuple (receiver side only — the private
    /// halves for a prekey THIS device previously published). iOS
    /// currently has no local one-time-prekey pool (see the TODO on
    /// `AppState.attemptGroupCtrlKmsPreBootstrap`), so a real lookup
    /// callback that finds one is future work; the type exists so the
    /// `decode` signature matches Android's shape and the lookup path
    /// is exercised (always missing -> `.missingPrekey`) rather than
    /// silently absent.
    public struct OneTimePrekey {
        public let prekeyId: UInt32
        public let pqPub: Data            // 1568B
        public let pqPriv: Data           // 3168B
        public let x25519Pub: Data        // 32B
        public let x25519Priv: Data       // 32B

        public init(prekeyId: UInt32, pqPub: Data, pqPriv: Data, x25519Pub: Data, x25519Priv: Data) {
            self.prekeyId = prekeyId
            self.pqPub = pqPub
            self.pqPriv = pqPriv
            self.x25519Pub = x25519Pub
            self.x25519Priv = x25519Priv
        }
    }

    /// Failure modes surfaced by `decode` — telemetry-friendly, never
    /// leaks secret-state detail to a remote peer.
    public enum FailureMode: String {
        case malformed, wrongRecipient, timestampSkew, replay, badSig, missingPrekey, aead
    }

    public struct KmsPreBootstrapError: Error {
        public let failureMode: FailureMode
        public let message: String
    }

    public enum EncodeError: Error {
        case payloadTooLarge
        case missingSenderSigningKey
        case invalidReceiverPqPub
        case invalidOneTimePrekey
        case encapFailed(Error)
        case signFailed(Error)
    }

    // MARK: - encode

    /// Build a `qa_kms_prebootstrap:1` envelope ready to ship via the
    /// existing 1:1 opaque-message channel.
    ///
    /// - Parameters:
    ///   - sender: sender's `IdentityKeys` — only `uuidRaw` and
    ///     `ikEdPriv` are read (matches Android's `encode`, which never
    ///     touches the sender's own PQ/X25519 halves — the sender always
    ///     generates a fresh ephemeral X25519 for forward secrecy on the
    ///     X-leg per ADR-014a §2.3).
    ///   - receiverBundle: fetched from the directory (`fetchUserIdentityBundleV2`).
    ///   - oneTimePrekey: public-half tuple from `/prekey/next`, or nil
    ///     to use the receiver's long-term keys.
    ///   - senderKeyInitPayload: bytes of the embedded `sender_key_init`/
    ///     `sender_key_rotate` envelope JSON — opaque to this layer.
    ///   - nowMs: current Unix epoch ms, written to the envelope's `ts`.
    public static func encode(
        sender: IdentityKeys,
        receiverBundle: ReceiverBundleView,
        oneTimePrekey: ReceiverOneTimePrekeyView?,
        senderKeyInitPayload: Data,
        nowMs: Int64
    ) throws -> EncodeResult {
        guard senderKeyInitPayload.count <= maxPayloadBytes else { throw EncodeError.payloadTooLarge }
        guard let ikEdPriv = sender.ikEdPriv, ikEdPriv.count == 32 else {
            throw EncodeError.missingSenderSigningKey
        }

        // 1) Per-envelope nonce + ephemeral X25519.
        var nonce = Data(count: nonceBytes)
        // force-unwrap safe: nonce is Data(count: nonceBytes) with
        // nonceBytes == 16, always non-empty — baseAddress nil only for
        // an empty buffer.
        nonce.withUnsafeMutableBytes { ptr in
            // swiftlint:disable:next force_unwrapping
            _ = SecRandomCopyBytes(kSecRandomDefault, nonceBytes, ptr.baseAddress!)
        }
        let ephPriv = Curve25519.KeyAgreement.PrivateKey()
        let ephPub = Data(ephPriv.publicKey.rawRepresentation)

        // 2) Pick PQ + X25519 receiver halves: OTP if available, else long-term.
        let recvPqPub: Data
        let recvXPubOrNil: Data?
        let oneTimePrekeyId: UInt32?
        if let otp = oneTimePrekey {
            recvPqPub = otp.pqPub
            recvXPubOrNil = otp.x25519Pub
            oneTimePrekeyId = otp.prekeyId
        } else {
            recvPqPub = receiverBundle.ikPqPub
            recvXPubOrNil = receiverBundle.ikX25519Pub
            oneTimePrekeyId = nil
        }
        guard recvPqPub.count == mlkemPubBytes else { throw EncodeError.invalidReceiverPqPub }
        if let x = recvXPubOrNil { guard x.count == 32 else { throw EncodeError.invalidOneTimePrekey } }

        // 3) ML-KEM encap.
        let pqc = PqcKeyExchange()
        let encapResult: PqcKeyExchange.EncapsulationResult
        do {
            encapResult = try pqc.encapsulate(remotePublicKey: recvPqPub)
        } catch {
            throw EncodeError.encapFailed(error)
        }
        let kemCt = encapResult.ciphertext
        var ssKem = encapResult.sharedSecret

        // 4) X25519 — only when receiver has a public key for it.
        var ssX25519: Data?
        if let recvXPub = recvXPubOrNil,
           let peerPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recvXPub) {
            let shared = try ephPriv.sharedSecretFromKeyAgreement(with: peerPub)
            ssX25519 = shared.withUnsafeBytes { Data($0) }
        }

        // 5) Build ad_bytes (canonical CBOR over the open header).
        let adBytes = buildAdBytes(
            envelopeVersion: envelopeVersion,
            sUuid: sender.uuidRaw,
            rUuid: receiverBundle.uuidRaw,
            ts: nowMs,
            nonce: nonce,
            oneTimePrekeyId: oneTimePrekeyId
        )

        // 6) Derive RK_0 + payload key. NOTE: payload encrypts BEFORE we
        //    sign, because the transcript binds payload_ct.
        let rk0Sym = hkdfExtractRk0(
            sUuid: sender.uuidRaw, rUuid: receiverBundle.uuidRaw,
            ssKem: ssKem, ssX25519: ssX25519
        )
        let rk0 = rk0Sym.withUnsafeBytes { Data($0) }
        var payloadKey = hkdfExpand(prk: rk0Sym, info: infoPayloadKey, length: 32)

        // 7) Encrypt with ChaCha20-Poly1305(AAD = ad_bytes). AEAD nonce =
        //    first 12 bytes of the envelope `nonce` (16B) — matches
        //    Android/Desktop's `aeadEncryptChaCha` (NOT a separately
        //    HKDF-derived nonce — a prior Android bug did that and broke
        //    interop, see KmsPreBootstrap.kt encode() step 7 comment).
        let nonce12 = Data(nonce.prefix(chachaNonceBytes))
        let payloadCt = try chachaEncrypt(key: payloadKey, plaintext: senderKeyInitPayload, aad: adBytes, nonce12: nonce12)

        // 8) Build sig transcript and sign with sender's IK_ed.
        let receiverIkX25519PubOrZeros = receiverBundle.ikX25519Pub ?? Data(count: 32)
        let transcript = buildTranscript(
            adBytes: adBytes, kemCt: kemCt, ephXPub: ephPub,
            receiverIkPqPub: receiverBundle.ikPqPub, receiverIkEdPub: receiverBundle.ikEdPub,
            receiverIkX25519PubOrZeros: receiverIkX25519PubOrZeros,
            oneTimePrekeyId: oneTimePrekeyId, payloadCt: payloadCt
        )
        let digest = Data(SHA256.hash(data: transcript))
        let sig: Data
        do {
            let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: ikEdPriv)
            sig = try signer.signature(for: digest)
        } catch {
            throw EncodeError.signFailed(error)
        }

        // 9) Serialize the canonical CBOR envelope.
        let senderUuidStr = KmsPreBootstrapCbor.uuidRawToCanonicalString(sender.uuidRaw)
        let receiverUuidStr = KmsPreBootstrapCbor.uuidRawToCanonicalString(receiverBundle.uuidRaw)
        let frame = KmsPreBootstrapCbor.encodeEnvelope(
            envelopeVersion: envelopeVersion,
            senderUuidStr: senderUuidStr,
            receiverUuidStr: receiverUuidStr,
            ts: nowMs,
            nonce: nonce,
            kemCt: kemCt,
            ephX25519Pub: ephPub,
            oneTimePrekeyId: oneTimePrekeyId,
            payloadCt: payloadCt,
            adBytes: adBytes,
            sig: sig
        )

        // 10) Best-effort zeroize ephemeral secret material. `rk0` itself
        //     is NOT zeroed here — it's surfaced to the caller so the
        //     sender can install the symmetric outgoing ratchet; the
        //     CALLER must zero it after handing it to the ratchet vault.
        zero(&ssKem)
        if var x = ssX25519 { zero(&x) }
        zero(&payloadKey)

        return EncodeResult(envelopeBytes: frame, rk0: rk0)
    }

    // MARK: - decode

    /// Parse + verify + decrypt a `qa_kms_prebootstrap:1` envelope.
    ///
    /// Returns `(senderKeyInitPayload, RK_0)` on success. The caller MUST
    /// install a new Phase-1 (v1) ratchet seeded with `RK_0` before
    /// processing `senderKeyInitPayload` further.
    ///
    /// Throws `KmsPreBootstrapError` on any verification failure —
    /// `failureMode` is for telemetry only, never surfaced to the peer.
    public static func decode(
        envelopeBytes: Data,
        receiver: IdentityKeys,
        oneTimePrekeyLookup: (UInt32) -> OneTimePrekey?,
        senderIkEdPub: Data,
        replayCache: KmsPreBootstrapReplayCache,
        nowMs: Int64
    ) throws -> (payload: Data, rk0: Data) {
        guard senderIkEdPub.count == 32 else {
            throw KmsPreBootstrapError(failureMode: .malformed, message: "senderIkEdPub must be 32B")
        }
        guard let ikPqPriv = receiver.ikPqPriv, ikPqPriv.count == mlkemPrivBytes else {
            throw KmsPreBootstrapError(failureMode: .malformed, message: "decode requires receiver.ikPqPriv")
        }

        // Step 1 — length / structure (CBOR envelope decode).
        let parsed: ParsedFrame
        do {
            parsed = try cborParseEnvelope(envelopeBytes)
        } catch {
            throw KmsPreBootstrapError(failureMode: .malformed, message: "parse failed: \(error)")
        }
        guard parsed.payloadCt.count <= maxPayloadBytes else {
            throw KmsPreBootstrapError(failureMode: .malformed, message: "payload too large")
        }
        guard parsed.kemCt.count == kemCtBytes else {
            throw KmsPreBootstrapError(failureMode: .malformed, message: "kem_ct size")
        }
        guard parsed.ephXPub.count == ephXPubBytes else {
            throw KmsPreBootstrapError(failureMode: .malformed, message: "eph_x25519_pub size")
        }
        guard parsed.nonce.count == nonceBytes else {
            throw KmsPreBootstrapError(failureMode: .malformed, message: "nonce size")
        }
        guard parsed.rUuid == receiver.uuidRaw else {
            throw KmsPreBootstrapError(failureMode: .wrongRecipient, message: "r != self")
        }

        // Step 2 — timestamp skew.
        guard abs(nowMs - parsed.ts) <= maxTsSkewMs else {
            throw KmsPreBootstrapError(failureMode: .timestampSkew, message: "|now-ts|>5min")
        }

        // Step 3 — replay cache.
        guard replayCache.putIfAbsent(senderUuid: parsed.sUuid, nonce: parsed.nonce, nowMs: nowMs) else {
            throw KmsPreBootstrapError(failureMode: .replay, message: "nonce seen recently")
        }

        // Step 4 — verify ad_bytes matches what we'd reconstruct, then
        // verify Ed25519 sig over transcript with pinned senderIkEdPub.
        let rebuiltAd = buildAdBytes(
            envelopeVersion: parsed.envelopeVersion, sUuid: parsed.sUuid, rUuid: parsed.rUuid,
            ts: parsed.ts, nonce: parsed.nonce, oneTimePrekeyId: parsed.oneTimePrekeyId
        )
        guard rebuiltAd == parsed.adBytes else {
            throw KmsPreBootstrapError(failureMode: .malformed, message: "ad_bytes mismatch")
        }
        let receiverIkX25519PubOrZeros = receiver.ikX25519Pub ?? Data(count: 32)
        let transcript = buildTranscript(
            adBytes: parsed.adBytes, kemCt: parsed.kemCt, ephXPub: parsed.ephXPub,
            receiverIkPqPub: receiver.ikPqPub, receiverIkEdPub: receiver.ikEdPub,
            receiverIkX25519PubOrZeros: receiverIkX25519PubOrZeros,
            oneTimePrekeyId: parsed.oneTimePrekeyId, payloadCt: parsed.payloadCt
        )
        let digest = Data(SHA256.hash(data: transcript))
        guard let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: senderIkEdPub),
              verifier.isValidSignature(parsed.sig, for: digest) else {
            throw KmsPreBootstrapError(failureMode: .badSig, message: "Ed25519 verify failed")
        }

        // Step 5 — one-time prekey lookup (if id present).
        var pqPrivToUse = ikPqPriv
        var xPrivToUse = receiver.ikX25519Priv
        var xPubToUse = receiver.ikX25519Pub
        var consumedPrekey: OneTimePrekey?
        if let otpId = parsed.oneTimePrekeyId {
            guard let otp = oneTimePrekeyLookup(otpId) else {
                throw KmsPreBootstrapError(
                    failureMode: .missingPrekey,
                    message: "one_time_prekey_id \(otpId) not in local pool"
                )
            }
            consumedPrekey = otp
            pqPrivToUse = otp.pqPriv
            xPrivToUse = otp.x25519Priv
            xPubToUse = otp.x25519Pub
        }

        defer {
            if var p = consumedPrekey?.pqPriv { zero(&p) }
            if var p = consumedPrekey?.x25519Priv { zero(&p) }
        }

        // Step 6 — ML-KEM decap.
        let pqc = PqcKeyExchange()
        var ssKem: Data
        do {
            ssKem = try pqc.decapsulate(ciphertext: parsed.kemCt, privateKey: pqPrivToUse)
        } catch {
            throw KmsPreBootstrapError(failureMode: .aead, message: "ML-KEM decap failed: \(error)")
        }

        // Step 7 — X25519 (only if both sides have it).
        var ssX25519: Data?
        if let xpriv = xPrivToUse, let xpub = xPubToUse, xpriv.count == 32, xpub.count == 32,
           let privKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: xpriv) {
            if let peerPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: parsed.ephXPub) {
                let shared = try privKey.sharedSecretFromKeyAgreement(with: peerPub)
                ssX25519 = shared.withUnsafeBytes { Data($0) }
            }
        }

        // Derive RK_0 + payload key.
        let rk0Sym = hkdfExtractRk0(sUuid: parsed.sUuid, rUuid: parsed.rUuid, ssKem: ssKem, ssX25519: ssX25519)
        let rk0 = rk0Sym.withUnsafeBytes { Data($0) }
        var payloadKey = hkdfExpand(prk: rk0Sym, info: infoPayloadKey, length: 32)

        defer {
            zero(&payloadKey)
            zero(&ssKem)
            if var x = ssX25519 { zero(&x) }
        }

        // Step 8 — AEAD decrypt with AAD = ad_bytes. AEAD nonce = first
        // 12 bytes of the envelope `nonce`.
        let nonce12 = Data(parsed.nonce.prefix(chachaNonceBytes))
        let plaintext: Data
        do {
            plaintext = try chachaDecrypt(key: payloadKey, ciphertext: parsed.payloadCt, aad: parsed.adBytes, nonce12: nonce12)
        } catch {
            throw KmsPreBootstrapError(failureMode: .aead, message: "AEAD decrypt failed: \(error)")
        }

        return (plaintext, rk0)
    }

    // MARK: - ad_bytes / transcript (exposed for KAT structural verification)

    /// Canonical CBOR map carrying the envelope header. Used as AAD in
    /// the AEAD step and as part of the signature transcript. Exposed
    /// `public` (not just internal) so `KmsPreBootstrapKatTests` can
    /// independently rebuild `ad_bytes` from a KAT vector's extracted
    /// fields and assert it byte-equals the vector's own `ad_bytes` —
    /// the KAT's structural-fidelity check per its own "notes" field.
    ///
    /// Wire shape unchanged from Android's `buildAdBytes`: `ts` encoded
    /// as an 8B big-endian byte-string (mt-2), `s`/`r` as 16B raw
    /// byte-strings (mt-2), `v` + OTP-id as mt-0 unsigned ints, `nonce`
    /// as 16B byte-string (mt-2).
    public static func buildAdBytes(
        envelopeVersion: Int,
        sUuid: Data,
        rUuid: Data,
        ts: Int64,
        nonce: Data,
        oneTimePrekeyId: UInt32?
    ) -> Data {
        var tsBe = Data(count: 8)
        var beBits = UInt64(bitPattern: ts).bigEndian
        tsBe = withUnsafeBytes(of: &beBits) { Data($0) }
        var entries: [(String, KmsPreBootstrapCbor.Value)] = [
            ("v", .uint(UInt64(envelopeVersion))),
            ("s", .bytes(sUuid)),
            ("r", .bytes(rUuid)),
            ("ts", .bytes(tsBe)),
            ("nonce", .bytes(nonce)),
        ]
        if let id = oneTimePrekeyId {
            entries.append(("one_time_prekey_id", .uint(UInt64(id))))
        }
        return KmsPreBootstrapCbor.encodeMap(entries)
    }

    /// Build the signature transcript exactly as ADR-014a §2.3 specifies:
    /// `SIG_DOMAIN(28B) || ad_bytes || kem_ct || eph_x25519_pub ||
    ///  sha256(receiverIkPqPub) || sha256(receiverIkEdPub) ||
    ///  sha256(receiverIkX25519PubOrZeros) || be32(oneTimePrekeyId or 0) ||
    ///  payload_ct`
    private static func buildTranscript(
        adBytes: Data, kemCt: Data, ephXPub: Data,
        receiverIkPqPub: Data, receiverIkEdPub: Data, receiverIkX25519PubOrZeros: Data,
        oneTimePrekeyId: UInt32?, payloadCt: Data
    ) -> Data {
        var out = Data()
        out.append(domainTag)
        out.append(adBytes)
        out.append(kemCt)
        out.append(ephXPub)
        out.append(Data(SHA256.hash(data: receiverIkPqPub)))
        out.append(Data(SHA256.hash(data: receiverIkEdPub)))
        out.append(Data(SHA256.hash(data: receiverIkX25519PubOrZeros)))
        var idBe = (oneTimePrekeyId ?? 0).bigEndian
        out.append(withUnsafeBytes(of: &idBe) { Data($0) })
        out.append(payloadCt)
        return out
    }

    // MARK: - KDF

    private static func hkdfExtractRk0(sUuid: Data, rUuid: Data, ssKem: Data, ssX25519: Data?) -> SymmetricKey {
        var salt = Data()
        salt.append(domainTag)
        salt.append(sUuid)
        salt.append(rUuid)
        var ikm = Data()
        ikm.append(ssKem)
        if let x = ssX25519 { ikm.append(x) }
        // HKDF-Extract = HMAC-SHA256(salt, ikm) per RFC 5869 §2.2 — matches
        // Android's bare HMAC (they can't get the raw PRK out of BC's
        // combined Extract+Expand helper, so they compute Extract by
        // hand). CryptoKit's `HKDF<SHA256>.extract` gives us the same raw
        // PRK directly, which we then feed into a SEPARATE `expand` call
        // below — the two-step form, not the single-shot `deriveKey`
        // convenience (which would not expose the bare PRK as `RK_0`).
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt)
        return SymmetricKey(data: Data(prk))
    }

    private static func hkdfExpand(prk: SymmetricKey, info: Data, length: Int) -> Data {
        let key = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: info, outputByteCount: length)
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - AEAD

    private static func chachaEncrypt(key: Data, plaintext: Data, aad: Data, nonce12: Data) throws -> Data {
        let symKey = SymmetricKey(data: key)
        let nonce = try ChaChaPoly.Nonce(data: nonce12)
        let sealed = try ChaChaPoly.seal(plaintext, using: symKey, nonce: nonce, authenticating: aad)
        // Matches Android/Desktop's ciphertext‖tag(16B) concatenation
        // (BouncyCastle's ChaCha20Poly1305.doFinal appends the tag).
        return sealed.ciphertext + sealed.tag
    }

    private static func chachaDecrypt(key: Data, ciphertext: Data, aad: Data, nonce12: Data) throws -> Data {
        guard ciphertext.count >= 16 else {
            throw KmsPreBootstrapError(failureMode: .aead, message: "ciphertext shorter than tag")
        }
        let ct = ciphertext.prefix(ciphertext.count - 16)
        let tag = ciphertext.suffix(16)
        let symKey = SymmetricKey(data: key)
        let nonce = try ChaChaPoly.Nonce(data: nonce12)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try ChaChaPoly.open(box, using: symKey, authenticating: aad)
    }

    // MARK: - Frame parsing

    private struct ParsedFrame {
        let envelopeVersion: Int
        let sUuid: Data
        let rUuid: Data
        let ts: Int64
        let nonce: Data
        let kemCt: Data
        let ephXPub: Data
        let oneTimePrekeyId: UInt32?
        let adBytes: Data
        let payloadCt: Data
        let sig: Data
    }

    private static func cborParseEnvelope(_ bytes: Data) throws -> ParsedFrame {
        let env = try KmsPreBootstrapCbor.decodeEnvelope(bytes)
        guard Int(env.magic) == envelopeVersion else {
            throw KmsPreBootstrapError(failureMode: .malformed, message: "bad magic \(env.magic)")
        }
        guard Int(env.v) == envelopeVersion else {
            throw KmsPreBootstrapError(failureMode: .malformed, message: "bad version \(env.v)")
        }
        let sUuidRaw = try KmsPreBootstrapCbor.uuidStringToRaw(env.s)
        let rUuidRaw = try KmsPreBootstrapCbor.uuidStringToRaw(env.r)
        return ParsedFrame(
            envelopeVersion: Int(env.v), sUuid: sUuidRaw, rUuid: rUuidRaw, ts: env.ts,
            nonce: env.nonce, kemCt: env.kemCt, ephXPub: env.ephX25519Pub,
            oneTimePrekeyId: env.oneTimePrekeyId, adBytes: env.adBytes,
            payloadCt: env.payloadCt, sig: env.sig
        )
    }

    // MARK: - Helpers

    private static func zero(_ data: inout Data) {
        data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            memset(base, 0, ptr.count)
        }
    }
}

/// Lightweight TTL+LRU replay cache for `(senderUuid, nonce)` keys, per
/// ADR-014a §2.5 step 3 (1 hour default) — mirrors Android's
/// `com.bcrypto.qaudion.crypto.ReplayCache`. Thread-safe via an internal
/// lock (Android's is single-threaded-by-contract, serialized by its
/// caller's coroutine dispatcher; iOS callers are not guaranteed to be
/// serialized the same way, so this adds its own lock rather than
/// relying on caller discipline).
public final class KmsPreBootstrapReplayCache: @unchecked Sendable {
    private struct Key: Hashable {
        let senderUuid: Data
        let nonce: Data
    }

    private let lock = NSLock()
    private var order: [Key] = []          // insertion/access order, oldest first
    private var store: [Key: Int64] = [:]  // key -> lastSeenMs
    private let ttlMillis: Int64
    private let maxEntries: Int

    public init(ttlMillis: Int64 = 60 * 60 * 1000, maxEntries: Int = 4096) {
        self.ttlMillis = ttlMillis
        self.maxEntries = maxEntries
    }

    /// Atomic "have I seen this nonce in the last `ttlMillis`?" probe.
    /// Returns `true` if the entry was *new* (and is now recorded);
    /// `false` if it was already present and not expired (replay).
    public func putIfAbsent(senderUuid: Data, nonce: Data, nowMs: Int64) -> Bool {
        precondition(nonce.count == 16, "nonce must be 16B")
        precondition(senderUuid.count == 16, "senderUuid must be 16B")
        lock.lock()
        defer { lock.unlock() }
        purgeExpiredLocked(nowMs)
        let key = Key(senderUuid: senderUuid, nonce: nonce)
        if let existing = store[key], nowMs - existing <= ttlMillis {
            return false // replay
        }
        if store[key] == nil { order.append(key) }
        store[key] = nowMs
        if store.count > maxEntries, !order.isEmpty {
            let oldest = order.removeFirst()
            store.removeValue(forKey: oldest)
        }
        return true
    }

    private func purgeExpiredLocked(_ nowMs: Int64) {
        guard !store.isEmpty else { return }
        var stillLive: [Key] = []
        stillLive.reserveCapacity(order.count)
        for k in order {
            if let ts = store[k], nowMs - ts > ttlMillis {
                store.removeValue(forKey: k)
            } else {
                stillLive.append(k)
            }
        }
        order = stillLive
    }

    /// Visible for tests / metrics.
    public func size() -> Int { lock.lock(); defer { lock.unlock() }; return store.count }

    /// Visible for tests.
    public func clear() { lock.lock(); defer { lock.unlock() }; store.removeAll(); order.removeAll() }
}
