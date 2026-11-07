import XCTest
@testable import QAudionEngine

/// The name the system call UI shows for an incoming call: caller and encrypted tag, with no padlock character.
final class CallKitCallerNameTests: XCTestCase {

    func test_callerDisplayName_isNameSeparatorTag() {
        XCTAssertEqual(CallKitProvider.callerDisplayName("Marco", encryptedTag: "Cifrata"), "Marco \u{00B7} Cifrata")
    }

    func test_callerDisplayName_hasNoPadlockOrPictograph() {
        let name = CallKitProvider.callerDisplayName("Anna", encryptedTag: "Encrypted")
        XCTAssertFalse(name.contains("\u{1F512}"))
        XCTAssertFalse(name.unicodeScalars.contains { $0.properties.isEmojiPresentation })
    }
}
