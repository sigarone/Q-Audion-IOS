import XCTest
@testable import QAudionEngine

final class LoginApprovalTypesTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private let ticketJson = """
    {"status":"approval_required","pending_id":"p-1","poll_token":"tok-secret","match_code":47,
     "expires_at":"2026-11-04T10:10:00Z","short_code":"ABCD2345","recovery":{"email":true,"sms":false}}
    """

    func test_ticket_isReadFromThe202Body() throws {
        let outcome = try LoginOutcome.parse(status: 202, data: data(ticketJson))
        guard case .approvalRequired(let ticket) = outcome else { return XCTFail("expected a pending state") }
        XCTAssertEqual(ticket.pendingId, "p-1")
        XCTAssertEqual(ticket.pollToken, "tok-secret")
        XCTAssertEqual(ticket.matchCode, "47", "a numeric match code is kept as text")
        XCTAssertEqual(ticket.shortCode, "ABCD2345")
        XCTAssertEqual(ticket.expiresAt, Date(timeIntervalSince1970: 1_793_787_000))
        XCTAssertTrue(ticket.emailRecovery)
        XCTAssertFalse(ticket.smsRecovery)
        XCTAssertNil(ticket.emailHint)
    }

    func test_ticket_acceptsTextMatchCodeAndEpochMilliseconds() throws {
        let outcome = try LoginOutcome.parse(status: 202, data: data("""
        {"pending_id":"p","poll_token":"t","match_code":"12","expires_at":1793787000000,"short_code":"S",
         "recovery":{"email":true,"sms":true,"email_hint":"m***@g***.com","sms_hint":"+39 ***45"}}
        """))
        guard case .approvalRequired(let ticket) = outcome else { return XCTFail("expected a pending state") }
        XCTAssertEqual(ticket.matchCode, "12")
        XCTAssertEqual(ticket.expiresAt, Date(timeIntervalSince1970: 1_793_787_000))
        XCTAssertEqual(ticket.emailHint, "m***@g***.com")
        XCTAssertEqual(ticket.phoneHint, "+39 ***45")
    }

    func test_ticket_withoutRecoveryObject_offersNoRecovery() throws {
        let outcome = try LoginOutcome.parse(status: 202, data: data("""
        {"pending_id":"p","poll_token":"t","match_code":"12","expires_at":"2026-11-04T10:10:00Z","short_code":"S"}
        """))
        guard case .approvalRequired(let ticket) = outcome else { return XCTFail("expected a pending state") }
        XCTAssertFalse(ticket.emailRecovery)
        XCTAssertFalse(ticket.smsRecovery)
    }

    func test_ticket_missingAField_isADecodingError() {
        XCTAssertThrowsError(try LoginOutcome.parse(status: 202, data: data("{\"pending_id\":\"p\"}"))) { error in
            guard case BCryptoError.decodingError = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try LoginOutcome.parse(status: 202, data: data("not json")))
    }

    func test_ticket_descriptionNeverShowsThePollToken() throws {
        guard case .approvalRequired(let ticket) = try LoginOutcome.parse(status: 202, data: data(ticketJson)) else {
            return XCTFail("expected a pending state")
        }
        XCTAssertFalse("\(ticket)".contains("tok-secret"))
        XCTAssertFalse(String(reflecting: ticket).contains("tok-secret"))
    }

    func test_plainSession_is200WithAToken() throws {
        let outcome = try LoginOutcome.parse(status: 200, data: data("""
        {"user_id":"u1","device_id":"d1","access_token":"a","refresh_token":"r","expires_in":900}
        """))
        guard case .credentials(let creds) = outcome else { return XCTFail("expected a session") }
        XCTAssertEqual(creds.userId, "u1")
        XCTAssertEqual(creds.deviceId, "d1")
        XCTAssertEqual(creds.refreshToken, "r")
    }

    func test_refusals_keepTheKnownErrors() {
        XCTAssertThrowsError(try LoginOutcome.parse(status: 401, data: data("{}"))) { error in
            guard case BCryptoError.unauthorized = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try LoginOutcome.parse(status: 402, data: data("{}"))) { error in
            guard case BCryptoError.paymentRequired = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try LoginOutcome.parse(status: 429, data: data("{}"))) { error in
            guard case BCryptoError.httpError(429) = error else { return XCTFail("\(error)") }
        }
    }

    func test_approvedLogin_readsThePairAndThePrompt() throws {
        let object = try XCTUnwrap(ApprovalWire.object(data("""
        {"user_id":"u1","device_id":"d1","access_token":"a.b.c","refresh_token":"r","expires_in":900,
         "token_type":"Bearer","revoke_prompt":"disconnect_all"}
        """)))
        let login = try XCTUnwrap(ApprovalWire.approvedLogin(from: object))
        XCTAssertEqual(login.credentials.userId, "u1")
        XCTAssertEqual(login.credentials.expiresIn, 900)
        XCTAssertEqual(login.revokePrompt, .disconnectAll)
    }

    func test_approvedLogin_withoutUserId_readsItFromTheAccessToken() throws {
        let payload = Data("{\"sub\":\"user-from-token\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let object: [String: Any] = ["device_id": "d1", "access_token": "h.\(payload).s", "revoke_prompt": "keep"]
        let login = try XCTUnwrap(ApprovalWire.approvedLogin(from: object))
        XCTAssertEqual(login.credentials.userId, "user-from-token")
        XCTAssertEqual(login.revokePrompt, .keep)
    }

    func test_approvedLogin_withoutAnyUserId_isNil() {
        XCTAssertNil(ApprovalWire.approvedLogin(from: ["device_id": "d1", "access_token": "opaque"]))
    }

    func test_revokePrompt_unknownOrMissing_isKeep() {
        XCTAssertEqual(RevokePrompt(wire: nil), .keep)
        XCTAssertEqual(RevokePrompt(wire: "something"), .keep)
        XCTAssertEqual(RevokePrompt(wire: "disconnect_all"), .disconnectAll)
    }

    func test_approvalBlob_layout() {
        let nonce = Data((0..<32).map { UInt8($0) })
        let blob = DeviceApprovalBlob.build(tag: DeviceApprovalBlob.tagApprove, serverId: "srv", pendingId: "pid",
                                            approverDeviceId: "dev", nonce: nonce)
        var expected = Data("QAUDION-APPROVE-v1".utf8)
        for part in ["srv", "pid", "dev"] {
            expected.append(0)
            expected.append(contentsOf: part.utf8)
        }
        expected.append(0)
        expected.append(nonce)
        XCTAssertEqual(blob, expected)
    }

    func test_approvalTags_arePrefixDisjointFromEveryOtherDeviceKeyUse() {
        let tags = [
            DeviceRenewBlob.domainTagDeviceRenew, DeviceRenewBlob.domainTagDeviceRevoke,
            DeviceApprovalBlob.tagApprove, DeviceApprovalBlob.tagDeny, DeviceApprovalBlob.tagRevokeOthers,
        ]
        for (i, a) in tags.enumerated() {
            for (j, b) in tags.enumerated() where i != j {
                XCTAssertFalse(a.hasPrefix(b), "\(a) starts with \(b)")
            }
        }
    }

    func test_approveAndDenyBlobs_differ() {
        let nonce = Data(repeating: 7, count: 32)
        let approve = DeviceApprovalBlob.build(tag: DeviceApprovalBlob.tagApprove, serverId: "s", pendingId: "p",
                                               approverDeviceId: "d", nonce: nonce)
        let deny = DeviceApprovalBlob.build(tag: DeviceApprovalBlob.tagDeny, serverId: "s", pendingId: "p",
                                            approverDeviceId: "d", nonce: nonce)
        XCTAssertNotEqual(approve, deny)
    }

    func test_disconnectPrompt_defaultFollowsTheServer() {
        XCTAssertEqual(DisconnectPrompt.defaultChoice(for: .keep), .keep)
        XCTAssertEqual(DisconnectPrompt.defaultChoice(for: .disconnectAll), .disconnectAll)
    }

    func test_accountNotice_codes() {
        XCTAssertEqual(AccountNotice.kind(["code": "login_denied"]), .loginDenied)
        XCTAssertEqual(AccountNotice.kind(["code": "login_expired"]), .loginExpired)
        XCTAssertEqual(AccountNotice.kind(["code": "login_recovered"]), .loginRecovered)
        XCTAssertEqual(AccountNotice.kind(["code": "device_disconnected"]), .deviceDisconnected)
        XCTAssertEqual(AccountNotice.kind(["code": "recovery_contact_changed"]), .recoveryContactChanged)
        XCTAssertEqual(AccountNotice.kind(["code": "login_approval_pending", "pending_id": "p"]), .loginApprovalPending)
        XCTAssertNil(AccountNotice.kind(["code": "phone_transfer_pending"]))
        XCTAssertNil(AccountNotice.kind(["code": 7]))
        XCTAssertNil(AccountNotice.kind([:]))
        XCTAssertFalse(AccountNoticeKind.loginApprovalPending.isInformational)
        XCTAssertTrue(AccountNoticeKind.deviceDisconnected.isInformational)
    }

    func test_approvalPush_isRecognisedByTypeOnly() {
        XCTAssertTrue(AccountNotice.isApprovalPush(userInfo: ["type": "login_approval_pending", "pending_id": "p"]))
        XCTAssertFalse(AccountNotice.isApprovalPush(userInfo: ["type": "phone_transfer_pending"]))
        XCTAssertFalse(AccountNotice.isApprovalPush(userInfo: ["code": "login_approval_pending"]))
        XCTAssertFalse(AccountNotice.isApprovalPush(userInfo: [:]))
    }
}
