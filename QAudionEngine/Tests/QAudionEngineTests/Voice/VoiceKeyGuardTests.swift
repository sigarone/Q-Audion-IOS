import XCTest
import Foundation
import CryptoKit
@testable import QAudionEngine

/// The key is not created again while data exists and a lookup only reads the key as missing for a moment; a lookup that fails,
/// or a question about the data that fails, is never read as "missing" or "no data".
final class VoiceKeyGuardTests: XCTestCase {
    private func key() -> SymmetricKey { SymmetricKey(size: .bits256) }

    private func bytes(_ k: SymmetricKey) -> [UInt8] { VoiceStoreFixtures.keyBytes(k) }

    func testMissingTwiceAndThenPresentWithDataGivesNoNewKeyAndNoLog() throws {
        let real = key()
        var looks = 0
        var created = 0
        var pauses = [Int]()
        var logs = [String]()
        let g = VoiceKeyGuard(
            existing: { looks += 1; return looks <= 2 ? nil : real },
            create: { created += 1; return SymmetricKey(size: .bits256) },
            dataExists: { true },
            log: { logs.append($0) },
            sleep: { pauses.append($0) })
        XCTAssertEqual(bytes(try g.get()), bytes(real))
        XCTAssertEqual(created, 0)
        XCTAssertEqual(pauses, [50, 150])
        XCTAssertEqual(logs, [])
    }

    func testStillMissingAfterThreeLooksWithDataGivesANewKeyAndOneFixedLogLine() throws {
        var created = 0
        var pauses = [Int]()
        var logs = [String]()
        let g = VoiceKeyGuard(
            existing: { nil },
            create: { created += 1; return SymmetricKey(size: .bits256) },
            dataExists: { true },
            log: { logs.append($0) },
            sleep: { pauses.append($0) })
        _ = try g.get()
        XCTAssertEqual(created, 1)
        XCTAssertEqual(pauses, [50, 150, 400])
        XCTAssertEqual(logs, [VoiceKeyGuard.logRecreated])
    }

    func testNoDataAndNoKeyCreatesTheKeyAtOnce() throws {
        var created = 0
        var pauses = [Int]()
        let g = VoiceKeyGuard(existing: { nil }, create: { created += 1; return SymmetricKey(size: .bits256) },
                              dataExists: { false }, sleep: { pauses.append($0) })
        _ = try g.get()
        XCTAssertEqual(created, 1)
        XCTAssertEqual(pauses, [])
    }

    func testAKeyThatIsThereIsReturnedWithoutAPauseAndWithoutAskingAboutData() throws {
        let real = key()
        var pauses = [Int]()
        let g = VoiceKeyGuard(existing: { real }, create: { XCTFail("no new key"); return SymmetricKey(size: .bits256) },
                              dataExists: { XCTFail("the data is not asked about"); return false }, sleep: { pauses.append($0) })
        XCTAssertEqual(bytes(try g.get()), bytes(real))
        XCTAssertEqual(pauses, [])
    }

    func testAFailingLookupIsNeverReadAsMissing() {
        var created = 0
        let g = VoiceKeyGuard(
            existing: { throw VoiceStoreError(.key, "keychain not available") },
            create: { created += 1; return SymmetricKey(size: .bits256) },
            dataExists: { false })
        XCTAssertThrowsError(try g.get()) { error in
            XCTAssertEqual((error as? VoiceStoreError)?.kind, .key)
        }
        XCTAssertEqual(created, 0)
    }

    func testAFailingQuestionAboutTheDataIsNeverReadAsNoData() {
        var created = 0
        let g = VoiceKeyGuard(
            existing: { nil },
            create: { created += 1; return SymmetricKey(size: .bits256) },
            dataExists: { throw VoiceStoreError(.io, "directory not listable") },
            sleep: { _ in })
        XCTAssertThrowsError(try g.get()) { error in
            XCTAssertEqual((error as? VoiceStoreError)?.kind, .io)
        }
        XCTAssertEqual(created, 0)
    }

    func testThroughTheStoreAKeyThatReadsAsMissingTwiceDeletesNothing() throws {
        let dir = try VoiceStoreFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = try VoiceKat.bundle().state
        let real = key()
        let first = VoiceAesGcmAead(key: { real })
        try VoiceTemplateStore(dir: dir, aead: first, accountId: "acct", dirSync: VoiceDirectorySyncs.none)
            .save("c", VoiceStoreFixtures.record(cfg))
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        var looks = 0
        var created = 0
        let guardian = VoiceKeyGuard(
            existing: { looks += 1; return looks <= 2 ? nil : real },
            create: { created += 1; return SymmetricKey(size: .bits256) },
            dataExists: { try VoiceTemplateStore.dataExists(in: dir) },
            sleep: { _ in })
        let next = VoiceTemplateStore(dir: dir, aead: VoiceAesGcmAead(key: { try guardian.get() }), accountId: "acct",
                                      dirSync: VoiceDirectorySyncs.none)
        XCTAssertNotNil(try next.load("c"))
        XCTAssertEqual(created, 0)
        XCTAssertEqual(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted(), files)
    }
}
