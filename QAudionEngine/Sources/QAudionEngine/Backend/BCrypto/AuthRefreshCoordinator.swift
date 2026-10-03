import Foundation

// MARK: - Session recovery: one coordinator per process
//
// 2026-10-02 incident (iPhone, iOS 1.0.1201, signed out 14:37:38-16:53:13 UTC).
//
// Every REST call answered 401 for 2h16m, the socket never authenticated, and the
// server logged 37 `/auth/refresh` rejections for the SAME refresh-token hash. That
// token was dead (neither live nor a tombstone) because, earlier that morning, two
// `/auth/refresh` calls carrying the same token had been in flight 49 ms apart: the
// proactive refresh in the app layer called `accountApi.refreshToken` directly, outside
// the REST client's single-flight, while a 401 cascade from another provider did the
// same. The server rotated once, forgave the second and collapsed the coexisting live
// tokens; the loser's token was deleted, and the loser was the one the client wrote to
// the Keychain last.
//
// Two defects are fixed here, in the one place every refresh now goes through:
//
//   1. Single flight PER PROCESS, not per `BCryptoRestClient` (the app builds ~20 of
//      them, each had its own `refreshInFlight`) and not per entry point (proactive
//      timer, REST 401, socket `auth_failed`, external tus client). Callers that present
//      the same refresh token await one network call.
//   2. Compare-and-swap persistence. The refresh token is read from the shared credential
//      store (the Keychain in the app), not from whatever copy a long-lived provider
//      holds, and a result is written back only if the store still holds the token that
//      was sent. A result that lost the race is discarded: an older pair never overwrites
//      a newer one.
//
// The coordinator is Foundation-only on purpose: it holds no secrets in logs, has no
// dependency on the transport, and is exercised by plain unit tests.

// MARK: - Value types

public enum AuthLogLevel: String, Sendable {
    case debug, info, warn, error
}

/// Tokens returned by `/auth/refresh` or `/auth/device-renew`, or adopted from the store.
public struct AuthTokenSet: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresInSec: Int?

    public init(accessToken: String, refreshToken: String?, expiresInSec: Int?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresInSec = expiresInSec
    }

    public var description: String {
        let ttl: String = expiresInSec.map { String($0) } ?? "nil"
        return "AuthTokenSet(accessToken: <redacted>, refreshToken: <redacted>, expiresInSec: \(ttl))"
    }
    public var debugDescription: String { description }
}

/// What the shared credential store currently holds.
public struct AuthStoredCredentials: Sendable, Equatable {
    public let access: String?
    public let refresh: String?
    public init(access: String?, refresh: String?) {
        self.access = access
        self.refresh = refresh
    }
}

public enum AuthCredentialStoreError: Error, Sendable, Equatable {
    /// The store could not be read (for the Keychain: locked, interaction not allowed,
    /// any status other than "item not found"). Distinct from "nothing stored".
    case unreadable(status: Int32)
}

/// The app's shared credential store (Keychain). Implemented by the app layer.
public protocol AuthCredentialStore: Sendable {
    /// Current pair. An absent item reads as `nil`; an unreadable store throws.
    func load() throws -> AuthStoredCredentials
    /// Persist `tokens` only if the stored refresh token still equals `expectedRefresh`
    /// (both compared with `AuthRefreshCoordinator.sameRefreshToken`). Returns `false`,
    /// writing nothing, when the store holds something else. A `nil`/empty
    /// `tokens.refreshToken` leaves the stored refresh token untouched.
    func compareAndSwap(expectedRefresh: String?, with tokens: AuthTokenSet) throws -> Bool
}

/// Short, grep-friendly reason codes. These are the only vocabulary the log lines use.
public enum AuthRecoveryReason: String, Sendable, Equatable {
    case noRecoveryPath = "no_recovery_path"
    case cooldown = "cooldown"
    case storeUnreadable = "keychain_unreadable"
    case casLost = "cas_lost"

    case refreshRejected = "refresh_rejected"
    case refreshNetwork = "refresh_network"
    case refreshServerError = "refresh_server_error"
    case refreshOther = "refresh_error"

