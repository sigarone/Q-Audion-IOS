import Foundation

// What a message row holds for a location message, and the fixed labels that stand for it wherever its content must not appear
// (WIRE_SPEC section 14.6.2 step 6 and docs/LOCATION_SHARING.md 1.3).
//
//  - A pin row keeps the pin body exactly as it was built or received: the coordinates are the message, like a photo.
//  - A live row keeps the LOCAL FORM of the start: the same prefix, `m`, `sid`, `st` and `du`, and nothing else. It never holds `k` and
//    never a position (the moving position lives only in the live-share store). The full start body, with `k`, exists only in the
//    sender's outbox until the `msg_sent` echo and is never stored in a received row.
//
//     {"qa_loc":1,"m":"live","sid":"<base64, 16 bytes>","st":<unix s>,"du":<s>}
//
// Everything is on bytes with the strict profile, like the codec: a stored row is read with the same parser as a body from the wire.

/// The facts of a live share that its message row keeps.
public struct LocationLiveRow: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sid: Data
    public let startedAt: Int64
    public let duration: Int64

    public init(sid: Data, startedAt: Int64, duration: Int64) {
        self.sid = sid
        self.startedAt = startedAt
        self.duration = duration
    }

    public var description: String { "LocationLiveRow(redacted)" }
    public var debugDescription: String { description }
}

/// A location row of the message table, read back.
public enum LocationRowForm: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case pin(LocationPosition)
    case live(LocationLiveRow)

    public var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    public var description: String { "LocationRowForm(redacted)" }
    public var debugDescription: String { description }

    /// The local form of a live start (no `k`, no position).
    public static func localForm(of start: LocationLiveStart) -> String {
        localForm(sid: start.sid, startedAt: start.startedAt, duration: start.duration)
    }

    public static func localForm(sid: Data, startedAt: Int64, duration: Int64) -> String {
        let parts: [String] = [
            #"{"qa_loc":1,"m":"live","sid":""#, sid.base64EncodedString(), #"","st":"#, String(startedAt),
            #","du":"#, String(duration), "}"
        ]
        return parts.joined()
    }

    /// Reads the text of a stored location row: a pin body, the local form of a live start, or (the sender, between the send and the
    /// echo) the full live start body, from which only the three facts are taken. `nil` for text that is not a readable location row.
    public static func parse(_ text: String) -> LocationRowForm? {
        let bytes = Array(text.utf8)
        guard bytes.starts(with: LocationWire.prefix) else { return nil }
        if let local = parseLocalForm(bytes) { return .live(local) }
        switch LocationCodec.recognize(utf8: Data(bytes), channel: .chat) {
        case .location(.pin(let position)):
            return .pin(position)
        case .location(.live(let start, _)):
            return .live(LocationLiveRow(sid: start.sid, startedAt: start.startedAt, duration: start.duration))
        case .notLocation, .rejected:
            return nil
        }
    }

    /// Whether `text` is the local form of a live start (no key, no position): what a row holds once the share has its record. Such a
    /// row is never sent again as a message: there is nothing in it to send.
    public static func isLocalLiveForm(_ text: String) -> Bool {
        parseLocalForm(Array(text.utf8)) != nil
    }

    /// The pin of a stored row, `nil` for a live row or text that is not a location.
    public static func pin(of text: String) -> LocationPosition? {
        if case .pin(let position)? = parse(text) { return position }
        return nil
    }

    /// Exactly the members `qa_loc`, `m`, `sid`, `st`, `du`: a body that also carries `k` or a position is not a local form.
    private static func parseLocalForm(_ bytes: [UInt8]) -> LocationLiveRow? {
        guard case .success(let object) = FileV2JSONParser.parse(bytes),
              case .number(let version)? = object.value("qa_loc"), FileV2JSONInteger.parse(version) == LocationWire.version,
              case .string(let mode)? = object.value("m"), mode == Array("live".utf8),
              case .string(let sidText)? = object.value("sid"), let sid = FileV2Base64.decode(sidText),
              sid.count == LocationWire.sidLength,
              case .number(let stToken)? = object.value("st"), let startedAt = FileV2JSONInteger.parse(stToken), startedAt >= 0,
              case .number(let duToken)? = object.value("du"), let duration = FileV2JSONInteger.parse(duToken),
              duration >= LocationWire.duMin, duration <= LocationWire.duMax else { return nil }
        for name in ["k", "lat", "lon", "acc", "age", "ap"] where object.value(name) != nil { return nil }
        return LocationLiveRow(sid: sid, startedAt: startedAt, duration: duration)
    }
}

/// The fixed texts that stand for a location message in a list preview, a notification, a share-sheet cache, an export or a quote:
/// never a coordinate, an accuracy or a body. The engine has no localisation of its own: the defaults are Italian and the app
/// installs the localised lookup once at launch.
public enum LocationLabel: Sendable {
    /// An instant position.
    case pin
    /// A live share.
    case live
}

public enum LocationLabels {

    public static var text: @Sendable (LocationLabel) -> String = { label in
        switch label {
        case .pin: return "📍 Posizione"
        case .live: return "📍 Posizione in tempo reale"
        }
    }

    /// The label of a body that begins with the location prefix: the live one for a live start (full or local form), the pin one for
    /// anything else (a pin, or a body that does not read back: it is never shown as text either way).
    public static func shown(forBody body: String) -> String {
        let live: Bool = LocationCodec.isLiveBody(Data(body.utf8))
        return text(live ? .live : .pin)
    }
}
