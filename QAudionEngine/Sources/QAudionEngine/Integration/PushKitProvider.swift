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

    /// TRUST-6 (`docs/security/CRYPTO_PROTOCOL_AUDIT_2026-09-01.md`, security
    /// audit backlog item 9) — decoded form of an opaque incoming-call wake
    /// push: `{"type":"opaque_wakeup","kind":"call","shash":"<hex>","ts":"<unix
    /// seconds>"}`. Deliberately carries NO caller identity, NO `call_id` —
    /// that is the whole point (the plaintext `ParsedPayload` above is what
    /// TRUST-6 flags: `call_id`/`caller_id`/`caller_name`/`call_type` visible
    /// in cleartext push metadata to Apple/the server even though the call's
    /// content is E2EE). `senderHash`/`timestamp` are logged/telemetry only —
    /// never used to establish identity or to correlate with a specific call;
    /// the real call details are learned exclusively over the already-
    /// authenticated signaling WebSocket after this wakes the app. Public so
    /// unit tests can use it.
    ///
    /// Wire shape mirrors bcrypto-server's EXISTING `opaque_wakeup` pattern
    /// for messages (`internal/push/fcm.go`'s `SendOpaquePush`: `type`,
    /// `kind`, `shash`, `ts` — same field names, `kind` there is presumably
    /// "message"/similar, here `"call"`). That pattern is FCM/WNS-only today
    /// (`internal/push/apns.go` has no `opaque_wakeup` sender at all — iOS
    /// currently has no push-driven message wake path whatsoever, messages
    /// rely entirely on the persistent WS) — there is no existing iOS
    /// opaque-wakeup precedent to literally copy, so the field names are
    /// carried over from the FCM/WNS shape instead, as the closest real
    /// cross-platform contract to stay consistent with.
    public struct OpaqueCallWakeupPayload: Equatable, Sendable {
        /// `kind` field, always "call" for anything this type parses
        /// (guaranteed by `parseOpaqueCallWakeup`'s own gate).
        public let kind: String
        /// `shash` — a non-identifying hash, opaque to this client. Never
        /// decoded/reversed; carried through only for diagnostics.
        public let senderHash: String
        /// `ts` — unix seconds the server sent the wakeup. Diagnostics only
        /// (staleness of the PUSH, not of the eventual call — that is
        /// `call_incoming`'s own `server_ts_ms`/W-OFFERTS gate).
        public let timestamp: Int64
    }

    /// W-CANCELPUSH (2026-09-03) — decoded form of the `type ==
    /// "call_cancelled"` VoIP payload (server: `internal/push/apns.go`
    /// `SendVoIPCallCancel`/`SendAlertCallCancel`). Wire: `{call_id}` only —
    /// deliberately no caller identity, this is a stop-ringing signal for a
    /// call the RECEIVING side already knows about (it already showed the
    /// ring from the original `incoming_call` push), not new information.
    /// Public so unit tests can use it.
    public struct ParsedCancelPayload: Equatable, Sendable {
        public let callId: UUID
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

    /// TRUST-6 — stateless parser for the opaque call-wakeup VoIP payload.
    /// Pure function, testable on any platform, same discipline as
    /// `parsePayload`/`parseGroupPayload` above. `kind` MUST be exactly
    /// `"call"` — a bare `opaque_wakeup` with a different (or missing)
    /// `kind` is some OTHER wakeup type this parser does not own and must
    /// reject, not silently accept as a call.
    public static func parseOpaqueCallWakeup(_ dict: [String: Any]) throws -> OpaqueCallWakeupPayload {
        guard let type = dict["type"] as? String, type == "opaque_wakeup" else {
            throw DecodeError.wrongType(dict["type"] as? String ?? "<absent>")
        }
        guard let kind = dict["kind"] as? String, kind == "call" else {
            throw DecodeError.wrongType(dict["kind"] as? String ?? "<absent-kind>")
        }
        let shash = (dict["shash"] as? String) ?? ""
        let ts: Int64
        if let n = dict["ts"] as? NSNumber {
            ts = n.int64Value
        } else if let s = dict["ts"] as? String, let parsed = Int64(s) {
            ts = parsed
        } else {
            ts = 0
        }
        return OpaqueCallWakeupPayload(kind: kind, senderHash: shash, timestamp: ts)
    }

    /// W-CANCELPUSH — stateless parser for the call-cancel VoIP payload.
    /// Pure function, testable on any platform, same discipline as the
    /// other parsers above.
    public static func parseCancelPayload(_ dict: [String: Any]) throws -> ParsedCancelPayload {
        guard let type = dict["type"] as? String, type == "call_cancelled" else {
            throw DecodeError.wrongType(dict["type"] as? String ?? "<absent>")
        }
        guard let callIdStr = dict["call_id"] as? String else {
            throw DecodeError.missingField("call_id")
        }
        guard let callId = UUID(uuidString: callIdStr) else {
            throw DecodeError.badUUID(callIdStr)
        }
        return ParsedCancelPayload(callId: callId)
    }

    // MARK: - PushKit-only behaviors (iOS-only)

    #if canImport(PushKit) && os(iOS)
    public typealias TokenHandler = (Data) async -> Void
    public typealias IncomingHandler = (ParsedPayload) async -> Void
    /// W-GRPRING — fired for a `type == "incoming_group_call"` VoIP push. The
    /// handler carries the SAME iOS mandate as `IncomingHandler`: it MUST
    /// report a new incoming call to CallKit before the push completes.
    public typealias IncomingGroupHandler = (ParsedGroupPayload) async -> Void
    /// TRUST-6 — fired for a `type == "opaque_wakeup", kind == "call"` VoIP
    /// push. Same iOS mandate as `IncomingHandler`: the handler MUST report
    /// SOME incoming call to CallKit before the push completes — see
    /// `AppState`'s wiring for how it does that with no identity to show yet.
    public typealias IncomingOpaqueCallWakeupHandler = (OpaqueCallWakeupPayload) async -> Void
    /// W-CANCELPUSH — fired for a `type == "call_cancelled"` VoIP push. Same
    /// iOS mandate as the other handlers: it MUST report SOME call to
    /// CallKit before the push completes — in practice this means reporting
    /// the SAME `callId` UUID that is already ringing (from the original
    /// invite) and immediately ending it, so CallKit dismisses that ring
    /// without ever surfacing a new one. See `AppState`'s wiring.
    public typealias IncomingCancelHandler = (ParsedCancelPayload) async -> Void
    /// Fired when a VoIP push arrives that we CANNOT decode into a call
    /// (wrong type / missing field / bad UUID / non-[String:Any] payload).
    /// The handler MUST still report-and-end a placeholder call to CallKit —
    /// see the iOS mandate note in `didReceiveIncomingPushWith`.
    public typealias MalformedHandler = () async -> Void

    private let registry: PKPushRegistry
    private let onTokenUpdate: TokenHandler
    private let onIncomingCall: IncomingHandler
    private let onIncomingGroupCall: IncomingGroupHandler?
    private let onIncomingOpaqueCallWakeup: IncomingOpaqueCallWakeupHandler?
    private let onIncomingCancel: IncomingCancelHandler?
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
            } else if let owner = self.owner,
                      let opaqueCallHandler = owner.onIncomingOpaqueCallWakeup,
                      let opaqueCall = try? PushKitProvider.parseOpaqueCallWakeup(dict) {
                // TRUST-6 — opaque call wakeup, no caller identity in the
                // push. Same mandate: report SOME call to CallKit before
                // completion(). If no handler is wired, fall through to
                // onMalformedPush exactly like the group branch above,
                // rather than completing silently.
                Task {
                    await opaqueCallHandler(opaqueCall)
                    completion()
                }
            } else if let owner = self.owner,
                      let cancelHandler = owner.onIncomingCancel,
                      let cancel = try? PushKitProvider.parseCancelPayload(dict) {
                // W-CANCELPUSH — same mandate as every other branch: the
                // handler reports (and immediately ends) a call to CallKit
                // before completion(). If no handler is wired, fall through
                // to onMalformedPush rather than completing silently.
                Task {
                    await cancelHandler(cancel)
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
                onIncomingOpaqueCallWakeup: IncomingOpaqueCallWakeupHandler? = nil,
                onIncomingCancel: IncomingCancelHandler? = nil,
                onMalformedPush: MalformedHandler? = nil) {
        self.onTokenUpdate = onTokenUpdate
        self.onIncomingCall = onIncomingCall
        self.onIncomingGroupCall = onIncomingGroupCall
        self.onIncomingOpaqueCallWakeup = onIncomingOpaqueCallWakeup
        self.onIncomingCancel = onIncomingCancel
        self.onMalformedPush = onMalformedPush
        self.registry = PKPushRegistry(queue: .main)
        delegate.owner = self
        registry.delegate = delegate
        registry.desiredPushTypes = [.voIP]
    }
    #endif
}