    case renewNoDeviceId = "renew_no_device_id"
    case renewKeyNotProvisioned = "renew_key_not_provisioned"
    case renewKeychainLocked = "renew_keychain_locked"
    case renewKeychainError = "renew_keychain_error"
    case renewNetwork = "renew_network"
    case renewRejected = "renew_rejected"
    case renewServerError = "renew_server_error"
    case renewMalformedChallenge = "renew_malformed_challenge"
    case renewOther = "renew_error"
}

public struct AuthRecoveryFailure: Error, Sendable, Equatable {
    public let reason: AuthRecoveryReason
    /// HTTP status when the failure was a server answer, nil otherwise.
    public let status: Int?
    /// True only when waiting cannot help: the server revoked the device, or the device
    /// has no credential to renew with. Everything else is transient and is retried.
    public let isFinal: Bool
    /// Set by the coordinator: how long until another attempt makes sense.
    public var retryAfterSec: Int
    /// For `.cooldown`: the reason of the failure that started the cooldown.
    public var underlyingReason: AuthRecoveryReason?

    public init(reason: AuthRecoveryReason,
                status: Int? = nil,
                isFinal: Bool = false,
                retryAfterSec: Int = 0,
                underlyingReason: AuthRecoveryReason? = nil) {
        self.reason = reason
        self.status = status
        self.isFinal = isFinal
        self.retryAfterSec = retryAfterSec
        self.underlyingReason = underlyingReason
    }

    /// `reason=... status=N final=0|1` (numeric tails, no secrets).
    public var logFields: String {
        var s = "reason=\(reason.rawValue) status=\(status ?? 0) final=\(isFinal ? 1 : 0)"
        if let u = underlyingReason { s += " last=\(u.rawValue)" }
        return s
    }
}

public enum AuthRecoveryPath: String, Sendable, Equatable {
    case refresh = "refresh"
    case deviceRenew = "device_renew"
}

public enum AuthRefreshOutcome: Sendable, Equatable {
    /// A network call produced these tokens and they are persisted.
    case refreshed(AuthTokenSet, via: AuthRecoveryPath)
    /// No network call: another path had already rotated the pair, this is what the store holds.
    case adopted(AuthTokenSet)
    case failed(AuthRecoveryFailure)

    public var tokens: AuthTokenSet? {
        switch self {
        case .refreshed(let t, _): return t
        case .adopted(let t): return t
        case .failed: return nil
        }
    }
    public var isSuccess: Bool { tokens != nil }
    public var failure: AuthRecoveryFailure? {
        if case .failed(let f) = self { return f }
        return nil
    }
}

/// What the socket does with the outcome of its `auth_failed` recovery.
public enum AuthRecoveryVerdict: Sendable, Equatable {
    case recovered
    /// Waiting cannot help (device revoked / nothing to renew with): park the reconnect loop.
    case revoked
    /// Could not recover right now: keep the reconnect loop alive and try again later.
    case transient(retryAfterSec: Int)
}

public enum AuthRefreshTrigger: String, Sendable {
    case rest401 = "rest_401"
    case wsAuthFailed = "ws_auth_failed"
    case proactive = "proactive"
    case external = "external"

    /// A trigger that reacts to a 401 on a specific access token may adopt a newer one from
    /// the store instead of calling the network. The proactive refresh has no failed token.
    var adoptsNewerStoredAccess: Bool { self != .proactive }
}

/// Raised by the app's renew closure when it cannot even start (no device id stored).
public enum AuthRenewPreconditionError: Error, Sendable, Equatable {
    case noDeviceId
}

public struct AuthRefreshRequest: Sendable {
    public typealias Refresher = @Sendable (_ refreshToken: String) async throws -> AuthTokenSet
    public typealias Renewer = @Sendable () async throws -> AuthTokenSet

