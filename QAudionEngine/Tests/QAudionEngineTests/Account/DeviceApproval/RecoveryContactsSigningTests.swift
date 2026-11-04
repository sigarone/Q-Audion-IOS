import CryptoKit
import XCTest
@testable import QAudionEngine

/// Signed recovery-contact calls (server `auth.BuildRecoveryContactBlob`) and the cleaning of the untrusted
/// device name / platform of a pending login.
final class RecoveryContactsSigningTests: XCTestCase {

    private let nonceHex = String(repeating: "cd", count: 32)

    override func tearDown() {
        ApprovalStubProtocol.reset()
        super.tearDown()
    }

    private func json(_ body: Data?) -> [String: Any] {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        return object
    }

    private func makeApi(seed: Data?, deviceId: String? = "dev-1",
                         refresher: BCryptoRestClient.TokenRefresher? = nil,
                         published: (() -> Void)? = nil) -> BCryptoRecoveryContactsApi {
        let rest = BCryptoRestClient(
            config: BackendConfig(serverUrl: "https://server.test", accessToken: "tok", refreshToken: "ref"),
            testURLProtocolClasses: [ApprovalStubProtocol.self])
        // A coordinator of its own: the process-wide one keeps a cooldown between tests.
        rest.authCoordinator = AuthRefreshCoordinator()
        if let refresher { rest.setTokenRefresher(refresher) }
        let api = BCryptoRecoveryContactsApi()
        api.getRestClient = { rest }
        api.loadDeviceKeySeed = { seed }
        api.loadDeviceId = { deviceId }
        api.ensureDeviceKeyPublished = { published?() }
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

    private func blob(_ body: [String: Any], kind: RecoveryContactKind, value: String?) throws -> Data {
        let epoch = try XCTUnwrap((body["epoch_ms"] as? NSNumber)?.int64Value)
        return RecoveryContactBlob.build(
            deviceId: "dev-1", kind: kind, value: value,
            nonce: try XCTUnwrap(DeviceRenewBlob.hexDecode(nonceHex)), epochMs: UInt64(epoch))
    }

    // MARK: - Blob

    /// Known-answer vectors from the server (`TestBuildRecoveryContactBlob_KAT`).
    func test_blob_matchesTheServerKnownAnswers() {
        let nonce = Data((0..<32).map { UInt8($0) })
        let epoch: UInt64 = 1_767_225_600_000
        let add = RecoveryContactBlob.build(deviceId: "dev-0123", kind: .email, value: "maria@example.com",
                                            nonce: nonce, epochMs: epoch)
        XCTAssertEqual(DeviceRenewBlob.hexEncode(add),
                       "51415544494f4e2d5245434f564552592d434f4e544143542d7631006465762d3031323300656d61696c003130656630346135613161636438316431386130633631666464333534613036336461303732323337323061316438373630616135633261666135653865653000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f000000019b76daa800")
        let remove = RecoveryContactBlob.build(deviceId: "dev-0123", kind: .phone, value: nil, nonce: nonce, epochMs: epoch)
        XCTAssertEqual(DeviceRenewBlob.hexEncode(remove),
                       "51415544494f4e2d5245434f564552592d434f4e544143542d7631006465762d303132330070686f6e650000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f000000019b76daa800")
    }

    // MARK: - Calls

    func test_start_publishesTheKey_thenSignsTheValueWithTheDeviceKey() async throws {
        let key = Curve25519.Signing.PrivateKey()
        challengeThen(200)
        var publishedBeforeAnyRequest = false
        let api = makeApi(seed: key.rawRepresentation) {
            publishedBeforeAnyRequest = ApprovalStubProtocol.recorded.isEmpty
        }
        try await api.start(kind: .email, value: "  Maria@Example.com ")
        XCTAssertTrue(publishedBeforeAnyRequest, "the device key is published before the challenge is read")

        let recorded = ApprovalStubProtocol.recorded
        XCTAssertEqual(recorded.map { "\($0.method) \($0.path)" }, [
            "GET /api/v1/auth/device-challenge", "POST /api/v1/account/recovery-contacts/email",
        ])
        let body = json(recorded[1].body)
        XCTAssertEqual(body["email"] as? String, "Maria@Example.com", "trimmed, not lowercased")
        XCTAssertEqual(body["requesting_device_id"] as? String, "dev-1")
        XCTAssertEqual(body["nonce_hex"] as? String, nonceHex)
        let sig = try XCTUnwrap(DeviceRenewBlob.hexDecode(try XCTUnwrap(body["signature_hex"] as? String)))
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: try blob(body, kind: .email, value: "Maria@Example.com")))
        XCTAssertFalse(key.publicKey.isValidSignature(sig, for: try blob(body, kind: .email, value: "maria@example.com")),
                       "the hash is over the value exactly as sent")
        XCTAssertFalse(key.publicKey.isValidSignature(sig, for: try blob(body, kind: .phone, value: "Maria@Example.com")),
                       "a signature made for another kind is no signature")
    }

    func test_startPhone_keepsThePlus_andUsesPhoneNumber() async throws {
        let key = Curve25519.Signing.PrivateKey()
        challengeThen(200)
        try await makeApi(seed: key.rawRepresentation).start(kind: .phone, value: "+393331112233")
        let post = try XCTUnwrap(ApprovalStubProtocol.recorded.last)
        XCTAssertEqual(post.path, "/api/v1/account/recovery-contacts/phone")
        let body = json(post.body)
        XCTAssertEqual(body["phone_number"] as? String, "+393331112233")
        let sig = try XCTUnwrap(DeviceRenewBlob.hexDecode(try XCTUnwrap(body["signature_hex"] as? String)))
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: try blob(body, kind: .phone, value: "+393331112233")))
    }

    func test_remove_isADeleteWithTheSignatureInTheBody_andAnEmptyValueHash() async throws {
        let key = Curve25519.Signing.PrivateKey()
        challengeThen(200)
        try await makeApi(seed: key.rawRepresentation).remove(kind: .phone)
        let delete = try XCTUnwrap(ApprovalStubProtocol.recorded.last)
        XCTAssertEqual(delete.method, "DELETE")
        XCTAssertEqual(delete.path, "/api/v1/account/recovery-contacts/phone")
        let body = json(delete.body)
        XCTAssertEqual(body["requesting_device_id"] as? String, "dev-1")
        let sig = try XCTUnwrap(DeviceRenewBlob.hexDecode(try XCTUnwrap(body["signature_hex"] as? String)))
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: try blob(body, kind: .phone, value: nil)))
        XCTAssertFalse(key.publicKey.isValidSignature(sig, for: try blob(body, kind: .email, value: nil)),
                       "a remove of the phone cannot be replayed on the email")
    }

    func test_verify_staysUnsigned() async throws {
        ApprovalStubProtocol.handler = { _ in (200, "{}", [:]) }
        try await makeApi(seed: Curve25519.Signing.PrivateKey().rawRepresentation).verify(kind: .email, code: "123456")
        XCTAssertEqual(ApprovalStubProtocol.recorded.map { "\($0.method) \($0.path)" },
                       ["POST /api/v1/account/recovery-contacts/email/verify"], "no challenge, no signature")
        XCTAssertNil(json(ApprovalStubProtocol.recorded[0].body)["signature_hex"])
    }

    func test_signatureRequired_isItsOwnError() async {
        challengeThen(400, body: "{\"error\":\"signature_required\"}")
        do {
            try await makeApi(seed: Curve25519.Signing.PrivateKey().rawRepresentation).start(kind: .email, value: "a@b.it")
            XCTFail("expected a throw")
        } catch RecoveryContactError.signatureRequired {
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_otherBadRequest_isStillAnInvalidValue() async {
        challengeThen(400, body: "{\"error\":\"invalid email\"}")
        do {
            try await makeApi(seed: Curve25519.Signing.PrivateKey().rawRepresentation).start(kind: .email, value: "a@b.it")
            XCTFail("expected a throw")
        } catch RecoveryContactError.invalidValue {
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_signingRefusals_areFailures_withoutARetry_whenThereIsNoWayToRefresh() async {
        for (status, body) in [(401, "{\"error\":\"invalid signature\"}"), (403, "{\"error\":\"device_key_required\"}")] {
            ApprovalStubProtocol.reset()
            challengeThen(status, body: body)
            do {
                try await makeApi(seed: Curve25519.Signing.PrivateKey().rawRepresentation).remove(kind: .email)
                XCTFail("expected a throw")
            } catch RecoveryContactError.failed {
            } catch {
                XCTFail("\(status): \(error)")
            }
            XCTAssertEqual(ApprovalStubProtocol.recorded.count, 2, "challenge and one signed call: the nonce is single use")
        }
    }

    /// The device-challenge GET is unauthenticated, so it proves nothing about the bearer: a 401 on the signed call
    /// refreshes the session and rebuilds the call (new challenge, new signature), once.
    func test_expiredBearer_isRefreshedAndTheSignedCallRebuiltOnce() async throws {
        let hex = nonceHex
        ApprovalStubProtocol.handler = { request in
            if request.method == "GET" { return (200, "{\"nonce_hex\":\"\(hex)\"}", [:]) }
            return request.authorization == "Bearer fresh" ? (200, "{}", [:]) : (401, "{\"error\":\"unauthorized\"}", [:])
        }
        let key = Curve25519.Signing.PrivateKey()
        let api = makeApi(seed: key.rawRepresentation, refresher: { _ in
            AuthTokenSet(accessToken: "fresh", refreshToken: "ref2", expiresInSec: 900)
        })
        try await api.start(kind: .email, value: "maria@example.com")
        let calls = ApprovalStubProtocol.recorded.map { "\($0.method) \($0.path)" }
        XCTAssertEqual(calls, ["GET /api/v1/auth/device-challenge", "POST /api/v1/account/recovery-contacts/email",
                               "GET /api/v1/auth/device-challenge", "POST /api/v1/account/recovery-contacts/email"])
        let retry = try XCTUnwrap(ApprovalStubProtocol.recorded.last)
        XCTAssertEqual(retry.authorization, "Bearer fresh")
        let body = json(retry.body)
        XCTAssertEqual(body["email"] as? String, "maria@example.com")
        let sig = try XCTUnwrap(DeviceRenewBlob.hexDecode(try XCTUnwrap(body["signature_hex"] as? String)))
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: try blob(body, kind: .email, value: "maria@example.com")))
    }

    func test_expiredBearer_onARemove_isRefreshedToo() async throws {
        let hex = nonceHex
        ApprovalStubProtocol.handler = { request in
            if request.method == "GET" { return (200, "{\"nonce_hex\":\"\(hex)\"}", [:]) }
            return request.authorization == "Bearer fresh" ? (200, "{}", [:]) : (401, "{}", [:])
        }
        let api = makeApi(seed: Curve25519.Signing.PrivateKey().rawRepresentation, refresher: { _ in
            AuthTokenSet(accessToken: "fresh", refreshToken: "ref2", expiresInSec: 900)
        })
        try await api.remove(kind: .phone)
        XCTAssertEqual(ApprovalStubProtocol.recorded.filter { $0.method == "DELETE" }.count, 2)
    }

    func test_aFailedRefresh_isAFailure_withASingleSignedCall() async {
        challengeThen(401)
        let api = makeApi(seed: Curve25519.Signing.PrivateKey().rawRepresentation, refresher: { _ in
            throw URLError(.timedOut)
        })
        do {
            try await api.start(kind: .email, value: "a@b.it")
            XCTFail("expected a throw")
        } catch RecoveryContactError.failed {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(ApprovalStubProtocol.recorded.filter { $0.method == "POST" }.count, 1)
    }

    func test_aSecond401AfterARefresh_stopsThere() async {
        challengeThen(401)
        let api = makeApi(seed: Curve25519.Signing.PrivateKey().rawRepresentation, refresher: { _ in
            AuthTokenSet(accessToken: "fresh", refreshToken: "ref2", expiresInSec: 900)
        })
        do {
            try await api.start(kind: .email, value: "a@b.it")
            XCTFail("expected a throw")
        } catch RecoveryContactError.failed {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(ApprovalStubProtocol.recorded.filter { $0.method == "POST" }.count, 2, "one retry, never a loop")
    }

    /// A wrong device clock is told as such, not as an invalid value.
    @MainActor
    func test_skewWindow400_isTheClockError() async {
        challengeThen(400, body: "{\"error\":\"epoch_ms outside skew window\"}")
        do {
            try await makeApi(seed: Curve25519.Signing.PrivateKey().rawRepresentation).start(kind: .email, value: "a@b.it")
            XCTFail("expected a throw")
        } catch RecoveryContactError.clockSkew {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(RecoveryContactsModel.problem(RecoveryContactError.clockSkew), .clockWrong)
        XCTAssertEqual(BCryptoRecoveryContactsApi.mapSigned(status: 400, data: Data("{\"error\":\"invalid email\"}".utf8),
                                                            codeFailure: .invalidValue), .invalidValue)
    }

    func test_removeOfAnAbsentContact_is404_andDone() async throws {
        challengeThen(404, body: "{}")
        try await makeApi(seed: Curve25519.Signing.PrivateKey().rawRepresentation).remove(kind: .email)
    }

    func test_withoutAKeyOrADeviceId_nothingIsSent() async {
        ApprovalStubProtocol.handler = { _ in (200, "{}", [:]) }
        let cases: [(Data?, String?)] = [(nil, "dev-1"), (Curve25519.Signing.PrivateKey().rawRepresentation, nil)]
        for (seed, deviceId) in cases {
            do {
                try await makeApi(seed: seed, deviceId: deviceId).start(kind: .email, value: "a@b.it")
                XCTFail("expected a throw")
            } catch DeviceApprovalError.notReady {
            } catch {
                XCTFail("\(error)")
            }
        }
        XCTAssertTrue(ApprovalStubProtocol.recorded.isEmpty)
    }

    func test_mapSigned() {
        XCTAssertEqual(BCryptoRecoveryContactsApi.mapSigned(status: 429, data: Data(), codeFailure: .invalidValue), .rateLimited)
        XCTAssertEqual(BCryptoRecoveryContactsApi.mapSigned(status: 500, data: Data(), codeFailure: .invalidValue), .failed)
        XCTAssertEqual(BCryptoRecoveryContactsApi.mapSigned(status: 400, data: Data("{}".utf8), codeFailure: .invalidValue), .invalidValue)
    }

    // MARK: - Untrusted labels

    func test_untrustedLabel_stripsDigitsControlsAndBidi() {
        XCTAssertEqual(UntrustedLabel.clean("scegli 47"), "scegli")
        XCTAssertEqual(UntrustedLabel.clean("Scegli \u{0664}\u{0667} ora"), "Scegli ora", "Arabic-Indic digits too")
        XCTAssertEqual(UntrustedLabel.clean("ab\u{202E}cd\u{200B}ef"), "abcdef", "bidi override and zero-width are format characters")
        XCTAssertEqual(UntrustedLabel.clean("riga1\nriga2\r\n  fine"), "riga riga fine")
        XCTAssertEqual(UntrustedLabel.clean("a\u{0007}b"), "ab")
        XCTAssertEqual(UntrustedLabel.clean("12 47 83"), "", "nothing left: the screen shows its own word")
        XCTAssertEqual(UntrustedLabel.clean(""), "")
        XCTAssertEqual(UntrustedLabel.clean(String(repeating: "x", count: 100)).count, 40)
        XCTAssertEqual(UntrustedLabel.clean("iPhone di Maria"), "iPhone di Maria")
    }

    func test_untrustedLabel_stripsInvisibleFillers_andKeepsCombiningMarks() {
        for filler in ["\u{2800}", "\u{115F}", "\u{1160}", "\u{3164}", "\u{FFA0}"] {
            XCTAssertEqual(UntrustedLabel.clean("ab\(filler)cd"), "abcd")
            XCTAssertEqual(UntrustedLabel.clean(filler + filler), "", "a name of fillers only is empty")
        }
        XCTAssertEqual(UntrustedLabel.clean("Cafe\u{0301}"), "Cafe\u{0301}", "combining acute accent stays")
        XCTAssertEqual(UntrustedLabel.clean("\u{0645}\u{064E}"), "\u{0645}\u{064E}", "Arabic with a mark stays")
    }

    func test_pendingRequest_exposesCleanedNames() {
        let request = LoginApprovalRequest(id: "p", deviceName: "scegli 47", platform: "ios 18", area: "", createdAt: nil,
                                           choices: ["12", "47", "83"])
        XCTAssertEqual(request.displayDeviceName, "scegli")
        XCTAssertEqual(request.displayPlatform, "ios")
    }
}
