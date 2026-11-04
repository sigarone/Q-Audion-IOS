import Combine
import Foundation

/// State of the waiting screen shown after a sign-in answered "approval required".
///
/// The model polls the server every `interval` seconds (the server allows one poll per 3 s) until the
/// entry ends. Rules, each pinned by `LoginWaitModelTests`:
///  - polling stops at the first final answer: approved, denied, expired or session revoked (401: the account's
///    sessions were revoked after the approval, so the pair is not handed out and the person must sign in
///    again). An approval keeps the session pair in `approved` until `takeApproved()` hands it over (once);
///  - a 429 stretches the next wait to the server's `Retry-After`, never below `interval`;
///  - a network or server failure keeps polling; after three in a row `connectionProblem` is raised, the
///    next good answer clears it;
///  - when the local clock is more than `expiryGrace` past the expiry and the server still says pending,
///    the entry is shown as expired (the clock never ends an entry earlier than the server's own answer);
///  - recovery by code: asking for a code is allowed while waiting; verifying needs a code that was asked;
///    a wrong code keeps the step, too many tries sends the person back to ask for a new code; success
///    polls at once, the approval then arrives with the next answer;
///  - nothing is logged or kept besides the ticket: no token, code or address.
@MainActor
public final class LoginWaitModel: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case waiting
        case approved
        case denied
        case expired
        /// The approval cannot be redeemed because the sessions of the account were revoked in between.
        case sessionRevoked
    }

    public enum RecoveryStep: Equatable, Sendable {
        case idle
        case requesting(RecoveryChannel)
        case codeSent(RecoveryChannel)
        case verifying(RecoveryChannel)
    }

    public enum RecoveryProblem: Equatable, Sendable {
        case invalidCode
        case tooManyAttempts
        /// The code expired or is gone while the entry may still be pending: ask for a new one.
        case codeExpired
        case rateLimited
        case unavailable
        case failed
    }

    public let ticket: PendingLoginTicket
    @Published public private(set) var phase: Phase = .waiting
    @Published public private(set) var recovery: RecoveryStep = .idle
    @Published public private(set) var recoveryProblem: RecoveryProblem?
    @Published public private(set) var connectionProblem = false

    private let api: PendingLoginApi
    private let interval: TimeInterval
    private let expiryGrace: TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let now: @Sendable () -> Date
    private var loop: Task<Void, Never>?
    private var polling = false
    private var failures = 0
    private var nextDelay: TimeInterval
    private var approvedLogin: ApprovedLogin?

    public init(
        ticket: PendingLoginTicket,
        api: PendingLoginApi,
        interval: TimeInterval = 3,
        expiryGrace: TimeInterval = 20,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ticket = ticket
        self.api = api
        self.interval = interval
        self.expiryGrace = expiryGrace
        self.sleep = sleep
        self.now = now
        self.nextDelay = interval
    }

    /// Whole seconds until the expiry the server announced, never below 0.
    public func remainingSeconds(at date: Date) -> Int {
        max(0, Int(ticket.expiresAt.timeIntervalSince(date).rounded(.up)))
    }

    /// Starts the polling loop (once).
    public func start() {
        guard loop == nil, phase == .waiting else { return }
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    /// Stops polling (the screen went away). The model can be started again while it is still `.waiting`.
    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// The session of an approved entry, once.
    public func takeApproved() -> ApprovedLogin? {
        defer { approvedLogin = nil }
        return approvedLogin
    }

    private func run() async {
        while !Task.isCancelled, phase == .waiting {
            await pollOnce()
            guard !Task.isCancelled, phase == .waiting else { break }
            let delay = nextDelay
            nextDelay = interval
            await sleep(delay)
        }
        // A cancelled loop was already dropped by stop(); only an ended entry clears it here.
        if phase != .waiting { loop = nil }
    }

    /// One poll. Public so a test (or the screen's pull-to-check) can drive it without the loop.
    public func pollOnce() async {
        guard phase == .waiting, !polling else { return }
        polling = true
        defer { polling = false }
        let result: PendingLoginPoll
        do {
            result = try await api.poll(pendingId: ticket.pendingId, pollToken: ticket.pollToken)
        } catch {
            guard !Task.isCancelled else { return }
            failures += 1
            if failures >= 3 { connectionProblem = true }
            expireIfLate()
            return
        }
        guard !Task.isCancelled, phase == .waiting else { return }
        failures = 0
        connectionProblem = false
        switch result {
        case .pending:
            expireIfLate()
        case .approved(let login):
            approvedLogin = login
            phase = .approved
        case .denied:
            phase = .denied
        case .expired:
            phase = .expired
        case .sessionRevoked:
            phase = .sessionRevoked
        case .tooFast(let retryAfter):
            nextDelay = max(retryAfter, interval)
        }
    }

    private func expireIfLate() {
        if now().timeIntervalSince(ticket.expiresAt) > expiryGrace { phase = .expired }
    }

    /// Asks for a 6-digit code on the verified contact of `channel`.
    public func requestCode(_ channel: RecoveryChannel) async {
        guard phase == .waiting else { return }
        switch recovery {
        case .requesting, .verifying: return
        case .idle, .codeSent: break
        }
        recoveryProblem = nil
        recovery = .requesting(channel)
        do {
            try await api.requestRecoveryCode(pendingId: ticket.pendingId, pollToken: ticket.pollToken, channel: channel)
            guard phase == .waiting else { return }
            recovery = .codeSent(channel)
        } catch {
            guard phase == .waiting else { return }
            recovery = .idle
            recoveryProblem = Self.problem(for: error)
            applyFinal(error)
        }
    }

    /// Sends the code the person typed. A code that is not six digits is refused without a request.
    public func verify(code rawCode: String) async {
        guard phase == .waiting, case .codeSent(let channel) = recovery else { return }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            recoveryProblem = .invalidCode
            return
        }
        recoveryProblem = nil
        recovery = .verifying(channel)
        do {
            try await api.verifyRecoveryCode(pendingId: ticket.pendingId, pollToken: ticket.pollToken, code: code)
            guard phase == .waiting else { return }
            recovery = .codeSent(channel)
            await pollOnce()
        } catch {
            guard phase == .waiting else { return }
            let problem = Self.problem(for: error)
            recoveryProblem = problem
            recovery = (problem == .tooManyAttempts || problem == .codeExpired || problem == .unavailable)
                ? .idle : .codeSent(channel)
            applyFinal(error)
        }
    }

    private func applyFinal(_ error: Error) {
        switch error as? PendingLoginRecoveryError {
        case .denied: phase = .denied
        case .expired: phase = .expired
        default: break
        }
    }

    static func problem(for error: Error) -> RecoveryProblem {
        switch error as? PendingLoginRecoveryError {
        case .invalidCode: return .invalidCode
        case .tooManyAttempts: return .tooManyAttempts
        case .codeExpired: return .codeExpired
        case .rateLimited: return .rateLimited
        case .channelUnavailable: return .unavailable
        default: return .failed
        }
    }
}
