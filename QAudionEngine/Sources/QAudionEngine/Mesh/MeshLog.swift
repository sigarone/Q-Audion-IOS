import Foundation
import CryptoKit

/// The diagnostic log events of the Bluetooth mesh (docs/mesh/MESH_LINK_SPEC.md
/// section 13), one line per event: `<event> key=value key=value`, written under
/// the runtime-log scope ``tag``.
///
/// The only identifiers a line may carry are a short node hash (`nh`, the first 6
/// hex characters of a node id), a per-process link handle (`c1`, `p2`, ...) and a
/// short payload hash (`ph`, the first 8 hex characters of SHA-256 of a packet's
/// payload). Never a full node id, a Bluetooth address or platform peer
/// identifier, a user, conversation, message or receipt id, payload or frame
/// bytes, a key or a name. ``line(_:_:)`` enforces the shape of every value, so a
/// call site that passed one of those by mistake cannot put it in a log.
///
/// The engine package cannot see `RTLog` (it lives in the app target), so the app
/// installs a sink at launch that forwards the line to it. Until a sink is
/// installed the line goes to `print`, which the runtime log captures anyway.
public enum MeshLog {

    /// The runtime-log scope of every mesh line (also the shipper's tag).
    public static let tag = "mesh"

    public enum Level: Sendable {
        case info
        case warn
    }

    /// The event names of the specification, in the order of its table.
    public enum Event: String, CaseIterable, Sendable {
        case identity
        case radio
        case linkUp = "link.up"
        case linkReady = "link.ready"
        case linkDown = "link.down"
        case linkRefused = "link.refused"
        case annTx = "ann.tx"
        case annRx = "ann.rx"
        case annSum = "ann.sum"
        case annProof = "ann.proof"
        case tx
        case txFrameFail = "tx.frame.fail"
        case rx
        case rxDrop = "rx.drop"
        case guardBlock = "guard.block"
        case relay
        case appTx = "app.tx"
        case appRx = "app.rx"
        case outbox
        case radioPause = "radio.pause"
        case radioResume = "radio.resume"
        case connectBackoff = "connect.backoff"

        /// The events the specification marks WARN.
        public var level: Level {
            switch self {
            case .txFrameFail, .rxDrop, .guardBlock: return .warn
            default: return .info
            }
        }
    }

    private final class Holder: @unchecked Sendable {
        private let lock = NSLock()
        private var sink: (@Sendable (Level, String, String) -> Void)?

        func set(_ newSink: (@Sendable (Level, String, String) -> Void)?) {
            lock.lock()
            sink = newSink
            lock.unlock()
        }

        func get() -> (@Sendable (Level, String, String) -> Void)? {
            lock.lock()
            defer { lock.unlock() }
            return sink
        }
    }

    private static let holder = Holder()

    /// Installs (or, with nil, removes) the destination of the lines: `(level, tag, message)`.
    public static func install(sink: (@Sendable (_ level: Level, _ tag: String, _ message: String) -> Void)?) {
        holder.set(sink)
    }

    // MARK: - Identifiers

    /// The `nh` of a node id: its first 6 hex characters.
    public static func nodeHash(_ nodeHex: String) -> String {
        String(nodeHex.prefix(6))
    }

    /// The `ph` of a packet: the first 8 hex characters of SHA-256 of its payload.
    /// Stable across relays, so a sender's transmission can be matched with a
    /// receiver's arrival.
    public static func payloadHash(_ payload: Data) -> String {
        let digest = SHA256.hash(data: payload)
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// `c<n>` for an outgoing (central role) link, `p<n>` for an incoming one.
    public static func linkHandle(outgoing: Bool, ordinal: Int) -> String {
        (outgoing ? "c" : "p") + String(ordinal)
    }

    // MARK: - Emitting

    public static func emit(_ event: Event, _ fields: [(String, String)] = []) {
        let message = line(event, fields)
        if let sink = holder.get() {
            sink(event.level, tag, message)
        } else {
            print("[\(tag)] \(message)")
        }
    }

    /// `event key=value key=value`. A value that is not a lowercase token or a number
    /// (at most 24 characters of `a-z 0-9 _ .`), or that looks like a node id or a
    /// longer hash (12 or more hex characters in a row), is replaced by `x`.
    public static func line(_ event: Event, _ fields: [(String, String)]) -> String {
        var out = event.rawValue
        for (key, value) in fields {
            out += " " + key + "=" + (isSafe(value) ? value : "x")
        }
        return out
    }

    public static func flag(_ value: Bool) -> String { value ? "1" : "0" }

    static func isSafe(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 24 else { return false }
        var hexRun = 0
        for byte in value.utf8 {
            let isDigit = byte >= 0x30 && byte <= 0x39
            let isLower = byte >= 0x61 && byte <= 0x7A
            guard isDigit || isLower || byte == 0x5F || byte == 0x2E || byte == 0x2D else { return false }
            let isHex = isDigit || (byte >= 0x61 && byte <= 0x66)
            hexRun = isHex ? hexRun + 1 : 0
            if hexRun >= 12 { return false }
        }
        return true
    }
}
