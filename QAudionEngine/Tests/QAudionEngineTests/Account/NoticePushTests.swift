import XCTest
@testable import QAudionEngine

/// The notice push of a pending phone-number transfer: when the app asks for the permission and
/// registers, the request that carries the token, and what a tap on the notification does.
final class NoticePushTests: XCTestCase {

    private let hex = String(repeating: "ab", count: 32)

    // MARK: - when to ask and register

    func testNothingBeforeSignIn() {
        for auth in [NoticePushAuthorization.notDetermined, .denied, .granted] {
            XCTAssertEqual(
                NoticePushPolicy.step(callKitFree: false, authenticated: false, authorization: auth), .none,
                "the permission is never asked, and nothing registered, before sign-in")
        }
    }

    func testAnUndecidedPermissionIsAskedOnce() {
        XCTAssertEqual(
            NoticePushPolicy.step(callKitFree: false, authenticated: true, authorization: .notDetermined),
            .askThenRegister)
    }

    func testAGrantedPermissionRegistersWithoutAsking() {
        XCTAssertEqual(
            NoticePushPolicy.step(callKitFree: false, authenticated: true, authorization: .granted), .register)
    }

    func testADeniedPermissionRegistersNothingAndIsNotAskedAgain() {
        XCTAssertEqual(
            NoticePushPolicy.step(callKitFree: false, authenticated: true, authorization: .denied), .none)
    }

    func testTheAlertCallPathKeepsItsOwnBehaviour() {
        for auth in [NoticePushAuthorization.notDetermined, .denied, .granted] {
            XCTAssertEqual(
                NoticePushPolicy.step(callKitFree: true, authenticated: true, authorization: auth), .none,
                "with callKitFree the existing token path owns the registration")
        }
    }

    // MARK: - the request

    func testTheNoticePathIsNotTheCallAlertPath() {
        XCTAssertEqual(AccountApnsTokenRoute.callAlert.path, "/api/v1/account/apns-token")
        XCTAssertEqual(AccountApnsTokenRoute.notice.path, "/api/v1/account/apns-notice-token")
    }

    func testTheNoticeRequestHasTheSameBodyAsTheCallAlertRequest() throws {
        let notice = try XCTUnwrap(AccountApnsTokenRequest.make(
            serverUrl: "https://server.test", route: .notice, hex: hex, bundleId: "com.example.app", bearer: "tok"))
        let alert = try XCTUnwrap(AccountApnsTokenRequest.make(
            serverUrl: "https://server.test", route: .callAlert, hex: hex, bundleId: "com.example.app", bearer: "tok"))
        XCTAssertEqual(notice.httpBody, alert.httpBody)
        let bodyData = try XCTUnwrap(notice.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: String])
        XCTAssertEqual(json, ["apns_token": hex, "bundle_id": "com.example.app"])
        XCTAssertEqual(notice.httpMethod, "POST")
        XCTAssertEqual(notice.url?.absoluteString, "https://server.test/api/v1/account/apns-notice-token")
        XCTAssertEqual(alert.url?.absoluteString, "https://server.test/api/v1/account/apns-token")
        XCTAssertEqual(notice.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(notice.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testTrailingSlashesOnTheServerUrlAreDropped() throws {
        let request = try XCTUnwrap(AccountApnsTokenRequest.make(
            serverUrl: "https://server.test/base//", route: .notice, hex: hex, bundleId: "b", bearer: "t"))
        XCTAssertEqual(request.url?.absoluteString, "https://server.test/base/api/v1/account/apns-notice-token")
    }

    func testAMalformedTokenMakesNoRequest() {
        for bad in ["", "abc", String(repeating: "zz", count: 32), String(repeating: "a", count: 63),
                    String(repeating: "a", count: 65)] {
            XCTAssertFalse(AccountApnsTokenRequest.isValid(hex: bad), bad)
            XCTAssertNil(AccountApnsTokenRequest.make(
                serverUrl: "https://server.test", route: .notice, hex: bad, bundleId: "b", bearer: "t"))
        }
        XCTAssertTrue(AccountApnsTokenRequest.isValid(hex: hex))
        XCTAssertTrue(AccountApnsTokenRequest.isValid(hex: String(repeating: "AB", count: 32)))
    }

    // MARK: - one request per token, per account

    func testTheSameTokenIsNotSentTwiceAtOnce() {
        var inFlight = AccountApnsTokenInFlight()
        XCTAssertNotNil(inFlight.begin(hex: hex))
        XCTAssertNil(inFlight.begin(hex: hex), "launch, login and foreground can deliver the same token together")
        XCTAssertNotNil(inFlight.begin(hex: String(repeating: "cd", count: 32)), "another token is a new request")
    }

    func testAFinishedRequestLetsTheTokenBeSentAgain() throws {
        var inFlight = AccountApnsTokenInFlight()
        let ticket = try XCTUnwrap(inFlight.begin(hex: hex))
        inFlight.finish(ticket: ticket)
        XCTAssertNotNil(inFlight.begin(hex: hex), "a later foreground re-sends the token, so a server-side clear heals")
    }

    func testLogoutThenAnotherAccountOnTheSameTokenRegistersAgain() throws {
        var inFlight = AccountApnsTokenInFlight()
        let first = try XCTUnwrap(inFlight.begin(hex: hex))   // account A, request still running
        inFlight.reset()                                      // logout / account change
        let second = try XCTUnwrap(inFlight.begin(hex: hex), "account B must register the same token")
        XCTAssertNotEqual(first, second)
        inFlight.finish(ticket: first)                        // the late answer for account A
        XCTAssertNil(inFlight.begin(hex: hex), "it must not clear account B's request")
        inFlight.finish(ticket: second)
        XCTAssertNotNil(inFlight.begin(hex: hex))
    }

    // MARK: - the tap

    func testOnlyThePendingTransferTypeIsRouted() {
        XCTAssertTrue(PhoneTransferNotice.isPendingPush(
            userInfo: ["type": "phone_transfer_pending", "transfer_id": "t-1"]))
        XCTAssertTrue(PhoneTransferNotice.isPendingPush(userInfo: ["type": "phone_transfer_pending"]),
                      "the transfer id is not needed: the list is read from the server")
    }

    func testOtherTypesAndMalformedPayloadsAreIgnored() {
        let ignored: [[String: String]] = [
            [:],
            ["type": "incoming_group_call"],
            ["type": "message"],
            ["type": ""],
            ["type": "Phone_Transfer_Pending"],
            ["type": "phone_transfer_pending "],
            ["transfer_id": "t-1"],
            ["code": "phone_transfer_pending"],
            ["conversationId": "x"],
        ]
        for info in ignored {
            XCTAssertFalse(PhoneTransferNotice.isPendingPush(userInfo: info), "\(info)")
        }
    }
}
