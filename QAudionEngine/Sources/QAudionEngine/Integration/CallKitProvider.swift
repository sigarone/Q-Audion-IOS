import Foundation
#if canImport(CallKit) && os(iOS)
@preconcurrency import CallKit
import AVFoundation

public final class CallKitProvider: NSObject, CallKitManaging, CXProviderDelegate, @unchecked Sendable {

    private let provider: CXProvider
    private let controller: CXCallController
    public var onAnswerCall: ((UUID) async -> Void)?
    public var onEndCall: ((UUID) async -> Void)?
    public var onMutedChanged: ((UUID, Bool) async -> Void)?

    public override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = true
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.phoneNumber, .generic]
        cfg.iconTemplateImageData = nil
        cfg.ringtoneSound = nil
        self.provider = CXProvider(configuration: cfg)
        self.controller = CXCallController()
        super.init()
        self.provider.setDelegate(self, queue: nil)
    }

    // MARK: - CallKitManaging

    public func reportIncomingCall(uuid: UUID, callerName: String, hasVideo: Bool) async {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.hasVideo = hasVideo
        update.localizedCallerName = callerName
        do {
            try await provider.reportNewIncomingCall(with: uuid, update: update)
        } catch {
            // Server emitted incoming-call but iOS rejected (e.g. Focus mode).
            // Silently drop — do NOT throw upward; CallService will time out separately.
        }
    }

    public func reportCallEnded(uuid: UUID, reason: CallEndReason) async {
        let cxReason: CXCallEndedReason
        switch reason {
        case .userEnded: cxReason = .remoteEnded
        case .remoteEnded: cxReason = .remoteEnded
        case .unanswered: cxReason = .unanswered
        case .declined: cxReason = .declinedElsewhere
        case .failed: cxReason = .failed
        }
        provider.reportCall(with: uuid, endedAt: Date(), reason: cxReason)
    }

    public func startOutgoingCall(handle: String, hasVideo: Bool) async throws -> UUID {
        let uuid = UUID()
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
        action.isVideo = hasVideo
        let txn = CXTransaction(action: action)
        try await controller.request(txn)
        return uuid
    }

    public func reportCallConnected(uuid: UUID) async {
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    public func setMuted(uuid: UUID, isMuted: Bool) async throws {
        let action = CXSetMutedCallAction(call: uuid, muted: isMuted)
        try await controller.request(CXTransaction(action: action))
    }

    public func setOnHold(uuid: UUID, isOnHold: Bool) async throws {
        let action = CXSetHeldCallAction(call: uuid, onHold: isOnHold)
        try await controller.request(CXTransaction(action: action))
    }

    // MARK: - CXProviderDelegate

    public func providerDidReset(_ provider: CXProvider) {
        // System reset — pending calls are gone.
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task {
            await onAnswerCall?(action.callUUID)
            action.fulfill()
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task {
            await onEndCall?(action.callUUID)
            action.fulfill()
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task {
            await onMutedChanged?(action.callUUID, action.isMuted)
            action.fulfill()
        }
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        try? audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try? audioSession.setActive(true)
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // System took the audio session — engine should pause mic capture.
    }
}
#endif
