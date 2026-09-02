import XCTest
import CryptoKit
@testable import QAudionEngine

/// ATT-1 (`docs/security/CRYPTO_PROTOCOL_AUDIT_2026-09-01.md` backlog item 1)
/// — first-principles sign/verify round-trip and negative tests for
/// `FileAttachmentAnnounceSig` (the announce envelope's new optional Ed25519
/// signature) plus the wire-envelope codec's new `sg` field.
///
/// No cross-platform KAT vectors exist yet for this NEW scheme — Android and
/// Desktop each land their own port of ATT-1 separately (it is listed in the
/// audit's backlog as a coordinated wire change, one flag day per platform),
/// so unlike `KmsHsBundleV1KatTests`/`HandshakeTranscriptKatTests` this file
/// has no frozen JSON vectors to pin against yet. These are self-contained
/// round-trip + negative tests instead, in the same spirit
/// `HandshakeTranscriptV2Tests` uses for its own first-principles checks.
///
/// ⚠️ Requires `swift test` (CryptoKit `Curve25519.Signing`). Authored on
/// win32, which cannot run CryptoKit locally — NOT executed in this session;
/// this repo's GitHub Actions macOS runner (see `ios-preflight`/CI docs) is
/// the gate. The four cases below are exactly the ones the fix design calls
/// out: valid signature accepted, tampered/wrong-key rejected, absent
/// signature accepted, transport_sender_id mismatch rejected.
final class FileAttachmentAnnounceSigTests: XCTestCase {

    // MARK: - Fixtures

    private func fixedBytes(_ n: Int, seed: UInt8) -> Data {
        Data((0..<n).map { UInt8((Int($0) + Int(seed)) & 0xFF) })
    }

    private struct Fixture {
        let signerSeed: Data
        let signerPub: Data
        let fileId: Data
        let senderUuid: Data
        let recipientUuid: Data
        let senderEphemeralPub: Data
        let wraps: [FileAttachmentAnnounceSig.DeviceWrap]
        let tusFileId: String
        let totalChunks: Int
        let totalSizeBytes: Int64
        let transportSenderId: Data
    }

    private func makeFixture() throws -> Fixture {
        let seed = fixedBytes(32, seed: 0x11)
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let wraps = [
            FileAttachmentAnnounceSig.DeviceWrap(
                deviceId: fixedBytes(16, seed: 0x04),
                wrappedContentKey: fixedBytes(48, seed: 0x05)),
        ]
        return Fixture(
            signerSeed: seed,
            signerPub: signer.publicKey.rawRepresentation,
            fileId: fixedBytes(16, seed: 0x02),
            senderUuid: fixedBytes(16, seed: 0x03),
            recipientUuid: fixedBytes(16, seed: 0x06),
            senderEphemeralPub: fixedBytes(32, seed: 0x07),
            wraps: wraps,
            tusFileId: "tus-file-42",
            totalChunks: 3,
            totalSizeBytes: 196_608,
            // Honest case: the transport frame's sender equals the
            // envelope's own claimed sender — exactly what a genuine send
            // produces (the server stamps outbound frames with the true
            // authenticated sender).
            transportSenderId: fixedBytes(16, seed: 0x03)
        )
    }

    private func canon(_ f: Fixture, transportSenderId: Data? = nil) -> Data? {
        FileAttachmentAnnounceSig.canon(
            fileId: f.fileId, senderUuid: f.senderUuid, recipientUuid: f.recipientUuid,
            senderEphemeralPub: f.senderEphemeralPub, wraps: f.wraps, tusFileId: f.tusFileId,
            totalChunks: f.totalChunks, totalSizeBytes: f.totalSizeBytes,
            transportSenderId: transportSenderId ?? f.transportSenderId
        )
    }

    // MARK: - 1. Valid signature accepted

    func test_validSignature_verifiesUnderSignerKey() throws {
        let f = try makeFixture()
        let c = try XCTUnwrap(canon(f))
        let sig = try FileAttachmentAnnounceSig.sign(canon: c, signingPrivateKeyRaw: f.signerSeed)
        XCTAssertEqual(sig.count, 64)
        XCTAssertTrue(
            FileAttachmentAnnounceSig.verify(canon: c, signature: sig, signerIdentityKey: f.signerPub),
            "a genuine signature over the exact canon it was produced for must verify"
        )
    }

    // MARK: - 2. Tampered / wrong-key rejected

    func test_tamperedCanon_rejected() throws {
        let f = try makeFixture()
        let c = try XCTUnwrap(canon(f))
        let sig = try FileAttachmentAnnounceSig.sign(canon: c, signingPrivateKeyRaw: f.signerSeed)

        // Flip the last byte of the signed canon (part of transport_sender_id,
        // the field a spoofed WS frame or a substituted wrap would actually
        // move) — verification must fail under the same, correct, signer key.
        var tampered = c
        tampered[tampered.count - 1] ^= 0xFF
        XCTAssertFalse(
            FileAttachmentAnnounceSig.verify(canon: tampered, signature: sig, signerIdentityKey: f.signerPub),
            "a genuine signature must not verify against a tampered canon"
        )
    }

