import XCTest
@testable import QAudionEngine

final class SasVerificationViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(SasVerificationViewModel.mock, SasVerificationViewModel.mock)
    }

    func test_mockHasFourSasWords() {
        // Cross-platform standard: 4 PGP words = 32 bits of fingerprint entropy.
        XCTAssertEqual(SasVerificationViewModel.mock.sasWords.count, 4)
    }

    func test_mockSasWordsAreLowercase() {
        for w in SasVerificationViewModel.mock.sasWords {
            XCTAssertEqual(w, w.lowercased(), "SAS words must be lowercase for cross-platform comparison")
        }
    }

    func test_mockExposesPeerFingerprint() {
        let mock = SasVerificationViewModel.mock
        let parts = mock.peerFingerprint.split(separator: ".")
        XCTAssertEqual(parts.count, 4)
    }

    func test_mockUserHasNotConfirmed() {
        XCTAssertEqual(SasVerificationViewModel.mock.userVerdict, .pending)
    }
}
