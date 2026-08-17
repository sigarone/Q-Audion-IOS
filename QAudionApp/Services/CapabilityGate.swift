import Foundation
import QAudionEngine

/// One entry per design doc (`ENTITLEMENTS_TIERING_DESIGN.md`) §2's
/// feature-key table, Base+Pro rows only — the "never gated" rows
/// (`feat.calls.voice`, `feat.messages`, `feat.messages.group`, Base=yes
/// AND Pro=yes) are deliberately excluded, since there is nothing for a
/// `Capability` to gate there. Confirmed against the design doc directly
/// during Task 3 investigation (2026-08-17) rather than assumed from the
/// plan doc: the list has not drifted since the plan was written, matching
/// what Android's own Task 3 independently found. This enum is the ONE
/// place a new gated feature gets added; every call site references
/// `Capability`, never a raw string key. Byte-for-byte the same 12 cases,
/// same string values, as Android's `Capability` enum
/// (`core-data/.../entitlements/CapabilityGate.kt`).
public enum Capability: String, CaseIterable {
    case callsVideo = "feat.calls.video"
    case callsGroup = "feat.calls.group"
    case callsGroupVideo = "feat.calls.group_video"
    case files = "feat.files"
    case vpn = "feat.vpn"
    case kms = "feat.kms"
    case psk = "feat.psk"
    case keyManagement = "feat.key_management"
    case nfc = "feat.nfc"
    case meshBle = "feat.mesh_ble"
    case voiceBiometrics = "feat.voice_biometrics"
    case backup = "feat.backup"
}

/// Design doc §7.3: revocation policy per capability, never a blanket
/// teardown when a grant lapses mid-use.
public enum RevocationPolicy {
    /// An active group call, an in-flight file transfer — runs to its
    /// natural end even after the grant backing it lapses.
    case graceUntilEnd
    /// 1:1 video calls — downgrade to audio-only rather than a hard
    /// teardown.
    case degradeInPlace
    /// VPN tunnel, mesh link — end at the next natural boundary, never
    /// mid-packet.
    case stopAtBoundary
}

/// Design doc §7.3's explicit mapping, byte-for-byte the same as Android's
/// `Capability.revocationPolicy()`. Every capability without an explicit
/// policy defaults to `.graceUntilEnd` — the softest option — rather than
/// silently assuming a harder cutoff the design doc never specified for
/// that capability.
public extension Capability {
    var revocationPolicy: RevocationPolicy {
        switch self {
        case .callsGroup, .files: return .graceUntilEnd
        case .callsVideo: return .degradeInPlace
        case .vpn, .meshBle: return .stopAtBoundary
        default: return .graceUntilEnd
        }
    }
}

/// `GET /api/v1/entitlements/token` response shape — confirmed real and
/// already consumed by Android's Task 3 (`BCryptoApi.getEntitlementsToken`).
public struct EntitlementsTokenResponse: Codable {
    public let token: String
    public let kid: String

    public init(token: String, kid: String) {
        self.token = token
        self.kid = kid
    }
}

/// `POST /api/v1/entitlements/redeem` success response shape — confirmed
/// real during Task 4 investigation (2026-08-17) by reading
/// `handleEntitlementsRedeem` directly (`cmd/bcrypto-lite/main.go`):
/// `jsonOK(w, map[string]any{"already_redeemed": res.AlreadyRedeemed,
/// "token": tokenStr, "kid": kid})`. Same wire shape Android's Task 5
/// already consumes (`RedeemActivationCodeResponse` in
/// `core/core-data/.../net/dto/EntitlementsDto.kt`).
///
/// `token` is a freshly minted EGT (same shape as
/// `EntitlementsTokenResponse.token`) — the server mints inline after a
/// successful redemption specifically so the redeeming device never has a
/// window where it's holding a stale token, and so the idempotent-replay
/// path (`alreadyRedeemed == true`, where `entitlements_changed` is
/// deliberately NOT fired — `entitlements_redemption.go`) still has a
/// delivery mechanism for the grant. See `CapabilityGate.adopt(_:)`'s doc
/// for why this must be adopted directly, never discarded in favor of a
/// follow-up `refresh()`.
///
/// Non-2xx responses (400 invalid code, 409 conflict, 429 rate-limited,
/// 503 disabled) surface as a thrown `BCryptoError.httpError` from
/// `BCryptoRestClient` instead of populating this type.
public struct RedeemActivationCodeResponse: Codable {
    public let alreadyRedeemed: Bool
    public let token: String
    public let kid: String