    func test_wrongSignerKey_rejected() throws {
        let f = try makeFixture()
        let c = try XCTUnwrap(canon(f))
        let sig = try FileAttachmentAnnounceSig.sign(canon: c, signingPrivateKeyRaw: f.signerSeed)

        // A genuine signature, but checked under a DIFFERENT identity key
        // than the one that produced it — e.g. a malicious server signs its
        // OWN forged envelope and the receiver correctly verifies against
        // the real sender's pinned key instead of trusting a wire-declared
        // key. Must fail.
        let otherSeed = fixedBytes(32, seed: 0x99)
        let otherPub = try Curve25519.Signing.PrivateKey(rawRepresentation: otherSeed).publicKey.rawRepresentation
        XCTAssertFalse(
            FileAttachmentAnnounceSig.verify(canon: c, signature: sig, signerIdentityKey: otherPub),
            "a genuine signature from key A must not verify under a different key B"
        )
    }

    // MARK: - 3. Absent signature accepted (wire-level compat)

    func test_absentSignature_parsesAsNilAndOmitsWireKey() throws {
        let envelope = FileAttachmentAnnounceWireEnvelope(
            fileId: UUID().uuidString, senderId: UUID().uuidString,
            senderEphPubB64: Data(repeating: 7, count: 32).base64EncodedString(),
            tusFileId: "tus-1", totalChunks: 1, chunkSize: 65536, totalSizeBytes: 10,
            mime: "application/octet-stream", filename: "f.bin",
            wraps: [.init(deviceIdB64: Data(repeating: 1, count: 16).base64EncodedString(),
                          wrappedContentKeyB64: Data(repeating: 2, count: 48).base64EncodedString())]
            // sigB64 intentionally omitted — defaults to nil, exactly the
            // shape a not-yet-updated (legacy) sender produces today.
        )
        XCTAssertNil(envelope.sigB64)

        let payload = try envelope.toWirePayload()
        guard let raw = Data(base64Encoded: payload),
              let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            XCTFail("payload did not decode as base64 JSON")
            return
        }
        XCTAssertNil(json["sg"], "an unsigned envelope must not emit an 'sg' key on the wire")

