import XCTest
import CryptoKit
@testable import QAudionEngine

/// Cross-platform `vkey-v1` K_video KAT verifier (iOS).
///
/// Asserts that the iOS PRODUCTION path
/// `QAudionCallIntegration.deriveVideoKey(sessionKey:agreedTags:psk:)`
/// reproduces the frozen, android-crypto + gemini-verified KAT vectors
/// byte-for-byte. K_video is the dedicated phone-level earbud-video key
/// fed to `LiveKitVideoFrameCryptor` when both peers advertise `vkey-v1`.
///
/// FROZEN SPEC (must match Android `deriveVideoKey` + Desktop port):
///   transcriptHash = SHA-256( agreedTags.distinct().sorted()
///                              .joined(",") as UTF-8 )                [32B]
///   IKM            = sessionKey (32-byte post-PSK-mix session key)
///   salt           = psk(32)        if (psk != nil && !psk.isEmpty)
///                    else UTF8("Q-AUDION-PHONE-VIDEO-SALT-V1")        [28B]
///   info           = UTF8("Q-AUDION-PHONE-VIDEO-V1")(23)
///                    || transcriptHash(32)                           [55B]
///   K_video        = HKDF-SHA256(IKM, salt, info, L=32)
///
/// FROZEN VECTORS: sessionKey = 0x00..0x1f,
/// agreedTags = [sframe-v1, ratchet-v3, vkey-v1] →
/// transcript string "ratchet-v3,sframe-v1,vkey-v1".
///   no PSK            → 66befe3fddb46f3a21dc9d7e105947b70dff9520783b81da6902ae04cee71f30
///   PSK = 0x80..0x9f  → 00c902209e7e8ba9d0dcabee58f15a4b7b4b296b634f2f21ccd45408654f04f2
///
/// Sister tests (byte-equal):
///   apps/qaudion-android-new/.../PhoneVideoKeyKatTest.kt
///   apps/qaudion-desktop/test/PhoneVideoKey.kat.spec.ts
final class PhoneVideoKeyKatTests: XCTestCase {

    /// sessionKey = bytes 0x00..0x1f.
    private let sessionKey = Data((0x00...0x1f).map { UInt8($0) })
    /// PSK = bytes 0x80..0x9f.
    private let psk = Data((0x80...0x9f).map { UInt8($0) })
    private let agreedTags = ["sframe-v1", "ratchet-v3", "vkey-v1"]

    func testNoPskVectorMatches() {
        let derived = QAudionCallIntegration.deriveVideoKey(
            sessionKey: sessionKey,
            agreedTags: agreedTags,
            psk: nil
        )
        XCTAssertEqual(
            derived.hexEncodedString(),
            "66befe3fddb46f3a21dc9d7e105947b70dff9520783b81da6902ae04cee71f30",
            "iOS deriveVideoKey (no PSK) drift — salt=Q-AUDION-PHONE-VIDEO-SALT-V1, "
            + "info='Q-AUDION-PHONE-VIDEO-V1'||SHA256('ratchet-v3,sframe-v1,vkey-v1')"
        )
    }

    func testPskVectorMatches() {
        let derived = QAudionCallIntegration.deriveVideoKey(
            sessionKey: sessionKey,
            agreedTags: agreedTags,
            psk: psk
        )
        XCTAssertEqual(
            derived.hexEncodedString(),
            "00c902209e7e8ba9d0dcabee58f15a4b7b4b296b634f2f21ccd45408654f04f2",
            "iOS deriveVideoKey (PSK present) drift — salt=psk(32), "
            + "info='Q-AUDION-PHONE-VIDEO-V1'||SHA256('ratchet-v3,sframe-v1,vkey-v1')"
        )
    }

    /// Empty PSK must behave identically to nil PSK (fixed-salt fallback).
    func testEmptyPskFallsBackToFixedSalt() {
        let withNil = QAudionCallIntegration.deriveVideoKey(
            sessionKey: sessionKey, agreedTags: agreedTags, psk: nil)
        let withEmpty = QAudionCallIntegration.deriveVideoKey(
            sessionKey: sessionKey, agreedTags: agreedTags, psk: Data())
        XCTAssertEqual(withNil, withEmpty,
            "empty PSK must fall back to the fixed Q-AUDION-PHONE-VIDEO-SALT-V1 salt")
    }

    /// Tag ordering / duplicates must not change the transcript hash:
    /// the derivation normalises via Set → sorted before hashing.
    func testTagOrderingAndDuplicatesAreNormalised() {
        let canonical = QAudionCallIntegration.deriveVideoKey(
            sessionKey: sessionKey, agreedTags: agreedTags, psk: nil)
        // Reversed + duplicated input must produce the same key.
        let scrambled = QAudionCallIntegration.deriveVideoKey(
            sessionKey: sessionKey,
            agreedTags: ["vkey-v1", "sframe-v1", "vkey-v1", "ratchet-v3"],
            psk: nil)
        XCTAssertEqual(canonical, scrambled,
            "deriveVideoKey must sort+dedupe agreedTags before hashing")
    }

    /// The HKDF labels must be exactly the frozen byte strings.
    func testHkdfLabelBytesAreFrozen() {
        XCTAssertEqual(
            String(decoding: HkdfLabels.phoneVideoV1, as: UTF8.self),
            "Q-AUDION-PHONE-VIDEO-V1")
        XCTAssertEqual(HkdfLabels.phoneVideoV1.count, 23)
        XCTAssertEqual(
            String(decoding: HkdfLabels.phoneVideoSaltV1, as: UTF8.self),
            "Q-AUDION-PHONE-VIDEO-SALT-V1")
        XCTAssertEqual(HkdfLabels.phoneVideoSaltV1.count, 28)
        XCTAssertTrue(HkdfLabels.verifyAllUtf8RoundTrip())
    }

    /// Capability negotiation must expose `useVideoKey` only when BOTH
    /// sides advertise `vkey-v1`.
    func testUseVideoKeyNegotiation() {
        let both = CallCapabilities.negotiate(
            local: CallCapabilities.local,
            peer: ["sframe-v1", "ratchet-v3", "vkey-v1"])
        XCTAssertTrue(both.useVideoKey)

        let peerWithout = CallCapabilities.negotiate(
            local: CallCapabilities.local,
            peer: ["sframe-v1", "ratchet-v3"])
        XCTAssertFalse(peerWithout.useVideoKey)

        let legacyNil = CallCapabilities.negotiate(
            local: CallCapabilities.local, peer: nil)
        XCTAssertFalse(legacyNil.useVideoKey)
    }
}

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
