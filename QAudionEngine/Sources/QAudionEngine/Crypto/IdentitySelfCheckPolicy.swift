import Foundation

/// W-IDSELFHEAL (2026-09-02) — closes the gap the night's SAS-blocking
/// incident exposed: `publishWithRetry` (AppState.swift) only ever compares
/// against ITS OWN memory of "did I already confirm a 200 for this exact
/// fingerprint" (`UserDefaults`). It never asks whether the SERVER still
/// agrees — so if the server-side record is overwritten by something outside
/// this device's control (root-caused live 2026-09-01/02, see audit memory
/// `reference_ios_stability_audit_2026_09_01.md`'s SAS investigation: a
/// second physical device sharing this account's device id republished a
/// different key on 2026-08-24, and the real device's local fingerprint
/// cache never noticed because IT never changed), this device keeps signing
/// with a key the server has no record of. Every peer that then verifies
/// this device's handshake finds the signer identity key outside the
/// server-published set — `identity_key_mismatch` — and the SAS
/// confirmation stays blocking on every single call, forever, with no way
/// for either side to self-correct.
///
/// This is a SELF-consistency check, not a trust decision about a peer: it
/// only ever asks the server "what do you have on file for MY OWN account",
/// over this device's own already-authenticated session — the exact same
/// `?all=1` set a peer already fetches to verify THIS device (D11
/// trust-on-publish), just pointed at `currentUserId` instead of a contact.
/// It never trusts anything peer-supplied, so it cannot be used by another
/// party to trigger extra republishes.
///
/// Pure decision only — the actual GET/POST and the persisted-fingerprint
/// cache-clear live in `AppState.runKmsSweep()`, which already fetches this
/// device's identity every sweep (periodic ~300s tick, on WS reconnect, and
/// on `kms_key_available`) — frequent enough that a genuine divergence
/// self-heals within one cycle instead of blocking every future call
/// indefinitely, matching the existing sweep cadence with no new timer.
public enum IdentitySelfCheckPolicy {
    /// Compile-time kill switch. `false` restores the exact pre-2026-09-02
    /// behavior (publish decision driven solely by the local cache).
    public static let selfCheckEnabled = true

    /// Floor between two self-heal-triggered republish attempts. Second
    /// opinion (`nim.ps1 -Mode security`) flagged the real edge case this
    /// guards: TWO physical devices sharing one account (this incident's
    /// exact root cause) each running this same self-heal would otherwise
    /// out-race each other every sweep (~300s), each seeing the OTHER's key
    /// as "missing" and re-publishing its own — a fast ping-pong that fixes
    /// nothing (the underlying two-devices-one-slot condition is a data/
    /// account-hygiene issue this code cannot resolve) while generating
    /// needless traffic and repeated SAS friction for every peer. This does
    /// not fix that condition — it only slows a genuine conflict down to a
    /// human-noticeable cadence instead of a network-noticeable one, while
    /// leaving the very-common single-device "server record went stale"
    /// case (this incident's actual trigger) to heal on the first sweep
    /// after the divergence, unchanged.
    public static let minRepublishIntervalSec: TimeInterval = 600

    /// `lastTriggeredAt` is the last time THIS check itself cleared the
    /// confirmed-fingerprint cache (nil = never). Independent of whether
    /// the resulting publish attempt succeeded — succeed or fail, the next
    /// self-heal check still waits out the same floor, so a persistently
    /// unreachable server cannot be hammered every sweep either.
    public static func shouldCheckNow(lastTriggeredAt: Date?, now: Date) -> Bool {
        guard selfCheckEnabled else { return false }
        guard let last = lastTriggeredAt else { return true }
        return now.timeIntervalSince(last) >= minRepublishIntervalSec
    }

    /// `serverKeys` is `BCryptoKmsClient.fetchUserIdentityKeySet(userId:)`'s
    /// result for THIS device's own `currentUserId` — empty on genuine
    /// "nothing published yet" AND on any transport/decode error (the
    /// client's own documented contract). Treating both as "needs
    /// republish" is deliberate: the underlying publish call is itself
    /// best-effort and idempotent (a stale/absent record and a transient
    /// fetch failure both call for the same corrective action — try
    /// publishing again), so there is no case here where retrying is worse
    /// than not retrying.
    ///
    /// `localSigningPub` must be exactly 32 bytes (the Ed25519 signing
    /// public key already used to construct the publish fingerprint) —
    /// callers already guard this length before reaching this policy.
    public static func needsRepublish(serverKeys: Set<Data>, localSigningPub: Data) -> Bool {
        guard selfCheckEnabled else { return false }
        return !serverKeys.contains(localSigningPub)
    }
}
