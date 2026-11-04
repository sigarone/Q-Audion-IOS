import XCTest
@testable import QAudionEngine

/// Round 2 of the saved-login rules: sign-out keeps the item, a changed biometric set drops it,
/// passwords are measured in Unicode scalars, the own-device notice is ignored.
final class SavedLoginLifecycleTests: XCTestCase {
    private final class FakeKeychain: SavedLoginKeychain {
        var data: Data?
        var invalidated = false
        var authFails = false
        func write(_ data: Data) -> Bool { self.data = data; return true }
        func read(reason: String) -> (data: Data?, authenticationFailed: Bool) {
            if authFails { return (nil, true) }
            return (data, false)
        }
        // Like the production Keychain: an invalidated item reads as absent.
        func exists() -> Bool { data != nil && !invalidated }
        func isInvalidated() -> Bool { data != nil && invalidated }
        func delete() { data = nil }
    }

    private var keychain: FakeKeychain!
    private var defaults: UserDefaults!
    private var store: SavedLoginStore!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "saved-login-lifecycle-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        keychain = FakeKeychain()
        store = SavedLoginStore(keychain: keychain, defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: biometric set changed

    func test_changedBiometricSetHidesTheButtonDeletesTheItemAndResetsTheDecision() {
        store.save(SavedLogin(extensionNumber: "176", password: "pw-123456"))
        keychain.invalidated = true
        XCTAssertFalse(store.hasSavedLogin)
        XCTAssertNil(keychain.data, "the unusable item is deleted")
        XCTAssertEqual(store.decision, .unasked)
        XCTAssertTrue(store.shouldAsk)
    }

    func test_nextLoginAfterBiometricSetChangeDoesNotSilentlyResave() {
        store.save(SavedLogin(extensionNumber: "176", password: "old-pw-123"))
        keychain.invalidated = true
        XCTAssertFalse(store.hasSavedLogin)
        XCTAssertNil(keychain.data)
        XCTAssertEqual(store.decision, .unasked)
        // The password login that follows: the sign-in code purges, then updateIfSaved.
        store.purgeIfInvalidated()
        store.updateIfSaved(SavedLogin(extensionNumber: "176", password: "new-pw-123"))
        XCTAssertNil(keychain.data, "nothing was saved under the new biometric set")
        XCTAssertEqual(store.decision, .unasked)
        XCTAssertTrue(store.shouldAsk, "the offer is shown again")
    }

    func test_updateIfSavedAloneAfterBiometricSetChangeDoesNotResave() {
        store.save(SavedLogin(extensionNumber: "176", password: "old-pw-123"))
        keychain.invalidated = true
        store.updateIfSaved(SavedLogin(extensionNumber: "176", password: "new-pw-123"))
        XCTAssertNil(keychain.data)
        XCTAssertTrue(store.shouldAsk)
    }

    func test_declinedAnswerSurvivesWhenNoBiometryIsEnrolled() {
        store.decline()
        keychain.invalidated = true
        XCTAssertFalse(store.hasSavedLogin)
        XCTAssertEqual(store.decision, .declined)
    }

    func test_loadAfterBiometricSetChangePurgesInsteadOfReportingCancelled() {
        store.save(SavedLogin(extensionNumber: "176", password: "pw-123456"))
        keychain.invalidated = true
        keychain.authFails = true
        XCTAssertEqual(store.load(reason: "r"), .notFound)
        XCTAssertNil(keychain.data)
        XCTAssertEqual(store.decision, .unasked)
    }

    func test_failedFaceScanWithSameBiometricSetKeepsTheItem() {
        store.save(SavedLogin(extensionNumber: "176", password: "pw-123456"))
        keychain.authFails = true
        XCTAssertEqual(store.load(reason: "r"), .notAuthenticated)
        XCTAssertTrue(store.hasSavedLogin)
    }

    func test_biometrySetCheck() {
        let a = Data([1, 2, 3]), b = Data([9, 9])
        XCTAssertTrue(BiometrySetCheck.isInvalidated(stored: a, current: b, notEnrolled: false))
        XCTAssertFalse(BiometrySetCheck.isInvalidated(stored: a, current: a, notEnrolled: false))
        XCTAssertTrue(BiometrySetCheck.isInvalidated(stored: a, current: nil, notEnrolled: true), "biometryNotEnrolled")
        XCTAssertFalse(BiometrySetCheck.isInvalidated(stored: nil, current: b, notEnrolled: false), "nothing recorded: cannot tell")
        XCTAssertFalse(BiometrySetCheck.isInvalidated(stored: a, current: nil, notEnrolled: false), "locked out: not a change")
    }

    // MARK: password length

    func test_lengthIsCountedInUnicodeScalars() {
        // Two family emoji are 2 graphemes but 10 scalars: long enough.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertNil(PasswordPolicy.lengthProblem(family + family))
        // 7 scalars in 7 graphemes is too short; 7 graphemes of 2 scalars (flags) are 14 scalars: fine.
        XCTAssertEqual(PasswordPolicy.lengthProblem("abcdefg"), .tooShort)
        let flag = "\u{1F1EE}\u{1F1F9}"
        XCTAssertNil(PasswordPolicy.lengthProblem(String(repeating: flag, count: 7)))
        // 22 family emoji: 22 graphemes but 110 scalars.
        XCTAssertEqual(PasswordPolicy.lengthProblem(String(repeating: family, count: 22)), .tooLong)
        // 64 scalars of ASCII is the limit; 65 is over; 73 bytes of 2-byte scalars is over the byte cap.
        XCTAssertNil(PasswordPolicy.lengthProblem(String(repeating: "a", count: 64)))
        XCTAssertEqual(PasswordPolicy.lengthProblem(String(repeating: "a", count: 65)), .tooLong)
        XCTAssertEqual(PasswordPolicy.lengthProblem(String(repeating: "\u{00E8}", count: 37)), .tooLong)
    }

    // MARK: own password_changed notice

    func test_noticeAfterOwnChangeIsIgnored() {
        let now = Date()
        XCTAssertFalse(PasswordChangedNoticeFilter.shouldShow(
            now: now, lastLocalChange: now.addingTimeInterval(-3), noticeDeviceId: nil, ownDeviceId: "d1"))
        XCTAssertTrue(PasswordChangedNoticeFilter.shouldShow(
            now: now, lastLocalChange: now.addingTimeInterval(-300), noticeDeviceId: nil, ownDeviceId: "d1"))
        XCTAssertTrue(PasswordChangedNoticeFilter.shouldShow(
            now: now, lastLocalChange: nil, noticeDeviceId: nil, ownDeviceId: "d1"))
    }

    func test_noticeCarryingOwnDeviceIdIsIgnored() {
        XCTAssertFalse(PasswordChangedNoticeFilter.shouldShow(
            now: Date(), lastLocalChange: nil, noticeDeviceId: "d1", ownDeviceId: "d1"))
        XCTAssertTrue(PasswordChangedNoticeFilter.shouldShow(
            now: Date(), lastLocalChange: nil, noticeDeviceId: "d2", ownDeviceId: "d1"))
    }

    // MARK: source invariants (the app target cannot be driven here)

    private func source(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let c = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: c.path) {
                let raw = try String(contentsOf: c, encoding: .utf8)
                let noComments = raw.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
                    .map { line -> Substring in
                        if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                        return line
                    }.joined(separator: "\n")
                return noComments.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
        }
        XCTFail("\(relativePath) not found")
        return ""
    }

