import XCTest
@testable import QAudionEngine

/// The custom TURN server of Settings > Trasporto: how `turn:user:password@host:port` is read, which addresses are
/// refused because they carry no credentials, and that the password stays out of anything printed.
///
/// libwebrtc rejects the whole configuration (no PeerConnection, so no call) for a TURN server with an empty user name or
/// password, and it does not read `user:password@` inside the URL. So the address is split here, and an address typed
/// without credentials is told apart from one that is simply malformed: Settings shows a different note for each, and
/// neither is ever saved, checked or handed to libwebrtc.
final class TransportCustomTurnTests: XCTestCase {

    private func server(_ typed: String, file: StaticString = #filePath, line: UInt = #line) throws -> TransportCustomTurn {
        try XCTUnwrap(TransportCustomTurn.parse(typed).server, "\"\(typed)\" is not a usable server", file: file, line: line)
    }

    // MARK: - Usable addresses

    func test_aServerWithCredentialsIsSplitIntoUrlUserNameAndPassword() throws {
        let s = try server("turn:alice:s3cret@relay.example.test:3478")
        XCTAssertEqual(s.iceUrl, "turn:relay.example.test:3478", "libwebrtc gets the address without the credentials")
        XCTAssertEqual(s.username, "alice")
        XCTAssertEqual(s.credential, "s3cret")
        XCTAssertEqual(s.storedText, "turn:alice:s3cret@relay.example.test:3478")
    }

    func test_turnsTheQueryTheCaseOfTheSchemeAndSurroundingSpacesAreHandled() throws {
        let tls = try server("turns:alice:s3cret@relay.example.test:5349?transport=tcp")
        XCTAssertEqual(tls.iceUrl, "turns:relay.example.test:5349?transport=tcp")
        XCTAssertEqual(tls.storedText, "turns:alice:s3cret@relay.example.test:5349?transport=tcp")

        let spaced = try server("  TURN:alice:s3cret@Relay.Example.Test  ")
        XCTAssertEqual(spaced.storedText, "turn:alice:s3cret@Relay.Example.Test", "lower case scheme, host as typed, no spaces")
        XCTAssertEqual(spaced.iceUrl, "turn:Relay.Example.Test")

        let emptyQuery = try server("turn:alice:s3cret@relay.example.test?")
        XCTAssertEqual(emptyQuery.iceUrl, "turn:relay.example.test", "an empty query is not passed on")
    }

    func test_theCredentialsAreReadWithPercentEncodingAndSubDelimitersStayAsTheyAre() throws {
        // The characters that would end or split the address are written as %xx; the value used is the decoded one.
        let encoded = try server("turn:a%40b:p%3Aw%2Fd%3F%25@relay.example.test:3478")
        XCTAssertEqual(encoded.username, "a@b")
        XCTAssertEqual(encoded.credential, "p:w/d?%")
        XCTAssertEqual(encoded.iceUrl, "turn:relay.example.test:3478", "nothing of the credentials is left in the url")

        // A base64 password uses + and =, an ephemeral user name has a colon: both are usable.
        let rest = try server("turn:1790000000%3Aalice:abc+def==@relay.example.test:3478")
        XCTAssertEqual(rest.username, "1790000000:alice")
        XCTAssertEqual(rest.credential, "abc+def==")

        let accents = try server("turn:alice:caf%C3%A9@relay.example.test")
        XCTAssertEqual(accents.credential, "café")
    }

    func test_theStoredTextRoundTripsThroughAUrlAndTheCopyWithoutCredentialsHasNone() throws {
        for typed in ["turn:alice:s3cret@relay.example.test:3478",
                      "turns:a%40b:p%3Aw@relay.example.test:5349?transport=tcp",
                      "turn:alice:abc+def==@203.0.113.7"] {
            let s = try server(typed)
            XCTAssertEqual(s.storedURL?.absoluteString, s.storedText, typed)
            XCTAssertEqual(s.urlWithoutCredentials?.absoluteString, s.iceUrl, typed)
            XCTAssertFalse(s.iceUrl.contains("@"), typed)
            XCTAssertEqual(TransportPlan.validatedCustomTurnUrl(typed)?.absoluteString, s.storedText, typed)
        }
    }

