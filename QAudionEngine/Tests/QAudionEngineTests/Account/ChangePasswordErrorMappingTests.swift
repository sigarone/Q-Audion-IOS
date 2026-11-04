import XCTest
@testable import QAudionEngine

/// Error mapping of `POST /api/v1/account/password` and the length rules of the new password.
final class ChangePasswordErrorMappingTests: XCTestCase {
    private func body(_ code: String) -> Data {
        Data("{\"error\":\"\(code)\"}".utf8)
    }

    func test_badRequestCodes() {
        let cases: [(String, ChangePasswordError)] = [
            ("password_too_short", .tooShort),
            ("password_too_long", .tooLong),
            ("password_common", .common),
            ("password_contains_identity", .containsIdentity),
            ("password_unchanged", .unchanged),
            ("invalid json", .invalidRequest),
            ("something_new", .invalidRequest),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(ChangePasswordError.map(status: 400, body: body(code), retryAfter: nil), expected, code)
        }
    }

    func test_unauthorizedSplitsWrongPasswordFromExpiredSession() {
        XCTAssertEqual(ChangePasswordError.map(status: 401, body: body("invalid credentials"), retryAfter: nil), .wrongCurrent)
        XCTAssertEqual(ChangePasswordError.map(status: 401, body: body("unauthorized"), retryAfter: nil), .sessionExpired)
        XCTAssertEqual(ChangePasswordError.map(status: 401, body: Data(), retryAfter: nil), .sessionExpired)
    }

    func test_forbiddenSplitsUnavailableFromLocked() {
        XCTAssertEqual(ChangePasswordError.map(status: 403, body: body("password_login_unavailable"), retryAfter: nil), .unavailable)
        XCTAssertEqual(ChangePasswordError.map(status: 403, body: body("account locked"), retryAfter: nil), .locked)
        XCTAssertEqual(ChangePasswordError.map(status: 403, body: Data("not json".utf8), retryAfter: nil), .locked)
    }

    func test_rateLimitAndUnavailableCarryRetryAfter() {
        XCTAssertEqual(ChangePasswordError.map(status: 429, body: Data(), retryAfter: "42"), .rateLimited(retryAfterSec: 42))
        XCTAssertEqual(ChangePasswordError.map(status: 429, body: Data(), retryAfter: nil), .rateLimited(retryAfterSec: nil))
        XCTAssertEqual(ChangePasswordError.map(status: 429, body: Data(), retryAfter: "garbage"), .rateLimited(retryAfterSec: nil))
        XCTAssertEqual(ChangePasswordError.map(status: 503, body: Data(), retryAfter: "7"), .serviceUnavailable(retryAfterSec: 7))
    }

    func test_otherStatusKeepsTheNumber() {
        XCTAssertEqual(ChangePasswordError.map(status: 500, body: Data(), retryAfter: nil), .server(500))
    }

    func test_lengthRules() {
        XCTAssertEqual(PasswordPolicy.lengthProblem("1234567"), .tooShort)
        XCTAssertNil(PasswordPolicy.lengthProblem("12345678"))
        XCTAssertNil(PasswordPolicy.lengthProblem(String(repeating: "a", count: 64)))
        XCTAssertEqual(PasswordPolicy.lengthProblem(String(repeating: "a", count: 65)), .tooLong)
        // 40 characters of 2 bytes each: under 64 characters, over 72 bytes.
        XCTAssertEqual(PasswordPolicy.lengthProblem(String(repeating: "\u{00E8}", count: 40)), .tooLong)
        // A decomposed accent counts as one character, like the server after NFC.
        XCTAssertNil(PasswordPolicy.lengthProblem(String(repeating: "e\u{0301}", count: 8)))
    }

    func test_resultDecodesAndNeverPrintsTokens() throws {
        let json = Data("""
        {"access_token":"AAA-secret","refresh_token":"RRR-secret","expires_in":900,"token_type":"Bearer","device_id":"dev-1"}
        """.utf8)
        let result = try JSONDecoder().decode(PasswordChangeResult.self, from: json)
        XCTAssertEqual(result.accessToken, "AAA-secret")
        XCTAssertEqual(result.refreshToken, "RRR-secret")
        XCTAssertEqual(result.deviceId, "dev-1")
        XCTAssertEqual(result.expiresIn, 900)
        XCTAssertFalse(String(describing: result).contains("secret"))
    }

    func test_profileReadsPasswordLogin() throws {
        let yes = try JSONDecoder().decode(UserProfile.self, from: Data("{\"user_id\":\"u\",\"password_login\":true}".utf8))
        XCTAssertEqual(yes.passwordLogin, true)
        let absent = try JSONDecoder().decode(UserProfile.self, from: Data("{\"user_id\":\"u\"}".utf8))
        XCTAssertNotEqual(absent.passwordLogin, true)
    }
}
