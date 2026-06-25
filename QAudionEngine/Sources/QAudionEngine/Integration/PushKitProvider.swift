import Foundation
#if canImport(PushKit) && os(iOS)
import PushKit
#endif

public final class PushKitProvider {

    /// Decoded form of the §5.7 VoIP payload. Public so unit tests can use it.
    public struct ParsedPayload: Equatable {
        public let callId: UUID
        public let callerId: String
        public let callerName: String
        public let hasVideo: Bool
    }

    public enum DecodeError: Error {
        case wrongType(String)
        case missingField(String)
        case badUUID(String)
    }

    /// Stateless payload parser. Pure function, testable on any platform.
    public static func parsePayload(_ dict: [String: Any]) throws -> ParsedPayload {
        guard let type = dict["type"] as? String, type == "incoming_call" else {
            throw DecodeError.wrongType(dict["type"] as? String ?? "<absent>")
        }
        guard let callIdStr = dict["call_id"] as? String else {
            throw DecodeError.missingField("call_id")
        }
        guard let callId = UUID(uuidString: callIdStr) else {
            throw DecodeError.badUUID(callIdStr)
        }
        guard let callerId = dict["caller_id"] as? String else {
            throw DecodeError.missingField("caller_id")
        }
        guard let callerName = dict["caller_name"] as? String else {
            throw DecodeError.missingField("caller_name")
        }
        let callTypeStr = (dict["call_type"] as? String) ?? "audio"
        let hasVideo = (callTypeStr == "video")
        return ParsedPayload(
            callId: callId,
            callerId: callerId,
            callerName: callerName,
            hasVideo: hasVideo
        )
    }

    // MARK: - PushKit-only behaviors (iOS-only)

    #if canImport(PushKit) && os(iOS)
    public typealias TokenHandler = (Data) async -> Void
    public typealias IncomingHandler = (ParsedPayload) async -> Void
    /// Fired when a VoIP push arrives that we CANNOT decode into a call
    /// (wrong type / missing field / bad UUID / non-[String:Any] payload).
    /// The handler MUST still report-and-end a placeholder call to CallKit —
    /// see the iOS mandate note in `didReceiveIncomingPushWith`.
    public typealias MalformedHandler = () async -> Void

    private let registry: PKPushRegistry
    private let onTokenUpdate: TokenHandler
    private let onIncomingCall: IncomingHandler
    private let onMalformedPush: MalformedHandler?

    private final class Delegate: NSObject, PKPushRegistryDelegate {
        weak var owner: PushKitProvider?
        func pushRegistry(_ registry: PKPushRegistry,
                          didUpdate pushCredentials: PKPushCredentials,
                          for type: PKPushType) {
            guard type == .voIP else { return }
            Task { await self.owner?.onTokenUpdate(pushCredentials.token) }
        }
        func pushRegistry(_ registry: PKPushRegistry,
                          didReceiveIncomingPushWith payload: PKPushPayload,
                          for type: PKPushType,
                          completion: @escaping () -> Void) {
            guard type == .voIP else { completion(); return }
            // iOS MANDATE (iOS 13+): every VoIP push MUST report a new incoming
            // call to CallKit before completion(). If it doesn't, the system
            // terminates the app and — on repeated violations — STOPS delivering
            // VoIP pushes, so the device silently goes unreachable for calls.
            // Therefore on ANY decode failure we STILL report (then end) a
            // placeholder call via onMalformedPush. Also use a SAFE cast: the old
            // `as! [String: Any]` could crash on a non-string-keyed payload — an
            // uncaught crash, which is itself a missed-report violation.
            let dict = (payload.dictionaryPayload as? [String: Any]) ?? [:]
            if let parsed = try? PushKitProvider.parsePayload(dict) {
                Task {
                    await self.owner?.onIncomingCall(parsed)
                    completion()
                }
            } else {
                Task {
                    await self.owner?.onMalformedPush?()
                    completion()
                }
            }
        }
    }

    private let delegate = Delegate()

    public init(onTokenUpdate: @escaping TokenHandler,
                onIncomingCall: @escaping IncomingHandler,
                onMalformedPush: MalformedHandler? = nil) {
        self.onTokenUpdate = onTokenUpdate
        self.onIncomingCall = onIncomingCall
        self.onMalformedPush = onMalformedPush
        self.registry = PKPushRegistry(queue: .main)
        delegate.owner = self
        registry.delegate = delegate
        registry.desiredPushTypes = [.voIP]
    }
    #endif
}
