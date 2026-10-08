import Foundation
#if canImport(PushKit) && os(iOS)
import PushKit
import UIKit
#endif

public final class PushKitProvider {

    /// Decoded form of the §5.7 VoIP payload. Public so unit tests can use it.
    public struct ParsedPayload: Equatable, Sendable {
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

    // MARK: - W-VOIPSYNC (2026-10-08): what the PushKit callback reports, decided before it returns

    /// What a VoIP push turned out to be, in the order the delegate has always tried
    /// the parsers (1:1, group, opaque wake, cancel). Anything else is `.unparsed`,
    /// which is reported as a placeholder and ended at once.
    public enum PushEvent: Sendable {
        case incoming(ParsedPayload)
        case group(ParsedGroupPayload)
        case opaque(OpaqueCallWakeupPayload)
        case cancel(ParsedCancelPayload)
        case unparsed

        /// `kind=` of the `voip` diagnostic lines: 0 unparsed, 1 incoming, 2 group,
        /// 3 opaque wake, 4 cancel.
        public var kindCode: Int {
            switch self {
            case .unparsed: return 0
            case .incoming: return 1
            case .group: return 2
            case .opaque: return 3
            case .cancel: return 4
            }
        }

        /// The first 8 characters of the call id the push carries (`call8=` field);
        /// nil when it carries none (opaque wake, unparsed).
        public var id8: String? {
            switch self {
            case .incoming(let p): return VoipPushDiagnostics.id8(p.callId.uuidString)
            case .group(let p): return VoipPushDiagnostics.id8(p.callId)
            case .cancel(let p): return VoipPushDiagnostics.id8(p.callId.uuidString)
            case .opaque, .unparsed: return nil
            }
        }

        public var isUnparsed: Bool {
            if case .unparsed = self { return true }
            return false
        }
    }

    /// What the delegate tells CallKit before it returns. `endReason` non-nil means
    /// "report, then end at once" (cancel push, group call that cannot ring,
    /// placeholder).
    public struct ReportSpec: Sendable {
        public let uuid: UUID
        public let callerName: String
        public let hasVideo: Bool
        public let endReason: CallEndReason?

        public init(uuid: UUID, callerName: String, hasVideo: Bool, endReason: CallEndReason?) {
            self.uuid = uuid
            self.callerName = callerName
            self.hasVideo = hasVideo
            self.endReason = endReason
        }
    }

    /// CallKit's answer to one report: `code` is 0 on success, the NSError code
    /// otherwise; `duplicate` = another report of the same uuid was already in
    /// flight or up (the ledger's `beginReport` claim was not ours).
    public struct ReportOutcome: Equatable, Sendable {
        public let ok: Bool
        public let code: Int
        public let duplicate: Bool

        public init(ok: Bool, code: Int, duplicate: Bool) {
            self.ok = ok
            self.code = code
            self.duplicate = duplicate
        }
    }

    /// Name shown by every placeholder report.
    public static let placeholderCallerName = "Q-Audion"

    /// Classify a VoIP payload. Same precedence the delegate always used.
    public static func classify(_ dict: [String: Any]) -> PushEvent {
        if let p = try? parsePayload(dict) { return .incoming(p) }
        if let g = try? parseGroupPayload(dict) { return .group(g) }
        if let o = try? parseOpaqueCallWakeup(dict) { return .opaque(o) }
        if let c = try? parseCancelPayload(dict) { return .cancel(c) }
        return .unparsed
    }

    /// The report used when there is nothing better: a payload that does not
    /// decode, no owner, or an owner with no handler for this kind. A fresh uuid,
    /// reported and ended at once: the PushKit mandate is one report per push.
    public static func placeholderSpec(uuid: UUID = UUID()) -> ReportSpec {
        ReportSpec(uuid: uuid, callerName: placeholderCallerName, hasVideo: false,
                   endReason: .failed("malformed-voip-push"))
    }

