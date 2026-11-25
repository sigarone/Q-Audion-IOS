import Foundation

/// Which CoreBluetooth callbacks the one earbud GATT client acts on.
///
/// The client follows ONE peripheral at a time. When a caller asks for another earbud, it cancels the
/// link of the old one and starts the new one, but CoreBluetooth reports the old link's end later
/// (`didDisconnectPeripheral`, or `didFailToConnect` for a request that was still pending), after the
/// new peripheral has become the current one. Acted on, that late callback of the OLD peripheral
/// clears the characteristics and the "ready" flag of the NEW link, or fails the operation that is
/// running on it, and the new connection looks lost although it is fine.
///
/// So every link callback is checked against the peripheral the client follows now, by CoreBluetooth
/// identifier (`CBPeripheral.identifier`; the same earbud may come back as another object). Pure
/// Foundation, so the rule is unit-tested without CoreBluetooth (EarbudLinkIdentityTests).
public enum EarbudLinkIdentity {

    /// True when a callback about the peripheral `callback` concerns the client's current link.
    ///
    /// - Parameters:
    ///   - callback: the identifier of the peripheral the callback is about.
    ///   - current: the identifier of the peripheral the client follows; nil when it follows none, in
    ///     which case no callback concerns it.
    public static func concernsCurrentLink(callback: UUID, current: UUID?) -> Bool {
        guard let current = current else { return false }
        return callback == current
    }
}
