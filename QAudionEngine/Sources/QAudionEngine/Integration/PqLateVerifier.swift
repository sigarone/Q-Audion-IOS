import Foundation

/// The late check of a second handshake signature whose key could not be resolved when its round was judged.
///
/// While the call is alive the peer key is looked up again in the background (about 1, 3, 7, 15 and 30 s after the first failure,
/// and once at once when a usable network comes back) and the SAME signature is verified against it, with the inputs the first
/// check used. The inputs are kept for the call only: they are dropped when the run ends, when the call ends and when another call
/// starts. A run is keyed by call id plus round. Nothing here touches a pin record, the screen or media: the result goes to the
/// `completion` closure, once.
final class PqLateVerifier: @unchecked Sendable {

    /// Posted when a usable network path appears (the REST client's path monitor).
    static let networkUsableNotification = Notification.Name("com.qaudion.pqlate.network-usable")
    /// Seconds after the first failure of each scheduled attempt.
    static let defaultSchedule: [Double] = [1, 3, 7, 15, 30]
    /// Upper bound of one lookup.
    static let defaultAttemptTimeoutSeconds = 4.0

    /// What the first check used, kept for the call only.
    struct Inputs: Sendable {
        let kind: UInt8
        let transcript: Data
        let signerEdPub: Data
        let dtlsFpSelf: Data
        let dtlsFpPeer: Data?
        let peer: BundleCapsBind
        let mldsaKeyIdB64: String?
        let sigHybridB64: String?
        let peerId: String
        let deviceId: String?
    }

    struct Completion: Sendable {
        let callId: String
        let round: Int
        let outcome: HybridBundleVerifier.Outcome
        /// The resolved key of a verified or failed check, nil when none was found within the run.
        let key: Pqsig.MlDsaPublicKey?
        let attempt: Int
        let ms: Int
    }

    typealias Resolver = @Sendable (_ peerId: String, _ deviceId: String?, _ signerEdPub: Data, _ keyId: Data) async -> Pqsig.MlDsaPublicKey?

    private let schedule: [Double]
    private let attemptTimeout: Double
    private let pollSeconds: Double
    /// A usable-network signal in the first moments of a run is left for the scheduled attempt (the round is still being judged).
    private let minNudgeMs: Int
    private let lock = NSLock()
    private var inputs: [String: Inputs] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generation = 0

    init(schedule: [Double] = PqLateVerifier.defaultSchedule, attemptTimeout: Double = PqLateVerifier.defaultAttemptTimeoutSeconds,
         pollSeconds: Double = 0.2, minNudgeMs: Int = 500) {
        self.minNudgeMs = minNudgeMs
        self.schedule = schedule
        self.attemptTimeout = attemptTimeout
        self.pollSeconds = pollSeconds
    }

    private static func key(_ callId: String, _ round: Int) -> String { callId.lowercased() + "#" + String(round) }

    /// Inputs held right now (a test reads it: it is zero once the call ended).
    var retainedInputsCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inputs.count
    }

    /// Runs in flight right now.
    var activeRunCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tasks.count
    }

    /// Starts the run of (call, round), replacing one that is already there. Returns at once.
    func start(callId: String, round: Int, inputs given: Inputs, resolve: @escaping Resolver,
               completion: @escaping @Sendable (Completion) -> Void) {
        let k = Self.key(callId, round)
        lock.lock()
        tasks[k]?.cancel()
        let gen = generation
        inputs[k] = given
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.run(k: k, gen: gen, callId: callId, round: round, resolve: resolve, completion: completion)
        }
        tasks[k] = task
        lock.unlock()
    }

    /// The call ended (no exception), or another call started (`exceptCall`): every run is cancelled and its inputs are dropped.
    func cancelAll(exceptCall: String? = nil) {
        let keep = exceptCall.map { $0.lowercased() + "#" }
        lock.lock()
        for (k, task) in tasks where keep == nil || !k.hasPrefix(keep!) {
            task.cancel()
            tasks[k] = nil
            inputs[k] = nil
        }
        if keep == nil {
            generation += 1
            inputs.removeAll()
        }
        lock.unlock()
    }

    private func isCurrent(_ k: String, _ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == gen && inputs[k] != nil
    }

    private func heldInputs(_ k: String) -> Inputs? {
        lock.lock()
        defer { lock.unlock() }
        return inputs[k]
    }

    private func finish(_ k: String, _ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == gen, inputs[k] != nil else { return false }
        inputs[k] = nil
        tasks[k] = nil
        return true
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.lock(); raised = true; lock.unlock() }
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; let r = raised; raised = false; return r }
    }

    private func run(k: String, gen: Int, callId: String, round: Int, resolve: @escaping Resolver,
                     completion: @escaping @Sendable (Completion) -> Void) async {
        let started = DispatchTime.now().uptimeNanoseconds
        func elapsedMs() -> Int { Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000) }
        let nudged = Flag()
        let observer = NotificationCenter.default.addObserver(
            forName: Self.networkUsableNotification, object: nil, queue: nil) { _ in nudged.raise() }
        defer { NotificationCenter.default.removeObserver(observer) }

        var attempt = 0
        // One attempt; true when the run is over (a result, or the call ended).
        func attemptOnce() async -> Bool {
            attempt += 1
            guard isCurrent(k, gen), !Task.isCancelled else { return true }
            let snapshot = heldInputs(k)
            guard let given = snapshot else { return true }
            var resolved: Pqsig.MlDsaPublicKey?
            let outcome = await HybridBundleVerifier.verify(
                kind: given.kind, transcript: given.transcript, signerEdPub: given.signerEdPub, dtlsFpSelf: given.dtlsFpSelf,
                dtlsFpPeer: given.dtlsFpPeer, peer: given.peer, mldsaKeyIdB64: given.mldsaKeyIdB64, sigHybridB64: given.sigHybridB64,
                resolveKey: { keyId in
                    let waited = await BoundedWait.run(seconds: self.attemptTimeout) {
                        await resolve(given.peerId, given.deviceId, given.signerEdPub, keyId)
                    }
                    resolved = waited.value
                    return waited.value
                })
            guard isCurrent(k, gen), !Task.isCancelled else { return true }
            let ms = elapsedMs()
            if outcome.result == .unavailable || outcome.result == .absent {
                CapsBindLog.line("PQ-LATE result=unavailable attempt=\(attempt) ms=\(ms)")
                return false
            }
            guard finish(k, gen) else { return true }
            completion(Completion(callId: callId, round: round, outcome: outcome, key: resolved, attempt: attempt, ms: ms))
            return true
        }

        for offset in schedule {
            // wait until the scheduled time; a usable network in the meantime makes one attempt at once
            while true {
                if Task.isCancelled || !isCurrent(k, gen) { return }
                if elapsedMs() >= minNudgeMs, nudged.take() {
                    if await attemptOnce() { return }
                }
                let remaining = offset - Double(elapsedMs()) / 1000
                if remaining <= 0 { break }
                try? await Task.sleep(nanoseconds: UInt64(min(remaining, pollSeconds) * 1_000_000_000))
            }
            if await attemptOnce() { return }
        }
        // out of time: still unavailable
        guard finish(k, gen) else { return }
        let ms = elapsedMs()
        let outcome = HybridBundleVerifier.Outcome(result: .unavailable, keyId: nil)
        completion(Completion(callId: callId, round: round, outcome: outcome, key: nil, attempt: attempt, ms: ms))
    }
}
