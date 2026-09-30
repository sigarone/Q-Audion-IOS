import Foundation

/// Group calls v2 (spec §4.6) — the client-driven layer / subscription policy.
/// Janus has no downlink allocator, so every receiver picks the simulcast
/// substream of each remote video itself:
///
///  * target substream by tile size — thumbnail 0, grid 1, fullscreen/speaker 2
///    (temporal layer 2 always);
///  * step DOWN one substream immediately on a `slowlink` event, on loss above
///    5 % over 2 s, or when the available incoming bitrate is below 1.2x what
///    the current layers need; step UP one substream after 10 s clean;
///  * unsubscribe tiles that are off-screen / hidden, and every remote video
///    while the app is in the background; audio is never touched here.
///
/// Pure state machine: time is passed in, decisions come out as `Action`s.
/// Not thread-safe by itself — the owner serialises every call.
public final class GroupLayerPolicy {

    public enum TileClass: Int, Sendable {
        case thumbnail = 0
        case grid = 1
        case fullscreen = 2
    }

    public struct Config: Sendable {
        /// Bitrate of each substream l / m / h (spec §4.4).
        public var layerBitrates: [Int] = [150_000, 450_000, 1_200_000]
        public var lossThresholdPercent: Double = 5
        public var lossWindowMs: Int64 = 2_000
        /// Fewer packets than this in the window are too few to judge loss.
        public var minPacketsForLoss = 20
        public var bandwidthHeadroom: Double = 1.2
        public var upgradeAfterMs: Int64 = 10_000
        public var bandwidthStepMinIntervalMs: Int64 = 2_000
        public var temporalLayer = 2

        public init() {}
    }

    public enum Action: Hashable, Sendable {
        case subscribe(key: String)
        case unsubscribe(key: String)
        /// `from` is the substream last commanded (-1 = none yet).
        case configure(key: String, substream: Int, temporal: Int, from: Int, reason: String)
    }

    private struct LossSample {
        let atMs: Int64
        let lost: Int
        let received: Int
    }

    private struct StreamState {
        var tile: TileClass = .grid
        var visible = true
        /// Whether the stream is currently subscribed (as last commanded).
        var subscribed = true
        /// Highest substream congestion currently allows.
        var ceiling = 2
        /// Substream last commanded, -1 until the first `configure`.
        var current = -1
        var lastDegradeMs: Int64 = Int64.min / 4
        var lastUpgradeMs: Int64 = Int64.min / 4
        var losses: [LossSample] = []
        var pendingReason = "subscribe"
    }

    public let config: Config
    private var streams: [String: StreamState] = [:]
    private var order: [String] = []
    private var backgrounded = false
    private var lastBandwidthStepMs: Int64 = Int64.min / 4

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Inputs

    /// Starts tracking a remote video stream (subscribed, grid tile).
    public func register(key: String) {
        guard streams[key] == nil else { return }
        streams[key] = StreamState()
        order.append(key)
    }

    public func unregister(key: String) {
        streams[key] = nil
        order.removeAll { $0 == key }
    }

    public func setTile(key: String, tile: TileClass, visible: Bool) {
        guard var state = streams[key] else { return }
        state.tile = tile
        state.visible = visible
        streams[key] = state
    }

    public func setBackgrounded(_ value: Bool) {
        backgrounded = value
    }

    /// Per-stream inbound-rtp deltas since the previous sample.
    public func onLossSample(key: String, packetsLostDelta: Int, packetsReceivedDelta: Int, nowMs: Int64) {
        guard var state = streams[key], state.subscribed else { return }
        state.losses.append(LossSample(atMs: nowMs, lost: max(0, packetsLostDelta), received: max(0, packetsReceivedDelta)))
        state.losses.removeAll { nowMs - $0.atMs > config.lossWindowMs }
        let lost = state.losses.reduce(0) { $0 + $1.lost }
        let received = state.losses.reduce(0) { $0 + $1.received }
        let total = lost + received
        if total >= config.minPacketsForLoss, Double(lost) * 100.0 / Double(total) > config.lossThresholdPercent {
            state.losses.removeAll()
            streams[key] = state
            degrade(key: key, reason: "loss", nowMs: nowMs)
            return
        }
        streams[key] = state
    }

