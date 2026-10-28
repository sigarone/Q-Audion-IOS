import XCTest
@testable import QAudionEngine

// MARK: - Fixtures

private enum LegalFixtures {
    static func document(version: String = "2026-10-29", lang: String = "it") -> LegalTermsDocument {
        LegalTermsDocument(
            version: version, lang: lang, title: "Terms", bodyMarkdown: "body",
            specificApproval: LegalSpecificApproval(id: "specific", title: "Specific approval", text: "specific text"),
            emergencyNotice: "Emergency calls are not supported.", withdrawalInfo: "You can withdraw.")
    }

    static func fetch(version: String = "2026-10-29", lang: String = "it") -> LegalTermsFetch {
        LegalTermsFetch(document: document(version: version, lang: lang), sha256: String(repeating: "cd", count: 32))
    }

    static let documentJSON = """
    {"version":"2026-10-29","lang":"en","title":"Terms",
     "body_markdown":"# Terms","specific_approval":{"id":"specific","title":"S","text":"s text"},
     "emergency_notice":"No emergency calls.","withdrawal_info":"Withdraw here."}
    """
}

private final class FakeLegalApi: LegalApi, @unchecked Sendable {
    var statusResults: [Result<LegalStatus, Error>] = []
    var termsResult: Result<LegalTermsFetch, Error> = .success(LegalFixtures.fetch())
    var acceptResults: [Result<Void, Error>] = []
    var withdrawResult: Result<WithdrawalReceipt, Error> = .success(WithdrawalReceipt(receiptText: "receipt", receiptId: "r1"))
    private(set) var accepted: [TermsAcceptance] = []
    private(set) var statusCalls = 0
    private(set) var termsCalls = 0
    private(set) var withdrawCalls = 0
    var withdrawGate: (() async -> Void)?

    func fetchTerms(lang: String) async throws -> LegalTermsFetch { termsCalls += 1; return try termsResult.get() }
    func status() async throws -> LegalStatus {
        statusCalls += 1
        return try (statusResults.isEmpty ? .failure(BCryptoError.httpError(500)) : statusResults.removeFirst()).get()
    }
    func accept(_ acceptance: TermsAcceptance) async throws {
        accepted.append(acceptance)
        try (acceptResults.isEmpty ? .success(()) : acceptResults.removeFirst()).get()
    }
    func acceptanceCopy() async throws -> Data { Data() }
    func withdraw() async throws -> WithdrawalReceipt {
        withdrawCalls += 1
        if let gate = withdrawGate { await gate() }
        return try withdrawResult.get()
    }
}

private func needsAcceptance(_ version: String = "2026-10-29") -> LegalStatus {
    LegalStatus(currentVersion: version, acceptedVersion: "2026-08-05", acceptanceRequired: true)
}

private func notRequired() -> LegalStatus {
    LegalStatus(currentVersion: "2026-10-29", acceptedVersion: "2026-10-29", acceptanceRequired: false)
}

// MARK: - Acceptance state machine

final class TermsAcceptanceDraftTests: XCTestCase {

    func testBothBoxesStartOff() {
        let draft = TermsAcceptanceDraft()
        XCTAssertFalse(draft.termsAccepted)
        XCTAssertFalse(draft.specificAccepted)
        XCTAssertFalse(draft.canContinue)
        XCTAssertNil(draft.acceptance(for: LegalFixtures.fetch()))
    }

    func testContinueNeedsBothBoxes() {
        var draft = TermsAcceptanceDraft()
        draft.termsAccepted = true
        XCTAssertFalse(draft.canContinue, "the Terms box alone is not enough")
        XCTAssertNil(draft.acceptance(for: LegalFixtures.fetch()))
        draft.specificAccepted = true
        XCTAssertTrue(draft.canContinue)
        draft.termsAccepted = false
        XCTAssertFalse(draft.canContinue, "unticking a box closes the gate again")
        draft = TermsAcceptanceDraft()
        draft.specificAccepted = true
        XCTAssertFalse(draft.canContinue, "the specific box alone is not enough")
    }

