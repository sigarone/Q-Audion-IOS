import Foundation

/// W-FLAGS -- remote feature-flag client (public, un-authed JSON poll).
///
/// Fetches a flat JSON dict of NON-SECRET booleans/strings from a public
/// static file (https://dash.bcrypto.com/flags.json), atomically swaps an
/// in-memory dict, persists it to UserDefaults, and exposes typed lookups
/// with a compiled fail-safe default. The remote file can ONLY relax or
/// restrict behaviour for keys the app already understands; an unknown or
/// absent key always resolves to the caller-supplied default.
///
/// **API design (CLAUDE.md section 16):** `start(...)` takes a PRIMITIVE
/// `flagsUrl` String only -- never AppState, never a closure dragging a
/// non-Sendable type into the signature. Same canonical shape as
/// `LiveLogStreamer.start(serverUrl:getToken:getUserId:)` and
/// `MetricKitDiagnostics.start()`. Section 13 honoured throughout: every
/// log argument is a single pre-bound `let line: String`, all formatting
/// lives in top-level static helpers, no inline `+` / interpolation /
/// `String(num)` inside any `Task { ... }` closure, `String(describing:)`
/// only. Pure ASCII. No new SPM dependency -- `URLSession` + `Foundation`.
///
/// **Trust model:** the flags host (dash.bcrypto.com) is NOT the pinned
/// voip host (voip.bcrypto.com). `PinnedURLSession` pins the voip cert
/// chain and would REJECT dash.bcrypto.com, so this deliberately uses a
/// PLAIN `URLSession` (default config -- system CA validation over HTTPS,
/// Let's Encrypt via Caddy). The payload is public and carries no secrets,
/// so no token and no cert pinning are required or wanted. This keeps the
/// flag fetch fully decoupled from the auth/voip backend (public read).
///
/// **SECURITY:** flags.json is served un-authed from a single static Caddy
/// route. It MUST contain ONLY non-secret booleans/strings -- never a key,
/// token, or any secret. This client treats it as untrusted public input:
/// it only reads keys the app already knows, and any value type other than
/// Bool/String for a requested key falls through to the compiled default.
///
/// **Fail-safe:** any network/parse failure leaves the last good cache in
/// place (or the compiled defaults on first run). Flags never block app
/// launch -- the refresh is fire-and-forget on a background `Task`, and the
/// periodic refresh runs on a `Timer` off the launch path.
///
/// **Known keys** (the ONLY keys the app reads from flags.json; any other
/// key in the remote file is ignored, and an absent key resolves to the
/// caller's compiled default):
///
///   | key                      | type | default               | effect                                   |
///   |--------------------------|------|-----------------------|------------------------------------------|
///   | `LOG_OTLP_EXPORT_ENABLED`| Bool | `LiveLogStreamer.isEnabled` (build-channel consent) | RUNTIME kill-switch for the log SHIPPER (`LiveLogStreamer.flushOnce`). `false` STOPS uploads on an already-shipped TestFlight build within the ~15 min refresh window; `true`/absent allow them. **Gates SHIP only -- egress REDACTION (`RuntimeLogSink.redactStructured`) is unconditional and is NEVER gated on this or any flag.** |
@MainActor
public final class FeatureFlags {

    public static let shared = FeatureFlags()

    /// UserDefaults key holding the last successfully fetched dict.
    private static let cacheKey: String = "qaudion.featureflags.cache.v1"

    /// Refresh cadence. ~15 min: short enough that a flag flip lands within
    /// a session, long enough to be effectively free (one tiny GET).
    private static let refreshIntervalSeconds: TimeInterval = 15.0 * 60.0

    private var flagsUrl: String?
    private var cache: [String: Any] = [:]
    private var timer: Timer?
    private var isStarted: Bool = false
    private var inflight: Bool = false

    private init() {
        self.cache = FeatureFlags.loadCache()
    }

    // MARK: - Lifecycle (CLAUDE.md section 16 -- primitive-only signature)

    /// Start the client. Idempotent. Primitive-only signature per
    /// CLAUDE.md section 16 (no AppState, no closures). Kicks one
    /// background refresh immediately, then schedules a periodic one.
    public func start(flagsUrl: String) {
        if isStarted { return }
        isStarted = true
        self.flagsUrl = flagsUrl
        let target: String = flagsUrl
        let line: String = "FeatureFlags started url=" + target
        RTLog.info("featureflags", line)
        refresh()
        scheduleTimer()
    }

