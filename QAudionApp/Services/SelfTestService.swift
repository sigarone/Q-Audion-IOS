import Foundation
import CryptoKit
import QAudionEngine

/// W545 — Per-device synthetic self-tests.
///
/// Routines that exercise the call pipeline WITHOUT a peer call, so
/// the maintainer can detect regressions (e.g. encode latency
/// climbing on iOS 26.5, ML-KEM keygen slowing on older hardware)
/// just by looking at the dashboard. Each routine emits one
/// `selftest.*` telemetry event with timing percentiles.
///
/// Lifecycle:
///   - Runs ONCE per app launch (in background, ~3 s after start so
///     the call-setup code paths don't compete for CPU).
///   - Can be re-run on demand from Settings → Diagnostica → "Run
///     self-tests". The Settings entry isn't wired yet — the
///     `runAll()` method is public for the UI to call.
///
/// Routines (each one emits its own event):
///   - selftest.opus_roundtrip — encode 100 frames + decode them
///     back. Measures p50/p95/max in microseconds.
///   - selftest.mlkem_keygen — generate 10 ML-KEM-1024 keypairs.
///   - selftest.aead — AES-GCM seal+open 100 small messages.
///   - selftest.ws_reachable — best-effort HEAD /api/v1/health to
///     confirm the server is reachable from THIS device's network
///     position (catches captive-portal / DNS issues).
///
/// All routines are idempotent and have no side effects on call
/// state. They allocate small buffers and free them at the end.
@MainActor
public final class SelfTestService {

    public static let shared = SelfTestService()

    /// True while a runAll() pass is in flight — prevents the UI
    /// from spawning concurrent runs.
    public private(set) var isRunning: Bool = false

    private var serverUrl: String = ""
    private var getToken: TelemetryService.TokenProvider?

    public typealias TokenProvider = TelemetryService.TokenProvider

    private init() {}

    // ─── Lifecycle ─────────────────────────────────────────────────

