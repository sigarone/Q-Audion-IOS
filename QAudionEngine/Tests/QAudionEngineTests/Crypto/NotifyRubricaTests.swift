import CryptoKit
import Foundation
import XCTest
@testable import QAudionEngine

/// The list of names the notification extension reads, the plan built from an opened envelope, and the key lifecycle
/// policy (requests, answers, in-flight latch).
final class NotifyRubricaTests: XCTestCase {

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notify-rubrica-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Rubrica

    func testRoundTripThroughTheFile() throws {
        let directory = try tempDirectory()
        let rubrica = NotifyRubrica.build(
            people: [("User-A", .init(name: "Anna", avatar: "a.jpg", muted: false)),
                     ("user-b", .init(name: "Bruno", avatar: nil, muted: true))],
            groups: [("C1D2-E3", .init(name: "Famiglia", muted: true))])
        XCTAssertTrue(NotifyRubricaFiles.write(rubrica, to: directory))
        let read = try XCTUnwrap(NotifyRubricaFiles.read(from: directory))
        XCTAssertEqual(read, rubrica)
        XCTAssertEqual(read.person("USER-A")?.name, "Anna")
        XCTAssertEqual(read.person("user-b")?.muted, true)
        XCTAssertEqual(read.group("c1d2e3")?.name, "Famiglia")
        XCTAssertEqual(read.group("c1d2-e3")?.muted, true)
    }

    func testSizeIsBounded() {
        let people = (0..<(NotifyRubrica.maxPeople + 50)).map {
            (id: "u\($0)", person: NotifyRubrica.Person(name: "Name \($0)"))
        }
        let groups = (0..<(NotifyRubrica.maxGroups + 20)).map {
            (id: "g\($0)", group: NotifyRubrica.Group(name: "Group \($0)"))
        }
        let rubrica = NotifyRubrica.build(people: people, groups: groups)
        XCTAssertEqual(rubrica.people.count, NotifyRubrica.maxPeople)
        XCTAssertEqual(rubrica.groups.count, NotifyRubrica.maxGroups)
        XCTAssertNotNil(rubrica.people["u0"], "the first (most recent) entries are the ones kept")
        XCTAssertNil(rubrica.people["u\(NotifyRubrica.maxPeople)"])
        XCTAssertLessThan((try? JSONEncoder().encode(rubrica).count) ?? Int.max, NotifyRubrica.maxFileBytes)
    }

    func testLongNamesAreClippedAndEmptyUnmutedEntriesDropped() {
        let long = String(repeating: "x", count: 500)
        let rubrica = NotifyRubrica.build(
            people: [("a", .init(name: long)), ("b", .init(name: "  ")), ("c", .init(name: "", muted: true))],
            groups: [])
        XCTAssertEqual(rubrica.people["a"]?.name.count, NotifyRubrica.maxNameLength)
        XCTAssertNil(rubrica.people["b"])
        XCTAssertEqual(rubrica.people["c"]?.muted, true)
    }

    func testAnOversizedFileIsIgnored() throws {
        let directory = try tempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let junk = Data(repeating: 0x20, count: NotifyRubrica.maxFileBytes + 1)
        try junk.write(to: directory.appendingPathComponent(NotifyRubricaFiles.fileName))
        XCTAssertNil(NotifyRubricaFiles.read(from: directory))
    }

