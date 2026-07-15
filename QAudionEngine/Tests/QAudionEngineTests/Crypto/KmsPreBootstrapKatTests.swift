import XCTest
import CryptoKit
@testable import QAudionEngine

/// gap A2 / ADR-014a — `qa_kms_prebootstrap:1` envelope cross-platform
/// verifier (iOS side).
///
/// Loads `Resources/kat/kms-prebootstrap-kat.json` (vendored byte-copy of
/// `qaudion-android-new/qaudion-engine/src/test/resources/kms-prebootstrap-kat.json`).
///
/// The vectors' OWN "notes" field says their ephemeral/session key
/// material is RANDOM per generation run — they are NOT meant to be
/// bit-reproduced by a fresh `encode()` call. Their value here is
/// DECODE-side structural fidelity: each vector's `envelope_bytes_hex` is
/// a REAL canonical-CBOR envelope produced by the Kotlin engine. This test
/// parses it with the Swift `KmsPreBootstrapCbor` decoder, extracts every
/// field, then INDEPENDENTLY rebuilds `ad_bytes` via
/// `KmsPreBootstrap.buildAdBytes` (mirroring Android's `buildAdBytes`) and
/// asserts it byte-equals the parsed `ad_bytes` field — validating that
/// the Swift CBOR encode+decode+ad_bytes-construction are byte-compatible
/// with the Kotlin engine WITHOUT needing the corresponding private keys
/// (which aren't in the KAT file; encode/decode itself is separately
/// exercised by `testSelfConsistencyRoundTrip` below).
///
/// ⚠️ Requires `swift test` (CryptoKit + the C `CLiboqs` target). Authored
/// on win32, which cannot run a Swift toolchain — every byte offset/field
/// name here was cross-checked against `KmsPreBootstrapCbor.kt` /
/// `KmsPreBootstrap.kt` by hand, but CI is the actual gate (same caveat as
/// `KmsHsBundleV1KatTests.swift`'s header).
final class KmsPreBootstrapKatTests: XCTestCase {

    private struct KatVector: Decodable {
        let name: String
        let sender_uuid_hex: String
        let receiver_uuid_hex: String
        let receiver_ik_x25519_pub_hex: String?
        let ts: Int64
        let one_time_prekey_id: UInt32?
        let envelope_bytes_hex: String
        let envelope_size: Int
    }

    private struct KatFile: Decodable {
        let version: Int
        let vectors: [KatVector]
    }

    private func loadKat() -> KatFile? {
        let data: Data?
        if let url = Bundle.module.url(forResource: "kms-prebootstrap-kat", withExtension: "json") {
            data = try? Data(contentsOf: url)
        } else {
            data = fsFallback()
        }
        guard let d = data else { return nil }
        return try? JSONDecoder().decode(KatFile.self, from: d)
    }

