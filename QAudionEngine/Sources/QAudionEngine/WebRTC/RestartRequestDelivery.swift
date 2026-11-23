import Foundation

/// Delivery of a `restart_ice_request` by the answering side (flag `calls.ice_fastswitch`).
///
/// A frame written to a socket that is closing, or not yet authenticated, can be lost without any error
/// reaching the writer. So a request counts as delivered only when the socket generation it was written on is
/// still the live authenticated one `confirmAfterSec` later, or when the peer's restart offer arrives. Otherwise
/// it is written again on the next authenticated socket, within `budgetSec` and `maxWrites`.
///
/// `RestartRequestPlan` holds the decisions and no clock or socket, so the bounds can be tested with plain numbers.
public struct RestartRequestPlan: Equatable {
    public static let confirmAfterSec: TimeInterval = 1.5
    public static let budgetSec: TimeInterval = 30
    public static let maxWrites: Int = 12

    public enum ResendReason: String, Equatable {
        /// The live socket is a different generation from the one written, with no gap seen in between.
        case wsgen
        /// The written socket was seen gone first (reconnect).
        case reconnect
    }

    public enum Step: Equatable {
        case write(resend: ResendReason?)
        case wait
        case delivered
        case giveUp
    }

    public let startedAt: TimeInterval
    public private(set) var writes: Int = 0
    private var writtenGeneration: Int?
    private var writtenAt: TimeInterval = 0
    private var sawGap = false

    public init(startedAt: TimeInterval) { self.startedAt = startedAt }

    /// - Parameter liveGeneration: generation of the authenticated, fresh socket right now, nil when there is none.
    public mutating func step(now: TimeInterval, liveGeneration: Int?) -> Step {
        if let written = writtenGeneration {
            if liveGeneration == written {
                if now - writtenAt >= Self.confirmAfterSec { return .delivered }
            } else if liveGeneration == nil {
                sawGap = true
            }
        }
        if now - startedAt >= Self.budgetSec { return .giveUp }
        guard let live = liveGeneration else { return .wait }
        if let written = writtenGeneration {
            if live == written { return .wait }
            if writes >= Self.maxWrites { return .giveUp }
            return .write(resend: sawGap ? .reconnect : .wsgen)
        }
        return .write(resend: nil)
    }

    /// Record the outcome of the write the last `.write` step asked for. `generation` nil: the socket refused it.
    public mutating func recordWrite(now: TimeInterval, generation: Int?) {
        guard let generation else { return }
        writes += 1
        writtenGeneration = generation
        writtenAt = now
        sawGap = false
    }
}

public final class RestartRequestDelivery: @unchecked Sendable {

    public struct Environment: Sendable {
        /// Writes the request on the authenticated socket; returns that socket's generation, nil when refused.
        public var write: @Sendable () -> Int?
        /// Generation of the authenticated, fresh socket, nil when there is none.
        public var liveGeneration: @Sendable () -> Int?
        /// Waits (bounded) for an authenticated socket, kicking a reconnect if needed.
        public var ensureReady: @Sendable (TimeInterval) async -> Bool
        public var now: @Sendable () -> TimeInterval
        public var sleep: @Sendable (TimeInterval) async -> Void
        public var log: @Sendable (String) -> Void

        public init(write: @escaping @Sendable () -> Int?,
                    liveGeneration: @escaping @Sendable () -> Int?,
                    ensureReady: @escaping @Sendable (TimeInterval) async -> Bool,
                    now: @escaping @Sendable () -> TimeInterval,
                    sleep: @escaping @Sendable (TimeInterval) async -> Void,
                    log: @escaping @Sendable (String) -> Void) {
            self.write = write
            self.liveGeneration = liveGeneration
            self.ensureReady = ensureReady
            self.now = now
            self.sleep = sleep
            self.log = log
        }
    }

    public static let firstReadyTimeoutSec: TimeInterval = 5
    public static let pollSec: TimeInterval = 0.25
    private static let gapReadyTimeoutSec: TimeInterval = 2

    private let env: Environment
    private let lock = NSLock()
    private var epoch = 0
    private var task: Task<Void, Never>?
    private var active = false
    /// A `start()` is between its entry and the spawn of its runner: a trigger that must not be lost.
    private var startsInFlight = 0

    public init(environment: Environment) { self.env = environment }

    /// Start (or restart) a delivery. Returns whether the first write was accepted by an authenticated socket;
    /// confirmation and re-sends continue in the background until delivered, given up, or cancelled.
    @discardableResult
    public func start() async -> Bool {
        let myEpoch: Int = lock.withLock {
            startsInFlight += 1
            epoch += 1
            task?.cancel()
            task = nil
            active = true
            return epoch
        }
        var plan = RestartRequestPlan(startedAt: env.now())
        _ = await env.ensureReady(Self.firstReadyTimeoutSec)
        var firstAccepted = false
        if isCurrent(myEpoch),
           case .write = plan.step(now: env.now(), liveGeneration: env.liveGeneration()) {
            let t = env.now()
            let gen = env.write()
            plan.recordWrite(now: t, generation: gen)
            firstAccepted = gen != nil
        }
        let initial = plan
        let newTask = Task { [weak self] in
            await self?.run(plan: initial, epoch: myEpoch)
        }
        lock.withLock {
            startsInFlight -= 1
            if epoch == myEpoch { task = newTask } else { newTask.cancel() }
        }
        return firstAccepted
    }

    /// The peer's restart offer arrived: the request did its job.
    /// A `start()` still in progress is a newer trigger than the offer that arrived: it keeps running.
    public func peerOfferArrived() {
        let wasActive: Bool = lock.withLock {
            if startsInFlight > 0 { return false }
            let a = active
            epoch += 1
            task?.cancel()
            task = nil
            active = false
            return a
        }
        if wasActive { env.log("restart_ice fast=1 role=responder delivered=1") }
    }

    /// Teardown: stop quietly.
    public func cancel() {
        lock.withLock {
            epoch += 1
            task?.cancel()
            task = nil
            active = false
        }
    }

    private func isCurrent(_ e: Int) -> Bool { lock.withLock { epoch == e } }

    private func finish(epoch e: Int) {
        lock.withLock {
            if epoch == e { active = false; task = nil }
        }
    }

    private func run(plan initial: RestartRequestPlan, epoch e: Int) async {
        var plan = initial
        while !Task.isCancelled && isCurrent(e) {
            let now = env.now()
            switch plan.step(now: now, liveGeneration: env.liveGeneration()) {
            case .delivered:
                guard isCurrent(e) else { return }
                env.log("restart_ice fast=1 role=responder n=\(plan.writes) delivered=1")
                finish(epoch: e)
                return
            case .giveUp:
                guard isCurrent(e) else { return }
                env.log("restart_ice fast=1 role=responder n=\(plan.writes) giveup=1")
                finish(epoch: e)
                return
            case .write(let resend):
                let gen = env.write()
                plan.recordWrite(now: env.now(), generation: gen)
                if gen != nil, let resend {
                    env.log("restart_ice fast=1 role=responder n=\(plan.writes) resend=1 reason=\(resend.rawValue)")
                }
                if gen == nil { await env.sleep(Self.pollSec) }
            case .wait:
                if env.liveGeneration() == nil {
                    _ = await env.ensureReady(Self.gapReadyTimeoutSec)
                }
                await env.sleep(Self.pollSec)
            }
        }
    }
}
