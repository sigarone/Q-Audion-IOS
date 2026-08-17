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

/// Thin seam around the one network call `CapabilityGate` needs, so tests
/// can fake it — investigation found no existing `Fake*Api` convention in
/// `QAudionAppTests` to copy (every test there exercises a leaf value type
/// or a static Keychain accessor), so this follows the general Swift
/// idiom directly: a narrow protocol, one production conformance, one fake
/// conformance in the test target.
public protocol EntitlementsApiClient {
    func fetchEntitlementsToken() async throws -> EntitlementsTokenResponse
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
///     with the new user's own grant).
@MainActor
public final class CapabilityGate: ObservableObject {
    /// Read-only view for UI call sites that want to react to entitlement
    /// changes via SwiftUI's `@Published`/`@ObservedObject`/
    /// `@EnvironmentObject` machinery, rather than polling `has(_:)`.
    /// Deliberately a plain `@Published` property read directly by
    /// `ObservableObject` conformance — NOT hoisted into a plain value and
    /// threaded down through a router/coordinator that builds a view
    /// hierarchy once and caches it (see the SwiftUI-reactivity-trap note
    /// in the Task 3 report: this app's `NavigationStack`/`.sheet`-based
    /// navigation, unlike Jetpack Compose Nav3's `entry<T>` cache, rebuilds
    /// its view closures on every SwiftUI diff pass, so a view reading
    /// `capabilityGate.has(...)` via `@EnvironmentObject` inside `body`
    /// re-evaluates on every publish — there is no equivalent trap
    /// confirmed here, and this shape is the one least likely to invite
    /// one by accident).
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
            TokenVault.clearEntitlement()
            claims = nil
            return
        }
        claims = verified
    }

    /// Fetches a fresh token from the server, verifies it, and caches it.
    /// On ANY failure — network error, non-2xx response (surfaced by
    /// `BCryptoRestClient` as a thrown `BCryptoError`), a fresh token that
    /// fails `EgtVerifier.verify`, or a fresh token whose `sub` doesn't
    /// match the logged-in user — this leaves whatever was already cached
    /// (both `claims` and `TokenVault`) completely untouched. Never throws:
    /// `try?` collapses the one call that can (`api.fetchEntitlementsToken`)
    /// into an `Optional`, and `adopt(_:)` applies the same fail-closed
    /// acceptance rule to the token itself.
    public func refresh() async {
        guard let response = try? await api.fetchEntitlementsToken() else { return }
        _ = adopt(response.token)
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
        guard let verified = verifier.verify(token), verified.sub == TokenVault.loadUserId() else {
            return false
        }
        TokenVault.saveEntitlement(token)
        claims = verified
        return true
    }
}
