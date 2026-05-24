import Foundation
@testable import QAudionEngine

/// In-memory record of a single CallKit action invoked on `MockCallKitManager`.
struct CallRecord: Equatable {
    enum Action: Equatable {
        case reportIncomingCall(uuid: UUID, callerName: String, hasVideo: Bool)
        case reportCallEnded(uuid: UUID, reason: CallEndReason)
        case startOutgoingCall(handle: String, hasVideo: Bool)
        case reportCallConnected(uuid: UUID)
        case setMuted(uuid: UUID, isMuted: Bool)
        case setOnHold(uuid: UUID, isOnHold: Bool)
    }

    let action: Action

    // MARK: - Equatable conformance for CallEndReason

    static func == (lhs: CallRecord, rhs: CallRecord) -> Bool {
        lhs.action == rhs.action
    }
}

extension CallEndReason: Equatable {
    public static func == (lhs: CallEndReason, rhs: CallEndReason) -> Bool {
        switch (lhs, rhs) {
        case (.userEnded, .userEnded): return true
        case (.remoteEnded, .remoteEnded): return true
        case (.unanswered, .unanswered): return true
        case (.declined, .declined): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

/// Thread-safe mock that records every call for assertion in unit tests.
final class MockCallKitManager: CallKitManaging, @unchecked Sendable {
    // Recorded invocations in call order.
    private let lock = NSLock()
    private var _records: [CallRecord] = []

    var records: [CallRecord] {
        lock.lock()
        defer { lock.unlock() }
        return _records
    }

    // Configurable stub responses.
    var startOutgoingCallResult: Result<UUID, Error> = .success(UUID())
    var setMutedError: Error? = nil
    var setOnHoldError: Error? = nil

    // MARK: - CallKitManaging

    func reportIncomingCall(uuid: UUID, callerName: String, hasVideo: Bool) async {
        append(.reportIncomingCall(uuid: uuid, callerName: callerName, hasVideo: hasVideo))
    }

    func reportCallEnded(uuid: UUID, reason: CallEndReason) async {
        append(.reportCallEnded(uuid: uuid, reason: reason))
    }

    func startOutgoingCall(handle: String, hasVideo: Bool) async throws -> UUID {
        append(.startOutgoingCall(handle: handle, hasVideo: hasVideo))
        switch startOutgoingCallResult {
        case .success(let uuid): return uuid
        case .failure(let error): throw error
        }
    }

    func reportCallConnected(uuid: UUID) async {
        append(.reportCallConnected(uuid: uuid))
    }

    func setMuted(uuid: UUID, isMuted: Bool) async throws {
        append(.setMuted(uuid: uuid, isMuted: isMuted))
        if let error = setMutedError { throw error }
    }

    func setOnHold(uuid: UUID, isOnHold: Bool) async throws {
        append(.setOnHold(uuid: uuid, isOnHold: isOnHold))
        if let error = setOnHoldError { throw error }
    }

    func answerCall(uuid: UUID) async throws {
        // W478 — no-op stub; tests that exercise in-app answer can subclass
        // or observe via records if needed.
    }

    // MARK: - Helpers

    private func append(_ action: CallRecord.Action) {
        lock.lock()
        defer { lock.unlock() }
        _records.append(CallRecord(action: action))
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        _records.removeAll()
    }
}
