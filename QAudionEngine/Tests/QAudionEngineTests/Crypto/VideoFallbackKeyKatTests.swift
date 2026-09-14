import XCTest
@testable import QAudionEngine

/// MEDIA-8 (2026-09-02 protocol audit, backlog item 5B) — the video
/// fallback key used when the peer did NOT negotiate `vkey-v1`
/// (`QAudionCallIntegration.deriveVideoFallbackKey`), replacing the old
/// behaviour of handing the raw audio session key straight to the video
/// FrameCryptor. UNCONDITIONAL — no kill switch, no negotiation (see the
/// function's own doc) — so unlike the other MEDIA-*/MSG-4 test files in
/// this backlog there is no "default off" property to pin here.
///
/// `test_pinnedVector*` lock the exact byte output for two fixed inputs via
/// vectors independently computed offline against the documented formula
/// (`HKDF-SHA256(IKM=sessionKey, salt=∅, info="q-audion-video-fallback-v1",
/// L=32)`) using .NET's `HMACSHA256` (RFC 5869 HKDF, hand-rolled
/// Extract/Expand) — NOT this build's own CryptoKit output, so it is an
/// independent check on the formula, not a tautology against the same code
/// path. That harness was itself validated by first reproducing this
/// repo's existing, already-shipped `PhoneVideoKeyKatTests` vector
/// byte-for-byte before computing these new ones.
final class VideoFallbackKeyKatTests: XCTestCase {

    /// sessionKey = 0x11 repeated 32 times.
    func test_pinnedVectorRepeatingByte() {
        let sessionKey = Data(repeating: 0x11, count: 32)
        let derived = QAudionCallIntegration.deriveVideoFallbackKey(sessionKey: sessionKey)
        XCTAssertEqual(
            derived.hexEncodedString(),
            "135918235df558b685cb9c5ad0eb2ee9e33de5709c6d2a7816de97667e2dff36",
            "deriveVideoFallbackKey drift from its own documented formula "
            + "HKDF-SHA256(IKM=sessionKey, salt=∅, info=\"q-audion-video-fallback-v1\", L=32)"
        )
    }

    /// sessionKey = bytes 0x00..0x1f (same shape PhoneVideoKeyKatTests uses
    /// for its own sessionKey vector, deliberately — makes the two files
    /// easy to cross-reference).
    func test_pinnedVectorSequentialBytes() {
        let sessionKey = Data((0x00...0x1f).map { UInt8($0) })
        let derived = QAudionCallIntegration.deriveVideoFallbackKey(sessionKey: sessionKey)
        XCTAssertEqual(
            derived.hexEncodedString(),
            "4b2b7c35170eccd3889dd5347be8c3334a2eaa624f56de9338c34d8e8b88468a",
            "deriveVideoFallbackKey drift from its own documented formula "
            + "HKDF-SHA256(IKM=sessionKey, salt=∅, info=\"q-audion-video-fallback-v1\", L=32)"
        )
    }

    func test_outputIs32Bytes() {
        let key = QAudionCallIntegration.deriveVideoFallbackKey(sessionKey: Data(repeating: 0x01, count: 32))
        XCTAssertEqual(key.count, 32)
    }

    func test_deterministic() {
        let sessionKey = Data(repeating: 0x02, count: 32)
        let a = QAudionCallIntegration.deriveVideoFallbackKey(sessionKey: sessionKey)
        let b = QAudionCallIntegration.deriveVideoFallbackKey(sessionKey: sessionKey)
        XCTAssertEqual(a, b)
    }

    /// MEDIA-8's whole point: the fallback key must NOT equal the raw
    /// session key it was fed — sharing that raw value with the audio
    /// cryptor verbatim (today's pre-fix behaviour) is exactly what this
    /// fix removes.
    func test_derivedKeyDiffersFromRawSessionKey() {
        let sessionKey = Data(repeating: 0x03, count: 32)
        let key = QAudionCallIntegration.deriveVideoFallbackKey(sessionKey: sessionKey)
        XCTAssertNotEqual(key, sessionKey)
    }

    /// Domain separation from the vkey-v1 K_video derivation this same
    /// class already ships, for the SAME session key and default
    /// (no-PSK/no-tags) inputs — the fallback path must be its own HKDF
    /// domain, not an accidental alias of `deriveVideoKey`.
    func test_derivedKeyDiffersFromVkeyV1Domain() {
        let sessionKey = Data(repeating: 0x04, count: 32)
        let fallback = QAudionCallIntegration.deriveVideoFallbackKey(sessionKey: sessionKey)
        let vkeyV1 = QAudionCallIntegration.deriveVideoKey(sessionKey: sessionKey, agreedTags: [], psk: nil)
        XCTAssertNotEqual(fallback, vkeyV1)
    }
}

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
