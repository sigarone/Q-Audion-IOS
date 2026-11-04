import XCTest
@testable import QAudionEngine

private final class FakeContactsApi: RecoveryContactsApi, @unchecked Sendable {
    private let lock = NSLock()
    private var _status = RecoveryContactsStatus()
    private var _fetchError: Error?
    private var _startError: Error?
    private var _verifyError: Error?
    private var _calls: [String] = []

    var status: RecoveryContactsStatus {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var fetchError: Error? {
        get { lock.withLock { _fetchError } }
        set { lock.withLock { _fetchError = newValue } }
    }
    var startError: Error? {
        get { lock.withLock { _startError } }
        set { lock.withLock { _startError = newValue } }
    }
    var verifyError: Error? {
        get { lock.withLock { _verifyError } }
        set { lock.withLock { _verifyError = newValue } }
    }
    var calls: [String] { lock.withLock { _calls } }

    func fetch() async throws -> RecoveryContactsStatus {
        lock.withLock { _calls.append("fetch") }
        if let error = fetchError { throw error }
        return status
    }

    func start(kind: RecoveryContactKind, value: String) async throws {
        lock.withLock { _calls.append("start \(kind.rawValue)") }
        if let error = startError { throw error }
    }

    func verify(kind: RecoveryContactKind, code: String) async throws {
        lock.withLock { _calls.append("verify \(kind.rawValue) \(code)") }
        if let error = verifyError { throw error }
        lock.withLock {
            if kind == .email { _status.emailVerified = true; _status.emailMasked = "a***@b***.it" }
            else { _status.phoneVerified = true; _status.phoneMasked = "+39 ***33" }
        }
    }

    func remove(kind: RecoveryContactKind) async throws {
        lock.withLock { _calls.append("remove \(kind.rawValue)") }
        lock.withLock {
            if kind == .email { _status.emailMasked = nil; _status.emailVerified = false }
            else { _status.phoneMasked = nil; _status.phoneVerified = false }
        }
    }
}

@MainActor
final class RecoveryContactsModelTests: XCTestCase {

    func test_load_showsMaskedHintsAndFlags() async {
        let api = FakeContactsApi()
        api.status = RecoveryContactsStatus(emailMasked: "m***@g***.com", emailVerified: true,
                                            phoneMasked: "+39 ***45", phoneVerified: false)
        let model = RecoveryContactsModel(api: api)
        await model.load()
        XCTAssertEqual(model.email.masked, "m***@g***.com")
        XCTAssertTrue(model.email.verified)
        XCTAssertEqual(model.phone.masked, "+39 ***45")
        XCTAssertFalse(model.phone.verified)
    }

    func test_addEmail_thenVerify_endsVerified() async {
        let api = FakeContactsApi()
        let model = RecoveryContactsModel(api: api)
        await model.start(.email, value: " ada@example.com ")
        XCTAssertEqual(model.email.step, .awaitingCode)
        await model.verify(.email, code: "123456")
        XCTAssertEqual(model.email.step, .idle)
        XCTAssertTrue(model.email.verified)
        XCTAssertEqual(api.calls, ["start email", "verify email 123456", "fetch"])
    }

    func test_invalidValues_areRefusedLocally() async {
        let api = FakeContactsApi()
        let model = RecoveryContactsModel(api: api)
        for bad in ["", "ada", "ada@", "@example.com", "ada@example", "a da@example.com", "ada@.com"] {
            await model.start(.email, value: bad)
            XCTAssertEqual(model.email.problem, .invalidValue, bad)
            XCTAssertEqual(model.email.step, .idle)
        }
        for bad in ["3331112233", "+0123456789", "+39 333 111", "+12", "+3933311122334455667"] {
            await model.start(.phone, value: bad)
            XCTAssertEqual(model.phone.problem, .invalidValue, bad)
        }
        XCTAssertTrue(api.calls.isEmpty)
    }

    func test_validValues() {
        XCTAssertTrue(RecoveryContactsModel.isValid(.email, "ada@example.com"))
        XCTAssertTrue(RecoveryContactsModel.isValid(.email, "ada.l+x@mail.example.co.uk"))
        XCTAssertTrue(RecoveryContactsModel.isValid(.phone, "+393331112233"))
        XCTAssertTrue(RecoveryContactsModel.isValid(.phone, "+14155550100"))
    }

    func test_serverRefusesTheValue_staysIdleWithAProblem() async {
        let api = FakeContactsApi()
        api.startError = RecoveryContactError.invalidValue
        let model = RecoveryContactsModel(api: api)
        await model.start(.phone, value: "+393331112233")
        XCTAssertEqual(model.phone.step, .idle)
        XCTAssertEqual(model.phone.problem, .invalidValue)
    }

    func test_wrongCode_keepsTheCodeStep() async {
        let api = FakeContactsApi()
        let model = RecoveryContactsModel(api: api)
        await model.start(.phone, value: "+393331112233")
        api.verifyError = RecoveryContactError.invalidCode
        await model.verify(.phone, code: "000000")
        XCTAssertEqual(model.phone.step, .awaitingCode)
        XCTAssertEqual(model.phone.problem, .invalidCode)
        XCTAssertFalse(model.phone.verified)
    }

    func test_codeNotSixDigits_isRefusedLocally() async {
        let api = FakeContactsApi()
        let model = RecoveryContactsModel(api: api)
        await model.start(.email, value: "ada@example.com")
        await model.verify(.email, code: "12ab56")
        XCTAssertEqual(model.email.problem, .invalidCode)
        XCTAssertEqual(api.calls, ["start email"])
    }

    func test_verify_withoutTheCodeStep_doesNothing() async {
        let api = FakeContactsApi()
        let model = RecoveryContactsModel(api: api)
        await model.verify(.email, code: "123456")
        XCTAssertTrue(api.calls.isEmpty)
    }

    func test_remove_clearsTheContact_withoutACode() async {
        let api = FakeContactsApi()
        api.status = RecoveryContactsStatus(emailMasked: "m***@g***.com", emailVerified: true)
        let model = RecoveryContactsModel(api: api)
        await model.load()
        await model.remove(.email)
        XCTAssertNil(model.email.masked)
        XCTAssertFalse(model.email.verified)
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("remove") }, ["remove email"])
    }

    func test_cancelCode_returnsToIdle() async {
        let model = RecoveryContactsModel(api: FakeContactsApi())
        await model.start(.email, value: "ada@example.com")
        model.cancelCode(.email)
        XCTAssertEqual(model.email.step, .idle)
    }

    func test_rejectedSession_clears_otherFailuresMarkTheLoad() async {
        let api = FakeContactsApi()
        api.status = RecoveryContactsStatus(emailMasked: "x", emailVerified: true)
        let model = RecoveryContactsModel(api: api)
        await model.load()
        api.fetchError = URLError(.timedOut)
        await model.load()
        XCTAssertTrue(model.loadFailed)
        XCTAssertEqual(model.email.masked, "x", "a failed read keeps what is shown")
        api.fetchError = BCryptoError.unauthorized
        await model.load()
        XCTAssertNil(model.email.masked)
        XCTAssertFalse(model.loadFailed)
    }
}
