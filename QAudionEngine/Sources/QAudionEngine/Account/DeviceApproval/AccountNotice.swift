import Foundation

/// The `account_notice` codes that have a screen on this device. Any other code, and a payload without a
/// string `code`, is ignored (`phone_transfer_pending` and `password_changed` keep their own handlers).
public enum AccountNoticeKind: String, Equatable, Sendable, CaseIterable {
    /// A new device waits for approval: the doorbell, the details are read over REST.
    case loginApprovalPending = "login_approval_pending"
    /// A pending sign-in of this account was denied.
    case loginDenied = "login_denied"
    /// A pending sign-in ended without an answer.
    case loginExpired = "login_expired"
    /// A pending sign-in was approved by a code sent to the email or the phone, or by the administrator.
    case loginRecovered = "login_recovered"
    /// This device was disconnected by a sign-in on a new device.
    case deviceDisconnected = "device_disconnected"
    /// The recovery email or phone changed.
    case recoveryContactChanged = "recovery_contact_changed"
    /// The phone number of this account was linked to another account.
    case phoneMoved = "phone_moved"

    /// Notices that open a banner or alert; the doorbell opens the approval sheet instead.
    public var isInformational: Bool { self != .loginApprovalPending }
}

public enum AccountNotice {
    /// Reads the WebSocket `account_notice` message.
    public static func kind(_ data: [String: Any]) -> AccountNoticeKind? {
        guard let code = data["code"] as? String else { return nil }
        return AccountNoticeKind(rawValue: code)
    }

    /// The push that rings the doorbell: custom key `type` = `login_approval_pending` (the payload flattened
    /// to strings). A missing or different `type` is ignored.
    public static func isApprovalPush(userInfo: [String: String]) -> Bool {
        userInfo["type"] == AccountNoticeKind.loginApprovalPending.rawValue
    }
}

/// What the person chose on the "disconnect the other devices?" prompt after an approved sign-in.
public enum DisconnectChoice: Equatable, Sendable {
    case disconnectAll
    /// Pick the devices one by one on the devices screen.
    case choose
    case keep
}

public enum DisconnectPrompt {
    /// The option that is selected when the prompt opens.
    public static func defaultChoice(for prompt: RevokePrompt) -> DisconnectChoice {
        prompt == .disconnectAll ? .disconnectAll : .keep
    }
}
