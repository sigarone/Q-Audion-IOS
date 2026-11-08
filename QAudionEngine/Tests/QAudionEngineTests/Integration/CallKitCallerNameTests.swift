import XCTest
@testable import QAudionEngine

/// The name the system call UI shows for a call: caller, padlock and the encrypted-call tag.
final class CallKitCallerNameTests: XCTestCase {

    func test_callerDisplayName_isNameSeparatorLockTag() {
        XCTAssertEqual(CallKitProvider.callerDisplayName("Marco", encryptedTag: "Chiamata cifrata"), "Marco · 🔒 Chiamata cifrata")
    }

    func test_callerDisplayName_hasPadlock() {
        let name = CallKitProvider.callerDisplayName("Anna", encryptedTag: "Encrypted call")
        XCTAssertTrue(name.contains("🔒"))
        XCTAssertTrue(name.hasSuffix("Encrypted call"))
    }

    func test_callerDisplayName_outgoingHandleGetsSameLabel() {
        XCTAssertEqual(CallKitProvider.callerDisplayName("+390000", encryptedTag: "Encrypted call"), "+390000 · 🔒 Encrypted call")
    }

    func test_encryptedCallTag_isNeverEmpty() {
        XCTAssertFalse(CallKitProvider.encryptedCallTag().isEmpty)
    }
}