    /// Janus `slowlink` on the subscriber handle: it is per handle, not per
    /// stream, so the stream on the highest substream steps down.
    public func onSlowlink(nowMs: Int64) {
        if let key = highestSubscribedKey() { degrade(key: key, reason: "slowlink", nowMs: nowMs) }
    }

    /// `availableIncomingBitrate` of the subscriber's selected candidate pair.
    public func onBandwidthSample(availableBps: Double, nowMs: Int64) {
        guard nowMs - lastBandwidthStepMs >= config.bandwidthStepMinIntervalMs else { return }
        var needed = 0.0
        for key in order {
            guard let state = streams[key], state.subscribed else { continue }
            needed += Double(layerBitrate(max(state.current, 0))) * config.bandwidthHeadroom
        }
        guard needed > 0, availableBps < needed else { return }
        if let key = highestSubscribedKey() {
            lastBandwidthStepMs = nowMs
            degrade(key: key, reason: "bandwidth", nowMs: nowMs)
        }
    }

    // MARK: - Decisions

    /// The commands that bring the subscriber in line with the policy right
    /// now. Call after every input change and on a slow timer (the 10 s
    /// upgrade needs the clock to advance).
    public func evaluate(nowMs: Int64) -> [Action] {
        var actions: [Action] = []
        for key in order {
            guard var state = streams[key] else { continue }
            let wantsSubscription = state.visible && !backgrounded
            if wantsSubscription != state.subscribed {
                state.subscribed = wantsSubscription
                if wantsSubscription {
                    state.current = -1
                    state.pendingReason = "subscribe"
                    actions.append(.subscribe(key: key))
                } else {
                    state.current = -1
                    actions.append(.unsubscribe(key: key))
                }
            }
            if state.subscribed {
                if state.ceiling < 2,
                   nowMs - state.lastDegradeMs >= config.upgradeAfterMs,
                   nowMs - state.lastUpgradeMs >= config.upgradeAfterMs {
                    state.ceiling += 1
                    state.lastUpgradeMs = nowMs
                    state.pendingReason = "recover"
                }
                let effective = min(state.tile.rawValue, state.ceiling)
                if effective != state.current {
                    actions.append(.configure(key: key, substream: effective, temporal: config.temporalLayer,
                                              from: state.current, reason: state.pendingReason))
                    state.current = effective
                    state.pendingReason = "tile"
                }
            }
            streams[key] = state
        }
        return actions
    }

    // MARK: - Introspection (tests, telemetry)

    public func currentSubstream(key: String) -> Int? { streams[key]?.current }
    public func isSubscribed(key: String) -> Bool { streams[key]?.subscribed ?? false }
    public func ceiling(key: String) -> Int? { streams[key]?.ceiling }

    // MARK: - Helpers

    private func layerBitrate(_ substream: Int) -> Int {
        let bitrates = config.layerBitrates
        guard !bitrates.isEmpty else { return 0 }
        return bitrates[min(max(substream, 0), bitrates.count - 1)]
    }

    private func highestSubscribedKey() -> String? {
        var best: String?
        var bestLevel = -1
        for key in order {
            guard let state = streams[key], state.subscribed else { continue }
            let level = max(state.current, 0)
            if level > bestLevel {
                bestLevel = level
                best = key
            }
        }
        return best
    }

    /// One step down from the substream in use; never below `l`.
    private func degrade(key: String, reason: String, nowMs: Int64) {
        guard var state = streams[key], state.subscribed else { return }
        let inUse = state.current >= 0 ? state.current : min(state.tile.rawValue, state.ceiling)
        guard inUse > 0 else {
            state.lastDegradeMs = nowMs
            streams[key] = state
            return
        }
        state.ceiling = min(state.ceiling, inUse) - 1
        state.lastDegradeMs = nowMs
        state.pendingReason = reason
        streams[key] = state
    }
}