    /// The spec the delegate reports: the app's own for a decoded push, the
    /// placeholder otherwise. Never nil: every VoIP push is reported.
    public static func resolveSpec(event: PushEvent, prepared: ReportSpec?) -> ReportSpec {
        if event.isUnparsed { return placeholderSpec() }
        return prepared ?? placeholderSpec()
    }

    // MARK: - PushKit-only behaviors (iOS-only)

    #if canImport(PushKit) && os(iOS)
    public typealias TokenHandler = (Data) async -> Void
    /// W-VOIPSYNC — runs ON MAIN, inside the PushKit callback and before the
    /// report: decides what CallKit is told (uuid, name, video, end at once).
    /// Must be synchronous and cheap; it is the old `MainActor.run { prepare… }`
    /// step of each handler. nil = no handler for this kind: a placeholder is
    /// reported and ended.
    public typealias PrepareHandler = @MainActor (PushEvent) -> ReportSpec?
    /// W-VOIPSYNC — runs on main once CallKit has answered the report (and after
    /// the end of a report-and-end spec), right before PushKit's completion. Only
    /// for pushes `PrepareHandler` answered. Everything that does not decide the
    /// report lives here (WS revive, ghost bookkeeping, group UI); anything async
    /// it needs is started from here as a Task, never awaited before the report.
    public typealias AfterReportHandler = @MainActor (PushEvent, ReportSpec, ReportOutcome) -> Void

    /// W-VOIPSYNC — the CallKit reporter, held STRONGLY: the report never depends
    /// on a weak reference being alive.
    private let reporter: VoipCallReporter
    private let onTokenUpdate: TokenHandler
    fileprivate let prepare: PrepareHandler
    fileprivate let afterReport: AfterReportHandler

    /// W-VOIPSYNC — ONE registry and ONE delegate per process, created by the
    /// first `init` and never replaced: a second `init` only re-attaches the
    /// owner, the reporter and the log sink. Main thread only (init runs from
    /// `AppState.initialize()`, the delegate on the registry's `.main` queue).
    private static var sharedRegistry: PKPushRegistry?
    private static var sharedDelegate: Delegate?
    /// How many times `init` ran in this process: 1 in a healthy process
    /// (`voip init count=N site=1`, `voip rx … init=N`).
    public private(set) static var initCount = 0

    /// Set from both the callback and the late timer, on main only.
    private final class LateFlag: @unchecked Sendable {
        var answered = false
    }

    private final class Delegate: NSObject, PKPushRegistryDelegate {
        weak var owner: PushKitProvider?
        /// STRONG (W-VOIPSYNC): a nil owner still gets its push reported.
        var reporter: VoipCallReporter
        var log: ((String) -> Void)?

        init(reporter: VoipCallReporter) {
            self.reporter = reporter
        }

        func pushRegistry(_ registry: PKPushRegistry,
                          didUpdate pushCredentials: PKPushCredentials,
                          for type: PKPushType) {
            guard type == .voIP else { return }
            Task { await self.owner?.onTokenUpdate(pushCredentials.token) }
        }

