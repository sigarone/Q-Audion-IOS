import Foundation

/// The log lines of NFC pairing v2 (docs/security/NFC_PAIRING_V2.md section 11).
///
/// Allowed fields only: role, step, result token, status word, HELLO round trip, durations, chunk index, `logTag` and
/// the booleans `peerKnown`, `pinned`, `stored`, `pending`, `replaced`. Never keys, nonces, transcript hashes, the SAS,
/// MACs, tags, signatures, identity public keys, user ids or fingerprints: the call sites pass nothing of the kind, and
/// `line(_:_:)` accepts only values that are tokens, numbers, booleans or the 8 hex characters of the log tag.
///
/// The engine package cannot see `RTLog` (it lives in the app target), so the app installs a sink at launch that
/// forwards `(tag, line)` to it. Until a sink is installed the line goes to `print`, which the runtime log already
/// captures.
public enum NfcPairingLog {

    /// The log tag of every line: the pairing scope of the runtime log (the shipper's tag list already has it).
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

    public enum Role: String, Sendable {
        case reader
        case card
    }

    public enum Step: String, Sendable {
        case select
        case ek
        case hello
        case ct
        case auth
        case reveal
        case confirm
        case finalize
    }

    // MARK: - Events

    public static func start(role: Role) {
        emit(line("nfc.pair.start", [("role", role.rawValue)]))
    }

    public static func step(role: Role, _ step: Step, result: String, statusWord: UInt16? = nil, chunk: Int? = nil,
                            roundTripMs: UInt64? = nil, durationMs: UInt64? = nil, logTag: String? = nil) {
        var fields: [(String, String)] = [("role", role.rawValue), ("step", step.rawValue), ("result", result)]
        if let statusWord { fields.append(("sw", String(format: "%04x", statusWord))) }
        if let chunk { fields.append(("chunk", String(chunk))) }
        if let roundTripMs { fields.append(("rtt_ms", String(roundTripMs))) }
        if let durationMs { fields.append(("ms", String(durationMs))) }
        if let logTag { fields.append(("tag", logTag)) }
        emit(line("nfc.pair.step", fields))
    }

    public static func fail(role: Role, _ failure: NfcPairingV2Failure, step: Step? = nil, logTag: String? = nil) {
        var fields: [(String, String)] = [("role", role.rawValue), ("result", failure.token.rawValue)]
        if let step { fields.append(("step", step.rawValue)) }
        if let statusWord = failure.statusWord { fields.append(("sw", String(format: "%04x", statusWord))) }
        if let logTag { fields.append(("tag", logTag)) }
        emit(line("nfc.pair.fail", fields))
    }

    public static func sasShown(role: Role, peerKnown: Bool, pinned: Bool, logTag: String) {
        emit(line("nfc.pair.sas_shown", [("role", role.rawValue), ("peerKnown", flag(peerKnown)),
                                         ("pinned", flag(pinned)), ("tag", logTag)]))
    }

    public enum UserDecision: String, Sendable {
        case confirm
        case reject
        case timeout
    }

    public static func user(role: Role, _ decision: UserDecision, logTag: String) {
        emit(line("nfc.pair.user", [("role", role.rawValue), ("result", decision.rawValue), ("tag", logTag)]))
    }

    public enum PeerDecision: String, Sendable {
        case confirm
        case reject
        case pending
    }

    public static func peer(role: Role, _ decision: PeerDecision, logTag: String) {
        emit(line("nfc.pair.peer", [("role", role.rawValue), ("result", decision.rawValue), ("tag", logTag)]))
    }

    public static func commit(role: Role, stored: Bool, pending: Bool, replaced: Bool, logTag: String) {
        emit(line("nfc.pair.commit", [("role", role.rawValue), ("stored", flag(stored)), ("pending", flag(pending)),
                                      ("replaced", flag(replaced)), ("tag", logTag)]))
    }

    public enum FinalizeVia: String, Sendable {
        case confirm
        case finalize
        case call
    }

    public static func finalize(role: Role, via: FinalizeVia, deleted: Int, logTag: String) {
        emit(line("nfc.pair.finalize", [("role", role.rawValue), ("via", via.rawValue), ("deleted", String(deleted)),
                                        ("tag", logTag)]))
    }

    // MARK: - Formatting

    /// `name key=value key=value`. A value that is not a token, a number or 8 hex characters is replaced, so a call
    /// site that passed secret material by mistake cannot put it in a log.
    static func line(_ name: String, _ fields: [(String, String)]) -> String {
        var out = name
        for (key, value) in fields {
            out += " " + key + "=" + (isSafe(value) ? value : "x")
        }
        return out
    }

    private static func flag(_ value: Bool) -> String { value ? "1" : "0" }

    /// Tokens (`[a-z0-9_]`), numbers and the 8-hex log tag are all lowercase ASCII letters, digits and underscore, at
    /// most 24 characters; anything longer (a key, a hash, a user id) is not logged.
    private static func isSafe(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 24 else { return false }
        return value.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }
    }

    private static func emit(_ text: String) {
        if let sink = holder.get() {
            sink(tag, text)
        } else {
            print("[\(tag)] \(text)")
        }
    }
}
