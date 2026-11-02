import Foundation

/// App Store build switches for UI that must stay hidden until the matching
/// feature is actually sold or wired. Both default to hidden; the views and
/// their code are kept, only the entry point is gated.
enum StoreComplianceFlags {
    /// The "PRO" pill next to the wordmark. Stays hidden until Pro is sold
    /// through In-App Purchase.
    static let showProBadge = false

    /// The "Link new device" entry in the device list. Stays hidden until
    /// device pairing works end to end.
    static let showLinkNewDevice = false
}
