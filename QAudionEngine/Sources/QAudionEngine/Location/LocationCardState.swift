import Foundation

// What the card of a location message in a conversation shows (docs/LOCATION_SHARING.md 1.5, "Cards"), decided from what the row holds and
// what the live-share store says, with no UI and no clock of its own. The app draws it; the rules are here so they are tested.
//
//   Pin               the position of the message, for whoever sent it and whoever received it
//   Live, active      a share that is running: the receiver sees the newest position and when it arrived, the sender sees that it runs
//   Live, stale       the receiver's share has not heard from the sender for a while: the last position stays, with its age
//   Live, ended       "Condivisione terminata": no position, no actions
//   Unreadable        a row that does not read back as a location (never shown as text)
//
// A position is never printed by this type.

public struct LocationCardState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {

    public enum Kind: Equatable, Sendable {
        case pin
        case liveActive
        case liveStale
        case liveEnded
        case unreadable
    }

    public let kind: Kind
    /// The share or the pin is this device's own message.
    public let own: Bool
    public let latE7: Int32?
    public let lonE7: Int32?
    public let accuracy: Int?
    public let approximate: Bool
    /// Unix seconds: when the newest update arrived (a received share).
    public let lastUpdateAt: Int64?
    /// Unix seconds: the end time of a running share.
    public let endAt: Int64?

    public init(kind: Kind, own: Bool, latE7: Int32? = nil, lonE7: Int32? = nil, accuracy: Int? = nil, approximate: Bool = false,
                lastUpdateAt: Int64? = nil, endAt: Int64? = nil) {
        self.kind = kind
        self.own = own
        self.latE7 = latE7
        self.lonE7 = lonE7
        self.accuracy = accuracy
        self.approximate = approximate
        self.lastUpdateAt = lastUpdateAt
        self.endAt = endAt
    }

    public var description: String { "LocationCardState(redacted)" }
    public var debugDescription: String { description }

    /// Whether the card offers the actions on a position (open, share as GPX, copy): a pin, and a receiver's running or stale share.
    public var hasPosition: Bool {
        latE7 != nil && lonE7 != nil
    }
}

public enum LocationCardResolver {

    /// - Parameters:
    ///   - rowText: the `plaintext` of the message row.
    ///   - outgoing: the row is this device's own message.
    ///   - ownShareEndAt: for an own live row, the end time (unix seconds) when a share is running on this device now, else `nil`.
    ///   - view: for a received live row, what the receiver of that conversation says about the share, else `nil` (no record).
    public static func resolve(rowText: String, outgoing: Bool, ownShareEndAt: Int64?, view: LiveShareView?) -> LocationCardState {
        guard let form = LocationRowForm.parse(rowText) else {
            return LocationCardState(kind: .unreadable, own: outgoing)
        }
        switch form {
        case .pin(let position):
            return LocationCardState(kind: .pin, own: outgoing, latE7: position.latE7, lonE7: position.lonE7,
                                     accuracy: position.accuracy, approximate: position.approximate)
        case .live:
            if outgoing {
                guard let endAt = ownShareEndAt else { return LocationCardState(kind: .liveEnded, own: true) }
                return LocationCardState(kind: .liveActive, own: true, endAt: endAt)
            }
            guard let view = view, !view.noCard, view.state != .ended, let position = view.position else {
                return LocationCardState(kind: .liveEnded, own: false)
            }
            let kind: LocationCardState.Kind = view.state == .stale ? .liveStale : .liveActive
            return LocationCardState(kind: kind, own: false, latE7: position.latE7, lonE7: position.lonE7,
                                     accuracy: position.accuracy, approximate: position.approximate,
                                     lastUpdateAt: view.lastFrameAt, endAt: view.endAt)
        }
    }
}
