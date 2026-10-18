import Foundation

/// How many ICE candidates of each type one gathering produced.
///
/// Only the TYPE of a candidate is read from its SDP line (`... typ host ...`). The address and the port in the same line
/// are never stored, shown or copied: the transport check must be safe to paste into a support request.
public struct TransportCandidateCounts: Equatable, Sendable {
    public private(set) var host: Int
    public private(set) var srflx: Int
    public private(set) var relay: Int
    /// `prflx`, or a line whose type could not be read.
    public private(set) var other: Int

    public init(host: Int = 0, srflx: Int = 0, relay: Int = 0, other: Int = 0) {
        self.host = host
        self.srflx = srflx
        self.relay = relay
        self.other = other
    }

    public var total: Int { host + srflx + relay + other }

    /// Counts one candidate by the type token that follows `typ` in its SDP line.
    public mutating func add(candidateSdp: String) {
        let type: String = Self.candidateType(of: candidateSdp) ?? ""
        switch type {
        case "host": host += 1
        case "srflx": srflx += 1
        case "relay": relay += 1
        default: other += 1
        }
    }

    /// The word after `typ` in an ICE candidate line, or `nil` when there is none.
    public static func candidateType(of candidateSdp: String) -> String? {
        let tokens = candidateSdp.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let typeMarker = tokens.firstIndex(of: "typ"), typeMarker + 1 < tokens.count else { return nil }
        return String(tokens[typeMarker + 1])
    }
}

/// The verdict of a transport check for the selected mode.
public enum TransportCheckOutcome: String, Equatable, Sendable, CaseIterable {
    /// p2p: candidates found and none of them relay. turn/relay: at least one relay candidate. auto: candidates found.
    case ok
    /// p2p only: a relay candidate appeared, which this mode must never produce.
    case unexpectedRelay
    /// turn/relay: no relay candidate came out of the gathering.
    case noRelayCandidate
    /// p2p/auto: not a single candidate, so there is no usable network.
    case noCandidates
    /// No server was tried, in any mode: the server did not give its list, or the list has nothing this mode may use
    /// (p2p without a STUN server, turn/relay without a TURN server or the bridge). A custom server brings its own
    /// address and credentials, so it is never in this case.
    case serverListUnavailable

    public var isOk: Bool { self == .ok }

    /// The rule of each mode. A check that tried no server is not OK in any mode, whatever the gathering found: host
    /// candidates alone say nothing about the servers the mode is about. After that, p2p differs from "no relay
    /// candidate" in one point: zero candidates in total is not OK either, because then nothing was tested.
    public static func evaluate(plan: TransportPlan, counts: TransportCandidateCounts,
                                serverListAvailable: Bool) -> TransportCheckOutcome {
        if !serverListAvailable { return .serverListUnavailable }
        switch plan.mode {
        case .p2p:
            if counts.relay > 0 { return .unexpectedRelay }
            return counts.total > 0 ? .ok : .noCandidates
        case .turn, .relay:
            return counts.relay > 0 ? .ok : .noRelayCandidate
        case .auto:
            return counts.total > 0 ? .ok : .noCandidates
        }
    }
}

/// What a transport check found. Built from the plan the call would use, so the verdict is about that configuration.
public struct TransportCheckResult: Equatable, Sendable {
    public let plan: TransportPlan
    public let counts: TransportCandidateCounts
    /// The plan had at least one server to try: the list of the BCrypto server arrived and the mode kept something of it,
    /// or the plan is a custom server (which needs no list). `false` makes the verdict `serverListUnavailable`.
    public let serverListAvailable: Bool
    /// The gathering was cut by the time limit instead of reporting that it was complete.
    public let gatheringTimedOut: Bool

    public init(plan: TransportPlan, counts: TransportCandidateCounts, serverListAvailable: Bool,
                gatheringTimedOut: Bool) {
        self.plan = plan
        self.counts = counts
        self.serverListAvailable = serverListAvailable
        self.gatheringTimedOut = gatheringTimedOut
    }

    public var outcome: TransportCheckOutcome {
        TransportCheckOutcome.evaluate(plan: plan, counts: counts, serverListAvailable: serverListAvailable)
    }

    /// The technical summary "Segnala problema" copies: mode, route, candidate types, outcome. No address, no port, no
    /// host name, no user name, no password, no custom address (only whether one was used).
    public var summary: String {
        let customState: String
        if plan.customTurn != nil {
            customState = "used"
        } else if plan.customTurnIgnored {
            customState = "ignored"
        } else {
            customState = "none"
        }
        var lines: [String] = []
        lines.append("transport_check")
        lines.append("mode=" + plan.mode.rawValue)
        lines.append("route=" + plan.route.rawValue)
        lines.append("custom_server=" + customState)
        lines.append("candidates host=\(counts.host) srflx=\(counts.srflx) relay=\(counts.relay) other=\(counts.other)")
        lines.append("gathering=" + (gatheringTimedOut ? "timeout" : "complete"))
        lines.append("result=" + outcome.rawValue)
        return lines.joined(separator: "\n")
    }
}

/// The user's "Confermo" after a check: which mode was checked, what the check found, and when. The answer is recorded
/// whatever the verdict was, OK or not: "Confermo" says the user looked at the result, and the line that shows it says
/// which result it was. Kept in `UserDefaults` (three keys), not in `SettingsStore`: `TransportSettingsViewModel` is a
/// fixed `Codable` payload written by "Salva", and adding fields to it would change what older installs have to decode.
public struct TransportCheckConfirmation: Equatable, Sendable {
    public let mode: TransportSettingsViewModel.Mode
    public let outcome: TransportCheckOutcome
    public let date: Date

    public init(mode: TransportSettingsViewModel.Mode, outcome: TransportCheckOutcome, date: Date) {
        self.mode = mode
        self.outcome = outcome
        self.date = date
    }
}

public struct TransportCheckConfirmationStore {
    public static let keyMode = "qaudion.transport.check_confirmed_mode"
    public static let keyOutcome = "qaudion.transport.check_confirmed_outcome"
    public static let keyDate = "qaudion.transport.check_confirmed_at"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func record(mode: TransportSettingsViewModel.Mode, outcome: TransportCheckOutcome, at date: Date = Date()) {
        defaults.set(mode.rawValue, forKey: Self.keyMode)
        defaults.set(outcome.rawValue, forKey: Self.keyOutcome)
        defaults.set(date.timeIntervalSince1970, forKey: Self.keyDate)
    }

    /// "Confermo" on the result of a check: the mode that was checked and what the check found. The verdict is recorded
    /// whether it was OK or not.
    public func record(result: TransportCheckResult, at date: Date = Date()) {
        record(mode: result.plan.mode, outcome: result.outcome, at: date)
    }

    /// The last confirmation, or `nil` when there is none or what is stored cannot be read (a missing or unknown mode,
    /// outcome or date).
    public func load() -> TransportCheckConfirmation? {
        guard let rawMode = defaults.string(forKey: Self.keyMode),
              let mode = TransportSettingsViewModel.Mode(rawValue: rawMode),
              let rawOutcome = defaults.string(forKey: Self.keyOutcome),
              let outcome = TransportCheckOutcome(rawValue: rawOutcome),
              let seconds = defaults.object(forKey: Self.keyDate) as? Double else { return nil }
        return TransportCheckConfirmation(mode: mode, outcome: outcome, date: Date(timeIntervalSince1970: seconds))
    }

    public func clear() {
        defaults.removeObject(forKey: Self.keyMode)
        defaults.removeObject(forKey: Self.keyOutcome)
        defaults.removeObject(forKey: Self.keyDate)
    }
}
