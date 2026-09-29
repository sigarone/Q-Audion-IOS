import XCTest
@testable import QAudionApp
import QAudionEngine

/// ADVERSARIAL REVIEW (2026-09-29, follow-up to I8 in
/// `fix(group-call): stop group video publish from failing on every quality
/// tier`) — coverage for `LogRedactor.redactStructured`'s letters-only
/// "code identifier" carve-out (`codeIdentifierRegex` /
/// `isLikelyCodeIdentifier` / `stashCodeIdentifiers`, `LogRedactor.swift`).
///
/// CONFIRMED DEFECT this file pins the fix for: stashing an
/// identifier-shaped candidate BEFORE the JWT/secret-keyword/blob/residual
/// scrubs run (so it survives them) is safe ONLY when the candidate is a
/// genuine standalone prose token. `codeIdentifierRegex` is anchored on
/// `\b`, and `\b` fires at `+`/`/`/`=`/`-` (none of the four are `\w`) even
/// though those are exactly the separator characters INSIDE a
/// base64/base64url/hex-with-hyphen run — so a candidate glued to one of
/// them with no real prose boundary is a fragment of a longer secret, not
/// an identifier. Stashing it splits what would have been one contiguous
/// >=20/24-char secret run into shorter pieces that individually fall
/// under `blobWithHyphen`'s 24-char / `residualRegex`'s 20-char floor —
/// restoring the "identifier" in the clear at the end AND leaving its
/// neighbouring fragments unredacted too. Reproduced by hand against the
/// pre-fix code (`git show <pre-adjacency-guard commit>` -- see this
/// file's own PR): `"relay candidate blob
/// 7f3ac9012+XyzAbcDef+91beffcafe0123456789abcdef=="` round-tripped to
/// `"***REDACTED***"` before the I8 change existed at all, to
/// `"relay candidate blob 7f3ac9012+XyzAbcDef***REDACTED***"` with I8's
/// carve-out and no adjacency guard, and is pinned back to full redaction
/// here by `blobAdjacentChars`.
///
/// Same gap `DisplayNameTests.swift`/`GroupCreationMetadataTests.swift`
/// already document: no Xcode/Swift toolchain is available in this session
/// (Windows, no macOS/Xcode) to compile or run this file, and
/// `QAudionAppTests` is not wired into `QAudionApp/project.yml` yet.
/// Written against that gap rather than left unwritten — UNVERIFIED BY
/// COMPILATION, reviewed carefully by hand against `LogRedactor.swift`'s
/// actual implementation (and cross-checked with an equivalent Python port
/// of the same regex/plausibility/stash logic run against Python 3.11)
/// instead.
final class LogRedactorCodeIdentifierTests: XCTestCase {

    // MARK: - The two identifiers the I8 fix names explicitly must still survive

    func test_namedClassIdentifier_survivesInProse() {
        let line = "log line mentions BCryptoGroupCallManager during setup"
        XCTAssertTrue(LogRedactor.redactStructured(line).contains("BCryptoGroupCallManager"))
    }

    func test_namedFunctionIdentifier_survivesInProse() {
        let line = "[GroupCallController] setVideoEnabled(true) failed inside performAcceptIncomingGroupCall"
        XCTAssertTrue(LogRedactor.redactStructured(line).contains("performAcceptIncomingGroupCall"))
    }

    // MARK: - Regression: identifier-shaped fragment glued to a blob
    // separator must NOT survive, and must not fragment the secret around it

    func test_camelCaseFragment_dashDelimitedInsideSecret_isFullyRedacted() {
        // "XyzAbcDef" alone matches the identifier shape and passes the
        // per-word plausibility check, but it is glued to '-' on both
        // sides -- a substring of one continuous secret-charset run, not a
        // standalone word.
        let line = "sig=ab12-XyzAbcDef-99fe0123456789abcdef0123456789"
        let out = LogRedactor.redactStructured(line)
        XCTAssertFalse(out.contains("XyzAbcDef"), "identifier-shaped middle fragment leaked: \(out)")
        XCTAssertFalse(out.contains("ab12"), "prefix fragment orphaned below the length floor: \(out)")
        XCTAssertFalse(out.contains("99fe"), "suffix fragment orphaned below the length floor: \(out)")
    }

    func test_camelCaseFragment_plusDelimitedInsideSecret_isFullyRedacted() {
        let line = "relay candidate blob 7f3ac9012+XyzAbcDef+91beffcafe0123456789abcdef=="
        let out = LogRedactor.redactStructured(line)
        XCTAssertFalse(out.contains("XyzAbcDef"), "identifier-shaped middle fragment leaked: \(out)")
        XCTAssertFalse(out.contains("7f3ac9012"), "prefix fragment orphaned below the length floor: \(out)")
    }

    func test_camelCaseFragment_slashDelimitedInsideSecret_isFullyRedacted() {
        let line = "auth=Zm9v/XyzAbcDef/YmFyYmF6cXV1eA=="
        let out = LogRedactor.redactStructured(line)
        XCTAssertFalse(out.contains("XyzAbcDef"), "identifier-shaped middle fragment leaked: \(out)")
    }

    func test_camelCaseFragment_equalsDelimited_isFullyRedacted() {
        // '=' is base64 padding, not a keyword-value introducer here (no
        // recognised secret keyword precedes it), so this exercises the
        // blob/residual path specifically, not `secretPrefixedEgress`.
        let line = "blob AbcDefGhi=91beffcafe0123456789abcdef0123456789"
        let out = LogRedactor.redactStructured(line)
        XCTAssertFalse(out.contains("AbcDefGhi"), "identifier-shaped fragment before '=' leaked: \(out)")
    }

    // MARK: - Sanity: ordinary secrets are still fully redacted (unaffected
    // by the code-identifier carve-out when no identifier-shaped substring
    // is present at all)

    func test_plainHexBlob_stillFullyRedacted() {
        let out = LogRedactor.redactStructured("session=0123456789abcdef0123456789abcdef")
        XCTAssertFalse(out.contains("0123456789abcdef"))
    }

    func test_plainBase64Blob_stillFullyRedacted() {
        let out = LogRedactor.redactStructured("key=dGhpc2lzYXNlY3JldGtleTEyMzQ1Njc4OTA=")
        XCTAssertFalse(out.contains("dGhpc2lzYXNlY3JldGtleTEyMzQ1Njc4OTA"))
    }

    // MARK: - CamelCase with embedded digits never matches the identifier
    // shape at all (a digit-letter transition is not a `\b`), so it is
    // untouched by this carve-out either way -- unrelated to the fix above,
    // pinned here so a future change to `codeIdentifierRegex` cannot
    // silently start treating it as a protected identifier.

    func test_camelCaseWithEmbeddedDigits_isNotTreatedAsProtectedIdentifier() {
        let line = "handler Abc123DefGhi456Jkl failed"
        // Not long enough to hit the 20-char residual floor either -- this
        // assertion is about the identifier carve-out only, not redaction
        // completeness for short mixed alnum runs (a separate, pre-existing
        // policy this fix does not change).
        XCTAssertEqual(LogRedactor.redactStructured(line), line)
    }
}