        let reparsed = try XCTUnwrap(FileAttachmentAnnounceWireEnvelope.parse(wirePayloadB64: payload))
        XCTAssertNil(reparsed.sigB64, "a legacy/unsigned envelope must parse back with sigB64 == nil, never fail to parse")
    }

    func test_presentSignature_roundTripsThroughWire() throws {
        let sigBytes = Data(repeating: 0xAB, count: 64)
        let envelope = FileAttachmentAnnounceWireEnvelope(
            fileId: UUID().uuidString, senderId: UUID().uuidString,
            senderEphPubB64: Data(repeating: 7, count: 32).base64EncodedString(),
            tusFileId: "tus-1", totalChunks: 1, chunkSize: 65536, totalSizeBytes: 10,
            mime: "application/octet-stream", filename: "f.bin",
            wraps: [.init(deviceIdB64: Data(repeating: 1, count: 16).base64EncodedString(),
                          wrappedContentKeyB64: Data(repeating: 2, count: 48).base64EncodedString())],
            sigB64: sigBytes.base64EncodedString()
        )
        let payload = try envelope.toWirePayload()
        let reparsed = try XCTUnwrap(FileAttachmentAnnounceWireEnvelope.parse(wirePayloadB64: payload))
        XCTAssertEqual(reparsed.sigB64, sigBytes.base64EncodedString())
    }

    // MARK: - 4. transport_sender_id mismatch rejected

    func test_transportSenderIdMismatch_rejected() throws {
        let f = try makeFixture()
        // Sign for the honest transport sender (== senderUuid, the real
        // send-time value).
        let signedCanon = try XCTUnwrap(canon(f))
        let sig = try FileAttachmentAnnounceSig.sign(canon: signedCanon, signingPrivateKeyRaw: f.signerSeed)
        XCTAssertTrue(
            FileAttachmentAnnounceSig.verify(canon: signedCanon, signature: sig, signerIdentityKey: f.signerPub)
        )

        // A malicious/compromised server relabels which WS opaque_message
        // frame this envelope rides on. The receiver rebuilds the canon
        // under the FRAME's server-stamped sender (never the envelope's own
        // claimed field) — this is exactly the residual gap the fix design
        // closes: a signature that only bound the claimed sender_uuid would
        // still verify here, since that field is untouched.
        let forgedTransportSenderId = fixedBytes(16, seed: 0xEE)
        let attackerCanon = try XCTUnwrap(canon(f, transportSenderId: forgedTransportSenderId))
        XCTAssertNotEqual(attackerCanon, signedCanon, "sanity: the two canons must actually differ")
        XCTAssertFalse(
            FileAttachmentAnnounceSig.verify(canon: attackerCanon, signature: sig, signerIdentityKey: f.signerPub),
            "a genuine signature must not verify once transport_sender_id is substituted"
        )
    }

    // MARK: - Canon shape sanity

    func test_canon_rejectsWrongLengthIdentifiers() throws {
        let f = try makeFixture()
        XCTAssertNil(FileAttachmentAnnounceSig.canon(
            fileId: Data(repeating: 0, count: 15), // wrong length (must be 16)
            senderUuid: f.senderUuid, recipientUuid: f.recipientUuid,
            senderEphemeralPub: f.senderEphemeralPub, wraps: f.wraps, tusFileId: f.tusFileId,
            totalChunks: f.totalChunks, totalSizeBytes: f.totalSizeBytes,
            transportSenderId: f.transportSenderId
        ), "canon must fail closed (nil) on a malformed identifier rather than encode garbage")
    }

    func test_canon_deterministicForSameInput() throws {
        let f = try makeFixture()
        let c1 = canon(f)
        let c2 = canon(f)
        XCTAssertNotNil(c1)
        XCTAssertEqual(c1, c2, "canon construction must be a pure function of its inputs")
    }

    // MARK: - ATT-1-followup: wrapped_content_key is a FIXED 48B field, no LP

    /// Regression guard for the ATT-1-followup fix: `wrapped_content_key` used
    /// to be `LP`-prefixed (`u16_BE(len) || bytes`) here — the one-of-three
    /// platform divergence found by direct cross-platform comparison (Android
    /// and Desktop never length-prefixed this field: its length is already
    /// fully determined by the AEAD wrap construction). A canon built from a
    /// 48-byte wrap must NOT contain a `0x00 0x30` (u16be 48) length-prefix
    /// pair immediately before the wrap bytes — asserting the field's byte
    /// offset directly pins the fixed-width, no-prefix shape so this can
    /// never silently regress back to LP.
    func test_canon_wrappedContentKeyIsFixed48BytesNoLengthPrefix() throws {
        let f = try makeFixture()
        let c = try XCTUnwrap(canon(f))

        // Fixed prefix up to and including n_wraps(1B): domain(26) +
        // version(1) + fileId(16) + senderUuid(16) + recipientUuid(16) +
        // senderEphemeralPub(32) + n_wraps(1) = 108.
        let domainLen = 26 // "qaudion-fa-announce-sig-v1".utf8.count
        let prefixLen = domainLen + 1 + 16 + 16 + 16 + 32 + 1
        XCTAssertEqual(c.count, prefixLen + 16 + 48 + 2 + f.tusFileId.utf8.count + 4 + 8 + 16,
                        "canon length must match the fixed-width (no wrap-key length-prefix) layout exactly")

        // Immediately after n_wraps || device_id(16B), the NEXT 48 bytes must
        // be the raw wrapped_content_key itself — NOT a 2-byte length prefix
        // (which would make the field start with 0x00 0x30 for a 48-byte key).
        let wrapKeyStart = prefixLen + 16
        let wrapKeyBytes = c.subdata(in: wrapKeyStart..<(wrapKeyStart + 48))
        XCTAssertEqual(wrapKeyBytes, f.wraps[0].wrappedContentKey,
                        "wrapped_content_key must appear as a raw fixed 48B field, byte-identical to the input, with no length prefix")
        XCTAssertFalse(wrapKeyBytes.starts(with: [0x00, 0x30]),
                        "a leading u16be(48) length prefix must not be present ahead of the wrap key bytes")
    }

    /// Android/Desktop both throw/return-nil on a wrong-length wrap rather
    /// than silently truncating or padding — this platform must fail closed
    /// (`canon` -> `nil`) the same way.
    func test_canon_rejectsWrongLengthWrappedContentKey() throws {
        let f = try makeFixture()
        let badWraps = [
            FileAttachmentAnnounceSig.DeviceWrap(
                deviceId: f.wraps[0].deviceId,
                wrappedContentKey: Data(repeating: 0x09, count: 47)) // 47, not 48
        ]
        XCTAssertNil(FileAttachmentAnnounceSig.canon(
            fileId: f.fileId, senderUuid: f.senderUuid, recipientUuid: f.recipientUuid,
            senderEphemeralPub: f.senderEphemeralPub, wraps: badWraps, tusFileId: f.tusFileId,
            totalChunks: f.totalChunks, totalSizeBytes: f.totalSizeBytes,
            transportSenderId: f.transportSenderId
        ), "canon must fail closed (nil) on a wrapped_content_key that is not exactly 48 bytes, never truncate/pad")
    }
}
