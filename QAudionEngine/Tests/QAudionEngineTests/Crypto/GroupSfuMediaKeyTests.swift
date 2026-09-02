import XCTest
@testable import QAudionEngine

/// MEDIA-7 (2026-09-02 protocol audit, backlog item 5A) — domain-separated
/// SFU/LiveKit media key derivation (`GroupSenderKey.deriveSfuMediaKey`),
/// gated behind `GroupCallController.grpSfuMediaKeyV1Enabled` (default
/// false).
///
/// `test_pinnedVector` locks the exact byte output for a fixed input via a
/// vector independently computed offline against the documented formula
/// (`HKDF-SHA256(IKM=SK_0, salt=∅, info="grp-sfu-media-key-v1", L=32)`)
/// using .NET's `HMACSHA256` (RFC 5869 HKDF, hand-rolled Extract/Expand) —
/// NOT this build's own CryptoKit output, so it is an independent check on
/// the formula, not a tautology against the same code path. That harness
/// was itself validated by first reproducing this repo's existing, already-
/// shipped `PhoneVideoKeyKatTests` vector byte-for-byte before computing the
/// new ones — see this file's own history for the cross-check. This is NOT
/// a cross-platform (Android/Desktop) KAT — no coordinated reconciliation
/// pass has happened yet (see the kill switch's own doc) — it only proves
/// the iOS implementation matches ITS OWN documented formula exactly. The
/// other tests below pin the structural properties the fix must have
/// regardless: deterministic, 32 bytes, and — the actual point of MEDIA-7 —
/// distinct from both the raw SK_0 it derives from and the sibling
/// `deriveAudioSessionKey` domain.
final class GroupSfuMediaKeyTests: XCTestCase {

    private let sk0 = Data(repeating: 0x5C, count: 32)

    /// Independently-computed vector for `sk0 = 0x5C repeated 32 times`,
    /// `info = "grp-sfu-media-key-v1"`, `salt = ∅` — see this file's kdoc.
    func test_pinnedVector() {
        let key = GroupSenderKey.deriveSfuMediaKey(sk0: sk0)
        XCTAssertEqual(
            key.hexEncodedString(),
            "9e1ef4c97bae0c38a1438da9f58223d0f1a51f0bfaaa8a2a236c897bcf610a17",
            "GroupSenderKey.deriveSfuMediaKey drift from its own documented formula "
            + "HKDF-SHA256(IKM=SK_0, salt=∅, info=\"grp-sfu-media-key-v1\", L=32)"
        )
    }

    func test_outputIs32Bytes() {
        let key = GroupSenderKey.deriveSfuMediaKey(sk0: sk0)
        XCTAssertEqual(key.count, 32)
    }

    func test_deterministic() {
        let a = GroupSenderKey.deriveSfuMediaKey(sk0: sk0)
        let b = GroupSenderKey.deriveSfuMediaKey(sk0: sk0)
        XCTAssertEqual(a, b)
    }

    /// The whole point of MEDIA-7: the derived key must NOT equal the raw
    /// SK_0 it was fed — reusing SK_0 verbatim (today's pre-fix behaviour)
    /// is exactly what this fix removes.
    func test_derivedKeyDiffersFromRawSk0() {
        let key = GroupSenderKey.deriveSfuMediaKey(sk0: sk0)
        XCTAssertNotEqual(key, sk0)
    }

    /// Domain separation from the SIBLING derivation this same file already
    /// ships (the WS-relay fallback-audio key) — both take the same 32-byte
    /// IKM shape, so if the two derivations ever collapsed onto the same
    /// HKDF `info` label this would start failing.
    func test_derivedKeyDiffersFromAudioSessionKeyDomain() {
        let sfuKey = GroupSenderKey.deriveSfuMediaKey(sk0: sk0)
        let audioKey = GroupSenderKey.deriveAudioSessionKey(ck0: sk0)
        XCTAssertNotEqual(sfuKey, audioKey)
    }

    /// Different input, different output — sanity that this is a real KDF
    /// call, not an accidental passthrough/constant.
    func test_differentInputProducesDifferentKey() {
        let other = Data(repeating: 0x5D, count: 32)
        let a = GroupSenderKey.deriveSfuMediaKey(sk0: sk0)
        let b = GroupSenderKey.deriveSfuMediaKey(sk0: other)
        XCTAssertNotEqual(a, b)
    }

    /// RULE B regression guard: the go-live gate must default OFF. If this
    /// ever starts failing because someone flipped the constant, that flip
    /// must be a deliberate, reviewed, coordinated cross-platform decision —
    /// not a silent default change.
    func test_killSwitchDefaultsFalse() {
        XCTAssertFalse(GroupCallController.grpSfuMediaKeyV1Enabled)
    }
}