        // iOS MANDATE (iOS 13+): every VoIP push MUST report a new incoming call to
        // CallKit before completion(); otherwise PushKit raises "Killing app because
        // it never posted an incoming call…" and, on repeated violations, stops
        // delivering VoIP pushes. W-VOIPSYNC (2026-10-08, incidents b0d7ba30 and
        // eb2a6367): the report used to sit behind a Task, the WEAK owner and a
        // main-actor hop; twice the app was killed 0.8 s after the push with not one
        // line from this path. Now the report is handed to CallKit here, before this
        // method returns, through the strongly held reporter; completion() is called
        // only from CallKit's own completion.
        func pushRegistry(_ registry: PKPushRegistry,
                          didReceiveIncomingPushWith payload: PKPushPayload,
                          for type: PKPushType,
                          completion: @escaping () -> Void) {
            guard type == .voIP else { completion(); return }
            let startNs: UInt64 = DispatchTime.now().uptimeNanoseconds
            let dict = (payload.dictionaryPayload as? [String: Any]) ?? [:]
            let event: PushEvent = PushKitProvider.classify(dict)
            let kind: Int = event.kindCode
            let owner: PushKitProvider? = self.owner
            let reporter: VoipCallReporter = self.reporter
            let log: ((String) -> Void)? = self.log
            // The registry's queue is `.main`, so this callback runs on the main
            // thread: the first line goes into the ring synchronously, and the
            // main-actor prepare step runs inline, with no hop.
            let prepared: ReportSpec? = MainActor.assumeIsolated { () -> ReportSpec? in
                let appState: Int = UIApplication.shared.applicationState.rawValue
                let rxLine: String = VoipPushDiagnostics.rxLine(
                    kind: kind, owner: owner != nil, initCount: PushKitProvider.initCount,
                    appState: appState, id8: event.id8)
                log?(rxLine)
                guard let owner, !event.isUnparsed else { return nil }
                return owner.prepare(event)
            }
            let spec: ReportSpec = PushKitProvider.resolveSpec(event: event, prepared: prepared)
            let late = LateFlag()
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(VoipPushDiagnostics.lateAfterMs)
            ) {
                guard !late.answered else { return }
                log?(VoipPushDiagnostics.lateLine(kind: kind, ms: VoipPushDiagnostics.lateAfterMs))
            }
            reporter.reportIncomingCallNow(
                uuid: spec.uuid, callerName: spec.callerName, hasVideo: spec.hasVideo
            ) { outcome in
                PushKitProvider.onMain {
                    late.answered = true
                    let reportMs: Int = PushKitProvider.elapsedMs(since: startNs)
                    log?(VoipPushDiagnostics.reportLine(
                        kind: kind, outcome: outcome, ms: reportMs,
                        id8: VoipPushDiagnostics.id8(spec.uuid.uuidString)))
                    if let reason = spec.endReason {
                        reporter.reportCallEndedNow(uuid: spec.uuid, reason: reason)
                    }
                    if prepared != nil, let owner {
                        MainActor.assumeIsolated {
                            owner.afterReport(event, spec, outcome)
                        }
                    }
                    log?(VoipPushDiagnostics.doneLine(
                        kind: kind, ok: outcome.ok, ms: PushKitProvider.elapsedMs(since: startNs)))
                    completion()
                }
            }
        }
    }

    /// Run `body` on main: inline when already there (CallKit usually answers on
    /// the provider's delegate queue, which is main here), otherwise async.
    fileprivate static func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async { body() }
        }
    }

    fileprivate static func elapsedMs(since startNs: UInt64) -> Int {
        let now: UInt64 = DispatchTime.now().uptimeNanoseconds
        return now > startNs ? Int((now - startNs) / 1_000_000) : 0
    }

    public init(reporter: VoipCallReporter,
                log: ((String) -> Void)?,
                onTokenUpdate: @escaping TokenHandler,
                prepare: @escaping PrepareHandler,
                afterReport: @escaping AfterReportHandler) {
        self.reporter = reporter
        self.onTokenUpdate = onTokenUpdate
        self.prepare = prepare
        self.afterReport = afterReport
        PushKitProvider.initCount += 1
        if let registry = PushKitProvider.sharedRegistry, let delegate = PushKitProvider.sharedDelegate {
            delegate.owner = self
            delegate.reporter = reporter
            delegate.log = log
            registry.delegate = delegate
        } else {
            let delegate = Delegate(reporter: reporter)
            delegate.owner = self
            delegate.log = log
            let registry = PKPushRegistry(queue: .main)
            PushKitProvider.sharedDelegate = delegate
            PushKitProvider.sharedRegistry = registry
            // Delegate first, push types second (Apple's order).
            registry.delegate = delegate
            registry.desiredPushTypes = [.voIP]
        }
        log?(VoipPushDiagnostics.initLine(count: PushKitProvider.initCount, site: VoipPushDiagnostics.siteRegistry))
    }
    #endif
}

