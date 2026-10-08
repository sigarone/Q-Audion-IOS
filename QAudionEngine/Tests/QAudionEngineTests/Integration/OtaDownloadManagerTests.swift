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

    // MARK: - downloadModel error mapping

    /// With no rest client the failure is specifically `.noServer` (the
    /// existing test above only checks the error TYPE).
    func testDownloadModelWithNoServerThrowsNoServer() async {
        let manager = OtaDownloadManager(restClient: nil)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ota_no_server.bin")
        do {
            try await manager.downloadModel(name: "test", to: tempURL)
            XCTFail("downloadModel should throw when no rest client is configured")
        } catch OtaError.noServer {
            // expected
        } catch {
            XCTFail("expected OtaError.noServer, got \(error)")
        }
    }

    /// A syntactically invalid model name is refused with `.invalidModelName`
    /// BEFORE any request leaves the device (path-traversal guard), even though
    /// a rest client is configured.
    func testDownloadModelInvalidNameThrowsInvalidModelNameWithoutRequest() async {
        OtaNoRequestURLProtocol.requestCount = 0
        let client = BCryptoRestClient(
            config: BackendConfig(serverUrl: "https://test.local"),
            testURLProtocolClasses: [OtaNoRequestURLProtocol.self]
        )
        let manager = OtaDownloadManager(restClient: client)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ota_invalid_name.bin")
        let badNames = ["", "..", "../secret", "a/b", "a\\b", "a b", "a%2Fb", String(repeating: "a", count: 129)]
        for name in badNames {
            do {
                try await manager.downloadModel(name: name, to: tempURL)
                XCTFail("downloadModel accepted invalid name '\(name)'")
            } catch OtaError.invalidModelName {
                // expected
            } catch {
                XCTFail("expected OtaError.invalidModelName for '\(name)', got \(error)")
            }
        }
        XCTAssertEqual(OtaNoRequestURLProtocol.requestCount, 0, "no network request may be made for an invalid name")
    }

    // MARK: - isValidModelName allow-list

    func testIsValidModelNameAcceptsPlainFileNames() {
        let valid = ["aasist_raw_small_distill_int8.onnx", "model-1.0", "A_b-c.d", "x", String(repeating: "a", count: 128)]
        for name in valid {
            XCTAssertTrue(OtaDownloadManager.isValidModelName(name), "'\(name)' should be accepted")
        }
    }

    func testIsValidModelNameRejectsTraversalSeparatorsAndOddCharacters() {
        let invalid = ["", "..", "a..b", "../x", "a/b", "a\\b", "a b", "a%20b", "caf\u{00E9}", String(repeating: "a", count: 129)]
        for name in invalid {
            XCTAssertFalse(OtaDownloadManager.isValidModelName(name), "'\(name)' should be rejected")
        }
    }
}

/// Counts requests instead of serving them: proves the name guard fires
/// before the REST client is ever used.
private final class OtaNoRequestURLProtocol: URLProtocol {
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