    func testTheAcceptanceCarriesTheDocumentTheScreenShowed() throws {
        let fetch = LegalFixtures.fetch(lang: "en")
        var draft = TermsAcceptanceDraft()
        draft.termsAccepted = true
        draft.specificAccepted = true
        let acceptance = try XCTUnwrap(draft.acceptance(for: fetch))
        XCTAssertEqual(acceptance.version, "2026-10-29")
        XCTAssertEqual(acceptance.lang, "en")
        XCTAssertEqual(acceptance.sha256, fetch.sha256)
        XCTAssertTrue(acceptance.terms)
        XCTAssertTrue(acceptance.specific)
    }

    func testTheRequestBodyIsJsonWithRealBooleans() throws {
        let fetch = LegalFixtures.fetch()
        var draft = TermsAcceptanceDraft()
        draft.termsAccepted = true
        draft.specificAccepted = true
        let data = try XCTUnwrap(draft.acceptance(for: fetch)).jsonData()
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "lang", "sha256", "terms", "specific", "platform", "app_version"])
        for key in ["terms", "specific"] {
            let number = try XCTUnwrap(json[key] as? NSNumber)
            XCTAssertTrue(CFGetTypeID(number) == CFBooleanGetTypeID(), "\(key) is not a JSON boolean")
            XCTAssertTrue(number.boolValue)
        }
    }

    func testTheLanguageIsItalianOnlyForAnItalianApp() {
        XCTAssertEqual(LegalLanguage.code(forAppLanguage: "it"), "it")
        XCTAssertEqual(LegalLanguage.code(forAppLanguage: "it-IT"), "it")
        XCTAssertEqual(LegalLanguage.code(forAppLanguage: "de"), "en")
        XCTAssertEqual(LegalLanguage.code(forAppLanguage: "pt-BR"), "en")
        XCTAssertEqual(LegalLanguage.code(forAppLanguage: ""), "en")
    }
}

// MARK: - Re-acceptance gate

@MainActor
final class TermsGateModelTests: XCTestCase {

    private func makeModel(_ api: FakeLegalApi) -> TermsGateModel {
        TermsGateModel(api: api, languageCode: { "it" })
    }

    private func tickEverything(_ model: TermsGateModel) {
        model.draft.specificAccepted = true
        model.draft.termsAccepted = true
    }

    func testNothingIsShownWhenTheStatusSaysItIsNotRequired() async {
        let api = FakeLegalApi()
        api.statusResults = [.success(notRequired())]
        let model = makeModel(api)
        await model.refresh()
        XCTAssertEqual(model.requirement, .notRequired)
        XCTAssertFalse(model.isPresented)
        XCTAssertEqual(api.termsCalls, 0, "the document is read only when it is needed")
    }