    /// Fully tear down the periodic refresh. Safe to call when not started.
    public func stop() {
        timer?.invalidate()
        timer = nil
        isStarted = false
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval: TimeInterval = FeatureFlags.refreshIntervalSeconds
        let t: Timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                FeatureFlags.shared.refresh()
            }
        }
        RunLoop.main.add(t, forMode: RunLoop.Mode.common)
        timer = t
    }

    // MARK: - Fetch (plain URLSession -- NOT PinnedURLSession; see header)

    /// Fire-and-forget refresh. Safe to call repeatedly; never throws,
    /// never blocks. On success it atomically overwrites the in-memory +
    /// persisted cache; on any failure it leaves the existing cache
    /// untouched (fail-safe to last-known, else compiled defaults).
    public func refresh() {
        if inflight { return }
        guard let urlString = flagsUrl,
              let url = URL(string: urlString) else { return }
        inflight = true
        Task {
            await self.fetch(url: url)
        }
    }

    private func fetch(url: URL) async {
        let session: URLSession = URLSession(configuration: URLSessionConfiguration.default)
        var request: URLRequest = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData
        request.timeoutInterval = 15.0
        do {
            let pair = try await session.data(for: request)
            let data: Data = pair.0
            let response: URLResponse = pair.1
            let ok: Bool = FeatureFlags.isHttpOk(response)
            if !ok {
                self.inflight = false
                let code: String = FeatureFlags.httpStatusString(response)
                let line: String = "fetch non-200 status=" + code
                RTLog.warn("featureflags", line)
                return
            }
            let parsed: [String: Any] = FeatureFlags.parse(data)
            if parsed.isEmpty {
                self.inflight = false
                let line: String = "fetch parsed empty -- keeping last cache"
                RTLog.warn("featureflags", line)
                return
            }
            // Atomic swap: replace the whole dict, then persist.
            self.cache = parsed
            FeatureFlags.saveCache(parsed)
            self.inflight = false
            let summary: String = FeatureFlags.summarize(parsed)
            let line: String = "fetched: " + summary
            RTLog.info("featureflags", line)
        } catch {
            self.inflight = false
            let reason: String = FeatureFlags.errorString(error)
            let line: String = "fetch failed -- keeping last cache reason=" + reason
            RTLog.warn("featureflags", line)
        }
    }

    // MARK: - Typed lookups (compiled default always wins on absence)

    /// Resolve a Bool flag. Returns `def` when the key is absent or the
    /// stored value is not a Bool. The compiled default is the fail-safe.
    public static func bool(_ key: String, _ def: Bool) -> Bool {
        let value = FeatureFlags.shared.cache[key]
        guard let b = value as? Bool else { return def }
        return b
    }

    /// Resolve a String flag. Returns `def` when the key is absent or the
    /// stored value is not a String. The compiled default is the fail-safe.
    public static func string(_ key: String, _ def: String) -> String {
        let value = FeatureFlags.shared.cache[key]
        guard let s = value as? String else { return def }
        return s
    }

    // MARK: - Persistence

    private static func loadCache() -> [String: Any] {
        guard let raw = UserDefaults.standard.data(forKey: cacheKey) else { return [:] }
        return parse(raw)
    }

    private static func saveCache(_ dict: [String: Any]) {
        let normalized: [String: Any] = filterScalar(dict)
        guard JSONSerialization.isValidJSONObject(normalized) else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: normalized,
                                                     options: []) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    // MARK: - Parsing helpers (top-level -- section 13 keeps closures clean)

    /// Decode a JSON object into a flat dict, keeping ONLY Bool and String
    /// scalar values. Anything else (numbers, nested objects, arrays, null)
    /// is dropped, so a malformed or hostile payload can never inject a
    /// non-scalar that later traps a lookup. Never throws -- returns `[:]`
    /// on any decode failure so the caller keeps its last-known cache.
    private static func parse(_ data: Data) -> [String: Any] {
        let obj = try? JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else { return [:] }
        return filterScalar(dict)
    }

    /// Keep only Bool / String entries. NSNumber bridging note: JSON `true`
    /// decodes to an NSNumber that bridges to Bool, and JSON numbers also
    /// bridge to NSNumber -- so test the precise Objective-C type to avoid
    /// treating `1` as `true`. A value is a flag Bool only when its CFType
    /// is the boolean type; otherwise a numeric is dropped (not a flag).
    private static func filterScalar(_ dict: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in dict {
            if let s = value as? String {
                out[key] = s
                continue
            }
            if let n = value as? NSNumber {
                if isBoolNumber(n) {
                    out[key] = n.boolValue
                }
                continue
            }
            if let b = value as? Bool {
                out[key] = b
            }
        }
        return out
    }

    /// True only when the NSNumber actually wraps a CFBoolean (JSON true/
    /// false), not an integer/double. Prevents `"k": 1` from masquerading
    /// as a Bool flag.
    private static func isBoolNumber(_ n: NSNumber) -> Bool {
        let boolTypeId = CFBooleanGetTypeID()
        let valueTypeId = CFGetTypeID(n)
        return valueTypeId == boolTypeId
    }

    // MARK: - HTTP + formatting helpers (single-overload, type-checker-safe)

    private static func isHttpOk(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        let code: Int = http.statusCode
        return code >= 200 && code < 300
    }

    private static func httpStatusString(_ response: URLResponse) -> String {
        guard let http = response as? HTTPURLResponse else { return "none" }
        return String(describing: http.statusCode)
    }

    private static func errorString(_ error: Error) -> String {
        let ns = error as NSError
        return String(describing: ns.code)
    }

    /// Build a short, redaction-safe, single-line summary of the parsed
    /// flags for the W417 trail. Keys are app-controlled identifiers and
    /// values are short scalars, all well under the 24-char secret-scrubber
    /// threshold. Sorted for stable diffing across fetches.
    private static func summarize(_ dict: [String: Any]) -> String {
        let count: String = String(describing: dict.count)
        let keys: [String] = dict.keys.sorted()
        var parts: [String] = []
        parts.reserveCapacity(keys.count)
        for key in keys {
            let valueStr: String = scalarString(dict[key])
            let entry: String = key + "=" + valueStr
            parts.append(entry)
        }
        let joined: String = parts.joined(separator: " ")
        return "n=" + count + " " + joined
    }

    private static func scalarString(_ value: Any?) -> String {
        if let b = value as? Bool { return String(describing: b) }
        if let s = value as? String { return s }
        return "?"
    }
}
