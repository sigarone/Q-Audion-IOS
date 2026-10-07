import XCTest
@testable import QAudionEngine

/// W-SIGNERBOOT — the Keychain blob of the sovereign identity decodes correctly, with the big-endian
/// length fields read byte by byte (the old aligned `load` trapped in Debug builds on the odd offsets
/// these fields sit at; Release hid it, so the first Debug run that held an identity crashed at launch).
/// Pure bytes: no Keychain.
final class SovereignIdentityStorageCodecTests: XCTestCase {

    private let manager = SovereignIdentityManager()

    func testRoundTripKeepsEveryField() throws {
        let id = manager.generateIdentity(serverUrl: "https://voip.example.test", displayName: "Test Name")
        let loaded = try XCTUnwrap(manager.deserializeIdentity(manager.serializeIdentity(id)))
        XCTAssertEqual(loaded.userId, id.userId)
        XCTAssertEqual(loaded.serverUrl, id.serverUrl)
        XCTAssertEqual(loaded.displayName, id.displayName)
        XCTAssertEqual(loaded.encryptionPrivate, id.encryptionPrivate)
        XCTAssertEqual(loaded.encryptionPublic, id.encryptionPublic)
        XCTAssertEqual(loaded.signingPrivate, id.signingPrivate)
        XCTAssertEqual(loaded.signingPublic, id.signingPublic)
        XCTAssertEqual(loaded.identityType, id.identityType)
    }

    /// The identity a first launch creates: empty server url, no display name.
    func testBootstrapShapeRoundTrips() throws {
        let id = manager.generateIdentity(serverUrl: "", displayName: nil)
        let loaded = try XCTUnwrap(manager.deserializeIdentity(manager.serializeIdentity(id)))
        XCTAssertEqual(loaded.signingPublic, id.signingPublic)
        XCTAssertEqual(loaded.serverUrl, "")
        XCTAssertNil(loaded.displayName)
    }

    /// A length above 255 needs its HIGH byte: it proves the fields are read big-endian.
    func testLengthsAboveOneByteDecodeBigEndian() throws {
        let longName = String(repeating: "n", count: 300)      // 0x012C
        let longUrl = "https://" + String(repeating: "h", count: 290)
        let id = manager.generateIdentity(serverUrl: longUrl, displayName: longName)
        let loaded = try XCTUnwrap(manager.deserializeIdentity(manager.serializeIdentity(id)))
        XCTAssertEqual(loaded.displayName, longName)
        XCTAssertEqual(loaded.serverUrl, longUrl)
    }

    func testTruncatedOrWrongVersionBlobIsRejected() {
        let id = manager.generateIdentity(serverUrl: "https://s.example.test", displayName: "X")
        let blob = manager.serializeIdentity(id)
        XCTAssertNil(manager.deserializeIdentity(Data(blob.prefix(100))))
        var wrongVersion = blob
        wrongVersion[0] = 0x7F
        XCTAssertNil(manager.deserializeIdentity(wrongVersion))
        XCTAssertNil(manager.deserializeIdentity(Data()))
    }
}