    func testTheScreenIsShownWhenRequiredAndNoCallIsActive() async {
        let api = FakeLegalApi()
        api.statusResults = [.success(needsAcceptance())]
        let model = makeModel(api)
        await model.refresh()
        XCTAssertEqual(model.requirement, .required)
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.fetch?.document.version, "2026-10-29")
    }

    func testAnActiveOrRingingCallDefersTheScreen() async {
        let api = FakeLegalApi()
        api.statusResults = [.success(needsAcceptance())]
        let model = makeModel(api)
        model.setCallBusy(true)
        await model.refresh()
        XCTAssertEqual(model.requirement, .required)
        XCTAssertFalse(model.isPresented, "never in front of a call")
        model.setCallBusy(false)
        XCTAssertTrue(model.isPresented, "it comes once the call is over")
    }

    func testACallThatStartsTakesTheScreenDownAndKeepsTheBoxes() async {
        let api = FakeLegalApi()
        api.statusResults = [.success(needsAcceptance())]
        let model = makeModel(api)
        await model.refresh()
        model.draft.specificAccepted = true
        model.setCallBusy(true)
        XCTAssertFalse(model.isPresented)
        model.setCallBusy(false)
        XCTAssertTrue(model.isPresented)
        XCTAssertTrue(model.draft.specificAccepted)
    }

    func testAnUnreadableStatusNeverBlocks() async {
        let api = FakeLegalApi()
        api.statusResults = [.failure(BCryptoError.httpError(503))]
        let model = makeModel(api)
        await model.refresh()
        XCTAssertEqual(model.requirement, .unknown)
        XCTAssertFalse(model.isPresented)
    }

    func testAnUnreadableDocumentNeverBlocks() async {
        let api = FakeLegalApi()
        api.statusResults = [.success(needsAcceptance())]
        api.termsResult = .failure(BCryptoError.httpError(500))
        let model = makeModel(api)
        await model.refresh()
        XCTAssertFalse(model.isPresented)
    }

    func testAcceptingSendsTheAcceptanceAndClosesTheScreen() async throws {
        let api = FakeLegalApi()
        api.statusResults = [.success(needsAcceptance())]
        let model = makeModel(api)
        await model.refresh()
        tickEverything(model)
        await model.submit()
        XCTAssertEqual(api.accepted.count, 1)
        XCTAssertEqual(api.accepted.first?.version, "2026-10-29")
        XCTAssertEqual(model.requirement, .notRequired)
        XCTAssertFalse(model.isPresented)
    }

    func testSubmitDoesNothingWhileABoxIsOff() async {
        let api = FakeLegalApi()
        api.statusResults = [.success(needsAcceptance())]
        let model = makeModel(api)
        await model.refresh()
        model.draft.specificAccepted = true
        await model.submit()
        XCTAssertTrue(api.accepted.isEmpty)
        XCTAssertTrue(model.isPresented)
    }

    func testAStaleEditionReadsTheServerAgainAndStartsOver() async {
        let api = FakeLegalApi()
        api.statusResults = [.success(needsAcceptance("2026-10-29")), .success(needsAcceptance("2026-12-01"))]
        api.acceptResults = [.failure(LegalApiError.versionStale)]
        let model = makeModel(api)
        await model.refresh()
        tickEverything(model)
        api.termsResult = .success(LegalFixtures.fetch(version: "2026-12-01"))
        await model.submit()
        XCTAssertEqual(model.problem, .editionChanged)
        XCTAssertEqual(model.fetch?.document.version, "2026-12-01")
        XCTAssertFalse(model.draft.specificAccepted, "the boxes are cleared for the new text")
        XCTAssertTrue(model.isPresented)
    }

    func testAFailedSendKeepsTheScreenAndTheBoxes() async {
        let api = FakeLegalApi()
        api.statusResults = [.success(needsAcceptance())]
        api.acceptResults = [.failure(BCryptoError.httpError(500))]
        let model = makeModel(api)
        await model.refresh()
        tickEverything(model)
        await model.submit()
        XCTAssertEqual(model.problem, .submitFailed)
        XCTAssertTrue(model.isPresented)
        XCTAssertTrue(model.draft.termsAccepted)
        XCTAssertFalse(model.isSubmitting)
    }

    func testResetDropsEverything() async {
        let api = FakeLegalApi()
        api.statusResults = [.success(needsAcceptance())]
        let model = makeModel(api)
        await model.refresh()
        model.reset()
        XCTAssertEqual(model.requirement, .unknown)
        XCTAssertNil(model.fetch)
        XCTAssertFalse(model.isPresented)
    }
}

// MARK: - Withdrawal

@MainActor
final class WithdrawalModelTests: XCTestCase {

    func testItStartsOnTheInfoAndConfirmingShowsTheReceipt() async {
        let api = FakeLegalApi()
        var seen: WithdrawalReceipt?
        let model = WithdrawalModel(api: api, onReceipt: { seen = $0 })
        XCTAssertEqual(model.state, .info)
        XCTAssertTrue(model.canConfirm)
        await model.confirm()
        XCTAssertEqual(model.state, .receipt(WithdrawalReceipt(receiptText: "receipt", receiptId: "r1")))
        XCTAssertEqual(seen?.receiptId, "r1")
        XCTAssertFalse(model.canConfirm)
        XCTAssertEqual(api.withdrawCalls, 1)
    }

    func testAFailureAllowsARetry() async {
        let api = FakeLegalApi()
        api.withdrawResult = .failure(BCryptoError.httpError(500))
        let model = WithdrawalModel(api: api)
        await model.confirm()
        XCTAssertEqual(model.state, .failed(.network))
        XCTAssertTrue(model.canConfirm)
        api.withdrawResult = .success(WithdrawalReceipt(receiptText: "ok", receiptId: "r2"))
        await model.confirm()
        XCTAssertEqual(model.state, .receipt(WithdrawalReceipt(receiptText: "ok", receiptId: "r2")))
        XCTAssertEqual(api.withdrawCalls, 2)
    }