    enum CodingKeys: String, CodingKey {
        case alreadyRedeemed = "already_redeemed"
        case token
        case kid
    }

    public init(alreadyRedeemed: Bool, token: String, kid: String) {
        self.alreadyRedeemed = alreadyRedeemed
        self.token = token
        self.kid = kid
    }
}

/// Thin seam around the entitlements network calls `CapabilityGate` and
/// `UpgradeSheet` (Task 4) need, so tests can fake them — investigation
/// found no existing `Fake*Api` convention in `QAudionAppTests` to copy
/// (every test there exercises a leaf value type or a static Keychain
/// accessor), so this follows the general Swift idiom directly: a narrow
/// protocol, one production conformance, one fake conformance per test
/// target. `redeemActivationCode` lives on the SAME protocol as
/// `fetchEntitlementsToken` (not a separate type) — both are entitlements
/// endpoints hit through the same `BCryptoRestClient`, mirroring Android's
/// `BCryptoApi` carrying both `getEntitlementsToken`/`redeemActivationCode`
/// side by side.
public protocol EntitlementsApiClient {
    func fetchEntitlementsToken() async throws -> EntitlementsTokenResponse
    /// `code` should already have passed `verifyActivationCodeChecksum`
    /// (`ActivationCode.swift`) client-side before this is ever called —
    /// the server re-checks it as its own first gate (design doc §5.1), so
    /// a client-side pass is a UX courtesy, not the security boundary.
    func redeemActivationCode(_ code: String) async throws -> RedeemActivationCodeResponse
}

/// Production `EntitlementsApiClient`, mirroring `BCryptoAccountApiImpl
/// .getProfile()`'s exact GET + `JSONDecoder` shape (Investigation step 3)
/// rather than inventing a new networking pattern for one endpoint —
/// `BCryptoRestClient.get(_:)` already carries Bearer-token injection and
/// the 401-refresh-and-retry cascade, so this type adds nothing on top of
/// it besides the path and the response type.
///
/// `getRestClient` is a settable closure, wired AFTER construction, rather
/// than a `BCryptoRestClient` taken directly in `init` — the same
/// `var getWsClient: WsClientProvider?` / `var getPeerId: PeerIdProvider?`
/// idiom `CallService` already uses (`AppState.connectPersistentSocket()`
/// wires those the same way). `AppState.liveProvider` cannot be captured at
/// `CapabilityGate`'s OWN property-initialization time (Swift forbids
/// referencing `self`/other instance members from a stored property's
/// initializer expression — the same reason `earbudCounterparty` in
/// `AppState.swift` is a `lazy var`), and `liveProvider` can be `nil` (not
/// yet connected) or get replaced (reconnect) over the object's lifetime —
/// reading it via a closure at CALL time, not caching a reference, is the
/// only shape that stays correct across both.
/// `@unchecked Sendable` — same escape hatch `EgtVerifier`/`CallService`
/// already use in this module: `getRestClient` is assigned once (from
/// `AppState`'s MainActor context, inside the `capabilityGate` lazy
/// initializer) and thereafter only ever READ, never mutated, by
/// `fetchEntitlementsToken()`, which itself may run off the main actor —
/// the same "closure captured across an actor boundary, read-only after
/// wiring" shape `CallService.getWsClient`/`getPeerId`/`getCallId` already
/// have without a compiler complaint in this codebase.
public final class BCryptoEntitlementsApiClient: EntitlementsApiClient, @unchecked Sendable {
    public var getRestClient: (() -> BCryptoRestClient?)?

    public init() {}

    public func fetchEntitlementsToken() async throws -> EntitlementsTokenResponse {
        guard let rest = getRestClient?() else { throw BCryptoError.unauthorized }
        let data = try await rest.get("/api/v1/entitlements/token")
        return try JSONDecoder().decode(EntitlementsTokenResponse.self, from: data)
    }

