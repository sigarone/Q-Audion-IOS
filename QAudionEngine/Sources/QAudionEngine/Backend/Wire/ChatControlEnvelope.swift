import Foundation

/// W86 — `qa_ctl:1` envelope codec for delete / edit / (future: reaction)
/// variants. Companion to ``AttachAnnounceEnvelope`` (which handles the
/// `attach_announce` variant).
///
/// **Cross-platform parity** (Desktop `ChatControlEnvelope.ts`, Android
/// `ChatControlEnvelope.kt`):
///
/// | Variant   | Wire JSON                                                          |
/// | --------- | ------------------------------------------------------------------ |
/// | delete    | `{"qa_ctl":1,"t":"delete","target":"<clientMsgId>","ts":<unix-s>}` |
/// | edit      | `{"qa_ctl":1,"t":"edit","target":"<clientMsgId>","new_body":"…","ts":<unix-s>}` |
/// | reaction  | `{"qa_ctl":1,"t":"reaction","target":"<clientMsgId>","emoji":"👍","ts":<unix-s>}` |
///
/// Field semantics:
///   - `target` is the **sender-generated `clientMsgId`** of the message
///     being modified (NOT the server-issued `serverMessageId`). Peers
///     reference each other's messages by this id. iOS persists it
///     (W86 schema bump) so cross-references resolve.
///   - `new_body` is the FULL replacement plaintext (Desktop caps at
///     8 KiB; iOS replicates that cap).
///   - `ts` is unix **seconds** (parity with Desktop/Android — both
///     emit `Date.now() / 1000` and `System.currentTimeMillis() / 1000`).
///
/// **Receive-side spoof check** — only the original sender of a message
/// may edit or delete it. The caller (AppState) verifies that the
/// `senderId` of the inbound `msg_receive` matches the
/// `senderUserId` (or peer-userId for inbound rows) of the row matched
/// by `target`. Mismatch → drop the envelope silently.
///
/// **Legacy aliases on receive** (Desktop/Android tolerated):
///   - `t: "del"` → normalized to `"delete"`.
///   - `body` → fallback for `new_body` (Phase-31 rename).
///   - `ref` → fallback for `target` (early-Android compat).
///
/// **Screenshot-lock family** (Android `TYPE_SCREENSHOT_*`) — conversation-level
/// controls for the mutual screenshot-unlock handshake. Unlike delete/edit/
/// reaction these carry NO `target` (they act on the whole conversation, not a
/// single message), matching Android's nullable `target`:
///
/// | Variant   | Wire JSON                                                          |
/// | --------- | ------------------------------------------------------------------ |
/// | ss_req    | `{"qa_ctl":1,"t":"ss_req","ts":<unix-s>}`                          |
/// | ss_resp   | `{"qa_ctl":1,"t":"ss_resp","approved":<bool>,"ts":<unix-s>}`       |
/// | ss_lock   | `{"qa_ctl":1,"t":"ss_lock","ts":<unix-s>}`                         |
///
/// RECEIVE-SIDE NOTE: iOS applies these envelopes through the conversation-level
/// ad-hoc JSON handler in `AppState.handleIncomingMessage` (which also renders
/// the system bubble and updates `ConversationStore.setScreenshotGranted`).
/// These enum cases exist so the typed wire model is complete and parity-checked
/// against Android/Desktop; `handleControlEnvelope`'s message-targeted dispatch
/// intentionally treats them as no-ops (see comment there) so there is exactly
/// one code path that applies them. Origination lives in `ChatContainer`.
public enum ChatControlEnvelope: Equatable {
    case delete(target: String, ts: Int64?)
    case edit(target: String, newBody: String, ts: Int64?)
    case reaction(target: String, emoji: String, ts: Int64?)
    /// Peer requests a mutual screenshot unlock for this conversation. No payload.
    case screenshotRequest(ts: Int64?)
    /// Peer's response to a screenshot-unlock request. `approved` = grant/deny.
    case screenshotResponse(approved: Bool, ts: Int64?)
    /// Peer re-locks screenshots for this conversation. No payload; no consent
    /// needed since it only restores the more-secure (locked) state.
    case screenshotLock(ts: Int64?)