    func testARejectedSessionIsNotReportedAsANetworkFailure() async {
        let api = FakeLegalApi()
        api.withdrawResult = .failure(BCryptoError.unauthorized)
        let model = WithdrawalModel(api: api)
        await model.confirm()
        XCTAssertEqual(model.state, .failed(.sessionEnded))
    }

    func testASecondTapWhileTheRequestRunsDoesNothing() async {
        let api = FakeLegalApi()
        let model = WithdrawalModel(api: api)
        let started = expectation(description: "request started")
        let release = AsyncGate()
        api.withdrawGate = { started.fulfill(); await release.wait() }
        let first = Task { await model.confirm() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.state, .sending)
        XCTAssertFalse(model.canConfirm)
        await model.confirm()
        XCTAssertEqual(api.withdrawCalls, 1)
        await release.open()
        await first.value
        XCTAssertEqual(api.withdrawCalls, 1)
    }
}

/// One-shot gate for a test that has to hold a request in flight.
private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

// MARK: - Markdown blocks

final class LegalMarkdownTests: XCTestCase {

    func testHeadingsAndParagraphsAreSplitAndTheWordsAreKept() {
        let blocks = LegalMarkdown.blocks(from: "# Title\n\nFirst line\nsecond line\n\n## Art. 1\nText of art. 1\n")
        XCTAssertEqual(blocks, [
            LegalMarkdownBlock(kind: .heading(level: 1), text: "Title"),
            LegalMarkdownBlock(kind: .paragraph, text: "First line\nsecond line"),
            LegalMarkdownBlock(kind: .heading(level: 2), text: "Art. 1"),
            LegalMarkdownBlock(kind: .paragraph, text: "Text of art. 1"),
        ])
    }

    func testAHashWithoutASpaceIsText() {
        XCTAssertEqual(LegalMarkdown.blocks(from: "#hashtag"), [LegalMarkdownBlock(kind: .paragraph, text: "#hashtag")])
        XCTAssertEqual(LegalMarkdown.blocks(from: "####### seven"), [LegalMarkdownBlock(kind: .paragraph, text: "####### seven")])
    }

    func testWindowsLineEndingsAndEmptyInput() {
        XCTAssertEqual(LegalMarkdown.blocks(from: "a\r\n\r\nb").map(\.text), ["a", "b"])
        XCTAssertTrue(LegalMarkdown.blocks(from: "").isEmpty)
    }
}

// MARK: - Wire

