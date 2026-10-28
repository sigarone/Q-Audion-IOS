import XCTest
@testable import QAudionEngine

/// The refusal of a registration over the Terms, the platform fields of the acceptance, the notice that never
/// holds a call, and the receipt kept on disk.
final class LegalFollowUpTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FollowUpStubURLProtocol.reset()
    }

    private func makeRest() -> BCryptoRestClient {
        BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local"),
                          testURLProtocolClasses: [FollowUpStubURLProtocol.self])
    }

    // MARK: refusal

    func testA400WithTheTermsCodeCarriesItsReason() async {
        for reason in ["missing", "incomplete", "stale"] {
            FollowUpStubURLProtocol.stub = (400, Data(#"{"code":"terms_acceptance_required","reason":"\#(reason)"}"#.utf8))
            do {
                _ = try await makeRest().post("/api/v1/auth/register/extension", body: Data("{}".utf8))
                XCTFail("a 400 must throw")
            } catch {
                XCTAssertEqual(BCryptoTermsRefusal.from(error)?.reason, BCryptoTermsRefusal.Reason(rawValue: reason))
            }
        }
    }

    func testAnUnknownReasonIsStillTheRefusal() {
        let refusal = BCryptoTermsRefusal(responseBody: Data(#"{"code":"terms_acceptance_required"}"#.utf8))
        XCTAssertEqual(refusal?.reason, .unspecified)
    }

    func testAnyOther400StaysAPlainHttpError() async {
        for body in [#"{"code":"email_invalid"}"#, "not json", ""] {
            FollowUpStubURLProtocol.stub = (400, Data(body.utf8))
            do {
                _ = try await makeRest().post("/api/v1/auth/register/extension", body: Data("{}".utf8))
                XCTFail("a 400 must throw")
            } catch BCryptoError.httpError(let status) {
                XCTAssertEqual(status, 400)
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }

    // MARK: platform and version

    func testTheAcceptanceSendsThePlatformAndTheAppVersion() throws {
        let acceptance = TermsAcceptance(version: "2026-10-28", lang: "it", sha256: "aa", terms: true, deviations: true,
                                         groups: ["g1": true], professional: false, appVersion: "1.0.1241.2000")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: acceptance.jsonData()) as? [String: Any])
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertEqual(json["app_version"] as? String, "1.0.1241.2000")
    }

    func testTheVersionIsShortPlusBuildInTheCharactersTheServerAccepts() {
        XCTAssertEqual(TermsAcceptance.appVersionString(short: "1.0", build: "1241"), "1.0.1241")
        XCTAssertEqual(TermsAcceptance.appVersionString(short: "1.0 beta!", build: nil), "1.0beta")
        XCTAssertEqual(TermsAcceptance.appVersionString(short: nil, build: nil), "unknown")
        XCTAssertEqual(TermsAcceptance.appVersionString(short: String(repeating: "9", count: 100), build: "1").count, 64)
        XCTAssertFalse(TermsAcceptance.currentAppVersion.isEmpty)
    }

    // MARK: emergency notice

    @MainActor
    private func coordinator(flag: FakeFlag = FakeFlag(), sceneActive: Bool = true, text: String? = "No emergency calls.",
                             answerTimeout: Double = 0.2) -> EmergencyNoticeCoordinator {
        let result = EmergencyNoticeCoordinator(
            flag: flag, isSceneActive: { sceneActive }, answerTimeoutSeconds: answerTimeout, fetchTimeoutSeconds: 0.2)
        result.configure(textProvider: { { text } })
        return result
    }

    @MainActor
    func testAnInactiveSceneNeverHoldsTheCall() async {
        let flag = FakeFlag()
        let center = coordinator(flag: flag, sceneActive: false)
        await center.confirmBeforeFirstCall()
        XCTAssertNil(center.pendingText)
        XCTAssertFalse(flag.acknowledged)
    }

    @MainActor
    func testAnUnansweredAlertLetsTheCallGoAheadAndLeavesTheFlagUnset() async {
        let flag = FakeFlag()
        let center = coordinator(flag: flag)
        await center.confirmBeforeFirstCall()
        XCTAssertNil(center.pendingText, "the alert goes away with the timeout")
        XCTAssertFalse(flag.acknowledged)
    }

    @MainActor
    func testTheTapOnTheAlertReleasesTheCallAndSetsTheFlag() async {
        let flag = FakeFlag()
        let center = coordinator(flag: flag, answerTimeout: 5)
        let call = Task { @MainActor in await center.confirmBeforeFirstCall() }
        while center.pendingText == nil { await Task.yield() }
        center.acknowledge()
        await call.value
        XCTAssertTrue(flag.acknowledged)
        XCTAssertNil(center.pendingText)
    }

    @MainActor
    func testASecondStartWaitsForTheSameAnswerAndAlsoCannotHang() async {
        let center = coordinator()
        let first = Task { @MainActor in await center.confirmBeforeFirstCall() }
        while center.pendingText == nil { await Task.yield() }
        let second = Task { @MainActor in await center.confirmBeforeFirstCall() }
        await first.value
        await second.value
        XCTAssertNil(center.pendingText)
    }

    @MainActor
    func testAnUnreadableTextOrAnAcknowledgedFlagProceedsAtOnce() async {
        let unreadable = coordinator(text: nil)
        await unreadable.confirmBeforeFirstCall()
        XCTAssertNil(unreadable.pendingText)
        let flag = FakeFlag()
        flag.acknowledged = true
        let done = coordinator(flag: flag)
        await done.confirmBeforeFirstCall()
        XCTAssertNil(done.pendingText)
    }

    // MARK: receipt

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("receipt-\(UUID().uuidString)")
    }

    func testTheReceiptSurvivesOnDiskUntilItIsDeleted() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = WithdrawalReceiptFile(directory: directory)
        XCTAssertNil(file.load())
        let receipt = WithdrawalReceipt(receiptText: "Hai receduto", receiptId: "abc-1")
        try file.save(receipt)
        XCTAssertEqual(WithdrawalReceiptFile(directory: directory).load(), receipt, "a new instance is a new launch")
        file.delete()
        XCTAssertNil(file.load())
    }

    func testClosingAnUnsavedReceiptAsksAndASavedOneClosesAtOnce() {
        XCTAssertEqual(ReceiptClosePolicy.decide(saved: false), .askToSave)
        XCTAssertEqual(ReceiptClosePolicy.decide(saved: true), .close)
    }
}

private final class FakeFlag: EmergencyNoticeFlagStore {
    var acknowledged = false
}

private final class FollowUpStubURLProtocol: URLProtocol {
    static var stub: (status: Int, body: Data) = (200, Data())

    static func reset() { stub = (200, Data()) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // swiftlint:disable:next force_unwrapping - test-only stub, the request URL is always present.
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.stub.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