    private func fsFallback() -> Data? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<8 {
            for rel in [
                "qaudion-android-new/qaudion-engine/src/test/resources/kms-prebootstrap-kat.json",
                "QAudionEngine/Tests/QAudionEngineTests/Resources/kat/kms-prebootstrap-kat.json",
            ] {
                let c = dir.appendingPathComponent(rel)
                if fm.fileExists(atPath: c.path), let d = try? Data(contentsOf: c) { return d }
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Structural / ad_bytes fidelity

    func testEveryVectorAdBytesReconstructs() throws {
        guard let kat = loadKat() else {
            XCTFail("kms-prebootstrap-kat.json not found (Bundle.module + fs fallback both missed)")
            return
        }
        XCTAssertEqual(kat.version, 1)
        XCTAssertGreaterThanOrEqual(kat.vectors.count, 3)

        var sawLongTerm = false, sawHybridOtp = false, sawV1Fallback = false
        for v in kat.vectors {
            try runVector(v)
            switch v.name {
            case "long-term": sawLongTerm = true
            case "hybrid-otp": sawHybridOtp = true
            case "v1-fallback": sawV1Fallback = true
            default: break
            }
        }
        XCTAssertTrue(sawLongTerm, "expected the 'long-term' vector (no OTP, has X25519)")
        XCTAssertTrue(sawHybridOtp, "expected the 'hybrid-otp' vector (OTP present, has X25519)")
        XCTAssertTrue(sawV1Fallback, "expected the 'v1-fallback' vector (no OTP, receiver_ik_x25519_pub_hex null)")
    }

    private func runVector(_ v: KatVector) throws {
        let envelopeBytes = Data(hex: v.envelope_bytes_hex)
        XCTAssertEqual(envelopeBytes.count, v.envelope_size, "[\(v.name)] envelope_size drift")

        // 1) Decode the REAL Kotlin-produced envelope with the Swift CBOR
        //    decoder — this alone proves KmsPreBootstrapCbor.decodeEnvelope
        //    parses Android's wire bytes without error.
        let parsed = try KmsPreBootstrapCbor.decodeEnvelope(envelopeBytes)
        XCTAssertEqual(parsed.magic, 1, "[\(v.name)] magic")
        XCTAssertEqual(parsed.v, 1, "[\(v.name)] v")

        // 2) `s`/`r` round-trip through uuidStringToRaw must equal the
        //    vector's own raw hex — proves the UUID string<->raw helpers
        //    agree with Android's uuidRawToCanonicalString/uuidStringToRaw.
        let sRaw = try KmsPreBootstrapCbor.uuidStringToRaw(parsed.s)
        let rRaw = try KmsPreBootstrapCbor.uuidStringToRaw(parsed.r)
        XCTAssertEqual(sRaw.hexEncodedString(), v.sender_uuid_hex, "[\(v.name)] sender uuid drift")
        XCTAssertEqual(rRaw.hexEncodedString(), v.receiver_uuid_hex, "[\(v.name)] receiver uuid drift")

        XCTAssertEqual(parsed.ts, v.ts, "[\(v.name)] ts drift")
        XCTAssertEqual(parsed.oneTimePrekeyId, v.one_time_prekey_id, "[\(v.name)] one_time_prekey_id drift")

        // 3) INDEPENDENTLY rebuild ad_bytes from the extracted fields
        //    (mirrors Android's buildAdBytes) and assert it byte-equals
        //    the envelope's own parsed ad_bytes field. This is the KAT's
        //    real value per its own "notes" field.
        let rebuiltAd = KmsPreBootstrap.buildAdBytes(
            envelopeVersion: Int(parsed.v),
            sUuid: sRaw,
            rUuid: rRaw,
            ts: parsed.ts,
            nonce: parsed.nonce,
            oneTimePrekeyId: parsed.oneTimePrekeyId
        )
        XCTAssertEqual(
            rebuiltAd.hexEncodedString(), parsed.adBytes.hexEncodedString(),
            "[\(v.name)] rebuilt ad_bytes MUST byte-equal the envelope's own ad_bytes field"
        )

        // 4) Structural sanity on the other fixed-size fields.
        XCTAssertEqual(parsed.nonce.count, 16, "[\(v.name)] nonce size")
        XCTAssertEqual(parsed.kemCt.count, 1568, "[\(v.name)] kem_ct size")
        XCTAssertEqual(parsed.ephX25519Pub.count, 32, "[\(v.name)] eph_x25519_pub size")
        XCTAssertEqual(parsed.sig.count, 64, "[\(v.name)] sig size")
        XCTAssertFalse(parsed.payloadCt.isEmpty, "[\(v.name)] payload_ct empty")
    }

    // MARK: - Self-consistency round trip (encode -> decode, fresh keys)

    /// Cannot bit-pin against Android without shared private keys (the
    /// KAT doesn't carry them), so this generates FRESH local ML-KEM-1024 +
    /// X25519 + Ed25519 keypairs (this repo's own `PqcKeyExchange` +
    /// CryptoKit), calls `KmsPreBootstrap.encode` then `.decode` with those
    /// keys, and asserts the recovered plaintext equals the original and
    /// the two `RK_0` values match. This is the strongest verification
    /// achievable without a live cross-platform 3-way test.
    func testSelfConsistencyRoundTrip() throws {
        let pqc = PqcKeyExchange()

        // Sender identity: only uuidRaw + ikEdPriv are read by encode().
        let senderUuid = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let senderEdKey = Curve25519.Signing.PrivateKey()

        // Receiver identity: needs the full long-term tuple for decode().
        let receiverUuid = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let receiverEdKey = Curve25519.Signing.PrivateKey()
        let receiverPqKeyPair = try pqc.generateKeyPair()
        let receiverXKey = Curve25519.KeyAgreement.PrivateKey()

        let receiverBundle = KmsPreBootstrap.ReceiverBundleView(
            uuidRaw: receiverUuid,
            ikEdPub: Data(receiverEdKey.publicKey.rawRepresentation),
            ikPqPub: try PqcKeyExchange.extractRawPublicKey(receiverPqKeyPair.publicKey),
            ikX25519Pub: Data(receiverXKey.publicKey.rawRepresentation)
        )
        let senderIdentity = KmsPreBootstrap.IdentityKeys(
            uuidRaw: senderUuid,
            ikEdPub: Data(senderEdKey.publicKey.rawRepresentation),
            ikEdPriv: Data(senderEdKey.rawRepresentation),
            ikPqPub: Data(), ikPqPriv: nil, ikX25519Pub: nil, ikX25519Priv: nil
        )
        let receiverIdentity = KmsPreBootstrap.IdentityKeys(
            uuidRaw: receiverUuid,
            ikEdPub: Data(receiverEdKey.publicKey.rawRepresentation),
            ikEdPriv: nil,
            ikPqPub: receiverBundle.ikPqPub,
            ikPqPriv: receiverPqKeyPair.privateKey,
            ikX25519Pub: receiverBundle.ikX25519Pub,
            ikX25519Priv: Data(receiverXKey.rawRepresentation)
        )

        let originalPayload = Data("{\"qa_grp\":1,\"t\":\"sender_key_init\"}".utf8)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        let encoded = try KmsPreBootstrap.encode(
            sender: senderIdentity,
            receiverBundle: receiverBundle,
            oneTimePrekey: nil,
            senderKeyInitPayload: originalPayload,
            nowMs: nowMs
        )
        XCTAssertEqual(encoded.rk0.count, 32)
        XCTAssertFalse(encoded.envelopeBytes.isEmpty)

        let replayCache = KmsPreBootstrapReplayCache()
        let (decodedPayload, decodedRk0) = try KmsPreBootstrap.decode(
            envelopeBytes: encoded.envelopeBytes,
            receiver: receiverIdentity,
            oneTimePrekeyLookup: { _ in nil },
            senderIkEdPub: Data(senderEdKey.publicKey.rawRepresentation),
            replayCache: replayCache,
            nowMs: nowMs
        )

        XCTAssertEqual(decodedPayload, originalPayload, "decode() must recover the original plaintext byte-for-byte")
        XCTAssertEqual(decodedRk0, encoded.rk0, "RK_0 must match between encode() and decode() for the same encap")

        // A second decode of the SAME envelope must be rejected as a replay.
        XCTAssertThrowsError(try KmsPreBootstrap.decode(
            envelopeBytes: encoded.envelopeBytes,
            receiver: receiverIdentity,
            oneTimePrekeyLookup: { _ in nil },
            senderIkEdPub: Data(senderEdKey.publicKey.rawRepresentation),
            replayCache: replayCache,
            nowMs: nowMs
        )) { error in
            guard let e = error as? KmsPreBootstrap.KmsPreBootstrapError else {
                XCTFail("expected KmsPreBootstrapError, got \(error)")
                return
            }
            XCTAssertEqual(e.failureMode, .replay)
        }
    }

    /// v1-fallback path: receiver has no X25519 leg at all (PQ-only encap),
    /// mirroring the KAT's "v1-fallback" vector shape.
    func testSelfConsistencyRoundTripV1Fallback() throws {
        let pqc = PqcKeyExchange()
        let senderUuid = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let senderEdKey = Curve25519.Signing.PrivateKey()
        let receiverUuid = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let receiverEdKey = Curve25519.Signing.PrivateKey()
        let receiverPqKeyPair = try pqc.generateKeyPair()

        let receiverBundle = KmsPreBootstrap.ReceiverBundleView(
            uuidRaw: receiverUuid,
            ikEdPub: Data(receiverEdKey.publicKey.rawRepresentation),
            ikPqPub: try PqcKeyExchange.extractRawPublicKey(receiverPqKeyPair.publicKey),
            ikX25519Pub: nil
        )
        let senderIdentity = KmsPreBootstrap.IdentityKeys(
            uuidRaw: senderUuid, ikEdPub: Data(senderEdKey.publicKey.rawRepresentation),
            ikEdPriv: Data(senderEdKey.rawRepresentation),
            ikPqPub: Data(), ikPqPriv: nil, ikX25519Pub: nil, ikX25519Priv: nil
        )
        let receiverIdentity = KmsPreBootstrap.IdentityKeys(
            uuidRaw: receiverUuid, ikEdPub: Data(receiverEdKey.publicKey.rawRepresentation), ikEdPriv: nil,
            ikPqPub: receiverBundle.ikPqPub, ikPqPriv: receiverPqKeyPair.privateKey,
            ikX25519Pub: nil, ikX25519Priv: nil
        )

        let originalPayload = Data("{\"qa_grp\":1,\"t\":\"sender_key_rotate\"}".utf8)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        let encoded = try KmsPreBootstrap.encode(
            sender: senderIdentity, receiverBundle: receiverBundle, oneTimePrekey: nil,
            senderKeyInitPayload: originalPayload, nowMs: nowMs
        )
        let (decodedPayload, decodedRk0) = try KmsPreBootstrap.decode(
            envelopeBytes: encoded.envelopeBytes, receiver: receiverIdentity,
            oneTimePrekeyLookup: { _ in nil },
            senderIkEdPub: Data(senderEdKey.publicKey.rawRepresentation),
            replayCache: KmsPreBootstrapReplayCache(), nowMs: nowMs
        )
        XCTAssertEqual(decodedPayload, originalPayload)
        XCTAssertEqual(decodedRk0, encoded.rk0)
    }
}

private extension Data {
    init(hex: String) {
        precondition(hex.count % 2 == 0)
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            data.append(UInt8(hex[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        self = data
    }

    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
