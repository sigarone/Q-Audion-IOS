import Foundation

/// Which tile a remote video is shown in (the view layer's vocabulary), mapped
/// by `GroupCallController` onto `GroupLayerPolicy.TileClass`.
public enum RemoteVideoRenderPriority: Sendable, Equatable {
    /// Not on screen: the stream is unsubscribed.
    case offScreen
    /// A grid tile.
    case onScreenSmall
    /// The speaker / spotlight tile.
    case onScreenSpotlight
    /// A thumbnail strip tile.
    case thumbnail

    var tileClass: GroupLayerPolicy.TileClass {
        switch self {
        case .offScreen, .thumbnail: return .thumbnail
        case .onScreenSmall: return .grid
        case .onScreenSpotlight: return .fullscreen
        }
    }

    var isVisible: Bool { self != .offScreen }
}

/// "Who is speaking", computed on the receiver from the decoded audio level
/// (the audio-level RTP extension is not negotiated, spec §4.4). A member
/// counts as speaking while its level is above the threshold and for a short
/// hold time afterwards, so the indicator does not flicker between words.
public struct GroupSpeakingDetector: Sendable {
    public var threshold: Double
    public var holdMs: Int64
    private var lastActiveMs: [String: Int64] = [:]

    public init(threshold: Double = 0.02, holdMs: Int64 = 1_200) {
        self.threshold = threshold
        self.holdMs = holdMs
    }

    /// `levels`: identity -> level 0...1 of the latest stats tick. Returns the
    /// speaking set, loudest first.
    public mutating func update(levels: [String: Double], nowMs: Int64) -> [String] {
        for (identity, level) in levels where level > threshold { lastActiveMs[identity] = nowMs }
        lastActiveMs = lastActiveMs.filter { nowMs - $0.value <= holdMs && levels[$0.key] != nil }
        return lastActiveMs.keys.sorted { (levels[$0] ?? 0) > (levels[$1] ?? 0) }
    }

    public mutating func reset() {
        lastActiveMs.removeAll()
    }
}

/// Uplink policy (spec §4.7 "Congestion policy: audio first; drop to substream
/// l, then stop video publish, never audio") and the phone thermal / battery
/// rule of §4.4 ("phones MAY publish only l/m under thermal / battery
/// pressure"). Pure: the decision only, the WebRTC wrapper applies it.
public enum GroupPublishPolicy {

    /// How many of the simulcast encodings (l, m, h) stay active.
    public struct Decision: Equatable, Sendable {
        /// 0 = stop the video publish entirely, 1 = l, 2 = l+m, 3 = l+m+h.
        public let activeLayers: Int
        public var publishVideo: Bool { activeLayers > 0 }
    }

    public enum Thermal: Int, Sendable {
        case nominal = 0, fair, serious, critical
    }

    /// `congestionSteps`: how many times Janus reported a slow uplink and the
    /// policy has stepped down since the last clean period (0 = none).
    public static func decide(thermal: Thermal, lowPowerMode: Bool, congestionSteps: Int) -> Decision {
        var layers = 3
        switch thermal {
        case .nominal, .fair: break
        case .serious: layers = 2
        case .critical: layers = 1
        }
        if lowPowerMode { layers = min(layers, 2) }
        layers -= max(0, congestionSteps)
        return Decision(activeLayers: max(0, layers))
    }
}
