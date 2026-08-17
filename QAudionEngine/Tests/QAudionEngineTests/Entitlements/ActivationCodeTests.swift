import XCTest
@testable import QAudionEngine

/// Cross-platform parity test for `computeActivationCodeChecksum` /
/// `verifyActivationCodeChecksum` — design doc §13's "the same vectors
/// implemented in Go, Kotlin, Swift and TypeScript from one shared KAT
/// file".
///
/// The vectors below are ported VERBATIM from the Go reference
/// implementation's own test table, `TestChecksumVectors_KAT` in
/// `bcrypto-server/cmd/bcrypto-lite/entitlements_code_format_test.go`
/// (read directly from that file during this task's investigation,
/// 2026-08-17) — the SAME table Android's `ActivationCodeFormatTest.kt`
/// (its own Task 5) already committed. Do not hand-derive new expected
/// values here — if this ever needs to change, the Go table changes first
/// and this one is re-copied from it, otherwise this stops being a
/// genuine cross-platform check.
///
/// NOTE (not yet wired into a build target): same gap `EgtVerifierTests
/// .swift`/`CapabilityGateTests.swift` already document — no Xcode/Swift
/// toolchain available in this session (Windows, no macOS) to compile or
/// run this file. Written against that gap rather than left unwritten
/// (TDD discipline: written FIRST against the not-yet-existing
/// `ActivationCode.swift`, verified by reading it would fail to compile —
/// `computeActivationCodeChecksum`/`verifyActivationCodeChecksum`
/// undefined — then `ActivationCode.swift` was implemented, then verified
/// by reading the vectors below match the algorithm's real output by hand
/// — see the worked example in `testChecksumMatchesTheRealGoServerKATVectors`'s
/// own comment) — UNVERIFIED BY COMPILATION, matching Task 1/2/3's own
/// honesty standard.
final class ActivationCodeTests: XCTestCase {

    // MARK: - KAT vectors (real, from the Go server's own test table)

    func testChecksumMatchesTheRealGoServerKATVectors() {
        // Hand-verified worked example for the first vector, since this
        // suite cannot be compiled/run in this session: SHA-256("QA1" +
        // "0000000000000") begins with byte0=0x5f (0101_1111), byte1=0x03
        // (0000_0011) — independently recomputed via `python -c
        // "import hashlib; print(hashlib.sha256(b'QA10000000000000').hexdigest())"`
        // during this task's investigation, not eyeballed. first5 =
        // byte0>>3 = 0b01011 = 11 -> alphabet[11]='B'. second5 =
        // ((byte0&0x07)<<2)|(byte1>>6) = (0b111<<2)|0b00 = 0b11100 = 28 ->
        // alphabet[28]='W'. => "BW", matching the Go table. All four
        // vectors below were verified the same way (real SHA-256, not
        // hand-derived) before being pinned here.
        let vectors: [(prefix: String, payload: String, wantChecksum: String)] = [
            ("QA1", "0000000000000", "BW"),
            ("QA1", "7K3M9PXTVYR2HN5", "ZZ"),
            ("QA1", "ZZZZZZZZZZZZZZZ", "09"),
            ("QA2", "A1B2C3D4E5F6G7H", "F8"),
        ]
        for v in vectors {
            XCTAssertEqual(
                computeActivationCodeChecksum(v.prefix, v.payload), v.wantChecksum,
                "computeActivationCodeChecksum(\(v.prefix), \(v.payload))"
            )
        }
    }

    func testVerifyAcceptsARealKATDerivedFormattedCode() {
        // Same KAT vectors above, round-tripped through the full
        // QA1-XXXXX-XXXXX-XXXXX-CC formatted shape (design doc §5.1) —
        // the exact string a user would paste into UpgradeSheet's field.
        XCTAssertTrue(verifyActivationCodeChecksum("QA1-7K3M9-PXTVY-R2HN5-ZZ"))
        XCTAssertTrue(verifyActivationCodeChecksum("QA1-ZZZZZ-ZZZZZ-ZZZZZ-09"))
        XCTAssertTrue(verifyActivationCodeChecksum("QA2-A1B2C-3D4E5-F6G7H-F8"))
    }

    // MARK: - Tamper rejection

    func testVerifyRejectsATamperedPayloadCharacter() {
        // Flip the first payload char of the known-good "QA1-7K3M9-..." KAT
        // code from '7' to '8'.
        XCTAssertFalse(verifyActivationCodeChecksum("QA1-8K3M9-PXTVY-R2HN5-ZZ"))
    }

    func testVerifyRejectsATamperedChecksum() {
        XCTAssertFalse(verifyActivationCodeChecksum("QA1-7K3M9-PXTVY-R2HN5-00"))
    }

    // MARK: - Normalization (case / hyphens / whitespace)

    func testVerifyNormalizesCaseHyphensAndSurroundingWhitespace() {
        XCTAssertTrue(verifyActivationCodeChecksum(" qa1 7k3m9 pxtvy r2hn5 zz "))
        XCTAssertTrue(verifyActivationCodeChecksum("qa1-7k3m9-pxtvy-r2hn5-zz"))
    }

    // MARK: - Shape rejection

    func testVerifyRejectsTheWrongShape() {
        XCTAssertFalse(verifyActivationCodeChecksum("QA1-7K3M-PXTVY-R2HN5-ZZ")) // one payload char short
        XCTAssertFalse(verifyActivationCodeChecksum(""))
        XCTAssertFalse(verifyActivationCodeChecksum("not a code at all"))
    }

    func testVerifyRejectsAmbiguousCrockfordCharactersNotInTheAlphabet() {
        // The alphabet excludes I, L, O, U entirely (design doc §5.1) — a
        // code containing one of those is stripped down to the wrong
        // length by normalization and must fail, not silently substitute
        // a digit.
        XCTAssertFalse(verifyActivationCodeChecksum("QA1-7K3M9-PXTVY-R2HNI-ZZ"))
    }
}
