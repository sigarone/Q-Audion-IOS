import Foundation

/// Pure decisions for delivering the callee's `call_accepted` when the first
/// send did not go out on an authenticated socket. No socket or call state
/// lives here, so every branch is unit-testable.
public enum CallAcceptResend {

    /// Delays between resends once the socket is authenticated.
    public static let ladderMs: [Int] = [2_500, 5_000, 10_000]

    /// How many 5 s authentication waits the resend path makes before giving up.
    public static let authWaitAttempts: Int = 6

    /// The ladder keeps going while the call is still the bound one and the
    /// caller has not been proven to have finalized.
    public static func shouldContinue(isBound: Bool, proven: Bool) -> Bool {
        isBound && !proven
    }

    /// A progression signal (media from the caller, an answer) only proves
    /// the caller got an accept that left on an authenticated socket: a
    /// signal seen before that cannot vouch for it.
    public static func provesCallerFinalized(authenticatedSendDone: Bool, signalReceived: Bool) -> Bool {
        authenticatedSendDone && signalReceived
    }
}

/// The accepted call id held while no provider (or no authenticated socket)
/// exists to carry `call_accepted`. Released only for the call that is still
/// the active one, so a late accept never attaches to another call.
public struct PendingCallAccept: Equatable {
    public private(set) var callId: String?

    public init() {}

    public mutating func hold(callId: String) {
        self.callId = callId.lowercased()
    }

    public mutating func clear() {
        callId = nil
    }

    /// Returns the held id when it is the active call (and clears it). A
    /// different active call drops the held id; no active call keeps it.
    public mutating func take(activeCallId: String?) -> String? {
        guard let held = callId else { return nil }
        guard let active = activeCallId, !active.isEmpty else { return nil }
        callId = nil
        return held == active.lowercased() ? held : nil
    }
}
