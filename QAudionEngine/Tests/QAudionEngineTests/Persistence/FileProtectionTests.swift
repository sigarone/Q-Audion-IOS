import Foundation
import XCTest
@testable import QAudionEngine

/// The helpers must create, write and tolerate repeats on every host. The class itself is not asserted: the simulator
/// and the macOS test host do not report Data Protection classes reliably (checked on a device instead).
final class FileProtectionTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fileprotection-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testPrepareDirectoryCreatesAndIsIdempotent() {
        let dir = tempDir().appendingPathComponent("a/b", isDirectory: true)
        XCTAssertTrue(FileProtection.prepareDirectory(dir))
        XCTAssertTrue(FileProtection.prepareDirectory(dir))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testWriteOptionsProduceAReadableFile() throws {
        let dir = tempDir()
        XCTAssertTrue(FileProtection.prepareDirectory(dir))
        let atomic = dir.appendingPathComponent("atomic.bin")
        let plain = dir.appendingPathComponent("plain.bin")
        try Data([1, 2, 3]).write(to: atomic, options: FileProtection.atomicWriteOptions)
        try Data([4, 5]).write(to: plain, options: FileProtection.plainWriteOptions)
        XCTAssertEqual(try Data(contentsOf: atomic), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: plain), Data([4, 5]))
    }

    func testCreateFileWithAttributesAndApply() throws {
        let dir = tempDir()
        FileProtection.prepareDirectory(dir)
        let file = dir.appendingPathComponent("created.bin")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: file.path, contents: Data([9]), attributes: FileProtection.lockedAccessAttributes))
        // Applying to an existing file and to a missing one must not trap.
        XCTAssertTrue(FileProtection.apply(to: file))
        XCTAssertFalse(FileProtection.apply(to: dir.appendingPathComponent("missing.bin")))
        XCTAssertEqual(try Data(contentsOf: file), Data([9]))
    }

    func testDatabaseFilesHelperToleratesMissingSidecars() throws {
        let dir = tempDir()
        FileProtection.prepareDirectory(dir)
        let db = dir.appendingPathComponent("x.sqlite")
        try Data([0]).write(to: db)
        FileProtection.applyToDatabaseFiles(atPath: db.path)
        FileProtection.applyToDatabaseFiles(atPath: dir.appendingPathComponent("none.sqlite").path)
    }
}