    /// `POST /api/v1/entitlements/redeem` — same request-body shape every
    /// other simple POST in this codebase uses (`{"code": "..."}` via
    /// `JSONSerialization`, matching `BCryptoAccountApiImpl.requestOtp`'s
    /// exact pattern, Investigation step 2), decoded via `JSONDecoder`
    /// like `fetchEntitlementsToken` just above. Non-2xx responses throw
    /// `BCryptoError.httpError`/`.unauthorized` from `BCryptoRestClient`,
    /// same as every other call through this client — see that type's own
    /// doc on why the failure response BODY (e.g. the specific 409 conflict
    /// reason) is not available here, unlike Android's `HttpException
    /// .response()?.errorBody()`.
    public func redeemActivationCode(_ code: String) async throws -> RedeemActivationCodeResponse {
        guard let rest = getRestClient?() else { throw BCryptoError.unauthorized }
        let body = try JSONSerialization.data(withJSONObject: ["code": code])
        let data = try await rest.post("/api/v1/entitlements/redeem", body: body)
        return try JSONDecoder().decode(RedeemActivationCodeResponse.self, from: data)
    }
}

/// Verified, cached EGT (Entitlement Grant Token) — the single source of
/// truth iOS's UI/use-case rings (design doc §7.1) read to decide what a
/// user may see or start. Registered on `AppState` the same flat
/// stored-property way `authService`/`callService` already are (no DI
/// container in this app — confirmed during investigation).
///
/// Port of Android's approved `CapabilityGate` (`core-data/.../entitlements
/// /CapabilityGate.kt`, shipped after 2 review rounds), adapted to this
/// app's real, different DI shape: Android independently injects
/// `TokenStore`/`WsDispatcher` into a Hilt singleton and subscribes to
/// their `Flow`s itself; iOS's `CapabilityGate` has no such independent
/// access to `AppState`'s reactive state (a `CapabilityGate` instance does
/// not — and structurally cannot, without breaking `AppState`'s existing
/// "flat stored property" shape — hold a reference back to the `AppState`
/// that owns it). So on iOS the reactive triggers Android arms inside its
/// own `start()` (WS-reconnect → `refresh()`, `entitlements_changed` →
/// `refresh()`, user-id change → discard) are instead wired FROM
/// `AppState`, calling INTO this class's public methods — see
/// `AppState.swift`'s `currentUserId` `didSet`, the WS state listener
/// inside `connectPersistentSocket()`, and the `entitlements_changed`
/// handler in `wireIncomingChatHandlers(on:)`.
///
/// Two invariants this class exists to hold, both load-bearing (Android's
/// exact wording, ported unchanged — the design constraints are identical
/// cross-platform):
///  1. `refresh()` NEVER clears an already-cached, already-verified grant
///     on failure — network error, non-2xx, a fresh token that fails
///     verification, or a fresh token minted for the wrong `sub` all leave
///     `claims` and the backing `TokenVault` exactly as they were (design
///     doc §3.2: `exp` is a refresh target, not a kill switch — a
///     connectivity blip must never look like a downgrade).
///  2. A grant is discarded the instant its `sub` stops matching the
///     logged-in user (design doc §7.1) — both at `loadCached()` time (a
///     stale cache left by a previous account) and reactively, via
///     `AppState`'s `currentUserId` `didSet` calling `loadCached()` again
///     on every login/logout/account-switch (a mid-session account switch,
///     before the next successful `refresh()` has a chance to overwrite it
///     with the new user's own grant). Whole-phase-review finding I1
///     (2026-08-17): this invariant does NOT hold for a session-ending
///     event that clears `TokenVault` WITHOUT also nilling `currentUserId`
///     — 4 of `AuthService.clearToken()`'s 5 call sites do exactly that
///     (only `AppState.logout()` nils `currentUserId` too). Those 4 sites
///     now call `discard()` explicitly instead — see that method's doc for
///     the full list and why an explicit call was chosen over widening
///     what `currentUserId = nil` touches at each site.
@MainActor
public final class CapabilityGate: ObservableObject {
    /// Read-only view for UI call sites that want to react to entitlement
    /// changes via SwiftUI's `@Published`/`@ObservedObject`/
    /// `@EnvironmentObject` machinery, rather than polling `has(_:)`.
    /// Deliberately a plain `@Published` property read directly by
    /// `ObservableObject` conformance — NOT hoisted into a plain value and
    /// threaded down through a router/coordinator that builds a view
    /// hierarchy once and caches it. This app's own navigation
    /// (`NavigationStack`/`.sheet`/`.fullScreenCover` in `ContentView.swift`)
    /// has no Jetpack-Compose-Nav3-`entry<T>`-style cache-the-hierarchy-once
    /// idiom — Grep-verified, not exhaustively audited — so that specific
    /// trap does not exist here.
    ///
    /// **A DIFFERENT, real reactivity gap DOES exist today (whole-phase-
    /// review finding I4, 2026-08-17), left for Task 5 (real UI call sites)
    /// to close, not fixed here:** `QAudionApp.swift` only does
    /// `.environmentObject(appState)`, never
    /// `.environmentObject(appState.capabilityGate)`, and `capabilityGate`
    /// is a plain `lazy var` on `AppState`, not itself observed by
    /// anything. A view that reads `appState.capabilityGate.has(...)`
    /// (via `@EnvironmentObject var appState: AppState`) inside `body`
    /// will NOT re-render when `claims` changes — SwiftUI does not forward
    /// a nested `ObservableObject`'s publisher through its parent
    /// automatically, and `AppState` never re-publishes on
    /// `capabilityGate`'s behalf. Task 5 must either inject
    /// `capabilityGate` as its OWN `@EnvironmentObject`
    /// (`.environmentObject(appState.capabilityGate)` alongside
    /// `appState`) or have `AppState` forward `capabilityGate.objectWillChange`
    /// into its own — do not assume `@EnvironmentObject var appState`
    /// alone makes a nested `capabilityGate.has(...)` read reactive.
    @Published public private(set) var claims: EgtClaims?

