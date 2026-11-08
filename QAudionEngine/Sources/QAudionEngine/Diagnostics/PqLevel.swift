import Foundation

/// Protection level of a call and the one diagnostic line that reports it (`QA-PQLEVEL`).
///
/// Telemetry only: nothing in here touches admission, keys or media. The level is computed from the layers the call really
/// used, and never claims more than what was observed.

/// Level of a path or of a whole call. Declaration order is the strength order: `cl < pq1 < pq2s < pq2`.
public enum PqLevel: Int, Comparable, Sendable {
    case cl = 0
    case pq1
    case pq2s
    case pq2

    public static func < (lhs: PqLevel, rhs: PqLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var token: String {
        switch self {
        case .cl: return "CL"
        case .pq1: return "PQ1"
        case .pq2s: return "PQ2S"
        case .pq2: return "PQ2"
        }
    }

    public init?(token: String) {
        switch token {
        case "CL": self = .cl
        case "PQ1": self = .pq1
        case "PQ2S": self = .pq2s
        case "PQ2": self = .pq2
        default: return nil
        }
    }
}

/// Which secret a post-quantum layer is keyed from. Two layers are independent when their secrets differ.
public enum PqSecret: Hashable, Sendable {
    /// The DTLS hop of the PeerConnection (only when it negotiated the hybrid group).
    case dtls
    /// Anything derived from the call's session key: the frame keys, the inner layer, an outer layer of the same key.
    case session
    /// An outer layer with its own secret.
    case relaySS
}

/// State of the outer layer of a sealed-audio leg.
public enum PqOuterState: String, Sendable {
    /// Keyed from the session key (the per-direction keys of the call).
    case same
    /// Keyed from its own secret.
    case ind
    case indrot
    /// No outer layer.
    case off
}

public enum PqLevelCalc {

    /// Layers of one path -> level. Two or more distinct secrets: `PQ2`; two or more layers sharing one secret: `PQ2S`;
    /// one layer: `PQ1`; none: `CL`.
    public static func pathLevel(_ layers: [PqSecret]) -> PqLevel {
        if Set(layers).count >= 2 { return .pq2 }
        if layers.count >= 2 { return .pq2s }
        if layers.count == 1 { return .pq1 }
        return .cl
    }

    private static func outerLayers(_ outer: PqOuterState) -> [PqSecret] {
        switch outer {
        case .same: return [.session]
        case .ind, .indrot: return [.relaySS]
        case .off: return []
        }
    }

    /// WebRTC RTP path: the DTLS hop (when hybrid) and the frame keys.
    public static func rtp(dtlsPq: Bool) -> [PqSecret] {
        (dtlsPq ? [.dtls] : []) + [.session]
    }

    /// Sealed-audio DataChannel: inside the PeerConnection's DTLS, plus inner and outer layers.
    public static func dcmux(dtlsPq: Bool, innerPq: Bool, outer: PqOuterState) -> [PqSecret] {
        (dtlsPq ? [.dtls] : []) + (innerPq ? [.session] : []) + outerLayers(outer)
    }

    /// Relay audio or relay video: no DTLS of ours, inner and outer layers.
    public static func relay(innerPq: Bool, outer: PqOuterState) -> [PqSecret] {
        (innerPq ? [.session] : []) + outerLayers(outer)
    }

    /// The level of a call is the weakest of its used paths. No used path: nil.
    public static func callLevel(paths: [[PqSecret]]) -> PqLevel? {
        paths.map(pathLevel).min()
    }

    /// A group member's announcement. A member that announces nothing has both nil.
    public struct GroupAnnouncement: Equatable, Sendable {
        public var tl: String?
        public var kd: String?
        public init(tl: String?, kd: String?) { self.tl = tl; self.kd = kd }
        var announcedNothing: Bool { tl == nil && kd == nil }
    }

    /// Level of a group room: `H` = every member's hop is hybrid, `K` = every member's key channel is hybrid (own included).
    /// A member that announces nothing makes both false and counts once in `unk`.
    public static func groupLevel(own: GroupAnnouncement, others: [GroupAnnouncement]) -> (level: PqLevel, unk: Int) {
        let h = own.tl == "pq" && others.allSatisfy { $0.tl == "pq" }
        let k = own.kd == "pq" && others.allSatisfy { $0.kd == "pq" }
        let unk = others.filter { $0.announcedNothing }.count
        let level: PqLevel = (h && k) ? .pq2 : ((h || k) ? .pq1 : .cl)
        return (level, unk)
    }
}

/// The fields of one `QA-PQLEVEL` line, in the order they are printed. A nil or empty value prints as `-`.
public struct PqLevelLine: Equatable, Sendable {
    public var call: String = ""
    public var kind: String = "1to1"
    public var level: String = ""
    public var auth: String = "C"
    public var sas: String = "0"
    public var dtls: String = ""
    public var frame: String = ""
    public var relay: String = ""
    public var dcmux: String = ""
    public var inner: String = ""
    public var rvideo: String = ""
    public var pin: String = ""
    public var hold: String = "0"
    public var withdraw: String = ""
    public var caps: String = ""
    public var pqstate: String = ""
    public var pqSig: String = ""
    public var outer: String = ""
    public var reason: String = ""
    public var rekey: String = ""
    public var round: String = ""
    /// Group lines only.
    public var tl: String?
    public var kd: String?
    public var unk: String?

    public init() {}

    private static func v(_ s: String) -> String { s.isEmpty ? "-" : s }

    public func format() -> String {
        var parts: [String] = [
            "QA-PQLEVEL v=1",
            "call=" + Self.v(call),
            "kind=" + Self.v(kind),
            "level=" + Self.v(level),
            "auth=" + Self.v(auth),
            "sas=" + Self.v(sas),
            "dtls=" + Self.v(dtls),
            "frame=" + Self.v(frame),
            "relay=" + Self.v(relay),
            "dcmux=" + Self.v(dcmux),
            "inner=" + Self.v(inner),
            "rvideo=" + Self.v(rvideo),
            "pin=" + Self.v(pin),
            "hold=" + Self.v(hold),
            "withdraw=" + Self.v(withdraw),
            "caps=" + Self.v(caps),
            "pqstate=" + Self.v(pqstate),
            "pq_sig=" + Self.v(pqSig),
            "outer=" + Self.v(outer),
            "reason=" + Self.v(reason),
            "rekey=" + Self.v(rekey),
            "round=" + Self.v(round),
        ]
        if kind == "group" {
            parts.append("tl=" + Self.v(tl ?? ""))
            parts.append("kd=" + Self.v(kd ?? ""))
            parts.append("unk=" + Self.v(unk ?? ""))
        }
        return parts.joined(separator: " ")
    }
}

/// The group (`dtls=`) value of the PeerConnection's own handshake report line (`NativeHandshakeLogLine`): `pq` for the hybrid
/// group X25519MLKEM768 (0x11ec), `cl` for any other. nil when the line carries no group field.
public enum PqDtlsGroup {
    public static let hybridGroupCode: UInt16 = 0x11ec

    public static func token(fromHandshakeLine line: String) -> String? {
        guard let r = line.range(of: " group=") else { return nil }
        let hex = line[r.upperBound...].prefix(while: { $0.isHexDigit })
        guard !hex.isEmpty, let code = UInt16(hex, radix: 16) else { return nil }
        return code == hybridGroupCode ? "pq" : "cl"
    }
}
