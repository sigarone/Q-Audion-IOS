import Foundation

// How often the phone asks the operating system for a position while a live share runs (docs/LOCATION_SHARING.md 1.1).
//
// Sampling and transmission are separate things. Transmission is FIXED by the wire contract (one frame every 30 seconds, 60 in a
// low-power mode) and never depends on movement. Sampling is ADAPTIVE because it is what costs battery, and it is a local matter that
// the server never sees. Two tiers:
//
//   moving: a fix 50 m or more from the still anchor, or a speed of 1 m/s or more.  Nearest ten metres, a distance filter of 10 m.
//   still:  no displacement of 25 m or more for 3 minutes.                          Hundred metres, a distance filter of 50 m.
//
// This is the pure decision; the app maps the tier onto `CLLocationManager`. It holds no coordinates beyond the anchor it needs to
// measure a displacement, keeps nothing on disk and describes itself with a fixed placeholder.

public enum LocationSamplingTier: Equatable, Sendable {
    case moving
    case still

    /// `desiredAccuracy` in metres (`kCLLocationAccuracyNearestTenMeters`, `kCLLocationAccuracyHundredMeters`).
    public var desiredAccuracyMetres: Double {
        switch self {
        case .moving: return 10
        case .still: return 100
        }
    }

    /// `distanceFilter` in metres.
    public var distanceFilterMetres: Double {
        switch self {
        case .moving: return 10
        case .still: return 50
        }
    }
}

public struct LocationSamplingPolicy: Sendable, CustomStringConvertible, CustomDebugStringConvertible {

    /// A fix this far from the still anchor, or any speed at or above `movingSpeed`, leaves the still tier.
    public static let leaveStillDistance: Double = 50
    /// Metres per second.
    public static let movingSpeed: Double = 1
    /// A displacement this large restarts the quiet period.
    public static let displacementThreshold: Double = 25
    /// Seconds without such a displacement before the still tier.
    public static let quietPeriod: Double = 180

    public private(set) var tier: LocationSamplingTier = .moving
    private var anchorLat: Double?
    private var anchorLon: Double?
    private var anchorAt: Double = 0

    public init() {}

    public var description: String { "LocationSamplingPolicy(redacted)" }
    public var debugDescription: String { description }

    /// A fix. `at` is any monotonic time in seconds (the same clock for every call); `speed` is the speed over ground in metres per
    /// second, negative or `nil` when the platform has none. Returns the tier now in force.
    @discardableResult
    public mutating func ingest(latitude: Double, longitude: Double, speed: Double?, at time: Double) -> LocationSamplingTier {
        guard let lat = anchorLat, let lon = anchorLon else {
            anchorLat = latitude
            anchorLon = longitude
            anchorAt = time
            tier = .moving
            return tier
        }
        let distance: Double = Self.distanceMetres(lat, lon, latitude, longitude)
        let fast: Bool = (speed ?? -1) >= Self.movingSpeed
        switch tier {
        case .still:
            if distance >= Self.leaveStillDistance || fast {
                tier = .moving
                anchorLat = latitude
                anchorLon = longitude
                anchorAt = time
            }
        case .moving:
            if distance >= Self.displacementThreshold || fast {
                // Moved: the quiet period starts again from here.
                anchorLat = latitude
                anchorLon = longitude
                anchorAt = time
            } else if time - anchorAt >= Self.quietPeriod {
                tier = .still
            }
        }
        return tier
    }

    /// No fix arrived (a tunnel, indoors): time still passes, so a share that stands still reaches the still tier without needing one.
    @discardableResult
    public mutating func idle(at time: Double) -> LocationSamplingTier {
        if tier == .moving, anchorLat != nil, time - anchorAt >= Self.quietPeriod {
            tier = .still
        }
        return tier
    }

    /// The share ended or restarts: nothing of the earlier position is kept.
    public mutating func reset() {
        tier = .moving
        anchorLat = nil
        anchorLon = nil
        anchorAt = 0
    }

    /// Great-circle distance in metres between two points in degrees (haversine, WGS 84 mean radius).
    static func distanceMetres(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radius: Double = 6_371_000
        let toRadians: Double = Double.pi / 180
        let dLat: Double = (lat2 - lat1) * toRadians
        let dLon: Double = (lon2 - lon1) * toRadians
        let a: Double = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * toRadians) * cos(lat2 * toRadians) * sin(dLon / 2) * sin(dLon / 2)
        let c: Double = 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
        return radius * c
    }
}