    private let verifier: EgtVerifier
    private let api: EntitlementsApiClient

    public init(verifier: EgtVerifier, api: EntitlementsApiClient) {
        self.verifier = verifier
        self.api = api
    }

    /// O(1) lookup. `false` before any token has ever been loaded (no
    /// cached claims yet), `false` if the current claims don't mention
    /// `capability` at all, and otherwise checks the feature's own expiry
    /// inside `fea` — `0` means perpetual (design doc §3.1).
    public func has(_ capability: Capability) -> Bool {
        guard let expiry = claims?.fea[capability.rawValue] else { return false }
        return expiry == 0 || expiry > Int64(Date().timeIntervalSince1970)
    }

    /// True unless a verified grant is currently loaded AND it explicitly
    /// lacks `capability`. Mirrors Android's `isUnlocked` (added in its own
    /// Task 4 review, findings C1/C2): "nothing verified yet" — cold start,
    /// offline, a mint-endpoint hiccup, or the pinned EGT pubkey still
    /// being Task 1's placeholder test key (true of every build today) —
    /// must never render as locked, or every capability would show
    /// Pro-locked to every user, Pro included, until the first successful
    /// token load. `has(_:)` alone conflates "no grant loaded yet" and
    /// "grant loaded, capability denied" into the same `false`; a naive
    /// `!has(capability)` read as "should I show this locked" cannot tell
    /// them apart. Android's review found exactly this bug hand-inlined at
    /// two separate UI call sites before adding this single named method.
    /// Task 5 (real UI call sites, not built here) should use THIS, not
    /// `!has(capability)`, when deciding whether to show a lock badge.
    public func isUnlocked(_ capability: Capability) -> Bool {
        guard let current = claims else { return true }
        guard let expiry = current.fea[capability.rawValue] else { return false }
        return expiry == 0 || expiry > Int64(Date().timeIntervalSince1970)
    }

    /// Loads and verifies whatever `TokenVault` has cached, discarding it —
    /// clearing BOTH the in-memory `claims` AND the persisted Keychain
    /// entry — if verification fails or the cached `sub` no longer matches
    /// the logged-in user (design doc §7.1). Call before any gated UI can
    /// render, and again on every reactive user-id change (see
    /// `AppState.currentUserId`'s `didSet`).
    public func loadCached() {
        guard let raw = TokenVault.loadEntitlement() else {
            claims = nil
            return
        }
        guard let verified = verifier.verify(raw), verified.sub == TokenVault.loadUserId() else {
            RTLog.warn("entitlements", "loadCached: cached token failed verification or sub mismatch — discarding")
            TokenVault.clearEntitlement()
            claims = nil
            return
        }
        claims = verified
    }

