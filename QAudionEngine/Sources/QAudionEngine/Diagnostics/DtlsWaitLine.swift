import Foundation

/// W-DTLSWAIT (2026-10-07) -- the one-line-per-second probe of the DTLS handshake wait of a 1:1 call, from the moment
/// ICE reaches checking/connected until the DTLS state reads connected (at most `maxLines` lines per controller).
/// It answers, from the log alone, what a call with "ICE up, DTLS connecting, no audio" was doing: which candidate pair
/// carried it (types only), in what pair state, and whether the DTLS bytes moved in either direction. Telemetry only:
/// nothing here decides anything about the call. Foundation only, so the whole file is unit-tested off-device
/// (`DtlsWaitLineTests`).
///
/// Line shape (every word and number below is built for the phone-log shipper, `scripts/ship-ios-logs.py`, which keeps
/// a body only if it has at most two words outside its vocabulary and masks an unprotected key=value token of 12 or
/// more characters; the exact texts are pinned by `scripts/test_ship_ios_dtlswait_vocab.py`):
///
///     dtls wait count=3 ms=2150 lct=host nt=3 rct=host cps=running sent=1420 recv=0 state=connecting
///
///  * `count`  line number of this call leg, 1...20.
///  * `ms`     milliseconds since ICE first reported checking/connected; capped at 99999 (= 99.999 s or more).
///  * `lct`/`rct`  local/remote candidate TYPE of the pair that carries the DTLS: host, srflx, prflx, relay, none
///    (no such row yet), other (a type this build does not know). Never an address.
///  * `nt`     local candidate network type: 1 wifi, 2 ethernet, 3 cellular, 4 vpn, 5 loopback, 6 unknown, 0 not
///    reported (`NativeAudioHeartbeatDeltas.networkTypeCode`).
///  * `cps`    candidate-pair state, shortened to fit the shipper: frozen, waiting, running (in-progress), ok
///    (succeeded), failed, cancel (cancelled), none, other.
///  * `sent`/`recv`  the transport's byte counters (omitted when the stats row does not carry them); capped at 9999999.
///  * `state`  the DTLS transport state: new, connecting, connected, closed, failed, none, other.
///
/// No address, id, fingerprint, key or token ever reaches the line: every text is mapped through a closed set above.
public enum DtlsWaitLine {

    /// Lines per controller (one controller = one call leg). The line that first shows `state=connected` is the last.
    public static let maxLines: Int = 20

    /// Minimum spacing between two lines. The 1 Hz call sampler and the capture-live poll both read the stats; this
    /// keeps the cadence at about one line per second whoever asks.
    public static let minIntervalMs: Int64 = 900

    /// `ms=` cap: 5 digits. The shipper allows two numbers of 6+ digits per body, and `sent`/`recv` may use both.
    static let msCap: Int64 = 99_999

    /// `sent=`/`recv=` cap: 7 digits, the widest number the shipper protects as a plain integer.
    static let bytesCap: Int64 = 9_999_999

    /// The line. A negative byte counter is "no such stats row" (-1) and is omitted, never printed.
    public static func format(count: Int, elapsedMs: Int64, localType: String?, networkTypeCode: Int,
                              remoteType: String?, pairState: String?, bytesSent: Int64, bytesReceived: Int64,
                              dtlsState: String?) -> String {
        var out: String = "dtls wait"
        out += CallMetricsLines.field("count", max(0, count))
        out += CallMetricsLines.field("ms", min(max(0, elapsedMs), msCap))
        out += " lct=" + typeWord(localType)
        out += CallMetricsLines.field("nt", min(max(0, networkTypeCode), 9))
        out += " rct=" + typeWord(remoteType)
        out += " cps=" + pairStateWord(pairState)
        out += CallMetricsLines.field("sent", bytesSent < 0 ? bytesSent : min(bytesSent, bytesCap))
        out += CallMetricsLines.field("recv", bytesReceived < 0 ? bytesReceived : min(bytesReceived, bytesCap))
        out += " state=" + dtlsStateWord(dtlsState)
        return out
    }

    /// host / srflx / prflx / relay, `none` when the row is missing, `other` for anything else.
    static func typeWord(_ raw: String?) -> String {
        guard let raw else { return "none" }
        switch raw.lowercased() {
        case "host": return "host"
        case "srflx": return "srflx"
        case "prflx": return "prflx"
        case "relay": return "relay"
        default: return "other"
        }
    }

