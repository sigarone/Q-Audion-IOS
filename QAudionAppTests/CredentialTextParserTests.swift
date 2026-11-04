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

    // MARK: - Generated passwords (OCR clean-up)

    private let generated = "K7M2PXQ9R4TWNBC8DFHJ"
    private let dashed = "K7M2-PXQ9-R4TW-NBC8-DFHJ"

    func testDashedDisplayShapeKeepsCaseAndDashes() {
        let c = CredentialTextParser.fromText("Interno: 176\nPassword: k7m2-pxq9-r4tw-nbc8-dfhj")
        XCTAssertEqual(c, ExtractedCredentials(extensionNumber: "176", password: "k7m2-pxq9-r4tw-nbc8-dfhj"))
        let d = CredentialTextParser.normalizeGenerated(dashed)
        XCTAssertEqual(d?.password, dashed)
        XCTAssertEqual(d?.uncertain, [])
    }

    func testDashedShapeWithLookAlikesIsMappedAndPositionsSkipDashes() {
        // Full-width K, Cyrillic M and P, Greek Chi, then a letter O at character 8 and a digit 1 at 20 (dashes not counted).
        let read = "\u{FF2B}7\u{041C}2-\u{0420}\u{03A7}Q0-R4TW-NBC8-DFH1"
        let n = CredentialTextParser.normalizeGenerated(read)
        XCTAssertEqual(n?.password, "K7M2-PXQ0-R4TW-NBC8-DFH1")
        XCTAssertEqual(n?.uncertain, [8, 20])
    }

    func testMixedScriptLookAlikesInAllUppercaseToken() {
        let read = "\u{FF2B}7\u{041C}2\u{0420}\u{03A7}Q9R4TWNBC8DFHJ"
        let c = CredentialTextParser.fromText("Interno: 176\nPassword: \(read)")
        XCTAssertEqual(c?.password, generated)
        XCTAssertEqual(c?.uncertainPositions, [])
        let z = CredentialTextParser.normalizeGenerated("\u{0396}7M2PXQ9R4TWNBC8DFHJ")
        XCTAssertEqual(z?.password, "Z7M2PXQ9R4TWNBC8DFHJ")
        // Greek capital Nu and Upsilon look like N and Y.
        let ny = CredentialTextParser.normalizeGenerated("\u{039D}7M2PXQ9R4TW\u{03A5}BC8DFHJ")
        XCTAssertEqual(ny?.password, "N7M2PXQ9R4TWYBC8DFHJ")
    }

    func testGreekLowercaseNuAndUpsilonAreNotMapped() {
        // v-shaped letters are not n or y: they stay as read, the token is not ASCII and nothing is rewritten.
        XCTAssertNil(CredentialTextParser.normalizeGenerated("K7M2PXQ9R4TW\u{03BD}BC8DFHJ"))
        XCTAssertNil(CredentialTextParser.normalizeGenerated("K7M2PXQ9R4TW\u{03C5}BC8DFHJ"))
    }

    func testLettersLAndOAndDigitsZeroOneAreFlagged() {
        let l = CredentialTextParser.normalizeGenerated("K7M2PXQ9R4TWNBC8DFHL")
        XCTAssertEqual(l?.password, "K7M2PXQ9R4TWNBC8DFHL")
        XCTAssertEqual(l?.uncertain, [20])
        let lower = CredentialTextParser.normalizeGenerated("k7m2-pxq9-r4tw-nbc8-dfhl")
        XCTAssertEqual(lower?.password, "k7m2-pxq9-r4tw-nbc8-dfhl")
        XCTAssertEqual(lower?.uncertain, [20])
        let c = CredentialTextParser.fromText("Interno: 176\nPassword: K7M2PXQ0R4TWNBC8DFHI")
        XCTAssertEqual(c?.password, "K7M2PXQ0R4TWNBC8DFHI")
        XCTAssertEqual(c?.uncertainPositions, [8, 20])
        let one = CredentialTextParser.normalizeGenerated("K7M2PXQ9R4TWNBC8DFH1")
        XCTAssertEqual(one?.uncertain, [20])
    }

    func testBoundaryOfSeventeenInAlphabet() {
        // Exactly 17 in the alphabet (three of 0/O/1/I/L): accepted. 16: untouched.
        let seventeen = CredentialTextParser.normalizeGenerated("K7M2PXQ9R4TWNBC8D" + "0O1")
        XCTAssertEqual(seventeen?.uncertain, [18, 19, 20])
        XCTAssertNil(CredentialTextParser.normalizeGenerated("K7M2PXQ9R4TWNBC8" + "0O1I"))
    }

    func testInAlphabetPairsAreNotTouched() {
        // 5, 8, 2, 6 and their letter twins are all valid: nothing changes, nothing is flagged.
        let n = CredentialTextParser.normalizeGenerated("S5B8Z2G6K7M2PXQ9R4TW")
        XCTAssertEqual(n?.password, "S5B8Z2G6K7M2PXQ9R4TW")
        XCTAssertEqual(n?.uncertain, [])
    }

    func testFreeFormPasswordsAreUntouched() {
        let lower20 = "correcthorsebattery1"
        XCTAssertEqual(lower20.count, 20)
        XCTAssertNil(CredentialTextParser.normalizeGenerated(lower20))
        XCTAssertNil(CredentialTextParser.normalizeGenerated("k7m2pxq9r4twnbc8dfhj"))  // 20 lowercase, no dashes
        XCTAssertNil(CredentialTextParser.normalizeGenerated("a1b2c3d4e5f60718"))
        XCTAssertNil(CredentialTextParser.normalizeGenerated("correct-horse-battery-staple"))
        XCTAssertNil(CredentialTextParser.normalizeGenerated("K7M2PXQ9R4TWNBC8DFH"))   // 19
        XCTAssertNil(CredentialTextParser.normalizeGenerated("K7M2PXQ9R4TWNBC8DFHJK")) // 21
        XCTAssertNil(CredentialTextParser.normalizeGenerated("K7M2 PXQ9 R4TW NBC8 DFHJ")) // spaces, not the display shape
        let free = CredentialTextParser.fromText("Interno: 176\nPassword: \(lower20)")
        XCTAssertEqual(free, ExtractedCredentials(extensionNumber: "176", password: lower20))
        let hex = CredentialTextParser.fromText("Interno: 176\nPassword: a1b2c3d4e5f60718")
        XCTAssertEqual(hex, ExtractedCredentials(extensionNumber: "176", password: "a1b2c3d4e5f60718"))
    }

    func testGeneratedPasswordWithoutLabels() {
        let c = CredentialTextParser.fromText("176\nK7M2PXQ9R4TWNBC8DFHJ")
        XCTAssertEqual(c, ExtractedCredentials(extensionNumber: "176", password: generated))
    }
}

/// UI that stays hidden in the store build until the feature behind it is real.
final class StoreComplianceFlagsTests: XCTestCase {
    func testHiddenByDefault() {
        XCTAssertFalse(StoreComplianceFlags.showProBadge)
        XCTAssertFalse(StoreComplianceFlags.showLinkNewDevice)
    }
}