final class BCryptoLegalApiTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LegalStubURLProtocol.reset()
        URLProtocol.registerClass(LegalStubURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(LegalStubURLProtocol.self)
        super.tearDown()
    }

    private func makeApi() -> BCryptoLegalApi {
        BCryptoLegalApi(rest: BCryptoRestClient(
            config: BackendConfig(serverUrl: "https://test.local"), testURLProtocolClasses: [LegalStubURLProtocol.self]))
    }

    func testTheDocumentIsDecodedAndItsDigestIsTheDigestOfTheServedBytes() async throws {
        let bytes = Data(LegalFixtures.documentJSON.utf8)
        LegalStubURLProtocol.stubResponse = (200, bytes)
        let fetch = try await makeApi().fetchTerms(lang: "de")
        XCTAssertEqual(LegalStubURLProtocol.lastRequestURL, "https://test.local/api/v1/legal/terms?lang=en",
                       "any language other than Italian asks for English")
        XCTAssertEqual(fetch.document.bodyMarkdown, "# Terms")
        XCTAssertEqual(fetch.document.emergencyNotice, "No emergency calls.")
        XCTAssertEqual(fetch.document.withdrawalInfo, "Withdraw here.")
        XCTAssertEqual(fetch.document.specificApproval.text, "s text")
        XCTAssertEqual(fetch.sha256, BCryptoLegalApi.sha256Hex(bytes))
        XCTAssertEqual(fetch.sha256.count, 64)
    }

    func testTheKnownDigestOfAShortInput() {
        XCTAssertEqual(BCryptoLegalApi.sha256Hex(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testItalianAsksForItalian() async throws {
        LegalStubURLProtocol.stubResponse = (200, Data(LegalFixtures.documentJSON.utf8))
        _ = try await makeApi().fetchTerms(lang: "it")
        XCTAssertEqual(LegalStubURLProtocol.lastRequestURL, "https://test.local/api/v1/legal/terms?lang=it")
    }

    func testStatusDecodesAnEmptyAcceptedVersion() async throws {
        LegalStubURLProtocol.stubResponse = (200, Data(#"{"current_version":"2026-10-29","accepted_version":"","acceptance_required":true}"#.utf8))
        let status = try await makeApi().status()
        XCTAssertEqual(status, LegalStatus(currentVersion: "2026-10-29", acceptedVersion: "", acceptanceRequired: true))
        LegalStubURLProtocol.stubResponse = (200, Data(#"{"current_version":"2026-10-29","acceptance_required":false}"#.utf8))
        let second = try await makeApi().status()
        XCTAssertFalse(second.acceptanceRequired)
    }

    func testAcceptPostsTheBodyAndMapsA409ToStale() async throws {
        LegalStubURLProtocol.stubResponse = (204, Data())
        let acceptance = TermsAcceptance(version: "2026-10-29", lang: "it", sha256: "aa", terms: true, specific: true)
        try await makeApi().accept(acceptance)
        XCTAssertEqual(LegalStubURLProtocol.lastRequestURL, "https://test.local/api/v1/legal/accept")
        XCTAssertEqual(LegalStubURLProtocol.lastMethod, "POST")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(LegalStubURLProtocol.lastBody)) as? [String: Any])
        XCTAssertEqual(json["version"] as? String, "2026-10-29")

        LegalStubURLProtocol.stubResponse = (409, Data(#"{"code":"terms_version_stale"}"#.utf8))
        do {
            try await makeApi().accept(acceptance)
            XCTFail("a 409 must throw")
        } catch {
            XCTAssertEqual(error as? LegalApiError, .versionStale)
        }
    }

    func testWithdrawSendsConfirmTrueAndDecodesTheReceipt() async throws {
        LegalStubURLProtocol.stubResponse = (200, Data(#"{"receipt_text":"Hai receduto","receipt_id":"abc"}"#.utf8))
        let receipt = try await makeApi().withdraw()
        XCTAssertEqual(LegalStubURLProtocol.lastRequestURL, "https://test.local/api/v1/legal/withdraw")
        XCTAssertEqual(receipt, WithdrawalReceipt(receiptText: "Hai receduto", receiptId: "abc"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(LegalStubURLProtocol.lastBody)) as? [String: Any])
        let confirm = try XCTUnwrap(json["confirm"] as? NSNumber)
        XCTAssertTrue(CFGetTypeID(confirm) == CFBooleanGetTypeID())
        XCTAssertTrue(confirm.boolValue)
    }

    func testAnEmptyReceiptIsNotAccepted() async {
        LegalStubURLProtocol.stubResponse = (200, Data(#"{"receipt_text":"","receipt_id":"abc"}"#.utf8))
        do {
            _ = try await makeApi().withdraw()
            XCTFail("an empty receipt is not a receipt")
        } catch {
            XCTAssertEqual(error as? LegalApiError, .malformedResponse)
        }
    }
}

private final class LegalStubURLProtocol: URLProtocol {
    static var stubResponse: (status: Int, body: Data) = (200, Data())
    static var lastRequestURL: String?
    static var lastMethod: String?
    static var lastBody: Data?

    static func reset() {
        stubResponse = (200, Data())
        lastRequestURL = nil
        lastMethod = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let body = request.httpBody {
            Self.lastBody = body
        } else if let stream = request.httpBodyStream {
            Self.lastBody = Self.readStream(stream)
        }
        Self.lastRequestURL = request.url?.absoluteString
        Self.lastMethod = request.httpMethod
        // swiftlint:disable:next force_unwrapping - test-only stub, the request URL is always present.
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.stubResponse.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stubResponse.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readStream(_ stream: InputStream) -> Data {
        var data = Data()
        stream.open()
        defer { stream.close() }
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buffer, maxLength: bufferSize)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