    /// The WebRTC candidate-pair states, at most 7 letters each (an unprotected `cps=` token of 12 characters is
    /// masked by the shipper: `cps=succeeded`, `cps=in-progress` and `cps=cancelled` all were).
    static func pairStateWord(_ raw: String?) -> String {
        guard let raw else { return "none" }
        switch raw.lowercased() {
        case "frozen": return "frozen"
        case "waiting": return "waiting"
        case "in-progress": return "running"
        case "succeeded": return "ok"
        case "failed": return "failed"
        case "cancelled": return "cancel"
        default: return "other"
        }
    }

    /// The RTCDtlsTransportState values.
    static func dtlsStateWord(_ raw: String?) -> String {
        guard let raw else { return "none" }
        switch raw.lowercased() {
        case "new": return "new"
        case "connecting": return "connecting"
        case "connected": return "connected"
        case "closed": return "closed"
        case "failed": return "failed"
        default: return "other"
        }
    }

    // MARK: - Which candidate pair carries the DTLS

    /// One `candidate-pair` stats row, reduced to what the choice needs.
    public struct Pair: Equatable, Sendable {
        public var id: String
        public var state: String?
        public var nominated: Bool
        public var localId: String?
        public var remoteId: String?

        public init(id: String, state: String?, nominated: Bool, localId: String?, remoteId: String?) {
            self.id = id
            self.state = state
            self.nominated = nominated
            self.localId = localId
            self.remoteId = remoteId
        }
    }

    /// The pair to describe, in this order: the one the transport reports as selected; a nominated succeeded pair; a
    /// nominated pair; a succeeded pair; an in-progress pair; else none. Ties are broken by id so the answer does not
    /// change between two polls only because a dictionary iterated in another order. (The heartbeat's own choice only
    /// looks at succeeded pairs, which is exactly the set that is still empty while the handshake is being waited for.)
    public static func pick(_ pairs: [Pair], selectedId: String?) -> Pair? {
        let sorted: [Pair] = pairs.sorted { $0.id < $1.id }
        if let selectedId, let hit = sorted.first(where: { $0.id == selectedId }) { return hit }
        if let hit = sorted.first(where: { $0.nominated && $0.state == "succeeded" }) { return hit }
        if let hit = sorted.first(where: { $0.nominated }) { return hit }
        if let hit = sorted.first(where: { $0.state == "succeeded" }) { return hit }
        return sorted.first(where: { $0.state == "in-progress" })
    }
}

/// When a `DtlsWaitLine` is due. Not started until ICE first reports checking/connected, then at most one line per
/// `minIntervalMs` and `maxLines` in all; finished for good once a line shows the DTLS state connected, after which
/// `wantsSample` is false and the stats callback does none of the extra work. The owner serialises access.
public struct DtlsWaitProbe: Sendable {
    private var iceStartedMs: Int64?
    private var lastLineMs: Int64?
    public private(set) var lines: Int = 0
    public private(set) var finished: Bool = false

    public init() {}

    /// ICE reported checking, connected or completed. Only the first call counts (an ICE restart does not restart the
    /// clock), and nothing after the probe finished.
    public mutating func noteIceActive(nowMs: Int64) {
        guard iceStartedMs == nil, !finished else { return }
        iceStartedMs = nowMs
    }

    /// Cheap pre-check, before the stats are walked: is a line due now?
    public func wantsSample(nowMs: Int64) -> Bool {
        guard !finished, lines < DtlsWaitLine.maxLines, iceStartedMs != nil else { return false }
        if let last = lastLineMs, nowMs - last < DtlsWaitLine.minIntervalMs { return false }
        return true
    }

    /// Claims the line when one is due: its number and the milliseconds since ICE started. Finishes the probe when
    /// this line shows the DTLS state connected or is the last allowed.
    public mutating func take(nowMs: Int64, dtlsState: String?) -> (count: Int, elapsedMs: Int64)? {
        guard wantsSample(nowMs: nowMs), let start = iceStartedMs else { return nil }
        lines += 1
        lastLineMs = nowMs
        if dtlsState == "connected" || lines >= DtlsWaitLine.maxLines { finished = true }
        return (lines, max(0, nowMs - start))
    }
}
