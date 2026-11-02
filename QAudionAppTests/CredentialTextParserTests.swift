import XCTest
@testable import QAudionApp

/// The pure part of "Fill in from a photo or file": which extension and password a piece of text or a
/// structured payload carries. Nothing here reads an image or touches the network.
final class CredentialTextParserTests: XCTestCase {

    private let accept: (String) -> Bool = { $0 == "https://voip.example.test" }

    private func json(server: String = "https://voip.example.test", ext: Int = 176, password: String = "s3cretPw") -> String {
        """
        {"v":1,"kind":"bcrypto-fast-setup","server":"\(server)","extension":\(ext),"phone_id":"fastsetup-0000","password":"\(password)","display_name":"Phone"}
        """
    }

    func testStructuredPayloadFillsBothValues() {
        let r = CredentialTextParser.extract(structuredPayloads: [json()], text: "", serverAccepted: accept)
        XCTAssertEqual(r, .found(ExtractedCredentials(extensionNumber: "176", password: "s3cretPw")))
    }

    func testStructuredPayloadFromUnpinnedServerIsRefused() {
        let r = CredentialTextParser.extract(structuredPayloads: [json(server: "https://evil.example.org")], text: "", serverAccepted: accept)
        XCTAssertEqual(r, .notPinned(server: "https://evil.example.org"))
    }

    func testStructuredPayloadWithWrongKindFallsBackToText() {
        let wrong = json().replacingOccurrences(of: "bcrypto-fast-setup", with: "other")
        let r = CredentialTextParser.extract(structuredPayloads: [wrong], text: "Interno: 201\nPassword: abc", serverAccepted: accept)
        XCTAssertEqual(r, .found(ExtractedCredentials(extensionNumber: "201", password: "abc")))
    }

    func testStructuredPayloadInsideTextFile() {
        let r = CredentialTextParser.extract(structuredPayloads: [], text: "\n" + json() + "\n", serverAccepted: accept)
        XCTAssertEqual(r, .found(ExtractedCredentials(extensionNumber: "176", password: "s3cretPw")))
    }

    func testLabelledItalian() {
        let c = CredentialTextParser.fromText("Interno: 176\nPassword: Rosa-9921")
        XCTAssertEqual(c, ExtractedCredentials(extensionNumber: "176", password: "Rosa-9921"))
    }

    func testLabelledEnglishWithEquals() {
        let c = CredentialTextParser.fromText("Extension = 305\nPwd = open sesame")
        XCTAssertEqual(c, ExtractedCredentials(extensionNumber: "305", password: "open sesame"))
    }

    func testUserAndPassLabels() {
        let c = CredentialTextParser.fromText("user: 4410\npass: k9Lm2")
        XCTAssertEqual(c, ExtractedCredentials(extensionNumber: "4410", password: "k9Lm2"))
    }

    func testBothLabelsOnOneLine() {
        let c = CredentialTextParser.fromText("Ext 88 Password: Tiger77")
        XCTAssertEqual(c, ExtractedCredentials(extensionNumber: "88", password: "Tiger77"))
    }

    func testValuesOnTheNextLine() {
        let c = CredentialTextParser.fromText("Interno\n176\nPassword\nMy-Pass-1")
        XCTAssertEqual(c, ExtractedCredentials(extensionNumber: "176", password: "My-Pass-1"))
    }

    func testLabelsAreCaseInsensitiveAndWordBound() {
        // "Next" and "Passphrase" must not be read as labels.
        let c = CredentialTextParser.fromText("Next step\nINTERNO: 120\nPASSWORD: Zz99")
        XCTAssertEqual(c, ExtractedCredentials(extensionNumber: "120", password: "Zz99"))
    }

    func testUnlabelledFallbackTakesFirstShortNumberThenNextToken() {
        let c = CredentialTextParser.fromText("176\nBlueFox42")
        XCTAssertEqual(c, ExtractedCredentials(extensionNumber: "176", password: "BlueFox42"))
    }

    func testUnlabelledFallbackOnOneLine() {
        let c = CredentialTextParser.fromText("Ciao! 2305 gatto-rosso")
        XCTAssertEqual(c, ExtractedCredentials(extensionNumber: "2305", password: "gatto-rosso"))
    }

    func testLabelledExtensionWithUnlabelledPassword() {
        let c = CredentialTextParser.fromText("Interno: 176\nxT7pq")
        XCTAssertEqual(c, ExtractedCredentials(extensionNumber: "176", password: "xT7pq"))
    }

    func testNothingFound() {
        XCTAssertNil(CredentialTextParser.fromText(""))
        XCTAssertNil(CredentialTextParser.fromText("Ciao, come stai oggi?"))
        XCTAssertNil(CredentialTextParser.fromText("176"))
        XCTAssertEqual(CredentialTextParser.extract(structuredPayloads: [], text: "Nessun dato qui", serverAccepted: accept), .notFound)
    }

    func testLongNumberIsNotTakenAsExtension() {
        XCTAssertNil(CredentialTextParser.fromText("1234567890 abc"))
    }
}

/// UI that stays hidden in the store build until the feature behind it is real.
final class StoreComplianceFlagsTests: XCTestCase {
    func testHiddenByDefault() {
        XCTAssertFalse(StoreComplianceFlags.showProBadge)
        XCTAssertFalse(StoreComplianceFlags.showLinkNewDevice)
    }
}