    public let trigger: AuthRefreshTrigger
    /// The access token that was just rejected (nil for the proactive refresh).
    public let staleAccessToken: String?
    /// The refresh token the caller's own copy holds. Used only when `store` is nil or empty.
    public let callerRefreshToken: String?
    public let store: AuthCredentialStore?
    public let refresher: Refresher?
    public let renewer: Renewer?
    /// The proactive / foreground refresh must not wait out a cooldown.
    public let ignoreCooldown: Bool

    public init(trigger: AuthRefreshTrigger,
                staleAccessToken: String?,
                callerRefreshToken: String?,
                store: AuthCredentialStore?,
                refresher: Refresher?,
                renewer: Renewer?,
                ignoreCooldown: Bool = false) {
        self.trigger = trigger
        self.staleAccessToken = staleAccessToken
        self.callerRefreshToken = callerRefreshToken
        self.store = store
        self.refresher = refresher
        self.renewer = renewer
        self.ignoreCooldown = ignoreCooldown
    }
}

// MARK: - Coordinator

public final class AuthRefreshCoordinator: @unchecked Sendable {

    public static let shared = AuthRefreshCoordinator()

    public typealias Logger = @Sendable (_ level: AuthLogLevel, _ message: String) -> Void

    /// Cooldown after consecutive failed flights of a store-backed session: 5, 15, 45, then
    /// 120 s. REST/socket callers fail fast inside it; the proactive refresh ignores it.
    public static func backoffSeconds(forFailures n: Int) -> Int {
        let ladder = [5, 15, 45, 120]
        return ladder[max(0, min(n - 1, ladder.count - 1))]
    }

    /// Equality for refresh tokens where nil and "" both mean "none".
    public static func sameRefreshToken(_ a: String?, _ b: String?) -> Bool {
        let x = (a?.isEmpty ?? true) ? nil : a
        let y = (b?.isEmpty ?? true) ? nil : b
        return x == y
    }

    private let lock = NSLock()
    private var inFlight: [String: Task<AuthRefreshOutcome, Never>] = [:]
    private var consecutiveFailures = 0
    private var cooldownUntil: Date?
    private var lastFailure: AuthRecoveryFailure?
    private var cooldownHits = 0
    private var logger: Logger?
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Install the log sink (the app routes it to `RTLog`).
    public func setLogger(_ logger: Logger?) {
        lock.withLock { self.logger = logger }
    }

    /// Drop the failure/cooldown state (login, logout, tests).
    public func resetBackoff() {
        lock.withLock {
            consecutiveFailures = 0
            cooldownUntil = nil
            lastFailure = nil
            cooldownHits = 0
        }
    }

    private func emit(_ level: AuthLogLevel, _ message: String) {
        let sink = lock.withLock { logger }
        sink?(level, message)
    }

    private enum Step {
        case join(Task<AuthRefreshOutcome, Never>)
        case start(Task<AuthRefreshOutcome, Never>)
        case cooling(AuthRecoveryFailure, hit: Int)
    }

