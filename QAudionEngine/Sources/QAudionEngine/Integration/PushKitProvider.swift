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

    /// W-GRPRING — decoded form of the GROUP-call VoIP payload
    /// (`type == "incoming_group_call"`, server commit 9619df4:
    /// `internal/push/apns.go` SendVoIPGroupCallInvite / SendAlertGroupCallInvite).
    /// Wire: {call_id, creator_id, creator_name, call_type, group_id, group_name}.
    /// Public so unit tests can use it.
    ///
    /// `Sendable` is explicit: a PUBLIC struct does NOT get implicit Sendable
    /// conformance across a module boundary, and the app layer hands this value
    /// straight into `MainActor.run { … }` (a @Sendable closure) from the
    /// PushKit delegate — without the conformance that is a non-sendable-capture
    /// diagnostic (warning under Swift 5, error under Swift 6). All stored
    /// members are `String`, so the conformance is sound.
    public struct ParsedGroupPayload: Equatable, Sendable {
        public let callId: String        // NOT a UUID type: the room id is an
                                         // opaque server string (a UUID today).
        public let creatorId: String
        public let creatorName: String
        public let callType: String      // "audio" | "video"
        public let groupId: String       // "" for an ad-hoc (picker) group call
        public let groupName: String
        public var hasVideo: Bool { callType == "video" }
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

    /// W-GRPRING — stateless parser for the GROUP-call VoIP payload. Pure
    /// function, testable on any platform. Mirrors `parsePayload` field for
    /// field; only `call_id` + `creator_id` are mandatory (the rest degrade
    /// to sane defaults so a payload from an older server still rings).
    public static func parseGroupPayload(_ dict: [String: Any]) throws -> ParsedGroupPayload {
        guard let type = dict["type"] as? String, type == "incoming_group_call" else {
            throw DecodeError.wrongType(dict["type"] as? String ?? "<absent>")
        }
        guard let callId = dict["call_id"] as? String, !callId.isEmpty else {
            throw DecodeError.missingField("call_id")
        }
        guard let creatorId = dict["creator_id"] as? String, !creatorId.isEmpty else {
            throw DecodeError.missingField("creator_id")
        }
        return ParsedGroupPayload(
            callId: callId,
            creatorId: creatorId,
            creatorName: (dict["creator_name"] as? String) ?? "",
            callType: (dict["call_type"] as? String) ?? "audio",
            groupId: (dict["group_id"] as? String) ?? "",
            groupName: (dict["group_name"] as? String) ?? ""
        )
    }

    // MARK: - PushKit-only behaviors (iOS-only)

    #if canImport(PushKit) && os(iOS)
    public typealias TokenHandler = (Data) async -> Void
    public typealias IncomingHandler = (ParsedPayload) async -> Void
    /// W-GRPRING — fired for a `type == "incoming_group_call"` VoIP push. The
    /// handler carries the SAME iOS mandate as `IncomingHandler`: it MUST
    /// report a new incoming call to CallKit before the push completes.
    public typealias IncomingGroupHandler = (ParsedGroupPayload) async -> Void
    /// Fired when a VoIP push arrives that we CANNOT decode into a call
    /// (wrong type / missing field / bad UUID / non-[String:Any] payload).
    /// The handler MUST still report-and-end a placeholder call to CallKit —
    /// see the iOS mandate note in `didReceiveIncomingPushWith`.
    public typealias MalformedHandler = () async -> Void

    private let registry: PKPushRegistry
    private let onTokenUpdate: TokenHandler
    private let onIncomingCall: IncomingHandler
    private let onIncomingGroupCall: IncomingGroupHandler?
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
            } else if let owner = self.owner,
                      let groupHandler = owner.onIncomingGroupCall,
                      let group = try? PushKitProvider.parseGroupPayload(dict) {
                // W-GRPRING — incoming GROUP call. Same mandate as the 1:1
                // branch: the handler reports a new incoming call to CallKit.
                // If no group handler is wired we deliberately fall through to
                // onMalformedPush (report-and-end) rather than completing the
                // push silently — a VoIP push with no report kills the app.
                Task {
                    await groupHandler(group)
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
                onIncomingGroupCall: IncomingGroupHandler? = nil,
                onMalformedPush: MalformedHandler? = nil) {
        self.onTokenUpdate = onTokenUpdate
        self.onIncomingCall = onIncomingCall
        self.onIncomingGroupCall = onIncomingGroupCall
        self.onMalformedPush = onMalformedPush
        self.registry = PKPushRegistry(queue: .main)
        delegate.owner = self
        registry.delegate = delegate
        registry.desiredPushTypes = [.voIP]
    }
    #endif
}