    /// Explicitly discards the in-memory grant and its persisted Keychain
    /// copy, WITHOUT requiring `AppState.currentUserId` to change first.
    ///
    /// Whole-phase-review finding I1 (2026-08-17): `loadCached()`'s discard
    /// only ever fires reactively through `currentUserId`'s `didSet`, but
    /// `AuthService.clearToken()` (which wipes the Keychain EGT via
    /// `TokenVault.clear()`) has 5 call sites in this app and only
    /// `AppState.logout()` also nils `currentUserId` — the other 4 (hard
    /// credential rejection after the refresh+device-renew cascade fails,
    /// the `remote_wipe` WS handler, the `account_locked` WS handler, and
    /// account deletion in `AccountSettingsScreen`) left `claims` fully
    /// populated in memory after the Keychain copy was already gone.
    /// Investigated each of those 4 sites before picking this fix over
    /// also nilling `currentUserId` there: none of them currently touch
    /// `currentUserId` (two — `remote_wipe`/`account_locked` — do not even
    /// flip `isAuthenticated`, a wider pre-existing gap outside this
    /// method's scope, not something specific to entitlements), so the
    /// surgical fix is an explicit call here rather than widening what
    /// `currentUserId = nil` touches at 4 sites whose other readers were
    /// not fully audited in this pass.
    public func discard() {
        RTLog.warn("entitlements", "discard: session ended (token cleared) without a currentUserId change — clearing cached grant")
        TokenVault.clearEntitlement()
        claims = nil
    }

    /// Fetches a fresh token from the server, verifies it, and caches it.
    /// On ANY failure — network error, non-2xx response (surfaced by
    /// `BCryptoRestClient` as a thrown `BCryptoError`), a fresh token that
    /// fails `EgtVerifier.verify`, or a fresh token whose `sub` doesn't
    /// match the logged-in user — this leaves whatever was already cached
    /// (both `claims` and `TokenVault`) completely untouched. Never throws:
    /// `try?` collapses the one call that can (`api.fetchEntitlementsToken`)
    /// into an `Optional`, and `tryAdopt` applies the same fail-closed
    /// acceptance rule to the token itself.
    public func refresh() async {
        guard let response = try? await api.fetchEntitlementsToken() else {
            RTLog.warn("entitlements", "refresh: fetchEntitlementsToken failed (network error or non-2xx) — keeping existing cache")
            return
        }
        _ = tryAdopt(response.token, source: "refresh")
    }

    /// Adopts a token that already arrived through a side channel OTHER
    /// than `refresh()`'s own `GET /entitlements/token` call — Task 4's
    /// activation-code redemption response is the intended future caller
    /// (mirrors Android's `adopt`, added there specifically because calling
    /// `refresh()` after redemption was a redundant round-trip that
    /// silently did nothing on the idempotent-replay path, where the server
    /// deliberately does not fire the `entitlements_changed` doorbell).
    ///
    /// Same acceptance rule `refresh()` applies to a freshly-fetched token:
    /// a `token` that fails `EgtVerifier.verify` or whose `sub` doesn't
    /// match the logged-in user is silently rejected, `claims`/`TokenVault`
    /// left exactly as they were. Returns `true` iff `token` was adopted.
    @discardableResult
    public func adopt(_ token: String) -> Bool {
        tryAdopt(token, source: "adopt")
    }

    /// Shared verify → sub-check → cache sequence `refresh()` and `adopt(_:)`
    /// both need, single-sourced so the acceptance rule can't drift between
    /// the two callers — mirrors Android's own `tryAdopt(token, source)`.
    /// `source` distinguishes the two log lines below so a real support
    /// case ("my Pro features disappeared") can tell a routine background
    /// refresh failure from a rejected redemption-code adoption.
    @discardableResult
    private func tryAdopt(_ token: String, source: String) -> Bool {
        guard let verified = verifier.verify(token) else {
            RTLog.warn("entitlements", "\(source): token failed verification, keeping existing cache")
            return false
        }
        guard verified.sub == TokenVault.loadUserId() else {
            RTLog.warn("entitlements", "\(source): token sub mismatch, keeping existing cache")
            return false
        }
        TokenVault.saveEntitlement(token)
        claims = verified
        RTLog.info("entitlements", "\(source): adopted a verified token")
        return true
    }
}
