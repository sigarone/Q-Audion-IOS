import XCTest
import Foundation
@testable import QAudionEngine

/// The pinned-at time of a key. Without the Keychain: the stored form, the fallback to the modification date, and the scan that
/// fails when a write path of the peer pins can skip the time. The tests that use the real Keychain are in the app test target
/// (`PeerIdentityPinKeychainTimeTests` there), which runs in a host that has one.
final class PeerIdentityPinTimeTests: XCTestCase {
    func testTheTimeIsEightBigEndianBytesOfUnixSecondsRoundedUp() {
        let d = PinTime.encode(Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(d, Data([0, 0, 0, 0, 0x6B, 0x49, 0xD2, 0x00]))
        XCTAssertEqual(PinTime.decode(d), Date(timeIntervalSince1970: 1_800_000_000))
        // A fraction of a second is rounded up: the age of a key is never overstated.
        XCTAssertEqual(PinTime.decode(PinTime.encode(Date(timeIntervalSince1970: 1_800_000_000.2))), Date(timeIntervalSince1970: 1_800_000_001))
        XCTAssertEqual(PinTime.decode(PinTime.encode(Date(timeIntervalSince1970: -5))), Date(timeIntervalSince1970: 0))
    }

    func testOnlyEightBytesAreATime() {
        XCTAssertNil(PinTime.decode(Data()))
        XCTAssertNil(PinTime.decode(Data(repeating: 1, count: 7)))
        XCTAssertNil(PinTime.decode(Data(repeating: 1, count: 9)))
        XCTAssertNil(PinTime.decode(Data(repeating: 0xFF, count: 8)), "not a plausible time")
    }

    func testAnItemWithoutTheStampFallsBackToItsModificationDateAndNothingElse() {
        let modified = Date(timeIntervalSince1970: 1_790_000_000)
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(PinTime.resolve(stamped: PinTime.encode(stamped), modified: modified), stamped, "the stamp wins")
        XCTAssertEqual(PinTime.resolve(stamped: nil, modified: modified), modified)
        XCTAssertEqual(PinTime.resolve(stamped: Data([1, 2, 3]), modified: modified), modified, "a stamp that is not a time is no stamp")
        XCTAssertNil(PinTime.resolve(stamped: nil, modified: nil), "no other fallback")
    }

    // MARK: every write path stamps the time

    private func storeSource() throws -> String {
        try VoiceTierInputsTests.source("QAudionEngine/Sources/QAudionEngine/Persistence/PeerIdentityPinStore.swift")
    }

    /// The text of the function that starts at `signature`, up to its closing brace at the same indentation.
    private func body(of signature: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), signature)
        let lineStart = text[..<start.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let indent = String(text[lineStart..<start.lowerBound])
        let close = try XCTUnwrap(text.range(of: "\n" + indent + "}", range: start.upperBound..<text.endIndex), signature)
        return String(text[start.lowerBound..<close.upperBound])
    }

    func testTheStoreWritesAPinInExactlyTwoPlacesAndBothStampTheTime() throws {
        let text = try storeSource()
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        XCTAssertEqual(code.components(separatedBy: "SecItemAdd(").count - 1, 1, "one add")
        XCTAssertEqual(code.components(separatedBy: "SecItemUpdate(").count - 1, 1, "one update")
        let add = try body(of: "private func addPin(account: String, key: Data) -> OSStatus {", in: text)
        let update = try body(of: "private func updatePin(account: String, key: Data) -> Bool {", in: text)
        XCTAssertTrue(add.contains("SecItemAdd("))
        XCTAssertTrue(update.contains("SecItemUpdate("))
        for helper in [add, update] {
            XCTAssertTrue(helper.contains("kSecAttrGeneric as String: PinTime.encode(clock())"), "the time is written with the key")
        }
    }

    func testEveryAddAndReplaceOfAPinGoesThroughThoseTwoWrites() throws {
        let text = try storeSource()
        let pinOrMatch = try body(of: "public func pinOrMatch(contactId: String, ed25519Pub: Data, deviceId: String? = nil) -> PinResult {", in: text)
        XCTAssertTrue(pinOrMatch.contains("addPin(account: account, key: ed25519Pub)"))
        XCTAssertFalse(pinOrMatch.contains("kSecValueData"), "no write of its own")
        let repin = try body(of: "public func repin(contactId: String, ed25519Pub: Data, deviceId: String? = nil) -> RepinOutcome {", in: text)
        XCTAssertTrue(repin.contains("updatePin(account: account, key: ed25519Pub)"), "the replacement")
        XCTAssertTrue(repin.contains("addPin(account: account, key: ed25519Pub)"), "the addition")
        XCTAssertFalse(repin.contains("kSecValueData"), "no write of its own")
        // A key that is already the pin is never written again, so seeing it again does not reset its age.
        XCTAssertTrue(repin.contains("if existing == ed25519Pub { return .unchanged }"))
        XCTAssertTrue(pinOrMatch.contains("existing == ed25519Pub ? .match : .mismatch"))
    }

    func testNoOtherFileWritesOrReadsTheKeychainServiceOfThePins() throws {
        var dir = URL(fileURLWithPath: "\(#filePath)")
        var root: URL?
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("QAudionEngine/Sources/QAudionEngine").path) { root = dir; break }
        }
        let repo = try XCTUnwrap(root)
        let files = PeerConnectionStatsGateScanTests.sourceFiles(under: repo)
        XCTAssertGreaterThan(files.count, 100, "the scan did find the sources")
        var outside: [String] = []
        for url in files where url.lastPathComponent != "PeerIdentityPinStore.swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            if code.contains("com.bcrypto.qaudion.peerpins") { outside.append(url.lastPathComponent) }
        }
        XCTAssertEqual(outside, [], "a new write path for the pins must go through PeerIdentityPinStore")
    }

    // MARK: the callers of the two writes (the repin paths)

    /// Every place that adds or replaces a pin does it through `pinOrMatch` or `repin`. New callers are fine (they stamp); this lists
    /// the ones that exist so that a reader of the test sees the paths: SAS adoption of a signer key and of a rotated key, the
    /// set-proven repin of a rotation (number moved, reinstall), the first-contact pins of the handshake and of the accepted new
    /// identity of the contact screen.
    func testTheKnownRepinPathsAllCallTheStore() throws {
        let app = try VoiceTierInputsTests.source("QAudionApp/AppState.swift")
        XCTAssertTrue(app.contains("store.repin(contactId: peer, ed25519Pub: candidate.key, deviceId: candidate.deviceId)"), "SAS-confirmed rotation")
        XCTAssertTrue(app.contains("store.pinOrMatch(contactId: peer, ed25519Pub: hit.key, deviceId: deviceId)"), "SAS-confirmed signer key")
        XCTAssertTrue(app.contains("pinStore.pinOrMatch(contactId: peerId, ed25519Pub: key, deviceId: deviceId)"), "handshake first contact")
        XCTAssertTrue(app.contains("pinStore.repin(contactId: peerId, ed25519Pub: key, deviceId: deviceId)"), "set-proven rotation")
        let trust = try VoiceTierInputsTests.source("QAudionApp/Services/PeerTrustEvaluator.swift")
        XCTAssertTrue(trust.contains("pinStore.pinOrMatch(contactId: peerUserId, ed25519Pub: newPeerIkEdPub)"), "accepted new identity")
    }
}
