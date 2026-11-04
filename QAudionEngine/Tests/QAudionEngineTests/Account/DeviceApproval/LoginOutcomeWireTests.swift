import XCTest
@testable import QAudionEngine

private final class OutcomeInstallIdStorage: InstallIdStorage {
    var value: String? = "0b6f3c1e-2d4a-4b8e-9c10-5a7e8f9d0a1b"
    func read() -> String? { value }
    func write(_ value: String) { self.value = value }
    func delete() { value = nil }
}

/// The two sign-ins that may answer "approval required": wire shape and the three kinds of answer.
final class LoginOutcomeWireTests: XCTestCase {

    override func tearDown() {
        ApprovalStubProtocol.reset()
        super.tearDown()
    }

    private func makeApi() -> BCryptoAccountApiImpl {
        let rest = BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local"),
                                     testURLProtocolClasses: [ApprovalStubProtocol.self])
        return BCryptoAccountApiImpl(rest: rest, installId: InstallIdStore(storage: OutcomeInstallIdStorage()))
    }

    private let ticketBody = """
    {"status":"approval_required","pending_id":"p-1","poll_token":"t-1","match_code":"47",
     "expires_at":"2026-11-04T10:10:00Z","short_code":"ABCD2345","recovery":{"email":true,"sms":true}}
    """

    private let sessionBody = #"{"user_id":"u","device_id":"d","access_token":"a","refresh_token":"r","expires_in":900}"#

    func test_extensionLogin_202_isThePendingState_andTheBodyKeepsInstallId() async throws {
        let answer = ticketBody
        ApprovalStubProtocol.handler = { _ in (202, answer, [:]) }
        let outcome = try await makeApi().loginWithExtensionOutcome(extension: 1234, password: "p", deviceName: "d")
        guard case .approvalRequired(let ticket) = outcome else { return XCTFail("expected a pending state") }
        XCTAssertEqual(ticket.pendingId, "p-1")
        let request = try XCTUnwrap(ApprovalStubProtocol.recorded.first)
        XCTAssertEqual(request.path, "/api/v1/auth/login/extension")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(body["install_id"] as? String, "0b6f3c1e-2d4a-4b8e-9c10-5a7e8f9d0a1b")
        XCTAssertEqual(body["extension"] as? Int, 1234)
        XCTAssertEqual(body["device_name"] as? String, "d")
    }

    func test_phoneLogin_202_isThePendingState() async throws {
        let answer = ticketBody
        ApprovalStubProtocol.handler = { _ in (202, answer, [:]) }
        let outcome = try await makeApi().loginOutcome(phoneHash: "h", password: "p", deviceName: "d")
        guard case .approvalRequired = outcome else { return XCTFail("expected a pending state") }
        XCTAssertEqual(ApprovalStubProtocol.recorded.first?.path, "/api/v1/auth/login")
    }

    func test_200_isASessionAsBefore() async throws {
        let answer = sessionBody
        ApprovalStubProtocol.handler = { _ in (200, answer, [:]) }
        let outcome = try await makeApi().loginWithExtensionOutcome(extension: 1, password: "p", deviceName: "d")
        guard case .credentials(let creds) = outcome else { return XCTFail("expected a session") }
        XCTAssertEqual(creds.userId, "u")
        XCTAssertEqual(creds.accessToken, "a")
    }

    func test_wrongPassword_is401Unauthorized_withoutARefreshAttempt() async {
        ApprovalStubProtocol.handler = { _ in (401, "{\"error\":\"invalid credentials\"}", [:]) }
        do {
            _ = try await makeApi().loginWithExtensionOutcome(extension: 1, password: "p", deviceName: "d")
            XCTFail("expected a throw")
        } catch BCryptoError.unauthorized {
            XCTAssertEqual(ApprovalStubProtocol.recorded.count, 1, "one request: nothing was retried")
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_tooManyPendingOrTooManyTries_is429_asBefore() async {
        ApprovalStubProtocol.handler = { _ in (429, "{}", ["Retry-After": "30"]) }
        do {
            _ = try await makeApi().loginWithExtensionOutcome(extension: 1, password: "p", deviceName: "d")
            XCTFail("expected a throw")
        } catch BCryptoError.httpError(429) {
        } catch {
            XCTFail("\(error)")
        }
    }
}
