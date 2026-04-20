import XCTest
@testable import QAudionEngine

/// Parity tests for `PhoneHash`. The canonical vectors must agree with
/// `QAudionEngine/Tests/Resources/cross_platform_vectors.json` and the
/// Android `PhoneHashHelper` implementation.
final class PhoneHashTests: XCTestCase {

    // MARK: - Known cross-platform vectors

    func test_vector_us_canonical() throws {
        let hash = try PhoneHash.hash("+14155552671")
        XCTAssertEqual(
            hash,
            "cb6880e416769253645cb9c6b8989154bf66a56a77fc14c81fb1019663cbb928",
            "Must match Android PhoneHashHelper.hashPhone('+14155552671')"
        )
    }

    func test_vector_us_formatted_matches_canonical() throws {
        XCTAssertEqual(
            try PhoneHash.hash("+1 (415) 555-2671"),
            try PhoneHash.hash("+14155552671")
        )
    }

    func test_vector_italian_leading_double_zero() throws {
        let hash = try PhoneHash.hash("003902 1234-5678")
        XCTAssertEqual(
            hash,
            "cd53ded8dc564b9d1743105e4533289635fe59304336f1ed1aaf04b484ab1a18"
        )
    }

    func test_vector_italian_default_country_fallback() throws {
        let hash = try PhoneHash.hash("0212345678", defaultCountry: "+39")
        XCTAssertEqual(
            hash,
            "3527fda1981c83fc2506ff39f2b4efe1318c6181945300a030c16cd0f7fa6ec1"
        )
    }

    // MARK: - Normalization edge cases (Android parity)

    func test_nonBreakingSpace_stripped() throws {
        // U+00A0 inside the number must be stripped (clipboard paste case).
        XCTAssertEqual(
            try PhoneHash.normalizeE164("+1\u{00A0}415\u{00A0}555\u{00A0}2671"),
            "+14155552671"
        )
    }

    func test_slash_and_dot_stripped() throws {
        XCTAssertEqual(
            try PhoneHash.normalizeE164("+39.02/1234.5678"),
            "+390212345678"
        )
    }

    // MARK: - Invalid inputs must throw

    func test_empty_throws() {
        XCTAssertThrowsError(try PhoneHash.hash("")) { error in
            XCTAssertEqual(error as? PhoneHash.Error, .empty)
        }
    }

    func test_tooShort_throws() {
        // "+12" → only 2 digits after +, regex requires 8..15
        XCTAssertThrowsError(try PhoneHash.hash("+12")) { error in
            if case PhoneHash.Error.invalidE164 = error { return }
            XCTFail("expected .invalidE164, got \(error)")
        }
    }

    func test_leadingZeroCountry_throws() {
        // +0... is rejected: country digit must be 1-9
        XCTAssertThrowsError(try PhoneHash.hash("+0123456789"))
    }

    func test_letters_throws() {
        // Letters aren't stripped → regex match fails
        XCTAssertThrowsError(try PhoneHash.hash("abc"))
    }

    // MARK: - Non-throwing helpers

    func test_isValid_positive() {
        XCTAssertTrue(PhoneHash.isValid("+14155552671"))
        XCTAssertTrue(PhoneHash.isValid("+39 02 1234 5678"))
    }

    func test_isValid_negative() {
        XCTAssertFalse(PhoneHash.isValid(""))
        XCTAssertFalse(PhoneHash.isValid("+12"))
        XCTAssertFalse(PhoneHash.isValid("xyz"))
    }

    func test_hashOrNil_returnsNilOnInvalid() {
        XCTAssertNil(PhoneHash.hashOrNil(""))
        XCTAssertNil(PhoneHash.hashOrNil("+12"))
    }

    func test_hashOrNil_equalsThrowingHashOnValid() throws {
        XCTAssertEqual(
            PhoneHash.hashOrNil("+14155552671"),
            try PhoneHash.hash("+14155552671")
        )
    }
}

extension PhoneHash.Error: Equatable {
    public static func == (lhs: PhoneHash.Error, rhs: PhoneHash.Error) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty): return true
        case (.invalidE164(let a), .invalidE164(let b)): return a == b
        default: return false
        }
    }
}
