import XCTest
@testable import QAudionApp
import QAudionEngine

/// The kept copy of a held file survives a restart and is removed when it is no longer needed, and the user-choice store only
/// approves what the user answered for.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-ci.yml`.
@MainActor
final class BluetoothHeldFilesTests: XCTestCase {

    private func sampleFile(_ name: String = "note.txt") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("held-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("hello".utf8).write(to: url)
        return url
    }

    func testAHeldDocumentIsKeptOnDiskAndFoundAgain() throws {
        let row = UUID()
        defer { BluetoothHeldFiles.remove(rowId: row) }
        let kept = try XCTUnwrap(BluetoothHeldFiles.keep(sourceURL: sampleFile(), rowId: row))
        XCTAssertEqual(try Data(contentsOf: kept), Data("hello".utf8))
        // A new process finds it by the row id, with no in-memory state.
        XCTAssertEqual(BluetoothHeldFiles.heldURL(rowId: row)?.lastPathComponent, "note.txt")
        let values = try kept.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testSweepRemovesOrphansAndKeepsHeldRows() throws {
        let held = UUID()
        let orphan = UUID()
        defer {
            BluetoothHeldFiles.remove(rowId: held)
            BluetoothHeldFiles.remove(rowId: orphan)
        }
        _ = BluetoothHeldFiles.keep(sourceURL: try sampleFile(), rowId: held)
        _ = BluetoothHeldFiles.keep(sourceURL: try sampleFile(), rowId: orphan)
        BluetoothHeldFiles.sweepOrphans(heldRowIds: [held])
        XCTAssertNotNil(BluetoothHeldFiles.heldURL(rowId: held))
        XCTAssertNil(BluetoothHeldFiles.heldURL(rowId: orphan))
    }

    func testASweepDuringAnUploadLeavesTheFileAndTheDirectoryIsGoneAfterwards() throws {
        let row = UUID()
        _ = BluetoothHeldFiles.keep(sourceURL: try sampleFile(), rowId: row)
        BluetoothHeldFiles.beginUse(rowId: row)
        // The hold was cleared before the upload started: the row is not held any more, and a sweep runs meanwhile.
        BluetoothHeldFiles.sweepOrphans(heldRowIds: [])
        XCTAssertNotNil(BluetoothHeldFiles.heldURL(rowId: row))
        XCTAssertTrue(BluetoothHeldFiles.isInUse(rowId: row))
        // The upload ends: the id leaves the set and the directory goes.
        BluetoothHeldFiles.finish(rowId: row)
        XCTAssertNil(BluetoothHeldFiles.heldURL(rowId: row))
        XCTAssertFalse(BluetoothHeldFiles.isInUse(rowId: row))
    }

    func testAFailedUploadKeepsItsCopySoRetryStillHasTheFile() throws {
        let oldRow = UUID()
        let failedRow = UUID()
        defer {
            BluetoothHeldFiles.remove(rowId: oldRow)
            BluetoothHeldFiles.remove(rowId: failedRow)
        }
        _ = BluetoothHeldFiles.keep(sourceURL: try sampleFile(), rowId: oldRow)
        BluetoothHeldFiles.beginUse(rowId: oldRow)
        // The upload fails for good: the id leaves the in-use set, the copy moves to the failed row, which stays retryable.
        BluetoothHeldFiles.endUse(rowId: oldRow)
        let moved = try XCTUnwrap(BluetoothHeldFiles.adopt(from: oldRow, to: failedRow))
        // A sweep runs while the failed row exists and is retryable.
        BluetoothHeldFiles.sweepOrphans(heldRowIds: [failedRow])
        // Retry finds the file.
        XCTAssertEqual(BluetoothHeldFiles.heldURL(rowId: failedRow)?.lastPathComponent, "note.txt")
        XCTAssertEqual(try Data(contentsOf: moved), Data("hello".utf8))
        // Only a successful send removes it.
        BluetoothHeldFiles.finish(rowId: failedRow)
        XCTAssertNil(BluetoothHeldFiles.heldURL(rowId: failedRow))
    }

    func testRemoveDeletesTheCopyAfterTheSend() throws {
        let row = UUID()
        _ = BluetoothHeldFiles.keep(sourceURL: try sampleFile(), rowId: row)
        BluetoothHeldFiles.remove(rowId: row)
        XCTAssertNil(BluetoothHeldFiles.heldURL(rowId: row))
    }

    func testOnlyAnAnsweredMessageIsApproved() {
        let suite = UserDefaults(suiteName: "test.approvals.\(UUID().uuidString)")!
        let store = UserNetworkApprovalStore(defaults: suite)
        let id = UUID().uuidString
        XCTAssertFalse(store.isApproved(messageId: id))
        store.approve(messageId: id)
        XCTAssertTrue(store.isApproved(messageId: id))
        XCTAssertFalse(store.isApproved(messageId: UUID().uuidString))
    }
}
