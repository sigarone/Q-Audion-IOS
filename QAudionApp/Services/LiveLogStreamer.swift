import Foundation
import QAudionEngine
import UIKit

/// W417 — Opt-in real-time telemetry pump (SECURITY C-10).
///
/// **Consent gate (SECURITY C-10):** this streamer uploads runtime
/// log chunks to the server. Doing that without explicit user consent
/// is a privacy violation. `start(...)` therefore checks the
/// UserDefaults bool `qaudion.diagnostics.liveStreamEnabled` and does
/// NOTHING (no tee, no upload, no timer) unless the user has
/// explicitly opted in. The key DEFAULTS TO FALSE when absent — the
/// pump is OFF until a Settings toggle flips it via
/// `LiveLogStreamer.setEnabled(true)`. Disabling it calls `stop()`
/// which fully tears down the timer + network path monitor.
///
/// **Why this exists:** the user reported on 2026-05-03 that opening
/// Settings → Diagnostica freezes the app, blocking the W415/W416
/// manual "Carica al server" flow. When the user has consented, an
/// auto-push mechanism lets the maintainer inspect runtime behaviour.
///
/// **What it does (only when consented):** every `flushIntervalSeconds`
/// (default 3s) the streamer reads new entries from `RuntimeLogSink`
/// since the last collection, redacts and formats them as JSON lines, keeps them in a
/// bounded backlog until the server confirms them, and uploads them as a UTF-8 .log
/// chunk via the shared tus-always pipeline (`/api/v1/files/tus`, see W-STORAGESPLIT on
/// `BCryptoStorageApiImpl.uploadFile`), NOT the legacy multipart
/// `/api/v1/files/upload` endpoint this comment used to (incorrectly)
/// describe. That mismatch is what let these chunks slip past the
/// server's SRV-M2 telemetry tagging for years (fixed W-TUSFILENAME,
/// 2026-09-08, by finally sending `filename` in the tus create's
/// Upload-Metadata). Each chunk's filename is:
///   `qaudion-live-<sessionHmac8>-<bootSession>-<seqZeroPad6>.log`
/// The maintainer reconstructs the timeline by listing files
/// matching the prefix sorted by name. The user-id prefix is an
/// HMAC (SECURITY L-6) so the server cannot enumerate logs by raw
/// user id.
///
/// **API design — IMPORTANT:** `start()` takes PRIMITIVE values plus
/// `@MainActor` closures, NEVER an `AppState` parameter directly. The
/// bisect from v1.0.386→v1.0.397 proved that having `AppState` as a
/// parameter TYPE in a method signature on a new file BREAKS THE
/// BUILD silently (Swift 6 strict concurrency Sendable inference
/// explodes on AppState's many @Published properties). The closure
/// approach captures only the specific values/behaviors needed (token,
/// userId, and — since 2026-09-10 — a way to ask for a token refresh)
/// without dragging the whole AppState type into the signature.
/// See CLAUDE.md "Hard-won lesson 16" for the full story.
///
/// **Off-main design (W-LIVELOGOFFMAIN, 2026-09-21):** this class is only the main-actor
/// FAÇADE (consent, start/stop, the providers). Everything expensive — redaction,
/// serialisation, blob building, the bounded backlog, the upload, the back-off on
/// HTTP 429/503, the timer, the network monitor — runs on `LiveLogWorker`, an actor, off
/// the main thread. Before this, all of it ran on the main actor and, when the server
/// answered 429, re-processed the whole unshipped ring on every attempt: five main-thread
/// stalls of 0.7-4.5 s in one perfect-network call. See `LiveLogWorker.swift` for the exact
/// list of what still touches the main thread.
///
/// **Non-interference design:**
///   1. Off-main: see above.
///   2. Single-flight: one upload concurrent max.
///   3. Throttle: ≥ 2s between upload starts.
///   4. Hard caps: 64 KB / 256 lines per chunk (extra lines wait in the bounded backlog).
///   5. Self-suppression: "livelog"-tagged entries are never shipped, to avoid a feedback
///      loop.
///   6. Auth-gated, fail-silent: skip when no token.
///   7. Back-off: HTTP 429/503 → honour `Retry-After`, else 5 s doubling to 120 s with
///      jitter; the backlog keeps collecting (oldest dropped, counted) and nothing retries.
///
/// **Lifetime:** singleton, started once from `AppState.initialize()`.
@MainActor
public final class LiveLogStreamer {

