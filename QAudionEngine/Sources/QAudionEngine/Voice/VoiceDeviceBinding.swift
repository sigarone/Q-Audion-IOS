import Foundation

/// The peer device id that the contact-voice check uses, BOUND TO ONE CALL: the device tag and the trust row of the tier are per
/// device, and a value that an earlier call left behind would read another device's row.
///
/// The device is the one that the handshake's identity check used for this call (`bind`: the offer's sender on the responder, the
/// answer's device on the initiator). The sender of the accept message (`noteAccept`) is a cross-check only: when both are present
/// and differ, the call has no trustworthy device and it is UNKNOWN for this call (tier 0), never one of the two. A nil id is never
/// "a new device". Entries are per call id and are removed when the call ends.
public final class VoiceDeviceBinding: @unchecked Sendable {
    private struct Bound {
        var answer: String?
        var accept: String?
        /// The device that the server stamped on the `call_answer` of an outgoing call.
        var answerSender: String?
        var mismatch: Bool { answer != nil && accept != nil && answer != accept }
        var effective: String? {
            if answer != nil { return mismatch ? nil : answer }
            // Outgoing call: the answering device counts only when the sender of the accept message is the same one.
            if let answerSender, answerSender == accept { return answerSender }
            return nil
        }
    }

    private let lock = NSLock()
    private var bound: [String: Bound] = [:]

    public init() {}

    private static func clean(_ id: String?) -> String? {
        guard let id = id?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        return id
    }

    /// The device that the identity check used. A nil or blank id never erases a known one.
    public func bind(callId: String, deviceId: String?) {
        let key = callId.lowercased()
        lock.lock()
        var b = bound[key] ?? Bound()
        b.answer = Self.clean(deviceId) ?? b.answer
        bound[key] = b
        lock.unlock()
    }

    /// The sender of the accept message: a cross-check only.
    public func noteAccept(callId: String, deviceId: String?) {
        let key = callId.lowercased()
        lock.lock()
        var b = bound[key] ?? Bound()
        b.accept = Self.clean(deviceId) ?? b.accept
        bound[key] = b
        lock.unlock()
    }

    /// The sender of the `call_answer` of an outgoing call. It binds the device only when the sender of the accept message is the
    /// same device, whatever the order in which the two arrive; a missing or a different one leaves the device unknown.
    public func noteAnswerSender(callId: String, deviceId: String?) {
        let key = callId.lowercased()
        lock.lock()
        var b = bound[key] ?? Bound()
        b.answerSender = Self.clean(deviceId) ?? b.answerSender
        bound[key] = b
        lock.unlock()
    }

    /// True when the device of this call comes from the `call_answer` and not from the identity check.
    public func isFromAnswerSender(forCall callId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let b = bound[callId.lowercased()] else { return false }
        return b.answer == nil && b.effective != nil
    }

    /// The device of exactly this call, or nil when none is known (or the two sources disagree).
    public func device(forCall callId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return bound[callId.lowercased()]?.effective
    }

    public func clear(callId: String) {
        lock.lock()
        bound.removeValue(forKey: callId.lowercased())
        lock.unlock()
    }
}