    func testAvatarFilesAreNamedByHashAndPruned() throws {
        let directory = try tempDirectory()
        let name = NotifyRubricaFiles.avatarFileName(for: "User-A")
        XCTAssertEqual(name, NotifyRubricaFiles.avatarFileName(for: "user-a"))
        XCTAssertFalse(name.contains("user"))
        XCTAssertTrue(name.hasSuffix(".jpg"))
        XCTAssertTrue(NotifyRubricaFiles.writeAvatar(Data([0xFF, 0xD8, 0xFF]), name: name, in: directory))
        XCTAssertTrue(NotifyRubricaFiles.writeAvatar(Data([1]), name: "other.jpg", in: directory))
        XCTAssertFalse(NotifyRubricaFiles.writeAvatar(Data([1]), name: "../escape.jpg", in: directory))
        XCTAssertNil(NotifyRubricaFiles.avatarURL("a/b.jpg", in: directory))
        NotifyRubricaFiles.pruneAvatars(keeping: [name], in: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("other.jpg").path))
    }

    func testClearRemovesEverything() throws {
        let directory = try tempDirectory()
        XCTAssertTrue(NotifyRubricaFiles.write(NotifyRubrica(), to: directory))
        NotifyRubricaFiles.clear(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(NotifyRubricaFiles.read(from: directory))
    }

    // MARK: - Content plan

    private func rubrica() -> NotifyRubrica {
        NotifyRubrica.build(
            people: [("sender-1", .init(name: "Anna", avatar: "anna.jpg")),
                     ("sender-2", .init(name: "Bruno", muted: true))],
            groups: [("aabbcc-dd", .init(name: "Famiglia")), ("eeff", .init(name: "Lavoro", muted: true))])
    }

    private func dm(_ id: String) -> NotifyEnvelope.Plaintext {
        .init(kind: .dm, senderID: id, groupID: nil, timestamp: 1)
    }

    private func grp(_ id: String, _ g: String) -> NotifyEnvelope.Plaintext {
        .init(kind: .grp, senderID: id, groupID: g, timestamp: 1)
    }

    func testOneToOneUsesTheContactNameAndAvatar() {
        let plan = NotifyContentPlan.make(from: dm("sender-1"), rubrica: rubrica())
        XCTAssertEqual(plan.title, "Anna")
        XCTAssertEqual(plan.avatarFile, "anna.jpg")
        XCTAssertFalse(plan.muted)
    }

    func testGroupTitleIsNameDotGroup() {
        let plan = NotifyContentPlan.make(from: grp("sender-1", "AABB-CCDD"), rubrica: rubrica())
        XCTAssertEqual(plan.title, "Anna \u{00B7} Famiglia")
        XCTAssertEqual(plan.conversationKey, "g:aabbccdd")
        XCTAssertFalse(plan.muted)
    }

    func testMuteFollowsTheConversation() {
        XCTAssertTrue(NotifyContentPlan.make(from: dm("sender-2"), rubrica: rubrica()).muted)
        XCTAssertTrue(NotifyContentPlan.make(from: grp("sender-1", "eeff"), rubrica: rubrica()).muted)
        // A muted person does not silence a group that is not muted.
        XCTAssertFalse(NotifyContentPlan.make(from: grp("sender-2", "aabbccdd"), rubrica: rubrica()).muted)
    }

    func testUnknownSenderKeepsTheGenericTitleAndHasNoAvatar() {
        let plan = NotifyContentPlan.make(from: dm("nobody"), rubrica: rubrica())
        XCTAssertNil(plan.title)
        XCTAssertNil(plan.avatarFile)
        let none = NotifyContentPlan.make(from: dm("sender-1"), rubrica: nil)
        XCTAssertNil(none.title)
        XCTAssertFalse(none.muted)
        // Unknown sender in a known group: the group name stands in.
        XCTAssertEqual(NotifyContentPlan.make(from: grp("nobody", "aabbccdd"), rubrica: rubrica()).title, "Famiglia")
        // Known sender in an unknown group: the sender name only.
        XCTAssertEqual(NotifyContentPlan.make(from: grp("sender-1", "zzzz"), rubrica: rubrica()).title, "Anna")
    }

    func testThreadIdentifierIsStableLocalAndOpaque() {
        let a = NotifyContentPlan.make(from: dm("sender-1"), rubrica: rubrica()).threadIdentifier
        let b = NotifyContentPlan.make(from: dm("SENDER-1"), rubrica: nil).threadIdentifier
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, NotifyContentPlan.make(from: dm("sender-2"), rubrica: rubrica()).threadIdentifier)
        XCTAssertFalse(a.contains("sender"))
        XCTAssertTrue(a.hasPrefix("qa-"))
    }

    // MARK: - Key lifecycle policy

    func testPutRequestShape() throws {
        let request = try XCTUnwrap(NotifyKeyRegistration.putRequest(
            serverUrl: "https://example.test/base/", publicBase64: "AAAA", bearer: "tok"))
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/base/api/v1/account/notify-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["pub": "AAAA", "alg": "x25519-hkdf-sha256-aes256gcm-v1"])
        let delete = try XCTUnwrap(NotifyKeyRegistration.deleteRequest(serverUrl: "https://example.test", bearer: "tok"))
        XCTAssertEqual(delete.httpMethod, "DELETE")
        XCTAssertNil(delete.httpBody)
    }

    func testAnswers() {
        XCTAssertEqual(NotifyKeyRegistration.outcome(statusCode: 200), .registered)
        XCTAssertEqual(NotifyKeyRegistration.outcome(statusCode: 204), .registered)
        XCTAssertEqual(NotifyKeyRegistration.outcome(statusCode: 409), .waitForNextToken)
        XCTAssertEqual(NotifyKeyRegistration.outcome(statusCode: 400), .failed)
        XCTAssertEqual(NotifyKeyRegistration.outcome(statusCode: 500), .failed)
        XCTAssertEqual(NotifyKeyRegistration.outcome(statusCode: nil), .failed)
    }

    func testTheKeyIsRegisteredOnlyAfterAnAlertTokenWhileSignedIn() {
        XCTAssertTrue(NotifyKeyRegistration.shouldRegister(authenticated: true, alertTokenJustRegistered: true))
        XCTAssertFalse(NotifyKeyRegistration.shouldRegister(authenticated: false, alertTokenJustRegistered: true))
        XCTAssertFalse(NotifyKeyRegistration.shouldRegister(authenticated: true, alertTokenJustRegistered: false))
    }

    func testInFlightLatch() {
        var latch = NotifyKeyInFlight()
        let first = latch.begin()
        XCTAssertNotNil(first)
        XCTAssertNil(latch.begin(), "a second request is not started while one runs")
        latch.reset()
        let second = latch.begin()
        XCTAssertNotNil(second)
        latch.finish(ticket: first!)   // the late answer of the old account does not free the new request
        XCTAssertNil(latch.begin())
        latch.finish(ticket: second!)
        XCTAssertNotNil(latch.begin())
    }

    func testEnsureKeyCreatesOnceAndKeepsIt() throws {
        let keychain = NotifyKeychain(accessGroup: nil)
        keychain.delete()
        addTeardownBlock { keychain.delete() }
        guard let first = NotifyKeyRegistration.ensureKey(in: keychain) else {
            throw XCTSkip("the keychain is not usable in this test host")
        }
        XCTAssertEqual(Data(base64Encoded: first.publicBase64)?.count, 32)
        let second = try XCTUnwrap(NotifyKeyRegistration.ensureKey(in: keychain))
        XCTAssertEqual(first.privateKey, second.privateKey)
        XCTAssertEqual(first.publicBase64, second.publicBase64)
        keychain.delete()
        XCTAssertNil(keychain.load())
    }
}
