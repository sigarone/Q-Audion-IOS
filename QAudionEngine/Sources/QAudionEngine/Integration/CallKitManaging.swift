import Foundation

/// Abstracts CallKit so the engine compiles on non-iOS targets (macOS, Linux).
/// The concrete iOS adapter is implemented behind `#if canImport(CallKit) && os(iOS)`
/// in Phase B.1. Unit tests use `MockCallKitManager`.
public protocol CallKitManaging: AnyObject, Sendable {
    /// Report an incoming call to the system so CallKit can display the incoming-call UI.
    func reportIncomingCall(uuid: UUID, callerName: String, hasVideo: Bool) async

    /// Report that a call has ended with the given reason.
    func reportCallEnded(uuid: UUID, reason: CallEndReason) async

    /// Start an outgoing call and return the UUID assigned to it.
    func startOutgoingCall(handle: String, hasVideo: Bool) async throws -> UUID

    /// Notify the system that the call is now fully connected.
    func reportCallConnected(uuid: UUID) async

    /// Mute or un-mute the call.
    func setMuted(uuid: UUID, isMuted: Bool) async throws

    /// Put the call on hold or take it off hold.
    func setOnHold(uuid: UUID, isOnHold: Bool) async throws
}

/// Reason a call was ended. Maps to `CXCallEndedReason` in the iOS-only adapter.
public enum CallEndReason: Sendable {
    case userEnded
    case remoteEnded
    case unanswered
    case failed(String)
    case declined
}
