import XCTest
import CryptoKit
@testable import QAudionEngine

final class AppAttestTests: XCTestCase {

    // MARK: - requests

    func testChallengeRequestShape() throws {
        let r = try XCTUnwrap(AppAttestRequests.challengeRequest(serverUrl: "https://example.test/", bearer: "tok"))
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.absoluteString, "https://example.test/api/v1/attest/challenge")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertNil(r.httpBody)
    }

    func testAttestRequestBodyIsStandardBase64Json() throws {
        let attestation = Data([0xfb, 0xff, 0xfe, 0x01])
        let sub = AppAttestSubmission(keyId: "S0VZ", attestation: attestation, challenge: "Q0hBTA==")
        let r = try XCTUnwrap(AppAttestRequests.attestRequest(serverUrl: "https://example.test", bearer: "tok", submission: sub))
        XCTAssertEqual(r.url?.path, "/api/v1/attest/ios")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(r.httpBody)) as? [String: String])
        XCTAssertEqual(Set(object.keys), ["key_id", "attestation", "challenge"])
        XCTAssertEqual(object["key_id"], "S0VZ")
        XCTAssertEqual(object["challenge"], "Q0hBTA==")
        XCTAssertEqual(object["attestation"], "+//+AQ==")  // standard alphabet, padded
    }

    func testClientDataHashIsSha256OfChallengeBytes() throws {
        let bytes = Data((0..<32).map { UInt8($0) })
        let hash = try XCTUnwrap(AppAttestRequests.clientDataHash(challenge: bytes.base64EncodedString()))
        XCTAssertEqual(hash, Data(SHA256.hash(data: bytes)))
        XCTAssertEqual(hash.count, 32)
        XCTAssertNil(AppAttestRequests.clientDataHash(challenge: "not base64 !"))
        XCTAssertNil(AppAttestRequests.clientDataHash(challenge: ""))
    }

    func testParsing() {
        XCTAssertEqual(AppAttestRequests.parseChallenge(Data(#"{"challenge":"abc","expires_in":300}"#.utf8)), "abc")
        XCTAssertNil(AppAttestRequests.parseChallenge(Data(#"{"challenge":""}"#.utf8)))
        XCTAssertNil(AppAttestRequests.parseChallenge(Data("x".utf8)))
        XCTAssertEqual(AppAttestRequests.parseErrorCode(Data(#"{"error":"attestation_failed","code":"bad_input"}"#.utf8)), "bad_input")
    }

    // MARK: - policy

    func testDecisions() {
        func d(_ s: Int, _ c: String? = nil) -> AppAttestDecision {
            AppAttestPolicy.decision(for: AppAttestTransportError(status: s, code: c))
        }
        XCTAssertEqual(d(0), .retryAfterBackoff)
        XCTAssertEqual(d(503), .retryAfterBackoff)
        XCTAssertEqual(d(400, "challenge_invalid"), .retryAfterBackoff)
        XCTAssertEqual(d(400, "bad_input"), .stop)
        XCTAssertEqual(d(422, "key_mismatch"), .regenerateKey)
        XCTAssertEqual(d(422, "x"), .stop)
        XCTAssertEqual(d(404), .stop)
        XCTAssertEqual(d(429), .stop)
        XCTAssertEqual(d(401), .stop)
        XCTAssertEqual(AppAttestPolicy.decision(for: .invalidKey), .regenerateKey)
        XCTAssertEqual(AppAttestPolicy.decision(for: .transient), .retryAfterBackoff)
        XCTAssertEqual(AppAttestPolicy.decision(for: .failed(2)), .stop)
    }

    func testBackoffGrowsAndIsBounded() {
        XCTAssertEqual(AppAttestPolicy.backoff(afterAttempt: 1), 2)
        XCTAssertEqual(AppAttestPolicy.backoff(afterAttempt: 2), 8)
        XCTAssertEqual(AppAttestPolicy.backoff(afterAttempt: 9), 30)
    }

    func testVerdictCodesCarryNoKeyMaterial() {
        let code = AppAttestPolicy.code(for: AppAttestTransportError(status: 422, code: "AAAA+/key=="))
        XCTAssertEqual(code, "http_422")
        XCTAssertEqual(AppAttestPolicy.code(for: AppAttestTransportError(status: 422, code: "key_mismatch")), "http_422_key_mismatch")
    }

    // MARK: - coordinator

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var keyId: String?
        var attested: String?
        var generated = 0
        var challenges = 0
        var submits: [AppAttestSubmission] = []
        var sleeps: [UInt64] = []
        var verdicts: [AppAttestVerdict] = []
        var supported = true
        var challengeErrors: [AppAttestTransportError] = []
        var submitErrors: [AppAttestTransportError] = []
        var attestErrors: [AppAttestServiceError] = []
    }

    private struct Fake: AppAttestPlatformService, AppAttestTransport, AppAttestStore {
        let box: Box
        var isSupported: Bool { box.supported }
        func generateKey() async throws -> String {
            box.lock.lock(); defer { box.lock.unlock() }
            box.generated += 1
            return Data("key\(box.generated)".utf8).base64EncodedString()
        }
        func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
            box.lock.lock(); defer { box.lock.unlock() }
            if !box.attestErrors.isEmpty { throw box.attestErrors.removeFirst() }
            return clientDataHash
        }
        func challenge() async throws -> String {
            box.lock.lock(); defer { box.lock.unlock() }
            box.challenges += 1
            if !box.challengeErrors.isEmpty { throw box.challengeErrors.removeFirst() }
            return Data(repeating: UInt8(box.challenges), count: 32).base64EncodedString()
        }
        func submit(_ body: AppAttestSubmission) async throws {
            box.lock.lock(); defer { box.lock.unlock() }
            if !box.submitErrors.isEmpty { throw box.submitErrors.removeFirst() }
            box.submits.append(body)
        }
        func keyId() -> String? { box.lock.lock(); defer { box.lock.unlock() }; return box.keyId }
        func setKeyId(_ keyId: String) { box.lock.lock(); defer { box.lock.unlock() }; box.keyId = keyId }
        func clearKey() { box.lock.lock(); defer { box.lock.unlock() }; box.keyId = nil; box.attested = nil }
        func attestedAccount() -> String? { box.lock.lock(); defer { box.lock.unlock() }; return box.attested }
        func setAttestedAccount(_ account: String) { box.lock.lock(); defer { box.lock.unlock() }; box.attested = account }
        func clearAttestedAccount() { box.lock.lock(); defer { box.lock.unlock() }; box.attested = nil }
    }

    private func make(_ box: Box) -> AppAttestCoordinator {
        let fake = Fake(box: box)
        return AppAttestCoordinator(
            service: fake, transport: fake, store: fake,
            report: { v in box.lock.lock(); box.verdicts.append(v); box.lock.unlock() },
            sleep: { s in box.lock.lock(); box.sleeps.append(s); box.lock.unlock() })
    }

    func testHappyPathAttestsOnceAndPersists() async {
        let box = Box()
        let c = make(box)
        let v = await c.attestIfNeeded(account: "u1")
        XCTAssertEqual(v, .ok)
        XCTAssertEqual(box.generated, 1)
        XCTAssertEqual(box.submits.count, 1)
        XCTAssertEqual(box.attested, "u1")
        XCTAssertEqual(box.verdicts, [.ok])
        // The attestation was bound to SHA256(challenge bytes).
        let challengeBytes = Data(base64Encoded: box.submits[0].challenge)!
        XCTAssertEqual(box.submits[0].attestation, Data(SHA256.hash(data: challengeBytes)))
        let again = await c.attestIfNeeded(account: "u1")
        XCTAssertEqual(again, .alreadyAttested)
        XCTAssertEqual(box.submits.count, 1)
    }

    func testUnsupportedStopsWithoutTouchingTheNetwork() async {
        let box = Box()
        box.supported = false
        let v = await make(box).attestIfNeeded(account: "u1")
        XCTAssertEqual(v, .unsupported)
        XCTAssertEqual(box.challenges, 0)
        XCTAssertEqual(box.generated, 0)
        XCTAssertEqual(box.verdicts, [.unsupported])
    }

    func testAccountChangeAttestsAgainWithTheSameKey() async {
        let box = Box()
        let c = make(box)
        _ = await c.attestIfNeeded(account: "u1")
        await c.accountLeft()
        XCTAssertNil(box.attested)
        let v = await c.attestIfNeeded(account: "u2")
        XCTAssertEqual(v, .ok)
        XCTAssertEqual(box.generated, 1)
        XCTAssertEqual(box.attested, "u2")
        XCTAssertEqual(box.submits.count, 2)
    }

    func testNotFoundAndRateLimitStopUntilNextLaunch() async {
        for status in [404, 429] {
            let box = Box()
            box.challengeErrors = [AppAttestTransportError(status: status, code: nil)]
            let v = await make(box).attestIfNeeded(account: "u1")
            XCTAssertEqual(v, .fail("http_\(status)"))
            XCTAssertEqual(box.challenges, 1)
            XCTAssertTrue(box.sleeps.isEmpty)
            XCTAssertNil(box.attested)
        }
    }

    func testTransientFailuresRetryWithBackoffThenGiveUp() async {
        let box = Box()
        box.challengeErrors = Array(repeating: AppAttestTransportError(status: 0, code: nil), count: 5)
        let v = await make(box).attestIfNeeded(account: "u1")
        XCTAssertEqual(v, .fail("http_0"))
        XCTAssertEqual(box.challenges, AppAttestPolicy.maxAttempts)
        XCTAssertEqual(box.sleeps, [2, 8])
    }

    func testFailureThenSuccessUsesAFreshChallenge() async {
        let box = Box()
        box.submitErrors = [AppAttestTransportError(status: 400, code: "challenge_invalid")]
        let v = await make(box).attestIfNeeded(account: "u1")
        XCTAssertEqual(v, .ok)
        XCTAssertEqual(box.challenges, 2)
        XCTAssertEqual(box.sleeps, [2])
    }

    func testInvalidKeyRegeneratesOnce() async {
        let box = Box()
        box.keyId = "b2xk"
        box.attestErrors = [.invalidKey]
        let v = await make(box).attestIfNeeded(account: "u1")
        XCTAssertEqual(v, .ok)
        XCTAssertEqual(box.generated, 1)
        XCTAssertNotEqual(box.keyId, "b2xk")
    }

    func testKeyMismatchRegeneratesOnlyOnce() async {
        let box = Box()
        box.submitErrors = Array(repeating: AppAttestTransportError(status: 422, code: "key_mismatch"), count: 3)
        let v = await make(box).attestIfNeeded(account: "u1")
        XCTAssertEqual(v, .fail("http_422_key_mismatch"))
        XCTAssertEqual(box.generated, 2)
        XCTAssertNil(box.attested)
    }
}
