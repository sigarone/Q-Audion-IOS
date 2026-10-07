import Foundation

/// W-SIGNERBOOT (2026-10-07) — "read the sovereign identity, create it ONLY if it is really absent",
/// as one serialised step.
///
/// WHY. The handshake is signed with this device's long-term Ed25519 identity
/// (`SovereignIdentityManager`). Nothing in the app created that identity when the account was set
/// up: the only creator was `ContactKeyExchange`'s lazy branch, run the first time a key exchange
/// was sent or received. A phone that received its FIRST call before any key exchange had
/// therefore no signer at all, the responder could not sign its ACCEPT and the call fell back to
/// the sealed relay (`sign_unavailable`), until the end-of-call key exchange finally minted the
/// identity. Creating it here, at the places that need it, closes that gap.
///
/// RULES.
///   * Present → never touched.
///   * Absent → generated and stored, exactly once, even when several callers race (the launch
///     bootstrap, the handshake and a key exchange can all arrive together): the check and the
///     creation are ONE critical section, so two callers can never mint two different identities
///     and let the second overwrite the first.
///   * Locked (`KeyVaultError.deviceLocked`, -25308) → the identity may well exist; nothing is
///     created, the caller retries after the user unlocks the phone.
///   * Any other read failure → nothing is created either: a failing read must never be answered
///     by writing a new key over one that may still be there.
///
/// Pure: the Keychain is behind two closures, so every branch is pinned by
/// `SovereignIdentityBootstrapTests` on the CI simulator (whose test bundle has no Keychain).
public enum SovereignIdentityBootstrap {

    public enum Outcome: Equatable {
        /// An identity was already stored.
        case existing
        /// None was stored; a new one was generated and stored by this call.
        case created
        /// The Keychain cannot be read right now (device locked). Nothing was created.
        case locked
        /// The read or the store failed for another reason. Nothing was overwritten.
        case failed
    }

    /// Process-wide: the identity lives in one Keychain slot, whatever manager instance reaches it.
    private static let gate = NSLock()

    /// - Parameters:
    ///   - read: `true` when an identity is stored and readable, `false` when there is none.
    ///     Throws `KeyVaultError.deviceLocked` for a locked Keychain, anything else for a failure.
    ///   - create: generate a new identity and store it. Called at most once, and only after
    ///     `read` answered `false`, with the gate held.
    public static func ensure(read: () throws -> Bool, create: () throws -> Void) -> Outcome {
        gate.lock()
        defer { gate.unlock() }
        do {
            if try read() { return .existing }
        } catch KeyVaultError.deviceLocked {
            return .locked
        } catch {
            return .failed
        }
        do {
            try create()
            return .created
        } catch {
            return .failed
        }
    }

    /// A short numeric code for a log line (the shipped log redactor drops anything wordy).
    public static func logCode(_ outcome: Outcome) -> Int {
        switch outcome {
        case .existing: return 0
        case .created: return 1
        case .locked: return 2
        case .failed: return 3
        }
    }
}
