import Foundation

/// Maps the errors the two recovery legs can throw onto the short reason codes the
/// coordinator logs and the socket decides on. Pure: no I/O, no secrets.
///
/// The question each mapping answers is "can waiting fix this?". A transient failure keeps
/// the session alive and is retried with backoff; only a server-confirmed device revocation
/// or the absence of any device credential is `isFinal`. (Before this, ANY failure of the
/// recovery made the socket give up for good, which is how a locked Keychain or a dropped
/// connection could leave a device signed out until something restarted the socket.)
enum AuthFailureClassifier {

    // MARK: - POST /auth/refresh

    static func classifyRefresh(_ error: Error) -> AuthRecoveryFailure {
        if let f = error as? AuthRecoveryFailure { return f }
        if let rl = error as? BCryptoRateLimitedError { return rateLimited(rl, reason: .refreshServerError) }
        if let e = error as? BCryptoError {
            switch e {
            case .unauthorized:
                return AuthRecoveryFailure(reason: .refreshRejected, status: 401)
            case .httpError(let status):
                return refreshHTTP(status)
            case .paymentRequired:
                return AuthRecoveryFailure(reason: .refreshOther, status: 402)
            default:
                return AuthRecoveryFailure(reason: .refreshOther)
            }
        }
        if isNetwork(error) { return AuthRecoveryFailure(reason: .refreshNetwork) }
        return AuthRecoveryFailure(reason: .refreshOther)
    }

    private static func refreshHTTP(_ status: Int) -> AuthRecoveryFailure {
        switch status {
        case 401, 403:
            return AuthRecoveryFailure(reason: .refreshRejected, status: status)
        case 429:
            return AuthRecoveryFailure(reason: .refreshServerError, status: status,
                                       retryAfterSec: AuthRefreshCoordinator.rateLimitFloorSec)
        case 500...599:
            return AuthRecoveryFailure(reason: .refreshServerError, status: status)
        default:
            return AuthRecoveryFailure(reason: .refreshOther, status: status)
        }
    }

    // MARK: - device-challenge + device-renew

    static func classifyRenew(_ error: Error) -> AuthRecoveryFailure {
        if let f = error as? AuthRecoveryFailure { return f }
        if let rl = error as? BCryptoRateLimitedError { return rateLimited(rl, reason: .renewServerError) }

        if let pre = error as? AuthRenewPreconditionError {
            switch pre {
            case .noDeviceId:
                return AuthRecoveryFailure(reason: .renewNoDeviceId, isFinal: true)
            }
        }
        if let renew = error as? BCryptoDeviceRenewClient.Error {
            switch renew {
            case .ed25519PrivateNotProvisioned:
                return AuthRecoveryFailure(reason: .renewKeyNotProvisioned, isFinal: true)
            case .malformedNonceHex:
                return AuthRecoveryFailure(reason: .renewMalformedChallenge)
            case .serverRejected(let inner):
                return renewHTTP(inner)
            }
        }
        if let vault = error as? KeyVaultError {
            switch vault {
            case .deviceLocked:
                return AuthRecoveryFailure(reason: .renewKeychainLocked)
            case .loadFailed(let status):
                return AuthRecoveryFailure(reason: .renewKeychainError, status: Int(status))
            default:
                return AuthRecoveryFailure(reason: .renewKeychainError)
            }
        }
        // The challenge GET is not wrapped by `serverRejected`: it throws the raw client error.
        if let e = error as? BCryptoError { return renewHTTP(e) }
        if isNetwork(error) { return AuthRecoveryFailure(reason: .renewNetwork) }
        // A request cancelled from outside (the REST client cancels every in-flight call of the
        // previous network generation on a Wi-Fi/cellular handoff) says nothing about the
        // server: it is a transport failure like a lost connection, never a spent renew.
        if error is CancellationError { return AuthRecoveryFailure(reason: .renewNetwork) }
        return AuthRecoveryFailure(reason: .renewOther)
    }

    /// Device-renew answers: 403 = device revoked (final); 401 = bad signature or raced nonce,
    /// 400 = clock skew, 410 = consumed nonce, 412 = public key not registered yet (all retried
    /// with backoff); 429/5xx = server side.
    private static func renewHTTP(_ error: BCryptoError) -> AuthRecoveryFailure {
        switch error {
        case .unauthorized:
            return AuthRecoveryFailure(reason: .renewRejected, status: 401)
        case .httpError(let status):
            switch status {
            case 403:
                return AuthRecoveryFailure(reason: .renewRejected, status: 403, isFinal: true)
            case 429:
                return AuthRecoveryFailure(reason: .renewServerError, status: status,
                                           retryAfterSec: AuthRefreshCoordinator.rateLimitFloorSec)
            case 500...599:
                return AuthRecoveryFailure(reason: .renewServerError, status: status)
            default:
                return AuthRecoveryFailure(reason: .renewRejected, status: status)
            }
        case .paymentRequired:
            return AuthRecoveryFailure(reason: .renewRejected, status: 402)
        case .certPinningFailed:
            return AuthRecoveryFailure(reason: .renewNetwork)
        default:
            return AuthRecoveryFailure(reason: .renewOther)
        }
    }

    /// A 429 from a recovery endpoint: wait what the server asked (`Retry-After`), but never
    /// less than `rateLimitFloorSec`. The coordinator treats `retryAfterSec` as a minimum.
    private static func rateLimited(_ error: BCryptoRateLimitedError, reason: AuthRecoveryReason) -> AuthRecoveryFailure {
        let wait = max(AuthRefreshCoordinator.rateLimitFloorSec, error.retryAfterSec ?? 0)
        return AuthRecoveryFailure(reason: reason, status: 429, retryAfterSec: wait)
    }

    static func isNetwork(_ error: Error) -> Bool {
        if error is URLError { return true }
        return (error as NSError).domain == NSURLErrorDomain
    }
}

/// When may the app wipe the stored session because a request failed?
///
/// `BCryptoError.unauthorized` is the one error that answers "the credentials are gone", and
/// the app answers it with `clearToken()` and a forced QR re-pair, so it must never be raised
/// for a transient failure (see `BCryptoRestClient.tryRefreshToken`: only a failure that
/// `provesCredentialLoss` surfaces as `.unauthorized`, everything else is a
/// `BCryptoSessionRecoveryError` or a plain network error). This is the second lock on that
/// door, applied at the one place that wipes the session after a REST failure (the launch
/// `getProfile` catch): even `.unauthorized` wipes only the session the request was made for.
public enum AuthSessionLossPolicy {

    /// - Parameters:
    ///   - error: what the request threw.
    ///   - requestAccessToken: the access token the failed request (the launch one) used.
    ///   - storedAccessToken: what the credential store holds now.
    /// - Returns: `true` only for `BCryptoError.unauthorized` while the store still holds the
    ///   session that request was made for (or nothing). A store that holds another access
    ///   token belongs to a session that replaced it (logout, then a different login: the
    ///   coordinator's `account_changed`): wiping it would sign the NEW account out.
    public static func shouldClearSession(after error: Error,
                                          requestAccessToken: String?,
                                          storedAccessToken: String?) -> Bool {
        guard case BCryptoError.unauthorized = error else { return false }
        if let stored = storedAccessToken, !stored.isEmpty, stored != requestAccessToken {
            return false
        }
        return true
    }
}
