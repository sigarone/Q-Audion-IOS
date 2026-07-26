import XCTest
import CryptoKit
@testable import QAudionEngine

/// C-3 — a persisted SAS verification must not outlive the identity it verified.
final class SasBindingTests: XCTestCase {

    private let keyA = Data(repeating: 0xA1, count: 32)
    private let keyB = Data(repeating: 0xB2, count: 32)

    func testRoundTrip() {
        let b = SasBinding(sasFingerprint: "aabb", identityTag: "ccdd")
        XCTAssertEqual("aabb:ccdd", b.encoded)
        XCTAssertEqual(b, SasBinding.decode(b.encoded))
    }

    /// THE case. A record written against one identity key must stop applying the
    /// moment the pinned key is a different one — which is what a server-driven
    /// rotation looks like from the client's side.
    func testARotatedIdentityInvalidatesTheVerification() {
        let b = SasBinding(sasFingerprint: "f00d",
                           identityTag: SasBinding.identityTag(forPinnedKey: keyA))
        XCTAssertTrue(b.appliesTo(currentIdentityTag: SasBinding.identityTag(forPinnedKey: keyA)))
        XCTAssertFalse(b.appliesTo(currentIdentityTag: SasBinding.identityTag(forPinnedKey: keyB)),
                       "a rotated identity key must not inherit the old confirmation")
    }

    /// A record from before the binding existed is reported ABSENT, not valid.
    /// Accepting it would leave the vulnerability in place for exactly the accounts
    /// that have been verified the longest.
    func testAnUnboundLegacyRecordIsTreatedAsAbsent() {
        XCTAssertNil(SasBinding.decode("deadbeefdeadbeefdeadbeefdeadbeef"))
        XCTAssertNil(SasBinding.decode(""))
        XCTAssertNil(SasBinding.decode(":onlytag"))
        XCTAssertNil(SasBinding.decode("onlysas:"))
    }

    func testTheFullInCallCheckRequiresBothHalves() {
        let tag = SasBinding.identityTag(forPinnedKey: keyA)
        let b = SasBinding(sasFingerprint: "1234", identityTag: tag)
        XCTAssertTrue(b.matches(sasFingerprint: "1234", identityTag: tag))
        XCTAssertFalse(b.matches(sasFingerprint: "9999", identityTag: tag),
                       "different SAS words on this call")
        XCTAssertFalse(b.matches(sasFingerprint: "1234",
                                 identityTag: SasBinding.identityTag(forPinnedKey: keyB)),
                       "same SAS words, different identity — the C-3 shape")
    }

    func testTheIdentityTagIsTheTruncatedSha256OfThePin() {
        let expected = SHA256.hash(data: keyA).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(expected, SasBinding.identityTag(forPinnedKey: keyA))
        XCTAssertEqual(32, SasBinding.identityTag(forPinnedKey: keyA).count)
    }

    /// A separator inside the second half must not turn one field into three.
    /// `maxSplits: 1` is what prevents it; this pins the choice, not its output.
    func testOnlyTheFirstSeparatorSplits() {
        let b = SasBinding.decode("aa:bb:cc")
        XCTAssertEqual("aa", b?.sasFingerprint)
        XCTAssertEqual("bb:cc", b?.identityTag)
    }
}