    public static let qaCtlVersion: Int = 1

    public enum Error: Swift.Error, LocalizedError {
        case wrongMarker
        case unknownVariant(String)
        case missingField(String)
        case bodyTooLarge(Int)
        case emptyBody
        case emojiTooLong(Int)

        public var errorDescription: String? {
            switch self {
            case .wrongMarker: return "qa_ctl != 1"
            case .unknownVariant(let t): return "unknown qa_ctl variant: \(t)"
            case .missingField(let k): return "missing field: \(k)"
            case .bodyTooLarge(let n): return "edit new_body too large: \(n) bytes"
            case .emptyBody: return "edit new_body empty / whitespace-only"
            case .emojiTooLong(let n): return "reaction emoji too long: \(n) chars"
            }
        }
    }

    /// 8 KiB cap on edit body (Desktop hardening parity).
    public static let editBodyCapBytes: Int = 8 * 1024
    /// 16-char cap on reaction emoji (Desktop hardening parity).
    /// Note: Swift `String.count` is grapheme-cluster based, so a single
    /// flag emoji (👨‍👩‍👧‍👦) counts as 1; 16 graphemes is plenty for any
    /// legit reaction.
    public static let reactionEmojiCapChars: Int = 16

    // MARK: - Decode

    /// Strictly interpret a `JSONSerialization` value as a JSON boolean.
    /// Returns the bool only when the value is a genuine JSON `true`/`false`
    /// (backed by `CFBoolean`); returns `nil` for JSON numbers, strings,
    /// objects, `null`, or a missing key. This prevents a crafted numeric
    /// `1`/`0` from being coerced into a boolean — parity with Android/Desktop,
    /// where a non-bool `approved` deserializes to null (→ deny).
    private static func jsonBool(_ value: Any?) -> Bool? {
        guard let num = value as? NSNumber else { return nil }
        // A JSON bool is bridged to an NSNumber whose CFTypeID is CFBoolean's;
        // a JSON integer/double is a plain numeric NSNumber. Only accept the
        // former.
        guard CFGetTypeID(num) == CFBooleanGetTypeID() else { return nil }
        return num.boolValue
    }

