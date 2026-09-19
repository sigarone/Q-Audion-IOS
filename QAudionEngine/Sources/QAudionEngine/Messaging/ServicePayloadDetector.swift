import Foundation

/// 2026-09-19 service-message root fix — what a decrypted plaintext STRUCTURALLY is.
///
/// Service traffic (control envelopes, group sender keys, KMS/bootstrap, nacks,
/// avatar/timer/screenshot signals, group-call control) must never become a
/// chat row, a preview, an unread count, a notification or a conversation. The
/// channel decides that first (0xE6 = CONTROL carries service traffic only, see
/// ``InboundWireClass``); this detector is the second, structural line: a
/// plaintext that LOOKS like a service payload is consumed-or-dropped and never
/// rendered, whatever wire it arrived on. It is a pure function on the text, so
/// every path (live, pending-sync, retry drain, mesh, group) shares one answer.
///
/// `qa_ctl` with `t == "attach_announce"` is the one carve-out: Android and
/// Desktop still announce an attachment as a `qa_ctl:1` envelope on the CHAT
/// wire, and an attachment is USER content. It is reported as
/// ``ServicePayloadShape/attachmentAnnounce`` so the attachment pipeline keeps
/// receiving it, while every other `qa_ctl` type is service.
public enum ServicePayloadShape: Equatable, Sendable {
    /// Not a service payload — ordinary user text (or a legacy `qfile` marker).
    case notService
    /// `qa_ctl:1` `t:"attach_announce"` — an attachment descriptor, user content.
    case attachmentAnnounce
    /// Structurally a service payload; `key` is the top-level key that matched.
    case service(key: String)

    public var isService: Bool {
        if case .service = self { return true }
        return false
    }
}

public enum ServicePayloadDetector {

    /// Top-level JSON keys that mark a service payload. Identical on every
    /// platform (Android `ServicePayloadGuard`, Desktop, iOS) — keep in step.
    public static let serviceKeys: [String] = [
        "qa_ctl",
        "qa_grp",
        "qa_kms",
        "qa_kms_prebootstrap",
        "qa_v4_bootstrap",
        "qa_grpcall_ctrl",
        "sender_key_init",
        "sender_key_rotate",
    ]

    /// `t` value of the attachment-announce variant of `qa_ctl`.
    public static let attachAnnounceType: String = "attach_announce"

    /// Texts longer than this are not run through a full JSON parse (a pasted
    /// megabyte starting with `{` must not cost a parse); the first-key scan
    /// below still classifies them.
    static let fullParseCapBytes: Int = 128 * 1024

    public static func classify(_ plaintext: String) -> ServicePayloadShape {
        let trimmed = plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return .notService }

        if trimmed.utf8.count <= fullParseCapBytes,
           let data = trimmed.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return classify(object: object)
        }

        // Truncated or malformed JSON: judge by the first key alone.
        if let key = firstKey(of: trimmed), serviceKeys.contains(key) {
            return .service(key: key)
        }
        return .notService
    }

    /// Convenience for guards that only need the yes/no.
    public static func isServiceShaped(_ plaintext: String) -> Bool {
        classify(plaintext).isService
    }

    private static func classify(object: [String: Any]) -> ServicePayloadShape {
        var matched: [String] = []
        for key in serviceKeys where object[key] != nil {
            matched.append(key)
        }
        guard let first = matched.first else { return .notService }
        if matched.count == 1, first == "qa_ctl",
           let t = object["t"] as? String, t == attachAnnounceType {
            return .attachmentAnnounce
        }
        return .service(key: first)
    }

    /// Reads the first object key of a text that starts with `{` without
    /// parsing any value. `nil` when the text does not open with a complete
    /// `{"key":` prefix (an escaped or unterminated key is not a service key).
    static func firstKey(of text: String) -> String? {
        var index = text.startIndex
        guard index < text.endIndex, text[index] == "{" else { return nil }
        index = text.index(after: index)
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == "\"" else { return nil }
        index = text.index(after: index)
        var key = ""
        while index < text.endIndex {
            let ch = text[index]
            if ch == "\"" { break }
            if ch == "\\" { return nil }
            key.append(ch)
            if key.count > 64 { return nil }
            index = text.index(after: index)
        }
        guard index < text.endIndex else { return nil }
        index = text.index(after: index)
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == ":" else { return nil }
        return key
    }
}

// MARK: - Inbound router

/// The wire class of an inbound frame = the first byte of the decoded
/// ciphertext. 0xE6 is the v5 CONTROL channel (service traffic ONLY); every
/// other frame (0xE5 v4, 0xE3 v3, 0xE2 v2, 0xE4 group, else legacy v1) is CHAT
/// class (USER content only). The class is a property of the channel, never of
/// what the plaintext claims to be.
public enum InboundWireClass: Equatable, Sendable {
    case control
    case chat

    public static func of(_ cipher: Data) -> InboundWireClass {
        MessageWireFormat.detect(cipher) == .v5 ? .control : .chat
    }
}

/// Why the router refused to let a decrypted frame become a row. The integer
/// raw value is what goes to the log (the shipper's redactor keeps numerics).
public enum InboundDropReason: Int, Equatable, Sendable {
    case nonUtf8 = 1
    case serviceOnChatWire = 2
    case plainTextOnControl = 3
    case attachmentOnControl = 4
}

public enum InboundRouterVerdict: Equatable, Sendable {
    /// Hand the payload to the service dispatcher, which consumes it (an
    /// unknown or malformed envelope is dropped there — never rendered).
    case dispatchService
    /// Genuine user content: text, or an attachment announce. The only verdict
    /// allowed to reach the conversation-persistence function.
    case userContent
    /// Drop, acknowledge, log. Never a row.
    case drop(InboundDropReason)
}

public enum InboundRouter {

    /// Verdict for a decrypted frame of `wireClass` carrying `plaintext`.
    public static func verdict(wireClass: InboundWireClass, plaintext: Data) -> InboundRouterVerdict {
        guard let text = String(data: plaintext, encoding: .utf8) else {
            return .drop(.nonUtf8)
        }
        return verdict(wireClass: wireClass, text: text)
    }

    public static func verdict(wireClass: InboundWireClass, text: String) -> InboundRouterVerdict {
        let shape = ServicePayloadDetector.classify(text)
        switch wireClass {
        case .control:
            switch shape {
            case .service: return .dispatchService
            case .attachmentAnnounce: return .drop(.attachmentOnControl)
            case .notService: return .drop(.plainTextOnControl)
            }
        case .chat:
            // Channel-is-kind: a service payload on the CHAT wire is never
            // accepted as control, and never rendered either.
            if shape.isService { return .drop(.serviceOnChatWire) }
            return .userContent
        }
    }
}
