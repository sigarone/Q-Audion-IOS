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
// Two rules keep the coordinator from making things worse than the outage it heals:
//
//   3. A signed-out store is never resurrected. When a store is attached, the refresh token
//      comes from it and ONLY from it: a lingering client of a logged-out (or switched)
//      session that still holds its own copy of an old refresh token cannot use it to sign
//      the device back in. An empty store, or a stored access token that belongs to another
//      account than the caller's, fails with no network call (`signed_out`, `account_changed`).
//   4. The server rate-limits the Ed25519 renew path hard (device-renew 6/h per device, burst
//      2, 60/h per IP; device-challenge 60/h per device) and records every rejected refresh
//      token presented again as a reuse event. So device-renew is attempted only when the
//      refresh token was REJECTED (401/403) or there is none (never on a network error, a 5xx
//      or a 429 of the refresh), a refresh token the server already rejected is not presented
//      again (for half an hour), and after a renew failure that PROVES the server's handler ran
//      (a 4xx/429/500 answer of device-renew or its challenge, or tokens that could not be
//      stored) the renew leg waits at least 10 minutes (6/h), longer if the server says so with
//      Retry-After. A failure that spent nothing (offline, a request cancelled by a network
//      handoff, a gateway 502/503/504, a locked Keychain) only keeps the 5/15/45/120 s ladder:
//      the server's own limiter (a free 429 once the burst is used) is the safety net there.
//
// One more rule keeps a single hung request from freezing every caller:
//
//   5. A flight has an overall deadline (`defaultFlightDeadlineSec`, 60 s: above the 3 x 15 s
//      that a refresh + challenge + renew can legitimately spend on the REST session's idle
//      timeout). When it expires the flight ends with the transient `flight_timeout` failure:
//      every waiter is released, the slot is freed and the ordinary ladder applies. The work
//      itself is cancelled but may still finish later; its result is still written with
//      compare-and-swap (the server may well have rotated the pair, so dropping it would lose
//      the new token), never over a newer pair, and a late rejection never starts a renew leg.
//
//   6. A flight cut at its deadline leaves an ABANDONED marker for its refresh token (until the
//      abandoned work completes, or `abandonedMarkerFactor` x the deadline at most). While the
//      marker lives no new flight presents that token: it ends at once with the transient
//      `flight_timeout` and no network call, because the abandoned request may still be on the
//      wire and two presentations of one refresh token within seconds are what collapsed the
//      session on 2026-10-02. The late result is still compare-and-swapped into the store and
//      adopted by the next caller. And a cancelled (abandoned) flight writes NO shared state
//      when it finally answers (dead-token memory, renew cooldown): only the compare-and-swap
//      of a successful result, so a zombie can never undo what a newer flight established.
//      One exception, in the safe direction: a late refresher SUCCESS proves the server spent
//      the token it was sent, so if that result cannot be stored (CAS throws, e.g. a locked
//      Keychain) the sent token is still remembered as dead. A late REJECTION is not recorded.
//   7. A refresh token the server rejected is final ONLY for a client without a store. A
//      store-backed client that merely lacks a renewer may be a half-wired builder: another
//      client of the same process, wired with device-renew, can still heal the session, so
//      the failure is transient for everyone and a renewer-equipped caller that joins the
//      flight (or arrives inside its cooldown) runs the renew leg itself.
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
    /// writing nothing, when the store holds something else, and always when the store is
    /// empty (no access and no refresh token: signed out, even if `expectedRefresh` is nil
    /// too). A `nil`/empty `tokens.refreshToken` leaves the stored refresh token untouched.
    func compareAndSwap(expectedRefresh: String?, with tokens: AuthTokenSet) throws -> Bool
}

