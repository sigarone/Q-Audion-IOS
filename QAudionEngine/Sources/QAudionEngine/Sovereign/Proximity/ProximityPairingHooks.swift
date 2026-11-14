import Foundation

/// The log lines of the in-person pairing's Bluetooth transport (tag `pair`).
///
/// Closed vocabulary only: roles, steps, events and states are fixed tokens, the rest is numbers (RSSI, error codes,
/// milliseconds) and the first 8 hex characters of the session id, which only serves to match the two phones' logs.
/// Never a key, a code, an identity, an address or a name: `line(_:_:)` replaces any value that is not a lowercase
/// token, a number or 8 hex characters.
///
/// The engine package cannot see `RTLog` (it lives in the app target), so the app installs a sink at launch that
/// forwards `(tag, line)` to it. Until a sink is installed the line goes to `print`, which the runtime log captures.
public enum ProximityPairingLog {

    /// The pairing scope of the runtime log; the log shipper has a closed grammar for these lines.
    public static let tag = "pair"

    private final class Holder: @unchecked Sendable {
        private let lock = NSLock()
        private var sink: (@Sendable (String, String) -> Void)?

        func set(_ newSink: (@Sendable (String, String) -> Void)?) {
            lock.lock()
            sink = newSink
            lock.unlock()
        }

        func get() -> (@Sendable (String, String) -> Void)? {
            lock.lock()
            defer { lock.unlock() }
            return sink
        }
    }

    private static let holder = Holder()

    /// Installs (or, with nil, removes) the destination of the lines.
    public static func install(sink: (@Sendable (_ tag: String, _ line: String) -> Void)?) {
        holder.set(sink)
    }

    /// The first 8 hex characters of a session id (4 bytes).
    public static func sessionPrefix(_ sessionId: Data) -> String {
        return Data(sessionId).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// `name key=value key=value`, written to the sink.
    public static func emit(_ name: String, _ fields: [(String, String)]) {
        let text: String = line(name, fields)
        if let sink = holder.get() {
            sink(tag, text)
        } else {
            print("[\(tag)] \(text)")
        }
    }

    static func line(_ name: String, _ fields: [(String, String)]) -> String {
        var out: String = name
        for (key, value) in fields {
            out += " " + key + "=" + (isSafe(value) ? value : "x")
        }
        return out
    }

    /// A lowercase token (`a-z 0-9 _`), a number (a leading `-` allowed) or 8 hex characters, at most 24 characters.
    private static func isSafe(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 24 else { return false }
        var bytes: [UInt8] = Array(value.utf8)
        if bytes.first == 0x2D, bytes.count > 1 { bytes.removeFirst() }
        return bytes.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }
    }
}

/// What the pairing screen asks of the app while it is open: keep the Bluetooth mesh quiet. The mesh lives in the app
/// target, which the engine cannot see, so the app installs `acquire` once at launch (`MeshBoot`). Without it (a
/// package test, a build without the mesh) the pairing simply does not ask.
@MainActor
public enum ProximityPairingMeshHold {

    /// Takes a hold and returns what gives it back. Giving it back twice does nothing. The app side also gives a hold
    /// back by itself after a while, so a pairing screen that vanished cannot leave the mesh off.
    public static var acquire: (@MainActor () -> (@MainActor () -> Void))?
}