    /// Run (or join) the one refresh for this session. Never throws: every outcome is a value.
    public func refresh(_ request: AuthRefreshRequest) async -> AuthRefreshOutcome {
        let trigger = request.trigger.rawValue

        // 1. The store, not the caller's copy, is the source of truth.
        var stored: AuthStoredCredentials?
        if let store = request.store {
            do {
                stored = try store.load()
            } catch {
                var f = AuthRecoveryFailure(reason: .storeUnreadable)
                f.retryAfterSec = Self.backoffSeconds(forFailures: 1)
                emit(.warn, "refresh skipped trigger=\(trigger) \(f.logFields)")
                return .failed(f)
            }
        }

        // 2. Another path already rotated the pair: use it, spend no refresh token.
        if request.trigger.adoptsNewerStoredAccess,
           let stale = request.staleAccessToken, !stale.isEmpty,
           let s = stored, let access = s.access, !access.isEmpty, access != stale {
            emit(.info, "refresh adopted trigger=\(trigger) newer_stored=1")
            return .adopted(AuthTokenSet(accessToken: access, refreshToken: s.refresh, expiresInSec: nil))
        }

        let storedRefresh = Self.nonEmpty(stored?.refresh)
        let sendToken = storedRefresh ?? Self.nonEmpty(request.callerRefreshToken)
        let key = (request.store != nil ? "s:" : "c:") + (sendToken ?? "-")

        // 3. Join the flight for this token, or start it.
        let step: Step = lock.withLock {
            if let existing = inFlight[key] { return .join(existing) }
            if !request.ignoreCooldown, request.store != nil,
               let until = cooldownUntil, now() < until {
                let remaining = max(1, Int(until.timeIntervalSince(now()).rounded(.up)))
                cooldownHits += 1
                let f = AuthRecoveryFailure(reason: .cooldown,
                                            status: lastFailure?.status,
                                            isFinal: lastFailure?.isFinal ?? false,
                                            retryAfterSec: remaining,
                                            underlyingReason: lastFailure?.reason)
                return .cooling(f, hit: cooldownHits)
            }
            let task = Task<AuthRefreshOutcome, Never> {
                await self.runFlight(request, sendToken: sendToken, expectedRefresh: storedRefresh, key: key)
            }
            inFlight[key] = task
            return .start(task)
        }

        switch step {
        case .join(let task):
            emit(.debug, "refresh joined trigger=\(trigger)")
            return await task.value
        case .start(let task):
            return await task.value
        case .cooling(let failure, let hit):
            // One line per cooldown window start, then every 20th hit.
            if hit == 1 || hit % 20 == 0 {
                emit(.info, "refresh skipped trigger=\(trigger) \(failure.logFields) retry_in=\(failure.retryAfterSec) hits=\(hit)")
            }
            return .failed(failure)
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private func runFlight(_ request: AuthRefreshRequest, sendToken: String?, expectedRefresh: String?, key: String) async -> AuthRefreshOutcome {
        var outcome = await perform(request, sendToken: sendToken, expectedRefresh: expectedRefresh)
        var failuresNow = 0
        // The slot is released only after the tokens are persisted (see `perform`), in the
        // same critical section that records the failure state: a late caller either joins
        // this flight or finds the new pair in the store.
        lock.withLock {
            inFlight[key] = nil
            guard request.store != nil else {
                if case .failed(var f) = outcome {
                    f.retryAfterSec = Self.backoffSeconds(forFailures: 1)
                    outcome = .failed(f)
                }
                return
            }
            if case .failed(var f) = outcome {
                consecutiveFailures += 1
                failuresNow = consecutiveFailures
                f.retryAfterSec = Self.backoffSeconds(forFailures: consecutiveFailures)
                cooldownUntil = now().addingTimeInterval(TimeInterval(f.retryAfterSec))
                lastFailure = f
                cooldownHits = 0
                outcome = .failed(f)
            } else {
                consecutiveFailures = 0
                cooldownUntil = nil
                lastFailure = nil
                cooldownHits = 0
            }
        }
        let trigger = request.trigger.rawValue
        switch outcome {
        case .failed(let f):
            let level: AuthLogLevel = f.isFinal ? .error : .warn
            emit(level, "recovery failed trigger=\(trigger) \(f.logFields) retry_in=\(f.retryAfterSec) failures=\(failuresNow)")
        case .refreshed(_, let path):
            emit(.info, "recovery ok trigger=\(trigger) via=\(path.rawValue)")
        case .adopted:
            emit(.info, "recovery ok trigger=\(trigger) via=adopted")
        }
        return outcome
    }

    private func perform(_ request: AuthRefreshRequest, sendToken: String?, expectedRefresh: String?) async -> AuthRefreshOutcome {
        let trigger = request.trigger.rawValue
        let canRefresh = sendToken != nil && request.refresher != nil
        let canRenew = request.renewer != nil
        emit(.info, "recovery start trigger=\(trigger) refresh=\(canRefresh ? 1 : 0) renew=\(canRenew ? 1 : 0) store=\(request.store != nil ? 1 : 0)")

        var refreshFailure: AuthRecoveryFailure?
        if let token = sendToken, let refresher = request.refresher {
            do {
                let tokens = try await refresher(token)
                return finalize(tokens, expectedRefresh: expectedRefresh, request: request, via: .refresh)
            } catch {
                let f = Self.failure(from: error, fallback: .refreshOther)
                refreshFailure = f
                emit(.warn, "refresh step failed trigger=\(trigger) \(f.logFields) renew_next=\(canRenew ? 1 : 0)")
            }
        }

        if let renewer = request.renewer {
            do {
                let tokens = try await renewer()
                return finalize(tokens, expectedRefresh: expectedRefresh, request: request, via: .deviceRenew)
            } catch {
                let f = Self.failure(from: error, fallback: .renewOther)
                emit(.warn, "renew step failed trigger=\(trigger) \(f.logFields)")
                return .failed(f)
            }
        }

        if var f = refreshFailure {
            // Rejected by the server and nothing else to try: the session cannot heal by waiting.
            if f.reason == .refreshRejected {
                f = AuthRecoveryFailure(reason: f.reason, status: f.status, isFinal: true)
            }
            return .failed(f)
        }
        return .failed(AuthRecoveryFailure(reason: .noRecoveryPath, isFinal: false))
    }

    /// Persist a network result with compare-and-swap, or discard it if it lost the race.
    private func finalize(_ tokens: AuthTokenSet,
                          expectedRefresh: String?,
                          request: AuthRefreshRequest,
                          via path: AuthRecoveryPath) -> AuthRefreshOutcome {
        guard let store = request.store else {
            return .refreshed(tokens, via: path)
        }
        let trigger = request.trigger.rawValue
        do {
            if try store.compareAndSwap(expectedRefresh: expectedRefresh, with: tokens) {
                return .refreshed(tokens, via: path)
            }
            emit(.warn, "stale result discarded trigger=\(trigger) via=\(path.rawValue) cas=0")
            let current = try store.load()
            if let access = current.access, !access.isEmpty {
                return .adopted(AuthTokenSet(accessToken: access, refreshToken: current.refresh, expiresInSec: nil))
            }
            return .failed(AuthRecoveryFailure(reason: .casLost))
        } catch {
            // The server rotated the pair but it could not be stored. The next attempt
            // presents the old token and falls through to device-renew, which heals it.
            emit(.error, "persist failed trigger=\(trigger) via=\(path.rawValue) reason=\(AuthRecoveryReason.storeUnreadable.rawValue)")
            return .failed(AuthRecoveryFailure(reason: .storeUnreadable))
        }
    }

    private static func failure(from error: Error, fallback: AuthRecoveryReason) -> AuthRecoveryFailure {
        if let f = error as? AuthRecoveryFailure { return f }
        return AuthRecoveryFailure(reason: fallback)
    }
}

// MARK: - In-memory store (tests, previews)

public final class InMemoryAuthCredentialStore: AuthCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var access: String?
    private var refresh: String?
    private var unreadableStatus: Int32?

    public init(access: String? = nil, refresh: String? = nil) {
        self.access = access
        self.refresh = refresh
    }

    public func load() throws -> AuthStoredCredentials {
        try lock.withLock {
            if let s = unreadableStatus { throw AuthCredentialStoreError.unreadable(status: s) }
            return AuthStoredCredentials(access: access, refresh: refresh)
        }
    }

    public func compareAndSwap(expectedRefresh: String?, with tokens: AuthTokenSet) throws -> Bool {
        try lock.withLock {
            if let s = unreadableStatus { throw AuthCredentialStoreError.unreadable(status: s) }
            guard AuthRefreshCoordinator.sameRefreshToken(refresh, expectedRefresh) else { return false }
            access = tokens.accessToken
            if let r = tokens.refreshToken, !r.isEmpty { refresh = r }
            return true
        }
    }

    /// Simulate another writer (login, a path outside the coordinator).
    public func overwrite(access: String?, refresh: String?) {
        lock.withLock {
            self.access = access
            self.refresh = refresh
        }
    }

    /// Simulate a locked Keychain (`status` -25308) or clear it with nil.
    public func setUnreadable(status: Int32?) {
        lock.withLock { unreadableStatus = status }
    }
}