/// W-VOIPSYNC (2026-10-08) — what the PushKit delegate needs from CallKit, called
/// synchronously from the PushKit callback. `CallKitProvider` implements it with
/// the same ledger as its async `reportIncomingCall`, so a later report of the
/// same uuid from the WS path stays a labelled duplicate.
public protocol VoipCallReporter: AnyObject {
    /// Hand the report to CallKit before returning; `completion` once CallKit has
    /// answered, on any queue.
    func reportIncomingCallNow(uuid: UUID, callerName: String, hasVideo: Bool,
                               completion: @escaping (PushKitProvider.ReportOutcome) -> Void)
    /// End a reported call at once (cancel push, placeholder), synchronously.
    func reportCallEndedNow(uuid: UUID, reason: CallEndReason)
}

/// W-VOIPSYNC (2026-10-08) — the `voip` diagnostic lines (tag "call"). Every shape
/// is pinned by `VoipPushSyncReportTests` and checked against the phone-log
/// shipper's vocabulary gate by `scripts/test_ship_ios_voip_vocab.py` (keep the
/// two in sync with this file). Read together they settle the next PushKit kill in
/// one look: no `voip rx` before the kill = PushKit never called the delegate;
/// `owner=0` = the provider was gone; `init` above 1 = a second registration;
/// `rx` without `report` = killed while CallKit had the report.
public enum VoipPushDiagnostics {

    /// A report CallKit has not answered after this long gets a `voip late` line.
    public static let lateAfterMs: Int = 2000

    /// `site=` of `voip init`: 1 = PushKitProvider.init, 2 = AppState.initialize().
    public static let siteRegistry: Int = 1
    public static let siteAppInitialize: Int = 2

    /// First line of the PushKit callback. `appState` is
    /// `UIApplication.State.rawValue` (0 active, 1 inactive, 2 background).
    public static func rxLine(kind: Int, owner: Bool, initCount: Int, appState: Int, id8: String?) -> String {
        let ownerFlag: String = owner ? "1" : "0"
        var line: String = "voip rx kind=" + String(kind) + " owner=" + ownerFlag
        line += " init=" + String(initCount) + " state=" + String(appState)
        if let id8 { line += " call8=" + id8 }
        return line
    }

    public static func initLine(count: Int, site: Int) -> String {
        "voip init count=" + String(count) + " site=" + String(site)
    }

    /// `AppState.initialize()` ran again and kept the registration it already had.
    public static func initSkippedLine() -> String {
        "voip init skip=1 site=" + String(siteAppInitialize)
    }

    /// No CallKit reporter: PushKit was NOT registered (cannot happen on iOS).
    public static func initNoReporterLine() -> String {
        "voip init count=0 site=" + String(siteRegistry)
    }

    /// CallKit's answer to the report.
    public static func reportLine(kind: Int, outcome: PushKitProvider.ReportOutcome, ms: Int, id8: String?) -> String {
        let okFlag: String = outcome.ok ? "1" : "0"
        let dupFlag: String = outcome.duplicate ? "1" : "0"
        var line: String = "voip report kind=" + String(kind) + " ok=" + okFlag
        line += " code=" + String(outcome.code) + " dup=" + dupFlag + " ms=" + String(ms)
        if let id8 { line += " call8=" + id8 }
        return line
    }

    /// Right before PushKit's completion.
    public static func doneLine(kind: Int, ok: Bool, ms: Int) -> String {
        let okFlag: String = ok ? "1" : "0"
        return "voip done kind=" + String(kind) + " ok=" + okFlag + " ms=" + String(ms)
    }

    public static func lateLine(kind: Int, ms: Int) -> String {
        "voip late kind=" + String(kind) + " ms=" + String(ms)
    }

    /// The first 8 characters of an id, lower-cased (the server journal's form),
    /// only when they are all hex (a uuid today); nil otherwise, so no free text
    /// reaches the line. Shipped as `call8=`: the shipper keeps that key's value
    /// even when all eight are digits, where `id=` would be masked as a phone
    /// number.
    public static func id8(_ id: String) -> String? {
        let head = String(id.prefix(8))
        guard head.count == 8, head.allSatisfy({ $0.isHexDigit }) else { return nil }
        return head.lowercased()
    }
}
