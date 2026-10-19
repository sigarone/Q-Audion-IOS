import Foundation

/// Decides when a change of the media path must make the speaker-change
/// detector start its reference over.
///
/// The detector measures the voice arriving now against a reference built
/// earlier in the same call. A change of path — direct to relay and back, an
/// ICE recovery — changes what the received audio sounds like (different
/// loss, different concealment, more of the far end's speech reconstructed
/// rather than transmitted), so a reference built under the old path no
/// longer describes the new one, and a detector that did not know would
/// report the network event as a person walking in.
///
/// A path report is not a path change worth acting on the moment it arrives.
/// During a real call the reports churn: a burst of direct, relay, direct,
/// relay inside a couple of seconds is ordinary while ICE re-evaluates. A
/// reference wiped on every one of them never gets the evidence it needs and
/// the detector can never fire. So a path is acted on only when it HOLDS for
/// `settleSeconds`, and only when it differs from the path the reference was
/// built under: a burst that ends where it started costs nothing.
///
/// "" is "no path reported yet". It is never a path to re-anchor for, but it
/// can be the path a reference was built under.
final class AcousticPathAnchor: @unchecked Sendable {

    /// How long a path must hold before the reference is rebuilt for it:
    /// long enough to swallow an ICE re-evaluation burst, short enough that a
    /// real move to the relay is reflected well within the time a
    /// conversation takes to matter. Same value as the Android client.
    static let settleSeconds: Double = 5

    /// Runs `work` once, after `delay` seconds. Injected so a test can fire it
    /// by hand.
    typealias Schedule = (_ delay: Double, _ work: @escaping @Sendable () -> Void) -> Void

    static let dispatchSchedule: Schedule = { delay, work in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { work() }
    }

    /// Fires, on a background queue, when a settled path differs from the one
    /// the reference was built under. Set once, before the first `observe`.
    var onReanchor: (@Sendable () -> Void)?

    private let settleSeconds: Double
    private let schedule: Schedule
    private let lock = NSLock()
    private var currentPath = ""
    private var anchoredPath = ""
    /// The contact the reference being built belongs to; nil while nothing is
    /// anchored (before the first call, and after `reset`).
    private var anchoredContact: String?
    /// Bumped by every change that invalidates a pending settle, so a
    /// scheduled check that fires late finds out it is stale.
    private var generation = 0

    init(settleSeconds: Double = AcousticPathAnchor.settleSeconds,
         schedule: @escaping Schedule = AcousticPathAnchor.dispatchSchedule) {
        self.settleSeconds = settleSeconds
        self.schedule = schedule
    }

    /// The media path in use is now `path` ("" for none).
    func observe(_ path: String) {
        lock.lock()
        let previous = currentPath
        currentPath = path
        guard path != previous, !path.isEmpty else {
            lock.unlock()
            return
        }
        generation += 1
        let token = generation
        lock.unlock()
        schedule(settleSeconds) { [weak self] in self?.settled(path: path, token: token) }
    }

    /// The reference about to be built belongs to whatever path the call is
    /// on right now. Call it when the per-contact check starts, so the first
    /// settled path of a call is not mistaken for a change.
    func anchorToCurrent() {
        lock.lock()
        anchoredPath = currentPath
        generation += 1
        lock.unlock()
    }

    /// `anchorToCurrent()` for the per-contact check starting for
    /// `contactId`, which the app starts more than once per call. It anchors
    /// only when nothing is anchored yet or `contactId` is not the contact
    /// already anchored: a repeated start for the same contact must not wipe
    /// a path change that is waiting to settle (it would move the anchor onto
    /// the new path and make the pending check stale, so the real change
    /// would never re-anchor).
    /// - Returns: whether it anchored.
    @discardableResult
    func anchorToCurrent(forContact contactId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard anchoredContact != contactId else { return false }
        anchoredContact = contactId
        anchoredPath = currentPath
        generation += 1
        return true
    }

    /// End of a call: forget both paths and the contact, and drop any pending
    /// check, so nothing from this call can re-anchor the next one.
    func reset() {
        lock.lock()
        currentPath = ""
        anchoredPath = ""
        anchoredContact = nil
        generation += 1
        lock.unlock()
    }

    private func settled(path: String, token: Int) {
        lock.lock()
        let stillCurrent = token == generation && currentPath == path
        let differs = anchoredPath != path
        if stillCurrent && differs { anchoredPath = path }
        lock.unlock()
        guard stillCurrent, differs else { return }
        onReanchor?()
    }
}
