import XCTest
@testable import QAudionEngine

final class OtaDownloadManagerTests: XCTestCase {

    // MARK: - OtaDownloadManager without server

    func testCheckForUpdateWithNoServerReturnsNil() async throws {
        let manager = OtaDownloadManager(restClient: nil)
        let result = try await manager.checkForUpdate(currentVersion: "1.0.0")
        XCTAssertNil(result, "checkForUpdate should return nil when no rest client is configured")
    }

    func testDownloadModelWithNoServerThrows() async {
        let manager = OtaDownloadManager(restClient: nil)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_model.bin")
        do {
            try await manager.downloadModel(name: "test", to: tempURL)
            XCTFail("downloadModel should throw when no rest client is configured")
        } catch {
            // Expect OtaError.noServer
            XCTAssertTrue(error is OtaError, "Error should be OtaError")
        }
    }

    // MARK: - OtaDownloadManager default init

    func testDefaultInitHasNoRestClient() async throws {
        let manager = OtaDownloadManager()
        let result = try await manager.checkForUpdate(currentVersion: "2.0.0")
        XCTAssertNil(result, "Default init with nil restClient should return nil")
    }

    // MARK: - OtaUpdateChecker lifecycle

    func testStartAndStopCheckingDoesNotCrash() {
        let manager = OtaDownloadManager()
        let checker = OtaUpdateChecker(downloadManager: manager)
        checker.startChecking(currentVersion: "1.0.0")
        checker.stopChecking()
        // Should not crash -- verifying clean start/stop lifecycle
    }

    func testStopCheckingWithoutStartDoesNotCrash() {
        let manager = OtaDownloadManager()
        let checker = OtaUpdateChecker(downloadManager: manager)
        checker.stopChecking()
        // Should not crash
    }

    func testMultipleStartStopCycles() {
        let manager = OtaDownloadManager()
        let checker = OtaUpdateChecker(downloadManager: manager)
        for _ in 0..<5 {
            checker.startChecking(currentVersion: "1.0.0")
            checker.stopChecking()
        }
        // Should not crash or leak timers
    }

    func testCallbackAssignment() {
        let manager = OtaDownloadManager()
        let checker = OtaUpdateChecker(downloadManager: manager)

        var callbackInvoked = false
        checker.onUpdateAvailable = { _ in
            callbackInvoked = true
        }

        // With nil rest client, the callback should never fire,
        // but assigning it should not crash
        checker.startChecking(currentVersion: "1.0.0")
        checker.stopChecking()
        // Cannot assert callbackInvoked == false reliably due to async,
        // but the assignment itself must not crash
        _ = callbackInvoked
    }

    // MARK: - OtaError conformance

    func testOtaErrorIsError() {
        let error: Error = OtaError.noServer
        XCTAssertNotNil(error)
    }
}
