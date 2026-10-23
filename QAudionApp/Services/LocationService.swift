import Foundation
import CoreLocation
import QAudionEngine

/// A position as the system gives it, before any conversion. It prints a fixed placeholder wherever it is described, so that a stray
/// interpolation or assertion message can never put a coordinate in a log (WIRE_SPEC 14.10).
struct LocationReading: CustomStringConvertible, CustomDebugStringConvertible {
    let latitude: Double
    let longitude: Double
    /// `horizontalAccuracy`: the radius in metres, negative when the fix is not valid.
    let horizontalAccuracy: Double
    let timestamp: Date
    /// Metres per second over ground, negative when the system has none.
    let speed: Double
    /// `accuracyAuthorization == .reducedAccuracy` at the time of the fix.
    let reducedAccuracy: Bool

    var description: String { "LocationReading(redacted)" }
    var debugDescription: String { description }

    /// The fix for the engine's builder: its age is taken against the system clock now (BUILD_MAX_FIX_AGE is judged there).
    func engineFix(now: Date = Date()) -> LocationFix {
        let elapsed: Double = max(0, now.timeIntervalSince(timestamp))
        let elapsedMs: Int64 = Int64(min(elapsed * 1000, 4_000_000_000))
        return LocationFix(latitude: latitude, longitude: longitude, horizontalAccuracy: horizontalAccuracy,
                           elapsedMs: elapsedMs, approximate: reducedAccuracy)
    }
}

enum LocationServiceError: Error {
    /// The user did not allow location, or location services are off.
    case denied
    /// The system could not give a position now.
    case unavailable
    /// No position arrived in time.
    case timeout
}

/// The one place the app talks to `CLLocationManager` (docs/LOCATION_SHARING.md 1.1, 1.8): When In Use only, never Always.
///
/// - A one-shot position for a pin (`requestOneShot`): the system `LocationButton` grants a one-time authorisation without a prompt,
///   and the request then runs under it.
/// - Continuous sampling for a live share (`beginLiveSampling`): updates start in the foreground, the background session is enabled only
///   while a share is live (`UIBackgroundModes` `location`, the blue indicator of the system stays visible), the automatic pause is off
///   (it cannot be resumed from the background under When In Use), and the accuracy and the distance filter follow the adaptive tiers of
///   `LocationSamplingPolicy`.
///
/// Created and used on the main thread (the manager delivers its callbacks on the thread that made it). It keeps the newest fix of the
/// running share in memory only, and `endLiveSampling` forgets it. Nothing here logs, prints or describes a position.
final class LocationService: NSObject, CLLocationManagerDelegate, @unchecked Sendable {

    /// Created on first use and not before: a build with the remote switch off, or a run in which no share was ever started, never makes
    /// a `CLLocationManager` (the code that only has to END sampling asks `hasInstance` first).
    static var shared: LocationService {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        if let existing = storedInstance { return existing }
        let made = LocationService()
        storedInstance = made
        return made
    }

    /// Whether the service (and so its location manager) was ever created in this process.
    static var hasInstance: Bool {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        return storedInstance != nil
    }

    private static let instanceLock = NSLock()
    private static var storedInstance: LocationService?

    /// Test seam (internal, set only by `QAudionAppTests`): forgets the instance so that a test can check that a code path never makes
    /// one. Production code never calls it.
    static func discardInstanceForTests() {
        instanceLock.lock()
        let old = storedInstance
        storedInstance = nil
        instanceLock.unlock()
        old?.endLiveSampling()
    }

    /// The purpose key of `NSLocationTemporaryUsageDescriptionDictionary` for the one-off request of full accuracy.
    static let fullAccuracyPurposeKey = "LocationFullAccuracyPurpose"

    private let manager: CLLocationManager
    private var policy = LocationSamplingPolicy()
    private var liveActive: Bool = false
    private var oneShotWaiters: [(id: Int, continuation: CheckedContinuation<Result<LocationReading, LocationServiceError>, Never>)] = []
    private var nextWaiterId: Int = 0
    private(set) var newestLiveFix: LocationReading?

    /// Called on the main thread for every fix of a running live share.
    var onLiveFix: ((LocationReading) -> Void)?
    /// Called on the main thread when the authorisation (or the accuracy authorisation) changes.
    var onAuthorizationChange: (() -> Void)?

