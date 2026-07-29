import XCTest
@testable import QAudionApp

/// W-CALLBOOK reconciliation (2026-07-29) — `NameResolutionService.phoneNumberOf`
/// is the iOS half of treating the wire `caller_display` value identically
/// across all three clients (mirrors Desktop's `extractCallPhoneNumber` and
/// Android's `phoneNumberOf`/`CallPeerNameViewModelPhoneNumberOfTest`; same
/// cases, same expected results).
///
/// Same gap `PeerTrustEvaluatorTests.swift`/`HeroPresenceLabelTests.swift`
/// already document: no `QAudionAppTests` target is wired in
/// `QAudionApp/project.yml` yet, and no Xcode/Swift toolchain is available in
/// this session to compile or run this file. Written against that gap rather
/// than left unwritten.
final class NameResolutionServicePhoneNumberOfTests: XCTestCase {

    func test_nilInput_yieldsNil() {
        XCTAssertNil(NameResolutionService.phoneNumberOf(nil))
    }

    func test_blankInput_yieldsNil() {
        XCTAssertNil(NameResolutionService.phoneNumberOf("   "))
    }

    func test_extensionShapedValue_yieldsNil() {
        XCTAssertNil(NameResolutionService.phoneNumberOf("151"))
    }

    func test_freeTextDisplayNameWithNoDigits_yieldsNil() {
        XCTAssertNil(NameResolutionService.phoneNumberOf("Marta Rinaldi"))
    }

    func test_leadingPlus_isRecognisedRegardlessOfLength() {
        XCTAssertEqual(NameResolutionService.phoneNumberOf("+39051"), "+39051")
    }

    func test_sevenOrMoreDigitsWithoutPlus_isRecognisedAsPhoneNumber() {
        XCTAssertEqual(NameResolutionService.phoneNumberOf("3331234567"), "3331234567")
    }

    func test_sixDigitsWithoutPlus_isNotRecognisedAsPhoneNumber() {
        XCTAssertNil(NameResolutionService.phoneNumberOf("123456"))
    }

    func test_realE164Number_isPassedThroughUnchanged() {
        XCTAssertEqual(NameResolutionService.phoneNumberOf("+391234567890"), "+391234567890")
    }
}
