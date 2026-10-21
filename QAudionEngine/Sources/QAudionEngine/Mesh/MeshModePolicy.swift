import Foundation

/// The user's answer to the Bluetooth mesh consent screen, about ONE thing: may this
/// phone relay other people's encrypted messages?
///
/// - `undecided`: the screen has not been answered; the radio stays off and no
///   Bluetooth permission is asked for.
/// - `accepted`: relaying is allowed; the default mode is `.fullMesh`.
/// - `declined`: relaying is not allowed; the default mode is `.direct`, which
///   still finds the contacts nearby and exchanges the user's own messages with
///   them but never forwards anyone else's.
public enum MeshRelayConsent: String, Equatable, Sendable {
    case undecided
    case accepted
    case declined
}

/// Which radio mode a consent allows (docs/mesh/MESH_LINK_SPEC.md section 2) and what
/// the platform's background rules mean for each mode (section 12). Plain values in,
/// plain answer out.
public enum MeshModePolicy {

    /// The mode the antenna comes up in when the user has not picked one.
    public static func defaultMode(consent: MeshRelayConsent) -> MeshAntennaMode? {
        switch consent {
        case .undecided: return nil
        case .accepted: return .fullMesh
        case .declined: return .direct
        }
    }

    /// `.fullMesh` needs the consent to relay; `.direct` and `.visibleOnly` only need that the screen was answered.
    public static func mayStart(featureEnabled: Bool, consent: MeshRelayConsent, mode: MeshAntennaMode) -> Bool {
        guard featureEnabled else { return false }
        switch consent {
        case .undecided: return false
        case .accepted: return true
        case .declined: return !mode.relays
        }
    }

    /// A mode the consent does not allow becomes the strongest one it does: a user who declined relaying never
    /// ends up in `.fullMesh`, whatever asked for it.
    public static func allowedMode(_ requested: MeshAntennaMode, consent: MeshRelayConsent) -> MeshAntennaMode? {
        switch consent {
        case .undecided: return nil
        case .accepted: return requested
        case .declined: return requested.relays ? .direct : requested
        }
    }

    /// Whether a backgrounded phone in `mode` can be reached by a device that cannot see an iPhone's
    /// background advertisement. With `bluetooth-peripheral` a backgrounded iPhone advertises its service UUID only
    /// in an overflow area that non-Apple scanners do not match, so the only way in is for the iPhone to connect out
    /// itself (`bluetooth-central`, scanning with the service UUID filter). A mode that never connects out is therefore
    /// reachable only while the app is in the foreground.
    public static func reachableInBackground(mode: MeshAntennaMode) -> Bool {
        mode.connectsOut
    }
}

/// Lets an action run at most once per interval across every caller (the
/// unknown-sender directory refresh of section 11: once per 60 s).
public struct MeshRefreshGate: Equatable, Sendable {
    public static let intervalMs: Int64 = 60_000

    private var lastRunMs: Int64?

    public init() {}

    /// True (and the gate closes) if the action may run now.
    public mutating func tryEnter(nowMs: Int64) -> Bool {
        if let lastRunMs, nowMs - lastRunMs < Self.intervalMs { return false }
        lastRunMs = nowMs
        return true
    }
}

/// Lets an action run at most once per interval PER KEY (answering a duplicate message with a fresh
/// delivery receipt, at most every 10 s per message). Old keys are forgotten once the table grows.
public struct MeshKeyedGate: Equatable, Sendable {
    public let intervalMs: Int64
    private var lastRunMs: [String: Int64] = [:]
    private static let maxKeys = 512

    public init(intervalMs: Int64) {
        self.intervalMs = intervalMs
    }

    /// True (and the key's gate closes) if the action may run now for `key`.
    public mutating func tryEnter(key: String, nowMs: Int64) -> Bool {
        if let last = lastRunMs[key], nowMs - last < intervalMs { return false }
        if lastRunMs.count >= Self.maxKeys {
            lastRunMs = lastRunMs.filter { nowMs - $0.value < intervalMs }
        }
        lastRunMs[key] = nowMs
        return true
    }
}
