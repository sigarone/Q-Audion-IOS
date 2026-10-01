import Foundation

/// Group calls v2 (spec §7) — client telemetry event builders. Ids only:
/// `call_id` and pseudonyms are cut to 8 characters here, and nothing that
/// could identify a key, token, fingerprint, ICE credential or address is ever
/// accepted as an attribute value (every builder takes closed enums or numbers,
/// or an id that goes through `id8`).
public struct GroupTelemetryEvent: @unchecked Sendable {
    public let kind: String
    public let attrs: [String: Any]

    public init(kind: String, attrs: [String: Any] = [:]) {
        self.kind = kind
        self.attrs = attrs
    }
}

public enum GroupTelemetry {

    public enum Kind {
        public static let mediaJoin = "group.media_join"
        public static let pcState = "group.pc_state"
        public static let transport = "group.transport"
        public static let transportPolicyViolation = "group.transport_policy_violation"
        public static let dtlsPinMismatch = "group.dtls_pin_mismatch"
        public static let e2ee = "group.e2ee"
        public static let layer = "group.layer"
        public static let layerResend = "group.layer_resend"
        public static let layerUnconfirmed = "group.layer_unconfirmed"
        public static let rejoin = "group.rejoin"
        public static let iceRestart = "group.ice_restart"
    }

    /// Ids are logged with at most 8 characters, never in full.
    public static func id8(_ value: String) -> String { String(value.prefix(8)) }

    public static func mediaJoin(nodeId: String, ms: Int) -> GroupTelemetryEvent {
        GroupTelemetryEvent(kind: Kind.mediaJoin, attrs: ["node": String(nodeId.prefix(16)), "ms": ms])
    }

    public enum PcRole: String, Sendable { case pub, sub }

    public static func pcState(_ pc: PcRole, state: String) -> GroupTelemetryEvent {
        GroupTelemetryEvent(kind: Kind.pcState, attrs: ["pc": pc.rawValue, "state": String(state.prefix(16))])
    }

    public static func transport(_ observed: GroupTransportPolicy.Observed) -> GroupTelemetryEvent {
        GroupTelemetryEvent(kind: Kind.transport, attrs: [
            "tls": observed.tlsVersion.map { String($0.prefix(8)) } ?? "?",
            "cipher": observed.dtlsCipher.map { String($0.prefix(32)) } ?? "?",
            "srtp": observed.srtpCipher.map { String($0.prefix(32)) } ?? "?",
            "cand_type": observed.candidateType.map { String($0.prefix(8)) } ?? "?",
        ])
    }

    public static func transportPolicyViolation(_ pc: PcRole, fields: [String]) -> GroupTelemetryEvent {
        GroupTelemetryEvent(kind: Kind.transportPolicyViolation, attrs: [
            "pc": pc.rawValue, "fields": fields.joined(separator: ","),
        ])
    }

    public static func dtlsPinMismatch(_ pc: PcRole) -> GroupTelemetryEvent {
        GroupTelemetryEvent(kind: Kind.dtlsPinMismatch, attrs: ["pc": pc.rawValue])
    }

    public enum E2eeEvent: String, Sendable {
        case keySent = "key_sent"
        case keyInstalled = "key_installed"
        case nack
        case missingKey = "missing_key"
        case decryptFail = "decrypt_fail"
    }

    public static func e2ee(_ event: E2eeEvent, epoch: UInt32) -> GroupTelemetryEvent {
        GroupTelemetryEvent(kind: Kind.e2ee, attrs: ["event": event.rawValue, "epoch": Int(epoch)])
    }

    public static func layer(mid: String, from: Int, to: Int, reason: String) -> GroupTelemetryEvent {
        GroupTelemetryEvent(kind: Kind.layer, attrs: [
            "mid": String(mid.prefix(8)), "from": from, "to": to, "reason": String(reason.prefix(24)),
        ])
    }

    /// A layer switch Janus has not confirmed in time, asked for again (attempt 1...3).
    public static func layerResend(mid: String, to: Int, attempt: Int) -> GroupTelemetryEvent {
        GroupTelemetryEvent(kind: Kind.layerResend, attrs: ["mid": String(mid.prefix(8)), "to": to, "attempt": attempt])
    }

    /// A layer switch given up on after its last re-send went unconfirmed.
    public static func layerUnconfirmed(mid: String, to: Int) -> GroupTelemetryEvent {
        GroupTelemetryEvent(kind: Kind.layerUnconfirmed, attrs: ["mid": String(mid.prefix(8)), "to": to])
    }

    public static func rejoin(reason: String) -> GroupTelemetryEvent {
        GroupTelemetryEvent(kind: Kind.rejoin, attrs: ["reason": String(reason.prefix(24))])
    }

    public static func iceRestart(reason: String) -> GroupTelemetryEvent {
        GroupTelemetryEvent(kind: Kind.iceRestart, attrs: ["reason": String(reason.prefix(24))])
    }
}
