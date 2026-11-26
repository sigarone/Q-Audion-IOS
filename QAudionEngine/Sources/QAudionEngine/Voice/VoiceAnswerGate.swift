import Foundation

/// The start of the contact-voice check at the point where THIS device answered a call. The call screen of the answering side is
/// reached by no frame of the caller, so the check starts here, once the connection of the call exists: armed at the answer with the
/// id of that call, asked again by every event that can make the call ready (the call object, its peer, its connection), with no time
/// limit while that call is the live one, and exactly once. A call that ended or was replaced never starts.
public struct VoiceAnswerGate: Equatable, Sendable {
    public private(set) var armedCallId: String?
    private var armed = false
    private var done = false

    public init() {}

    /// The call was answered. `callId` is the id known at that moment (nil when it is not bound yet: the first question captures it).
    public mutating func arm(callId: String?) {
        armed = true
        done = false
        armedCallId = callId?.lowercased()
    }

    /// The call ended, or the check was started elsewhere.
    public mutating func disarm() {
        armed = false
        done = false
        armedCallId = nil
    }

    /// The id of the call to start the check for now, or nil. A different live call than the armed one disarms the gate.
    public mutating func pending(activeCallId: String?, inCall: Bool) -> String? {
        guard armed, !done, inCall, let active = activeCallId?.lowercased(), !active.isEmpty else { return nil }
        if armedCallId == nil { armedCallId = active }
        if armedCallId != active {
            disarm() // the answered call is gone and another one is live
            return nil
        }
        return active
    }

    /// The check started for the armed call.
    public mutating func started() {
        done = true
    }
}