    public static let shared = LiveLogStreamer()

    /// SECURITY C-10 — UserDefaults bool that gates ALL telemetry
    /// upload. Absent / false ⇒ the pump is fully inert. A future
    /// Settings toggle flips it through `setEnabled(_:)`.
    public static let consentKey: String = LiveLogConsent.key

    /// SECURITY C-10 — current consent state.
    ///
    /// MASVS-PRIVACY remediation (2026-08-20): an EXPLICIT user choice
    /// (Settings → Diagnostica → toggle → `setEnabled`) always wins. When
    /// the user has never chosen, the default is now unconditionally
    /// `false` on EVERY build channel — including TestFlight. Before this
    /// fix, the default was `!isAppStoreBuild`, which resolved `true` for
    /// TestFlight (the app's only real distribution channel today, per
    /// `CLAUDE.md`), with `setEnabled()` having zero reachable UI call
    /// sites anywhere in the app — i.e. the pump was silently on for every
    /// real user with no way to see or disable it, contradicting this very
    /// file's "opt-in" framing. See
    /// the MASVS-PRIVACY remediation of 2026-08-20 (assessment §1.1) for
    /// the full writeup. A real Settings toggle now exists (`PrivacySettingsScreen`,
    /// "Log diagnostici in tempo reale" under DIAGNOSTICA) and is the only
    /// way this ever becomes `true`.
    public static var isEnabled: Bool {
        return LiveLogConsent.isEnabled
    }

