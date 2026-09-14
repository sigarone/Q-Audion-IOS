import Foundation

/// Delivery/read receipt for the E2EE file-attachment (`qa_fa_announce:1`)
/// and voice-note (`qa_vn_announce:1`) transports — byte-for-byte mirror of
/// Android's `AttachmentReceiptDispatcher` wire shape.
///
/// Bug found live 2026-08-18: a sent file or voice note never left its
/// single grey tick no matter what the recipient did with it. Both
/// transports ride `opaque_message` directly — the server never sees a
/// `msg_send`, so the normal `serverMessageId`-keyed
/// `msg_delivered`/`msg_read` events never had anything to match against
/// for these rows. This is the same idea applied to that gap: the
/// recipient sends this small envelope back over `opaque_message`, keyed
/// by the SAME `fileId`/`voiceNoteId` UUID both sides already agree on
/// from the announce envelope.
///
/// # Wire shape
///
///   JSON, base64-encoded, sent via `sendOpaqueMessageString` — same
///   convention as the announce envelopes themselves:
///   ```
///   {"t":"qa_att_receipt:1","id":"<fileId-or-voiceNoteId>","st":"d"|"r","ts":<unix_ms>}
///   ```
///   `st`: `"d"` = delivered, `"r"` = read.
public struct AttachmentReceiptEnvelope: Codable {
    public static let wireType = "qa_att_receipt:1"
    public static let statusDelivered = "d"
    public static let statusRead = "r"

    enum CodingKeys: String, CodingKey {
        case type = "t"
        case id
        case status = "st"
        case ts
    }

    public let type: String
    public let id: String
    public let status: String
    public let ts: Int64

    public init(id: String, status: String, ts: Int64) {
        self.type = Self.wireType
        self.id = id
        self.status = status
        self.ts = ts
    }

    /// Base64-decodes + JSON-decodes [wirePayloadB64]. Returns `nil` for
    /// any payload that isn't this envelope (wrong `t` marker, not valid
    /// base64/JSON) — a safe no-op fall-through for every other
    /// `opaque_message` consumer, same contract as
    /// `FileAttachmentAnnounceWireEnvelope.parse`.
    public static func parse(wirePayloadB64: String) -> AttachmentReceiptEnvelope? {
        guard let raw = Data(base64Encoded: wirePayloadB64) else { return nil }
        guard let envelope = try? JSONDecoder().decode(AttachmentReceiptEnvelope.self, from: raw) else {
            return nil
        }
        guard envelope.type == wireType else { return nil }
        return envelope
    }

    /// JSON-encodes + base64-encodes for the wire.
    public func toWirePayload() throws -> String {
        let data = try JSONEncoder().encode(self)
        return data.base64EncodedString()
    }
}