    func test_clearTokenKeepsTheSavedLogin() throws {
        let auth = try source("QAudionApp/Services/AuthService.swift")
        let start = try XCTUnwrap(auth.range(of: "func clearToken() {"))
        let body = auth[start.upperBound...].prefix(600)
        XCTAssertFalse(body.contains("SavedLoginStore"), "a normal sign-out keeps the saved login")
    }

    func test_savedLoginIsDeletedOnWipeLockAndDeletion() throws {
        let app = try source("QAudionApp/AppState.swift")
        XCTAssertGreaterThanOrEqual(app.components(separatedBy: "SavedLoginStore.shared.deleteAll()").count - 1, 2,
                                    "remote_wipe and account_locked")
        let legal = try source("QAudionApp/Services/LegalService.swift")
        XCTAssertTrue(legal.contains("SavedLoginStore.shared.deleteAll()"))
        let settings = try source("QAudionApp/Views/Settings/AccountSettingsScreen.swift")
        XCTAssertTrue(settings.contains("SavedLoginStore.shared.deleteAll()"))
        let login = try source("QAudionApp/Views/Onboarding/ExtensionLoginScreen.swift")
        XCTAssertTrue(login.contains("lastLoginRejectedAsInvalid") && login.contains("store.deleteAll()"),
                      "a saved password the server rejects is dropped")
    }
}