    func test_theHostIsLowerCaseWhateverTheCaseTypedAndPortAndQueryAreNotPartOfIt() throws {
        XCTAssertEqual(try server("turn:alice:s3cret@Relay.Example.Test:3478?transport=udp").host, "relay.example.test")
        XCTAssertEqual(try server("turn:alice:s3cret@203.0.113.7").host, "203.0.113.7")
        XCTAssertEqual(try server("turns:alice:s3cret@relay-1.example.test:5349").host, "relay-1.example.test")
    }

    // MARK: - The three fields of the screen

    func test_theFieldsMakeTheSameServerTheOneTextFormMakes() throws {
        let fromFields = try XCTUnwrap(TransportCustomTurn.make(address: "turn:relay.example.test:3478",
                                                                username: "alice", password: "s3cret"))
        XCTAssertEqual(fromFields, try server("turn:alice:s3cret@relay.example.test:3478"))
        XCTAssertEqual(fromFields.iceUrl, "turn:relay.example.test:3478")
        XCTAssertEqual(fromFields.host, "relay.example.test")
        XCTAssertEqual(fromFields.username, "alice")
        XCTAssertEqual(fromFields.credential, "s3cret")
    }

    func test_theFieldsTakePlainTextAndWriteTheEscapesThemselves() throws {
        // The characters that would end or split an address are typed as they are in the fields.
        let s = try XCTUnwrap(TransportCustomTurn.make(address: "turns:relay.example.test:5349?transport=tcp",
                                                       username: "1790000000:a@b", password: "p:w/d?%é +=#"))
        XCTAssertEqual(s.username, "1790000000:a@b")
        XCTAssertEqual(s.credential, "p:w/d?%é +=#")
        XCTAssertEqual(s.iceUrl, "turns:relay.example.test:5349?transport=tcp", "nothing of the credentials is left in the url")
        // Written as the one text and read again, it is the same server.
        XCTAssertEqual(TransportCustomTurn.parse(s.storedText).server, s)
        XCTAssertEqual(s.storedURL?.absoluteString, s.storedText)
    }

    func test_theFieldsKeepSpacesInsideACredentialAndTrimTheAddress() throws {
        let s = try XCTUnwrap(TransportCustomTurn.make(address: "  TURN:relay.example.test:3478  ",
                                                       username: " alice ", password: " pass word "))
        XCTAssertEqual(s.username, " alice ", "a credential is kept exactly as typed")
        XCTAssertEqual(s.credential, " pass word ")
        XCTAssertEqual(s.iceUrl, "turn:relay.example.test:3478")
    }

    func test_theFieldsMakeNoServerWithoutBothCredentialsOrWithAnAddressThatIsNotOne() {
        let address = "turn:relay.example.test:3478"
        XCTAssertNil(TransportCustomTurn.make(address: address, username: "", password: "s3cret"))
        XCTAssertNil(TransportCustomTurn.make(address: address, username: "alice", password: ""))
        XCTAssertNil(TransportCustomTurn.make(address: address, username: "", password: ""))
        // A control character cannot be part of a credential.
        XCTAssertNil(TransportCustomTurn.make(address: address, username: "alice", password: "two\nlines"))
        XCTAssertNil(TransportCustomTurn.make(address: address, username: "al\u{7F}ice", password: "s3cret"))
        // Not an address, or credentials already written inside it.
        for bad in ["", "relay.example.test", "http://relay.example.test", "turn:", "turn://relay.example.test",
                    "turn:relay.example.test:0", "turn:other:creds@relay.example.test:3478", "turn:alice@relay.example.test"] {
            XCTAssertNil(TransportCustomTurn.make(address: bad, username: "alice", password: "s3cret"), "\"\(bad)\"")
        }
    }