    /// Wire + schedule the first auto-run. Idempotent.
    public func start(
        serverUrl: String,
        getToken: @escaping TokenProvider
    ) {
        self.serverUrl = serverUrl
        self.getToken = getToken
        // Defer the first auto-run so app-launch traffic (login,
        // contacts fetch, WS connect) gets all the CPU it needs.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await self?.runAll(trigger: "boot")
        }
    }

    /// Run every self-test in sequence and emit telemetry. Safe to
    /// call from UI. Returns once all routines have completed (~1-2 s
    /// in steady state, longer first time when the codecs warm up).
    public func runAll(trigger: String = "manual") async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        // Anchor event — the dashboard groups everything between
        // selftest.suite_started and selftest.suite_finished into
        // the same run via the run_id below. UUID per invocation.
        let runId = UUID().uuidString
        TelemetryService.shared.emit(
            kind: "selftest.suite_started",
            attrs: ["run_id": runId, "trigger": trigger]
        )

        await runOpusRoundtrip(runId: runId)
        await runMLKEMKeygen(runId: runId)
        await runAEAD(runId: runId)
        await runWSReachable(runId: runId)

        TelemetryService.shared.emit(
            kind: "selftest.suite_finished",
            attrs: ["run_id": runId]
        )
    }

    // ─── Routines ──────────────────────────────────────────────────

    /// Encode 100 frames of synthetic PCM through OpusCodec, decode
    /// them back. Captures the per-frame encode + decode latency. A
    /// regression in either direction implies a CPU / DSP issue we
    /// want to know about ASAP.
    private func runOpusRoundtrip(runId: String) async {
        let codec = OpusCodec(config: .secure())
        // Generate a deterministic test signal: 1 kHz sine at -12 dBFS.
        // 48 kHz / 20 ms → 960 samples per frame, mono, Int16.
        let frameSamples = AudioConstants.samplesPerFrame
        let bytesPerFrame = AudioConstants.bytesPerFrame
        var pcm = Data(count: bytesPerFrame)
        pcm.withUnsafeMutableBytes { (rawBuf: UnsafeMutableRawBufferPointer) in
            guard let p = rawBuf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            let twopi = Double.pi * 2.0
            for i in 0..<frameSamples {
                let v = sinTab(twopi * 1000.0 * Double(i) / 48000.0) * 8192.0
                p[i] = Int16(max(-32767, min(32767, Int(v))))
            }
        }

        var encUs: [Int] = []
        var decUs: [Int] = []
        let iterations = 100
        for _ in 0..<iterations {
            let t0 = DispatchTime.now()
            guard let encoded = codec.encode(pcm) else { continue }
            let t1 = DispatchTime.now()
            _ = codec.decode(encoded)
            let t2 = DispatchTime.now()
            encUs.append(Int((t1.uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000))
            decUs.append(Int((t2.uptimeNanoseconds - t1.uptimeNanoseconds) / 1_000))
        }
        guard !encUs.isEmpty, !decUs.isEmpty else { return }
        encUs.sort()
        decUs.sort()
        let encP50 = encUs[encUs.count / 2]
        let encP95 = encUs[(encUs.count * 95) / 100]
        let encMax = encUs.last ?? 0
        let decP50 = decUs[decUs.count / 2]
        let decP95 = decUs[(decUs.count * 95) / 100]
        let decMax = decUs.last ?? 0

        TelemetryService.shared.emit(
            kind: "selftest.opus_roundtrip",
            attrs: [
                "run_id":      runId,
                "iterations":  iterations,
                "enc_p50_us":  encP50,
                "enc_p95_us":  encP95,
                "enc_max_us":  encMax,
                "dec_p50_us":  decP50,
                "dec_p95_us":  decP95,
                "dec_max_us":  decMax,
                "bytes_per_frame": bytesPerFrame
            ]
        )
    }

    /// Generate 10 ML-KEM-1024 keypairs back-to-back. Slow keygen is
    /// a quality-of-call hit (longer dial-to-secure latency) — and
    /// it's the kind of thing that can regress unnoticed when libops
    /// or VPP bridge ABI changes.
    private func runMLKEMKeygen(runId: String) async {
        let iterations = 10
        var us: [Int] = []
        // W553-fix: `generateKeyPair()` is an instance method, not
        // static — construct once and reuse for the whole loop.
        let pqc = PqcKeyExchange()
        for _ in 0..<iterations {
            let t0 = DispatchTime.now()
            do {
                _ = try pqc.generateKeyPair()
            } catch {
                // Don't crash the suite — emit a failure event and bail.
                TelemetryService.shared.emit(
                    kind: "selftest.mlkem_keygen_fail",
                    attrs: ["run_id": runId, "error": String(describing: error)]
                )
                return
            }
            let t1 = DispatchTime.now()
            us.append(Int((t1.uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000))
        }
        us.sort()
        TelemetryService.shared.emit(
            kind: "selftest.mlkem_keygen",
            attrs: [
                "run_id":      runId,
                "iterations":  iterations,
                "p50_us":      us[us.count / 2],
                "p95_us":      us[(us.count * 95) / 100],
                "max_us":      us.last ?? 0
            ]
        )
    }

    /// AES-256-GCM seal+open round-trip. Catches CryptoKit /
    /// hardware AES intrinsics issues (rare but happens after major
    /// iOS releases when Apple ships a new accelerator).
    private func runAEAD(runId: String) async {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data(repeating: 0xAB, count: 207)  // ~Opus frame size
        let iterations = 100
        var us: [Int] = []
        var failures: Int = 0
        for _ in 0..<iterations {
            let t0 = DispatchTime.now()
            do {
                let sealed = try AES.GCM.seal(plaintext, using: key)
                let opened = try AES.GCM.open(sealed, using: key)
                if opened != plaintext {
                    failures += 1
                }
            } catch {
                failures += 1
            }
            let t1 = DispatchTime.now()
            us.append(Int((t1.uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000))
        }
        us.sort()
        TelemetryService.shared.emit(
            kind: "selftest.aead",
            attrs: [
                "run_id":      runId,
                "iterations":  iterations,
                "p50_us":      us[us.count / 2],
                "p95_us":      us[(us.count * 95) / 100],
                "max_us":      us.last ?? 0,
                "failures":    failures
            ]
        )
    }

    /// Probe `/api/v1/health` to confirm THIS device's network can
    /// reach the server. Catches captive portals, DNS poisoning, or
    /// cellular routes that block our specific endpoint.
    private func runWSReachable(runId: String) async {
        guard !serverUrl.isEmpty,
              let url = URL(string: serverUrl + "/api/v1/health") else {
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        let t0 = DispatchTime.now()
        do {
            // W-AUXPIN (2026-09-01): cert-pinned session (same delegate/pins
            // as the REST client) instead of URLSession.shared, so the probe
            // measures the SAME TLS path real traffic takes — and a pin
            // rotation miss shows up here as ok=false instead of hiding
            // behind an unpinned success (audit memory
            // reference_ios_stability_audit_2026_09_01, P1 item 6).
            let (data, resp) = try await PinnedURLSession.auxiliary(for: serverUrl).data(for: req)
            let t1 = DispatchTime.now()
            let httpResp = resp as? HTTPURLResponse
            let status = httpResp?.statusCode ?? 0
            TelemetryService.shared.emit(
                kind: "selftest.ws_reachable",
                attrs: [
                    "run_id":     runId,
                    "ok":         status == 200,
                    "status":     status,
                    "rtt_us":     Int((t1.uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000),
                    "bytes":      data.count
                ]
            )
        } catch {
            TelemetryService.shared.emit(
                kind: "selftest.ws_reachable",
                attrs: [
                    "run_id": runId,
                    "ok":     false,
                    "error":  error.localizedDescription
                ]
            )
        }
    }

    // ─── Helpers ───────────────────────────────────────────────────

    /// Inlined sin via Darwin to avoid importing Accelerate / Math
    /// (the routine runs once per launch — perf doesn't matter).
    private func sinTab(_ x: Double) -> Double {
        return _sin(x)
    }
}

@_silgen_name("sin") private func _sin(_ x: Double) -> Double