/// Short, grep-friendly reason codes. These are the only vocabulary the log lines use.
public enum AuthRecoveryReason: String, Sendable, Equatable {
    case noRecoveryPath = "no_recovery_path"
    case cooldown = "cooldown"
    case storeUnreadable = "keychain_unreadable"
    case casLost = "cas_lost"
    /// The shared store holds no credentials at all: the session was logged out.
    case signedOut = "signed_out"
    /// The shared store holds the tokens of another account than the caller's.
    case accountChanged = "account_changed"
    /// Device-renew is waiting out its own rate-limit budget (`last=` is the failure that started it).
    case renewBudget = "renew_budget"
    /// The flight did not finish within its deadline (a request or a Keychain access that hung).
    /// Transient: the work may still finish later and its result is compare-and-swapped then.
    case flightTimeout = "flight_timeout"
    /// A recovery that SUCCEEDED (fresh or adopted tokens), yet the retried request was rejected
    /// with 401 again. Raised by the REST client, never by the coordinator. The session was just
    /// proven alive, so this is not a loss of credentials.
    case rejectedAfterRecovery = "rejected_after_recovery"

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

    /// True only when this failure PROVES the session's credentials are gone, so the caller
    /// may surface `BCryptoError.unauthorized` (which the app answers with a forced QR re-pair):
    /// the server revoked the device (device-renew 403), the device has no credential left to
    /// renew with, the store was signed out, or it now holds another account (all `isFinal`:
    /// the same set that parks the socket), or no recovery path exists at all for this client
    /// (`no_recovery_path`: a store-less / unwired client such as login or onboarding, whose
    /// 401 is simply the answer). Everything else (a cooldown after a transient failure, a
    /// network error, a 5xx or 429, the renew budget, a locked Keychain, a flight timeout)
    /// says nothing about the credentials and must surface as a transient error that is
    /// retried and never clears a token.
    public var provesCredentialLoss: Bool {
        isFinal || reason == .noRecoveryPath
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
    /// The refresh token the caller's own copy holds. Used ONLY when `store` is nil: with a
    /// store attached the store is the one source of truth, and a store that holds no refresh
    /// token is never papered over with a caller's possibly stale copy.
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

    /// Minimum wait before the renew leg runs again after a failure that provably spent the
    /// server's renew budget (see `spendsRenewBudget`). The server grants device-renew 6/h per
    /// device (burst 2), i.e. one per 10 min.
    public static let renewCooldownFloorSec = 600
    /// Minimum cooldown after a 429, whatever `Retry-After` said (the server sends 60).
    public static let rateLimitFloorSec = 60
    /// Upper bound for any cooldown, so a bogus `Retry-After` cannot park recovery for a day.
    public static let maxCooldownSec = 3600
    /// How long a rejected refresh token is remembered as dead. The server's 401 on a refresh
    /// token is definitive, but a safety valve costs one reuse event per half hour and keeps a
    /// spurious rejection from ever blocking the refresh leg for good.
    public static let deadTokenMemorySec = 1800
    /// Overall deadline of one flight (refresh, or refresh + challenge + renew). The REST
    /// session times a request out after 15 s of silence (`timeoutIntervalForRequest`; its
    /// resource timeout is the 7 day default, so a trickling answer can outlive it), and the
    /// longest legitimate cascade is a refresh, a challenge and a renew in a row: 3 x 15 s.
    /// 60 s sits above that, so a flight that is merely slow is never cut, and a hung one
    /// frees every caller within a minute.
    public static let defaultFlightDeadlineSec: TimeInterval = 60
    /// How long, in flight deadlines, an abandoned flight's marker keeps its refresh token from
    /// being presented again when the abandoned work never reports back.
    public static let abandonedMarkerFactor: Double = 2

    /// Equality for refresh tokens where nil and "" both mean "none".
    public static func sameRefreshToken(_ a: String?, _ b: String?) -> Bool {
        let x = (a?.isEmpty ?? true) ? nil : a
        let y = (b?.isEmpty ?? true) ? nil : b
        return x == y
    }

    /// False when a store holds neither token (nil and "" both mean none): a signed-out store.
    /// A compare-and-swap must refuse such a store even when `expectedRefresh` is nil too.
    public static func hasAnyToken(access: String?, refresh: String?) -> Bool {
        !((access?.isEmpty ?? true) && (refresh?.isEmpty ?? true))
    }

    /// The account an access token (a compact JWT) was minted for: its `uid` claim, else `sub`.
    /// Nil for anything that is not a decodable JWT with such a claim. NOT a verification: the
    /// token comes from our own store or config and the answer only ever makes the coordinator
    /// refuse to cross accounts, never grants anything.
    public static func accountId(ofAccessToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["uid", "sub"] {
            if let v = obj[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    /// False only when both access tokens decode and name different accounts.
    public static func sameAccount(_ a: String, _ b: String) -> Bool {
        guard let x = accountId(ofAccessToken: a), let y = accountId(ofAccessToken: b) else { return true }
        return x == y
    }

    /// True only for a renew-leg failure that PROVES the origin's device-renew handler ran, and so
    /// took a token from the server's 6/h bucket: an answer that carries a status the handler
    /// writes (400 clock skew, 401 bad signature or raced nonce, 403 revoked, 410 consumed nonce,
    /// 412 key not registered yet, 429 bucket empty, 500). Everything else did not provably spend
    /// anything and keeps the ordinary 5/15/45/120 s ladder: the local preflights (no device id,
    /// key not provisioned, Keychain locked), a transport failure (offline, DNS, timeout, pin
    /// failure, a request cancelled by a Wi-Fi/cellular handoff), a malformed challenge, and a
    /// gateway answer (502/503/504) that the origin never saw. The server limits itself: past
    /// the burst it answers a 429 without charging a token, and that 429 starts the 10 minute block.
    private static func spendsRenewBudget(_ f: AuthRecoveryFailure) -> Bool {
        switch f.reason {
        case .renewRejected, .renewServerError:
            guard let status = f.status else { return false }
            return !(502...504).contains(status)
        default:
            return false
        }
    }

    private let lock = NSLock()
    /// One running flight per key. `hasRenewer` records whether the flight's own request could
    /// run the renew leg: a joiner that can must not be stuck with the answer of one that could not.
    private struct Flight {
        let task: Task<AuthRefreshOutcome, Never>
        let hasRenewer: Bool
    }
    private var inFlight: [String: Flight] = [:]
    /// Flights cut at their deadline whose work may still be alive, by key (the refresh token
    /// the flight presented). Set by the deadline, cleared when the work completes, expiring
    /// after `abandonedMarkerFactor` x the deadline.
    private var abandoned: [String: (id: UInt64, until: Date)] = [:]
    private var nextFlightId: UInt64 = 0
    private var abandonedHits = 0
    /// True when the failure that started the current cooldown came from a flight WITHOUT a
    /// renewer and is one a renewer could heal (refresh rejected, no recovery path): callers
    /// that do have a renewer are not held back by that cooldown.
    private var cooldownHealableByRenewer = false
    private var consecutiveFailures = 0
    private var cooldownUntil: Date?
    private var lastFailure: AuthRecoveryFailure?
    private var cooldownHits = 0
    /// Renew leg's own cooldown (see `renewCooldownFloorSec`) and the failure that started it.
    private var renewBlockedUntil: Date?
    private var lastRenewFailure: AuthRecoveryFailure?
    /// The refresh token the server last rejected (or consumed) and when. In memory only, never logged.
    private var rejectedRefresh: (token: String, at: Date)?
    /// Bumped by `resetBackoff()`: a flight that began under an older epoch (before a login
    /// or logout) must not write its outcome into the state of the new session.
    private var epoch = 0
    private var logger: Logger?
    private let now: @Sendable () -> Date
    private let flightDeadlineSec: TimeInterval

    /// - Parameter flightDeadlineSec: overall deadline of one flight (tests inject a short one).
    public init(now: @escaping @Sendable () -> Date = { Date() },
                flightDeadlineSec: TimeInterval = AuthRefreshCoordinator.defaultFlightDeadlineSec) {
        self.now = now
        self.flightDeadlineSec = max(0.001, flightDeadlineSec)
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
            cooldownHealableByRenewer = false
            renewBlockedUntil = nil
            lastRenewFailure = nil
            rejectedRefresh = nil
            epoch += 1
        }
    }

    private func emit(_ level: AuthLogLevel, _ message: String) {
        let sink = lock.withLock { logger }
        sink?(level, message)
    }

    private enum Step {
        case join(Flight)
        case start(Flight)
        case cooling(AuthRecoveryFailure, hit: Int)
        case abandoned(AuthRecoveryFailure, hit: Int)
    }

    /// Run (or join) the one refresh for this session. Never throws: every outcome is a value.
    public func refresh(_ request: AuthRefreshRequest) async -> AuthRefreshOutcome {
        await refresh(request, healingRetry: false)
    }

    /// A failure a renewer could have healed, produced by a flight that had none.
    private static func isHealableByRenewer(_ f: AuthRecoveryFailure) -> Bool {
        !f.isFinal && (f.reason == .refreshRejected || f.reason == .noRecoveryPath)
    }

    private func refresh(_ request: AuthRefreshRequest, healingRetry: Bool) async -> AuthRefreshOutcome {
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

        // 1b. A store that holds nothing means the session was logged out. Whatever the caller
        // still has in memory (a client built before the logout: an upload in flight, a socket
        // recovery task) is a leftover of that session and must not sign the device back in by
        // presenting its own refresh token. No network call.
        if request.store != nil, let s = stored,
           Self.nonEmpty(s.access) == nil, Self.nonEmpty(s.refresh) == nil {
            let f = AuthRecoveryFailure(reason: .signedOut, isFinal: true)
            emit(.info, "refresh skipped trigger=\(trigger) \(f.logFields)")
            return .failed(f)
        }

        // 1c. The stored pair belongs to another account than the one this caller was rejected
        // for (logout, then a different login): never hand the new account's tokens to a
        // client of the old one, by adoption or by refreshing with the stored refresh token.
        if request.trigger.adoptsNewerStoredAccess,
           let stale = Self.nonEmpty(request.staleAccessToken),
           let current = Self.nonEmpty(stored?.access), current != stale,
           !Self.sameAccount(stale, current) {
            let f = AuthRecoveryFailure(reason: .accountChanged, isFinal: true)
            emit(.warn, "refresh skipped trigger=\(trigger) \(f.logFields)")
            return .failed(f)
        }

        // 2. Another path already rotated the pair: use it, spend no refresh token.
        if request.trigger.adoptsNewerStoredAccess,
           let stale = request.staleAccessToken, !stale.isEmpty,
           let s = stored, let access = s.access, !access.isEmpty, access != stale {
            emit(.info, "refresh adopted trigger=\(trigger) newer_stored=1")
            return .adopted(AuthTokenSet(accessToken: access, refreshToken: s.refresh, expiresInSec: nil))
        }

        // With a store attached the refresh token comes from the store only; the caller's own
        // copy is for store-less clients (onboarding, tests).
        let storedRefresh = Self.nonEmpty(stored?.refresh)
        let sendToken = request.store != nil ? storedRefresh : Self.nonEmpty(request.callerRefreshToken)
        let key = (request.store != nil ? "s:" : "c:") + (sendToken ?? "-")

        // 3. Join the flight for this token, or start it.
        let step: Step = lock.withLock {
            if let existing = inFlight[key] { return .join(existing) }
            // A renewer-equipped caller is not held back by a cooldown that a flight WITHOUT a
            // renewer started with a failure only a renewer can heal.
            let healsCooldown = request.renewer != nil && cooldownHealableByRenewer
            if !request.ignoreCooldown, request.store != nil, !healsCooldown,
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
            // The abandoned flight of this very token may still have its request on the wire:
            // presenting the token again now is the double presentation that kills sessions.
            // No network call, no state change; the caller retries and finds either the late
            // result (adopted from the store) or, once the work is gone, a free slot.
            if let mark = abandoned[key] {
                if now() < mark.until {
                    let remaining = max(1, Int(mark.until.timeIntervalSince(now()).rounded(.up)))
                    abandonedHits += 1
                    let f = AuthRecoveryFailure(reason: .flightTimeout,
                                                retryAfterSec: min(remaining, 15))
                    return .abandoned(f, hit: abandonedHits)
                }
                abandoned[key] = nil
            }
            let startEpoch = epoch
            nextFlightId += 1
            let flightId = nextFlightId
            let task = Task<AuthRefreshOutcome, Never> {
                await self.runFlight(request, sendToken: sendToken, expectedRefresh: storedRefresh,
                                     key: key, epoch: startEpoch, flightId: flightId)
            }
            let flight = Flight(task: task, hasRenewer: request.renewer != nil)
            inFlight[key] = flight
            return .start(flight)
        }

        switch step {
        case .join(let flight):
            emit(.debug, "refresh joined trigger=\(trigger)")
            let outcome = await flight.task.value
            // The flight we shared had no way to run the renew leg, this caller has: its
            // answer ("the refresh token was rejected") is exactly what device-renew heals.
            // Run once more; the rejected token is known dead by now, so this goes straight
            // to device-renew without presenting the refresh token again.
            if !healingRetry, request.store != nil, request.renewer != nil, !flight.hasRenewer,
               case .failed(let f) = outcome, Self.isHealableByRenewer(f) {
                emit(.info, "refresh retried with renewer trigger=\(trigger) \(f.logFields)")
                return await refresh(request, healingRetry: true)
            }
            return outcome
        case .start(let flight):
            return await flight.task.value
        case .cooling(let failure, let hit):
            // One line per cooldown window start, then every 20th hit.
            if hit == 1 || hit % 20 == 0 {
                emit(.info, "refresh skipped trigger=\(trigger) \(failure.logFields) retry_in=\(failure.retryAfterSec) hits=\(hit)")
            }
            return .failed(failure)
        case .abandoned(let failure, let hit):
            if hit == 1 || hit % 20 == 0 {
                emit(.info, "refresh skipped trigger=\(trigger) \(failure.logFields) abandoned_flight_live=1 retry_in=\(failure.retryAfterSec) hits=\(hit)")
            }
            return .failed(failure)
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// Cooldown of the next ordinary attempt: the ladder step, raised to whatever the failure
    /// itself asked for (`Retry-After`, the renew budget), never past `maxCooldownSec`.
    private static func retryAfter(forFailures n: Int, hint: Int) -> Int {
        min(max(backoffSeconds(forFailures: n), hint), maxCooldownSec)
    }

    private func runFlight(_ request: AuthRefreshRequest, sendToken: String?, expectedRefresh: String?,
                           key: String, epoch startEpoch: Int, flightId: UInt64) async -> AuthRefreshOutcome {
        var outcome = await performWithDeadline(request, sendToken: sendToken,
                                                expectedRefresh: expectedRefresh, epoch: startEpoch,
                                                key: key, flightId: flightId)
        var failuresNow = 0
        // The slot is released only after the tokens are persisted (see `perform`), in the
        // same critical section that records the failure state: a late caller either joins
        // this flight or finds the new pair in the store. A flight that hit its deadline
        // releases the slot without that guarantee: its late result is still written with
        // compare-and-swap whenever it arrives.
        lock.withLock {
            inFlight[key] = nil
            // Without a store there is no shared session to protect with a cooldown, and a
            // flight that began before a login/logout (`resetBackoff`) must not write its
            // outcome into the state of the session that replaced it.
            guard request.store != nil, epoch == startEpoch else {
                if case .failed(var f) = outcome {
                    f.retryAfterSec = Self.retryAfter(forFailures: 1, hint: f.retryAfterSec)
                    outcome = .failed(f)
                }
                return
            }
            if case .failed(var f) = outcome {
                consecutiveFailures += 1
                failuresNow = consecutiveFailures
                f.retryAfterSec = Self.retryAfter(forFailures: consecutiveFailures, hint: f.retryAfterSec)
                cooldownUntil = now().addingTimeInterval(TimeInterval(f.retryAfterSec))
                lastFailure = f
                cooldownHits = 0
                cooldownHealableByRenewer = request.renewer == nil && Self.isHealableByRenewer(f)
                outcome = .failed(f)
            } else {
                consecutiveFailures = 0
                cooldownUntil = nil
                lastFailure = nil
                cooldownHits = 0
                cooldownHealableByRenewer = false
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

    /// Run `perform` against the flight deadline. Whichever finishes first settles the flight:
    ///
    ///   - `perform` first: its outcome, exactly as before.
    ///   - The deadline first: the transient `flight_timeout` failure. The caller (`runFlight`)
    ///     then releases every waiter and frees the slot. The work is cancelled, which stops a
    ///     cooperative closure (a sleeping or awaiting Keychain call) and keeps `perform` from
    ///     starting the renew leg afterwards, but a request that ignores cancellation, or a
    ///     closure that never returns, simply stays behind: it can no longer hold anyone up.
    ///     If it does finish later, `perform` has already written its result with
    ///     compare-and-swap (never over a newer pair); only the log line is added here.
    ///     (`BCryptoRestClient.request` runs each call in its own unstructured task, which the
    ///     cancellation does not reach: there the answer, or the session's 15 s idle timeout,
    ///     arrives on its own schedule and takes the late-result path above.)
    ///
    /// Deliberately NOT a task group: a group waits for every child on exit, so one hung
    /// closure would hold the flight forever, which is the very failure being fixed.
    private func performWithDeadline(_ request: AuthRefreshRequest, sendToken: String?,
                                     expectedRefresh: String?, epoch startEpoch: Int,
                                     key: String, flightId: UInt64) async -> AuthRefreshOutcome {
        let gate = FlightGate()
        let trigger = request.trigger.rawValue
        let seconds = flightDeadlineSec

        let work = Task<Void, Never> { [self] in
            let outcome = await self.perform(request, sendToken: sendToken,
                                             expectedRefresh: expectedRefresh, epoch: startEpoch)
            if !gate.settle(outcome) {
                // The abandoned work is over: its request is no longer on the wire.
                self.clearAbandoned(key: key, flightId: flightId)
                self.emit(.info, "late flight result trigger=\(trigger) \(Self.describe(outcome)) cas_checked=1")
            }
        }
        let timer = Task<Void, Never> { [self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return  // the work finished first and cancelled the timer
            }
            // The marker goes up BEFORE the gate is settled: a late finish that finds the gate
            // settled then always finds the marker to take down, and a finish that won the gate
            // takes it down here. Either way no stale marker outlives the work.
            self.markAbandoned(key: key, flightId: flightId)
            let failure = AuthRecoveryFailure(reason: .flightTimeout)
            if gate.settle(.failed(failure)) {
                self.emit(.warn, "flight deadline reached trigger=\(trigger) after_s=\(Int(seconds.rounded(.up))) \(failure.logFields)")
                work.cancel()
            } else {
                self.clearAbandoned(key: key, flightId: flightId)
            }
        }
        let outcome = await gate.wait()
        timer.cancel()
        return outcome
    }

    private func markAbandoned(key: String, flightId: UInt64) {
        let until = now().addingTimeInterval(flightDeadlineSec * Self.abandonedMarkerFactor)
        lock.withLock { abandoned[key] = (id: flightId, until: until) }
    }

    private func clearAbandoned(key: String, flightId: UInt64) {
        lock.withLock {
            if abandoned[key]?.id == flightId { abandoned[key] = nil }
        }
    }

    private static func describe(_ outcome: AuthRefreshOutcome) -> String {
        switch outcome {
        case .refreshed(_, let path): return "outcome=ok via=\(path.rawValue)"
        case .adopted: return "outcome=ok via=adopted"
        case .failed(let f): return "outcome=failed \(f.logFields)"
        }
    }

    private func perform(_ request: AuthRefreshRequest, sendToken: String?, expectedRefresh: String?,
                         epoch startEpoch: Int) async -> AuthRefreshOutcome {
        let trigger = request.trigger.rawValue
        // A refresh token the server already rejected (or already consumed) is not presented
        // again: it cannot succeed and each repeat is a reuse event in the server's audit log.
        let rejected = lock.withLock { rejectedRefresh }
        var knownDead = false
        if let sendToken, let rejected, rejected.token == sendToken,
           now().timeIntervalSince(rejected.at) < TimeInterval(Self.deadTokenMemorySec) {
            knownDead = true
        }
        let canRefresh = sendToken != nil && request.refresher != nil && !knownDead
        let canRenew = request.renewer != nil
        let deadNote: String = knownDead ? " refresh_token_known_dead=1" : ""
        emit(.info, "recovery start trigger=\(trigger) refresh=\(canRefresh ? 1 : 0) renew=\(canRenew ? 1 : 0) store=\(request.store != nil ? 1 : 0)\(deadNote)")

        var refreshRejection: AuthRecoveryFailure?
        if canRefresh, let token = sendToken, let refresher = request.refresher {
            do {
                let tokens = try await refresher(token)
                let outcome = finalize(tokens, expectedRefresh: expectedRefresh, request: request, via: .refresh)
                if case .failed = outcome {
                    // The server rotated the pair, so the token we sent is spent whether or not
                    // the result could be stored, and even when this flight was abandoned at
                    // its deadline: a success is proof, unlike a late rejection.
                    markRefreshTokenDead(token, epoch: startEpoch, serverAccepted: true)
                }
                return outcome
            } catch {
                let f = Self.failure(from: error, fallback: .refreshOther)
                guard f.reason == .refreshRejected else {
                    // Network error, 5xx, 429, anything but a rejection: the refresh token may
                    // well be alive, and the renew leg is rate-limited far harder than refresh.
                    // Retry the refresh on the ladder; do not spend renew budget on it.
                    emit(.warn, "refresh step failed trigger=\(trigger) \(f.logFields) renew_next=0")
                    return .failed(f)
                }
                refreshRejection = f
                markRefreshTokenDead(token, epoch: startEpoch)
                emit(.warn, "refresh step failed trigger=\(trigger) \(f.logFields) renew_next=\(canRenew ? 1 : 0)")
            }
        }

        // Here the refresh token was rejected, is known dead, or there is none.
        guard let renewer = request.renewer else {
            // Final only for a client with no store: nothing else in the process shares its
            // session. With a store attached, a missing renewer says nothing about the session
            // (a half-wired builder, see header rule 7): another client of the same store, wired
            // with device-renew, can still heal it, so this is transient and a renewer-equipped
            // caller is let through (see `refresh`).
            let isFinal = request.store == nil
            if let f = refreshRejection {
                return .failed(AuthRecoveryFailure(reason: f.reason, status: f.status, isFinal: isFinal))
            }
            if knownDead {
                return .failed(AuthRecoveryFailure(reason: .refreshRejected, status: 401, isFinal: isFinal))
            }
            return .failed(AuthRecoveryFailure(reason: .noRecoveryPath, isFinal: false))
        }

        // A flight cancelled at its deadline (see `performWithDeadline`) that only now got its
        // refresh answered with a rejection must not go on to spend device-renew budget: its
        // callers were already released and the next flight decides what to do.
        if Task.isCancelled {
            emit(.info, "renew skipped trigger=\(trigger) reason=\(AuthRecoveryReason.flightTimeout.rawValue)")
            return .failed(AuthRecoveryFailure(reason: .flightTimeout))
        }

        // The renew leg has its own, much smaller, budget on the server (see the header).
        let gate: AuthRecoveryFailure? = lock.withLock {
            guard let until = renewBlockedUntil, now() < until else { return nil }
            let remaining = max(1, Int(until.timeIntervalSince(now()).rounded(.up)))
            return AuthRecoveryFailure(reason: .renewBudget,
                                       status: lastRenewFailure?.status,
                                       isFinal: lastRenewFailure?.isFinal ?? false,
                                       retryAfterSec: remaining,
                                       underlyingReason: lastRenewFailure?.reason)
        }
        if let gate {
            emit(.info, "renew skipped trigger=\(trigger) \(gate.logFields) retry_in=\(gate.retryAfterSec)")
            return .failed(gate)
        }

        do {
            let tokens = try await renewer()
            let outcome = finalize(tokens, expectedRefresh: expectedRefresh, request: request, via: .deviceRenew)
            if case .failed(let f) = outcome {
                // The renew reached the server and spent budget even though storing the result failed.
                return .failed(noteRenewFailure(f, epoch: startEpoch, serverMintedTokens: true))
            }
            lock.withLock {
                // A cancelled (abandoned) flight writes nothing but its compare-and-swap.
                guard epoch == startEpoch, !Task.isCancelled else { return }
                renewBlockedUntil = nil
                lastRenewFailure = nil
            }
            return outcome
        } catch {
            let f = Self.failure(from: error, fallback: .renewOther)
            emit(.warn, "renew step failed trigger=\(trigger) \(f.logFields)")
            return .failed(noteRenewFailure(f, epoch: startEpoch))
        }
    }

    /// - Parameter serverAccepted: the server ANSWERED THE REFRESH WITH A NEW PAIR, so the sent
    ///   token is provably spent. Only then is a cancelled (abandoned) flight allowed to write.
    private func markRefreshTokenDead(_ token: String, epoch startEpoch: Int, serverAccepted: Bool = false) {
        lock.withLock {
            // A cancelled (abandoned) flight must not touch shared state when its late answer
            // arrives, with one exception: a success that could not be stored (see above). The
            // epoch guard stays: a flight of a previous session never marks the new one.
            guard epoch == startEpoch, serverAccepted || !Task.isCancelled else { return }
            rejectedRefresh = (token: token, at: now())
        }
    }

    /// Start the renew cooldown for a failure that provably spent the server's renew budget
    /// (`spendsRenewBudget`), or for a renew the server answered with tokens that could not be
    /// stored (`serverMintedTokens`): at least `renewCooldownFloorSec` (6/h), or what the server
    /// asked for, whichever is longer. Any other failure (local preflight, transport error,
    /// gateway answer) spends no budget and keeps the ordinary ladder, so a dropped connection
    /// or a network handoff never locks the session out for ten minutes.
    private func noteRenewFailure(_ failure: AuthRecoveryFailure, epoch startEpoch: Int,
                                  serverMintedTokens: Bool = false) -> AuthRecoveryFailure {
        guard serverMintedTokens || Self.spendsRenewBudget(failure) else { return failure }
        var f = failure
        let wait = min(max(Self.renewCooldownFloorSec, f.retryAfterSec), Self.maxCooldownSec)
        f.retryAfterSec = wait
        lock.withLock {
            guard epoch == startEpoch, !Task.isCancelled else { return }
            renewBlockedUntil = now().addingTimeInterval(TimeInterval(wait))
            lastRenewFailure = f
        }
        return f
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
                // The store moved on while this flight was on the wire. If it now holds another
                // account (logout, then a different login) this caller must not receive it.
                if request.trigger.adoptsNewerStoredAccess,
                   let stale = Self.nonEmpty(request.staleAccessToken),
                   !Self.sameAccount(stale, access) {
                    return .failed(AuthRecoveryFailure(reason: .accountChanged, isFinal: true))
                }
                return .adopted(AuthTokenSet(accessToken: access, refreshToken: current.refresh, expiresInSec: nil))
            }
            return .failed(AuthRecoveryFailure(reason: .casLost))
        } catch {
            // The server rotated the pair but it could not be stored. The token we sent is
            // spent (see `perform`): the next attempt goes to device-renew, which heals it.
            emit(.error, "persist failed trigger=\(trigger) via=\(path.rawValue) reason=\(AuthRecoveryReason.storeUnreadable.rawValue)")
            return .failed(AuthRecoveryFailure(reason: .storeUnreadable))
        }
    }

    private static func failure(from error: Error, fallback: AuthRecoveryReason) -> AuthRecoveryFailure {
        if let f = error as? AuthRecoveryFailure { return f }
        return AuthRecoveryFailure(reason: fallback)
    }
}

// MARK: - Flight deadline gate

/// One-shot rendezvous between the work of a flight and its deadline: the first `settle` wins,
/// the single `wait` resumes with that value, whichever happened first.
private final class FlightGate: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var outcome: AuthRefreshOutcome?
    private var continuation: CheckedContinuation<AuthRefreshOutcome, Never>?

    /// Returns `true` when this call settled the gate, `false` when it was already settled.
    func settle(_ value: AuthRefreshOutcome) -> Bool {
        let (first, waiting): (Bool, CheckedContinuation<AuthRefreshOutcome, Never>?) = lock.withLock {
            guard !settled else { return (false, nil) }
            settled = true
            outcome = value
            let c = continuation
            continuation = nil
            return (true, c)
        }
        waiting?.resume(returning: value)
        return first
    }

    func wait() async -> AuthRefreshOutcome {
        await withCheckedContinuation { (c: CheckedContinuation<AuthRefreshOutcome, Never>) in
            let ready: AuthRefreshOutcome? = lock.withLock {
                if settled { return outcome }
                continuation = c
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
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
            // Never write into an empty (signed-out) store, even when `expectedRefresh` is nil too.
            guard AuthRefreshCoordinator.hasAnyToken(access: access, refresh: refresh) else { return false }
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
