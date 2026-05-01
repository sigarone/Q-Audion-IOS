import Foundation

/// W86 — `qa_ctl:1` envelope codec for delete / edit / (future: reaction)
/// variants. Companion to ``AttachAnnounceEnvelope`` (which handles the
/// `attach_announce` variant).
///
/// **Cross-platform parity** (Desktop `ChatControlEnvelope.ts`, Android
/// `ChatControlEnvelope.kt`):
///
/// | Variant | Wire JSON                                                          |
/// | ------- | ------------------------------------------------------------------ |
/// | delete  | `{"qa_ctl":1,"t":"delete","target":"<clientMsgId>","ts":<unix-s>}`  |
/// | edit    | `{"qa_ctl":1,"t":"edit","target":"<clientMsgId>","new_body":"…","ts":<unix-s>}` |
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
public enum ChatControlEnvelope: Equatable {
    case delete(target: String, ts: Int64?)
    case edit(target: String, newBody: String, ts: Int64?)

    public static let qaCtlVersion: Int = 1

    public enum Error: Swift.Error, LocalizedError {
        case wrongMarker
        case unknownVariant(String)
        case missingField(String)
        case bodyTooLarge(Int)
        case emptyBody

        public var errorDescription: String? {
            switch self {
            case .wrongMarker: return "qa_ctl != 1"
            case .unknownVariant(let t): return "unknown qa_ctl variant: \(t)"
            case .missingField(let k): return "missing field: \(k)"
            case .bodyTooLarge(let n): return "edit new_body too large: \(n) bytes"
            case .emptyBody: return "edit new_body empty / whitespace-only"
            }
        }
    }

    /// 8 KiB cap on edit body (Desktop hardening parity).
    public static let editBodyCapBytes: Int = 8 * 1024

    // MARK: - Decode

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

        // Extract `target` (or legacy `ref`).
        guard let target = (any["target"] as? String) ?? (any["ref"] as? String),
              !target.isEmpty else {
            // Some variants (attach_announce, reaction) don't have
            // target — but for delete/edit it's required.
            if typeStr == "delete" || typeStr == "edit" {
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
        case "attach_announce", "reaction":
            // Caller routes these through a different codec.
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
        }
    }

    /// Convenience: current unix epoch in seconds (parity with the wire
    /// format). Use when emitting an envelope without an explicit ts.
    public static func nowTsSeconds() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }
}
