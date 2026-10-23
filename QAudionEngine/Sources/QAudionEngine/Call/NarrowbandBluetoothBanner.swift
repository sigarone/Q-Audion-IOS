import Foundation

/// IN-CALL NARROWBAND BLUETOOTH NOTICE (2026-10-22) -- the rules of the small banner that tells the user that the call
/// audio runs over a Bluetooth hands-free link limited to 8 kHz, and offers one tap to move the call to the phone.
/// Foundation only: the decisions, the dismissal, the call scope and the two log lines are unit-tested off-device
/// (`NarrowbandBluetoothBannerTests`), and so is the live side that watches the route, `NarrowbandBluetoothWatcher`
/// (`NarrowbandBluetoothWatcherTests`, with a fake route and clock); the app only reads `AVAudioSession` and draws.
/// The Android app follows the same rules (same thresholds, same lines).
///
/// The condition is the one the `audioroute ... profile=1 sr=8000` line already records: the INPUT port of the session
/// route is Bluetooth hands-free (HFP) and the session sample rate is 8 kHz or less. A 16 kHz (wideband) hands-free
/// link, a Bluetooth music profile (A2DP, output only: the microphone stays the built-in one), LE Audio and every
/// non-Bluetooth route never show it.
public enum NarrowbandBluetoothPolicy {

    /// `AVAudioSession.Port.bluetoothHFP.rawValue`.
    public static let handsFreeInputPort: String = "BluetoothHFP"

    /// The hands-free link is narrowband at this rate or below (CVSD, 8 kHz). Wideband (mSBC) is 16 kHz.
    public static let maxNarrowbandHz: Int = 8000

    /// True when the call audio input is a Bluetooth hands-free route running at 8 kHz or less.
    /// `inputPort` is the raw value of the first input port of the current route (nil = no input).
    /// `sampleRateHz` is the session's actual sample rate; a value that cannot be read (zero, negative, not finite)
    /// is "unknown", and unknown never shows the banner.
    public static func isNarrowbandHandsFree(inputPort: String?, sampleRateHz: Double) -> Bool {
        guard inputPort == handsFreeInputPort else { return false }
        guard sampleRateHz.isFinite, sampleRateHz > 0, sampleRateHz < 1_000_000 else { return false }
        return Int(sampleRateHz.rounded()) <= maxNarrowbandHz
    }
}

/// Whether the banner is up, for one call. The route is fed in as it is observed (route change, periodic sample); the
/// state says what the screen has to do about it. Nothing here touches the audio session.
///
///  * It shows once the narrowband hands-free route has held for `settleSeconds` without a break (a hands-free link can
///    report a provisional rate for a moment while it negotiates; a banner that flashes and goes would only be noise).
///    An observation that is not narrowband hands-free, an unreadable rate included, restarts that count.
///  * It hides on its own the moment the route stops being a narrowband hands-free one (the user switched to the phone,
///    the headset disconnected, the link came up wideband). It is not latched: if Bluetooth is chosen again later and the
///    route is narrowband again for `settleSeconds`, it shows again.
///  * The user can dismiss it; that holds for the rest of the call (`reset` at the start of the next call clears it).
///  * The `shown` log line is written for the first `maxShownLinesPerCall` appearances of a call and not after (a link
///    that flaps would otherwise write one at every return); the banner itself keeps following the link.
public struct NarrowbandBluetoothBannerState: Equatable, Sendable {

    /// How long a narrowband hands-free route has to hold before the banner shows.
    public static let settleSeconds: Double = 1.0

    /// At most this many `audioroute nb_banner` lines per call.
    public static let maxShownLinesPerCall: Int = 5

    /// What an observation or a dismissal did to the banner.
    public enum Change: Equatable, Sendable {
        case unchanged
        /// The banner went up; `sampleRateHz` is the rate that made it (for the log line), `log` says whether the line
        /// is still to be written (false once `maxShownLinesPerCall` lines were written for this call).
        case shown(sampleRateHz: Int, log: Bool)
        /// The banner went away.
        case hidden
    }

