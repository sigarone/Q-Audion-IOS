import CryptoKit
import XCTest
@testable import QAudionEngine

/// URLProtocol stub for the device-approval calls: records method, path, query and body of every request.
final class ApprovalStubProtocol: URLProtocol {
    struct Recorded {
        let method: String
        let path: String
        let query: String
        let body: Data?
        let authorization: String?
    }

    static var handler: ((Recorded) -> (status: Int, body: String, headers: [String: String]))?
    static var recorded: [Recorded] = []

    static func reset() {
        handler = nil
        recorded = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: size)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            stream.close()
            body = collected
        }
        let item = Recorded(method: request.httpMethod ?? "", path: request.url?.path ?? "",
                            query: request.url?.query ?? "", body: body,
                            authorization: request.value(forHTTPHeaderField: "Authorization"))
        Self.recorded.append(item)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: -1))
            return
        }
        let answer = handler(item)
        // swiftlint:disable:next force_unwrapping
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil,
                                       headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class DeviceApprovalApiTests: XCTestCase {

    private let nonceHex = String(repeating: "ab", count: 32)

    override func tearDown() {
        ApprovalStubProtocol.reset()
        super.tearDown()
    }

    private func makeRest(token: String? = "tok") -> BCryptoRestClient {
        BCryptoRestClient(config: BackendConfig(serverUrl: "https://server.test", accessToken: token),
                          testURLProtocolClasses: [ApprovalStubProtocol.self])
    }

    private func json(_ body: Data?) -> [String: Any] {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        return object
    }

    // MARK: - Pending login (public)

    private func pendingApi() -> BCryptoPendingLoginApi { BCryptoPendingLoginApi(rest: makeRest(token: nil)) }

    func test_poll_pending() async throws {
        ApprovalStubProtocol.handler = { _ in (200, "{\"status\":\"pending\"}", [:]) }
        let result = try await pendingApi().poll(pendingId: "p-1", pollToken: "t-1")
        guard case .pending = result else { return XCTFail("\(result)") }
        let request = try XCTUnwrap(ApprovalStubProtocol.recorded.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v1/auth/login/pending")
        XCTAssertEqual(json(request.body)["pending_id"] as? String, "p-1")
        XCTAssertEqual(json(request.body)["poll_token"] as? String, "t-1")
        XCTAssertNil(request.authorization, "the waiting screen has no session")
    }

    func test_poll_approved_returnsThePairAndThePrompt() async throws {
        ApprovalStubProtocol.handler = { _ in
            (200, """
            {"access_token":"a","refresh_token":"r","expires_in":900,"token_type":"Bearer","device_id":"d-9",
             "user_id":"u-1","revoke_prompt":"disconnect_all"}
            """, [:])
        }
        let result = try await pendingApi().poll(pendingId: "p", pollToken: "t")
        guard case .approved(let login) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(login.credentials.deviceId, "d-9")
        XCTAssertEqual(login.credentials.accessToken, "a")
        XCTAssertEqual(login.revokePrompt, .disconnectAll)
    }

    func test_poll_finalAnswers() async throws {
        ApprovalStubProtocol.handler = { _ in (403, "{\"error\":\"denied\"}", [:]) }
        var result = try await pendingApi().poll(pendingId: "p", pollToken: "t")
        guard case .denied = result else { return XCTFail("\(result)") }
        ApprovalStubProtocol.handler = { _ in (410, "{\"error\":\"expired\"}", [:]) }
        result = try await pendingApi().poll(pendingId: "p", pollToken: "t")
        guard case .expired = result else { return XCTFail("\(result)") }
        ApprovalStubProtocol.handler = { _ in (404, "{}", [:]) }
        result = try await pendingApi().poll(pendingId: "p", pollToken: "t")
        guard case .expired = result else { return XCTFail("a gone entry reads as expired: \(result)") }
    }

    /// 401 "session revoked, sign in again": the approval cannot be redeemed. It is a final answer with its own
    /// reason, not a failure to retry (the next poll would only say "expired").
    func test_poll_401_isSessionRevoked() async throws {
        ApprovalStubProtocol.handler = { _ in (401, "{\"error\":\"session revoked, sign in again\"}", [:]) }
        let result = try await pendingApi().poll(pendingId: "p", pollToken: "t")
        guard case .sessionRevoked = result else { return XCTFail("\(result)") }
    }

    func test_poll_429_carriesRetryAfter() async throws {
        ApprovalStubProtocol.handler = { _ in (429, "{}", ["Retry-After": "7"]) }
        let result = try await pendingApi().poll(pendingId: "p", pollToken: "t")
        guard case .tooFast(let retryAfter) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(retryAfter, 7)
    }

    func test_poll_serverError_throws() async {
        ApprovalStubProtocol.handler = { _ in (500, "{}", [:]) }
        do {
            _ = try await pendingApi().poll(pendingId: "p", pollToken: "t")
            XCTFail("expected a throw")
        } catch BCryptoError.httpError(500) {
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_poll_approvedWithoutAUserId_isADecodingError() async {
        ApprovalStubProtocol.handler = { _ in (200, "{\"access_token\":\"opaque\",\"device_id\":\"d\"}", [:]) }
        do {
            _ = try await pendingApi().poll(pendingId: "p", pollToken: "t")
            XCTFail("expected a throw")
        } catch BCryptoError.decodingError {
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_recover_sendsTheChannel_andVerifySendsTheCode() async throws {
        ApprovalStubProtocol.handler = { _ in (200, "{}", [:]) }
        let api = pendingApi()
        try await api.requestRecoveryCode(pendingId: "p", pollToken: "t", channel: .sms)
        try await api.verifyRecoveryCode(pendingId: "p", pollToken: "t", code: "123456")
        let recorded = ApprovalStubProtocol.recorded
        XCTAssertEqual(recorded.map(\.path), ["/api/v1/auth/login/pending/recover",
                                              "/api/v1/auth/login/pending/recover/verify"])
        XCTAssertEqual(json(recorded[0].body)["channel"] as? String, "sms")
        XCTAssertEqual(json(recorded[1].body)["code"] as? String, "123456")
    }

    func test_recoveryErrors_areTold_apart() {
        func error(_ status: Int, _ body: String = "{}", retry: String? = nil) -> PendingLoginRecoveryError? {
            BCryptoPendingLoginApi.recoveryError(status: status, data: Data(body.utf8), retryAfter: retry)
        }
        XCTAssertNil(error(200))
        XCTAssertEqual(error(400, "{\"error\":\"invalid_code\"}"), .invalidCode)
        XCTAssertEqual(error(403), .invalidCode)
        XCTAssertEqual(error(403, "{\"error\":\"too_many_attempts\"}"), .tooManyAttempts)
        XCTAssertEqual(error(403, "{\"error\":\"denied\"}"), .denied)
        XCTAssertEqual(error(410), .expired)
        XCTAssertEqual(error(410, "{\"error\":\"expired\"}"), .expired, "the whole entry is over")
        XCTAssertEqual(error(410, "{\"error\":\"code expired or not found, request a new one\"}"), .codeExpired,
                       "only the code is gone: the entry may still be pending")
        XCTAssertEqual(error(401, "{\"error\":\"invalid code\"}"), .invalidCode)
        XCTAssertEqual(error(429, "{\"error\":\"too many attempts, request a new code\"}", retry: "30"), .tooManyAttempts)
        XCTAssertEqual(error(429, "{\"error\":\"rate limit exceeded\"}", retry: "30"), .rateLimited(retryAfter: 30))
        XCTAssertEqual(error(429, "{\"error\":\"code requested too soon\"}", retry: "30"), .rateLimited(retryAfter: 30))
        XCTAssertEqual(error(429, retry: "30"), .rateLimited(retryAfter: 30))
        XCTAssertEqual(error(409), .channelUnavailable)
        XCTAssertEqual(error(503), .server(status: 503))
    }

    // MARK: - Approving device

    private func approvalApi(seed: Data?, deviceId: String? = "dev-1") -> BCryptoDeviceApprovalApi {
        let rest = makeRest()
        let api = BCryptoDeviceApprovalApi()
        api.getRestClient = { rest }
        api.loadDeviceKeySeed = { seed }
        api.loadDeviceId = { deviceId }
        return api
    }

    private func challengeThen(_ status: Int, body: String = "{}") {
        let hex = nonceHex
        ApprovalStubProtocol.handler = { request in
            if request.method == "GET" {
                return (200, "{\"nonce_hex\":\"\(hex)\",\"server_id\":\"srv-1\",\"ttl\":60}", [:])
            }
            return (status, body, [:])
        }
    }

    func test_approve_signsTheApprovalBlobWithTheDeviceKey() async throws {
        let key = Curve25519.Signing.PrivateKey()
        challengeThen(200)
        let result = try await approvalApi(seed: key.rawRepresentation).approve(id: "pend-1", matchCode: "47")
        XCTAssertEqual(result, .done)

        let recorded = ApprovalStubProtocol.recorded
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded[0].path, "/api/v1/auth/device-challenge")
        XCTAssertEqual(recorded[0].query, "device_id=dev-1")
        XCTAssertEqual(recorded[1].method, "POST")
        XCTAssertEqual(recorded[1].path, "/api/v1/account/pending-logins/pend-1/approve")
        XCTAssertEqual(recorded[1].authorization, "Bearer tok")
        let body = json(recorded[1].body)
        XCTAssertEqual(body["match_code"] as? String, "47")
        XCTAssertEqual(body["nonce"] as? String, nonceHex)
        let sig = try XCTUnwrap(DeviceRenewBlob.hexDecode(try XCTUnwrap(body["sig"] as? String)))
        let blob = DeviceApprovalBlob.build(
            tag: "QAUDION-APPROVE-v1", serverId: "srv-1", pendingId: "pend-1", approverDeviceId: "dev-1",
            nonce: try XCTUnwrap(DeviceRenewBlob.hexDecode(nonceHex)))
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: blob))
    }

    func test_deny_usesItsOwnTag() async throws {
        let key = Curve25519.Signing.PrivateKey()
        challengeThen(200)
        let result = try await approvalApi(seed: key.rawRepresentation).deny(id: "pend-1")
        XCTAssertEqual(result, .done)
        let post = try XCTUnwrap(ApprovalStubProtocol.recorded.last)
        XCTAssertEqual(post.path, "/api/v1/account/pending-logins/pend-1/deny")
        XCTAssertNil(json(post.body)["match_code"])
        let sig = try XCTUnwrap(DeviceRenewBlob.hexDecode(try XCTUnwrap(json(post.body)["sig"] as? String)))
        let nonce = try XCTUnwrap(DeviceRenewBlob.hexDecode(nonceHex))
        let deny = DeviceApprovalBlob.build(tag: "QAUDION-DENY-v1", serverId: "srv-1", pendingId: "pend-1",
                                            approverDeviceId: "dev-1", nonce: nonce)
        let approve = DeviceApprovalBlob.build(tag: "QAUDION-APPROVE-v1", serverId: "srv-1", pendingId: "pend-1",
                                               approverDeviceId: "dev-1", nonce: nonce)
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: deny))
        XCTAssertFalse(key.publicKey.isValidSignature(sig, for: approve), "a deny signature is no approval")
    }

    func test_approve_statusMapping() async throws {
        let key = Curve25519.Signing.PrivateKey().rawRepresentation
        challengeThen(403, body: "{\"error\":\"wrong_code\"}")
        var result = try await approvalApi(seed: key).approve(id: "p", matchCode: "11")
        XCTAssertEqual(result, .wrongCode)
        challengeThen(409)
        result = try await approvalApi(seed: key).approve(id: "p", matchCode: "11")
        XCTAssertEqual(result, .alreadyResolved)
        challengeThen(410)
        result = try await approvalApi(seed: key).approve(id: "p", matchCode: "11")
        XCTAssertEqual(result, .gone)
    }

    /// The server answers 403 `device_key_required` before it looks at the number, and the entry stays pending:
    /// that is not "wrong number, entry closed".
    func test_approve_403DeviceKeyRequired_isAFailure_notAWrongCode() async throws {
        let key = Curve25519.Signing.PrivateKey().rawRepresentation
        for body in ["{\"error\":\"device_key_required\"}", "{}", ""] {
            challengeThen(403, body: body)
            do {
                let result = try await approvalApi(seed: key).approve(id: "p", matchCode: "11")
                XCTFail("expected a throw, got \(result)")
            } catch BCryptoError.httpError(403) {
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    func test_deny_403_isAFailure_notAWrongCode() async throws {
        let key = Curve25519.Signing.PrivateKey().rawRepresentation
        challengeThen(403)
        do {
            _ = try await approvalApi(seed: key).deny(id: "p")
            XCTFail("expected a throw")
        } catch BCryptoError.httpError(403) {
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_approve_withoutAKeyOrDeviceId_sendsNothing() async {
        challengeThen(200)
        do {
            _ = try await approvalApi(seed: nil).approve(id: "p", matchCode: "11")
            XCTFail("expected a throw")
        } catch DeviceApprovalError.notReady {
        } catch {
            XCTFail("\(error)")
        }
        do {
            _ = try await approvalApi(seed: Data(repeating: 1, count: 32), deviceId: nil).approve(id: "p", matchCode: "11")
            XCTFail("expected a throw")
        } catch DeviceApprovalError.notReady {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(ApprovalStubProtocol.recorded.isEmpty)
    }

    func test_approve_malformedChallenge_sendsNothing() async {
        ApprovalStubProtocol.handler = { _ in (200, "{\"nonce_hex\":\"zz\",\"server_id\":\"s\"}", [:]) }
        do {
            _ = try await approvalApi(seed: Data(repeating: 1, count: 32)).approve(id: "p", matchCode: "11")
            XCTFail("expected a throw")
        } catch DeviceApprovalError.malformedChallenge {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(ApprovalStubProtocol.recorded.count, 1, "only the challenge was fetched")
    }

    /// The wire of cmd/bcrypto-lite/revoke_others.go: body {requesting_device_id, nonce_hex, epoch_ms,
    /// signature_hex}, signature over auth.BuildRevokeOthersBlob (tag, device, "*", nonce, epoch BE u64), and the
    /// answer is the fresh session of this device.
    func test_revokeOthers_matchesTheServerWire_andReturnsTheFreshSession() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let hex = nonceHex
        ApprovalStubProtocol.handler = { request in
            if request.method == "GET" {
                return (200, "{\"nonce_hex\":\"\(hex)\",\"server_id\":\"srv-1\",\"ttl\":60}", [:])
            }
            return (200, """
            {"access_token":"new-access","refresh_token":"new-refresh","expires_in":900,"token_type":"Bearer",
             "device_id":"dev-1","revoked_at":1793786400000}
            """, [:])
        }
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let fresh = try await approvalApi(seed: key.rawRepresentation).revokeOthers()
        XCTAssertEqual(fresh.accessToken, "new-access")
        XCTAssertEqual(fresh.refreshToken, "new-refresh")
        XCTAssertEqual(fresh.deviceId, "dev-1")

        let post = try XCTUnwrap(ApprovalStubProtocol.recorded.last)
        XCTAssertEqual(post.method, "POST")
        XCTAssertEqual(post.path, "/api/v1/account/devices/revoke-others")
        XCTAssertEqual(post.authorization, "Bearer tok")
        let body = json(post.body)
        XCTAssertEqual(Set(body.keys), ["requesting_device_id", "nonce_hex", "epoch_ms", "signature_hex"],
                       "the server answers 400 for a missing epoch_ms / nonce_hex / signature_hex")
        XCTAssertEqual(body["requesting_device_id"] as? String, "dev-1")
        XCTAssertEqual(body["nonce_hex"] as? String, nonceHex)
        let epoch = try XCTUnwrap((body["epoch_ms"] as? NSNumber)?.int64Value)
        XCTAssertGreaterThanOrEqual(epoch, before)
        XCTAssertLessThanOrEqual(epoch, Int64(Date().timeIntervalSince1970 * 1000))

        // The blob, laid out by hand like the Go builder does it.
        var expected = Data("QAUDION-REVOKE-OTHERS-v1".utf8)
        expected.append(0)
        expected.append(Data("dev-1".utf8))
        expected.append(0)
        expected.append(Data("*".utf8))
        expected.append(0)
        expected.append(try XCTUnwrap(DeviceRenewBlob.hexDecode(nonceHex)))
        expected.append(0)
        withUnsafeBytes(of: UInt64(epoch).bigEndian) { expected.append(contentsOf: $0) }
        let sig = try XCTUnwrap(DeviceRenewBlob.hexDecode(try XCTUnwrap(body["signature_hex"] as? String)))
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: expected))
    }

    func test_revokeOthers_answerWithoutATokenPair_isMalformed() async {
        challengeThen(200, body: "{\"device_id\":\"dev-1\"}")
        do {
            _ = try await approvalApi(seed: Curve25519.Signing.PrivateKey().rawRepresentation).revokeOthers()
            XCTFail("expected a throw")
        } catch DeviceApprovalError.malformedAnswer {
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_revokeOthers_deviceKeyRequired_throws() async {
        challengeThen(403, body: "{\"error\":\"device_key_required\"}")
        do {
            _ = try await approvalApi(seed: Curve25519.Signing.PrivateKey().rawRepresentation).revokeOthers()
            XCTFail("expected a throw")
        } catch BCryptoError.httpError(403) {
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_listDevices_readsTheContract() async throws {
        ApprovalStubProtocol.handler = { _ in
            (200, """
            {"devices":[{"device_id":"d-1","label":"iPhone di Ada","platform":"ios","last_seen_ms":1793786400000,"current":true},
                        {"device_id":"d-2","label":"Pixel","platform":"android","last_seen_ms":1793700000000,"current":false},
                        {"label":"no id"}]}
            """, [:])
        }
        let list = try await approvalApi(seed: nil).listDevices()
        XCTAssertEqual(list.map(\.deviceId), ["d-1", "d-2"])
        XCTAssertEqual(list.map(\.current), [true, false])
        XCTAssertEqual(list[1].label, "Pixel")
        XCTAssertEqual(list[1].platform, "android")
        XCTAssertNotNil(list[0].lastSeen)
        let request = try XCTUnwrap(ApprovalStubProtocol.recorded.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v1/account/devices")
        XCTAssertEqual(request.authorization, "Bearer tok")
    }

    func test_listDevices_failureAndMalformedAnswerThrow() async {
        ApprovalStubProtocol.handler = { _ in (500, "{}", [:]) }
        do {
            _ = try await approvalApi(seed: nil).listDevices()
            XCTFail("expected a throw")
        } catch BCryptoError.httpError(500) {
        } catch {
            XCTFail("\(error)")
        }
        ApprovalStubProtocol.handler = { _ in (200, "[]", [:]) }
        do {
            _ = try await approvalApi(seed: nil).listDevices()
            XCTFail("expected a throw")
        } catch BCryptoError.decodingError {
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_revokeDevice_deletesThatDevice() async throws {
        ApprovalStubProtocol.handler = { _ in (200, "{}", [:]) }
        try await approvalApi(seed: nil).revokeDevice(id: "d-2")
        let request = try XCTUnwrap(ApprovalStubProtocol.recorded.first)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.path, "/api/v1/devices/d-2")
        XCTAssertEqual(request.authorization, "Bearer tok")
    }

    func test_revokeDevice_ownDevice_isRefusedByTheServer() async {
        ApprovalStubProtocol.handler = { _ in (400, "{\"error\":\"current_device\"}", [:]) }
        do {
            try await approvalApi(seed: nil).revokeDevice(id: "dev-1")
            XCTFail("expected a throw")
        } catch BCryptoError.httpError(400) {
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_fetchPending_readsTheListAndKeepsChoicesAsText() async throws {
        ApprovalStubProtocol.handler = { _ in
            (200, """
            [{"id":"p-1","device_name":"iPhone di Ada","platform":"ios","area":"Italia, rete mobile",
              "created_at":"2026-11-04T10:00:00Z","choices":[12,47,"83"],"extra":1},
             {"device_name":"no id"}]
            """, [:])
        }
        let list = try await approvalApi(seed: nil).fetchPending()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, "p-1")
        XCTAssertEqual(list.first?.choices, ["12", "47", "83"])
        XCTAssertEqual(list.first?.area, "Italia, rete mobile")
        XCTAssertEqual(ApprovalStubProtocol.recorded.first?.path, "/api/v1/account/pending-logins")
    }

    func test_fetchPending_404_isEmpty() async throws {
        ApprovalStubProtocol.handler = { _ in (404, "{}", [:]) }
        let list = try await approvalApi(seed: nil).fetchPending()
        XCTAssertTrue(list.isEmpty)
    }

    func test_actionPath_escapesTheId() {
        XCTAssertEqual(BCryptoDeviceApprovalApi.actionPath(id: "a/b?c", action: "approve"),
                       "/api/v1/account/pending-logins/a%2Fb%3Fc/approve")
    }

    // MARK: - Recovery contacts

    private func contactsApi() -> BCryptoRecoveryContactsApi {
        let rest = makeRest()
        let api = BCryptoRecoveryContactsApi()
        api.getRestClient = { rest }
        api.loadDeviceKeySeed = { Curve25519.Signing.PrivateKey().rawRepresentation }
        api.loadDeviceId = { "dev-1" }
        return api
    }

    func test_recoveryContacts_fetchReadsMaskedHintsOnly() async throws {
        ApprovalStubProtocol.handler = { _ in
            (200, "{\"email_masked\":\"m***@g***.com\",\"email_verified\":true,\"phone_masked\":\"\",\"phone_verified\":false}", [:])
        }
        let status = try await contactsApi().fetch()
        XCTAssertEqual(status, RecoveryContactsStatus(emailMasked: "m***@g***.com", emailVerified: true,
                                                      phoneMasked: nil, phoneVerified: false))
        XCTAssertEqual(ApprovalStubProtocol.recorded.first?.path, "/api/v1/account/recovery-contacts")
    }

    func test_recoveryContacts_calls() async throws {
        let hex = nonceHex
        ApprovalStubProtocol.handler = { request in
            request.method == "GET"
                ? (200, "{\"nonce_hex\":\"\(hex)\",\"server_id\":\"srv-1\",\"ttl\":60}", [:])
                : (200, "{}", [:])
        }
        let api = contactsApi()
        try await api.start(kind: .email, value: "a@b.it")
        try await api.start(kind: .phone, value: "+393331112233")
        try await api.verify(kind: .email, code: "123456")
        try await api.remove(kind: .phone)
        let recorded = ApprovalStubProtocol.recorded
        XCTAssertEqual(recorded.map { "\($0.method) \($0.path)" }, [
            "GET /api/v1/auth/device-challenge",
            "POST /api/v1/account/recovery-contacts/email",
            "GET /api/v1/auth/device-challenge",
            "POST /api/v1/account/recovery-contacts/phone",
            "POST /api/v1/account/recovery-contacts/email/verify",
            "GET /api/v1/auth/device-challenge",
            "DELETE /api/v1/account/recovery-contacts/phone",
        ])
        XCTAssertEqual(json(recorded[1].body)["email"] as? String, "a@b.it")
        XCTAssertEqual(json(recorded[3].body)["phone_number"] as? String, "+393331112233")
        XCTAssertEqual(json(recorded[4].body)["code"] as? String, "123456")
        XCTAssertNotNil(json(recorded[6].body)["signature_hex"], "the DELETE carries its signature in the body")
    }

    /// A wrong verification code is a 401 `invalid code`: the person's mistake. It must reach the model as a
    /// wrong code, with no token refresh in between (the refresh budget is rate limited).
    func test_recoveryContacts_wrongCode_isInvalidCode_withoutARefresh() async {
        ApprovalStubProtocol.handler = { _ in (401, "{\"error\":\"invalid code\"}", [:]) }
        do {
            try await contactsApi().verify(kind: .email, code: "123456")
            XCTFail("expected a throw")
        } catch RecoveryContactError.invalidCode {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(ApprovalStubProtocol.recorded.map(\.path), ["/api/v1/account/recovery-contacts/email/verify"],
                       "one request: no refresh and no retry")
    }

    func test_recoveryContacts_otherUnauthorized_isARejectedSession() async {
        ApprovalStubProtocol.handler = { _ in (401, "{\"error\":\"unauthorized\"}", [:]) }
        do {
            try await contactsApi().verify(kind: .email, code: "123456")
            XCTFail("expected a throw")
        } catch BCryptoError.unauthorized {
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_recoveryContacts_statusMapping() {
        XCTAssertEqual(BCryptoRecoveryContactsApi.map(status: 400, codeFailure: .invalidValue), .invalidValue)
        XCTAssertEqual(BCryptoRecoveryContactsApi.map(status: 403, codeFailure: .invalidCode), .invalidCode)
        XCTAssertEqual(BCryptoRecoveryContactsApi.map(status: 429, codeFailure: .invalidCode), .rateLimited)
        XCTAssertEqual(BCryptoRecoveryContactsApi.map(status: 500, codeFailure: .invalidCode), .failed)
    }
}
