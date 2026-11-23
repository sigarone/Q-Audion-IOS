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

    /// One run: the inputs it checks (kept for the call only) and its task, under a token that only this run holds.
    private struct Run {
        let token: UUID
        let inputs: Inputs
        var task: Task<Void, Never>?
    }

    private var runs: [String: Run] = [:]
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
        return runs.count
    }

    /// Runs in flight right now.
    var activeRunCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return runs.count
    }

    /// Whether the run of (call, round) is still waiting for its key.
    func isPending(callId: String, round: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return runs[Self.key(callId, round)] != nil
    }

    /// The token of the run of (call, round), or nil (a test reads it).
    func token(callId: String, round: Int) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return runs[Self.key(callId, round)]?.token
    }

    /// Starts the run of (call, round), replacing one that is already there. Returns at once. Runs of other calls and other rounds
    /// are never touched: a run ends with its own result, or with the end of the call (`cancelAll`).
    func start(callId: String, round: Int, inputs given: Inputs, resolve: @escaping Resolver,
               completion: @escaping @Sendable (Completion) -> Void) {
        let k = Self.key(callId, round)
        let token = UUID()
        lock.lock()
        runs[k]?.task?.cancel()
        let gen = generation
        runs[k] = Run(token: token, inputs: given, task: nil)
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.run(k: k, gen: gen, token: token, callId: callId, round: round, resolve: resolve, completion: completion)
        }
        runs[k]?.task = task
        lock.unlock()
    }

    /// The call ended: every run is cancelled and its inputs are dropped.
    func cancelAll() {
        lock.lock()
        for (_, run) in runs { run.task?.cancel() }
        runs.removeAll()
        generation += 1
        lock.unlock()
    }

    private func isCurrent(_ k: String, _ gen: Int, _ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == gen && runs[k]?.token == token
    }

    private func heldInputs(_ k: String, _ token: UUID) -> Inputs? {
        lock.lock()
        defer { lock.unlock() }
        guard let run = runs[k], run.token == token else { return nil }
        return run.inputs
    }

    /// Ends the run, dropping its inputs, only if the entry still belongs to THIS run (`token`).
    func finish(_ k: String, _ gen: Int, _ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == gen, let run = runs[k], run.token == token else { return false }
        runs[k] = nil
        return true
    }

    /// `finish` for a test: the key of (call, round) with a given token.
    func finish(callId: String, round: Int, token: UUID) -> Bool {
        lock.lock()
        let gen = generation
        lock.unlock()
        return finish(Self.key(callId, round), gen, token)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.lock(); raised = true; lock.unlock() }
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; let r = raised; raised = false; return r }
    }

    private func run(k: String, gen: Int, token: UUID, callId: String, round: Int, resolve: @escaping Resolver,
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
            guard isCurrent(k, gen, token), !Task.isCancelled else { return true }
            let snapshot = heldInputs(k, token)
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
            guard isCurrent(k, gen, token), !Task.isCancelled else { return true }
            let ms = elapsedMs()
            if outcome.result == .unavailable || outcome.result == .absent {
                CapsBindLog.line("PQ-LATE result=unavailable attempt=\(attempt) ms=\(ms)")
                return false
            }
            guard finish(k, gen, token) else { return true }
            completion(Completion(callId: callId, round: round, outcome: outcome, key: resolved, attempt: attempt, ms: ms))
            return true
        }

        for offset in schedule {
            // wait until the scheduled time; a usable network in the meantime makes one attempt at once
            while true {
                if Task.isCancelled || !isCurrent(k, gen, token) { return }
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
        guard finish(k, gen, token) else { return }
        let ms = elapsedMs()
        let outcome = HybridBundleVerifier.Outcome(result: .unavailable, keyId: nil)
        completion(Completion(callId: callId, round: round, outcome: outcome, key: nil, attempt: attempt, ms: ms))
    }
}

/// What the call screen's grey note does with the end of a late check: only a result that concerns round 1 sets or clears it.
public enum PqLateNote {
    /// The call the note is up for after (callId, result, round) came in; `current` is the call it is up for now.
    public static func next(current: String?, callId: String, result: String, round: Int) -> String? {
        guard round <= 1 else { return current }
        return result == "unavailable" ? callId.lowercased() : nil
    }
}