    public private(set) var isVisible: Bool = false
    public private(set) var isDismissed: Bool = false
    public private(set) var shownLines: Int = 0
    private var narrowbandSince: Double?

    public init() {}

    /// The moment (same clock as `observe`) at which the banner shows if the route keeps holding: the start of the
    /// narrowband count plus `settleSeconds`. Nil when there is nothing to wait for: the banner is already up, it was
    /// dismissed, or the route is not narrowband hands-free right now. The watcher schedules one look at this moment,
    /// so the banner appears when the settle time is over and not at the next periodic look.
    public var showDeadline: Double? {
        guard !isVisible, !isDismissed, let since = narrowbandSince else { return nil }
        return since + Self.settleSeconds
    }

    /// One look at the route. `now` is a monotonic clock in seconds (the caller's choice; only differences matter).
    @discardableResult
    public mutating func observe(inputPort: String?, sampleRateHz: Double, now: Double) -> Change {
        guard NarrowbandBluetoothPolicy.isNarrowbandHandsFree(inputPort: inputPort, sampleRateHz: sampleRateHz) else {
            narrowbandSince = nil
            guard isVisible else { return .unchanged }
            isVisible = false
            return .hidden
        }
        let since: Double = narrowbandSince ?? now
        narrowbandSince = since
        guard !isVisible, !isDismissed, now - since >= Self.settleSeconds else { return .unchanged }
        isVisible = true
        let writeLine: Bool = shownLines < Self.maxShownLinesPerCall
        if writeLine { shownLines += 1 }
        return .shown(sampleRateHz: Int(sampleRateHz.rounded()), log: writeLine)
    }

    /// The user closed the banner: it stays closed for the rest of the call.
    @discardableResult
    public mutating func dismiss() -> Change {
        isDismissed = true
        guard isVisible else { return .unchanged }
        isVisible = false
        return .hidden
    }

    /// A new call (or the end of the last one): nothing is remembered.
    public mutating func reset() {
        self = NarrowbandBluetoothBannerState()
    }
}

/// What "one call" is for the banner: the dismissal, the settle count and the log-line count belong to it. A 1:1 call is
/// one call; a group call is another, identified by its call id, so a 1:1 call promoted to a group is a NEW call and the
/// banner starts clean (a dismissal is forgotten, and the banner shows again after the settle time if the route is still
/// narrowband). The Android app keys its banner the same way (the call id of the screen).
public enum NarrowbandBluetoothCallScope {

    /// The key of a 1:1 call (there is never more than one at a time, and a call that ends always passes through nil).
    public static let oneToOne: String = "1:1"

    /// The key of the call that is up now, or nil when none is. A live group call wins over the 1:1 call it grew out of
    /// (the hand-over keeps both up for a moment).
    public static func key(oneToOneLive: Bool, groupCallId: String?) -> String? {
        if let groupCallId = groupCallId { return "g:" + groupCallId }
        return oneToOneLive ? oneToOne : nil
    }
}

/// The numeric log lines of the notice. Tag "call", the family word `audioroute` first, like the route line
/// (`CallRouteDiagnostics.routeLine`): numbers only, so the phone-log shipper and the in-app redactor let them through
/// (pinned by `test_ship_ios_callmetrics_vocab.py` and `CallMetricsRedactionTests`). Two lines, the same two on Android;
/// the effect of a tap is the ordinary `audioroute` route line that follows it.
public enum NarrowbandBluetoothLines {

    /// `audioroute nb_banner shown=1 sr=<Hz>`: the banner went up on a route at this sample rate (at most
    /// `NarrowbandBluetoothBannerState.maxShownLinesPerCall` per call).
    public static func shown(sampleRateHz: Int) -> String {
        var out: String = "audioroute nb_banner shown=1"
        out += CallMetricsLines.field("sr", min(max(sampleRateHz, 0), 99_999))
        return out
    }

    /// `audioroute nb_switch tap=1`: the user tapped "use the phone" (every tap; one per human tap, no cap).
    public static let switchTap: String = "audioroute nb_switch tap=1"
}