    /// SECURITY C-10 — flip the consent flag. When disabled we also
    /// tear the running pump down so consent withdrawal is immediate.
    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: consentKey)
        if !enabled {
            LiveLogStreamer.shared.stop()
            return
        }
        // W-CONSENTLATESTART (2026-08-29) — turning consent ON must actually
        // START the pump. It used to write the preference and nothing else,
        // and `start(serverUrl:getToken:getUserId:)` runs exactly once per
        // launch (from `AppState`), where it returns immediately if consent
        // was off at that moment. So the only way to ever begin shipping was
        // to enable the toggle and then RELAUNCH the app — which nobody
        // knows to do, and which made the feature look silently broken:
        // reported live 2026-08-29 ("il toggle è acceso ma i log non
        // salgono"), with the server confirming the device never even
        // attempted an upload.
        //
        // Safe because `startIfConfigured` re-checks consent itself and does
        // nothing at all until `start` has supplied the endpoint and the
        // providers.
        LiveLogStreamer.shared.startIfConfigured()
    }

    public let bootSessionId: String = UUID().uuidString.lowercased()
    public var flushIntervalSeconds: TimeInterval = 3.0
    public let maxChunkBytes: Int = 64 * 1024
    public let maxLinesPerChunk: Int = 256

    public typealias TokenProvider = @MainActor () -> String?
    public typealias UserIdProvider = @MainActor () -> String?
    /// W-LIVELOGAUTHREFRESH (2026-09-10) — ask the caller (AppState) to run
    /// its OWN existing, single-flight-coalesced refresh cascade
    /// (`runProactiveRefresh()`) and returns once it settles, success or
    /// failure either way. Deliberately does NOT hand this streamer a
    /// refresh token or a way to run its own refresh cascade — this
    /// process already has exactly one coalesced refresh path guarding a
    /// single-use refresh token against replay (see `runProactiveRefresh`'s
    /// own kdoc); a second, independent refresh attempt from this
    /// low-priority telemetry pipeline could race it and burn that
    /// single-use token out from under a real, in-flight refresh. See
    /// `LiveLogWorker.uploadFailed` for how a 401 uses this.
    public typealias RefreshRequestProvider = @MainActor () async -> Void

    private var serverUrl: String?
    private var tokenProvider: TokenProvider?
    private var userIdProvider: UserIdProvider?
    private var refreshRequestProvider: RefreshRequestProvider?
    private var isStarted: Bool = false

    /// Orders start/stop as they reach the worker actor (see `LiveLogWorker.start`).
    private var epoch: Int = 0
    private let worker: LiveLogWorker = LiveLogWorker()

    private init() {}

    /// Start the flush pump. Idempotent. Pass primitive values + closures
    /// — NEVER AppState directly (see file header for why).
    public func start(serverUrl: String,
                      getToken: @escaping TokenProvider,
                      getUserId: @escaping UserIdProvider,
                      requestTokenRefresh: @escaping RefreshRequestProvider) {
        // W-CONSENTLATESTART (2026-08-29) — retain the endpoint and the two
        // provider closures BEFORE the consent gate, so consent granted
        // later in the same launch can start the pump without waiting for a
        // relaunch. This is deliberately not a weakening of SECURITY C-10:
        // the gate below still returns before ANY observable side effect —
        // no tee, no timer, no path monitor, no upload, no network of any
        // kind. What is kept is four references already held elsewhere in
        // this process (the server URL the app is talking to anyway, and
        // three closures reading/driving state AppState owns), which
        // produce nothing on their own. Without them `setEnabled(true)` has
        // no endpoint to ship to and the toggle stays inert for the rest of
        // the launch.
        self.serverUrl = serverUrl
        self.tokenProvider = getToken
        self.userIdProvider = getUserId
        self.refreshRequestProvider = requestTokenRefresh
        // SECURITY C-10 — consent gate. No consent ⇒ no tee, no
        // upload, no timer, no path monitor. Returns BEFORE any
        // side effect. Default is false (key absent ⇒ false).
        guard LiveLogStreamer.isEnabled else { return }
        if isStarted { return }
        isStarted = true

        // Device facts are main-actor state (UIDevice): read once, here, and handed over.
        let model: String = UIDevice.current.model
        let os: String = "ios-" + UIDevice.current.systemVersion
        let appVer: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let session: String = bootSessionId

        // The one place the worker needs the main actor for: token, user id and the remote
        // kill-switch (`LOG_OTLP_EXPORT_ENABLED`, W-FLAGS). Sampled by the worker at most every
        // 30 s, not on every tick.
        let authProvider: @MainActor () -> LiveLogWorker.AuthSnapshot = {
            let token: String = getToken() ?? ""
            let user: String = getUserId() ?? "anon"
            let ship: Bool = FeatureFlags.bool("LOG_OTLP_EXPORT_ENABLED", true)
            return LiveLogWorker.AuthSnapshot(token: token, userId: user, shipEnabled: ship)
        }
        let config = LiveLogWorker.Config(serverUrl: serverUrl,
                                          bootSessionId: session,
                                          model: model,
                                          os: os,
                                          appVer: appVer,
                                          flushIntervalSeconds: flushIntervalSeconds,
                                          maxChunkBytes: maxChunkBytes,
                                          maxLinesPerChunk: maxLinesPerChunk,
                                          authProvider: authProvider,
                                          refreshProvider: requestTokenRefresh)
        epoch += 1
        let thisEpoch: Int = epoch
        let w: LiveLogWorker = worker
        Task { await w.start(epoch: thisEpoch, config: config) }

        let line: String = "LiveLogStreamer started session=" + session
        RTLog.info("livelog", line)
    }

    /// W-CONSENTLATESTART (2026-08-29) — begin shipping if, and only if,
    /// consent is granted AND `start` has already supplied the endpoint and
    /// providers for this launch. Called when the user grants consent from
    /// Settings, so the toggle takes effect immediately rather than at the
    /// next launch.
    ///
    /// Idempotent (`isStarted` short-circuits) and inert before `start`:
    /// with no `serverUrl` there is nothing to ship to, and returning here
    /// leaves the process exactly as it was.
    public func startIfConfigured() {
        guard LiveLogStreamer.isEnabled, !isStarted else { return }
        guard let url = serverUrl,
              let token = tokenProvider,
              let user = userIdProvider,
              let refresh = refreshRequestProvider else { return }
        start(serverUrl: url, getToken: token, getUserId: user, requestTokenRefresh: refresh)
    }

    /// Fully tear down the pump. Safe to call when not started.
    /// SECURITY C-10 — invoked on consent withdrawal so no timer or
    /// network monitor survives after the user opts out, and the buffered
    /// (already redacted) lines are dropped.
    public func stop() {
        isStarted = false
        epoch += 1
        let thisEpoch: Int = epoch
        let w: LiveLogWorker = worker
        Task { await w.stop(epoch: thisEpoch) }
    }
}