    private override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
    }

    // MARK: Authorisation

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    /// Whether the app may read the position now (When In Use or Always).
    var isAuthorized: Bool {
        let status: CLAuthorizationStatus = manager.authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    var isDenied: Bool {
        let status: CLAuthorizationStatus = manager.authorizationStatus
        return status == .denied || status == .restricted
    }

    var isNotDetermined: Bool {
        manager.authorizationStatus == .notDetermined
    }

    var isReducedAccuracy: Bool {
        manager.accuracyAuthorization == .reducedAccuracy
    }

    /// A short enum label for telemetry: never a coordinate.
    var authorizationLabel: String {
        switch manager.authorizationStatus {
        case .notDetermined: return "undetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "when_in_use"
        @unknown default: return "unknown"
        }
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    /// The system asks, once, for full accuracy for this use only (a reduced-accuracy grant stays reduced for everything else).
    func requestTemporaryFullAccuracy() {
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.fullAccuracyPurposeKey)
    }

    // MARK: One-shot position

    /// A position for a pin. Uses the fix the manager already holds when it is a few seconds old (a live share, or a screen that was
    /// already following), otherwise asks for one. `timeout` seconds without a fix is `.timeout`.
    func requestOneShot(timeout: TimeInterval = 15) async -> Result<LocationReading, LocationServiceError> {
        if !isAuthorized {
            return .failure(isDenied ? .denied : .unavailable)
        }
        if let held = freshHeldReading(maxAge: 8) {
            return .success(held)
        }
        let waiterId: Int = nextWaiterId
        nextWaiterId += 1
        let result: Result<LocationReading, LocationServiceError> = await withCheckedContinuation { continuation in
            self.oneShotWaiters.append((id: waiterId, continuation: continuation))
            if !self.liveActive {
                self.manager.desiredAccuracy = kCLLocationAccuracyBest
                self.manager.requestLocation()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolveWaiter(id: waiterId, with: .failure(.timeout))
            }
        }
        return result
    }

    private func freshHeldReading(maxAge: TimeInterval) -> LocationReading? {
        if let live = newestLiveFix, Date().timeIntervalSince(live.timestamp) <= maxAge, live.horizontalAccuracy >= 0 {
            return live
        }
        guard let location = manager.location, location.horizontalAccuracy >= 0,
              Date().timeIntervalSince(location.timestamp) <= maxAge else { return nil }
        return reading(from: location)
    }

    private func resolveWaiter(id: Int, with result: Result<LocationReading, LocationServiceError>) {
        guard let index = oneShotWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = oneShotWaiters.remove(at: index)
        waiter.continuation.resume(returning: result)
    }

    private func resolveAllWaiters(with result: Result<LocationReading, LocationServiceError>) {
        let waiters = oneShotWaiters
        oneShotWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: result)
        }
    }

    // MARK: Live sampling

    /// Starts continuous updates for a live share. Call it from a visible conversation (the system refuses to start a session from the
    /// background under When In Use). Idempotent.
    func beginLiveSampling() {
        guard isAuthorized else { return }
        if liveActive { return }
        liveActive = true
        policy.reset()
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        applyTier(.moving)
        manager.startUpdatingLocation()
    }

    /// Stops the updates and the background session, and forgets the fix and the sampling state.
    func endLiveSampling() {
        guard liveActive else { return }
        liveActive = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        policy.reset()
        newestLiveFix = nil
    }

    var isSamplingLive: Bool { liveActive }

    /// Time passes without a fix: a share that stands still reaches the still tier without needing one.
    func noteClockTick() {
        guard liveActive else { return }
        let before: LocationSamplingTier = policy.tier
        let after: LocationSamplingTier = policy.idle(at: ProcessInfo.processInfo.systemUptime)
        if after != before { applyTier(after) }
    }

    private func applyTier(_ tier: LocationSamplingTier) {
        switch tier {
        case .moving:
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        case .still:
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        }
        manager.distanceFilter = tier.distanceFilterMetres
    }

    private func reading(from location: CLLocation) -> LocationReading {
        LocationReading(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                        horizontalAccuracy: location.horizontalAccuracy, timestamp: location.timestamp,
                        speed: location.speed, reducedAccuracy: manager.accuracyAuthorization == .reducedAccuracy)
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations where location.horizontalAccuracy >= 0 {
            let item: LocationReading = reading(from: location)
            if liveActive {
                newestLiveFix = item
                let before: LocationSamplingTier = policy.tier
                let speed: Double? = item.speed >= 0 ? item.speed : nil
                let after: LocationSamplingTier = policy.ingest(
                    latitude: item.latitude, longitude: item.longitude, speed: speed,
                    at: ProcessInfo.processInfo.systemUptime)
                if after != before { applyTier(after) }
                onLiveFix?(item)
            }
            if !oneShotWaiters.isEmpty {
                resolveAllWaiters(with: .success(item))
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code: Int = (error as NSError).code
        if code == CLError.locationUnknown.rawValue {
            // Transient: the system keeps trying.
            return
        }
        if !oneShotWaiters.isEmpty {
            let denied: Bool = code == CLError.denied.rawValue
            resolveAllWaiters(with: .failure(denied ? .denied : .unavailable))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if !isAuthorized && !oneShotWaiters.isEmpty {
            resolveAllWaiters(with: .failure(isDenied ? .denied : .unavailable))
        }
        onAuthorizationChange?()
    }
}
