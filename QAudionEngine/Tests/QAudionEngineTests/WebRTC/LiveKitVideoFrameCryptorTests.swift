import XCTest
import CryptoKit
@testable import QAudionEngine

/// WS-7 — AES-256 wire-format interop for the LIVE 1:1 video FrameCryptor
/// path (`LiveKitVideoFrameCryptor`, installed by
/// `QAudionWebRtcCallController.ensureVideoSealer` as `.livekit(...)`).
///
/// Android's now-shipping native FrameCryptor is built from
/// `webrtc-aes256-build/aes256-framecryptor.patch`, which makes
/// `ParticipantKeyHandler::SetKeyFromMaterial` call
/// `DeriveKeys(password, ratchet_salt, password.size() == 32 ? 256 : 128)`.
/// With Q-Audion's 32-byte shared key the native side derives 32 bytes and
/// BoringSSL `GetAesGcmAlgorithmFromKeySize` selects `EVP_aead_aes_256_gcm`.
/// iOS must derive the byte-identical 32-byte key and run AES-256-GCM so the
/// two interop.
final class LiveKitVideoFrameCryptorTests: XCTestCase {

    /// Frozen cross-platform KAT for the derived FrameCryptor key.
    ///
    /// HKDF-SHA256(
    ///   ikm  = 32 × 0x42,
    ///   salt = empty (ratchet_salt; Q-Audion passes 0-length on every platform),
    ///   info = 128 × 0x00,
    ///   L    = 32) → AES-256-GCM key
    ///
    /// Computed independently (RFC-5869 reference impl); MUST match
    /// byte-for-byte the value the patched native webrtc-sdk derives for the
    /// same shared key, and the Desktop `deriveFrameCryptorKey` (@noble/hashes
    /// HKDF, DERIVED_KEY_BYTES = 32). Do NOT edit without re-deriving all
    /// three platforms.
    func testDerivedKeyKAT_AES256() {
        let pqc = Data(repeating: 0x42, count: 32)
        let key = LiveKitVideoFrameCryptor.deriveFrameCryptorKey(pqcSessionKey: pqc)
        XCTAssertEqual(key.count, 32, "WS-7: FrameCryptor key must be 32 bytes (AES-256)")
        XCTAssertEqual(
            key.map { String(format: "%02x", $0) }.joined(),
            "8dcc8d7bb94a3109095ec07e103d566f9709c4c2e9326d93d0b7bc1e110aae93",
            "WS-7 KAT drift: derived AES-256 key no longer matches the "
            + "cross-platform anchor — iOS↔Android↔Desktop video would "
            + "fail to interop. Re-derive on all three platforms before changing."
        )
    }

    /// The first 16 bytes of the AES-256 key equal the old AES-128 key
    /// (HKDF expand is a prefix-stable stream) — documents WHY a peer that
    /// is still on AES-128 cannot decrypt AES-256 frames (different cipher /
    /// tag), even though the key prefix is shared.
    func testKey256PrefixMatchesLegacy128Prefix() {
        let pqc = Data(repeating: 0x42, count: 32)
        let key256 = LiveKitVideoFrameCryptor.deriveFrameCryptorKey(pqcSessionKey: pqc)
        let legacy128 = Data([
            0x8d, 0xcc, 0x8d, 0x7b, 0xb9, 0x4a, 0x31, 0x09,
            0x09, 0x5e, 0xc0, 0x7e, 0x10, 0x3d, 0x56, 0x6f,
        ])
        XCTAssertEqual(key256.prefix(16), legacy128)
    }

    /// Round-trip every codec family at AES-256: seal then open returns the
    /// plaintext. Exercises the clear-header / AAD / RBSP paths unchanged by
    /// the key-length bump.
    func testRoundTripAllCodecs_AES256() throws {
        let pqc = Data(repeating: 0x9a, count: 32)
        let cryptor = LiveKitVideoFrameCryptor(keyProvider: { pqc })

        // VP8 keyframe (10-byte clear header), VP9 (0), opus (1), and an
        // H264 Annex-B IDR (start-code + NALU type 5) to exercise RBSP.
        let vp8 = Data((0..<200).map { UInt8($0 & 0xff) })
        let vp9 = Data(repeating: 0x5c, count: 128)
        let opus = Data(repeating: 0x77, count: 64)
        let h264 = Data([0x00, 0x00, 0x00, 0x01, 0x65] + (0..<180).map { UInt8($0 & 0xff) })

        for (codec, data, kf) in [
            (LiveKitVideoFrameCryptor.FrameCodec.vp8, vp8, true),
            (.vp9, vp9, false),
            (.opus, opus, false),
            (.h264, h264, true),
        ] {
            let wire = try cryptor.seal(data: data, codec: codec, isKeyFrame: kf, ssrc: 7, rtpTimestamp: 12345)
            let opened = try cryptor.open(data: wire, codec: codec, isKeyFrame: kf)
            XCTAssertEqual(opened, data, "round-trip failed for \(codec.rawValue)")
            XCTAssertGreaterThan(wire.count, data.count, "wire must carry tag+iv+trailer")
        }
    }

    /// A 32-byte derived key makes CryptoKit run AES-256-GCM; a frame sealed
    /// at 256 must NOT open under a key derived at the legacy 128-bit length
    /// (different cipher) — proves the upgrade is a real wire change, so both
    /// peers must be on 256.
    func testAes256SealRejectsAes128Open() throws {
        let pqc = Data(repeating: 0x9a, count: 32)
        let cryptor = LiveKitVideoFrameCryptor(keyProvider: { pqc })
        let pt = Data(repeating: 0xab, count: 96)
        let wire = try cryptor.seal(data: pt, codec: .vp9, isKeyFrame: false)

        // Manually reproduce the legacy AES-128 open: derive a 16-byte key,
        // parse the wire trailer, and attempt AES-128-GCM open. It must fail.
        let legacy16 = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pqc),
            salt: Data(),
            info: Data(count: 128),
            outputByteCount: 16
        )
        // Wire (vp9, header=0): [ ct ‖ tag(16) ] iv(12) trailer(2)
        let trailerStart = wire.count - 2
        let ivStart = trailerStart - 12
        let iv = wire.subdata(in: ivStart..<trailerStart)
        let ctAndTag = wire.subdata(in: 0..<ivStart)
        let tagStart = ctAndTag.count - 16
        let ct = ctAndTag.subdata(in: 0..<tagStart)
        let tag = ctAndTag.subdata(in: tagStart..<ctAndTag.count)
        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        XCTAssertThrowsError(
            try AES.GCM.open(box, using: legacy16, authenticating: Data()),
            "AES-256 frame must not open under the legacy AES-128 key"
        )
    }
}