    func test_anAddressIsReadOnItsOwnWithoutLookingAtCredentials() throws {
        let plain = try XCTUnwrap(TransportCustomTurn.parseAddress("  TURNS:Relay.Example.Test:5349?transport=tcp "))
        XCTAssertEqual(plain.url, "turns:Relay.Example.Test:5349?transport=tcp")
        XCTAssertEqual(plain.host, "relay.example.test")
        XCTAssertFalse(plain.hasCredentialsInside)

        let withCredentials = try XCTUnwrap(TransportCustomTurn.parseAddress("turn:alice:s3cret@relay.example.test:3478"))
        XCTAssertEqual(withCredentials.url, "turn:relay.example.test:3478", "the url never has the credentials")
        XCTAssertTrue(withCredentials.hasCredentialsInside)
        XCTAssertTrue(try XCTUnwrap(TransportCustomTurn.parseAddress("turn:alice@relay.example.test")).hasCredentialsInside,
                      "part of a credential counts too")

        for bad in ["", "   ", "relay.example.test", "http://relay.example.test", "turn:", "turn:relay.example.test:0",
                    "turn:relay.example.test:65536", "turn:-relay.example.test"] {
            XCTAssertNil(TransportCustomTurn.parseAddress(bad), "\"\(bad)\"")
        }
    }

    // MARK: - Well formed but without credentials

    func test_aWellFormedAddressWithoutUserNameAndPasswordIsMissingCredentialsNotMalformed() {
        let withoutCredentials = [
            "turn:relay.example.test:3478",
            "turns:relay.example.test",
            "turn:relay.example.test:3478?transport=udp",
            "turn:alice@relay.example.test:3478",
            "turn:alice:@relay.example.test:3478",
            "turn::s3cret@relay.example.test:3478",
            "turn:@relay.example.test"
        ]
        for typed in withoutCredentials {
            XCTAssertEqual(TransportCustomTurn.parse(typed), .missingCredentials, typed)
            XCTAssertNil(TransportCustomTurn.parse(typed).server, typed)
            XCTAssertNil(TransportPlan.validatedCustomTurnUrl(typed), "\(typed): it must never reach the calls")
        }
    }

    // MARK: - Malformed

    func test_whatCannotBeReadIsMalformed() {
        let malformed = [
            "", "   ", "relay.example.test", "http://alice:s3cret@relay.example.test", "stun:alice:s3cret@relay.example.test",
            "turn:", "turn:alice:s3cret@", "turn://alice:s3cret@relay.example.test",
            "turn:alice:s3cret@relay.example.test:0", "turn:alice:s3cret@relay.example.test:99999",
            "turn:alice:s3cret@relay.example.test:port", "turn:alice:s3cret@-relay.example.test",
            // An extra colon, an extra @, a raw ? or / inside the credentials: they must be written as %xx.
            "turn:a:b:c@relay.example.test", "turn:a@b:c@relay.example.test", "turn:alice:pa?ss@relay.example.test",
            "turn:alice:p/ss@relay.example.test",
            // A space, a bad escape, an escape that is a control character.
            "turn:alice:pa ss@relay.example.test", "turn:alice:p%zz@relay.example.test", "turn:alice:p%@relay.example.test",
            "turn:alice:p%00@relay.example.test", "turn:alice:p%0A@relay.example.test"
        ]
        for typed in malformed {
            XCTAssertEqual(TransportCustomTurn.parse(typed), .malformed, "\"\(typed)\"")
        }
    }

    func test_theWholeTextIsLimitedTo512Characters() throws {
        let head = "turn:u:"
        let tail = "@h.example.test"
        let fits = head + String(repeating: "a", count: TransportCustomTurn.maxLength - head.count - tail.count) + tail
        XCTAssertEqual(fits.count, TransportCustomTurn.maxLength)
        XCTAssertNotNil(TransportCustomTurn.parse(fits).server)
        XCTAssertEqual(TransportCustomTurn.parse(fits + "a"), .malformed, "one character more is too long")
        XCTAssertEqual(TransportCustomTurn.parse(head + String(repeating: "a", count: 600) + tail), .malformed)
    }

    // MARK: - The password stays out of anything printed

    func test_noDescriptionShowsTheUserNameOrThePassword() throws {
        let s = try server("turn:alice-user:s3cret-pass@relay.example.test:3478")
        let plan = TransportPlan.make(mode: .relay, customTurnUrl: s.storedURL, bridgeAvailable: false)
        XCTAssertNotNil(plan.customTurn)
        for printed in [String(describing: s), String(reflecting: s), "\(s)", "\(plan)", String(reflecting: plan),
                        "\(TransportCustomTurn.Parsed.server(s))"] {
            XCTAssertFalse(printed.contains("s3cret-pass"), "the password is printed: \(printed)")
            XCTAssertFalse(printed.contains("alice-user"), "the user name is printed: \(printed)")
        }
    }
}
