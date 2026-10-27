import XCTest
@testable import QAudionApp
import QAudionEngine

/// HTTP 403 on the registration calls means the server is not accepting registrations: both onboarding paths map it
/// to "onboarding.error.registration_unavailable", never to the generic server error.
final class RegistrationUnavailableMappingTests: XCTestCase {

    private let unavailable = String(localized: "onboarding.error.registration_unavailable", defaultValue: "Registrazione temporaneamente non disponibile, riprova più tardi.")
    private let forbidden = BCryptoError.httpError(403)

    func testOtpRegister403MapsToRegistrationUnavailable() {
        XCTAssertEqual(OtpVerificationScreen.userFacingMessage(for: forbidden, mode: .register), unavailable)
    }

    func testOtpLogin403StaysGenericServerError() {
        let message = OtpVerificationScreen.userFacingMessage(for: forbidden, mode: .login)
        XCTAssertNotEqual(message, unavailable)
    }

    func testExtensionOnly403MapsToRegistrationUnavailable() {
        XCTAssertEqual(ExtensionOnlyRegisterScreen.userFacingMessage(for: forbidden), unavailable)
    }

    func testOtherStatusesDoNotMapToRegistrationUnavailable() {
        for status in [400, 409, 429, 503, 500] {
            let error = BCryptoError.httpError(status)
            XCTAssertNotEqual(OtpVerificationScreen.userFacingMessage(for: error, mode: .register), unavailable, "otp \(status)")
            XCTAssertNotEqual(ExtensionOnlyRegisterScreen.userFacingMessage(for: error), unavailable, "ext \(status)")
        }
    }
}