    /// Parse a JSON-encoded plaintext envelope into a typed variant.
    /// Returns `nil` if the JSON is well-formed but doesn't have
    /// `qa_ctl == 1` (caller falls back to other parsers — e.g.
    /// AttachAnnounceEnvelope, plain text, FileTransfer marker).
    /// Throws when the envelope IS qa_ctl:1 but the variant payload is
    /// malformed.
    public static func parse(_ jsonText: String) throws -> ChatControlEnvelope? {
        guard let data = jsonText.data(using: .utf8) else { return nil }
        guard let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let marker = any["qa_ctl"] as? Int, marker == qaCtlVersion else {
            return nil
        }
        guard var typeStr = any["t"] as? String else {
            throw Error.missingField("t")
        }
        // Legacy alias normalization.
        if typeStr == "del" { typeStr = "delete" }

        // Screenshot-lock family — conversation-level, NO `target` field.
        // Handle these BEFORE the target-extraction guard below (which would
        // otherwise throw `missingField("target")` for these payload-less
        // variants). `ts` is optional here too, mirroring Android.
        switch typeStr {
        case "ss_req":
            let ts: Int64? = (any["ts"] as? Int64) ?? (any["ts"] as? NSNumber)?.int64Value
            return .screenshotRequest(ts: ts)
        case "ss_resp":
            // `approved` MUST be a genuine JSON boolean. Anything else
            // (missing, string, number, object) is treated as `false` (deny) —
            // the fail-closed reading for a security-sensitive unlock response,
            // and strict parity with Android/Desktop (kotlinx / JSON.parse both
            // require a real bool; a numeric `1` deserializes to null → deny).
            // We deliberately do NOT accept a numeric NSNumber here so a crafted
            // `"approved":1` cannot be coerced into a grant.
            let approved = jsonBool(any["approved"]) ?? false
            let ts: Int64? = (any["ts"] as? Int64) ?? (any["ts"] as? NSNumber)?.int64Value
            return .screenshotResponse(approved: approved, ts: ts)
        case "ss_lock":
            let ts: Int64? = (any["ts"] as? Int64) ?? (any["ts"] as? NSNumber)?.int64Value
            return .screenshotLock(ts: ts)
        default:
            break
        }

        // Extract `target` (or legacy `ref`).
        guard let target = (any["target"] as? String) ?? (any["ref"] as? String),
              !target.isEmpty else {
            // delete / edit / reaction all require target.
            if typeStr == "delete" || typeStr == "edit" || typeStr == "reaction" {
                throw Error.missingField("target")
            }
            return nil
        }
        let ts: Int64? = (any["ts"] as? Int64)
            ?? (any["ts"] as? NSNumber)?.int64Value

        switch typeStr {
        case "delete":
            return .delete(target: target, ts: ts)
        case "edit":
            // `new_body` is canonical; `body` is the Phase-31 legacy alias.
            guard let body = (any["new_body"] as? String) ?? (any["body"] as? String) else {
                throw Error.missingField("new_body")
            }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw Error.emptyBody
            }
            let byteCount = body.utf8.count
            if byteCount > editBodyCapBytes {
                throw Error.bodyTooLarge(byteCount)
            }
            return .edit(target: target, newBody: body, ts: ts)
        case "reaction":
            guard let emoji = any["emoji"] as? String, !emoji.isEmpty else {
                throw Error.missingField("emoji")
            }
            if emoji.count > reactionEmojiCapChars {
                throw Error.emojiTooLong(emoji.count)
            }
            return .reaction(target: target, emoji: emoji, ts: ts)
        case "attach_announce":
            // Caller routes attach_announce through AttachAnnounceEnvelope.
            return nil
        default:
            throw Error.unknownVariant(typeStr)
        }
    }

    // MARK: - Encode

    public func toJsonString() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: toJsonDict(),
            options: [.sortedKeys]
        )
        guard let s = String(data: data, encoding: .utf8) else {
            throw Error.missingField("encoding utf-8")
        }
        return s
    }

    public func toJsonDict() -> [String: Any] {
        switch self {
        case .delete(let target, let ts):
            var d: [String: Any] = [
                "qa_ctl": Self.qaCtlVersion,
                "t":      "delete",
                "target": target,
            ]
            if let ts = ts { d["ts"] = ts }
            return d
        case .edit(let target, let newBody, let ts):
            var d: [String: Any] = [
                "qa_ctl":   Self.qaCtlVersion,
                "t":        "edit",
                "target":   target,
                "new_body": newBody,
            ]
            if let ts = ts { d["ts"] = ts }
            return d
        case .reaction(let target, let emoji, let ts):
            var d: [String: Any] = [
                "qa_ctl": Self.qaCtlVersion,
                "t":      "reaction",
                "target": target,
                "emoji":  emoji,
            ]
            if let ts = ts { d["ts"] = ts }
            return d
        case .screenshotRequest(let ts):
            var d: [String: Any] = [
                "qa_ctl": Self.qaCtlVersion,
                "t":      "ss_req",
            ]
            if let ts = ts { d["ts"] = ts }
            return d
        case .screenshotResponse(let approved, let ts):
            var d: [String: Any] = [
                "qa_ctl":   Self.qaCtlVersion,
                "t":        "ss_resp",
                "approved": approved,
            ]
            if let ts = ts { d["ts"] = ts }
            return d
        case .screenshotLock(let ts):
            var d: [String: Any] = [
                "qa_ctl": Self.qaCtlVersion,
                "t":      "ss_lock",
            ]
            if let ts = ts { d["ts"] = ts }
            return d
        }
    }

    /// Convenience: current unix epoch in seconds (parity with the wire
    /// format). Use when emitting an envelope without an explicit ts.
    public static func nowTsSeconds() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }
}
